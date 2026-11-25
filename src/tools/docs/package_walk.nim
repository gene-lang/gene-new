## Corpus discovery: which files a documentation build reads (design §7, Q37).
##
## Modules are found by walking a directory, never by following imports. That
## is deliberate: an entry script, a plugin loaded by path, or a file added
## today is documented even when nothing imports it. Imports are recorded
## separately and only describe edges among the modules the walk found.

import std/[algorithm, os, strutils, tables]
import ../../gene/[package, reader, types]

const
  DocSuffix* = ".doc.gene"
  SourceSuffix* = ".gene"
  ManifestFileName* = "package.gene"
  OutputDir* = "build/docs"

type
  CorpusItem* = object
    modulePath*: string     ## logical module path (`gene/str`, `src/public/x`)
    sourceFile*: string     ## the module source; "" for a standalone sidecar
    sidecarFile*: string    ## the paired sidecar; "" when there is none
    sourceRel*: string      ## package-relative path for `^source`

proc declaresLibrary(pkg: Package): bool =
  ## `^library {}` has no importable entry, so `Package.hasLibrary` is false,
  ## but the manifest still declares where the package's own sources live.
  if pkg.manifestPath.len == 0 or not fileExists(pkg.manifestPath):
    return false
  try:
    let forms = readAll(readFile(pkg.manifestPath), pkg.manifestPath)
    if forms.len == 1 and forms[0].kind == vkMap:
      return forms[0].mapEntries.hasKey("library")
  except ReadError, IOError:
    return false

proc sourceRoots*(pkg: Package): seq[string] =
  ## The directories the default walk starts from: the library root, else each
  ## application entry's directory, else the package root. A package that
  ## declares an empty `^library {}` still keeps its sources under the
  ## conventional source directory.
  let bases = pkg.moduleBases()
  if bases.len > 0:
    for base in bases:
      result.add normalizedPath(absolutePath(base))
    return
  for application in pkg.applications:
    if application.entry.len == 0:
      continue
    let dir = normalizedPath(absolutePath(parentDir(
      pkg.root / application.entry)))
    if dir notin result:
      result.add dir
  if result.len > 0:
    return
  if pkg.declaresLibrary:
    let srcDir = if pkg.sourceDir.len > 0: pkg.sourceDir else: "src"
    let candidate = normalizedPath(absolutePath(pkg.root / srcDir))
    if dirExists(candidate):
      return @[candidate]
  @[pkg.root]

proc relativeToRoot(pkg: Package, path: string): string =
  relativePath(path, pkg.root).replace('\\', '/')

proc skippedDir(pkg: Package, path: string): bool =
  ## A directory the walk must not enter: another package's root, a generated
  ## or vendored tree, or a subtree the manifest excludes.
  let rel = pkg.relativeToRoot(path)
  if rel == "." or rel.len == 0:
    return false
  if fileExists(path / ManifestFileName) and path != pkg.root:
    return true
  let name = lastPathPart(path)
  if name in ["build", "vendor", "node_modules"]:
    return true
  if rel.startsWith("build/") or rel.startsWith("vendor/"):
    return true
  for pattern in pkg.files.excludes:
    if pattern.endsWith("/**") and workspaceMemberMatches(pattern, rel):
      return true

proc excludedByManifest(pkg: Package, path: string): bool =
  let rel = pkg.relativeToRoot(path)
  for pattern in pkg.files.excludes:
    if workspaceMemberMatches(pattern, rel):
      return true
  if pkg.files.includes.len > 0:
    var included = false
    for pattern in pkg.files.includes:
      if workspaceMemberMatches(pattern, rel):
        included = true
        break
    if not included:
      return true

proc skippedFile(pkg: Package, path: string): bool =
  let name = lastPathPart(path)
  if not name.endsWith(SourceSuffix):
    return true
  if name == ManifestFileName or name.endsWith("_spec.gene"):
    return true
  let rel = pkg.relativeToRoot(path)
  for segment in rel.split('/'):
    if segment == ".gene" or segment.startsWith(".gene-"):
      return true
  if pkg.excludedByManifest(path):
    return true

proc walkGeneFiles(pkg: Package, root: string): seq[string] =
  ## Every `.gene` file under `root`, skipping nested packages, test specs,
  ## manifests, generated stores, and manifest-excluded paths. Sorted, so the
  ## walk has one order.
  var stack = @[root]
  while stack.len > 0:
    let dir = stack.pop()
    var children: seq[string]
    for kind, path in walkDir(dir):
      case kind
      of pcFile:
        if not pkg.skippedFile(path):
          result.add normalizedPath(absolutePath(path))
      of pcDir:
        if not pkg.skippedDir(path):
          children.add path
      of pcLinkToDir:
        # Follow a symlinked directory only when its real target stays inside
        # the package. A link out of the tree is not this package's source.
        let real = canonicalPath(path)
        if containsPath(pkg.realRoot, real) and not pkg.skippedDir(path):
          children.add path
      else:
        discard
    for child in children:
      stack.add child
  result.sort()

proc stripSourceSuffix(path: string): string =
  if path.endsWith(SourceSuffix):
    path[0 ..< path.len - SourceSuffix.len]
  else:
    path

proc stripDocSuffix(path: string): string =
  if path.endsWith(DocSuffix):
    path[0 ..< path.len - DocSuffix.len]
  else:
    path

proc modulePathFor*(pkg: Package, path: string): string =
  ## The logical module path. `relativeModulePath` is the runtime's own rule,
  ## relative to the library root. The one special location is the runtime's
  ## global `gene` namespace: `src/gene/lib/str.doc.gene` is `gene/str`,
  ## because that is the name Gene code imports and the natives register under.
  var file = path
  if file.endsWith(DocSuffix):
    file = file[0 ..< file.len - DocSuffix.len] & SourceSuffix
  if pkg.name == "gene/runtime":
    let srcDir = if pkg.sourceDir.len > 0: pkg.sourceDir else: "src"
    let libRoot = normalizedPath(absolutePath(pkg.root / srcDir / "gene" / "lib"))
    if containsPath(libRoot, file):
      return "gene/" & stripSourceSuffix(
        relativePath(file, libRoot).replace('\\', '/'))
  relativeModulePath(pkg, file)

proc sidecarFor*(sourceFile: string): string =
  stripSourceSuffix(sourceFile) & DocSuffix

proc isSidecar*(path: string): bool = path.endsWith(DocSuffix)

proc corpusItems*(pkg: Package, walkRoot: string): seq[CorpusItem] =
  ## Pair `<mod>.doc.gene` with its `<mod>.gene`; a sidecar without a sibling
  ## stands alone and documents a native namespace.
  var files = pkg.walkGeneFiles(walkRoot)
  var byPath = initTable[string, bool]()
  for file in files:
    byPath[file] = true
  for file in files:
    if file.isSidecar:
      let sibling = stripDocSuffix(file) & SourceSuffix
      if byPath.hasKey(sibling):
        continue
      result.add CorpusItem(modulePath: pkg.modulePathFor(file),
                            sourceFile: "", sidecarFile: file,
                            sourceRel: pkg.relativeToRoot(file))
    else:
      let sidecar = sidecarFor(file)
      result.add CorpusItem(modulePath: pkg.modulePathFor(file),
                            sourceFile: file,
                            sidecarFile: (if fileExists(sidecar): sidecar else: ""),
                            sourceRel: pkg.relativeToRoot(file))
  result.sort(proc (a, b: CorpusItem): int = cmp(a.modulePath, b.modulePath))
