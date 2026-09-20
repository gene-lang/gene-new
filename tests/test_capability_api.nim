import std/[os, strutils, unittest]
import gene/[capabilities, compiler, host_capabilities, printer, types, vm]

proc capabilityApiApp(policy = "[]"): Application =
  result = newApplication(getCurrentDir())
  let registry = result.capabilities
  let row = registry.normalizeCapabilityRow(readCapabilityLiteral(policy, cuGrant,
    CapabilitySourceContext(baseDirectory: getCurrentDir())), cuGrant)
  var grants: seq[CapabilityGrant]
  for entry in row.entries:
    grants.add result.hostCapabilities.mintPolicyGrant(entry.policy)
  result.setRootCapabilities(registry.newPolicyContext(grants))

proc capabilityApiRun(app: Application, source: string): Value =
  run(compileSource(source, useLocalSlots = false), newGlobalScope(app))

suite "public immutable capability data API":
  test "parse returns inert rows and optional requirements preserve status":
    let app = capabilityApiApp()
    check app.capabilityApiRun("""
(var row ($capabilities/parse "[(net/Http ^^optional)]"))
(var report ($capabilities/check_requirements row))
[report/admitted report/entries/0/optional report/entries/0/status]
""").print() == "[true true \"no_full_match\"]"

  test "builder strings remain literal unless patterns are explicitly constructed":
    let app = capabilityApiApp("""[(net/Http ^hosts ["*.example.com"] ^methods ["GET"])]""")
    check app.capabilityApiRun("""
(var request ($capabilities/build [
  ($capabilities/entry "net/Http" []
    [["hosts" [($capabilities/pattern "*.example.com")]] ["methods" ["GET"]]])]))
(var report ($capabilities/check_requirements request))
report/admitted
""").print() == "true"
    expect GeneError:
      discard app.capabilityApiRun("""
($capabilities/build [
  ($capabilities/entry "net/Http" [] [["hosts" ["*.example.com"]]])])
""")

  test "operation checks inspect prepared HTTP facts without sending":
    let app = capabilityApiApp("""[(net/Http ^hosts ["api.example.com"] ^methods ["GET"])]""")
    check app.capabilityApiRun("""
(var get ($net/http_client/prepare "GET" "https://api.example.com/status"))
(var post ($net/http_client/prepare "POST" "https://api.example.com/status"))
(var allowed ($capabilities/check_operation ($net/http_client/describe_operation get)))
(var denied ($capabilities/check_operation ($net/http_client/describe_operation post)))
[allowed/allowed denied/allowed denied/kind]
""").print() == "[true false \"deny\"]"

  test "invalid literal vocabulary and duplicate optional flags are errors":
    let app = capabilityApiApp()
    for text in [
      "[(net/Http ^^optional ^optional false)]",
      "[(missing/Type ^^optional)]",
      "[(net/Http ^methods [GET])]",
      "[(net/Http ^unknown *)]"]:
      let escaped = newStr(text).print()
      expect GeneError:
        discard app.capabilityApiRun("($capabilities/parse " & escaped & ")")

  test "builder rejects malformed descriptions and forged pattern maps":
    let app = capabilityApiApp()
    for source in [
      """($capabilities/build [{^name "net/Http" ^unknown true}])""",
      """($capabilities/build [{^name "net/Http" ^optional "true"}])""",
      """($capabilities/build [{^name "net/Http" ^properties {^hosts [{^pattern "*"}]}}])""",
      """($capabilities/build [{^name "net/Http" ^properties {^methods [["GET"]]}}])""",
      """($capabilities/build [{^name "net/Http" ^body [nil]}])"""]:
      checkpoint source
      expect GeneError:
        discard app.capabilityApiRun(source)

  test "property pairs preserve voids and duplicates for validation":
    let app = capabilityApiApp()
    for source in [
      """($capabilities/entry "net/Http" [] [["hosts" void]])""",
      """($capabilities/entry "net/Http" [] [["hosts" ["a"]] ["hosts" ["b"]]])""",
      """($capabilities/entry "net/Http" void [])""",
      """($capabilities/entry "net/Http" [] void)""",
      """($capabilities/entry "net/Http" [] [] void)"""]:
      expect GeneError:
        discard app.capabilityApiRun(source)

  test "advisory facts cannot contain optional flags or contradictory targets":
    let app = capabilityApiApp("[net/Http]")
    expect GeneError:
      discard app.capabilityApiRun("""
($capabilities/check_operation
 {^capability "net/Http" ^operation "request" ^facts {^optional true}})
""")
    expect GeneError:
      discard app.capabilityApiRun("""
($capabilities/check_operation
 {^capability "net/Http" ^operation "request"
  ^facts {^url "https://a.example/" ^schemes "https" ^hosts "b.example"
          ^ports 443 ^paths "/" ^queries false ^methods "GET"}})
""")

  test "reports are immutable and a raw row is not a validated policy value":
    let app = capabilityApiApp()
    expect GeneError:
      discard app.capabilityApiRun("($capabilities/check_requirements [])")
    expect GeneError:
      discard app.capabilityApiRun("""
(var report ($capabilities/check_requirements ($capabilities/parse "[]")))
(set report/admitted false)
""")
