import std/[os, strutils, tables, tempfiles, unittest]
import gene/[capabilities, compiler, digest, fs_capabilities, gir, printer, reader, types, vm]
import ./capability_test_support

proc sourcePolicyApp(root: string): Application =
  result = newApplication(root)
  result.setRootCapabilities(result.capabilities.newPolicyContext([]))

proc sourcePolicyEval(scope: Scope, source: string): Value =
  run(compileSource(source, useLocalSlots = false), scope)

suite "retained capability source policies":
  test "escaped functions keep their directory and relative import base":
    let root = expandFilename(createTempDir("gene-source-escape-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", """
(fn load [path] (eval (quote Item) ^in (env ^imports [path])))
""")
    writeFile(root / "plugin" / "sibling.gene", "(type Item)")
    writeFile(root / "private.gene", "(type Item)")
    let app = sourcePolicyApp(root)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    let headers = app.moduleCompileHeaderCount
    var denied = ""
    try:
      discard scope.sourcePolicyEval("(plugin/load \"../private\")")
    except GeneError as error: denied = error.msg
    check "retained loader policy" in denied
    check app.moduleCompileHeaderCount == headers
    let first = scope.sourcePolicyEval("(plugin/load \"./sibling\")")
    let again = scope.sourcePolicyEval("(plugin/load \"./sibling\")")
    check first.kind == vkType
    check first.bits == again.bits
    let host = app.loadFileModule(root / "private.gene")
    check host.moduleRootNamespace.nsScope.lookup("Item").kind == vkType

  test "pre-existing host helper cannot launder a plugin's source restriction":
    let root = expandFilename(createTempDir("gene-source-helper-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "helper.gene", "(fn load [path] (env ^imports [path]))")
    writeFile(root / "private.gene", "(type Secret)")
    writeFile(root / "plugin" / "entry.gene",
      "(fn attempt [helper] (helper/load \"./private\"))")
    let app = sourcePolicyApp(root)
    let helper = app.loadFileModule(root / "helper.gene")
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("helper", helper)
    scope.define("plugin", plugin)
    let headers = app.moduleCompileHeaderCount
    expect GeneError:
      discard scope.sourcePolicyEval("(plugin/attempt helper)")
    check app.moduleCompileHeaderCount == headers
    check scope.sourcePolicyEval("(helper/load \"./private\")").kind == vkEnv

  test "Env bounds and parent bounds apply before imported initialization":
    let root = expandFilename(createTempDir("gene-source-env-bound-", ""))
    defer: removeDir(root)
    let target = root / "effect.txt"
    writeFile(root / "effect.gene", "($fs/write_text " & newStr(target).print() &
      " \"effect\") (var result 7)")
    for source in [
      "(env ^capabilities [] ^imports [\"./effect\"])",
      "(env ^capabilities ($capabilities/parse \"[]\") ^imports [\"./effect\"])",
      "(env ^parent (env ^capabilities []) ^imports [\"./effect\"])"]:
      let app = newFilesystemPolicyApp(root, "fs/ReadWrite")
      checkpoint source
      var denied = ""
      try: discard newGlobalScope(app).sourcePolicyEval(source)
      except GeneError as error: denied = error.msg
      check "MissingCapability" in denied
      check not fileExists(target)
      discard app.loadFileModule(root / "effect.gene")
      check readFile(target) == "effect"
      removeFile(target)

  test "escaped Env and eval-created functions preserve source bounds and base":
    let root = expandFilename(createTempDir("gene-source-env-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", "(fn environment [] (env))")
    writeFile(root / "plugin" / "sibling.gene", "(var value 17)")
    writeFile(root / "private.gene", "(var value 99)")
    let app = sourcePolicyApp(root)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    scope.define("saved", scope.sourcePolicyEval("(plugin/environment)"))
    check scope.sourcePolicyEval("""
(eval (quote (eval (quote value) ^in (env ^imports ["./sibling"]))) ^in saved)
""").print() == "17"
    let escaped = scope.sourcePolicyEval("""
(eval (quote (fn fetch [path] (eval (quote value) ^in (env ^imports [path])))) ^in saved)
""")
    scope.define("escaped", escaped)
    check scope.sourcePolicyEval("(escaped \"./sibling\")").print() == "17"
    expect GeneError: discard scope.sourcePolicyEval("(escaped \"../private\")")

  test "shared instances stay pinned across host reload and source removal":
    let root = expandFilename(createTempDir("gene-source-shared-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    let contractPath = root / "contracts.gene"
    writeFile(contractPath, "(type Item)")
    writeFile(root / "plugin" / "entry.gene", """
(fn contract [] (eval (quote Item) ^in (env ^imports ["../contracts"])))
""")
    let app = sourcePolicyApp(root)
    let first = app.loadFileModule(contractPath)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities, @[contractPath])
    let second = app.reloadFileModule(contractPath)
    removeFile(contractPath)
    let next = app.loadCapabilityDomainModule("plugin", "r2", root / "plugin",
      "entry.gene", app.rootCapabilities, @[contractPath])
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    scope.define("next", next)
    let firstType = first.moduleRootNamespace.nsScope.lookup("Item")
    let secondType = second.moduleRootNamespace.nsScope.lookup("Item")
    check firstType.bits != secondType.bits
    check scope.sourcePolicyEval("(plugin/contract)").bits == firstType.bits
    check scope.sourcePolicyEval("(next/contract)").bits == secondType.bits

  test "a shared instance must be admitted by each retained source bound":
    let root = expandFilename(createTempDir("gene-source-intersect-", ""))
    defer: removeDir(root)
    createDir(root / "first")
    createDir(root / "second")
    writeFile(root / "contracts.gene", "(type Item)")
    writeFile(root / "first" / "entry.gene", """
(fn contract [] (env ^imports ["../contracts"]))
""")
    writeFile(root / "second" / "entry.gene", "(fn call_other [other] (other/contract))")
    let app = sourcePolicyApp(root)
    discard app.loadFileModule(root / "contracts.gene")
    let first = app.loadCapabilityDomainModule("first", "r1", root / "first",
      "entry.gene", app.rootCapabilities, @[root / "contracts.gene"])
    let second = app.loadCapabilityDomainModule("second", "r1", root / "second",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("first", first)
    scope.define("second", second)
    expect GeneError: discard scope.sourcePolicyEval("(second/call_other first)")
    check scope.sourcePolicyEval("(first/contract)").kind == vkEnv

  test "host sandbox manager cannot be called through a restricted helper":
    let root = expandFilename(createTempDir("gene-source-manager-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    createDir(root / "other")
    writeFile(root / "other" / "entry.gene", "(type Item)")
    writeFile(root / "helper.gene", """
(fn load [] ($runtime/load_sandboxed "other" "entry.gene" [] []))
""")
    writeFile(root / "plugin" / "entry.gene", "(fn attempt [helper] (helper/load))")
    let app = sourcePolicyApp(root)
    let helper = app.loadFileModule(root / "helper.gene")
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("helper", helper)
    scope.define("plugin", plugin)
    var denied = ""
    try: discard scope.sourcePolicyEval("(plugin/attempt helper)")
    except GeneError as error: denied = error.msg
    check "private host control" in denied
    check scope.sourcePolicyEval("(helper/load)").kind == vkModule

  test "compiled module functions resolve imports from their defining module":
    let root = expandFilename(createTempDir("gene-source-compiled-base-", ""))
    defer: removeDir(root)
    createDir(root / "nested")
    writeFile(root / "nested" / "sibling.gene", "(var value 23)")
    writeFile(root / "sibling.gene", "(var value 999)")
    let path = root / "nested" / "entry.gene"
    let app = sourcePolicyApp(root)
    let chunk = compileSource("(fn fetch [] (eval (quote value) ^in (env ^imports [\"./sibling\"])))", path)
    let module = app.loadCompiledFileModule(path, chunk)
    let scope = newGlobalScope(app)
    scope.define("module", module)
    check scope.sourcePolicyEval("(module/fetch)").print() == "23"

  test "retained Env source policy also preserves its initializing authority ceiling":
    let root = expandFilename(createTempDir("gene-source-env-authority-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    let target = root / "forbidden"
    writeFile(root / "plugin" / "entry.gene", "(fn environment [] (env))")
    let app = newFilesystemPolicyApp(root, "fs/ReadWrite")
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.capabilities.newPolicyContext([]))
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    scope.define("target", newStr(target))
    scope.define("saved", scope.sourcePolicyEval("(plugin/environment)"))
    let result = scope.sourcePolicyEval("""
(try (eval (quote ($fs/write_text target "forbidden")) ^in saved)
  catch MissingCapability "denied")
""")
    check result.print() == "\"denied\""
    check not fileExists(target)

  test "Env extension retains its creator's source restriction":
    let root = expandFilename(createTempDir("gene-source-env-extend-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", "(fn extend [parent] (parent .extend {}))")
    writeFile(root / "private.gene", "(var value 99)")
    let app = sourcePolicyApp(root)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    scope.define("saved", scope.sourcePolicyEval("(plugin/extend (env))"))
    let headers = app.moduleCompileHeaderCount
    expect GeneError:
      discard scope.sourcePolicyEval("""
(eval (quote (env ^imports ["../private"])) ^in saved)
""")
    check app.moduleCompileHeaderCount == headers

  test "compiler header discovery obeys the intersection of source directories":
    let root = expandFilename(createTempDir("gene-source-header-meet-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    createDir(root / "plugin" / "narrow")
    writeFile(root / "plugin" / "entry.gene", "(fn load [] (env ^imports [\"./narrow/dependency\"]))")
    writeFile(root / "plugin" / "narrow" / "entry.gene", "(fn call_other [other] (other/load))")
    writeFile(root / "plugin" / "narrow" / "dependency.gene", "(import [secret] ^from \"../secret\")")
    writeFile(root / "plugin" / "secret.gene", "(var secret 42)")
    let app = sourcePolicyApp(root)
    let broad = app.loadCapabilityDomainModule("broad", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let narrow = app.loadCapabilityDomainModule("narrow", "r1", root / "plugin" / "narrow",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("broad", broad)
    scope.define("narrow", narrow)
    let headers = app.moduleCompileHeaderCount
    var denied = ""
    try: discard scope.sourcePolicyEval("(narrow/call_other broad)")
    except GeneError as error: denied = error.msg
    check "unadmitted source" in denied
    check app.moduleCompileHeaderCount == headers + 1

  test "same shared source path cannot substitute a different admitted generation":
    let root = expandFilename(createTempDir("gene-source-shared-conflict-", ""))
    defer: removeDir(root)
    createDir(root / "first")
    createDir(root / "second")
    let shared = root / "contracts.gene"
    writeFile(shared, "(type Item)")
    writeFile(root / "first" / "entry.gene", "(fn contract [] (env ^imports [\"../contracts\"]))")
    writeFile(root / "second" / "entry.gene", "(fn call_other [other] (other/contract))")
    let app = sourcePolicyApp(root)
    discard app.loadFileModule(shared)
    let first = app.loadCapabilityDomainModule("first", "r1", root / "first",
      "entry.gene", app.rootCapabilities, @[shared])
    discard app.reloadFileModule(shared)
    let second = app.loadCapabilityDomainModule("second", "r1", root / "second",
      "entry.gene", app.rootCapabilities, @[shared])
    let scope = newGlobalScope(app)
    scope.define("first", first)
    scope.define("second", second)
    var denied = ""
    try: discard scope.sourcePolicyEval("(second/call_other first)")
    except GeneError as error: denied = error.msg
    check "different shared instances" in denied

  test "escaped shared imports reject capability annotations that would change identity":
    let root = expandFilename(createTempDir("gene-source-shared-annotation-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    let shared = root / "contracts.gene"
    writeFile(shared, "(type Item)")
    writeFile(root / "plugin" / "entry.gene", """
(fn contract []
  (import [Item] ^from "../contracts" ^capabilities [])
  Item)
""")
    let app = sourcePolicyApp(root)
    discard app.loadFileModule(shared)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities, @[shared])
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    var denied = ""
    try: discard scope.sourcePolicyEval("(plugin/contract)")
    except GeneError as error: denied = error.msg
    check "shared module imports retain their admitted identity" in denied

  test "a passed host transaction cannot expand a retained source policy":
    let root = expandFilename(createTempDir("gene-source-transaction-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    createDir(root / "other")
    writeFile(root / "other" / "entry.gene", "(type Item)")
    writeFile(root / "helper.gene", """
(fn prepare [tx]
  (tx .prepare {^dir "other" ^entry "entry.gene" ^grants [] ^shared []
    ^policy {^max_steps 10000}}))
""")
    writeFile(root / "plugin" / "entry.gene", "(fn attempt [helper tx] (helper/prepare tx))")
    let app = sourcePolicyApp(root)
    let helper = app.loadFileModule(root / "helper.gene")
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("helper", helper)
    scope.define("plugin", plugin)
    let tx = scope.sourcePolicyEval("($runtime/sandbox_transaction)")
    scope.define("tx", tx)
    var denied = ""
    try: discard scope.sourcePolicyEval("(plugin/attempt helper tx)")
    except GeneError as error: denied = error.msg
    check "private host control" in denied
    check scope.sourcePolicyEval("(helper/prepare tx)").kind == vkNode
    discard scope.sourcePolicyEval("(tx .discard)")

  test "CallerEnv snapshots preserve the restricted snapshot creator":
    let root = expandFilename(createTempDir("gene-source-snapshot-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    let target = root / "forbidden"
    writeFile(root / "plugin" / "entry.gene", """
(fn capture! [] (caller_env .snapshot ["target"]))
""")
    let app = newFilesystemPolicyApp(root, "fs/ReadWrite")
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.capabilities.newPolicyContext([]))
    let scope = newGlobalScope(app)
    scope.define("capture!", plugin.moduleRootNamespace.nsScope.lookup("capture!"))
    scope.define("target", newStr(target))
    scope.define("saved", scope.sourcePolicyEval("(capture!)"))
    check scope.sourcePolicyEval("""
(try (eval (quote ($fs/write_text target "forbidden")) ^in saved)
  catch MissingCapability "denied")
""").print() == "\"denied\""
    check not fileExists(target)

  test "lazy imports use captured bytes after source replacement or removal":
    let root = expandFilename(createTempDir("gene-source-frozen-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", "(fn load [path] (eval (quote value) ^in (env ^imports [path])))")
    writeFile(root / "plugin" / "dependency.gene", "(var value 11)")
    writeFile(root / "private.gene", "(var value 99)")
    let app = sourcePolicyApp(root)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    removeFile(root / "plugin" / "dependency.gene")
    createSymlink(root / "private.gene", root / "plugin" / "dependency.gene")
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    check scope.sourcePolicyEval("(plugin/load \"./dependency\")").print() == "11"
    removeDir(root / "plugin")
    check scope.sourcePolicyEval("(plugin/load \"./dependency\")").print() == "11"

  test "new files and symlinked directories do not expand an admitted revision":
    let root = expandFilename(createTempDir("gene-source-frozen-members-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    createDir(root / "outside")
    writeFile(root / "outside" / "secret.gene", "(var value 99)")
    createSymlink(root / "outside", root / "plugin" / "linked")
    writeFile(root / "plugin" / "entry.gene", "(fn load [path] (env ^imports [path]))")
    let app = sourcePolicyApp(root)
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    writeFile(root / "plugin" / "new.gene", "(var value 42)")
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    let headers = app.moduleCompileHeaderCount
    for path in ["./new", "./linked/secret"]:
      var denied = ""
      try: discard scope.sourcePolicyEval("(plugin/load " & newStr(path).print() & ")")
      except GeneError as error: denied = error.msg
      check "source snapshot" in denied
    check app.moduleCompileHeaderCount == headers

  test "same source revision stays frozen across different authority domains":
    let root = expandFilename(createTempDir("gene-source-revision-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    let source = root / "plugin" / "entry.gene"
    writeFile(source, "(fn value [] 1)")
    let app = newFilesystemPolicyApp(root)
    let first = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.capabilities.newPolicyContext([]))
    writeFile(source, "(fn value [] 2)")
    let second = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let next = app.loadCapabilityDomainModule("plugin", "r2", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("first", first)
    scope.define("second", second)
    scope.define("next", next)
    check scope.sourcePolicyEval("[(first/value) (second/value) (next/value)]").print() == "[1 1 2]"

  test "source-file symlinks fail before any compiler header or initializer runs":
    let root = expandFilename(createTempDir("gene-source-reject-before-compile-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "private.gene", "(unknown_initializer)")
    createSymlink(root / "private.gene", root / "plugin" / "entry.gene")
    let app = sourcePolicyApp(root)
    var denied = ""
    try:
      discard app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
        "entry.gene", app.rootCapabilities)
    except GeneError as error: denied = error.msg
    check "source acquisition failed" in denied
    check app.moduleCompileHeaderCount == 0
    check app.moduleCacheEntryCount == 0
    check app.filesystemCapabilities.initializedFilesystemRoots == 0

  test "intersected source revisions must agree on imported bytes":
    let root = expandFilename(createTempDir("gene-source-conflicting-revisions-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    writeFile(root / "plugin" / "entry.gene", """
(fn load [] (eval (quote value) ^in (env ^imports ["./dependency"])))
(fn invoke [other] (other/load))
""")
    writeFile(root / "plugin" / "dependency.gene", "(var value 1)")
    let app = sourcePolicyApp(root)
    let first = app.loadCapabilityDomainModule("first", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    writeFile(root / "plugin" / "dependency.gene", "(var value 2)")
    let second = app.loadCapabilityDomainModule("second", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("first", first)
    scope.define("second", second)
    var denied = ""
    try: discard scope.sourcePolicyEval("(second/invoke first)")
    except GeneError as error: denied = error.msg
    check "snapshots disagree" in denied
    check scope.sourcePolicyEval("[(first/load) (second/load)]").print() == "[1 2]"

  test "an unrelated installed artifact cannot replace an admitted source revision":
    let root = expandFilename(createTempDir("gene-source-installed-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    let path = root / "plugin" / "entry.gene"
    let stale = "(fn value [] 99)"
    writeFile(path, "(fn value [] 11)")
    let app = sourcePolicyApp(root)
    app.installCompiledModules([CompiledModule(identity: app.moduleIdentityFor(path),
      chunk: compileSource(stale, path), macroExports: initTable[string, MacroDef](),
      compileInterface: buildCompileInterface(readAll(stale), path))])
    let plugin = app.loadCapabilityDomainModule("plugin", "r1", root / "plugin",
      "entry.gene", app.rootCapabilities)
    let scope = newGlobalScope(app)
    scope.define("plugin", plugin)
    check scope.sourcePolicyEval("(plugin/value)").print() == "11"

  test "normalized transaction graphs report captured sources and release their instances":
    let root = expandFilename(createTempDir("gene-source-transaction-graph-", ""))
    defer: removeDir(root)
    createDir(root / "plugin")
    let path = root / "plugin" / "entry.gene"
    let source = "($fs/write_text " & newStr(path).print() &
      " \"(type Changed)\") (type Original)"
    writeFile(path, source)
    let app = newFilesystemPolicyApp(root, "fs/ReadWrite")
    let scope = newGlobalScope(app)
    let graph = scope.sourcePolicyEval("""
(var tx ($runtime/sandbox_transaction))
(var generation (tx .prepare {^dir "plugin" ^entry "entry.gene"
  ^grants ["fs"] ^shared [] ^policy {^max_steps 10000}}))
(var graph (generation .graph))
(tx .commit)
graph
""")
    check readFile(path) == "(type Changed)"
    require graph.mapEntries["nodes"].listItems.len == 1
    let node = graph.mapEntries["nodes"].listItems[0]
    check node.mapEntries["source_digest"].strVal == "sha256:" & sha256Hex(source)
    check node.mapEntries["identity"].strVal.startsWith("capability-instance:")
    check app.moduleCacheEntryCount == 1
    discard scope.sourcePolicyEval("(generation .release)")
    check app.moduleCacheEntryCount == 0

  test "the legacy URL-enable flag cannot admit unverified normalized source":
    let root = expandFilename(createTempDir("gene-source-url-profile-", ""))
    defer: removeDir(root)
    let app = sourcePolicyApp(root)
    app.allowUrlModules = true
    var denied = ""
    try: discard app.loadUrlModule("http://127.0.0.1:1/unadmitted.gene")
    except GeneError as error: denied = error.msg
    check "URL source acquisition requires an authenticated loader profile" in denied
    check app.moduleCompileHeaderCount == 0
    check app.moduleCacheEntryCount == 0
