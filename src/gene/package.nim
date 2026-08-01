## Package discovery, manifests, identity, and local stores
## (docs/proposals/package.md).
##
## This deep module owns discovery, the closed manifest and lock schemas,
## source identity, solving, immutable stores, vendoring, and GC roots. It
## knows nothing about the VM: manifests and locks are read with `readAll` as
## inert data and are never compiled or executed. Runtime code receives only a
## pre-materialized alias graph and performs O(1) edge lookup.

import std/[algorithm, os, sequtils, sets, strutils, tables, times, uri]
import std/unicode as unicode
import ./types
import ./reader
import ./digest
import ./printer
import ./process_lock
import ./unicode_package

const
  ManifestFileName* = "package.gene"
  DefaultSourceDir* = "src"
  DefaultMainModule* = "index"
  DefaultTestDir* = "tests"
  ManifestFormat* = 1
  PackageCompilerVersion* = "0.1.0"
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
    poWorkspace = "workspace"
    poRegistrySource = "registry_source"
    poApplicationStore = "application_store"
    poUserStore = "user_store"
    poPathDependency = "path_dependency"

  DependencyScope* = enum
    dsRuntime = "runtime"
    dsDevelopment = "development"
    dsBuild = "build"

  DependencySourceKind* = enum
    dskRegistry = "registry"
    dskGit = "git"
    dskPath = "path"
    dskWorkspace = "workspace"

  LibraryTarget* = object
    entry*: string
    uses*: seq[string]

  ApplicationTarget* = object
    name*: string
    entry*: string
    command*: string
    uses*: seq[string]

  WorkspaceDecl* = object
    members*: seq[string]

  TestTarget* = object
    root*: string

  BuildProfile* = object
    ## Effective build settings. Custom profiles inherit one built-in profile
    ## during manifest validation, so build planning never has to interpret
    ## raw manifest data.
    name*: string
    inherits*: string
    optimization*: string
    debugInfo*: string
    assertions*: bool
    sealing*: string
    lto*: bool

  FileSelection* = object
    includes*: seq[string]
    excludes*: seq[string]
    executables*: seq[string]

  SystemProviderKind* = enum
    spkPkgConfig = "pkg_config"
    spkVcpkg = "vcpkg"
    spkSystemFramework = "system_framework"
    spkPolicyMapping = "policy_mapping"

  SystemLinkage* = enum
    slStatic = "static"
    slDynamic = "dynamic"
    slEither = "either"

  SystemLibraryRequirement* = object
    alias*: string
    name*: string
    version*: string
    providers*: seq[SystemProviderKind]
    linkage*: SystemLinkage
    components*: seq[string]

  DependencyDecl* = object
    ## One alias-keyed, validated `(dep "owner/name" …)` declaration.
    alias*: string
    name*: string
    constraint*: string
    scope*: DependencyScope
    sourceKind*: DependencySourceKind
    registry*: string
    git*: string
    gitSelectorKind*: string
    gitSelector*: string
    path*: string
    features*: seq[string]
    defaultFeatures*: bool
    optional*: bool

  Package* = ref object
    kind*: PackageKind
    format*: int
    name*: string          ## "" for an ad-hoc package
    version*: string
    description*: string
    root*: string          ## normalized absolute directory
    realRoot*: string      ## `root` with symlinks resolved; containment checks
                           ## use this so a symlink cannot escape the package
                           ## boundary unnoticed (proposal §9, §13)
    manifestPath*: string  ## canonical file path; "" for an ad-hoc package
    manifestDigest*: string
    treeDigest*: string
    archiveDigest*: string
    id*: string
    sourceKind*: DependencySourceKind
    sourceName*: string
    sourcePath*: string
    selectedFeatures*: seq[string]
    yanked*: bool
    license*: string
    repository*: string
    singleton*: bool
    workspace*: WorkspaceDecl
    hasWorkspace*: bool
    library*: LibraryTarget
    hasLibrary*: bool
    applications*: seq[ApplicationTarget]
    tests*: TestTarget
    hasTests*: bool
    files*: FileSelection
    features*: Table[string, seq[string]]
    defaultFeatures*: seq[string]
    profiles*: Table[string, BuildProfile]
    buildRecipes*: Value
    systemDependencies*: Table[string, SystemLibraryRequirement]
    sourceDir*: string     ## normalized relative path; "" means the root
    mainModule*: string    ## normalized relative module path
    testDir*: string       ## normalized relative path
    dependencies*: seq[DependencyDecl]
    origin*: PackageOrigin
    dependencyEdges*: Table[string, string] ## alias -> package instance id
    dependencyEdgeScopes*: Table[string, DependencyScope]

  ResolveRequest* = object
    startDir*: string
    activePackageRoot*: string
    includeDevelopment*: bool
    includeBuild*: bool
    userStoreRoot*: string
    unlockAliases*: seq[string]
    unlockAll*: bool
    offline*: bool

  RegistrySnapshot* = object
    name*: string
    url*: string
    indexDigest*: string

  Resolution* = ref object
    workspaceRoot*: string
    rootManifestDigest*: string
    workspaceDigest*: string
    registrySnapshots*: seq[RegistrySnapshot]
    lockDigest*: string
    activePackageId*: string
    rootPackageIds*: seq[string]
    packagesById*: Table[string, Package]

  SyncPolicy* = object
    offline*: bool
    locked*: bool
    userStoreRoot*: string

  MaterializedGraph* = ref object
    workspaceRoot*: string
    lockDigest*: string
    activePackageId*: string
    ## The package whose development dependencies are enabled for this
    ## command. This remains stable while dependency packages are compiled.
    developmentPackageId*: string
    rootPackageIds*: seq[string]
    packagesById*: Table[string, Package]
    includeDevelopment*: bool
    includeBuild*: bool

  VendorRequest* = object
    destination*: string

  VendorReceipt* = object
    root*: string
    packagePaths*: Table[string, string]

  CacheGcResult* = object
    keptObjects*: int
    removedObjects*: int
    removedRootReceipts*: int

  PackageSourceAdapter* = ref object
    name*: string
    root*: string
    url*: string

  GitCheckout* = object
    root*: string
    canonicalUrl*: string
    commit*: string

  GitSourceAdapter* = proc (canonicalUrl, selectorKind, selector: string,
                            offline: bool): GitCheckout {.closure.}

  PackageManager* = ref object
    userStoreRoot*: string
    registries*: seq[PackageSourceAdapter]
    defaultRegistry*: string
    gitSourceAdapter*: GitSourceAdapter

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
    pecStoreBusy = "PACKAGE_STORE_BUSY"

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

type SemVersion* = object
  major*, minor*, patch*: int
  prerelease*: seq[string]
  build*: string
  text*: string

proc parseNumericPart(text, context: string): int =
  if text.len == 0 or (text.len > 1 and text[0] == '0'):
    raisePackageError(pecManifestInvalid,
      "invalid semantic version numeric component: " & text, [context])
  for ch in text:
    if ch notin {'0' .. '9'}:
      raisePackageError(pecManifestInvalid,
        "invalid semantic version numeric component: " & text, [context])
  try:
    result = parseInt(text)
  except ValueError:
    raisePackageError(pecManifestInvalid,
      "semantic version component is out of range: " & text, [context])

proc parseSemVersion*(text, context: string,
                      allowPartial = false): SemVersion =
  if text.len == 0:
    raisePackageError(pecManifestInvalid,
      "semantic version must not be empty", [context])
  result.text = text
  var coreAndPre = text
  let plus = coreAndPre.find('+')
  if plus >= 0:
    result.build = coreAndPre[plus + 1 .. ^1]
    coreAndPre = coreAndPre[0 ..< plus]
    if result.build.len == 0 or '+' in result.build:
      raisePackageError(pecManifestInvalid,
        "semantic version build metadata must not be empty: " & text,
        [context])
    for part in result.build.split('.'):
      if part.len == 0:
        raisePackageError(pecManifestInvalid,
          "semantic version build identifier must not be empty: " & text,
          [context])
      for ch in part:
        if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-'}:
          raisePackageError(pecManifestInvalid,
            "invalid semantic version build identifier: " & part, [context])
  var core = coreAndPre
  let dash = coreAndPre.find('-')
  if dash >= 0:
    core = coreAndPre[0 ..< dash]
    let prerelease = coreAndPre[dash + 1 .. ^1]
    if prerelease.len == 0:
      raisePackageError(pecManifestInvalid,
        "semantic version prerelease must not be empty: " & text, [context])
    result.prerelease = prerelease.split('.')
    for part in result.prerelease:
      if part.len == 0:
        raisePackageError(pecManifestInvalid,
          "semantic version prerelease identifier must not be empty: " & text,
          [context])
      for ch in part:
        if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-'}:
          raisePackageError(pecManifestInvalid,
            "invalid semantic version prerelease identifier: " & part,
            [context])
      if part.len > 1 and part[0] == '0' and part.allCharsInSet({'0' .. '9'}):
        raisePackageError(pecManifestInvalid,
          "numeric prerelease identifiers cannot have leading zeroes: " & part,
          [context])
  let parts = core.split('.')
  if parts.len < (if allowPartial: 1 else: 3) or parts.len > 3:
    raisePackageError(pecManifestInvalid,
      "semantic version must have " &
      (if allowPartial: "one to three" else: "three") &
      " numeric components: " & text, [context])
  result.major = parseNumericPart(parts[0], context)
  if parts.len > 1:
    result.minor = parseNumericPart(parts[1], context)
  if parts.len > 2:
    result.patch = parseNumericPart(parts[2], context)

proc compareIdentifier(a, b: string): int =
  let aNumeric = a.allCharsInSet({'0' .. '9'})
  let bNumeric = b.allCharsInSet({'0' .. '9'})
  if aNumeric and bNumeric:
    result = cmp(a.len, b.len)
    if result == 0:
      result = cmp(a, b)
  elif aNumeric:
    result = -1
  elif bNumeric:
    result = 1
  else:
    result = cmp(a, b)

proc cmpSemVersion*(a, b: SemVersion): int =
  result = cmp(a.major, b.major)
  if result == 0: result = cmp(a.minor, b.minor)
  if result == 0: result = cmp(a.patch, b.patch)
  if result != 0:
    return
  if a.prerelease.len == 0 and b.prerelease.len == 0:
    return 0
  if a.prerelease.len == 0:
    return 1
  if b.prerelease.len == 0:
    return -1
  for i in 0 ..< min(a.prerelease.len, b.prerelease.len):
    result = compareIdentifier(a.prerelease[i], b.prerelease[i])
    if result != 0:
      return
  result = cmp(a.prerelease.len, b.prerelease.len)

proc coreEquals(a, b: SemVersion): bool =
  a.major == b.major and a.minor == b.minor and a.patch == b.patch

proc matchesConstraint*(versionText, constraint, context: string): bool =
  let candidate = parseSemVersion(versionText, context)
  if constraint == "*":
    return candidate.prerelease.len == 0
  let tokens = strutils.splitWhitespace(constraint)
  if tokens.len == 0:
    raisePackageError(pecManifestInvalid,
      "version constraint must not be empty", [context])
  var admitsPrerelease = candidate.prerelease.len == 0
  for token in tokens:
    var op = "="
    var versionPart = token
    for prefix in [">=", "<=", ">", "<", "=", "^", "~"]:
      if token.startsWith(prefix):
        op = prefix
        versionPart = token[prefix.len .. ^1]
        break
    if versionPart.len == 0:
      raisePackageError(pecManifestInvalid,
        "invalid version comparator: " & token, [context])
    let required = parseSemVersion(versionPart, context, allowPartial = true)
    if required.prerelease.len > 0 and candidate.coreEquals(required):
      admitsPrerelease = true
    let compared = cmpSemVersion(candidate, required)
    case op
    of "=": result = compared == 0
    of ">=": result = compared >= 0
    of "<=": result = compared <= 0
    of ">": result = compared > 0
    of "<": result = compared < 0
    of "^":
      var upper: SemVersion
      if required.major > 0:
        upper.major = required.major + 1
      elif required.minor > 0:
        upper.minor = required.minor + 1
      else:
        upper.patch = required.patch + 1
      result = compared >= 0 and cmpSemVersion(candidate, upper) < 0
    of "~":
      var upper: SemVersion
      if versionPart.count('.') == 0:
        upper.major = required.major + 1
      else:
        upper.major = required.major
        upper.minor = required.minor + 1
      result = compared >= 0 and cmpSemVersion(candidate, upper) < 0
    else:
      raisePackageError(pecManifestInvalid,
        "unsupported version comparator: " & op, [context])
    if not result:
      return false
  result = admitsPrerelease

proc packageIdentity*(pkg: Package): string =
  ## The portable half of a module identity (proposal §10). Ad-hoc packages
  ## have no stable name, so they get one reserved spelling per application.
  case pkg.kind
  of pkAdHoc:
    "<ad_hoc:application>"
  of pkRegular:
    if pkg.id.len > 0: pkg.id
    elif pkg.version.len > 0: pkg.name & "@" & pkg.version
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
  ## Validate a canonical manifest path. Format 1 paths already use `/` and
  ## never contain empty, `.` or `..` segments; silently normalizing those
  ## spellings would give distinct manifests one filesystem meaning.
  if raw.len == 0:
    return ""
  if unicode.validateUtf8(raw) >= 0 or unicodeNfc151(raw) != raw:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be valid Unicode 15.1 NFC: " & raw,
      [manifestPath])
  if raw.isAbsolute or raw[0] == '/' or '\\' in raw:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be a canonical `/`-separated relative path: " &
      raw, [manifestPath])
  var segments: seq[string]
  for segment in raw.split('/'):
    if segment in ["", ".", ".."]:
      raisePackageError(pecManifestInvalid,
        "^" & field & " contains a non-canonical path segment: " & raw,
        [manifestPath])
    segments.add segment
  segments.join("/")

proc normalizeDependencyPath(raw, field, manifestPath: string): string =
  ## Dependency locators may walk to a sibling of the declaring package, but
  ## must still have one canonical lexical spelling. Only a leading run of
  ## `..` segments is allowed; `a/../b` would be a second spelling of `b`.
  if raw.len == 0 or raw.isAbsolute or raw[0] == '/' or '\\' in raw:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be a canonical `/`-separated relative locator: " &
      raw, [manifestPath])
  if unicode.validateUtf8(raw) >= 0 or unicodeNfc151(raw) != raw:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be valid Unicode 15.1 NFC: " & raw,
      [manifestPath])
  var leftParentPrefix = false
  for segment in raw.split('/'):
    if segment in ["", "."]:
      raisePackageError(pecManifestInvalid,
        "^" & field & " contains a non-canonical path segment: " & raw,
        [manifestPath])
    if segment == "..":
      if leftParentPrefix:
        raisePackageError(pecManifestInvalid,
          "^" & field & " contains a non-leading `..` segment: " & raw,
          [manifestPath])
    else:
      leftParentPrefix = true
  raw

proc containsPath*(root, path: string): bool
proc globMatches(pattern, path: string): bool
proc canonicalPackageUrl*(raw, context: string): string

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

# ---------------------------------------------------------------------------
# Manifest parsing (proposal §6)
# ---------------------------------------------------------------------------

const manifestFields = ["format", "name", "version", "description", "license",
                        "repository", "workspace", "library", "applications",
                        "dependencies", "dev_dependencies",
                        "build_dependencies", "features", "default_features",
                        "singleton", "tests", "files", "profiles", "build",
                        "system_dependencies"]

proc localNameIsValid(name: string): bool =
  if name.len == 0:
    return false
  var visible = false
  for ch in name:
    case ch
    of 'a' .. 'z', '0' .. '9': visible = true
    of '_': discard
    else: return false
  visible

proc validateLocalName(name, kind, manifestPath: string) =
  if not localNameIsValid(name):
    raisePackageError(pecManifestInvalid,
      kind & " must use lowercase snake_case: " & name, [manifestPath])

proc rejectUnknown(entries: PropTable, allowed: openArray[string],
                   context, manifestPath: string) =
  var unknown: seq[string]
  for key in entries.keys:
    if key notin allowed:
      unknown.add key
  if unknown.len > 0:
    unknown.sort()
    for key in unknown.mitems:
      key = "^" & key
    raisePackageError(pecManifestInvalid,
      context & " has unknown field(s): " & unknown.join(", "),
      [manifestPath])

proc manifestString(value: Value, field, manifestPath: string): string =
  if value.kind != vkString:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be a string", [manifestPath])
  value.strVal

proc manifestBool(value: Value, field, manifestPath: string): bool =
  if value.kind != vkBool:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be a boolean", [manifestPath])
  value.boolVal

proc manifestName(value: Value, field, manifestPath: string): string =
  case value.kind
  of vkSymbol: result = value.symVal
  of vkString: result = value.strVal
  else:
    raisePackageError(pecManifestInvalid,
      "^" & field & " entries must be names", [manifestPath])
  validateLocalName(result, field, manifestPath)

proc manifestNames(value: Value, field, manifestPath: string): seq[string] =
  if value.kind != vkList:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be a list", [manifestPath])
  for item in value.listItems:
    result.add manifestName(item, field, manifestPath)

proc manifestStrings(value: Value, field, manifestPath: string): seq[string] =
  if value.kind != vkList:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be a list", [manifestPath])
  for item in value.listItems:
    result.add manifestString(item, field, manifestPath)

proc builtinBuildProfile*(name: string): BuildProfile =
  case name
  of "dev":
    result = BuildProfile(name: name, inherits: name, optimization: "none",
                          debugInfo: "full", assertions: true,
                          sealing: "open", lto: false)
  of "test":
    result = BuildProfile(name: name, inherits: name, optimization: "none",
                          debugInfo: "full", assertions: true,
                          sealing: "open", lto: false)
  of "release":
    result = BuildProfile(name: name, inherits: name, optimization: "speed",
                          debugInfo: "min", assertions: false,
                          sealing: "sealed", lto: true)
  else:
    raisePackageError(pecManifestInvalid,
      "unknown built-in build profile: " & name)

proc parseProfile(name: string, value: Value,
                  manifestPath: string): BuildProfile =
  validateLocalName(name, "profile name", manifestPath)
  if name in ["dev", "test", "release"]:
    raisePackageError(pecManifestInvalid,
      "custom profile cannot replace built-in profile: " & name,
      [manifestPath])
  if value.kind != vkNode or value.head.kind != vkSymbol or
      value.head.symVal != "profile" or value.body.len != 0:
    raisePackageError(pecManifestInvalid,
      "profile " & name & " must be a (profile ...) node", [manifestPath])
  rejectUnknown(value.props,
    ["inherits", "optimization", "debug_info", "assertions", "sealing",
     "lto"], "profile " & name, manifestPath)
  if not value.props.hasKey("inherits"):
    raisePackageError(pecManifestInvalid,
      "profile " & name & " requires ^inherits", [manifestPath])
  let inherited = manifestName(value.props["inherits"], "inherits",
                               manifestPath)
  if inherited notin ["dev", "test", "release"]:
    raisePackageError(pecManifestInvalid,
      "profile " & name & " must inherit dev, test, or release",
      [manifestPath])
  result = builtinBuildProfile(inherited)
  result.name = name
  result.inherits = inherited
  if value.props.hasKey("optimization"):
    result.optimization = manifestName(value.props["optimization"],
                                       "optimization", manifestPath)
    if result.optimization notin ["none", "speed", "size"]:
      raisePackageError(pecManifestInvalid,
        "profile optimization must be none, speed, or size", [manifestPath])
  if value.props.hasKey("debug_info"):
    result.debugInfo = manifestName(value.props["debug_info"], "debug_info",
                                    manifestPath)
    if result.debugInfo notin ["full", "min", "none"]:
      raisePackageError(pecManifestInvalid,
        "profile debug_info must be full, min, or none", [manifestPath])
  if value.props.hasKey("assertions"):
    result.assertions = manifestBool(value.props["assertions"], "assertions",
                                     manifestPath)
  if value.props.hasKey("sealing"):
    result.sealing = manifestName(value.props["sealing"], "sealing",
                                  manifestPath)
    if result.sealing notin ["open", "sealed"]:
      raisePackageError(pecManifestInvalid,
        "profile sealing must be open or sealed", [manifestPath])
  if value.props.hasKey("lto"):
    result.lto = manifestBool(value.props["lto"], "lto", manifestPath)

proc buildProfile*(pkg: Package, name: string): BuildProfile =
  if name in ["dev", "test", "release"]:
    return builtinBuildProfile(name)
  if pkg.profiles.hasKey(name):
    return pkg.profiles[name]
  raisePackageError(pecManifestInvalid, "unknown build profile: " & name,
                    [pkg.manifestPath])

proc appendU64(bytes: var string, value: uint64) =
  for shift in countdown(56, 0, 8):
    bytes.add char((value shr shift) and 0xff'u64)

proc canonicalValueBytes(value: Value): string

proc canonicalPropsBytes(entries: PropTable): string =
  var pairs: seq[tuple[key, value: string]]
  for key, value in entries:
    var keyBytes = "\x05"
    keyBytes.appendU64(uint64(key.len))
    keyBytes.add key
    pairs.add (keyBytes, canonicalValueBytes(value))
  pairs.sort(proc (a, b: tuple[key, value: string]): int = cmp(a.key, b.key))
  result.add '\x07'
  result.appendU64(uint64(pairs.len))
  for pair in pairs:
    result.add pair.key
    result.add pair.value

proc canonicalValueBytes(value: Value): string =
  case value.kind
  of vkNil:
    result.add '\x00'
  of vkBool:
    result.add(if value.boolVal: '\x02' else: '\x01')
  of vkInt:
    let text = $value.intVal
    result.add '\x03'
    result.appendU64(uint64(text.len))
    result.add text
  of vkString:
    result.add '\x04'
    result.appendU64(uint64(value.strVal.len))
    result.add value.strVal
  of vkSymbol:
    result.add '\x05'
    result.appendU64(uint64(value.symVal.len))
    result.add value.symVal
  of vkList:
    result.add '\x06'
    result.appendU64(uint64(value.listItems.len))
    for item in value.listItems:
      result.add canonicalValueBytes(item)
  of vkMap:
    result = canonicalPropsBytes(value.mapEntries)
  of vkNode:
    result.add '\x08'
    result.add canonicalValueBytes(value.head)
    result.add canonicalPropsBytes(value.props)
    result.appendU64(uint64(value.body.len))
    for item in value.body:
      result.add canonicalValueBytes(item)
  else:
    raisePackageError(pecManifestInvalid,
      "package data contains a non-canonical value kind: " & $value.kind)

proc canonicalGeneData*(value: Value): string =
  "gene-data-v1\0" & canonicalValueBytes(value)

proc canonicalDigest*(value: Value): string =
  "sha256:" & sha256Hex(canonicalGeneData(value))

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

proc parseDependency(alias: string, form: Value, scope: DependencyScope,
                     manifestPath: string): DependencyDecl =
  validateLocalName(alias, "dependency alias", manifestPath)
  if alias == "self":
    raisePackageError(pecManifestInvalid,
      "dependency alias `self` is reserved", [manifestPath])
  if form.kind != vkNode:
    raisePackageError(pecManifestInvalid,
      "dependency values must be (dep \"owner/name\" …) forms",
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
  result.alias = alias
  result.name = body[0].strVal
  result.scope = scope
  result.sourceKind = dskRegistry
  result.defaultFeatures = true
  validatePackageName(result.name, manifestPath)
  if body.len > 2:
    raisePackageError(pecManifestInvalid,
      "dep accepts a name and at most one version: " & result.name,
      [manifestPath])
  if body.len == 2:
    if body[1].kind != vkString:
      raisePackageError(pecManifestInvalid,
        "dep version must be a string: " & result.name, [manifestPath])
    result.constraint = body[1].strVal
    if result.constraint.len == 0:
      raisePackageError(pecManifestInvalid,
        "dep constraint must not be empty: " & result.name, [manifestPath])
    discard matchesConstraint("0.0.0", result.constraint, manifestPath)
  var sourceCount = 0
  for key, value in form.props:
    case key
    of "registry":
      result.registry = manifestString(value, "registry", manifestPath)
      validateLocalName(result.registry, "registry name", manifestPath)
      inc sourceCount
    of "git":
      result.git = canonicalPackageUrl(
        manifestString(value, "git", manifestPath), manifestPath)
      if parseUri(result.git).path == "/":
        raisePackageError(pecManifestInvalid,
          "git source URL must name a repository path", [manifestPath])
      result.sourceKind = dskGit
      inc sourceCount
    of "commit", "tag", "branch":
      if result.gitSelectorKind.len > 0:
        raisePackageError(pecManifestInvalid,
          "git dependency accepts exactly one of ^commit, ^tag, or ^branch: " &
          result.name, [manifestPath])
      result.gitSelectorKind = key
      result.gitSelector = manifestString(value, key, manifestPath)
      if result.gitSelector.len == 0:
        raisePackageError(pecManifestInvalid,
          "git selector must not be empty: " & result.name, [manifestPath])
    of "path":
      result.path = normalizeDependencyPath(
        manifestString(value, "path", manifestPath), "path", manifestPath)
      result.sourceKind = dskPath
      inc sourceCount
    of "workspace":
      if not manifestBool(value, "workspace", manifestPath):
        raisePackageError(pecManifestInvalid,
          "dep ^workspace accepts only true: " & result.name,
          [manifestPath])
      result.sourceKind = dskWorkspace
      inc sourceCount
    of "features":
      result.features = manifestNames(value, "features", manifestPath)
    of "default_features":
      result.defaultFeatures = manifestBool(value, "default_features",
                                            manifestPath)
    of "optional":
      result.optional = manifestBool(value, "optional", manifestPath)
    else:
      raisePackageError(pecManifestInvalid,
        "dep got unexpected option ^" & key & ": " & result.name,
        [manifestPath])
  if sourceCount > 1:
    raisePackageError(pecManifestInvalid,
      "dep selects more than one source: " & result.name, [manifestPath])
  if result.sourceKind == dskGit and result.gitSelectorKind.len == 0:
    raisePackageError(pecManifestInvalid,
      "git dependency requires exactly one of ^commit, ^tag, or ^branch: " &
      result.name, [manifestPath])
  if result.sourceKind != dskGit and result.gitSelectorKind.len > 0:
    raisePackageError(pecManifestInvalid,
      "^" & result.gitSelectorKind & " requires ^git: " & result.name,
      [manifestPath])
  if result.sourceKind in {dskRegistry, dskWorkspace} and
      result.constraint.len == 0:
    raisePackageError(pecManifestInvalid,
      "registry and workspace dependencies require a version constraint: " &
      result.name, [manifestPath])
  if result.optional and scope != dsRuntime:
    raisePackageError(pecManifestInvalid,
      "optional dependencies are allowed only in ^dependencies: " & alias,
      [manifestPath])

proc parseDependencyMap(value: Value, scope: DependencyScope,
                        manifestPath: string): seq[DependencyDecl] =
  if value.kind != vkMap:
    raisePackageError(pecManifestInvalid,
      "dependency section must be a map", [manifestPath])
  var aliases: seq[string]
  for alias in value.mapEntries.keys:
    aliases.add alias
  aliases.sort()
  for alias in aliases:
    result.add parseDependency(alias, value.mapEntries[alias], scope,
                               manifestPath)

proc parseLibrary(value: Value, manifestPath: string): LibraryTarget =
  if value.kind != vkMap:
    raisePackageError(pecManifestInvalid,
      "^library must be a map", [manifestPath])
  let entries = value.mapEntries
  rejectUnknown(entries, ["entry", "uses"], "^library", manifestPath)
  if not entries.hasKey("entry"):
    raisePackageError(pecManifestInvalid, "^library requires ^entry",
                      [manifestPath])
  result.entry = normalizeRelativePath(
    manifestString(entries["entry"], "entry", manifestPath), "entry",
    manifestPath)
  if result.entry.len == 0:
    raisePackageError(pecManifestInvalid, "^library ^entry must name a file",
                      [manifestPath])
  if entries.hasKey("uses"):
    result.uses = manifestNames(entries["uses"], "uses", manifestPath)

proc parseApplication(value: Value,
                      manifestPath: string): ApplicationTarget =
  if value.kind != vkNode or value.head.kind != vkSymbol or
      value.head.symVal != "application":
    raisePackageError(pecManifestInvalid,
      "^applications entries must be (application <name> ...)",
      [manifestPath])
  if value.body.len != 1:
    raisePackageError(pecManifestInvalid,
      "application requires exactly one target name", [manifestPath])
  result.name = manifestName(value.body[0], "application name", manifestPath)
  rejectUnknown(value.props, ["entry", "command", "uses"], "application",
                manifestPath)
  if not value.props.hasKey("entry"):
    raisePackageError(pecManifestInvalid,
      "application " & result.name & " requires ^entry", [manifestPath])
  result.entry = normalizeRelativePath(
    manifestString(value.props["entry"], "entry", manifestPath), "entry",
    manifestPath)
  if result.entry.len == 0:
    raisePackageError(pecManifestInvalid,
      "application ^entry must name a file: " & result.name, [manifestPath])
  result.command = result.name
  if value.props.hasKey("command"):
    result.command = manifestName(value.props["command"], "command",
                                  manifestPath)
  if value.props.hasKey("uses"):
    result.uses = manifestNames(value.props["uses"], "uses", manifestPath)

proc readPackageData(source, path: string): seq[Value] =
  try:
    result = readAll(source, path,
                     ReadOptions(rejectDuplicateProps: true))
  except ReadError as error:
    raisePackageError(pecManifestInvalid, error.msg, [path])

proc parseWorkspace(value: Value, manifestPath: string): WorkspaceDecl =
  if value.kind != vkMap:
    raisePackageError(pecManifestInvalid,
      "^workspace must be a map", [manifestPath])
  let entries = value.mapEntries
  rejectUnknown(entries, ["members"], "^workspace", manifestPath)
  if not entries.hasKey("members"):
    raisePackageError(pecManifestInvalid,
      "^workspace requires ^members", [manifestPath])
  result.members = manifestStrings(entries["members"], "members", manifestPath)
  if result.members.len == 0:
    raisePackageError(pecManifestInvalid,
      "^workspace ^members must not be empty", [manifestPath])
  for pattern in result.members.mitems:
    pattern = normalizeRelativePath(pattern, "workspace.members", manifestPath)
    if pattern.len == 0:
      raisePackageError(pecManifestInvalid,
        "workspace member pattern must not be empty", [manifestPath])

proc parseManifest*(source, manifestPath, root: string,
                    origin: PackageOrigin): Package =
  ## Read and validate one `package.gene`. The manifest is data: it is read
  ## with `readAll` and never compiled or executed (§6).
  var forms: seq[Value]
  try:
    forms = readPackageData(source, manifestPath)
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

  rejectUnknown(manifest.mapEntries, manifestFields, "manifest", manifestPath)

  result = Package(kind: pkRegular, root: root, realRoot: canonicalPath(root),
                   manifestPath: manifestPath, origin: origin,
                   buildRecipes: NIL)
  let entries = manifest.mapEntries
  if not entries.hasKey("format"):
    raisePackageError(pecManifestInvalid,
      "manifest requires ^format 1", [manifestPath])
  if entries["format"].kind != vkInt or entries["format"].intVal != 1:
    raisePackageError(pecManifestInvalid,
      "unsupported package manifest format; expected ^format 1",
      [manifestPath])
  result.format = ManifestFormat
  if not entries.hasKey("name"):
    raisePackageError(pecManifestInvalid, "manifest requires ^name",
                      [manifestPath])
  result.name = manifestString(entries["name"], "name", manifestPath)
  validatePackageName(result.name, manifestPath)
  if not entries.hasKey("version"):
    raisePackageError(pecManifestInvalid, "manifest requires ^version",
                      [manifestPath])
  result.version = manifestString(entries["version"], "version", manifestPath)
  if result.version.len == 0:
    raisePackageError(pecManifestInvalid, "^version must not be empty",
                      [manifestPath])
  discard parseSemVersion(result.version, manifestPath)
  if entries.hasKey("description"):
    result.description = manifestString(entries["description"], "description",
                                        manifestPath)
  if entries.hasKey("license"):
    result.license = manifestString(entries["license"], "license", manifestPath)
  if entries.hasKey("repository"):
    result.repository = manifestString(entries["repository"], "repository",
                                       manifestPath)
  if entries.hasKey("singleton"):
    result.singleton = manifestBool(entries["singleton"], "singleton",
                                    manifestPath)
  if entries.hasKey("workspace"):
    result.workspace = parseWorkspace(entries["workspace"], manifestPath)
    result.hasWorkspace = true
  if entries.hasKey("library"):
    result.library = parseLibrary(entries["library"], manifestPath)
    result.hasLibrary = true
    let parent = parentDir(result.library.entry).replace('\\', '/')
    result.sourceDir = if parent == ".": "" else: parent
    var modulePath = relativePath(result.library.entry,
      if result.sourceDir.len > 0: result.sourceDir else: ".").replace('\\', '/')
    if modulePath.endsWith(".gene"):
      modulePath.setLen(modulePath.len - 5)
    result.mainModule = modulePath
  else:
    result.sourceDir = ""
    result.mainModule = ""
  if entries.hasKey("applications"):
    if entries["applications"].kind != vkList:
      raisePackageError(pecManifestInvalid,
        "^applications must be a list", [manifestPath])
    var targets = initHashSet[string]()
    var commands = initHashSet[string]()
    for value in entries["applications"].listItems:
      let target = parseApplication(value, manifestPath)
      if target.name in targets:
        raisePackageError(pecManifestInvalid,
          "duplicate application target: " & target.name, [manifestPath])
      if target.command in commands:
        raisePackageError(pecManifestInvalid,
          "duplicate application command: " & target.command, [manifestPath])
      targets.incl target.name
      commands.incl target.command
      result.applications.add target
  var seenAliases = initHashSet[string]()
  for (field, scope) in [("dependencies", dsRuntime),
                         ("dev_dependencies", dsDevelopment),
                         ("build_dependencies", dsBuild)]:
    if entries.hasKey(field):
      for dep in parseDependencyMap(entries[field], scope, manifestPath):
        if dep.alias in seenAliases:
          raisePackageError(pecManifestInvalid,
            "dependency alias appears in more than one scope: " & dep.alias,
            [manifestPath])
        seenAliases.incl dep.alias
        result.dependencies.add dep
  if entries.hasKey("features"):
    if entries["features"].kind != vkMap:
      raisePackageError(pecManifestInvalid,
        "^features must be a map", [manifestPath])
    for name, value in entries["features"].mapEntries:
      validateLocalName(name, "feature name", manifestPath)
      result.features[name] = manifestStrings(value, "features", manifestPath)
  if entries.hasKey("default_features"):
    result.defaultFeatures = manifestNames(entries["default_features"],
                                           "default_features", manifestPath)
  var depsByAlias = initTable[string, DependencyDecl]()
  for dep in result.dependencies:
    depsByAlias[dep.alias] = dep
  var optionalReferences = initHashSet[string]()
  for feature in result.defaultFeatures:
    if not result.features.hasKey(feature):
      raisePackageError(pecManifestInvalid,
        "^default_features names unknown feature: " & feature, [manifestPath])
  for feature, activations in result.features:
    for activation in activations:
      if activation.startsWith("feature:"):
        let target = activation[8 .. ^1]
        validateLocalName(target, "feature reference", manifestPath)
        if not result.features.hasKey(target):
          raisePackageError(pecManifestInvalid,
            "feature " & feature & " names unknown feature: " & target,
            [manifestPath])
      elif activation.startsWith("dep:"):
        let coordinate = activation[4 .. ^1]
        let slash = coordinate.find('/')
        let alias = if slash < 0: coordinate else: coordinate[0 ..< slash]
        validateLocalName(alias, "dependency feature alias", manifestPath)
        if not depsByAlias.hasKey(alias):
          raisePackageError(pecManifestInvalid,
            "feature " & feature & " names unknown dependency alias: " & alias,
            [manifestPath])
        if slash < 0:
          if not depsByAlias[alias].optional:
            raisePackageError(pecManifestInvalid,
              "dep:" & alias & " activation requires an optional dependency",
              [manifestPath])
          optionalReferences.incl alias
        else:
          let targetFeature = coordinate[slash + 1 .. ^1]
          validateLocalName(targetFeature, "dependency feature", manifestPath)
      else:
        raisePackageError(pecManifestInvalid,
          "feature activation must start with feature: or dep:: " & activation,
          [manifestPath])
  for dep in result.dependencies:
    if dep.optional and dep.alias notin optionalReferences:
      raisePackageError(pecManifestInvalid,
        "optional dependency is not enabled by any feature: " & dep.alias,
        [manifestPath])
  result.testDir = DefaultTestDir
  if entries.hasKey("tests"):
    if entries["tests"].kind != vkMap:
      raisePackageError(pecManifestInvalid, "^tests must be a map",
                        [manifestPath])
    rejectUnknown(entries["tests"].mapEntries, ["root"], "^tests",
                  manifestPath)
    if not entries["tests"].mapEntries.hasKey("root"):
      raisePackageError(pecManifestInvalid, "^tests requires ^root",
                        [manifestPath])
    result.tests.root = normalizeRelativePath(
      manifestString(entries["tests"].mapEntries["root"], "root", manifestPath),
      "tests.root", manifestPath)
    result.testDir = result.tests.root
    result.hasTests = true
  result.files.includes = @["**/*"]
  if entries.hasKey("files"):
    if entries["files"].kind != vkMap:
      raisePackageError(pecManifestInvalid, "^files must be a map",
                        [manifestPath])
    let fileEntries = entries["files"].mapEntries
    rejectUnknown(fileEntries, ["include", "exclude", "executable"], "^files",
                  manifestPath)
    if fileEntries.hasKey("include"):
      result.files.includes = manifestStrings(fileEntries["include"], "include",
                                              manifestPath)
    if fileEntries.hasKey("exclude"):
      result.files.excludes = manifestStrings(fileEntries["exclude"], "exclude",
                                              manifestPath)
    if fileEntries.hasKey("executable"):
      result.files.executables = manifestStrings(fileEntries["executable"],
                                                 "executable", manifestPath)
  for pattern in result.files.includes.mitems:
    pattern = normalizeRelativePath(pattern, "files.include", manifestPath)
  for pattern in result.files.excludes.mitems:
    pattern = normalizeRelativePath(pattern, "files.exclude", manifestPath)
  for pattern in result.files.executables.mitems:
    pattern = normalizeRelativePath(pattern, "files.executable", manifestPath)
  var requiredFiles = @[ManifestFileName]
  if result.hasLibrary:
    requiredFiles.add result.library.entry
  for application in result.applications:
    requiredFiles.add application.entry
  for path in requiredFiles:
    var selected = false
    for pattern in result.files.includes:
      if globMatches(pattern, path):
        selected = true
        break
    for pattern in result.files.excludes:
      if globMatches(pattern, path):
        selected = false
    if not selected:
      raisePackageError(pecManifestInvalid,
        "^files excludes required package file: " & path, [manifestPath])
    let absolute = normalizedPath(absolutePath(path, root))
    if (fileExists(absolute) or dirExists(absolute)) and
        not containsPath(canonicalPath(root), canonicalPath(absolute)):
      raisePackageError(pecBoundary,
        "declared package path escapes through a symlink: " & path,
        [manifestPath])
  if entries.hasKey("profiles"):
    if entries["profiles"].kind != vkMap:
      raisePackageError(pecManifestInvalid, "^profiles must be a map",
                        [manifestPath])
    var profileNames: seq[string]
    for name in entries["profiles"].mapEntries.keys:
      profileNames.add name
    profileNames.sort()
    for name in profileNames:
      result.profiles[name] = parseProfile(
        name, entries["profiles"].mapEntries[name], manifestPath)
  if entries.hasKey("build"):
    if entries["build"].kind != vkList:
      raisePackageError(pecManifestInvalid, "^build must be a list",
                        [manifestPath])
    result.buildRecipes = entries["build"]
  if entries.hasKey("system_dependencies"):
    if entries["system_dependencies"].kind != vkMap:
      raisePackageError(pecManifestInvalid,
        "^system_dependencies must be a map", [manifestPath])
    let systemEntries = entries["system_dependencies"].mapEntries
    var aliases: seq[string]
    for alias in systemEntries.keys:
      aliases.add alias
    aliases.sort()
    for alias in aliases:
      validateLocalName(alias, "system dependency alias", manifestPath)
      let value = systemEntries[alias]
      if value.kind != vkNode or value.head.kind != vkSymbol or
          value.head.symVal != "system_library":
        raisePackageError(pecManifestInvalid,
          "system dependency must be a (system_library ...) node: " & alias,
          [manifestPath])
      if value.body.len != 0:
        raisePackageError(pecManifestInvalid,
          "system_library has no positional values: " & alias, [manifestPath])
      rejectUnknown(value.props,
        ["name", "version", "providers", "linkage", "components"],
        "system_library", manifestPath)
      for field in ["name", "version"]:
        if not value.props.hasKey(field):
          raisePackageError(pecManifestInvalid,
            "system_library requires ^" & field & ": " & alias,
            [manifestPath])
      var requirement = SystemLibraryRequirement(
        alias: alias,
        name: manifestString(value.props["name"], "name", manifestPath),
        version: manifestString(value.props["version"], "version", manifestPath),
        linkage: slEither)
      discard matchesConstraint("0.0.0", requirement.version, manifestPath)
      if value.props.hasKey("providers"):
        if value.props["providers"].kind != vkList:
          raisePackageError(pecManifestInvalid,
            "system_library ^providers must be a list", [manifestPath])
        for provider in value.props["providers"].listItems:
          if provider.kind != vkSymbol:
            raisePackageError(pecManifestInvalid,
              "system_library providers must be symbols", [manifestPath])
          var parsed: SystemProviderKind
          case provider.symVal
          of "pkg_config": parsed = spkPkgConfig
          of "vcpkg": parsed = spkVcpkg
          of "system_framework": parsed = spkSystemFramework
          of "policy_mapping": parsed = spkPolicyMapping
          else:
            raisePackageError(pecManifestInvalid,
              "unknown system library provider: " & provider.symVal,
              [manifestPath])
          if parsed in requirement.providers:
            raisePackageError(pecManifestInvalid,
              "duplicate system library provider: " & provider.symVal,
              [manifestPath])
          requirement.providers.add parsed
      if value.props.hasKey("linkage"):
        if value.props["linkage"].kind != vkSymbol:
          raisePackageError(pecManifestInvalid,
            "system_library ^linkage must be a symbol", [manifestPath])
        case value.props["linkage"].symVal
        of "static": requirement.linkage = slStatic
        of "dynamic": requirement.linkage = slDynamic
        of "either": requirement.linkage = slEither
        else:
          raisePackageError(pecManifestInvalid,
            "system_library linkage must be static, dynamic, or either",
            [manifestPath])
      if value.props.hasKey("components"):
        requirement.components = manifestStrings(value.props["components"],
                                                 "components", manifestPath)
      result.systemDependencies[alias] = requirement
  result.manifestDigest = canonicalDigest(manifest)

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
          mainModule: "", testDir: DefaultTestDir, origin: poEntry,
          id: "ad_hoc:" & sha256Hex(canonicalRoot), buildRecipes: NIL)

proc singlePackageGraph*(pkg: Package): MaterializedGraph =
  ## The execution graph of one already-discovered package, with no resolution
  ## step: no lock, no store, and no dependency acquisition. A host that has no
  ## package store at all starts here, because resolving would take the store's
  ## GC barrier for a graph that can only ever contain this one package.
  result = MaterializedGraph(workspaceRoot: pkg.root,
                             activePackageId: pkg.id,
                             developmentPackageId: pkg.id,
                             rootPackageIds: @[pkg.id],
                             packagesById: initTable[string, Package]())
  result.packagesById[pkg.id] = pkg

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
# Workspace discovery and package-manager seam (proposal §3.2, §4, §10)
# ---------------------------------------------------------------------------

type PackageContext = object
  active: Package
  workspaceRoot: Package
  membersByName: Table[string, Package]

proc splitPattern(pattern: string): seq[string] =
  for segment in pattern.replace('\\', '/').split('/'):
    if segment.len > 0:
      result.add segment

proc expandMemberPattern(root, pattern, manifestPath: string): seq[string] =
  let segments = splitPattern(pattern)
  var matches: seq[string]

  proc descend(current: string, index: int) =
    if index == segments.len:
      if dirExists(current):
        matches.add normalizedPath(absolutePath(current))
      return
    let segment = segments[index]
    case segment
    of "*":
      if not dirExists(current):
        return
      var children: seq[string]
      for kind, path in walkDir(current, relative = false):
        if kind == pcDir:
          children.add path
      children.sort()
      for child in children:
        descend(child, index + 1)
    of "**":
      descend(current, index + 1)
      if not dirExists(current):
        return
      var children: seq[string]
      for kind, path in walkDir(current, relative = false):
        if kind == pcDir:
          children.add path
      children.sort()
      for child in children:
        descend(child, index)
    else:
      if '*' in segment:
        raisePackageError(pecManifestInvalid,
          "workspace patterns support only complete `*` and `**` segments: " &
          pattern, [manifestPath])
      descend(current / segment, index + 1)

  descend(root, 0)
  matches.sort()
  var unique: seq[string]
  for path in matches:
    if path notin unique:
      unique.add path
  result = unique

proc loadWorkspace(rootPackage: Package): Table[string, Package] =
  result[rootPackage.name] = rootPackage
  var memberRoots: seq[string]
  for pattern in rootPackage.workspace.members:
    let matches = expandMemberPattern(rootPackage.root, pattern,
                                      rootPackage.manifestPath)
    if matches.len == 0:
      raisePackageError(pecManifestInvalid,
        "workspace member pattern matched no directories: " & pattern,
        [rootPackage.manifestPath])
    for memberRoot in matches:
      if not containsPath(rootPackage.realRoot, canonicalPath(memberRoot)):
        raisePackageError(pecBoundary,
          "workspace member escapes the workspace root: " & memberRoot,
          [rootPackage.manifestPath])
      if not fileExists(memberRoot / ManifestFileName):
        raisePackageError(pecManifestInvalid,
          "workspace member has no " & ManifestFileName & ": " & memberRoot,
          [rootPackage.manifestPath])
      memberRoots.add memberRoot
  memberRoots.sort()
  for i, memberRoot in memberRoots:
    for j in 0 ..< i:
      let left = canonicalPath(memberRoots[j])
      let right = canonicalPath(memberRoot)
      if containsPath(left, right) or containsPath(right, left):
        raisePackageError(pecManifestInvalid,
          "workspace member roots overlap: " & memberRoots[j] & " and " &
          memberRoot, [rootPackage.manifestPath])
    let member = loadPackageAt(memberRoot, poWorkspace)
    if member.hasWorkspace:
      raisePackageError(pecManifestInvalid,
        "nested workspaces are not allowed: " & member.manifestPath,
        [rootPackage.manifestPath])
    if result.hasKey(member.name):
      raisePackageError(pecManifestInvalid,
        "duplicate workspace package name: " & member.name,
        [result[member.name].manifestPath, member.manifestPath])
    result[member.name] = member

proc discoverPackageContext(startDir: string): PackageContext =
  result.active = discoverApplicationPackage(startDir)
  if result.active.kind == pkAdHoc:
    result.workspaceRoot = result.active
    return

  var candidateRoots: seq[Package]
  var dir = result.active.root
  while true:
    if fileExists(dir / ManifestFileName):
      let candidate =
        if dir == result.active.root: result.active
        else: loadPackageAt(dir, poEntry)
      if candidate.hasWorkspace:
        let members = loadWorkspace(candidate)
        var containsActive = candidate.root == result.active.root
        if not containsActive:
          for member in members.values:
            if member.root == result.active.root:
              containsActive = true
              result.active = member
              break
        if containsActive:
          candidateRoots.add candidate
          result.membersByName = members
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  if candidateRoots.len > 1:
    raisePackageError(pecManifestInvalid,
      "nested workspaces contain the active package",
      candidateRoots.mapIt(it.manifestPath))
  if candidateRoots.len == 1:
    result.workspaceRoot = candidateRoots[0]
  else:
    result.workspaceRoot = result.active
    result.membersByName[result.active.name] = result.active

proc contextWorkspaceDigest(context: PackageContext): string =
  var values: seq[Value]
  if context.workspaceRoot.kind == pkAdHoc or
      not context.workspaceRoot.hasWorkspace:
    values.add NIL
  else:
    var workspaceEntries = initPropTable()
    var patterns: seq[Value]
    for pattern in context.workspaceRoot.workspace.members:
      patterns.add newStr(pattern)
    workspaceEntries["members"] = newList(patterns)
    values.add newMap(workspaceEntries)
    var members: seq[Package]
    for _, member in context.membersByName:
      if member.root != context.workspaceRoot.root:
        members.add member
    members.sort(proc (a, b: Package): int = cmp(a.root, b.root))
    for member in members:
      values.add newList(@[
        newStr(relativePath(member.root, context.workspaceRoot.root)
          .replace('\\', '/')),
        newStr(member.manifestDigest)])
  canonicalDigest(newList(values))

proc segmentMatches(pattern, value: string): bool =
  var p = 0
  var v = 0
  var star = -1
  var retry = 0
  while v < value.len:
    if p < pattern.len and pattern[p] == value[v]:
      inc p
      inc v
    elif p < pattern.len and pattern[p] == '*':
      star = p
      inc p
      retry = v
    elif star >= 0:
      p = star + 1
      inc retry
      v = retry
    else:
      return false
  while p < pattern.len and pattern[p] == '*':
    inc p
  p == pattern.len

proc globMatches(pattern, path: string): bool =
  let patternParts = splitPattern(pattern)
  let pathParts = splitPattern(path)
  var memo = initTable[tuple[p, s: int], bool]()
  var known = initHashSet[tuple[p, s: int]]()

  proc matches(p, s: int): bool =
    let key = (p, s)
    if key in known:
      return memo[key]
    known.incl key
    if p == patternParts.len:
      result = s == pathParts.len
    elif patternParts[p] == "**":
      result = matches(p + 1, s) or
        (s < pathParts.len and matches(p, s + 1))
    else:
      result = s < pathParts.len and
        segmentMatches(patternParts[p], pathParts[s]) and
        matches(p + 1, s + 1)
    memo[key] = result

  matches(0, 0)

proc workspaceMemberMatches*(pattern, path: string): bool =
  globMatches(pattern, path)

const immutableDefaultExcludes = [
  "package.gene.lock", ".gene/**", "vendor/**", ".git/**", ".hg/**",
  ".svn/**", ".DS_Store", "Thumbs.db", "*~", "*.swp", "*.tmp"]

proc selectedByFiles(pkg: Package, relPath: string): bool =
  var included = false
  for pattern in pkg.files.includes:
    if globMatches(pattern, relPath):
      included = true
      break
  if not included:
    return false
  for pattern in immutableDefaultExcludes:
    if globMatches(pattern, relPath):
      return false
  for pattern in pkg.files.excludes:
    if globMatches(pattern, relPath):
      return false
  true

type SourceTreeEntry = object
  path: string
  rawPath: string
  absolutePath: string
  symlink: bool
  executable: bool
  size: int64
  linkTarget: string
  targetPath: string

proc normalizeSymlinkTarget(raw, path, manifestPath: string): string =
  var target = raw.replace('\\', '/')
  if target.len == 0 or target.isAbsolute or target[0] == '/':
    raisePackageError(pecBoundary,
      "source tree symlink has a non-relative target: " & path,
      [manifestPath])
  var segments: seq[string]
  for segment in target.split('/'):
    if segment.len == 0 or segment == ".":
      continue
    if segment == ".." and segments.len > 0 and segments[^1] != "..":
      discard segments.pop()
    else:
      segments.add segment
  if segments.len == 0:
    raisePackageError(pecBoundary,
      "source tree symlink has an empty normalized target: " & path,
      [manifestPath])
  segments.join("/")

proc sourceTreeEntries(pkg: Package): seq[SourceTreeEntry] =
  var entries: seq[SourceTreeEntry]
  proc walk(dir, relativeDir: string) =
    var children: seq[tuple[kind: PathComponent, path: string]]
    for kind, path in walkDir(dir, relative = false):
      children.add (kind, path)
    children.sort(proc (a, b: tuple[kind: PathComponent, path: string]): int =
      cmp(extractFilename(a.path), extractFilename(b.path)))
    for child in children:
      let name = extractFilename(child.path)
      let rel = (if relativeDir.len > 0: relativeDir & "/" else: "") & name
      case child.kind
      of pcDir:
        walk(child.path, rel)
      of pcFile:
        if pkg.selectedByFiles(rel):
          let info = getFileInfo(child.path, followSymlink = false)
          if info.isSpecial:
            raisePackageError(pecBoundary,
              "source tree contains a special device or stream: " & rel,
              [pkg.manifestPath])
          var executable = false
          for pattern in pkg.files.executables:
            if globMatches(pattern, rel):
              executable = true
              break
          entries.add SourceTreeEntry(path: rel, executable: executable,
                                      absolutePath: child.path,
                                      size: info.size)
      of pcLinkToFile, pcLinkToDir:
        if pkg.selectedByFiles(rel):
          let rawTarget = normalizeSymlinkTarget(
            expandSymlink(child.path), rel, pkg.manifestPath)
          if unicode.validateUtf8(rawTarget) >= 0:
            raisePackageError(pecManifestInvalid,
              "source tree symlink target is not valid UTF-8: " & rel,
              [pkg.manifestPath])
          let target = unicodeNfc151(rawTarget)
          let lexicalTarget = normalizedPath(absolutePath(
            rawTarget, parentDir(child.path)))
          if not containsPath(pkg.root, lexicalTarget):
            raisePackageError(pecBoundary,
              "source tree symlink escapes the package lexically: " & rel,
              [pkg.manifestPath])
          var resolved: string
          try:
            resolved = expandFilename(normalizedPath(absolutePath(
              rawTarget, parentDir(child.path))))
          except OSError, IOError:
            raisePackageError(pecBoundary,
              "source tree symlink cannot be resolved safely: " & rel,
              [pkg.manifestPath])
          if not containsPath(pkg.realRoot, resolved):
            raisePackageError(pecBoundary,
              "source tree symlink escapes the package: " & rel,
              [pkg.manifestPath])
          entries.add SourceTreeEntry(path: rel, symlink: true,
                                      absolutePath: child.path,
                                      linkTarget: target,
                                      targetPath: unicodeNfc151(relativePath(
                                        lexicalTarget, pkg.root)
                                        .replace('\\', '/')),
                                      size: int64(target.len))

  walk(pkg.root, "")
  result = entries
  for entry in result.mitems:
    if unicode.validateUtf8(entry.path) >= 0:
      raisePackageError(pecManifestInvalid,
        "source tree path is not valid UTF-8: " & entry.path,
        [pkg.manifestPath])
    entry.rawPath = entry.path
    entry.path = unicodeNfc151(entry.path)
  result.sort(proc (a, b: SourceTreeEntry): int = cmp(a.path, b.path))
  var normalizedTopology = initTable[string, tuple[raw: string,
                                                    terminal: bool]]()
  var foldedTopology = initTable[string, string]()
  for entry in result:
    let canonicalSegments = entry.path.split('/')
    let rawSegments = entry.rawPath.split('/')
    var canonical = ""
    var raw = ""
    for index in 0 ..< canonicalSegments.len:
      if index > 0:
        canonical.add '/'
        raw.add '/'
      canonical.add canonicalSegments[index]
      raw.add rawSegments[index]
      let terminal = index == canonicalSegments.high
      if normalizedTopology.hasKey(canonical):
        let existing = normalizedTopology[canonical]
        if existing.raw != raw or existing.terminal or terminal:
          raisePackageError(pecManifestInvalid,
            "source tree contains a Unicode-normalization topology " &
            "collision: " & canonical, [existing.raw, raw, pkg.manifestPath])
      else:
        normalizedTopology[canonical] = (raw: raw, terminal: terminal)
      let folded = unicodeDefaultCaseFold151(canonical)
      if foldedTopology.hasKey(folded) and
          foldedTopology[folded] != canonical:
        raisePackageError(pecManifestInvalid,
          "source tree contains a case-fold topology collision: " &
          canonical, [foldedTopology[folded], pkg.manifestPath])
      foldedTopology[folded] = canonical
  var selectedPaths = initHashSet[string]()
  var symlinkTargets = initTable[string, string]()
  for entry in result:
    selectedPaths.incl entry.path
  for entry in result:
    if not entry.symlink:
      continue
    let relativeTarget = entry.targetPath
    symlinkTargets[entry.path] = relativeTarget
    var selected = relativeTarget in selectedPaths
    if not selected:
      for candidate in selectedPaths:
        if candidate.startsWith(relativeTarget & "/"):
          selected = true
          break
    if not selected:
      raisePackageError(pecBoundary,
        "source tree symlink target is outside the selected source tree: " &
        entry.path, [entry.linkTarget, pkg.manifestPath])
  # `expandFilename` rejects host-visible cycles. Keep an explicit cycle check
  # over canonical selected paths as well so the format rule does not depend
  # on platform-specific symlink traversal behavior.
  var visiting = initHashSet[string]()
  var visited = initHashSet[string]()
  proc visitSymlink(path: string) =
    if path in visiting:
      raisePackageError(pecBoundary,
        "source tree contains a symlink cycle: " & path, [pkg.manifestPath])
    if path in visited or not symlinkTargets.hasKey(path):
      return
    visiting.incl path
    let target = symlinkTargets[path]
    # Directory links alias a subtree, so cycles also pass through links
    # below the target directory (for example `a -> dir`,
    # `dir/back -> ../a`). A target can likewise traverse a link prefix.
    var dependencies: seq[string]
    for candidate in symlinkTargets.keys:
      if candidate == target or target.startsWith(candidate & "/") or
          candidate.startsWith(target & "/"):
        dependencies.add candidate
    dependencies.sort()
    for dependency in dependencies:
      visitSymlink(dependency)
    visiting.excl path
    visited.incl path
  var links: seq[string]
  for path in symlinkTargets.keys:
    links.add path
  links.sort()
  for path in links:
    visitSymlink(path)

proc sourceTreeBytes*(pkg: Package): string =
  let entries = sourceTreeEntries(pkg)
  result = "gene-tree-v1\0"
  result.appendU64(uint64(entries.len))
  for entry in entries:
    result.add(if entry.symlink: '\x02' else: '\x01')
    result.appendU64(uint64(entry.path.len))
    result.add entry.path
    if not entry.symlink:
      result.add(if entry.executable: '\x01' else: '\x00')
    result.appendU64(uint64(entry.size))
    if entry.symlink:
      result.add entry.linkTarget
    else:
      let content = readFile(entry.absolutePath)
      if int64(content.len) != entry.size:
        raisePackageError(pecIdentityMismatch,
          "source changed while its canonical tree was captured",
          [entry.absolutePath])
      result.add content

proc updateSourceEntries(context: var Sha256Context,
                         entries: openArray[SourceTreeEntry],
                         mirror: ptr Sha256Context = nil) =
  var header = ""
  header.appendU64(uint64(entries.len))
  context.update(header)
  if mirror != nil: mirror[].update(header)
  for entry in entries:
    header.setLen(0)
    header.add(if entry.symlink: '\x02' else: '\x01')
    header.appendU64(uint64(entry.path.len))
    header.add entry.path
    if not entry.symlink:
      header.add(if entry.executable: '\x01' else: '\x00')
    header.appendU64(uint64(entry.size))
    context.update(header)
    if mirror != nil: mirror[].update(header)
    if entry.symlink:
      context.update(entry.linkTarget)
      if mirror != nil: mirror[].update(entry.linkTarget)
      continue
    var file: File
    if not open(file, entry.absolutePath, fmRead):
      raisePackageError(pecNotFound,
        "source file disappeared while its canonical tree was captured",
        [entry.absolutePath])
    var buffer: array[64 * 1024, byte]
    var bytesRead: int64
    try:
      while true:
        let count = file.readBuffer(addr buffer[0], buffer.len)
        if count <= 0:
          break
        context.update(buffer.toOpenArray(0, count - 1))
        if mirror != nil:
          mirror[].update(buffer.toOpenArray(0, count - 1))
        bytesRead += int64(count)
    finally:
      close(file)
    if bytesRead != entry.size or getFileSize(entry.absolutePath) != entry.size:
      raisePackageError(pecIdentityMismatch,
        "source changed while its canonical tree was captured",
        [entry.absolutePath])

proc sourceTreeDigest*(pkg: Package): string =
  var context = initSha256()
  context.update("gene-tree-v1\0")
  context.updateSourceEntries(sourceTreeEntries(pkg))
  "sha256:" & context.finishHex()

proc sourceTreeStamp*(pkg: Package): string =
  ## A local incremental-cache stamp, never a package or artifact identity.
  ## It lets a warm build reuse a previously verified tree digest after one
  ## sorted metadata scan; any content-relevant filesystem change on supported
  ## hosts changes size, mtime/ctime, or the file identity and triggers a full
  ## canonical tree hash. Hosts without POSIX ctime additionally hash file
  ## bytes: correctness never depends on a timestamp API being able to observe
  ## same-size edits with restored mtimes.
  var context = initSha256()
  context.update("gene-source-stamp-v1\0")
  for entry in sourceTreeEntries(pkg):
    var record = ""
    record.appendU64(uint64(entry.path.len))
    record.add entry.path
    record.add(if entry.symlink: '\x02' else: '\x01')
    record.add(if entry.executable: '\x01' else: '\x00')
    record.appendU64(uint64(entry.size))
    if entry.symlink:
      record.appendU64(uint64(entry.linkTarget.len))
      record.add entry.linkTarget
    let info = getFileInfo(entry.absolutePath, followSymlink = false)
    for value in [$info.id.device, $info.id.file,
                  $info.lastWriteTime.toUnix,
                  $info.lastWriteTime.nanosecond,
                  $info.creationTime.toUnix,
                  $info.creationTime.nanosecond]:
      record.appendU64(uint64(value.len))
      record.add value
    when not defined(posix):
      if not entry.symlink:
        let contentDigest = sha256File(entry.absolutePath)
        record.appendU64(uint64(contentDigest.len))
        record.add contentDigest
    context.update(record)
  "sha256:" & context.finishHex()

proc sourcePackageDigest*(pkg: Package, treeDigest: string): string =
  ## Digest the exact deterministic Source Package v1 byte stream. This is a
  ## cold registry/publication operation: the tree digest must be known before
  ## it can be embedded in the container metadata, so source bytes are read a
  ## second time without buffering the package in memory.
  var metadata = initPropTable()
  metadata["format"] = newInt(1)
  metadata["name"] = newStr(pkg.name)
  metadata["version"] = newStr(pkg.version)
  metadata["manifest_digest"] = newStr(pkg.manifestDigest)
  metadata["tree_digest"] = newStr(treeDigest)
  let metadataBytes = canonicalGeneData(newMap(metadata))
  var context = initSha256()
  context.update("gene-gpkg-v1\0")
  var header = ""
  header.appendU64(uint64(metadataBytes.len))
  context.update(header)
  context.update(metadataBytes)
  var observedTree = initSha256()
  observedTree.update("gene-tree-v1\0")
  context.updateSourceEntries(sourceTreeEntries(pkg), addr observedTree)
  let observedDigest = "sha256:" & observedTree.finishHex()
  if observedDigest != treeDigest:
    raisePackageError(pecIdentityMismatch,
      "source changed while its source package was captured",
      ["expected: " & treeDigest, "actual: " & observedDigest,
       pkg.manifestPath])
  "sha256:" & context.finishHex()

proc makeMaterializedTreeWritable*(path: string) =
  ## Restore owner permissions before deleting or replacing an immutable
  ## package, snapshot, or artifact tree. Symlinks are deliberately not
  ## followed.
  when defined(posix):
    if not dirExists(path):
      return
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    for kind, child in walkDir(path, relative = false):
      case kind
      of pcDir:
        makeMaterializedTreeWritable(child)
      of pcFile:
        var permissions = {fpUserRead, fpUserWrite}
        if fpUserExec in getFilePermissions(child):
          permissions.incl fpUserExec
        setFilePermissions(child, permissions)
      of pcLinkToFile, pcLinkToDir:
        discard

proc protectMaterializedTree*(path: string) =
  ## Make a published content-addressed tree read-only, including its
  ## directories. Directory protection prevents entry replacement while the
  ## object is being verified or consumed.
  when defined(posix):
    if not dirExists(path):
      return
    for kind, child in walkDir(path, relative = false):
      case kind
      of pcDir:
        protectMaterializedTree(child)
      of pcFile:
        var permissions = {fpUserRead, fpGroupRead, fpOthersRead}
        if fpUserExec in getFilePermissions(child):
          permissions.incl fpUserExec
          permissions.incl fpGroupExec
          permissions.incl fpOthersExec
        setFilePermissions(child, permissions)
      of pcLinkToFile, pcLinkToDir:
        discard
    setFilePermissions(path, {
      fpUserRead, fpUserExec,
      fpGroupRead, fpGroupExec,
      fpOthersRead, fpOthersExec})

proc materializeSourceTree*(pkg: Package, destination: string) =
  ## Copy exactly the canonical selected tree. Store objects and build
  ## snapshots must not acquire ignored VCS, vendor, or `.gene/` contents.
  if dirExists(destination):
    makeMaterializedTreeWritable(destination)
    removeDir(destination)
  createDir(destination)
  for entry in sourceTreeEntries(pkg):
    let target = destination / entry.path
    createDir(parentDir(target))
    if entry.symlink:
      createSymlink(entry.linkTarget, target)
    else:
      copyFile(entry.absolutePath, target)
      var permissions = {fpUserRead, fpGroupRead, fpOthersRead}
      if entry.executable:
        permissions.incl fpUserExec
        permissions.incl fpGroupExec
        permissions.incl fpOthersExec
      setFilePermissions(target, permissions)

proc packageInstanceId(pkg: Package, workspaceRoot: string,
                       workspaceOwner: Package,
                       declaring: Package = nil): string =
  if pkg.kind == pkAdHoc:
    return pkg.id
  var identity: Value
  case pkg.sourceKind
  of dskRegistry:
    identity = newList(@[
      newList(@[newSym("registry"), newStr(pkg.sourcePath)]),
      newStr(pkg.treeDigest)])
  of dskGit:
    identity = newList(@[
      newList(@[newSym("git"), newStr(pkg.sourceName),
                newStr(pkg.sourcePath)]),
      newStr(pkg.treeDigest)])
  of dskWorkspace:
    identity = newList(@[
      newSym("workspace"),
      newStr(workspaceOwner.name), newStr(workspaceOwner.version),
      newStr(relativePath(pkg.root, workspaceRoot).replace('\\', '/')),
      newStr(pkg.name), newStr(pkg.version), newStr(pkg.manifestDigest)])
  of dskPath:
    let declaringIdentity =
      if declaring != nil and declaring.id.len > 0: declaring.id
      elif declaring != nil: declaring.name & "@" & declaring.version
      else: workspaceOwner.name & "@" & workspaceOwner.version
    identity = newList(@[
      newSym("path"), newStr(declaringIdentity), newStr(pkg.sourcePath),
      newStr(pkg.name), newStr(pkg.version), newStr(pkg.manifestDigest)])
  let prefix = if pkg.sourceKind in {dskRegistry, dskGit}: "pkg" else:
    $pkg.sourceKind
  prefix & ":" & pkg.name & "@" & pkg.version & "#" &
    canonicalDigest(identity)

proc canonicalPercentEncoding(text, context: string): string =
  const hex = "0123456789ABCDEF"
  var i = 0
  while i < text.len:
    if text[i] != '%':
      result.add text[i]
      inc i
      continue
    if i + 2 >= text.len or text[i + 1] notin HexDigits or
        text[i + 2] notin HexDigits:
      raisePackageError(pecManifestInvalid,
        "source URL contains an invalid percent escape", [context])
    let value = parseHexInt(text[i + 1 .. i + 2])
    let decoded = char(value)
    if decoded in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.', '_', '~'}:
      result.add decoded
    else:
      result.add '%'
      result.add hex[(value shr 4) and 0xf]
      result.add hex[value and 0xf]
    i += 3

proc canonicalPackageUrl*(raw, context: string): string =
  var parsed: Uri
  try:
    parsed = parseUri(raw)
  except ValueError:
    raisePackageError(pecManifestInvalid, "invalid source URL", [raw, context])
  let scheme = parsed.scheme.toLowerAscii()
  if scheme notin ["https", "ssh"] or parsed.hostname.len == 0:
    raisePackageError(pecManifestInvalid,
      "source URL must use absolute https:// or ssh:// form", [raw, context])
  if parsed.password.len > 0 or parsed.query.len > 0 or parsed.anchor.len > 0:
    raisePackageError(pecManifestInvalid,
      "source URL must not contain a password, query, or fragment",
      [raw, context])
  if scheme != "ssh" and parsed.username.len > 0:
    raisePackageError(pecManifestInvalid,
      "only ssh source URLs may contain a username", [raw, context])
  for ch in parsed.hostname:
    if ord(ch) > 127:
      raisePackageError(pecManifestInvalid,
        "source URL hosts must use an IDNA A-label", [raw, context])
  var port = parsed.port
  if (scheme == "https" and port == "443") or
      (scheme == "ssh" and port == "22"):
    port = ""
  if port.len > 0:
    try:
      let number = parseInt(port)
      if number < 1 or number > 65535:
        raise newException(ValueError, "port out of range")
    except ValueError:
      raisePackageError(pecManifestInvalid,
        "source URL has an invalid port", [raw, context])
  let encodedPath = canonicalPercentEncoding(parsed.path, context)
  var segments: seq[string]
  for segment in encodedPath.split('/'):
    if segment.len == 0 or segment == ".":
      continue
    if segment == "..":
      if segments.len > 0:
        discard segments.pop()
    else:
      segments.add segment
  var path = "/" & segments.join("/")
  if parsed.path.endsWith("/") and path != "/":
    path.add '/'
  result = scheme & "://"
  if parsed.username.len > 0:
    result.add canonicalPercentEncoding(parsed.username, context) & "@"
  result.add parsed.hostname.toLowerAscii()
  if port.len > 0:
    result.add ":" & port
  result.add path

proc canonicalGitCommit(value, context: string): string =
  if value.len notin [40, 64]:
    raisePackageError(pecManifestInvalid,
      "git commit must be a 40- or 64-character lowercase hexadecimal ID",
      [value, context])
  for ch in value:
    if ch notin {'0' .. '9', 'a' .. 'f'}:
      raisePackageError(pecManifestInvalid,
        "git commit must be a lowercase hexadecimal ID", [value, context])
  value

proc newFilesystemRegistry*(name, root: string,
                            url = ""): PackageSourceAdapter =
  validateLocalName(name, "registry name", root)
  let effectiveUrl = if url.len > 0: url else:
    "https://" & name & ".registry.invalid/"
  PackageSourceAdapter(name: name, root: normalizedPath(absolutePath(root)),
    url: canonicalPackageUrl(effectiveUrl, root))

proc newPackageManager*(userStoreRoot = "",
                        registries: seq[PackageSourceAdapter] = @[],
                        gitSourceAdapter: GitSourceAdapter = nil,
                        defaultRegistry = ""):
                        PackageManager =
  var names = initHashSet[string]()
  var urls = initHashSet[string]()
  for adapter in registries:
    if adapter == nil:
      raisePackageError(pecManifestInvalid, "registry adapter must not be nil")
    validateLocalName(adapter.name, "registry name", adapter.root)
    adapter.url = canonicalPackageUrl(adapter.url, adapter.root)
    if adapter.name in names or adapter.url in urls:
      raisePackageError(pecManifestInvalid,
        "registry names and URLs must have a one-to-one mapping",
        [adapter.name, adapter.url])
    names.incl adapter.name
    urls.incl adapter.url
  let selectedDefault =
    if defaultRegistry.len > 0: defaultRegistry
    elif registries.len > 0: registries[0].name
    else: ""
  if selectedDefault.len > 0 and selectedDefault notin names:
    raisePackageError(pecManifestInvalid,
      "default registry is not configured: " & selectedDefault)
  PackageManager(userStoreRoot:
    if userStoreRoot.len > 0: normalizedPath(absolutePath(userStoreRoot))
    else: userStoreDir(), registries: registries,
    defaultRegistry: selectedDefault,
    gitSourceAdapter: gitSourceAdapter)

type
  PendingRequirement = object
    importerId: string
    dep: DependencyDecl

  SolverState = object
    selected: Table[string, Package]
    edges: Table[tuple[importer, alias: string], string]
    features: Table[string, HashSet[string]]
    scheduled: HashSet[tuple[importer, alias: string]]
    pending: seq[PendingRequirement]

proc cloneState(state: SolverState): SolverState =
  for id, pkg in state.selected:
    result.selected[id] = pkg
  for edge, target in state.edges:
    result.edges[edge] = target
  for id, features in state.features:
    var copied = initHashSet[string]()
    for feature in features:
      copied.incl feature
    result.features[id] = copied
  for edge in state.scheduled:
    result.scheduled.incl edge
  result.pending = state.pending

proc dependencyEnabled(dep: DependencyDecl,
                       developmentRoot: bool): bool =
  case dep.scope
  of dsRuntime: true
  of dsDevelopment: developmentRoot
  of dsBuild: true

proc expandedFeatures(pkg: Package, requested: HashSet[string]):
                      HashSet[string] =
  for feature in requested:
    if not pkg.features.hasKey(feature):
      raisePackageError(pecVersionConflict,
        pkg.name & " does not define requested feature " & feature,
        [pkg.manifestPath])
    result.incl feature
  var changed = true
  while changed:
    changed = false
    var current: seq[string]
    for feature in result:
      current.add feature
    current.sort()
    for feature in current:
      for activation in pkg.features[feature]:
        if activation.startsWith("feature:"):
          let target = activation[8 .. ^1]
          if target notin result:
            result.incl target
            changed = true

proc plannedDependencies(pkg: Package, features: HashSet[string],
                         developmentRoot: bool): seq[DependencyDecl] =
  var enabledOptional = initHashSet[string]()
  var forwarded = initTable[string, seq[string]]()
  for feature in features:
    for activation in pkg.features.getOrDefault(feature):
      if activation.startsWith("dep:"):
        let coordinate = activation[4 .. ^1]
        let slash = coordinate.find('/')
        if slash < 0:
          enabledOptional.incl coordinate
        else:
          let alias = coordinate[0 ..< slash]
          let targetFeature = coordinate[slash + 1 .. ^1]
          if targetFeature notin forwarded.mgetOrPut(alias, @[]):
            forwarded[alias].add targetFeature
  var deps = pkg.dependencies
  deps.sort(proc (a, b: DependencyDecl): int = cmp(a.alias, b.alias))
  for dep in deps:
    if not dependencyEnabled(dep, developmentRoot):
      continue
    if dep.optional and dep.alias notin enabledOptional:
      continue
    var planned = dep
    for feature in forwarded.getOrDefault(dep.alias):
      if feature notin planned.features:
        planned.features.add feature
    planned.features.sort()
    result.add planned

proc activatePackage(state: var SolverState, pkg: Package,
                     requested: seq[string], enableDefaults: bool,
                     developmentRoot: bool) =
  var features = state.features.getOrDefault(pkg.id)
  if enableDefaults:
    for feature in pkg.defaultFeatures:
      features.incl feature
  for feature in requested:
    features.incl feature
  let expanded = expandedFeatures(pkg, features)
  var changed = expanded.len != state.features.getOrDefault(pkg.id).len
  if not changed:
    for feature in expanded:
      if feature notin state.features.getOrDefault(pkg.id):
        changed = true
        break
  if not changed and state.features.hasKey(pkg.id):
    return
  state.features[pkg.id] = expanded
  for dep in plannedDependencies(pkg, expanded, developmentRoot):
    let edgeKey = (pkg.id, dep.alias)
    if state.edges.hasKey(edgeKey):
      let target = state.selected[state.edges[edgeKey]]
      state.activatePackage(target, dep.features, dep.defaultFeatures, false)
    elif edgeKey in state.scheduled:
      for pending in state.pending.mitems:
        if pending.importerId == pkg.id and pending.dep.alias == dep.alias:
          for feature in dep.features:
            if feature notin pending.dep.features:
              pending.dep.features.add feature
          pending.dep.features.sort()
          break
    else:
      state.scheduled.incl edgeKey
      state.pending.add PendingRequirement(importerId: pkg.id, dep: dep)

proc validateMaterializedEdges(manager: PackageManager,
                               graph: MaterializedGraph, importer: Package,
                               developmentRoot: bool, contextPath: string) =
  ## A lock is an exact rendering of enabled manifest requirements, not an
  ## authority to omit an alias or substitute a different source locator.
  var selected = initHashSet[string]()
  for feature in importer.selectedFeatures:
    selected.incl feature
  let expanded = expandedFeatures(importer, selected)
  if expanded.len != selected.len:
    raisePackageError(pecIdentityMismatch,
      "locked feature set is not transitively closed",
      [importer.id, contextPath])
  let expected = plannedDependencies(importer, expanded, developmentRoot)
  if expected.len != importer.dependencyEdges.len:
    raisePackageError(pecIdentityMismatch,
      "locked dependency set disagrees with the enabled manifest edges",
      [importer.id, contextPath])
  for declaration in expected:
    if not importer.dependencyEdges.hasKey(declaration.alias):
      raisePackageError(pecIdentityMismatch,
        "lockfile omits enabled dependency alias: " & declaration.alias,
        [importer.manifestPath, contextPath])
    if importer.dependencyEdgeScopes.hasKey(declaration.alias) and
        importer.dependencyEdgeScopes[declaration.alias] != declaration.scope:
      raisePackageError(pecIdentityMismatch,
        "locked dependency scope disagrees with the manifest: " &
        declaration.alias, [importer.manifestPath, contextPath])
    let targetId = importer.dependencyEdges[declaration.alias]
    if not graph.packagesById.hasKey(targetId):
      raisePackageError(pecIdentityMismatch,
        "locked dependency target is absent: " & targetId,
        [importer.manifestPath, contextPath])
    let target = graph.packagesById[targetId]
    if target.name != declaration.name or
        target.sourceKind != declaration.sourceKind or
        (declaration.constraint.len > 0 and not matchesConstraint(
          target.version, declaration.constraint, importer.manifestPath)):
      raisePackageError(pecIdentityMismatch,
        "locked dependency target disagrees with the manifest: " &
        declaration.alias, [importer.manifestPath, targetId])
    case declaration.sourceKind
    of dskRegistry:
      let expectedRegistry =
        if declaration.registry.len > 0: declaration.registry
        else: manager.defaultRegistry
      if expectedRegistry.len > 0 and target.sourceName != expectedRegistry:
        raisePackageError(pecIdentityMismatch,
          "locked registry disagrees with the manifest policy: " &
          declaration.alias,
          ["expected: " & expectedRegistry, "found: " & target.sourceName])
    of dskGit:
      if target.sourceName != declaration.git or
          (declaration.gitSelectorKind == "commit" and
           target.sourcePath != declaration.gitSelector):
        raisePackageError(pecIdentityMismatch,
          "locked git source disagrees with the manifest: " &
          declaration.alias,
          [importer.manifestPath, target.sourceName & "#" & target.sourcePath])
    of dskPath:
      if target.sourcePath != declaration.path:
        raisePackageError(pecIdentityMismatch,
          "locked path locator disagrees with the manifest: " &
          declaration.alias,
          ["expected: " & declaration.path, "found: " & target.sourcePath])
    of dskWorkspace:
      discard

proc createsCycle(state: SolverState, importerId, targetId: string): bool =
  if importerId == targetId:
    return true
  var pending = @[targetId]
  var seen = initHashSet[string]()
  while pending.len > 0:
    let current = pending.pop()
    if current == importerId:
      return true
    if current in seen:
      continue
    seen.incl current
    for edge, target in state.edges:
      if edge.importer == current:
        pending.add target
  false

proc solutionGroups(state: SolverState): Table[string, seq[Package]] =
  for _, pkg in state.selected:
    let sourceIdentity =
      if pkg.sourceName.len > 0: pkg.sourceName
      else: $pkg.sourceKind
    result.mgetOrPut(pkg.name & "\0" & sourceIdentity, @[]).add pkg
  for _, packages in result.mpairs:
    packages.sort(proc (a, b: Package): int =
      result = -cmpSemVersion(parseSemVersion(a.version, a.manifestPath),
                              parseSemVersion(b.version, b.manifestPath))
      if result == 0:
        result = -cmp(a.version, b.version)
      if result == 0:
        result = -cmp(a.id, b.id))

type PreservedEdges = Table[tuple[importer, alias: string], string]

proc preservationIdentity(pkg: Package): string =
  case pkg.sourceKind
  of dskWorkspace, dskPath:
    $pkg.sourceKind & ":" & pkg.sourcePath & ":" & pkg.name & "@" & pkg.version
  of dskRegistry:
    "registry:" & pkg.sourceName & ":" & pkg.name & "@" & pkg.version
  of dskGit:
    "git:" & pkg.sourceName & "#" & pkg.sourcePath & ":" &
      pkg.name & "@" & pkg.version

proc preservationScore(state: SolverState, preserved: PreservedEdges): int =
  for edge, target in state.edges:
    let importer = state.selected[edge.importer].preservationIdentity()
    let key = (importer, edge.alias)
    if preserved.hasKey(key) and
        preserved[key] == state.selected[target].preservationIdentity():
      inc result

proc readPreservedEdges(lockPath: string, unlockAliases: seq[string],
                        activePackage: Package): PreservedEdges =
  if not fileExists(lockPath):
    return
  try:
    let forms = readPackageData(readFile(lockPath), lockPath)
    if forms.len != 1 or forms[0].kind != vkMap or
        not forms[0].mapEntries.hasKey("packages") or
        forms[0].mapEntries["packages"].kind != vkList:
      return
    var identities = initTable[string, string]()
    var nodes = initTable[string, Value]()
    var adjacency = initTable[string, seq[tuple[alias, target: string]]]()
    for value in forms[0].mapEntries["packages"].listItems:
      if value.kind != vkNode or value.head.kind != vkSymbol or
          value.head.symVal != "locked_package" or
          not value.props.hasKey("id") or value.props["id"].kind != vkString or
          not value.props.hasKey("name") or
          value.props["name"].kind != vkString or
          not value.props.hasKey("version") or
          value.props["version"].kind != vkString or
          not value.props.hasKey("source"):
        return
      let id = value.props["id"].strVal
      let source = value.props["source"]
      if source.kind != vkNode or source.head.kind != vkSymbol:
        return
      let sourceHead = source.head.symVal
      if sourceHead in ["workspace", "path"] and
          source.props.hasKey("path") and
          source.props["path"].kind == vkString:
        identities[id] = sourceHead & ":" & source.props["path"].strVal & ":" &
          value.props["name"].strVal & "@" & value.props["version"].strVal
      elif sourceHead == "registry" and source.body.len == 1 and
          source.body[0].kind == vkString:
        identities[id] = "registry:" & source.body[0].strVal & ":" &
          value.props["name"].strVal & "@" & value.props["version"].strVal
      elif sourceHead == "git" and source.body.len == 1 and
          source.body[0].kind == vkString and
          source.props.hasKey("commit") and
          source.props["commit"].kind == vkString:
        identities[id] = "git:" & source.body[0].strVal & "#" &
          source.props["commit"].strVal & ":" &
          value.props["name"].strVal & "@" & value.props["version"].strVal
      else:
        identities[id] = id
      nodes[id] = value
    for id, value in nodes:
      if not value.props.hasKey("dependencies") or
          value.props["dependencies"].kind != vkMap:
        continue
      for alias, edge in value.props["dependencies"].mapEntries:
        if edge.kind == vkNode and edge.props.hasKey("target") and
            edge.props["target"].kind == vkString:
          adjacency.mgetOrPut(id, @[]).add(
            (alias, edge.props["target"].strVal))

    var cutEdges = initHashSet[tuple[importer, alias: string]]()
    var unlockedNodes = initHashSet[string]()
    if unlockAliases.len > 0 and
        forms[0].mapEntries.hasKey("roots") and
        forms[0].mapEntries["roots"].kind == vkList:
      var roots: seq[string]
      var activeRoot = ""
      for root in forms[0].mapEntries["roots"].listItems:
        if root.kind != vkString or not nodes.hasKey(root.strVal):
          continue
        roots.add root.strVal
        let node = nodes[root.strVal]
        if node.props["name"].strVal == activePackage.name and
            node.props["version"].strVal == activePackage.version:
          activeRoot = root.strVal
      if activeRoot.len > 0:
        for edge in adjacency.getOrDefault(activeRoot):
          if edge.alias in unlockAliases:
            cutEdges.incl (activeRoot, edge.alias)
            var pending = @[edge.target]
            while pending.len > 0:
              let current = pending.pop()
              if current in unlockedNodes:
                continue
              unlockedNodes.incl current
              for child in adjacency.getOrDefault(current):
                pending.add child.target
        # A node also reachable without a selected root edge is shared by a
        # retained root and must keep its lock preference.
        var protected = initHashSet[string]()
        var pending = roots
        while pending.len > 0:
          let current = pending.pop()
          if current in protected:
            continue
          protected.incl current
          for edge in adjacency.getOrDefault(current):
            if (current, edge.alias) notin cutEdges:
              pending.add edge.target
        for id in protected:
          unlockedNodes.excl id
    for id, value in nodes:
      if not value.props.hasKey("dependencies") or
          value.props["dependencies"].kind != vkMap:
        continue
      for alias, edge in value.props["dependencies"].mapEntries:
        if (id, alias) in cutEdges or id in unlockedNodes or
            edge.kind != vkNode or
            not edge.props.hasKey("target") or
            edge.props["target"].kind != vkString:
          continue
        let target = edge.props["target"].strVal
        if identities.hasKey(target):
          result[(identities[id], alias)] = identities[target]
  except CatchableError:
    discard

proc betterSolution(candidate, incumbent: SolverState,
                    hasIncumbent: bool, preserved: PreservedEdges): bool =
  if not hasIncumbent:
    return true
  let candidatePreserved = preservationScore(candidate, preserved)
  let incumbentPreserved = preservationScore(incumbent, preserved)
  if candidatePreserved != incumbentPreserved:
    return candidatePreserved > incumbentPreserved
  if candidate.selected.len != incumbent.selected.len:
    return candidate.selected.len < incumbent.selected.len
  let candidateGroups = solutionGroups(candidate)
  let incumbentGroups = solutionGroups(incumbent)
  var keys: seq[string]
  for key in candidateGroups.keys:
    keys.add key
  for key in incumbentGroups.keys:
    if key notin keys:
      keys.add key
  keys.sort()
  for key in keys:
    let left = candidateGroups.getOrDefault(key)
    let right = incumbentGroups.getOrDefault(key)
    if left.len != right.len:
      return left.len < right.len
    for i in 0 ..< left.len:
      let compared = cmpSemVersion(parseSemVersion(left[i].version,
                                                   left[i].manifestPath),
                                   parseSemVersion(right[i].version,
                                                   right[i].manifestPath))
      if compared != 0:
        return compared > 0
      if left[i].version != right[i].version:
        return left[i].version > right[i].version
      if left[i].id != right[i].id:
        return left[i].id > right[i].id
  false

proc resolve*(manager: PackageManager, request: ResolveRequest): Resolution =
  ## Deterministically solve local workspace/path and injected registry
  ## sources. Every edge is alias -> package instance; names are never global
  ## version slots.
  let start =
    if request.activePackageRoot.len > 0: request.activePackageRoot
    elif request.startDir.len > 0: request.startDir
    else: getCurrentDir()
  let context = discoverPackageContext(start)
  let preserved =
    if request.unlockAll: initTable[tuple[importer, alias: string], string]()
    else: readPreservedEdges(
      context.workspaceRoot.root / "package.gene.lock", request.unlockAliases,
      context.active)
  var candidateCache = initTable[string, seq[Package]]()
  var consultedRegistries = initHashSet[string]()

  proc registryCandidates(dep: DependencyDecl): seq[Package] =
    let cacheKey = dep.registry & "\0" & dep.name
    if candidateCache.hasKey(cacheKey):
      return candidateCache[cacheKey]
    let nameParts = dep.name.split('/')
    let selectedRegistry =
      if dep.registry.len > 0: dep.registry else: manager.defaultRegistry
    for adapter in manager.registries:
      if adapter.name != selectedRegistry:
        continue
      consultedRegistries.incl adapter.name
      let packageDir = adapter.root / nameParts[0] / nameParts[1]
      if not dirExists(packageDir):
        continue
      var versions: seq[string]
      for kind, path in walkDir(packageDir, relative = false):
        if kind in {pcDir, pcLinkToDir} and
            fileExists(path / ManifestFileName):
          versions.add path
      versions.sort()
      for path in versions:
        let pkg = loadPackageAt(path, poRegistrySource)
        if pkg.name != dep.name:
          raisePackageError(pecIdentityMismatch,
            "registry path for " & dep.name & " declares " & pkg.name,
            [pkg.manifestPath])
        pkg.sourceKind = dskRegistry
        pkg.sourceName = adapter.name
        pkg.sourcePath = adapter.url
        # Filesystem registries are a development adapter without a prebuilt
        # metadata index. Keep candidates manifest-only while solving and hash
        # source bytes only for instances selected into the solution.
        pkg.id = "candidate:registry:" & pkg.name & "@" & pkg.version & "#" &
          sha256Hex(adapter.name & "\0" & pkg.manifestDigest)
        result.add pkg
    result.sort(proc (a, b: Package): int =
      result = -cmpSemVersion(parseSemVersion(a.version, a.manifestPath),
                              parseSemVersion(b.version, b.manifestPath))
      if result == 0: result = -cmp(a.version, b.version)
      if result == 0: result = -cmp(a.manifestDigest, b.manifestDigest))
    candidateCache[cacheKey] = result

  proc candidatesFor(declaring: Package,
                     dep: DependencyDecl): seq[Package] =
    case dep.sourceKind
    of dskWorkspace:
      if not context.membersByName.hasKey(dep.name):
        raisePackageError(pecNotFound,
          "workspace has no declared member named " & dep.name,
          [declaring.manifestPath, "dependency alias: " & dep.alias])
      let pkg = context.membersByName[dep.name]
      pkg.sourceKind = dskWorkspace
      pkg.sourcePath = relativePath(pkg.root, context.workspaceRoot.root)
        .replace('\\', '/')
      pkg.id = packageInstanceId(pkg, context.workspaceRoot.root,
                                 context.workspaceRoot)
      result.add pkg
    of dskPath:
      let root = normalizedPath(absolutePath(dep.path, declaring.root))
      if not fileExists(root / ManifestFileName):
        raisePackageError(pecNotFound,
          "path dependency has no " & ManifestFileName & ": " & dep.name,
          [root])
      let cacheKey = "path\0" & declaring.id & "\0" & root
      var pkg: Package
      if candidateCache.hasKey(cacheKey):
        pkg = candidateCache[cacheKey][0]
      else:
        pkg = loadPackageAt(root, poPathDependency)
        pkg.sourceKind = dskPath
        pkg.sourcePath = normalizeDependencyPath(
          relativePath(root, declaring.root).replace('\\', '/'), "path",
          declaring.manifestPath)
        pkg.id = packageInstanceId(pkg, context.workspaceRoot.root,
                                   context.workspaceRoot, declaring)
        candidateCache[cacheKey] = @[pkg]
      result.add pkg
    of dskRegistry:
      result = registryCandidates(dep)
    of dskGit:
      if manager.gitSourceAdapter == nil:
        raisePackageError(pecNotFound,
          "git source adapter is not configured for " & dep.name,
          [declaring.manifestPath, "dependency alias: " & dep.alias])
      let checkout = manager.gitSourceAdapter(
        dep.git, dep.gitSelectorKind, dep.gitSelector, request.offline)
      if checkout.canonicalUrl != dep.git:
        raisePackageError(pecIdentityMismatch,
          "git adapter returned a different canonical source URL",
          ["expected: " & dep.git, "actual: " & checkout.canonicalUrl])
      let commit = canonicalGitCommit(checkout.commit, declaring.manifestPath)
      if dep.gitSelectorKind == "commit" and
          canonicalGitCommit(dep.gitSelector, declaring.manifestPath) != commit:
        raisePackageError(pecIdentityMismatch,
          "git adapter returned a different commit than the manifest pin",
          ["expected: " & dep.gitSelector, "actual: " & commit])
      let root = normalizedPath(absolutePath(checkout.root))
      if not fileExists(root / ManifestFileName):
        raisePackageError(pecNotFound,
          "git checkout has no " & ManifestFileName, [root, dep.git])
      let pkg = loadPackageAt(root, poRegistrySource)
      pkg.sourceKind = dskGit
      pkg.sourceName = dep.git
      pkg.sourcePath = commit
      pkg.treeDigest = sourceTreeDigest(pkg)
      pkg.id = packageInstanceId(pkg, context.workspaceRoot.root,
                                 context.workspaceRoot)
      result.add pkg
    var compatible: seq[Package]
    for pkg in result:
      if pkg.name != dep.name:
        raisePackageError(pecIdentityMismatch,
          "dependency " & dep.alias & " expected " & dep.name & " but found " &
          pkg.name, [pkg.manifestPath])
      if dep.constraint.len == 0 or
          matchesConstraint(pkg.version, dep.constraint, declaring.manifestPath):
        compatible.add pkg
    result = compatible

  var workspaceRoots: seq[Package]
  if context.active.kind == pkAdHoc:
    workspaceRoots.add context.active
  else:
    for _, pkg in context.membersByName:
      workspaceRoots.add pkg
    workspaceRoots.sort(proc (a, b: Package): int =
      if a.root == context.workspaceRoot.root: return -1
      if b.root == context.workspaceRoot.root: return 1
      cmp(a.root, b.root))
  for pkg in workspaceRoots:
    pkg.sourceKind = dskWorkspace
    pkg.sourcePath = relativePath(pkg.root, context.workspaceRoot.root)
      .replace('\\', '/')
    pkg.id = packageInstanceId(pkg, context.workspaceRoot.root,
                               context.workspaceRoot)
  var initial: SolverState
  for pkg in workspaceRoots:
    initial.selected[pkg.id] = pkg
    # Every workspace member is an independently authorable lock root. Its
    # development graph is solved into the one stable lock, while development
    # edges of consumed dependencies never propagate.
    initial.activatePackage(pkg, @[], true, true)
  var best: SolverState
  var hasBest = false
  var failureChain: seq[string]

  proc search(state: SolverState) =
    if state.pending.len == 0:
      if betterSolution(state, best, hasBest, preserved):
        best = cloneState(state)
        hasBest = true
      return
    let requirement = state.pending[0]
    let importer = state.selected[requirement.importerId]
    let candidates = candidatesFor(importer, requirement.dep)
    if candidates.len == 0:
      failureChain.add importer.name & " --" & requirement.dep.alias & "--> " &
        requirement.dep.name & " " & requirement.dep.constraint
      return
    for candidate in candidates:
      if state.createsCycle(importer.id, candidate.id):
        failureChain.add(importer.name & " --" & requirement.dep.alias &
          "--> " & candidate.name & "@" & candidate.version &
          " would create a dependency cycle")
        continue
      var singletonConflict = false
      var conflictingSingleton = ""
      for _, selected in state.selected:
        if selected.name == candidate.name and selected.id != candidate.id and
            (candidate.singleton or selected.singleton):
          singletonConflict = true
          conflictingSingleton = selected.id
          break
      if singletonConflict:
        failureChain.add(importer.name & " --" & requirement.dep.alias &
          "--> " & candidate.id & " conflicts with singleton " &
          conflictingSingleton)
        continue
      var next = cloneState(state)
      next.pending.delete(0)
      next.edges[(importer.id, requirement.dep.alias)] = candidate.id
      if not next.selected.hasKey(candidate.id):
        next.selected[candidate.id] = candidate
      next.activatePackage(candidate, requirement.dep.features,
                           requirement.dep.defaultFeatures, false)
      search(next)

  search(initial)
  if not hasBest:
    failureChain.sort()
    raisePackageError(pecVersionConflict,
      "no package graph satisfies all dependency requirements", failureChain)

  result = Resolution(workspaceRoot: context.workspaceRoot.root,
                      rootManifestDigest: context.workspaceRoot.manifestDigest,
                      workspaceDigest: contextWorkspaceDigest(context),
                      activePackageId: context.active.id,
                      packagesById: initTable[string, Package]())
  for pkg in workspaceRoots:
    result.rootPackageIds.add pkg.id
  var finalIds = initTable[string, string]()
  for id, pkg in best.selected:
    pkg.dependencyEdges.clear()
    pkg.dependencyEdgeScopes.clear()
    pkg.selectedFeatures = @[]
    for feature in best.features.getOrDefault(id):
      pkg.selectedFeatures.add feature
    pkg.selectedFeatures.sort()
    if pkg.sourceKind == dskRegistry:
      pkg.treeDigest = sourceTreeDigest(pkg)
      pkg.archiveDigest = sourcePackageDigest(pkg, pkg.treeDigest)
      pkg.id = packageInstanceId(pkg, context.workspaceRoot.root,
                                 context.workspaceRoot)
    finalIds[id] = pkg.id
  for id, pkg in best.selected:
    result.packagesById[finalIds[id]] = pkg
  for edge, target in best.edges:
    let importer = result.packagesById[finalIds[edge.importer]]
    importer.dependencyEdges[edge.alias] = finalIds[target]
    for declaration in importer.dependencies:
      if declaration.alias == edge.alias:
        importer.dependencyEdgeScopes[edge.alias] = declaration.scope
        break
  var registryNames: seq[string]
  for name in consultedRegistries:
    registryNames.add name
  registryNames.sort()
  for name in registryNames:
    var records: seq[string]
    for _, packages in candidateCache:
      for pkg in packages:
        if pkg.sourceName == name:
          records.add pkg.name & "@" & pkg.version & "#" &
            pkg.manifestDigest & "#" & pkg.treeDigest & "#" &
            pkg.archiveDigest & "#yanked=" & $pkg.yanked
    records.sort()
    var registryUrl = ""
    for adapter in manager.registries:
      if adapter.name == name:
        registryUrl = adapter.url
        break
    result.registrySnapshots.add RegistrySnapshot(
      name: name,
      url: registryUrl,
      indexDigest: "sha256:" & sha256Hex(records.join("\n")))

proc lockNode(value: Value, head, context: string): Value
proc lockProp(node: Value, name, context: string): Value

proc atomicPackageWrite(path, content: string) =
  createDir(parentDir(path))
  let temp = path & ".tmp-" & $getCurrentProcessId()
  if fileExists(temp):
    removeFile(temp)
  writeFile(temp, content)
  try:
    moveFile(temp, path)
  except OSError:
    if not fileExists(path):
      raise
    if fileExists(temp):
      removeFile(temp)

proc acquireStoreGcBarrier(storeRoot: string): ProcessFileLock =
  try:
    result = acquireProcessFileLock(storeRoot / "locks" / "gc.lock")
  except IOError as error:
    raisePackageError(pecStoreBusy, error.msg, [storeRoot])

proc writeProjectStoreRoot(storeRoot: string, resolution: Resolution,
                           graph: MaterializedGraph) =
  if resolution.lockDigest.len == 0:
    return
  var digests: seq[string]
  for _, pkg in graph.packagesById:
    if pkg.sourceKind in {dskRegistry, dskGit} and
        pkg.treeDigest notin digests:
      digests.add pkg.treeDigest
  digests.sort()
  var entries = initPropTable()
  entries["root_format"] = newInt(1)
  entries["workspace_root"] = newStr(resolution.workspaceRoot)
  entries["lock_path"] = newStr(resolution.workspaceRoot /
                                "package.gene.lock")
  entries["lock_digest"] = newStr(resolution.lockDigest)
  var digestValues: seq[Value]
  for digest in digests:
    digestValues.add newStr(digest)
  entries["tree_digests"] = newList(digestValues)
  let receiptPath = storeRoot / "roots" / "projects" /
    (sha256Hex(resolution.workspaceRoot) & ".gene")
  atomicPackageWrite(receiptPath, newMap(entries).print() & "\n")

proc installationRootPath(storeRoot: string,
                          resolution: Resolution): string =
  storeRoot / "roots" / "installations" /
    ($getCurrentProcessId() & "-" &
     sha256Hex(resolution.workspaceRoot & "\0" & resolution.lockDigest)[0 .. 15] &
     ".gene")

proc registerInstallationRoot(storeRoot: string,
                              resolution: Resolution): string =
  ## Register every intended immutable object while briefly holding the GC
  ## barrier. Installation and verification then proceed concurrently across
  ## unrelated projects; GC sees the receipt and keeps all in-flight objects.
  var digests: seq[string]
  for _, pkg in resolution.packagesById:
    if pkg.sourceKind in {dskRegistry, dskGit} and
        pkg.treeDigest notin digests:
      digests.add pkg.treeDigest
  digests.sort()
  var values: seq[Value]
  for digest in digests:
    values.add newStr(digest)
  var entries = initPropTable()
  entries["root_format"] = newInt(1)
  entries["process_id"] = newInt(getCurrentProcessId())
  entries["tree_digests"] = newList(values)
  result = installationRootPath(storeRoot, resolution)
  let barrier = acquireStoreGcBarrier(storeRoot)
  try:
    atomicPackageWrite(result, newMap(entries).print() & "\n")
  finally:
    barrier.release()

proc unregisterInstallationRoot(storeRoot, receiptPath: string) =
  if receiptPath.len == 0 or not fileExists(receiptPath):
    return
  let barrier = acquireStoreGcBarrier(storeRoot)
  try:
    if fileExists(receiptPath):
      removeFile(receiptPath)
  finally:
    barrier.release()

proc publishProjectRoot(storeRoot: string, resolution: Resolution,
                        graph: MaterializedGraph,
                        installationReceipt: string) =
  let barrier = acquireStoreGcBarrier(storeRoot)
  try:
    writeProjectStoreRoot(storeRoot, resolution, graph)
    if fileExists(installationReceipt):
      removeFile(installationReceipt)
  finally:
    barrier.release()

proc sync*(manager: PackageManager, resolution: Resolution,
           policy: SyncPolicy): MaterializedGraph =
  ## Materialize immutable nodes transactionally. A matching vendor object is
  ## authoritative; corruption is reported instead of falling through to the
  ## user store.
  let storeRoot =
    if policy.userStoreRoot.len > 0:
      normalizedPath(absolutePath(policy.userStoreRoot))
    else:
      manager.userStoreRoot
  if policy.locked and resolution.lockDigest.len == 0:
    raisePackageError(pecVersionMismatch,
      "locked synchronization requires package.gene.lock")
  let installationReceipt = registerInstallationRoot(storeRoot, resolution)
  var installationPublished = false
  defer:
    if not installationPublished:
      unregisterInstallationRoot(storeRoot, installationReceipt)
  result = MaterializedGraph(workspaceRoot: resolution.workspaceRoot,
                             lockDigest: resolution.lockDigest,
                             activePackageId: resolution.activePackageId,
                             developmentPackageId: resolution.activePackageId,
                             rootPackageIds: resolution.rootPackageIds,
                             packagesById: initTable[string, Package]())
  let vendorRoot = resolution.workspaceRoot / "vendor" / "packages"
  let vendorIndexPath = vendorRoot / "vendor.gene.lock"
  var vendorPaths = initTable[string, string]()
  var vendorSources = initTable[string, string]()
  var vendorIndexLoaded = false
  if fileExists(vendorIndexPath):
    let forms = readPackageData(readFile(vendorIndexPath), vendorIndexPath)
    if forms.len != 1 or forms[0].kind != vkMap:
      raisePackageError(pecManifestInvalid,
        "vendor lock must contain exactly one map", [vendorIndexPath])
    let entries = forms[0].mapEntries
    rejectUnknown(entries, ["vendor_format", "root_lock_digest", "packages"],
                  "vendor lock", vendorIndexPath)
    for field in ["vendor_format", "root_lock_digest", "packages"]:
      if not entries.hasKey(field):
        raisePackageError(pecManifestInvalid,
          "vendor lock requires ^" & field, [vendorIndexPath])
    if entries["vendor_format"].kind != vkInt or
        entries["vendor_format"].intVal != 1:
      raisePackageError(pecManifestInvalid,
        "unsupported vendor lock format", [vendorIndexPath])
    let lockedDigest = manifestString(entries["root_lock_digest"],
                                      "root_lock_digest", vendorIndexPath)
    if resolution.lockDigest.len > 0 and lockedDigest != resolution.lockDigest:
      raisePackageError(pecIdentityMismatch,
        "vendor snapshot belongs to a different root lock",
        ["expected: " & resolution.lockDigest,
         "found: " & lockedDigest, vendorIndexPath])
    if entries["packages"].kind != vkList:
      raisePackageError(pecManifestInvalid,
        "vendor lock ^packages must be a list", [vendorIndexPath])
    for value in entries["packages"].listItems:
      let node = lockNode(value, "vendored_package", "vendored package")
      rejectUnknown(node.props, ["id", "source", "path"], "vendored package",
                    vendorIndexPath)
      if node.body.len != 0:
        raisePackageError(pecManifestInvalid,
          "vendored_package has no positional values", [vendorIndexPath])
      let id = manifestString(lockProp(node, "id", "vendored package"),
                              "id", vendorIndexPath)
      let sourceValue = lockProp(node, "source", "vendored package")
      if sourceValue.kind != vkSymbol or sourceValue.symVal notin
          ["object", "workspace", "path"]:
        raisePackageError(pecManifestInvalid,
          "vendored package ^source must be object, workspace, or path",
          [vendorIndexPath])
      let rawPath = manifestString(
        lockProp(node, "path", "vendored package"), "path", vendorIndexPath)
      let path =
        case sourceValue.symVal
        of "object": normalizeRelativePath(rawPath, "path", vendorIndexPath)
        of "workspace":
          if rawPath == ".": rawPath
          else: normalizeRelativePath(rawPath, "path", vendorIndexPath)
        of "path": normalizeDependencyPath(rawPath, "path", vendorIndexPath)
        else: rawPath
      if vendorPaths.hasKey(id):
        raisePackageError(pecManifestInvalid,
          "duplicate vendored package id: " & id, [vendorIndexPath])
      vendorPaths[id] = path
      vendorSources[id] = sourceValue.symVal
    vendorIndexLoaded = true

  proc digestPath(root, digest: string): string =
    let hex = digest.replace("sha256:", "")
    if hex.len < 3:
      raisePackageError(pecManifestInvalid, "invalid tree digest: " & digest)
    root / "objects" / "sha256" / hex[0 .. 1] / hex[2 .. ^1]

  proc vendorPath(pkg: Package): string =
    let parts = pkg.name.split('/')
    resolution.workspaceRoot / "vendor" / "packages" / parts[0] / parts[1] /
      pkg.version / pkg.treeDigest.replace("sha256:", "")

  if vendorIndexLoaded:
    if vendorPaths.len != resolution.packagesById.len:
      raisePackageError(pecIdentityMismatch,
        "vendor snapshot package set disagrees with the root lock",
        [vendorIndexPath])
    for id, pkg in resolution.packagesById:
      if not vendorPaths.hasKey(id):
        raisePackageError(pecIdentityMismatch,
          "vendor snapshot omits a locked package instance", [id,
          vendorIndexPath])
      let expectedSource =
        case pkg.sourceKind
        of dskWorkspace: "workspace"
        of dskPath: "path"
        else: "object"
      let expectedPath =
        if expectedSource == "object":
          relativePath(vendorPath(pkg), vendorRoot).replace('\\', '/')
        else:
          pkg.sourcePath
      if vendorSources[id] != expectedSource or vendorPaths[id] != expectedPath:
        raisePackageError(pecIdentityMismatch,
          "vendor snapshot location disagrees with the locked package",
          [id, vendorIndexPath])

  proc verifiedPackageAt(path: string, expected: Package,
                         origin: PackageOrigin): Package =
    if not fileExists(path / ManifestFileName):
      raisePackageError(pecNotFound,
        "package object has no " & ManifestFileName, [path])
    result = loadPackageAt(path, origin)
    if result.name != expected.name or result.version != expected.version or
        result.manifestDigest != expected.manifestDigest:
      raisePackageError(pecIdentityMismatch,
        "materialized package identity does not match the resolution",
        ["expected: " & expected.name & "@" & expected.version,
         "found: " & result.name & "@" & result.version, path])
    result.sourceKind = expected.sourceKind
    result.sourceName = expected.sourceName
    result.sourcePath = expected.sourcePath
    result.treeDigest = sourceTreeDigest(result)
    if result.treeDigest != expected.treeDigest:
      raisePackageError(pecIdentityMismatch,
        "materialized package tree digest does not match the resolution",
        ["expected: " & expected.treeDigest,
         "actual: " & result.treeDigest, path])
    result.archiveDigest = expected.archiveDigest
    result.id = expected.id
    result.selectedFeatures = expected.selectedFeatures
    result.yanked = expected.yanked
    result.dependencyEdges = expected.dependencyEdges
    result.dependencyEdgeScopes = expected.dependencyEdgeScopes

  proc copyTree(source, target: string) =
    let sourcePackage = loadPackageAt(source, poRegistrySource)
    createDir(parentDir(target))
    materializeSourceTree(sourcePackage, target)

  proc immutableSource(expected: Package): Package =
    case expected.sourceKind
    of dskRegistry:
      let parts = expected.name.split('/')
      for adapter in manager.registries:
        if adapter.name != expected.sourceName:
          continue
        let source = adapter.root / parts[0] / parts[1] / expected.version
        if not fileExists(source / ManifestFileName):
          continue
        result = verifiedPackageAt(source, expected, poRegistrySource)
        let archiveDigest = sourcePackageDigest(result, result.treeDigest)
        if expected.archiveDigest.len > 0 and
            archiveDigest != expected.archiveDigest:
          raisePackageError(pecIdentityMismatch,
            "registry source package digest does not match the resolution",
            ["expected: " & expected.archiveDigest,
             "actual: " & archiveDigest, source])
        result.archiveDigest = archiveDigest
        return
      raisePackageError(pecNotFound,
        "locked registry object is unavailable",
        [expected.name & "@" & expected.version,
         "registry: " & expected.sourceName])
    of dskGit:
      if manager.gitSourceAdapter == nil:
        raisePackageError(pecNotFound,
          "git source adapter is not configured for locked source",
          [expected.id, expected.sourceName])
      let checkout = manager.gitSourceAdapter(
        expected.sourceName, "commit", expected.sourcePath, false)
      let commit = canonicalGitCommit(checkout.commit, expected.manifestPath)
      if checkout.canonicalUrl != expected.sourceName or
          commit != expected.sourcePath:
        raisePackageError(pecIdentityMismatch,
          "git adapter did not reacquire the exact locked source",
          ["expected: " & expected.sourceName & "#" & expected.sourcePath,
           "actual: " & checkout.canonicalUrl & "#" & commit])
      result = verifiedPackageAt(
        normalizedPath(absolutePath(checkout.root)), expected,
        poRegistrySource)
    else:
      raisePackageError(pecNotFound,
        "no acquisition adapter is configured for locked source",
        [expected.id, $expected.sourceKind])

  proc insertUserObject(pkg: Package): Package =
    let target = digestPath(storeRoot, pkg.treeDigest)
    let objectLockPath = storeRoot / "locks" / "objects" /
      (pkg.treeDigest.replace("sha256:", "") & ".lock")
    var objectLock: ProcessFileLock
    try:
      objectLock = acquireProcessFileLock(objectLockPath)
    except IOError as error:
      raisePackageError(pecStoreBusy, error.msg, [target])
    try:
      if dirExists(target):
        protectMaterializedTree(target)
        result = verifiedPackageAt(target, pkg, poUserStore)
        return
      var source = pkg
      if source.root.len == 0 or not fileExists(source.root / ManifestFileName):
        source = immutableSource(pkg)
      let tempRoot = storeRoot / "tmp"
      createDir(tempRoot)
      let temp = tempRoot / (pkg.treeDigest.replace("sha256:", "") &
        ".partial-" & $getCurrentProcessId())
      if dirExists(temp):
        makeMaterializedTreeWritable(temp)
        removeDir(temp)
      copyTree(source.root, temp)
      discard verifiedPackageAt(temp, pkg, poUserStore)
      createDir(parentDir(target))
      try:
        moveDir(temp, target)
      except OSError:
        if not dirExists(target):
          raise
        if dirExists(temp):
          makeMaterializedTreeWritable(temp)
          removeDir(temp)
      protectMaterializedTree(target)
      result = verifiedPackageAt(target, pkg, poUserStore)
    finally:
      objectLock.release()

  if policy.offline:
    var missing: seq[string]
    for _, pkg in resolution.packagesById:
      if pkg.sourceKind in {dskWorkspace, dskPath}:
        continue
      if dirExists(vendorPath(pkg)) or
          dirExists(digestPath(storeRoot, pkg.treeDigest)) or
          (pkg.root.len > 0 and fileExists(pkg.root / ManifestFileName)):
        continue
      missing.add pkg.name & "@" & pkg.version & " [" & pkg.id & "]"
    if missing.len > 0:
      missing.sort()
      raisePackageError(pecNotFound,
        "offline synchronization is missing locked package objects", missing)

  for id, pkg in resolution.packagesById:
    if pkg.sourceKind in {dskWorkspace, dskPath}:
      result.packagesById[id] = pkg
      continue
    let vendored = vendorPath(pkg)
    if dirExists(vendored):
      if resolution.lockDigest.len > 0 and not vendorIndexLoaded:
        raisePackageError(pecIdentityMismatch,
          "vendored package exists without vendor.gene.lock", [vendored])
      if vendorIndexLoaded:
        let relative = relativePath(vendored, vendorRoot).replace('\\', '/')
        if vendorSources[id] != "object" or vendorPaths[id] != relative:
          raisePackageError(pecIdentityMismatch,
            "vendored package path disagrees with vendor.gene.lock",
            ["package: " & id, vendored, vendorIndexPath])
      result.packagesById[id] = verifiedPackageAt(
        vendored, pkg, poApplicationStore)
    else:
      result.packagesById[id] = insertUserObject(pkg)

  # A lock authenticates graph identity, but it must not be able to invent an
  # alias that the acquired manifest never declared. Validate after every
  # immutable node has been materialized so transitive registry manifests get
  # the same treatment as live workspace/path manifests.
  for _, importer in result.packagesById:
    manager.validateMaterializedEdges(result, importer,
      importer.id in resolution.rootPackageIds, resolution.workspaceRoot)
  publishProjectRoot(storeRoot, resolution, result, installationReceipt)
  installationPublished = true

proc geneQuoted(text: string): string =
  result = "\""
  for ch in text:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add ch
  result.add '"'

proc edgeScope(pkg: Package, alias: string): DependencyScope =
  for dep in pkg.dependencies:
    if dep.alias == alias:
      return dep.scope
  dsRuntime

proc resolutionLockText*(resolution: Resolution): string =
  var text = "{\n  ^lock_format 1\n"
  text.add "  ^root_manifest_digest " &
    geneQuoted(resolution.rootManifestDigest) & "\n"
  text.add "  ^workspace_digest " & geneQuoted(resolution.workspaceDigest) &
    "\n  ^registry_snapshots ["
  var snapshots = resolution.registrySnapshots
  snapshots.sort(proc (a, b: RegistrySnapshot): int = cmp(a.name, b.name))
  for snapshot in snapshots:
    text.add "\n    (registry " & geneQuoted(snapshot.name) & " ^url " &
      geneQuoted(snapshot.url) & " ^index_digest " &
      geneQuoted(snapshot.indexDigest) & ")"
  text.add "\n  ]\n  ^roots ["
  var roots = resolution.rootPackageIds
  roots.sort()
  for id in roots:
    text.add " " & geneQuoted(id)
  text.add "]\n  ^packages ["
  var ids: seq[string]
  for id in resolution.packagesById.keys:
    ids.add id
  ids.sort()
  for id in ids:
    let pkg = resolution.packagesById[id]
    text.add "\n    (locked_package\n      ^id " & geneQuoted(pkg.id) &
      "\n      ^name " & geneQuoted(pkg.name) &
      "\n      ^version " & geneQuoted(pkg.version) &
      "\n      ^manifest_digest " & geneQuoted(pkg.manifestDigest) &
      "\n      ^source "
    case pkg.sourceKind
    of dskWorkspace:
      text.add "(workspace ^path " & geneQuoted(pkg.sourcePath) & ")"
    of dskPath:
      text.add "(path ^path " & geneQuoted(pkg.sourcePath) & ")"
    of dskRegistry:
      text.add "(registry " & geneQuoted(pkg.sourceName) &
        " ^archive_digest " & geneQuoted(pkg.archiveDigest) &
        " ^tree_digest " & geneQuoted(pkg.treeDigest) & ")"
    of dskGit:
      text.add "(git " & geneQuoted(pkg.sourceName) &
        " ^commit " & geneQuoted(pkg.sourcePath) &
        " ^tree_digest " & geneQuoted(pkg.treeDigest) & ")"
    text.add "\n      ^features ["
    var selectedFeatures = pkg.selectedFeatures
    selectedFeatures.sort()
    for feature in selectedFeatures:
      text.add " " & feature
    text.add "]\n      ^dependencies {"
    var aliases: seq[string]
    for alias in pkg.dependencyEdges.keys:
      aliases.add alias
    aliases.sort()
    for alias in aliases:
      text.add "\n        ^" & alias & " (locked_edge ^scope " &
        $pkg.edgeScope(alias) & " ^target " &
        geneQuoted(pkg.dependencyEdges[alias]) & ")"
    text.add "\n      }"
    if pkg.sourceKind in {dskRegistry, dskGit}:
      text.add "\n      ^yanked " & (if pkg.yanked: "true" else: "false")
    text.add "\n      ^compatibility (compatibility ^package_format 1 " &
      "^runtime \">=0.1.0 <0.2.0\"))"
  text.add "\n  ]\n}\n"
  text

proc writeResolutionLock*(resolution: Resolution, path = ""): string =
  result =
    if path.len > 0: normalizedPath(absolutePath(path))
    else: resolution.workspaceRoot / "package.gene.lock"
  let source = resolutionLockText(resolution)
  let forms = readPackageData(source, result)
  resolution.lockDigest = canonicalDigest(forms[0])
  createDir(parentDir(result))
  let temp = result & ".tmp"
  writeFile(temp, source)
  moveFile(temp, result)

proc lockNode(value: Value, head, context: string): Value =
  if value.kind != vkNode or value.head.kind != vkSymbol or
      value.head.symVal != head:
    raisePackageError(pecManifestInvalid,
      context & " must be a (" & head & " ...) node")
  value

proc lockProp(node: Value, name, context: string): Value =
  if not node.props.hasKey(name):
    raisePackageError(pecManifestInvalid,
      context & " requires ^" & name)
  node.props[name]

proc requireSha256(value, field, path: string) =
  if not value.startsWith("sha256:") or value.len != 71:
    raisePackageError(pecManifestInvalid,
      "^" & field & " must be a sha256 digest", [path])
  for ch in value[7 .. ^1]:
    if ch notin {'0' .. '9', 'a' .. 'f'}:
      raisePackageError(pecManifestInvalid,
        "^" & field & " must use lowercase hexadecimal", [path])

proc loadResolutionLock*(manager: PackageManager,
                         startDir: string): Resolution =
  let context = discoverPackageContext(startDir)
  let lockPath = context.workspaceRoot.root / "package.gene.lock"
  if not fileExists(lockPath):
    raisePackageError(pecNotFound, "package lockfile is missing", [lockPath])
  let forms = readPackageData(readFile(lockPath), lockPath)
  if forms.len != 1 or forms[0].kind != vkMap:
    raisePackageError(pecManifestInvalid,
      "lockfile must contain exactly one map datum", [lockPath])
  let lock = forms[0]
  let entries = lock.mapEntries
  rejectUnknown(entries,
    ["lock_format", "root_manifest_digest", "workspace_digest",
     "registry_snapshots", "roots", "packages"], "lockfile", lockPath)
  for field in ["lock_format", "root_manifest_digest", "workspace_digest",
                "registry_snapshots", "roots", "packages"]:
    if not entries.hasKey(field):
      raisePackageError(pecManifestInvalid,
        "lockfile requires ^" & field, [lockPath])
  if entries["lock_format"].kind != vkInt or
      entries["lock_format"].intVal != 1:
    raisePackageError(pecManifestInvalid,
      "unsupported lock format; expected ^lock_format 1", [lockPath])
  result = Resolution(workspaceRoot: context.workspaceRoot.root,
                      packagesById: initTable[string, Package](),
                      lockDigest: canonicalDigest(lock))
  result.rootManifestDigest = manifestString(entries["root_manifest_digest"],
                                             "root_manifest_digest", lockPath)
  result.workspaceDigest = manifestString(entries["workspace_digest"],
                                          "workspace_digest", lockPath)
  if result.rootManifestDigest != context.workspaceRoot.manifestDigest:
    raisePackageError(pecVersionMismatch,
      "root manifest disagrees with package.gene.lock",
      ["expected: " & result.rootManifestDigest,
       "actual: " & context.workspaceRoot.manifestDigest, lockPath])
  let actualWorkspaceDigest = contextWorkspaceDigest(context)
  if result.workspaceDigest != actualWorkspaceDigest:
    raisePackageError(pecVersionMismatch,
      "workspace membership disagrees with package.gene.lock",
      ["expected: " & result.workspaceDigest,
       "actual: " & actualWorkspaceDigest, lockPath])

  if entries["registry_snapshots"].kind != vkList:
    raisePackageError(pecManifestInvalid,
      "^registry_snapshots must be a list", [lockPath])
  var registryNames = initHashSet[string]()
  var registryUrls = initHashSet[string]()
  var registryUrlByName = initTable[string, string]()
  for value in entries["registry_snapshots"].listItems:
    let node = lockNode(value, "registry", "registry snapshot")
    rejectUnknown(node.props, ["url", "index_digest"], "registry snapshot",
                  lockPath)
    if node.body.len != 1 or node.body[0].kind != vkString:
      raisePackageError(pecManifestInvalid,
        "registry snapshot requires one registry name string", [lockPath])
    let name = node.body[0].strVal
    validateLocalName(name, "registry name", lockPath)
    let url = manifestString(lockProp(node, "url", "registry snapshot"),
                             "url", lockPath)
    let digest = manifestString(
      lockProp(node, "index_digest", "registry snapshot"), "index_digest",
      lockPath)
    requireSha256(digest, "index_digest", lockPath)
    if name in registryNames or url in registryUrls:
      raisePackageError(pecManifestInvalid,
        "duplicate registry name or URL in lockfile", [lockPath])
    registryNames.incl name
    registryUrls.incl url
    registryUrlByName[name] = url
    result.registrySnapshots.add RegistrySnapshot(name: name, url: url,
                                                   indexDigest: digest)

  if entries["packages"].kind != vkList:
    raisePackageError(pecManifestInvalid,
      "^packages must be a list", [lockPath])
  var edgeValues = initTable[string, Value]()
  for value in entries["packages"].listItems:
    let node = lockNode(value, "locked_package", "locked package")
    rejectUnknown(node.props,
      ["id", "name", "version", "manifest_digest", "source", "features",
       "dependencies", "yanked", "compatibility"], "locked package", lockPath)
    if node.body.len != 0:
      raisePackageError(pecManifestInvalid,
        "locked_package has no positional values", [lockPath])
    for field in ["id", "name", "version", "manifest_digest", "source",
                  "features", "dependencies", "compatibility"]:
      discard lockProp(node, field, "locked package")
    let id = manifestString(node.props["id"], "id", lockPath)
    if result.packagesById.hasKey(id):
      raisePackageError(pecManifestInvalid,
        "duplicate locked package id: " & id, [lockPath])
    let name = manifestString(node.props["name"], "name", lockPath)
    let version = manifestString(node.props["version"], "version", lockPath)
    validatePackageName(name, lockPath)
    discard parseSemVersion(version, lockPath)
    let manifestDigest = manifestString(node.props["manifest_digest"],
                                        "manifest_digest", lockPath)
    requireSha256(manifestDigest, "manifest_digest", lockPath)
    let source = node.props["source"]
    if source.kind != vkNode or source.head.kind != vkSymbol:
      raisePackageError(pecManifestInvalid,
        "locked package ^source must be a source node", [lockPath])
    var pkg: Package
    let sourceHead = source.head.symVal
    case sourceHead
    of "workspace":
      rejectUnknown(source.props, ["path"], "workspace source", lockPath)
      if source.body.len != 0:
        raisePackageError(pecManifestInvalid,
          "workspace source has no positional values", [lockPath])
      let rawRel = manifestString(
        lockProp(source, "path", "workspace source"), "path", lockPath)
      let rel =
        if rawRel == ".": rawRel
        else: normalizeRelativePath(rawRel, "path", lockPath)
      let packageRoot = normalizedPath(absolutePath(rel,
                                                    context.workspaceRoot.root))
      pkg = loadPackageAt(packageRoot, poWorkspace)
      pkg.sourceKind = dskWorkspace
      pkg.sourcePath = rel
      if pkg.name != name or pkg.version != version or
          pkg.manifestDigest != manifestDigest:
        raisePackageError(pecIdentityMismatch,
          "mutable package identity disagrees with the lockfile",
          [id, pkg.manifestPath])
    of "path":
      rejectUnknown(source.props, ["path"], "path source", lockPath)
      if source.body.len != 0:
        raisePackageError(pecManifestInvalid,
          "path source has no positional values", [lockPath])
      let rel = normalizeDependencyPath(manifestString(
        lockProp(source, "path", "path source"), "path", lockPath),
        "path", lockPath)
      # The locator is relative to the declaring package, which is known only
      # after dependency edges have been parsed. Hydrate and verify this node
      # during the root graph walk below.
      pkg = Package(kind: pkRegular, format: ManifestFormat, name: name,
                    version: version, manifestDigest: manifestDigest,
                    sourceKind: dskPath, sourcePath: rel, buildRecipes: NIL)
    of "registry":
      rejectUnknown(source.props, ["archive_digest", "tree_digest"],
                    "registry source", lockPath)
      if source.body.len != 1 or source.body[0].kind != vkString:
        raisePackageError(pecManifestInvalid,
          "registry source requires one registry name string", [lockPath])
      pkg = Package(kind: pkRegular, format: ManifestFormat, name: name,
                    version: version, manifestDigest: manifestDigest,
                    sourceKind: dskRegistry,
                    sourceName: source.body[0].strVal,
                    buildRecipes: NIL)
      validateLocalName(pkg.sourceName, "registry name", lockPath)
      if not registryUrlByName.hasKey(pkg.sourceName):
        raisePackageError(pecManifestInvalid,
          "locked package names an absent registry snapshot: " &
          pkg.sourceName, [lockPath])
      pkg.sourcePath = registryUrlByName[pkg.sourceName]
      pkg.archiveDigest = manifestString(
        lockProp(source, "archive_digest", "registry source"),
        "archive_digest", lockPath)
      pkg.treeDigest = manifestString(
        lockProp(source, "tree_digest", "registry source"), "tree_digest",
        lockPath)
      requireSha256(pkg.archiveDigest, "archive_digest", lockPath)
      requireSha256(pkg.treeDigest, "tree_digest", lockPath)
    of "git":
      rejectUnknown(source.props, ["commit", "tree_digest", "archive_digest"],
                    "git source", lockPath)
      if source.body.len != 1 or source.body[0].kind != vkString:
        raisePackageError(pecManifestInvalid,
          "git source requires one canonical URL string", [lockPath])
      pkg = Package(kind: pkRegular, format: ManifestFormat, name: name,
                    version: version, manifestDigest: manifestDigest,
                    sourceKind: dskGit,
                    sourceName: canonicalPackageUrl(source.body[0].strVal,
                                                    lockPath),
                    buildRecipes: NIL)
      if pkg.sourceName != source.body[0].strVal:
        raisePackageError(pecManifestInvalid,
          "git source URL is not in canonical form", [lockPath])
      pkg.sourcePath = canonicalGitCommit(manifestString(
        lockProp(source, "commit", "git source"), "commit", lockPath),
        lockPath)
      pkg.treeDigest = manifestString(
        lockProp(source, "tree_digest", "git source"), "tree_digest",
        lockPath)
      requireSha256(pkg.treeDigest, "tree_digest", lockPath)
      if source.props.hasKey("archive_digest"):
        pkg.archiveDigest = manifestString(source.props["archive_digest"],
                                           "archive_digest", lockPath)
        requireSha256(pkg.archiveDigest, "archive_digest", lockPath)
    else:
      raisePackageError(pecManifestInvalid,
        "unsupported locked source kind: " & sourceHead, [lockPath])
    pkg.id = id
    if pkg.sourceKind in {dskRegistry, dskGit, dskWorkspace}:
      let expectedId = packageInstanceId(pkg, context.workspaceRoot.root,
                                         context.workspaceRoot)
      if id != expectedId:
        raisePackageError(pecIdentityMismatch,
          "locked package ID disagrees with canonical source identity",
          ["expected: " & expectedId, "found: " & id, lockPath])
    if node.props["features"].kind != vkList:
      raisePackageError(pecManifestInvalid,
        "locked package ^features must be a list", [lockPath])
    pkg.selectedFeatures = manifestNames(node.props["features"], "features",
                                         lockPath)
    if node.props.hasKey("yanked"):
      pkg.yanked = manifestBool(node.props["yanked"], "yanked", lockPath)
    if pkg.sourceKind in {dskRegistry, dskGit} and
        not node.props.hasKey("yanked"):
      raisePackageError(pecManifestInvalid,
        "immutable locked package requires ^yanked", [lockPath])
    if node.props["dependencies"].kind != vkMap:
      raisePackageError(pecManifestInvalid,
        "locked package ^dependencies must be a map", [lockPath])
    edgeValues[id] = node.props["dependencies"]
    let compatibility = lockNode(node.props["compatibility"], "compatibility",
                                 "locked compatibility")
    rejectUnknown(compatibility.props, ["package_format", "runtime", "compiler"],
                  "locked compatibility", lockPath)
    if compatibility.body.len != 0 or
        not compatibility.props.hasKey("package_format") or
        not compatibility.props.hasKey("runtime") or
        compatibility.props["package_format"].kind != vkInt or
        compatibility.props["package_format"].intVal != ManifestFormat or
        compatibility.props["runtime"].kind != vkString:
      raisePackageError(pecManifestInvalid,
        "locked compatibility requires package_format 1 and runtime",
        [lockPath])
    if not matchesConstraint("0.1.0",
        compatibility.props["runtime"].strVal, lockPath):
      raisePackageError(pecVersionMismatch,
        "locked package is incompatible with this Gene runtime", [id])
    if compatibility.props.hasKey("compiler") and
        compatibility.props["compiler"].kind != vkString:
      raisePackageError(pecManifestInvalid,
        "locked compatibility ^compiler must be a string", [lockPath])
    if compatibility.props.hasKey("compiler") and
        not matchesConstraint(PackageCompilerVersion,
                              compatibility.props["compiler"].strVal,
                              lockPath):
      raisePackageError(pecVersionMismatch,
        "locked package is incompatible with this Gene compiler", [id])
    result.packagesById[id] = pkg

  for id, value in edgeValues:
    for alias, edgeValue in value.mapEntries:
      validateLocalName(alias, "dependency alias", lockPath)
      let edge = lockNode(edgeValue, "locked_edge", "locked dependency edge")
      rejectUnknown(edge.props, ["scope", "target"], "locked dependency edge",
                    lockPath)
      if edge.body.len != 0:
        raisePackageError(pecManifestInvalid,
          "locked_edge has no positional values", [lockPath])
      let scopeValue = lockProp(edge, "scope", "locked dependency edge")
      if scopeValue.kind != vkSymbol or scopeValue.symVal notin
          ["runtime", "development", "build"]:
        raisePackageError(pecManifestInvalid,
          "locked edge scope must be runtime, development, or build",
          [lockPath])
      let lockedScope =
        case scopeValue.symVal
        of "development": dsDevelopment
        of "build": dsBuild
        else: dsRuntime
      let target = manifestString(
        lockProp(edge, "target", "locked dependency edge"), "target", lockPath)
      if not result.packagesById.hasKey(target):
        raisePackageError(pecManifestInvalid,
          "locked edge target is absent: " & target, [lockPath])
      let importer = result.packagesById[id]
      if importer.root.len > 0:
        var declaration: DependencyDecl
        var declared = false
        for dep in importer.dependencies:
          if dep.alias == alias:
            declaration = dep
            declared = true
            break
        if not declared:
          raisePackageError(pecIdentityMismatch,
            "lockfile contains an undeclared dependency alias: " & alias,
            [importer.manifestPath, lockPath])
        if $declaration.scope != scopeValue.symVal:
          raisePackageError(pecIdentityMismatch,
            "locked dependency scope disagrees with the manifest: " & alias,
            [importer.manifestPath, lockPath])
        let targetPkg = result.packagesById[target]
        if targetPkg.name != declaration.name or
            (declaration.constraint.len > 0 and not matchesConstraint(
              targetPkg.version, declaration.constraint,
              importer.manifestPath)) or
            targetPkg.sourceKind != declaration.sourceKind:
          raisePackageError(pecIdentityMismatch,
            "locked dependency target disagrees with the manifest: " & alias,
            [importer.manifestPath, target])
      result.packagesById[id].dependencyEdges[alias] = target
      result.packagesById[id].dependencyEdgeScopes[alias] = lockedScope

  if entries["roots"].kind != vkList:
    raisePackageError(pecManifestInvalid, "^roots must be a list", [lockPath])
  for value in entries["roots"].listItems:
    let id = manifestString(value, "roots", lockPath)
    if not result.packagesById.hasKey(id):
      raisePackageError(pecManifestInvalid,
        "locked root is absent from packages: " & id, [lockPath])
    if id in result.rootPackageIds:
      raisePackageError(pecManifestInvalid,
        "duplicate locked root: " & id, [lockPath])
    result.rootPackageIds.add id
  if result.rootPackageIds.len == 0:
    raisePackageError(pecManifestInvalid,
      "lockfile ^roots must not be empty", [lockPath])

  var expectedRoots = initHashSet[string]()
  for _, member in context.membersByName:
    member.sourceKind = dskWorkspace
    member.sourcePath = relativePath(member.root, context.workspaceRoot.root)
      .replace('\\', '/')
    member.id = packageInstanceId(member, context.workspaceRoot.root,
                                  context.workspaceRoot)
    expectedRoots.incl member.id
  if expectedRoots.len == 0 and context.active.kind == pkAdHoc:
    expectedRoots.incl context.active.id
  if expectedRoots.len != result.rootPackageIds.len:
    raisePackageError(pecIdentityMismatch,
      "lockfile roots disagree with workspace membership", [lockPath])
  for id in result.rootPackageIds:
    if id notin expectedRoots:
      raisePackageError(pecIdentityMismatch,
        "lockfile has a non-workspace root: " & id, [lockPath])

  var visiting = initHashSet[string]()
  var reached = initHashSet[string]()
  let lockedResolution = result

  proc hydratePath(targetId: string, importer: Package): Package =
    let locked = lockedResolution.packagesById[targetId]
    if locked.sourceKind != dskPath:
      return locked
    if importer.root.len == 0:
      raisePackageError(pecIdentityMismatch,
        "a path dependency cannot be declared by an unmaterialized package",
        [importer.id, targetId, lockPath])
    let packageRoot = normalizedPath(absolutePath(locked.sourcePath,
                                                  importer.root))
    if locked.root.len > 0:
      if locked.root != packageRoot:
        raisePackageError(pecIdentityMismatch,
          "one locked path package has multiple declaring roots",
          [targetId, locked.root, packageRoot, lockPath])
      return locked
    let live = loadPackageAt(packageRoot, poPathDependency)
    live.sourceKind = dskPath
    live.sourcePath = locked.sourcePath
    if live.name != locked.name or live.version != locked.version or
        live.manifestDigest != locked.manifestDigest:
      raisePackageError(pecIdentityMismatch,
        "mutable path package identity disagrees with the lockfile",
        [targetId, live.manifestPath])
    live.id = locked.id
    live.selectedFeatures = locked.selectedFeatures
    live.dependencyEdges = locked.dependencyEdges
    live.dependencyEdgeScopes = locked.dependencyEdgeScopes
    let expectedId = packageInstanceId(live, context.workspaceRoot.root,
                                       context.workspaceRoot, importer)
    if targetId != expectedId:
      raisePackageError(pecIdentityMismatch,
        "locked path package ID disagrees with its declaring package",
        ["expected: " & expectedId, "found: " & targetId, lockPath])
    lockedResolution.packagesById[targetId] = live
    live

  proc visit(id: string) =
    if id in visiting:
      raisePackageError(pecManifestInvalid,
        "lockfile package dependency graph contains a cycle", [id, lockPath])
    if id in reached:
      return
    visiting.incl id
    let importer = lockedResolution.packagesById[id]
    if importer.root.len > 0:
      var selected = initHashSet[string]()
      for feature in importer.selectedFeatures:
        selected.incl feature
      let expected = plannedDependencies(importer,
        expandedFeatures(importer, selected),
        id in lockedResolution.rootPackageIds)
      if expected.len != importer.dependencyEdges.len:
        raisePackageError(pecIdentityMismatch,
          "locked dependency set disagrees with the enabled manifest edges",
          [importer.manifestPath, lockPath])
      for declaration in expected:
        if not importer.dependencyEdges.hasKey(declaration.alias):
          raisePackageError(pecIdentityMismatch,
            "lockfile omits enabled dependency alias: " & declaration.alias,
            [importer.manifestPath, lockPath])
        let target = importer.dependencyEdges[declaration.alias]
        let lockedTarget = lockedResolution.packagesById[target]
        if declaration.sourceKind == dskPath and
            lockedTarget.sourcePath != declaration.path:
          raisePackageError(pecIdentityMismatch,
            "locked path locator disagrees with the manifest: " &
            declaration.alias,
            ["expected: " & declaration.path,
             "found: " & lockedTarget.sourcePath, lockPath])
    var aliases: seq[string]
    for alias in importer.dependencyEdges.keys:
      aliases.add alias
    aliases.sort()
    for alias in aliases:
      let target = importer.dependencyEdges[alias]
      discard hydratePath(target, importer)
      visit(target)
    visiting.excl id
    reached.incl id
  for id in result.rootPackageIds:
    visit(id)
  if reached.len != result.packagesById.len:
    raisePackageError(pecManifestInvalid,
      "lockfile contains unreachable package instances", [lockPath])

  result.activePackageId = result.rootPackageIds[0]
  for id, pkg in result.packagesById:
    if pkg.name == context.active.name and pkg.sourcePath ==
        relativePath(context.active.root, context.workspaceRoot.root)
          .replace('\\', '/'):
      result.activePackageId = id
      break

proc packageLockPathFor*(startDir: string): string =
  let context = discoverPackageContext(startDir)
  context.workspaceRoot.root / "package.gene.lock"

proc workspaceMembers*(startDir: string): seq[Package] =
  let context = discoverPackageContext(startDir)
  for _, pkg in context.membersByName:
    if pkg.root != context.workspaceRoot.root:
      result.add pkg
  result.sort(proc (a, b: Package): int = cmp(a.root, b.root))

proc workspaceRootFor*(startDir: string): Package =
  discoverPackageContext(startDir).workspaceRoot

proc lockedTreeDigests(lockPath: string): HashSet[string] =
  let forms = readPackageData(readFile(lockPath), lockPath)
  if forms.len != 1 or forms[0].kind != vkMap or
      not forms[0].mapEntries.hasKey("packages") or
      forms[0].mapEntries["packages"].kind != vkList:
    raisePackageError(pecManifestInvalid,
      "GC root lock must contain a package list", [lockPath])
  for value in forms[0].mapEntries["packages"].listItems:
    let node = lockNode(value, "locked_package", "GC root package")
    if not node.props.hasKey("source"):
      raisePackageError(pecManifestInvalid,
        "GC root package requires ^source", [lockPath])
    let source = node.props["source"]
    if source.kind == vkNode and source.head.kind == vkSymbol and
        source.head.symVal in ["registry", "git"]:
      let digest = manifestString(
        lockProp(source, "tree_digest", "GC root source"), "tree_digest",
        lockPath)
      requireSha256(digest, "tree_digest", lockPath)
      result.incl digest

proc cacheGc*(manager: PackageManager, dryRun = false): CacheGcResult =
  ## Trace every project receipt recorded by sync, then remove source objects
  ## not named by any still-present lock. A short GC barrier serializes the
  ## mark/sweep only with installation-root registration and project-root
  ## publication; ordinary acquisition uses independent per-object locks.
  let storeRoot = manager.userStoreRoot
  let gcBarrier = acquireStoreGcBarrier(storeRoot)
  defer: gcBarrier.release()
  var live = initHashSet[string]()
  let installationRoot = storeRoot / "roots" / "installations"
  if dirExists(installationRoot):
    var receipts: seq[string]
    for path in walkDirRec(installationRoot, yieldFilter = {pcFile}):
      if path.endsWith(".gene"):
        receipts.add path
    receipts.sort()
    for receiptPath in receipts:
      let forms = readPackageData(readFile(receiptPath), receiptPath)
      if forms.len != 1 or forms[0].kind != vkMap:
        raisePackageError(pecManifestInvalid,
          "installation root receipt must contain one map", [receiptPath])
      let entries = forms[0].mapEntries
      rejectUnknown(entries, ["root_format", "process_id", "tree_digests"],
                    "installation root receipt", receiptPath)
      if not entries.hasKey("root_format") or
          not entries.hasKey("process_id") or
          not entries.hasKey("tree_digests") or
          entries["root_format"].kind != vkInt or
          entries["root_format"].intVal != 1 or
          entries["process_id"].kind != vkInt or
          entries["tree_digests"].kind != vkList:
        raisePackageError(pecManifestInvalid,
          "invalid installation root receipt", [receiptPath])
      let owner = int(entries["process_id"].intVal)
      if not processAlive(owner):
        inc result.removedRootReceipts
        if not dryRun:
          removeFile(receiptPath)
        continue
      for value in entries["tree_digests"].listItems:
        let digest = manifestString(value, "tree_digests", receiptPath)
        requireSha256(digest, "tree_digests", receiptPath)
        live.incl digest

  let receiptRoot = storeRoot / "roots" / "projects"
  if dirExists(receiptRoot):
    var receipts: seq[string]
    for path in walkDirRec(receiptRoot, yieldFilter = {pcFile}):
      if path.endsWith(".gene"):
        receipts.add path
    receipts.sort()
    for receiptPath in receipts:
      let forms = readPackageData(readFile(receiptPath), receiptPath)
      if forms.len != 1 or forms[0].kind != vkMap:
        raisePackageError(pecManifestInvalid,
          "package-store root receipt must contain one map", [receiptPath])
      let entries = forms[0].mapEntries
      rejectUnknown(entries,
        ["root_format", "workspace_root", "lock_path", "lock_digest",
         "tree_digests"], "package-store root receipt", receiptPath)
      for field in ["root_format", "workspace_root", "lock_path",
                    "lock_digest", "tree_digests"]:
        if not entries.hasKey(field):
          raisePackageError(pecManifestInvalid,
            "package-store root receipt requires ^" & field, [receiptPath])
      if entries["root_format"].kind != vkInt or
          entries["root_format"].intVal != 1 or
          entries["tree_digests"].kind != vkList:
        raisePackageError(pecManifestInvalid,
          "invalid package-store root receipt format", [receiptPath])
      let lockPath = manifestString(entries["lock_path"], "lock_path",
                                    receiptPath)
      if not lockPath.isAbsolute:
        raisePackageError(pecManifestInvalid,
          "package-store root receipt lock path must be absolute",
          [receiptPath])
      if not fileExists(lockPath):
        inc result.removedRootReceipts
        if not dryRun:
          removeFile(receiptPath)
        continue
      # The receipt is the exact graph most recently materialized. Preserve it
      # even if the workspace lock was subsequently edited but not yet synced.
      for value in entries["tree_digests"].listItems:
        let digest = manifestString(value, "tree_digests", receiptPath)
        requireSha256(digest, "tree_digests", receiptPath)
        live.incl digest
      for digest in lockedTreeDigests(lockPath):
        live.incl digest

  let objectsRoot = storeRoot / "objects" / "sha256"
  if not dirExists(objectsRoot):
    return
  var objects: seq[tuple[digest, path: string]]
  for prefixKind, prefixPath in walkDir(objectsRoot, relative = false):
    if prefixKind != pcDir:
      continue
    let prefix = extractFilename(prefixPath)
    for objectKind, objectPath in walkDir(prefixPath, relative = false):
      if objectKind != pcDir:
        continue
      let digest = "sha256:" & prefix & extractFilename(objectPath)
      if digest.len == 71:
        objects.add (digest, objectPath)
  objects.sort(proc (a, b: tuple[digest, path: string]): int =
    cmp(a.digest, b.digest))
  for item in objects:
    if item.digest in live:
      inc result.keptObjects
    else:
      inc result.removedObjects
      if not dryRun:
        makeMaterializedTreeWritable(item.path)
        removeDir(item.path)

proc vendor*(manager: PackageManager, graph: MaterializedGraph,
             request: VendorRequest): VendorReceipt =
  let destination =
    if request.destination.len > 0:
      normalizedPath(absolutePath(request.destination))
    else:
      graph.workspaceRoot / "vendor" / "packages"
  createDir(destination)
  result.root = destination
  var ids: seq[string]
  for id in graph.packagesById.keys:
    ids.add id
  ids.sort()
  let rootLockDigest =
    if graph.lockDigest.len > 0: graph.lockDigest
    else: "sha256:" & sha256Hex("unlocked\0" & graph.activePackageId)
  var index = "{^vendor_format 1 ^root_lock_digest " &
    geneQuoted(rootLockDigest) & " ^packages ["
  for id in ids:
    let pkg = graph.packagesById[id]
    if pkg.sourceKind in {dskWorkspace, dskPath}:
      index.add "\n  (vendored_package ^id " & geneQuoted(id) &
        " ^source " & $pkg.sourceKind & " ^path " &
        geneQuoted(pkg.sourcePath) & ")"
      continue
    let parts = pkg.name.split('/')
    let relative = parts[0] & "/" & parts[1] & "/" & pkg.version & "/" &
      pkg.treeDigest.replace("sha256:", "")
    let target = destination / relative
    if dirExists(target):
      protectMaterializedTree(target)
      let existing = loadPackageAt(target, poApplicationStore)
      existing.treeDigest = sourceTreeDigest(existing)
      if existing.name != pkg.name or existing.version != pkg.version or
          existing.treeDigest != pkg.treeDigest:
        raisePackageError(pecIdentityMismatch,
          "vendored package object does not match the graph",
          ["package: " & id, target])
    else:
      let temp = destination / (".tmp-" &
        pkg.treeDigest.replace("sha256:", "") & "-" &
        $getCurrentProcessId())
      if dirExists(temp):
        makeMaterializedTreeWritable(temp)
        removeDir(temp)
      createDir(parentDir(temp))
      materializeSourceTree(pkg, temp)
      let copied = loadPackageAt(temp, poApplicationStore)
      copied.treeDigest = sourceTreeDigest(copied)
      if copied.treeDigest != pkg.treeDigest:
        removeDir(temp)
        raisePackageError(pecIdentityMismatch,
          "copied vendor object changed digest",
          ["expected: " & pkg.treeDigest, "actual: " & copied.treeDigest])
      createDir(parentDir(target))
      moveDir(temp, target)
      protectMaterializedTree(target)
    result.packagePaths[id] = target
    index.add "\n  (vendored_package ^id " & geneQuoted(id) &
      " ^source object ^path " & geneQuoted(relative) & ")"
  index.add "\n]}\n"
  writeFile(destination / "vendor.gene.lock", index)

proc packageForAlias*(graph: MaterializedGraph, importerId,
                      alias: string): Package =
  if not graph.packagesById.hasKey(importerId):
    raisePackageError(pecNotFound,
      "package instance is absent from the materialized graph: " & importerId)
  let importer = graph.packagesById[importerId]
  if alias == "self":
    return importer
  if not importer.dependencyEdges.hasKey(alias):
    raisePackageError(pecNotDeclared,
      importer.name & " does not declare dependency alias " & alias,
      [importer.manifestPath])
  var scope = dsRuntime
  for declaration in importer.dependencies:
    if declaration.alias == alias:
      scope = declaration.scope
      break
  if (scope == dsDevelopment and
      (not graph.includeDevelopment or
       importerId != graph.developmentPackageId)) or
      (scope == dsBuild and not graph.includeBuild):
    raisePackageError(pecNotDeclared,
      importer.name & " dependency alias " & alias & " is not available in " &
      "this command scope", ["scope: " & $scope, importer.manifestPath])
  let targetId = importer.dependencyEdges[alias]
  if not graph.packagesById.hasKey(targetId):
    raisePackageError(pecNotFound,
      "locked dependency target is absent: " & targetId,
      [importer.manifestPath, "dependency alias: " & alias])
  graph.packagesById[targetId]

proc dependencyAliases*(graph: MaterializedGraph,
                        importerId: string): seq[string] =
  ## Stable command projection over the one all-scope lock graph.
  if not graph.packagesById.hasKey(importerId):
    return
  let importer = graph.packagesById[importerId]
  for alias in importer.dependencyEdges.keys:
    var scope = dsRuntime
    for declaration in importer.dependencies:
      if declaration.alias == alias:
        scope = declaration.scope
        break
    if scope == dsDevelopment and
        (not graph.includeDevelopment or
         importerId != graph.developmentPackageId):
      continue
    if scope == dsBuild and not graph.includeBuild:
      continue
    result.add alias
  result.sort()

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
  ## Package-qualified modules have exactly one base: the declared library
  ## root. Ad-hoc programs use their synthesized package root. There is no
  ## regular-package root fallback.
  if pkg.kind == pkAdHoc:
    result.add pkg.root
  elif pkg.hasLibrary:
    result.add(if pkg.sourceDir.len > 0: pkg.root / pkg.sourceDir else: pkg.root)

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
