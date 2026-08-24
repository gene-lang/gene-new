## Built-in filesystem capability provider.
##
## This module owns filesystem authority semantics. It resolves inert path
## specifications against inherited directory grants and returns sealed grants;
## filesystem adapters consume those grants separately.

import std/[algorithm, atomics, locks, options, os, strutils, tables]
import ./capabilities

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  import std/posix

  {.emit: """
  #include <errno.h>
  #include <fcntl.h>
  #include <stdio.h>
  #include <sys/stat.h>
  #include <unistd.h>

  static int gene_fs_open_root(const char *path) {
    return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  }

  static int gene_fs_open_dir_at(int parent, const char *name) {
    return openat(parent, name,
                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  }

  static int gene_fs_open_read_at(int parent, const char *name) {
    return openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  }

  static int gene_fs_open_write_at(int parent, const char *name,
                                   int append, int create) {
    int flags = O_WRONLY | O_NOFOLLOW | O_CLOEXEC;
    flags |= append ? O_APPEND : O_TRUNC;
    if (create) flags |= O_CREAT;
    return openat(parent, name, flags, 0666);
  }

  static int gene_fs_open_atomic_at(int parent, const char *name) {
    return openat(parent, name,
                  O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                  0600);
  }

  static int gene_fs_replace_at(int parent, const char *source,
                                const char *destination) {
    return renameat(parent, source, parent, destination);
  }

  static int gene_fs_exists_at(int parent, const char *name) {
    struct stat info;
    if (fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0) return 1;
    if (errno == ENOENT || errno == ENOTDIR) return 0;
    return -1;
  }

  static int gene_fs_is_symlink_at(int parent, const char *name) {
    struct stat info;
    if (fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0)
      return S_ISLNK(info.st_mode) ? 1 : 0;
    if (errno == ENOENT || errno == ENOTDIR) return 0;
    return -1;
  }

  static int gene_fs_make_dir_at(int parent, const char *name) {
    if (mkdirat(parent, name, 0700) == 0 || errno == EEXIST) return 0;
    return -1;
  }

  static int gene_fs_remove_at(int parent, const char *name) {
    if (unlinkat(parent, name, 0) == 0 || errno == ENOENT) return 0;
    return -1;
  }

  static int gene_fs_remove_dir_at(int parent, const char *name) {
    if (unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT) return 0;
    return -1;
  }

  static int gene_fs_owner_only_dir(int fd) {
    return fchmod(fd, 0700);
  }
  """.}

  proc openRoot(path: cstring): cint {.importc: "gene_fs_open_root", nodecl.}
  proc openDirAt(parent: cint, name: cstring): cint
    {.importc: "gene_fs_open_dir_at", nodecl.}
  proc openReadAt(parent: cint, name: cstring): cint
    {.importc: "gene_fs_open_read_at", nodecl.}
  proc openWriteAt(parent: cint, name: cstring,
                   append, create: cint): cint
    {.importc: "gene_fs_open_write_at", nodecl.}
  proc openAtomicAt(parent: cint, name: cstring): cint
    {.importc: "gene_fs_open_atomic_at", nodecl.}
  proc replaceAt(parent: cint, source, destination: cstring): cint
    {.importc: "gene_fs_replace_at", nodecl.}
  proc existsAt(parent: cint, name: cstring): cint
    {.importc: "gene_fs_exists_at", nodecl.}
  proc isSymlinkAt(parent: cint, name: cstring): cint
    {.importc: "gene_fs_is_symlink_at", nodecl.}
  proc makeDirAt(parent: cint, name: cstring): cint
    {.importc: "gene_fs_make_dir_at", nodecl.}
  proc removeAt(parent: cint, name: cstring): cint
    {.importc: "gene_fs_remove_at", nodecl.}
  proc removeDirAt(parent: cint, name: cstring): cint
    {.importc: "gene_fs_remove_dir_at", nodecl.}
  proc ownerOnlyDir(fd: cint): cint
    {.importc: "gene_fs_owner_only_dir", nodecl.}
  proc fdopendir(fd: cint): ptr DIR
    {.importc, header: "<dirent.h>", sideEffect.}

type
  FilesystemCapabilityTypes* = object
    readDir*: CapabilityType
    writeDir*: CapabilityType
    readWriteDir*: CapabilityType
    readFile*: CapabilityType
    writeFile*: CapabilityType

  FilesystemProvider* = ref object of CapabilityProvider
    types*: FilesystemCapabilityTypes
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      ## Retained anchor handles, keyed by `operationAnchor` (§7.5: "anchor
      ## resolution at a directory handle"). Re-opening the anchor by path per
      ## operation re-walks its ancestors every time, and `O_NOFOLLOW` guards
      ## only the final component — so a directory swapped above the granted
      ## root between two operations would silently redirect the second. The
      ## table is bounded in practice because a derived grant inherits its
      ## parent's anchor: distinct anchors come only from host root grants.
      anchorLock*: Lock
      anchorHandles*: Table[string, cint]

  FilesystemCapabilityError* = object of CapabilityError
  AmbiguousCapabilityError* = object of FilesystemCapabilityError

  FsRight = enum
    frRead
    frWrite
  FsRights = set[FsRight]

  FsFilePolicy = object
    append: bool
    create: bool
    followSymlinks: bool

proc canonicalCapabilityPath*(path: string): string =
  ## Lexical normalization, then the real path of the longest prefix that
  ## exists — a grant names a *resource*, not a route to it.
  ##
  ## Without this, granting a symlinked directory mints a grant that can never
  ## be opened: the handle walk opens each component `O_NOFOLLOW` (§7.5), so
  ## `--allow_read_dir /tmp` on macOS, where `/tmp -> private/tmp`, fails every
  ## operation with "filesystem capability root is unavailable". `/tmp`,
  ## `$TMPDIR` and `/etc` all have that shape, which is most of the directories
  ## anyone actually wants to grant.
  ##
  ## Resolving here rather than relaxing the walk keeps `O_NOFOLLOW` meaning
  ## the thing that matters: no symlink appeared *after* we decided what this
  ## path denotes. A symlink planted inside a granted directory is still
  ## refused — and now refused at resolution, before any handle is opened.
  ##
  ## Every path reaching a grant goes through here, root scopes and requested
  ## paths alike, so containment comparisons stay consistent.
  let lexical = normalizedPath(absolutePath(path))
  var existing = lexical
  var trailing: seq[string]
  while existing.len > 1 and not existing.fileExists and not existing.dirExists:
    let (parent, name) = splitPath(existing)
    if name.len == 0 or parent.len == 0 or parent == existing:
      break
    trailing.add name
    existing = parent
  var resolved =
    try:
      expandFilename(existing)
    except CatchableError:
      return lexical
  for i in countdown(trailing.high, 0):
    resolved = resolved / trailing[i]
  normalizedPath(resolved)

proc isPathWithin(path, root: string): bool =
  if path == root:
    return true
  if root == $DirSep:
    return path.startsWith($DirSep)
  path.startsWith(root & $DirSep)

proc typeRights(provider: FilesystemProvider,
                capabilityType: CapabilityType): FsRights =
  if capabilityType == provider.types.readDir or
      capabilityType == provider.types.readFile:
    {frRead}
  elif capabilityType == provider.types.writeDir or
      capabilityType == provider.types.writeFile:
    {frWrite}
  elif capabilityType == provider.types.readWriteDir:
    {frRead, frWrite}
  else:
    {}

proc isFileType(provider: FilesystemProvider,
                capabilityType: CapabilityType): bool =
  capabilityType == provider.types.readFile or
    capabilityType == provider.types.writeFile

proc filePolicy(provider: FilesystemProvider,
                capabilityType: CapabilityType,
                named: openArray[CapabilityNamedArg]): FsFilePolicy =
  result.create = true
  for item in named:
    if item.value.kind != cakBool:
      raise newException(FilesystemCapabilityError,
        "filesystem capability property " & item.name & " must be boolean")
    case item.name
    of "append":
      if capabilityType != provider.types.writeFile:
        raise newException(FilesystemCapabilityError,
          "append is valid only for fs/WriteFile")
      result.append = item.value.boolValue
    of "create":
      if capabilityType != provider.types.writeFile:
        raise newException(FilesystemCapabilityError,
          "create is valid only for fs/WriteFile")
      result.create = item.value.boolValue
    of "follow_symlinks":
      result.followSymlinks = item.value.boolValue
    else:
      raise newException(FilesystemCapabilityError,
        "unknown filesystem capability property: " & item.name)
  if result.followSymlinks:
    raise newException(FilesystemCapabilityError,
      "follow_symlinks true is not supported by this filesystem provider")

proc canonicalPolicy(provider: FilesystemProvider,
                     capabilityType: CapabilityType,
                     policy: FsFilePolicy): seq[CapabilityNamedArg] =
  if capabilityType == provider.types.writeFile:
    result.add capNamed("append", capBool(policy.append))
    result.add capNamed("create", capBool(policy.create))
  result.add capNamed("follow_symlinks", capBool(policy.followSymlinks))

proc grantFilePolicy(provider: FilesystemProvider,
                     grant: CapabilityGrant): FsFilePolicy =
  provider.filePolicy(grant.capabilityType, grant.policy)

proc validateSpec(provider: FilesystemProvider,
                  requested: CapabilitySpec): FsFilePolicy =
  if requested.positional.len > 1:
    raise newException(FilesystemCapabilityError,
      requested.capabilityType.name & " expects at most one path argument")
  if requested.positional.len == 1:
    discard requested.positionalString(0)
  provider.filePolicy(requested.capabilityType, requested.named)

method validity*(provider: FilesystemProvider,
                 grant: CapabilityGrant): CapabilityValidity =
  if not grant.isOwnedBy(provider):
    return CapabilityValidity()
  grant.sealedValidity

method subsumes*(provider: FilesystemProvider,
                 broader, narrower: CapabilitySpec): CapabilitySubsumption =
  let broaderRights = provider.typeRights(broader.capabilityType)
  let narrowerRights = provider.typeRights(narrower.capabilityType)
  if broaderRights == {} or narrowerRights == {} or
      not (narrowerRights <= broaderRights):
    return csNo
  try:
    let broadPolicy = provider.validateSpec(broader)
    let narrowPolicy = provider.validateSpec(narrower)
    if provider.isFileType(broader.capabilityType) and
        provider.isFileType(narrower.capabilityType):
      if broader.capabilityType == provider.types.writeFile and
          narrower.capabilityType == provider.types.writeFile:
        if broadPolicy.append != narrowPolicy.append or
            (not broadPolicy.create and narrowPolicy.create):
          return csNo
      if not broadPolicy.followSymlinks and narrowPolicy.followSymlinks:
        return csNo
  except CapabilityError:
    return csUnknown
  if broader.positional.len == 0:
    return csYes
  if narrower.positional.len == 0:
    return csNo
  try:
    let broadPath = canonicalCapabilityPath($DirSep / broader.positionalString(0))
    let narrowPath = canonicalCapabilityPath($DirSep / narrower.positionalString(0))
    if provider.isFileType(broader.capabilityType):
      if broadPath == narrowPath: csYes else: csNo
    elif narrowPath.isPathWithin(broadPath):
      csYes
    else:
      csNo
  except CapabilityError:
    csUnknown

proc requestedPath(parent: CapabilityGrant, requested: CapabilitySpec): string =
  if requested.positional.len == 0:
    return parent.scope
  let raw = requested.positionalString(0)
  if raw == "*" or raw.len == 0:
    return parent.scope
  # Lexical only. Root scopes are already stored resolved, so a request that
  # is genuinely inside one matches without touching the filesystem — and this
  # runs per operation, so a `realpath` here costs every file the program
  # opens. `resolve` retries with resolution only when the lexical check fails.
  if raw.isAbsolute:
    normalizedPath(absolutePath(raw))
  else:
    normalizedPath(absolutePath(parent.resolutionBase / raw))

method resolve*(provider: FilesystemProvider, parent: CapabilityGrant,
                requested: CapabilitySpec): Option[CapabilityGrant] =
  if parent == nil or not parent.isValid:
    return none(CapabilityGrant)
  let availableRights = provider.typeRights(parent.capabilityType)
  let requestedRights = provider.typeRights(requested.capabilityType)
  if requestedRights == {} or not (requestedRights <= availableRights):
    return none(CapabilityGrant)
  let requestedPolicy = provider.validateSpec(requested)
  var path = requestedPath(parent, requested)
  if not path.isPathWithin(parent.scope):
    # The lexical spelling is outside, but it may be a symlinked route to a
    # path that is inside — `/tmp/x` against a root stored as `/private/tmp`.
    # Resolving only here keeps the cost off every successful operation and
    # pays it once, on the request that would otherwise be refused.
    let resolved = canonicalCapabilityPath(path)
    if resolved == path or not resolved.isPathWithin(parent.scope):
      return none(CapabilityGrant)
    path = resolved
  if provider.isFileType(parent.capabilityType) and path != parent.scope:
    return none(CapabilityGrant)
  if provider.isFileType(parent.capabilityType):
    let parentPolicy = provider.grantFilePolicy(parent)
    if parent.capabilityType == provider.types.writeFile and
        requested.capabilityType == provider.types.writeFile:
      if parentPolicy.append != requestedPolicy.append or
          (not parentPolicy.create and requestedPolicy.create):
        return none(CapabilityGrant)
    if not parentPolicy.followSymlinks and requestedPolicy.followSymlinks:
      return none(CapabilityGrant)
  let base =
    if provider.isFileType(requested.capabilityType):
      parent.resolutionBase
    else:
      path
  let policy = provider.canonicalPolicy(requested.capabilityType,
                                        requestedPolicy)
  some(provider.deriveGrant(parent, requested.capabilityType, path, base,
                            policy = policy))

proc intersectionPolicy(provider: FilesystemProvider,
                        left, right: CapabilityGrant,
                        capabilityType: CapabilityType,
                        policy: var seq[CapabilityNamedArg]): bool =
  if not provider.isFileType(capabilityType):
    policy = provider.canonicalPolicy(capabilityType, FsFilePolicy(create: true))
    return true
  var selected = FsFilePolicy(create: true)
  var hasFilePolicy = false
  for grant in [left, right]:
    if not provider.isFileType(grant.capabilityType):
      continue
    let candidate = provider.grantFilePolicy(grant)
    if not hasFilePolicy:
      selected = candidate
      hasFilePolicy = true
    else:
      if capabilityType == provider.types.writeFile and
          selected.append != candidate.append:
        return false
      selected.create = selected.create and candidate.create
      selected.followSymlinks = selected.followSymlinks and
        candidate.followSymlinks
  policy = provider.canonicalPolicy(capabilityType, selected)
  true

proc addIntersection(provider: FilesystemProvider, left, right: CapabilityGrant,
                     capabilityType: CapabilityType, path: string,
                     output: var seq[CapabilityGrant]) =
  let base =
    if provider.isFileType(capabilityType):
      if left.resolutionBase.len > right.resolutionBase.len:
        left.resolutionBase
      elif right.resolutionBase.len > left.resolutionBase.len:
        right.resolutionBase
      elif left.resolutionBase <= right.resolutionBase:
        left.resolutionBase
      else:
        right.resolutionBase
    else:
      path
  var policy: seq[CapabilityNamedArg]
  if not provider.intersectionPolicy(left, right, capabilityType, policy):
    return
  output.add provider.intersectGrant(left, right, capabilityType, path, base,
                                     policy = policy)

method intersect*(provider: FilesystemProvider,
                  left, right: openArray[CapabilityGrant]): seq[CapabilityGrant] =
  if left.len == right.len:
    var leftKeys = newSeqOfCap[string](left.len)
    var rightKeys = newSeqOfCap[string](right.len)
    for grant in left:
      leftKeys.add grant.semanticKey
    for grant in right:
      rightKeys.add grant.semanticKey
    leftKeys.sort()
    rightKeys.sort()
    if leftKeys == rightKeys:
      return @left
  for a in left:
    for b in right:
      if a == nil or b == nil or not a.isValid or not b.isValid:
        continue
      let rights = provider.typeRights(a.capabilityType) *
        provider.typeRights(b.capabilityType)
      if rights == {}:
        continue
      var path = ""
      if a.scope.isPathWithin(b.scope):
        path = a.scope
      elif b.scope.isPathWithin(a.scope):
        path = b.scope
      else:
        continue
      let fileResult = provider.isFileType(a.capabilityType) or
        provider.isFileType(b.capabilityType)
      if not fileResult and rights == {frRead, frWrite}:
        provider.addIntersection(a, b, provider.types.readWriteDir,
                                 path, result)
      elif frRead in rights:
        provider.addIntersection(a, b,
          if fileResult: provider.types.readFile else: provider.types.readDir,
          path, result)
      if (fileResult or rights != {frRead, frWrite}) and frWrite in rights:
        provider.addIntersection(a, b,
          if fileResult: provider.types.writeFile else: provider.types.writeDir,
          path, result)

proc admitFilesystemProvider*(registry: CapabilityRegistry): FilesystemProvider =
  if registry == nil:
    raise newException(CapabilityError,
      "filesystem provider admission requires a registry")
  result = FilesystemProvider()
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    initLock(result.anchorLock)
    result.anchorHandles = initTable[string, cint]()
  registry.admitProvider(result, "fs")
  result.types.readDir = registry.admitType(result, "fs/ReadDir")
  result.types.writeDir = registry.admitType(result, "fs/WriteDir")
  result.types.readWriteDir = registry.admitType(result, "fs/ReadWriteDir")
  result.types.readFile = registry.admitType(result, "fs/ReadFile")
  result.types.writeFile = registry.admitType(result, "fs/WriteFile")

  for source in [result.types.readDir, result.types.readWriteDir]:
    registry.admitEntailment(result, source, result.types.readFile)
  for source in [result.types.writeDir, result.types.readWriteDir]:
    registry.admitEntailment(result, source, result.types.writeFile)
  registry.admitEntailment(result, result.types.readWriteDir,
                           result.types.readDir)
  registry.admitEntailment(result, result.types.readWriteDir,
                           result.types.writeDir)

proc grantReadDir*(provider: FilesystemProvider,
                   root: string): CapabilityGrant =
  provider.mintRootGrant(provider.types.readDir, canonicalCapabilityPath(root))

proc grantWriteDir*(provider: FilesystemProvider,
                    root: string): CapabilityGrant =
  provider.mintRootGrant(provider.types.writeDir, canonicalCapabilityPath(root))

proc grantReadWriteDir*(provider: FilesystemProvider,
                        root: string): CapabilityGrant =
  provider.mintRootGrant(provider.types.readWriteDir, canonicalCapabilityPath(root))

proc resolveOperation(provider: FilesystemProvider, context: CapabilityContext,
                      capabilityType: CapabilityType, path: string,
                      named: openArray[CapabilityNamedArg] = []): CapabilityGrant =
  if provider == nil or context == nil:
    raise newException(FilesystemCapabilityError,
      "MissingCapability: " & capabilityType.name)
  let requested = newCapabilitySpec(capabilityType, [capString(path)], named)
  for parent in context.grants:
    if not parent.isOwnedBy(provider) or
        not parent.isValid:
      continue
    let candidate =
      if parent.capabilityType == capabilityType and
          requestedPath(parent, requested) == parent.scope:
        some(parent)
      else:
        provider.resolve(parent, requested)
    if candidate.isNone:
      continue
    let grant = candidate.get
    if result == nil:
      result = grant
    elif grant.scope != result.scope or
        grant.operationAnchor != result.operationAnchor or
        grant.policy != result.policy:
      raise newException(AmbiguousCapabilityError,
        "AmbiguousCapability: " & capabilityType.name & " for " & path)
  if result == nil:
    raise newException(FilesystemCapabilityError,
      "MissingCapability: " & capabilityType.name & " for " & path)

proc relativeOperationPath(grant: CapabilityGrant): string =
  let root = grant.operationAnchor
  if grant.scope == root:
    return "."
  if not grant.scope.isPathWithin(root):
    raise newException(FilesystemCapabilityError,
      "filesystem grant target escapes its resolution root")
  # `root.len + 1` skips the separator *between* root and the remainder. The
  # filesystem root is its own separator, so it has no such character to skip
  # and the same arithmetic would eat the first byte of the first component
  # ("/var/x" under "/" becoming "ar/x").
  let skip = if root == $DirSep: root.len else: root.len + 1
  grant.scope[skip .. ^1]

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc operationParts(grant: CapabilityGrant): seq[string] =
    let relative = grant.relativeOperationPath
    if relative == ".":
      return
    for part in relative.split(DirSep):
      if part.len == 0 or part in [".", ".."]:
        raise newException(FilesystemCapabilityError,
          "filesystem path contains an invalid component")
      result.add part

  const MaxRetainedAnchorHandles = 64

  proc openAnchor(grant: CapabilityGrant): cint =
    ## A descriptor for the grant's anchor directory, duplicated from a handle
    ## the provider opened once and retains. Callers close what they get back;
    ## the retained handle stays open, so every later operation walks from the
    ## *same* directory inode rather than re-resolving the anchor's ancestors.
    let provider = FilesystemProvider(grant.owningProvider)
    let anchor = grant.operationAnchor
    if provider == nil:
      return openRoot(anchor.cstring)
    acquire(provider.anchorLock)
    try:
      var retained: cint = -1
      if provider.anchorHandles.hasKey(anchor):
        retained = provider.anchorHandles[anchor]
      else:
        retained = openRoot(anchor.cstring)
        if retained < 0:
          return retained
        if provider.anchorHandles.len >= MaxRetainedAnchorHandles:
          # Anchors come from host root grants and do not accumulate in
          # practice; if that ever stops being true, drop the table rather
          # than leak descriptors. Outstanding duplicates stay valid.
          for _, handle in provider.anchorHandles:
            discard posix.close(handle)
          provider.anchorHandles.clear()
        provider.anchorHandles[anchor] = retained
      result = posix.dup(retained)
      if result < 0:
        raise newException(FilesystemCapabilityError,
          "filesystem capability root handle could not be duplicated")
    finally:
      release(provider.anchorLock)

  proc openDirectory(grant: CapabilityGrant): cint =
    let parts = grant.operationParts
    result = grant.openAnchor
    if result < 0:
      raise newException(FilesystemCapabilityError,
        "filesystem capability root is unavailable")
    try:
      for part in parts:
        let next = openDirAt(result, part.cstring)
        if next < 0:
          raise newException(FilesystemCapabilityError,
            "filesystem path component is unavailable or is a symlink")
        discard posix.close(result)
        result = next
    except:
      discard posix.close(result)
      raise

  proc openParent(grant: CapabilityGrant): tuple[fd: cint, leaf: string] =
    let parts = grant.operationParts
    if parts.len == 0:
      raise newException(FilesystemCapabilityError,
        "filesystem operation requires a target beneath the granted root")
    result.fd = grant.openAnchor
    if result.fd < 0:
      raise newException(FilesystemCapabilityError,
        "filesystem capability root is unavailable")
    try:
      for i in 0 ..< parts.high:
        let next = openDirAt(result.fd, parts[i].cstring)
        if next < 0:
          raise newException(FilesystemCapabilityError,
            "filesystem path component is unavailable or is a symlink")
        discard posix.close(result.fd)
        result.fd = next
      result.leaf = parts[^1]
    except:
      discard posix.close(result.fd)
      raise

  proc openOperation(grant: CapabilityGrant, write: bool): cint =
    let parent = grant.openParent
    try:
      result =
        if write:
          openWriteAt(parent.fd, parent.leaf.cstring,
                      cint(grant.policyBool("append", false)),
                      cint(grant.policyBool("create", true)))
        else: openReadAt(parent.fd, parent.leaf.cstring)
      if result < 0:
        raise newException(FilesystemCapabilityError,
          "filesystem target is unavailable or is a symlink")
    finally:
      discard posix.close(parent.fd)

  proc makeDirectory(grant: CapabilityGrant) =
    let parts = grant.operationParts
    var current = grant.openAnchor
    if current < 0:
      raise newException(FilesystemCapabilityError,
        "filesystem capability root is unavailable")
    try:
      for part in parts:
        var next = openDirAt(current, part.cstring)
        if next < 0:
          if makeDirAt(current, part.cstring) < 0:
            raise newException(FilesystemCapabilityError,
              "filesystem directory could not be created")
          if posix.fsync(current) != 0:
            raise newException(FilesystemCapabilityError,
              "filesystem directory creation could not be synchronized")
          next = openDirAt(current, part.cstring)
        if next < 0:
          raise newException(FilesystemCapabilityError,
            "filesystem directory is unavailable or is a symlink")
        discard posix.close(current)
        current = next
    finally:
      discard posix.close(current)

  proc readOpened(fd: cint): string =
    var buffer: array[8192, char]
    while true:
      let count = posix.read(fd, addr buffer[0], buffer.len)
      if count == 0:
        break
      if count < 0:
        raise newException(FilesystemCapabilityError,
          "filesystem read failed")
      let oldLen = result.len
      result.setLen(oldLen + int(count))
      copyMem(addr result[oldLen], addr buffer[0], int(count))

  proc writeOpened(fd: cint, content: string) =
    var offset = 0
    while offset < content.len:
      let count = posix.write(fd, unsafeAddr content[offset],
                              content.len - offset)
      if count <= 0:
        raise newException(FilesystemCapabilityError,
          "filesystem write failed")
      offset += int(count)

  var atomicWriteSequence {.global.}: Atomic[uint64]

  proc writeAtomic(grant: CapabilityGrant, content: string) =
    if grant.policyBool("append", false):
      raise newException(FilesystemCapabilityError,
        "atomic replacement is incompatible with append mode")
    let parent = grant.openParent
    var temporary = ""
    var fd: cint = -1
    try:
      if not grant.policyBool("create", true):
        let present = existsAt(parent.fd, parent.leaf.cstring)
        if present != 1:
          raise newException(FilesystemCapabilityError,
            "filesystem target must already exist")
      for attempt in 0 ..< 32:
        let sequence = atomicWriteSequence.fetchAdd(1'u64) + 1'u64
        temporary = ".gene-tmp-" & $getCurrentProcessId() & "-" &
          $sequence & "-" & $attempt
        fd = openAtomicAt(parent.fd, temporary.cstring)
        if fd >= 0:
          break
      if fd < 0:
        raise newException(FilesystemCapabilityError,
          "filesystem atomic temporary file could not be created")
      try:
        writeOpened(fd, content)
        if posix.fsync(fd) != 0:
          raise newException(FilesystemCapabilityError,
            "filesystem atomic write could not be synchronized")
      finally:
        discard posix.close(fd)
        fd = -1
      if not grant.isValid:
        raise newException(FilesystemCapabilityError,
          "filesystem capability was revoked")
      if replaceAt(parent.fd, temporary.cstring, parent.leaf.cstring) != 0:
        raise newException(FilesystemCapabilityError,
          "filesystem atomic replacement failed")
      temporary.setLen(0)
      if posix.fsync(parent.fd) != 0:
        raise newException(FilesystemCapabilityError,
          "filesystem directory could not be synchronized")
    finally:
      if fd >= 0:
        discard posix.close(fd)
      if temporary.len > 0:
        discard removeAt(parent.fd, temporary.cstring)
      discard posix.close(parent.fd)

proc readBytes*(provider: FilesystemProvider, context: CapabilityContext,
                path: string): string =
  let grant = provider.resolveOperation(context, provider.types.readFile, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let fd = grant.openOperation(false)
    try:
      if not grant.isValid:
        raise newException(FilesystemCapabilityError,
          "filesystem capability was revoked")
      result = readOpened(fd)
    finally:
      discard posix.close(fd)
  else:
    result = readFile(grant.scope)

proc readText*(provider: FilesystemProvider, context: CapabilityContext,
               path: string): string =
  provider.readBytes(context, path)

proc writeBytes*(provider: FilesystemProvider, context: CapabilityContext,
                 path, content: string) =
  let grant = provider.resolveOperation(context, provider.types.writeFile, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let fd = grant.openOperation(true)
    try:
      if not grant.isValid:
        raise newException(FilesystemCapabilityError,
          "filesystem capability was revoked")
      writeOpened(fd, content)
    finally:
      discard posix.close(fd)
  else:
    writeFile(grant.scope, content)

proc writeText*(provider: FilesystemProvider, context: CapabilityContext,
                path, content: string) =
  provider.writeBytes(context, path, content)

proc writeBytesAtomic*(provider: FilesystemProvider,
                       context: CapabilityContext,
                       path, content: string) =
  let grant = provider.resolveOperation(context, provider.types.writeFile, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if not grant.isValid:
      raise newException(FilesystemCapabilityError,
        "filesystem capability was revoked")
    grant.writeAtomic(content)
  else:
    let temporary = grant.scope & ".gene-tmp"
    writeFile(temporary, content)
    moveFile(temporary, grant.scope)

proc writeTextAtomic*(provider: FilesystemProvider,
                      context: CapabilityContext,
                      path, content: string) =
  provider.writeBytesAtomic(context, path, content)

proc openWriteFile*(provider: FilesystemProvider, context: CapabilityContext,
                    path: string, append = false, create = true):
                    tuple[file: File, grant: CapabilityGrant] =
  ## Open a retained file handle through the same handle-relative confinement
  ## used by one-shot writes. The returned grant is the resource's immutable
  ## creation-time ceiling; callers must re-intersect it with active authority
  ## before every later operation on the handle.
  let grant = provider.resolveOperation(context, provider.types.writeFile,
    path, [capNamed("append", capBool(append)),
           capNamed("create", capBool(create))])
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let fd = grant.openOperation(true)
    var file: File
    if not system.open(file, FileHandle(fd),
                       if append: fmAppend else: fmWrite):
      discard posix.close(fd)
      raise newException(FilesystemCapabilityError,
        "filesystem target could not be opened as a stream")
    result = (file, grant)
  else:
    var file: File
    if not system.open(file, grant.scope,
                       if append: fmAppend else: fmWrite):
      raise newException(FilesystemCapabilityError,
        "filesystem target could not be opened as a stream")
    result = (file, grant)

proc pathExists*(provider: FilesystemProvider, context: CapabilityContext,
                 path: string): bool =
  let grant = provider.resolveOperation(context, provider.types.readDir, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if grant.scope == grant.operationAnchor:
      let fd = grant.openDirectory
      discard posix.close(fd)
      return true
    let parts = grant.operationParts
    var current = grant.openAnchor
    if current < 0:
      raise newException(FilesystemCapabilityError,
        "filesystem capability root is unavailable")
    try:
      if not grant.isValid:
        raise newException(FilesystemCapabilityError,
          "filesystem capability was revoked")
      # `openParent` deliberately treats a missing intermediate component and
      # an existing symlink alike: both are invalid for an operation. An
      # existence query has one extra legitimate outcome, though — a path whose
      # parent has not been created yet simply does not exist. Check each
      # component before opening it so ENOENT/ENOTDIR returns false while an
      # existing component that cannot be opened with O_NOFOLLOW still fails
      # closed as a symlink/inaccessible path.
      for i in 0 ..< parts.high:
        let present = existsAt(current, parts[i].cstring)
        if present == 0:
          return false
        if present < 0:
          raise newException(FilesystemCapabilityError,
            "filesystem path component could not be inspected")
        let next = openDirAt(current, parts[i].cstring)
        if next < 0:
          raise newException(FilesystemCapabilityError,
            "filesystem path component is unavailable or is a symlink")
        discard posix.close(current)
        current = next
      let found = existsAt(current, parts[^1].cstring)
      if found < 0:
        raise newException(FilesystemCapabilityError,
          "filesystem target could not be inspected")
      if found == 1 and isSymlinkAt(current, parts[^1].cstring) == 1:
        raise newException(FilesystemCapabilityError,
          "filesystem target is a symlink")
      result = found == 1
    finally:
      discard posix.close(current)
  else:
    result = fileExists(grant.scope) or dirExists(grant.scope) or
      symlinkExists(grant.scope)

proc listDir*(provider: FilesystemProvider, context: CapabilityContext,
              path: string): seq[string] =
  let grant = provider.resolveOperation(context, provider.types.readDir, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let fd = grant.openDirectory
    let directory = fdopendir(fd)
    if directory == nil:
      discard posix.close(fd)
      raise newException(FilesystemCapabilityError,
        "filesystem directory could not be listed")
    try:
      if not grant.isValid:
        raise newException(FilesystemCapabilityError,
          "filesystem capability was revoked")
      while true:
        let entry = readdir(directory)
        if entry == nil:
          break
        let name = $cast[cstring](addr entry[].d_name[0])
        if name notin [".", ".."]:
          result.add name
    finally:
      discard closedir(directory)
  else:
    for _, name in walkDir(grant.scope, relative = true):
      result.add name
  result.sort()

proc makeDir*(provider: FilesystemProvider, context: CapabilityContext,
              path: string) =
  let grant = provider.resolveOperation(context, provider.types.writeDir, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if not grant.isValid:
      raise newException(FilesystemCapabilityError,
        "filesystem capability was revoked")
    grant.makeDirectory()
  else:
    createDir(grant.scope)

proc restrictDirToOwner*(provider: FilesystemProvider,
                         context: CapabilityContext, path: string) =
  let grant = provider.resolveOperation(context, provider.types.writeDir, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let fd = grant.openDirectory
    try:
      if not grant.isValid:
        raise newException(FilesystemCapabilityError,
          "filesystem capability was revoked")
      if ownerOnlyDir(fd) != 0:
        raise newException(FilesystemCapabilityError,
          "filesystem directory permissions could not be restricted")
    finally:
      discard posix.close(fd)
  else:
    setFilePermissions(grant.scope,
      {fpUserRead, fpUserWrite, fpUserExec})

proc removeFile*(provider: FilesystemProvider, context: CapabilityContext,
                 path: string) =
  let grant = provider.resolveOperation(context, provider.types.writeFile, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let parent = grant.openParent
    try:
      if not grant.isValid:
        raise newException(FilesystemCapabilityError,
          "filesystem capability was revoked")
      if removeAt(parent.fd, parent.leaf.cstring) < 0:
        raise newException(FilesystemCapabilityError,
          "filesystem target could not be removed")
    finally:
      discard posix.close(parent.fd)
  else:
    if fileExists(grant.scope) or symlinkExists(grant.scope):
      os.removeFile(grant.scope)

proc removeDir*(provider: FilesystemProvider, context: CapabilityContext,
                path: string) =
  let grant = provider.resolveOperation(context, provider.types.writeDir, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let parent = grant.openParent
    try:
      if not grant.isValid:
        raise newException(FilesystemCapabilityError,
          "filesystem capability was revoked")
      if removeDirAt(parent.fd, parent.leaf.cstring) < 0:
        raise newException(FilesystemCapabilityError,
          "filesystem directory could not be removed")
      if posix.fsync(parent.fd) != 0:
        raise newException(FilesystemCapabilityError,
          "filesystem directory removal could not be synchronized")
    finally:
      discard posix.close(parent.fd)
  else:
    if dirExists(grant.scope):
      os.removeDir(grant.scope)

proc realPath*(provider: FilesystemProvider, context: CapabilityContext,
               path: string): string =
  ## Capability-safe canonical path. The provider's default no-follow policy
  ## deliberately rejects symlinked ancestors instead of resolving through
  ## them, so this never reveals or returns a target outside the sealed root.
  let grant = provider.resolveOperation(context, provider.types.readDir, path)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if grant.scope == grant.operationAnchor:
      let fd = grant.openDirectory
      discard posix.close(fd)
    else:
      let parent = grant.openParent
      try:
        let symlink = isSymlinkAt(parent.fd, parent.leaf.cstring)
        if symlink < 0:
          raise newException(FilesystemCapabilityError,
            "filesystem target could not be inspected")
        if symlink == 1:
          raise newException(FilesystemCapabilityError,
            "filesystem target is a symlink under no-follow policy")
      finally:
        discard posix.close(parent.fd)
  result = grant.scope
