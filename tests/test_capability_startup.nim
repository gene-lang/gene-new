import std/[options, os, strutils, tempfiles, unittest]
import gene/[capabilities, capability_startup, fs_capabilities, host_capabilities,
             http_capabilities, compiler, gir, printer, types, vm]

var startupNativeCalls = 0
proc startupNativeProbe(args: openArray[Value]): Value {.nimcall.} =
  inc startupNativeCalls
  newInt(7)

type StartupProbeProvider = ref object of CapabilityProvider
  capability: CapabilityType
  initialized: seq[CapabilityGrant]
  released: int
  failRelease, widenIntersection: bool

method normalizeCapabilityEntry(provider: StartupProbeProvider,
    capabilityType: CapabilityType, literal: CapabilityEntryLiteral,
    source: CapabilitySourceContext): CapabilityPolicyEntry =
  if literal.properties.len != 0 or literal.body.len > 1:
    raise newException(CapabilityError, "invalid startup probe policy")
  newCapabilityPolicyEntry(capabilityType,
    if literal.body.len == 0: constraintAny()
    else: constraintExact(literal.body[0]))

method initializeCapabilityGrant(provider: StartupProbeProvider,
    policy: CapabilityPolicyEntry): CapabilityGrant =
  if policy.body.kind == cckExact and policy.body.exactScalar.text == "fail":
    raise newException(CapabilityError, "startup probe initialization failed")
  result = provider.mintPolicyGrant(policy)
  provider.initialized.add result

method releaseCapabilityGrant(provider: StartupProbeProvider, grant: CapabilityGrant) =
  inc provider.released
  if provider.failRelease:
    raise newException(CapabilityError, "startup probe cleanup failed")
  provider.revoke(grant)

method intersectStartupPolicies(provider: StartupProbeProvider,
    left, right: CapabilityPolicyEntry, budget: var CapabilityProofBudget):
    seq[CapabilityPolicyEntry] =
  if provider.widenIntersection:
    @[newCapabilityPolicyEntry(provider.capability, constraintAny())]
  else:
    @[intersectSameCapabilityPolicies(left, right, budget)]

proc startupCatalog(): tuple[registry: CapabilityRegistry,
    fs: FilesystemProvider, http: HostCapabilityProvider] =
  result.registry = newCapabilityRegistry()
  result.fs = result.registry.admitFilesystemProvider()
  result.http = result.registry.admitHostCapabilityProvider()
  result.registry.freeze()

proc startupRow(registry: CapabilityRegistry, text: string,
    use = cuGrant, base = ""): CapabilitySpecRow =
  registry.normalizeCapabilityRow(readCapabilityLiteral(text, use,
    CapabilitySourceContext(baseDirectory: base)), use)

proc startupHttpAllowed(registry: CapabilityRegistry,
    provider: HttpCapabilityProvider, context: CapabilityContext,
    verb, url: string): bool =
  registry.checkCapabilityOperation(context,
    provider.describeHttpOperation(prepareCapabilityHttpRequest(verb, url))).allowed

suite "startup capability sources":
  test "all CLI aliases consume one complete value without shell evaluation":
    for flag in ["--capabilities", "--cap", "--capabilities-file", "--cap-file"]:
      var separate, attached: CapabilityStartupOptions
      var index = 0
      check separate.consumeCapabilityOption([flag, "[]", "entry.gene"], index)
      check index == 2
      index = 0
      check attached.consumeCapabilityOption([flag & "=[]", "entry.gene"], index)
      check index == 1
      check selectCapabilityStartup(separate, getCurrentDir()).origin ==
        selectCapabilityStartup(attached, getCurrentDir()).origin
    var untouched: CapabilityStartupOptions
    var index = 0
    check not untouched.consumeCapabilityOption(["--other"], index)
    check index == 0

  test "duplicate and mixed CLI policy sources are errors":
    for first in ["--cap", "--cap-file", "--capabilities", "--capabilities-file"]:
      for second in ["--cap", "--cap-file", "--capabilities", "--capabilities-file"]:
        var options: CapabilityStartupOptions
        options.setCapabilityOption(first, "[]")
        expect CapabilityError: options.setCapabilityOption(second, "[]")
    var missing: CapabilityStartupOptions
    var index = 0
    expect CapabilityError: discard missing.consumeCapabilityOption(["--cap"], index)

  test "CLI replaces environment and host defaults instead of unioning":
    let catalog = startupCatalog()
    var options: CapabilityStartupOptions
    options.setCapabilityOption("--cap", "[(net/Http ^methods [\"GET\"])]")
    let selected = selectCapabilityStartup(options, getCurrentDir(),
      some("this lower source is malformed"),
      hostCapabilityDefault("also malformed", getCurrentDir()))
    check selected.origin == csoCliLiteral
    let row = catalog.registry.startupCapabilityPolicy(selected)
    require row.len == 1
    check row.entries[0].policy.capabilityType == catalog.http.types.netHttp
    check row.entries[0].policy.field("methods").matches(capabilityText("GET"))
    check not row.entries[0].policy.field("methods").matches(capabilityText("POST"))

  test "environment replaces host defaults and an empty environment value is invalid":
    let catalog = startupCatalog()
    let host = hostCapabilityDefault("[net/Http]", getCurrentDir())
    let selected = selectCapabilityStartup(CapabilityStartupOptions(), getCurrentDir(),
      some("[]"), host)
    check selected.origin == csoEnvironmentVariable
    check catalog.registry.startupCapabilityPolicy(selected).len == 0
    let invalid = selectCapabilityStartup(CapabilityStartupOptions(), getCurrentDir(),
      some(""), host)
    expect CapabilityLiteralError:
      discard catalog.registry.startupCapabilityPolicy(invalid)

  test "host defaults apply only when CLI and environment sources are absent":
    let catalog = startupCatalog()
    let selected = selectCapabilityStartup(CapabilityStartupOptions(), getCurrentDir(),
      hostDefault = hostCapabilityDefault("[net/Http]", getCurrentDir()))
    check selected.origin == csoHostConfiguration
    check catalog.registry.startupCapabilityPolicy(selected).len == 1

  test "omission and explicit empty stay distinct but both select no authority":
    let catalog = startupCatalog()
    let absent = selectCapabilityStartup(CapabilityStartupOptions(), getCurrentDir())
    var options: CapabilityStartupOptions
    options.setCapabilityOption("--cap", "[]")
    let explicit = selectCapabilityStartup(options, getCurrentDir(), some("[net/Http]"))
    check absent.origin == csoBuiltinDefault
    check explicit.origin == csoCliLiteral
    for selected in [absent, explicit]:
      let authority = catalog.registry.initializeStartupCapabilities(
        catalog.registry.startupCapabilityPolicy(selected))
      defer: authority.close()
      check authority.context.isPolicyContext
      check authority.context.grants.len == 0
      check catalog.fs.initializedFilesystemRoots == 0

  test "selected malformed input never falls back to a valid lower source":
    let catalog = startupCatalog()
    for text in ["", "[unknown/Provider]", "[(net/Http ^^optional)]",
                 "[(net/Http ^optional false)]", "[(net/Http ^methods [GET])]"]:
      var options: CapabilityStartupOptions
      options.setCapabilityOption("--cap", text)
      let selected = selectCapabilityStartup(options, getCurrentDir(), some("[net/Http]"))
      var rejected = false
      try: discard catalog.registry.startupCapabilityPolicy(selected)
      except CapabilityError, CapabilityLiteralError: rejected = true
      checkpoint text
      check rejected

  test "CLI and environment paths keep the captured launch base after cwd changes":
    let root = expandFilename(createTempDir("gene-startup-base-", ""))
    defer: removeDir(root)
    createDir(root / "other")
    let catalog = startupCatalog()
    var options: CapabilityStartupOptions
    options.setCapabilityOption("--cap", "[(fs/Read \"data\")]")
    let cli = selectCapabilityStartup(options, root)
    let environment = selectCapabilityStartup(CapabilityStartupOptions(), root,
      some("[(fs/Read \"data\")]"))
    let previous = getCurrentDir()
    setCurrentDir(root / "other")
    try:
      for selected in [cli, environment]:
        let row = catalog.registry.startupCapabilityPolicy(selected)
        check row.entries[0].policy.body.treeRoot == root / "data"
    finally: setCurrentDir(previous)

  test "capability files use their own base and lend no acquisition authority":
    let root = expandFilename(createTempDir("gene-startup-file-", ""))
    defer: removeDir(root)
    createDir(root / "config")
    let path = root / "config" / "caps.gene"
    writeFile(path, "[(fs/Read \"../data\")]")
    let catalog = startupCatalog()
    var options: CapabilityStartupOptions
    options.setCapabilityOption("--cap-file", "config/caps.gene")
    let selected = selectCapabilityStartup(options, root, some("malformed ignored source"))
    check selected.capabilityFile == path
    check selected.source.baseDirectory == root / "config"
    let row = catalog.registry.startupCapabilityPolicy(selected, catalog.fs)
    check row.entries[0].policy.body.treeRoot == root / "data"
    check catalog.fs.initializedFilesystemRoots == 0
    check catalog.fs.initializedFilesystemFiles == 0
    writeFile(path, "[]")
    check row.entries[0].policy.body.treeRoot == root / "data"
    let empty = catalog.registry.initializeStartupCapabilities(
      catalog.registry.startupCapabilityPolicy(selected, catalog.fs))
    defer: empty.close()
    check empty.context.grants.len == 0

  test "missing oversized and symlinked selected files fail without fallback or leaks":
    let root = expandFilename(createTempDir("gene-startup-file-errors-", ""))
    defer: removeDir(root)
    let catalog = startupCatalog()
    writeFile(root / "large", repeat(' ', DefaultCapabilityLiteralLimits.maxBytes + 1))
    writeFile(root / "target", "[]")
    createSymlink(root / "target", root / "linked")
    for path in ["missing", "large", "linked"]:
      var options: CapabilityStartupOptions
      options.setCapabilityOption("--capabilities-file", path)
      let selected = selectCapabilityStartup(options, root, some("[net/Http]"))
      expect CapabilityError:
        discard catalog.registry.startupCapabilityPolicy(selected, catalog.fs)
      check catalog.fs.initializedFilesystemRoots == 0
      check catalog.fs.initializedFilesystemFiles == 0

  test "captured startup input is not reread while the host prepares an application":
    let root = expandFilename(createTempDir("gene-startup-captured-", ""))
    defer: removeDir(root)
    let path = root / "caps.gene"
    writeFile(path, "[]")
    let catalog = startupCatalog()
    var options: CapabilityStartupOptions
    options.setCapabilityOption("--cap-file", path)
    let selected = catalog.registry.captureCapabilityStartup(
      selectCapabilityStartup(options, root), catalog.fs)
    writeFile(path, "[net/Http]")
    let app = newApplication(root)
    let authority = app.configureCapabilityStartup(selected)
    defer: authority.close()
    check app.rootCapabilities.grants.len == 0

  test "normalized namespace expansion excludes superseded internal identities":
    let catalog = startupCatalog()
    let fs = catalog.registry.startupRow("[fs/*]")
    check fs.len == 3
    for entry in fs.entries:
      check entry.policy.capabilityType.name in ["fs/Read", "fs/Write", "fs/ReadWrite"]
    let net = catalog.registry.startupRow("[net/*]")
    check net.len == 1
    check net.entries[0].policy.capabilityType == catalog.http.types.netHttp
    for text in ["[fs/ReadDir]", "[net/Connect]", "[os/*]"]:
      expect CapabilityError: discard catalog.registry.startupRow(text)

suite "startup grant initialization":
  test "administrator bounds trim roots and rights before any resource is initialized":
    let root = expandFilename(createTempDir("gene-startup-trim-", ""))
    defer: removeDir(root)
    createDir(root / "allowed")
    writeFile(root / "allowed" / "data", "allowed")
    let catalog = startupCatalog()
    let selected = catalog.registry.startupRow(
      "[(fs/ReadWrite \"missing\" \"allowed\")]", base = root)
    let ceiling = catalog.registry.startupRow("[(fs/Read \"allowed\")]", cuBound, root)
    let authority = catalog.registry.initializeStartupCapabilities(selected, [ceiling])
    defer: authority.close()
    require authority.effectivePolicies.len == 1
    check authority.effectivePolicies[0].capabilityType == catalog.fs.types.read
    check catalog.fs.initializedFilesystemRoots == 1
    check catalog.fs.readText(authority.context, root / "allowed" / "data") == "allowed"
    expect CapabilityError:
      catalog.fs.writeText(authority.context, root / "allowed" / "new", "forbidden")
    check not fileExists(root / "allowed" / "new")

  test "an empty ceiling initializes no state even for unavailable configured roots":
    let root = expandFilename(createTempDir("gene-startup-empty-", ""))
    defer: removeDir(root)
    let catalog = startupCatalog()
    let authority = catalog.registry.initializeStartupCapabilities(
      catalog.registry.startupRow("[(fs/Read \"missing\") net/Http]", base = root),
      [catalog.registry.startupRow("[]", cuBound)])
    defer: authority.close()
    check authority.context.grants.len == 0
    check catalog.fs.initializedFilesystemRoots == 0

  test "HTTP ceiling alternatives keep their complete host-method correlations":
    let catalog = startupCatalog()
    let selected = catalog.registry.startupRow("""
[(net/Http ^hosts ["a.example" "b.example"] ^methods ["GET" "POST"])]
""")
    let ceiling = catalog.registry.startupRow("""
[(net/Http ^hosts ["a.example"] ^methods ["GET"])
 (net/Http ^hosts ["b.example"] ^methods ["POST"])]
""", cuBound)
    let authority = catalog.registry.initializeStartupCapabilities(selected, [ceiling])
    defer: authority.close()
    check catalog.registry.startupHttpAllowed(catalog.http, authority.context, "GET", "https://a.example/")
    check catalog.registry.startupHttpAllowed(catalog.http, authority.context, "POST", "https://b.example/")
    check not catalog.registry.startupHttpAllowed(catalog.http, authority.context, "POST", "https://a.example/")
    check not catalog.registry.startupHttpAllowed(catalog.http, authority.context, "GET", "https://b.example/")

  test "filesystem intersection preserves compound demands within one entry":
    let root = expandFilename(createTempDir("gene-startup-compound-", ""))
    defer: removeDir(root)
    createDir(root / "a")
    createDir(root / "b")
    let catalog = startupCatalog()
    let selected = catalog.registry.startupRow("[(fs/Write \"a\" \"b\")]", base = root)
    let complete = catalog.registry.startupRow("[(fs/Write \"a\" \"b\")]", cuBound, root)
    let split = catalog.registry.startupRow("[(fs/Write \"a\") (fs/Write \"b\")]", cuBound, root)
    let allowed = catalog.registry.initializeStartupCapabilities(selected, [complete])
    defer: allowed.close()
    let denied = catalog.registry.initializeStartupCapabilities(selected, [split])
    defer: denied.close()
    writeFile(root / "a" / "data", "value")
    expect CapabilityError:
      catalog.fs.renamePath(denied.context, root / "a" / "data", root / "b" / "data")
    check fileExists(root / "a" / "data")
    catalog.fs.renamePath(allowed.context, root / "a" / "data", root / "b" / "data")
    check readFile(root / "b" / "data") == "value"

  test "failed initialization releases earlier state and publishes no usable authority":
    let root = expandFilename(createTempDir("gene-startup-rollback-", ""))
    defer: removeDir(root)
    createDir(root / "allowed")
    let catalog = startupCatalog()
    let selected = catalog.registry.startupRow(
      "[(fs/Read \"allowed\") (fs/Read \"missing\")]", base = root)
    expect CapabilityError: discard catalog.registry.initializeStartupCapabilities(selected)
    check catalog.fs.initializedFilesystemRoots == 0

  test "closing startup authority revokes held contexts and is idempotent":
    let catalog = startupCatalog()
    let authority = catalog.registry.initializeStartupCapabilities(catalog.registry.startupRow("[net/Http]"))
    let retained = authority.context
    check catalog.registry.startupHttpAllowed(catalog.http, retained, "GET", "https://a.example/")
    authority.close()
    authority.close()
    check not catalog.registry.startupHttpAllowed(catalog.http, retained, "GET", "https://a.example/")

  test "existing embedding authority is selected without reissuing grants or losing revocation":
    let catalog = startupCatalog()
    let authority = catalog.registry.initializeStartupCapabilities(catalog.registry.startupRow("[net/Http]"))
    defer: authority.close()
    let selected = catalog.registry.selectStartupCapabilities(authority.context,
      catalog.registry.startupRow("[(net/Http ^hosts [\"a.example\"])]"),
      [catalog.registry.startupRow("[(net/Http ^methods [\"GET\"])]", cuBound)])
    check selected.grants.len == 1
    check selected.grants[0] == authority.context.grants[0]
    check catalog.registry.startupHttpAllowed(catalog.http, selected, "GET", "https://a.example/")
    check not catalog.registry.startupHttpAllowed(catalog.http, selected, "POST", "https://a.example/")
    check not catalog.registry.startupHttpAllowed(catalog.http, selected, "GET", "https://b.example/")
    catalog.http.revoke(authority.context.grants[0])
    check not catalog.registry.startupHttpAllowed(catalog.http, selected, "GET", "https://a.example/")

  test "a provider cannot widen the planned startup intersection":
    let registry = newCapabilityRegistry()
    let provider = StartupProbeProvider(widenIntersection: true)
    registry.admitProvider(provider, "startup-probe")
    provider.capability = registry.admitType(provider, "probe/Grant")
    registry.freeze()
    let policy = registry.startupRow("[(probe/Grant \"limited\")]")
    expect CapabilityError:
      discard registry.initializeStartupCapabilities(policy, [policy])
    check provider.initialized.len == 0

  test "cleanup failure preserves the initialization cause and still releases other providers":
    let root = expandFilename(createTempDir("gene-startup-cleanup-failure-", ""))
    defer: removeDir(root)
    let registry = newCapabilityRegistry()
    let fs = registry.admitFilesystemProvider()
    let provider = StartupProbeProvider(failRelease: true)
    registry.admitProvider(provider, "startup-probe")
    provider.capability = registry.admitType(provider, "probe/Grant")
    registry.freeze()
    let selected = registry.startupRow(
      "[(fs/Read \".\") (probe/Grant \"ready\") (probe/Grant \"fail\")]", base = root)
    var failure: ref CapabilityStartupError
    try: discard registry.initializeStartupCapabilities(selected)
    except CapabilityStartupError as error: failure = error
    require failure != nil
    check failure.parent.msg == "startup probe initialization failed"
    check failure.cleanupFailure.msg == "startup probe cleanup failed"
    check provider.released == 1
    require provider.initialized.len == 1
    check not provider.initialized[0].isValid
    check fs.initializedFilesystemRoots == 0

  test "startup Cartesian expansion has a fixed limit before initialization":
    let catalog = startupCatalog()
    var selected, ceiling = "["
    for index in 0 ..< 33:
      selected.add "(net/Http ^hosts [\"a" & $index & ".example\"])"
      ceiling.add "(net/Http ^methods [\"M" & $index & "\"])"
    selected.add "]"
    ceiling.add "]"
    var message = ""
    try:
      discard catalog.registry.startupCapabilityPolicies(
        catalog.registry.startupRow(selected),
        [catalog.registry.startupRow(ceiling, cuBound)])
    except CapabilityError as error: message = error.msg
    check "expansion limit" in message

suite "application startup installation":
  test "embedding construction starts with no implicit application authority":
    let root = expandFilename(createTempDir("gene-embedding-empty-", ""))
    defer: removeDir(root)
    let path = root / "data"
    writeFile(path, "private")
    let app = newApplication(root)
    check app.rootCapabilities.isPolicyContext
    check app.rootCapabilities.grants.len == 0
    let scope = newGlobalScope(app)
    scope.define("path", newStr(path))
    check run(compileSource("""
      (try ($fs/read_text path) false catch MissingCapability true)
    """), scope).boolVal
    check run(compileSource("""
      (try ($fs/write_text path "changed") false catch MissingCapability true)
    """), scope).boolVal
    check readFile(path) == "private"
    for source in ["($os/get_env \"PATH\")", "($println \"ungranted\")",
                   "($ffi/open \"unavailable-library\")"]:
      check run(compileSource("(try " & source &
        " false catch UnsupportedCapability true)"), scope).boolVal

  test "embedding cannot install legacy or foreign contexts to bypass enforcement":
    let app = newApplication()
    let initial = app.rootCapabilities
    expect CapabilityError:
      app.setRootCapabilities(newCapabilityContext())
    expect CapabilityError:
      app.setRootCapabilities(newCapabilityContext([
        app.filesystemCapabilities.grantReadDir(getCurrentDir())]))
    let other = newApplication()
    expect CapabilityError:
      app.setRootCapabilities(other.rootCapabilities)
    check app.rootCapabilities == initial

  test "host catalog extensions do not implicitly create root grants":
    let provider = StartupProbeProvider()
    let app = newApplicationConfigured(getCurrentDir(),
      proc(registry: CapabilityRegistry, filesystem: FilesystemProvider,
           host: HostCapabilityProvider) =
        registry.admitProvider(provider, "startup_probe")
        provider.capability = registry.admitType(provider, "test/Root"))
    check app.rootCapabilities.isPolicyContext
    check app.rootCapabilities.grants.len == 0
    check provider.initialized.len == 0
    expect CapabilityError:
      discard app.capabilities.admitType(provider, "test/TooLate")
    var options: CapabilityStartupOptions
    options.setCapabilityOption("--cap", "[test/Root]")
    let authority = app.configureCapabilityStartup(options)
    defer: authority.close()
    check provider.initialized.len == 1
    check app.rootCapabilities.grants.len == 1

  test "direct execution overrides cannot re-enable legacy or foreign authority":
    let app = newApplication()
    let scope = newGlobalScope(app)
    let entered = newCell(FALSE)
    scope.define("entered", entered)
    let body = compileSource("(entered .set true)")
    for context in [newCapabilityContext(), newCapabilityContext([
        app.filesystemCapabilities.grantReadDir(getCurrentDir())]),
        newApplication().rootCapabilities]:
      expect GeneError:
        discard run(body, scope, initialCapabilities = context)
      check not run(compileSource("(entered .get)"), scope).boolVal

  test "native SDK entry without a bytecode caller still enforces the empty profile":
    startupNativeCalls = 0
    let unknown = newNativeFn("startup/unknown", startupNativeProbe)
    let privateHost = newNativeFn("startup/private", startupNativeProbe,
      effectKind = nekHostControl)
    for target in [unknown, privateHost]:
      expect GeneError: discard target.call()
    check startupNativeCalls == 0
    let pure = newNativeFn("startup/pure", startupNativeProbe,
      effectKind = nekCapabilityFree)
    check pure.call().intVal == 7
    check startupNativeCalls == 1

  test "direct function entry freezes startup before optimized body execution":
    let app = newApplication()
    let scope = newGlobalScope(app)
    let proto = compileSource("(fn entry [] 7)").functions[0]
    let entry = newFunction(proto.name, proto.params, proto, scope)
    check entry.call().intVal == 7
    expect GeneError:
      discard app.configureCapabilityStartup(CapabilityStartupOptions())

  test "a held callable does not lend its application's grants to an unscoped SDK call":
    let root = expandFilename(createTempDir("gene-embedding-caller-", ""))
    defer: removeDir(root)
    writeFile(root / "data", "private")
    let app = newApplication(root)
    var options: CapabilityStartupOptions
    options.setCapabilityOption("--cap", "[(fs/Read " & newStr(root).print() & ")]")
    let authority = app.configureCapabilityStartup(options)
    defer: authority.close()
    let scope = newGlobalScope(app)
    scope.define("path", newStr(root / "data"))
    let target = run(compileSource("(fn [] ($fs/read_text path))"), scope)
    expect GeneError: discard target.call()
    check target.call(@[], @[], @[], scope).strVal == "private"

  test "an explicit normalized execution context also freezes startup":
    let app = newApplication()
    discard run(compileSource("7"), newGlobalScope(app),
      initialCapabilities = app.rootCapabilities)
    expect GeneError:
      discard app.configureCapabilityStartup(CapabilityStartupOptions())

  test "module initialization freezes embedding root configuration":
    let root = expandFilename(createTempDir("gene-embedding-initialized-", ""))
    defer: removeDir(root)
    let path = root / "entry.gene"
    writeFile(path, "(var initialized true)")
    let app = newApplication(root)
    let entry = app.loadFileModule(path)
    check entry.moduleRootNamespace.nsScope.lookup("initialized").boolVal
    expect GeneError:
      app.setRootCapabilities(app.capabilities.newPolicyContext([]))

  test "startup installation selects explicit grants before application execution":
    let root = expandFilename(createTempDir("gene-startup-install-", ""))
    defer: removeDir(root)
    writeFile(root / "data", "private")
    let app = newApplication(root)
    var options: CapabilityStartupOptions
    options.setCapabilityOption("--cap", "[net/Http]")
    let authority = app.configureCapabilityStartup(options)
    defer: authority.close()
    check app.rootCapabilities.isPolicyContext
    check app.rootCapabilities.grants.len == 1
    let scope = newGlobalScope(app)
    scope.define("path", newStr(root / "data"))
    check run(compileSource("""
(try ($fs/read_text path) false catch MissingCapability true)
"""), scope).boolVal

  test "failed startup does not leave old authority available or permit a fallback attempt":
    let app = newApplication(getCurrentDir())
    var bad: CapabilityStartupOptions
    bad.setCapabilityOption("--cap", "[(net/Http ^^optional)]")
    expect CapabilityLiteralError: discard app.configureCapabilityStartup(bad)
    check app.rootCapabilities.isPolicyContext
    check app.rootCapabilities.grants.len == 0
    expect GeneError:
      discard app.configureCapabilityStartup(CapabilityStartupOptions(), some("[net/Http]"))

  test "startup changes cannot be installed after application code has begun":
    let app = newApplication(getCurrentDir())
    discard run(compileSource("1"), newGlobalScope(app))
    expect GeneError:
      discard app.configureCapabilityStartup(CapabilityStartupOptions())
