## Deterministic pure-Gene target planning and artifact construction.

import std/[algorithm, os, sets, strutils, tables]
import ./[digest, gir, gir_codec, package, printer, process_lock, reader,
          system_dependency, types, vm]

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  import std/posix

type
  BuildMode* = enum
    bmVm = "vm"
    bmMixed = "mixed"

  BuildArtifactKind* = enum
    bakGeneLibrary = "gene_library"
    bakGeneApplication = "gene_application"
    bakGeneTest = "gene_test"

  BuildErrorCode* = enum
    becRequestInvalid = "BUILD_REQUEST_INVALID"
    becTargetNotFound = "BUILD_TARGET_NOT_FOUND"
    becTargetAmbiguous = "BUILD_TARGET_AMBIGUOUS"
    becRecipeUnavailable = "BUILD_FEATURE_UNAVAILABLE"
    becDependencyCycle = "BUILD_DEPENDENCY_CYCLE"
    becNonReproducible = "BUILD_NON_REPRODUCIBLE"

  BuildError* = object of GeneError
    code*: BuildErrorCode

  SourceSnapshotter* = proc (pkg: Package, snapshotRoot: string): Package
                       {.closure.}

  ToolchainSet* = ref object
    compilerIdentity*: string
    hostTargetTriple*: string

  BuildPolicy* = object
    ## Phase-1 pure Gene compilation requests no ambient authority. Later
    ## recipe phases extend this closed policy instead of consulting globals.
    allowNetwork*: bool
    keepFailedSandboxes*: bool

  ArtifactSource* = ref object
    name*: string

  ArtifactStore* = ref object
    root*: string

  SandboxRunner* = ref object
    name*: string

  BuildEnvironment* = object
    toolchains*: ToolchainSet
    policy*: BuildPolicy
    artifactSources*: seq[ArtifactSource]
    artifactStore*: ArtifactStore
    sandboxRunner*: SandboxRunner
    systemDependencyProviders*: SystemDependencyResolver
    sourceSnapshotter*: SourceSnapshotter

  BuildEngine* = ref object
    environment*: BuildEnvironment

  BuildRequest* = object
    rootPackageId*: string
    target*: string
    testEntry*: string
    targetTriple*: string
    profile*: string
    mode*: BuildMode
    sealed*: bool
    open*: bool
    debugInfo*: string
    preferBinary*: bool
    sourceOnly*: bool
    rebuild*: bool
    verifyReproducible*: bool
    maxParallelism*: int

  BuildArtifact* = object
    packageId*: string
    packageName*: string
    target*: string
    kind*: BuildArtifactKind
    entry*: string
    sourceDigest*: string
    derivationId*: string
    artifactDigest*: string
    objectPath*: string
    cacheHit*: bool
    profile*: BuildProfile
    compiledChunk*: Chunk
    compiledModules*: seq[CompiledModule]
    cacheReason*: string

  BuildResult* = ref object
    rootArtifact*: BuildArtifact
    artifacts*: seq[BuildArtifact]
    projectView*: string
    rebuilt*: int
    cacheHits*: int
    explanation*: string
    executionGraph*: MaterializedGraph

proc raiseBuild(code: BuildErrorCode, message: string,
                details: openArray[string] = []) =
  var error: ref BuildError
  new(error)
  error.code = code
  error.msg = $code & ": " & message
  for detail in details:
    error.msg.add "\n  " & detail
  raise error

proc defaultSourceSnapshot(pkg: Package, snapshotRoot: string): Package

proc newToolchainSet*(compilerIdentity, hostTargetTriple: string): ToolchainSet =
  ToolchainSet(compilerIdentity: compilerIdentity,
               hostTargetTriple: hostTargetTriple)

proc newLocalArtifactStore*(root: string): ArtifactStore =
  ArtifactStore(root: normalizedPath(absolutePath(root)))

proc userArtifactStoreDir*(): string =
  let configured = getEnv("GENE_ARTIFACT_STORE")
  if configured.len > 0:
    return normalizedPath(absolutePath(configured))
  normalizedPath(getHomeDir() / ".gene" / "artifacts")

proc newBuildEngine*(environment: BuildEnvironment): BuildEngine =
  if environment.toolchains == nil or
      environment.toolchains.compilerIdentity.len == 0 or
      environment.toolchains.hostTargetTriple.len == 0:
    raiseBuild(becRequestInvalid,
      "BuildEnvironment requires an explicit ToolchainSet")
  if environment.artifactStore == nil or
      environment.artifactStore.root.len == 0:
    raiseBuild(becRequestInvalid,
      "BuildEnvironment requires an explicit ArtifactStore")
  var effective = environment
  if effective.sourceSnapshotter == nil:
    effective.sourceSnapshotter = defaultSourceSnapshot
  BuildEngine(environment: effective)

proc runningCompilerIdentity*(): string =
  ## The executable is the compiler boundary in Phase 1. Hashing its exact
  ## bytes covers Gene compiler changes, linked runtime changes, build flags,
  ## and the artifact ABI; NimVersion alone covers none of those.
  "gene-phase1/abi-1/sha256:" & sha256File(getAppFilename())

proc valueList(values: seq[string]): Value =
  var items: seq[Value]
  for value in values:
    items.add newStr(value)
  newList(items)

proc derivationId(environment: BuildEnvironment, request: BuildRequest,
                  graph: MaterializedGraph, pkg: Package,
                  kind: BuildArtifactKind, target, entry, sourceDigest: string,
                  dependencyArtifacts: seq[BuildArtifact],
                  profile: BuildProfile): string =
  var dependencyIds: seq[string]
  for artifact in dependencyArtifacts:
    dependencyIds.add artifact.packageId & "=" & artifact.artifactDigest
  dependencyIds.sort()
  var entries = initPropTable()
  entries["build_format"] = newInt(1)
  entries["package_id"] = newStr(pkg.id)
  entries["target_kind"] = newSym($kind)
  entries["target"] = newStr(target)
  entries["entry"] = newStr(entry)
  entries["source_digest"] = newStr(sourceDigest)
  entries["dependencies"] = valueList(dependencyIds)
  entries["lock_digest"] =
    if graph.lockDigest.len > 0: newStr(graph.lockDigest) else: NIL
  entries["features"] = valueList(pkg.selectedFeatures)
  entries["compiler_identity"] = newStr(
    environment.toolchains.compilerIdentity)
  entries["target_triple"] = newStr(
    if request.targetTriple.len > 0: request.targetTriple
    else: environment.toolchains.hostTargetTriple)
  entries["profile"] = newSym(request.profile)
  entries["mode"] = newSym($request.mode)
  entries["optimization"] = newSym(profile.optimization)
  entries["debug_info"] = newSym(profile.debugInfo)
  entries["assertions"] = newBool(profile.assertions)
  entries["sealing"] = newSym(profile.sealing)
  entries["lto"] = newBool(profile.lto)
  canonicalDigest(newMap(entries))

proc artifactMetadata(pkg: Package, artifact: BuildArtifact,
                      request: BuildRequest, graph: MaterializedGraph,
                      dependencyArtifacts: seq[BuildArtifact],
                      profile: BuildProfile): Value =
  var dependencies: seq[string]
  for dependency in dependencyArtifacts:
    dependencies.add dependency.packageId & "=" & dependency.artifactDigest
  dependencies.sort()
  var entries = initPropTable()
  entries["artifact_format"] = newInt(1)
  entries["type"] = newSym($artifact.kind)
  entries["package_id"] = newStr(pkg.id)
  entries["package_name"] = newStr(pkg.name)
  entries["target"] = newStr(artifact.target)
  entries["entry"] = newStr(artifact.entry)
  entries["source_digest"] = newStr(artifact.sourceDigest)
  entries["derivation_id"] = newStr(artifact.derivationId)
  entries["profile"] = newSym(request.profile)
  entries["mode"] = newSym($request.mode)
  entries["optimization"] = newSym(profile.optimization)
  entries["debug_info"] = newSym(profile.debugInfo)
  entries["assertions"] = newBool(profile.assertions)
  entries["sealing"] = newSym(profile.sealing)
  entries["lto"] = newBool(profile.lto)
  entries["lock_digest"] =
    if graph.lockDigest.len > 0: newStr(graph.lockDigest) else: NIL
  entries["dependencies"] = valueList(dependencies)
  newMap(entries)

proc updateU64(context: var Sha256Context, value: uint64) =
  var bytes: array[8, byte]
  for i in 0 ..< 8:
    bytes[i] = byte((value shr ((7 - i) * 8)) and 0xff'u64)
  context.update(bytes)

proc beginArtifactDigest(kind: BuildArtifactKind, metadata: Value,
                         payloadPath: string,
                         payloadSize: uint64): Sha256Context =
  result = initSha256()
  result.update("gene-artifact-v1\0")
  result.update($kind)
  result.update("\0")
  result.update(canonicalGeneData(metadata))
  result.update("gene-tree-v1\0")
  result.updateU64(1)
  result.update("\x01")
  result.updateU64(uint64(payloadPath.len))
  result.update(payloadPath)
  result.update("\x00")
  result.updateU64(payloadSize)

proc artifactDigest(kind: BuildArtifactKind, metadata: Value,
                    payload: string): string =
  var context = beginArtifactDigest(kind, metadata, "artifact.gir",
                                    uint64(payload.len))
  context.update(payload)
  "sha256:" & context.finishHex()

proc artifactFileDigest(kind: BuildArtifactKind, metadata: Value,
                        payloadPath: string): string =
  let size = getFileSize(payloadPath)
  var context = beginArtifactDigest(kind, metadata, "artifact.gir",
                                    uint64(size))
  var file: File
  if not open(file, payloadPath, fmRead):
    raiseBuild(becNonReproducible,
      "artifact payload cannot be read", [payloadPath])
  var buffer: array[64 * 1024, byte]
  var observed: int64
  try:
    while true:
      let count = file.readBuffer(addr buffer[0], buffer.len)
      if count <= 0:
        break
      context.update(buffer.toOpenArray(0, count - 1))
      observed += int64(count)
  finally:
    close(file)
  if observed != size or getFileSize(payloadPath) != size:
    raiseBuild(becNonReproducible,
      "artifact payload changed during verification", [payloadPath])
  "sha256:" & context.finishHex()

proc validSha256Digest(digest: string): bool =
  if digest.len != 71 or not digest.startsWith("sha256:"):
    return false
  for ch in digest[7 .. ^1]:
    if ch notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true

proc requireBuildDigest(digest, context: string) =
  if not validSha256Digest(digest):
    raiseBuild(becNonReproducible,
      "invalid canonical SHA-256 digest", [context, digest])

proc digestObjectPath(root, digest: string): string =
  requireBuildDigest(digest, "artifact object path")
  let hex = digest[7 .. ^1]
  root / "objects" / "sha256" / hex[0 .. 1] / hex[2 .. ^1]

proc derivationIndexPath(root, derivation: string): string =
  requireBuildDigest(derivation, "derivation index path")
  root / "derivations" / "sha256" / derivation[7 .. ^1] /
    "index.gene"

proc activeArtifact(indexPath: string): string =
  if not fileExists(indexPath):
    return ""
  let forms = readAll(readFile(indexPath), indexPath,
                      ReadOptions(rejectDuplicateProps: true))
  if forms.len != 1 or forms[0].kind != vkMap:
    raiseBuild(becNonReproducible, "invalid derivation index", [indexPath])
  let entries = forms[0].mapEntries
  if not entries.hasKey("state") or entries["state"].kind != vkSymbol or
      not entries.hasKey("artifact_digest") or
      entries["artifact_digest"].kind != vkString:
    raiseBuild(becNonReproducible, "invalid derivation index", [indexPath])
  if entries["state"].symVal == "poisoned":
    raiseBuild(becNonReproducible, "derivation is permanently poisoned",
               [indexPath])
  if entries["state"].symVal != "active":
    raiseBuild(becNonReproducible, "unknown derivation state", [indexPath])
  result = entries["artifact_digest"].strVal
  requireBuildDigest(result, indexPath)

proc verifyArtifactObject(objectPath, expectedDigest, expectedDerivation: string,
                          kind: BuildArtifactKind): bool =
  if not dirExists(objectPath):
    return false
  let payloadPath = objectPath / "artifact.gir"
  let metadataPath = objectPath / "metadata.gene"
  if not fileExists(payloadPath) or not fileExists(metadataPath):
    raiseBuild(becNonReproducible,
      "artifact-store object is incomplete", [objectPath])
  try:
    let forms = readAll(readFile(metadataPath), metadataPath,
                        ReadOptions(rejectDuplicateProps: true))
    if forms.len != 1 or forms[0].kind != vkMap or
        not forms[0].mapEntries.hasKey("derivation_id") or
        forms[0].mapEntries["derivation_id"].kind != vkString or
        forms[0].mapEntries["derivation_id"].strVal != expectedDerivation:
      raiseBuild(becNonReproducible,
        "artifact metadata disagrees with its derivation", [objectPath])
    let observed = artifactFileDigest(kind, forms[0], payloadPath)
    if observed != expectedDigest:
      raiseBuild(becNonReproducible,
        "artifact-store object failed content verification",
        ["expected: " & expectedDigest, "actual: " & observed, objectPath])
    return true
  except BuildError:
    raise
  except CatchableError as error:
    raiseBuild(becNonReproducible,
      "artifact-store object metadata is invalid", [objectPath, error.msg])

proc loadVerifiedArtifactPayload(objectPath, expectedDigest,
                                 expectedDerivation: string,
                                 kind: BuildArtifactKind): string =
  ## Cache consumers need the payload to decode GIR. Hash the same immutable
  ## string that will be decoded, avoiding both a second artifact-sized read
  ## and a verify-then-reread replacement race.
  if not dirExists(objectPath):
    return ""
  let payloadPath = objectPath / "artifact.gir"
  let metadataPath = objectPath / "metadata.gene"
  if not fileExists(payloadPath) or not fileExists(metadataPath):
    raiseBuild(becNonReproducible,
      "artifact-store object is incomplete", [objectPath])
  try:
    let forms = readAll(readFile(metadataPath), metadataPath,
                        ReadOptions(rejectDuplicateProps: true))
    if forms.len != 1 or forms[0].kind != vkMap or
        not forms[0].mapEntries.hasKey("derivation_id") or
        forms[0].mapEntries["derivation_id"].kind != vkString or
        forms[0].mapEntries["derivation_id"].strVal != expectedDerivation:
      raiseBuild(becNonReproducible,
        "artifact metadata disagrees with its derivation", [objectPath])
    result = readFile(payloadPath)
    let observed = artifactDigest(kind, forms[0], result)
    if observed != expectedDigest:
      raiseBuild(becNonReproducible,
        "artifact-store object failed content verification",
        ["expected: " & expectedDigest, "actual: " & observed, objectPath])
  except BuildError:
    raise
  except CatchableError as error:
    raiseBuild(becNonReproducible,
      "artifact-store object is invalid", [objectPath, error.msg])

proc atomicWrite(path, content: string) =
  createDir(parentDir(path))
  let temp = path & ".tmp-" & $getCurrentProcessId()
  if fileExists(temp):
    removeFile(temp)
  writeFile(temp, content)
  try:
    moveFile(temp, path)
  except OSError:
    # Some platforms do not replace an existing destination. Convergence is
    # safe only when another publisher wrote the exact intended bytes; every
    # other failure must propagate, especially active -> poisoned transitions.
    let converged = fileExists(path) and readFile(path) == content
    if fileExists(temp):
      removeFile(temp)
    if not converged:
      raise

proc acquireInsertionLock(indexPath: string): ProcessFileLock =
  let directory = parentDir(indexPath)
  createDir(directory)
  try:
    result = acquireProcessFileLock(directory / "insert.lock")
  except IOError as error:
    raiseBuild(becNonReproducible, error.msg, [indexPath])

proc observationDigests(indexPath: string): seq[string] =
  let root = parentDir(indexPath) / "observations"
  if not dirExists(root):
    return
  for kind, path in walkDir(root, relative = false):
    if kind != pcFile or not path.endsWith(".gene"):
      continue
    let name = splitFile(path).name
    if name.len != 64 or not validSha256Digest("sha256:" & name):
      raiseBuild(becNonReproducible,
        "invalid artifact observation filename", [path])
    result.add "sha256:" & name
  result.sort()

proc poisonedIndexText(digests: seq[string]): string =
  result = "{^state poisoned ^artifact_digest \"" & digests[0] &
    "\" ^conflicting_digest \"" & digests[1] & "\" ^observations ["
  for digest in digests:
    result.add "\"" & digest & "\" "
  result.add "]}\n"

proc snapshotPackageFields(snapshot, original: Package) =
  snapshot.id = original.id
  snapshot.sourceKind = original.sourceKind
  snapshot.sourceName = original.sourceName
  snapshot.sourcePath = original.sourcePath
  snapshot.archiveDigest = original.archiveDigest
  snapshot.selectedFeatures = original.selectedFeatures
  snapshot.yanked = original.yanked
  snapshot.dependencyEdges = original.dependencyEdges

proc sourceIndexPath(snapshotRoot, packageRoot: string): string =
  parentDir(parentDir(snapshotRoot)) / "source_indexes" / "sha256" /
    (sha256Hex(normalizedPath(absolutePath(packageRoot))) & ".gene")

proc cachedSourceDigest(indexPath, stamp: string): string =
  if not fileExists(indexPath):
    return ""
  try:
    let forms = readAll(readFile(indexPath), indexPath,
                        ReadOptions(rejectDuplicateProps: true))
    if forms.len != 1 or forms[0].kind != vkMap:
      return ""
    let entries = forms[0].mapEntries
    if entries.len != 3 or not entries.hasKey("source_index_format") or
        entries["source_index_format"].kind != vkInt or
        entries["source_index_format"].intVal != 1 or
        not entries.hasKey("stamp") or entries["stamp"].kind != vkString or
        not entries.hasKey("tree_digest") or
        entries["tree_digest"].kind != vkString or
        entries["stamp"].strVal != stamp:
      return ""
    let digest = entries["tree_digest"].strVal
    if validSha256Digest(digest):
      return digest
  except CatchableError:
    discard

proc writeSourceIndex(indexPath, stamp, treeDigest: string) =
  var entries = initPropTable()
  entries["source_index_format"] = newInt(1)
  entries["stamp"] = newStr(stamp)
  entries["tree_digest"] = newStr(treeDigest)
  atomicWrite(indexPath, newMap(entries).print() & "\n")

proc makeSnapshotWritable(path: string) =
  ## Snapshot trees are protected against accidental mutation after their
  ## digest is verified. Restore owner permissions before replacing a corrupt
  ## or concurrently superseded snapshot.
  makeMaterializedTreeWritable(path)

proc protectSnapshot(path: string) =
  when defined(posix):
    if not dirExists(path):
      return
    for kind, child in walkDir(path, relative = false):
      case kind
      of pcDir:
        protectSnapshot(child)
      of pcFile:
        var permissions = {fpUserRead, fpGroupRead, fpOthersRead}
        let current = getFilePermissions(child)
        if fpUserExec in current:
          permissions.incl fpUserExec
          permissions.incl fpGroupExec
          permissions.incl fpOthersExec
        setFilePermissions(child, permissions)
      of pcLinkToFile, pcLinkToDir:
        discard

proc protectSnapshotDirectories(path: string) =
  ## Directory metadata is not part of sourceTreeStamp. Protect directories
  ## only after the validity marker has been created so the marker can be
  ## published atomically without re-chmodding source files and changing
  ## their ctime after the stamp was captured.
  when defined(posix):
    if not dirExists(path):
      return
    for kind, child in walkDir(path, relative = false):
      if kind == pcDir:
        protectSnapshotDirectories(child)
    setFilePermissions(path, {
      fpUserRead, fpUserExec,
      fpGroupRead, fpGroupExec,
      fpOthersRead, fpOthersExec})

proc verifiedSnapshot(destination, expectedDigest: string,
                      original: Package): Package =
  ## A snapshot is fully content-hashed when it is created. A warm artifact hit
  ## needs only its atomic marker: it does not parse or walk snapshot source.
  ## The cache-miss path authenticates the full snapshot tree immediately
  ## before compiler use.
  let marker = destination / ".gene" / "snapshot.digest"
  if not dirExists(destination) or not fileExists(marker):
    return nil
  try:
    let forms = readAll(readFile(marker), marker,
                        ReadOptions(rejectDuplicateProps: true))
    if forms.len != 1 or forms[0].kind != vkMap:
      return nil
    let entries = forms[0].mapEntries
    if entries.len != 3 or not entries.hasKey("snapshot_format") or
        entries["snapshot_format"].kind != vkInt or
        entries["snapshot_format"].intVal != 1 or
        not entries.hasKey("tree_digest") or
        entries["tree_digest"].kind != vkString or
        entries["tree_digest"].strVal != expectedDigest or
        not entries.hasKey("tree_stamp") or
        entries["tree_stamp"].kind != vkString:
      return nil
  except CatchableError:
    return nil
  new(result)
  result[] = original[]
  result.root = destination
  result.realRoot = canonicalPath(destination)
  result.manifestPath = destination / ManifestFileName
  result.treeDigest = expectedDigest
  result.snapshotPackageFields(original)

proc defaultSourceSnapshot(pkg: Package, snapshotRoot: string): Package =
  if pkg.sourceKind in {dskRegistry, dskGit}:
    return pkg
  let indexPath = sourceIndexPath(snapshotRoot, pkg.root)
  let initialStamp = sourceTreeStamp(pkg)
  let cachedDigest = cachedSourceDigest(indexPath, initialStamp)
  if cachedDigest.len > 0:
    let destination = snapshotRoot / cachedDigest.replace("sha256:", "")
    let existing = verifiedSnapshot(destination, cachedDigest, pkg)
    if existing != nil:
      return existing
    if dirExists(destination):
      makeSnapshotWritable(destination)
      removeDir(destination)
  for attempt in 0 ..< 3:
    let attemptStamp =
      if attempt == 0: initialStamp else: sourceTreeStamp(pkg)
    let expectedDigest = sourceTreeDigest(pkg)
    let destination = snapshotRoot / expectedDigest.replace("sha256:", "")
    if dirExists(destination):
      let existing = verifiedSnapshot(destination, expectedDigest, pkg)
      if existing != nil:
        return existing
      makeSnapshotWritable(destination)
      removeDir(destination)
    let staged = snapshotRoot / (".tmp-" &
      expectedDigest.replace("sha256:", "") & "-" &
      $getCurrentProcessId() & "-" & $attempt)
    if dirExists(staged):
      removeDir(staged)
    createDir(snapshotRoot)
    materializeSourceTree(pkg, staged)
    let captured = loadPackageAt(staged, pkg.origin)
    let actualDigest = sourceTreeDigest(captured)
    if actualDigest != expectedDigest:
      removeDir(staged)
      continue
    # Publish a complete directory atomically. In particular, the validity
    # marker must move with the snapshot; writing it after moveDir exposes a
    # window where another build can mistake an in-progress snapshot for
    # corruption and remove it.
    protectSnapshot(staged)
    let capturedStamp = sourceTreeStamp(captured)
    createDir(staged / ".gene")
    var markerEntries = initPropTable()
    markerEntries["snapshot_format"] = newInt(1)
    markerEntries["tree_digest"] = newStr(expectedDigest)
    markerEntries["tree_stamp"] = newStr(capturedStamp)
    writeFile(staged / ".gene" / "snapshot.digest",
              newMap(markerEntries).print() & "\n")
    when defined(posix):
      setFilePermissions(staged / ".gene" / "snapshot.digest",
        {fpUserRead, fpGroupRead, fpOthersRead})
    protectSnapshotDirectories(staged)
    try:
      moveDir(staged, destination)
    except OSError:
      if not dirExists(destination):
        raise
      if dirExists(staged):
        makeSnapshotWritable(staged)
        removeDir(staged)
    let stable = verifiedSnapshot(destination, expectedDigest, pkg)
    if stable == nil:
      raiseBuild(becNonReproducible,
        "concurrent source snapshot publication produced invalid state",
        [destination])
    if sourceTreeStamp(pkg) == attemptStamp:
      writeSourceIndex(indexPath, attemptStamp, expectedDigest)
    return stable
  raiseBuild(becRequestInvalid,
    "source changed repeatedly while its build snapshot was captured",
    [pkg.root])

proc snapshotGraph(engine: BuildEngine, graph: MaterializedGraph,
                   artifactRoot, rootPackageId: string): MaterializedGraph =
  var ids: seq[string]
  var pending = @[rootPackageId]
  var reached = initHashSet[string]()
  while pending.len > 0:
    let id = pending.pop()
    if id in reached:
      continue
    reached.incl id
    ids.add id
    var aliases = graph.dependencyAliases(id)
    aliases.sort(order = SortOrder.Descending)
    for alias in aliases:
      pending.add graph.packagesById[id].dependencyEdges[alias]
  ids.sort()
  result = MaterializedGraph(workspaceRoot: graph.workspaceRoot,
    lockDigest: graph.lockDigest, activePackageId: graph.activePackageId,
    developmentPackageId: graph.developmentPackageId,
    rootPackageIds: @[rootPackageId],
    packagesById: initTable[string, Package](),
    includeDevelopment: graph.includeDevelopment,
    includeBuild: graph.includeBuild)
  for id in ids:
    let original = graph.packagesById[id]
    result.packagesById[id] = engine.environment.sourceSnapshotter(
      original, artifactRoot / "snapshots" / "sha256")

proc localGraph(graph: MaterializedGraph,
                activePackageId: string): MaterializedGraph =
  MaterializedGraph(workspaceRoot: graph.workspaceRoot,
                    lockDigest: graph.lockDigest,
                    activePackageId: activePackageId,
                    developmentPackageId: graph.developmentPackageId,
                    rootPackageIds: @[activePackageId],
                    packagesById: graph.packagesById,
                    includeDevelopment: graph.includeDevelopment,
                    includeBuild: graph.includeBuild)

proc entryChunk(artifact: ExecutableGir): Chunk =
  for compiled in artifact.modules:
    if compiled.identity == artifact.entryIdentity:
      return compiled.chunk

proc preparedArtifact(engine: BuildEngine, request: BuildRequest,
                      graph: MaterializedGraph, pkg: Package,
                      kind: BuildArtifactKind, target, entry: string,
                      dependencies: seq[BuildArtifact],
                      profile: BuildProfile): BuildArtifact =
  if entry.len == 0:
    raiseBuild(becTargetNotFound, "target entry is missing",
      [pkg.name & ":" & target, pkg.root / entry])
  let sourceDigest =
    if pkg.treeDigest.len > 0: pkg.treeDigest else: sourceTreeDigest(pkg)
  result = BuildArtifact(packageId: pkg.id, packageName: pkg.name,
                         target: target, kind: kind, entry: entry,
                         sourceDigest: sourceDigest, profile: profile,
                         cacheReason: "derivation has no active artifact")
  result.derivationId = derivationId(engine.environment, request, graph, pkg,
    kind, target, entry, sourceDigest, dependencies, profile)

proc loadCachedArtifact(engine: BuildEngine, request: BuildRequest,
                        graph: MaterializedGraph, pkg: Package,
                        kind: BuildArtifactKind, target, entry: string,
                        dependencies: seq[BuildArtifact], artifactRoot: string,
                        profile: BuildProfile): BuildArtifact =
  result = preparedArtifact(engine, request, graph, pkg, kind, target, entry,
                            dependencies, profile)
  if request.rebuild or request.verifyReproducible:
    result.cacheReason =
      if request.verifyReproducible: "reproducibility verification requested"
      else: "explicit rebuild requested"
    return
  let indexPath = derivationIndexPath(artifactRoot, result.derivationId)
  let cachedDigest = activeArtifact(indexPath)
  if cachedDigest.len == 0:
    return
  let cachedObject = digestObjectPath(artifactRoot, cachedDigest)
  let payload = loadVerifiedArtifactPayload(cachedObject, cachedDigest,
                                            result.derivationId, kind)
  if payload.len == 0:
    result.cacheReason = "artifact object is absent"
    return
  try:
    let executable = decodeExecutableGir(payload)
    let expectedEntry = pkg.moduleIdentity(pkg.root / entry)
    if executable.entryIdentity != expectedEntry:
      raise newException(ValueError,
        "entry identity mismatch: expected " & expectedEntry &
        ", found " & executable.entryIdentity)
    result.compiledChunk = executable.entryChunk()
    result.compiledModules = executable.modules
  except CatchableError as error:
    raiseBuild(becNonReproducible,
      "verified artifact contains invalid executable GIR",
      [cachedObject, error.msg])
  result.artifactDigest = cachedDigest
  result.objectPath = cachedObject
  result.cacheHit = true
  result.cacheReason = "verified derivation and artifact digest matched"

proc buildOne(engine: BuildEngine, request: BuildRequest,
              graph: MaterializedGraph, pkg: Package,
              kind: BuildArtifactKind, target, entry: string,
              dependencies: seq[BuildArtifact], artifactRoot: string,
              profile: BuildProfile):
              BuildArtifact =
  result = engine.loadCachedArtifact(request, graph, pkg, kind, target, entry,
                                     dependencies, artifactRoot, profile)
  if result.cacheHit:
    return
  if not fileExists(pkg.root / entry):
    raiseBuild(becTargetNotFound, "target entry is missing",
      [pkg.name & ":" & target, pkg.root / entry])
  let observedSourceDigest = sourceTreeDigest(pkg)
  if observedSourceDigest != result.sourceDigest:
    raiseBuild(becNonReproducible,
      "authenticated source snapshot disagrees with its derivation",
      [pkg.name & ":" & target, "expected: " & result.sourceDigest,
       "actual: " & observedSourceDigest, pkg.root])
  let indexPath = derivationIndexPath(artifactRoot, result.derivationId)

  proc compilePayload(): tuple[executable: ExecutableGir, payload: string] =
    let app = newApplication(localGraph(graph, pkg.id), pkg.root)
    for dependency in dependencies:
      app.installCompiledModules(dependency.compiledModules)
    result.executable = app.compileFileModuleBundle(
      pkg.root / entry, pkg.id, includeLibraryModules = kind == bakGeneLibrary)
    result.payload = encodeExecutableGir(result.executable)
  let compiled = compilePayload()
  let payload = compiled.payload
  result.compiledChunk = compiled.executable.entryChunk()
  result.compiledModules = compiled.executable.modules
  if request.verifyReproducible:
    let repeated = compilePayload().payload
    if repeated != payload:
      raiseBuild(becNonReproducible,
        "clean compiler observations disagreed for one derivation",
        [pkg.name & ":" & target])
  let metadata = artifactMetadata(pkg, result, request, graph, dependencies,
                                  profile)
  result.artifactDigest = artifactDigest(kind, metadata, payload)
  result.objectPath = digestObjectPath(artifactRoot, result.artifactDigest)
  if not dirExists(result.objectPath):
    let temp = artifactRoot / "tmp" /
      (result.artifactDigest.replace("sha256:", "") & "-" &
       $getCurrentProcessId())
    if dirExists(temp):
      makeMaterializedTreeWritable(temp)
      removeDir(temp)
    createDir(temp)
    writeFile(temp / "artifact.gir", payload)
    writeFile(temp / "metadata.gene", metadata.print() & "\n")
    createDir(parentDir(result.objectPath))
    try:
      moveDir(temp, result.objectPath)
    except OSError:
      if not dirExists(result.objectPath):
        raise
      if dirExists(temp):
        makeMaterializedTreeWritable(temp)
        removeDir(temp)
  protectMaterializedTree(result.objectPath)
  discard verifyArtifactObject(result.objectPath, result.artifactDigest,
                               result.derivationId, kind)
  let observationPath = parentDir(indexPath) / "observations" /
    (result.artifactDigest.replace("sha256:", "") & ".gene")
  let insertionLock = acquireInsertionLock(indexPath)
  try:
    let committedDigest = activeArtifact(indexPath)
    if not fileExists(observationPath):
      atomicWrite(observationPath,
        "{^observation_format 1 ^derivation_id \"" & result.derivationId &
        "\" ^artifact_digest \"" & result.artifactDigest &
        "\" ^artifact_type " & $kind & "}\n")
    var observations = observationDigests(indexPath)
    if committedDigest.len > 0 and committedDigest notin observations:
      observations.add committedDigest
      observations.sort()
    if observations.len > 1:
      atomicWrite(indexPath, poisonedIndexText(observations))
      raiseBuild(becNonReproducible,
        "one derivation produced different artifact bytes",
        ["derivation: " & result.derivationId,
         "first: " & observations[0], "second: " & observations[1]])
    atomicWrite(indexPath, "{^state active ^artifact_digest \"" &
      result.artifactDigest & "\" ^observations [\"" &
      result.artifactDigest & "\"]}\n")
  finally:
    insertionLock.release()

proc targetEntry(pkg: Package, target, testEntry: string):
                 tuple[kind: BuildArtifactKind, name, entry: string] =
  if target == "test":
    if not pkg.hasTests:
      raiseBuild(becTargetNotFound, pkg.name & " has no test target")
    if testEntry.len == 0:
      raiseBuild(becRequestInvalid, "test builds require one discovered entry")
    let entry = testEntry.replace('\\', '/')
    if entry.isAbsolute or entry == ".." or entry.startsWith("../") or
        "/../" in entry:
      raiseBuild(becRequestInvalid, "test entry escapes the package", [entry])
    if entry != pkg.tests.root and
        not entry.startsWith(pkg.tests.root & "/"):
      raiseBuild(becRequestInvalid,
        "test entry is outside the declared test root", [entry])
    return (bakGeneTest, "test-" & sha256Hex(entry)[0 .. 11], entry)
  if target == "library":
    if not pkg.hasLibrary:
      raiseBuild(becTargetNotFound, pkg.name & " has no library target")
    return (bakGeneLibrary, "library", pkg.library.entry)
  for application in pkg.applications:
    if application.name == target:
      return (bakGeneApplication, application.name, application.entry)
  raiseBuild(becTargetNotFound,
    "package has no target named " & target, [pkg.manifestPath])

proc defaultTarget(pkg: Package): string =
  if pkg.applications.len == 1:
    return pkg.applications[0].name
  if pkg.applications.len == 0 and pkg.hasLibrary:
    return "library"
  raiseBuild(becTargetAmbiguous,
    "target is required when a package has multiple products",
    [pkg.manifestPath])

proc projectViewPath(graph: MaterializedGraph, request: BuildRequest,
                     artifact: BuildArtifact): string =
  let packageKey = artifact.packageName.replace('/', '_') & "-" &
    sha256Hex(artifact.packageId)[0 .. 11]
  graph.workspaceRoot / ".gene" / "build" / request.profile / packageKey /
    ($artifact.kind & "-" & artifact.target)

proc materializeProjectView(path: string, artifact: BuildArtifact) =
  requireBuildDigest(artifact.artifactDigest, "project build view")
  let lockPath = path & ".lock"
  var viewLock: ProcessFileLock
  try:
    viewLock = acquireProcessFileLock(lockPath)
  except IOError as error:
    raiseBuild(becNonReproducible, error.msg, [path])
  try:
    let digestPath = path / "artifact.digest"
    let objectPath = path / "artifact.object"
    let girPath = path / "artifact.gir"
    let metadataPath = path / "metadata.gene"
    var current = fileExists(digestPath) and fileExists(objectPath) and
      readFile(digestPath).strip() == artifact.artifactDigest and
      readFile(objectPath).strip() == artifact.objectPath and
      fileExists(girPath) and fileExists(metadataPath)
    if current:
      when defined(posix):
        current = symlinkExists(girPath) and symlinkExists(metadataPath) and
          expandSymlink(girPath) == artifact.objectPath / "artifact.gir" and
          expandSymlink(metadataPath) == artifact.objectPath / "metadata.gene"
      else:
        current = sameFileContent(
          girPath, artifact.objectPath / "artifact.gir") and
          sameFileContent(metadataPath,
                          artifact.objectPath / "metadata.gene")
    if current:
      return
    let staged = path & ".tmp-" & $getCurrentProcessId()
    if dirExists(staged):
      removeDir(staged)
    createDir(staged)
    when defined(posix):
      createSymlink(artifact.objectPath / "artifact.gir",
                    staged / "artifact.gir")
      createSymlink(artifact.objectPath / "metadata.gene",
                    staged / "metadata.gene")
    else:
      copyFile(artifact.objectPath / "artifact.gir", staged / "artifact.gir")
      copyFile(artifact.objectPath / "metadata.gene",
               staged / "metadata.gene")
    writeFile(staged / "artifact.digest", artifact.artifactDigest & "\n")
    writeFile(staged / "artifact.object", artifact.objectPath & "\n")
    if dirExists(path):
      removeDir(path)
    moveDir(staged, path)
  finally:
    viewLock.release()

proc build*(engine: BuildEngine, request: BuildRequest,
            graph: MaterializedGraph): BuildResult =
  if not graph.packagesById.hasKey(request.rootPackageId):
    raiseBuild(becRequestInvalid,
      "root package instance is absent from the materialized graph",
      [request.rootPackageId])
  if request.sealed and request.open:
    raiseBuild(becRequestInvalid, "--sealed and --open conflict")
  if request.mode == bmMixed:
    raiseBuild(becRecipeUnavailable,
      "mixed native acceleration is not available in the pure-Gene build phase")
  if request.debugInfo.len > 0 and
      request.debugInfo notin ["full", "min", "none"]:
    raiseBuild(becRequestInvalid, "invalid debug_info: " & request.debugInfo)
  if request.maxParallelism < 0:
    raiseBuild(becRequestInvalid, "maxParallelism cannot be negative")
  var effectiveRequest = request
  if effectiveRequest.profile.len == 0:
    effectiveRequest.profile = "dev"
  let artifactRoot = engine.environment.artifactStore.root
  createDir(artifactRoot)
  let buildGraph = engine.snapshotGraph(graph, artifactRoot,
                                        request.rootPackageId)
  let rootPkg = buildGraph.packagesById[request.rootPackageId]
  var profile: BuildProfile
  try:
    profile = rootPkg.buildProfile(effectiveRequest.profile)
  except PackageError as error:
    raiseBuild(becRequestInvalid, error.msg)
  if effectiveRequest.debugInfo.len > 0:
    profile.debugInfo = effectiveRequest.debugInfo
  if effectiveRequest.sealed:
    profile.sealing = "sealed"
  elif effectiveRequest.open:
    profile.sealing = "open"
  result = BuildResult()
  result.executionGraph = buildGraph
  var builtLibraries = initTable[string, BuildArtifact]()
  var visiting = initHashSet[string]()

  var plannedLibraries: seq[string]
  var planned = initHashSet[string]()
  proc planLibrary(packageId: string) =
    if packageId in planned:
      return
    if packageId in visiting:
      raiseBuild(becDependencyCycle,
        "library build graph contains a cycle", [packageId])
    visiting.incl packageId
    let pkg = buildGraph.packagesById[packageId]
    if not pkg.hasLibrary:
      raiseBuild(becTargetNotFound,
        "dependency package has no library target", [pkg.name, pkg.manifestPath])
    if pkg.library.uses.len > 0:
      raiseBuild(becRecipeUnavailable,
        "target recipes are not available in the pure-Gene build phase",
        [pkg.name, pkg.library.uses.join(", ")])
    let aliases = buildGraph.dependencyAliases(packageId)
    for alias in aliases:
      planLibrary(pkg.dependencyEdges[alias])
    visiting.excl packageId
    planned.incl packageId
    plannedLibraries.add packageId

  proc dependencyArtifacts(packageId: string): seq[BuildArtifact] =
    let pkg = buildGraph.packagesById[packageId]
    for alias in buildGraph.dependencyAliases(packageId):
      let dependencyId = pkg.dependencyEdges[alias]
      if not builtLibraries.hasKey(dependencyId):
        raiseBuild(becDependencyCycle,
          "library dependency was not scheduled before its importer",
          [packageId, dependencyId])
      result.add builtLibraries[dependencyId]

  proc buildLibraryNow(packageId: string,
                       workerRequest = effectiveRequest): BuildArtifact =
    let pkg = buildGraph.packagesById[packageId]
    engine.buildOne(workerRequest, buildGraph, pkg, bakGeneLibrary,
                    "library", pkg.library.entry,
                    dependencyArtifacts(packageId), artifactRoot, profile)

  proc executePlannedLibraries() =
    ## Schedule deterministic readiness batches. On POSIX, independent
    ## compiler actions run in forked workers; publication is coordinated by
    ## per-derivation locks, and the parent decodes each verified artifact.
    ## Other hosts retain the identical topological order with one worker.
    var remaining = plannedLibraries.toHashSet()
    let limit = max(1, effectiveRequest.maxParallelism)
    while remaining.len > 0:
      var ready: seq[string]
      for packageId in remaining:
        let pkg = buildGraph.packagesById[packageId]
        var isReady = true
        for alias in buildGraph.dependencyAliases(packageId):
          if not builtLibraries.hasKey(pkg.dependencyEdges[alias]):
            isReady = false
            break
        if isReady:
          ready.add packageId
      ready.sort()
      if ready.len == 0:
        raiseBuild(becDependencyCycle,
          "library build graph has no schedulable derivation")
      if ready.len > limit:
        ready.setLen(limit)

      # Resolve verified cache hits in the parent before creating workers. A
      # no-op build performs no compiler process spawn; only actual misses are
      # admitted to the parallel batch.
      var misses: seq[string]
      for packageId in ready:
        let pkg = buildGraph.packagesById[packageId]
        let cached = engine.loadCachedArtifact(effectiveRequest, buildGraph,
          pkg, bakGeneLibrary, "library", pkg.library.entry,
          dependencyArtifacts(packageId), artifactRoot, profile)
        if cached.cacheHit:
          builtLibraries[packageId] = cached
          remaining.excl packageId
        else:
          misses.add packageId
      ready = misses
      if ready.len == 0:
        continue

      when defined(posix) and not defined(emscripten) and not defined(geneWasm):
        if limit > 1 and ready.len > 1:
          let workerRoot = artifactRoot / "tmp" / "workers" /
            ($getCurrentProcessId() & "-" &
             sha256Hex(ready.join("\0"))[0 .. 15])
          if dirExists(workerRoot):
            removeDir(workerRoot)
          createDir(workerRoot)
          var workers: seq[tuple[packageId: string, processId: Pid,
                                 statusPath: string, errorPath: string]]
          for packageId in ready:
            let statusPath = workerRoot /
              (sha256Hex(packageId)[0 .. 15] & ".status")
            let errorPath = statusPath & ".error"
            let processId = posix.fork()
            if processId < 0:
              for worker in workers:
                var status: cint
                discard posix.waitpid(worker.processId, status, 0)
              raiseBuild(becRequestInvalid,
                "could not create a parallel build worker", [packageId])
            if processId == 0:
              try:
                let artifact = buildLibraryNow(packageId)
                writeFile(statusPath,
                  if artifact.cacheHit: "cache_hit\n" else: "rebuilt\n")
                posix.exitnow(0)
              except BuildError as error:
                try:
                  writeFile(errorPath, $error.code & "\n" & error.msg & "\n")
                except CatchableError:
                  discard
                posix.exitnow(1)
              except CatchableError as error:
                try:
                  writeFile(errorPath, error.msg & "\n")
                except CatchableError:
                  discard
                posix.exitnow(1)
            workers.add (packageId: packageId, processId: processId,
                         statusPath: statusPath, errorPath: errorPath)

          var workerFailure = ""
          var workerFailureCode = becRequestInvalid
          for worker in workers:
            var status: cint
            discard posix.waitpid(worker.processId, status, 0)
            if status != 0 or not fileExists(worker.statusPath):
              let detail =
                if fileExists(worker.errorPath): readFile(worker.errorPath).strip()
                else: "parallel compiler worker exited without a diagnostic"
              if workerFailure.len == 0:
                var message = detail
                let lines = detail.splitLines()
                if lines.len > 1:
                  try:
                    workerFailureCode = parseEnum[BuildErrorCode](lines[0])
                    message = lines[1 .. ^1].join("\n")
                  except ValueError:
                    discard
                workerFailure = worker.packageId & ": " & message
          if workerFailure.len > 0:
            removeDir(workerRoot)
            raiseBuild(workerFailureCode,
              "parallel compiler action failed", [workerFailure])

          var loadRequest = effectiveRequest
          loadRequest.rebuild = false
          loadRequest.verifyReproducible = false
          for worker in workers:
            var artifact = buildLibraryNow(worker.packageId, loadRequest)
            artifact.cacheHit = readFile(worker.statusPath).strip() == "cache_hit"
            builtLibraries[worker.packageId] = artifact
            remaining.excl worker.packageId
          removeDir(workerRoot)
          continue

      for packageId in ready:
        builtLibraries[packageId] = buildLibraryNow(packageId)
        remaining.excl packageId

  let selectedTarget =
    if effectiveRequest.target.len > 0: effectiveRequest.target
    else: defaultTarget(rootPkg)
  let target = targetEntry(rootPkg, selectedTarget, effectiveRequest.testEntry)
  let aliases = buildGraph.dependencyAliases(rootPkg.id)
  for alias in aliases:
    planLibrary(rootPkg.dependencyEdges[alias])
  if target.kind == bakGeneLibrary:
    planLibrary(rootPkg.id)
  executePlannedLibraries()
  var dependencies: seq[BuildArtifact]
  for alias in aliases:
    dependencies.add builtLibraries[rootPkg.dependencyEdges[alias]]
  if target.kind == bakGeneLibrary:
    result.rootArtifact = builtLibraries[rootPkg.id]
  else:
    for application in rootPkg.applications:
      if application.name == target.name and application.uses.len > 0:
        raiseBuild(becRecipeUnavailable,
          "target recipes are not available in the pure-Gene build phase",
          [rootPkg.name, application.uses.join(", ")])
    result.rootArtifact = engine.buildOne(effectiveRequest, buildGraph, rootPkg,
      target.kind, target.name, target.entry, dependencies, artifactRoot,
      profile)
  for _, artifact in builtLibraries:
    result.artifacts.add artifact
  result.artifacts.sort(proc (a, b: BuildArtifact): int =
    cmp(a.packageId, b.packageId))
  if target.kind != bakGeneLibrary:
    result.artifacts.add result.rootArtifact
  for artifact in result.artifacts:
    if artifact.cacheHit: inc result.cacheHits else: inc result.rebuilt
  result.projectView = projectViewPath(buildGraph, effectiveRequest,
                                       result.rootArtifact)
  materializeProjectView(result.projectView, result.rootArtifact)
  result.explanation =
    if result.rebuilt == 0:
      "cache hit: every derivation and artifact digest matched"
    else:
      "rebuilt " & $result.rebuilt & " derivation(s); reused " &
      $result.cacheHits
  for artifact in result.artifacts:
    result.explanation.add "\n  " &
      (if artifact.cacheHit: "reused " else: "rebuilt ") &
      artifact.packageName & ":" & artifact.target & " — " &
      artifact.cacheReason & " [" & artifact.derivationId & "]"
