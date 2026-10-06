import gene/[compiler, io_lifecycle, printer, types, vm]
import std/unittest

var pendingCleanupLease = NIL
var pendingUserTask = NIL
var cleanupRetired = false
var lateCompletionIgnored = false
var simulatedIo: IoLifecycle
var simulatedTicket: IoTicket
var simulatedUserTask = NIL
var simulatedOperationLease = NIL
var simulatedCloseLease = NIL
var simulatedLateIgnored = false
var simulatedOpOwnerFound = false
var simulatedCloseOwnerFound = false

proc hasTaskOwner(scope: Scope): bool =
  var current = scope
  while current != nil:
    if current.ownsTasks: return true
    current = current.parent

proc beginSimulatedIo(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1 or args[0].kind != vkBytes or call == nil:
    raise newException(GeneError, "begin_sim_io expects Bytes")
  let admitted = simulatedIo.admitIoOperation(iodWrite, args[0].bytesVal.len)
  if not admitted.accepted or admitted.immediate:
    raise newException(GeneError, "simulated I/O admission failed")
  simulatedTicket = admitted.ticket
  simulatedOpOwnerFound = hasTaskOwner(call[].dispatchScope)
  let operation = nativeNewIoOperation(call[].dispatchScope)
  simulatedUserTask = operation.task
  simulatedOperationLease = operation.cleanupLease
  operation.task

proc closeSimulatedIo(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 0 or call == nil:
    raise newException(GeneError, "close_sim_io expects no arguments")
  let retireNow = simulatedIo.requestIoClose()
  simulatedCloseOwnerFound = hasTaskOwner(call[].dispatchScope)
  simulatedCloseLease = nativeNewIoCleanupLease(call[].dispatchScope)
  if simulatedUserTask.kind == vkTask:
    discard nativeTaskCancel(simulatedUserTask, call[].dispatchScope)
  if retireNow:
    discard simulatedIo.retireIoClose()
    discard nativeRetireIoCleanupLease(simulatedCloseLease,
                                       call[].dispatchScope)
  NIL

proc completeSimulatedIo(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 0 or call == nil:
    raise newException(GeneError, "complete_sim_io expects no arguments")
  let finished = simulatedIo.finishIoOperation(simulatedTicket)
  if not finished.accepted:
    raise newException(GeneError, "simulated I/O completion was stale")
  simulatedLateIgnored = not nativeTaskComplete(simulatedUserTask, newInt(3),
                                                call[].dispatchScope)
  discard nativeRetireIoCleanupLease(simulatedOperationLease,
                                     call[].dispatchScope)
  if finished.retireReady:
    discard simulatedIo.retireIoClose()
    discard nativeRetireIoCleanupLease(simulatedCloseLease,
                                       call[].dispatchScope)
  simulatedUserTask = NIL
  simulatedOperationLease = NIL
  simulatedCloseLease = NIL
  NIL

proc simulatedIoOutcome(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "sim_io_outcome expects no arguments")
  newList(@[newBool(simulatedLateIgnored),
            newBool(simulatedIo.ioSnapshot().phase == iopClosed),
            newBool(simulatedOpOwnerFound), newBool(simulatedCloseOwnerFound)])

proc beginCleanupLease(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 0 or call == nil:
    raise newException(GeneError, "begin_cleanup_lease expects a call scope")
  let operation = nativeNewIoOperation(call[].dispatchScope)
  pendingUserTask = operation.task
  pendingCleanupLease = operation.cleanupLease
  operation.task

proc completeCleanupLease(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 0 or call == nil or pendingCleanupLease.kind != vkTask:
    raise newException(GeneError, "no pending cleanup lease")
  lateCompletionIgnored = not nativeTaskComplete(pendingUserTask, newInt(1),
                                                 call[].dispatchScope)
  cleanupRetired = nativeRetireIoCleanupLease(pendingCleanupLease,
                                              call[].dispatchScope)
  pendingCleanupLease = NIL
  pendingUserTask = NIL
  NIL

proc cleanupWasRetired(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "retired? expects no arguments")
  newBool(cleanupRetired and lateCompletionIgnored)

proc newCleanupTestScope(): Scope =
  result = newGlobalScope()
  result.define("begin_cleanup_lease",
    newNativeCallFn("begin_cleanup_lease", beginCleanupLease,
                    acceptsNamed = false))
  result.define("complete_cleanup_lease",
    newNativeCallFn("complete_cleanup_lease", completeCleanupLease,
                    acceptsNamed = false))
  result.define("cleanup_retired?",
    newNativeFn("cleanup_retired?", cleanupWasRetired))
  result.define("begin_sim_io",
    newNativeCallFn("begin_sim_io", beginSimulatedIo,
                    acceptsNamed = false))
  result.define("close_sim_io",
    newNativeCallFn("close_sim_io", closeSimulatedIo,
                    acceptsNamed = false))
  result.define("complete_sim_io",
    newNativeCallFn("complete_sim_io", completeSimulatedIo,
                    acceptsNamed = false))
  result.define("sim_io_outcome",
    newNativeFn("sim_io_outcome", simulatedIoOutcome))

suite "I/O cleanup leases — structured scope":
  test "normal scope exit waits for physical retirement":
    cleanupRetired = false
    lateCompletionIgnored = false
    pendingCleanupLease = NIL
    pendingUserTask = NIL
    let scope = newCleanupTestScope()
    let value = run(compileSource("""
      (spawn ^lane root (do ($sleep 1) (complete_cleanup_lease)))
      (scope (let operation (begin_cleanup_lease)) (operation .cancel) nil)
      (cleanup_retired?)
    """), scope)
    check value.boolVal
    check pendingCleanupLease.kind == vkNil
    check pendingUserTask.kind == vkNil

  test "error exit does not cancel the cleanup obligation":
    cleanupRetired = false
    lateCompletionIgnored = false
    pendingCleanupLease = NIL
    pendingUserTask = NIL
    let scope = newCleanupTestScope()
    let value = run(compileSource("""
      (spawn ^lane root (do ($sleep 1) (complete_cleanup_lease)))
      (try
        (scope
          (begin_cleanup_lease)
          (fail (RuntimeError ^message "stop")))
        catch RuntimeError (cleanup_retired?))
    """), scope)
    check value.boolVal
    check pendingCleanupLease.kind == vkNil
    check pendingUserTask.kind == vkNil

  test "close during cancelled I/O keeps byte and cleanup leases until completion":
    simulatedLateIgnored = false
    simulatedUserTask = NIL
    simulatedOperationLease = NIL
    simulatedCloseLease = NIL
    let scope = newCleanupTestScope()
    simulatedIo = nativeNewIoLifecycle(scope, maxBytes = 16)
    let value = run(compileSource("""
      (let peak ($cell 0))
      (spawn ^lane root (do ($sleep 1) (complete_sim_io)))
      (try
        (scope
          (let operation (begin_sim_io ($binary/from_str "abc")))
          (try
            (fail (RuntimeError ^message "stop"))
            ensure (do
              (close_sim_io)
              (let stats ($runtime/gc_stats))
              (peak .set stats/io_cleanup_leases))))
        catch RuntimeError nil)
      (let after ($runtime/gc_stats))
      [(peak .get) after/io_retained_bytes after/io_cleanup_leases
       after/io_root_cleanup_tasks
       (sim_io_outcome)]
    """), scope)
    check value.print() == "[2 0 0 0 [true true true true]]"

  test "panic across nested ensure still waits for cleanup":
    cleanupRetired = false
    lateCompletionIgnored = false
    pendingCleanupLease = NIL
    pendingUserTask = NIL
    let scope = newCleanupTestScope()
    expect GenePanic:
      discard run(compileSource("""
        (spawn ^lane root (do ($sleep 1) (complete_cleanup_lease)))
        (scope
          (let operation (begin_cleanup_lease))
          (try (panic "stop") ensure nil))
      """), scope)
    check cleanupRetired and lateCompletionIgnored

  test "explicit return across nested ensure waits for cleanup":
    cleanupRetired = false
    lateCompletionIgnored = false
    pendingCleanupLease = NIL
    pendingUserTask = NIL
    let scope = newCleanupTestScope()
    let value = run(compileSource("""
      (fn exit_with_cleanup []
        (spawn ^lane root (do ($sleep 1) (complete_cleanup_lease)))
        (scope
          (let operation (begin_cleanup_lease))
          (operation .cancel)
          (try (return 42) ensure nil))
        0)
      [(exit_with_cleanup) (cleanup_retired?)]
    """), scope)
    check value.print() == "[42 true]"

  test "task cancellation across nested ensure waits for cleanup":
    cleanupRetired = false
    lateCompletionIgnored = false
    pendingCleanupLease = NIL
    pendingUserTask = NIL
    let scope = newCleanupTestScope()
    let value = run(compileSource("""
      (let ready ($channel ^capacity 1))
      (let release ($channel ^capacity 1))
      (spawn ^lane root (do (release .recv) (complete_cleanup_lease)))
      (let target (spawn ^lane root
        (scope
          (begin_cleanup_lease)
          (ready .send 1)
          (try ($sleep 1000) ensure nil))))
      (ready .recv)
      (target .cancel)
      (release .send 1)
      [(match (target .join) ^!exhaustive (when TaskOutcome/cancelled true))
       (cleanup_retired?)]
    """), scope)
    check value.print() == "[true true]"
