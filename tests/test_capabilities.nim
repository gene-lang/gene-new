import gene/capabilities
import gene/fs_capabilities
import gene/host_capabilities
import gene/[compiler, gir, printer, reader, types, vm]
import std/[options, os, strutils, tables, unittest]

type
  TestDirProvider = ref object of CapabilityProvider

method validity(provider: TestDirProvider,
                grant: CapabilityGrant): CapabilityValidity =
  discard provider
  grant.sealedValidity

proc isWithin(path, root: string): bool =
  path == root or path.startsWith(root & "/")

method resolve(provider: TestDirProvider, parent: CapabilityGrant,
               requested: CapabilitySpec): Option[CapabilityGrant] =
  let sameType = parent.capabilityType == requested.capabilityType
  let writeDirToFile = parent.capabilityType.name.endsWith("/WriteDir") and
    requested.capabilityType.name.endsWith("/WriteFile")
  if not sameType and not writeDirToFile:
    return none(CapabilityGrant)
  let requestedPath = requested.positionalString(0)
  let parentPath = parent.scope
  if requestedPath.isWithin(parentPath):
    some(provider.deriveGrant(parent, requested.capabilityType, requestedPath))
  else:
    none(CapabilityGrant)

method intersect(provider: TestDirProvider,
                 left, right: openArray[CapabilityGrant]): seq[CapabilityGrant] =
  for a in left:
    for b in right:
      if a.capabilityType != b.capabilityType:
        continue
      if a.scope.isWithin(b.scope):
        result.add provider.intersectGrant(a, b, a.capabilityType, a.scope)
      elif b.scope.isWithin(a.scope):
        result.add provider.intersectGrant(a, b, a.capabilityType, b.scope)

proc newGeneFacadeTestApp(capabilityName, identity, schema: string,
                          root = "/workspace"): Application =
  newApplicationConfigured(getCurrentDir(),
    proc(registry: CapabilityRegistry, filesystem: FilesystemProvider,
         host: HostCapabilityProvider): seq[CapabilityGrant] =
      discard filesystem
      discard host
      let provider = TestDirProvider()
      registry.admitProvider(provider, "app")
      let capabilityType = registry.admitGeneType(provider,
        capabilityName, identity, schema)
      @[provider.mintRootGrant(capabilityType, root)])

proc newApplicationRootedAt(root: string): Application =
  ## `newApplication`'s argument anchors *module resolution* only; filesystem
  ## authority deliberately follows the launch directory so `gene run
  ## path/to/app.gene` cannot reinterpret "tmp/x" beneath the entry file
  ## (vm.nim, newApplicationState). A fixture operating under `root` grants it
  ## the way an embedding host or `--allow_read_write_dir` would.
  result = newApplication(root)
  result.setRootCapabilities(newCapabilityContext(
    @(result.rootCapabilities.grants) &
    @[result.filesystemCapabilities.grantReadWriteDir(root)]))

proc facadeSchema(name: string, hasStringBody = true): string =
  capabilityFacadeSchemaHash(name, bodySchema =
    (if hasStringBody: newList(@[newSym("Str")]) else: NIL))

suite "capability providers":
  test "provider admission is exclusive and frozen before program code":
    let registry = newCapabilityRegistry()
    let first = TestDirProvider()
    let second = TestDirProvider()
    registry.admitProvider(first, "first")
    let owned = registry.admitType(first, "app/Owned")
    expect CapabilityError:
      registry.admitProvider(second, "first")
    registry.admitProvider(second, "second")
    expect CapabilityError:
      discard registry.admitType(second, "app/Owned")
    let foreign = registry.admitType(second, "app/Foreign")
    expect CapabilityError:
      registry.admitEntailment(first, owned, foreign)
    registry.freeze()
    expect CapabilityError:
      discard registry.admitType(first, "app/Late")

  test "the host provider narrows nominal authority without widening it":
    let registry = newCapabilityRegistry()
    let provider = registry.admitHostCapabilityProvider()
    registry.freeze()
    let root = provider.grant(provider.types.netConnect)
    let broad = newCapabilitySpec(provider.types.netConnect)
    let exact = newCapabilitySpec(provider.types.netConnect,
      named = [capNamed("host", capString("example.com")),
               capNamed("port", capInt(443))])
    let other = newCapabilitySpec(provider.types.netConnect,
      named = [capNamed("host", capString("other.example")),
               capNamed("port", capInt(443))])

    let narrowed = provider.resolve(root, exact)
    check narrowed.isSome
    check provider.resolve(narrowed.get, exact).isSome
    check provider.resolve(narrowed.get, broad).get == narrowed.get
    check provider.resolve(narrowed.get, other).isNone
    check provider.subsumes(broad, exact) == csYes
    check provider.subsumes(exact, broad) == csNo

  test "bare empty and star selectors have one nominal meaning":
    let registry = newCapabilityRegistry()
    let provider = registry.admitHostCapabilityProvider()
    registry.freeze()
    let root = provider.grant(provider.types.osEnv)
    let context = newCapabilityContext([root])
    let bare = registry.resolveSelector(context,
      newCapabilitySpec(provider.types.osEnv))
    let star = registry.resolveSelector(context,
      newCapabilitySpec(provider.types.osEnv, [capString("*")]))
    check bare.len == 1
    check star.len == 1
    check bare[0].semanticKey == star[0].semanticKey

  test "namespace projection selects inherited grants and never the catalog":
    let registry = newCapabilityRegistry()
    let fs = registry.admitFilesystemProvider()
    let host = registry.admitHostCapabilityProvider()
    registry.freeze()
    let context = newCapabilityContext([
      fs.grantReadDir("/workspace"),
      host.grant(host.types.osEnv)
    ])
    let projected = registry.resolveProjection(context, "fs")
    check projected.len == 1
    check projected[0].capabilityType == fs.types.readDir
    check registry.resolveProjection(newCapabilityContext(), "fs").len == 0

  test "resolution can narrow inherited authority but cannot widen it":
    let registry = newCapabilityRegistry()
    let provider = TestDirProvider()
    registry.admitProvider(provider, "test_fs")
    let writeDir = registry.admitType(provider, "test_fs/WriteDir")
    registry.freeze()

    let root = provider.mintRootGrant(writeDir, "/workspace")
    let narrowed = provider.resolve(
      root, newCapabilitySpec(writeDir, [capString("/workspace/tmp")]))
    check narrowed.isSome
    check narrowed.get.scope == "/workspace/tmp"

    let widened = provider.resolve(
      narrowed.get, newCapabilitySpec(writeDir, [capString("/")]))
    check widened.isNone

  test "revoking an ancestor invalidates every derived grant":
    let registry = newCapabilityRegistry()
    let provider = TestDirProvider()
    registry.admitProvider(provider, "test_fs")
    let writeDir = registry.admitType(provider, "test_fs/WriteDir")
    registry.freeze()

    let root = provider.mintRootGrant(writeDir, "/workspace")
    let child = provider.resolve(
      root, newCapabilitySpec(writeDir, [capString("/workspace/tmp")])).get
    check child.isValid

    provider.revoke(root)
    check not root.isValid
    check not child.isValid

  test "context intersection is provider-owned and keeps both revocation lineages":
    let registry = newCapabilityRegistry()
    let provider = TestDirProvider()
    registry.admitProvider(provider, "test_fs")
    let writeDir = registry.admitType(provider, "test_fs/WriteDir")
    registry.freeze()

    let callerGrant = provider.mintRootGrant(writeDir, "/workspace")
    let ceilingGrant = provider.mintRootGrant(writeDir, "/workspace/tmp")
    let caller = newCapabilityContext([callerGrant])
    let ceiling = newCapabilityContext([ceilingGrant])
    let effective = intersectContexts(caller, ceiling)

    check effective.len == 1
    check effective[0].scope == "/workspace/tmp"
    check effective[0].isValid

    provider.revoke(ceilingGrant)
    check not effective[0].isValid

  test "registered same-provider entailment resolves a related capability type":
    let registry = newCapabilityRegistry()
    let provider = TestDirProvider()
    registry.admitProvider(provider, "test_fs")
    let writeDir = registry.admitType(provider, "test_fs/WriteDir")
    let writeFile = registry.admitType(provider, "test_fs/WriteFile")
    registry.admitEntailment(provider, writeDir, writeFile)
    registry.freeze()

    let root = provider.mintRootGrant(writeDir, "/workspace")
    let context = newCapabilityContext([root])
    let matches = registry.resolveSelector(context,
      newCapabilitySpec(writeFile, [capString("/workspace/tmp/test.md")]))

    check matches.len == 1
    check matches[0].capabilityType == writeFile
    check matches[0].scope == "/workspace/tmp/test.md"
    check registry.resolveSelector(context,
      newCapabilitySpec(writeFile, [capString("/outside/test.md")])).len == 0

  test "equivalent derivations and contexts have stable semantic identity":
    let registry = newCapabilityRegistry()
    let provider = TestDirProvider()
    registry.admitProvider(provider, "test_fs")
    let writeDir = registry.admitType(provider, "test_fs/WriteDir")
    registry.freeze()

    let root = provider.mintRootGrant(writeDir, "/workspace")
    let requested = newCapabilitySpec(
      writeDir, [capString("/workspace/tmp")])
    let first = provider.resolve(root, requested).get
    let second = provider.resolve(root, requested).get

    check first.semanticKey == second.semanticKey
    check first == second
    check newCapabilityContext([root, first]) ==
      newCapabilityContext([first, root, first])

  test "a revoked cached derivative is never returned as a valid result":
    let registry = newCapabilityRegistry()
    let provider = TestDirProvider()
    registry.admitProvider(provider, "test_fs")
    let writeDir = registry.admitType(provider, "test_fs/WriteDir")
    registry.freeze()

    let root = provider.mintRootGrant(writeDir, "/workspace")
    let requested = newCapabilitySpec(
      writeDir, [capString("/workspace/tmp")])
    let first = provider.resolve(root, requested).get
    let epoch = registry.capabilityEpoch
    provider.revoke(first)
    check registry.capabilityEpoch > epoch
    check not first.isValid

    let second = provider.resolve(root, requested).get
    check second.isValid
    check second != first

  test "entailment is transitive and cycles are rejected":
    let registry = newCapabilityRegistry()
    let provider = TestDirProvider()
    registry.admitProvider(provider, "test_fs")
    let writeDir = registry.admitType(provider, "test_fs/WriteDir")
    let intermediate = registry.admitType(provider, "test_fs/Intermediate")
    let writeFile = registry.admitType(provider, "test_fs/WriteFile")
    registry.admitEntailment(provider, writeDir, intermediate)
    registry.admitEntailment(provider, intermediate, writeFile)
    expect CapabilityError:
      registry.admitEntailment(provider, writeFile, writeDir)
    registry.freeze()

    let root = provider.mintRootGrant(writeDir, "/workspace")
    let context = newCapabilityContext([root])
    check registry.resolveSelector(context,
      newCapabilitySpec(writeFile,
        [capString("/workspace/tmp/test.md")])).len == 1

  test "dynamic grant and context interning remain bounded":
    let registry = newCapabilityRegistry()
    let provider = TestDirProvider()
    registry.admitProvider(provider, "test_fs")
    let writeDir = registry.admitType(provider, "test_fs/WriteDir")
    registry.freeze()
    let root = provider.mintRootGrant(writeDir, "/workspace")
    for i in 0 .. MaxCapabilityGrantCacheEntries + 16:
      let child = provider.resolve(root, newCapabilitySpec(
        writeDir, [capString("/workspace/" & $i)])).get
      discard newCapabilityContext([child])
    check provider.cachedGrantCount <= MaxCapabilityGrantCacheEntries
    check registry.internedContextCount <= MaxCapabilityContextInternEntries

  test "filesystem intersections obey set algebra by semantic identity":
    let registry = newCapabilityRegistry()
    let fs = registry.admitFilesystemProvider()
    registry.freeze()
    let broad = newCapabilityContext([fs.grantReadWriteDir("/workspace")])
    let middle = newCapabilityContext([fs.grantReadWriteDir("/workspace/tmp")])
    let narrow = newCapabilityContext([
      fs.grantReadWriteDir("/workspace/tmp/nested")
    ])

    let idempotent = intersectContexts(broad, broad)
    check idempotent.len == 1
    check idempotent[0].capabilityType == fs.types.readWriteDir
    check idempotent.semanticKey == broad.semanticKey

    let broadMiddle = intersectContexts(broad, middle)
    let middleBroad = intersectContexts(middle, broad)
    check broadMiddle.semanticKey == middleBroad.semanticKey
    check broadMiddle.len == 1
    check broadMiddle[0].capabilityType == fs.types.readWriteDir

    let leftGrouped = intersectContexts(broadMiddle, narrow)
    let rightGrouped = intersectContexts(broad,
      intersectContexts(middle, narrow))
    check leftGrouped.semanticKey == rightGrouped.semanticKey
    check leftGrouped.len == 1
    check leftGrouped[0].scope == "/workspace/tmp/nested"

    fs.revoke(middle[0])
    check not leftGrouped[0].isValid
    check not rightGrouped[0].isValid

suite "filesystem capability provider":
  test "a write-directory root resolves only files beneath that directory":
    let registry = newCapabilityRegistry()
    let fs = registry.admitFilesystemProvider()
    registry.freeze()
    let root = fs.grantWriteDir("/workspace/tmp")
    let context = newCapabilityContext([root])

    let allowed = registry.resolveSelector(context,
      newCapabilitySpec(fs.types.writeFile,
                        [capString("/workspace/tmp/test.md")]))
    check allowed.len == 1
    check allowed[0].scope == "/workspace/tmp/test.md"

    let escaped = registry.resolveSelector(context,
      newCapabilitySpec(fs.types.writeFile,
                        [capString("/workspace/secret.md")]))
    check escaped.len == 0

  test "provider-owned adapters enforce the active exact file grant":
    let root = getTempDir() / "gene-capability-adapter-test"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    createDir(root / "tmp")
    defer:
      if fileExists(root / "tmp" / "test.md"):
        removeFile(root / "tmp" / "test.md")
      removeDir(root / "tmp")
      removeDir(root)

    let registry = newCapabilityRegistry()
    let fs = registry.admitFilesystemProvider()
    registry.freeze()
    let broad = newCapabilityContext([fs.grantWriteDir(root)])
    let exact = newCapabilityContext(registry.resolveSelector(
      broad, newCapabilitySpec(fs.types.writeFile,
                               [capString("tmp/test.md")])))
    fs.writeText(exact, "tmp/test.md", "hello")
    check readFile(root / "tmp" / "test.md") == "hello"
    expect FilesystemCapabilityError:
      fs.writeText(exact, "tmp/other.md", "escape")

  test "directory narrowing keeps the original trusted operation anchor":
    let root = getTempDir() / "gene-capability-anchor-test"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    createDir(root / "tmp")
    defer:
      if fileExists(root / "tmp" / "test.md"):
        removeFile(root / "tmp" / "test.md")
      removeDir(root / "tmp")
      removeDir(root)

    let registry = newCapabilityRegistry()
    let fs = registry.admitFilesystemProvider()
    registry.freeze()
    let broad = newCapabilityContext([fs.grantWriteDir(root)])
    let directory = newCapabilityContext(registry.resolveSelector(
      broad, newCapabilitySpec(fs.types.writeDir, [capString("tmp")])))
    let exact = newCapabilityContext(registry.resolveSelector(
      directory,
      newCapabilitySpec(fs.types.writeFile, [capString("test.md")])))

    check exact.len == 1
    check exact[0].scope == canonicalCapabilityPath(root) / "tmp" / "test.md"
    check exact[0].resolutionBase == canonicalCapabilityPath(root) / "tmp"
    check exact[0].operationAnchor == canonicalCapabilityPath(root)
    fs.writeText(exact, "test.md", "anchored")
    check readFile(root / "tmp" / "test.md") == "anchored"

  test "provider-owned directory and metadata adapters stay confined":
    let root = getTempDir() / "gene-capability-directory-adapter-test"
    let outside = getTempDir() / "gene-capability-directory-adapter-outside"
    if dirExists(root):
      removeDir(root)
    if dirExists(outside):
      removeDir(outside)
    createDir(root)
    createDir(outside)
    defer:
      if fileExists(root / "nested" / "file.txt"):
        removeFile(root / "nested" / "file.txt")
      when defined(posix):
        if symlinkExists(root / "escape"):
          removeFile(root / "escape")
      if dirExists(root / "nested"):
        removeDir(root / "nested")
      removeDir(root)
      if fileExists(outside / "escaped.txt"):
        removeFile(outside / "escaped.txt")
      removeDir(outside)

    let registry = newCapabilityRegistry()
    let fs = registry.admitFilesystemProvider()
    registry.freeze()
    let context = newCapabilityContext([fs.grantReadWriteDir(root)])

    fs.makeDir(context, "nested")
    fs.writeText(context, "nested/file.txt", "content")
    check fs.pathExists(context, "nested/file.txt")
    check not fs.pathExists(context, "nested/missing.txt")
    check fs.listDir(context, "nested") == @["file.txt"]
    check fs.realPath(context, "nested/file.txt") ==
      canonicalCapabilityPath(root) / "nested" / "file.txt"
    fs.removeFile(context, "nested/file.txt")
    check not fileExists(root / "nested" / "file.txt")
    fs.removeDir(context, "nested")
    check not dirExists(root / "nested")

    when defined(posix):
      createSymlink(outside, root / "escape")
      expect FilesystemCapabilityError:
        discard fs.pathExists(context, "escape")
      expect FilesystemCapabilityError:
        fs.writeText(context, "escape/escaped.txt", "escape")
      check not fileExists(outside / "escaped.txt")

  test "write-file properties are canonical, enforced, and attenuating":
    let root = getTempDir() / "gene-capability-write-policy-test"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    defer:
      if fileExists(root / "append.txt"):
        removeFile(root / "append.txt")
      if fileExists(root / "existing.txt"):
        removeFile(root / "existing.txt")
      removeDir(root)

    let registry = newCapabilityRegistry()
    let fs = registry.admitFilesystemProvider()
    registry.freeze()
    let broad = newCapabilityContext([fs.grantWriteDir(root)])
    let appendGrants = registry.resolveSelector(broad,
      newCapabilitySpec(fs.types.writeFile, [capString("append.txt")],
        [capNamed("append", capBool(true))]))
    check appendGrants.len == 1
    let appendOnly = newCapabilityContext(appendGrants)
    fs.writeText(appendOnly, "append.txt", "a")
    fs.writeText(appendOnly, "append.txt", "b")
    check readFile(root / "append.txt") == "ab"

    let truncateGrants = registry.resolveSelector(broad,
      newCapabilitySpec(fs.types.writeFile, [capString("append.txt")]))
    check intersectContexts(appendOnly,
      newCapabilityContext(truncateGrants)).len == 0
    check registry.resolveSelector(appendOnly,
      newCapabilitySpec(fs.types.writeFile, [capString("append.txt")])).len == 0

    writeFile(root / "existing.txt", "old")
    let noCreate = newCapabilityContext(registry.resolveSelector(broad,
      newCapabilitySpec(fs.types.writeFile, [capString("existing.txt")],
        [capNamed("create", capBool(false))])))
    fs.writeText(noCreate, "existing.txt", "new")
    check readFile(root / "existing.txt") == "new"
    removeFile(root / "existing.txt")
    expect FilesystemCapabilityError:
      fs.writeText(noCreate, "existing.txt", "denied")

    expect FilesystemCapabilityError:
      discard registry.resolveSelector(broad,
        newCapabilitySpec(fs.types.writeFile, [capString("bad.txt")],
          [capNamed("unknown", capBool(true))]))
    expect FilesystemCapabilityError:
      discard registry.resolveSelector(broad,
        newCapabilitySpec(fs.types.writeFile, [capString("link.txt")],
          [capNamed("follow_symlinks", capBool(true))]))

suite "capability specifications in Gene":
  test "calling a capability type constructs an inert specification":
    let scope = newGlobalScope()
    let value = run(compileSource("(fs/WriteDir \"tmp\")"), scope)
    check value.print == "(fs/WriteDir \"tmp\")"

  test "named properties remain inert specification data":
    let scope = newGlobalScope()
    let value = run(
      compileSource("(fs/WriteFile ^append true \"tmp/test.md\")"), scope)
    check value.print == "(fs/WriteFile ^append true \"tmp/test.md\")"

  test "reflection exposes canonical rows and the enforcing provider":
    let scope = newGlobalScope(newApplication())
    let value = run(compileSource("""
      (fn write_report [filename]
        ^capabilities [(fs/WriteFile filename)]
        nil)
      [(capabilities_of write_report)
       (capability_type_info fs/WriteDir)]
    """), scope)
    check value.listItems[0].print == "[(fs/WriteFile filename)]"
    let info = value.listItems[1]
    check info.mapEntries["provider"].strVal == "fs"
    check info.mapEntries["enforced"].boolVal

  test "a host-admitted Gene facade canonicalizes and resolves end to end":
    let schema = facadeSchema("WriteArea")
    let app = newGeneFacadeTestApp("app/WriteArea",
      "program#WriteArea", schema)
    let source = """
      (type WriteArea
        ^capability "app/WriteArea"
        ^body [Str]
        (impl CapabilitySpec
          (message canonicalize []
            ^capabilities []
            ($freeze (WriteArea ($str/lower self/0))))))
      (fn inspect [path]
        ^capabilities [(app/WriteArea path)]
        (let info (capability_type_info WriteArea))
        [(check_capabilities (WriteArea path))
         info/provider])
      (inspect "/WORKSPACE/TMP")
    """
    let value = run(compileSource(source), newGlobalScope(app))
    check value.print == "[true \"app\"]"

  test "a linked facade without explicit CapabilitySpec conformance is rejected":
    let schema = facadeSchema("NoSpec")
    let app = newGeneFacadeTestApp("app/NoSpec",
      "program#NoSpec", schema)
    expect GeneError:
      discard run(compileSource("""
        (type NoSpec
          ^capability "app/NoSpec"
          ^body [Str])
        (fn use [path]
          ^capabilities [(app/NoSpec path)]
          true)
        (use "/workspace/tmp")
      """), newGlobalScope(app))

  test "custom canonicalization rejects mutable and non-idempotent results":
    let mutableSchema = facadeSchema("MutableArea")
    let mutableApp = newGeneFacadeTestApp("app/MutableArea",
      "program#MutableArea", mutableSchema)
    expect GeneError:
      discard run(compileSource("""
        (type MutableArea
          ^capability "app/MutableArea"
          ^body [Str]
          (impl CapabilitySpec
            (message canonicalize []
              ^capabilities []
              (MutableArea self/0))))
        (fn use [path]
          ^capabilities [(app/MutableArea path)]
          true)
        (use "/workspace/tmp")
      """), newGlobalScope(mutableApp))

    let unstableSchema = facadeSchema("UnstableArea")
    let unstableApp = newGeneFacadeTestApp("app/UnstableArea",
      "program#UnstableArea", unstableSchema)
    expect GeneError:
      discard run(compileSource("""
        (var alternate false)
        (type UnstableArea
          ^capability "app/UnstableArea"
          ^body [Str]
          (impl CapabilitySpec
            (message canonicalize []
              ^capabilities []
              (set alternate (! alternate))
              ($freeze (UnstableArea
                (if alternate "/workspace/a" "/workspace/b"))))))
        (fn use [path]
          ^capabilities [(app/UnstableArea path)]
          true)
        (use "/workspace/tmp")
      """), newGlobalScope(unstableApp))

  test "a Gene facade cannot claim a mismatched admitted identity":
    let schema = facadeSchema("Claimed", hasStringBody = false)
    let app = newApplicationConfigured(getCurrentDir(),
      proc(registry: CapabilityRegistry, filesystem: FilesystemProvider,
           host: HostCapabilityProvider): seq[CapabilityGrant] =
        discard filesystem
        discard host
        let provider = TestDirProvider()
        registry.admitProvider(provider, "app")
        discard registry.admitGeneType(provider, "app/Claimed",
          "attacker/app#Claimed", schema)
        @[])
    expect GeneError:
      discard run(compileSource("""
        (type Claimed
          ^capability "app/Claimed")
      """), newGlobalScope(app))

  test "a Gene facade schema must match the admitted descriptor":
    let admittedSchema = facadeSchema("SchemaArea", hasStringBody = false)
    let app = newGeneFacadeTestApp("app/SchemaArea",
      "program#SchemaArea", admittedSchema)
    expect GeneError:
      discard run(compileSource("""
        (type SchemaArea
          ^capability "app/SchemaArea"
          ^body [Str]
          (impl CapabilitySpec
            (message canonicalize []
              ^capabilities []
              ($freeze self))))
      """), newGlobalScope(app))

  test "an admitted but unlinked Gene facade raises UnsupportedCapability":
    let app = newGeneFacadeTestApp("app/UnlinkedArea",
      "program#UnlinkedArea", facadeSchema("UnlinkedArea"))
    let value = run(compileSource("""
      (fn use [path]
        ^capabilities [(app/UnlinkedArea path)]
        true)
      (try (use "/workspace/tmp")
        catch UnsupportedCapability "unsupported")
    """), newGlobalScope(app))
    check value.strVal == "unsupported"

suite "compiled capability declarations":
  test "an enforced compiler catalog rejects unadmitted capability types":
    let source = readAllWithLocs("""
      (fn use []
        ^capabilities [(app/Unknown)]
        nil)
    """, "unknown_capability.gene")
    let imported = initTable[string, Table[string, MacroDef]]()
    let catalog = initTable[string, CapabilityCompileDescriptor]()
    expect GeneError:
      discard compileFormsWithMacros(source, imported,
        capabilityCatalog = catalog,
        enforceCapabilityCatalog = true)

  test "parameter-dependent rows compile to slot descriptors":
    let chunk = compileSource("""
      (fn write_file [filename content]
        ^capabilities [(fs/WriteFile filename ^append true)]
        nil)
    """)
    check chunk.functions.len == 1
    let row = chunk.functions[0].capabilityRow
    check row.kind == crkSelect
    check row.selectors.len == 1
    check row.selectors[0].kind == cskExact
    check row.selectors[0].typeName == "fs/WriteFile"
    check row.selectors[0].positional[0].kind == ctakParameter
    check row.selectors[0].positional[0].parameterName == "filename"
    check row.selectors[0].named[0].name == "append"
    check row.selectors[0].named[0].value.literal.boolValue

  test "deeply immutable custom selector data compiles canonically":
    let chunk = compileSource("""
      (fn use []
        ^capabilities [(app/Publish #[events #{^durable true}])]
        nil)
    """)
    let argument = chunk.functions[0].capabilityRow.selectors[0].positional[0]
    check argument.kind == ctakLiteral
    check argument.literal.kind == cakList
    check argument.literal.listValue[0].kind == cakSymbol
    check argument.literal.listValue[0].symbolValue == "events"
    check argument.literal.listValue[1].kind == cakMap
    check argument.literal.listValue[1].mapValue[0].name == "durable"
    check argument.literal.listValue[1].mapValue[0].value.boolValue

    for source in [
      "(fn bad [] ^capabilities [(app/Publish [events])] nil)",
      "(fn bad [] ^capabilities [(app/Publish {^durable true})] nil)"
    ]:
      expect GeneError:
        discard compileSource(source)

  test "built-in filesystem selector shape is validated while compiling":
    for source in [
      "(fn bad [] ^capabilities [(fs/WriteFile \"x\" ^unknown true)] nil)",
      "(fn bad [] ^capabilities [(fs/ReadDir \"x\" ^append true)] nil)",
      "(fn bad [] ^capabilities [(fs/WriteFile 7)] nil)",
      "(fn bad [] ^capabilities [(fs/WriteFile \"x\" ^create \"yes\")] nil)",
      "(fn bad [] ^capabilities [(fs/WriteFile \"x\" ^follow_symlinks true)] nil)"
    ]:
      expect GeneError:
        discard compileSource(source)

  test "strict public functions require an explicit row":
    expect GeneError:
      discard compileSource("""
        (mod strict_app ^capabilities_mode strict
          (fn exposed [] nil))
      """)
    discard compileSource("""
      (mod strict_app ^capabilities_mode strict
        (fn exposed [] ^capabilities * nil)
        (fn hidden ^^private [] nil))
    """)

  test "strict public protocol and method declarations require rows":
    expect GeneError:
      discard compileSource("""
        (mod strict_app ^capabilities_mode strict
          (protocol P (message act [])))
      """)
    expect GeneError:
      discard compileSource("""
        (mod strict_app ^capabilities_mode strict
          (type T (message act [] nil)))
      """)
    discard compileSource("""
      (mod strict_app ^capabilities_mode strict
        (protocol P
          (message act [] ^capabilities []))
        (type T
          (message act [] ^capabilities [] nil)))
    """)

  test "protocol implementations cannot broaden capability contracts":
    let scope = newGlobalScope(newApplication())
    expect GeneError:
      discard run(compileSource("""
        (protocol P
          (message act [] ^capabilities [(fs/WriteDir "tmp")]))
        (type T)
        (impl P for T
          (message act []
            ^capabilities [(fs/WriteDir "other")]
            nil))
      """), scope)
    discard run(compileSource("""
      (protocol Q
        (message act [] ^capabilities [(fs/WriteDir "tmp")]))
      (type U)
      (impl Q for U
        (message act []
          ^capabilities [(fs/WriteDir "tmp")]
          nil))
    """), newGlobalScope(newApplication()))

    discard run(compileSource("""
      (protocol Narrowable
        (message act [] ^capabilities [(fs/WriteDir "tmp")]))
      (type NarrowWriter)
      (impl Narrowable for NarrowWriter
        (message act []
          ^capabilities [(fs/WriteFile "tmp/result.md")]
          nil))
    """), newGlobalScope(newApplication()))

    expect GeneError:
      discard run(compileSource("""
        (protocol OptionalP
          (message act []
            ^capabilities [(fs/WriteDir "tmp" ^^optional)]))
        (type RequiredWriter)
        (impl OptionalP for RequiredWriter
          (message act []
            ^capabilities [(fs/WriteDir "tmp")]
            nil))
      """), newGlobalScope(newApplication()))

    discard run(compileSource("""
      (protocol Renamed
        (message save [destination]
          ^capabilities [(fs/WriteFile destination)]))
      (type RenamedWriter)
      (impl Renamed for RenamedWriter
        (message save [path]
          ^capabilities [(fs/WriteFile path)]
          nil))
    """), newGlobalScope(newApplication()))

suite "capability call boundaries":
  test "a missing mandatory selector fails before the function body":
    let app = newApplication()
    let scope = newGlobalScope(app)
    app.setRootCapabilities(newCapabilityContext())
    check app.rootCapabilities.len == 0
    check app.capabilities.resolveSelector(
      app.rootCapabilities,
      newCapabilitySpec(app.filesystemCapabilities.types.writeDir,
                        [capString("tmp")])).len == 0
    expect GeneError:
      discard run(compileSource("""
        (var entered false)
        (fn guarded []
          ^capabilities [(fs/WriteDir "tmp")]
          (set entered true))
        (guarded)
      """), scope)
    check not scope.lookup("entered").boolVal

  test "a nested declaration cannot recover authority removed by its parent":
    let app = newApplication()
    let scope = newGlobalScope(app)
    expect GeneError:
      discard run(compileSource("""
        (fn inner []
          ^capabilities [(fs/WriteDir "/")]
          1)
        (fn outer []
          ^capabilities [(fs/WriteDir "tmp")]
          (inner))
        (outer)
      """), scope)

  test "the parent context is restored after an error":
    let app = newApplication()
    let scope = newGlobalScope(app)
    let value = run(compileSource("""
      (fn fails []
        ^capabilities []
        (fail "expected"))
      (fn succeeds []
        ^capabilities [(fs/WriteDir "tmp")]
        7)
      (try (fails) catch Any nil)
      (succeeds)
    """), scope)
    check value.intVal == 7

  test "with_capabilities narrows dynamically and restores on exit":
    let app = newApplication()
    let scope = newGlobalScope(app)
    let value = run(compileSource("""
      (fn needs_tmp []
        ^capabilities [(fs/WriteDir "tmp")]
        7)
      (var denied false)
      (try
        (with_capabilities [] (needs_tmp))
        catch Any
        (set denied true))
      [denied (needs_tmp)]
    """), scope)
    check value.listItems[0].boolVal
    check value.listItems[1].intVal == 7

  test "with_capabilities can bind a lexical selector argument":
    let app = newApplication()
    let scope = newGlobalScope(app)
    let value = run(compileSource("""
      (let dir "tmp")
      (with_capabilities [(fs/WriteDir dir)] 9)
    """), scope)
    check value.intVal == 9

  test "spawn captures the attenuated context without mutating its parent":
    let value = run(compileSource("""
      (fn needs_tmp []
        ^capabilities [(fs/WriteDir "tmp")]
        7)
      (var child_result
        (scope
          (with_capabilities []
            (var task (spawn
              (try (needs_tmp)
                catch MissingCapability 9)))
            (await task))))
      [child_result (needs_tmp)]
    """), newGlobalScope(newApplication()))
    check value.print == "[9 7]"

  test "capability failures are typed recoverable errors":
    let value = run(compileSource("""
      (fn denied []
        ^capabilities []
        ($fs/read_text "missing.txt"))
      (try (denied)
        catch MissingCapability
        [$ex/capability $ex/operation])
    """), newGlobalScope(newApplication()))
    check value.print == "[\"fs/ReadFile\" \"fs/read_text\"]"

  test "a file database resource cannot restore authority in an empty context":
    let root = getTempDir() / "gene-capability-sqlite-resource"
    let databasePath = root / "database.sqlite"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    defer:
      for suffix in ["database.sqlite", "database.sqlite-wal",
                     "database.sqlite-shm", "database.sqlite-journal"]:
        if fileExists(root / suffix): removeFile(root / suffix)
      removeDir(root)
    let value = run(compileSource("""
      (import $db/sqlite [open Db])
      (var db (open """ & newStr(databasePath).print & """))
      (db .Db:exec "create table guarded (x integer)")
      (db .Db:execute "insert into guarded(x) values (?)" 7)
      (var write_denied false)
      (var read_denied false)
      (try
        (with_capabilities []
          (db .Db:exec "create table denied (x integer)"))
        catch MissingCapability
        (set write_denied true))
      (try
        (with_capabilities []
          (db .Db:query "select x from guarded"))
        catch MissingCapability
        (set read_denied true))
      (db .Db:close)
      [write_denied read_denied]
    """), newGlobalScope(newApplicationRootedAt(root)))
    check value.print == "[true true]"

  test "retained resource authority is released on close and final drop":
    let root = getTempDir() / "gene-capability-resource-lifecycle"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    defer:
      if dirExists(root): removeDir(root)
    let baseline = resourceAuthorityRecordCount()
    block:
      let app = newApplicationRootedAt(root)
      let scope = newGlobalScope(app)
      let resource = run(compileSource(
        "(import $store/fs [open]) (open ^root " &
        newStr(root).print & ")"), scope)
      check resourceAuthorityRecordCount() == baseline + 1
      discard run(compileSource(
        "(import $store/fs [open Store]) " &
        "(var s (open ^root " & newStr(root).print & ")) " &
        "(s .Store:close) s"), newGlobalScope(app))
      check resourceAuthorityRecordCount() == baseline + 1
      check resource.kind == vkNode
    check resourceAuthorityRecordCount() == baseline

  test "check_capabilities resolves selectors against the live context":
    # Availability is a question about the *context*, not about what this
    # boundary happened to declare: `"other"` was never named in the row, but a
    # relative path resolves against the active root and lands inside `tmp/`
    # (§7.5), so it is genuinely available. Only a path outside the root — here
    # an absolute one — is not.
    let app = newApplication()
    let scope = newGlobalScope(app)
    app.setRootCapabilities(newCapabilityContext([
      app.filesystemCapabilities.grantWriteDir(getCurrentDir())
    ]))
    let value = run(compileSource("""
      (fn inspect []
        ^capabilities [(fs/WriteDir "tmp")]
        [
          (check_capabilities (fs/WriteDir "tmp"))
          (check_capabilities (fs/WriteDir "other"))
          (check_capabilities (fs/WriteDir "/etc"))
        ])
      (inspect)
    """), scope)
    check value.print == "[true true false]"

  test "check_capabilities discovers entailment across capability types":
    # A `ReadDir` grant satisfies a `ReadFile` selector inside it. Cross-type
    # satisfaction like this is discovered by `resolve`, which is why the check
    # resolves rather than consulting a table — and it agrees with the
    # operation, which succeeds.
    let root = getTempDir() / "gene-check-entailment"
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeFile(root / "note.txt", "hello")
    let app = newApplication()
    app.setRootCapabilities(newCapabilityContext([
      app.filesystemCapabilities.grantReadDir(root)
    ]))
    let value = run(compileSource("""
      [(check_capabilities (fs/ReadFile "note.txt"))
       (try (do ($fs/read_text "note.txt") "read")
         catch MissingCapability "denied")]
    """), newGlobalScope(app))
    check value.print == "[true \"read\"]"

  test "check_capabilities reports ambiguity as the operation does":
    # Overlapping grants are a configuration fault, not an availability answer.
    # The operation raises `AmbiguousCapability`, so the check raises it too
    # rather than promising an admission that would then fail.
    let root = getTempDir() / "gene-check-ambiguous"
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeFile(root / "note.txt", "hello")
    expect GeneError:
      discard run(compileSource("""
        (check_capabilities (fs/ReadFile "note.txt"))
      """), newGlobalScope(newApplicationRootedAt(root)))

  test "check_capabilities takes several selectors and answers for all of them":
    let app = newApplication()
    let scope = newGlobalScope(app)
    app.setRootCapabilities(newCapabilityContext([
      app.filesystemCapabilities.grantWriteDir(getCurrentDir())
    ]))
    let value = run(compileSource("""
      (fn inspect []
        ^capabilities [(fs/WriteDir "tmp")]
        [
          (check_capabilities (fs/WriteDir "tmp") (fs/WriteDir "nested"))
          (check_capabilities (fs/WriteDir "tmp") (fs/WriteDir "/etc"))
        ])
      (inspect)
    """), scope)
    check value.print == "[true false]"

  test "check_capabilities tracks attenuation and agrees with the operation":
    # The property that makes it worth having: a `true` must mean the operation
    # would be admitted, and a `false` that it would be refused. If these ever
    # disagree the check is worse than no check at all.
    #
    # The row is `^^optional` because a mandatory one is enforced at the
    # declaration, so under `with_capabilities []` the body would never run to
    # be asked.
    let value = run(compileSource("""
      (fn probe [path]
        ^capabilities [(fs/WriteFile path ^^optional)]
        [(check_capabilities (fs/WriteFile path))
         (try (do ($fs/write_text path "x") "wrote")
           catch MissingCapability "denied")])
      (with_capabilities [] (probe "missing.txt"))
    """), newGlobalScope(newApplication()))
    check value.print == "[false \"denied\"]"

  test "check_capabilities rejects an empty row and a non-selector argument":
    expect GeneError:
      discard run(compileSource("(check_capabilities)"),
                  newGlobalScope(newApplication()))
    expect GeneError:
      discard run(compileSource("(check_capabilities 42)"),
                  newGlobalScope(newApplication()))

  test "an absent optional selector starts with no grant and reports absence":
    # The boundary still starts — that is what `^^optional` buys — and the body
    # can see the authority is missing before it tries to use it.
    let value = run(compileSource("""
      (fn optional_write [path]
        ^capabilities [(fs/WriteFile path ^^optional)]
        [(check_capabilities (fs/WriteFile path))
         (try ($fs/write_text path "no")
           catch MissingCapability "denied")])
      (with_capabilities [] (optional_write "missing.txt"))
    """), newGlobalScope(newApplication()))
    check value.print == "[false \"denied\"]"

  test "optional is rejected on an expression capability specification":
    expect GeneError:
      discard run(compileSource("(fs/WriteDir ^^optional)"),
                  newGlobalScope(newApplication()))

  test "the standard library writes through the active exact grant":
    let root = getTempDir() / "gene-capability-stdlib-test"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    defer:
      if fileExists(root / "test.md"):
        removeFile(root / "test.md")
      if fileExists(root / "other.md"):
        removeFile(root / "other.md")
      removeDir(root)

    let app = newApplication()
    app.setRootCapabilities(newCapabilityContext([
      app.filesystemCapabilities.grantWriteDir(root)
    ]))
    let scope = newGlobalScope(app)
    discard run(compileSource("""
      (fn write_exact [filename content]
        ^capabilities [(fs/WriteFile filename)]
        ($fs/write_text filename content))
      (write_exact "test.md" "hello")
    """), scope)
    check readFile(root / "test.md") == "hello"

    expect GeneError:
      discard run(compileSource("""
        (fn write_other [filename]
          ^capabilities [(fs/WriteFile filename)]
          ($fs/write_text "other.md" "escape"))
        (write_other "test.md")
      """), scope)
    check not fileExists(root / "other.md")

  test "static transitions are cached and invalidated by revocation":
    let app = newApplication()
    let scope = newGlobalScope(app)
    let chunk = compileSource("""
      (fn guarded []
        ^capabilities [(fs/WriteDir "tmp")]
        7)
    """)
    discard run(chunk, scope)
    let guarded = scope.lookup("guarded")
    check guarded.call(@[], @[], @[], scope).intVal == 7
    let proto = FunctionProto(guarded.fnCode)
    let cached = proto.capabilityCacheTransition.context
    check cached != nil
    check guarded.call(@[], @[], @[], scope).intVal == 7
    check proto.capabilityCacheTransition.context == cached

    let epoch = app.capabilities.capabilityEpoch
    var filesystemRoot: CapabilityGrant
    for grant in app.rootCapabilities.grants:
      if grant.capabilityType == app.filesystemCapabilities.types.readWriteDir:
        filesystemRoot = grant
        break
    check filesystemRoot != nil
    app.filesystemCapabilities.revoke(filesystemRoot)
    check app.capabilities.capabilityEpoch > epoch
    expect GeneError:
      discard guarded.call(@[], @[], @[], scope)

suite "application and module ceilings":
  test "an imported module ceiling intersects the caller context":
    let entryPath = getCurrentDir() / "tests" / "fixtures" /
      "capability_ceiling_entry.gene"
    let app = newApplicationForEntryFile(entryPath)
    let entry = app.loadFileModule(entryPath)
    let main = entry.moduleRootNamespace.nsScope.lookup("main")
    expect GeneError:
      discard main.call()

  test "a narrowed module initializes with an empty context":
    let entryPath = getCurrentDir() / "tests" / "fixtures" /
      "capability_init_denied.gene"
    let app = newApplicationForEntryFile(entryPath)
    expect GeneError:
      discard app.loadFileModule(entryPath)

  test "an open module initializes under its inherited context":
    let entryPath = getCurrentDir() / "tests" / "fixtures" /
      "capability_init_open.gene"
    let app = newApplicationForEntryFile(entryPath)
    let entry = app.loadFileModule(entryPath)
    check entry.moduleRootNamespace.nsScope.lookup("initialized").intVal == 1

  test "an import-site ceiling bounds a dependency the importer does not control":
    # §5.3.1. The dependency declares nothing and would inherit the entry's
    # `fs/*`; the importer bounds it once, at the import, instead of wrapping
    # every call site.
    let entryPath = getCurrentDir() / "tests" / "fixtures" /
      "capability_import_ceiling_entry.gene"
    let app = newApplicationForEntryFile(entryPath)
    let entry = app.loadFileModule(entryPath)
    let main = entry.moduleRootNamespace.nsScope.lookup("main")
    expect GeneError:
      discard main.call()

  test "an import-site ceiling narrows rather than denies":
    let entryPath = getCurrentDir() / "tests" / "fixtures" /
      "capability_import_ceiling_allowed.gene"
    let app = newApplicationForEntryFile(entryPath)
    let entry = app.loadFileModule(entryPath)
    let main = entry.moduleRootNamespace.nsScope.lookup("main")
    check main.call().intVal == 1

  test "a module bounded by an import ceiling initializes under an empty context":
    # The half that makes the ceiling real: a call-boundary intersection alone
    # arrives after the dependency's top level has already run, and §5.3 says
    # what it captured then cannot be retracted.
    let entryPath = getCurrentDir() / "tests" / "fixtures" /
      "capability_import_init_entry.gene"
    let app = newApplicationForEntryFile(entryPath)
    let entry = app.loadFileModule(entryPath)
    let main = entry.moduleRootNamespace.nsScope.lookup("main")
    check main.call().strVal == "denied"

  test "require_strict_dependencies fails the link on an open dependency":
    # §5.0.2: the policy validates interface metadata; it must not recompile
    # the dependency under a mode its author did not choose, and it must name
    # the offender rather than failing somewhere inside it later.
    let entryPath = getCurrentDir() / "tests" / "fixtures" /
      "capability_strict_deps_entry.gene"
    let app = newApplicationForEntryFile(entryPath)
    var message = ""
    try:
      discard app.loadFileModule(entryPath)
    except CatchableError as error:
      message = error.msg
    check "require_strict_dependencies" in message
    check "capability_ceiling_dep" in message

  test "require_strict_dependencies accepts a strict dependency":
    let entryPath = getCurrentDir() / "tests" / "fixtures" /
      "capability_strict_deps_ok.gene"
    let app = newApplicationForEntryFile(entryPath)
    let entry = app.loadFileModule(entryPath)
    let main = entry.moduleRootNamespace.nsScope.lookup("main")
    check main.call().intVal == 1
