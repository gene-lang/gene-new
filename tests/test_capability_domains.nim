import std/[os, strutils, tempfiles, unittest]
import gene/[capabilities, compiler, fs_capabilities, printer, types, vm]

proc capabilityDomainApp(root: string): Application =
  result = newApplication(root)
  result.setRootCapabilities(result.capabilities.newPolicyContext([]))

proc domainSource(app: Application, source: string): Value =
  run(compileSource(source, useLocalSlots = false), newGlobalScope(app))

suite "capability module-domain prototype":
  test "independent domains own distinct types, protocols and implementation environments":
    let root = expandFilename(createTempDir("gene-domain-v1-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", """
(type Request ^props {^value Int})
(protocol Handler (message handle [request : Request] : Int))
(type Local ^props {})
(impl Handler for Local (message handle [request : Request] : Int request/value))
(fn dispatch [request : Request] : Int ((Local) .Handler:handle request))
""")
    let app = capabilityDomainApp(root)
    let context = app.rootCapabilities
    let first = app.loadCapabilityDomainModule("first", "r1", root / "plugin",
      "entry.gene", context)
    let compiledFirst = app.moduleCompileArtifactCount
    let second = app.loadCapabilityDomainModule("second", "r1", root / "plugin",
      "entry.gene", context)
    check app.moduleCompileArtifactCount > compiledFirst
    let scope = newGlobalScope(app)
    scope.define("first", first)
    scope.define("second", second)
    check run(compileSource("[(same? first/Request second/Request) " &
      "(same? first/Handler second/Handler)]"), scope).print() == "[false false]"
    check run(compileSource("(first/dispatch (first/Request ^value 7))"), scope).print() == "7"
    expect GeneError:
      discard run(compileSource("(second/dispatch (first/Request ^value 7))"), scope)

  test "preinitialized shared contracts bridge host and plugin identities":
    let root = expandFilename(createTempDir("gene-domain-shared-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "contracts.gene", """
(type Request ^props {^value Int})
(protocol Handler (message handle [request : Request] : Int))
""")
    writeFile(root / "plugin" / "entry.gene", """
(import [Request Handler] ^from "../contracts")
(fn request_type [] Request)
(fn handler_type [] Handler)
(type Local ^props {})
(impl Handler for Local (message handle [request : Request] : Int request/value))
(fn dispatch [request : Request] : Int ((Local) .Handler:handle request))
""")
    let app = capabilityDomainApp(root)
    let contract = app.loadFileModule(root / "contracts.gene")
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities, @[root / "contracts.gene"])
    let scope = newGlobalScope(app)
    scope.define("contract", contract)
    scope.define("plugin", plugin)
    check run(compileSource("[(same? contract/Request (plugin/request_type)) " &
      "(same? contract/Handler (plugin/handler_type)) " &
      "(plugin/dispatch (contract/Request ^value 9))]"), scope).print() == "[true true 9]"

  test "identical normalized domains reuse initialized declarations and compiled artifacts":
    let root = expandFilename(createTempDir("gene-domain-reuse-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", "(type Item ^props {})")
    let app = capabilityDomainApp(root)
    let registry = app.capabilities
    let empty = registry.normalizeCapabilityRow(
      readCapabilityLiteral("[]", cuBound, CapabilitySourceContext()), cuBound)
    let firstContext = registry.attenuateCapabilities(app.rootCapabilities, empty)
    let secondContext = registry.attenuateCapabilities(app.rootCapabilities, empty)
    let first = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", firstContext)
    let artifacts = app.moduleCompileArtifactCount
    let second = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", secondContext)
    check first.bits == second.bits
    check app.moduleCompileArtifactCount == artifacts
    let nextRevision = app.loadCapabilityDomainModule("plugin", "r2", root / "plugin",
      "entry.gene", secondContext)
    check nextRevision.bits != first.bits
    let scope = newGlobalScope(app)
    scope.define("first", first)
    scope.define("next", nextRevision)
    check run(compileSource("(same? first/Item next/Item)"), scope).print() == "false"

  test "an uninitialized shared module cannot acquire host startup authority":
    let root = expandFilename(createTempDir("gene-domain-cold-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "contracts.gene", "(type Item ^props {})")
    writeFile(root / "plugin" / "entry.gene", "(import [Item] ^from \"../contracts\")")
    let app = capabilityDomainApp(root)
    expect GeneError:
      discard app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
        "entry.gene", app.rootCapabilities, @[root / "contracts.gene"])
    check app.moduleCacheEntryCount == 0

  test "initialization uses the supplied bound before any application effect":
    let root = expandFilename(createTempDir("gene-domain-init-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    let target = root / "forbidden.txt"
    writeFile(root / "plugin" / "entry.gene",
      "($fs/write_text \"" & target & "\" \"forbidden\")")
    let app = newApplication(root)
    let row = app.capabilities.normalizeCapabilityRow(readCapabilityLiteral(
      "[(fs/ReadWrite \"" & root & "\")]", cuGrant,
      CapabilitySourceContext()), cuGrant)
    let grant = app.filesystemCapabilities.initializeFilesystemGrant(row.entries[0].policy)
    defer: app.filesystemCapabilities.releaseFilesystemGrant(grant)
    app.setRootCapabilities(app.capabilities.newPolicyContext([grant]))
    let empty = app.capabilities.newPolicyContext([])
    var denied = ""
    try:
      discard app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
        "entry.gene", empty, exposedNamespaces = @["fs"])
    except GeneError as error:
      denied = error.msg
    check "capability" in denied.toLowerAscii
    check not fileExists(target)
    discard app.loadCapabilityDomainModule("allowed", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities, exposedNamespaces = @["fs"])
    check readFile(target) == "forbidden"

  test "module-level legacy contracts are rejected in an admitted v1 domain":
    let root = expandFilename(createTempDir("gene-domain-contract-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", "(mod entry ^capabilities [] (var value 1))")
    let app = capabilityDomainApp(root)
    expect GeneError:
      discard app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
        "entry.gene", app.rootCapabilities)

  test "unsupported output and database effects stay rejected through empty boundaries":
    let root = expandFilename(createTempDir("gene-domain-effects-", ""))
    defer: removeDir(root)
    for source in [
      "($println \"forbidden\")",
      "(with_capabilities [] ($println \"forbidden\"))",
      "(fn denied [] ^capabilities [] ($println \"forbidden\")) (denied)",
      "($os/read_line)",
      "($db/sqlite/open \":memory:\")"]:
      let app = capabilityDomainApp(root)
      var rejected = ""
      try:
        discard app.domainSource(source)
      except GeneError as error:
        rejected = error.msg
      checkpoint source
      check "UnsupportedCapability" in rejected

  test "loader policy changes cannot reuse a warmer domain with broader shared imports":
    let root = expandFilename(createTempDir("gene-domain-shared-policy-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "contracts.gene", "(type Item ^props {})")
    writeFile(root / "plugin" / "entry.gene", "(import [Item] ^from \"../contracts\")")
    let app = capabilityDomainApp(root)
    discard app.loadFileModule(root / "contracts.gene")
    discard app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities, @[root / "contracts.gene"])
    expect GeneError:
      discard app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
        "entry.gene", app.rootCapabilities)

  test "unadmitted dependency source is rejected before reading its compiler header":
    let root = expandFilename(createTempDir("gene-domain-source-policy-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "private.gene", "(var secret 42)")
    writeFile(root / "plugin" / "entry.gene", "(import [secret] ^from \"../private\")")
    let app = capabilityDomainApp(root)
    expect GeneError:
      discard app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
        "entry.gene", app.rootCapabilities)
    check app.moduleCompileHeaderCount == 1

  test "failed initialization is cached in its domain until an explicit new revision":
    let root = expandFilename(createTempDir("gene-domain-failure-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "contracts.gene", "(var attempts ($cell 0))")
    writeFile(root / "plugin" / "entry.gene", """
(import [attempts] ^from "../contracts")
(attempts .set (+ (attempts .get) 1))
missing_domain_symbol
""")
    let app = capabilityDomainApp(root)
    let contract = app.loadFileModule(root / "contracts.gene")
    for attempt in 0..1:
      expect GeneError:
        discard app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
          "entry.gene", app.rootCapabilities, @[root / "contracts.gene"])
    let scope = newGlobalScope(app)
    scope.define("contract", contract)
    check run(compileSource("(contract/attempts .get)"), scope).print() == "1"
    expect GeneError:
      discard app.loadCapabilityDomainModule("plugin", "r2", root / "plugin",
        "entry.gene", app.rootCapabilities, @[root / "contracts.gene"])
    check run(compileSource("(contract/attempts .get)"), scope).print() == "2"
