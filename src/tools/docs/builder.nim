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
    buildDiagnostics*: seq[DocDiagnostic]   ## not attached to one module
    diagnosticCount*: int
    readErrors*: int
    entryCount*: int
    withDoc*: int
    unresolvedImports*: int
    unexpandedCount*: int

proc stableMessage(message, root: string): string =
  ## Diagnostics are data: they must not carry the checkout's absolute path.
  ## The package root and the user's home directory are the two prefixes the
  ## loader's messages can name.
  result = message.replace(root & "/", "").replace(root, ".")
  let home = getHomeDir()
  if home.len > 1:
    result = result.replace(home, "~")

proc graphFor(pkg: Package):
    tuple[graph: MaterializedGraph, diagnostic: DocDiagnostic] =
  ## The lock graph when there is one, so `^pkg` imports resolve to their real
  ## packages; otherwise the package stands alone. Reading the lock does not
  ## acquire, materialize, or run anything. A lock that cannot be loaded is
  ## reported, not swallowed: the build still runs, but a reader must be able
  ## to tell that every `^pkg` reason comes from that failure.
  let lockPath = packageLockPathFor(pkg.root)
  if fileExists(lockPath):
    try:
      let manager = newPackageManager()
      let resolution = manager.loadResolutionLock(pkg.root)
      return (MaterializedGraph(workspaceRoot: resolution.workspaceRoot,
        lockDigest: resolution.lockDigest,
        activePackageId: resolution.activePackageId,
        developmentPackageId: resolution.activePackageId,
        rootPackageIds: resolution.rootPackageIds,
        packagesById: resolution.packagesById), DocDiagnostic())
    except CatchableError as error:
      let newline = error.msg.find('\n')
      let text = if newline >= 0: error.msg[0 ..< newline] else: error.msg
      # The lock lives at the workspace root, which may be above pkg.root (a
      # workspace member), so both prefixes are made relative.
      var clean = stableMessage(text, pkg.root)
      clean = stableMessage(clean, parentDir(lockPath))
      return (singlePackageGraph(pkg), DocDiagnostic(
        kind: "lock_unreadable",
        message: "package.gene.lock could not be loaded, so ^pkg imports are " &
          "unresolved and names from dependencies are not documented: " & clean,
        source: "package.gene.lock"))
  (singlePackageGraph(pkg), DocDiagnostic())

proc moduleOutputPath(outputRoot, modulePath: string): string =
  var rel = modulePath.replace('\\', '/')
  if rel == "." or rel.len == 0:
    rel = "main"
  result = outputRoot / "modules" / (rel & ".gene")

proc unreadable(doc: ModuleDoc): bool =
  ## A sidecar that fails does not make the module's own source unreadable;
  ## `readable` is set only by the source read.
  not doc.readable

proc unresolvedImports(doc: ModuleDoc): int =
  for imported in doc.imports:
    if imported.resolvedModule.len == 0:
      inc result

proc writeModuleFiles(build: BuildResult) =
  let modulesRoot = build.outputRoot / "modules"
  if dirExists(modulesRoot):
    removeDir(modulesRoot)
  createDir(modulesRoot)
  for doc in build.modules:
    # A module that did not read has a diagnostic and no data file: an empty
    # module would tell a consumer the file is fine with zero entries.
    if doc.unreadable:
      continue
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
  var moduleDiagnostics = 0
  var unresolvedCount = 0
  var unverifiedCount = 0
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
    moduleDiagnostics += doc.diagnostics.len
    let unresolved = doc.unresolvedImports
    unresolvedCount += unresolved
    var moduleUnverified = 0
    for entry in entries:
      if entry.unverified:
        inc moduleUnverified
    unverifiedCount += moduleUnverified
    moduleRows.add "  {^module " & qq(doc.module) & " ^source " &
      qq(doc.source) & " ^entries " & $entries.len & " ^with_doc " &
      $moduleWithDoc & " ^unverified " & $moduleUnverified &
      " ^unresolved_imports " & $unresolved &
      " ^unexpanded " & $doc.unexpanded.len & " ^diagnostics " &
      $doc.diagnostics.len & "}"
  lines.addList("^modules", moduleRows)
  let diagnosticCount = moduleDiagnostics + build.buildDiagnostics.len
  lines.add " ^counts {^modules " & $modules.len & " ^entries " &
    $entriesCount & " ^with_doc " & $withDoc & " ^without_doc " &
    $(entriesCount - withDoc) & " ^unverified " & $unverifiedCount &
    " ^unresolved_imports " & $unresolvedCount &
    " ^unexpanded " & $unexpandedCount & " ^diagnostics " &
    $diagnosticCount & "}"
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
  var buildRows: seq[string]
  for diagnostic in build.buildDiagnostics:
    buildRows.add "  {^kind " & qq(diagnostic.kind) & " ^message " &
      qq(diagnostic.message) & " ^source " & qq(diagnostic.source) & "}"
  lines.addList("^build_diagnostics", buildRows)
  var diagnosticRows: seq[string]
  for doc in modules:
    for diagnostic in doc.diagnostics:
      var row = "  {^module " & qq(doc.module) & " ^kind " &
        qq(diagnostic.kind) & " ^message " & qq(diagnostic.message) &
        " ^source " & qq(diagnostic.source)
      if diagnostic.line > 0 or diagnostic.col > 0:
        row.add " ^line " & $diagnostic.line & " ^col " & $diagnostic.col
      row.add "}"
      diagnosticRows.add row
  lines.addList("^diagnostics", diagnosticRows)
  lines.add "}"
  lines.join("\n") & "\n"

proc writeCoverage(build: BuildResult) =
  writeFile(build.outputRoot / "coverage.gene", renderCoverage(build))

proc packageAndGraph*(startDir: string): tuple[pkg: Package,
    graph: MaterializedGraph, diagnostic: DocDiagnostic] =
  ## The package `startDir` belongs to and the graph its imports resolve in.
  ## A lock that cannot load is the diagnostic; its `kind` is "" otherwise.
  var pkg = discoverApplicationPackage(startDir)
  let (graph, graphDiagnostic) = graphFor(pkg)
  # The lock graph's instance carries the dependency edges and the instance
  # id; the freshly discovered package has neither. Prefer the graph's copy
  # when it names the same root.
  if graph.packagesById.hasKey(graph.activePackageId):
    let active = graph.packagesById[graph.activePackageId]
    if active.root == pkg.root:
      pkg = active
  (pkg, graph, graphDiagnostic)

proc buildPackage*(startDir: string, corpusDir = ""): BuildResult =
  ## Build one package's corpus. `startDir` is where package discovery starts;
  ## `corpusDir`, when given, is the directory the walk starts from (a subtree
  ## such as `src/gene/lib`).
  let (pkg, graph, graphDiagnostic) = packageAndGraph(startDir)
  if graphDiagnostic.kind.len > 0:
    result.buildDiagnostics.add graphDiagnostic
  var roots: seq[string]
  if corpusDir.len > 0:
    let root = normalizedPath(absolutePath(corpusDir))
    if not dirExists(root):
      raise newException(ValueError, "corpus directory does not exist: " & root)
    if not pkg.contains(root) and root != pkg.root:
      raise newException(ValueError,
        "corpus directory is outside package " & pkg.name & ": " & root)
    roots = @[root]
  else:
    roots = pkg.sourceRoots()
    if roots.len == 0:
      roots = @[pkg.root]
  var items: seq[CorpusItem]
  var seenFiles = initTable[string, bool]()
  for root in roots:
    if not dirExists(root):
      continue
    for item in corpusItems(pkg, root):
      let key = if item.sourceFile.len > 0: item.sourceFile else: item.sidecarFile
      if seenFiles.hasKey(key):
        continue
      seenFiles[key] = true
      items.add item
  items.sort(proc (a, b: CorpusItem): int = cmp(a.modulePath, b.modulePath))
  result.packageName = pkg.name
  result.packageRoot = pkg.root
  result.outputRoot = pkg.root / OutputDir
  for item in items:
    var doc: ModuleDoc
    if item.sourceFile.len > 0:
      doc = buildModuleDoc(pkg, item.sourceFile, item.modulePath, graph)
    else:
      doc = ModuleDoc(package: pkg.name, module: item.modulePath,
                      source: item.sourceRel)
    if item.sidecarFile.len > 0:
      mergeSidecar(doc, pkg, item.sidecarFile,
                   pkg.relativeToRoot(item.sidecarFile),
                   item.sourceFile.len == 0, graph)
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
    build.unexpandedCount += doc.unexpanded.len
    build.unresolvedImports += doc.unresolvedImports
  build.diagnosticCount += build.buildDiagnostics.len

proc writeOutputs*(build: BuildResult, outputRoot = "") =
  ## `outputRoot` is for tests that build twice; the command always uses the
  ## package's `<root>/build/docs`.
  let root = if outputRoot.len > 0: outputRoot else: build.outputRoot
  var target = build
  target.outputRoot = root
  createDir(root)
  writeModuleFiles(target)
  writeCoverage(target)
