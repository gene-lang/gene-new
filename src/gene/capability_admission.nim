## Included by capabilities.nim. Independent rows are never pooled for an
## admission proof. Bounds contain predicates; root rows retain issued grants.

proc mintPolicyGrant*(provider: CapabilityProvider,
                      policy: CapabilityPolicyEntry): CapabilityGrant =
  if provider == nil or provider.registry == nil or policy == nil or
      provider.registry.providerFor(policy.capabilityType) != provider:
    raise newException(CapabilityError,
      "normalized root grant requires its admitted owning provider")
  result = provider.mintRootGrant(policy.capabilityType, policy.canonicalKey)
  result.normalizedPolicy = policy

proc normalizedPolicy*(grant: CapabilityGrant): CapabilityPolicyEntry =
  if grant == nil or grant.normalizedPolicy == nil:
    raise newException(CapabilityError,
      "grant does not implement the normalized capability policy contract")
  grant.normalizedPolicy

method initializeCapabilityGrant*(provider: CapabilityProvider,
    policy: CapabilityPolicyEntry): CapabilityGrant {.base.} =
  raise newException(CapabilityError,
    "provider has no startup grant initialization contract")

method releaseCapabilityGrant*(provider: CapabilityProvider,
    grant: CapabilityGrant) {.base.} =
  provider.revoke(grant)

proc canonicalizeAuthorityRow(row: CapabilityAuthorityRow) =
  row.authorityEntries.sort(proc(a, b: CapabilityAuthorityEntry): int =
    result = cmp(a.policy.canonicalKey, b.policy.canonicalKey)
    if result == 0 and a.grant != nil and b.grant != nil:
      result = cmp(a.grant.semanticKey, b.grant.semanticKey))
  row.authorityKey = $row.authorityCatalog & ":" &
    (if row.rootRow: "grants:" else: "bound:")
  var previous = ""
  var entries: seq[CapabilityAuthorityEntry]
  for entry in row.authorityEntries:
    let key = if row.rootRow: entry.grant.semanticKey else: entry.policy.canonicalKey
    if entries.len == 0 or key != previous:
      entries.add entry
      row.authorityKey.add $key.len & ":" & key
      previous = key
  row.authorityEntries = entries

proc newCapabilityAuthorityRow*(registry: CapabilityRegistry,
    grants: openArray[CapabilityGrant]): CapabilityAuthorityRow =
  if registry == nil or not registry.frozen:
    raise newException(CapabilityError, "authority requires an admitted catalog")
  result = CapabilityAuthorityRow(authorityCatalog: registry.registryId, rootRow: true)
  for grant in grants:
    if not grant.belongsTo(registry):
      raise newException(CapabilityError, "authority row contains a foreign grant")
    let policy = grant.normalizedPolicy
    if policy.capabilityType != grant.capabilityType:
      raise newException(CapabilityError, "grant policy identity does not match")
    # Retain revoked references too: revocation changes validity, not domain
    # identity. Admission and operation guards observe current validity.
    result.authorityEntries.add CapabilityAuthorityEntry(policy: policy, grant: grant)
  result.canonicalizeAuthorityRow()

proc capabilitySelectionRow*(registry: CapabilityRegistry,
    row: CapabilitySpecRow, use: CapabilityUse): CapabilityAuthorityRow =
  registry.validateUse(row, use)
  result = CapabilityAuthorityRow(authorityCatalog: registry.registryId)
  for entry in row.normalizedEntries:
    result.authorityEntries.add CapabilityAuthorityEntry(policy: entry.normalized)
  result.canonicalizeAuthorityRow()

proc canonicalKey*(row: CapabilityAuthorityRow): string =
  if row == nil:
    raise newException(CapabilityError, "nil capability authority row")
  row.authorityKey

proc validateAuthorityRows(registry: CapabilityRegistry,
                           rows: openArray[CapabilityAuthorityRow]) =
  if registry == nil or not registry.frozen:
    raise newException(CapabilityError, "authority requires a frozen catalog")
  var hasRoot = false
  for row in rows:
    if row == nil or row.authorityCatalog != registry.registryId:
      raise newException(CapabilityError, "foreign or nil capability authority row")
    hasRoot = hasRoot or row.rootRow
  if not hasRoot:
    raise newException(CapabilityError,
      "specification bounds cannot establish root capability authority")

proc failureScope*(outcome: CapabilityRequirementResult): CapabilityFailureScope =
  if outcome.failure == nil: cfsShared else: outcome.failure.scope

proc requirementFailure(error: ref CatchableError,
                         request: CapabilityPolicyEntry): CapabilityRequirementResult =
  var failure: ref CapabilityProviderFailure
  if error of CapabilityProviderFailure:
    failure = cast[ref CapabilityProviderFailure](error)
  else:
    failure = newException(CapabilityProviderFailure, "capability admission provider failed")
    failure.scope = cfsShared
    failure.parent = error
  CapabilityRequirementResult(status: caProviderFailure, authorityRow: -1,
    alternative: request, failure: failure)

proc requirementRank(outcome: CapabilityRequirementResult): int =
  case outcome.status
  of caMatched: 0
  of caCannotProve: 1
  of caProviderFailure: (if outcome.failureScope == cfsShared: 4 else: 2)
  of caUnmatched: 3

proc combineRequirements(left, right: CapabilityRequirementResult): CapabilityRequirementResult =
  if right.requirementRank > left.requirementRank: right else: left

proc matchCompleteEntry(registry: CapabilityRegistry, row: CapabilityAuthorityRow,
                        request: CapabilityPolicyEntry,
                        budget: var CapabilityProofBudget): CapabilityRequirementResult =
  var failed: seq[string]
  var unproved: seq[string]
  var matched = false
  var failure = CapabilityRequirementResult(status: caMatched)
  for candidate in row.authorityEntries:
    if candidate.policy.capabilityType != request.capabilityType and
        candidate.policy.capabilityType.id notin
          registry.entailmentClosure.getOrDefault(request.capabilityType.id):
      continue
    try:
      if candidate.grant != nil and not candidate.grant.isValid:
        continue
      let available =
        if candidate.grant == nil: candidate.policy
        else: candidate.grant.provider.availableCapabilityPolicy(candidate.grant)
      if available == nil or available.capabilityType != candidate.policy.capabilityType:
        raise newException(CapabilityError, "provider changed live policy identity")
      let comparison = registry.compareCapabilityEntries(available, request, budget)
      case comparison.status
      of ccCovered: matched = true
      of ccNotCovered: failed.add comparison.failedFields
      of ccCannotProve: unproved.add comparison.unprovedFields
    except CatchableError as error:
      failure = combineRequirements(failure, requirementFailure(error, request))
  if failure.status == caProviderFailure and failure.failureScope == cfsShared:
    return failure
  if matched:
    return CapabilityRequirementResult(status: caMatched, authorityRow: -1)
  if failure.status == caProviderFailure:
    return failure
  CapabilityRequirementResult(
    status: if unproved.len > 0: caCannotProve else: caUnmatched,
    failedFields: failed, unprovedFields: unproved, alternative: request)

proc matchCapabilityRow*(registry: CapabilityRegistry, row: CapabilityAuthorityRow,
                        request: CapabilityPolicyEntry,
                        budget: var CapabilityProofBudget): CapabilityRequirementResult =
  if row == nil or row.authorityCatalog != registry.identity:
    raise newException(CapabilityError, "foreign or nil capability authority row")
  # Normalization has already validated all metadata. An explicit empty
  # predicate has no operation demand, so it does not inspect live resources.
  if request.body.kind == cckEmpty:
    return CapabilityRequirementResult(status: caMatched, authorityRow: -1)
  for field in request.fields:
    if field.constraint.kind == cckEmpty:
      return CapabilityRequirementResult(status: caMatched, authorityRow: -1)
  result = registry.matchCompleteEntry(row, request, budget)
  if result.status == caMatched:
    return
  if result.status == caProviderFailure and result.failureScope == cfsShared:
    return
  let provider = registry.providerFor(request.capabilityType)
  var decomposition: CapabilityAlternativeResult
  try:
    decomposition = provider.capabilityAlternatives(request, budget)
  except CatchableError as error:
    return requirementFailure(error, request)
  if not decomposition.complete:
    if result.status != caProviderFailure: result.status = caCannotProve
    result.unprovedFields.add "alternative decomposition"
    return
  if decomposition.entries.len == 1 and
      decomposition.entries[0].canonicalKey == request.canonicalKey:
    return
  var combined = CapabilityRequirementResult(status: caMatched, authorityRow: -1)
  for alternative in decomposition.entries:
    if alternative == nil or alternative.capabilityType != request.capabilityType:
      raise newException(CapabilityError,
        "provider returned a foreign admission alternative")
    let matched = registry.matchCompleteEntry(row, alternative, budget)
    combined = combineRequirements(combined, matched)
  result = combined

proc checkCapabilityRequirements*(registry: CapabilityRegistry,
    authority: openArray[CapabilityAuthorityRow], request: CapabilitySpecRow,
    budget: var CapabilityProofBudget): CapabilityRequirementReport =
  registry.validateAuthorityRows(authority)
  registry.validateUse(request, cuRequest)
  result.admitted = true
  for requested in request.normalizedEntries:
    var combined = CapabilityRequirementResult(status: caMatched, authorityRow: -1)
    for index, row in authority:
      var matched = registry.matchCapabilityRow(row, requested.normalized, budget)
      matched.authorityRow = index
      combined = combineRequirements(combined, matched)
    combined.optional = requested.optionalValue
    combined.authoredIndex = requested.authoredIndexValue
    if combined.status != caMatched and not combined.optional:
      result.admitted = false
    result.entries.add combined

proc checkCapabilityRequirements*(registry: CapabilityRegistry,
    authority: openArray[CapabilityAuthorityRow], request: CapabilitySpecRow):
    CapabilityRequirementReport =
  var budget = newCapabilityProofBudget()
  registry.checkCapabilityRequirements(authority, request, budget)
