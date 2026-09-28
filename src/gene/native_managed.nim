## Additive Nim SDK for mediated Gene references. Legacy GeneApi v4/v5 is
## unchanged. No raw Value or Scope is returned by this module except through
## the explicitly irreversible legacy export.

import std/[dynlib, locks, tables]
import ./[native_api, types, vm]
when defined(geneAtomicGenerationRetirementProbe):
  import ./retirement_native_gate

type
  GeneOutBytesV6* {.bycopy.} = object
    data*: ptr uint8
    capacity*: csize_t
    required*: csize_t

  GeneApiV6* {.bycopy.} = object
    version*: uint32
    structSize*: uint32
    featureBits*: uint64
    runtimeContext*: pointer
    attachThread*: pointer
    detachThread*: pointer
    retain*: pointer
    release*: pointer
    kind*: pointer
    copyBool*: pointer
    copyI64*: pointer
    copyText*: pointer
    copyBytes*: pointer
    newBool*: pointer
    newI64*: pointer
    newText*: pointer
    newBytes*: pointer
    length*: pointer
    copyKey*: pointer
    traverse*: pointer
    call*: pointer
    define*: pointer
    registerCallback*: pointer
    requestClose*: pointer
    waitClosed*: pointer

  GeneModuleInitV6Proc* = proc(api: ptr GeneApiV6, environment: uint64,
                               diagnostic: ptr GeneOutBytesV6): uint32 {.cdecl.}

  ManagedEntry = ref object
    scopes: seq[Scope] # strong known Scope/code provenance until physical release
    value: Value

  GeneManagedDomain* = ref object
    application: RuntimeContext
    rootLane: int
    rootScope: Scope
    lock: Lock
    nextId: uint64
    roots: Table[uint64, ManagedEntry]
    borrows: int
    producers: int
    producerEntries: Table[uint64, ManagedEntry]
    closed: bool
    v6Api: GeneApiV6

  GeneManagedRoot* = ref object
    domain: GeneManagedDomain
    id: uint64

  GeneManagedEnvironment* = ref object
    root: GeneManagedRoot

  GeneNativeBorrow* = ref object
    domain: GeneManagedDomain
    entry: ManagedEntry
    ownerLane: int
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

proc ownedCopy[T](value: T): T {.inline.} = value

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

proc configureV6Api(domain: GeneManagedDomain)

proc geneNewManagedDomain*(scope: Scope): GeneManagedDomain =
  vm.requireNativeRootLane(scope)
  new(result)
  result.application = scope.application
  result.rootLane = currentEventLane()
  result.rootScope = scope
  result.roots = initTable[uint64, ManagedEntry]()
  result.producerEntries = initTable[uint64, ManagedEntry]()
  initLock(result.lock)
  result.configureV6Api()

proc addRoot(domain: GeneManagedDomain, value: Value,
             scopes: seq[Scope] = @[]): GeneManagedRoot =
  domain.requireDomain()
  acquire(domain.lock)
  try:
    if domain.closed:
      raise newException(GeneError, "managed native domain is closed")
    if domain.nextId == high(uint64):
      raise newException(GeneError, "managed native root IDs are exhausted")
    inc domain.nextId
    let id = domain.nextId
    domain.roots[id] = ManagedEntry(value: value, scopes: scopes)
    result = GeneManagedRoot(domain: domain, id: id)
  finally:
    release(domain.lock)

proc requireRootLane(domain: GeneManagedDomain) =
  domain.requireDomain()
  if currentEventLane() != domain.rootLane:
    raise newException(GeneError, "managed native operation requires the runtime root lane")

proc liveRootValue(domain: GeneManagedDomain,
                   root: GeneManagedRoot): Value =
  domain.requireDomain()
  if root == nil or root.domain != domain:
    raise newException(GeneError, "managed root belongs to another runtime")
  acquire(domain.lock)
  try:
    let entry = domain.roots.getOrDefault(root.id)
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
    if found == nil:
      raise newException(GeneError, "managed native root has been released")
    result = ownedCopy(found)
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

proc geneManagedRelease*(root: GeneManagedRoot) =
  if root == nil or root.domain == nil: return
  when defined(geneAtomicGenerationRetirementProbe):
    if not enterRetirementNativeAccess(true):
      raise newException(GeneError, "managed release cannot enter generation analysis")
  try:
    let domain = root.domain
    var retired: ManagedEntry
    acquire(domain.lock)
    try:
      let found = domain.roots.getOrDefault(root.id)
      if found != nil:
        # Keep the final owner until after the registry lock is released.
        retired = ownedCopy(found)
        domain.roots.del(root.id)
    finally:
      release(domain.lock)
    reset(retired)
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
      let entry = domain.roots.getOrDefault(root.id)
      if entry == nil:
        raise newException(GeneError, "managed native root has been released")
      result = GeneNativeBorrow(domain: domain, entry: entry,
                                ownerLane: currentEventLane(), active: true)
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
  result = borrow.domain.addRoot(entry.value, entry.scopes)

proc requireFrozen(value: Value, kind: ValueKind, label: string) =
  if value.kind != kind or not value.isDeepFrozen:
    raise newException(GeneError, "managed " & label & " requires a deep-frozen " & $kind)

proc geneManagedListLength*(borrow: GeneNativeBorrow): int =
  let value = borrow.requireBorrow().value
  requireFrozen(value, vkList, "length")
  value.listItems.len

proc geneManagedListAt*(borrow: GeneNativeBorrow, index: int): GeneManagedRoot =
  let value = borrow.requireBorrow().value
  requireFrozen(value, vkList, "index")
  if index < 0 or index >= value.listItems.len:
    raise newException(GeneError, "managed List index is out of bounds")
  borrow.domain.addRoot(value.listItems[index])

proc geneManagedMapAt*(borrow: GeneNativeBorrow,
                       name: string): GeneManagedRoot =
  let value = borrow.requireBorrow().value
  requireFrozen(value, vkMap, "lookup")
  borrow.domain.addRoot(value.mapEntries.getOrDefault(name, VOID))

proc geneManagedNodeHead*(borrow: GeneNativeBorrow): GeneManagedRoot =
  let value = borrow.requireBorrow().value
  requireFrozen(value, vkNode, "head")
  borrow.domain.addRoot(value.head)

proc geneManagedNodeProp*(borrow: GeneNativeBorrow,
                          name: string): GeneManagedRoot =
  let value = borrow.requireBorrow().value
  requireFrozen(value, vkNode, "property")
  borrow.domain.addRoot(value.props.getOrDefault(name, VOID))

proc geneManagedNodeBodyAt*(borrow: GeneNativeBorrow,
                            index: int): GeneManagedRoot =
  let value = borrow.requireBorrow().value
  requireFrozen(value, vkNode, "body")
  if index < 0 or index >= value.body.len:
    raise newException(GeneError, "managed Node body index is out of bounds")
  borrow.domain.addRoot(value.body[index])

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
      let stored = domain.liveRootValue(value)
      scope.define(name, stored)
      result.status = gsOk
      result.value = domain.addRoot(stored)
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
        itemEntry.value, itemEntry.scopes, scope)
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
      var statePins = ownedCopy(stateEntry.scopes)
      statePins.add vm.publishManagedRootForRetirement(stateEntry.value)
      var handlerPins = ownedCopy(handlerEntry.scopes)
      handlerPins.add vm.publishManagedRootForRetirement(handlerEntry.value)
      var contractPins: seq[Scope]
      if contractEntry != nil:
        contractPins = ownedCopy(contractEntry.scopes)
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
        messageEntry.value, messageEntry.scopes, scope)
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
    let payloadEntry = domain.liveRootEntry(value)
    let payload = payloadEntry.value
    let producer = task.claimProducer()
    try:
      producer.value.retainTaskSourceScopes(payloadEntry.scopes)
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
        producer.value.retainTaskSourceScopes(payloadEntry.scopes)
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
  pinLegacyManagedScopes(entry.scopes)
  when defined(geneAtomicGenerationRetirementProbe):
    vm.publishNativeRootForRetirement(entry.value)
  result = geneRoot(entry.value) # irreversible raw publication

const GeneApiV6IdentityFeature* = 1'u64

proc v6Diagnostic(output: ptr GeneOutBytesV6, message: string) =
  if output == nil: return
  output.required = csize_t(message.len)
  if output.data == nil or output.capacity == 0: return
  let count = if output.capacity > csize_t(message.len): message.len
              else: int(output.capacity)
  if count > 0:
    copyMem(output.data, unsafeAddr message[0], count)

proc v6Domain(context: pointer): GeneManagedDomain =
  if context == nil:
    raise newException(GeneError, "native v6 runtime context is nil")
  result = cast[GeneManagedDomain](context)
  result.requireRootLane()
  result.requireOpen()

proc v6Retain(context: pointer, id: uint64, output: ptr uint64,
              diagnostic: ptr GeneOutBytesV6): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native v6 retain output is nil")
    let domain = v6Domain(context)
    let root = GeneManagedRoot(domain: domain, id: id)
    let copied = geneWithNativeBorrow(root,
      proc(b: GeneNativeBorrow): GeneManagedRoot = geneManagedRetain(b))
    output[] = copied.id
    v6Diagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    v6Diagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    v6Diagnostic(diagnostic, e.msg)
    result = 2

proc v6Release(context: pointer, id: uint64,
               diagnostic: ptr GeneOutBytesV6): uint32 {.cdecl.} =
  try:
    let domain = v6Domain(context)
    let root = GeneManagedRoot(domain: domain, id: id)
    discard domain.liveRootEntry(root) # stale IDs fail rather than no-op
    geneManagedRelease(root)
    v6Diagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    v6Diagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    v6Diagnostic(diagnostic, e.msg)
    result = 2

proc v6Kind(context: pointer, id: uint64, output: ptr uint32,
            diagnostic: ptr GeneOutBytesV6): uint32 {.cdecl.} =
  if output != nil: output[] = 255'u32
  try:
    if output == nil:
      raise newException(GeneError, "native v6 kind output is nil")
    let domain = v6Domain(context)
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
    v6Diagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    v6Diagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    v6Diagnostic(diagnostic, e.msg)
    result = 2

proc v6NewI64(context: pointer, value: int64, output: ptr uint64,
              diagnostic: ptr GeneOutBytesV6): uint32 {.cdecl.} =
  if output != nil: output[] = 0
  try:
    if output == nil:
      raise newException(GeneError, "native v6 Int output is nil")
    let domain = v6Domain(context)
    output[] = geneManagedRootFromVm(domain, domain.rootScope,
                                      newInt(value)).id
    v6Diagnostic(diagnostic, "")
    result = 0
  except GeneError as e:
    v6Diagnostic(diagnostic, e.msg)
    result = 1
  except GenePanic as e:
    v6Diagnostic(diagnostic, e.msg)
    result = 2

proc configureV6Api(domain: GeneManagedDomain) =
  domain.v6Api = GeneApiV6(version: 6'u32,
                           structSize: uint32(sizeof(GeneApiV6)),
                           featureBits: GeneApiV6IdentityFeature,
                           runtimeContext: cast[pointer](domain),
                           retain: cast[pointer](v6Retain),
                           release: cast[pointer](v6Release),
                           kind: cast[pointer](v6Kind),
                           newI64: cast[pointer](v6NewI64))

const GeneModuleInitV6Symbol* = "gene_module_init_v6"

proc geneManagedLoadModuleV6*(domain: GeneManagedDomain,
    library: GeneManagedRoot, environment: GeneManagedEnvironment,
    name: string, requiredFeatures = 0'u64): GeneManagedResult =
  ## Initial ABI 6 loader slice. Only root-lane identity/Int construction is
  ## advertised; other operations remain unavailable until they are qualified.
  ## v4/v5 continue through their original versioned loader unchanged.
  withManagedProgress:
    var moduleEnvironment: GeneManagedEnvironment
    try:
      domain.requireOpen()
      let parentScope = domain.environmentScope(environment)
      let lib = domain.liveRootValue(library)
      if lib.kind != vkFfiLibrary or lib.ffiLibraryClosed:
        raise newException(GeneError,
          "managed v6 module load requires an open ffi/Library")
      if name.len == 0:
        raise newException(GeneError, "managed v6 module name is empty")
      if (requiredFeatures and not domain.v6Api.featureBits) != 0:
        raise newException(GeneError,
          "native v6 required feature bits are unavailable")
      let symbol = symAddr(cast[LibHandle](lib.ffiLibraryHandle),
                           GeneModuleInitV6Symbol)
      if symbol == nil:
        raise newException(GeneError,
          "native v6 initializer not found: " & GeneModuleInitV6Symbol)
      let moduleScope = newScope(parentScope)
      moduleScope.moduleRoot = true
      moduleScope.moduleBase = nil
      moduleScope.moduleStatic = true
      moduleEnvironment = geneNewManagedEnvironment(domain, moduleScope)
      var bytes: array[512, uint8]
      var diagnostic = GeneOutBytesV6(data: addr bytes[0],
                                      capacity: csize_t(bytes.len))
      let initializer = cast[GeneModuleInitV6Proc](symbol)
      let code = initializer(addr domain.v6Api, moduleEnvironment.root.id,
                             addr diagnostic)
      if code != 0:
        let count = if diagnostic.required > csize_t(bytes.len): bytes.len
                    else: int(diagnostic.required)
        var message = "native v6 initializer returned " & $code
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
    except GeneError as e:
      result.status = gsError
      result.message = e.msg
    except GenePanic as e:
      result.status = gsPanic
      result.message = e.msg
    finally:
      if moduleEnvironment != nil:
        geneManagedEnvironmentRelease(moduleEnvironment)

proc geneManagedClose*(domain: GeneManagedDomain): bool =
  domain.requireDomain()
  if currentEventLane() != domain.rootLane:
    raise newException(GeneError, "managed native close requires the root lane")
  acquire(domain.lock)
  try:
    domain.closed = true
    result = domain.roots.len == 0 and domain.borrows == 0 and
             domain.producers == 0
  finally:
    release(domain.lock)

proc geneManagedStats*(domain: GeneManagedDomain):
    tuple[roots, borrows, producers: int, closed: bool, nextId: uint64] =
  domain.requireDomain()
  acquire(domain.lock)
  try:
    result = (domain.roots.len, domain.borrows, domain.producers,
              domain.closed, domain.nextId)
  finally:
    release(domain.lock)
