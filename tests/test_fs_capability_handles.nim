import std/[os, tempfiles, unittest]
import gene/[capabilities, fs_capabilities]
when defined(posix):
  import std/posix

  proc liveTestDescriptors(): int =
    for fd in 0..<1024:
      if posix.fcntl(cint(fd), F_GETFD) >= 0: inc result

proc handleCatalog(): tuple[registry: CapabilityRegistry, provider: FilesystemProvider] =
  result.registry = newCapabilityRegistry()
  result.provider = result.registry.admitFilesystemProvider()
  result.registry.freeze()

proc handleGrant(registry: CapabilityRegistry, provider: FilesystemProvider,
                  root: string, name = "fs/ReadWrite"): CapabilityGrant =
  let row = registry.normalizeCapabilityRow(buildCapabilityLiteral([
    CapabilityEntryLiteral(name: name, body: @[capabilityText(root)])], cuGrant,
    CapabilitySourceContext()), cuGrant)
  provider.initializeFilesystemGrant(row.entries[0].policy)

proc handleTemporary(): string = expandFilename(createTempDir("gene-fs-handles-", ""))

suite "retained normalized filesystem handles":
  test "read/write modes, offsets and current authority guard actual data":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let empty = registry.newPolicyContext([])
    let path = root / "data"
    writeFile(path, "abcdef")
    let file = provider.openFilesystemFile(context, path)
    defer: file.close()
    check file.readBytes(context, 3) == "abc"
    check not file.checkFilesystemFile(empty).allowed
    expect CapabilityGuardError: discard file.readBytes(empty, 1)
    check file.readBytes(context) == "def"
    check not file.checkFilesystemFile(context, writing = true).allowed
    expect CapabilityGuardError: file.writeBytes(context, "changed")
    check readFile(path) == "abcdef"
    let writer = provider.openFilesystemFile(context, path, ffWrite, append = true)
    defer: writer.close()
    writer.writeBytes(context, "-more")
    writer.sync(context)
    expect CapabilityGuardError: discard writer.readBytes(context)
    expect CapabilityGuardError: writer.writeBytes(empty, "forbidden")
    check readFile(path) == "abcdef-more"

  test "a broader caller cannot replace a revoked origin":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let originGrant = registry.handleGrant(provider, root)
    let laterGrant = registry.handleGrant(provider, root)
    defer:
      provider.releaseFilesystemGrant(originGrant)
      provider.releaseFilesystemGrant(laterGrant)
    let origin = registry.newPolicyContext([originGrant])
    let later = registry.newPolicyContext([laterGrant])
    let path = root / "data"
    let file = provider.openFilesystemFile(origin, path, ffWrite, create = true)
    file.writeBytes(origin, "initial")
    provider.revoke(originGrant)
    expect CapabilityGuardError: file.writeBytes(later, "forbidden")
    expect CapabilityGuardError: file.sync(later)
    check readFile(path) == "initial"
    file.close()
    file.close()
    check file.closed
    check provider.initializedFilesystemFiles == 0
    expect CapabilityOperationError: file.writeBytes(later, "closed")

  test "retained origin alternatives survive revocation of an earlier match":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let first = registry.handleGrant(provider, root)
    let second = registry.handleGrant(provider, root)
    defer:
      provider.releaseFilesystemGrant(first)
      provider.releaseFilesystemGrant(second)
    let origin = registry.newPolicyContext([first, second])
    let current = registry.newPolicyContext([second])
    let path = root / "data"
    let file = provider.openFilesystemFile(origin, path, ffWrite, create = true)
    defer: file.close()
    provider.releaseFilesystemGrant(first)
    file.writeBytes(current, "surviving grant")
    check readFile(path) == "surviving grant"

  test "replacement and movement never retarget a retained data descriptor":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let path = root / "data"
    writeFile(path, "original")
    let file = provider.openFilesystemFile(context, path, ffReadWrite)
    defer: file.close()
    moveFile(path, root / "moved")
    writeFile(path, "replacement")
    expect CapabilityGuardError: discard file.readBytes(context)
    expect CapabilityGuardError: file.writeBytes(context, "forbidden")
    check readFile(root / "moved") == "original"
    check readFile(path) == "replacement"
    removeFile(path)
    moveFile(root / "moved", path)
    check file.readBytes(context) == "original"

  test "read/write opens require both demands before creating a file":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let read = registry.handleGrant(provider, root, "fs/Read")
    let write = registry.handleGrant(provider, root, "fs/Write")
    defer:
      provider.releaseFilesystemGrant(read)
      provider.releaseFilesystemGrant(write)
    let path = root / "data"
    expect CapabilityGuardError:
      discard provider.openFilesystemFile(registry.newPolicyContext([write]), path,
        ffReadWrite, create = true)
    check not fileExists(path)
    let both = registry.newPolicyContext([read, write])
    let file = provider.openFilesystemFile(both, path, ffReadWrite, create = true)
    defer: file.close()
    file.writeBytes(both, "allowed")
    check readFile(path) == "allowed"

  test "a moved parent outside the root invalidates retained I/O without retargeting":
    let parent = handleTemporary()
    defer: removeDir(parent)
    let root = parent / "allowed"
    createDir(root / "child")
    writeFile(root / "child" / "data", "original")
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let file = provider.openFilesystemFile(context, root / "child" / "data", ffReadWrite)
    defer: file.close()
    moveDir(root / "child", parent / "outside")
    createDir(root / "child")
    writeFile(root / "child" / "data", "replacement")
    expect CapabilityGuardError: file.writeBytes(context, "forbidden")
    expect CapabilityGuardError: discard file.readBytes(context)
    check readFile(parent / "outside" / "data") == "original"
    check readFile(root / "child" / "data") == "replacement"

  test "final drops release descriptors and their origin references":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    writeFile(root / "data", "data")
    when defined(posix):
      let descriptorsBefore = liveTestDescriptors()
    for iteration in 0..<32:
      block:
        let file = provider.openFilesystemFile(context, root / "data")
        check provider.initializedFilesystemFiles == 1
        check file.readBytes(context) == "data"
      check provider.initializedFilesystemFiles == 0
    when defined(posix):
      check liveTestDescriptors() <= descriptorsBefore

suite "guarded atomic filesystem replacement":
  test "atomic writes replace data and leave no staging file on success":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let path = root / "data"
    writeFile(path, "old")
    provider.writeTextAtomic(context, path, "new")
    check readFile(path) == "new"
    check provider.listDir(context, root) == @["data"]
    check provider.initializedFilesystemFiles == 0

  test "publication denial leaves the destination unchanged and cleanup stays guarded":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let path = root / "data"
    writeFile(path, "old")
    let stage = provider.beginFilesystemAtomicWrite(context, path)
    stage.writeBytes(context, "staged")
    let temporary = stage.stagingPath
    expect CapabilityGuardError: stage.commit(registry.newPolicyContext([]))
    check readFile(path) == "old"
    check stage.abort(context)
    check stage.abort(context)
    check not fileExists(temporary)
    check provider.initializedFilesystemFiles == 0

  test "revocation prevents publication and does not grant unlink during release":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let path = root / "data"
    writeFile(path, "old")
    let stage = provider.beginFilesystemAtomicWrite(context, path)
    stage.writeBytes(context, "staged")
    let temporary = stage.stagingPath
    provider.revoke(grant)
    expect CapabilityGuardError: stage.commit(context)
    check not stage.abort(context)
    check readFile(path) == "old"
    check readFile(temporary) == "staged"
    check provider.initializedFilesystemFiles == 0

  test "replacing a staged entry cannot publish or delete the known replacement":
    let root = handleTemporary()
    defer: removeDir(root)
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let path = root / "data"
    writeFile(path, "old")
    let stage = provider.beginFilesystemAtomicWrite(context, path)
    stage.writeBytes(context, "staged")
    let temporary = stage.stagingPath
    moveFile(temporary, root / "moved")
    writeFile(temporary, "replacement")
    expect CapabilityGuardError: stage.commit(context)
    check not stage.abort(context)
    check readFile(path) == "old"
    check readFile(temporary) == "replacement"
    check readFile(root / "moved") == "staged"
    check provider.initializedFilesystemFiles == 0

  test "atomic replacement changes a symlink entry without following its target":
    let root = handleTemporary()
    defer: removeDir(root)
    createDir(root / "allowed")
    writeFile(root / "outside", "private")
    createSymlink(root / "outside", root / "allowed" / "link")
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root / "allowed")
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    provider.writeTextAtomic(context, root / "allowed" / "link", "replacement")
    check readFile(root / "outside") == "private"
    check not symlinkExists(root / "allowed" / "link")
    check readFile(root / "allowed" / "link") == "replacement"

  test "moving the staging parent cannot redirect publication or cleanup":
    let parent = handleTemporary()
    defer: removeDir(parent)
    let root = parent / "allowed"
    createDir(root / "child")
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let path = root / "child" / "data"
    writeFile(path, "old")
    let stage = provider.beginFilesystemAtomicWrite(context, path)
    stage.writeBytes(context, "staged")
    let temporary = stage.stagingPath.extractFilename()
    moveDir(root / "child", parent / "outside")
    createDir(root / "child")
    writeFile(path, "replacement")
    expect CapabilityGuardError: stage.commit(context)
    check not stage.abort(context)
    check readFile(parent / "outside" / "data") == "old"
    check readFile(parent / "outside" / temporary) == "staged"
    check readFile(path) == "replacement"
    check provider.initializedFilesystemFiles == 0

  test "failed native publication cleans up without masking the original failure":
    let root = handleTemporary()
    defer: removeDir(root)
    createDir(root / "directory")
    let (registry, provider) = handleCatalog()
    let grant = registry.handleGrant(provider, root)
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    expect FilesystemCapabilityError:
      provider.writeTextAtomic(context, root / "directory", "cannot replace a directory")
    check provider.listDir(context, root) == @["directory"]
    check provider.initializedFilesystemFiles == 0
