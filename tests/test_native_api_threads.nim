import gene/ext/logging
import gene/[compiler, gir, native_api, native_managed, printer, types, vm]
# native_managed installs the owned ingress adapter exercised below.
import std/[atomics, dynlib, monotimes, os, osproc, strtabs, streams,
            strutils, tables, times]
import std/unittest

type
  SetIngressApi = proc(api: ptr GeneApi): cint {.cdecl.}
  IngressEmitForeign = proc(context: pointer, generation: uint64,
                       data: pointer, length: csize_t,
                       began, enqueued: ptr cint): cint {.cdecl.}
  IngressHoldStart = proc(context: pointer, generation: uint64): cint {.cdecl.}
  IngressHoldFinish = proc(): cint {.cdecl.}

proc unloadIngressFixture(address: pointer) {.nimcall.} =
  unloadLib(cast[LibHandle](address))

var ingressForeignDelivered: seq[string]
var ingressWakeDeliveredAt: MonoTime

type DelayedIngressArgs = object
  context: pointer
  generation: uint64

proc delayedIngress(args: DelayedIngressArgs) {.thread.} =
  os.sleep(50)
  if geneIngressBegin(args.context, args.generation) == 1:
    var byte = 'w'
    discard geneIngressEnqueue(args.context, addr byte, 1)
    geneIngressEnd(args.context)

proc captureIngressWake(args: openArray[Value]): Value {.nimcall.} =
  ingressWakeDeliveredAt = getMonoTime()
  NIL

proc captureIngressForeign(args: openArray[Value]): Value {.nimcall.} =
  ingressForeignDelivered.add args[0].bytesVal
  NIL

proc buildIngressFixture(): string =
  let compiler = findExe("cc")
  if compiler.len == 0:
    return ""
  let root = getTempDir() / "gene-native-ingress-fixture"
  createDir(root)
  result = root / (when defined(macosx): "native_ingress.dylib"
                   else: "native_ingress.so")
  var args = when defined(macosx): @["-dynamiclib", "-fPIC"]
             else: @["-shared", "-fPIC"]
  args.add @["-std=c11", "-pthread", "-Isrc/gene",
    "tests/fixtures/native_ingress_fixture.c", "-o", result]
  let environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): environment[key] = value
  when defined(macosx):
    let pinned = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if dirExists(pinned): environment["SDKROOT"] = pinned
  let process = startProcess(compiler, getCurrentDir(), args,
                             env = environment,
                             options = {poStdErrToStdOut})
  let diagnostics = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  if code != 0:
    raise newException(ValueError,
      "ingress C fixture failed to compile: " & diagnostics)

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
  test "ingress C ingress copies foreign notifications and waits for entry quiescence":
    let path = buildIngressFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      if handle != nil:
        let library = newFfiLibrary(cast[pointer](handle), path,
                                    unloadIngressFixture)
        defer: library.closeFfiLibrary()
        let setApi = cast[SetIngressApi](symAddr(handle, "gene_test_set_api"))
        var api = geneApiIngress()
        check setApi(addr api) == 0
        let emit = cast[IngressEmitForeign](symAddr(handle,
          "gene_test_ingress_emit_foreign"))
        let holdStart = cast[IngressHoldStart](symAddr(handle,
          "gene_test_ingress_hold_start"))
        let holdFinish = cast[IngressHoldFinish](symAddr(handle,
          "gene_test_ingress_hold_finish"))
        check emit != nil and holdStart != nil and holdFinish != nil
        let context = newGeneIngressContext(91, maxCount = 2,
          maxBytes = 4, maxPayload = 4)
        var payload = "ok"
        var began, enqueued: cint
        check emit(context, 91, addr payload[0], 2,
                   addr began, addr enqueued) == 0
        check began == 1 and enqueued == GeneIngressAccepted
        payload[0] = 'X'
        var copied = ""
        check geneIngressPop(context, copied)
        check copied == "ok"
        check holdStart(context, 91) == 1
        check geneIngressStats(context).inFlight == 1
        geneIngressClose(context)
        geneIngressConfirmUnregistered(context)
        check not geneIngressCanRetire(context)
        check holdFinish() == GeneIngressClosed
        check geneIngressCanRetire(context)
        check geneIngressStats(context).firstFailure == GeneIngressClosed
        geneIngressDestroy(context)
        let bounded = newGeneIngressContext(93, maxCount = 1,
          maxBytes = 1, maxPayload = 1)
        check emit(bounded, 92, addr payload[0], 1,
                   addr began, addr enqueued) == 0
        check began == 0 and enqueued == GeneIngressEntryMissing
        geneIngressFailNextAllocation(bounded)
        check emit(bounded, 93, addr payload[0], 1,
                   addr began, addr enqueued) == 0
        check began == 1 and enqueued == GeneIngressAllocationFailed
        check emit(bounded, 93, addr payload[0], 1,
                   addr began, addr enqueued) == 0
        check enqueued == GeneIngressAccepted
        check emit(bounded, 93, addr payload[0], 1,
                   addr began, addr enqueued) == 0
        check enqueued == GeneIngressOverflow
        let stats = geneIngressStats(bounded)
        check stats.rejected == 2
        check stats.firstFailure == GeneIngressAllocationFailed
        geneIngressClose(bounded)
        geneIngressConfirmUnregistered(bounded)
        check geneIngressCanRetire(bounded)
        geneIngressDestroy(bounded)
        let scope = newGlobalScope()
        ingressForeignDelivered.setLen(0)
        let subscription = newGeneIngressSubscription(
          newNativeFn("capture_ingress_foreign", captureIngressForeign), scope)
        var message = "foreign"
        check emit(subscription.context, subscription.id,
                   addr message[0], csize_t(message.len),
                   addr began, addr enqueued) == 0
        check began == 1 and enqueued == GeneIngressAccepted
        discard run(compileSource("($sleep 5)"), scope)
        check ingressForeignDelivered == @["foreign"]
        check subscription.handled == 1
        geneIngressRequestCloseSubscription(subscription)
        geneIngressConfirmUnregistered(subscription.context)
        geneIngressReleaseSubscription(subscription)

  test "ingress ingress wake interrupts a long root scheduler sleep":
    let scope = newGlobalScope()
    let subscription = newGeneIngressSubscription(
      newNativeFn("capture_ingress_wake", captureIngressWake), scope)
    let started = getMonoTime()
    var worker: Thread[DelayedIngressArgs]
    createThread(worker, delayedIngress,
      DelayedIngressArgs(context: subscription.context,
                         generation: subscription.id))
    discard run(compileSource("($sleep 700)"), scope)
    joinThread(worker)
    let delay = (ingressWakeDeliveredAt - started).inMilliseconds
    check delay >= 20 and delay < 250
    check subscription.handled == 1
    geneIngressRequestCloseSubscription(subscription)
    geneIngressConfirmUnregistered(subscription.context)
    geneIngressReleaseSubscription(subscription)

  test "ingress unregister runs off-root and retains context through late C entry":
    let path = buildIngressFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      if handle != nil:
        let library = newFfiLibrary(cast[pointer](handle), path,
                                    unloadIngressFixture)
        defer: library.closeFfiLibrary()
        let setApi = cast[SetIngressApi](symAddr(handle, "gene_test_set_api"))
        var api = geneApiIngress()
        check setApi(addr api) == 0
        let holdStart = cast[IngressHoldStart](symAddr(handle,
          "gene_test_ingress_hold_start"))
        let holdFinish = cast[IngressHoldFinish](symAddr(handle,
          "gene_test_ingress_hold_finish"))
        let slow = cast[GeneIngressUnregisterProc](symAddr(handle,
          "gene_test_ingress_unregister_slow"))
        let failure = cast[GeneIngressUnregisterProc](symAddr(handle,
          "gene_test_ingress_unregister_fail"))
        check holdStart != nil and holdFinish != nil
        check slow != nil and failure != nil
        let scope = newGlobalScope()
        let baseline = nativeRootCount()
        let subscription = newGeneIngressSubscription(
          newNativeFn("capture_ingress_foreign", captureIngressForeign), scope,
          unregisterProc = slow)
        let waiting1 = geneIngressWaitClosed(subscription, scope)
        let waiting2 = geneIngressWaitClosed(subscription, scope)
        check waiting1.bits != waiting2.bits
        check holdStart(subscription.context, subscription.id) == 1
        let started = getMonoTime()
        geneIngressRequestCloseSubscription(subscription)
        check (getMonoTime() - started).inMilliseconds < 100
        check geneIngressSubscriptionStatus(subscription).unregisterPending
        let deadline = getMonoTime() + initDuration(seconds = 3)
        while geneIngressSubscriptionStatus(subscription).unregisterPending and
            getMonoTime() < deadline:
          discard run(compileSource("($sleep 10)"), scope)
        check geneIngressStats(subscription.context).unregistered
        check not geneIngressCanRetire(subscription.context)
        check not waiting1.taskDone and not waiting2.taskDone
        check holdFinish() == GeneIngressClosed
        check geneIngressCanRetire(subscription.context)
        geneIngressReleaseSubscription(subscription)
        check waiting1.taskDone and waiting2.taskDone
        check not waiting1.taskHasError and not waiting2.taskHasError
        let late = geneIngressWaitClosed(subscription, scope)
        check late.taskDone and late.bits != waiting1.bits
        when defined(geneRcStats):
          check nativeRootCount() == baseline

        let failed = newGeneIngressSubscription(
          newNativeFn("capture_ingress_foreign", captureIngressForeign), scope,
          unregisterProc = failure)
        let failedWait = geneIngressWaitClosed(failed, scope)
        geneIngressRequestCloseSubscription(failed)
        let failDeadline = getMonoTime() + initDuration(seconds = 3)
        while geneIngressSubscriptionStatus(failed).unregisterPending and
            getMonoTime() < failDeadline:
          discard run(compileSource("($sleep 10)"), scope)
        check failed.terminalStatus == gsError
        check failed.terminalMessage.contains("unregistration returned 17")
        check failedWait.taskDone and failedWait.taskHasError
        let repeatWait = geneIngressWaitClosed(failed, scope)
        check repeatWait.taskDone and repeatWait.taskHasError
        check repeatWait.bits != failedWait.bits
        check not geneIngressStats(failed.context).unregistered
        expect GeneError:
          geneIngressReleaseSubscription(failed)
        # The fixture guarantees it has no future callbacks despite the
        # nonzero diagnostic; the test may explicitly discharge that proof.
        geneIngressConfirmUnregistered(failed.context)
        geneIngressReleaseSubscription(failed)

  test "ingress Gene IoResource wrapper waits for physical native retirement":
    let path = buildIngressFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      if handle != nil:
        let library = newFfiLibrary(cast[pointer](handle), path,
                                    unloadIngressFixture)
        defer: library.closeFfiLibrary()
        let setApi = cast[SetIngressApi](symAddr(handle, "gene_test_set_api"))
        var api = geneApiIngress()
        check setApi(addr api) == 0
        let emit = cast[IngressEmitForeign](symAddr(handle,
          "gene_test_ingress_emit_foreign"))
        let slow = cast[GeneIngressUnregisterProc](symAddr(handle,
          "gene_test_ingress_unregister_slow"))
        let scope = newGlobalScope()
        ingressForeignDelivered.setLen(0)
        let baseline = nativeRootCount()
        let subscription = newGeneIngressSubscription(
          newNativeFn("capture_ingress_foreign", captureIngressForeign), scope,
          unregisterProc = slow)
        let wrapper = newGeneIngressHandle(subscription, scope)
        scope.define("native_handle", wrapper)
        var message = "owned"
        var began, enqueued: cint
        check emit(subscription.context, subscription.id,
                   addr message[0], csize_t(message.len),
                   addr began, addr enqueued) == 0
        check began == 1 and enqueued == GeneIngressAccepted
        discard run(compileSource("($sleep 5)"), scope)
        check ingressForeignDelivered == @["owned"]
        let active = run(compileSource("(native_handle .status)"), scope)
        check active.mapEntries["state"].strVal == "active"
        check active.mapEntries["handled"].intVal == 1
        let first = run(compileSource(
          "(let IoResource $io/IoResource) " &
          "(native_handle .IoResource:wait_closed)"), scope)
        let second = run(compileSource(
          "(native_handle .IoResource:wait_closed)"), scope)
        check first.bits != second.bits
        check not first.taskDone and not second.taskDone
        let during = run(compileSource(
          "(/io_root_cleanup_tasks ($runtime/gc_stats))"), scope)
        check during.intVal >= 3
        let started = getMonoTime()
        discard run(compileSource("(native_handle .IoResource:close)"), scope)
        check (getMonoTime() - started).inMilliseconds < 100
        discard nativeTaskCancel(first, scope)
        check first.taskCancelled
        discard run(compileSource(
          "(await (native_handle .IoResource:wait_closed))"), scope)
        check subscription.released
        check first.taskDone and second.taskDone
        check first.taskCancelled and not second.taskHasError
        let closed = run(compileSource("(native_handle .status)"), scope)
        check closed.mapEntries["state"].strVal == "closed"
        let late = run(compileSource(
          "(native_handle .IoResource:wait_closed)"), scope)
        check late.taskDone and late.bits != first.bits
        let after = run(compileSource(
          "(/io_root_cleanup_tasks ($runtime/gc_stats))"), scope)
        check after.intVal == 0
        when defined(geneRcStats):
          check nativeRootCount() == baseline

  test "ingress abandoned Gene handle requests close and retires after unregister":
    let path = buildIngressFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      if handle != nil:
        let library = newFfiLibrary(cast[pointer](handle), path,
                                    unloadIngressFixture)
        defer: library.closeFfiLibrary()
        let setApi = cast[SetIngressApi](symAddr(handle, "gene_test_set_api"))
        var api = geneApiIngress()
        check setApi(addr api) == 0
        let slow = cast[GeneIngressUnregisterProc](symAddr(handle,
          "gene_test_ingress_unregister_slow"))
        let scope = newGlobalScope()
        let subscription = newGeneIngressSubscription(
          newNativeFn("capture_ingress_foreign", captureIngressForeign), scope,
          unregisterProc = slow)
        var wrapper = newGeneIngressHandle(subscription, scope)
        wrapper = NIL
        let deadline = getMonoTime() + initDuration(seconds = 3)
        while not subscription.released and getMonoTime() < deadline:
          discard run(compileSource("($sleep 10)"), scope)
        check subscription.released
        check subscription.closeRequested

  test "ingress C registration bridge creates a Gene-owned subscription":
    let path = buildIngressFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      if handle != nil:
        let library = newFfiLibrary(cast[pointer](handle), path,
                                    unloadIngressFixture)
        let scope = newGlobalScope()
        scope.define("bridge_library", library)
        scope.define("bridge_handler",
          newNativeFn("capture_ingress_foreign", captureIngressForeign))
        ingressForeignDelivered.setLen(0)
        let wrapper = run(compileSource("""
          ($native/ingress/open bridge_library bridge_handler
            ^register "gene_test_ingress_register"
            ^unregister "gene_test_ingress_unregister_slow")
        """), scope)
        scope.define("bridge_subscription", wrapper)
        discard run(compileSource("($sleep 5)"), scope)
        check ingressForeignDelivered == @["registered"]
        let status = run(compileSource("(bridge_subscription .status)"), scope)
        check status.mapEntries["state"].strVal == "active"
        check status.mapEntries["handled"].intVal == 1
        expect GeneError:
          library.closeFfiLibrary()
        discard run(compileSource("""
          (let IoResource $io/IoResource)
          (bridge_subscription .IoResource:close)
          (await (bridge_subscription .IoResource:wait_closed))
        """), scope)
        check run(compileSource("(bridge_subscription .status)"),
                  scope).mapEntries["state"].strVal == "closed"
        library.closeFfiLibrary()
        check library.ffiLibraryClosed

  test "ingress failed registration keeps cleanup until C unregister returns":
    let path = buildIngressFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      if handle != nil:
        let library = newFfiLibrary(cast[pointer](handle), path,
                                    unloadIngressFixture)
        let scope = newGlobalScope()
        scope.define("bridge_library", library)
        scope.define("bridge_handler",
          newNativeFn("capture_ingress_foreign", captureIngressForeign))
        let baseline = nativeRootCount()
        expect GeneError:
          discard run(compileSource("""
            ($native/ingress/open bridge_library bridge_handler
              ^register "gene_test_ingress_register_fail"
              ^unregister "gene_test_ingress_unregister_slow")
          """), scope)
        expect GeneError:
          library.closeFfiLibrary()
        discard run(compileSource("($sleep 250)"), scope)
        expect GeneError:
          discard run(compileSource("""
            ($native/ingress/open bridge_library bridge_handler
              ^register "gene_test_ingress_register_no_context"
              ^unregister "gene_test_ingress_unregister_slow")
          """), scope)
        discard run(compileSource("($sleep 250)"), scope)
        library.closeFfiLibrary()
        check library.ffiLibraryClosed
        when defined(geneRcStats):
          check nativeRootCount() == baseline
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
    for kind in ["data", "formatter", "admitted", "builtin"]:
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
      elif kind == "admitted":
        payload = run(compileSource("""
          (try (fail ($freeze (AssertionError ^message "native"))) catch Error $err)
        """), scope)
      else:
        # A foreign native thread may admit a built-in error before this
        # Application has ever spawned a Gene task.
        payload = run(compileSource("($freeze (AssertionError ^message \"native\"))"), scope)
      let task = nativeNewAsyncTask()
      markSharedValue(payload)
      markSharedValue(task)
      let args = AsyncFailureArgs(task: task, payload: payload, scope: scope)
      var worker: Thread[AsyncFailureArgs]
      createThread(worker, failTaskOnWorker, args)
      joinThread(worker)
      scope.define("pending", task)
      let caught = run(compileSource("(try (await pending) catch Error $err)"), scope)
      if kind in ["admitted", "builtin"]:
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
