import std/[os, strutils, tables, tempfiles, unittest]
import gene/[capabilities, capability_startup, compiler, gir, module_sources,
             package, printer, reader, types, vm]

proc applicationSourceHost(root: string, policy = "[]"): Application =
  result = newApplication(root)
  var options: CapabilityStartupOptions
  options.setCapabilityOption("--cap", policy)
  discard result.configureCapabilityStartup(options)

proc applicationSourceEval(scope: Scope, source: string): Value =
  run(compileSource(source, useLocalSlots = false), scope)

proc applicationArtifact(app: Application, path, text: string): AdmittedModuleArtifact =
  result.path = path
  result.artifact = CompiledModule(identity: app.moduleIdentityFor(path),
    chunk: compileSource(text, path), macroExports: initTable[string, MacroDef](),
    compileInterface: buildCompileInterface(readAll(text), path))

suite "ordinary application source admission":
  test "the admitted entry does not acquire its neighboring sources":
    let root = expandFilename(createTempDir("gene-app-source-entry-", ""))
    defer: removeDir(root)
    let entry = root / "entry.gene"
    writeFile(entry, "(import [secret] ^from \"./private\")")
    writeFile(root / "private.gene", "(var secret 42)")
    let app = applicationSourceHost(root)
    let captured = app.filesystemCapabilities.captureModuleSourceFile(entry)
    app.admitApplicationSources(entry, [captured])
    var denied = ""
    try: discard app.loadFileModule(entry)
    except GeneError as error: denied = error.msg
    check "retained source snapshot" in denied
    check app.moduleCompileHeaderCount == 1
    check app.moduleCacheEntryCount == 0

  test "explicit source bundles support imports without filesystem authority":
    let root = expandFilename(createTempDir("gene-app-source-bundle-", ""))
    defer: removeDir(root)
    createDir(root / "library")
    let entry = root / "entry.gene"
    writeFile(entry, "(import [Item value] ^from \"./library/item\") (fn result [] [(value) Item])")
    writeFile(root / "library" / "item.gene", "(type Item) (fn value [] 7)")
    let app = applicationSourceHost(root)
    app.admitApplicationSources(entry, [
      app.filesystemCapabilities.captureModuleSourceFile(entry),
      app.filesystemCapabilities.captureModuleSources(root / "library")])
    removeFile(root / "library" / "item.gene")
    let module = app.loadFileModule(entry)
    let scope = newGlobalScope(app)
    scope.define("module", module)
    let value = scope.applicationSourceEval("(module/result)")
    check value.listItems[0].intVal == 7
    check value.listItems[1].kind == vkType
    check app.rootCapabilities.grants.len == 0

  test "ordinary initialization and later callbacks cannot invoke private host controls":
    let root = expandFilename(createTempDir("gene-app-source-control-", ""))
    defer: removeDir(root)
    let entry = root / "entry.gene"
    writeFile(entry, "(fn control [] ($runtime/sandbox_transaction))")
    let app = applicationSourceHost(root)
    app.admitApplicationSources(entry,
      [app.filesystemCapabilities.captureModuleSourceFile(entry)])
    let module = app.loadFileModule(entry)
    let scope = newGlobalScope(app)
    scope.define("module", module)
    check scope.applicationSourceEval("""
(try (module/control) false catch UnsupportedCapability true)
""").boolVal
    let hostScope = newScope(app.builtinsScope(), application = app)
    hostScope.moduleRoot = true
    hostScope.define("module", module)
    check hostScope.applicationSourceEval("""
(try (module/control) false catch UnsupportedCapability true)
""").boolVal

  test "empty inline source admission disallows dynamic acquisition and private host calls":
    let root = expandFilename(createTempDir("gene-app-source-inline-", ""))
    defer: removeDir(root)
    writeFile(root / "private.gene", "(var secret 42)")
    let app = applicationSourceHost(root)
    app.admitApplicationSources("")
    let scope = newGlobalScope(app)
    check scope.applicationSourceEval("(+ 2 3)").intVal == 5
    expect GeneError:
      discard scope.applicationSourceEval("(env ^imports [\"./private\"])")
    check scope.applicationSourceEval("""
(try ($runtime/sandbox_transaction) false catch UnsupportedCapability true)
""").boolVal

  test "compiled admission uses pinned artifacts without live source or installed-template fallback":
    let root = expandFilename(createTempDir("gene-app-source-artifact-", ""))
    defer: removeDir(root)
    let entry = root / "entry.gene"
    let dependency = root / "library.gene"
    let app = applicationSourceHost(root)
    let first = app.applicationArtifact(entry,
      "(import [Item value] ^from \"./library\") (fn result [] [(value) Item])")
    let library = app.applicationArtifact(dependency, "(type Item) (fn value [] 11)")
    app.admitApplicationSources(entry, artifacts = [first, library])
    let stale = app.applicationArtifact(dependency, "(fn value [] 99)")
    app.installCompiledModules([stale.artifact])
    let module = app.loadFileModule(entry)
    let scope = newGlobalScope(app)
    scope.define("module", module)
    check scope.applicationSourceEval("(module/result)").listItems[0].intVal == 11
    check app.moduleCompileHeaderCount == 0

  test "compiled entry loading rejects a chunk from another admitted revision":
    let root = expandFilename(createTempDir("gene-app-source-stale-chunk-", ""))
    defer: removeDir(root)
    let path = root / "entry.gene"
    let app = applicationSourceHost(root)
    let admitted = app.applicationArtifact(path, "(fn value [] 7)")
    app.admitApplicationSources(path, artifacts = [admitted])
    expect GeneError:
      discard app.loadCompiledFileModule(path, compileSource("(fn value [] 99)", path))
    let module = app.loadCompiledFileModule(path, admitted.artifact.chunk)
    let scope = newGlobalScope(app)
    scope.define("module", module)
    check scope.applicationSourceEval("(module/value)").intVal == 7

  test "shared contract instances retain their chosen identity across application admission":
    let root = expandFilename(createTempDir("gene-app-source-shared-", ""))
    defer: removeDir(root)
    let contractPath = root / "contract.gene"
    let entry = root / "entry.gene"
    writeFile(contractPath, "(type Item)")
    writeFile(entry, "(import [Item] ^from \"./contract\") (fn item_type [] Item)")
    let app = applicationSourceHost(root)
    let contract = app.loadFileModule(contractPath)
    app.admitApplicationSources(entry,
      [app.filesystemCapabilities.captureModuleSourceFile(entry)], shared = [contract])
    removeFile(contractPath)
    let module = app.loadFileModule(entry)
    let scope = newGlobalScope(app)
    scope.define("module", module)
    check scope.applicationSourceEval("(module/item_type)").bits ==
      contract.moduleRootNamespace.nsScope.lookup("Item").bits

  test "failed source admission cannot fall back to raw loading or a broader second attempt":
    let root = expandFilename(createTempDir("gene-app-source-failure-", ""))
    defer: removeDir(root)
    let entry = root / "entry.gene"
    writeFile(entry, "(fn value [] 1)")
    let app = applicationSourceHost(root)
    expect GeneError: app.admitApplicationSources(entry)
    expect GeneError: discard app.loadFileModule(entry)
    expect GeneError:
      app.admitApplicationSources(entry,
        [app.filesystemCapabilities.captureModuleSourceFile(entry)])
    check app.moduleCompileHeaderCount == 0

  test "a snapshot is immutable across different ordinary authority domains":
    let root = expandFilename(createTempDir("gene-app-source-domains-", ""))
    defer: removeDir(root)
    let entry = root / "entry.gene"
    writeFile(entry, "(type Item)")
    let app = applicationSourceHost(root, "[net/Http]")
    app.admitApplicationSources(entry,
      [app.filesystemCapabilities.captureModuleSourceFile(entry)])
    let first = app.loadFileModule(entry)
    writeFile(entry, "(unknown_initializer)")
    let scope = newGlobalScope(app)
    let again = scope.applicationSourceEval("(import [Item] ^from \"./entry\") Item")
    let narrow = scope.applicationSourceEval("(with_capabilities [] (import [Item] ^from \"./entry\") Item)")
    let repeated = scope.applicationSourceEval("(with_capabilities [] (import [Item] ^from \"./entry\") Item)")
    check first.moduleRootNamespace.nsScope.lookup("Item").bits == again.bits
    check narrow.bits != again.bits
    check narrow.bits == repeated.bits

  test "a declared artifact resource base is retained through capability linking":
    let root = expandFilename(createTempDir("gene-app-source-resource-base-", ""))
    defer: removeDir(root)
    createDir(root / "code")
    createDir(root / "resources" / "data")
    writeFile(root / "resources" / "data" / "value", "resource")
    let path = root / "code" / "entry.gene"
    let app = applicationSourceHost(root,
      "[(fs/Read " & newStr(root / "resources").print() & ")]")
    let text = "(fn read [path] ^capabilities [(fs/Read \"data\")] ($fs/read_text path))"
    var admitted = app.applicationArtifact(path, text)
    admitted.artifact.chunk = compileSource(text, "package@revision::entry")
    admitted.resourceBase = root / "resources"
    app.admitApplicationSources(path, artifacts = [admitted])
    let module = app.loadFileModule(path)
    let scope = newGlobalScope(app)
    scope.define("module", module)
    scope.define("path", newStr(root / "resources" / "data" / "value"))
    check scope.applicationSourceEval("(module/read path)").strVal == "resource"

  test "explicit reload creates a new declaration generation from the admitted snapshot":
    let root = expandFilename(createTempDir("gene-app-source-reload-", ""))
    defer: removeDir(root)
    let path = root / "entry.gene"
    writeFile(path, "(type Item) (fn value [] 7)")
    let app = applicationSourceHost(root)
    app.admitApplicationSources(path,
      [app.filesystemCapabilities.captureModuleSourceFile(path)])
    let first = app.loadFileModule(path)
    writeFile(path, "(unknown_initializer)")
    let next = app.reloadFileModule(path)
    check first.moduleRootNamespace.nsScope.lookup("Item").bits !=
      next.moduleRootNamespace.nsScope.lookup("Item").bits
    let scope = newGlobalScope(app)
    scope.define("next", next)
    check scope.applicationSourceEval("(next/value)").intVal == 7

  test "an explicit package graph and source admission allow approved external dependencies":
    let root = expandFilename(createTempDir("gene-app-source-packages-", ""))
    defer: removeDir(root)
    createDir(root / "app")
    createDir(root / "library")
    let owner = newAdHocPackage(root / "app")
    let dependency = newAdHocPackage(root / "library")
    owner.dependencyEdges["dep"] = dependency.id
    let graph = singlePackageGraph(owner)
    graph.packagesById[dependency.id] = dependency
    let entry = root / "app" / "entry.gene"
    writeFile(entry, "(import [value] ^from \"api\" ^pkg \"dep\") (fn result [] (value))")
    writeFile(root / "library" / "api.gene", "(fn value [] 31)")
    let app = newApplication(graph, owner.root)
    discard app.configureCapabilityStartup(CapabilityStartupOptions())
    app.admitApplicationSources(entry, [
      app.filesystemCapabilities.captureModuleSourceFile(entry),
      app.filesystemCapabilities.captureModuleSources(dependency.root)])
    removeFile(root / "library" / "api.gene")
    let module = app.loadFileModule(entry)
    let scope = newGlobalScope(app)
    scope.define("module", module)
    check scope.applicationSourceEval("(module/result)").intVal == 31

  test "artifact admission rejects conflicting paths and freezes supplied templates":
    let root = expandFilename(createTempDir("gene-app-source-artifact-freeze-", ""))
    defer: removeDir(root)
    let path = root / "entry.gene"
    let app = applicationSourceHost(root)
    let admitted = app.applicationArtifact(path, "(fn value [] 17)")
    app.admitApplicationSources(path, artifacts = [admitted])
    let replacement = compileSource("(fn value [] 99)", path)
    admitted.artifact.chunk.functions[0] = replacement.functions[0]
    let module = app.loadFileModule(path)
    let scope = newGlobalScope(app)
    scope.define("module", module)
    check scope.applicationSourceEval("(module/value)").intVal == 17
    let second = applicationSourceHost(root)
    let a = second.applicationArtifact(path, "(fn value [] 1)")
    let b = second.applicationArtifact(path, "(fn value [] 2)")
    expect GeneError: second.admitApplicationSources(path, artifacts = [a, b])
    expect GeneError: discard second.loadFileModule(path)

  test "intersected loader origins also intersect namespace exposure":
    let root = expandFilename(createTempDir("gene-app-source-namespaces-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", """
(fn load [] (eval (quote had_fs) ^in (env ^imports ["./dependency"])))
(fn through [other] (other/load))
""")
    writeFile(root / "plugin" / "dependency.gene", "(var had_fs (not ($void? gene/fs)))")
    let app = applicationSourceHost(root)
    let broad = app.loadCapabilityDomainModule("broad", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities, exposedNamespaces = @["fs"])
    let narrow = app.loadCapabilityDomainModule("narrow", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("broad", broad)
    scope.define("narrow", narrow)
    check scope.applicationSourceEval("[(broad/load) (narrow/through broad)]").print() == "[true false]"
