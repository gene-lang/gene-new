## The documentation builder's tests (design §7, Q36; milestone M1).
##
## Four things are checked here, in the order the design states them:
##   1. the fixtures cover every declaration kind, sidecars, exports, private
##      declarations, unreadable files, and forms the builder cannot expand;
##   2. a build runs nothing — no form, no `main`, no marker file;
##   3. two builds produce the same bytes;
##   4. the builder agrees with the runtime: for fixed modules, the names,
##      kinds, and signatures it reports are the ones `$declarations` and
##      `$runtime/signature` report. This test *does* run code (that is the
##      oracle); the builder's own pass above does not.
##
## Plus the dependency check: `gene-doc` must not link the VM, the compiler, or
## the standard library.

import std/[algorithm, json, os, osproc, sets, strutils, tables, unittest]
import gene/[callable_reflection, gir, package, printer, reader, types, vm,
            web]
import tools/declaration_heads
import tools/docs/builder as docBuilder
from tools/docs/model import DocEntry, DocImport, DocParam, ModuleDoc, renderModuleDoc

const docTestFixturesRelative = "tests/fixtures/docs"

proc docTestRepoRoot(): string =
  normalizedPath(parentDir(currentSourcePath()) / "..")

proc docTestFixturesRoot(): string = docTestRepoRoot() / docTestFixturesRelative

proc docTestFixture(name: string): string = docTestFixturesRoot() / "src" / name

proc docTestCopyTree(source, target: string, skipBuild = true) =
  createDir(target)
  for kind, path in walkDir(source):
    let name = lastPathPart(path)
    case kind
    of pcDir:
      if not (skipBuild and name == "build"):
        docTestCopyTree(path, target / name, skipBuild = false)
    of pcFile:
      copyFile(path, target / name)
    else:
      discard

type DocBuildResult = docBuilder.BuildResult

proc docTestBuildFixtures(): DocBuildResult =
  result = docBuilder.buildPackage(docTestFixturesRoot())
  result.summarize()

proc docTestDocFor(build: DocBuildResult, modulePath: string): ModuleDoc =
  for doc in build.modules:
    if doc.module == modulePath:
      return doc
  checkpoint "module not built: " & modulePath
  raise newException(ValueError, "module not built: " & modulePath)

proc docTestEntriesNamed(doc: ModuleDoc, name: string): seq[DocEntry] =
  for entry in doc.entries:
    if entry.name == name:
      result.add entry

proc docTestTopNamed(doc: ModuleDoc, name: string): seq[DocEntry] =
  let base = "lib/" & doc.module
  for entry in doc.entries:
    if entry.name == name and entry.parent == base:
      result.add entry

proc docTestAnyEntryNamed(doc: ModuleDoc, name: string): DocEntry =
  let found = doc.docTestEntriesNamed(name)
  check found.len == 1
  if found.len > 0:
    result = found[0]

proc docTestEntryNamed(doc: ModuleDoc, name: string): DocEntry =
  let found = doc.docTestTopNamed(name)
  check found.len == 1
  if found.len > 0:
    result = found[0]

# ---------------------------------------------------------------------------
# Fixtures: every kind, sidecars, and the records for what cannot be read
# ---------------------------------------------------------------------------

suite "doc builder — declaration pass":
  test "every declaration kind becomes an entry":
    let result = docTestBuildFixtures()
    let main = result.docTestDocFor("main")
    check main.package == "test/docs"
    check main.doc.startsWith("Fixture module")
    for name in ["greet", "twice", "naturals", "answer", "counter", "limit",
                 "Person", "Color", "Labelled", "Name", "tools"]:
      checkpoint "entry: " & name
      check main.docTestTopNamed(name).len == 1
    check main.docTestEntryNamed("twice").kind == dkMacro
    check main.docTestEntryNamed("answer").kind == dkLet
    check main.docTestEntryNamed("counter").kind == dkVar
    check main.docTestEntryNamed("limit").kind == dkConst
    check main.docTestEntryNamed("Name").kind == dkAlias
    check main.docTestEntryNamed("Person").kind == dkType
    check main.docTestEntryNamed("Color").kind == dkEnum
    check main.docTestEntryNamed("Labelled").kind == dkProtocol

  test "a callable's signature is the source text as written":
    let main = docTestBuildFixtures().docTestDocFor("main")
    let greet = main.docTestEntryNamed("greet")
    check greet.positional.len == 1
    check greet.positional[0].name == "name"
    check greet.positional[0].typ == "Str"
    check greet.positional[0].required
    check greet.named.len == 1
    check greet.named[0].name == "loud"
    check greet.named[0].local == "flag"
    check greet.named[0].typ == "Bool"
    check greet.named[0].default == "false"
    check greet.named[0].hasDefault
    check not greet.named[0].required
    check greet.result == "Str"
    check greet.errors == @["InputError"]
    check greet.doc == "Greet one person."
    check greet.see.len == 2
    check greet.status == "experimental"
    check greet.line == 5

  test "generator, fexpr, and doc meta are read from every kind":
    let main = docTestBuildFixtures().docTestDocFor("main")
    let naturals = main.docTestEntryNamed("naturals")
    check naturals.generator
    check not naturals.fexpr
    check naturals.result == "(Stream Int Never)"
    check naturals.doc.startsWith("Yield")
    check main.docTestEntryNamed("Color").doc == "A small colour set."
    check main.docTestEntryNamed("Labelled").doc == "Anything with a label."
    check main.docTestEntryNamed("tools").doc == "Small helpers."

  test "types record fields, body fields, messages, and the ctor":
    let main = docTestBuildFixtures().docTestDocFor("main")
    let person = main.docTestEntryNamed("Person")
    check person.named.len == 2
    check person.named[0].name == "name"
    check person.named[0].typ == "Str"
    check person.named[1].name == "nickname"
    check person.named[1].typ == "Str?"
    check not person.named[1].required
    check person.positional.len == 1
    if person.positional.len == 1:
      check person.positional[0].typ == "Int"
    check person.rest.typ == "Int"
    # Type messages and the ctor are children with addressable ids.
    var messages: seq[string]
    for entry in main.entries:
      if entry.parent == person.id:
        messages.add entry.name
    check messages == @["greet", "rename", "ctor"]

  test "protocol requirements use the send spelling":
    let main = docTestBuildFixtures().docTestDocFor("main")
    let labelled = main.docTestEntryNamed("Labelled")
    var ids: seq[string]
    for entry in main.entries:
      if entry.parent == labelled.id:
        ids.add entry.id
        check entry.kind == dkMessage
    check ids == @["lib/main/Labelled:label", "lib/main/Labelled:shout"]

  test "enums record their variants":
    let main = docTestBuildFixtures().docTestDocFor("main")
    let color = main.docTestEntryNamed("Color")
    check color.variants.len == 3
    check color.variants[0].name == "red"
    check color.variants[1].name == "green"
    check color.variants[2].name == "rgb"
    check color.variants[2].fields.len == 3

  test "namespaces recurse with qualified names and parents":
    let main = docTestBuildFixtures().docTestDocFor("main")
    let tools = main.docTestEntryNamed("tools")
    check tools.kind == dkNs
    let helper = main.docTestAnyEntryNamed("helper")
    check helper.id == "lib/main/tools/helper"
    check helper.parent == tools.id
    check main.docTestAnyEntryNamed("marker").kind == dkLet

  test "private declarations are hidden, not documented":
    let main = docTestBuildFixtures().docTestDocFor("main")
    check main.docTestTopNamed("hidden").len == 0
    check main.hidden == @["hidden"]

  test "the FFI and web declaration heads are mapped":
    let forms = docTestBuildFixtures().docTestDocFor("forms")
    for name in ["browser_app", "libc", "Point", "abs", "Number", "Callback",
                 "Signature"]:
      checkpoint "form entry: " & name
      check forms.docTestEntriesNamed(name).len == 1
    # A top-level `derive` has no meaning outside a protocol: recorded, not
    # silently dropped.
    check forms.unexpanded.len == 1
    check forms.unexpanded[0].head == "derive"

  test "a sidecar supplies prose and checks a restated shape":
    let paired = docTestBuildFixtures().docTestDocFor("paired")
    check paired.docTestEntryNamed("documented").doc == "Sidecar doc wins."
    check paired.docTestEntryNamed("documented").status == "experimental"
    check paired.docTestEntryNamed("described").see == @["book/values/text"]
    check paired.docTestEntryNamed("shaped").doc.startsWith("The sidecar restates")
    # The shape still comes from the source.
    check paired.docTestEntryNamed("shaped").positional[0].typ == "Int"
    check paired.docTestEntryNamed("shaped").result == "Int"

  test "a standalone sidecar documents a native namespace":
    let standalone = docTestBuildFixtures().docTestDocFor("standalone")
    check standalone.source == "src/standalone.doc.gene"
    check standalone.doc.startsWith("A native namespace")
    check standalone.entries.len == 1
    check standalone.entries[0].id == "lib/standalone/thing"
    check standalone.entries[0].forName == "standalone/thing"

  test "a shape mismatch and a dangling @for are diagnostics, not failures":
    let mismatch = docTestBuildFixtures().docTestDocFor("mismatch")
    var kinds: seq[string]
    for diagnostic in mismatch.diagnostics:
      kinds.add diagnostic.kind
    check "shape_mismatch" in kinds
    check "unresolved_for" in kinds

  test "a type inside a namespace keeps its path in its children's ids":
    let nested = docTestBuildFixtures().docTestDocFor("nested")
    check nested.diagnostics.len == 0
    for id in ["lib/nested/a/T/m", "lib/nested/a/T/ctor",
               "lib/nested/b/T/m", "lib/nested/b/T/ctor",
               "lib/nested/c/Q:n"]:
      checkpoint "id: " & id
      var found = false
      for entry in nested.entries:
        if entry.id == id:
          found = true
      check found

  test "sidecar diagnostics point into the sidecar, not the module source":
    let result = docTestBuildFixtures()
    let mismatch = result.docTestDocFor("mismatch")
    check mismatch.diagnostics.len == 2
    for diagnostic in mismatch.diagnostics:
      check diagnostic.source == "src/mismatch.doc.gene"
      check diagnostic.line in [1, 6]
      check diagnostic.col > 0
    let broken = result.docTestDocFor("broken_sidecar")
    check broken.entries.len == 1
    check broken.diagnostics.len == 1
    check broken.diagnostics[0].kind == "read_error"
    check broken.diagnostics[0].source == "src/broken_sidecar.doc.gene"

  test "the walk follows package membership, not directory names":
    let result = docTestBuildFixtures()
    # `src/build/` is ordinary source; only the package-root build output is
    # skipped. `src/excluded/**` is the manifest's own exclusion.
    check result.docTestDocFor("build/inner").entries.len == 1
    var excluded = false
    for doc in result.modules:
      if doc.module == "excluded/hidden":
        excluded = true
    check not excluded

  test "every application entry's directory is walked":
    let result = docBuilder.buildPackage(
      docTestRepoRoot() / "tests/fixtures/docs_multi")
    var paths: seq[string]
    for doc in result.modules:
      paths.add doc.module
    paths.sort()
    check paths == @["a/main", "b/main"]

  test "a lock that cannot load is a diagnostic, not a silent fallback":
    var result = docBuilder.buildPackage(
      docTestRepoRoot() / "tests/fixtures/docs_bad_lock")
    result.summarize()
    check result.buildDiagnostics.len == 1
    check result.buildDiagnostics[0].kind == "lock_unreadable"
    let main = result.docTestDocFor("main")
    check main.imports.len == 1
    check main.imports[0].resolvedModule.len == 0
    check result.unresolvedImports == 1
    let outDir = docTestRepoRoot() / "build/m1/doc-bad-lock"
    if dirExists(outDir): removeDir(outDir)
    result.writeOutputs(outDir)
    let coverage = readFile(outDir / "coverage.gene")
    check "lock_unreadable" in coverage
    check "^unresolved_imports 1" in coverage
    removeDir(outDir)

  test "imports are recorded with resolution, selectors, and re-export":
    let result = docTestBuildFixtures()
    let paired = result.docTestDocFor("paired")
    check paired.imports.len == 0
    let exports = result.docTestDocFor("exports")
    check exports.imports.len == 2
    let reexport = exports.imports[0]
    check reexport.path == "./main"
    check reexport.resolvedPackage == "test/docs"
    check reexport.resolvedModule == "main"
    check reexport.reexport
    check reexport.selections == @[("greet", "greet")]
    let plain = exports.imports[1]
    check not plain.reexport
    let forms = result.docTestDocFor("forms")
    check forms.imports.len == 1
    check forms.imports[0].implImport
    check forms.imports[0].resolvedModule == "main"
    let unresolved = result.docTestDocFor("unresolved")
    check unresolved.imports.len == 1
    check unresolved.imports[0].resolvedModule.len == 0
    check unresolved.imports[0].reason.len > 0
    let missing = result.docTestDocFor("missing_import")
    check missing.imports.len == 2
    for imported in missing.imports:
      check imported.resolvedModule.len == 0
      check "module not found" in imported.reason

  test "an unreadable file is a positioned diagnostic and the walk continues":
    let result = docTestBuildFixtures()
    var found = false
    for doc in result.modules:
      for diagnostic in doc.diagnostics:
        if diagnostic.kind == "read_error":
          found = true
          check diagnostic.line > 0
    check found
    check result.readErrors == 2
    let outDir = docTestRepoRoot() / "build/m1/doc-unreadable"
    if dirExists(outDir): removeDir(outDir)
    result.writeOutputs(outDir)
    check not fileExists(outDir / "modules" / "unreadable.gene")
    check fileExists(outDir / "modules" / "broken_sidecar.gene")
    let coverage = readFile(outDir / "coverage.gene")
    check "^unresolved_imports 3" in coverage
    check "^build_diagnostics []" in coverage
    removeDir(outDir)

  test "an unknown head becomes an unexpanded record":
    let userMacro = docTestBuildFixtures().docTestDocFor("user_macro")
    var heads: seq[string]
    for item in userMacro.unexpanded:
      heads.add item.head
    check heads == @["my_macro", "server"]

  test "the output is deterministic":
    let first = docTestBuildFixtures()
    let second = docTestBuildFixtures()
    for i in 0 ..< min(first.modules.len, second.modules.len):
      check renderModuleDoc(first.modules[i]) == renderModuleDoc(second.modules[i])
    let outA = docTestRepoRoot() / "build/m1/doc-determinism-a"
    let outB = docTestRepoRoot() / "build/m1/doc-determinism-b"
    if dirExists(outA): removeDir(outA)
    if dirExists(outB): removeDir(outB)
    docBuilder.writeOutputs(first, outA)
    docBuilder.writeOutputs(second, outB)
    var filesA, filesB: seq[string]
    for path in walkDirRec(outA): filesA.add relativePath(path, outA)
    for path in walkDirRec(outB): filesB.add relativePath(path, outB)
    filesA.sort()
    filesB.sort()
    check filesA == filesB
    for name in filesA:
      check readFile(outA / name) == readFile(outB / name)
    removeDir(outA)
    removeDir(outB)
    # The same corpus at a different absolute path renders the same bytes: no
    # diagnostic may leak an absolute path.
    let copyRoot = docTestRepoRoot() / "build/m1/docs-copy"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(docTestFixturesRoot(), copyRoot)
    let copied = docBuilder.buildPackage(copyRoot)
    check copied.modules.len == first.modules.len
    for i in 0 ..< min(first.modules.len, copied.modules.len):
      check first.modules[i].module == copied.modules[i].module
      check renderModuleDoc(first.modules[i]) == renderModuleDoc(copied.modules[i])
    removeDir(copyRoot)

  test "a build runs no form and calls no main":
    let marker = docTestFixturesRoot() / "RAN_MARKER"
    if fileExists(marker): removeFile(marker)
    let runs = docTestBuildFixtures().docTestDocFor("runs")
    check not fileExists(marker)
    check not fileExists("tests/fixtures/docs/RAN_MARKER")
    # The declarations are still read; the deliberately unknown calls are
    # recorded rather than executed.
    check runs.docTestEntriesNamed("main").len == 1
    check runs.unexpanded.len == 2
    check runs.unexpanded[0].head == "gene/fs/write_text"
    check runs.unexpanded[1].head == "gene/println"

# ---------------------------------------------------------------------------
# Conformance with the runtime
# ---------------------------------------------------------------------------

var docTestConformanceFailures = 0

template docTestConform(cond: untyped) =
  ## `check` inside a helper proc does not fail the enclosing test in this
  ## suite, so the conformance comparison counts its own mismatches and the
  ## test asserts the count.
  if not cond:
    inc docTestConformanceFailures
    checkpoint("conformance mismatch: " & astToStr(cond))

proc docTestCanonType(text: string): string =
  ## One spelling to compare declared and reflected types: strip immutability
  ## and accessor wrappers, desugar the `T?` suffix, and unwrap `(type T)`.
  var text = text.strip
  while text.len > 0 and text[0] == '#':
    text = text[1 .. ^1].strip
  text = text.replace("#(", "(").replace("#[", "[").replace("#{", "{")
  if text.len > 1 and text.endsWith("?") and not text.startsWith("(? "):
    text = "(? " & docTestCanonType(text[0 .. ^2]) & ")"
  if text.startsWith("(type ") and text.endsWith(")"):
    text = text[6 .. ^2].strip
  strutils.splitWhitespace(text).join(" ")

proc docTestCanonSource(text: string): string =
  if text.len == 0: return ""
  try:
    docTestCanonType(print(read(text)))
  except ReadError, GeneError:
    docTestCanonType(text)

proc docTestCanonValue(value: Value): string =
  if value.kind == vkNil: ""
  else: docTestCanonType(print(value))

proc docTestParamName(param: Value): string =
  let name = param.mapEntries.getOrDefault("name", NIL)
  if name.kind == vkString and name.strVal.len > 0:
    return name.strVal
  let local = param.mapEntries.getOrDefault("local", NIL)
  if local.kind == vkString: local.strVal else: ""

proc docTestCheckParam(label: string; declared: DocParam; actual: Value) =
  checkpoint label
  docTestConform docTestParamName(actual) == declared.name
  docTestConform actual.mapEntries.getOrDefault("required", FALSE).boolVal ==
    declared.required
  docTestConform actual.mapEntries.getOrDefault("has_default", FALSE).boolVal ==
    declared.hasDefault
  if declared.typ.len > 0:
    let known = actual.mapEntries.getOrDefault("type_known", FALSE)
    docTestConform known.kind == vkBool and known.boolVal
    docTestConform docTestCanonValue(actual.mapEntries.getOrDefault("type", NIL)) ==
      docTestCanonSource(declared.typ)

proc docTestCompareSignature(declared: DocEntry; signature: Value; stripSelf: bool;
                      typeLike = false) =
  ## Compare one declared signature with `$runtime/signature`'s description.
  ## A type reports inherited fields and messages, so for a type the declared
  ## fields must be present with the declared shape, not be the whole shape.
  checkpoint "signature for " & declared.id
  var positional = signature.props["positional"].listItems
  var named = signature.props["named"].listItems
  if stripSelf and positional.len > 0 and docTestParamName(positional[0]) == "self":
    positional = positional[1 .. ^1]
  var expectedNamed = declared.named
  expectedNamed.sort(proc (a, b: DocParam): int = cmp(a.name, b.name))
  named.sort(proc (a, b: Value): int = cmp(docTestParamName(a), docTestParamName(b)))
  if typeLike:
    docTestConform positional.len >= declared.positional.len
    for i in 0 ..< min(positional.len, declared.positional.len):
      docTestConform docTestParamName(positional[i]) == declared.positional[i].name
      docTestConform positional[i].mapEntries.getOrDefault("required", FALSE).boolVal ==
        declared.positional[i].required
      if declared.positional[i].typ.len > 0:
        docTestConform docTestCanonValue(positional[i].mapEntries.getOrDefault("type", NIL)) ==
          docTestCanonSource(declared.positional[i].typ)
    for param in expectedNamed:
      var found = false
      for actual in named:
        if docTestParamName(actual) == param.name:
          found = true
          docTestConform actual.mapEntries.getOrDefault("required", FALSE).boolVal ==
            param.required
          docTestConform docTestCanonValue(actual.mapEntries.getOrDefault("type", NIL)) ==
            docTestCanonSource(param.typ)
          break
      docTestConform found
  else:
    docTestConform positional.len == declared.positional.len
    for i in 0 ..< min(positional.len, declared.positional.len):
      docTestCheckParam("positional " & $i, declared.positional[i], positional[i])
    docTestConform named.len == expectedNamed.len
    for i in 0 ..< min(named.len, expectedNamed.len):
      docTestCheckParam("named " & expectedNamed[i].name, expectedNamed[i], named[i])
    let actualRest = signature.props.getOrDefault("rest", NIL)
    if declared.rest.typ.len > 0:
      docTestConform actualRest.kind == vkMap
      if actualRest.kind == vkMap:
        docTestConform docTestCanonValue(actualRest.mapEntries.getOrDefault("type", NIL)) ==
          docTestCanonSource(declared.rest.typ)
    else:
      docTestConform actualRest.kind == vkNil
    let namedRest = signature.props.getOrDefault("named_rest", NIL)
    if declared.namedRest.typ.len > 0:
      docTestConform namedRest.kind == vkMap
    else:
      docTestConform namedRest.kind == vkNil
    let resultType = signature.props.getOrDefault("result", NIL)
    if declared.result.len > 0:
      docTestConform docTestCanonValue(resultType) == docTestCanonSource(declared.result)
    else:
      docTestConform resultType.kind == vkNil
    let errors = signature.props["invocation_errors"]
    let checked = errors.mapEntries.getOrDefault("checked", FALSE)
    let runtimeErrors = errors.mapEntries.getOrDefault("types", NIL)
    if declared.errors.len > 0:
      docTestConform checked.kind == vkBool and checked.boolVal
      docTestConform runtimeErrors.kind == vkList
      if runtimeErrors.kind == vkList:
        docTestConform runtimeErrors.listItems.len == declared.errors.len
        for i in 0 ..< min(runtimeErrors.listItems.len, declared.errors.len):
          docTestConform docTestCanonValue(runtimeErrors.listItems[i]) ==
            docTestCanonSource(declared.errors[i])
    else:
      docTestConform not (checked.kind == vkBool and checked.boolVal)
    let execution = signature.props.getOrDefault("execution", NIL)
    docTestConform declared.generator ==
      (execution.kind == vkSymbol and execution.symVal == "generator")
    let category = signature.props.getOrDefault("category", NIL)
    docTestConform declared.fexpr ==
      (category.kind == vkSymbol and category.symVal == "fexpr")

proc docTestKindMatches(kind: DeclKind; value: Value): bool =
  let actual = declarationKind(value)
  case kind
  of dkFn: actual in ["Fn", "Fexpr"]
  of dkMacro: actual in ["Macro", "Fn"]
  of dkType, dkAlias, dkEnum, dkFfiStruct, dkFfiUnion, dkFfiCallback,
     dkFfiSignature: actual == "Type"
  of dkProtocol: actual == "Protocol"
  of dkNs: actual == "Namespace"
  of dkFfiFn: actual in ["FfiCallable", "NativeFn"]
  of dkWebModule: actual in ["Module", "Namespace"]
  of dkLet, dkVar, dkConst, dkFfiLibrary: true
  of dkImport, dkImportImpl, dkDerive, dkCtor, dkMessage, dkImpl,
     dkMod: true

proc docTestMacroNames(scope: Scope): seq[string] =
  ## `$declarations` does not report compiler macros, but the module's compile
  ## interface does, and `gene doc <file>` lists them. They are compared here
  ## from the same table that walk reads.
  if scope.compilerMacros != nil and scope.compilerMacros of MacroBindings:
    let context = MacroBindings(scope.compilerMacros)
    for name in context.ownedNames:
      if '/' notin name:
        result.add name

proc docTestScopeNames(scope: Scope): seq[string] =
  scope.materializeMirroredVars()
  for name in scope.vars.keys:
    if name.len == 0 or name[0] == '\0':
      continue
    if name in ["this_mod", "this_pkg"]:
      continue
    result.add name
  for name in docTestMacroNames(scope):
    result.add name
  result.sort()

proc docTestImportedNames(doc: ModuleDoc): seq[string] =
  for imported in doc.imports:
    for (_, local) in imported.selections:
      result.add local
    if imported.alias.len > 0:
      result.add imported.alias

proc docTestCompareModule(app: Application, doc: ModuleDoc, file: string,
                      compareDocs = true) =
  let abs = normalizedPath(absolutePath(file))
  let module = app.loadFileModule(abs)
  let scope = module.moduleRootNamespace.nsScope
  let runtimeNames = docTestScopeNames(scope)
  var declaredTop: seq[DocEntry]
  let base = "lib/" & doc.module
  for entry in doc.entries:
    if entry.parent == base:
      declaredTop.add entry
  var builderNames: seq[string]
  for entry in declaredTop:
    builderNames.add entry.name
  for name in docTestImportedNames(doc):
    builderNames.add name
  for name in doc.hidden:
    builderNames.add name.split("/")[^1]
  builderNames.sort()
  docTestConform builderNames == runtimeNames

  let macros = docTestMacroNames(scope)
  for entry in declaredTop:
    checkpoint "entry " & entry.id
    if entry.kind == dkMacro:
      # A macro is compile-time metadata, not a runtime binding.
      docTestConform entry.name in macros
      continue
    docTestConform scope.vars.hasKey(entry.name)
    if not scope.vars.hasKey(entry.name):
      continue
    let value = scope.vars[entry.name]
    docTestConform docTestKindMatches(entry.kind, value)
    case entry.kind
    of dkFn:
      let signature = describeCallable(value, reflectionTypeLookup)
      if signature.props.getOrDefault("shape_known", FALSE) == TRUE:
        docTestCompareSignature(entry, signature, stripSelf = false)
      # `@doc` reaches the runtime for a function, and the builder reads the
      # same string from the form.
      let runtimeDoc = signature.props.getOrDefault("doc", NIL)
      if compareDocs and entry.doc.len > 0:
        docTestConform runtimeDoc.kind == vkString and runtimeDoc.strVal == entry.doc
    of dkType:
      let signature = describeCallable(value, reflectionTypeLookup)
      docTestCompareSignature(entry, signature, stripSelf = false, typeLike = true)
      if compareDocs and entry.doc.len > 0:
        # Known runtime gap: the builder reads `@doc` from the form, and the
        # runtime still drops it for types, enums, and protocols. When the
        # runtime starts reporting it, this assertion fails on purpose.
        docTestConform signature.props.getOrDefault("doc", NIL).kind == vkNil
      # Named fields come from `^props`; reflection reports them in map order.
      var messageNames: seq[string]
      for name in typeDirectMessageNames(value):
        messageNames.add name
      var declaredMessages: seq[string]
      for child in doc.entries:
        if child.parent == entry.id and child.kind == dkMessage:
          declaredMessages.add child.name
          let message = typeDirectMessage(value, child.name)
          let messageSig = describeCallable(message, reflectionTypeLookup)
          docTestCompareSignature(child, messageSig, stripSelf = true)
      messageNames.sort()
      declaredMessages.sort()
      for name in declaredMessages:
        docTestConform name in messageNames
    of dkEnum:
      if compareDocs and entry.doc.len > 0:
        let signature = describeCallable(value, reflectionTypeLookup)
        docTestConform signature.props.getOrDefault("doc", NIL).kind == vkNil
      var variants: seq[string]
      for variant in enumVariants(value):
        variants.add enumVariantName(variant)
      var declared: seq[string]
      for variant in entry.variants:
        declared.add variant.name
      docTestConform declared == variants
    of dkProtocol:
      if compareDocs and entry.doc.len > 0:
        let signature = describeCallable(value, reflectionTypeLookup)
        docTestConform signature.props.getOrDefault("doc", NIL).kind == vkNil
      var runtimeNames: seq[string]
      for name, _ in protocolMessages(value):
        runtimeNames.add name
      var declaredNames: seq[string]
      for child in doc.entries:
        if child.parent == entry.id and child.kind == dkMessage:
          declaredNames.add child.name
          let message = protocolMessages(value)[child.name]
          let fn = protocolMessageSignatureFn(message)
          if fn.kind == vkFunction and fn.fnCode of FunctionProto:
            let signature = describeCallable(fn, reflectionTypeLookup,
              ReflectionOptions(requirement: true, abstractSelf: true))
            docTestCompareSignature(child, signature, stripSelf = true)
      runtimeNames.sort()
      declaredNames.sort()
      docTestConform declaredNames == runtimeNames
    of dkNs:
      let names = docTestScopeNames(value.nsScope)
      var declaredNames: seq[string]
      for child in doc.entries:
        if child.parent == entry.id:
          declaredNames.add child.name
      declaredNames.sort()
      docTestConform declaredNames == names
    else: discard

  # The messages of a type are children of its entry, but they are not in the
  # module scope, so the namespace comparison above must not expect them.

suite "doc builder — runtime conformance":
  test "fixture modules agree with $declarations and $runtime/signature":
    docTestConformanceFailures = 0
    let result = docTestBuildFixtures()
    var app: Application
    for name in ["main", "paired", "mismatch", "exports", "nested"]:
      let file = docTestFixture(name & ".gene")
      if app == nil:
        app = newApplicationForEntryFile(file)
      # A paired sidecar replaces prose by design, so the runtime's source
      # doc is not the documentation the builder emits.
      let hasSidecar = name in ["paired", "mismatch"]
      docTestCompareModule(app, result.docTestDocFor(name), file,
                        compareDocs = not hasSidecar)
    check docTestConformanceFailures == 0

  test "the stdlib's embedded Gene source agrees":
    docTestConformanceFailures = 0
    var build = docBuilder.buildPackage(docTestRepoRoot(), docTestRepoRoot() / "src/gene/lib")
    build.summarize()
    let doc = build.docTestDocFor("gene/sync")
    let app = newApplicationForEntryFile(docTestRepoRoot() / "src/gene/lib/sync.gene")
    docTestCompareModule(app, doc, docTestRepoRoot() / "src/gene/lib/sync.gene")
    check docTestConformanceFailures == 0

  test "the Harness's public modules agree":
    let harnessRoot = docTestRepoRoot() / "examples/gene-harness"
    if not dirExists(harnessRoot / "src/public"):
      checkpoint "no Harness public modules on this tree"
      check true
    else:
      docTestConformanceFailures = 0
      var build = docBuilder.buildPackage(harnessRoot)
      build.summarize()
      var files: seq[string]
      for kind, path in walkDir(harnessRoot / "src/public"):
        if kind == pcFile and path.endsWith(".gene"):
          files.add path
      files.sort()
      var app: Application
      for file in files:
        let rel = relativePath(file, harnessRoot).replace('\\', '/')
        let modulePath = rel[0 ..< rel.len - 5]
        var found = false
        for doc in build.modules:
          if doc.module == modulePath:
            found = true
            if app == nil:
              app = newApplicationForEntryFile(file)
            docTestCompareModule(app, doc, file)
            break
        check found
      check docTestConformanceFailures == 0

# ---------------------------------------------------------------------------
# Nothing from the VM or the compiler may be linked into gene-doc
# ---------------------------------------------------------------------------

proc docTestLinkedObjects(repo: string): seq[string] =
  let outDir = repo / "build/m1/doc-deps-test"
  createDir(outDir)
  let cache = outDir / "nimcache"
  let exe = outDir / "gene-doc"
  let command = "nim c --path:" & quoteShell(repo / "src") &
    " --hints:off --genDeps --nimcache:" & quoteShell(cache) &
    " -o:" & quoteShell(exe) & " " & quoteShell(repo / "src/gene_doc.nim")
  let built = execCmdEx(command, workingDir = repo)
  if built.exitCode != 0:
    checkpoint built.output
  check built.exitCode == 0
  let depsPath = cache / "gene-doc.json"
  if not fileExists(depsPath):
    checkpoint "gene-doc.json was not written"
    return
  let deps = parseFile(depsPath)
  for item in deps["link"]:
    result.add item.getStr()

suite "doc builder — no VM linked":
  test "gene-doc's import closure excludes vm, compiler, and stdlib":
    if findExe("nim").len == 0:
      checkpoint "nim is not on PATH; cannot verify the dependency list"
      check false
    else:
      let objects = docTestLinkedObjects(docTestRepoRoot())
      check objects.len > 0
      var moduleNames: seq[string]
      for path in objects:
        moduleNames.add lastPathPart(path)
      for forbidden in ["@sgene@svm.nim", "@sgene@scompiler.nim",
                        "@sgene@sstdlib.nim"]:
        for name in moduleNames:
          if name.startsWith(forbidden):
            checkpoint "linked: " & name
            check false
