## Included by capabilities.nim: catalog-owned normalization and complete-entry
## comparison. This shares the sealed registry rather than creating a second
## provider catalog or a source-level provider dispatch path.

const MaxNormalizedCapabilityEntries* = 1024

proc capabilityType*(entry: CapabilityPolicyEntry): CapabilityType =
  if entry == nil:
    raise newException(CapabilityError, "nil normalized capability entry")
  entry.policyType

proc body*(entry: CapabilityPolicyEntry): CapabilityConstraint =
  discard entry.capabilityType
  entry.policyBody

proc fields*(entry: CapabilityPolicyEntry): seq[CapabilityPolicyField] =
  discard entry.capabilityType
  for field in entry.policyFields:
    result.add field

proc canonicalKey*(entry: CapabilityPolicyEntry): string =
  discard entry.capabilityType
  entry.policyKey

proc field*(entry: CapabilityPolicyEntry, name: string): CapabilityConstraint =
  discard entry.capabilityType
  for field in entry.policyFields:
    if field.name == name:
      return field.constraint
  constraintAny()

proc newCapabilityPolicyEntry*(capabilityType: CapabilityType,
    body: CapabilityConstraint,
    fields: openArray[CapabilityPolicyField] = []): CapabilityPolicyEntry =
  if not capabilityType.isValid:
    raise newException(CapabilityError, "policy requires an admitted capability")
  var normalizedFields: seq[CapabilityPolicyField]
  var seen = initHashSet[string]()
  for field in fields:
    if field.name.len == 0 or field.name == "optional":
      raise newException(CapabilityError, "invalid normalized capability field")
    if seen.containsOrIncl(field.name):
      raise newException(CapabilityError,
        "duplicate normalized capability field: " & field.name)
    # Validate even fields that subsequently disappear as unrestricted.
    discard field.constraint.canonicalKey
    if field.constraint.kind != cckAny:
      normalizedFields.add field
  normalizedFields.sort(proc(a, b: CapabilityPolicyField): int =
    cmp(a.name, b.name))
  var key = $capabilityType.registryId & "/" & $capabilityType.id & ":" &
    $body.canonicalKey.len & ":" & body.canonicalKey
  for field in normalizedFields:
    key.add "|" & $field.name.len & ":" & field.name & "=" &
      $field.constraint.canonicalKey.len & ":" & field.constraint.canonicalKey
  CapabilityPolicyEntry(policyType: capabilityType, policyBody: body,
    policyFields: normalizedFields, policyKey: key)

method normalizeCapabilityEntry*(provider: CapabilityProvider,
    capabilityType: CapabilityType, literal: CapabilityEntryLiteral,
    source: CapabilitySourceContext): CapabilityPolicyEntry {.base.} =
  discard provider
  discard capabilityType
  discard literal
  discard source
  raise newException(CapabilityError,
    "capability provider does not implement the normalized policy contract")

method supportsCapabilityPolicies*(provider: CapabilityProvider,
    capabilityType: CapabilityType): bool {.base.} =
  ## Built-in legacy identities can remain internal during migration without
  ## appearing in the normalized catalog or its namespace expansion.
  true

proc policyCapabilityTypes*(registry: CapabilityRegistry): seq[CapabilityType] =
  for capabilityType in registry.capabilityTypes():
    if registry.providerFor(capabilityType).supportsCapabilityPolicies(capabilityType):
      result.add capabilityType

proc emptyPolicy*(entry: CapabilityPolicyEntry): bool =
  if entry.body.kind == cckEmpty: return true
  for field in entry.fields:
    if field.constraint.kind == cckEmpty: return true

proc intersectSameCapabilityPolicies*(left, right: CapabilityPolicyEntry,
    budget: var CapabilityProofBudget): CapabilityPolicyEntry =
  if left.capabilityType != right.capabilityType:
    raise newException(CapabilityError, "policy intersection requires the same identity")
  var names = initHashSet[string]()
  for field in left.fields: names.incl field.name
  for field in right.fields: names.incl field.name
  var fields: seq[CapabilityPolicyField]
  for name in names:
    fields.add CapabilityPolicyField(name: name,
      constraint: constraintIntersection([left.field(name), right.field(name)], budget))
  newCapabilityPolicyEntry(left.capabilityType,
    constraintIntersection([left.body, right.body], budget), fields)

method intersectStartupPolicies*(provider: CapabilityProvider,
    left, right: CapabilityPolicyEntry, budget: var CapabilityProofBudget):
    seq[CapabilityPolicyEntry] {.base.} =
  if left.capabilityType != right.capabilityType:
    raise newException(CapabilityError,
      "provider has no cross-identity startup intersection contract")
  let entry = intersectSameCapabilityPolicies(left, right, budget)
  if not entry.emptyPolicy: result.add entry

method translateCapabilityPolicy*(provider: CapabilityProvider,
    entry: CapabilityPolicyEntry, target: CapabilityType):
    Option[CapabilityPolicyEntry] {.base.} =
  discard provider
  if entry.capabilityType == target: some(entry)
  else: none(CapabilityPolicyEntry)

method capabilityAlternatives*(provider: CapabilityProvider,
    entry: CapabilityPolicyEntry, budget: var CapabilityProofBudget):
    CapabilityAlternativeResult {.base.} =
  discard provider
  discard budget.remaining
  # Default is indivisible. A provider must explicitly declare a sound split.
  CapabilityAlternativeResult(complete: true, entries: @[entry])

method availableCapabilityPolicy*(provider: CapabilityProvider,
    grant: CapabilityGrant): CapabilityPolicyEntry {.base.} =
  ## A provider may narrow an issued entry to its currently usable resource
  ## portions. It must retain identity and never broaden the issued policy.
  discard provider
  if grant == nil or grant.normalizedPolicy == nil:
    raise newException(CapabilityError, "grant has no normalized policy")
  grant.normalizedPolicy

proc normalizeCapabilityRow*(registry: CapabilityRegistry,
    literal: CapabilityLiteralRow, use: CapabilityUse): CapabilitySpecRow =
  # Enumerating the fixed catalog also rejects a nil/unfrozen registry.
  let catalog = registry.policyCapabilityTypes()
  result = CapabilitySpecRow(catalogIdentity: registry.registryId,
                            normalizationSource: literal.source)
  for index, entry in literal.entries:
    if entry.hasOptional and use != cuRequest:
      raise newException(CapabilityError,
        "optional is allowed only in capability requests")
    var selected: seq[CapabilityType]
    if entry.name.endsWith("/*"):
      let namespace = entry.name[0 ..< entry.name.len - 2]
      for capabilityType in catalog:
        if capabilityType.namespaceName == namespace or
            capabilityType.namespaceName.startsWith(namespace & "/"):
          selected.add capabilityType
      if selected.len == 0:
        raise newException(CapabilityError,
          "unknown or empty capability namespace: " & entry.name)
    else:
      let capabilityType = registry.capabilityType(entry.name)
      if not registry.providerFor(capabilityType).supportsCapabilityPolicies(capabilityType):
        raise newException(CapabilityError,
          "capability identity is not admitted by this policy profile: " & entry.name)
      selected.add capabilityType
    for capabilityType in selected:
      if result.normalizedEntries.len >= MaxNormalizedCapabilityEntries:
        raise newException(CapabilityError,
          "normalized capability row expansion limit exceeded")
      var providerLiteral = entry
      providerLiteral.name = capabilityType.name
      providerLiteral.hasOptional = false
      providerLiteral.optional = false
      let provider = registry.providerFor(capabilityType)
      let normalized = provider.normalizeCapabilityEntry(
        capabilityType, providerLiteral, literal.source)
      if normalized == nil or normalized.capabilityType != capabilityType:
        raise newException(CapabilityError,
          "provider returned a foreign normalized capability entry")
      result.normalizedEntries.add CapabilityRequestEntry(
        normalized: normalized, optionalValue: entry.optional,
        optionalPresent: entry.hasOptional,
        authoredIndexValue: index, locationValue: entry.location)

proc validateCatalog*(registry: CapabilityRegistry, row: CapabilitySpecRow) =
  if registry == nil or row == nil or not registry.frozen or
      row.catalogIdentity != registry.registryId:
    raise newException(CapabilityError,
      "capability specification belongs to another or unavailable catalog")

proc validateUse*(registry: CapabilityRegistry, row: CapabilitySpecRow,
                  use: CapabilityUse) =
  registry.validateCatalog(row)
  if use != cuRequest:
    for entry in row.normalizedEntries:
      if entry.optionalPresent:
        raise newException(CapabilityError,
          "optional is allowed only in capability requests")

proc entries*(row: CapabilitySpecRow): seq[CapabilityRequestEntry] =
  if row == nil:
    raise newException(CapabilityError, "nil capability specification row")
  for entry in row.normalizedEntries:
    result.add entry

proc policy*(entry: CapabilityRequestEntry): CapabilityPolicyEntry =
  entry.normalized
proc optional*(entry: CapabilityRequestEntry): bool = entry.optionalValue
proc hasOptional*(entry: CapabilityRequestEntry): bool = entry.optionalPresent
proc authoredIndex*(entry: CapabilityRequestEntry): int = entry.authoredIndexValue
proc location*(entry: CapabilityRequestEntry): CapabilityLocation = entry.locationValue
proc source*(row: CapabilitySpecRow): CapabilitySourceContext =
  if row == nil:
    raise newException(CapabilityError, "nil capability specification row")
  row.normalizationSource
proc len*(row: CapabilitySpecRow): int =
  if row == nil: 0 else: row.normalizedEntries.len

proc compareCapabilityEntries*(registry: CapabilityRegistry,
    granted, requested: CapabilityPolicyEntry,
    budget: var CapabilityProofBudget): CapabilityEntryComparison =
  let provider = registry.providerFor(granted.capabilityType)
  discard registry.providerFor(requested.capabilityType)
  var covering = granted
  if granted.capabilityType != requested.capabilityType:
    let sources = registry.entailmentClosure.getOrDefault(
      requested.capabilityType.id)
    if granted.capabilityType.id notin sources:
      return CapabilityEntryComparison(status: ccNotCovered,
                                       failedFields: @["identity"])
    let translated = provider.translateCapabilityPolicy(
      granted, requested.capabilityType)
    if translated.isNone:
      return CapabilityEntryComparison(status: ccCannotProve,
                                       unprovedFields: @["identity mapping"])
    covering = translated.get
    if covering.capabilityType != requested.capabilityType:
      raise newException(CapabilityError,
        "provider returned an invalid capability implication mapping")
  template record(name, coverage: untyped) =
    case coverage
    of ccCovered: discard
    of ccNotCovered: result.failedFields.add name
    of ccCannotProve: result.unprovedFields.add name
  record("body", covering.body.covers(requested.body, budget))
  var names = initHashSet[string]()
  for field in covering.policyFields:
    names.incl field.name
  for field in requested.policyFields:
    names.incl field.name
  var orderedNames: seq[string]
  for name in names:
    orderedNames.add name
  orderedNames.sort()
  for name in orderedNames:
    record(name, covering.field(name).covers(requested.field(name), budget))
  result.status =
    if result.failedFields.len > 0: ccNotCovered
    elif result.unprovedFields.len > 0: ccCannotProve
    else: ccCovered

proc compareCapabilityEntries*(registry: CapabilityRegistry,
    granted, requested: CapabilityPolicyEntry): CapabilityEntryComparison =
  var budget = newCapabilityProofBudget()
  registry.compareCapabilityEntries(granted, requested, budget)

proc decomposeCapabilityEntry*(entry: CapabilityPolicyEntry,
    splitBody: bool, splitFields: openArray[string],
    budget: var CapabilityProofBudget): CapabilityAlternativeResult =
  ## The provider declares which dimensions genuinely denote alternatives.
  ## Every resulting entry retains all other constraints. No grants are merged.
  if entry.body.kind == cckEmpty:
    return CapabilityAlternativeResult(complete: true)
  for field in entry.policyFields:
    if field.constraint.kind == cckEmpty:
      return CapabilityAlternativeResult(complete: true)
  var dimensions: seq[tuple[name: string, alternatives: seq[CapabilityConstraint]]]
  if splitBody and entry.body.kind == cckAlternatives:
    dimensions.add ("", entry.body.operands)
  for name in splitFields:
    if entry.field(name).kind == cckAlternatives:
      dimensions.add (name, entry.field(name).operands)
  result.entries = @[entry]
  for dimension in dimensions:
    var expanded: seq[CapabilityPolicyEntry]
    for previous in result.entries:
      for alternative in dimension.alternatives:
        if budget.remaining <= 0 or expanded.len >= MaxNormalizedCapabilityEntries:
          return CapabilityAlternativeResult(complete: false)
        dec budget.remaining
        if dimension.name.len == 0:
          expanded.add newCapabilityPolicyEntry(entry.capabilityType,
            alternative, previous.fields)
        else:
          var fields = previous.fields
          var replaced = false
          for field in fields.mitems:
            if field.name == dimension.name:
              field.constraint = alternative
              replaced = true
          if not replaced:
            raise newException(CapabilityError,
              "capability decomposition lost its selected field")
          expanded.add newCapabilityPolicyEntry(entry.capabilityType,
            previous.body, fields)
    result.entries = expanded
  result.complete = true
