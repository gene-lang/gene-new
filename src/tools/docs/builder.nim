## The documentation builder (design §7, Q36): walk, read, merge, emit.
##
## This is a third engine beside the compiler and the VM. It reads source,
## follows module resolution, and never compiles a body or runs a form. Its
## output is one Gene data file per module plus a coverage report; the later
## Gene generator (`tools/docs`) turns those into Markdown and a site.

import std/[algorithm, os, strutils, tables]
import ../../gene/[package]
import ./declarations
import ./model
import ./package_walk
import ./sidecar

type
  BuildResult* = object
    packageName*: string
    packageRoot*: string
    outputRoot*: string
    modules*: seq[ModuleDoc]
    diagnosticCount*: int
    readErrors*: int
    entryCount*: int
    withDoc*: int
    missingDoc*: seq[string]
    unexpandedCount*: int

proc graphFor(pkg: Package): MaterializedGraph =
  ## The lock graph when there is one, so `^pkg` imports resolve to their real
  ## packages; otherwise the package stands alone. Reading the lock does not
  ## acquire, materialize, or run anything, and a lock that no longer matches
  ## the tree falls back rather than failing the build.
  let lockPath = packageLockPathFor(pkg.root)
  if fileExists(lockPath):
    try:
      let manager = newPackageManager()
      let resolution = manager.loadResolutionLock(pkg.root)
      return MaterializedGraph(workspaceRoot: resolution.workspaceRoot,
        lockDigest: resolution.lockDigest,
        activePackageId: resolution.activePackageId,
        developmentPackageId: resolution.activePackageId,
        rootPackageIds: resolution.rootPackageIds,
        packagesById: resolution.packagesById)
    except CatchableError:
      discard
  singlePackageGraph(pkg)

proc moduleOutputPath(outputRoot, modulePath: string): string =
  var rel = modulePath.replace('\\', '/')
  if rel == "." or rel.len == 0:
    rel = "main"
  result = outputRoot / "modules" / (rel & ".gene")

proc writeModuleFiles(build: BuildResult) =
  let modulesRoot = build.outputRoot / "modules"
  if dirExists(modulesRoot):
    removeDir(modulesRoot)
  createDir(modulesRoot)
  for doc in build.modules:
    let path = moduleOutputPath(build.outputRoot, doc.module)
    createDir(parentDir(path))
    writeFile(path, renderModuleDoc(doc))

proc addList(lines: var seq[string], name: string, items: seq[string]) =
  if items.len == 0:
    lines.add " " & name & " []"
  else:
    lines.add " " & name & " ["
    for item in items:
      lines.add item
    lines.add " ]"

proc renderCoverage(build: BuildResult): string =
  var lines: seq[string]
  lines.add "{^format 1"
  lines.add " ^package " & qq(build.packageName)
  var moduleRows: seq[string]
  var modules = build.modules
  modules.sort(proc (a, b: ModuleDoc): int = cmp(a.module, b.module))
  var entriesCount = 0
  var withDoc = 0
  var unexpandedCount = 0
  var diagnosticCount = 0
  var missing: seq[string]
  for doc in modules:
    var entries = doc.entries
    entries.sort(proc (a, b: DocEntry): int = cmp(a.id, b.id))
    var moduleWithDoc = 0
    for entry in entries:
      if entry.doc.len > 0:
        inc moduleWithDoc
      else:
        missing.add entry.id
    entriesCount += entries.len
    withDoc += moduleWithDoc
    unexpandedCount += doc.unexpanded.len
    diagnosticCount += doc.diagnostics.len
    moduleRows.add "  {^module " & qq(doc.module) & " ^source " &
      qq(doc.source) & " ^entries " & $entries.len & " ^with_doc " &
      $moduleWithDoc & " ^unexpanded " & $doc.unexpanded.len &
      " ^diagnostics " & $doc.diagnostics.len & "}"
  lines.addList("^modules", moduleRows)
  lines.add " ^counts {^modules " & $modules.len & " ^entries " &
    $entriesCount & " ^with_doc " & $withDoc & " ^without_doc " &
    $(entriesCount - withDoc) & " ^unexpanded " & $unexpandedCount &
    " ^diagnostics " & $diagnosticCount & "}"
  missing.sort()
  var missingRows: seq[string]
  for id in missing:
    missingRows.add "  {^id " & qq(id) & "}"
  lines.addList("^missing_doc", missingRows)
  var unexpandedRows: seq[string]
  for doc in modules:
    for item in doc.unexpanded:
      unexpandedRows.add "  {^module " & qq(doc.module) & " ^line " &
        $item.line & " ^head " & qq(item.head) & "}"
  lines.addList("^unexpanded", unexpandedRows)
  var diagnosticRows: seq[string]
  for doc in modules:
    for diagnostic in doc.diagnostics:
      diagnosticRows.add "  {^module " & qq(doc.module) & " ^kind " &
        qq(diagnostic.kind) & " ^message " & qq(diagnostic.message) &
        " ^source " & qq(diagnostic.source) & " ^line " & $diagnostic.line &
        " ^col " & $diagnostic.col & "}"
  lines.addList("^diagnostics", diagnosticRows)
  lines.add "}"
  lines.join("\n") & "\n"

proc writeCoverage(build: BuildResult) =
  writeFile(build.outputRoot / "coverage.gene", renderCoverage(build))

proc buildPackage*(startDir: string, corpusDir = ""): BuildResult =
  ## Build one package's corpus. `startDir` is where package discovery starts;
  ## `corpusDir`, when given, is the directory the walk starts from (a subtree
  ## such as `src/gene/lib`).
  var pkg = discoverApplicationPackage(startDir)
  let graph = graphFor(pkg)
  # The lock graph's instance carries the dependency edges and the instance
  # id; the freshly discovered package has neither. Prefer the graph's copy
  # when it names the same root.
  if graph.packagesById.hasKey(graph.activePackageId):
    let active = graph.packagesById[graph.activePackageId]
    if active.root == pkg.root:
      pkg = active
  var walkRoot = ""
  if corpusDir.len > 0:
    walkRoot = normalizedPath(absolutePath(corpusDir))
  else:
    let roots = pkg.sourceRoots()
    if roots.len > 0: walkRoot = roots[0]
    else: walkRoot = pkg.root
  if not dirExists(walkRoot):
    raise newException(ValueError, "corpus directory does not exist: " & walkRoot)
  if not pkg.contains(walkRoot) and walkRoot != pkg.root:
    raise newException(ValueError,
      "corpus directory is outside package " & pkg.name & ": " & walkRoot)
  result.packageName = pkg.name
  result.packageRoot = pkg.root
  result.outputRoot = pkg.root / OutputDir
  let items = corpusItems(pkg, walkRoot)
  for item in items:
    var doc: ModuleDoc
    if item.sourceFile.len > 0:
      doc = buildModuleDoc(pkg, item.sourceFile, item.modulePath, graph)
    else:
      doc = ModuleDoc(package: pkg.name, module: item.modulePath,
                      source: item.sourceRel)
    if item.sidecarFile.len > 0:
      mergeSidecar(doc, pkg, item.sidecarFile, item.sourceFile.len == 0, graph)
    elif item.sourceFile.len == 0 and item.sidecarFile.len == 0:
      discard
    result.modules.add doc

proc summarize*(build: var BuildResult) =
  for doc in build.modules:
    for diagnostic in doc.diagnostics:
      if diagnostic.kind == "read_error":
        inc build.readErrors
      inc build.diagnosticCount
    for entry in doc.entries:
      inc build.entryCount
      if entry.doc.len > 0: inc build.withDoc
      else: build.missingDoc.add entry.id
    build.unexpandedCount += doc.unexpanded.len

proc writeOutputs*(build: BuildResult, outputRoot = "") =
  ## `outputRoot` is for tests that build twice; the command always uses the
  ## package's `<root>/build/docs`.
  let root = if outputRoot.len > 0: outputRoot else: build.outputRoot
  var target = build
  target.outputRoot = root
  createDir(root)
  writeModuleFiles(target)
  writeCoverage(target)
