## First POSIX install generation: locked source closure, resources, and VM.
## Native artifact staging and hosted coordinates follow in PKG-2/3.

import std/[algorithm, os, osproc, streams, strtabs, strutils, tables]
import ./[build, digest, package, printer, process_lock, types]

when defined(posix):
  import std/posix
  proc cRename(oldPath, newPath: cstring): cint
      {.importc: "rename", header: "<stdio.h>".}

type InstalledReceipt* = object
  generation*: string
  launcher*: string
  packageName*: string
  target*: string

type UninstallReceipt* = object
  removedGenerations*: int
  retainedGenerations*: int

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc syncInstallPath(path: string) =
  when defined(posix):
    let fd = posix.open(path.cstring, posix.O_RDONLY, 0)
    if fd < 0: raiseOSError(osLastError())
    try:
      if posix.fsync(fd) != 0: raiseOSError(osLastError())
    finally:
      discard posix.close(fd)

proc syncInstallTree(root: string) =
  when defined(posix):
    var dirs = @[root]
    var cursor = 0
    while cursor < dirs.len:
      let parent = dirs[cursor]
      for kind, path in walkDir(parent):
        case kind
        of pcDir: dirs.add path
        of pcFile: syncInstallPath(path)
        of pcLinkToFile, pcLinkToDir: discard
      inc cursor
    for i in countdown(dirs.high, 0): syncInstallPath(dirs[i])

proc installPrefixCommon(graph: MaterializedGraph): string =
  result = graph.workspaceRoot
  for _, pkg in graph.packagesById:
    if pkg.sourceKind notin {dskWorkspace, dskPath}:
      continue
    while not containsPath(result, pkg.root):
      let parent = parentDir(result)
      if parent == result:
        raise newException(ValueError,
          "local package roots have no common ancestor")
      result = parent

proc installRelative(root, common: string): string =
  result = relativePath(root, common).replace('\\', '/')
  if result == ".." or result.startsWith("../") or
      result.isAbsolute:
    raise newException(ValueError,
      "package root escapes the installation source layout: " & root)

proc copyLocalClosure(graph: MaterializedGraph, destination,
                      common: string) =
  var locals: seq[Package]
  for _, pkg in graph.packagesById:
    if pkg.sourceKind in {dskWorkspace, dskPath}:
      locals.add pkg
  locals.sort(proc (a, b: Package): int = cmp(a.root.len, b.root.len))
  for pkg in locals:
    let target = destination / installRelative(pkg.root, common)
    createDir(parentDir(target))
    materializeSourceTree(pkg, target)
    let copied = loadPackageAt(target, poApplicationStore)
    let copiedDigest = sourceTreeDigest(copied)
    let expectedDigest =
      if pkg.treeDigest.len > 0: pkg.treeDigest else: sourceTreeDigest(pkg)
    if copiedDigest != expectedDigest:
      raise newException(ValueError,
        "installed package copy failed digest check: " & pkg.name &
        " expected " & expectedDigest & " got " & copiedDigest)

proc installManifest(graph: MaterializedGraph, built: BuildResult,
                     app: ApplicationTarget, executableDigest: string,
                     sourceRelative: string): string =
  var fields = initPropTable()
  fields["install_format"] = newInt(1)
  fields["package_id"] = newStr(graph.activePackageId)
  fields["package_name"] = newStr(built.rootArtifact.packageName)
  fields["target"] = newStr(app.name)
  fields["artifact_digest"] = newStr(built.rootArtifact.artifactDigest)
  fields["lock_digest"] = newStr(graph.lockDigest)
  fields["runtime_digest"] = newStr(executableDigest)
  fields["source_relative"] = newStr(sourceRelative)
  fields["pkg_config_path"] = newStr(getEnv("GENE_PKG_CONFIG_PATH"))
  fields["sdk_root"] = newStr(getEnv("SDKROOT"))
  var native: seq[Value]
  for artifact in built.artifacts:
    for resource in artifact.resources:
      if resource.nativeAlias.len == 0: continue
      var item = initPropTable()
      item["package_id"] = newStr(artifact.packageId)
      item["alias"] = newStr(resource.nativeAlias)
      item["target"] = newStr(resource.nativeTarget)
      item["abi_kind"] = newSym(resource.abiKind)
      item["abi_version"] = newInt(resource.abiVersion)
      item["digest"] = newStr(resource.digest)
      var requirements: seq[Value]
      for evidence in resource.systemEvidence:
        requirements.add newStr(evidence)
      item["system_evidence"] = newList(requirements)
      native.add newMap(item)
  if native.len > 0:
    native.sort(proc (a, b: Value): int =
      cmp(a.mapEntries["package_id"].strVal & ":" &
          a.mapEntries["alias"].strVal,
          b.mapEntries["package_id"].strVal & ":" &
          b.mapEntries["alias"].strVal))
    fields["native_artifacts"] = newList(native)
  newMap(fields).print() & "\n"

proc installedObjectPath(root, digest: string): string =
  if not digest.startsWith("sha256:") or digest.len != 71:
    raise newException(ValueError, "invalid native artifact digest")
  let hex = digest[7 .. ^1]
  root / "objects" / "sha256" / hex[0 .. 1] / hex[2 .. ^1]

proc stageArtifactClosure(root: string, built: BuildResult): string =
  ## Copy only verified, declared artifact files into the generation.
  for artifact in built.artifacts:
    if not verifyArtifactObject(artifact.objectPath,
        artifact.artifactDigest, artifact.derivationId, artifact.kind):
      raise newException(ValueError,
        "build artifact disappeared before installation")
    let target = installedObjectPath(root, artifact.artifactDigest)
    createDir(target)
    copyFile(artifact.objectPath / "artifact.gir", target / "artifact.gir")
    copyFile(artifact.objectPath / "metadata.gene", target / "metadata.gene")
    for resource in artifact.resources:
      if resource.builtRelative.len == 0: continue
      if result.len > 0 and result != resource.compilerEvidence:
        raise newException(ValueError,
          "installation contains conflicting C compiler evidence")
      result = resource.compilerEvidence
      let destination = target / resource.builtRelative
      createDir(parentDir(destination))
      copyFile(artifact.objectPath / resource.builtRelative, destination)
    discard verifyArtifactObject(target, artifact.artifactDigest,
                                 artifact.derivationId, artifact.kind)
    let index = root / "derivations" / "sha256" /
      artifact.derivationId[7 .. ^1] / "index.gene"
    createDir(parentDir(index))
    writeFile(index, "{^state active ^artifact_digest \"" &
      artifact.artifactDigest & "\" ^observations [\"" &
      artifact.artifactDigest & "\"]}\n")

proc verifyGeneration(generation, expectedManifest,
                      executableDigest: string,
                      graph: MaterializedGraph, common: string,
                      built: BuildResult) =
  if not fileExists(generation / "install.gene") or
      readFile(generation / "install.gene") != expectedManifest or
      not fileExists(generation / "bin" / "gene") or
      not fileExists(generation / "c-compiler-evidence.txt") or
      not fileExists(generation / "pkg-config-path.txt") or
      "sha256:" & sha256File(generation / "bin" / "gene") != executableDigest:
    raise newException(ValueError,
      "existing installation generation failed verification: " & generation)
  var expectedCompilerEvidence = ""
  for artifact in built.artifacts:
    for resource in artifact.resources:
      if resource.builtRelative.len == 0: continue
      if expectedCompilerEvidence.len > 0 and
          expectedCompilerEvidence != resource.compilerEvidence:
        raise newException(ValueError,
          "installation has conflicting compiler evidence")
      expectedCompilerEvidence = resource.compilerEvidence
  if readFile(generation / "c-compiler-evidence.txt").strip() !=
      expectedCompilerEvidence:
    raise newException(ValueError,
      "installed C compiler evidence changed: " & generation)
  if readFile(generation / "pkg-config-path.txt").strip() !=
      getEnv("GENE_PKG_CONFIG_PATH"):
    raise newException(ValueError,
      "installed system dependency search path changed: " & generation)
  for _, pkg in graph.packagesById:
    if pkg.sourceKind notin {dskWorkspace, dskPath}:
      continue
    let installed = generation / "sources" / installRelative(pkg.root, common)
    if not fileExists(installed / "package.gene"):
      raise newException(ValueError,
        "installed package is missing: " & pkg.name)
    let actual = loadPackageAt(installed, poApplicationStore)
    let expectedDigest =
      if pkg.treeDigest.len > 0: pkg.treeDigest else: sourceTreeDigest(pkg)
    if sourceTreeDigest(actual) != expectedDigest:
      raise newException(ValueError,
        "installed package changed after publication: " & pkg.name)
  for artifact in built.artifacts:
    let objectPath = installedObjectPath(generation / "artifacts",
                                         artifact.artifactDigest)
    if not verifyArtifactObject(objectPath, artifact.artifactDigest,
                                artifact.derivationId, artifact.kind):
      raise newException(ValueError,
        "installed artifact is missing: " & artifact.packageName)
    let index = generation / "artifacts" / "derivations" / "sha256" /
      artifact.derivationId[7 .. ^1] / "index.gene"
    let expectedIndex = "{^state active ^artifact_digest \"" &
      artifact.artifactDigest & "\" ^observations [\"" &
      artifact.artifactDigest & "\"]}\n"
    if not fileExists(index) or readFile(index) != expectedIndex:
      raise newException(ValueError,
        "installed artifact index changed: " & artifact.packageName)

proc writeLauncher(path, body, owner: string) =
  if fileExists(path) and not readFile(path).startsWith("#!/bin/sh\n# gene-install " & owner & "\n"):
    raise newException(ValueError, "launcher is owned by another application: " & path)
  let temporary = path & ".tmp-" & $getCurrentProcessId()
  writeFile(temporary, body)
  setFilePermissions(temporary, {fpUserRead, fpUserWrite, fpUserExec,
                                 fpGroupRead, fpGroupExec,
                                 fpOthersRead, fpOthersExec})
  try:
    syncInstallPath(temporary)
    when defined(posix):
      if cRename(temporary.cstring, path.cstring) != 0:
        raiseOSError(osLastError())
    else:
      moveFile(temporary, path)
    syncInstallPath(parentDir(path))
  except CatchableError:
    if fileExists(temporary): removeFile(temporary)
    raise

proc installLocal*(graph: MaterializedGraph, built: BuildResult,
                   app: ApplicationTarget, prefix, executable: string):
                   InstalledReceipt =
  when not defined(posix):
    raise newException(ValueError,
      "PKG-1 install currently requires a POSIX host")
  else:
    if built.rootArtifact.kind != bakGeneApplication or
        built.rootArtifact.target != app.name or graph.lockDigest.len == 0:
      raise newException(ValueError,
        "install requires a locked, built application target")
    let active = graph.packagesById[graph.activePackageId]
    let common = installPrefixCommon(graph)
    let workspaceRelative = installRelative(graph.workspaceRoot, common)
    let activeRelative = installRelative(active.root, common)
    let absolutePrefix = normalizedPath(absolutePath(prefix))
    let owner = active.name & ":" & app.name
    let key = active.name.replace('/', '_') & "-" & app.name
    let appBase = absolutePrefix / "apps" / key
    let generations = appBase / "generations"
    let launcherDir = absolutePrefix / "bin"
    let launcher = launcherDir / app.name
    createDir(generations)
    createDir(launcherDir)
    syncInstallPath(parentDir(absolutePrefix))
    syncInstallPath(absolutePrefix)
    syncInstallPath(absolutePrefix / "apps")
    syncInstallPath(appBase)
    syncInstallPath(generations)
    syncInstallPath(launcherDir)
    let lock = acquireProcessFileLock(appBase & ".lock")
    try:
      let executableDigest = "sha256:" & sha256File(executable)
      let generationId = sha256Hex("gene-install-bundle-v5\0" & owner & "\0" &
        built.rootArtifact.artifactDigest & "\0" & graph.lockDigest & "\0" &
        executableDigest & "\0" & getEnv("GENE_PKG_CONFIG_PATH") & "\0" &
        getEnv("SDKROOT"))
      let generation = generations / generationId
      let manifest = installManifest(graph, built, app, executableDigest,
                                     activeRelative)
      if not dirExists(generation):
        let staged = generations / (".tmp-" & generationId & "-" &
                                     $getCurrentProcessId())
        if dirExists(staged): removeDir(staged)
        createDir(staged)
        try:
          createDir(staged / "bin")
          createDir(staged / "leases")
          copyFile(executable, staged / "bin" / "gene")
          setFilePermissions(staged / "bin" / "gene",
            {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
             fpOthersRead, fpOthersExec})
          copyLocalClosure(graph, staged / "sources", common)
          let relocatedWorkspace = staged / "sources" / workspaceRelative
          createDir(relocatedWorkspace)
          let originalLock = graph.workspaceRoot / "package.gene.lock"
          if not fileExists(originalLock):
            raise newException(ValueError, "package lock disappeared during install")
          copyFile(originalLock, relocatedWorkspace / "package.gene.lock")
          let manager = newPackageManager()
          discard manager.vendor(graph, VendorRequest(
            destination: relocatedWorkspace / "vendor" / "packages"))
          let compilerEvidence = stageArtifactClosure(staged / "artifacts", built)
          writeFile(staged / "c-compiler-evidence.txt", compilerEvidence & "\n")
          writeFile(staged / "pkg-config-path.txt",
                    getEnv("GENE_PKG_CONFIG_PATH") & "\n")
          writeFile(staged / "sdk-root.txt", getEnv("SDKROOT") & "\n")
          let relocatedActive = staged / "sources" / activeRelative
          let preflightCache = appBase /
            (".preflight-cache-" & $getCurrentProcessId())
          if dirExists(preflightCache):
            makeMaterializedTreeWritable(preflightCache)
            removeDir(preflightCache)
          defer:
            if dirExists(preflightCache):
              makeMaterializedTreeWritable(preflightCache)
              removeDir(preflightCache)
          let preflightEnv = newStringTable(modeCaseSensitive)
          for key, value in envPairs(): preflightEnv[key] = value
          preflightEnv["GENE_INSTALLED_ARTIFACTS"] = staged / "artifacts"
          preflightEnv["GENE_ARTIFACT_STORE"] = preflightCache
          preflightEnv["GENE_C_COMPILER_EVIDENCE"] = compilerEvidence
          preflightEnv["GENE_C_COMPILER"] = staged / "missing-compiler"
          preflightEnv["GENE_PKG_CONFIG_PATH"] = getEnv("GENE_PKG_CONFIG_PATH")
          let preflight = startProcess(staged / "bin" / "gene", "",
            args = @["build", app.name, "--package-root", relocatedActive,
                     "--locked", "--offline", "--profile", "release"],
            env = preflightEnv,
            options = {poStdErrToStdOut})
          let output = preflight.outputStream.readAll()
          let exitCode = preflight.waitForExit()
          preflight.close()
          if exitCode != 0:
            raise newException(ValueError,
              "installed offline build failed: " & output)
          writeFile(staged / "install.gene", manifest)
          syncInstallTree(staged)
          moveDir(staged, generation)
          syncInstallPath(generations)
        except CatchableError:
          if dirExists(staged): removeDir(staged)
          raise
      verifyGeneration(generation, manifest, executableDigest, graph, common,
                       built)
      if not dirExists(generation / "leases"):
        createDir(generation / "leases")
      let launcherLock = acquireProcessFileLock(launcherDir / ".install.lock")
      try:
        # A collision must fail before changing an existing application's
        # current pointer. This prefix-wide lock also serializes two apps
        # trying to claim the same launcher name.
        if fileExists(launcher) and not readFile(launcher).startsWith(
            "#!/bin/sh\n# gene-install " & owner & "\n"):
          raise newException(ValueError,
            "launcher is owned by another application: " & launcher)
        let body = "#!/bin/sh\n# gene-install " & owner & "\n" &
          "generation=$(CDPATH= cd -P -- " & shellQuote(appBase / "current") &
          " && pwd) || exit 1\n" &
          "lease=\"$generation/leases/$$\"\n" &
          "printf '%s\\n' \"$$\" > \"$lease\" || exit 1\n" &
          "trap 'rm -f \"$lease\"' EXIT HUP INT TERM\n" &
          "GENE_INSTALLED_ARTIFACTS=\"$generation/artifacts\"\n" &
          "GENE_C_COMPILER_EVIDENCE=" & shellQuote(
            readFile(generation / "c-compiler-evidence.txt").strip()) & "\n" &
          "GENE_PKG_CONFIG_PATH=" & shellQuote(
            readFile(generation / "pkg-config-path.txt").strip()) & "\n" &
          "SDKROOT=" & shellQuote(
            readFile(generation / "sdk-root.txt").strip()) & "\n" &
          "export GENE_INSTALLED_ARTIFACTS GENE_C_COMPILER_EVIDENCE GENE_PKG_CONFIG_PATH SDKROOT\n" &
          "\"$generation/bin/gene\" run --package-root " &
          "\"$generation/sources/\"" & shellQuote(activeRelative) &
          " --locked --offline --profile release " &
          shellQuote(app.name) & " -- \"$@\"\n" &
          "status=$?\nexit \"$status\"\n"
        let hadLauncher = fileExists(launcher)
        if hadLauncher and readFile(launcher) != body:
          writeLauncher(launcher, body, owner)
        let current = appBase / "current"
        let pending = appBase / (".current-" & $getCurrentProcessId())
        if symlinkExists(pending): removeFile(pending)
        createSymlink("generations/" & generationId, pending)
        if cRename(pending.cstring, current.cstring) != 0:
          removeFile(pending)
          raiseOSError(osLastError())
        syncInstallPath(appBase)
        if not hadLauncher:
          writeLauncher(launcher, body, owner)
        result = InstalledReceipt(generation: generation, launcher: launcher,
                                  packageName: active.name, target: app.name)
      finally:
        launcherLock.release()
    finally:
      lock.release()

proc validInstallName(value: string, allowSlash: bool): bool =
  if value.len == 0: return false
  var slashCount = 0
  for ch in value:
    case ch
    of 'a'..'z', '0'..'9', '_': discard
    of '/':
      if not allowSlash: return false
      inc slashCount
    else: return false
  result = if allowSlash: slashCount == 1 and not value.startsWith('/') and
                     not value.endsWith('/')
           else: true

proc liveGenerationLease(generation: string): bool =
  let leases = generation / "leases"
  if not dirExists(leases): return false
  for kind, path in walkDir(leases):
    if kind != pcFile: return true
    var owner = 0
    try:
      owner = parseInt(readFile(path).strip())
    except CatchableError:
      return true # An unrecognized lease is not permission to remove files.
    if processAlive(owner):
      return true
    removeFile(path)
  result = false

proc installDirEmpty(path: string): bool =
  if not dirExists(path): return true
  for _ in walkDir(path): return false
  result = true

proc uninstallLocal*(name, target, prefix: string): UninstallReceipt =
  when not defined(posix):
    raise newException(ValueError, "uninstall currently requires a POSIX host")
  else:
    if not validInstallName(name, true) or
        not validInstallName(target, false):
      raise newException(ValueError, "uninstall expects owner/name:target")
    let absolutePrefix = normalizedPath(absolutePath(prefix))
    let appBase = absolutePrefix / "apps" /
      (name.replace('/', '_') & "-" & target)
    if not dirExists(appBase): return
    let launcher = absolutePrefix / "bin" / target
    let appLock = acquireProcessFileLock(appBase & ".lock")
    try:
      let launcherLock = acquireProcessFileLock(
        absolutePrefix / "bin" / ".install.lock")
      try:
        if fileExists(launcher):
          if not readFile(launcher).startsWith(
              "#!/bin/sh\n# gene-install " & name & ":" & target & "\n"):
            raise newException(ValueError,
              "launcher is owned by another application: " & launcher)
          removeFile(launcher)
          syncInstallPath(parentDir(launcher))
        let current = appBase / "current"
        if symlinkExists(current):
          let link = expandSymlink(current)
          if link.len <= "generations/".len or
              not link.startsWith("generations/") or
              '/' in link["generations/".len .. ^1]:
            raise newException(ValueError,
              "installed current pointer is not a generation")
          removeFile(current)
          syncInstallPath(appBase)
      finally:
        launcherLock.release()
      let generations = appBase / "generations"
      if dirExists(generations):
        for kind, path in walkDir(generations):
          if kind != pcDir: continue
          if liveGenerationLease(path):
            inc result.retainedGenerations
          else:
            removeDir(path)
            inc result.removedGenerations
        syncInstallPath(generations)
      if result.retainedGenerations == 0:
        if installDirEmpty(generations) and dirExists(generations):
          removeDir(generations)
        if installDirEmpty(appBase) and dirExists(appBase):
          removeDir(appBase)
          syncInstallPath(absolutePrefix / "apps")
    finally:
      appLock.release()
