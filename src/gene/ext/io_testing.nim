## Deterministic native I/O adapter for IO-1 conformance.
##
## An admitted operation holds a user Task and an independent cleanup lease.
## `complete_*` stands in for a worker's physical completion; close may settle
## the user Task first, but only completion releases the ticket and lease.

proc ioTestingErrorValue(scope: Scope, kind, operation: string, id: uint64,
                         message: string, transferred = -1,
                         cause: Value = NIL): Value =
  var props = initPropTable()
  props["message"] = newStr(message)
  props["operation"] = newStr(operation)
  props["resource_id"] = newIntFromDecimal($id)
  if transferred >= 0:
    props["bytes_transferred"] = newInt(transferred)
  if cause.kind != vkNil:
    props["cause"] = cause
  let typ = builtinBinding(scope, kind)
  newNode(if typ.kind == vkType: typ else: newSym(kind),
          props = props, immutable = true)

proc raiseIoTestingError(scope: Scope, kind, operation: string, id: uint64,
                         message: string) {.noreturn.} =
  var error: ref GeneError
  new(error)
  error.msg = message
  error.errVal = ioTestingErrorValue(scope, kind, operation, id, message)
  error.hasErrVal = true
  raise error

proc ioTestingRecord(value: Value, call: ptr NativeCall,
                     operation: string): IoTestingRecord =
  let scope = if call == nil: nil else: call[].dispatchScope
  let app = if scope == nil: currentApplication() else: scope.application()
  let typ = builtinBinding(scope, "IoTestResource")
  if value.kind != vkNode or typ.kind != vkType or value.head.bits != typ.bits:
    raiseTypeError("io/testing " & operation, "IoTestResource", value, scope)
  let id = value.nodeResourceId
  acquire(resourceRecordLock)
  try:
    result = ioTestingRecords.getOrDefault(id)
  finally:
    release(resourceRecordLock)
  if result == nil or result.application != app:
    raiseIoTestingError(scope, "IoClosed", operation, id,
                        "I/O resource is unavailable")
  if result.ownerLane != currentEventLane():
    raiseValueSemanticError("RuntimeLaneError",
      "I/O resource belongs to another lane")

proc ioTestingReadLifecycle*(value: Value): IoLifecycle =
  ## The lifecycle behind an IoTestResource Value, or nil.
  if value.kind != vkNode or value.nodeResourceId == 0:
    return nil
  acquire(resourceRecordLock)
  try:
    let record = ioTestingRecords.getOrDefault(value.nodeResourceId)
    if record != nil:
      result = record.lifecycle
  finally:
    release(resourceRecordLock)

proc ioTestingAdmission(record: IoTestingRecord, direction: IoDirection,
                        bytes: int, scope: Scope,
                        operation: string): IoAdmission =
  result = record.lifecycle.admitIoOperation(direction, bytes)
  if result.accepted:
    return
  let kind =
    case result.failure
    of iaBusy: "IoBusy"
    of iaClosed: "IoClosed"
    of iaBackpressure: "IoBackpressure"
    else: "IoError"
  raiseIoTestingError(scope, kind, operation,
    record.lifecycle.ioResourceId(),
    case result.failure
    of iaBusy: "I/O direction already has an active operation"
    of iaClosed: "I/O resource is closing or closed"
    of iaBackpressure: "I/O byte admission budget is exhausted"
    else: "invalid I/O operation size")

proc ioTestingRetire(record: IoTestingRecord, scope: Scope) =
  if not record.lifecycle.retireIoClose(record.closeFailure):
    return
  if record.closeLease.kind == vkTask:
    discard nativeRetireIoCleanupLease(record.closeLease, scope)
    record.closeLease = NIL
  for waiter in record.waiters:
    if record.closeFailure.len == 0:
      discard nativeTaskComplete(waiter, NIL, scope)
    else:
      let error = ioTestingErrorValue(scope, "IoError", "close",
        record.lifecycle.ioResourceId(), record.closeFailure)
      discard nativeTaskFail(waiter, record.closeFailure, error,
                             hasValue = true, scope = scope)
  record.waiters.setLen(0)

proc biIoTestingNew(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "io/testing/new expects no positional arguments")
  let scope = if call == nil: nil else: call[].dispatchScope
  if scope == nil:
    raise newException(GeneError, "io/testing/new needs a call scope")
  if currentEventLane() != schedulerForScope(scope).rootLane:
    raiseValueSemanticError("RuntimeLaneError", "io/testing/new requires the root lane")
  var maxBytes = DefaultIoResourceBytes
  var sawMaxBytes = false
  for i, name in call[].namedNames:
    if name != "max_bytes" or sawMaxBytes:
      raise newException(GeneError,
        "io/testing/new got unexpected or duplicate named argument: " & name)
    sawMaxBytes = true
    let amount = requireInt64("io/testing/new max_bytes", call[].namedValues[i])
    if amount < 0 or amount > DefaultIoResourceBytes:
      raise newException(GeneError,
        "io/testing/new max_bytes must be within 0..1048576")
    maxBytes = int(amount)
  let lifecycle = nativeNewIoLifecycle(scope, maxBytes)
  let id = lifecycle.ioResourceId()
  let record = IoTestingRecord(application: scope.application(),
    ownerLane: currentEventLane(), lifecycle: lifecycle)
  acquire(resourceRecordLock)
  try:
    ioTestingRecords[id] = record
  finally:
    release(resourceRecordLock)
  try:
    newRuntimeResourceHandle(scope, "IoTestResource", id)
  except CatchableError:
    acquire(resourceRecordLock)
    ioTestingRecords.del(id)
    release(resourceRecordLock)
    raise

proc biIoTestingRead(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2:
    raise newException(GeneError, "AsyncReader:read expects max_bytes")
  let scope = if call == nil: nil else: call[].dispatchScope
  let record = ioTestingRecord(args[0], call, "read")
  let amount = requireInt64("AsyncReader:read max_bytes", args[1])
  if amount < 1 or amount > DefaultIoResourceBytes:
    raiseIoTestingError(scope, "IoError", "read", record.lifecycle.ioResourceId(),
      "read max_bytes must be within 1..1048576")
  let admission = ioTestingAdmission(record, iodRead, int(amount), scope, "read")
  let operation = nativeNewIoOperation(scope)
  record.readTicket = admission.ticket
  record.readTask = operation.task
  record.readLease = operation.cleanupLease
  operation.task

proc biIoTestingWrite(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2 or args[1].kind != vkBytes:
    raise newException(GeneError, "AsyncWriter:write expects Bytes")
  let scope = if call == nil: nil else: call[].dispatchScope
  let record = ioTestingRecord(args[0], call, "write")
  let payload = args[1].bytesVal
  let admission = ioTestingAdmission(record, iodWrite, payload.len, scope, "write")
  if admission.immediate:
    return newCompletedTask(newInt(0))
  let operation = nativeNewIoOperation(scope)
  record.writeTicket = admission.ticket
  record.writePayload = payload
  record.writeTask = operation.task
  record.writeLease = operation.cleanupLease
  operation.task

proc biIoTestingFlush(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError, "AsyncWriter:flush expects a receiver")
  let scope = if call == nil: nil else: call[].dispatchScope
  let record = ioTestingRecord(args[0], call, "flush")
  let admission = ioTestingAdmission(record, iodFlush, 0, scope, "flush")
  let operation = nativeNewIoOperation(scope)
  record.writeTicket = admission.ticket
  record.writeTask = operation.task
  record.writeLease = operation.cleanupLease
  operation.task

proc biIoTestingClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError, "IoResource:close expects a receiver")
  let scope = if call == nil: nil else: call[].dispatchScope
  let record = ioTestingRecord(args[0], call, "close")
  if record.lifecycle.ioSnapshot().phase != iopOpen:
    return NIL
  let retireReady = record.lifecycle.requestIoClose()
  record.closeLease = nativeNewIoCleanupLease(scope)
  if record.readTask.kind == vkTask:
    discard nativeTaskCancel(record.readTask, scope)
  if record.writeTask.kind == vkTask:
    discard nativeTaskCancel(record.writeTask, scope)
  if retireReady:
    ioTestingRetire(record, scope)
  NIL

proc biIoTestingWaitClosed(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError, "IoResource:wait_closed expects a receiver")
  let scope = if call == nil: nil else: call[].dispatchScope
  let record = ioTestingRecord(args[0], call, "wait_closed")
  if record.lifecycle.ioSnapshot().phase == iopClosed:
    if record.closeFailure.len == 0:
      return newCompletedTask(NIL)
    let error = ioTestingErrorValue(scope, "IoError", "close",
      record.lifecycle.ioResourceId(), record.closeFailure)
    return newFailedTask(record.closeFailure, error, hasValue = true)
  result = newExternalTask()
  scope.registerIoTask(result)
  record.waiters.add result

proc biIoTestingCompleteRead(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2 or args[1].kind notin {vkNil, vkBytes}:
    raise newException(GeneError, "io/testing/complete_read expects Bytes or nil")
  let scope = if call == nil: nil else: call[].dispatchScope
  let record = ioTestingRecord(args[0], call, "complete_read")
  if record.readTask.kind != vkTask:
    raise newException(GeneError, "there is no pending read")
  if args[1].kind == vkBytes and
      (args[1].bytesVal.len == 0 or args[1].bytesVal.len > record.readTicket.reservedBytes):
    raise newException(GeneError, "read completion exceeds its admitted bounds")
  let finished = record.lifecycle.finishIoOperation(record.readTicket)
  if not finished.accepted:
    raise newException(GeneError, "stale read completion")
  discard nativeTaskComplete(record.readTask, args[1], scope)
  discard nativeRetireIoCleanupLease(record.readLease, scope)
  record.readTask = NIL
  record.readLease = NIL
  record.readTicket = IoTicket()
  if finished.retireReady:
    ioTestingRetire(record, scope)
  NIL

proc biIoTestingCompleteWrite(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2 or args[1].kind != vkInt:
    raise newException(GeneError, "io/testing/complete_write expects an Int")
  let scope = if call == nil: nil else: call[].dispatchScope
  let record = ioTestingRecord(args[0], call, "complete_write")
  if record.writeTask.kind != vkTask:
    raise newException(GeneError, "there is no pending write or flush")
  let count = requireInt64("io/testing/complete_write count", args[1])
  if count < 0 or count > record.writeTicket.reservedBytes or
      (record.writeTicket.direction == iodFlush and count != 0):
    raise newException(GeneError, "write completion exceeds its admitted bounds")
  let finished = record.lifecycle.finishIoOperation(record.writeTicket)
  if not finished.accepted:
    raise newException(GeneError, "stale write completion")
  if record.writeTicket.direction == iodFlush:
    discard nativeTaskComplete(record.writeTask, NIL, scope)
  else:
    if count > 0:
      record.written.add record.writePayload[0 ..< int(count)]
      discard nativeTaskComplete(record.writeTask, newInt(count), scope)
    else:
      let error = ioTestingErrorValue(scope, "IoError", "write",
        record.lifecycle.ioResourceId(), "writer made no progress")
      discard nativeTaskFail(record.writeTask, "writer made no progress", error,
                             hasValue = true, scope = scope)
  discard nativeRetireIoCleanupLease(record.writeLease, scope)
  record.writeTask = NIL
  record.writeLease = NIL
  record.writeTicket = IoTicket()
  record.writePayload.setLen(0)
  if finished.retireReady:
    ioTestingRetire(record, scope)
  NIL

proc biIoTestingWritten(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError, "io/testing/written expects a resource")
  let record = ioTestingRecord(args[0], call, "written")
  newBytes(record.written)

proc biIoTestingFailClose(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 2 or args[1].kind != vkString:
    raise newException(GeneError, "io/testing/fail_close expects a Str")
  let record = ioTestingRecord(args[0], call, "fail_close")
  if record.lifecycle.ioSnapshot().phase == iopClosed:
    raise newException(GeneError, "close result is already retained")
  record.closeFailure = args[1].strVal
  NIL

proc biIoTestingState(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if args.len != 1:
    raise newException(GeneError, "io/testing/state expects a resource")
  let record = ioTestingRecord(args[0], call, "state")
  let state = record.lifecycle.ioSnapshot()
  var props = initPropTable()
  props["phase"] = newStr($state.phase)
  props["read_busy"] = newBool(state.readBusy)
  props["write_busy"] = newBool(state.writeBusy)
  props["retained_bytes"] = newInt(state.retainedBytes)
  props["active_operations"] = newInt(state.activeOperations)
  props["close_lease"] = newBool(state.closeLease)
  props["resource_id"] = newIntFromDecimal($record.lifecycle.ioResourceId())
  newMap(props, immutable = true)
