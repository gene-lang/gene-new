import std/[os, strutils, tables, tempfiles, unittest]
import gene/[capabilities, compiler, fs_capabilities, gir, gir_codec, printer, reader, types, vm]
import ./capability_test_support

proc ordinaryCapabilityApp(root: string): Application =
  result = newApplication(root)
  let row = result.capabilities.normalizeCapabilityRow(readCapabilityLiteral(
    "[net/Http]", cuGrant, CapabilitySourceContext()), cuGrant)
  let grant = result.hostCapabilities.mintPolicyGrant(row.entries[0].policy)
  result.setRootCapabilities(result.capabilities.newPolicyContext([grant]))

proc ordinaryReload(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  call[].dispatchScope.application().reloadFileModule(args[0].strVal)

const ordinaryDomainSource = """
(fn allowed []
  (var report ($capabilities/check_requirements ($capabilities/parse "[net/Http]")))
  report/admitted)
(var initialized (allowed))
(type Item ^props {^number Int})
(protocol ReadNumber (message value [] : Int))
(impl ReadNumber for Item (message value [] : Int self/number))
"""

suite "ordinary normalized module instances":
  test "ordinary imports use caller domains and retain their initialization ceilings":
    let root = expandFilename(createTempDir("gene-ordinary-domains-", ""))
    defer: removeDir(root)
    writeFile(root / "library.gene", ordinaryDomainSource)
    let app = ordinaryCapabilityApp(root)
    let broad = app.loadFileModule(root / "library.gene")
    let scope = newGlobalScope(app)
    scope.define("broad", broad)
    let source = """
      (with_capabilities []
        (import [Item ReadNumber initialized allowed] ^from "./library")
        [Item ReadNumber initialized allowed])
    """
    let narrow = run(compileSource(source), scope)
    let again = run(compileSource(source.replace("with_capabilities []",
      "with_capabilities ($capabilities/parse \"[]\")")), scope)
    check narrow.listItems[0].bits == again.listItems[0].bits
    check narrow.listItems[1].bits == again.listItems[1].bits
    check narrow.listItems[0].bits != broad.moduleRootNamespace.nsScope.lookup("Item").bits
    check narrow.listItems[1].bits != broad.moduleRootNamespace.nsScope.lookup("ReadNumber").bits
    check not narrow.listItems[2].boolVal
    check broad.moduleRootNamespace.nsScope.lookup("initialized").boolVal
    scope.define("narrow_allowed", narrow.listItems[3])
    check run(compileSource("[(narrow_allowed) (broad/allowed)]"), scope).print() == "[false true]"

  test "a narrow first import does not choose the broader instance's exports":
    let root = expandFilename(createTempDir("gene-ordinary-first-", ""))
    defer: removeDir(root)
    writeFile(root / "library.gene", ordinaryDomainSource)
    let app = ordinaryCapabilityApp(root)
    let narrow = run(compileSource("""
      (with_capabilities [] (import [initialized] ^from "./library") initialized)
    """), newGlobalScope(app))
    check not narrow.boolVal
    let broad = app.loadFileModule(root / "library.gene")
    check broad.moduleRootNamespace.nsScope.lookup("initialized").boolVal

  test "import annotations narrow ordinary initialization without a path-global ceiling":
    let root = expandFilename(createTempDir("gene-ordinary-import-", ""))
    defer: removeDir(root)
    writeFile(root / "library.gene", ordinaryDomainSource)
    let app = ordinaryCapabilityApp(root)
    let scope = newGlobalScope(app)
    check run(compileSource("""
      (import [allowed : narrow] ^from "./library" ^capabilities [])
      (import [allowed : broad] ^from "./library")
      [(narrow) (broad)]
    """), scope).print() == "[false true]"

  test "failed ordinary initialization is cached until an explicit reload generation":
    let root = expandFilename(createTempDir("gene-ordinary-failure-", ""))
    defer: removeDir(root)
    let path = root / "library.gene"
    let target = root / "forbidden"
    writeFile(path, "($fs/write_text " & newStr(target).print() & " \"forbidden\") (type Ready)")
    let app = newFilesystemPolicyApp(root, "fs/ReadWrite")
    let scope = newGlobalScope(app)
    scope.define("reload_source", newNativeCallFn("test/reload_source", ordinaryReload,
      effectKind = nekHostControl))
    scope.define("path", newStr(path))
    let importing = compileSource("(with_capabilities [] (import [Ready] ^from \"./library\") Ready)")
    expect GeneError: discard run(importing, scope)
    check not fileExists(target)
    check app.moduleCacheEntryCount == 0
    writeFile(path, "(type Ready)")
    expect GeneError: discard run(importing, scope)
    let refreshed = run(compileSource("(with_capabilities [] (reload_source path))"), scope)
    let ready = run(importing, scope)
    check ready.bits == refreshed.moduleRootNamespace.nsScope.lookup("Ready").bits

  test "a new ordinary generation preserves earlier declaration identities":
    let root = expandFilename(createTempDir("gene-ordinary-reload-", ""))
    defer: removeDir(root)
    let path = root / "library.gene"
    writeFile(path, "(type Item) (fn value [] 1)")
    let app = ordinaryCapabilityApp(root)
    let first = app.loadFileModule(path)
    writeFile(path, "(type Item) (fn value [] 2)")
    let second = app.reloadFileModule(path)
    let scope = newGlobalScope(app)
    scope.define("first", first)
    scope.define("second", second)
    check run(compileSource("[(same? first/Item second/Item) (first/value) (second/value)]"),
      scope).print() == "[false 1 2]"
    check app.loadFileModule(path).bits == second.bits

  test "compiled templates are linked independently and remain reusable":
    let root = expandFilename(createTempDir("gene-ordinary-compiled-", ""))
    defer: removeDir(root)
    let path = root / "compiled.gene"
    let code = compileSource("(type Item (message identity [] : Self self))", path)
    let firstApp = ordinaryCapabilityApp(root)
    let first = firstApp.loadCompiledFileModule(path, code)
    let secondApp = ordinaryCapabilityApp(root)
    let second = secondApp.loadCompiledFileModule(path, code)
    let firstType = first.moduleRootNamespace.nsScope.lookup("Item")
    let secondType = second.moduleRootNamespace.nsScope.lookup("Item")
    check firstType.bits != secondType.bits
    for (app, module, typ) in [(firstApp, first, firstType), (secondApp, second, secondType)]:
      let scope = newGlobalScope(app)
      scope.define("module", module)
      check run(compileSource("((module/Item) .identity)"), scope).head.bits == typ.bits
    discard cloneCompiledChunk(code)

  test "unsupported declarations hidden in function bodies cannot bypass admission":
    let root = expandFilename(createTempDir("gene-ordinary-native-", ""))
    defer: removeDir(root)
    let path = root / "native.gene"
    let source = "(fn later [] (ffi/struct CPoint ^fields [[x C/Int]]) 1)"
    let code = compileSource(source, path)
    require code.functions[0].chunk.ffiStructs.len == 1
    writeFile(path, source)
    let app = ordinaryCapabilityApp(root)
    expect GeneError: discard app.loadFileModule(path)
    check app.moduleCacheEntryCount == 0

  test "compiled templates reject live authority and runtime values":
    let root = expandFilename(createTempDir("gene-ordinary-template-", ""))
    defer: removeDir(root)
    let app = ordinaryCapabilityApp(root)
    let bound = compileSource("(fn value [] 1)")
    bound.functions[0].boundCapabilityCeiling = app.rootCapabilities
    expect ValueError: discard cloneCompiledChunk(bound)
    let runtime = compileSource("1")
    runtime.constants.add newCell(newInt(7))
    expect ValueError: discard cloneCompiledChunk(runtime)
    expect ValueError:
      app.installCompiledModules([
        CompiledModule(identity: "valid", chunk: compileSource("1")),
        CompiledModule(identity: "invalid", chunk: runtime)])
    check app.moduleCompileArtifactCount == 0

  test "verified compiled dependencies do not fall back to mutable source in another domain":
    let root = expandFilename(createTempDir("gene-ordinary-installed-", ""))
    defer: removeDir(root)
    let path = root / "library.gene"
    let source = "(type Item) (fn value [] 7)"
    let app = ordinaryCapabilityApp(root)
    let compiled = CompiledModule(identity: app.moduleIdentityFor(path),
      chunk: compileSource(source, path),
      macroExports: initTable[string, MacroDef](), syntaxFnExports: @[],
      compileInterface: buildCompileInterface(readAll(source), path))
    app.installCompiledModules([compiled])
    writeFile(path, "($panic \"mutable source must not execute\")")
    let broad = app.loadFileModule(path)
    removeFile(path)
    let narrow = run(compileSource("""
      (with_capabilities []
        (import [Item value] ^from "./library")
        [(value) Item])
    """), newGlobalScope(app))
    check narrow.listItems[0].intVal == 7
    check narrow.listItems[1].bits != broad.moduleRootNamespace.nsScope.lookup("Item").bits

  test "portable source names link relative capability roots to the admitted module base":
    let root = expandFilename(createTempDir("gene-ordinary-portable-", ""))
    defer: removeDir(root)
    createDir(root / "data")
    writeFile(root / "data" / "value", "linked")
    let app = newFilesystemPolicyApp(root)
    let code = compileSource("""
      (fn read [path] ^capabilities [(fs/Read "data")]
        (require_capabilities [(fs/Read "data")] ($fs/read_text path)))
    """, "package@revision::library")
    let module = app.loadCompiledFileModule(root / "library.gene", code)
    let scope = newGlobalScope(app)
    scope.define("library", module)
    scope.define("path", newStr(root / "data" / "value"))
    check run(compileSource("(library/read path)"), scope).strVal == "linked"
    check code.functions[0].capabilityRow.literal.source.baseDirectory == ""

  test "inherited compiled contracts keep the protocol's declaring base":
    let root = expandFilename(createTempDir("gene-ordinary-contract-base-", ""))
    defer: removeDir(root)
    createDir(root / "contracts" / "data")
    createDir(root / "implementation" / "data")
    writeFile(root / "contracts" / "data" / "value", "contract")
    writeFile(root / "implementation" / "data" / "value", "implementation")
    let app = newFilesystemPolicyApp(root)
    let contract = app.loadCompiledFileModule(root / "contracts" / "api.gene",
      compileSource("""
        (protocol P (message read [path] ^capabilities [(fs/Read "data")]))
      """, "package@revision::contracts/api"))
    let implementation = app.loadCompiledFileModule(root / "implementation" / "entry.gene",
      compileSource("""
        (import [P] ^from "../contracts/api")
        (type T)
        (impl P for T (message read [path] ($fs/read_text path)))
      """, "package@revision::implementation/entry"))
    let scope = newGlobalScope(app)
    scope.define("P", contract.moduleRootNamespace.nsScope.lookup("P"))
    scope.define("T", implementation.moduleRootNamespace.nsScope.lookup("T"))
    scope.define("good", newStr(root / "contracts" / "data" / "value"))
    scope.define("bad", newStr(root / "implementation" / "data" / "value"))
    check run(compileSource("""
      (var item (T))
      [(item .P:read good) (try (item .P:read bad) false catch MissingCapability true)]
    """), scope).print() == "[\"contract\" true]"

  test "failed reload leaves the published generation intact and an explicit retry can succeed":
    let root = expandFilename(createTempDir("gene-ordinary-reload-failure-", ""))
    defer: removeDir(root)
    let path = root / "library.gene"
    writeFile(path, "(fn value [] 1)")
    let app = ordinaryCapabilityApp(root)
    let first = app.loadFileModule(path)
    writeFile(path, "(unknown_initializer)")
    expect GeneError: discard app.reloadFileModule(path)
    check app.loadFileModule(path).bits == first.bits
    writeFile(path, "(fn value [] 2)")
    let next = app.reloadFileModule(path)
    check next.bits != first.bits
    let scope = newGlobalScope(app)
    scope.define("next", next)
    check run(compileSource("(next/value)"), scope).intVal == 2
