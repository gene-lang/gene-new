import std/[json, monotimes, os, osproc, streams, strutils, tempfiles, times, unittest]
import gene/[capabilities, compiler, fs_capabilities, printer, types, vm]

type HttpPolicyFixture = object
  process: Process
  directory, records, url, certificate: string
  port: int

proc startHttpPolicyFixture(tls = false): HttpPolicyFixture =
  result.directory = expandFilename(createTempDir("gene-http-policy-", ""))
  result.records = result.directory / "requests.jsonl"
  writeFile(result.records, "")
  var arguments = @[getCurrentDir() / "tests/fixtures/http_capability_server.py", result.records]
  if tls:
    result.certificate = result.directory / "certificate.pem"
    let key = result.directory / "key.pem"
    let generator = startProcess("openssl", args = ["req", "-x509", "-newkey", "rsa:2048",
      "-nodes", "-days", "1", "-keyout", key, "-out", result.certificate,
      "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost"],
      options = {poUsePath, poStdErrToStdOut})
    let output = generator.outputStream.readAll()
    let exitCode = generator.waitForExit(10000)
    generator.close()
    if exitCode != 0: raise newException(IOError, output)
    arguments.add result.certificate
    arguments.add key
  result.process = startProcess("python3", args = arguments,
    options = {poUsePath, poStdErrToStdOut})
  result.port = parseInt(result.process.outputStream.readLine())
  result.url = (if tls: "https" else: "http") & "://127.0.0.1:" & $result.port

proc releaseHttpPolicyFixture(fixture: HttpPolicyFixture) =
  fixture.process.inputStream.writeLine("release")
  fixture.process.inputStream.flush()

proc closeHttpPolicyFixture(fixture: var HttpPolicyFixture) =
  fixture.releaseHttpPolicyFixture()
  fixture.process.inputStream.writeLine("stop")
  fixture.process.inputStream.flush()
  discard fixture.process.waitForExit(5000)
  if fixture.process.running: fixture.process.terminate()
  fixture.process.close()
  removeDir(fixture.directory)

proc httpPolicyApp(fixture: HttpPolicyFixture, policy = ""):
    tuple[app: Application, grants: seq[CapabilityGrant]] =
  result.app = newApplication()
  let scheme = if fixture.url.startsWith("https:"): "https" else: "http"
  let text = if policy.len > 0: policy else:
    "[(net/Http ^schemes [" & newStr(scheme).print() & "] ^hosts [\"127.0.0.1\"] ^ports [" &
      $fixture.port & "] ^methods [\"GET\" \"POST\" \"HEAD\"])]"
  let row = result.app.capabilities.normalizeCapabilityRow(readCapabilityLiteral(
    text, cuGrant, CapabilitySourceContext()), cuGrant)
  for entry in row.entries:
    result.grants.add result.app.hostCapabilities.mintPolicyGrant(entry.policy)
  result.app.setRootCapabilities(result.app.capabilities.newPolicyContext(result.grants))

proc httpPolicyRun(app: Application, source: string): Value =
  run(compileSource(source, useLocalSlots = false), newGlobalScope(app))

proc recordedHttpRequests(fixture: HttpPolicyFixture): seq[JsonNode] =
  for line in readFile(fixture.records).splitLines():
    if line.len > 0: result.add parseJson(line)

suite "native HTTP capability transport":
  test "guarded prepared requests preserve exact method, target and body bytes":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let (app, _) = fixture.httpPolicyApp()
    for target in ["/raw", "/raw?", "/raw?x=1&x=2&empty=&star=*&encoded=%2a"]:
      let url = newStr(fixture.url & target).print()
      let response = app.httpPolicyRun("""
        (var request ($net/http_client/prepare "POST" URL
          ^headers ["Authorization: explicit-data" "Cookie: explicit=1"] ^body "payload"))
        (var r (await ($net/http_client/send request)))
        ($json/parse r/body)
      """.replace("URL", url))
      check response.mapEntries["target"].strVal == target
      check response.mapEntries["method"].strVal == "POST"
      check response.mapEntries["version"].strVal == "HTTP/1.1"
      check response.mapEntries["host"].strVal == "127.0.0.1:" & $fixture.port
      check response.mapEntries["body"].strVal == "payload"
      check response.mapEntries["authorization"].strVal == "explicit-data"
    check fixture.recordedHttpRequests().len == 3

  test "operation guards deny nonselected methods and query presence before connecting":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let exact = fixture.url & "/only?"
    let policy = "[(net/Http " & newStr(exact).print() & " ^methods [\"GET\"])]"
    let (app, _) = fixture.httpPolicyApp(policy)
    for (verb, target) in [("POST", "/only?"), ("GET", "/only"), ("GET", "/only?x=1")]:
      check app.httpPolicyRun("(try ($net/http_client/request ^method " &
        newStr(verb).print() & " ^url " & newStr(fixture.url & target).print() &
        ") false catch MissingCapability true)").boolVal
    check fixture.recordedHttpRequests().len == 0
    let response = app.httpPolicyRun("(await ($net/http_client/request ^url " &
      newStr(exact).print() & "))")
    check response.mapEntries["status"].intVal == 200
    check response.mapEntries["effective_url"].strVal == exact
    check fixture.recordedHttpRequests()[0]["target"].getStr() == "/only?"

  test "redirects remain responses and a later target needs another guard":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let (app, _) = fixture.httpPolicyApp("[(net/Http " &
      newStr(fixture.url & "/redirect").print() & ")]")
    let response = app.httpPolicyRun("(await ($net/http_client/request ^url " &
      newStr(fixture.url & "/redirect").print() & "))")
    check response.mapEntries["status"].intVal == 302
    check fixture.recordedHttpRequests().len == 1
    check app.httpPolicyRun("(try ($net/http_client/request ^url " &
      newStr(fixture.url & "/destination").print() &
      ") false catch MissingCapability true)").boolVal
    check fixture.recordedHttpRequests().len == 1

  test "environment proxies are disabled and authentication is not retained":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let keys = ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY",
                "ALL_PROXY", "no_proxy", "NO_PROXY"]
    var saved: seq[tuple[present: bool, value: string]]
    for key in keys:
      saved.add (existsEnv(key), getEnv(key))
      putEnv(key, if key.toLowerAscii == "no_proxy": "" else: "http://127.0.0.1:1")
    defer:
      for i, key in keys:
        if saved[i].present: putEnv(key, saved[i].value)
        else: delEnv(key)
    let (app, _) = fixture.httpPolicyApp()
    discard app.httpPolicyRun("(await ($net/http_client/request ^url " &
      newStr(fixture.url & "/redirect").print() &
      " ^headers [\"Authorization: explicit-first-request\"]))")
    discard app.httpPolicyRun("(await ($net/http_client/request ^url " &
      newStr(fixture.url & "/destination").print() & "))")
    let records = fixture.recordedHttpRequests()
    check records.len == 2
    check records[1]["authorization"].getStr() == ""
    check records[1]["cookie"].getStr() == ""

  test "unsupported request overrides and CONNECT never reach the endpoint":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let (app, _) = fixture.httpPolicyApp()
    for extra in ["^method \"CONNECT\"", "^headers [\"Host: elsewhere\"]",
                  "^headers [\"Upgrade: websocket\"]",
                  "^headers [\"Expect: 100-continue\"]",
                  "^headers [\"Transfer-Encoding: chunked\"]"]:
      check app.httpPolicyRun("(try ($net/http_client/request ^url " &
        newStr(fixture.url & "/").print() & " " & extra &
        ") false catch CapabilityTypeError true)").boolVal
    check fixture.recordedHttpRequests().len == 0

  test "large request bodies do not enable automatic expectation retries":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let (app, _) = fixture.httpPolicyApp()
    let scope = newGlobalScope(app)
    scope.define("payload", newStr(repeat('x', 2 * 1024 * 1024)))
    let response = run(compileSource("(await ($net/http_client/request ^method \"POST\" ^url " &
      newStr(fixture.url & "/expectation").print() & " ^body payload))"), scope)
    check response.mapEntries["status"].intVal == 417
    let records = fixture.recordedHttpRequests()
    check records.len == 1
    check records[0]["expect"].getStr() == ""
    check records[0]["body_size"].getInt() == 2 * 1024 * 1024

  test "a prepared request remains inert and sending it uses the actual caller":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let (app, _) = fixture.httpPolicyApp()
    let result = app.httpPolicyRun("""
      (var prepared ($net/http_client/prepare "GET" URL))
      (var denied (try (with_capabilities [] ($net/http_client/send prepared))
        false catch MissingCapability true))
      (var modified (try ($net/http_client/send prepared ^url URL)
        false catch $net/http_client/HttpClientError true))
      (var response (await ($net/http_client/send prepared)))
      [denied modified response/status]
    """.replace("URL", newStr(fixture.url & "/prepared").print()))
    check result.print() == "[true true 200]"
    check fixture.recordedHttpRequests().len == 1

  test "a caller-supplied CA file requires separate filesystem authority":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let (app, _) = fixture.httpPolicyApp()
    let ca = fixture.directory / "ca.pem"
    writeFile(ca, "test data that must not be read")
    check app.httpPolicyRun("(try ($net/http_client/request ^url " &
      newStr(fixture.url & "/").print() & " ^ca_file " & newStr(ca).print() &
      ") false catch MissingCapability $err/capability)").strVal == "fs/Read"
    check fixture.recordedHttpRequests().len == 0

  test "normalized HTTP and filesystem grants compose for verified TLS":
    if findExe("openssl").len == 0:
      skip()
    else:
      var fixture = startHttpPolicyFixture(tls = true)
      defer: fixture.closeHttpPolicyFixture()
      let (app, network) = fixture.httpPolicyApp()
      let row = app.capabilities.normalizeCapabilityRow(buildCapabilityLiteral([
        CapabilityEntryLiteral(name: "fs/Read", body: @[capabilityText(fixture.directory)])],
        cuGrant, CapabilitySourceContext()), cuGrant)
      let filesystem = app.filesystemCapabilities.initializeFilesystemGrant(row.entries[0].policy)
      defer: app.filesystemCapabilities.releaseFilesystemGrant(filesystem)
      app.setRootCapabilities(app.capabilities.newPolicyContext(network & @[filesystem]))
      let url = newStr(fixture.url & "/tls").print()
      check app.httpPolicyRun("(try (await ($net/http_client/request ^url " & url &
        ")) false catch $net/http_client/HttpClientError $err/kind)").strVal == "transport"
      check fixture.recordedHttpRequests().len == 0
      let response = app.httpPolicyRun("(await ($net/http_client/request ^url " & url &
        " ^ca_file " & newStr(fixture.certificate).print() & "))")
      check response.mapEntries["status"].intVal == 200
      check fixture.recordedHttpRequests().len == 1
      check app.filesystemCapabilities.initializedFilesystemFiles == 0

  test "unexpected upgrades expose neither a result body nor stream chunks":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let (app, _) = fixture.httpPolicyApp()
    let result = app.httpPolicyRun("""
      (var transfer ($net/http_client/stream ^url URL))
      (var denied (try (await transfer/task) false
        catch UnsupportedCapability $err/reason))
      [denied (try (transfer/channel .recv) false catch ChannelClosed true)]
    """.replace("URL", newStr(fixture.url & "/upgrade").print()))
    check result.print() == "[\"unsupported_upgrade\" true]"

  test "HEAD consumes no response body and retains its distinct method":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let (app, _) = fixture.httpPolicyApp()
    let response = app.httpPolicyRun("(await ($net/http_client/request ^method \"HEAD\" ^url " &
      newStr(fixture.url & "/head").print() & "))")
    check response.mapEntries["status"].intVal == 200
    check response.mapEntries["body"].strVal == ""
    check fixture.recordedHttpRequests()[0]["method"].getStr() == "HEAD"

  test "queued sends observe revocation, alternatives and cancellation at worker start":
    var fixture = startHttpPolicyFixture()
    defer: fixture.closeHttpPolicyFixture()
    let common = "net/Http ^schemes [\"http\"] ^hosts [\"127.0.0.1\"] ^ports [" &
      $fixture.port & "] ^methods [\"GET\"] ^paths "
    let (app, grants) = fixture.httpPolicyApp("[(" & common & "[\"/hold*\" \"/cancel\"]) (" &
      common & "[\"/queued\"]) (" & common & "[\"/redundant\"]) (" &
      common & "[\"/redundant\"]) ]")
    let scope = newGlobalScope(app)
    scope.define("base", newStr(fixture.url))
    discard run(compileSource("(var jobs []) (var probe ($channel))",
      useLocalSlots = false), scope)
    let start = compileSource("""
      (jobs .push ($net/http_client/request ^url $"${base}/hold" ^timeout_ms 15000))
    """)
    # Native completion polling is driven by scheduler/channel operations, not
    # by an arbitrary computation-only VM run. Admit every held transfer before
    # queuing the operations whose authority will change.
    let pump = compileSource("(probe .try_recv)")
    for expected in 1..16:
      discard run(start, scope)
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while fixture.recordedHttpRequests().len < expected and getMonoTime() < deadline:
        discard run(pump, scope)
        os.sleep(2)
      require fixture.recordedHttpRequests().len == expected
    require scope.lookup("jobs").listItems.len == 16
    discard run(compileSource("""
      (var denied ($net/http_client/request ^url $"${base}/queued"))
      (var redundant ($net/http_client/request ^url $"${base}/redundant"))
      (var cancelled ($net/http_client/request ^url $"${base}/cancel"))
      (cancelled .cancel)
    """, useLocalSlots = false), scope)
    app.hostCapabilities.revoke(grants[1])
    app.hostCapabilities.revoke(grants[2])
    fixture.releaseHttpPolicyFixture()
    let result = run(compileSource("""
      (var denial (try (await denied) false catch MissingCapability $err/reason))
      (var response (await redundant))
      (for job in jobs (await job))
      [denial response/status]
    """), scope)
    check result.print() == "[\"no_permitting_entry\" 200]"
    let records = fixture.recordedHttpRequests()
    check records.len == 17
    for record in records:
      check record["target"].getStr() notin ["/queued", "/cancel"]
