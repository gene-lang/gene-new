## Admission for the AsyncReader protocol, including Gene implementations.
## The scheduler owns pending reads and upload borrows. Completed records are
## pruned on its root lane, with Value destruction outside the scheduler lock.

proc isIoReadMessage(scope: Scope, protocol: Value, name: string): bool =
  if name != "read" or protocol.kind != vkProtocol or scope == nil:
    return false
  let library = scope.application().stdlib
  if library == nil or not library.vars.hasKey("io"):
    return false
  let io = library.vars["io"].nsScope
  io.vars.hasKey("AsyncReader") and io.vars["AsyncReader"].bits == protocol.bits

proc pruneIoReadGuards(s: SchedulerState) =
  if s == nil or currentEventLane() != s.rootLane:
    return
  var retiredTasks: seq[Value]
  var retired: seq[IoReadGuard]
  withSchedulerLock(s):
    retiredTasks = move s.ioReadRetiredTasks
    var remove: seq[uint64]
    for key, guard in s.ioReadGuards:
      if not guard.admitting and guard.pending.kind == vkTask and
          guard.pending.taskDone:
        retiredTasks.add guard.pending
        guard.pending = NIL
      if not guard.admitting and guard.pending.kind != vkTask and
          guard.borrower == 0:
        remove.add key
    for key in remove:
      retired.add s.ioReadGuards[key]
      s.ioReadGuards.del(key)
  retiredTasks.setLen(0)
  retired.setLen(0)

proc publishIoReadPin(value: Value) =
  when compileOption("threads") and defined(gcAtomicArc):
    if activeWorkerThread:
      # A root-lane completion may release this scheduler-owned pin. Publish
      # its Value/scope edges just as a spawned capture is published.
      var scopes: HashSet[pointer]
      var values: HashSet[uint64]
      var chunks: HashSet[pointer]
      publishSpawnValue(value, scopes, values, chunks)

proc borrowProtocolRead(reader: Value, owner: uint64, scope: Scope) =
  if owner == 0:
    raise newException(GeneError, "read borrow requires an owner")
  let scheduler = schedulerForScope(scope)
  pruneIoReadGuards(scheduler)
  publishIoReadPin(reader)
  var busy = false
  var id = 0'u64
  withSchedulerLock(scheduler):
    var guard = scheduler.ioReadGuards.getOrDefault(reader.bits)
    if guard == nil:
      guard = IoReadGuard(reader: reader, id: nextRuntimeResourceId())
      scheduler.ioReadGuards[reader.bits] = guard
    id = guard.id
    busy = guard.admitting or
      (guard.pending.kind == vkTask and not guard.pending.taskDone) or
      (guard.borrower != 0 and guard.borrower != owner)
    if not busy:
      guard.borrower = owner
  if busy:
    raiseIoTestingError(scope, "IoBusy", "http_client/upload", id,
      "AsyncReader has a read in flight or another borrower")

proc releaseProtocolRead(reader: Value, owner: uint64, scope: Scope) =
  let scheduler = schedulerForScope(scope)
  withSchedulerLock(scheduler):
    let guard = scheduler.ioReadGuards.getOrDefault(reader.bits)
    if guard != nil and guard.borrower == owner:
      guard.borrower = 0
  pruneIoReadGuards(scheduler)

proc applyIoReadCall(target: Value, args: openArray[Value], named: NamedArgs,
                     scope: Scope, site: Value, loc: SourceLoc,
                     delegated = false): Value =
  if args.len < 2:
    raise newException(GeneError, "AsyncReader/read expects a receiver and max_bytes")
  let amount = requireInt64("AsyncReader/read max_bytes", args[1])
  if amount < 1 or amount > 1_048_576:
    raiseIoTestingError(scope, "IoError", "read", 0,
      "read max_bytes must be within 1..1048576")
  let scheduler = schedulerForScope(scope)
  pruneIoReadGuards(scheduler)
  let reader = args[0]
  publishIoReadPin(reader)
  if delegated:
    var continuation = false
    var owner = 0'u64
    withSchedulerLock(scheduler):
      let current = scheduler.ioReadGuards.getOrDefault(reader.bits)
      if current != nil:
        continuation =
          (current.admitting and current.borrower == currentIoReadOwner()) or
          (current.pending.kind == vkTask and currentFiberActive and
           activeTask.kind == vkTask and
           current.pending.taskSharesState(activeTask))
        owner = current.borrower
    if continuation:
      withIoReadOwner(owner):
        return applyCall(target, args, named, scope, site, loc)
  var guard: IoReadGuard
  var busy = false
  withSchedulerLock(scheduler):
    guard = scheduler.ioReadGuards.getOrDefault(reader.bits)
    if guard == nil:
      guard = IoReadGuard(reader: reader, id: nextRuntimeResourceId())
      scheduler.ioReadGuards[reader.bits] = guard
    busy = guard.admitting or
      (guard.pending.kind == vkTask and not guard.pending.taskDone) or
      (guard.borrower != 0 and guard.borrower != currentIoReadOwner())
    if not busy:
      guard.admitting = true
  if busy:
    raiseIoTestingError(scope, "IoBusy", "read", guard.id,
      "AsyncReader already has a read in flight or is borrowed")
  try:
    result = applyCall(target, args, named, scope, site, loc)
    if result.kind != vkTask:
      raiseIoTestingError(scope, "IoError", "read", guard.id,
        "AsyncReader/read did not return a Task")
    publishIoReadPin(result)
    withSchedulerLock(scheduler):
      if guard.pending.kind == vkTask:
        scheduler.ioReadRetiredTasks.add guard.pending
      guard.pending = result
  finally:
    withSchedulerLock(scheduler):
      guard.admitting = false
    pruneIoReadGuards(scheduler)
