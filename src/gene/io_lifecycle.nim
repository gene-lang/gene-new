## Root-lane I/O resource admission and physical-retirement state.
##
## A user Task may settle as cancelled before its native request does. The
## ticket remains reserved until finishIoOperation, so the copied payload and
## handle stay pinned. The caller marshals completion to the root lane and
## settles Tasks; this module never creates Gene values or touches a scheduler.

import std/locks

type
  IoPhase* = enum
    iopOpen, iopClosing, iopClosed

  IoDirection* = enum
    iodRead, iodWrite, iodFlush

  IoAdmissionFailure* = enum
    iaNone, iaInvalid, iaClosed, iaBusy, iaBackpressure

  IoTicket* = object
    resourceId*: uint64
    sequence*: uint64
    direction*: IoDirection
    reservedBytes*: int

  IoAdmission* = object
    accepted*: bool
    immediate*: bool   ## empty write; complete a fresh Task with 0
    failure*: IoAdmissionFailure
    ticket*: IoTicket

  IoFinish* = object
    accepted*: bool    ## false for stale/duplicate completion
    retireReady*: bool ## close was requested and no operation remains

  IoSnapshot* = object
    phase*: IoPhase
    readBusy*: bool
    writeBusy*: bool
    retainedBytes*: int
    activeOperations*: int
    closeLease*: bool
    closeError*: string

  IoBudget* = ref object
    lock: Lock
    maxBytes: int
    retainedBytes: int
    peakRetainedBytes: int
    cleanupLeases: int

  IoLifecycle* = ref object
    lock: Lock
    budget: IoBudget
    resourceId: uint64
    sequence: uint64
    phase: IoPhase
    readTicket: IoTicket
    writeTicket: IoTicket
    readBusy: bool
    writeBusy: bool
    retainedBytes: int
    maxBytes: int
    closeLease: bool
    closeError: string

const
  DefaultIoResourceBytes* = 1_048_576
  DefaultIoApplicationBytes* = 67_108_864

proc newIoBudget*(maxBytes = DefaultIoApplicationBytes): IoBudget =
  if maxBytes < 0:
    raise newException(ValueError, "I/O budget must be nonnegative")
  new(result)
  initLock(result.lock)
  result.maxBytes = maxBytes

proc newIoLifecycle*(budget: IoBudget, resourceId: uint64,
                     maxBytes = DefaultIoResourceBytes): IoLifecycle =
  if budget == nil or resourceId == 0 or maxBytes < 0 or
      maxBytes > DefaultIoResourceBytes:
    raise newException(ValueError, "invalid I/O lifecycle configuration")
  new(result)
  initLock(result.lock)
  result.budget = budget
  result.resourceId = resourceId
  result.maxBytes = maxBytes
  result.phase = iopOpen

proc ioBudgetSnapshot*(budget: IoBudget): tuple[retainedBytes, cleanupLeases: int] =
  acquire(budget.lock)
  try:
    result = (budget.retainedBytes, budget.cleanupLeases)
  finally:
    release(budget.lock)

proc ioBudgetPeak*(budget: IoBudget): int =
  acquire(budget.lock)
  try:
    result = budget.peakRetainedBytes
  finally:
    release(budget.lock)

proc reserveIoBudgetBytes*(budget: IoBudget, amount: int): bool =
  ## Reserve native payload for adapters with multiple concurrent requests
  ## rather than a single read/write slot per resource.
  if budget == nil or amount < 0:
    raise newException(ValueError, "invalid I/O budget reservation")
  acquire(budget.lock)
  try:
    if amount > budget.maxBytes - budget.retainedBytes:
      return false
    budget.retainedBytes += amount
    budget.peakRetainedBytes = max(budget.peakRetainedBytes,
                                    budget.retainedBytes)
    true
  finally:
    release(budget.lock)

proc releaseIoBudgetBytes*(budget: IoBudget, amount: int) =
  if budget == nil or amount < 0:
    raise newException(ValueError, "invalid I/O budget release")
  acquire(budget.lock)
  try:
    if amount > budget.retainedBytes:
      raise newException(ValueError, "I/O budget release exceeds reservation")
    budget.retainedBytes -= amount
  finally:
    release(budget.lock)

proc ioSnapshot*(resource: IoLifecycle): IoSnapshot =
  acquire(resource.lock)
  try:
    result = IoSnapshot(phase: resource.phase,
      readBusy: resource.readBusy, writeBusy: resource.writeBusy,
      retainedBytes: resource.retainedBytes,
      activeOperations: int(resource.readBusy) + int(resource.writeBusy),
      closeLease: resource.closeLease, closeError: resource.closeError)
  finally:
    release(resource.lock)

proc ioResourceId*(resource: IoLifecycle): uint64 =
  resource.resourceId

proc admitIoOperation*(resource: IoLifecycle, direction: IoDirection,
                       reserveBytes: int): IoAdmission =
  if reserveBytes < 0 or
      (direction == iodRead and
        (reserveBytes == 0 or reserveBytes > DefaultIoResourceBytes)) or
      (direction == iodFlush and reserveBytes != 0):
    return IoAdmission(failure: iaInvalid)
  if direction == iodWrite and reserveBytes > DefaultIoResourceBytes:
    return IoAdmission(failure: iaBackpressure)
  acquire(resource.lock)
  try:
    if resource.phase != iopOpen:
      return IoAdmission(failure: iaClosed)
    if (direction == iodRead and resource.readBusy) or
        (direction in {iodWrite, iodFlush} and resource.writeBusy):
      return IoAdmission(failure: iaBusy)
    if direction == iodWrite and reserveBytes == 0:
      return IoAdmission(accepted: true, immediate: true)
    acquire(resource.budget.lock)
    try:
      if reserveBytes > resource.maxBytes - resource.retainedBytes or
          reserveBytes > resource.budget.maxBytes - resource.budget.retainedBytes:
        return IoAdmission(failure: iaBackpressure)
      inc resource.sequence
      if resource.sequence == 0:
        raise newException(OverflowDefect, "I/O operation identity exhausted")
      let ticket = IoTicket(resourceId: resource.resourceId,
        sequence: resource.sequence, direction: direction,
        reservedBytes: reserveBytes)
      if direction == iodRead:
        resource.readBusy = true
        resource.readTicket = ticket
      else:
        resource.writeBusy = true
        resource.writeTicket = ticket
      resource.retainedBytes += reserveBytes
      resource.budget.retainedBytes += reserveBytes
      if resource.budget.retainedBytes > resource.budget.peakRetainedBytes:
        resource.budget.peakRetainedBytes = resource.budget.retainedBytes
      inc resource.budget.cleanupLeases
      return IoAdmission(accepted: true, ticket: ticket)
    finally:
      release(resource.budget.lock)
  finally:
    release(resource.lock)

proc requestIoClose*(resource: IoLifecycle): bool =
  ## Return true when no operation is in flight and physical close can start.
  ## Closing an already-closing/closed resource is idempotent.
  acquire(resource.lock)
  try:
    if resource.phase != iopOpen:
      return false
    resource.phase = iopClosing
    resource.closeLease = true
    acquire(resource.budget.lock)
    try:
      inc resource.budget.cleanupLeases
    finally:
      release(resource.budget.lock)
    result = not resource.readBusy and not resource.writeBusy
  finally:
    release(resource.lock)

proc finishIoOperation*(resource: IoLifecycle, ticket: IoTicket): IoFinish =
  acquire(resource.lock)
  try:
    if ticket.resourceId != resource.resourceId or ticket.sequence == 0:
      return
    let active =
      if ticket.direction == iodRead:
        resource.readBusy and resource.readTicket.sequence == ticket.sequence and
          resource.readTicket.reservedBytes == ticket.reservedBytes
      else:
        resource.writeBusy and resource.writeTicket.sequence == ticket.sequence and
          resource.writeTicket.direction == ticket.direction and
          resource.writeTicket.reservedBytes == ticket.reservedBytes
    if not active:
      return
    if ticket.direction == iodRead:
      resource.readBusy = false
      resource.readTicket = IoTicket()
    else:
      resource.writeBusy = false
      resource.writeTicket = IoTicket()
    resource.retainedBytes -= ticket.reservedBytes
    acquire(resource.budget.lock)
    try:
      resource.budget.retainedBytes -= ticket.reservedBytes
      dec resource.budget.cleanupLeases
    finally:
      release(resource.budget.lock)
    result.accepted = true
    result.retireReady = resource.phase == iopClosing and
      not resource.readBusy and not resource.writeBusy
  finally:
    release(resource.lock)

proc retireIoClose*(resource: IoLifecycle, error = ""): bool =
  ## Physical retirement, including an uninterruptible worker operation,
  ## happened before this call. A failure is sticky for every wait_closed Task.
  acquire(resource.lock)
  try:
    if resource.phase != iopClosing or resource.readBusy or
        resource.writeBusy or not resource.closeLease:
      return false
    resource.phase = iopClosed
    resource.closeLease = false
    resource.closeError = error
    acquire(resource.budget.lock)
    try:
      dec resource.budget.cleanupLeases
    finally:
      release(resource.budget.lock)
    true
  finally:
    release(resource.lock)
