import gene/ext/logging
import gene/[compiler, gir, native_api, types, vm]
import std/[os, strutils, tables]
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

proc publishOnWorker(args: EventLaneArgs) {.thread.} =
  ## An embedding host thread reaching a bus the way `geneCall` lets it: no
  ## sendability check stands between them, because no value is transferred.
  {.cast(gcsafe).}:
    let attachment = geneAttachThread()
    args.lane = currentEventLane()
    try:
      discard run(args.chunk, args.scope)
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

suite "native api threaded attachment":
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
