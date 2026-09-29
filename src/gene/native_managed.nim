## Mediated Gene references for the single C extension ABI. The internal
## direct Nim native helpers still serve in-repo callers. No raw Value or
## Scope leaves this module except through irreversible legacy export.

import std/[dynlib, locks, sysatomics, tables, unicode]
import ./[native_api, types, vm]
when defined(geneAtomicGenerationRetirementProbe):
  import ./retirement_native_gate

type
  ManagedEntry = ref object
    scopes: seq[Scope] # strong known Scope/code provenance until physical release
    source: ManagedEntry # foreign slots refer to root-owned provenance
    value: Value

  ManagedAttachment = object
    id: uint64
    lane: int
    ticket: GeneThreadAttachment

  ForeignRootState = enum
    frFree, frLive, frPending, frDraining

  ForeignRootSlot = ref object
    id: uint64
    entry: ManagedEntry # allocated on the root lane before foreign access
    borrows: int
    state: ForeignRootState

  GeneManagedRegistration = ref object of RootObj
    domain: GeneManagedDomain
    id: uint64
    callback: GeneNativeCallbackProc
    userContext: pointer
    retire: GeneContextRetireProc
    library: Value
    environmentRoot: GeneManagedRoot
    inFlight: int
    closeRequested, retiring, retired: bool
    waiters: seq[Value]

  GeneManagedIngressOwner = ref object of RootObj
    domain: GeneManagedDomain
    handler: GeneManagedRoot
    environment: GeneManagedEnvironment
    library: GeneManagedRoot
    activeTask: GeneManagedRoot
    borrowedLibrary, released: bool

  ManagedModuleWaiter = object
    task, lease: Value
    scope: Scope

  GeneManagedPackageModule = ref object
    id: uint64
    application: Application
    ownerLane: int
    domain: GeneManagedDomain
    environment: GeneManagedEnvironment
    libraryRoot, moduleRoot: GeneManagedRoot
    library, lease, cleanupLease: Value
    closeTasks: seq[GeneManagedRoot]
    waiters: seq[ManagedModuleWaiter]
    closeRequested, rootsReleased, closed: bool
    handleGone: bool
    terminalStatus: GeneStatus
    terminalMessage: string

  ManagedLoadFrame = object
    library: Value
    environment: uint64
    registrations: seq[uint64]

  ManagedCProducer = ref object
    task: GeneManagedTask
    environment: GeneManagedEnvironment
    library: Value
    releaseNode: ManagedProducerRelease
    copyKind: uint32
    copyScalar: int64
    copyReal: float64
    copyData: pointer
    copyLength: int
    copyNext: ManagedCProducer

  ManagedProducerRelease = ref object
    environment: GeneManagedEnvironment
    library: Value
    next: ManagedProducerRelease

  GeneManagedDomain* = ref object
    application: RuntimeContext
    rootLane: int
    rootScope: Scope
    lock: Lock
    nextId: uint64
    roots: Table[uint64, ManagedEntry]
    foreignSlots: seq[ForeignRootSlot]
    foreignIndex: Table[uint64, int]
    foreignLive, foreignPending: int
    foreignWakeHeld: bool
    borrows: int
    nextAttachmentId: uint64
    attachmentCount: int
    attachments: array[256, ManagedAttachment]
    producers: int
    producerEntries: Table[uint64, ManagedEntry]
    nextProducerId: uint64
    cProducers: Table[uint64, ManagedCProducer]
    pendingProducerReleases: ManagedProducerRelease
    copyHead, copyTail: ManagedCProducer
    copyCount, copyBytes: int
    copyReservations, copyReservedBytes: int
    nextRegistrationId: uint64
    liveRegistrations: int
    registrations: Table[uint64, GeneManagedRegistration]
    loadFrames: seq[ManagedLoadFrame]
    activeCallbacks: seq[GeneManagedRegistration]
    closed: bool
    apiTable: GeneApi

  GeneManagedRoot* = ref object
    domain: GeneManagedDomain
    id: uint64

  GeneManagedEnvironment* = ref object
    root: GeneManagedRoot

  GeneNativeBorrow* = ref object
    domain: GeneManagedDomain
    entry: ManagedEntry
    ownerLane: int
    foreignSlot: int
    active: bool

  GeneManagedTask* = ref object
    domain: GeneManagedDomain
    root: GeneManagedRoot
    entry: ManagedEntry # producer's physical owner, independent of user root
    lock: Lock
    settled: bool

  GeneManagedAck* = object
    status*: GeneStatus
    accepted*: bool
    message*: string

  GeneManagedReceive* = object
    status*: GeneStatus
    hasValue*: bool
    value*: GeneManagedRoot
    message*: string

  GeneManagedActorStatus* = object
    closed*: bool
    mailbox*: int
    processing*: bool
    idle*: bool

  GeneManagedResult* = object
    status*: GeneStatus
    message*: string
    value*: GeneManagedRoot
    error*: GeneManagedRoot

var managedPackageModules = initTable[uint64, GeneManagedPackageModule]()
var managedPackageModuleLock: Lock
initLock(managedPackageModuleLock)

const
  GeneCopiedNil = 0'u32
  GeneCopiedBool = 1'u32
  GeneCopiedI64 = 2'u32
  GeneCopiedText = 3'u32
  GeneCopiedBytes = 4'u32
  GeneCopiedF64 = 5'u32
  GeneCopiedQueueCount = 256
  GeneCopiedQueueBytes = 64 * 1024 * 1024
  GeneForeignRootLimit = 65536

when defined(geneNativeCopyAllocationProbe):
  var failNextNativeCopyAllocation: bool
  proc geneFailNextNativeCopyAllocation*() =
    failNextNativeCopyAllocation = true

proc copiedMalloc(size: csize_t): pointer
    {.importc: "malloc", header: "<stdlib.h>".}
proc copiedFree(value: pointer) {.importc: "free", header: "<stdlib.h>".}

proc ownedCopy[T](value: T): T {.inline.} = value

proc provenanceRoot(entry: ManagedEntry): ManagedEntry =
  result = entry
  while result != nil and result.source != nil:
    result = result.source

proc knownScopes(entry: ManagedEntry): seq[Scope] =
  entry.provenanceRoot().scopes

proc requireDomain(domain: GeneManagedDomain) =
  if domain == nil:
    raise newException(GeneError, "managed native domain is nil")

proc requireOpen(domain: GeneManagedDomain) =
  domain.requireDomain()
  acquire(domain.lock)
  try:
    if domain.closed:
      raise newException(GeneError, "managed native domain is closed")
  finally:
    release(domain.lock)

proc requireBorrow(borrow: GeneNativeBorrow): ManagedEntry =
  if borrow == nil or borrow.ownerLane != currentEventLane():
    raise newException(GeneError, "managed native borrow belongs to another lane")
  if not borrow.active or borrow.entry == nil:
    raise newException(GeneError, "managed native borrow has ended")
  borrow.entry

proc configureApiTable(domain: GeneManagedDomain)

proc geneNewManagedDomain*(scope: Scope): GeneManagedDomain =
  vm.requireNativeRootLane(scope)
  new(result)
  result.application = scope.application
  result.rootLane = currentEventLane()
  result.rootScope = scope
  result.roots = initTable[uint64, ManagedEntry]()
  result.foreignIndex = initTable[uint64, int]()
  result.producerEntries = initTable[uint64, ManagedEntry]()
  result.cProducers = initTable[uint64, ManagedCProducer]()
  result.registrations = initTable[uint64, GeneManagedRegistration]()
  initLock(result.lock)
  result.configureApiTable()

proc addRoot(domain: GeneManagedDomain, value: Value,
             scopes: seq[Scope] = @[],
             allowClosed = false,
             source: ManagedEntry = nil): GeneManagedRoot =
  domain.requireDomain()
  if currentEventLane() != domain.rootLane:
    if source == nil:
      raise newException(GeneError,
        "foreign managed root requires rooted provenance")
    var id: uint64
    acquire(domain.lock)
    try:
      if domain.closed and not allowClosed:
        raise newException(GeneError, "managed native domain is closed")
      if domain.nextId == high(uint64):
        raise newException(GeneError, "managed native root IDs are exhausted")
      var slotIndex = -1
      for i, slot in domain.foreignSlots:
        if slot.state == frFree:
          slotIndex = i
          break
      if slotIndex < 0:
        raise newException(GeneError,
          "foreign managed root capacity exhausted; reserve on the root lane")
      inc domain.nextId
      id = domain.nextId
      let slot = domain.foreignSlots[slotIndex]
      slot.entry.value = value
      slot.entry.source = source.provenanceRoot()
      slot.id = id
      slot.state = frLive
      domain.foreignIndex[id] = slotIndex
      inc domain.foreignLive
    finally:
      release(domain.lock)
    return GeneManagedRoot(domain: domain, id: id)
  acquire(domain.lock)
  try:
    if domain.closed and not allowClosed:
      raise newException(GeneError, "managed native domain is closed")
    if domain.nextId == high(uint64):
      raise newException(GeneError, "managed native root IDs are exhausted")
    inc domain.nextId
    let id = domain.nextId
    let rootScopes = if source == nil: scopes else: source.knownScopes()
    domain.roots[id] = ManagedEntry(value: value, scopes: rootScopes)
    result = GeneManagedRoot(domain: domain, id: id)
  finally:
    release(domain.lock)

proc requireRootLane(domain: GeneManagedDomain) =
  domain.requireDomain()
  if currentEventLane() != domain.rootLane:
    raise newException(GeneError, "managed native operation requires the runtime root lane")

proc geneManagedReserveForeignRoots*(domain: GeneManagedDomain,
                                     capacity: int) =
  ## Allocate every slot, entry, and index bucket on the root lane. Attached
  ## lanes may fill existing slots but never grow a Nim container.
  domain.requireRootLane()
  domain.requireOpen()
  if capacity < 1 or capacity > GeneForeignRootLimit:
    raise newException(GeneError, "foreign managed root capacity is invalid")
  let current = domain.foreignSlots.len
  if capacity <= current: return
  var wakeHeld = false
  var installed = false
  var oldSlots: seq[ForeignRootSlot]
  var oldIndex: Table[uint64, int]
  try:
    if current == 0:
      geneHoldNativeWake()
      wakeHeld = true
    var slots = newSeq[ForeignRootSlot](capacity)
    for i in current ..< capacity:
      slots[i] = ForeignRootSlot(entry: ManagedEntry(value: NIL))
    var index = initTable[uint64, int](capacity * 4)
    acquire(domain.lock)
    try:
      if domain.closed:
        raise newException(GeneError, "managed native domain is closed")
      for i in 0 ..< current:
        slots[i] = domain.foreignSlots[i]
      for id, slotIndex in domain.foreignIndex:
        index[id] = slotIndex
      oldSlots = move(domain.foreignSlots)
      oldIndex = move(domain.foreignIndex)
      domain.foreignSlots = move(slots)
      domain.foreignIndex = move(index)
      if wakeHeld: domain.foreignWakeHeld = true
      installed = true
    finally:
      release(domain.lock)
  finally:
    if wakeHeld and not installed: geneReleaseNativeWake()
  reset(oldSlots)
  reset(oldIndex)

proc foreignSlotIndex(domain: GeneManagedDomain, id: uint64): int =
  if domain.foreignIndex.hasKey(id): domain.foreignIndex[id]
  else: -1

proc liveRootValue(domain: GeneManagedDomain,
                   root: GeneManagedRoot): Value =
  domain.requireDomain()
  if root == nil or root.domain != domain:
    raise newException(GeneError, "managed root belongs to another runtime")
  acquire(domain.lock)
  try:
    var entry = domain.roots.getOrDefault(root.id)
    if entry == nil:
      let slotIndex = domain.foreignSlotIndex(root.id)
      if slotIndex >= 0:
        entry = domain.foreignSlots[slotIndex].entry
    if entry == nil:
      raise newException(GeneError, "managed native root has been released")
    result = entry.value
  finally:
    release(domain.lock)

proc liveRootEntry(domain: GeneManagedDomain,
                   root: GeneManagedRoot): ManagedEntry =
  domain.requireDomain()
  if root == nil or root.domain != domain:
    raise newException(GeneError, "managed root belongs to another runtime")
  acquire(domain.lock)
  try:
    let found = domain.roots.getOrDefault(root.id)
    if found != nil:
      result = ownedCopy(found)
    else:
      let slotIndex = domain.foreignSlotIndex(root.id)
      if slotIndex < 0:
        raise newException(GeneError, "managed native root has been released")
      let entry = domain.foreignSlots[slotIndex].entry
      # A snapshot owns its fields independently of a reusable foreign slot.
      result = ManagedEntry(value: entry.value,
                            source: entry.provenanceRoot())
  finally:
    release(domain.lock)

proc environmentScope(domain: GeneManagedDomain,
                      environment: GeneManagedEnvironment,
                      rootOnly = true): Scope =
  if rootOnly: domain.requireRootLane()
  else: domain.requireDomain()
  if environment == nil or environment.root == nil:
    raise newException(GeneError, "managed native environment is nil")
  let value = domain.liveRootValue(environment.root)
  if value.kind != vkNamespace:
    raise newException(GeneError, "managed native environment is unavailable")
  result = value.nsScope
  if rootOnly: vm.requireNativeRootLane(result)

template withManagedProgress(body: untyped) =
  when defined(geneAtomicGenerationRetirementProbe):
    if not enterRetirementNativeAccess(true):
      raise newException(GeneError, "managed operation cannot enter generation analysis")
    try: body
    finally: leaveRetirementNativeAccess()
  else:
    body

proc geneManagedRootFromVm*(domain: GeneManagedDomain, scope: Scope,
                            value: Value): GeneManagedRoot =
  ## VM/root-lane handoff only. An arbitrary already-foreign raw Value cannot
  ## be imported retroactively into a tracked lifetime.
  domain.requireOpen()
  vm.requireNativeRootLane(scope)
  if scope.application != domain.application:
    raise newException(GeneError, "managed native root belongs to another runtime")
  vm.requireNativeRootable(value)
  when defined(geneAtomicGenerationRetirementProbe):
    if not enterRetirementNativeAccess(true):
      raise newException(GeneError, "managed root cannot enter generation analysis")
    try:
      let scopes = vm.publishManagedRootForRetirement(value)
      result = domain.addRoot(value, scopes)
    finally:
      leaveRetirementNativeAccess()
  else:
    let scopes = vm.publishManagedRootForRetirement(value)
    result = domain.addRoot(value, scopes)

proc drainForeignRoots(domain: GeneManagedDomain) =
  domain.requireRootLane()
  acquire(domain.lock)
  let pending = domain.foreignPending
  release(domain.lock)
  if pending == 0: return
  for i in 0 ..< domain.foreignSlots.len:
    var entry: ManagedEntry
    acquire(domain.lock)
    try:
      let slot = domain.foreignSlots[i]
      if slot.state == frPending and slot.borrows == 0:
        slot.state = frDraining
        entry = ownedCopy(slot.entry)
    finally:
      release(domain.lock)
    if entry == nil: continue
    try:
      entry.value = NIL
      reset(entry.scopes)
      reset(entry.source)
    finally:
      acquire(domain.lock)
      try:
        let slot = domain.foreignSlots[i]
        slot.id = 0
        slot.state = frFree
        dec domain.foreignPending
      finally:
        release(domain.lock)

proc geneManagedRelease*(root: GeneManagedRoot) =
  if root == nil or root.domain == nil: return
  when defined(geneAtomicGenerationRetirementProbe):
    if not enterRetirementNativeAccess(true):
      raise newException(GeneError, "managed release cannot enter generation analysis")
  try:
    let domain = root.domain
    var retired: ManagedEntry
    var foreign = false
    acquire(domain.lock)
    try:
      let found = domain.roots.getOrDefault(root.id)
      if found != nil:
        # Keep the final owner until after the registry lock is released.
        retired = ownedCopy(found)
        domain.roots.del(root.id)
      else:
        let slotIndex = domain.foreignSlotIndex(root.id)
        if slotIndex >= 0:
          let slot = domain.foreignSlots[slotIndex]
          slot.state = frPending
          domain.foreignIndex.del(root.id)
          dec domain.foreignLive
          inc domain.foreignPending
          foreign = true
    finally:
      release(domain.lock)
    reset(retired)
    if foreign:
      if currentEventLane() == domain.rootLane:
        domain.drainForeignRoots()
      else:
        geneSignalNativeWake()
  finally:
    when defined(geneAtomicGenerationRetirementProbe):
      leaveRetirementNativeAccess()

proc beginBorrow(root: GeneManagedRoot): GeneNativeBorrow =
  if root == nil or root.domain == nil:
    raise newException(GeneError, "managed native root is nil")
  let domain = root.domain
  when not defined(gcAtomicArc):
    if currentEventLane() != domain.rootLane:
      raise newException(GeneError, "foreign managed borrow requires AtomicArc")
  if currentEventLane() != domain.rootLane and not geneThreadAttached():
    raise newException(GeneError, "native lane must attach before a managed borrow")
  when defined(geneAtomicGenerationRetirementProbe):
    # The user callback may wait for VM/root-lane progress even if it only uses
    # copied getters. Never make a collecting root wait for that callback.
    if not enterRetirementNativeAccess(true):
      raise newException(GeneError, "managed borrow cannot enter generation analysis")
  var admitted = false
  try:
    acquire(domain.lock)
    try:
      if domain.closed:
        raise newException(GeneError, "managed native domain is closed")
      var entry = domain.roots.getOrDefault(root.id)
      var slotIndex = -1
      if entry == nil:
        slotIndex = domain.foreignSlotIndex(root.id)
        if slotIndex >= 0:
          let slot = domain.foreignSlots[slotIndex]
          entry = slot.entry
          inc slot.borrows
      if entry == nil:
        raise newException(GeneError, "managed native root has been released")
      result = GeneNativeBorrow(domain: domain, entry: entry,
                                ownerLane: currentEventLane(),
                                foreignSlot: slotIndex, active: true)
      inc domain.borrows
      admitted = true
    finally:
      release(domain.lock)
  finally:
    when defined(geneAtomicGenerationRetirementProbe):
      if not admitted: leaveRetirementNativeAccess()

proc endBorrow(borrow: GeneNativeBorrow) =
  let entry = borrow.requireBorrow()
  let domain = borrow.domain
  try:
    var retired: ManagedEntry
    acquire(domain.lock)
    try:
      borrow.active = false
      dec domain.borrows
      if borrow.foreignSlot >= 0:
        let slot = domain.foreignSlots[borrow.foreignSlot]
        dec slot.borrows
        if slot.state == frPending and slot.borrows == 0:
          geneSignalNativeWake()
      retired = ownedCopy(entry)
      reset(borrow.entry) # `retired` prevents last-owner cleanup under the lock
    finally:
      release(domain.lock)
    reset(retired)
  finally:
    when defined(geneAtomicGenerationRetirementProbe):
      leaveRetirementNativeAccess() # full callback is owner-dependent

proc geneWithNativeBorrow*[T](root: GeneManagedRoot,
    body: proc(borrow: GeneNativeBorrow): T): T =
  let borrow = beginBorrow(root)
  try: result = body(borrow)
  finally: endBorrow(borrow)

proc geneWithNativeBorrow*(root: GeneManagedRoot,
    body: proc(borrow: GeneNativeBorrow)) =
  let borrow = beginBorrow(root)
  try: body(borrow)
  finally: endBorrow(borrow)

proc geneManagedKind*(borrow: GeneNativeBorrow): ValueKind =
  borrow.requireBorrow().value.kind

proc geneManagedBool*(borrow: GeneNativeBorrow): bool =
  let value = borrow.requireBorrow().value
  if value.kind != vkBool:
    raise newException(GeneError, "managed native value is not a Bool")
  value.boolVal

proc geneManagedInt64*(borrow: GeneNativeBorrow): int64 =
  let value = borrow.requireBorrow().value
  if value.kind != vkInt or not value.intFitsInt64:
    raise newException(GeneError, "managed native Int does not fit in int64")
  value.intVal

proc geneManagedFloat64*(borrow: GeneNativeBorrow): float64 =
  let value = borrow.requireBorrow().value
  if value.kind != vkFloat:
    raise newException(GeneError, "managed native value is not a Float")
  value.floatVal

proc geneManagedText*(borrow: GeneNativeBorrow): string =
  let value = borrow.requireBorrow().value
  if value.kind != vkString:
    raise newException(GeneError, "managed native value is not a Str")
  let source = value.strVal
  result = newStringOfCap(source.len)
  result.add source

proc geneManagedBytes*(borrow: GeneNativeBorrow): seq[byte] =
  let value = borrow.requireBorrow().value
  if value.kind != vkBytes:
    raise newException(GeneError, "managed native value is not Bytes")
  let source = value.bytesVal
  result = newSeq[byte](source.len)
  for i in 0 ..< source.len:
    result[i] = byte(ord(source[i]))

proc geneManagedRetain*(borrow: GeneNativeBorrow): GeneManagedRoot =
  let entry = borrow.requireBorrow()
  result = borrow.domain.addRoot(entry.value, source = entry)

proc requireFrozen(value: Value, kind: ValueKind, label: string) =
  if value.kind != kind or not value.isDeepFrozen:
    raise newException(GeneError, "managed " & label & " requires a deep-frozen " & $kind)

proc geneManagedListLength*(borrow: GeneNativeBorrow): int =
  let value = borrow.requireBorrow().value
  requireFrozen(value, vkList, "length")
  value.listItems.len

proc geneManagedListAt*(borrow: GeneNativeBorrow, index: int): GeneManagedRoot =
  let entry = borrow.requireBorrow()
  let value = entry.value
  requireFrozen(value, vkList, "index")
  if index < 0 or index >= value.listItems.len:
    raise newException(GeneError, "managed List index is out of bounds")
  borrow.domain.addRoot(value.listItems[index], source = entry)

proc geneManagedMapAt*(borrow: GeneNativeBorrow,
                       name: string): GeneManagedRoot =
  let entry = borrow.requireBorrow()
  let value = entry.value
  requireFrozen(value, vkMap, "lookup")
  borrow.domain.addRoot(value.mapEntries.getOrDefault(name, VOID),
                        source = entry)

proc geneManagedNodeHead*(borrow: GeneNativeBorrow): GeneManagedRoot =
  let entry = borrow.requireBorrow()
  let value = entry.value
  requireFrozen(value, vkNode, "head")
  borrow.domain.addRoot(value.head, source = entry)

proc geneManagedNodeProp*(borrow: GeneNativeBorrow,
                          name: string): GeneManagedRoot =
  let entry = borrow.requireBorrow()
  let value = entry.value
  requireFrozen(value, vkNode, "property")
  borrow.domain.addRoot(value.props.getOrDefault(name, VOID), source = entry)

proc geneManagedNodeBodyAt*(borrow: GeneNativeBorrow,
                            index: int): GeneManagedRoot =
  let entry = borrow.requireBorrow()
  let value = entry.value
  requireFrozen(value, vkNode, "body")
  if index < 0 or index >= value.body.len:
    raise newException(GeneError, "managed Node body index is out of bounds")
  borrow.domain.addRoot(value.body[index], source = entry)

proc geneNewManagedEnvironment*(domain: GeneManagedDomain,
                                scope: Scope): GeneManagedEnvironment =
  ## Opaque dispatch environment. The Namespace is never returned as a Value.
  let namespace = newNamespace("native/environment", scope)
  result = GeneManagedEnvironment(
    root: geneManagedRootFromVm(domain, scope, namespace))

proc geneManagedEnvironmentRelease*(environment: GeneManagedEnvironment) =
  if environment != nil:
    geneManagedRelease(environment.root)

proc geneManagedDefine*(environment: GeneManagedEnvironment,
                        name: string, value: GeneManagedRoot): GeneManagedResult =
  if environment == nil or environment.root == nil:
    raise newException(GeneError, "managed native environment is nil")
  let domain = environment.root.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let entry = domain.liveRootEntry(value)
      let stored = entry.value
      var pins = ownedCopy(entry.knownScopes())
      pins.add vm.publishManagedRootForRetirement(stored)
      scope.define(name, stored)
      if pins.len > 0:
        scope.managedBindingPins[name] = pins
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, scope, stored)
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedLookup*(environment: GeneManagedEnvironment,
                       name: string): GeneManagedResult =
  if environment == nil or environment.root == nil:
    raise newException(GeneError, "managed native environment is nil")
  let domain = environment.root.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      result.value = geneManagedRootFromVm(domain, scope, scope.lookup(name))
      result.status = gsOk
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

type GeneManagedWrapperField* = object
  name*: string
  typeExpr*: GeneManagedRoot # nil means Any
  optional*: bool

proc geneManagedDefineWrapperType*(environment: GeneManagedEnvironment,
                                   name: string,
                                   fields: openArray[GeneManagedWrapperField]):
                                   GeneManagedResult =
  if environment == nil or environment.root == nil:
    raise newException(GeneError, "managed native environment is nil")
  let domain = environment.root.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      if name.len == 0:
        raise newException(GeneError, "wrapper type requires a name")
      let scope = domain.environmentScope(environment)
      var schema: seq[TypeField]
      for field in fields:
        if field.name.len == 0:
          raise newException(GeneError, "wrapper field requires a name")
        schema.add TypeField(name: field.name, optional: field.optional,
          typeExpr: (if field.typeExpr == nil: NIL
                     else: domain.liveRootValue(field.typeExpr)))
      let typ = newType(name, NIL, schema, @[], scope, repr = trNativeWrapper)
      scope.define(name, typ)
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, scope, typ)
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedNewWrapper*(wrapperType: GeneManagedRoot,
    properties: openArray[(string, GeneManagedRoot)],
    environment: GeneManagedEnvironment): GeneManagedResult =
  if wrapperType == nil or wrapperType.domain == nil:
    raise newException(GeneError, "managed wrapper Type is nil")
  let domain = wrapperType.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let typ = domain.liveRootValue(wrapperType)
      var props: seq[(string, Value)]
      for entry in properties:
        props.add (entry[0], domain.liveRootValue(entry[1]))
      let instance = vm.newNativeWrapper(typ, props)
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, scope, instance)
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedWrapperField*(instance, wrapperType: GeneManagedRoot,
                              name: string,
                              environment: GeneManagedEnvironment):
                              GeneManagedResult =
  if instance == nil or instance.domain == nil:
    raise newException(GeneError, "managed wrapper is nil")
  let domain = instance.domain
  withManagedProgress:
    domain.requireOpen()
    let scope = domain.environmentScope(environment)
    let observed = geneWrapperField(domain.liveRootValue(instance),
                                    domain.liveRootValue(wrapperType), name)
    result.status = observed.status
    result.message = observed.message
    if observed.status == gsOk:
      result.value = geneManagedRootFromVm(domain, scope, observed.value)
    elif observed.hasErrorValue:
      result.error = geneManagedRootFromVm(domain, scope, observed.errorValue)

proc geneManagedNewCPtr*(environment: GeneManagedEnvironment,
                         address: pointer,
                         targetType: GeneManagedRoot = nil): GeneManagedResult =
  if environment == nil or environment.root == nil:
    raise newException(GeneError, "managed native environment is nil")
  let domain = environment.root.domain
  withManagedProgress:
    domain.requireOpen()
    let scope = domain.environmentScope(environment)
    let typ = if targetType == nil: NIL else: domain.liveRootValue(targetType)
    result.status = gsOk
    result.value = geneManagedRootFromVm(domain, scope, newCPtr(address, typ))

proc geneManagedNewOwnedCPtr*(environment: GeneManagedEnvironment,
    address: pointer, release: CPtrReleaseProc,
    targetType: GeneManagedRoot = nil): GeneManagedResult =
  if environment == nil or environment.root == nil or release == nil:
    raise newException(GeneError, "managed owned pointer requires environment and release")
  let domain = environment.root.domain
  withManagedProgress:
    domain.requireOpen()
    let scope = domain.environmentScope(environment)
    let typ = if targetType == nil: NIL else: domain.liveRootValue(targetType)
    result.status = gsOk
    result.value = geneManagedRootFromVm(domain, scope,
      newCOwnedPtr(address, release, typ))

proc geneManagedWithCPtr*(borrow: GeneNativeBorrow,
                          body: proc(address: pointer)) =
  let value = borrow.requireBorrow().value
  borrow.domain.requireRootLane()
  if value.kind != vkCPtr:
    raise newException(GeneError, "managed pointer borrow requires a CPtr")
  withManagedProgress:
    value.borrowCPtr()
    try: body(value.cPtrAddress)
    finally: value.releaseCPtrBorrow()

proc geneManagedCloseCPtr*(borrow: GeneNativeBorrow): GeneManagedResult =
  let value = borrow.requireBorrow().value
  borrow.domain.requireRootLane()
  withManagedProgress:
    try:
      value.closeCPtr()
      result.status = gsOk
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc requireManagedBuffer(borrow: GeneNativeBorrow): Value =
  result = borrow.requireBorrow().value
  borrow.domain.requireRootLane()
  if result.kind != vkBuffer:
    raise newException(GeneError, "managed buffer operation requires a Buffer")
  when defined(geneAtomicGenerationRetirementProbe):
    if result.valueRawPublishedForRetirement:
      raise newException(GeneError,
        "published Buffer requires a shared mutation policy")

proc geneManagedNewBuffer*(environment: GeneManagedEnvironment,
    elemType: GeneManagedRoot,
    items: openArray[GeneManagedRoot]): GeneManagedResult =
  if environment == nil or environment.root == nil:
    raise newException(GeneError, "managed buffer requires an environment")
  let domain = environment.root.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let typ = if elemType == nil: NIL else: domain.liveRootValue(elemType)
      var values: seq[Value]
      for item in items: values.add domain.liveRootValue(item)
      let buffer = vm.newCheckedBuffer(typ, values, scope)
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, scope, buffer)
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedBufferLength*(borrow: GeneNativeBorrow): int =
  borrow.requireManagedBuffer().bufferLen

proc geneManagedBufferGet*(borrow: GeneNativeBorrow, index: int,
                           environment: GeneManagedEnvironment):
                           GeneManagedResult =
  let buffer = borrow.requireManagedBuffer()
  let domain = borrow.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let item = vm.getCheckedBufferItem(buffer, index)
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, scope, item)
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedBufferSet*(borrow: GeneNativeBorrow, index: int,
                           item: GeneManagedRoot,
                           environment: GeneManagedEnvironment):
                           GeneManagedResult =
  let buffer = borrow.requireManagedBuffer()
  let domain = borrow.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let stored = vm.setCheckedBufferItem(buffer, index,
                                           domain.liveRootValue(item), scope)
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, scope, stored)
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedNewChannel*(environment: GeneManagedEnvironment,
    capacity: int, itemType: GeneManagedRoot = nil): GeneManagedResult =
  if environment == nil or environment.root == nil:
    raise newException(GeneError, "managed Channel requires an environment")
  let domain = environment.root.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      if capacity <= 0:
        raise newException(GeneError, "managed Channel capacity must be positive")
      var channel = newChannel(capacity)
      if itemType != nil:
        channel = newCheckedChannel(channel, domain.liveRootValue(itemType), scope)
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, scope, channel)
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedChannelTrySend*(channel, item: GeneManagedRoot,
    environment: GeneManagedEnvironment): GeneManagedAck =
  if channel == nil or channel.domain == nil:
    raise newException(GeneError, "managed Channel is nil")
  let domain = channel.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let channelEntry = domain.liveRootEntry(channel)
      let itemEntry = domain.liveRootEntry(item)
      result.accepted = vm.nativeChannelTrySendManaged(channelEntry.value,
        itemEntry.value, itemEntry.knownScopes(), scope)
      result.status = gsOk
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedChannelTryRecv*(channel: GeneManagedRoot,
    environment: GeneManagedEnvironment): GeneManagedReceive =
  if channel == nil or channel.domain == nil:
    raise newException(GeneError, "managed Channel is nil")
  let domain = channel.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let channelEntry = domain.liveRootEntry(channel)
      let received = vm.nativeChannelTryRecvManaged(channelEntry.value, scope)
      result.status = gsOk
      if received.hasValue:
        # Hold weak environments explicitly through root registration. Releasing
        # the queue ticket earlier would leave a weak Scope pointer dangling.
        var pins = ownedCopy(received.pins)
        result.value = geneManagedRootFromVm(domain, scope, received.item)
        reset(pins)
        result.hasValue = true
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedNewActor*(environment: GeneManagedEnvironment,
    capacity: int, state, handler: GeneManagedRoot,
    messageType: GeneManagedRoot = nil): GeneManagedResult =
  if environment == nil or environment.root == nil:
    raise newException(GeneError, "managed Actor requires an environment")
  let domain = environment.root.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      if capacity <= 0:
        raise newException(GeneError, "managed Actor capacity must be positive")
      let stateEntry = domain.liveRootEntry(state)
      let handlerEntry = domain.liveRootEntry(handler)
      let contractEntry = if messageType == nil: nil
                          else: domain.liveRootEntry(messageType)
      let contract = if contractEntry == nil: newSym("Any")
                     else: contractEntry.value
      let actor = newActorRef(capacity, stateEntry.value, handlerEntry.value,
                              contract,
                              messageTypeExplicit = contractEntry != nil)
      var statePins = ownedCopy(stateEntry.knownScopes())
      statePins.add vm.publishManagedRootForRetirement(stateEntry.value)
      var handlerPins = ownedCopy(handlerEntry.knownScopes())
      handlerPins.add vm.publishManagedRootForRetirement(handlerEntry.value)
      var contractPins: seq[Scope]
      if contractEntry != nil:
        contractPins = ownedCopy(contractEntry.knownScopes())
        contractPins.add vm.publishManagedRootForRetirement(contract)
      actor.configureManagedActor(statePins, handlerPins, contractPins)
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, scope, actor)
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedActorTrySend*(actor, message: GeneManagedRoot,
    environment: GeneManagedEnvironment): GeneManagedAck =
  if actor == nil or actor.domain == nil:
    raise newException(GeneError, "managed Actor is nil")
  let domain = actor.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let actorEntry = domain.liveRootEntry(actor)
      let messageEntry = domain.liveRootEntry(message)
      result.accepted = vm.nativeActorTrySendManaged(actorEntry.value,
        messageEntry.value, messageEntry.knownScopes(), scope)
      result.status = gsOk
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedActorState*(actor: GeneManagedRoot,
    environment: GeneManagedEnvironment): GeneManagedResult =
  if actor == nil or actor.domain == nil:
    raise newException(GeneError, "managed Actor is nil")
  let domain = actor.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let actorValue = domain.liveRootValue(actor)
      if actorValue.kind != vkActorRef:
        raise newException(GeneError, "managed Actor state requires an ActorRef")
      let snapshot = actorValue.actorManagedStateSnapshot()
      result.value = geneManagedRootFromVm(domain, scope, snapshot.state)
      result.status = gsOk
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedActorStatus*(actor: GeneManagedRoot,
    environment: GeneManagedEnvironment): GeneManagedActorStatus =
  if actor == nil or actor.domain == nil:
    raise newException(GeneError, "managed Actor is nil")
  let domain = actor.domain
  withManagedProgress:
    domain.requireOpen()
    discard domain.environmentScope(environment)
    let value = domain.liveRootValue(actor)
    if value.kind != vkActorRef or not value.actorManaged:
      raise newException(GeneError, "managed status requires a managed Actor")
    let snapshot = value.actorSnapshotFields()
    result.closed = snapshot.closed
    result.mailbox = snapshot.mailbox
    result.processing = snapshot.processing
    result.idle = snapshot.idle

proc geneManagedActorClose*(actor: GeneManagedRoot,
    environment: GeneManagedEnvironment): GeneManagedAck =
  if actor == nil or actor.domain == nil:
    raise newException(GeneError, "managed Actor is nil")
  let domain = actor.domain
  withManagedProgress:
    try:
      domain.requireOpen()
      let scope = domain.environmentScope(environment)
      let value = domain.liveRootValue(actor)
      vm.nativeActorCloseManaged(value, scope)
      result.status = gsOk
      result.accepted = true
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg

proc geneManagedNewTask*(environment: GeneManagedEnvironment): GeneManagedTask =
  if environment == nil or environment.root == nil:
    raise newException(GeneError, "managed Task requires an environment")
  let domain = environment.root.domain
  withManagedProgress:
    domain.requireOpen()
    let scope = domain.environmentScope(environment)
    let root = geneManagedRootFromVm(domain, scope, vm.nativeNewAsyncTask())
    new(result)
    result.domain = domain
    result.root = root
    initLock(result.lock)
    acquire(domain.lock)
    try:
      result.entry = ownedCopy(domain.roots[root.id])
      domain.producerEntries[root.id] = ownedCopy(result.entry)
      inc domain.producers
    finally:
      release(domain.lock)

proc geneManagedTaskRoot*(task: GeneManagedTask): GeneManagedRoot =
  if task == nil or task.root == nil:
    raise newException(GeneError, "managed Task is nil")
  task.root

proc claimProducer(task: GeneManagedTask): ManagedEntry =
  if task == nil or task.domain == nil:
    raise newException(GeneError, "managed Task is nil")
  acquire(task.lock)
  try:
    if task.settled or task.entry == nil:
      raise newException(GeneError, "managed Task producer has retired")
    task.settled = true
    result = ownedCopy(task.entry)
  finally:
    release(task.lock)

proc releaseProducer(task: GeneManagedTask) =
  var retired: ManagedEntry
  acquire(task.domain.lock)
  try:
    retired = ownedCopy(task.domain.producerEntries[task.root.id])
    task.domain.producerEntries.del(task.root.id)
    reset(task.entry)
    dec task.domain.producers
    doAssert task.domain.producerEntries.len == task.domain.producers
  finally:
    release(task.domain.lock)
  reset(retired) # callbacks must not run under the domain lock

proc geneManagedTaskComplete*(task: GeneManagedTask,
                              value: GeneManagedRoot,
                              environment: GeneManagedEnvironment):
                              GeneManagedAck =
  if task == nil or task.domain == nil:
    raise newException(GeneError, "managed Task is nil")
  let domain = task.domain
  withManagedProgress:
    let scope = domain.environmentScope(environment, rootOnly = false)
    let payloadEntry = if value == nil: nil else: domain.liveRootEntry(value)
    let payload = if payloadEntry == nil: NIL else: payloadEntry.value
    let producer = task.claimProducer()
    try:
      if payloadEntry != nil:
        producer.value.retainTaskSourceScopes(payloadEntry.knownScopes())
      result.accepted = vm.nativeTaskComplete(producer.value, payload, scope)
      result.status = gsOk
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
      discard vm.nativeTaskFail(producer.value, e.msg, NIL, false, scope)
    finally:
      task.releaseProducer()

proc geneManagedTaskFail*(task: GeneManagedTask,
                          environment: GeneManagedEnvironment,
                          message: string,
                          error: GeneManagedRoot = nil): GeneManagedAck =
  if task == nil or task.domain == nil:
    raise newException(GeneError, "managed Task is nil")
  let domain = task.domain
  withManagedProgress:
    let scope = domain.environmentScope(environment, rootOnly = false)
    if error != nil and currentEventLane() != domain.rootLane:
      raise newException(GeneError,
        "typed foreign Task failure needs a root-lane adapter")
    let payloadEntry = if error == nil: nil else: domain.liveRootEntry(error)
    let payload = if payloadEntry == nil: NIL else: payloadEntry.value
    let producer = task.claimProducer()
    try:
      if payloadEntry != nil:
        producer.value.retainTaskSourceScopes(payloadEntry.knownScopes())
      result.accepted = vm.nativeTaskFail(producer.value, message, payload,
                                           error != nil, scope)
      result.status = gsOk
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
      discard vm.nativeTaskFail(producer.value, e.msg, NIL, false, scope)
    finally:
      task.releaseProducer()

proc geneManagedTaskCancel*(task: GeneManagedTask,
                            environment: GeneManagedEnvironment): GeneManagedAck =
  if task == nil or task.domain == nil:
    raise newException(GeneError, "managed Task is nil")
  withManagedProgress:
    let scope = task.domain.environmentScope(environment, rootOnly = false)
    var entry: ManagedEntry
    acquire(task.lock)
    try:
      if task.settled or task.entry == nil:
        raise newException(GeneError, "managed Task producer has retired")
      entry = ownedCopy(task.entry)
    finally:
      release(task.lock)
    try:
      result.accepted = vm.nativeTaskCancel(entry.value, scope)
      result.status = gsOk
    except GeneError as e:
      result.status = gsError
      result.message = e.msg

proc geneManagedTaskRetire*(task: GeneManagedTask,
                            environment: GeneManagedEnvironment): GeneManagedAck =
  ## Physical cancellation cleanup may finish after the user Task went terminal.
  if task == nil or task.domain == nil:
    raise newException(GeneError, "managed Task is nil")
  withManagedProgress:
    let scope = task.domain.environmentScope(environment, rootOnly = false)
    let producer = task.claimProducer()
    try:
      result.accepted = vm.nativeTaskCancel(producer.value, scope)
      result.status = gsOk
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    finally:
      task.releaseProducer()

proc geneManagedTaskOutcome*(borrow: GeneNativeBorrow,
                             environment: GeneManagedEnvironment):
                             GeneManagedResult =
  let task = borrow.requireBorrow().value
  if task.kind != vkTask:
    raise newException(GeneError, "managed outcome requires a Task")
  let domain = borrow.domain
  domain.requireRootLane()
  withManagedProgress:
    let scope = domain.environmentScope(environment)
    if not task.taskDone:
      raise newException(GeneError, "managed Task has not settled")
    if task.taskCancelled:
      result.status = gsCancelled
    elif task.taskHasPanic:
      result.status = gsPanic
      result.message = task.taskPanicMsg
      if task.taskHasPanicValue:
        result.error = geneManagedRootFromVm(domain, scope, task.taskPanicValue)
    elif task.taskHasError:
      result.status = gsError
      result.message = task.taskErrorMsg
      if task.taskHasErrorValue:
        result.error = geneManagedRootFromVm(domain, scope, task.taskErrorValue)
    else:
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, scope, task.taskResult)

proc geneManagedCall*(borrow: GeneNativeBorrow,
                      arguments: openArray[GeneManagedRoot],
                      environment: GeneManagedEnvironment): GeneManagedResult =
  let callee = borrow.requireBorrow().value
  let domain = borrow.domain
  if environment == nil or environment.root == nil or
      environment.root.domain != domain:
    raise newException(GeneError, "managed call requires its runtime environment")
  if currentEventLane() != domain.rootLane:
    raise newException(GeneError, "managed Gene calls require the runtime root lane")
  when defined(geneAtomicGenerationRetirementProbe):
    doAssert enterRetirementNativeAccess(true) # VM execution needs root progress
  try:
    var values: seq[Value]
    var dispatchScope: Scope
    acquire(domain.lock)
    try:
      if domain.closed:
        raise newException(GeneError, "managed native domain is closed")
      let envEntry = domain.roots.getOrDefault(environment.root.id)
      if envEntry == nil or envEntry.value.kind != vkNamespace:
        raise newException(GeneError, "managed environment has been released")
      dispatchScope = envEntry.value.nsScope
      for argument in arguments:
        if argument == nil or argument.domain != domain:
          raise newException(GeneError, "managed argument belongs to another runtime")
        let entry = domain.roots.getOrDefault(argument.id)
        if entry == nil:
          raise newException(GeneError, "managed argument has been released")
        values.add entry.value
    finally:
      release(domain.lock)
    vm.requireNativeRootLane(dispatchScope)
    try:
      let returned = vm.call(callee, values, @[], @[], dispatchScope, NIL)
      result.status = gsOk
      result.value = geneManagedRootFromVm(domain, dispatchScope, returned)
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
      if e.hasErrVal:
        result.error = geneManagedRootFromVm(domain, dispatchScope, e.errVal)
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg
      if e.hasErrVal:
        result.error = geneManagedRootFromVm(domain, dispatchScope, e.errVal)
    except GeneCancel as e:
      result.status = gsCancelled
      result.message = e.msg
  finally:
    when defined(geneAtomicGenerationRetirementProbe):
      leaveRetirementNativeAccess()

proc geneExportManagedRoot*(borrow: GeneNativeBorrow): GeneRoot =
  let entry = borrow.requireBorrow()
  if currentEventLane() != borrow.domain.rootLane:
    raise newException(GeneError, "legacy export requires the runtime root lane")
  borrow.domain.requireOpen()
  pinLegacyManagedScopes(entry.knownScopes())
  when defined(geneAtomicGenerationRetirementProbe):
    vm.publishNativeRootForRetirement(entry.value)
  result = geneRoot(entry.value) # irreversible raw publication

const
  GeneApiIdentityFeature* = 1'u64
  GeneApiScalarFeature* = 2'u64
  GeneApiCallDefineFeature* = 4'u64
  GeneApiFrozenFeature* = 8'u64
  GeneApiAttachedFeature* = 16'u64
  GeneApiCallbackFeature* = 64'u64
  GeneApiTaskProducerFeature* = 128'u64
  GeneApiTaskCopyFeature* = 256'u64
  GeneApiFloatFeature* = 512'u64
  GeneApiForeignRootsFeature* = 1024'u64
  GeneApiMaxCopyBytes* = 64 * 1024 * 1024

proc apiDiagnostic(output: ptr GeneOutBytes, message: string) =
  if output == nil: return
  output.required = csize_t(message.len)
  if output.data == nil or output.capacity == 0: return
  let count = if output.capacity > csize_t(message.len): message.len
              else: int(output.capacity)
  if count > 0:
    copyMem(output.data, unsafeAddr message[0], count)

proc apiDomain(context: pointer, rootOnly = true,
              allowClosed = false): GeneManagedDomain =
  if context == nil:
    raise newException(GeneError, "native ABI runtime context is nil")
  result = cast[GeneManagedDomain](context)
  if rootOnly:
    result.requireRootLane()
  else:
    result.requireDomain()
    when not defined(gcAtomicArc):
      if currentEventLane() != result.rootLane:
        raise newException(GeneError,
          "foreign native ABI access requires AtomicArc")
    if currentEventLane() != result.rootLane and not geneThreadAttached():
      raise newException(GeneError,
        "foreign native ABI lane must attach first")
  if not allowClosed:
    result.requireOpen()

proc apiAttachThread(context: pointer, output: ptr uint64,
                    diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  var ticket: GeneThreadAttachment
  var admitted = false
  try:
    if output == nil or context == nil:
      raise newException(GeneError, "native ABI attachment input is nil")
    when not (defined(gcAtomicArc) and compileOption("threads")):
      raise newException(GeneError,
        "native ABI foreign attachment requires threaded AtomicArc")
    let domain = cast[GeneManagedDomain](context)
    domain.requireDomain()
    acquire(domain.lock)
    try:
      if domain.closed and domain.cProducers.len == 0:
        raise newException(GeneError, "managed native domain is closed")
    finally:
      release(domain.lock)
    ticket = geneAttachThread()
    acquire(domain.lock)
    try:
      if domain.closed and domain.cProducers.len == 0:
        raise newException(GeneError, "managed native domain is closed")
      if domain.nextAttachmentId == high(uint64):
        raise newException(GeneError, "native ABI attachment IDs are exhausted")
      var slot = -1
      for i in 0 ..< domain.attachments.len:
        if domain.attachments[i].id == 0:
          slot = i
          break
      if slot < 0:
        raise newException(GeneError, "native ABI attachment limit reached")
      inc domain.nextAttachmentId
      domain.attachments[slot] = ManagedAttachment(
        id: domain.nextAttachmentId, lane: currentEventLane(), ticket: ticket)
      inc domain.attachmentCount
      GC_ref(domain) # token physically retains its runtime until detach
      admitted = true
      output[] = domain.nextAttachmentId
    finally:
      release(domain.lock)
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  finally:
    if not admitted and ticket != nil:
      geneDetachThread(ticket)

proc apiDetachThread(context: pointer, token: uint64,
                    diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  try:
    if context == nil or token == 0:
      raise newException(GeneError, "native ABI detach input is invalid")
    let domain = cast[GeneManagedDomain](context)
    var ticket: GeneThreadAttachment
    acquire(domain.lock)
    try:
      for i in 0 ..< domain.attachments.len:
        if domain.attachments[i].id == token:
          if domain.attachments[i].lane != currentEventLane() or
              not geneThreadAttached():
            raise newException(GeneError,
              "native ABI attachment belongs to another lane")
          ticket = move(domain.attachments[i].ticket)
          domain.attachments[i] = ManagedAttachment()
          dec domain.attachmentCount
          break
      if ticket == nil:
        raise newException(GeneError, "native ABI attachment is unavailable")
    finally:
      release(domain.lock)
    geneDetachThread(ticket)
    apiDiagnostic(diagnostic, "")
    GC_unref(domain)
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiRetain(context: pointer, id: uint64, output: ptr uint64,
              diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI retain output is nil")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    let copied = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): GeneManagedRoot = geneManagedRetain(b))
    output[] = copied.id
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiRelease(context: pointer, id: uint64,
               diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  try:
    let domain = apiDomain(context, rootOnly = false, allowClosed = true)
    let root = GeneManagedRoot(domain: domain, id: id)
    discard domain.liveRootEntry(root) # stale IDs fail rather than no-op
    geneManagedRelease(root)
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiKind(context: pointer, id: uint64, output: ptr uint32,
            diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 255'u32
  try:
    if output == nil:
      raise newException(GeneError, "native ABI kind output is nil")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    let kind = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b))
    output[] = case kind
      of vkNil: 0'u32
      of vkBool: 1'u32
      of vkInt: 2'u32
      of vkString: 3'u32
      of vkBytes: 4'u32
      of vkList: 5'u32
      of vkMap: 6'u32
      of vkNode: 7'u32
      of vkFunction, vkNativeFn: 8'u32
      of vkTask: 9'u32
      of vkChannel: 10'u32
      of vkActorRef: 11'u32
      else: 255'u32
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiNewI64(context: pointer, value: int64, output: ptr uint64,
              diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI Int output is nil")
    let domain = apiDomain(context)
    output[] = geneManagedRootFromVm(domain, domain.rootScope,
                                      newInt(value)).id
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiNewF64(context: pointer, value: float64, output: ptr uint64,
               diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI Float output is nil")
    let domain = apiDomain(context)
    output[] = geneManagedRootFromVm(domain, domain.rootScope,
                                      newFloat(value)).id
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiCopiedInput(data: ptr uint8, length: csize_t): string =
  if length > csize_t(GeneApiMaxCopyBytes):
    raise newException(GeneError, "native ABI byte input exceeds limit")
  if length > 0 and data == nil:
    raise newException(GeneError, "native ABI byte input is nil")
  result = newString(int(length))
  if length > 0:
    copyMem(addr result[0], data, int(length))

proc apiCopyText(context: pointer, id: uint64, output: ptr GeneOutBytes,
                diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  try:
    if output == nil:
      raise newException(GeneError, "native ABI text output is nil")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    let copied = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): string = geneManagedText(b))
    if validateUtf8(copied) != -1:
      raise newException(GeneError, "managed native Str is not valid UTF-8")
    output.required = csize_t(copied.len)
    if output.data != nil and output.capacity > 0 and copied.len > 0:
      let count = if output.capacity > csize_t(copied.len): copied.len
                  else: int(output.capacity)
      copyMem(output.data, unsafeAddr copied[0], count)
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiCopyBytes(context: pointer, id: uint64, output: ptr GeneOutBytes,
                 diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  try:
    if output == nil:
      raise newException(GeneError, "native ABI Bytes output is nil")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    let copied = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): seq[byte] = geneManagedBytes(b))
    output.required = csize_t(copied.len)
    if output.data != nil and output.capacity > 0 and copied.len > 0:
      let count = if output.capacity > csize_t(copied.len): copied.len
                  else: int(output.capacity)
      copyMem(output.data, unsafeAddr copied[0], count)
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiCopyBool(context: pointer, id: uint64, output: ptr uint8,
                diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI Bool output is nil")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    output[] = if geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): bool = geneManagedBool(b)): 1'u8 else: 0'u8
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiCopyI64(context: pointer, id: uint64, output: ptr int64,
               diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI Int output is nil")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    output[] = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): int64 = geneManagedInt64(b))
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiCopyF64(context: pointer, id: uint64, output: ptr float64,
                diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI Float output is nil")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    output[] = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): float64 = geneManagedFloat64(b))
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiNewBool(context: pointer, value: uint8, output: ptr uint64,
               diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil or value > 1:
      raise newException(GeneError, "native ABI Bool input or output is invalid")
    let domain = apiDomain(context)
    output[] = geneManagedRootFromVm(domain, domain.rootScope,
                                      newBool(value == 1)).id
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiNewText(context: pointer, data: ptr uint8, length: csize_t,
               output: ptr uint64,
               diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI text output is nil")
    let domain = apiDomain(context)
    let copied = apiCopiedInput(data, length)
    if validateUtf8(copied) != -1:
      raise newException(GeneError, "native ABI text is not valid UTF-8")
    output[] = geneManagedRootFromVm(domain, domain.rootScope,
                                      newStr(copied)).id
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiNewBytes(context: pointer, data: ptr uint8, length: csize_t,
                output: ptr uint64,
                diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI Bytes output is nil")
    let domain = apiDomain(context)
    output[] = geneManagedRootFromVm(domain, domain.rootScope,
                                      newBytes(apiCopiedInput(data, length))).id
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiFrozenKey(borrow: GeneNativeBorrow, selector: uint32,
                 index: csize_t): string =
  let value = borrow.requireBorrow().value
  case selector
  of 1'u32:
    requireFrozen(value, vkMap, "entry key")
    if index >= csize_t(value.mapEntries.len):
      raise newException(GeneError, "native ABI Map entry is out of bounds")
    result = value.mapEntries.propKeyAtCopy(int(index))
  of 3'u32:
    requireFrozen(value, vkNode, "property key")
    if index >= csize_t(value.props.len):
      raise newException(GeneError, "native ABI Node property is out of bounds")
    result = value.props.propKeyAtCopy(int(index))
  else:
    raise newException(GeneError,
      "native ABI key selector requires Map entry or Node property")

proc apiLength(context: pointer, id: uint64, selector: uint32,
              output: ptr csize_t,
              diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI length output is nil")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    let count = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): int =
        let value = b.requireBorrow().value
        case selector
        of 0'u32: geneManagedListLength(b)
        of 1'u32:
          requireFrozen(value, vkMap, "length")
          value.mapEntries.len
        of 2'u32:
          requireFrozen(value, vkNode, "body length")
          value.body.len
        of 3'u32:
          requireFrozen(value, vkNode, "property length")
          value.props.len
        of 4'u32:
          requireFrozen(value, vkNode, "head length")
          1
        else:
          raise newException(GeneError, "native ABI length selector is invalid"))
    output[] = csize_t(count)
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiCopyKey(context: pointer, id: uint64, selector: uint32,
               index: csize_t, output: ptr GeneOutBytes,
               diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  try:
    if output == nil:
      raise newException(GeneError, "native ABI key output is nil")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    let key = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): string = apiFrozenKey(b, selector, index))
    if validateUtf8(key) != -1:
      raise newException(GeneError, "native ABI key is not valid UTF-8")
    output.required = csize_t(key.len)
    if output.data != nil and output.capacity > 0 and key.len > 0:
      let count = if output.capacity > csize_t(key.len): key.len
                  else: int(output.capacity)
      copyMem(output.data, unsafeAddr key[0], count)
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiTraverse(context: pointer, id: uint64, selector: uint32,
                index: csize_t, output: ptr uint64,
                diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI traversal output is nil")
    if index > csize_t(high(int)):
      raise newException(GeneError, "native ABI traversal index is too large")
    let domain = apiDomain(context, rootOnly = false)
    let root = GeneManagedRoot(domain: domain, id: id)
    let child = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): GeneManagedRoot =
        case selector
        of 0'u32: geneManagedListAt(b, int(index))
        of 1'u32: geneManagedMapAt(b, apiFrozenKey(b, selector, index))
        of 2'u32: geneManagedNodeBodyAt(b, int(index))
        of 3'u32: geneManagedNodeProp(b, apiFrozenKey(b, selector, index))
        of 4'u32:
          if index != 0:
            raise newException(GeneError, "native ABI Node head index is out of bounds")
          geneManagedNodeHead(b)
        else:
          raise newException(GeneError, "native ABI traversal selector is invalid"))
    output[] = child.id
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiCopiedName(data: ptr uint8, length: csize_t): string =
  result = apiCopiedInput(data, length)
  if result.len == 0 or validateUtf8(result) != -1:
    raise newException(GeneError, "native ABI name must be nonempty UTF-8")

proc apiResult(managed: GeneManagedResult, output, error: ptr uint64,
              diagnostic: ptr GeneOutBytes): uint32 =
  if output != nil and managed.value != nil:
    output[] = managed.value.id
  if error != nil and managed.error != nil:
    error[] = managed.error.id
  apiDiagnostic(diagnostic, managed.message)
  uint32(ord(managed.status))

proc apiLookup(context: pointer, environment: uint64,
              name: ptr uint8, nameLength: csize_t,
              output: ptr uint64,
              diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI lookup output is nil")
    let domain = apiDomain(context)
    let env = GeneManagedEnvironment(
      root: GeneManagedRoot(domain: domain, id: environment))
    result = apiResult(geneManagedLookup(env,
      apiCopiedName(name, nameLength)), output, nil, diagnostic)
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiDefine(context: pointer, environment: uint64,
              name: ptr uint8, nameLength: csize_t, value: uint64,
              output: ptr uint64,
              diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native ABI define output is nil")
    let domain = apiDomain(context)
    let env = GeneManagedEnvironment(
      root: GeneManagedRoot(domain: domain, id: environment))
    let input = GeneManagedRoot(domain: domain, id: value)
    result = apiResult(geneManagedDefine(env,
      apiCopiedName(name, nameLength), input), output, nil, diagnostic)
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiCall(context: pointer, callable: uint64,
            arguments: ptr uint64, argumentCount: csize_t,
            environment: uint64, output, error: ptr uint64,
            diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  if error != nil: error[] = 0
  try:
    if output == nil or error == nil:
      raise newException(GeneError, "native ABI call outputs are nil")
    if argumentCount > 4096 or
        (argumentCount > 0 and arguments == nil):
      raise newException(GeneError, "native ABI call arguments are invalid")
    let domain = apiDomain(context)
    var roots = newSeq[GeneManagedRoot](int(argumentCount))
    let ids = cast[ptr UncheckedArray[uint64]](arguments)
    for i in 0 ..< roots.len:
      roots[i] = GeneManagedRoot(domain: domain, id: ids[i])
    let env = GeneManagedEnvironment(
      root: GeneManagedRoot(domain: domain, id: environment))
    let callee = GeneManagedRoot(domain: domain, id: callable)
    let called = geneWithNativeBorrow(callee,
      proc(b: GeneNativeBorrow): GeneManagedResult =
        geneManagedCall(b, roots, env))
    result = apiResult(called, output, error, diagnostic)
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc finishRegistration(registration: GeneManagedRegistration) =
  ## Transfer every physical owner out of the registry lock before calling C.
  let domain = registration.domain
  var retire: GeneContextRetireProc
  var userContext: pointer
  var library = NIL
  var environmentRoot: GeneManagedRoot
  var waiters: seq[Value]
  acquire(domain.lock)
  try:
    if registration.retiring or registration.retired or
        not registration.closeRequested or
        registration.inFlight != 0:
      return
    registration.retiring = true
    retire = registration.retire
    userContext = registration.userContext
    library = move(registration.library)
    environmentRoot = move(registration.environmentRoot)
    registration.callback = nil
    registration.retire = nil
    registration.userContext = nil
  finally:
    release(domain.lock)
  try:
    if retire != nil:
      retire(userContext)
  finally:
    if library.kind == vkFfiLibrary:
      releaseFfiLibraryBorrow(library)
    if environmentRoot != nil:
      geneManagedRelease(environmentRoot)
    acquire(domain.lock)
    try:
      registration.retired = true
      registration.retiring = false
      waiters = move(registration.waiters)
    finally:
      release(domain.lock)
    for waiter in waiters:
      discard vm.nativeTaskComplete(waiter, NIL, domain.rootScope)
    acquire(domain.lock)
    try:
      dec domain.liveRegistrations
    finally:
      release(domain.lock)

proc requestCloseRegistration(registration: GeneManagedRegistration): uint32 =
  let domain = registration.domain
  acquire(domain.lock)
  try:
    registration.closeRequested = true
    result = if registration.retired or
        (registration.inFlight == 0 and not registration.retiring): 0'u32
        else: 4'u32
  finally:
    release(domain.lock)
  if result == 0:
    finishRegistration(registration)

proc invokeRegisteredCallback(context: RootRef, arguments: openArray[Value],
                              call: ptr NativeCall): Value {.nimcall.} =
  let registration = GeneManagedRegistration(context)
  let domain = registration.domain
  withManagedProgress:
    var callback: GeneNativeCallbackProc
    var userContext: pointer
    acquire(domain.lock)
    try:
      if domain.closed or registration.closeRequested or registration.retired:
        raise newException(GeneError, "native callback is closed")
      inc registration.inFlight
      callback = registration.callback
      userContext = registration.userContext
    finally:
      release(domain.lock)
    var temporary: seq[GeneManagedRoot]
    var temporaryIds: seq[uint64]
    var outputId, errorId: uint64
    try:
      if arguments.len > 4096 or
          (call != nil and call.namedNames.len > 4096):
        raise newException(GeneError, "native callback arguments exceed limit")
      let env = GeneManagedEnvironment(root: registration.environmentRoot)
      let scope = domain.environmentScope(env)
      vm.requireNativeRootLane(scope)
      var argumentIds = newSeq[uint64](arguments.len)
      for i, argument in arguments:
        let root = geneManagedRootFromVm(domain, scope, argument)
        temporary.add root
        temporaryIds.add root.id
        argumentIds[i] = root.id
      var named: seq[GeneNamedArg]
      if call != nil:
        named.setLen(call.namedNames.len)
        for i in 0 ..< named.len:
          let root = geneManagedRootFromVm(domain, scope, call.namedValues[i])
          temporary.add root
          temporaryIds.add root.id
          let name = call.namedNames[i]
          named[i] = GeneNamedArg(
            name: if name.len == 0: nil
                  else: cast[ptr uint8](unsafeAddr call.namedNames[i][0]),
            nameLen: csize_t(name.len), value: root.id)
      let environmentRoot = domain.addRoot(
        domain.liveRootEntry(registration.environmentRoot).value,
        domain.liveRootEntry(registration.environmentRoot).knownScopes())
      temporary.add environmentRoot
      temporaryIds.add environmentRoot.id
      var bytes: array[512, uint8]
      var diagnostic = GeneOutBytes(data: addr bytes[0],
                                    capacity: csize_t(bytes.len))
      domain.activeCallbacks.add registration
      var code: uint32
      try:
        code = callback(addr domain.apiTable, userContext,
          (if argumentIds.len == 0: nil else: addr argumentIds[0]),
          csize_t(argumentIds.len),
          (if named.len == 0: nil else: addr named[0]), csize_t(named.len),
          environmentRoot.id, addr outputId, addr errorId, addr diagnostic)
      finally:
        domain.activeCallbacks.setLen(domain.activeCallbacks.len - 1)
      let count = if diagnostic.required > csize_t(bytes.len): bytes.len
                  else: int(diagnostic.required)
      var message = "native callback returned " & $code
      if count > 0:
        message.add ": "
        for i in 0 ..< count: message.add char(bytes[i])
      if (outputId != 0 and outputId in temporaryIds) or
          (errorId != 0 and errorId in temporaryIds):
        raise newException(GeneError,
          "native callback returned a borrowed argument handle")
      if outputId != 0 and outputId == errorId:
        raise newException(GeneError,
          "native callback returned the same handle twice")
      if code != 0 and outputId != 0:
        raise newException(GeneError,
          "native callback returned a value handle on failure")
      let output = if outputId == 0: NIL else:
        domain.liveRootValue(GeneManagedRoot(domain: domain, id: outputId))
      let errorValue = if errorId == 0: NIL else:
        domain.liveRootValue(GeneManagedRoot(domain: domain, id: errorId))
      case code
      of 0'u32:
        if errorId != 0:
          raise newException(GeneError,
            "native callback returned an error handle on success")
        result = output
      of 1'u32:
        let failure = newException(GeneError, message)
        if errorId != 0:
          failure.errVal = errorValue
          failure.hasErrVal = true
        raise failure
      of 2'u32:
        let failure = newException(GenePanic, message)
        if errorId != 0:
          failure.errVal = errorValue
          failure.hasErrVal = true
        raise failure
      of 3'u32:
        raise newException(GeneCancel, message)
      else:
        raise newException(GeneError,
          "native callback returned unsupported status " & $code)
    finally:
      try:
        if outputId != 0 and outputId notin temporaryIds:
          geneManagedRelease(GeneManagedRoot(domain: domain, id: outputId))
        if errorId != 0 and errorId != outputId and errorId notin temporaryIds:
          geneManagedRelease(GeneManagedRoot(domain: domain, id: errorId))
        for root in temporary:
          geneManagedRelease(root)
      finally:
        var shouldFinish = false
        acquire(domain.lock)
        try:
          dec registration.inFlight
          shouldFinish = registration.closeRequested and
                         registration.inFlight == 0
        finally:
          release(domain.lock)
        if shouldFinish:
          finishRegistration(registration)

proc apiRegisterCallback(context: pointer, environment: uint64,
    name: ptr uint8, nameLength: csize_t,
    callback: GeneNativeCallbackProc, userContext: pointer,
    retire: GeneContextRetireProc, output, token: ptr uint64,
    diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  if token != nil: token[] = 0
  var library = NIL
  var environmentRoot, callableRoot: GeneManagedRoot
  var borrowed = false
  try:
    let domain = apiDomain(context)
    if output == nil or token == nil or callback == nil or retire == nil:
      raise newException(GeneError,
        "native callback registration arguments are invalid")
    let copiedName = apiCopiedName(name, nameLength)
    if copiedName.len > 128:
      raise newException(GeneError, "native callback name is too long")
    if domain.loadFrames.len == 0 or
        domain.loadFrames[^1].environment != environment:
      raise newException(GeneError,
        "native callback registration requires an active module initializer")
    library = domain.loadFrames[^1].library
    let env = GeneManagedEnvironment(
      root: GeneManagedRoot(domain: domain, id: environment))
    let scope = domain.environmentScope(env)
    let source = domain.liveRootEntry(env.root)
    library.borrowFfiLibrary()
    borrowed = true
    environmentRoot = domain.addRoot(source.value, source.knownScopes())
    var registration = GeneManagedRegistration(
      domain: domain, callback: callback, userContext: userContext,
      retire: retire, library: library, environmentRoot: environmentRoot)
    acquire(domain.lock)
    try:
      if domain.nextRegistrationId == high(uint64):
        raise newException(GeneError, "native registration IDs are exhausted")
      inc domain.nextRegistrationId
      registration.id = domain.nextRegistrationId
    finally:
      release(domain.lock)
    let callable = newNativeContextFn(copiedName, RootRef(registration),
                                      invokeRegisteredCallback)
    callableRoot = geneManagedRootFromVm(domain, scope, callable)
    let defined = geneManagedDefine(env, copiedName, callableRoot)
    if defined.status != gsOk:
      raise newException(GeneError, defined.message)
    geneManagedRelease(defined.value)
    acquire(domain.lock)
    try:
      domain.registrations[registration.id] = registration
      inc domain.liveRegistrations
      domain.loadFrames[^1].registrations.add registration.id
    finally:
      release(domain.lock)
    borrowed = false # registration owns the library borrow now
    environmentRoot = nil
    output[] = callableRoot.id
    token[] = registration.id
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  finally:
    if result != 0:
      if callableRoot != nil: geneManagedRelease(callableRoot)
      if environmentRoot != nil: geneManagedRelease(environmentRoot)
      if borrowed: library.releaseFfiLibraryBorrow()

proc apiRequestClose(context: pointer, token: uint64,
                     diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  try:
    let domain = apiDomain(context, allowClosed = true)
    var registration: GeneManagedRegistration
    acquire(domain.lock)
    try:
      registration = domain.registrations.getOrDefault(token)
    finally:
      release(domain.lock)
    if registration == nil:
      raise newException(GeneError, "native registration token is unavailable")
    result = requestCloseRegistration(registration)
    apiDiagnostic(diagnostic, "")
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiWaitClosed(context: pointer, token: uint64, output: ptr uint64,
                   diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native close waiter output is nil")
    let domain = apiDomain(context, allowClosed = true)
    var registration: GeneManagedRegistration
    acquire(domain.lock)
    try:
      registration = domain.registrations.getOrDefault(token)
      if registration == nil or not registration.closeRequested:
        raise newException(GeneError,
          "native registration must request close before waiting")
    finally:
      release(domain.lock)
    let task = vm.nativeNewAsyncTask()
    let taskRoot = domain.addRoot(task, allowClosed = true)
    acquire(domain.lock)
    try:
      domain.registrations.del(token) # wait consumes the registration token
      if not registration.retired:
        registration.waiters.add task
    finally:
      release(domain.lock)
    if registration.retired:
      discard vm.nativeTaskComplete(task, NIL, domain.rootScope)
    output[] = taskRoot.id
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc drainCProducerReleases(domain: GeneManagedDomain) =
  domain.requireRootLane()
  var pending: ManagedProducerRelease
  acquire(domain.lock)
  try:
    pending = move(domain.pendingProducerReleases)
  finally:
    release(domain.lock)
  while pending != nil:
    let release = move(pending)
    pending = move(release.next)
    try:
      geneManagedEnvironmentRelease(release.environment)
    finally:
      try:
        release.library.releaseFfiLibraryBorrow()
      finally:
        try:
          geneReleaseNativeWake()
        finally:
          GC_unref(domain)

proc finishCProducer(domain: GeneManagedDomain,
                     producer: ManagedCProducer) =
  acquire(domain.lock)
  try:
    producer.releaseNode.next = move(domain.pendingProducerReleases)
    domain.pendingProducerReleases = producer.releaseNode
    geneSignalNativeWake() # foreign physical completion wakes an awaiting root
  finally:
    release(domain.lock)
  if currentEventLane() == domain.rootLane:
    drainCProducerReleases(domain)

proc takeCProducer(domain: GeneManagedDomain,
                   token: uint64): ManagedCProducer =
  acquire(domain.lock)
  try:
    result = domain.cProducers.getOrDefault(token)
    if result == nil:
      raise newException(GeneError, "native Task producer token is unavailable")
    domain.cProducers.del(token)
  finally:
    release(domain.lock)

proc apiNewTask(context: pointer, environment: uint64,
                output, producerToken: ptr uint64,
                diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  if producerToken != nil: producerToken[] = 0
  var task: GeneManagedTask
  var ownedEnvironment: GeneManagedEnvironment
  var library = NIL
  var borrowed = false
  var wakeHeld = false
  var admitted = false
  try:
    let domain = apiDomain(context)
    if output == nil or producerToken == nil:
      raise newException(GeneError, "native Task outputs are nil")
    if domain.activeCallbacks.len == 0:
      raise newException(GeneError,
        "native Task creation requires an active registered callback")
    if domain.loadFrames.len != 0:
      raise newException(GeneError,
        "native Task creation requires completed module initialization")
    let registration = domain.activeCallbacks[^1]
    let supplied = GeneManagedEnvironment(
      root: GeneManagedRoot(domain: domain, id: environment))
    let scope = domain.environmentScope(supplied)
    if scope != domain.environmentScope(
        GeneManagedEnvironment(root: registration.environmentRoot)):
      raise newException(GeneError,
        "native Task environment belongs to another callback")
    let source = domain.liveRootEntry(supplied.root)
    ownedEnvironment = GeneManagedEnvironment(
      root: domain.addRoot(source.value, source.knownScopes()))
    library = registration.library
    library.borrowFfiLibrary()
    borrowed = true
    task = geneManagedNewTask(ownedEnvironment)
    geneHoldNativeWake()
    wakeHeld = true
    acquire(domain.lock)
    try:
      if domain.nextProducerId == high(uint64):
        raise newException(GeneError, "native Task producer IDs are exhausted")
      inc domain.nextProducerId
      let token = domain.nextProducerId
      let releaseNode = ManagedProducerRelease(
        environment: ownedEnvironment, library: library)
      domain.cProducers[token] = ManagedCProducer(
        task: task, environment: ownedEnvironment, library: library,
        releaseNode: releaseNode)
      GC_ref(domain) # C token keeps the runtime alive until physical retirement
      producerToken[] = token
      output[] = task.root.id
      admitted = true
    finally:
      release(domain.lock)
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  finally:
    if not admitted:
      if task != nil:
        discard geneManagedTaskRetire(task, ownedEnvironment)
        geneManagedRelease(task.root)
      if borrowed: library.releaseFfiLibraryBorrow()
      if wakeHeld: geneReleaseNativeWake()
      if ownedEnvironment != nil:
        geneManagedEnvironmentRelease(ownedEnvironment)

proc apiTaskComplete(context: pointer, token, value: uint64,
                     accepted: ptr uint8,
                     diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if accepted != nil: accepted[] = 0
  var producer: ManagedCProducer
  var domain: GeneManagedDomain
  try:
    domain = apiDomain(context, rootOnly = false, allowClosed = true)
    if accepted == nil:
      raise newException(GeneError, "native Task acceptance output is nil")
    if value != 0:
      withManagedProgress:
        let payload = domain.liveRootEntry(
          GeneManagedRoot(domain: domain, id: value))
        if currentEventLane() != domain.rootLane and
            not payload.value.isDeepFrozen:
          raise newException(GeneError,
            "foreign Task payload must be deep-frozen")
    producer = takeCProducer(domain, token)
    let payload = if value == 0: nil
                  else: GeneManagedRoot(domain: domain, id: value)
    var ack: GeneManagedAck
    ack = geneManagedTaskComplete(producer.task, payload,
                                  producer.environment)
    if ack.status != gsOk:
      raise newException(GeneError, ack.message)
    accepted[] = uint8(ord(ack.accepted))
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  finally:
    if producer != nil:
      if not producer.task.settled:
        discard geneManagedTaskRetire(producer.task, producer.environment)
      finishCProducer(domain, producer)

proc apiTaskFail(context: pointer, token: uint64,
                 message: ptr uint8, messageLength: csize_t, error: uint64,
                 accepted: ptr uint8,
                 diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if accepted != nil: accepted[] = 0
  var producer: ManagedCProducer
  var domain: GeneManagedDomain
  try:
    domain = apiDomain(context, rootOnly = false, allowClosed = true)
    if accepted == nil:
      raise newException(GeneError, "native Task acceptance output is nil")
    let copiedMessage = apiCopiedInput(message, messageLength)
    if error != 0:
      if currentEventLane() != domain.rootLane:
        raise newException(GeneError,
          "typed foreign Task failure needs a root-lane adapter")
      discard domain.liveRootEntry(GeneManagedRoot(domain: domain, id: error))
    producer = takeCProducer(domain, token)
    let errorRoot = if error == 0: nil
                    else: GeneManagedRoot(domain: domain, id: error)
    let ack = geneManagedTaskFail(producer.task, producer.environment,
                                  copiedMessage, errorRoot)
    if ack.status != gsOk:
      raise newException(GeneError, ack.message)
    accepted[] = uint8(ord(ack.accepted))
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  finally:
    if producer != nil:
      if not producer.task.settled:
        discard geneManagedTaskRetire(producer.task, producer.environment)
      finishCProducer(domain, producer)

proc apiTaskCancel(context: pointer, token: uint64,
                   accepted: ptr uint8,
                   diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if accepted != nil: accepted[] = 0
  try:
    let domain = apiDomain(context, rootOnly = false, allowClosed = true)
    if accepted == nil:
      raise newException(GeneError, "native Task acceptance output is nil")
    var producer: ManagedCProducer
    acquire(domain.lock)
    try:
      producer = domain.cProducers.getOrDefault(token)
    finally:
      release(domain.lock)
    if producer == nil:
      raise newException(GeneError, "native Task producer token is unavailable")
    let ack = geneManagedTaskCancel(producer.task, producer.environment)
    if ack.status != gsOk:
      raise newException(GeneError, ack.message)
    accepted[] = uint8(ord(ack.accepted))
    geneSignalNativeWake() # cancellation does not consume the producer
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc apiTaskRetire(context: pointer, token: uint64,
                   accepted: ptr uint8,
                   diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  if accepted != nil: accepted[] = 0
  var producer: ManagedCProducer
  var domain: GeneManagedDomain
  try:
    domain = apiDomain(context, rootOnly = false, allowClosed = true)
    if accepted == nil:
      raise newException(GeneError, "native Task acceptance output is nil")
    producer = takeCProducer(domain, token)
    let ack = geneManagedTaskRetire(producer.task, producer.environment)
    if ack.status != gsOk:
      raise newException(GeneError, ack.message)
    accepted[] = uint8(ord(ack.accepted))
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  finally:
    if producer != nil:
      finishCProducer(domain, producer)

proc apiTaskSubmitCopy(context: pointer, token: uint64,
                       source: ptr GeneCopiedResult,
                       diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  var copied: pointer
  var domain: GeneManagedDomain
  var reserved = false
  var length = 0
  try:
    domain = apiDomain(context, rootOnly = false, allowClosed = true)
    if source == nil:
      raise newException(GeneError, "native copied Task result is nil")
    let item = source[]
    if item.kind > GeneCopiedF64:
      raise newException(GeneError, "native copied Task kind is invalid")
    if item.kind == GeneCopiedText or item.kind == GeneCopiedBytes:
      if item.scalar != 0 or item.real != 0 or
          item.length > csize_t(GeneApiMaxCopyBytes) or
          (item.length > 0 and item.data == nil):
        raise newException(GeneError, "native copied Task span is invalid")
      length = int(item.length)
    elif item.length != 0 or item.data != nil or
        (item.kind == GeneCopiedNil and item.scalar != 0) or
        (item.kind == GeneCopiedBool and item.scalar notin [0'i64, 1'i64]) or
        (item.kind == GeneCopiedF64 and item.scalar != 0) or
        (item.kind != GeneCopiedF64 and item.real != 0):
      raise newException(GeneError, "native copied Task scalar is invalid")
    acquire(domain.lock)
    try:
      if domain.cProducers.getOrDefault(token) == nil:
        raise newException(GeneError, "native Task producer token is unavailable")
      if domain.copyCount + domain.copyReservations >= GeneCopiedQueueCount or
          domain.copyBytes + domain.copyReservedBytes >
            GeneCopiedQueueBytes - length:
        raise newException(GeneError, "native copied Task queue is full")
      inc domain.copyReservations
      domain.copyReservedBytes += length
      reserved = true
    finally:
      release(domain.lock)
    if length > 0:
      when defined(geneNativeCopyAllocationProbe):
        if failNextNativeCopyAllocation:
          failNextNativeCopyAllocation = false
          raise newException(GeneError, "native copied Task allocation failed")
      copied = copiedMalloc(csize_t(length))
      if copied == nil:
        raise newException(GeneError, "native copied Task allocation failed")
      copyMem(copied, item.data, length)
    acquire(domain.lock)
    try:
      let producer = domain.cProducers.getOrDefault(token)
      if producer == nil:
        raise newException(GeneError, "native Task producer token is unavailable")
      producer.copyKind = item.kind
      producer.copyScalar = item.scalar
      producer.copyReal = item.real
      producer.copyData = copied
      producer.copyLength = length
      if domain.copyTail == nil:
        domain.copyHead = producer
      else:
        domain.copyTail.copyNext = producer
      domain.copyTail = producer
      inc domain.copyCount
      domain.copyBytes += length
      dec domain.copyReservations
      domain.copyReservedBytes -= length
      reserved = false
      domain.cProducers.del(token)
      copied = nil # the queued producer now owns the C allocation
      geneSignalNativeWake() # root cannot drain before this C entry signals
    finally:
      release(domain.lock)
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  finally:
    if copied != nil: copiedFree(copied)
    if reserved:
      acquire(domain.lock)
      try:
        dec domain.copyReservations
        domain.copyReservedBytes -= length
      finally:
        release(domain.lock)

proc geneManagedPoll*(domain: GeneManagedDomain): int =
  ## A direct Nim embedder may call this from its root event loop. The normal
  ## NativeModule owner calls it through the installed scheduler poll hook.
  domain.requireRootLane()
  domain.drainForeignRoots()
  var copiedBytes = 0
  while result < 32:
    var producer: ManagedCProducer
    acquire(domain.lock)
    try:
      let next = domain.copyHead
      if next == nil or (result > 0 and
          copiedBytes + next.copyLength > 1024 * 1024):
        break
      producer = ownedCopy(next)
      domain.copyHead = move(producer.copyNext)
      if domain.copyHead == nil: domain.copyTail = nil
      dec domain.copyCount
      domain.copyBytes -= producer.copyLength
    finally:
      release(domain.lock)
    inc result
    copiedBytes += producer.copyLength
    var payloadRoot: GeneManagedRoot
    try:
      let payload = case producer.copyKind
        of GeneCopiedNil: NIL
        of GeneCopiedBool: newBool(producer.copyScalar == 1)
        of GeneCopiedI64: newInt(producer.copyScalar)
        of GeneCopiedF64: newFloat(producer.copyReal)
        of GeneCopiedText, GeneCopiedBytes:
          var bytes = newString(producer.copyLength)
          if bytes.len > 0:
            copyMem(addr bytes[0], producer.copyData, bytes.len)
          if producer.copyKind == GeneCopiedText:
            if validateUtf8(bytes) != -1:
              raise newException(GeneError,
                "native copied Task text is not valid UTF-8")
            newStr(bytes)
          else: newBytes(bytes)
        else:
          raise newException(GeneError, "native copied Task kind is invalid")
      payloadRoot = domain.addRoot(payload, allowClosed = true)
      let ack = geneManagedTaskComplete(producer.task, payloadRoot,
                                        producer.environment)
      if ack.status != gsOk:
        raise newException(GeneError, ack.message)
    except CatchableError as e:
      if not producer.task.settled:
        discard geneManagedTaskFail(producer.task, producer.environment,
                                     e.msg)
    finally:
      try:
        if payloadRoot != nil: geneManagedRelease(payloadRoot)
      finally:
        try:
          if producer.copyData != nil:
            copiedFree(producer.copyData)
            producer.copyData = nil
        finally:
          try:
            if not producer.task.settled:
              discard geneManagedTaskRetire(producer.task,
                                            producer.environment)
          finally:
            finishCProducer(domain, producer)
  drainCProducerReleases(domain)
  domain.drainForeignRoots()

proc apiReserveForeignRoots(context: pointer, capacity: csize_t,
                            diagnostic: ptr GeneOutBytes): uint32 {.cdecl.} =
  try:
    if capacity > csize_t(GeneForeignRootLimit):
      raise newException(GeneError, "foreign managed root capacity is invalid")
    let domain = apiDomain(context)
    domain.geneManagedReserveForeignRoots(int(capacity))
    apiDiagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 2
  except CatchableError as e:
    apiDiagnostic(diagnostic, e.msg)
    result = 1

proc configureApiTable(domain: GeneManagedDomain) =
  domain.apiTable = GeneApi(version: GeneApiVersion,
                           structSize: uint32(sizeof(GeneApi)),
                           featureBits: GeneApiIdentityFeature or
                                        GeneApiScalarFeature or
                                        GeneApiCallDefineFeature or
                                        GeneApiFrozenFeature or
                                        GeneApiIngressFeature or
                                        GeneApiCallbackFeature or
                                        GeneApiTaskProducerFeature or
                                        GeneApiTaskCopyFeature or
                                        GeneApiFloatFeature,
                           runtimeContext: cast[pointer](domain),
                           retain: cast[pointer](apiRetain),
                           release: cast[pointer](apiRelease),
                           kind: cast[pointer](apiKind),
                           call: cast[pointer](apiCall),
                           define: cast[pointer](apiDefine),
                           copyBool: cast[pointer](apiCopyBool),
                           copyI64: cast[pointer](apiCopyI64),
                           copyText: cast[pointer](apiCopyText),
                           copyBytes: cast[pointer](apiCopyBytes),
                           newBool: cast[pointer](apiNewBool),
                           newI64: cast[pointer](apiNewI64),
                           length: cast[pointer](apiLength),
                           copyKey: cast[pointer](apiCopyKey),
                           traverse: cast[pointer](apiTraverse))
  domain.apiTable.registerCallback = cast[pointer](apiRegisterCallback)
  domain.apiTable.requestClose = cast[pointer](apiRequestClose)
  domain.apiTable.waitClosed = cast[pointer](apiWaitClosed)
  domain.apiTable.newTask = cast[pointer](apiNewTask)
  domain.apiTable.taskComplete = cast[pointer](apiTaskComplete)
  domain.apiTable.taskFail = cast[pointer](apiTaskFail)
  domain.apiTable.taskCancel = cast[pointer](apiTaskCancel)
  domain.apiTable.taskRetire = cast[pointer](apiTaskRetire)
  domain.apiTable.taskSubmitCopy = cast[pointer](apiTaskSubmitCopy)
  domain.apiTable.copyF64 = cast[pointer](apiCopyF64)
  domain.apiTable.newF64 = cast[pointer](apiNewF64)
  domain.apiTable.ingressBegin = geneIngressBegin
  domain.apiTable.ingressEnqueue = geneIngressEnqueue
  domain.apiTable.ingressEnd = geneIngressEnd
  domain.apiTable.newText = cast[pointer](apiNewText)
  domain.apiTable.newBytes = cast[pointer](apiNewBytes)
  domain.apiTable.lookup = cast[pointer](apiLookup)
  when defined(gcAtomicArc) and compileOption("threads"):
    domain.apiTable.featureBits = domain.apiTable.featureBits or
                               GeneApiAttachedFeature or
                               GeneApiForeignRootsFeature
    domain.apiTable.attachThread = cast[pointer](apiAttachThread)
    domain.apiTable.detachThread = cast[pointer](apiDetachThread)
    domain.apiTable.reserveForeignRoots = cast[pointer](apiReserveForeignRoots)

const GeneModuleInitSymbol* = "gene_module_init"

proc rollbackModuleLoad(domain: GeneManagedDomain,
                        frame: ManagedLoadFrame, firstNewRoot: uint64) =
  for id in frame.registrations:
    var registration: GeneManagedRegistration
    acquire(domain.lock)
    try:
      registration = domain.registrations.getOrDefault(id)
    finally:
      release(domain.lock)
    if registration != nil:
      discard requestCloseRegistration(registration)
      acquire(domain.lock)
      try:
        if registration.retired:
          domain.registrations.del(id)
      finally:
        release(domain.lock)
  var newRoots: seq[uint64]
  acquire(domain.lock)
  try:
    for id in domain.roots.keys:
      if id > firstNewRoot: newRoots.add id
  finally:
    release(domain.lock)
  for id in newRoots:
    geneManagedRelease(GeneManagedRoot(domain: domain, id: id))

proc geneManagedLoadModule*(domain: GeneManagedDomain,
    library: GeneManagedRoot, environment: GeneManagedEnvironment,
    name: string, requiredFeatures = 0'u64): GeneManagedResult =
  ## Load the single C module entry with a stable per-domain API table.
  ## Absent operations remain unadvertised until qualified.
  withManagedProgress:
    var moduleEnvironment: GeneManagedEnvironment
    var frame: ManagedLoadFrame
    var frameStarted = false
    var frameOnStack = false
    var succeeded = false
    var initializerBorrowed = false
    var firstNewRoot: uint64
    var lib = NIL
    try:
      domain.requireOpen()
      let parentScope = domain.environmentScope(environment)
      lib = domain.liveRootValue(library)
      if lib.kind != vkFfiLibrary or lib.ffiLibraryClosed:
        raise newException(GeneError,
          "managed module load requires an open ffi/Library")
      if name.len == 0:
        raise newException(GeneError, "managed module name is empty")
      if (requiredFeatures and not domain.apiTable.featureBits) != 0:
        raise newException(GeneError,
          "native ABI required feature bits are unavailable")
      let symbol = symAddr(cast[LibHandle](lib.ffiLibraryHandle),
                           GeneModuleInitSymbol)
      if symbol == nil:
        raise newException(GeneError,
          "native ABI initializer not found: " & GeneModuleInitSymbol)
      let moduleScope = newScope(parentScope)
      moduleScope.moduleRoot = true
      moduleScope.moduleBase = nil
      moduleScope.moduleStatic = true
      acquire(domain.lock)
      try:
        firstNewRoot = domain.nextId
      finally:
        release(domain.lock)
      moduleEnvironment = geneNewManagedEnvironment(domain, moduleScope)
      lib.borrowFfiLibrary()
      initializerBorrowed = true
      domain.loadFrames.add ManagedLoadFrame(
        library: lib, environment: moduleEnvironment.root.id)
      frameStarted = true
      frameOnStack = true
      var bytes: array[512, uint8]
      var diagnostic = GeneOutBytes(data: addr bytes[0],
                                      capacity: csize_t(bytes.len))
      let initializer = cast[GeneModuleInitCProc](symbol)
      let code = initializer(addr domain.apiTable, moduleEnvironment.root.id,
                             addr diagnostic)
      frame = move(domain.loadFrames[^1])
      domain.loadFrames.setLen(domain.loadFrames.len - 1)
      frameOnStack = false
      if code != 0:
        let count = if diagnostic.required > csize_t(bytes.len): bytes.len
                    else: int(diagnostic.required)
        var message = "native ABI initializer returned " & $code
        if count > 0:
          message.add ": "
          for i in 0 ..< count:
            message.add char(bytes[i])
        result.status = case code
          of 2'u32: gsPanic
          of 3'u32: gsCancelled
          else: gsError
        result.message = message
        return
      let root = newNamespace(name, moduleScope, lib.ffiLibraryPath,
                              moduleRoot = true)
      let moduleValue = newModule(name, root, lib.ffiLibraryPath)
      result.value = geneManagedRootFromVm(domain, parentScope, moduleValue)
      result.status = gsOk
      succeeded = true
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg
    finally:
      if frameOnStack:
        frame = move(domain.loadFrames[^1])
        domain.loadFrames.setLen(domain.loadFrames.len - 1)
      if frameStarted and not succeeded:
        rollbackModuleLoad(domain, frame, firstNewRoot)
      if moduleEnvironment != nil:
        geneManagedEnvironmentRelease(moduleEnvironment)
      if initializerBorrowed:
        lib.releaseFfiLibraryBorrow()

proc geneManagedClose*(domain: GeneManagedDomain): bool =
  domain.requireDomain()
  if currentEventLane() != domain.rootLane:
    raise newException(GeneError, "managed native close requires the root lane")
  discard geneManagedPoll(domain)
  var registrations: seq[GeneManagedRegistration]
  acquire(domain.lock)
  try:
    domain.closed = true
    for _, registration in domain.registrations:
      registrations.add registration
  finally:
    release(domain.lock)
  for registration in registrations:
    discard requestCloseRegistration(registration)
  var retiredSlots: seq[ForeignRootSlot]
  var retiredIndex: Table[uint64, int]
  var releaseForeignWake = false
  acquire(domain.lock)
  try:
    result = domain.roots.len == 0 and domain.borrows == 0 and
             domain.foreignLive == 0 and domain.foreignPending == 0 and
             domain.producers == 0 and domain.attachmentCount == 0 and
             domain.registrations.len == 0 and domain.liveRegistrations == 0 and
             domain.cProducers.len == 0 and
             domain.pendingProducerReleases == nil and
             domain.copyCount == 0 and domain.copyReservations == 0
    if result and domain.foreignWakeHeld:
      retiredSlots = move(domain.foreignSlots)
      retiredIndex = move(domain.foreignIndex)
      domain.foreignWakeHeld = false
      releaseForeignWake = true
  finally:
    release(domain.lock)
  reset(retiredSlots)
  reset(retiredIndex)
  if releaseForeignWake: geneReleaseNativeWake()

proc geneManagedStats*(domain: GeneManagedDomain):
    tuple[roots, borrows, producers, attachments, registrations,
          liveRegistrations, copiedQueued, copiedBytes,
          copiedReserved, copiedReservedBytes, foreignLive,
          foreignPending, foreignCapacity: int,
          closed: bool, nextId: uint64] =
  domain.requireDomain()
  acquire(domain.lock)
  try:
    result = (domain.roots.len + domain.foreignLive + domain.foreignPending,
              domain.borrows, domain.producers,
              domain.attachmentCount, domain.registrations.len,
              domain.liveRegistrations, domain.copyCount, domain.copyBytes,
              domain.copyReservations, domain.copyReservedBytes,
              domain.foreignLive, domain.foreignPending,
              domain.foreignSlots.len,
              domain.closed, domain.nextId)
  finally:
    release(domain.lock)

proc managedIngressSettle(raw: RootRef): GeneIngressManagedResult {.nimcall.} =
  let owner = GeneManagedIngressOwner(raw)
  if owner == nil or owner.released:
    raise newException(GeneError, "managed ingress owner is unavailable")
  if owner.activeTask == nil:
    return
  let task = owner.domain.liveRootValue(owner.activeTask)
  if not task.taskDone:
    result.pending = true
    return
  var outcome: GeneManagedResult
  try:
    outcome = geneWithNativeBorrow(owner.activeTask,
      proc(b: GeneNativeBorrow): GeneManagedResult =
        geneManagedTaskOutcome(b, owner.environment))
  except CatchableError as error:
    geneManagedRelease(owner.activeTask)
    owner.activeTask = nil
    return GeneIngressManagedResult(completed: true, status: gsError,
                                    message: error.msg)
  geneManagedRelease(owner.activeTask)
  owner.activeTask = nil
  if outcome.value != nil: geneManagedRelease(outcome.value)
  if outcome.error != nil: geneManagedRelease(outcome.error)
  result.completed = true
  result.status = outcome.status
  result.message = outcome.message

proc managedIngressCancel(raw: RootRef) {.nimcall.} =
  let owner = GeneManagedIngressOwner(raw)
  if owner == nil or owner.released:
    raise newException(GeneError, "managed ingress owner is unavailable")
  if owner.activeTask == nil: return
  let task = owner.domain.liveRootValue(owner.activeTask)
  if task.kind == vkTask and not task.taskDone:
    let scope = owner.domain.environmentScope(owner.environment)
    discard vm.nativeTaskCancel(task, scope)

proc managedIngressRelease(raw: RootRef) {.nimcall.} =
  let owner = GeneManagedIngressOwner(raw)
  if owner == nil or owner.released: return
  if owner.activeTask != nil and managedIngressSettle(raw).pending:
    raise newException(GeneError,
      "managed ingress handler Task has not settled")
  if owner.library != nil:
    if owner.borrowedLibrary:
      let library = owner.domain.liveRootValue(owner.library)
      releaseFfiLibraryBorrow(library)
    geneManagedRelease(owner.library)
    owner.library = nil
    owner.borrowedLibrary = false
  if owner.environment != nil:
    geneManagedEnvironmentRelease(owner.environment)
    owner.environment = nil
  if owner.handler != nil:
    geneManagedRelease(owner.handler)
    owner.handler = nil
  if owner.domain != nil:
    if not geneManagedClose(owner.domain):
      raise newException(GeneError,
        "managed ingress owner has outstanding handles")
    owner.domain = nil
  owner.released = true

proc managedIngressOpen(handler: Value, scope: Scope,
                        library: Value): RootRef {.nimcall.} =
  # Some VM dispatch scopes inherit their Application through the active
  # scheduler rather than a field. Freeze that identity for this native owner;
  # later scheduler turns may run another Application on the same root lane.
  let stableScope = newScope(scope,
    application = RuntimeContext(vm.application(scope)))
  let owner = GeneManagedIngressOwner(domain: geneNewManagedDomain(stableScope))
  try:
    owner.handler = geneManagedRootFromVm(owner.domain, stableScope, handler)
    owner.environment = geneNewManagedEnvironment(owner.domain, stableScope)
    if library.kind != vkNil:
      owner.library = geneManagedRootFromVm(owner.domain, stableScope, library)
      borrowFfiLibrary(library)
      owner.borrowedLibrary = true
    result = RootRef(owner)
  except CatchableError:
    managedIngressRelease(RootRef(owner))
    raise

proc managedIngressDispatch(raw: RootRef,
                            payload: string): GeneIngressManagedResult
                            {.nimcall.} =
  let owner = GeneManagedIngressOwner(raw)
  if owner == nil or owner.released or owner.activeTask != nil:
    raise newException(GeneError,
      "managed ingress handler is unavailable")
  let scope = owner.domain.environmentScope(owner.environment)
  let input = geneManagedRootFromVm(owner.domain, scope, newBytes(payload))
  try:
    let called = geneWithNativeBorrow(owner.handler,
      proc(b: GeneNativeBorrow): GeneManagedResult =
        geneManagedCall(b, [input], owner.environment))
    result.status = called.status
    result.message = called.message
    var valueRoot = called.value
    try:
      if called.error != nil: geneManagedRelease(called.error)
      if called.status != gsOk:
        return
      if valueRoot == nil:
        result.completed = true
        return
      let kind = geneWithNativeBorrow(valueRoot,
        proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b))
      if kind == vkTask:
        owner.activeTask = valueRoot
        valueRoot = nil # the owner keeps the Task through settlement
        result = managedIngressSettle(raw)
        if not result.completed: result.pending = true
      else:
        result.completed = true
    finally:
      if valueRoot != nil: geneManagedRelease(valueRoot)
  finally:
    geneManagedRelease(input)

installNativeIngressManagedHooks(GeneIngressManagedHooks(
  open: managedIngressOpen,
  dispatch: managedIngressDispatch,
  settle: managedIngressSettle,
  cancel: managedIngressCancel,
  release: managedIngressRelease))

proc unloadManagedPackageLibrary(address: pointer) {.nimcall.} =
  unloadLib(cast[LibHandle](address))

proc requestCloseManagedPackageModule(record: GeneManagedPackageModule)
proc pollManagedPackageModule(record: GeneManagedPackageModule)

proc managedPackageModuleRecord(value: Value,
                                scope: Scope): GeneManagedPackageModule =
  if value.kind != vkNode or value.nodeResourceId == 0 or scope == nil:
    raise newException(GeneError, "native module requires a live handle")
  acquire(managedPackageModuleLock)
  try:
    result = managedPackageModules.getOrDefault(value.nodeResourceId)
  finally:
    release(managedPackageModuleLock)
  if result == nil or result.application != vm.application(scope) or
      result.ownerLane != currentEventLane():
    raise newException(GeneError,
      "native module handle is unavailable on this lane")

proc settleManagedPackageWaiter(record: GeneManagedPackageModule,
                                waiter: ManagedModuleWaiter) =
  case record.terminalStatus
  of gsOk: discard vm.nativeTaskComplete(waiter.task, NIL, waiter.scope)
  of gsError: discard vm.nativeTaskFail(waiter.task,
    record.terminalMessage, scope = waiter.scope)
  of gsPanic: discard vm.nativeTaskPanic(waiter.task,
    record.terminalMessage, waiter.scope)
  of gsCancelled: discard vm.nativeTaskCancel(waiter.task, waiter.scope)
  if waiter.lease.kind == vkTask:
    discard vm.nativeRetireIoCleanupLease(waiter.lease, waiter.scope)

proc requestCloseManagedPackageModule(record: GeneManagedPackageModule) =
  if record == nil or record.closed: return
  record.closeRequested = true
  if record.domain == nil: return
  var registrations: seq[uint64]
  acquire(record.domain.lock)
  try:
    for id in record.domain.registrations.keys: registrations.add id
  finally:
    release(record.domain.lock)
  for id in registrations:
    var registration: GeneManagedRegistration
    acquire(record.domain.lock)
    try:
      registration = record.domain.registrations.getOrDefault(id)
    finally:
      release(record.domain.lock)
    if registration == nil: continue
    discard requestCloseRegistration(registration)
    var stillRegistered = false
    acquire(record.domain.lock)
    try:
      stillRegistered = record.domain.registrations.hasKey(id)
    finally:
      release(record.domain.lock)
    if not stillRegistered: continue # C retirement consumed its own token
    var taskId: uint64
    let code = apiWaitClosed(cast[pointer](record.domain), id,
                             addr taskId, nil)
    if code == 0 and taskId != 0:
      record.closeTasks.add GeneManagedRoot(domain: record.domain, id: taskId)
    elif record.terminalStatus == gsOk:
      record.terminalStatus = gsError
      record.terminalMessage = "native registration close waiter failed"

proc pollManagedPackageModule(record: GeneManagedPackageModule) =
  if record == nil or record.closed: return
  if not record.closeRequested:
    if not atomicLoadN(addr record.handleGone, ATOMIC_ACQUIRE): return
    record.requestCloseManagedPackageModule()
  let domain = record.domain
  if domain != nil:
    if geneManagedStats(domain).registrations > 0:
      record.requestCloseManagedPackageModule()
    let before = geneManagedStats(domain)
    if before.liveRegistrations > 0: return
    for root in record.closeTasks:
      let task = domain.liveRootValue(root)
      if not task.taskDone: return
      if task.taskHasError and record.terminalStatus == gsOk:
        record.terminalStatus = gsError
        record.terminalMessage = task.taskErrorMsg
    discard geneManagedClose(domain) # seals new native admission
    let sealed = geneManagedStats(domain)
    if sealed.borrows > 0 or sealed.producers > 0 or
        sealed.attachments > 0: return
    if not record.rootsReleased:
      var ids: seq[uint64]
      acquire(domain.lock)
      try:
        for id in domain.roots.keys: ids.add id
      finally:
        release(domain.lock)
      for id in ids:
        geneManagedRelease(GeneManagedRoot(domain: domain, id: id))
      record.closeTasks.setLen(0)
      record.moduleRoot = nil
      record.libraryRoot = nil
      record.environment = nil
      record.rootsReleased = true
    if not geneManagedClose(domain): return
  try:
    if record.library.kind == vkFfiLibrary:
      record.library.closeFfiLibrary()
    if record.lease.kind != vkNil:
      vm.closeMaterializedResourceFromNative(record.lease,
        if domain == nil: nil else: domain.rootScope)
    if record.cleanupLease.kind == vkTask:
      discard vm.nativeRetireIoCleanupLease(record.cleanupLease)
  except CatchableError as error:
    if record.terminalStatus == gsOk:
      record.terminalStatus = gsError
      record.terminalMessage = error.msg
    return # keep the image and lease for a later physical retry
  record.library = NIL
  record.lease = NIL
  record.cleanupLease = NIL
  record.domain = nil
  record.closed = true
  for waiter in record.waiters:
    record.settleManagedPackageWaiter(waiter)
  record.waiters.setLen(0)
  if atomicLoadN(addr record.handleGone, ATOMIC_ACQUIRE):
    acquire(managedPackageModuleLock)
    try:
      managedPackageModules.del(record.id)
    finally:
      release(managedPackageModuleLock)

proc managedPackageModuleOpen(lease: Value, path, name: string,
                              scope: Scope): Value {.nimcall.} =
  vm.requireNativeRootLane(scope)
  let stableScope = newScope(scope,
    application = RuntimeContext(vm.application(scope)))
  var record = GeneManagedPackageModule(
    id: nextRuntimeResourceId(), application: vm.application(scope),
    ownerLane: currentEventLane(), lease: lease)
  try:
    record.domain = geneNewManagedDomain(stableScope)
    record.cleanupLease = vm.nativeNewIoCleanupLease(stableScope)
    acquire(managedPackageModuleLock)
    try:
      managedPackageModules[record.id] = record
    finally:
      release(managedPackageModuleLock)
    let handle = loadLib(path)
    if handle == nil:
      raise newException(GeneError,
        "managed native module failed to open library: " & path)
    record.library = newFfiLibrary(cast[pointer](handle), path,
                                   unloadManagedPackageLibrary)
    record.environment = geneNewManagedEnvironment(record.domain, stableScope)
    record.libraryRoot = geneManagedRootFromVm(record.domain, stableScope,
                                               record.library)
    let loaded = geneManagedLoadModule(record.domain, record.libraryRoot,
                                       record.environment, name)
    if loaded.status != gsOk:
      case loaded.status
      of gsPanic: raise newException(GenePanic, loaded.message)
      of gsCancelled: raise newException(GeneCancel, loaded.message)
      else: raise newException(GeneError, loaded.message)
    record.moduleRoot = loaded.value
    result = newRuntimeResourceHandle(scope, "NativeModule", record.id)
  except CatchableError:
    if record.domain == nil:
      vm.closeMaterializedResourceFromNative(lease, scope)
    else:
      atomicStoreN(addr record.handleGone, true, ATOMIC_RELEASE)
      record.requestCloseManagedPackageModule()
      record.pollManagedPackageModule()
    raise

proc biManagedPackageModuleValue(args: openArray[Value],
                                 call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raise newException(GeneError, "NativeModule.module expects one receiver")
  let record = managedPackageModuleRecord(args[0], scope)
  if record.closed or record.closeRequested or record.moduleRoot == nil:
    raise newException(GeneError, "native module is closing or closed")
  record.domain.liveRootValue(record.moduleRoot)

proc biManagedPackageModuleClose(args: openArray[Value],
                                 call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raise newException(GeneError, "NativeModule.close expects one receiver")
  let record = managedPackageModuleRecord(args[0], scope)
  record.requestCloseManagedPackageModule()
  record.pollManagedPackageModule()
  NIL

proc biManagedPackageModuleWaitClosed(args: openArray[Value],
                                      call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raise newException(GeneError,
      "NativeModule.wait_closed expects one receiver")
  let record = managedPackageModuleRecord(args[0], scope)
  record.pollManagedPackageModule()
  if record.closed:
    result = vm.nativeNewAsyncTask()
    record.settleManagedPackageWaiter(ManagedModuleWaiter(task: result,
      scope: scope))
    return
  let operation = vm.nativeNewIoOperation(scope)
  result = operation.task
  record.waiters.add ManagedModuleWaiter(task: operation.task,
    lease: operation.cleanupLease, scope: scope)

proc biManagedPackageModuleStatus(args: openArray[Value],
                                  call: ptr NativeCall): Value {.nimcall.} =
  let scope = if call == nil: nil else: call[].dispatchScope
  if args.len != 1:
    raise newException(GeneError, "NativeModule.status expects one receiver")
  let record = managedPackageModuleRecord(args[0], scope)
  let stats = if record.domain == nil:
    (roots: 0, producers: 0, registrations: 0, liveRegistrations: 0,
     copiedQueued: 0, copiedBytes: 0, copiedReserved: 0,
     copiedReservedBytes: 0, foreignLive: 0, foreignPending: 0,
     foreignCapacity: 0)
    else:
      let current = geneManagedStats(record.domain)
      (roots: current.roots, producers: current.producers,
       registrations: current.registrations,
       liveRegistrations: current.liveRegistrations,
       copiedQueued: current.copiedQueued,
       copiedBytes: current.copiedBytes,
       copiedReserved: current.copiedReserved,
       copiedReservedBytes: current.copiedReservedBytes,
       foreignLive: current.foreignLive,
       foreignPending: current.foreignPending,
       foreignCapacity: current.foreignCapacity)
  var fields = initPropTable()
  fields["state"] = newStr(
    if record.closed: "closed"
    elif record.closeRequested: "closing"
    else: "active")
  fields["roots"] = newInt(stats.roots)
  fields["producers"] = newInt(stats.producers)
  fields["registrations"] = newInt(stats.registrations)
  fields["live_registrations"] = newInt(stats.liveRegistrations)
  fields["copied_queued"] = newInt(stats.copiedQueued)
  fields["copied_bytes"] = newInt(stats.copiedBytes)
  fields["copied_reserved"] = newInt(stats.copiedReserved)
  fields["copied_reserved_bytes"] = newInt(stats.copiedReservedBytes)
  fields["foreign_roots"] = newInt(stats.foreignLive)
  fields["foreign_pending"] = newInt(stats.foreignPending)
  fields["foreign_capacity"] = newInt(stats.foreignCapacity)
  fields["terminal_kind"] = newStr($record.terminalStatus)
  fields["terminal_message"] = newStr(record.terminalMessage)
  newMap(fields)

proc releaseManagedPackageModuleHandle(id: uint64) {.nimcall, raises: [].} =
  var retired: GeneManagedPackageModule
  acquire(managedPackageModuleLock)
  try:
    let record = managedPackageModules.getOrDefault(id)
    if record != nil:
      atomicStoreN(addr record.handleGone, true, ATOMIC_RELEASE)
      if record.closed:
        discard managedPackageModules.pop(id, retired)
  finally:
    release(managedPackageModuleLock)
  reset(retired)

proc managedPackageModuleRecordCount(app: Application): int {.nimcall.} =
  acquire(managedPackageModuleLock)
  try:
    for _, record in managedPackageModules:
      if record.application == app: inc result
  finally:
    release(managedPackageModuleLock)

proc pollManagedPackageModules(scheduler: SchedulerState) {.nimcall.} =
  var pending: seq[GeneManagedPackageModule]
  acquire(managedPackageModuleLock)
  try:
    for _, record in managedPackageModules:
      if vm.schedulerOwnsApplication(scheduler, record.application) and
          record.ownerLane == currentEventLane():
        pending.add record
  finally:
    release(managedPackageModuleLock)
  for record in pending:
    if record.domain != nil:
      discard geneManagedPoll(record.domain)
    record.pollManagedPackageModule()

proc hasManagedPackageModulesClosing(scheduler: SchedulerState): bool
                                     {.nimcall.} =
  var records: seq[GeneManagedPackageModule]
  acquire(managedPackageModuleLock)
  try:
    for _, record in managedPackageModules:
      if vm.schedulerOwnsApplication(scheduler, record.application):
        records.add record
  finally:
    release(managedPackageModuleLock)
  for record in records:
    if record.closed: continue
    if record.closeRequested or
        atomicLoadN(addr record.handleGone, ATOMIC_ACQUIRE):
      return true
    if record.domain != nil:
      acquire(record.domain.lock)
      try:
        if record.domain.cProducers.len > 0 or record.domain.copyCount > 0 or
            record.domain.pendingProducerReleases != nil or
            record.domain.foreignPending > 0:
          return true
      finally:
        release(record.domain.lock)

installNativeModuleAdapter(NativeModuleAdapter(
  abiVersion: int(GeneApiVersion),
  open: managedPackageModuleOpen,
  module: biManagedPackageModuleValue,
  close: biManagedPackageModuleClose,
  waitClosed: biManagedPackageModuleWaitClosed,
  status: biManagedPackageModuleStatus,
  recordCount: managedPackageModuleRecordCount))
installNativeModuleHandleReleaseHook(releaseManagedPackageModuleHandle)
installNativeModulePollHook(pollManagedPackageModules)
installNativeModuleActiveHook(hasManagedPackageModulesClosing)
