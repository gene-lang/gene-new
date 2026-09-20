## Included by fs_capability_policy.nim. These are trusted adapter interfaces;
## no raw descriptor, buffered File, context-restoration token, or grant escapes.

type
  FilesystemFileMode* = enum
    ffRead, ffWrite, ffReadWrite
  FilesystemFileObj = object
    provider: FilesystemProvider
    origin: CapabilityContext
    path: string
    rights: FsRights
    fd, parentFd: cint
    identity: tuple[device, inode: uint64]
    leaf: string
    opened, counted, lockInitialized: bool
    lock: Lock
  FilesystemFile* = ref FilesystemFileObj
  FilesystemAtomicWriteObj = object
    file: FilesystemFile
    target: string
    done, published, cleaned, lockInitialized: bool
    lock: Lock
  FilesystemAtomicWrite* = ref FilesystemAtomicWriteObj

proc releaseFile(file: var FilesystemFileObj) =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    if file.opened:
      discard posix.close(file.fd)
      discard posix.close(file.parentFd)
      if file.counted:
        withLock file.provider.anchorLock:
          dec file.provider.normalizedFileCount
  file.counted = false
  file.opened = false
  file.fd = -1
  file.parentFd = -1
  file.provider = nil
  file.origin = nil
  file.path = ""
  file.leaf = ""

proc `=destroy`(file: var FilesystemFileObj) =
  file.releaseFile()
  if file.lockInitialized:
    deinitLock(file.lock)
    file.lockInitialized = false

proc close*(file: FilesystemFile) =
  if file == nil or not file.lockInitialized: return
  withLock file.lock:
    file[].releaseFile()

proc closed*(file: FilesystemFile): bool =
  if file == nil or not file.lockInitialized: return true
  withLock file.lock:
    result = not file.opened

proc initializedFilesystemFiles*(provider: FilesystemProvider): int =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    withLock provider.anchorLock:
      result = provider.normalizedFileCount

proc requireOpen(file: FilesystemFile) =
  if file == nil or not file.opened:
    raise newException(CapabilityOperationError, "filesystem handle is closed")

proc fileOperation(file: FilesystemFile, kind: string): CapabilityOperation =
  file.requireOpen()
  let state = FsPreparedState(active: true, kind: kind, targets: @[file.path],
    descriptors: @[file.parentFd], leaves: @[file.leaf], retainedFile: true,
    dataFd: file.fd, dataIdentity: file.identity, fileRights: file.rights)
  file.provider.withOperationState(
    file.provider.describeFilesystemOperation(kind, [file.path]), state)

proc guardFileUse(file: FilesystemFile, current: CapabilityContext, kind: string) =
  file.requireOpen()
  let context = intersectContexts(current, file.origin)
  file.provider.capabilityRegistry.guardCapabilityOperation(context,
    file.fileOperation(kind))

proc checkFilesystemFile*(file: FilesystemFile, current: CapabilityContext,
                          writing = false): CapabilityDecision =
  if file == nil or not file.lockInitialized:
    raise newException(CapabilityOperationError, "filesystem handle is closed")
  withLock file.lock:
    file.requireOpen()
    let context = intersectContexts(current, file.origin)
    result = file.provider.capabilityRegistry.checkCapabilityOperation(context,
      file.fileOperation(if writing: "write" else: "read"))

proc openFilesystemFile*(provider: FilesystemProvider, context: CapabilityContext,
    path: string, mode = ffRead, append = false, create = false,
    truncate = false, exclusive = false): FilesystemFile =
  if not context.isPolicyContext:
    raise newException(CapabilityError, "retained files require normalized authority")
  if (mode == ffRead and (append or create or truncate or exclusive)) or
      (append and truncate) or (exclusive and not create):
    raise newException(CapabilityOperationError, "invalid filesystem open mode")
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let kind = if mode == ffRead: "read" else: "write"
    let prepared = provider.prepareFs(context, kind, [path])
    defer: prepared.state.closePrepared()
    if mode == ffReadWrite:
      let reading = FsPreparedState(active: true, kind: "read",
        targets: prepared.state.targets, descriptors: prepared.state.descriptors,
        leaves: prepared.state.leaves)
      provider.capabilityRegistry.guardCapabilityOperation(context,
        provider.withOperationState(provider.describeFilesystemOperation("read", [path]), reading))
    let fd = openRetainedAt(prepared.state.descriptors[0],
      prepared.state.leaves[0].cstring, cint(ord(mode)), cint(append), cint(create), cint(exclusive))
    if fd < 0:
      if exclusive and osLastError() == OSErrorCode(EEXIST):
        raise newException(FilesystemEntryExistsError, "filesystem entry already exists")
      filesystemFailure("filesystem file is unavailable, nonregular, or a symlink")
    result = FilesystemFile(provider: provider, origin: context,
      path: provider.fsAbsolute(path), fd: fd,
      parentFd: prepared.state.descriptors[0], leaf: prepared.state.leaves[0],
      opened: true, rights: (case mode
        of ffRead: {frRead}
        of ffWrite: {frWrite}
        of ffReadWrite: {frRead, frWrite}))
    prepared.state.descriptors[0] = -1
    withLock provider.anchorLock:
      inc provider.normalizedFileCount
      result.counted = true
    initLock(result.lock)
    result.lockInitialized = true
    try:
      result.identity = fdIdentity(fd)
      result.guardFileUse(context, kind)
      if truncate and posix.ftruncate(fd, 0) != 0:
        filesystemFailure("filesystem file could not be truncated")
    except:
      result.close()
      raise
  else:
    filesystemFailure("UnsupportedCapability: retained filesystem backend is unavailable")

proc readBytes*(file: FilesystemFile, current: CapabilityContext, maxBytes = -1): string =
  if maxBytes < -1:
    raise newException(CapabilityOperationError, "invalid filesystem read limit")
  if file == nil or not file.lockInitialized:
    raise newException(CapabilityOperationError, "filesystem handle is closed")
  withLock file.lock:
    file.guardFileUse(current, "read")
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      var buffer: array[65536, char]
      while maxBytes < 0 or result.len < maxBytes:
        file.guardFileUse(current, "read")
        let wanted = if maxBytes < 0: buffer.len else: min(buffer.len, maxBytes - result.len)
        let count = posix.read(file.fd, addr buffer[0], wanted)
        if count == 0: break
        if count < 0:
          if osLastError() == OSErrorCode(EINTR): continue
          filesystemFailure("filesystem read failed")
        let start = result.len
        result.setLen(start + int(count))
        copyMem(addr result[start], addr buffer[0], int(count))
    else:
      filesystemFailure("UnsupportedCapability: retained filesystem backend is unavailable")

proc writeBytes*(file: FilesystemFile, current: CapabilityContext, content: string) =
  if file == nil or not file.lockInitialized:
    raise newException(CapabilityOperationError, "filesystem handle is closed")
  withLock file.lock:
    file.guardFileUse(current, "write")
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      var offset = 0
      while offset < content.len:
        file.guardFileUse(current, "write")
        let count = posix.write(file.fd, unsafeAddr content[offset], min(65536, content.len - offset))
        if count < 0 and osLastError() == OSErrorCode(EINTR): continue
        if count <= 0: filesystemFailure("filesystem write failed")
        offset += int(count)
    else:
      filesystemFailure("UnsupportedCapability: retained filesystem backend is unavailable")

proc sync*(file: FilesystemFile, current: CapabilityContext) =
  if file == nil or not file.lockInitialized:
    raise newException(CapabilityOperationError, "filesystem handle is closed")
  withLock file.lock:
    file.guardFileUse(current, "write")
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      if posix.fsync(file.fd) != 0: filesystemFailure("filesystem synchronization failed")
    else:
      filesystemFailure("UnsupportedCapability: retained filesystem backend is unavailable")

proc readBytesV1(provider: FilesystemProvider, context: CapabilityContext, path: string): string =
  let file = provider.openFilesystemFile(context, path)
  defer: file.close()
  file.readBytes(context)

proc writeBytesV1(provider: FilesystemProvider, context: CapabilityContext, path, content: string) =
  let file = provider.openFilesystemFile(context, path, ffWrite, create = true, truncate = true)
  defer: file.close()
  file.writeBytes(context, content)

proc `=destroy`(stage: var FilesystemAtomicWriteObj) =
  stage.file.close()
  stage.file = nil
  stage.target = ""
  if stage.lockInitialized:
    deinitLock(stage.lock)
    stage.lockInitialized = false

proc beginFilesystemAtomicWrite*(provider: FilesystemProvider, context: CapabilityContext,
                                 path: string): FilesystemAtomicWrite =
  when defined(posix) and not defined(emscripten) and not defined(geneWasm):
    let target = provider.fsAbsolute(path)
    let initial = provider.prepareFs(context, "write", [target])
    defer: initial.state.closePrepared()
    for attempt in 0 ..< 32:
      let sequence = atomicWriteSequence.fetchAdd(1'u64) + 1'u64
      let temporary = parentDir(target) / (".gene-tmp-" & $getCurrentProcessId() &
        "-" & $sequence & "-" & $attempt)
      var file: FilesystemFile
      try:
        file = provider.openFilesystemFile(context, temporary, ffWrite, create = true, exclusive = true)
      except FilesystemEntryExistsError:
        continue
      if fdIdentity(file.parentFd) != fdIdentity(initial.state.descriptors[0]):
        file.close()
        filesystemFailure("filesystem atomic parent changed during staging")
      result = FilesystemAtomicWrite(file: file, target: target)
      initLock(result.lock)
      result.lockInitialized = true
      return
    filesystemFailure("filesystem atomic temporary file could not be created")
  else:
    filesystemFailure("UnsupportedCapability: atomic filesystem backend is unavailable")

proc stagingPath*(stage: FilesystemAtomicWrite): string =
  if stage == nil or not stage.lockInitialized: return ""
  withLock stage.lock:
    result = stage.file.path

proc writeBytes*(stage: FilesystemAtomicWrite, current: CapabilityContext, content: string) =
  if stage == nil or not stage.lockInitialized:
    raise newException(CapabilityOperationError, "atomic filesystem write is closed")
  withLock stage.lock:
    if stage.done:
      raise newException(CapabilityOperationError, "atomic filesystem write is closed")
    stage.file.writeBytes(current, content)

proc commit*(stage: FilesystemAtomicWrite, current: CapabilityContext) =
  if stage == nil or not stage.lockInitialized:
    raise newException(CapabilityOperationError, "atomic filesystem write is closed")
  withLock stage.lock:
    if stage.done:
      raise newException(CapabilityOperationError, "atomic filesystem write is closed")
    let file = stage.file
    file.sync(current)
    let provider = file.provider
    let context = intersectContexts(current, file.origin)
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      let rename = provider.prepareFs(context, "rename", [file.path, stage.target])
      defer: rename.state.closePrepared()
      if fdIdentity(rename.state.descriptors[0]) != fdIdentity(file.parentFd) or
          fdIdentity(rename.state.descriptors[1]) != fdIdentity(file.parentFd):
        filesystemFailure("filesystem atomic parent changed before publication")
      # Check the retained staging binding again after preparing the rename.
      file.guardFileUse(current, "write")
      provider.capabilityRegistry.guardCapabilityOperation(context, rename.operation)
      if replaceAt(file.parentFd, file.leaf.cstring, rename.state.leaves[1].cstring) != 0:
        filesystemFailure("filesystem atomic replacement failed")
      stage.published = true
      stage.done = true
      defer: file.close()
      let directory = provider.prepareFs(context, "sync_directory", [parentDir(stage.target)])
      defer: directory.state.closePrepared()
      if fdIdentity(directory.state.descriptors[0]) != fdIdentity(file.parentFd):
        filesystemFailure("filesystem atomic parent changed before synchronization")
      if posix.fsync(directory.state.descriptors[0]) != 0:
        filesystemFailure("filesystem atomic directory synchronization failed")
    else:
      filesystemFailure("UnsupportedCapability: atomic filesystem backend is unavailable")

proc abort*(stage: FilesystemAtomicWrite, current: CapabilityContext): bool =
  ## Release always; cleanup of an unpublished name still requires authority.
  if stage == nil or not stage.lockInitialized: return true
  withLock stage.lock:
    if stage.done: return stage.published or stage.cleaned
    let file = stage.file
    defer:
      stage.done = true
      file.close()
    if stage.published: return true
    if file.closed: return false
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      try:
        file.guardFileUse(current, "write")
        let context = intersectContexts(current, file.origin)
        let removal = file.provider.prepareFs(context, "remove_file", [file.path])
        defer: removal.state.closePrepared()
        if fdIdentity(removal.state.descriptors[0]) != fdIdentity(file.parentFd): return false
        file.guardFileUse(current, "write")
        file.provider.capabilityRegistry.guardCapabilityOperation(context, removal.operation)
        result = removeAt(file.parentFd, file.leaf.cstring) == 0
        stage.cleaned = result
      except CapabilityError:
        result = false

proc writeBytesAtomicV1(provider: FilesystemProvider, context: CapabilityContext, path, content: string) =
  let stage = provider.beginFilesystemAtomicWrite(context, path)
  defer: discard stage.abort(context)
  stage.writeBytes(context, content)
  stage.commit(context)
