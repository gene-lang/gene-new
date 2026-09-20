## Included by fs_capabilities.nim: normalized tree policy and descriptor-bound
## native operations. Unmigrated entry points reject normalized contexts.

const MaxNormalizedFilesystemRoots* = 64

type FsPreparedState = ref object of CapabilityOperationState
  active: bool
  kind: string
  targets: seq[string]
  descriptors: seq[cint]
  leaves: seq[string]
  retainedFile: bool
  dataFd: cint
  dataIdentity: tuple[device, inode: uint64]
  fileRights: FsRights

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc fdIdentity(fd: cint): tuple[device, inode: uint64]

proc filesystemFailure(message: string) {.noReturn.} =
  raise newException(FilesystemCapabilityError, message)

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc filesystemInspectionFailure(message: string, missingBinding = false) {.noReturn.} =
    let code = osLastError()
    var cause = newException(OSError, osErrorMsg(code))
    cause.errorCode = int32(code)
    if missingBinding and code in [OSErrorCode(ENOENT), OSErrorCode(ENOTDIR), OSErrorCode(ELOOP)]:
      var error = newException(FilesystemBindingUnavailable, message)
      error.parent = cause
      raise error
    var error = newException(CapabilityProviderFailure, message)
    error.scope = if code in [OSErrorCode(EBADF), OSErrorCode(EMFILE),
                             OSErrorCode(ENFILE), OSErrorCode(ENOMEM)]: cfsShared else: cfsEntry
    error.parent = cause
    raise error

proc fsAbsolute(provider: FilesystemProvider, path: string, base = ""): string =
  if path.len == 0 or '\0' in path:
    filesystemFailure("invalid filesystem path")
  let origin = if base.len > 0: base else: provider.operationBase
  if not path.isAbsolute and origin.len == 0:
    filesystemFailure("relative filesystem path requires a normalization base")
  normalizedPath(if path.isAbsolute: path else: origin / path)

proc isV1Type(provider: FilesystemProvider, capabilityType: CapabilityType): bool =
  capabilityType in [provider.types.read, provider.types.write, provider.types.readWrite]

method supportsCapabilityPolicies*(provider: FilesystemProvider,
    capabilityType: CapabilityType): bool =
  provider.isV1Type(capabilityType)

method intersectStartupPolicies*(provider: FilesystemProvider,
    left, right: CapabilityPolicyEntry, budget: var CapabilityProofBudget):
    seq[CapabilityPolicyEntry] =
  if not provider.isV1Type(left.capabilityType) or not provider.isV1Type(right.capabilityType):
    filesystemFailure("invalid filesystem startup identity")
  var target: CapabilityType
  if left.capabilityType == right.capabilityType: target = left.capabilityType
  elif left.capabilityType == provider.types.readWrite: target = right.capabilityType
  elif right.capabilityType == provider.types.readWrite: target = left.capabilityType
  else: return # Read and Write have no shared operation domain.
  let a = if left.body.kind == cckAlternatives: left.body.operands else: @[left.body]
  let b = if right.body.kind == cckAlternatives: right.body.operands else: @[right.body]
  var roots: seq[CapabilityConstraint]
  for first in a:
    for second in b:
      if budget.remaining <= 0:
        filesystemFailure("startup intersection work limit exceeded")
      dec budget.remaining
      let root = constraintIntersection([first, second], budget)
      if root.kind != cckEmpty: roots.add root
  let body = constraintAlternatives(roots)
  if body.kind != cckEmpty:
    # Keep the complete root set in ONE entry, including cross-root rename.
    result.add newCapabilityPolicyEntry(target, body)

method normalizeCapabilityEntry*(provider: FilesystemProvider,
    capabilityType: CapabilityType, literal: CapabilityEntryLiteral,
    source: CapabilitySourceContext): CapabilityPolicyEntry =
  if not provider.isV1Type(capabilityType):
    filesystemFailure("legacy filesystem capability names are not normalized policies")
  if literal.properties.len > 0:
    filesystemFailure("unknown filesystem capability property")
  var roots: seq[CapabilityConstraint]
  for value in literal.body:
    case value.kind
    of cskWildcard:
      roots.add constraintAny()
    of cskText:
      if value.stringMode == csmPattern:
        filesystemFailure("filesystem roots are literal paths, not patterns")
      if not value.text.isAbsolute and source.baseDirectory.len == 0:
        filesystemFailure("relative filesystem policy requires its source base")
      let root = provider.fsAbsolute(value.text, source.baseDirectory)
      roots.add (if root == "/": constraintAny() else: constraintTree(root))
    else:
      filesystemFailure("filesystem roots must be strings or *")
  newCapabilityPolicyEntry(capabilityType,
    if roots.len == 0: constraintAny() else: constraintAlternatives(roots))

method translateCapabilityPolicy*(provider: FilesystemProvider,
    entry: CapabilityPolicyEntry, target: CapabilityType): Option[CapabilityPolicyEntry] =
  if entry.capabilityType == target:
    return some(entry)
  if entry.capabilityType == provider.types.readWrite and
      target in [provider.types.read, provider.types.write]:
    return some(newCapabilityPolicyEntry(target, entry.body, entry.fields))
  none(CapabilityPolicyEntry)

method capabilityAlternatives*(provider: FilesystemProvider,
    entry: CapabilityPolicyEntry, budget: var CapabilityProofBudget):
    CapabilityAlternativeResult =
  # Splitting Write/ReadWrite roots would drop cross-root rename operations.
  decomposeCapabilityEntry(entry, entry.capabilityType == provider.types.read, [], budget)

proc describeFilesystemOperation*(provider: FilesystemProvider,
    kind: string, targets: openArray[string]): CapabilityOperation =
  let reading = kind in ["read", "stat", "list"]
  if not reading and kind notin ["write", "mkdir", "remove_file", "remove_dir", "rename", "sync_directory"]:
    raise newException(CapabilityOperationError, "unsupported filesystem operation")
  if targets.len != (if kind == "rename": 2 else: 1):
    raise newException(CapabilityOperationError, "invalid filesystem target count")
  var paths: seq[CapabilityScalar]
  for target in targets:
    paths.add capabilityText(provider.fsAbsolute(target))
  if not reading and kind != "sync_directory":
    for target in targets:
      paths.add capabilityText(parentDir(provider.fsAbsolute(target)))
  newCapabilityOperation(
    if reading: provider.types.read else: provider.types.write, kind, paths)

method validateCapabilityOperation*(provider: FilesystemProvider,
    operation: CapabilityOperation) =
  let kind = operation.operationKind
  let count = if kind == "rename": 2 else: 1
  let body = operation.operationBody
  if body.len < count or operation.operationFields.len != 0:
    raise newException(CapabilityOperationError, "invalid filesystem facts")
  var targets: seq[string]
  for i in 0 ..< count:
    if body[i].kind != cskText:
      raise newException(CapabilityOperationError, "filesystem target must be text")
    targets.add body[i].text
  let expected = provider.describeFilesystemOperation(kind, targets)
  if operation.capabilityType != expected.capabilityType or body.len != expected.operationBody.len:
    raise newException(CapabilityOperationError, "contradictory filesystem facts")
  for i, value in body:
    if value.kind != cskText or value.text != expected.operationBody[i].text:
      raise newException(CapabilityOperationError, "contradictory filesystem facts")
  let prepared = provider.operationState(operation)
  if prepared != nil:
    if not (prepared of FsPreparedState):
      raise newException(CapabilityOperationError, "invalid filesystem prepared state")
    let state = FsPreparedState(prepared)
    if state.kind != kind or state.targets != targets:
      raise newException(CapabilityOperationError, "prepared target does not match operation")

method validateSharedOperationState*(provider: FilesystemProvider,
    operation: CapabilityOperation) =
  let state = provider.operationState(operation)
  if state != nil and not FsPreparedState(state).active:
    filesystemFailure("filesystem prepared resolution has expired")
  if state != nil and FsPreparedState(state).retainedFile:
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      let file = FsPreparedState(state)
      if fdIdentity(file.dataFd) != file.dataIdentity or regularFd(file.dataFd) != 1:
        filesystemFailure("retained filesystem descriptor identity changed")
    else:
      filesystemFailure("unsupported retained filesystem backend")

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc closePrepared(state: FsPreparedState) =
    state.active = false
    for fd in state.descriptors:
      if fd >= 0:
        discard posix.close(fd)
    state.descriptors.setLen(0)

  proc fdIdentity(fd: cint): tuple[device, inode: uint64] =
    var info: Stat
    if posix.fstat(fd, info) != 0:
      filesystemInspectionFailure("filesystem descriptor could not be inspected")
    (uint64(info.st_dev), uint64(info.st_ino))

  proc acquireRoot(path: string): cint =
    result = openRoot("/")
    if result < 0:
      filesystemInspectionFailure("filesystem root could not be opened")
    try:
      for part in path.split('/'):
        if part.len == 0: continue
        let next = openDirAt(result, part.cstring)
        if next < 0:
          filesystemInspectionFailure("filesystem root is unavailable or traverses a symlink",
            missingBinding = true)
        discard posix.close(result)
        result = next
    except:
      discard posix.close(result)
      raise

  proc rootsFor(provider: FilesystemProvider, grant: CapabilityGrant):
      seq[tuple[key, path: string]] =
    acquire(provider.anchorLock)
    try:
      for key in provider.normalizedGrantRoots.getOrDefault(grant.semanticKey):
        if provider.normalizedAnchors.hasKey(key):
          result.add (key, provider.normalizedAnchors[key].logicalRoot)
    finally:
      release(provider.anchorLock)
    result.sort(proc(a, b: tuple[key, path: string]): int =
      result = cmp(b.path.len, a.path.len)
      if result == 0: result = cmp(a.key, b.key))

  proc duplicateRoot(provider: FilesystemProvider, key: string): cint =
    acquire(provider.anchorLock)
    try:
      if not provider.normalizedAnchors.hasKey(key):
        raise newException(FilesystemBindingUnavailable, "filesystem root has been released")
      result = openDirAt(provider.normalizedAnchors[key].fd, ".")
      if result < 0:
        filesystemInspectionFailure("filesystem root descriptor is unavailable")
    finally:
      release(provider.anchorLock)

  proc rootBindingValid(provider: FilesystemProvider, key, path: string): bool =
    var retained, named: cint = -1
    try:
      retained = provider.duplicateRoot(key)
      named = acquireRoot(path)
      result = fdIdentity(retained) == fdIdentity(named)
    except FilesystemBindingUnavailable:
      result = false
    finally:
      if retained >= 0: discard posix.close(retained)
      if named >= 0: discard posix.close(named)

  proc resolveTarget(provider: FilesystemProvider, grant: CapabilityGrant,
      path: string, directory, allowSelf: bool): tuple[fd: cint, leaf: string] =
    for root in provider.rootsFor(grant):
      if not path.isPathWithin(root.path):
        continue
      if path == root.path and not directory and not allowSelf:
        continue
      # A still-live broader root cannot revive a displaced narrower anchor.
      # Choose only roots whose original binding is verified at this use.
      if not provider.rootBindingValid(root.key, root.path): continue
      let relative = relativePath(path, root.path)
      var parts: seq[string]
      if relative != ".":
        for part in relative.split('/'):
          if part.len == 0 or part in [".", ".."]:
            filesystemFailure("invalid filesystem resolution component")
          parts.add part
      var fd = provider.duplicateRoot(root.key)
      try:
        let walk = if directory: parts.len else: max(0, parts.len - 1)
        for i in 0 ..< walk:
          let next = openDirAt(fd, parts[i].cstring)
          if next < 0:
            filesystemInspectionFailure("filesystem parent is unavailable or is a symlink",
              missingBinding = true)
          discard posix.close(fd)
          fd = next
        return (fd, if directory or parts.len == 0: "" else: parts[^1])
      except:
        discard posix.close(fd)
        raise
    raise newException(FilesystemBindingUnavailable,
      "filesystem target is outside initialized roots")

  proc bindingIdentity(parent: cint, leaf: string): tuple[device, inode: uint64] =
    var device, inode: culonglong
    if statIdentity(parent, leaf.cstring, addr device, addr inode) != 0:
      filesystemInspectionFailure("filesystem binding could not be inspected", missingBinding = true)
    (uint64(device), uint64(inode))

  proc sameResolution(provider: FilesystemProvider, grant: CapabilityGrant,
                       state: FsPreparedState): bool =
    for i, target in state.targets:
      let candidate = provider.resolveTarget(grant, target,
        state.kind in ["list", "sync_directory"], state.kind == "stat")
      try:
        if state.kind == "stat" and
            (candidate.leaf.len == 0 or state.leaves[i].len == 0):
          if bindingIdentity(candidate.fd, candidate.leaf) !=
              bindingIdentity(state.descriptors[i], state.leaves[i]):
            return false
        elif candidate.leaf != state.leaves[i] or
            fdIdentity(candidate.fd) != fdIdentity(state.descriptors[i]):
          return false
        if state.retainedFile:
          if bindingIdentity(candidate.fd, candidate.leaf) != state.dataIdentity:
            return false
      finally:
        discard posix.close(candidate.fd)
    true

method authorizeCapabilityEntry*(provider: FilesystemProvider,
    grant: CapabilityGrant, policy: CapabilityPolicyEntry,
    operation: CapabilityOperation,
    budget: var CapabilityProofBudget): CapabilityDecision =
  if policy.fields.len > 0:
    raise newException(CapabilityError, "unsupported filesystem policy fields")
  for path in operation.operationBody:
    if not policy.body.matches(path, budget):
      return CapabilityDecision(kind: cdDeny, reason: "filesystem_tree")
  let prepared = provider.operationState(operation)
  if prepared != nil and FsPreparedState(prepared).retainedFile and
      not (provider.typeRights(operation.capabilityType) <= FsPreparedState(prepared).fileRights):
    return CapabilityDecision(kind: cdDeny, reason: "filesystem_handle_mode")
  if grant != nil and prepared != nil:
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      try:
        if not provider.sameResolution(grant, FsPreparedState(prepared)):
          return CapabilityDecision(kind: cdDeny, reason: "filesystem_resource_identity")
      except FilesystemBindingUnavailable:
        return CapabilityDecision(kind: cdDeny, reason: "filesystem_resource_resolution")
    else:
      filesystemFailure("unsupported filesystem backend")
  CapabilityDecision(kind: cdAllow, authorityRow: -1)

proc initializeFilesystemGrant*(provider: FilesystemProvider,
                                policy: CapabilityPolicyEntry): CapabilityGrant =
  if not provider.isV1Type(policy.capabilityType) or policy.fields.len > 0:
    filesystemFailure("invalid filesystem grant policy")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    var roots: seq[string]
    case policy.body.kind
    of cckAny: roots.add "/"
    of cckTree: roots.add policy.body.treeRoot
    of cckAlternatives:
      for operand in policy.body.operands:
        if operand.kind != cckTree:
          filesystemFailure("filesystem grant roots must be directory trees")
        roots.add operand.treeRoot
    else:
      filesystemFailure("unsupported filesystem root policy")
    acquire(provider.anchorLock)
    let exceedsLimit = provider.normalizedAnchors.len + roots.len >
      MaxNormalizedFilesystemRoots
    release(provider.anchorLock)
    if exceedsLimit:
      filesystemFailure("filesystem root handle limit exceeded")
    var acquired: seq[FsRootAnchor]
    for root in roots:
      let anchor = FsRootAnchor(fd: -1, logicalRoot: root)
      anchor.fd = acquireRoot(root)
      acquired.add anchor
    acquire(provider.anchorLock)
    try:
      if provider.normalizedAnchors.len + acquired.len > MaxNormalizedFilesystemRoots:
        filesystemFailure("filesystem root handle limit exceeded")
      result = provider.mintPolicyGrant(policy)
      var keys: seq[string]
      for i, anchor in acquired:
        let key = result.semanticKey & ":" & $i
        provider.normalizedAnchors[key] = anchor
        keys.add key
      provider.normalizedGrantRoots[result.semanticKey] = keys
    finally:
      release(provider.anchorLock)
  else:
    filesystemFailure("unsupported filesystem backend")

proc releaseFilesystemGrant*(provider: FilesystemProvider, grant: CapabilityGrant) =
  provider.revoke(grant)
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    acquire(provider.anchorLock)
    try:
      for key in provider.normalizedGrantRoots.getOrDefault(grant.semanticKey):
        provider.normalizedAnchors.del(key)
      provider.normalizedGrantRoots.del(grant.semanticKey)
    finally:
      release(provider.anchorLock)

method initializeCapabilityGrant*(provider: FilesystemProvider,
    policy: CapabilityPolicyEntry): CapabilityGrant =
  provider.initializeFilesystemGrant(policy)

method releaseCapabilityGrant*(provider: FilesystemProvider,
    grant: CapabilityGrant) =
  provider.releaseFilesystemGrant(grant)

proc initializedFilesystemRoots*(provider: FilesystemProvider): int =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    acquire(provider.anchorLock)
    result = provider.normalizedAnchors.len
    release(provider.anchorLock)

method availableCapabilityPolicy*(provider: FilesystemProvider,
    grant: CapabilityGrant): CapabilityPolicyEntry =
  var available: seq[CapabilityConstraint]
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    for root in provider.rootsFor(grant):
      if provider.rootBindingValid(root.key, root.path):
        available.add (if root.path == "/": constraintAny() else: constraintTree(root.path))
  newCapabilityPolicyEntry(grant.capabilityType, constraintAlternatives(available))

proc normalizedFilesystemGrantValid(provider: FilesystemProvider,
                                     grant: CapabilityGrant): bool =
  provider.availableCapabilityPolicy(grant).body.kind != cckEmpty

when defined(posix) and not defined(emscripten) and not defined(geneWasm):
  proc prepareFs(provider: FilesystemProvider, context: CapabilityContext,
      kind: string, targets: openArray[string]): tuple[state: FsPreparedState,
                                                       operation: CapabilityOperation] =
    let registry = provider.capabilityRegistry
    let operation = provider.describeFilesystemOperation(kind, targets)
    registry.guardCapabilityOperation(context, operation)
    var normalized: seq[string]
    for target in targets:
      normalized.add provider.fsAbsolute(target)
    var candidates = @(context.grants)
    candidates.sort(proc(a, b: CapabilityGrant): int = cmp(a.semanticKey, b.semanticKey))
    var resolutionFailure: ref FilesystemCapabilityError
    var providerFailure: ref CapabilityProviderFailure
    for grant in candidates:
      if not grant.isOwnedBy(provider) or
          not provider.isV1Type(grant.capabilityType) or
          not (provider.typeRights(operation.capabilityType) <= provider.typeRights(grant.capabilityType)):
        continue
      var eligible = true
      for resource in operation.operationBody:
        if not grant.normalizedPolicy.body.matches(resource):
          eligible = false
      if not eligible: continue
      let state = FsPreparedState(active: true, kind: kind, targets: normalized)
      try:
        if not grant.isValid: continue
        for target in normalized:
          let resolved = provider.resolveTarget(grant, target,
            kind in ["list", "sync_directory"], kind == "stat")
          state.descriptors.add resolved.fd
          state.leaves.add resolved.leaf
        let prepared = provider.withOperationState(operation, state)
        registry.guardCapabilityOperation(context, prepared)
        return (state, prepared)
      except CapabilityProviderFailure as error:
        state.closePrepared()
        if error.scope == cfsShared: raise
        providerFailure = error
        continue
      except FilesystemCapabilityError as error:
        resolutionFailure = error
        state.closePrepared()
        continue
      except CapabilityGuardError as error:
        state.closePrepared()
        if error.decision.kind == cdDeny:
          continue
        raise
      except:
        state.closePrepared()
        raise
    if providerFailure != nil:
      raise providerFailure
    if resolutionFailure != nil:
      raise resolutionFailure
    filesystemFailure("MissingCapability: no common guarded filesystem resolution")

include ./fs_capability_handles

proc pathExistsV1(provider: FilesystemProvider, context: CapabilityContext, path: string): bool =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let prepared = provider.prepareFs(context, "stat", [path])
    defer: prepared.state.closePrepared()
    if prepared.state.leaves[0].len == 0: return true
    let parent = prepared.state.descriptors[0]
    let leaf = prepared.state.leaves[0].cstring
    if isSymlinkAt(parent, leaf) == 1:
      filesystemFailure("filesystem metadata target is a symlink")
    let found = existsAt(parent, leaf)
    if found < 0: filesystemFailure("filesystem metadata lookup failed")
    found == 1
  else: filesystemFailure("unsupported filesystem backend")

proc listDirV1(provider: FilesystemProvider, context: CapabilityContext, path: string): seq[string] =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let prepared = provider.prepareFs(context, "list", [path])
    defer: prepared.state.closePrepared()
    let copied = openDirAt(prepared.state.descriptors[0], ".")
    if copied < 0: filesystemFailure("filesystem directory is unavailable")
    let directory = fdopendir(copied)
    if directory == nil:
      discard posix.close(copied)
      filesystemFailure("filesystem directory cannot be listed")
    try:
      while true:
        let entry = readdir(directory)
        if entry == nil: break
        let name = $cast[cstring](addr entry[].d_name[0])
        if name notin [".", ".."]: result.add name
    finally:
      discard closedir(directory)
    result.sort()
  else: filesystemFailure("unsupported filesystem backend")

proc listDirectoryEntries*(provider: FilesystemProvider, context: CapabilityContext,
    path: string, maxEntries: int): seq[FilesystemDirectoryEntry] =
  ## Host adapter primitive. Entry kinds describe the directory entry itself;
  ## inspecting one never follows a symlink to another resource.
  if maxEntries < 0:
    raise newException(CapabilityOperationError, "invalid directory entry limit")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let prepared = provider.prepareFs(context, "list", [path])
    defer: prepared.state.closePrepared()
    let parent = prepared.state.descriptors[0]
    let copied = openDirAt(parent, ".")
    if copied < 0: filesystemInspectionFailure("filesystem directory is unavailable")
    let directory = fdopendir(copied)
    if directory == nil:
      discard posix.close(copied)
      filesystemInspectionFailure("filesystem directory cannot be listed")
    try:
      while true:
        # readdir signals both EOF and failure with nil; preserve the error.
        errno = 0
        let entry = readdir(directory)
        if entry == nil:
          if errno != 0: filesystemInspectionFailure("filesystem directory enumeration failed")
          break
        let name = $cast[cstring](addr entry[].d_name[0])
        if name in [".", ".."]: continue
        if result.len >= maxEntries:
          raise newException(CapabilityOperationError, "source directory entry limit exceeded")
        let kind = entryKindAt(parent, name.cstring)
        if kind < 0: filesystemInspectionFailure("filesystem directory entry changed during inspection")
        result.add FilesystemDirectoryEntry(name: name, kind: FilesystemEntryKind(kind))
    finally:
      discard closedir(directory)
    result.sort(proc(a, b: FilesystemDirectoryEntry): int = cmp(a.name, b.name))
  else: filesystemFailure("UnsupportedCapability: source acquisition backend is unavailable")

proc mutateV1(provider: FilesystemProvider, context: CapabilityContext, kind, path: string) =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let prepared = provider.prepareFs(context, kind, [path])
    defer: prepared.state.closePrepared()
    let parent = prepared.state.descriptors[0]
    let leaf = prepared.state.leaves[0].cstring
    let status = case kind
      of "mkdir": makeDirAt(parent, leaf)
      of "remove_file": removeAt(parent, leaf)
      of "remove_dir": removeDirAt(parent, leaf)
      else: -1.cint
    if status < 0: filesystemFailure("filesystem directory-entry mutation failed")
    if kind == "mkdir":
      let directory = openDirAt(parent, leaf)
      if directory < 0:
        filesystemFailure("filesystem mkdir target is not a safe directory")
      discard posix.close(directory)
  else: filesystemFailure("unsupported filesystem backend")

proc renamePath*(provider: FilesystemProvider, context: CapabilityContext,
                 source, destination: string) =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let prepared = provider.prepareFs(context, "rename", [source, destination])
    defer: prepared.state.closePrepared()
    if renameBetween(prepared.state.descriptors[0], prepared.state.leaves[0].cstring,
        prepared.state.descriptors[1], prepared.state.leaves[1].cstring) != 0:
      filesystemFailure("filesystem rename failed")
  else: filesystemFailure("unsupported filesystem backend")

proc copyFile*(provider: FilesystemProvider, context: CapabilityContext,
               source, destination: string) =
  let registry = provider.capabilityRegistry
  registry.guardCapabilityOperation(context, provider.describeFilesystemOperation("read", [source]))
  registry.guardCapabilityOperation(context, provider.describeFilesystemOperation("write", [destination]))
  let content = provider.readBytesV1(context, source)
  provider.writeBytesV1(context, destination, content)
