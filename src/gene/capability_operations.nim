## Included by capabilities.nim. Advisory checks and effect guards use this
## evaluator; operation descriptors carry facts, never an authorization ticket.

from std/unicode import validateUtf8

proc checkedOperationScalar(fact: CapabilityScalar): CapabilityScalar =
  if fact.kind in {cskInvalid, cskWildcard}:
    raise newException(CapabilityOperationError,
      "operation facts cannot contain permission wildcards")
  result = fact
  if fact.kind == cskText:
    if fact.text.len > 65536 or validateUtf8(fact.text) != -1:
      raise newException(CapabilityOperationError,
        "concrete operation text is invalid or exceeds its size limit")
    result.stringMode = csmLiteral

proc newCapabilityOperation*(capabilityType: CapabilityType, kind: string,
    body: openArray[CapabilityScalar] = [],
    fields: openArray[CapabilityOperationField] = []): CapabilityOperation =
  if not capabilityType.isValid or kind.len == 0 or kind.len > 128 or
      body.len > 64 or fields.len > 32:
    raise newException(CapabilityOperationError, "invalid operation identity")
  result = CapabilityOperation(operationType: capabilityType, operationKind: kind)
  for fact in body:
    result.operationBody.add checkedOperationScalar(fact)
  var names = initHashSet[string]()
  for field in fields:
    if field.name.len == 0 or field.name.len > 128 or field.name == "optional" or
        names.containsOrIncl(field.name) or field.value.kind == cskWildcard:
      raise newException(CapabilityOperationError, "invalid concrete operation field")
    result.operationFields.add CapabilityOperationField(name: field.name,
      value: checkedOperationScalar(field.value))

proc capabilityType*(operation: CapabilityOperation): CapabilityType =
  if operation == nil:
    raise newException(CapabilityOperationError, "nil capability operation")
  operation.operationType

proc operationKind*(operation: CapabilityOperation): string =
  discard operation.capabilityType
  operation.operationKind

proc operationBody*(operation: CapabilityOperation): seq[CapabilityScalar] =
  discard operation.capabilityType
  for fact in operation.operationBody:
    result.add fact

proc operationFields*(operation: CapabilityOperation): seq[CapabilityOperationField] =
  discard operation.capabilityType
  for field in operation.operationFields:
    result.add field

proc operationField*(operation: CapabilityOperation, name: string): CapabilityScalar =
  discard operation.capabilityType
  for field in operation.operationFields:
    if field.name == name:
      return field.value
  raise newException(CapabilityOperationError,
    "missing concrete operation field: " & name)

proc withOperationState*(provider: CapabilityProvider, operation: CapabilityOperation,
    state: CapabilityOperationState): CapabilityOperation =
  ## Trusted adapter seam. No Gene value exposes this state or its ownership.
  ## Return a new descriptor rather than mutate a published advisory value.
  if provider == nil or state == nil or
      provider.registry.providerFor(operation.capabilityType) != provider or
      (state.operationStateOwner != nil and state.operationStateOwner != provider):
    raise newException(CapabilityOperationError, "invalid prepared operation owner")
  state.operationStateOwner = provider
  result = newCapabilityOperation(operation.capabilityType, operation.operationKind,
    operation.operationBody, operation.operationFields)
  result.preparedState = state

proc operationState*(provider: CapabilityProvider,
                     operation: CapabilityOperation): CapabilityOperationState =
  discard operation.capabilityType
  if operation.preparedState != nil and
      operation.preparedState.operationStateOwner != provider:
    raise newException(CapabilityOperationError, "foreign prepared operation state")
  operation.preparedState

proc allowed*(decision: CapabilityDecision): bool = decision.kind == cdAllow

method validateCapabilityOperation*(provider: CapabilityProvider,
    operation: CapabilityOperation) {.base.} =
  discard provider
  discard operation
  raise newException(CapabilityOperationError,
    "provider does not define concrete operation facts")

method validateSharedOperationState*(provider: CapabilityProvider,
    operation: CapabilityOperation) {.base.} =
  discard provider
  discard operation
  raise newException(CapabilityError,
    "provider does not define shared operation validation")

method authorizeCapabilityEntry*(provider: CapabilityProvider,
    grant: CapabilityGrant, policy: CapabilityPolicyEntry,
    operation: CapabilityOperation,
    budget: var CapabilityProofBudget): CapabilityDecision {.base.} =
  discard provider
  discard grant
  discard policy
  discard operation
  discard budget.remaining
  raise newException(CapabilityError,
    "provider does not implement concrete operation authorization")

proc matchCapabilityFacts*(policy: CapabilityPolicyEntry,
    body: CapabilityScalar, fields: openArray[CapabilityOperationField],
    budget: var CapabilityProofBudget): CapabilityDecision =
  ## Optional helper for providers with one scalar body and named scalar facts.
  ## The provider first validates completeness and chooses its actual body
  ## meaning; structured/compound bodies require their own whole-body matcher.
  var incomplete: ref CatchableError
  try:
    if not policy.body.matches(body, budget):
      return CapabilityDecision(kind: cdDeny, reason: "body")
  except CapabilityProofLimitError as error:
    incomplete = error
  for restriction in policy.policyFields:
    var found = false
    for field in fields:
      if field.name == restriction.name:
        found = true
        try:
          if not restriction.constraint.matches(field.value, budget):
            return CapabilityDecision(kind: cdDeny, reason: restriction.name)
        except CapabilityProofLimitError as error:
          incomplete = error
        break
    if not found:
      raise newException(CapabilityOperationError,
        "missing constrained concrete operation field: " & restriction.name)
  if incomplete != nil:
    return CapabilityDecision(kind: cdProviderFailure,
      reason: "matching_limit", failure: incomplete)
  CapabilityDecision(kind: cdAllow, authorityRow: -1)

proc authorizeCapabilityOperation*(registry: CapabilityRegistry,
    authority: openArray[CapabilityAuthorityRow],
    operation: CapabilityOperation): CapabilityDecision =
  registry.validateAuthorityRows(authority)
  let provider = registry.providerFor(operation.capabilityType)
  let startEpoch = registry.capabilityEpoch
  try:
    provider.validateCapabilityOperation(operation)
    provider.validateSharedOperationState(operation)
  except CapabilityOperationError:
    raise
  except CatchableError as error:
    return CapabilityDecision(kind: cdProviderFailure,
      reason: "shared_provider_failure", authorityRow: -1, failure: error)
  var rowFailure = CapabilityDecision(kind: cdAllow, authorityRow: -1)
  var rowDenial = CapabilityDecision(kind: cdAllow, authorityRow: -1)
  var sharedFailure: ref CatchableError
  for index, row in authority:
    var anyAllowed = false
    var failure: ref CatchableError
    var failureReason = ""
    for candidate in row.authorityEntries:
      var policy = candidate.policy
      if policy.capabilityType != operation.capabilityType and
          policy.capabilityType.id notin
            registry.entailmentClosure.getOrDefault(operation.capabilityType.id):
        continue
      try:
        if candidate.grant != nil:
          if not candidate.grant.isValid:
            continue
          policy = candidate.grant.provider.availableCapabilityPolicy(candidate.grant)
          if policy == nil or policy.capabilityType != candidate.policy.capabilityType:
            raise newException(CapabilityError, "provider changed live policy identity")
        if policy.capabilityType != operation.capabilityType:
          let translated = provider.translateCapabilityPolicy(policy,
            operation.capabilityType)
          if translated.isNone:
            raise newException(CapabilityError,
              "operation implication has no admitted constraint mapping")
          policy = translated.get
          if policy.capabilityType != operation.capabilityType:
            raise newException(CapabilityError, "invalid operation implication mapping")
        # Each independent complete entry gets the same work limit. One
        # expensive failing alternative cannot starve another complete proof.
        var budget = newCapabilityProofBudget()
        let decision = provider.authorizeCapabilityEntry(
          candidate.grant, policy, operation, budget)
        case decision.kind
        of cdAllow: anyAllowed = true
        of cdDeny: discard
        of cdProviderFailure:
          failureReason = if decision.reason.len > 0: decision.reason
                          else: "entry_provider_failure"
          failure = decision.failure
      except CapabilityOperationError:
        raise
      except CapabilityProviderFailure as error:
        if error.scope == cfsEntry:
          failure = error
          failureReason = "entry_provider_failure"
        else:
          sharedFailure = error
      except CatchableError as error:
        # Unexpected errors cannot be assumed isolated to one grant.
        sharedFailure = error
    if not anyAllowed:
      if failureReason.len > 0:
        rowFailure = CapabilityDecision(kind: cdProviderFailure,
          reason: failureReason, authorityRow: index, failure: failure)
      else:
        rowDenial = CapabilityDecision(kind: cdDeny,
          reason: "no_permitting_entry", authorityRow: index)
  # Evaluate every relevant entry before reducing, so an unexpected shared
  # failure cannot be hidden behind whichever allowing entry was visited first.
  if sharedFailure != nil:
    return CapabilityDecision(kind: cdProviderFailure,
      reason: "shared_provider_failure", authorityRow: -1, failure: sharedFailure)
  if rowDenial.kind == cdDeny:
    return rowDenial
  if rowFailure.kind == cdProviderFailure:
    return rowFailure
  if registry.capabilityEpoch != startEpoch:
    return CapabilityDecision(kind: cdProviderFailure,
      reason: "validity_changed_during_check", authorityRow: -1)
  CapabilityDecision(kind: cdAllow, authorityRow: -1)

proc checkCapabilityOperation*(registry: CapabilityRegistry,
    authority: openArray[CapabilityAuthorityRow],
    operation: CapabilityOperation): CapabilityDecision =
  registry.authorizeCapabilityOperation(authority, operation)

proc guardCapabilityOperation*(registry: CapabilityRegistry,
    authority: openArray[CapabilityAuthorityRow], operation: CapabilityOperation) =
  let decision = registry.authorizeCapabilityOperation(authority, operation)
  if not decision.allowed:
    var error = newException(CapabilityGuardError,
      "capability operation rejected: " & decision.reason)
    error.decision = decision
    if decision.failure != nil:
      error.parent = decision.failure
    raise error
