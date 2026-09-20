import std/[os, unittest]
import gene/capabilities

type PolicyTestProvider = ref object of CapabilityProvider
  readType, networkType, nominalType: CapabilityType
  sharedUnavailable: bool
  failingGrant, unexpectedFailureGrant: CapabilityGrant
  unavailableGrant, unexpectedAvailabilityGrant: CapabilityGrant

method availableCapabilityPolicy(provider: PolicyTestProvider,
    grant: CapabilityGrant): CapabilityPolicyEntry =
  if grant == provider.unavailableGrant:
    var error = newException(CapabilityProviderFailure, "isolated availability inspection failed")
    error.scope = cfsEntry
    error.parent = newException(IOError, "original availability cause")
    raise error
  if grant == provider.unexpectedAvailabilityGrant:
    raise newException(ValueError, "unexpected availability failure")
  grant.normalizedPolicy

method validity(provider: PolicyTestProvider,
                grant: CapabilityGrant): CapabilityValidity =
  discard provider
  grant.sealedValidity

method normalizeCapabilityEntry(provider: PolicyTestProvider,
    capabilityType: CapabilityType, literal: CapabilityEntryLiteral,
    source: CapabilitySourceContext): CapabilityPolicyEntry =
  if literal.hasOptional:
    raise newException(CapabilityError, "core metadata reached the provider")
  var body = constraintAny()
  var fields: seq[CapabilityPolicyField]
  if capabilityType == provider.nominalType:
    if literal.body.len > 0 or literal.properties.len > 0:
      raise newException(CapabilityError, "nominal provider accepts no fields")
  elif capabilityType == provider.readType:
    if literal.properties.len > 0:
      raise newException(CapabilityError, "unknown read property")
    if literal.body.len > 0:
      var roots: seq[CapabilityConstraint]
      for value in literal.body:
        case value.kind
        of cskWildcard: roots.add constraintAny()
        of cskText:
          if value.stringMode == csmPattern:
            raise newException(CapabilityError, "filesystem roots are literal")
          if not value.text.isAbsolute and source.baseDirectory.len == 0:
            raise newException(CapabilityError, "relative path needs a source base")
          roots.add constraintTree(
            if value.text.isAbsolute: value.text
            else: source.baseDirectory / value.text)
        else:
          raise newException(CapabilityError, "read roots must be strings")
      body = constraintAlternatives(roots)
  elif capabilityType == provider.networkType:
    if literal.body.len > 0:
      if literal.body.len != 1 or literal.body[0].kind != cskWildcard:
        raise newException(CapabilityError, "network test body is unrestricted")
    for property in literal.properties:
      if property.name notin ["hosts", "methods"]:
        raise newException(CapabilityError, "unknown network property")
      let values = if property.value.isList: property.value.items
                   else: @[property.value.scalar]
      var alternatives: seq[CapabilityConstraint]
      for value in values:
        if value.kind == cskWildcard:
          alternatives.add constraintAny()
        elif value.kind != cskText:
          raise newException(CapabilityError, "network fields must be strings")
        elif property.name == "hosts":
          alternatives.add constraintPattern(value.text,
            literal = value.stringMode == csmLiteral)
        else:
          if value.stringMode == csmPattern:
            raise newException(CapabilityError, "methods are exact")
          alternatives.add constraintExact(value)
      fields.add CapabilityPolicyField(name: property.name,
        constraint: constraintAlternatives(alternatives))
  else:
    raise newException(CapabilityError, "foreign test capability")
  newCapabilityPolicyEntry(capabilityType, body, fields)

method capabilityAlternatives(provider: PolicyTestProvider,
    entry: CapabilityPolicyEntry, budget: var CapabilityProofBudget):
    CapabilityAlternativeResult =
  if entry.capabilityType == provider.readType:
    decomposeCapabilityEntry(entry, true, [], budget)
  elif entry.capabilityType == provider.networkType:
    decomposeCapabilityEntry(entry, false, ["hosts", "methods"], budget)
  else:
    CapabilityAlternativeResult(complete: true, entries: @[entry])

method validateCapabilityOperation(provider: PolicyTestProvider,
    operation: CapabilityOperation) =
  if operation.capabilityType == provider.readType:
    if operation.operationKind != "read" or operation.operationBody.len != 1 or
        operation.operationBody[0].kind != cskText or
        not operation.operationBody[0].text.isAbsolute or
        operation.operationFields.len != 0:
      raise newException(CapabilityOperationError, "invalid read facts")
  elif operation.capabilityType == provider.networkType:
    if operation.operationKind != "request" or operation.operationBody.len != 0 or
        operation.operationFields.len != 2:
      raise newException(CapabilityOperationError, "invalid request facts")
    for name in ["hosts", "methods"]:
      if operation.operationField(name).kind != cskText:
        raise newException(CapabilityOperationError, "request fact must be text")
  elif operation.capabilityType == provider.nominalType:
    if operation.operationKind != "execute" or operation.operationBody.len != 0 or
        operation.operationFields.len != 0:
      raise newException(CapabilityOperationError, "invalid nominal facts")
  else:
    raise newException(CapabilityOperationError, "foreign test operation")

method validateSharedOperationState(provider: PolicyTestProvider,
    operation: CapabilityOperation) =
  discard operation
  if provider.sharedUnavailable:
    raise newException(CapabilityError, "shared test provider state is unavailable")

method authorizeCapabilityEntry(provider: PolicyTestProvider,
    grant: CapabilityGrant, policy: CapabilityPolicyEntry,
    operation: CapabilityOperation,
    budget: var CapabilityProofBudget): CapabilityDecision =
  if grant != nil and grant == provider.failingGrant:
    var error = newException(CapabilityProviderFailure, "isolated test grant failure")
    error.scope = cfsEntry
    raise error
  if grant != nil and grant == provider.unexpectedFailureGrant:
    raise newException(ValueError, "unexpected shared test state failure")
  let fact = if operation.operationBody.len == 1: operation.operationBody[0]
             else: capabilityBoolean(true)
  matchCapabilityFacts(policy, fact, operation.operationFields, budget)

proc policyTestCatalog(): tuple[registry: CapabilityRegistry,
                                provider: PolicyTestProvider] =
  result.registry = newCapabilityRegistry()
  result.provider = PolicyTestProvider()
  result.registry.admitProvider(result.provider, "policy/test")
  result.provider.readType = result.registry.admitType(result.provider, "demo/Read")
  result.provider.networkType = result.registry.admitType(result.provider, "demo/Network")
  result.provider.nominalType = result.registry.admitType(result.provider, "demo/Nominal")
  result.registry.admitCapabilityAlias("demo/network", result.provider.networkType)
  result.registry.freeze()

proc policyTestRow(registry: CapabilityRegistry, text: string,
                   use = cuRequest, base = "/workspace"): CapabilitySpecRow =
  registry.normalizeCapabilityRow(readCapabilityLiteral(text, use,
    CapabilitySourceContext(name: "test-policy", baseDirectory: base)), use)

suite "catalog-owned capability policy normalization":
  test "canonical names are case sensitive and aliases must be admitted":
    let (registry, provider) = policyTestCatalog()
    check registry.capabilityType("demo/network") == provider.networkType
    check registry.capabilityTypes.len == 3
    expect CapabilityError:
      discard registry.capabilityType("Demo/Network")
    let other = newCapabilityRegistry()
    let trusted = PolicyTestProvider()
    other.admitProvider(trusted, "other")
    for invalidName in ["Read", "Demo/Read", "demo/read", "demo//Read"]:
      expect CapabilityError:
        discard other.admitType(trusted, invalidName)

  test "normalization validates every entry, including optional and redundant":
    let (registry, _) = policyTestCatalog()
    for text in [
      "[(unknown/Missing ^^optional)]", "[(demo/Read 5 ^^optional)]",
      "[demo/Read (demo/Read ^unknown true)]",
      "[(demo/Network ^^optional ^unknown [])]",
      "[(demo/Read * 5)]"]:
      checkpoint text
      expect CapabilityError:
        discard registry.policyTestRow(text)

  test "namespace expansion is catalog based and validates every selected schema":
    let (registry, _) = policyTestCatalog()
    let selected = registry.policyTestRow("[(demo/* ^^optional)]")
    check selected.len == 3
    for entry in selected.entries:
      check entry.optional
      check entry.authoredIndex == 0
    for text in ["[(missing/* ^^optional)]", "[(demo/* \"/tmp\")]",
                 "[demo/Network/*]"]:
      expect CapabilityError:
        discard registry.policyTestRow(text)

  test "core optional metadata and receiving context survive normalization":
    let (registry, _) = policyTestCatalog()
    let row = registry.policyTestRow(
      "[(demo/Network ^optional false) (demo/Read ^^optional)]")
    check row.entries[0].hasOptional
    check not row.entries[0].optional
    check row.entries[1].optional
    expect CapabilityError:
      registry.validateUse(row, cuGrant)
    expect CapabilityError:
      registry.validateUse(row, cuBound)
    registry.validateUse(row, cuRequest)
    let (other, _) = policyTestCatalog()
    expect CapabilityError:
      other.validateCatalog(row)

  test "relative constraints use captured bases without filesystem inspection":
    let (registry, _) = policyTestCatalog()
    let relative = registry.policyTestRow("[(demo/Read \"data\")]").entries[0].policy
    let absolute = registry.policyTestRow(
      "[(demo/Read \"/workspace/data\")]").entries[0].policy
    check relative.canonicalKey == absolute.canonicalKey
    let different = registry.policyTestRow(
      "[(demo/Read \"data\")]", base = "/another").entries[0].policy
    check different.canonicalKey != relative.canonicalKey
    expect CapabilityError:
      discard registry.policyTestRow("[(demo/Read \"data\")]", base = "")

  test "whole entries compare every constraint without mixing fields":
    let (registry, _) = policyTestCatalog()
    let entries = registry.policyTestRow("""
[
  (demo/Network ^hosts ["a"] ^methods ["GET"])
  (demo/Network ^hosts ["b"] ^methods ["POST"])
  (demo/Network ^hosts ["a"] ^methods ["POST"])
  (demo/Network ^hosts ["a"] ^methods ["GET" "POST"])
]
""").entries
    check registry.compareCapabilityEntries(
      entries[0].policy, entries[2].policy).status == ccNotCovered
    check registry.compareCapabilityEntries(
      entries[1].policy, entries[2].policy).status == ccNotCovered
    check registry.compareCapabilityEntries(
      entries[0].policy, entries[3].policy).status == ccNotCovered

  test "a definite failed field wins over an inconclusive field proof":
    let (registry, _) = policyTestCatalog()
    let granted = registry.policyTestRow(
      "[(demo/Network ^hosts [\"a*b\"] ^methods [\"GET\"])]").entries[0].policy
    let requested = registry.policyTestRow(
      "[(demo/Network ^hosts [\"a*ab\"] ^methods [\"POST\"])]").entries[0].policy
    var budget = newCapabilityProofBudget(1)
    let comparison = registry.compareCapabilityEntries(granted, requested, budget)
    check comparison.status == ccNotCovered
    check "hosts" in comparison.unprovedFields
    check "methods" in comparison.failedFields

  test "provider-declared decomposition preserves complete cross products":
    let (registry, provider) = policyTestCatalog()
    let request = registry.policyTestRow("""
[(demo/Network ^hosts ["a" "b"] ^methods ["GET" "POST"])]
""").entries[0].policy
    var budget = newCapabilityProofBudget()
    let alternatives = provider.capabilityAlternatives(request, budget)
    check alternatives.complete
    check alternatives.entries.len == 4
    for host in ["a", "b", "c"]:
      for verb in ["GET", "POST", "DELETE"]:
        let allowed = request.field("hosts").matches(capabilityText(host)) and
          request.field("methods").matches(capabilityText(verb))
        var matched = false
        for entry in alternatives.entries:
          matched = matched or (entry.field("hosts").matches(capabilityText(host)) and
            entry.field("methods").matches(capabilityText(verb)))
        check matched == allowed
    var exhausted = newCapabilityProofBudget(1)
    check not provider.capabilityAlternatives(request, exhausted).complete

  test "empty alternative constraints decompose to the empty union":
    let (registry, provider) = policyTestCatalog()
    let empty = registry.policyTestRow(
      "[(demo/Network ^methods [])]").entries[0].policy
    var budget = newCapabilityProofBudget()
    let alternatives = provider.capabilityAlternatives(empty, budget)
    check alternatives.complete
    check alternatives.entries.len == 0

proc policyTestAuthority(registry: CapabilityRegistry, provider: PolicyTestProvider,
    text: string): tuple[row: CapabilityAuthorityRow, grants: seq[CapabilityGrant]] =
  let specs = registry.policyTestRow(text, cuGrant)
  for entry in specs.entries:
    result.grants.add provider.mintPolicyGrant(entry.policy)
  result.row = registry.newCapabilityAuthorityRow(result.grants)

suite "live complete-entry capability admission":
  test "independent roots collectively cover a grouped read request":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider,
      "[(demo/Read \"/one\") (demo/Read \"/two\")]")
    let request = registry.policyTestRow("[(demo/Read \"/one\" \"/two\")]")
    check registry.checkCapabilityRequirements([authority.row], request).admitted
    let missing = registry.policyTestRow("[(demo/Read \"/one\" \"/missing\")]")
    let rejected = registry.checkCapabilityRequirements([authority.row], missing)
    check not rejected.admitted
    check rejected.entries[0].status == caUnmatched
    check rejected.entries[0].alternative.body.matches(capabilityText("/missing"))

  test "separate method grants cover alternatives but do not mix host fields":
    let (registry, provider) = policyTestCatalog()
    let sameHost = registry.policyTestAuthority(provider, """
[(demo/Network ^hosts ["a"] ^methods ["GET"])
 (demo/Network ^hosts ["a"] ^methods ["POST"])]
""")
    let request = registry.policyTestRow(
      """[(demo/Network ^hosts ["a"] ^methods ["GET" "POST"])]""")
    check registry.checkCapabilityRequirements([sameHost.row], request).admitted
    let differentHosts = registry.policyTestAuthority(provider, """
[(demo/Network ^hosts ["a"] ^methods ["GET"])
 (demo/Network ^hosts ["b"] ^methods ["POST"])]
""")
    let crossProduct = registry.policyTestRow(
      """[(demo/Network ^hosts ["a" "b"] ^methods ["GET" "POST"])]""")
    check not registry.checkCapabilityRequirements(
      [differentHosts.row], crossProduct).admitted

  test "ceilings independently cover every requested alternative":
    let (registry, provider) = policyTestCatalog()
    let first = registry.policyTestAuthority(provider, "[(demo/Read \"/one\")]")
    let second = registry.policyTestAuthority(provider, "[(demo/Read \"/two\")]")
    let request = registry.policyTestRow("[(demo/Read \"/one\" \"/two\")]")
    check not registry.checkCapabilityRequirements([first.row, second.row], request).admitted
    let broad = registry.policyTestAuthority(provider, "[demo/Read]")
    let bound = registry.capabilitySelectionRow(
      registry.policyTestRow("[(demo/Read \"/one\")]", cuBound), cuBound)
    let report = registry.checkCapabilityRequirements([broad.row, bound], request)
    check not report.admitted
    check report.entries[0].authorityRow == 1

  test "optional broad selection does not impose unrestricted admission":
    let (registry, provider) = policyTestCatalog()
    let narrow = registry.policyTestAuthority(provider,
      """[(demo/Network ^hosts ["a"] ^methods ["GET"])]""")
    let mandatory = registry.policyTestRow("[demo/Network]")
    check not registry.checkCapabilityRequirements([narrow.row], mandatory).admitted
    let optional = registry.policyTestRow("[(demo/Network ^^optional)]")
    let report = registry.checkCapabilityRequirements([narrow.row], optional)
    check report.admitted
    check report.entries[0].optional
    check report.entries[0].status != caMatched
    let empty = registry.newCapabilityAuthorityRow([])
    check registry.checkCapabilityRequirements([empty], optional).admitted

  test "an optional broad entry never erases a mandatory narrow obligation":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider,
      """[(demo/Network ^hosts ["a"] ^methods ["GET"])]""")
    let request = registry.policyTestRow("""
[(demo/Network ^^optional) (demo/Network ^hosts ["a"] ^methods ["POST"])]
""")
    let report = registry.checkCapabilityRequirements([authority.row], request)
    check not report.admitted
    check report.entries.len == 2
    check report.entries[0].optional
    check not report.entries[1].optional

  test "revocation removes only the affected live alternative":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider,
      """[(demo/Read "/") (demo/Read "/tmp")]""")
    let narrow = registry.policyTestRow("""[(demo/Read "/tmp")]""")
    let outside = registry.policyTestRow("""[(demo/Read "/outside")]""")
    let identity = authority.row.canonicalKey
    check registry.checkCapabilityRequirements([authority.row], outside).admitted
    provider.revoke(authority.grants[0])
    check registry.checkCapabilityRequirements([authority.row], narrow).admitted
    check not registry.checkCapabilityRequirements([authority.row], outside).admitted
    check authority.row.canonicalKey == identity
    let reordered = registry.newCapabilityAuthorityRow([
      authority.grants[1], authority.grants[0]])
    check reordered.canonicalKey == identity
    provider.revoke(authority.grants[1])
    check not registry.checkCapabilityRequirements([authority.row], narrow).admitted

  test "bounds alone cannot mint root authority":
    let (registry, _) = policyTestCatalog()
    let request = registry.policyTestRow("[demo/Network]")
    let bound = registry.capabilitySelectionRow(request, cuBound)
    expect CapabilityError:
      discard registry.checkCapabilityRequirements([bound], request)

  test "independent issued grants with equal policies retain distinct identities":
    let (registry, provider) = policyTestCatalog()
    let one = registry.policyTestAuthority(provider, "[demo/Network]")
    let two = registry.policyTestAuthority(provider, "[demo/Network]")
    check one.row.canonicalKey != two.row.canonicalKey

  test "bounded decomposition never admits an unproved mandatory request":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider,
      """[(demo/Network ^hosts ["a"] ^methods ["GET"])
          (demo/Network ^hosts ["a"] ^methods ["POST"])]""")
    let request = registry.policyTestRow(
      """[(demo/Network ^hosts ["a"] ^methods ["GET" "POST"])]""")
    var budget = newCapabilityProofBudget(0)
    let report = registry.checkCapabilityRequirements([authority.row], request, budget)
    check not report.admitted
    check report.entries[0].status == caCannotProve

proc policyTestRequest(provider: PolicyTestProvider, host, verb: string):
    CapabilityOperation =
  newCapabilityOperation(provider.networkType, "request", fields = [
    CapabilityOperationField(name: "hosts", value: capabilityText(host)),
    CapabilityOperationField(name: "methods", value: capabilityText(verb))])

suite "shared capability checks and operation guards":
  test "one complete permitting entry is required in every independent row":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, """
[(demo/Network ^hosts ["a"] ^methods ["GET"])
 (demo/Network ^hosts ["b"] ^methods ["POST"])]
""")
    check registry.checkCapabilityOperation(
      [authority.row], provider.policyTestRequest("a", "GET")).allowed
    check not registry.checkCapabilityOperation(
      [authority.row], provider.policyTestRequest("a", "POST")).allowed
    check not registry.checkCapabilityOperation(
      [authority.row], provider.policyTestRequest("b", "GET")).allowed
    let ceiling = registry.capabilitySelectionRow(
      registry.policyTestRow("""[(demo/Network ^methods ["GET"])]""", cuBound),
      cuBound)
    check not registry.checkCapabilityOperation(
      [authority.row, ceiling], provider.policyTestRequest("b", "POST")).allowed

  test "optional selection retains the available intersection, not all or none":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider,
      """[(demo/Network ^hosts ["a"] ^methods ["GET"])]""")
    let request = registry.policyTestRow("[(demo/Network ^^optional)]")
    check registry.checkCapabilityRequirements([authority.row], request).admitted
    let selected = registry.capabilitySelectionRow(request, cuRequest)
    check registry.checkCapabilityOperation(
      [authority.row, selected], provider.policyTestRequest("a", "GET")).allowed
    check not registry.checkCapabilityOperation(
      [authority.row, selected], provider.policyTestRequest("a", "POST")).allowed
    let empty = registry.newCapabilityAuthorityRow([])
    check not registry.checkCapabilityOperation(
      [empty, selected], provider.policyTestRequest("a", "GET")).allowed

  test "a selector excludes unrelated authority and empty bounds deny all effects":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Read demo/Network]")
    let selected = registry.capabilitySelectionRow(
      registry.policyTestRow("[demo/Network]", cuBound), cuBound)
    let read = newCapabilityOperation(provider.readType, "read",
      [capabilityText("/tmp/file")])
    check registry.checkCapabilityOperation([authority.row], read).allowed
    check not registry.checkCapabilityOperation([authority.row, selected], read).allowed
    let empty = registry.capabilitySelectionRow(
      registry.policyTestRow("[]", cuBound), cuBound)
    check not registry.checkCapabilityOperation(
      [authority.row, empty], provider.policyTestRequest("a", "GET")).allowed

  test "the actual operation guards again after a favorable advisory descriptor":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider,
      """[(demo/Network ^hosts ["a"] ^methods ["GET"])]""")
    let favorable = provider.policyTestRequest("a", "GET")
    check registry.checkCapabilityOperation([authority.row], favorable).allowed
    var effects = 0
    proc executeActual(host, verb: string) =
      let actual = provider.policyTestRequest(host, verb)
      registry.guardCapabilityOperation([authority.row], actual)
      inc effects
    expect CapabilityGuardError:
      executeActual("b", "GET")
    check effects == 0
    executeActual("a", "GET")
    check effects == 1
    provider.revoke(authority.grants[0])
    expect CapabilityGuardError:
      executeActual("a", "GET")
    check effects == 1

  test "isolated entry failures allow an independent proof in either order":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Network demo/Network]")
    provider.failingGrant = authority.grants[0]
    let reordered = registry.newCapabilityAuthorityRow([
      authority.grants[1], authority.grants[0]])
    let operation = provider.policyTestRequest("a", "GET")
    check registry.checkCapabilityOperation([authority.row], operation).allowed
    check registry.checkCapabilityOperation([reordered], operation).allowed
    provider.revoke(authority.grants[1])
    check registry.checkCapabilityOperation(
      [authority.row], operation).kind == cdProviderFailure
    expect CapabilityGuardError:
      registry.guardCapabilityOperation([authority.row], operation)

  test "shared validation and unexpected failures cannot hide behind an allow":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Network demo/Network]")
    let operation = provider.policyTestRequest("a", "GET")
    provider.sharedUnavailable = true
    check registry.checkCapabilityOperation(
      [authority.row], operation).kind == cdProviderFailure
    provider.sharedUnavailable = false
    provider.unexpectedFailureGrant = authority.grants[1]
    check registry.checkCapabilityOperation(
      [authority.row], operation).kind == cdProviderFailure
    let reordered = registry.newCapabilityAuthorityRow([
      authority.grants[1], authority.grants[0]])
    check registry.checkCapabilityOperation(
      [reordered], operation).kind == cdProviderFailure

  test "a definite independent ceiling denial takes precedence over entry failure":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Network]")
    provider.failingGrant = authority.grants[0]
    let empty = registry.capabilitySelectionRow(
      registry.policyTestRow("[]", cuBound), cuBound)
    let operation = provider.policyTestRequest("a", "GET")
    check registry.checkCapabilityOperation(
      [authority.row, empty], operation).kind == cdDeny
    check registry.checkCapabilityOperation(
      [empty, authority.row], operation).kind == cdDeny

  test "invalid and mutable advisory facts cannot bypass provider validation":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Network]")
    let incomplete = newCapabilityOperation(provider.networkType, "request")
    expect CapabilityOperationError:
      discard registry.checkCapabilityOperation([authority.row], incomplete)
    expect CapabilityOperationError:
      discard newCapabilityOperation(provider.networkType, "request",
        fields = [CapabilityOperationField(name: "optional", value: capabilityBoolean(true))])
    expect CapabilityOperationError:
      discard newCapabilityOperation(provider.networkType, "request",
        fields = [CapabilityOperationField(name: "hosts", value: capabilityAny())])
    var fields = @[
      CapabilityOperationField(name: "hosts", value: capabilityText("a")),
      CapabilityOperationField(name: "methods", value: capabilityText("GET"))]
    let immutable = newCapabilityOperation(provider.networkType, "request", fields = fields)
    fields[0].value.text[0] = 'b'
    var inspected = immutable.operationFields
    inspected[0].value.text[0] = 'c'
    check immutable.operationField("hosts").text == "a"
    check not CapabilityDecision().allowed

suite "normalized execution capability contexts":
  test "admission retains provider failures and accepts independent live proofs":
    for failedIndex in 0..1:
      let (registry, provider) = policyTestCatalog()
      let authority = registry.policyTestAuthority(provider, "[demo/Network demo/Network]")
      provider.unavailableGrant = authority.grants[failedIndex]
      let request = registry.policyTestRow("[demo/Network]")
      check registry.checkCapabilityRequirements([authority.row], request).admitted
      provider.unexpectedAvailabilityGrant = provider.unavailableGrant
      provider.unavailableGrant = nil
      let report = registry.checkCapabilityRequirements([authority.row], request)
      check not report.admitted
      check report.entries[0].status == caProviderFailure
      check report.entries[0].failureScope == cfsShared

  test "optional availability reports failures without adding an entry precondition":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Network]")
    provider.unavailableGrant = authority.grants[0]
    let request = registry.policyTestRow("[(demo/Network ^^optional)]")
    let context = registry.newPolicyContext(authority.grants)
    let report = registry.checkCapabilityRequirements(context, request)
    check report.admitted
    check report.entries[0].optional
    check report.entries[0].status == caProviderFailure
    check report.entries[0].failureScope == cfsEntry
    discard registry.requireCapabilities(context, request)
    try:
      discard registry.requireCapabilities(context, registry.policyTestRow("[demo/Network]"))
      check false
    except CapabilityRequirementError as error:
      require error.parent != nil
      require error.parent.parent != nil
      check error.parent.parent.msg == "original availability cause"
      check error.failedEntry.status == caProviderFailure

  test "healthy decomposed alternatives can cover a request beside a failed broad grant":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider,
      """[demo/Network (demo/Network ^methods ["GET"]) (demo/Network ^methods ["POST"])]""")
    provider.unavailableGrant = authority.grants[0]
    check registry.checkCapabilityRequirements([authority.row], registry.policyTestRow(
      """[(demo/Network ^methods ["GET" "POST"])]""")).admitted

  test "independent admission rows reduce local and shared failures consistently":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Network]")
    let empty = registry.capabilitySelectionRow(registry.policyTestRow("[]", cuBound), cuBound)
    let request = registry.policyTestRow("[demo/Network]")
    provider.unavailableGrant = authority.grants[0]
    for rows in [@[empty, authority.row], @[authority.row, empty]]:
      let report = registry.checkCapabilityRequirements(rows, request)
      check report.entries[0].status == caUnmatched
    provider.unavailableGrant = nil
    provider.unexpectedAvailabilityGrant = authority.grants[0]
    for rows in [@[empty, authority.row], @[authority.row, empty]]:
      let report = registry.checkCapabilityRequirements(rows, request)
      check report.entries[0].status == caProviderFailure
      check report.entries[0].failureScope == cfsShared
    check registry.checkCapabilityRequirements([authority.row], registry.policyTestRow(
      """[(demo/Network ^methods [])]""")).admitted

  test "runtime attenuation installs exact predicates without reissuing grants":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Network demo/Read]")
    let root = newCapabilityContext(authority.grants)
    check root.isPolicyContext
    let bound = registry.policyTestRow(
      """[(demo/Network ^hosts ["a"] ^methods ["GET"])]""", cuBound)
    let child = registry.attenuateCapabilities(root, bound)
    check registry.checkCapabilityOperation(child,
      provider.policyTestRequest("a", "GET")).allowed
    check not registry.checkCapabilityOperation(child,
      provider.policyTestRequest("a", "POST")).allowed
    check not registry.checkCapabilityOperation(child,
      newCapabilityOperation(provider.readType, "read",
        [capabilityText("/tmp/file")])).allowed
    check registry.checkCapabilityOperation(root,
      provider.policyTestRequest("b", "POST")).allowed
    check child.grants.len == authority.grants.len

  test "required boundaries admit mandatory entries and retain optional overlap":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider,
      """[(demo/Network ^hosts ["a"] ^methods ["GET"])]""")
    let root = newCapabilityContext(authority.grants)
    let selected = registry.requireCapabilities(root,
      registry.policyTestRow("[(demo/Network ^^optional)]"))
    check registry.checkCapabilityOperation(selected,
      provider.policyTestRequest("a", "GET")).allowed
    try:
      discard registry.requireCapabilities(root, registry.policyTestRow("[demo/Network]"))
      check false
    except CapabilityRequirementError as error:
      check not error.report.admitted
      check error.report.entries.len > 0
      check error.report.entries[0].authoredIndex == 0
      check error.report.entries[0].authorityRow == 0
      check not error.report.entries[0].optional
      check error.report.entries[0].status != caMatched
    expect CapabilityError:
      discard registry.attenuateCapabilities(root,
        registry.policyTestRow("[(demo/Network ^optional false)]"))

  test "intersections retain independent rows, stable keys and live revocation":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Network]")
    let root = newCapabilityContext(authority.grants)
    let hosts = registry.attenuateCapabilities(root,
      registry.policyTestRow("""[(demo/Network ^hosts ["a"])]""", cuBound))
    let methods = registry.attenuateCapabilities(root,
      registry.policyTestRow("""[(demo/Network ^methods ["GET"])]""", cuBound))
    let combined = intersectContexts(hosts, methods)
    check combined.domainKey == intersectContexts(methods, hosts).domainKey
    check combined.domainKey == intersectContexts(combined, hosts).domainKey
    check registry.checkCapabilityOperation(combined,
      provider.policyTestRequest("a", "GET")).allowed
    check not registry.checkCapabilityOperation(combined,
      provider.policyTestRequest("b", "GET")).allowed
    let identity = combined.domainKey
    provider.revoke(authority.grants[0])
    check combined.domainKey == identity
    check not registry.checkCapabilityOperation(combined,
      provider.policyTestRequest("a", "GET")).allowed

  test "empty contexts remain empty through intersection and optional requests":
    let (registry, provider) = policyTestCatalog()
    let first = registry.newPolicyContext([])
    let second = registry.requireCapabilities(first,
      registry.policyTestRow("[(demo/Network ^^optional)]"))
    check intersectContexts(first, second).domainKey ==
      intersectContexts(second, first).domainKey
    check not registry.checkCapabilityOperation(second,
      provider.policyTestRequest("a", "GET")).allowed
    expect CapabilityError:
      discard registry.requireCapabilities(second, registry.policyTestRow("[demo/Network]"))

  test "domain identity survives context-cache eviction":
    let (registry, provider) = policyTestCatalog()
    let authority = registry.policyTestAuthority(provider, "[demo/Read]")
    let root = newCapabilityContext(authority.grants)
    let bound = registry.policyTestRow("""[(demo/Read "/original")]""", cuBound)
    let first = registry.attenuateCapabilities(root, bound)
    for i in 0..MaxCapabilityContextInternEntries:
      discard registry.attenuateCapabilities(root,
        registry.policyTestRow("[(demo/Read \"/path/" & $i & "\")]", cuBound))
    let second = registry.attenuateCapabilities(root, bound)
    check first.domainKey == second.domainKey
