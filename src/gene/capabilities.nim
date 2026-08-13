## Trusted capability-provider seam and immutable authority primitives.
##
## Gene source can construct CapabilitySpec values, but only an admitted
## CapabilityProvider can construct CapabilityGrant values. The VM propagates
## grants through CapabilityContext rather than exposing them as Gene Values.

import std/[algorithm, atomics, locks, options, strutils, tables]

const
  MaxCapabilityGrantCacheEntries* = 4096
  MaxCapabilityContextInternEntries* = 4096

type
  CapabilityError* = object of CatchableError

  CapabilitySubsumption* = enum
    csUnknown
    csNo
    csYes

  CapabilityValidity* = object
    semanticKey*: string
    current*: bool
    dependencyCount*: int

  CapabilityType* = object
    registryId: uint64
    id: uint32
    providerId: uint32
    qualifiedName: string
    facadeIdentity: string
    schemaHash: string

  CapabilityArgKind* = enum
    cakNil
    cakBool
    cakInt
    cakString
    cakSymbol
    cakList
    cakMap

  CapabilityArg* = object
    case kind*: CapabilityArgKind
    of cakNil:
      discard
    of cakBool:
      boolValue*: bool
    of cakInt:
      intValue*: int64
    of cakString:
      stringValue*: string
    of cakSymbol:
      symbolValue*: string
    of cakList:
      listValue*: seq[CapabilityArg]
    of cakMap:
      mapValue*: seq[CapabilityNamedArg]

  CapabilityNamedArg* = object
    name*: string
    value*: CapabilityArg

  CapabilitySpec* = object
    capabilityType*: CapabilityType
    positional*: seq[CapabilityArg]
    named*: seq[CapabilityNamedArg]

  CapabilityTemplateArgKind* = enum
    ctakLiteral
    ctakParameter

  CapabilityTemplateArg* = object
    case kind*: CapabilityTemplateArgKind
    of ctakLiteral:
      literal*: CapabilityArg
    of ctakParameter:
      parameterSlot*: int
      parameterName*: string

  CapabilityTemplateNamedArg* = object
    name*: string
    value*: CapabilityTemplateArg

  CapabilitySelectorKind* = enum
    cskExact
    cskNamespace
    cskAll

  CapabilitySelectorTemplate* = object
    kind*: CapabilitySelectorKind
    typeName*: string
    namespaceName*: string
    positional*: seq[CapabilityTemplateArg]
    named*: seq[CapabilityTemplateNamedArg]
    optional*: bool

  CapabilityRowKind* = enum
    crkInherit
    crkSelect

  CapabilityRow* = object
    ## Compiler-normalized declaration. `capabilities_mode` never appears in
    ## runtime data: omissions are rewritten to either inherit or an explicit
    ## empty selection before a proto/chunk is emitted.
    kind*: CapabilityRowKind
    selectors*: seq[CapabilitySelectorTemplate]

  CapabilityPresenceEntry* = object
    spec*: CapabilitySpec
    available*: bool

  CapabilityPresence* = ref object
    ## Exact selectors evaluated at one declaration boundary. Presence queries
    ## consult this record and never resolve against a parent context.
    entries*: seq[CapabilityPresenceEntry]

  CapabilityTransition* = object
    context*: CapabilityContext
    presence*: CapabilityPresence

  CapabilityRegistry* = ref object
    registryId: uint64
    frozen: bool
    nextProviderId: uint32
    nextTypeId: uint32
    providers: Table[string, CapabilityProvider]
    types: Table[string, CapabilityType]
    sourcesByTarget: Table[uint32, seq[uint32]]
    targetsBySource: Table[uint32, seq[uint32]]
    identityLock: Lock
    nextGrantId: uint64
    nextContextId: uint64
    epoch: Atomic[uint64]
    contexts: Table[string, CapabilityContext]
    providersById: seq[CapabilityProvider]

  CapabilityProvider* = ref object of RootObj
    registry: CapabilityRegistry
    providerId: uint32
    providerName: string
    grantCacheLock: Lock
    grantCache: Table[string, CapabilityGrant]

  RevocationToken = ref object
    semanticId: uint64
    generation: Atomic[uint64]

  RevocationDependency = object
    token: RevocationToken
    generation: uint64

  CapabilityGrant* = ref object
    provider: CapabilityProvider
    capabilityType*: CapabilityType
    scope*: string
    resolutionBase: string
    ## Stable host-side anchor used by provider adapters. Selector-relative
    ## resolution may advance `resolutionBase`, but a derivative must retain
    ## the root handle lineage from which the host originally granted access.
    operationAnchor: string
    policy: seq[CapabilityNamedArg]
    parent: CapabilityGrant
    revocation: RevocationToken
    dependencies: seq[RevocationDependency]
    semanticIdentity: string
    semanticId: uint64

  CapabilityContext* = ref object
    items: seq[CapabilityGrant]
    semanticId: uint64
    registryId: uint64

proc newRevocationToken(registry: CapabilityRegistry): RevocationToken =
  new(result)
  acquire(registry.identityLock)
  result.semanticId = registry.nextGrantId
  inc registry.nextGrantId
  release(registry.identityLock)
  result.generation.store(1'u64)

var nextCapabilityRegistryId: Atomic[uint64]

proc ownDependency(token: RevocationToken): RevocationDependency {.inline.} =
  RevocationDependency(token: token, generation: token.generation.load())

proc `==`*(a, b: CapabilityType): bool {.inline.} =
  a.registryId == b.registryId and a.id == b.id and
    a.providerId == b.providerId

proc `==`*(a, b: CapabilityArg): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of cakNil:
    true
  of cakBool:
    a.boolValue == b.boolValue
  of cakInt:
    a.intValue == b.intValue
  of cakString:
    a.stringValue == b.stringValue
  of cakSymbol:
    a.symbolValue == b.symbolValue
  of cakList:
    if a.listValue.len != b.listValue.len:
      return false
    for i in 0 ..< a.listValue.len:
      if a.listValue[i] != b.listValue[i]:
        return false
    true
  of cakMap:
    if a.mapValue.len != b.mapValue.len:
      return false
    for i in 0 ..< a.mapValue.len:
      if a.mapValue[i].name != b.mapValue[i].name or
          a.mapValue[i].value != b.mapValue[i].value:
        return false
    true

proc `==`*(a, b: CapabilityNamedArg): bool {.inline.} =
  a.name == b.name and a.value == b.value

proc `==`*(a, b: CapabilitySpec): bool =
  if a.capabilityType != b.capabilityType or
      a.positional.len != b.positional.len or a.named.len != b.named.len:
    return false
  for i in 0 ..< a.positional.len:
    if a.positional[i] != b.positional[i]:
      return false
  for i in 0 ..< a.named.len:
    if a.named[i] != b.named[i]:
      return false
  true

proc isValid*(capabilityType: CapabilityType): bool {.inline.} =
  capabilityType.registryId != 0 and capabilityType.id != 0 and
    capabilityType.providerId != 0

proc name*(capabilityType: CapabilityType): lent string {.inline.} =
  capabilityType.qualifiedName

proc isGeneFacade*(capabilityType: CapabilityType): bool {.inline.} =
  capabilityType.facadeIdentity.len > 0

proc facadeIdentity*(capabilityType: CapabilityType): lent string {.inline.} =
  capabilityType.facadeIdentity

proc schemaHash*(capabilityType: CapabilityType): lent string {.inline.} =
  capabilityType.schemaHash

proc semanticKey*(grant: CapabilityGrant): string {.inline.} =
  if grant == nil: "" else: grant.semanticIdentity

proc semanticKey*(context: CapabilityContext): uint64 {.inline.} =
  if context == nil: 0'u64 else: context.semanticId

proc resolutionBase*(grant: CapabilityGrant): lent string =
  if grant == nil:
    raise newException(CapabilityError, "nil capability grant")
  grant.resolutionBase

proc operationAnchor*(grant: CapabilityGrant): lent string =
  if grant == nil:
    raise newException(CapabilityError, "nil capability grant")
  grant.operationAnchor

proc policy*(grant: CapabilityGrant): lent seq[CapabilityNamedArg] =
  if grant == nil:
    raise newException(CapabilityError, "nil capability grant")
  grant.policy

proc policyBool*(grant: CapabilityGrant, name: string,
                 default: bool): bool =
  if grant == nil:
    raise newException(CapabilityError, "nil capability grant")
  for item in grant.policy:
    if item.name == name:
      if item.value.kind != cakBool:
        raise newException(CapabilityError,
          "capability grant policy " & name & " is not boolean")
      return item.value.boolValue
  default

proc isOwnedBy*(grant: CapabilityGrant,
                provider: CapabilityProvider): bool {.inline.} =
  grant != nil and grant.provider == provider

proc belongsTo*(grant: CapabilityGrant,
                registry: CapabilityRegistry): bool {.inline.} =
  grant != nil and registry != nil and grant.provider != nil and
    grant.provider.registry == registry and
    grant.capabilityType.registryId == registry.registryId

proc capNil*(): CapabilityArg {.inline.} =
  CapabilityArg(kind: cakNil)

proc capBool*(value: bool): CapabilityArg {.inline.} =
  CapabilityArg(kind: cakBool, boolValue: value)

proc capInt*(value: int64): CapabilityArg {.inline.} =
  CapabilityArg(kind: cakInt, intValue: value)

proc capString*(value: string): CapabilityArg {.inline.} =
  CapabilityArg(kind: cakString, stringValue: value)

proc capSymbol*(value: string): CapabilityArg =
  if value.len == 0:
    raise newException(CapabilityError,
      "capability symbol must not be empty")
  CapabilityArg(kind: cakSymbol, symbolValue: value)

proc capList*(value: openArray[CapabilityArg]): CapabilityArg =
  CapabilityArg(kind: cakList, listValue: @value)

proc capMap*(value: openArray[CapabilityNamedArg]): CapabilityArg =
  result = CapabilityArg(kind: cakMap, mapValue: @value)
  result.mapValue.sort(proc(a, b: CapabilityNamedArg): int = cmp(a.name, b.name))
  for i in 1 ..< result.mapValue.len:
    if result.mapValue[i - 1].name == result.mapValue[i].name:
      raise newException(CapabilityError,
        "duplicate capability map key: " & result.mapValue[i].name)

proc capNamed*(name: string, value: CapabilityArg): CapabilityNamedArg =
  if name.len == 0:
    raise newException(CapabilityError,
      "capability specification property name must not be empty")
  CapabilityNamedArg(name: name, value: value)

proc capLiteral*(value: CapabilityArg): CapabilityTemplateArg {.inline.} =
  CapabilityTemplateArg(kind: ctakLiteral, literal: value)

proc capParameter*(slot: int, name: string): CapabilityTemplateArg =
  if name.len == 0:
    raise newException(CapabilityError,
      "capability parameter reference requires a name")
  CapabilityTemplateArg(kind: ctakParameter,
                        parameterSlot: slot,
                        parameterName: name)

proc inheritsCapabilities*(row: CapabilityRow): bool {.inline.} =
  row.kind == crkInherit

proc declaresCapabilities*(row: CapabilityRow): bool {.inline.} =
  row.kind == crkSelect

proc isStatic*(row: CapabilityRow): bool =
  for selector in row.selectors:
    for argument in selector.positional:
      if argument.kind == ctakParameter:
        return false
    for argument in selector.named:
      if argument.value.kind == ctakParameter:
        return false
  true

proc sameTemplateArg(a, b: CapabilityTemplateArg): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of ctakLiteral:
    a.literal == b.literal
  of ctakParameter:
    a.parameterSlot == b.parameterSlot

proc sameSelectorTemplate*(a, b: CapabilitySelectorTemplate): bool =
  if a.kind != b.kind or a.typeName != b.typeName or
      a.namespaceName != b.namespaceName or a.optional != b.optional or
      a.positional.len != b.positional.len or a.named.len != b.named.len:
    return false
  for i in 0 ..< a.positional.len:
    if not sameTemplateArg(a.positional[i], b.positional[i]):
      return false
  for i in 0 ..< a.named.len:
    if a.named[i].name != b.named[i].name or
        not sameTemplateArg(a.named[i].value, b.named[i].value):
      return false
  true

proc sameSelectorAuthority*(a, b: CapabilitySelectorTemplate): bool =
  var left = a
  var right = b
  left.optional = false
  right.optional = false
  sameSelectorTemplate(left, right)

proc sameCapabilityRow*(a, b: CapabilityRow): bool =
  if a.kind != b.kind or a.selectors.len != b.selectors.len:
    return false
  var matched = newSeq[bool](b.selectors.len)
  for selector in a.selectors:
    var found = false
    for i, candidate in b.selectors:
      if not matched[i] and sameSelectorTemplate(selector, candidate):
        matched[i] = true
        found = true
        break
    if not found:
      return false
  true

proc newCapabilitySpec*(capabilityType: CapabilityType,
                        positional: openArray[CapabilityArg] = [],
                        named: openArray[CapabilityNamedArg] = []): CapabilitySpec =
  if not capabilityType.isValid:
    raise newException(CapabilityError, "capability specification requires an admitted type")
  result.capabilityType = capabilityType
  result.positional = @positional
  result.named = @named
  result.named.sort(proc(a, b: CapabilityNamedArg): int = cmp(a.name, b.name))
  for i in 1 ..< result.named.len:
    if result.named[i - 1].name == result.named[i].name:
      raise newException(CapabilityError,
        "duplicate capability specification property: " & result.named[i].name)

proc positionalString*(spec: CapabilitySpec, index: int): lent string =
  if index < 0 or index >= spec.positional.len or
      spec.positional[index].kind != cakString:
    raise newException(CapabilityError,
      "capability specification argument " & $index & " must be a string")
  spec.positional[index].stringValue

proc newCapabilityRegistry*(): CapabilityRegistry =
  let registryId = nextCapabilityRegistryId.fetchAdd(1'u64) + 1'u64
  result = CapabilityRegistry(
    registryId: registryId,
    nextProviderId: 1,
    nextTypeId: 1,
    nextGrantId: 1,
    nextContextId: 1,
    providers: initTable[string, CapabilityProvider](),
    types: initTable[string, CapabilityType](),
    sourcesByTarget: initTable[uint32, seq[uint32]](),
    targetsBySource: initTable[uint32, seq[uint32]](),
    contexts: initTable[string, CapabilityContext](),
    providersById: @[CapabilityProvider(nil)])
  initLock(result.identityLock)
  result.epoch.store(1'u64)

proc capabilityEpoch*(registry: CapabilityRegistry): uint64 {.inline.} =
  if registry == nil: 0'u64 else: registry.epoch.load()

proc identity*(registry: CapabilityRegistry): uint64 {.inline.} =
  if registry == nil: 0'u64 else: registry.registryId

proc internedContextCount*(registry: CapabilityRegistry): int =
  if registry == nil:
    return 0
  acquire(registry.identityLock)
  result = registry.contexts.len
  release(registry.identityLock)

proc cachedGrantCount*(provider: CapabilityProvider): int =
  if provider == nil:
    return 0
  acquire(provider.grantCacheLock)
  result = provider.grantCache.len
  release(provider.grantCacheLock)

proc admitProvider*(registry: CapabilityRegistry, provider: CapabilityProvider,
                    name: string) =
  if registry == nil or provider == nil:
    raise newException(CapabilityError, "provider admission requires a registry and provider")
  if registry.frozen:
    raise newException(CapabilityError, "capability registry is frozen")
  if name.len == 0:
    raise newException(CapabilityError, "capability provider name must not be empty")
  if registry.providers.hasKey(name):
    raise newException(CapabilityError, "capability provider already admitted: " & name)
  if provider.registry != nil:
    raise newException(CapabilityError, "capability provider is already admitted")
  provider.registry = registry
  provider.providerId = registry.nextProviderId
  provider.providerName = name
  provider.grantCache = initTable[string, CapabilityGrant]()
  initLock(provider.grantCacheLock)
  inc registry.nextProviderId
  registry.providers[name] = provider
  registry.providersById.add provider

proc admitType*(registry: CapabilityRegistry, provider: CapabilityProvider,
                qualifiedName: string): CapabilityType =
  if registry == nil or provider == nil or provider.registry != registry:
    raise newException(CapabilityError,
      "capability type requires a provider admitted by this registry")
  if registry.frozen:
    raise newException(CapabilityError, "capability registry is frozen")
  if qualifiedName.len == 0:
    raise newException(CapabilityError, "capability type name must not be empty")
  if registry.types.hasKey(qualifiedName):
    raise newException(CapabilityError,
      "capability type already admitted: " & qualifiedName)
  result = CapabilityType(registryId: registry.registryId,
                          id: registry.nextTypeId,
                          providerId: provider.providerId,
                          qualifiedName: qualifiedName)
  inc registry.nextTypeId
  registry.types[qualifiedName] = result

proc admitGeneType*(registry: CapabilityRegistry,
                    provider: CapabilityProvider,
                    qualifiedName, facadeIdentity, schemaHash: string):
                    CapabilityType =
  if facadeIdentity.len == 0 or schemaHash.len == 0:
    raise newException(CapabilityError,
      "Gene capability type admission requires facade identity and schema hash")
  result = registry.admitType(provider, qualifiedName)
  result.facadeIdentity = facadeIdentity
  result.schemaHash = schemaHash
  registry.types[qualifiedName] = result

proc admitEntailment*(registry: CapabilityRegistry,
                      provider: CapabilityProvider,
                      sourceType, targetType: CapabilityType) =
  if registry == nil or provider == nil or provider.registry != registry:
    raise newException(CapabilityError,
      "capability entailment requires a provider admitted by this registry")
  if registry.frozen:
    raise newException(CapabilityError, "capability registry is frozen")
  if not sourceType.isValid or not targetType.isValid or
      sourceType.registryId != registry.registryId or
      targetType.registryId != registry.registryId:
    raise newException(CapabilityError,
      "capability entailment types must belong to this registry")
  if sourceType.providerId != provider.providerId or
      targetType.providerId != provider.providerId:
    raise newException(CapabilityError,
      "version 1 capability entailment must stay within one provider")

  var pending = @[targetType.id]
  var visited: seq[uint32]
  while pending.len > 0:
    let current = pending.pop()
    if current == sourceType.id:
      raise newException(CapabilityError,
        "capability entailment must be acyclic")
    if current in visited:
      continue
    visited.add current
    if registry.targetsBySource.hasKey(current):
      for next in registry.targetsBySource[current]:
        pending.add next
  if sourceType.id notin registry.sourcesByTarget.mgetOrPut(targetType.id, @[]):
    registry.sourcesByTarget.mgetOrPut(targetType.id, @[]).add sourceType.id
    registry.targetsBySource.mgetOrPut(sourceType.id, @[]).add targetType.id

proc freeze*(registry: CapabilityRegistry) =
  if registry == nil:
    raise newException(CapabilityError, "cannot freeze a nil capability registry")
  registry.frozen = true

proc capabilityType*(registry: CapabilityRegistry,
                     qualifiedName: string): CapabilityType =
  if registry == nil or not registry.frozen:
    raise newException(CapabilityError,
      "capability lookup requires a frozen registry")
  if not registry.types.hasKey(qualifiedName):
    raise newException(CapabilityError,
      "unknown capability type: " & qualifiedName)
  registry.types[qualifiedName]

proc capabilityTypes*(registry: CapabilityRegistry): seq[CapabilityType] =
  if registry == nil or not registry.frozen:
    raise newException(CapabilityError,
      "capability type enumeration requires a frozen registry")
  var names: seq[string]
  for name in registry.types.keys:
    names.add name
  names.sort()
  for name in names:
    result.add registry.types[name]

proc providerFor*(registry: CapabilityRegistry,
                  capabilityType: CapabilityType): CapabilityProvider =
  if registry == nil or capabilityType.registryId != registry.registryId or
      capabilityType.providerId == 0 or
      int(capabilityType.providerId) >= registry.providersById.len:
    raise newException(CapabilityError,
      "capability type does not belong to this registry")
  registry.providersById[int(capabilityType.providerId)]

proc name*(provider: CapabilityProvider): lent string =
  if provider == nil:
    raise newException(CapabilityError, "nil capability provider")
  provider.providerName

proc namespaceName*(capabilityType: CapabilityType): string =
  let slash = capabilityType.qualifiedName.rfind('/')
  if slash <= 0: "" else: capabilityType.qualifiedName[0 ..< slash]

proc isValid*(grant: CapabilityGrant): bool

proc appendArgKey(key: var string, argument: CapabilityArg) =
  key.add $ord(argument.kind)
  key.add ':'
  case argument.kind
  of cakNil:
    discard
  of cakBool:
    key.add(if argument.boolValue: "1" else: "0")
  of cakInt:
    key.add $argument.intValue
  of cakString:
    key.add $argument.stringValue.len
    key.add ':'
    key.add argument.stringValue
  of cakSymbol:
    key.add $argument.symbolValue.len
    key.add ':'
    key.add argument.symbolValue
  of cakList:
    key.add '['
    for item in argument.listValue:
      key.appendArgKey(item)
      key.add ';'
    key.add ']'
  of cakMap:
    key.add '{'
    for item in argument.mapValue:
      key.add $item.name.len
      key.add ':'
      key.add item.name
      key.add '='
      key.appendArgKey(item.value)
      key.add ';'
    key.add '}'

proc policyKey(policy: openArray[CapabilityNamedArg]): string =
  for item in policy:
    result.add $item.name.len
    result.add ':'
    result.add item.name
    result.add '='
    result.appendArgKey(item.value)
    result.add ';'

proc canonicalKey*(spec: CapabilitySpec): string =
  result = $spec.capabilityType.registryId & ":" &
    $spec.capabilityType.id & "|p:"
  for argument in spec.positional:
    result.appendArgKey(argument)
    result.add ';'
  result.add "|n:"
  result.add policyKey(spec.named)

proc stableHash64(value: string): uint64 =
  result = 1469598103934665603'u64
  for character in value:
    result = (result xor uint64(ord(character))) * 1099511628211'u64
  if result == 0:
    result = 1

proc dependencyKey(dependencies: openArray[RevocationDependency]): string =
  var identities = newSeqOfCap[tuple[id, generation: uint64]](
    dependencies.len)
  for dependency in dependencies:
    identities.add (dependency.token.semanticId, dependency.generation)
  identities.sort(proc(a, b: tuple[id, generation: uint64]): int =
    result = cmp(a.id, b.id)
    if result == 0:
      result = cmp(a.generation, b.generation))
  for identity in identities:
    result.add $identity.id
    result.add ':'
    result.add $identity.generation
    result.add ';'

proc grantSemanticIdentity(provider: CapabilityProvider,
                           capabilityType: CapabilityType,
                           scope, resolutionBase, operationAnchor: string,
                           policy: openArray[CapabilityNamedArg],
                           dependencies: openArray[RevocationDependency]): string =
  $provider.registry.registryId & ":" & $provider.providerId &
    ":" & $capabilityType.id & ":" & $scope.len & ":" & scope &
    ":" & $resolutionBase.len & ":" & resolutionBase &
    ":" & $operationAnchor.len & ":" & operationAnchor & ":" &
    policyKey(policy) & ":" & dependencyKey(dependencies)

proc derivationKey(parent: CapabilityGrant, capabilityType: CapabilityType,
                   scope: string): string =
  "d:" & $parent.semanticIdentity.len & ":" & parent.semanticIdentity &
    ":" & $capabilityType.id & ":" &
    $scope.len & ":" & scope

proc intersectionKey(left, right: CapabilityGrant,
                     capabilityType: CapabilityType,
                     scope: string): string =
  let first = min(left.semanticIdentity, right.semanticIdentity)
  let second = max(left.semanticIdentity, right.semanticIdentity)
  "i:" & $first.len & ":" & first & ":" & $second.len & ":" & second &
    ":" & $capabilityType.id & ":" & $scope.len & ":" & scope

proc mintRootGrant*(provider: CapabilityProvider,
                    capabilityType: CapabilityType,
                    scope: string): CapabilityGrant =
  if provider == nil or provider.registry == nil:
    raise newException(CapabilityError, "root grant requires an admitted provider")
  if capabilityType.providerId != provider.providerId:
    raise newException(CapabilityError,
      "provider cannot mint a grant for a type it does not own")
  let token = newRevocationToken(provider.registry)
  let dependencies = @[token.ownDependency]
  result = CapabilityGrant(provider: provider, capabilityType: capabilityType,
                           scope: scope, resolutionBase: scope,
                           operationAnchor: scope, revocation: token,
                           dependencies: dependencies)
  result.semanticIdentity = provider.grantSemanticIdentity(
    capabilityType, scope, scope, scope, [], dependencies)
  result.semanticId = stableHash64(result.semanticIdentity)

proc deriveGrant*(provider: CapabilityProvider, parent: CapabilityGrant,
                  capabilityType: CapabilityType,
                  scope: string, resolutionBase = "",
                  operationAnchor = "",
                  policy: openArray[CapabilityNamedArg] = []): CapabilityGrant =
  if provider == nil or parent == nil or parent.provider != provider:
    raise newException(CapabilityError,
      "provider can derive only from one of its own grants")
  if capabilityType.providerId != provider.providerId:
    raise newException(CapabilityError,
      "provider cannot derive a grant for a type it does not own")
  if not parent.isValid:
    raise newException(CapabilityError,
      "provider cannot derive from a revoked grant")
  let base =
    if resolutionBase.len > 0: resolutionBase
    else: parent.resolutionBase
  let anchor =
    if operationAnchor.len > 0: operationAnchor
    else: parent.operationAnchor
  let key = derivationKey(parent, capabilityType,
                          scope & "\x00" & base & "\x00" & anchor & "\x00" &
                          policyKey(policy))
  acquire(provider.grantCacheLock)
  if provider.grantCache.hasKey(key):
    result = provider.grantCache[key]
    if result.isValid:
      release(provider.grantCacheLock)
      return
    provider.grantCache.del(key)
  let token = newRevocationToken(provider.registry)
  result = CapabilityGrant(provider: provider, capabilityType: capabilityType,
                           scope: scope, resolutionBase: base,
                           operationAnchor: anchor,
                           policy: @policy,
                           parent: parent, revocation: token,
                           dependencies: parent.dependencies)
  result.dependencies.add token.ownDependency
  result.semanticIdentity = provider.grantSemanticIdentity(
    capabilityType, scope, base, anchor, policy, result.dependencies)
  result.semanticId = stableHash64(result.semanticIdentity)
  if provider.grantCache.len >= MaxCapabilityGrantCacheEntries:
    provider.grantCache.clear()
  provider.grantCache[key] = result
  release(provider.grantCacheLock)

proc intersectGrant*(provider: CapabilityProvider,
                     left, right: CapabilityGrant,
                     capabilityType: CapabilityType,
                     scope: string, resolutionBase = "",
                     operationAnchor = "",
                     policy: openArray[CapabilityNamedArg] = []): CapabilityGrant =
  if provider == nil or left == nil or right == nil or
      left.provider != provider or right.provider != provider:
    raise newException(CapabilityError,
      "provider can intersect only its own grants")
  if capabilityType.providerId != provider.providerId:
    raise newException(CapabilityError,
      "provider cannot intersect into a type it does not own")
  if not left.isValid or not right.isValid:
    raise newException(CapabilityError,
      "provider cannot intersect a revoked grant")
  let base =
    if resolutionBase.len > 0: resolutionBase
    elif left.resolutionBase.len > right.resolutionBase.len:
      left.resolutionBase
    elif right.resolutionBase.len > left.resolutionBase.len:
      right.resolutionBase
    elif left.resolutionBase <= right.resolutionBase:
      left.resolutionBase
    else:
      right.resolutionBase
  let anchor =
    if operationAnchor.len > 0: operationAnchor
    elif left.operationAnchor.len > right.operationAnchor.len:
      left.operationAnchor
    elif right.operationAnchor.len > left.operationAnchor.len:
      right.operationAnchor
    elif left.operationAnchor <= right.operationAnchor:
      left.operationAnchor
    else:
      right.operationAnchor
  let key = intersectionKey(left, right, capabilityType,
                            scope & "\x00" & base & "\x00" & anchor & "\x00" &
                            policyKey(policy))
  acquire(provider.grantCacheLock)
  if provider.grantCache.hasKey(key):
    result = provider.grantCache[key]
    if result.isValid:
      release(provider.grantCacheLock)
      return
    provider.grantCache.del(key)
  result = CapabilityGrant(provider: provider, capabilityType: capabilityType,
                           scope: scope, resolutionBase: base,
                           operationAnchor: anchor,
                           policy: @policy,
                           revocation: nil)
  for dependency in left.dependencies:
    result.dependencies.add dependency
  for dependency in right.dependencies:
    var duplicate = false
    for existing in result.dependencies:
      if existing.token == dependency.token and
          existing.generation == dependency.generation:
        duplicate = true
        break
    if not duplicate:
      result.dependencies.add dependency
  result.semanticIdentity = provider.grantSemanticIdentity(
    capabilityType, scope, base, anchor, policy, result.dependencies)
  result.semanticId = stableHash64(result.semanticIdentity)
  if provider.grantCache.len >= MaxCapabilityGrantCacheEntries:
    provider.grantCache.clear()
  provider.grantCache[key] = result
  release(provider.grantCacheLock)

proc lineageIsValid(grant: CapabilityGrant): bool =
  if grant == nil:
    return false
  for dependency in grant.dependencies:
    if dependency.token == nil or
        dependency.token.generation.load() != dependency.generation:
      return false
  true

method validity*(provider: CapabilityProvider,
                 grant: CapabilityGrant): CapabilityValidity {.base.} =
  discard provider
  discard grant
  raise newException(CapabilityError,
    "admitted capability provider does not implement validity")

proc sealedValidity*(grant: CapabilityGrant): CapabilityValidity =
  CapabilityValidity(
    semanticKey: if grant == nil: "" else: grant.semanticIdentity,
    current: grant.lineageIsValid,
    dependencyCount: if grant == nil: 0 else: grant.dependencies.len)

method subsumes*(provider: CapabilityProvider,
                 broader, narrower: CapabilitySpec): CapabilitySubsumption
                 {.base.} =
  discard provider
  discard broader
  discard narrower
  csUnknown

proc isValid*(grant: CapabilityGrant): bool =
  grant != nil and grant.provider != nil and grant.lineageIsValid and
    grant.provider.validity(grant).current

proc revoke*(provider: CapabilityProvider, grant: CapabilityGrant) =
  if provider == nil or grant == nil or grant.provider != provider:
    raise newException(CapabilityError,
      "provider can revoke only one of its own grants")
  if grant.revocation == nil:
    raise newException(CapabilityError,
      "an intersection grant is revoked through either source grant")
  discard grant.revocation.generation.fetchAdd(1'u64)
  discard provider.registry.epoch.fetchAdd(1'u64)

method resolve*(provider: CapabilityProvider, parent: CapabilityGrant,
                requested: CapabilitySpec): Option[CapabilityGrant] {.base.} =
  discard provider
  discard parent
  discard requested
  none(CapabilityGrant)

method intersect*(provider: CapabilityProvider,
                  left, right: openArray[CapabilityGrant]): seq[CapabilityGrant]
                  {.base.} =
  discard provider
  discard left
  discard right
  raise newException(CapabilityError,
    "admitted capability provider does not implement intersect")

let emptyCapabilityContext = CapabilityContext(items: @[], semanticId: 0,
                                               registryId: 0)

proc newCapabilityContext*(grants: openArray[CapabilityGrant] = []): CapabilityContext =
  if grants.len == 0:
    return emptyCapabilityContext
  var normalized = newSeqOfCap[CapabilityGrant](grants.len)
  var registry: CapabilityRegistry
  for grant in grants:
    if grant == nil or grant.provider == nil:
      raise newException(CapabilityError,
        "capability context cannot contain an unissued grant")
    if not grant.isValid:
      raise newException(CapabilityError,
        "capability context cannot contain a revoked grant")
    if registry == nil:
      registry = grant.provider.registry
    elif grant.provider.registry != registry:
      raise newException(CapabilityError,
        "capability context cannot combine grants from different registries")
    normalized.add grant
  normalized.sort(proc(a, b: CapabilityGrant): int =
    result = cmp(a.semanticId, b.semanticId)
    if result == 0:
      result = cmp(a.semanticIdentity, b.semanticIdentity))
  var deduplicated = newSeqOfCap[CapabilityGrant](normalized.len)
  var previous = ""
  var hasPrevious = false
  for grant in normalized:
    if not hasPrevious or grant.semanticIdentity != previous:
      deduplicated.add grant
      previous = grant.semanticIdentity
      hasPrevious = true
  var keyParts = newSeqOfCap[string](deduplicated.len)
  for grant in deduplicated:
    keyParts.add $grant.semanticIdentity.len & ":" & grant.semanticIdentity
  let key = keyParts.join(":")
  acquire(registry.identityLock)
  if registry.contexts.hasKey(key):
    result = registry.contexts[key]
  else:
    if registry.contexts.len >= MaxCapabilityContextInternEntries:
      registry.contexts.clear()
    result = CapabilityContext(items: deduplicated,
                               semanticId: registry.nextContextId,
                               registryId: registry.registryId)
    inc registry.nextContextId
    registry.contexts[key] = result
  release(registry.identityLock)

proc len*(context: CapabilityContext): int {.inline.} =
  if context == nil: 0 else: context.items.len

proc `[]`*(context: CapabilityContext, index: int): CapabilityGrant {.inline.} =
  if context == nil:
    raise newException(IndexDefect, "cannot index a nil capability context")
  context.items[index]

proc grants*(context: CapabilityContext): lent seq[CapabilityGrant] =
  if context == nil:
    raise newException(CapabilityError, "nil capability context")
  context.items

proc intersectContexts*(left, right: CapabilityContext): CapabilityContext =
  if left == nil or right == nil or left.len == 0 or right.len == 0:
    return newCapabilityContext()
  var leftByProvider = initTable[uint32, seq[CapabilityGrant]]()
  var rightByProvider = initTable[uint32, seq[CapabilityGrant]]()
  for grant in left.items:
    leftByProvider.mgetOrPut(grant.provider.providerId, @[]).add grant
  for grant in right.items:
    rightByProvider.mgetOrPut(grant.provider.providerId, @[]).add grant
  var intersections: seq[CapabilityGrant]
  var providerIds: seq[uint32]
  for providerId in leftByProvider.keys:
    if rightByProvider.hasKey(providerId):
      providerIds.add providerId
  providerIds.sort()
  for providerId in providerIds:
    let leftGrants = leftByProvider[providerId]
    if not rightByProvider.hasKey(providerId):
      continue
    let provider = leftGrants[0].provider
    let produced = provider.intersect(leftGrants, rightByProvider[providerId])
    for grant in produced:
      if grant == nil or grant.provider != provider:
        raise newException(CapabilityError,
          "capability provider returned a foreign or nil intersection grant")
      intersections.add grant
  newCapabilityContext(intersections)

proc resolveSelector*(registry: CapabilityRegistry, context: CapabilityContext,
                      requested: CapabilitySpec): seq[CapabilityGrant] =
  if registry == nil or not registry.frozen:
    raise newException(CapabilityError,
      "capability resolution requires a frozen registry")
  if requested.capabilityType.registryId != registry.registryId:
    raise newException(CapabilityError,
      "capability specification belongs to another registry")
  if context == nil:
    return
  var sourceTypeIds: seq[uint32]
  var pending = @[requested.capabilityType.id]
  while pending.len > 0:
    let targetId = pending.pop()
    if registry.sourcesByTarget.hasKey(targetId):
      for sourceId in registry.sourcesByTarget[targetId]:
        if sourceId != requested.capabilityType.id and
            sourceId notin sourceTypeIds:
          sourceTypeIds.add sourceId
          pending.add sourceId
  sourceTypeIds.sort()
  var candidateTypeIds = @[requested.capabilityType.id]
  candidateTypeIds.add sourceTypeIds
  for parent in context.items:
    if parent == nil or not parent.isValid or
        parent.capabilityType.registryId != registry.registryId or
        parent.capabilityType.id notin candidateTypeIds:
      continue
    let resolved = parent.provider.resolve(parent, requested)
    if resolved.isNone:
      continue
    let grant = resolved.get
    if grant == nil or grant.provider != parent.provider or
        grant.capabilityType != requested.capabilityType or not grant.isValid:
      raise newException(CapabilityError,
        "capability provider returned an invalid resolution grant")
    var duplicate = false
    for existing in result:
      if existing == grant:
        duplicate = true
        break
    if not duplicate:
      result.add grant

proc resolveProjection*(registry: CapabilityRegistry,
                        context: CapabilityContext,
                        namespace = ""): seq[CapabilityGrant] =
  ## Re-mint identity selections so even `*` and `fs/*` advance the checked
  ## ceiling instead of retaining an ancestor grant directly.
  if registry == nil or not registry.frozen:
    raise newException(CapabilityError,
      "capability projection requires a frozen registry")
  if context == nil:
    return
  for parent in context.items:
    if parent == nil or not parent.isValid or
        parent.capabilityType.registryId != registry.registryId:
      continue
    if namespace.len > 0 and parent.capabilityType.namespaceName != namespace:
      continue
    let requested = newCapabilitySpec(parent.capabilityType)
    let resolved = parent.provider.resolve(parent, requested)
    if resolved.isNone:
      raise newException(CapabilityError,
        "capability provider refused identity projection for " &
        parent.capabilityType.name)
    let grant = resolved.get
    if grant == nil or grant.provider != parent.provider or
        grant.capabilityType != parent.capabilityType or not grant.isValid:
      raise newException(CapabilityError,
        "capability provider returned an invalid projection grant")
    var duplicate = false
    for existing in result:
      if existing.semanticKey == grant.semanticKey:
        duplicate = true
        break
    if not duplicate:
      result.add grant
