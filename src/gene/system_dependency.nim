## Host system-library discovery behind the package-build resolver seam.

import std/[algorithm, cmdline, os, osproc, sequtils, sets, streams, strtabs,
            strutils, tables, tempfiles, times]
import ./[digest, package, types]

type
  SystemDependencyErrorCode* = enum
    sdecProviderUnavailable = "SYSTEM_DEPENDENCY_PROVIDER_UNAVAILABLE"
    sdecQueryFailed = "SYSTEM_DEPENDENCY_QUERY_FAILED"
    sdecVersionMismatch = "SYSTEM_DEPENDENCY_VERSION_MISMATCH"
    sdecLibraryMissing = "SYSTEM_DEPENDENCY_LIBRARY_MISSING"

  SystemDependencyError* = object of GeneError
    code*: SystemDependencyErrorCode

  PathDigest* = object
    path*: string
    digest*: string

  PkgConfigPolicy* = object
    executable*: string
    sysroot*: string
    searchPaths*: seq[string]
    librarySearchPaths*: seq[string]
    environment*: Table[string, string]

  SystemDependencyPolicy* = object
    providerOrder*: seq[SystemProviderKind]
    pkgConfig*: PkgConfigPolicy

  SystemDependencyRequest* = object
    requirement*: SystemLibraryRequirement
    targetTriple*: string
    toolchainIdentity*: string

  SystemDependencyResult* = object
    alias*: string
    name*: string
    version*: string
    targetTriple*: string
    abi*: string
    headerRoots*: seq[PathDigest]
    libraryRoots*: seq[PathDigest]
    libraryFiles*: seq[PathDigest]
    compileDefinitions*: seq[string]
    compileOptions*: seq[string]
    linkNames*: seq[string]
    linkOptions*: seq[string]
    provider*: SystemProviderKind
    providerIdentity*: string
    query*: seq[string]
    linkage*: SystemLinkage
    redistribution*: string
    canonicalDigest*: string

  CachedPathDigest = object
    stamp: string
    value: PathDigest

  SystemDependencyResolver* = ref object
    policy*: SystemDependencyPolicy
    pathDigests: Table[string, CachedPathDigest]

proc raiseSystemDependency(code: SystemDependencyErrorCode, message: string,
                           details: openArray[string] = []) =
  var error: ref SystemDependencyError
  new(error)
  error.code = code
  error.msg = $code & ": " & message
  for detail in details:
    error.msg.add "\n  " & detail
  raise error

type CapturedProcess = object
  output: string
  diagnostics: string
  exitCode: int

proc runCaptured(executable: string, args: openArray[string],
                 environment: StringTableRef): CapturedProcess =
  ## Keep stdout parseable and stderr diagnostic-only without risking the
  ## classic two-pipe deadlock. A securely-created temporary file drains
  ## stderr directly in the child; every command component is shell-quoted.
  let (diagnosticFile, diagnosticPath) =
    createTempFile("gene-pkg-config-", ".stderr")
  diagnosticFile.close()
  defer:
    if fileExists(diagnosticPath):
      removeFile(diagnosticPath)
  var commandParts = @[executable]
  commandParts.add args
  let command = quoteShellCommand(commandParts) & " 2>" &
                quoteShell(diagnosticPath)
  let process = startProcess(command, env = environment,
                             options = {poEvalCommand})
  try:
    result.output = process.outputStream.readAll()
    result.exitCode = process.waitForExit()
  finally:
    process.close()
  result.diagnostics = readFile(diagnosticPath)

proc defaultSystemDependencyPolicy*(): SystemDependencyPolicy =
  result.providerOrder = @[spkPkgConfig]
  result.pkgConfig.executable = findExe("pkg-config")
  if result.pkgConfig.executable.len > 0:
    let emptyEnvironment = newStringTable(modeCaseSensitive)
    try:
      let captured = runCaptured(result.pkgConfig.executable,
        ["--variable=pc_path", "pkg-config"], emptyEnvironment)
      let compiledSearchPath = captured.output.strip()
      if captured.exitCode == 0 and compiledSearchPath.len > 0:
        result.pkgConfig.librarySearchPaths = compiledSearchPath.split(PathSep)
    except OSError, IOError:
      discard

proc newSystemDependencyResolver*(policy = defaultSystemDependencyPolicy()):
                                  SystemDependencyResolver =
  SystemDependencyResolver(policy: policy,
    pathDigests: initTable[string, CachedPathDigest]())

proc fileDigest(path: string): string =
  let before = getFileInfo(path)
  var file: File
  if not open(file, path, fmRead):
    raiseSystemDependency(sdecLibraryMissing,
      "system dependency file is unavailable", [path])
  var context = initSha256()
  var buffer: array[64 * 1024, byte]
  try:
    while true:
      let count = file.readBuffer(addr buffer[0], buffer.len)
      if count <= 0:
        break
      context.update(buffer.toOpenArray(0, count - 1))
  finally:
    close(file)
  let after = getFileInfo(path)
  if before.id.device != after.id.device or before.id.file != after.id.file or
      before.size != after.size or
      before.lastWriteTime != after.lastWriteTime or
      before.creationTime != after.creationTime:
    raiseSystemDependency(sdecQueryFailed,
      "system dependency file changed while it was hashed", [path])
  "sha256:" & context.finishHex()

proc updateLength(context: var Sha256Context, value: uint64) =
  var bytes: array[8, byte]
  for i in 0 ..< 8:
    bytes[i] = byte((value shr ((7 - i) * 8)) and 0xff'u64)
  context.update(bytes)

proc updateField(context: var Sha256Context, value: string) =
  context.updateLength(uint64(value.len))
  context.update(value)

type PathScan = object
  stamp: string
  digest: string

proc sameIdentityAndTimes(a, b: FileInfo): bool =
  a.id.device == b.id.device and a.id.file == b.id.file and
    a.size == b.size and a.lastWriteTime == b.lastWriteTime and
    a.creationTime == b.creationTime

proc scanPath(path: string, includeContent: bool): PathScan =
  ## Metadata is an invalidation index, never the ABI identity. A cache miss
  ## computes stamp and content in one traversal. Warm queries walk metadata
  ## only. Symlinks retain their link text in the identity and follow their
  ## targets for metadata/content, with directory-identity cycle detection;
  ## changing an external target therefore invalidates the ABI input.
  let normalized = normalizedPath(absolutePath(path))
  var stampContext = initSha256()
  stampContext.update("gene-system-stamp-v2\0")
  var digestContext = initSha256()
  digestContext.update("gene-system-tree-v2\0")
  var activeDirectories = initHashSet[string]()

  proc updateInfo(context: var Sha256Context, info: FileInfo) =
    for value in [$info.id.device, $info.id.file, $info.size,
                  $info.lastWriteTime.toUnix,
                  $info.lastWriteTime.nanosecond,
                  $info.creationTime.toUnix,
                  $info.creationTime.nanosecond,
                  $(fpUserExec in info.permissions),
                  $(fpGroupExec in info.permissions),
                  $(fpOthersExec in info.permissions)]:
      context.updateField(value)

  proc addMetadata(candidate, relative: string, kind: PathComponent) =
    stampContext.updateField(relative)
    stampContext.updateField($kind)
    if kind in {pcLinkToFile, pcLinkToDir}:
      stampContext.updateField(expandSymlink(candidate))
    stampContext.updateInfo(getFileInfo(candidate, followSymlink = false))
    if kind in {pcLinkToFile, pcLinkToDir}:
      # lstat alone misses mutations behind an external symlink.
      stampContext.updateInfo(getFileInfo(candidate, followSymlink = true))

  proc addContentFile(tag, relative, candidate: string,
                      linkTarget = "") =
    if not includeContent:
      return
    digestContext.update(tag)
    digestContext.updateField(relative)
    if linkTarget.len > 0:
      digestContext.updateField(linkTarget)
    digestContext.updateField(fileDigest(candidate))

  proc walk(dir, relative: string) =
    let before = getFileInfo(dir, followSymlink = true)
    let directoryKey = $before.id.device & ":" & $before.id.file
    if activeDirectories.containsOrIncl(directoryKey):
      raiseSystemDependency(sdecLibraryMissing,
        "system dependency symlink directory cycle", [dir])
    defer:
      activeDirectories.excl directoryKey
    var children: seq[tuple[kind: PathComponent, path: string]]
    for kind, child in walkDir(dir, relative = false):
      children.add (kind, child)
    children.sort(proc (a, b: tuple[kind: PathComponent, path: string]): int =
      cmp(extractFilename(a.path), extractFilename(b.path)))
    for child in children:
      let name = extractFilename(child.path)
      let rel = if relative.len > 0: relative & "/" & name else: name
      addMetadata(child.path, rel, child.kind)
      case child.kind
      of pcDir:
        if includeContent:
          digestContext.update("dir\0")
          digestContext.updateField(rel)
        walk(child.path, rel)
      of pcFile:
        addContentFile("file\0", rel, child.path)
      of pcLinkToFile:
        addContentFile("link_file\0", rel, child.path,
                       expandSymlink(child.path))
      of pcLinkToDir:
        if includeContent:
          digestContext.update("link_dir\0")
          digestContext.updateField(rel)
          digestContext.updateField(expandSymlink(child.path))
        walk(child.path, rel)
    let after = getFileInfo(dir, followSymlink = true)
    if not sameIdentityAndTimes(before, after):
      raiseSystemDependency(sdecQueryFailed,
        "system dependency directory changed while it was hashed", [dir])

  if symlinkExists(normalized):
    let kind = if dirExists(normalized): pcLinkToDir else: pcLinkToFile
    if not dirExists(normalized) and not fileExists(normalized):
      raiseSystemDependency(sdecLibraryMissing,
        "system dependency symlink target does not exist", [normalized])
    addMetadata(normalized, "", kind)
    if kind == pcLinkToDir:
      if includeContent:
        digestContext.update("root_link_dir\0")
        digestContext.updateField(expandSymlink(normalized))
      walk(normalized, "")
    else:
      addContentFile("root_link_file\0", "", normalized,
                     expandSymlink(normalized))
  elif fileExists(normalized):
    addMetadata(normalized, "", pcFile)
    addContentFile("root_file\0", "", normalized)
  elif dirExists(normalized):
    addMetadata(normalized, "", pcDir)
    walk(normalized, "")
  else:
    raiseSystemDependency(sdecLibraryMissing,
      "system dependency path does not exist", [normalized])
  result.stamp = "sha256:" & stampContext.finishHex()
  if includeContent:
    result.digest = "sha256:" & digestContext.finishHex()

proc cachedPathDigest(resolver: SystemDependencyResolver,
                      path: string): PathDigest =
  let normalized = normalizedPath(absolutePath(path))
  when defined(posix):
    if resolver.pathDigests.hasKey(normalized):
      let metadata = scanPath(normalized, includeContent = false)
      if resolver.pathDigests[normalized].stamp == metadata.stamp:
        return resolver.pathDigests[normalized].value
  # Non-POSIX hosts do not universally expose a metadata-change timestamp.
  # Hash bytes on every query rather than accepting a stale ABI identity.
  let scanned = scanPath(normalized, includeContent = true)
  result = PathDigest(path: normalized, digest: scanned.digest)
  resolver.pathDigests[normalized] = CachedPathDigest(stamp: scanned.stamp,
                                                       value: result)

proc controlledEnvironment(policy: PkgConfigPolicy): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in policy.environment:
    result[key] = value
  result["PKG_CONFIG_PATH"] = policy.searchPaths.join($PathSep)
  result["PKG_CONFIG_LIBDIR"] = policy.librarySearchPaths.join($PathSep)
  result["PKG_CONFIG_SYSROOT_DIR"] = policy.sysroot

proc runProvider(executable: string, args: seq[string],
                 environment: StringTableRef): string =
  if executable.len == 0 or not fileExists(executable):
    raiseSystemDependency(sdecProviderUnavailable,
      "pkg_config executable is unavailable", [executable])
  let captured = runCaptured(executable, args, environment)
  if captured.exitCode != 0:
    raiseSystemDependency(sdecQueryFailed,
      "pkg_config query failed",
      ["command: " & executable & " " & args.join(" "),
       "exit code: " & $captured.exitCode,
       captured.diagnostics.strip()])
  result = captured.output.strip()

proc moduleNames(requirement: SystemLibraryRequirement): seq[string] =
  result.add requirement.name
  result.add requirement.components

proc addUnique(items: var seq[string], item: string) =
  if item notin items:
    items.add item

proc parseCompileFlags(resolver: SystemDependencyResolver, flags: string,
                       result: var SystemDependencyResult) =
  let tokens = parseCmdLine(flags)
  var i = 0
  while i < tokens.len:
    let token = tokens[i]
    if token == "-I" and i + 1 < tokens.len:
      inc i
      result.headerRoots.add resolver.cachedPathDigest(tokens[i])
    elif token.startsWith("-I") and token.len > 2:
      result.headerRoots.add resolver.cachedPathDigest(token[2 .. ^1])
    elif token == "-D" and i + 1 < tokens.len:
      inc i
      result.compileDefinitions.addUnique(tokens[i])
    elif token.startsWith("-D") and token.len > 2:
      result.compileDefinitions.addUnique(token[2 .. ^1])
    else:
      result.compileOptions.add token
    inc i

proc libraryCandidates(root, name: string,
                       linkage: SystemLinkage): seq[string] =
  let staticName = root / ("lib" & name & ".a")
  when defined(macosx):
    let dynamicNames = @[root / ("lib" & name & ".dylib"),
                         root / ("lib" & name & ".tbd")]
  elif defined(windows):
    let dynamicNames = @[root / (name & ".dll"), root / (name & ".lib")]
  else:
    let dynamicNames = @[root / ("lib" & name & ".so")]
  case linkage
  of slStatic:
    result.add staticName
  of slDynamic:
    result.add dynamicNames
  of slEither:
    result.add dynamicNames
    result.add staticName

proc parseLinkFlags(resolver: SystemDependencyResolver, flags: string,
                    result: var SystemDependencyResult) =
  let tokens = parseCmdLine(flags)
  var roots: seq[string]
  for root in result.libraryRoots:
    roots.addUnique(root.path)
  var absoluteLibraries: seq[string]
  var i = 0
  while i < tokens.len:
    let token = tokens[i]
    if token == "-L" and i + 1 < tokens.len:
      inc i
      roots.addUnique(normalizedPath(absolutePath(tokens[i])))
    elif token.startsWith("-L") and token.len > 2:
      roots.addUnique(normalizedPath(absolutePath(token[2 .. ^1])))
    elif token == "-l" and i + 1 < tokens.len:
      inc i
      result.linkNames.addUnique(tokens[i])
    elif token.startsWith("-l") and token.len > 2:
      result.linkNames.addUnique(token[2 .. ^1])
    elif token.isAbsolute and fileExists(token):
      absoluteLibraries.add token
    else:
      result.linkOptions.add token
    inc i
  for root in roots:
    var known = false
    for existing in result.libraryRoots:
      if existing.path == root:
        known = true
        break
    if not known:
      result.libraryRoots.add PathDigest(
        path: root, digest: "sha256:" & sha256Hex("search-root\0" & root))
  for path in absoluteLibraries:
    result.libraryFiles.add resolver.cachedPathDigest(path)
  for name in result.linkNames:
    var found = ""
    for root in roots:
      for candidate in libraryCandidates(root, name, result.linkage):
        if fileExists(candidate):
          found = candidate
          break
      if found.len > 0:
        break
    if found.len == 0:
      raiseSystemDependency(sdecLibraryMissing,
        "pkg_config named a library that was not found",
        ["library: " & name, "search roots: " & roots.join(", ")])
    result.libraryFiles.add resolver.cachedPathDigest(found)

proc valueList(values: seq[string]): Value =
  var items: seq[Value]
  for value in values:
    items.add newStr(value)
  result = newList(items)

proc pathDigestValues(values: seq[PathDigest]): Value =
  var items: seq[Value]
  for value in values:
    var entries = initPropTable()
    entries["path"] = newStr(value.path)
    entries["digest"] = newStr(value.digest)
    items.add newMap(entries)
  result = newList(items)

proc resultDigest(resolved: SystemDependencyResult): string =
  var entries = initPropTable()
  entries["alias"] = newStr(resolved.alias)
  entries["name"] = newStr(resolved.name)
  entries["version"] = newStr(resolved.version)
  entries["target_triple"] = newStr(resolved.targetTriple)
  entries["abi"] = newStr(resolved.abi)
  entries["header_roots"] = pathDigestValues(resolved.headerRoots)
  entries["library_roots"] = pathDigestValues(resolved.libraryRoots)
  entries["library_files"] = pathDigestValues(resolved.libraryFiles)
  entries["compile_definitions"] = valueList(resolved.compileDefinitions)
  entries["compile_options"] = valueList(resolved.compileOptions)
  entries["link_names"] = valueList(resolved.linkNames)
  entries["link_options"] = valueList(resolved.linkOptions)
  entries["provider"] = newSym($resolved.provider)
  entries["provider_identity"] = newStr(resolved.providerIdentity)
  entries["query"] = valueList(resolved.query)
  entries["linkage"] = newSym($resolved.linkage)
  entries["redistribution"] = newStr(resolved.redistribution)
  result = canonicalDigest(newMap(entries))

proc resolvePkgConfig(resolver: SystemDependencyResolver,
                      policy: PkgConfigPolicy,
                      request: SystemDependencyRequest):
                      SystemDependencyResult =
  let environment = controlledEnvironment(policy)
  let modules = moduleNames(request.requirement)
  result.alias = request.requirement.alias
  result.name = request.requirement.name
  result.targetTriple = request.targetTriple
  result.abi = request.targetTriple
  result.provider = spkPkgConfig
  result.linkage = request.requirement.linkage
  result.query = modules
  result.redistribution = "system"
  result.providerIdentity = "sha256:" & sha256Hex(
    fileDigest(policy.executable) & "\0" & policy.sysroot & "\0" &
    policy.searchPaths.join("\0") & "\0" &
    policy.librarySearchPaths.join("\0") & "\0" &
    request.toolchainIdentity)
  let versionOutput = runProvider(policy.executable,
                                  @["--modversion"] & modules, environment)
  if versionOutput.len == 0:
    raiseSystemDependency(sdecQueryFailed,
      "pkg_config returned an empty version",
      ["library: " & request.requirement.name])
  result.version = versionOutput.splitLines()[0].strip()
  if not matchesConstraint(result.version, request.requirement.version,
                           request.requirement.alias):
    raiseSystemDependency(sdecVersionMismatch,
      "system library version does not satisfy the manifest",
      ["library: " & request.requirement.name,
       "required: " & request.requirement.version,
       "found: " & result.version])
  let compileFlags = runProvider(policy.executable,
                                 @["--cflags"] & modules, environment)
  parseCompileFlags(resolver, compileFlags, result)
  if result.headerRoots.len == 0:
    for module in modules:
      let includeDir = runProvider(policy.executable,
        @["--variable=includedir", module], environment)
      if includeDir.len > 0 and dirExists(includeDir):
        result.headerRoots.add resolver.cachedPathDigest(includeDir)
  let linkFlags = runProvider(policy.executable,
                              @["--libs"] & modules, environment)
  if not parseCmdLine(linkFlags).anyIt(it == "-L" or it.startsWith("-L")):
    for module in modules:
      let libraryDir = runProvider(policy.executable,
        @["--variable=libdir", module], environment)
      if libraryDir.len > 0:
        let normalized = normalizedPath(absolutePath(libraryDir))
        result.libraryRoots.add PathDigest(
          path: normalized,
          digest: "sha256:" & sha256Hex("search-root\0" & normalized))
  when defined(macosx):
    var extraRoots: seq[string]
    for header in result.headerRoots:
      let marker = "/usr/include"
      if header.path.endsWith(marker):
        let sdkLibrary = header.path[0 ..< header.path.len - marker.len] &
          "/usr/lib"
        if dirExists(sdkLibrary):
          extraRoots.addUnique(sdkLibrary)
    for root in extraRoots:
      result.libraryRoots.add PathDigest(
        path: root, digest: "sha256:" & sha256Hex("search-root\0" & root))
  parseLinkFlags(resolver, linkFlags, result)
  result.canonicalDigest = resultDigest(result)

proc resolve*(resolver: SystemDependencyResolver,
              request: SystemDependencyRequest): SystemDependencyResult =
  if request.requirement.alias.len == 0 or request.targetTriple.len == 0 or
      request.toolchainIdentity.len == 0:
    raiseSystemDependency(sdecQueryFailed,
      "system dependency request is incomplete")
  var providers: seq[SystemProviderKind]
  # The manifest describes acceptable providers. Host policy remains the
  # authority and its order is the preference order; a manifest can narrow
  # that list but can never enable a provider the host excluded.
  for provider in resolver.policy.providerOrder:
    if request.requirement.providers.len == 0 or
        provider in request.requirement.providers:
      providers.add provider
  if providers.len == 0:
    raiseSystemDependency(sdecProviderUnavailable,
      "manifest and host policy have no provider in common",
      ["system dependency: " & request.requirement.alias])
  var failures: seq[string]
  var actionableCode = sdecProviderUnavailable
  for provider in providers:
    case provider
    of spkPkgConfig:
      try:
        return resolvePkgConfig(resolver, resolver.policy.pkgConfig, request)
      except SystemDependencyError as error:
        failures.add error.msg
        if actionableCode == sdecProviderUnavailable and
            error.code != sdecProviderUnavailable:
          actionableCode = error.code
    else:
      failures.add $provider & " provider is not configured"
  raiseSystemDependency(actionableCode,
    "no allowed provider resolved " & request.requirement.alias, failures)
