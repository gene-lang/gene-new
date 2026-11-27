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
import gene/[callable_reflection, compiler, docs_lookup, gir, package, printer,
            reader, types, vm, web]
import tools/declaration_heads
import gene/doc_compiler_data
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

proc docTestWriteHeads(root: string, heads: seq[string]) =
  var quoted: seq[string]
  for head in heads:
    quoted.add("\"" & head.replace("\\", "\\\\").replace("\"", "\\\"") & "\"")
  createDir(root / "build" / "docs")
  writeFile(root / "build" / "docs" / "heads.gene",
    "[" & quoted.join(" ") & "]\n")

proc docTestRunGenerator(root: string) =
  ## Run `tools/docs` in this test's VM, the way `gene doc build` runs it.
  let mainPath = docTestRepoRoot() / "tools/docs/src/main.gene"
  check fileExists(mainPath)
  let app = newApplicationForEntryFile(mainPath)
  let module = app.loadFileModule(mainPath)
  let scope = module.moduleRootNamespace.nsScope
  var mainValue: Value
  check scope.lookupOptional("main", mainValue)
  if mainValue.kind == vkFunction:
    discard mainValue.call(@[newList(@[newStr(root)])])

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
    check standalone.entries.len == 2
    check standalone.entries[0].id == "lib/standalone/thing"
    check standalone.entries[0].forName == "standalone/thing"
    # A flagged declaration in a standalone sidecar is recorded, and nothing
    # else changes: the @for still has to match the native name.
    check standalone.entries[1].id == "lib/standalone/ghost"
    check standalone.entries[1].unverified
    check standalone.entries[1].ownUnverified
    check standalone.entries[1].forName == "standalone/ghost"
    check standalone.diagnostics.len == 0

  test "a shape mismatch and a dangling @for are diagnostics, not failures":
    let mismatch = docTestBuildFixtures().docTestDocFor("mismatch")
    var kinds: seq[string]
    for diagnostic in mismatch.diagnostics:
      kinds.add diagnostic.kind
    check "shape_mismatch" in kinds
    check "unresolved_for" in kinds

  test "@@unverified declares an entry the source does not show":
    let dynamic = docTestBuildFixtures().docTestDocFor("dynamic")
    proc entryById(id: string): DocEntry =
      for entry in dynamic.entries:
        if entry.id == id:
          return entry
      checkpoint "no entry: " & id
      check false
    # Declared by the sidecar alone: as written, flagged, located in the sidecar.
    let made = entryById("lib/dynamic/made_in_if")
    check made.unverified
    check made.forName == "dynamic/made_in_if"
    check made.sourceFile == "src/dynamic.doc.gene"
    check made.positional.len == 1 and made.positional[0].typ == "Int"
    check made.result == "Int"
    check made.doc.startsWith("Defined inside an `if`")
    # A prose map can still target it.
    check made.see == @["book/values/text"]
    # Everything inside a flagged form is flagged too.
    check entryById("lib/dynamic/Dyn").unverified
    check entryById("lib/dynamic/Dyn/go").unverified
    check entryById("lib/dynamic/Dyn/go").doc == "Runs it."
    # A flagged entry added to a namespace the source declares.
    let extra = entryById("lib/dynamic/tools/extra")
    check extra.unverified
    check extra.parent == "lib/dynamic/tools"
    # The source's own entries are untouched and unflagged.
    check not entryById("lib/dynamic/tools").unverified
    check not entryById("lib/dynamic/tools/helper").unverified
    # A flag on something the source does declare is stale: the entry stays the
    # source's, the prose merges, and the build says to remove the flag.
    let plain = entryById("lib/dynamic/plain")
    check not plain.unverified
    check plain.sourceFile.len == 0
    check plain.doc.startsWith("The source declares this one")
    check dynamic.diagnostics.len == 1
    check dynamic.diagnostics[0].kind == "unverified_in_source"
    check dynamic.diagnostics[0].source == "src/dynamic.doc.gene"
    # The data says which entries the builder could not verify.
    let text = renderModuleDoc(dynamic)
    check text.count("^unverified true") == 4
    check "^source \"src/dynamic.doc.gene\"" in text

  test "a stale @@unverified is reported once, for the flagged form":
    let stale = docTestBuildFixtures().docTestDocFor("stale_type")
    check stale.diagnostics.len == 1
    check stale.diagnostics[0].kind == "unverified_in_source"
    check stale.diagnostics[0].source == "src/stale_type.doc.gene"
    # The messages inherit the flag for adding, but are not each reported.
    check stale.docTestAnyEntryNamed("a").doc.len == 0
    check not stale.docTestAnyEntryNamed("a").unverified

  test "an unverified entry's id follows @for":
    let target = docTestBuildFixtures().docTestDocFor("unverified_target")
    check target.diagnostics.len == 0
    proc entryById(id: string): DocEntry =
      for entry in target.entries:
        if entry.id == id:
          return entry
      checkpoint "no entry: " & id
      check false
    # @for names the entry, so the id and ^for agree.
    let other = entryById("lib/unverified_target/other")
    check other.name == "zed"
    check other.forName == "unverified_target/other"
    check other.unverified
    check other.sourceFile == "src/unverified_target.doc.gene"
    # The flag directly on a message form and an inherited flag on a ctor.
    check entryById("lib/unverified_target/flag_msg").unverified
    check entryById("lib/unverified_target/flag_msg").ownUnverified
    check entryById("lib/unverified_target/Dyn/ctor").unverified
    check not entryById("lib/unverified_target/Dyn/ctor").ownUnverified
    # The data and coverage count what is not backed by source.
    var build = docTestBuildFixtures()
    build.summarize()
    let outDir = docTestRepoRoot() / "build/m1/doc-unverified"
    if dirExists(outDir): removeDir(outDir)
    docBuilder.writeOutputs(build, outDir)
    let coverage = readFile(outDir / "coverage.gene")
    check "^unverified 10" in coverage
    check "^counts {^modules 18" in coverage
    removeDir(outDir)

  test "an I/O read failure has no line and no absolute path":
    let root = docTestRepoRoot() / "build/m1/docs-io"
    if dirExists(root): removeDir(root)
    docTestCopyTree(docTestFixturesRoot(), root)
    let target = root / "src/main.gene"
    setFilePermissions(target, {})
    var readable = true
    try:
      discard readFile(target)
    except IOError:
      readable = false
    if not readable:
      var build = docBuilder.buildPackage(root)
      build.summarize()
      var main: ModuleDoc
      for doc in build.modules:
        if doc.module == "main":
          main = doc
      check main.diagnostics.len == 1
      check main.diagnostics[0].kind == "read_error"
      check main.diagnostics[0].line == 0
      check main.diagnostics[0].col == 0
      check main.diagnostics[0].message.startsWith("cannot read file: src/main.gene")
      check docTestRepoRoot() notin main.diagnostics[0].message
      check "^loc" notin renderModuleDoc(main)
    else:
      checkpoint "read permission is not enforced here; I/O failure not tested"
    setFilePermissions(target, {fpUserRead, fpUserWrite, fpGroupRead,
                                fpOthersRead})
    removeDir(root)

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
    check result.readErrors == 3
    let outDir = docTestRepoRoot() / "build/m1/doc-unreadable"
    if dirExists(outDir): removeDir(outDir)
    result.writeOutputs(outDir)
    check not fileExists(outDir / "modules" / "unreadable.gene")
    check fileExists(outDir / "modules" / "broken_sidecar.gene")
    # A broken source with a valid sidecar reports the source once; the sidecar
    # is not re-reported as dangling.
    let broken = result.docTestDocFor("broken_source")
    check broken.diagnostics.len == 1
    check broken.diagnostics[0].kind == "read_error"
    check broken.diagnostics[0].source == "src/broken_source.gene"
    check not fileExists(outDir / "modules" / "broken_source.gene")
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
    # Coverage carries diagnostics, so it is the file most likely to leak a
    # path; compare it too.
    let firstOut = docTestRepoRoot() / "build/m1/doc-copy-a"
    let copiedOut = docTestRepoRoot() / "build/m1/doc-copy-b"
    if dirExists(firstOut): removeDir(firstOut)
    if dirExists(copiedOut): removeDir(copiedOut)
    docBuilder.writeOutputs(first, firstOut)
    docBuilder.writeOutputs(copied, copiedOut)
    check readFile(firstOut / "coverage.gene") ==
      readFile(copiedOut / "coverage.gene")
    removeDir(firstOut)
    removeDir(copiedOut)
    removeDir(copyRoot)

  test "a lock failure names no checkout path":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_missing_dep_lock"
    let copyRoot = docTestRepoRoot() / "build/m1/missing-dep-lock-copy"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    var first = docBuilder.buildPackage(firstRoot)
    first.summarize()
    var second = docBuilder.buildPackage(copyRoot)
    second.summarize()
    check first.buildDiagnostics.len == 1
    let message = first.buildDiagnostics[0].message
    check first.buildDiagnostics[0].kind == "lock_unreadable"
    check "missing_dep/package.gene" in message
    check docTestRepoRoot() notin message
    check second.buildDiagnostics.len == 1
    check second.buildDiagnostics[0].message == message
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
  test "the generated corpus is identical at two checkout paths":
    let firstRoot = docTestFixturesRoot()
    let copyRoot = docTestRepoRoot() / "build/m1/docs-generator-copy"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    for root in [firstRoot, copyRoot]:
      removeDir(root / "build" / "docs")
      var built = docBuilder.buildPackage(root)
      built.writeOutputs(root / "build" / "docs")
    docTestRunGenerator(firstRoot)
    docTestRunGenerator(copyRoot)
    var filesA, filesB: seq[string]
    for path in walkDirRec(firstRoot / "build" / "docs"):
      filesA.add relativePath(path, firstRoot / "build" / "docs")
    for path in walkDirRec(copyRoot / "build" / "docs"):
      filesB.add relativePath(path, copyRoot / "build" / "docs")
    filesA.sort()
    filesB.sort()
    check filesA == filesB
    check "md/book/overview.md" in filesA
    check "llms.txt" in filesA
    check "manifest.gene" in filesA
    check "names.gene" in filesA
    check "gene-docs.sqlite" in filesA
    for name in filesA:
      check readFile(firstRoot / "build" / "docs" / name) ==
        readFile(copyRoot / "build" / "docs" / name)
    let twice = readFile(firstRoot / "build" / "docs" / "md" / "lib" / "main" /
      "twice.md")
    check "**Introduced in:**" in twice
    check "book/values/text" in twice
    let llms = readFile(firstRoot / "build" / "docs" / "llms.txt")
    check llms.startsWith("# test/docs documentation")
    check "## Reference" in llms
    let manifest = readFile(firstRoot / "build" / "docs" / "manifest.gene")
    check "^sizes {" in manifest
    check "^checks {^links \"ok\"" in manifest
    removeDir(copyRoot)

  test "a broken book link fails the link check before writing":
    let root = docTestRepoRoot() / "tests/fixtures/docs_bad_link"
    var built = docBuilder.buildPackage(root)
    built.writeOutputs()
    let keep = root / "build" / "docs" / "md" / "keep.md"
    createDir(root / "build" / "docs" / "md")
    writeFile(keep, "old corpus")
    var failed = false
    try:
      docTestRunGenerator(root)
    except GeneError as error:
      failed = true
      check "check problem" in error.msg
    check failed
    check fileExists(keep)

  test "the runtime corpus wins over a package corpus":
    let root = docTestRepoRoot()
    let built = root / "build" / "docs"
    if not fileExists(built / "manifest.gene"):
      var builtRepo = docBuilder.buildPackage(root)
      builtRepo.writeOutputs()
      docTestRunGenerator(root)
    let temp = root / "build/m1/corpus-precedence"
    if dirExists(temp): removeDir(temp)
    createDir(temp / "build" / "docs" / "md")
    writeFile(temp / "build" / "docs" / "manifest.gene", "{}")
    let saved = getCurrentDir()
    let hadRoot = existsEnv("GENE_DOCS_ROOT")
    let savedRoot = getEnv("GENE_DOCS_ROOT")
    try:
      delEnv("GENE_DOCS_ROOT")
      setCurrentDir(temp)
      check normalizedPath(findCorpus()) == normalizedPath(built)
      putEnv("GENE_DOCS_ROOT", temp)
      check normalizedPath(findCorpus()) == normalizedPath(temp / "build" / "docs")
      putEnv("GENE_DOCS_ROOT", "/nonexistent-corpus")
      check findCorpus() == ""
    finally:
      setCurrentDir(saved)
      if hadRoot: putEnv("GENE_DOCS_ROOT", savedRoot)
      else: delEnv("GENE_DOCS_ROOT")
    removeDir(temp)

  test "reflection entries keep their signature and build the same at two paths":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-reflect-copy"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    for root in [firstRoot, copyRoot]:
      removeDir(root / "build" / "docs")
      var built = docBuilder.buildPackage(root)
      built.writeOutputs(root / "build" / "docs")
    docTestRunGenerator(firstRoot)
    docTestRunGenerator(copyRoot)
    let page = firstRoot / "build" / "docs" / "md" / "lib" / "gene" / "runtime" /
      "with_context.md"
    check fileExists(page)
    if fileExists(page):
      let text = readFile(page)
      check "with_context" in text
      check "context" in text
    let bodyPage = firstRoot / "build" / "docs" / "md" / "lib" / "gene" /
      "node" / "body.md"
    check fileExists(bodyPage)
    if fileExists(bodyPage):
      let text = readFile(bodyPage)
      check "book/fences/real" in text
      check "book/fakes" notin text
    # `$"n=${n}"` reads as a `$to_str` call; only the written call counts.
    let toStrPage = firstRoot / "build" / "docs" / "md" / "lib" / "gene" /
      "to_str.md"
    check fileExists(toStrPage)
    if fileExists(toStrPage):
      let text = readFile(toStrPage)
      check "book/fences/real" in text
      check "book/fakes" notin text
    let rootPage = readFile(firstRoot / "build" / "docs" / "md" / "lib" /
      "gene.md")
    check rootPage.startsWith("# Built-in functions, types, and errors\n")
    var filesA, filesB: seq[string]
    for path in walkDirRec(firstRoot / "build" / "docs"):
      filesA.add relativePath(path, firstRoot / "build" / "docs")
    for path in walkDirRec(copyRoot / "build" / "docs"):
      filesB.add relativePath(path, copyRoot / "build" / "docs")
    filesA.sort()
    filesB.sort()
    check filesA == filesB
    for name in filesA:
      check readFile(firstRoot / "build" / "docs" / name) ==
        readFile(copyRoot / "build" / "docs" / name)
    removeDir(copyRoot)

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

  test "check 4: every compiler head has a book section":
    let root = docTestRepoRoot()
    var built = docBuilder.buildPackage(root)
    built.writeOutputs()
    writeCompilerDocData(root)
    docTestRunGenerator(root)
    let manifest = readFile(root / "build" / "docs" / "manifest.gene")
    check "^heads \"ok\"" in manifest
    let names = readFile(root / "build" / "docs" / "names.gene")
    check " ^heads [" in names
    check "{^spelling \"path\" ^introduced_in \"book/code_as_data/computed_paths\"}" in names
    # The compiler's namespace macros have reference pages, so check 2 needs
    # no exemption for them.
    check "^spelling \"$test/describe\" ^id \"lib/gene/test/describe\"" in names
    check "^spelling \"$log/log_info\" ^id \"lib/gene/log/log_info\"" in names
    let describe = readFile(root / "build" / "docs" / "md" / "lib" / "gene" /
                            "test" / "describe.md")
    check "$test/describe [description body...]" in describe
    # Type messages, spellings, paging, imported-selection credit, and the
    # index target.
    check fileExists(root / "build" / "docs" / "md" / "lib" / "gene" /
                     "List" / "push.md")
    let listPage = readFile(root / "build" / "docs" / "md" / "lib" / "gene" /
                            "List.md")
    check "## Messages" in listPage
    check "List.push" in listPage
    check fileExists(root / "build" / "docs" / "md" / "lib" / "gene" / "@2.md")
    let index = readFile(root / "build" / "docs" / "llms.txt")
    check "`List.push` is `lib/gene/List/push`" in index
    check "### Storage" in index
    let rootNs = readFile(root / "build" / "docs" / "md" / "lib" / "gene.md")
    var rootRows = 0
    for line in rootNs.splitLines:
      if line.startsWith("- ["): inc rootRows
    check rootRows <= 100
    check fileExists(root / "build" / "docs" / "md" / "lib" / "gene" / "@3.md")
    check "{^spelling \"List.push\" ^id \"lib/gene/List/push\"" in names
    check "{^spelling \"$str/join\" ^id \"lib/gene/str/join\" ^kind \"fn\" ^canonical true ^introduced_in \"book/names/the_standard_library\"" in names
    check "{^spelling \"List.join\" ^id \"lib/gene/List/join\" ^kind \"message\" ^canonical false" in names
    # Check 3 reports authored summaries per kind and for the book's names,
    # and the manifest reads back: the lookup loads it.
    check "^summaries {^kinds {^fn {^entries " in manifest
    check "^book_used {^entries 104 ^with_summary 104}" in manifest
    check "^namespace {^entries 52 ^with_summary 52}" in manifest
    let corpus = loadCorpus(root / "build" / "docs")
    check "lib/gene/List/push" in corpus.byId
    # The content file is not a module.
    check not fileExists(root / "build" / "docs" / "md" / "lib" / "gene" /
                         "content.md")
    check "lib/gene/content" notin corpus.byId
    # Content documents reflected names; a sidecar's own docs stay.
    let absentPage = readFile(root / "build" / "docs" / "md" / "lib" /
                              "gene" / "absent?.md")
    check "Returns true when the value is `nil`" in absentPage
    let trimPage = readFile(root / "build" / "docs" / "md" / "lib" /
                            "gene" / "str" / "trim.md")
    check "Returns `text` without leading and trailing whitespace" in trimPage
    check "— String operations" in index
    # A summary keeps a code span whole.
    check "max_bytes bytes" in readFile(root / "build" / "docs" / "md" / "lib" /
                                        "gene" / "str.md")
    # A protocol requirement keeps its colon spelling and has no dot row.
    check "{^spelling \"csv/IoResource:close\" ^id \"lib/gene/csv/IoResource:close\"" in names
    check "{^spelling \"csv.IoResource:close\"" notin names
    let requirement = readFile(root / "build" / "docs" / "md" / "lib" / "gene" /
                               "csv" / "IoResource:close.md")
    check requirement.startsWith("# $csv/IoResource:close\n")
    # A re-exported protocol's requirements alias the canonical declaration's.
    check "**Alias of:** [`$io/IoResource:close`]" in requirement
    # A message signature leaves out the receiver, and an inherited message
    # points at the type that declares it.
    let inherited = readFile(root / "build" / "docs" / "md" / "lib" / "gene" /
                             "ActorClosed" / "message.md")
    check "ActorClosed.message [] : Str" in inherited
    check "**Inherited from:** [`Throwable.message`](../Throwable/message.md)" in inherited
    # The canonical entry names its receiver forms.
    let size = readFile(root / "build" / "docs" / "md" / "lib" / "gene" / "size.md")
    check "**Receiver form:** [`List.size`](List/size.md)" in size
    # An alias carries its canonical entry's summary.
    check "[List.size](List/size.md) — Alias of `$size`: Returns the number" in listPage
    check "[ActorClosed.message](ActorClosed/message.md) — Inherited from `Throwable.message`." in
      readFile(root / "build" / "docs" / "md" / "lib" / "gene" / "ActorClosed.md")
    # The paged namespace says which page holds which names.
    check "Pages: page 1 (this page): `$" in rootNs
    check "[page 2](gene/@2.md): `" in rootNs
    # Index summaries are whole words, without the chapter opener.
    check "This chapter " notin index
    check "..." notin index
    check "No corpus is built yet for `genex/" in index

  test "check 4: a head with no section fails the build and names the head":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-missing-head"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    var built = docBuilder.buildPackage(copyRoot)
    built.writeOutputs()
    docTestWriteHeads(copyRoot, @["let", "zzz_missing_head"])
    var failed = false
    try:
      docTestRunGenerator(copyRoot)
    except GeneError as error:
      failed = true
      check "zzz_missing_head" in error.msg
    check failed

  test "SKILL.md is generated from the overview page":
    let root = docTestRepoRoot()
    let skillPath = root / "tools" / "gene-lang-skill" / "SKILL.md"
    var built = docBuilder.buildPackage(root)
    built.writeOutputs()
    writeCompilerDocData(root)
    docTestRunGenerator(root)
    let pagePath = root / "build" / "docs" / "skill.md"
    let skill = readFile(skillPath)
    let close = skill.find("\n---", 3)
    check close > 0
    if close > 0:
      let body = skill[close + 4 .. ^1].strip()
      check body == readFile(pagePath).strip()

  test "check 2: a stale qualified name fails the build":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-stale-name"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    var built = docBuilder.buildPackage(copyRoot)
    built.writeOutputs()
    docTestWriteHeads(copyRoot, @["let"])
    writeFile(copyRoot / "AGENTS.md",
      "```gene\n`(do %x)\n```\n\nUse `$str/no_such_name` here.\n")
    var failed = false
    try:
      docTestRunGenerator(copyRoot)
    except GeneError as error:
      failed = true
      check "no_such_name" in error.msg
    check failed

  test "check 2: an import does not hide a stale qualified name":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-import-stale"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    let book = copyRoot / "docs" / "book" / "fences.md"
    writeFile(book, readFile(book) &
      "\n## Imported\n\n```gene\n(import $str/[join])\n($str/no_such_fence \"x\")\n```\n")
    var built = docBuilder.buildPackage(copyRoot)
    built.writeOutputs()
    docTestWriteHeads(copyRoot, @["let"])
    var failed = false
    try:
      docTestRunGenerator(copyRoot)
    except GeneError as error:
      failed = true
      check "no_such_fence" in error.msg
    check failed

  test "check 2: stale import targets and selections fail":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-import-targets"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    let book = copyRoot / "docs" / "book" / "fences.md"
    writeFile(book, readFile(book) &
      "\n## Imports\n\n```gene\n(import $strs/[join])\n(import $str/[no_such_sel])\n```\n")
    var built = docBuilder.buildPackage(copyRoot)
    built.writeOutputs()
    docTestWriteHeads(copyRoot, @["let"])
    var failed = false
    try:
      docTestRunGenerator(copyRoot)
    except GeneError as error:
      failed = true
      check "import target `$strs`" in error.msg
      check "`$str/no_such_sel`" in error.msg
    check failed

  test "check 2: nested and aliased standard selections pass":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-import-nested"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    let book = copyRoot / "docs" / "book" / "fences.md"
    writeFile(book, readFile(book) &
      "\n## Nested imports\n\n```gene\n(import $db/[sqlite/[Db open]])\n" &
      "(import $str/[join:glue])\n```\n")
    var built = docBuilder.buildPackage(copyRoot)
    built.writeOutputs()
    docTestWriteHeads(copyRoot, @["let"])
    docTestRunGenerator(copyRoot)
    let manifest = readFile(copyRoot / "build" / "docs" / "manifest.gene")
    check "^stale \"ok\"" in manifest

  test "check 2: a stale nested or aliased selection fails":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-import-nested-stale"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    let book = copyRoot / "docs" / "book" / "fences.md"
    writeFile(book, readFile(book) &
      "\n## Nested imports\n\n```gene\n(import $db/[sqlite/[NoSuchDb]])\n" &
      "(import $str/[no_such_join:glue])\n```\n")
    var built = docBuilder.buildPackage(copyRoot)
    built.writeOutputs()
    docTestWriteHeads(copyRoot, @["let"])
    var failed = false
    try:
      docTestRunGenerator(copyRoot)
    except GeneError as error:
      failed = true
      check "`$db/sqlite/NoSuchDb`" in error.msg
      check "`$str/no_such_join`" in error.msg
    check failed

  test "check 2: a test macro's params list binds its fixture":
    # The binder comes from the macro data: without macros.gene, `t` is unbound
    # and `t/items` fails; with it, `it` binds its params list.
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-test-binder"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    let book = copyRoot / "docs" / "book" / "fences.md"
    writeFile(book, readFile(book) &
      "\n## Test block\n\n```gene\n(describe \"x\"\n  (it \"y\" [t]\n" &
      "    (t/items .push 1)\n    t/items/.empty?))\n```\n")
    var built = docBuilder.buildPackage(copyRoot)
    built.writeOutputs()
    docTestWriteHeads(copyRoot, @["let"])
    var failed = false
    try:
      docTestRunGenerator(copyRoot)
    except GeneError as error:
      failed = true
      check "`t/items`" in error.msg
    check failed
    writeFile(copyRoot / "build" / "docs" / "macros.gene", compilerMacrosText())
    docTestRunGenerator(copyRoot)
    let manifest = readFile(copyRoot / "build" / "docs" / "manifest.gene")
    check "^stale \"ok\"" in manifest

  test "check 2: names a test block does not bind, and names before a send, fail":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-test-binder-stale"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    let book = copyRoot / "docs" / "book" / "fences.md"
    writeFile(book, readFile(book) &
      "\n## Test block\n\n```gene\n(describe \"x\"\n  (it \"y\" [t]\n" &
      "    (u/items .push 1)\n    ($println $str/no_such/.size)))\n```\n")
    var built = docBuilder.buildPackage(copyRoot)
    built.writeOutputs()
    docTestWriteHeads(copyRoot, @["let"])
    writeFile(copyRoot / "build" / "docs" / "macros.gene", compilerMacrosText())
    var failed = false
    try:
      docTestRunGenerator(copyRoot)
    except GeneError as error:
      failed = true
      check "`u/items`" in error.msg
      check "`$str/no_such`" in error.msg
      check "`t/items`" notin error.msg
    check failed

  test "the content file documents reflected names, once each":
    let firstRoot = docTestRepoRoot() / "tests/fixtures/docs_reflect"
    let copyRoot = docTestRepoRoot() / "build/m1/docs-test-content"
    if dirExists(copyRoot): removeDir(copyRoot)
    docTestCopyTree(firstRoot, copyRoot)
    # A sidecar that documents one native, so content cannot document it too.
    createDir(copyRoot / "src" / "gene" / "lib")
    writeFile(copyRoot / "src" / "gene" / "lib" / "json.doc.gene",
      "(fn parse [text : Str]\n  @doc \"Parses JSON text.\"\n" &
      "  @for \"gene/json/parse\"\n  nil)\n")
    var built = docBuilder.buildPackage(copyRoot)
    built.writeOutputs()
    docTestWriteHeads(copyRoot, @["let"])
    writeFile(copyRoot / "build" / "docs" / "macros.gene", compilerMacrosText())
    let content = copyRoot / "docs" / "reference.gene"
    writeFile(content, "{^namespaces [{^id \"lib/gene/bit\" ^doc \"Bits.\"}]\n" &
      " ^entries [{^for \"gene/List/push\" ^doc \"Appends an item.\" ^errors [\"Oops\"]}]}\n")
    docTestRunGenerator(copyRoot)
    let push = readFile(copyRoot / "build" / "docs" / "md" / "lib" / "gene" /
                        "List" / "push.md")
    check "Appends an item." in push
    check "**Errors:** Oops" in push
    check "# bit — Bits." in readFile(copyRoot / "build" / "docs" / "md" / "lib" /
                                      "gene" / "bit.md")
    for (text, expected) in [
        ("{^entries [{^for \"gene/no_such\" ^doc \"x\"}]}",
         "docs/reference.gene: gene/no_such names no reference entry"),
        ("{^entries [{^for \"gene/List/size\" ^doc \"x\"}]}",
         "gene/List/size is an alias of lib/gene/size; document that entry instead"),
        ("{^entries [{^for \"gene/json/parse\" ^doc \"x\"}]}",
         "gene/json/parse is already documented in src/gene/lib/json.doc.gene"),
        ("{^entries [{^for \"gene/List/push\" ^doc \"a\"} {^for \"gene/List/push\" ^doc \"b\"}]}",
         "gene/List/push is documented twice"),
        ("{^namespaces [{^id \"lib/gene/nope\" ^doc \"x\"}]}",
         "lib/gene/nope names no namespace")]:
      writeFile(content, text & "\n")
      var failed = false
      try:
        docTestRunGenerator(copyRoot)
      except GeneError as error:
        failed = true
        checkpoint error.msg
        check expected in error.msg
      check failed
