import gene/capabilities
import gene/fs_capabilities
import gene/host_capabilities
import gene/[compiler, gir, printer, reader, types, vm]
import ./capability_test_support
import std/[options, os, strutils, tables, tempfiles, unittest]

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

suite "unsupported native resource entry":
  test "database and store APIs reject before creating files or retained authority":
    let root = expandFilename(createTempDir("gene-unsupported-resources-", ""))
    defer: removeDir(root)
    let app = newFilesystemPolicyApp(root, "fs/ReadWrite")
    let scope = newGlobalScope(app)
    scope.define("root", newStr(root))
    scope.define("database", newStr(root / "database.sqlite"))
    let baseline = resourceAuthorityRecordCount()
    for operation in ["($db/sqlite/open database)", "($store/fs/open ^root root)"]:
      check run(compileSource("(try " & operation &
        " catch UnsupportedCapability $err/reason)"), scope).strVal ==
        "unsupported_operation"
      check resourceAuthorityRecordCount() == baseline
    check not fileExists(root / "database.sqlite")
    var entries = 0
    for entry in walkDir(root): inc entries
    check entries == 0

proc migrationEval(scope: Scope, root, source: string): Value =
  run(compileSource(source, root / "entry.gene", useLocalSlots = false), scope)

suite "capability source migration":
  test "legacy capability constructors and selector APIs are no longer exported":
    let scope = newApplication().builtinsScope().lookup("gene").nsScope
    for source in ["fs/ReadDir", "fs/WriteDir", "fs/ReadWriteDir",
                   "fs/ReadFile", "fs/WriteFile", "net/Connect", "net/Listen",
                   "net/Http", "os/Env", "os/Exec", "os/Pty", "os/Process",
                   "ffi/Load", "db/Postgres", "crypto/Random", "device/Compute",
                   "clock/Monotonic",
                   "CapabilitySpec", "check_capabilities", "capabilities_of",
                   "capability_type_info"]:
      checkpoint source
      let parts = source.split('/')
      var owner = scope
      for index in 0 ..< parts.len - 1:
        let namespace = owner.lookup(parts[index])
        require namespace.kind == vkNamespace
        owner = namespace.nsScope
      # Namespace exports exclude lexical ancestors (for example, os/Env must
      # not be confused with the unrelated builtin Env type in its parent).
      check not owner.vars.hasKey(parts[^1])

  test "even a host-supplied old specification is no longer callable":
    let app = newApplication()
    let scope = newGlobalScope(app)
    scope.define("legacy", newCapability(app.filesystemCapabilities.types.readDir))
    expect GeneError:
      discard run(compileSource("(legacy \"/tmp\")"), scope)
    expect GeneError:
      discard run(compileSource("(($capabilities/parse \"[]\"))"), scope)

  test "Gene capability canonicalizers cannot enter the authorization path":
    for source in [
      "(type Area ^capability \"app/Area\")",
      "(type Area ^capability \"app/Area\" ^body [Str] " &
        "(impl CapabilitySpec (message canonicalize [] ^capabilities [] self)))"]:
      var message = ""
      try: discard compileSource(source)
      except GeneError as error: message = error.msg
      check "Gene capability facades were removed" in message

  test "old facade metadata in a supplied compiled chunk is rejected":
    let scope = newGlobalScope()
    discard run(compileSource("(let touched ($cell false))", useLocalSlots = false), scope)
    let chunk = compileSource("""
      (protocol Derivation
        (derive [t req] (touched .set true) nil))
      (type Area ^derive [Derivation])
    """, useLocalSlots = false)
    require chunk.typeProtos.len == 1
    chunk.typeProtos[0].capabilityName = "app/Area"
    var message = ""
    try: discard run(chunk, scope)
    except GeneError as error: message = error.msg
    check "obsolete capability facade metadata" in message
    check not run(compileSource("(touched .get)"), scope).boolVal

  test "catalog identifiers are independent of ordinary source bindings":
    let app = newApplication()
    app.setRootCapabilities(app.capabilities.newPolicyContext([]))
    let value = run(compileSource("""
      (let calls ($cell 0))
      (let fs {^Read (fn [] (calls .set 1))})
      (fn inspect [] ^capabilities [(fs/Read ^^optional)] (calls .get))
      [(inspect) (calls .get)]
    """), newGlobalScope(app))
    check value.print() == "[0 0]"

  test "the compiler preserves inert rows instead of parameter slot selectors":
    let chunk = compileSource("""
      (fn inspect [path]
        ^capabilities [(fs/Read "data") (net/Http ^methods ["GET"] ^^optional)]
        path)
    """)
    let row = chunk.functions[0].capabilityRow
    require row.literal != nil
    check row.literal.entries.len == 2
    check row.literal.entries[0].name == "fs/Read"
    check row.literal.entries[0].body[0].text == "data"
    check row.literal.entries[1].optional
    for text in ["[(fs/Read path)]", "[(fs/Read (compute))]",
                 "[(app/Publish #[events #{^durable true}])]",
                 "[(app/Publish {^durable true})]", "*"]:
      expect GeneError:
        discard compileSource("(fn bad [path] ^capabilities " & text & " nil)")

  test "an enforced compiler catalog rejects unadmitted capability types":
    let source = readAllWithLocs("(fn use [] ^capabilities [app/Unknown] nil)",
      "unknown_capability.gene")
    expect GeneError:
      discard compileFormsWithMacros(source,
        initTable[string, Table[string, MacroDef]](),
        capabilityCatalog = initTable[string, CapabilityCompileDescriptor](),
        enforceCapabilityCatalog = true)

  test "strict dependency fixtures are explicit rejection cases":
    for name in ["capability_strict_dep.gene", "capability_strict_deps_entry.gene",
                 "capability_strict_deps_ok.gene"]:
      let path = getCurrentDir() / "tests" / "fixtures" / name
      var message = ""
      try: discard compileSource(readFile(path), path)
      except GeneError as error: message = error.msg
      check "module capability declarations/modes were removed" in message

suite "migrated capability calls and checks":
  setup:
    let root = expandFilename(createTempDir("gene-capability-migration-", ""))
    createDir(root / "allowed")
    createDir(root / "other")
    writeFile(root / "allowed" / "note", "hello")
    writeFile(root / "other" / "note", "outside")
    let app = newFilesystemPolicyApp(root, "fs/ReadWrite")
    let scope = newGlobalScope(app)
    scope.define("allowed", newStr(root / "allowed" / "note"))
    scope.define("other", newStr(root / "other" / "note"))
    scope.define("tree", newStr(root / "allowed"))
  teardown:
    removeDir(root)

  test "mandatory admission precedes defaults and in-memory body effects":
    check scope.migrationEval(root, """
      (let entered ($cell false))
      (fn write [path = (entered .set true)] ^capabilities [(fs/Write "allowed")]
        (entered .set true))
      [(try (with_capabilities [] (write)) catch MissingCapability "denied")
       (entered .get)]
    """).print() == "[\"denied\" false]"

  test "errors and empty blocks restore the parent's authority":
    check scope.migrationEval(root, """
      (fn read [] ^capabilities [(fs/Read "allowed")] ($fs/read_text allowed))
      (fn fail_empty [] ^capabilities [] (fail (RuntimeError ^message "expected")))
      (try (fail_empty) catch RuntimeError nil)
      [(try (with_capabilities [] (read)) catch MissingCapability "denied")
       (read)]
    """).print() == "[\"denied\" \"hello\"]"

  test "runtime resource names use the checked builder and select an exact tree":
    check scope.migrationEval(root, """
      (let row ($capabilities/build [($capabilities/entry "fs/Read" [tree] [])]))
      (with_capabilities row
        [($fs/read_text allowed)
         (try ($fs/read_text other) catch MissingCapability "denied")])
    """).print() == "[\"hello\" \"denied\"]"

  test "spawn retains the selected authority without narrowing its parent":
    check scope.migrationEval(root, """
      (scope
        (let child (with_capabilities [] (spawn ^lane root
          (try ($fs/read_text allowed) catch MissingCapability "denied"))))
        [(await child) ($fs/read_text allowed)])
    """).print() == "[\"denied\" \"hello\"]"

  test "requirement checks use the selected context and do not reinterpret bases":
    check scope.migrationEval(root, """
      (let good ($capabilities/build [($capabilities/entry "fs/Read" [tree] [])]))
      (let both ($capabilities/build [
        ($capabilities/entry "fs/Read" [tree] [])
        ($capabilities/entry "fs/Read" [other] [])]))
      (with_capabilities good
        (let one ($capabilities/check_requirements good))
        (let two ($capabilities/check_requirements both))
        [one/admitted two/admitted ($fs/read_text allowed)])
    """).print() == "[true false \"hello\"]"

  test "empty checks are valid and arbitrary lists are not spec-row values":
    check scope.migrationEval(root, """
      (let report ($capabilities/check_requirements ($capabilities/parse "[]")))
      report/admitted
    """).boolVal
    expect GeneError:
      discard scope.migrationEval(root, "($capabilities/check_requirements [])")

  test "optional broad requests preserve narrow overlap and permit fallback":
    check scope.migrationEval(root, """
      (fn probe [path] ^capabilities [(fs/Read ^^optional)]
        (try ($fs/read_text path) catch MissingCapability "denied"))
      (let bound ($capabilities/build [($capabilities/entry "fs/Read" [tree] [])]))
      [(with_capabilities [] (probe allowed))
       (with_capabilities bound (probe allowed))
       (with_capabilities bound (probe other))]
    """).print() == "[\"denied\" \"hello\" \"denied\"]"

  test "standard library writes stay in the declared tree":
    check scope.migrationEval(root, """
      (fn write [path] ^capabilities [(fs/Write "allowed")]
        ($fs/write_text path "changed"))
      (write allowed)
      (try (write other) catch MissingCapability "denied")
    """).strVal == "denied"
    check readFile(root / "allowed" / "note") == "changed"
    check readFile(root / "other" / "note") == "outside"

  test "revocation invalidates later admission before memory-only effects":
    discard scope.migrationEval(root, """
      (let count ($cell 0))
      (fn guarded [] ^capabilities [(fs/Read "allowed")]
        (count .set (+ (count .get) 1)))
      (guarded)
    """)
    for grant in app.rootCapabilities.grants:
      app.filesystemCapabilities.revoke(grant)
    check scope.migrationEval(root, """
      [(try (guarded) catch MissingCapability "denied") (count .get)]
    """).print() == "[\"denied\" 1]"

  test "overlapping live grants are alternatives rather than an ambiguity error":
    let row = app.capabilities.normalizeCapabilityRow(readCapabilityLiteral(
      "[(fs/ReadWrite " & newStr(root).print() & ")]", cuGrant,
      CapabilitySourceContext()), cuGrant)
    let extra = app.filesystemCapabilities.initializeFilesystemGrant(row.entries[0].policy)
    app.setRootCapabilities(app.capabilities.newPolicyContext(
      @(app.rootCapabilities.grants) & @[extra]))
    check scope.migrationEval(root, "($fs/read_text allowed)").strVal == "hello"

  test "inherited contracts require exact mandatory and optional metadata":
    for replacement in ["[fs/Read]", "[]", "[(fs/Read \"allowed\" ^^optional)]"]:
      var message = ""
      try:
        discard newGlobalScope(app).migrationEval(root, """
          (protocol P (message read [] ^capabilities [(fs/Read ^^optional)]))
          (type T)
          (impl P for T (message read [] ^capabilities """ & replacement & """ nil))
        """)
      except GeneError as error: message = error.msg
      check "implementation changes its inherited ^capabilities contract" in message
    check scope.migrationEval(root, """
      (protocol Empty (message read [] ^capabilities []))
      (type Reader)
      (impl Empty for Reader (message read []
        (try ($fs/read_text allowed) catch MissingCapability "denied")))
      ((Reader) .Empty:read)
    """).strVal == "denied"

suite "migrated module capability fixtures":
  test "import bounds apply before initialization and remain on escaped calls":
    let root = getCurrentDir() / "tests" / "fixtures"
    for (name, outcome) in [
      ("capability_ceiling_entry.gene", "denied"),
      ("capability_import_ceiling_entry.gene", "denied"),
      ("capability_import_ceiling_allowed.gene", "1"),
      ("capability_import_init_entry.gene", "\"denied\"")]:
      checkpoint name
      let app = newFilesystemPolicyApp(root, "fs/ReadWrite")
      let entry = app.loadFileModule(root / name)
      let scope = newGlobalScope(app)
      scope.define("entry", entry)
      var actual = ""
      try: actual = scope.migrationEval(root, "(entry/main)").print()
      except GeneError as error:
        check "MissingCapability" in error.msg
        actual = "denied"
      check actual == outcome

  test "unannotated modules inherit initialization authority; explicit blocks narrow":
    let root = getCurrentDir() / "tests" / "fixtures"
    let app = newFilesystemPolicyApp(root, "fs/ReadWrite")
    let entry = app.loadFileModule(root / "capability_init_open.gene")
    check entry.moduleRootNamespace.nsScope.lookup("initialized").intVal == 1
    expect GeneError:
      discard app.loadFileModule(root / "capability_init_denied.gene")
