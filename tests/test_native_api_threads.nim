import gene/ext/logging
import gene/[compiler, gir, native_api, printer, types, vm]
import std/[atomics, os, strutils, tables]
import std/unittest

proc detachOnWorker(attachment: GeneThreadAttachment) {.thread.} =
  geneDetachThread(attachment)

type AsyncCompleteArgs = ref object
  taskRoot: GeneRoot
  valueRoot: GeneRoot
  scope: Scope
  status: GeneStatus
  completed: bool

type AsyncCancelArgs = ref object
  taskRoot: GeneRoot
  scope: Scope
  status: GeneStatus
  cancelled: bool

type AsyncFailureArgs = ref object
  task: Value
  payload: Value
  scope: Scope
  accepted: bool
  rejected: bool
  unsettledOnRejection: bool

proc failTaskOnWorker(args: AsyncFailureArgs) {.thread.} =
  {.cast(gcsafe).}:
    let attachment = geneAttachThread()
    try:
      try:
        args.accepted = nativeTaskFail(args.task, "native", args.payload,
                                      hasValue = true, scope = args.scope)
      except GeneError:
        args.rejected = true
        args.unsettledOnRejection = not args.task.taskDone
        discard nativeTaskFail(args.task, "rejected before publication", scope = args.scope)
    finally:
      geneDetachThread(attachment)

proc completeTaskOnWorker(args: AsyncCompleteArgs) {.thread.} =
  {.cast(gcsafe).}:
    let attachment = geneAttachThread()
    os.sleep(10)
    let result = geneTaskComplete(geneRootGet(args.taskRoot), args.valueRoot,
                                  args.scope)
    args.status = result.status
    args.completed = result.value == TRUE
    geneDetachThread(attachment)

proc cancelTaskOnWorker(args: AsyncCancelArgs) {.thread.} =
  {.cast(gcsafe).}:
    let attachment = geneAttachThread()
    os.sleep(10)
    let result = geneTaskCancel(geneRootGet(args.taskRoot), args.scope)
    args.status = result.status
    args.cancelled = result.value == TRUE
    geneDetachThread(attachment)

type EventLaneArgs = ref object
  scope: Scope
  chunk: Chunk
  lane: int
  raised: bool
  message: string
  output: string

proc publishOnWorker(args: EventLaneArgs) {.thread.} =
  ## An embedding host thread reaching a bus the way `geneCall` lets it: no
  ## sendability check stands between them, because no value is transferred.
  {.cast(gcsafe).}:
    let attachment = geneAttachThread()
    args.lane = currentEventLane()
    try:
      args.output = run(args.chunk, args.scope).print()
    except CatchableError as e:
      args.raised = true
      args.message = e.msg
    geneDetachThread(attachment)

proc emitLogsOnWorker(id: int) {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< 100:
      let name = "gene/thread/" & $id & "/" & $i
      let routeId = resolveRouteId(name)
      if loggerEnabled(routeId, llInfo):
        emitLog(routeId, name, llInfo, "worker=" & $id & " item=" & $i)

const sharedErrorWorkers = 4
const sharedErrorCount = 16

proc prepareConcurrentProbe(scope: Scope, source: string): Chunk =
  # Foreign threads need the same publication preparation as VM workers:
  # scope values, bytecode constants, patterns, and callable bodies all use it.
  discard run(compileSource("(fn concurrent_probe [] " & source & ")",
                            useLocalSlots = false), scope)
  discard run(compileSource("(await (spawn concurrent_probe))",
                            useLocalSlots = false), scope)
  compileSource("(concurrent_probe)", useLocalSlots = false)

type SharedErrorGate = ref object
  ready: array[sharedErrorCount, Atomic[int]]
  failed: Atomic[bool]

type SharedErrorArgs = ref object
  scope: Scope
  chunk: Chunk
  errors: Value
  gate: SharedErrorGate
  messages: seq[string]
  failure: string

type SharedAwaitArgs = ref object
  scope: Scope
  chunk: Chunk
  tasks: Value
  gate: SharedErrorGate
  canPeek: bool
  outcomes: seq[int]
  failure: string

proc awaitSharedTasks(args: SharedAwaitArgs) {.thread.} =
  {.cast(gcsafe).}:
    let attachment = geneAttachThread()
    try:
      for i, task in args.tasks.listItems:
        args.scope.assign("pending", task)
        args.scope.assign("peek", newBool(args.canPeek and i mod 2 == 0))
        discard args.gate.ready[i].fetchAdd(1, moAcquireRelease)
        while args.gate.ready[i].load(moAcquire) < sharedErrorWorkers:
          if args.gate.failed.load(moAcquire): return
        let outcome = run(args.chunk, args.scope)
        args.outcomes.add(if outcome.kind == vkInt: int(outcome.intVal) else: -999)
    except CatchableError as failure:
      args.failure = failure.msg
      args.gate.failed.store(true, moRelease)
    finally:
      geneDetachThread(attachment)

proc raiseSharedErrors(args: SharedErrorArgs) {.thread.} =
  {.cast(gcsafe).}:
    let attachment = geneAttachThread()
    try:
      for i, error in args.errors.listItems:
        args.scope.assign("incoming", error)
        discard args.gate.ready[i].fetchAdd(1, moAcquireRelease)
        while args.gate.ready[i].load(moAcquire) < sharedErrorWorkers:
          if args.gate.failed.load(moAcquire): return
        let recovered = run(args.chunk, args.scope)
        if recovered.listItems[0].bits != error.bits:
          raise newException(ValueError, "catch changed the shared error's identity")
        args.messages.add recovered.listItems[1].strVal
    except CatchableError as failure:
      args.failure = failure.msg
      args.gate.failed.store(true, moRelease)
    finally:
      geneDetachThread(attachment)

suite "native api threaded attachment":
  test "concurrent awaits consume once while joins retain a consistent outcome":
    let app = newApplication()
    let producer = newGlobalScope(app)
    let generated = run(compileSource("(try (let n : Int \"bad\") catch TypeError $err)"), producer)
    var tasks: seq[Value]
    for i in 0 ..< sharedErrorCount:
      let task = nativeNewAsyncTask()
      case i mod 3
      of 0: discard nativeTaskComplete(task, newInt(7))
      of 1: discard nativeTaskFail(task, "original", scope = producer)
      else: discard nativeTaskFail(task, "generated", generated, hasValue = true, scope = producer)
      tasks.add task
    let shared = newList(tasks, immutable = true)
    markSharedValue(shared)
    let gate = SharedErrorGate()
    let source = """
      (try
        (if peek
          (match (pending .join)
            (when (TaskOutcome/ok value) value)
            (when (TaskOutcome/error (_ : TypeError)) 8)
            (when (TaskOutcome/error error)
              (if (== error/.Error:message "original") 9 -999))
            (else -999))
          (await pending))
        catch TypeError 8
        catch RuntimeError
          (if (== $err_msg "task result has already been awaited") -1
            (if (== $err_msg "task result has already been consumed by await") -1
              (if (== $err_msg "original") 9 -999))))
    """
    var arguments: array[sharedErrorWorkers, SharedAwaitArgs]
    var workers: array[sharedErrorWorkers, Thread[SharedAwaitArgs]]
    for i in 0 ..< sharedErrorWorkers:
      let scope = newGlobalScope(app)
      scope.define("pending", NIL)
      scope.define("peek", FALSE)
      arguments[i] = SharedAwaitArgs(scope: scope, chunk: prepareConcurrentProbe(scope, source), tasks: shared,
                                      gate: gate, canPeek: i > 0)
    for i in 0 ..< sharedErrorWorkers:
      createThread(workers[i], awaitSharedTasks, arguments[i])
    for i in 0 ..< sharedErrorWorkers: joinThread(workers[i])
    for argument in arguments:
      check argument.failure == ""
      check argument.outcomes.len == sharedErrorCount
    if not gate.failed.load(moAcquire):
      for i in 0 ..< sharedErrorCount:
        var successes = 0
        let expected = case i mod 3
          of 0: 7
          of 1: 9
          else: 8
        for argument in arguments:
          check argument.outcomes[i] in [-1, expected]
          if argument.outcomes[i] == expected: inc successes
        if i mod 2 == 0:
          check arguments[0].outcomes[i] == expected
        else:
          check successes == 1

  test "native failure publication checks payload and formatter Send requirements":
    for kind in ["data", "formatter", "admitted"]:
      let scope = newGlobalScope(newApplication())
      scope.implOverlayRoot = true
      var payload: Value
      if kind == "data":
        var props = initPropTable()
        props["message"] = newStr("native")
        props["local"] = newCell(newInt(1))
        payload = newNode(run(compileSource("RuntimeError"), scope), props = props)
      elif kind == "formatter":
        payload = run(compileSource("""
          (let local ($cell "native"))
          (type NativeFailure ^props {^code Int})
          (impl Error for NativeFailure
            (message message [] : Str ^errors [] (local .get)))
          (NativeFailure ^code 1)
        """), scope)
      else:
        payload = run(compileSource("""
          (try (fail ($freeze (AssertionError ^message "native"))) catch Error $err)
        """), scope)
      let task = nativeNewAsyncTask()
      markSharedValue(payload)
      markSharedValue(task)
      let args = AsyncFailureArgs(task: task, payload: payload, scope: scope)
      var worker: Thread[AsyncFailureArgs]
      createThread(worker, failTaskOnWorker, args)
      joinThread(worker)
      scope.define("pending", task)
      let caught = run(compileSource("(try (await pending) catch Error $err)"), scope)
      if kind == "admitted":
        check args.accepted
        check not args.rejected
        check caught.bits == payload.bits
      else:
        check args.rejected
        check args.unsettledOnRejection
        check caught.props["message"].strVal == "rejected before publication"
        if kind == "formatter": check not payload.hasErrorWitness

  test "concurrent failures retain one complete witness and every trace contribution":
    let app = newApplication()
    let parent = newGlobalScope(app)
    let errorType = run(compileSource("(type SharedFailure ^props {^message Str}) SharedFailure"), parent)
    var errors: seq[Value]
    for i in 0 ..< sharedErrorCount:
      var props = initPropTable()
      props["message"] = newStr("shared " & $i)
      errors.add newNode(errorType, props = props, immutable = true)
    let shared = newList(errors, immutable = true)
    markSharedValue(shared)
    let gate = SharedErrorGate()
    var workers: array[sharedErrorWorkers, Thread[SharedErrorArgs]]
    var arguments: array[sharedErrorWorkers, SharedErrorArgs]
    for i in 0 ..< sharedErrorWorkers:
      let scope = newScope(parent)
      scope.implOverlayRoot = true
      scope.define("incoming", NIL)
      discard run(compileSource("""
        (impl Error for SharedFailure
          (message message [] : Str ^errors [] "producer PRODUCER"))
        (fn bounce [] (fail incoming))
      """.replace("PRODUCER", $i), sourceName = "shared_error_producer.gene",
        useLocalSlots = false), scope)
      arguments[i] = SharedErrorArgs(scope: scope,
        chunk: prepareConcurrentProbe(scope, "(try (bounce) catch Error [$err $err_msg])"),
        errors: shared, gate: gate)
    for i in 0 ..< sharedErrorWorkers:
      createThread(workers[i], raiseSharedErrors, arguments[i])
    for i in 0 ..< sharedErrorWorkers: joinThread(workers[i])
    for argument in arguments:
      check argument.failure == ""
      check argument.messages.len == sharedErrorCount
    if not gate.failed.load(moAcquire):
      for i, error in errors:
        let selected = arguments[0].messages[i]
        check selected.startsWith("producer ")
        for argument in arguments: check argument.messages[i] == selected
        check error.hasErrorWitness
        var bounces = 0
        for frame in error.errorProperties["trace"].listItems:
          if frame.props["name"].strVal == "bounce": inc bounces
        check bounces == sharedErrorWorkers

  test "concurrent route creation and emission serialize complete records":
    let dir = getTempDir() / "gene_threaded_logging"
    createDir(dir)
    let path = dir / "events.jsonl"
    if fileExists(path): removeFile(path)
    var config = defaultLoggingConfig()
    for _, sink in config.sinks: closeLogSink(sink)
    config.sinks = initTable[string, LogSink]()
    config.sinks["file"] = newFileLogSink("file", path, lfJsonl, lflClose)
    config.rootTargets = @["file"]
    config.rootLevel = llInfo
    installLoggingConfig(config)
    var workers: array[4, Thread[int]]
    for i in 0 ..< workers.len:
      createThread(workers[i], emitLogsOnWorker, i)
    for i in 0 ..< workers.len:
      joinThread(workers[i])
    shutdownLogging()
    let lines = readFile(path).strip().splitLines()
    check lines.len == 400
    for line in lines:
      check line.startsWith("{\"schema\":\"gene.log.v1\"")
      check line.endsWith("}")
    removeFile(path)
    removeDir(dir)
    resetLogging()

  test "wrong-thread detach does not consume owner attachment":
    let scope = newGlobalScope()
    let callee = run(compileSource("(fn [x] (+ x 10))"), scope)
    let callback = geneNewCallback(callee)
    let attachment = geneAttachThread()

    check geneThreadAttached()

    var worker: Thread[GeneThreadAttachment]
    createThread(worker, detachOnWorker, attachment)
    joinThread(worker)

    check geneThreadAttached()
    let called = geneCallCallback(callback,
                                  GeneCall(args: @[newInt(32)],
                                           dispatchScope: scope))
    check called.status == gsOk
    check called.value == newInt(42)

    geneDetachThread(attachment)
    check not geneThreadAttached()

    geneReleaseCallback(callback)

  test "foreign thread can complete a native async task awaited at root":
    let scope = newGlobalScope()
    let task = geneNewAsyncTask()
    scope.define("pending", task)
    let args = AsyncCompleteArgs(taskRoot: geneRoot(task),
                                 valueRoot: geneRoot(newInt(77)),
                                 scope: scope)

    var worker: Thread[AsyncCompleteArgs]
    createThread(worker, completeTaskOnWorker, args)
    let awaited = run(compileSource("(await pending)"), scope)
    joinThread(worker)

    check awaited == newInt(77)
    check args.status == gsOk
    check args.completed
    geneRootRelease(args.valueRoot)
    geneRootRelease(args.taskRoot)

  test "a foreign thread cannot publish on a bus owned by another lane":
    # events.md §9.1. Every *transfer* of a bus is already refused because it
    # is not `Send` — channel, actor message, worker-safe spawn capture. This
    # is the path that transfers nothing: a host thread calling in through
    # native_api reaches the same scope directly, and would otherwise mutate
    # `subs` and the bucket tables concurrently with the owning lane.
    let scope = newGlobalScope()
    discard run(compileSource(
      "(type Ping : $event/Event) " &
      "(fn note [e] 1) " &
      "(var bus ($event/Bus)) " &
      "(bus .subscribe Ping note)"), scope)
    let args = EventLaneArgs(scope: scope,
                             chunk: compileSource("(bus .publish (Ping))"))

    var worker: Thread[EventLaneArgs]
    createThread(worker, publishOnWorker, args)
    joinThread(worker)

    check args.lane != currentEventLane()
    check args.raised
    check "owned by another lane" in args.message
    # The owning lane is unaffected: the bus still works, and the refusal left
    # no partial state behind.
    check run(compileSource("(bus .publish (Ping))"), scope)
             .props["delivered"].intVal == 1

  test "runtime require_root_lane rejects a non-owner lane with a typed error":
    let scope = newGlobalScope()
    let args = EventLaneArgs(
      scope: scope,
      chunk: compileSource(
        "(try (do ($runtime/require_root_lane) `root) " &
        " catch RuntimeLaneError `other)"))

    var worker: Thread[EventLaneArgs]
    createThread(worker, publishOnWorker, args)
    joinThread(worker)

    check args.lane != currentEventLane()
    check not args.raised
    check args.output == "other"

  test "sandbox transaction handles reject a non-owner lane":
    let scope = newGlobalScope()
    discard run(compileSource(
      "(var tx ($runtime/sandbox_transaction))"), scope)
    let args = EventLaneArgs(
      scope: scope,
      chunk: compileSource(
        "(try (tx .discard) \"missing\" catch Any $err/message)"))

    var worker: Thread[EventLaneArgs]
    createThread(worker, publishOnWorker, args)
    joinThread(worker)

    check args.lane != currentEventLane()
    check not args.raised
    check "owned by another lane" in args.output
    discard run(compileSource("(tx .discard)", useLocalSlots = false), scope)

  test "foreign thread can cancel a native async task awaited at root":
    let scope = newGlobalScope()
    let task = geneNewAsyncTask()
    scope.define("pending", task)
    let args = AsyncCancelArgs(taskRoot: geneRoot(task), scope: scope)

    var worker: Thread[AsyncCancelArgs]
    createThread(worker, cancelTaskOnWorker, args)
    expect GeneCancel:
      discard run(compileSource("(await pending)"), scope)
    joinThread(worker)

    check args.status == gsOk
    check args.cancelled
    geneRootRelease(args.taskRoot)
