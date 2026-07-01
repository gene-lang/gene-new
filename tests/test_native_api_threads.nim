import gene/[compiler, native_api, types, vm]
import std/os
import std/unittest

proc detachOnWorker(attachment: GeneThreadAttachment) {.thread.} =
  geneDetachThread(attachment)

type AsyncCompleteArgs = ref object
  taskRoot: GeneRoot
  valueRoot: GeneRoot
  scope: Scope
  status: GeneStatus
  completed: bool

proc completeTaskOnWorker(args: AsyncCompleteArgs) {.thread.} =
  {.cast(gcsafe).}:
    let attachment = geneAttachThread()
    os.sleep(10)
    let result = geneTaskComplete(geneRootGet(args.taskRoot), args.valueRoot,
                                  args.scope)
    args.status = result.status
    args.completed = result.value == TRUE
    geneDetachThread(attachment)

suite "native api threaded attachment":
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
