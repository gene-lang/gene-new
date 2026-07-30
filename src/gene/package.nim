## Package discovery, manifests, identity, and local stores
## (docs/proposals/package.md).
##
## This module owns everything that can be decided from the filesystem and a
## `package.gene` manifest alone: the package-name grammar, manifest parsing
## and validation, ancestor discovery, and the two store locations. It knows
## nothing about the VM, so a manifest is *data* here in the strongest sense —
## it is read with `readAll` and never compiled or executed (proposal §6, §13).
##
## Package resolution proper (the two-phase walk over declared dependencies)
## lives in `vm.nim`, because it has to interact with the Application's package
## table and module cache. What that walk consumes is entirely produced here.

import std/[algorithm, os, strutils, tables]
import ./types
import ./reader

const
  ManifestFileName* = "package.gene"
  DefaultSourceDir* = "src"
  DefaultMainModule* = "index"
  DefaultTestDir* = "tests"
  PackageEntryModulePath* = "."
    ## The one module path the resolver rewrites (proposal §10). It resolves to
    ## the selected package's `main_module`; every other module name resolves
    ## literally.
  UserStoreEnvVar* = "GENE_USER_PACKAGES"
    ## Overrides the user store location. `~/.gene/packages` is the normative
    ## spelling; this exists so a test or a sandboxed run can point the user
    ## tier somewhere hermetic without writing to the real home directory.

type
  PackageKind* = enum
    pkAdHoc = "ad_hoc"
    pkRegular = "regular"

  PackageOrigin* = enum
    ## Provenance for diagnostics and `gene pkg locate`. Never part of package
    ## identity (proposal §11).
    poEntry = "entry"
    poApplicationStore = "application_store"
    poUserStore = "user_store"
    poPathDependency = "path_dependency"

  DependencyDecl* = object
    ## One validated `(dep "owner/name" …)` declaration.
    name*: string
    version*: string      ## exact version; meaningful only when `hasVersion`
    hasVersion*: bool
    path*: string         ## `^path`, relative to the declaring package root
    hasPath*: bool

  PackageRequirement* = object
    ## One `(dep name version)` edge, kept as a *requirement* rather than
    ## applied immediately: a version conflict is a property of two
    ## requirements, so no procedure that looks at one import at a time can
    ## detect one (proposal §9).
    requiredBy*: string
    version*: string

  Package* = ref object
    kind*: PackageKind
    name*: string          ## "" for an ad-hoc package
    version*: string
    description*: string
    root*: string          ## normalized absolute directory
    realRoot*: string      ## `root` with symlinks resolved; containment checks
                           ## use this so a symlink cannot escape the package
                           ## boundary unnoticed (proposal §9, §13)
    manifestPath*: string  ## canonical file path; "" for an ad-hoc package
    sourceDir*: string     ## normalized relative path; "" means the root
    mainModule*: string    ## normalized relative module path
    testDir*: string       ## normalized relative path
    dependencies*: seq[DependencyDecl]
    origin*: PackageOrigin

  PackageErrorClass* = enum
    ## The §12 diagnostic classes. Every package/module failure is prefixed
    ## with one of these so a reader can tell at a glance whether to fix a
    ## store, a manifest, or an import.
    pecManifestInvalid = "PACKAGE_MANIFEST_INVALID"
    pecNameInvalid = "PACKAGE_NAME_INVALID"
    pecNotDeclared = "PACKAGE_NOT_DECLARED"
    pecNotFound = "PACKAGE_NOT_FOUND"
    pecIdentityMismatch = "PACKAGE_IDENTITY_MISMATCH"
    pecVersionMismatch = "PACKAGE_VERSION_MISMATCH"
    pecVersionConflict = "PACKAGE_VERSION_CONFLICT"
    pecBoundary = "PACKAGE_BOUNDARY"
    pecDependencyCycle = "PACKAGE_DEPENDENCY_CYCLE"
    pecModuleNotFound = "MODULE_NOT_FOUND"
    pecModuleAmbiguous = "MODULE_AMBIGUOUS"

  PackageError* = object of GeneError
    ## A `GeneError` that also carries its diagnostic class, so tooling can
    ## branch on the class instead of matching message text.
    class*: PackageErrorClass

proc canonicalPath*(path: string): string =
  ## Fully resolve `path`, symlinks included, falling back to the lexical
  ## normalization when it does not exist yet. Used for the boundary checks;
  ## module identities keep the lexical form so a temp directory reached
  ## through a symlinked prefix still prints the way the caller spelled it.
  let lexical = normalizedPath(absolutePath(path))
  try:
    expandFilename(lexical)
  except OSError, IOError:
    lexical

proc raisePackageError*(class: PackageErrorClass, message: string,
                        details: openArray[string] = []) =
  ## Raise `class` with `message` on the first line and each detail indented
  ## beneath it, matching the §12 examples.
  var e: ref PackageError
  new(e)
  e.class = class
  var text = $class & ": " & message
  for detail in details:
    text.add "\n  " & detail
  e.msg = text
  raise e

# ---------------------------------------------------------------------------
# Package names (proposal §6)
# ---------------------------------------------------------------------------
#
# Package names are string *values*, so the repository's registered-name
# convention does not decide their spelling. This grammar does, and it lands on
# the same `snake_case` rule so package names read like every other Gene-facing
# name.

proc isPackageNameSegment(segment: string): bool =
  if segment.len == 0:
    return false
  var hasVisible = false
  for ch in segment:
    case ch
    of 'a' .. 'z', '0' .. '9':
      hasVisible = true
    of '_':
      discard
    else:
      return false
  hasVisible

proc isValidPackageName*(name: string): bool =
  ## `<owner>/<name>`, each segment lowercase `snake_case`, neither `.`, `..`,
  ## nor empty. `.`/`..` and `-` fall out of the segment character set.
  let parts = name.split('/')
  if parts.len != 2:
    return false
  parts[0].isPackageNameSegment and parts[1].isPackageNameSegment

proc validatePackageName*(name: string, context: string) =
  if not name.isValidPackageName:
    raisePackageError(pecNameInvalid,
      "package name must be <owner>/<name> in lowercase snake_case: " &
      (if name.len == 0: "(empty)" else: name),
      [context])

proc packageIdentity*(pkg: Package): string =
  ## The portable half of a module identity (proposal §10). Ad-hoc packages
  ## have no stable name, so they get one reserved spelling per application.
  case pkg.kind
  of pkAdHoc:
    "<ad_hoc:application>"
  of pkRegular:
    if pkg.version.len > 0: pkg.name & "@" & pkg.version
    else: pkg.name

proc describe*(pkg: Package): string =
  ## Short human-facing label used in diagnostics.
  case pkg.kind
  of pkAdHoc: "the ad-hoc application package at " & pkg.root
  of pkRegular: pkg.name

# ---------------------------------------------------------------------------
# Relative path normalization
# ---------------------------------------------------------------------------

proc normalizeRelativePath*(raw, field, manifestPath: string): string =
  ## Normalize a manifest-declared relative path. Absolute paths and paths that
  ## escape the package root are rejected here rather than at use time, so a
  ## bad manifest fails once with a manifest diagnostic.
  if raw.len == 0:
    return ""
  if raw.isAbsolute or (raw.len > 0 and raw[0] == '/'):
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be a relative path: " & raw, [manifestPath])
  var segments: seq[string]
  for segment in raw.replace('\\', '/').split('/'):
    case segment
    of "", ".":
      discard
    of "..":
      if segments.len == 0:
        raisePackageError(pecManifestInvalid,
          "^" & field & " must not escape the package root: " & raw,
          [manifestPath])
      segments.setLen(segments.len - 1)
    else:
      segments.add segment
  segments.join("/")

# ---------------------------------------------------------------------------
# Store locations (proposal §7)
# ---------------------------------------------------------------------------

proc applicationStoreDir*(applicationRoot: string): string =
  applicationRoot / "vendor" / "packages"

proc userStoreDir*(): string =
  ## `~/.gene/packages` is the normative user-visible spelling; the home
  ## directory is expanded here rather than by Gene code.
  let override = getEnv(UserStoreEnvVar)
  if override.len > 0:
    return normalizedPath(absolutePath(override))
  normalizedPath(getHomeDir() / ".gene" / "packages")

proc storeCandidateDir*(store, name: string): string =
  ## `<store>/<owner>/<name>`, constructed directly — the store is never
  ## enumerated, so neither the result nor the cost depends on what else is
  ## installed.
  let parts = name.split('/')
  store / parts[0] / parts[1]

# ---------------------------------------------------------------------------
# Manifest parsing (proposal §6)
# ---------------------------------------------------------------------------

const manifestFields = ["name", "version", "description", "source_dir",
                        "main_module", "test_dir", "dependencies"]

proc manifestString(value: Value, field, manifestPath: string): string =
  if value.kind != vkString:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be a string", [manifestPath])
  value.strVal

proc dependencyHeadText(head: Value): string =
  ## Render a dependency head for diagnostics. `$dep` reads as a node whose
  ## head is `(path gene dep)`, not a symbol, so it needs its own spelling.
  case head.kind
  of vkSymbol:
    head.symVal
  of vkNode:
    if head.head.kind == vkSymbol and head.head.symVal == "path":
      var segments: seq[string]
      for segment in head.body:
        segments.add (if segment.kind == vkSymbol: segment.symVal else: "?")
      "(path " & segments.join(" ") & ")"
    else:
      "(…)"
  else:
    $head.kind

proc parseDependency(form: Value, manifestPath: string): DependencyDecl =
  if form.kind != vkNode:
    raisePackageError(pecManifestInvalid,
      "^dependencies entries must be (dep \"owner/name\" …) forms",
      [manifestPath])
  # Schema validation matches on the literal head symbol `dep`. `$dep` is
  # reader sugar for the `gene/dep` member path, so it never reads as a symbol
  # head at all — a manifest must not appear to name something in the standard
  # library (§6).
  if form.head.kind != vkSymbol or form.head.symVal != "dep":
    raisePackageError(pecManifestInvalid,
      "^dependencies entries must have the literal head `dep`, got " &
      dependencyHeadText(form.head), [manifestPath])
  let body = form.body
  if body.len == 0 or body[0].kind != vkString:
    raisePackageError(pecManifestInvalid,
      "dep requires a package name string", [manifestPath])
  result.name = body[0].strVal
  validatePackageName(result.name, manifestPath)
  if body.len > 2:
    raisePackageError(pecManifestInvalid,
      "dep accepts a name and at most one version: " & result.name,
      [manifestPath])
  if body.len == 2:
    if body[1].kind != vkString:
      raisePackageError(pecManifestInvalid,
        "dep version must be a string: " & result.name, [manifestPath])
    result.version = body[1].strVal
    result.hasVersion = true
    if result.version.len == 0:
      raisePackageError(pecManifestInvalid,
        "dep version must not be empty: " & result.name, [manifestPath])
  for key, value in form.props:
    if key != "path":
      raisePackageError(pecManifestInvalid,
        "dep got unexpected option ^" & key & ": " & result.name,
        [manifestPath])
    if value.kind != vkString or value.strVal.len == 0:
      raisePackageError(pecManifestInvalid,
        "dep ^path must be a non-empty string: " & result.name, [manifestPath])
    result.path = value.strVal
    result.hasPath = true
  # A store dependency must name an exact version, because §7 permits one
  # active version per name per store and there is nothing to choose between.
  # A `^path` declaration may omit it so sibling checkouts can move freely.
  if not result.hasPath and not result.hasVersion:
    raisePackageError(pecManifestInvalid,
      "dep on a stored package requires an exact version: " & result.name,
      [manifestPath])

proc parseManifest*(source, manifestPath, root: string,
                    origin: PackageOrigin): Package =
  ## Read and validate one `package.gene`. The manifest is data: it is read
  ## with `readAll` and never compiled or executed (§6).
  var forms: seq[Value]
  try:
    forms = readAll(source, manifestPath)
  except ReadError as e:
    raisePackageError(pecManifestInvalid, e.msg, [manifestPath])
  if forms.len == 0:
    raisePackageError(pecManifestInvalid,
      "manifest must contain exactly one map datum, found none",
      [manifestPath])
  if forms.len > 1:
    raisePackageError(pecManifestInvalid,
      "manifest must contain exactly one map datum, found " & $forms.len &
      " top-level forms", [manifestPath])
  let manifest = forms[0]
  if manifest.kind != vkMap:
    raisePackageError(pecManifestInvalid,
      "manifest must be a map datum, got " & $manifest.kind, [manifestPath])

  var unknown: seq[string]
  for key in manifest.mapEntries.keys:
    if key notin manifestFields:
      unknown.add key
  if unknown.len > 0:
    unknown.sort()
    var spelled: seq[string]
    for key in unknown:
      spelled.add "^" & key
    raisePackageError(pecManifestInvalid,
      "manifest has unknown field(s): " & spelled.join(", "), [manifestPath])

  result = Package(kind: pkRegular, root: root, realRoot: canonicalPath(root),
                   manifestPath: manifestPath, origin: origin)
  let entries = manifest.mapEntries
  if not entries.hasKey("name"):
    raisePackageError(pecManifestInvalid, "manifest requires ^name",
                      [manifestPath])
  result.name = manifestString(entries["name"], "name", manifestPath)
  validatePackageName(result.name, manifestPath)
  if entries.hasKey("version"):
    result.version = manifestString(entries["version"], "version", manifestPath)
    if result.version.len == 0:
      raisePackageError(pecManifestInvalid, "^version must not be empty",
                        [manifestPath])
  if entries.hasKey("description"):
    result.description = manifestString(entries["description"], "description",
                                        manifestPath)
  result.sourceDir =
    if entries.hasKey("source_dir"):
      normalizeRelativePath(
        manifestString(entries["source_dir"], "source_dir", manifestPath),
        "source_dir", manifestPath)
    else:
      DefaultSourceDir
  result.mainModule =
    if entries.hasKey("main_module"):
      normalizeRelativePath(
        manifestString(entries["main_module"], "main_module", manifestPath),
        "main_module", manifestPath)
    else:
      DefaultMainModule
  if result.mainModule.len == 0:
    raisePackageError(pecManifestInvalid,
      "^main_module must name a module", [manifestPath])
  result.testDir =
    if entries.hasKey("test_dir"):
      normalizeRelativePath(
        manifestString(entries["test_dir"], "test_dir", manifestPath),
        "test_dir", manifestPath)
    else:
      DefaultTestDir
  if entries.hasKey("dependencies"):
    let deps = entries["dependencies"]
    if deps.kind != vkList:
      raisePackageError(pecManifestInvalid, "^dependencies must be a list",
                        [manifestPath])
    var seen: Table[string, bool]
    for item in deps.listItems:
      let dep = parseDependency(item, manifestPath)
      if seen.hasKeyOrPut(dep.name, true):
        raisePackageError(pecManifestInvalid,
          "duplicate dependency name: " & dep.name, [manifestPath])
      result.dependencies.add dep

proc loadPackageAt*(root: string, origin: PackageOrigin): Package =
  ## Read the manifest at `root` and build its Package record. The caller has
  ## already established that `root/package.gene` exists.
  let canonicalRoot = normalizedPath(absolutePath(root))
  let manifestPath = canonicalRoot / ManifestFileName
  var source: string
  try:
    source = readFile(manifestPath)
  except IOError as e:
    raisePackageError(pecManifestInvalid, e.msg, [manifestPath])
  parseManifest(source, manifestPath, canonicalRoot, origin)

# ---------------------------------------------------------------------------
# Discovery (proposal §4)
# ---------------------------------------------------------------------------

proc newAdHocPackage*(root: string): Package =
  ## The synthesized package for a tree with no ancestor manifest (§5). It has
  ## no name, no manifest, and no declared dependency allow-list, but it still
  ## enforces its filesystem boundary and still has an application store.
  let canonicalRoot = normalizedPath(absolutePath(root))
  Package(kind: pkAdHoc, root: canonicalRoot,
          realRoot: canonicalPath(canonicalRoot), sourceDir: "",
          mainModule: "", testDir: DefaultTestDir, origin: poEntry)

proc findManifestDir*(startDir: string): string =
  ## The nearest ancestor of `startDir` (inclusive) holding a `package.gene`,
  ## or "" when there is none. Discovery is based on ancestors — never on
  ## descendants or siblings.
  var dir = normalizedPath(absolutePath(startDir))
  while true:
    if fileExists(dir / ManifestFileName):
      return dir
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      return ""
    dir = parent

proc discoverApplicationPackage*(startDir: string): Package =
  ## Walk from `startDir` toward the filesystem root and stop at the first
  ## `package.gene`; synthesize an ad-hoc package rooted at `startDir` when
  ## there is none. The nearest manifest wins, so a nested package is a real
  ## boundary.
  let manifestDir = findManifestDir(startDir)
  if manifestDir.len == 0:
    newAdHocPackage(startDir)
  else:
    loadPackageAt(manifestDir, poEntry)

# ---------------------------------------------------------------------------
# Containment (proposal §10, §13)
# ---------------------------------------------------------------------------

proc containsPath*(root, path: string): bool =
  ## Both sides must already be canonical. `path == root` counts as inside.
  if path == root:
    return true
  let prefix =
    if root.len > 0 and root[^1] == DirSep: root
    else: root & $DirSep
  path.startsWith(prefix)

proc contains*(pkg: Package, path: string): bool =
  ## Two checks, deliberately: the lexical one rejects `../` traversal without
  ## touching the filesystem, and the resolved one rejects a symlink inside the
  ## package whose target is outside it. Passing only the first is how a
  ## symlink escapes a boundary unnoticed (§13).
  if not containsPath(pkg.root, path):
    return false
  if not (fileExists(path) or dirExists(path)):
    # Nothing to resolve: a path that does not exist has no symlink to follow,
    # and it must still reach "module not found" rather than a boundary error.
    return true
  containsPath(pkg.realRoot, canonicalPath(path))

proc moduleBases*(pkg: Package): seq[string] =
  ## Where module names resolve inside a package (§10): the declared source
  ## directory first, then the root. For an ad-hoc package `source_dir` is the
  ## root, so the two coincide and only one base is searched.
  if pkg.sourceDir.len > 0:
    result.add pkg.root / pkg.sourceDir
  result.add pkg.root

proc relativeModulePath*(pkg: Package, absPath: string): string =
  ## The portable module path for `absPath` inside `pkg`: relative to the
  ## source directory when it lives there, else to the package root. Always
  ## `/`-separated and without the `.gene` extension.
  var base = pkg.root
  if pkg.sourceDir.len > 0:
    let sourceRoot = pkg.root / pkg.sourceDir
    if containsPath(sourceRoot, absPath):
      base = sourceRoot
  var rel = relativePath(absPath, base)
  rel = rel.replace('\\', '/')
  if rel.endsWith(".gene"):
    rel = rel[0 ..< rel.len - 5]
  rel

proc moduleIdentity*(pkg: Package, absPath: string): string =
  ## `<package_identity>::<normalized_module_path>` (§10). The filesystem path
  ## stays available for diagnostics and source loading, but it is provenance,
  ## not portable identity.
  pkg.packageIdentity & "::" & pkg.relativeModulePath(absPath)
