## HTTP component policies and immutable request preparation.
## Transport profile: docs/implementation/capabilities-http-profile.md.

import std/[net, strutils, tables]
from std/unicode import validateUtf8
import ./capabilities

const HttpCapabilityProfile* = "http-components-v1"

type
  HttpCapabilityProvider* = ref object of CapabilityProvider
    httpType*: CapabilityType
  HttpUrlFacts* = object
    url*, scheme*, host*, path*, query*: string
    port*: int
    queryPresent*: bool
  PreparedCapabilityHttpRequest* = ref object of RootObj
    factsValue: HttpUrlFacts
    methodValue: string
    headersValue: seq[string]
    bodyValue: string

method supportsCapabilityPolicies*(provider: HttpCapabilityProvider,
    capabilityType: CapabilityType): bool =
  capabilityType == provider.httpType

method initializeCapabilityGrant*(provider: HttpCapabilityProvider,
    policy: CapabilityPolicyEntry): CapabilityGrant =
  if policy.capabilityType != provider.httpType:
    raise newException(CapabilityError, "invalid HTTP startup identity")
  provider.mintPolicyGrant(policy)

proc invalidHttp(message: string) {.noReturn.} =
  raise newException(CapabilityOperationError, "invalid HTTP operation: " & message)

proc normalizeHttpHost*(text: string): string =
  if text.len == 0 or text.len > 253 or text.endsWith(".") or '%' in text:
    invalidHttp("unsupported host spelling")
  for c in text:
    if ord(c) > 127 or c in {'\0', '\\', '/', '@', '[', ']'}:
      invalidHttp("unsupported host spelling")
  if ':' in text:
    try:
      let address = parseIpAddress(text)
      if address.family != IpAddressFamily.IPv6:
        invalidHttp("invalid IPv6 host")
      return ($address).toLowerAscii
    except ValueError:
      invalidHttp("invalid IPv6 host")
  result = text.toLowerAscii
  var numeric = true
  for part in result.split('.'):
    var number = part.len > 0
    if part.startsWith("0x"):
      number = true
      for c in part[2 .. ^1]:
        if c notin HexDigits:
          number = false
    else:
      for c in part:
        if c notin Digits:
          number = false
    numeric = numeric and number
  if numeric:
    try:
      let address = parseIpAddress(result)
      if address.family != IpAddressFamily.IPv4 or $address != result:
        invalidHttp("noncanonical IPv4 host")
      return
    except ValueError:
      invalidHttp("ambiguous numeric host")
  for label in result.split('.'):
    if label.len == 0 or label.len > 63 or label[0] == '-' or label[^1] == '-':
      invalidHttp("invalid DNS label")
    for c in label:
      if c notin {'a'..'z', '0'..'9', '-'}:
        invalidHttp("invalid DNS label")

proc numericAddress(host: string): bool =
  try:
    discard parseIpAddress(host)
    true
  except ValueError:
    false

proc normalizeHttpComponent(text: string, path: bool, pattern = false): string =
  if validateUtf8(text) != -1:
    invalidHttp("invalid UTF-8 component")
  var i = 0
  while i < text.len:
    let c = text[i]
    if pattern and c == '\\':
      if i + 1 >= text.len or text[i + 1] != '*':
        invalidHttp("unsupported path pattern escape")
      result.add "\\*"
      i += 2
    elif c == '%':
      if i + 2 >= text.len or text[i + 1] notin HexDigits or text[i + 2] notin HexDigits:
        invalidHttp("invalid percent escape")
      let escaped = text[i .. i + 2]
      if path and escaped.toLowerAscii in ["%2f", "%5c"]:
        invalidHttp("encoded path separators are unsupported")
      result.add escaped
      i += 3
    elif ord(c) >= 128:
      result.add '%' & toHex(ord(c), 2)
      inc i
    elif ord(c) <= 32 or ord(c) == 127 or c in {'\\', '#'} or
        (path and c == '?'):
      invalidHttp("unsupported character in URL component")
    elif c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~',
                 '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=',
                 ':', '@', '/', '?'}:
      invalidHttp("unsupported character in URL component")
    else:
      result.add c
      inc i
  if path:
    if result.len == 0:
      result = "/"
    if not result.startsWith("/") and not (pattern and result == "*"):
      invalidHttp("path must be absolute")
    for segment in result.split('/'):
      if segment.toLowerAscii.replace("%2e", ".") in [".", ".."]:
        invalidHttp("dot path segments are unsupported")

proc normalizedHttpUrl*(url: string): HttpUrlFacts =
  if url.len == 0 or url.len > 16384 or '#' in url or '\0' in url:
    invalidHttp("unsupported URL")
  let separator = url.find("://")
  if separator < 0:
    invalidHttp("URL must be absolute")
  result.scheme = url[0 ..< separator].toLowerAscii
  if result.scheme notin ["http", "https"]:
    invalidHttp("unsupported scheme")
  let start = separator + 3
  var ending = start
  while ending < url.len and url[ending] notin {'/', '?'}:
    inc ending
  let authority = url[start ..< ending]
  if authority.len == 0 or '@' in authority:
    invalidHttp("missing host or unsupported URL credentials")
  var host, port: string
  if authority.startsWith("["):
    let close = authority.find(']')
    if close < 0:
      invalidHttp("unterminated IPv6 host")
    host = authority[1 ..< close]
    if ':' notin host:
      invalidHttp("brackets require an IPv6 host")
    if close < authority.high:
      if authority[close + 1] != ':':
        invalidHttp("invalid port suffix")
      port = authority[close + 2 .. ^1]
      if port.len == 0:
        invalidHttp("empty port")
  else:
    let colon = authority.find(':')
    if colon >= 0:
      host = authority[0 ..< colon]
      port = authority[colon + 1 .. ^1]
      if port.len == 0:
        invalidHttp("empty port")
    else:
      host = authority
  result.host = normalizeHttpHost(host)
  result.port = if result.scheme == "https": 443 else: 80
  if port.len > 0:
    if port.len > 5:
      invalidHttp("invalid port")
    for c in port:
      if c notin Digits:
        invalidHttp("invalid port")
    result.port = parseInt(port)
    if result.port < 1 or result.port > 65535:
      invalidHttp("port outside 1..65535")
  let query = url.find('?', ending)
  result.queryPresent = query >= 0
  let pathEnd = if query >= 0: query else: url.len
  result.path = normalizeHttpComponent(url[ending ..< pathEnd], path = true)
  if query >= 0:
    result.query = normalizeHttpComponent(url[query + 1 .. ^1], path = false)
  let hostname = if ':' in result.host: "[" & result.host & "]" else: result.host
  result.url = result.scheme & "://" & hostname
  if result.port != (if result.scheme == "https": 443 else: 80):
    result.url.add ":" & $result.port
  result.url.add result.path
  if result.queryPresent:
    result.url.add "?" & result.query

proc checkedHttpToken(text: string, limit: int): string =
  if text.len == 0 or text.len > limit:
    invalidHttp("invalid token length")
  for c in text:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&',
                 '\'', '*', '+', '-', '.', '^', '_', '|', '~'} and ord(c) != 96:
      invalidHttp("invalid HTTP token")
  text

proc checkedHttpMethod*(verb: string): string =
  if verb == "CONNECT":
    invalidHttp("unsupported method")
  checkedHttpToken(verb, 64)

proc checkedHttpHeaders*(headers: openArray[string]): seq[string] =
  if headers.len > 256:
    invalidHttp("too many headers")
  for header in headers:
    if header.len > 65536:
      invalidHttp("header too long")
    let colon = header.find(':')
    if colon <= 0:
      invalidHttp("invalid header")
    let name = header[0 ..< colon]
    discard checkedHttpToken(name, 128)
    for c in header:
      if (ord(c) < 32 and c != '\t') or ord(c) == 127:
        invalidHttp("control character in header")
    let lowered = name.toLowerAscii
    if lowered in ["host", "upgrade", "proxy-authorization", "proxy-connection",
                   "content-length", "transfer-encoding", "expect"]:
      invalidHttp("unsupported target, framing, proxy, handshake, or upgrade override")
    if lowered == "connection":
      for token in header[colon + 1 .. ^1].split(','):
        if token.strip.toLowerAscii == "upgrade":
          invalidHttp("upgraded connections are unsupported")
    result.add header

proc prepareCapabilityHttpRequest*(verb, url: string,
    headers: openArray[string] = [], body = ""): PreparedCapabilityHttpRequest =
  if verb == "HEAD" and body.len > 0:
    invalidHttp("HEAD request bodies are unsupported")
  PreparedCapabilityHttpRequest(factsValue: normalizedHttpUrl(url),
    methodValue: checkedHttpMethod(verb), headersValue: checkedHttpHeaders(headers),
    bodyValue: body)

proc facts*(request: PreparedCapabilityHttpRequest): HttpUrlFacts = request.factsValue
proc httpMethod*(request: PreparedCapabilityHttpRequest): string = request.methodValue
proc headers*(request: PreparedCapabilityHttpRequest): seq[string] =
  for header in request.headersValue:
    result.add header
proc body*(request: PreparedCapabilityHttpRequest): string = request.bodyValue
proc requestTarget*(request: PreparedCapabilityHttpRequest): string =
  request.factsValue.path &
    (if request.factsValue.queryPresent: "?" & request.factsValue.query else: "")

proc componentFacts(facts: HttpUrlFacts, verb: string): seq[CapabilityOperationField] =
  @[
    CapabilityOperationField(name: "schemes", value: capabilityText(facts.scheme)),
    CapabilityOperationField(name: "hosts", value: capabilityText(facts.host)),
    CapabilityOperationField(name: "ports", value: capabilityInteger(facts.port)),
    CapabilityOperationField(name: "paths", value: capabilityText(facts.path)),
    CapabilityOperationField(name: "queries", value:
      (if facts.queryPresent: capabilityText(facts.query) else: capabilityBoolean(false))),
    CapabilityOperationField(name: "methods", value: capabilityText(verb)),
    CapabilityOperationField(name: "url", value: capabilityText(facts.url))]

proc describeHttpOperation*(provider: HttpCapabilityProvider,
    request: PreparedCapabilityHttpRequest): CapabilityOperation =
  if provider == nil or request == nil:
    invalidHttp("missing provider or prepared request")
  newCapabilityOperation(provider.httpType, "request",
    fields = componentFacts(request.factsValue, request.methodValue))

proc httpConstraint(name: string, value: CapabilityScalar): CapabilityConstraint =
  if value.kind == cskWildcard:
    return constraintAny()
  if name == "ports":
    if value.kind != cskInteger or value.integer < 1 or value.integer > 65535:
      invalidHttp("ports require integers in 1..65535")
    return constraintExact(value)
  if name == "queries" and value.kind == cskBoolean and not value.boolean:
    return constraintExact(value)
  if value.kind != cskText:
    invalidHttp("component requires text")
  let literal = value.stringMode == csmLiteral
  case name
  of "schemes":
    if value.stringMode == csmPattern or value.text.toLowerAscii notin ["http", "https"]:
      invalidHttp("unsupported scheme constraint")
    constraintExact(capabilityText(value.text.toLowerAscii))
  of "hosts":
    if not literal and value.text.startsWith("*."):
      let suffix = normalizeHttpHost(value.text[2 .. ^1])
      if numericAddress(suffix):
        invalidHttp("host wildcard requires a DNS suffix")
      constraintPattern("*." & suffix)
    else:
      constraintExact(capabilityText(normalizeHttpHost(value.text)))
  of "paths":
    let path = normalizeHttpComponent(value.text, path = true, pattern = not literal)
    if literal: constraintExact(capabilityText(path))
    else: constraintPattern(path)
  of "queries":
    if value.stringMode == csmPattern:
      invalidHttp("query constraints do not support patterns")
    constraintExact(capabilityText(normalizeHttpComponent(value.text, path = false)))
  of "methods":
    if value.stringMode == csmPattern:
      invalidHttp("method constraints do not support patterns")
    constraintExact(capabilityText(checkedHttpMethod(value.text)))
  else:
    invalidHttp("unknown HTTP capability property")

method normalizeCapabilityEntry*(provider: HttpCapabilityProvider,
    capabilityType: CapabilityType, literal: CapabilityEntryLiteral,
    source: CapabilitySourceContext): CapabilityPolicyEntry =
  discard source
  if capabilityType != provider.httpType or literal.body.len > 1:
    invalidHttp("HTTP entry accepts at most one exact URL")
  var fields = initTable[string, CapabilityConstraint]()
  if literal.body.len == 1 and literal.body[0].kind != cskWildcard:
    let value = literal.body[0]
    if value.kind != cskText or value.stringMode == csmPattern or
        (value.stringMode == csmSource and '*' in value.text):
      invalidHttp("HTTP URL shorthand must be exact")
    let facts = normalizedHttpUrl(value.text)
    for field in componentFacts(facts, "GET"):
      if field.name notin ["url", "methods"]:
        fields[field.name] = constraintExact(field.value)
  for property in literal.properties:
    if property.name notin ["schemes", "hosts", "ports", "paths", "queries", "methods"]:
      invalidHttp("unknown HTTP capability property")
    let values = if property.value.isList: property.value.items
                 else: @[property.value.scalar]
    var alternatives: seq[CapabilityConstraint]
    for value in values:
      if property.value.isList and value.kind == cskWildcard:
        invalidHttp("unrestricted token must be the whole HTTP field")
      alternatives.add httpConstraint(property.name, value)
    let restriction = constraintAlternatives(alternatives)
    fields[property.name] = constraintIntersection([
      fields.getOrDefault(property.name, constraintAny()), restriction])
  var normalized: seq[CapabilityPolicyField]
  for name, constraint in fields:
    normalized.add CapabilityPolicyField(name: name, constraint: constraint)
  newCapabilityPolicyEntry(capabilityType, constraintAny(), normalized)

method capabilityAlternatives*(provider: HttpCapabilityProvider,
    entry: CapabilityPolicyEntry, budget: var CapabilityProofBudget):
    CapabilityAlternativeResult =
  discard provider
  decomposeCapabilityEntry(entry, false,
    ["schemes", "hosts", "ports", "paths", "queries", "methods"], budget)

method validity*(provider: HttpCapabilityProvider,
                 grant: CapabilityGrant): CapabilityValidity =
  if grant.isOwnedBy(provider): grant.sealedValidity else: CapabilityValidity()

method validateCapabilityOperation*(provider: HttpCapabilityProvider,
                                    operation: CapabilityOperation) =
  if operation.capabilityType != provider.httpType or
      operation.operationKind != "request" or operation.operationBody.len != 0 or
      operation.operationFields.len != 7:
    invalidHttp("invalid descriptor shape")
  let url = operation.operationField("url")
  let verb = operation.operationField("methods")
  if url.kind != cskText or verb.kind != cskText:
    invalidHttp("URL and method must be text")
  let facts = normalizedHttpUrl(url.text)
  for expected in componentFacts(facts, checkedHttpMethod(verb.text)):
    let actual = operation.operationField(expected.name)
    if actual.kind != expected.value.kind:
      invalidHttp("contradictory descriptor facts")
    case actual.kind
    of cskText:
      if actual.text != expected.value.text: invalidHttp("contradictory descriptor facts")
    of cskInteger:
      if actual.integer != expected.value.integer: invalidHttp("contradictory descriptor facts")
    of cskBoolean:
      if actual.boolean != expected.value.boolean: invalidHttp("contradictory descriptor facts")
    else: invalidHttp("invalid descriptor facts")

method validateSharedOperationState*(provider: HttpCapabilityProvider,
                                     operation: CapabilityOperation) =
  discard provider
  discard operation

method authorizeCapabilityEntry*(provider: HttpCapabilityProvider,
    grant: CapabilityGrant, policy: CapabilityPolicyEntry,
    operation: CapabilityOperation,
    budget: var CapabilityProofBudget): CapabilityDecision =
  discard provider
  discard grant
  matchCapabilityFacts(policy, capabilityBoolean(true),
    operation.operationFields, budget)

proc admitHttpCapabilityProvider*(registry: CapabilityRegistry): HttpCapabilityProvider =
  result = HttpCapabilityProvider()
  registry.admitProvider(result, "net/http")
  result.httpType = registry.admitType(result, "net/Http")
