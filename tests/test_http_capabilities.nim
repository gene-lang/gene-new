import std/unittest
import gene/[capabilities, http_capabilities]

proc normalizedHttpCatalog(): tuple[registry: CapabilityRegistry,
                                    provider: HttpCapabilityProvider] =
  result.registry = newCapabilityRegistry()
  result.provider = result.registry.admitHttpCapabilityProvider()
  result.registry.freeze()

proc normalizedHttpPolicy(registry: CapabilityRegistry, text: string,
                          use = cuRequest): CapabilitySpecRow =
  registry.normalizeCapabilityRow(readCapabilityLiteral(text, use,
    CapabilitySourceContext(name: "http-policy", baseDirectory: "/workspace")), use)

proc normalizedHttpAuthority(registry: CapabilityRegistry,
    provider: HttpCapabilityProvider, text: string): CapabilityContext =
  var grants: seq[CapabilityGrant]
  for entry in registry.normalizedHttpPolicy(text, cuGrant).entries:
    grants.add provider.mintPolicyGrant(entry.policy)
  registry.newPolicyContext(grants)

proc httpPermitted(registry: CapabilityRegistry, provider: HttpCapabilityProvider,
    context: CapabilityContext, verb, url: string): bool =
  registry.checkCapabilityOperation(context, provider.describeHttpOperation(
    prepareCapabilityHttpRequest(verb, url))).allowed

suite "HTTP capability URL preparation":
  test "canonical authority, ports, empty paths and IPv6 are shared facts":
    let first = normalizedHttpUrl("HTTPS://API.EXAMPLE.COM:443")
    check first.url == "https://api.example.com/"
    check first.port == 443
    check first.path == "/"
    check normalizedHttpUrl("http://127.0.0.1:8080/x").port == 8080
    check normalizedHttpUrl("http://[0:0:0:0:0:0:0:1]:80").url == "http://[::1]/"
    check normalizedHttpUrl("http://[::1]:8080/").host == "::1"

  test "queries retain presence, order, duplicate keys and encoded values":
    let absent = prepareCapabilityHttpRequest("GET", "https://example.com/path")
    let empty = prepareCapabilityHttpRequest("GET", "https://example.com/path?")
    let data = prepareCapabilityHttpRequest("GET",
      "https://example.com/path?x=1&x=2&x=%2f&q=*")
    check not absent.facts.queryPresent
    check absent.requestTarget == "/path"
    check empty.facts.queryPresent
    check empty.requestTarget == "/path?"
    check data.facts.query == "x=1&x=2&x=%2f&q=*"
    check data.requestTarget == "/path?x=1&x=2&x=%2f&q=*"
    check normalizedHttpUrl("https://example.com/你好?q=🙂").url ==
      "https://example.com/%E4%BD%A0%E5%A5%BD?q=%F0%9F%99%82"

  test "ambiguous hosts, traversal forms, credentials and fragments are rejected":
    for url in [
      "file:///tmp/secret", "http://", "http://a@", "http://u:p@example.com/",
      "http://example.com/#fragment", "http://example.com./",
      "http://éxample.com/", "http://127.1/", "http://2130706433/",
      "http://0177.0.0.1/", "http://0x7f000001/", "http://0x/",
      "http://[::1%25en0]/", "http://[127.0.0.1]/", "http://::1/",
      "http://example.com:/", "http://example.com:0/",
      "http://example.com:65536/", "http://example.com:80x/",
      "http://example.com/a/../secret", "http://example.com/a/%2e%2E/secret",
      "http://example.com/a%2fsecret", "http://example.com/a%5csecret",
      "http://example.com/a b", "http://example.com/a\\b",
      "http://example.com/%x0", "http://example.com/%",
      "http://%61.example.com/", "http://a..example.com/"]:
      checkpoint url
      expect CapabilityOperationError:
        discard normalizedHttpUrl(url)

  test "caller headers cannot change targets, upgrades or message framing":
    for header in ["Host: evil.example", "hOsT: example.com", "Upgrade: websocket",
                   "Connection: keep-alive, Upgrade", "Proxy-Authorization: secret",
                   "Content-Length: 0", "Transfer-Encoding: chunked", "Expect: 100-continue",
                   "X-Test: safe\r\nHost: evil.example", "Host : evil.example",
                   ":authority: evil.example", "X-Test: bad\0value"]:
      checkpoint header
      expect CapabilityOperationError:
        discard prepareCapabilityHttpRequest("GET", "https://example.com/", [header])
    check prepareCapabilityHttpRequest("GET", "https://example.com/",
      ["Authorization: app-data", "Cookie: app-data", "Connection: close"]).headers.len == 3
    expect CapabilityOperationError:
      discard prepareCapabilityHttpRequest("CONNECT", "https://example.com/")
    expect CapabilityOperationError:
      discard prepareCapabilityHttpRequest("HEAD", "https://example.com/", body = "body")
    expect CapabilityOperationError:
      discard prepareCapabilityHttpRequest("GET\r\nPOST", "https://example.com/")

  test "prepared targets cannot be mutated through inputs or inspection":
    var supplied = @["X-Test: original"]
    let request = prepareCapabilityHttpRequest("GET", "https://example.com/", supplied)
    supplied[0] = "Host: evil.example"
    var inspected = request.headers
    inspected[0][0] = 'Y'
    var facts = request.facts
    facts.host[0] = 'X'
    check request.headers[0] == "X-Test: original"
    check request.facts.host == "example.com"

suite "HTTP capability policy and actual facts":
  test "host and method restrictions guard the actual operation":
    let (registry, provider) = normalizedHttpCatalog()
    let context = registry.normalizedHttpAuthority(provider,
      """[(net/Http ^hosts ["api.example.com"] ^methods ["GET"])]""")
    check registry.httpPermitted(provider, context, "GET", "https://API.EXAMPLE.COM/status")
    for verb in ["POST", "HEAD", "get"]:
      check not registry.httpPermitted(provider, context, verb, "https://api.example.com/status")
    check not registry.httpPermitted(provider, context, "GET", "https://api.example.com.evil.test/")
    check not registry.httpPermitted(provider, context, "GET", "https://other.example.com/")

  test "exact URL shorthand has the same canonical component contract":
    let (registry, _) = normalizedHttpCatalog()
    let shorthand = registry.normalizedHttpPolicy(
      """[(net/Http "https://api.example.com/status" ^methods ["GET"])]""")
    let components = registry.normalizedHttpPolicy("""
[(net/Http ^schemes ["https"] ^hosts ["api.example.com"] ^ports [443]
           ^paths ["/status"] ^queries [false] ^methods ["GET"])]
""")
    check shorthand.entries[0].policy.canonicalKey == components.entries[0].policy.canonicalKey

  test "exact query distinctions survive authorization":
    let (registry, provider) = normalizedHttpCatalog()
    for suffix in ["", "?", "?x=1", "?x=1&x=2", "?x=2&x=1"]:
      let context = registry.normalizedHttpAuthority(provider,
        "[(net/Http \"https://example.com/status" & suffix & "\")]")
      for candidate in ["", "?", "?x=1", "?x=1&x=2", "?x=2&x=1"]:
        check registry.httpPermitted(provider, context, "GET",
          "https://example.com/status" & candidate) == (suffix == candidate)

  test "different URL entries preserve correlated hosts and paths":
    let (registry, provider) = normalizedHttpCatalog()
    let context = registry.normalizedHttpAuthority(provider, """
[(net/Http "https://a.example/one" ^methods ["GET"])
 (net/Http "https://b.example/two" ^methods ["POST"])]
""")
    check registry.httpPermitted(provider, context, "GET", "https://a.example/one")
    check registry.httpPermitted(provider, context, "POST", "https://b.example/two")
    check not registry.httpPermitted(provider, context, "GET", "https://a.example/two")
    check not registry.httpPermitted(provider, context, "POST", "https://a.example/one")
    check not registry.httpPermitted(provider, context, "GET", "https://b.example/one")

  test "host wildcard grammar matches complete subdomains only":
    let (registry, provider) = normalizedHttpCatalog()
    let context = registry.normalizedHttpAuthority(provider,
      """[(net/Http ^hosts ["*.example.com"] ^paths ["/api/*"])]""")
    for host in ["a.example.com", "a.b.example.com"]:
      check registry.httpPermitted(provider, context, "GET", "https://" & host & "/api/x")
    for host in ["example.com", "example.com.evil.test", "evil-example.com"]:
      check not registry.httpPermitted(provider, context, "GET", "https://" & host & "/api/x")
    check not registry.httpPermitted(provider, context, "GET", "https://a.example.com/other")
    for host in ["localhost*", "api.*.example.com", "*", "*.127.0.0.1"]:
      expect CapabilityError:
        discard registry.normalizedHttpPolicy("[(net/Http ^hosts [\"" & host & "\"])]")

  test "literal builders prevent wildcard interpretation":
    let (registry, provider) = normalizedHttpCatalog()
    let literal = buildCapabilityLiteral([
      CapabilityEntryLiteral(name: "net/Http", properties: @[
        CapabilityPropertyLiteral(name: "paths",
          value: capabilityValue(capabilityText("/a*b")))])],
      cuGrant, CapabilitySourceContext(kind: csoBuilder, name: "builder"))
    let row = registry.normalizeCapabilityRow(literal, cuGrant)
    let context = registry.newPolicyContext([provider.mintPolicyGrant(row.entries[0].policy)])
    check registry.httpPermitted(provider, context, "GET", "https://example.com/a*b")
    check not registry.httpPermitted(provider, context, "GET", "https://example.com/axb")

  test "invalid configurations cannot hide behind optional or unrestricted entries":
    let (registry, _) = normalizedHttpCatalog()
    for text in [
      """[(net/Http "https://example.com/*")]""",
      """[(net/Http "https://a.example/" "https://b.example/")]""",
      """[(net/Http * "https://a.example/")]""",
      """[(net/Http ^^optional ^methods ["CONNECT"])]""",
      """[net/Http (net/Http ^ports [0])]""",
      """[(net/Http ^hosts [*])]""",
      """[(net/Http ^queries [true])]""",
      """[(net/Http ^^optional ^unknown [])]"""]:
      checkpoint text
      expect CapabilityError:
        discard registry.normalizedHttpPolicy(text)

  test "contradictory advisory descriptors are invalid, not permission":
    let (registry, provider) = normalizedHttpCatalog()
    let context = registry.normalizedHttpAuthority(provider, "[net/Http]")
    let request = prepareCapabilityHttpRequest("GET", "https://a.example/")
    let original = provider.describeHttpOperation(request)
    var fields = original.operationFields
    for field in fields.mitems:
      if field.name == "hosts":
        field.value = capabilityText("b.example")
    let forged = newCapabilityOperation(provider.httpType, "request", fields = fields)
    expect CapabilityOperationError:
      discard registry.checkCapabilityOperation(context, forged)

  test "grouped method admission and optional partial availability share the guard":
    let (registry, provider) = normalizedHttpCatalog()
    let context = registry.normalizedHttpAuthority(provider, """
[(net/Http ^hosts ["a.example"] ^methods ["GET"])
 (net/Http ^hosts ["a.example"] ^methods ["POST"])]
""")
    let required = registry.normalizedHttpPolicy(
      """[(net/Http ^hosts ["a.example"] ^methods ["GET" "POST"])]""")
    check registry.checkCapabilityRequirements(context, required).admitted
    let optional = registry.requireCapabilities(context,
      registry.normalizedHttpPolicy("[(net/Http ^^optional)]"))
    check registry.httpPermitted(provider, optional, "GET", "https://a.example/")
    check not registry.httpPermitted(provider, optional, "HEAD", "https://a.example/")
    let blocked = registry.attenuateCapabilities(context,
      registry.normalizedHttpPolicy("[]", cuBound))
    check not registry.httpPermitted(provider, blocked, "GET", "https://a.example/")
