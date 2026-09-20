## Included by capabilities.nim. A normalized execution context is an exact
## intersection of independent authority rows, retaining live root references.

const
  MaxCapabilityAuthorityRows* = 128
  MaxCapabilityContextIdentityBytes* = 1_048_576

proc registryFor(context: CapabilityContext): CapabilityRegistry =
  if context.ownerRegistry != nil:
    return context.ownerRegistry
  for grant in context.items:
    return grant.provider.registry

proc internPolicyContext(registry: CapabilityRegistry,
    rows: openArray[CapabilityAuthorityRow]): CapabilityContext =
  registry.validateAuthorityRows(rows)
  var ordered = @rows
  ordered.sort(proc(a, b: CapabilityAuthorityRow): int =
    cmp(a.authorityKey, b.authorityKey))
  var unique: seq[CapabilityAuthorityRow]
  var grants: seq[CapabilityGrant]
  var grantKeys = initHashSet[string]()
  var key = "policy:" & $registry.registryId & ":"
  for row in ordered:
    if unique.len > 0 and unique[^1].authorityKey == row.authorityKey:
      continue
    unique.add row
    key.add $row.authorityKey.len & ":" & row.authorityKey
    if key.len > MaxCapabilityContextIdentityBytes:
      raise newException(CapabilityError, "capability context identity size limit exceeded")
    for entry in row.authorityEntries:
      if entry.grant != nil and not grantKeys.containsOrIncl(entry.grant.semanticKey):
        grants.add entry.grant
  if unique.len > MaxCapabilityAuthorityRows:
    raise newException(CapabilityError, "capability boundary count limit exceeded")
  grants.sort(proc(a, b: CapabilityGrant): int = cmp(a.semanticKey, b.semanticKey))
  acquire(registry.identityLock)
  try:
    if registry.contexts.hasKey(key):
      return registry.contexts[key]
    if registry.contexts.len >= MaxCapabilityContextInternEntries:
      registry.contexts.clear()
    result = CapabilityContext(items: grants, authorityRows: unique,
      domainIdentity: key, registryId: registry.registryId,
      semanticId: registry.nextContextId, ownerRegistry: registry)
    inc registry.nextContextId
    registry.contexts[key] = result
  finally:
    release(registry.identityLock)

proc newPolicyContext*(registry: CapabilityRegistry,
                       grants: openArray[CapabilityGrant]): CapabilityContext =
  registry.internPolicyContext([registry.newCapabilityAuthorityRow(grants)])

proc policyRows*(registry: CapabilityRegistry, context: CapabilityContext):
    seq[CapabilityAuthorityRow] =
  if not context.isPolicyContext:
    if context == nil or context.items.len == 0:
      return @[registry.newCapabilityAuthorityRow([])]
    raise newException(CapabilityError,
      "execution context has not migrated to normalized capability authority")
  if context.registryId != registry.identity:
    raise newException(CapabilityError, "execution context belongs to another catalog")
  for row in context.authorityRows:
    result.add row

proc domainKey*(context: CapabilityContext): string =
  if context == nil or (not context.isPolicyContext and context.items.len == 0):
    return "empty"
  if not context.isPolicyContext:
    raise newException(CapabilityError,
      "stable authority domains require normalized capability contexts")
  context.domainIdentity

proc intersectPolicyContexts(left, right: CapabilityContext): CapabilityContext =
  let registry = if left.isPolicyContext: left.registryFor else: right.registryFor
  if left == nil or right == nil:
    return registry.newPolicyContext([])
  for context in [left, right]:
    if not context.isPolicyContext:
      if context.items.len == 0:
        return registry.newPolicyContext([])
      let normalized = if left.isPolicyContext: left else: right
      for row in normalized.authorityRows:
        if row.authorityEntries.len == 0:
          # An explicit empty selector already forbids every operation. An
          # unmigrated ceiling cannot add authority to this exact empty result.
          return normalized
      raise newException(CapabilityError,
        "cannot intersect normalized and unmigrated capability authority")
  if left.registryId != right.registryId:
    raise newException(CapabilityError, "capability contexts belong to different catalogs")
  registry.internPolicyContext(left.authorityRows & right.authorityRows)

proc attenuateCapabilities*(registry: CapabilityRegistry,
    context: CapabilityContext, bound: CapabilitySpecRow): CapabilityContext =
  registry.internPolicyContext(registry.policyRows(context) &
    @[registry.capabilitySelectionRow(bound, cuBound)])

proc requireCapabilities*(registry: CapabilityRegistry,
    context: CapabilityContext, request: CapabilitySpecRow): CapabilityContext =
  let rows = registry.policyRows(context)
  let report = registry.checkCapabilityRequirements(rows, request)
  if not report.admitted:
    var blocked = CapabilityRequirementResult(status: caMatched, authorityRow: -1)
    for entry in report.entries:
      if not entry.optional and entry.status != caMatched:
        blocked = combineRequirements(blocked, entry)
    let reason = if blocked.status == caProviderFailure: "provider failed requirement evaluation"
                 elif blocked.status == caCannotProve: "cannot prove requirement"
                 else: "unmatched requirement"
    var error = newException(CapabilityRequirementError,
      reason & " at entry " & $blocked.authoredIndex &
      ", authority row " & $blocked.authorityRow)
    error.report = report
    error.failedEntry = blocked
    error.parent = blocked.failure
    raise error
  registry.internPolicyContext(rows &
    @[registry.capabilitySelectionRow(request, cuRequest)])

proc checkCapabilityRequirements*(registry: CapabilityRegistry,
    context: CapabilityContext, request: CapabilitySpecRow): CapabilityRequirementReport =
  registry.checkCapabilityRequirements(registry.policyRows(context), request)

proc checkCapabilityOperation*(registry: CapabilityRegistry,
    context: CapabilityContext, operation: CapabilityOperation): CapabilityDecision =
  registry.checkCapabilityOperation(registry.policyRows(context), operation)

proc guardCapabilityOperation*(registry: CapabilityRegistry,
    context: CapabilityContext, operation: CapabilityOperation) =
  registry.guardCapabilityOperation(registry.policyRows(context), operation)
