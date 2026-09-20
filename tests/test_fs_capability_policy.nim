import std/[os, tempfiles, unittest]
import gene/[capabilities, fs_capabilities]
when defined(posix):
  import std/posix

proc fsProfileCatalog(): tuple[registry: CapabilityRegistry,
                               provider: FilesystemProvider] =
  result.registry = newCapabilityRegistry()
  result.provider = result.registry.admitFilesystemProvider()
  result.registry.freeze()

proc fsProfilePolicy(registry: CapabilityRegistry, name: string,
    roots: openArray[string], use = cuRequest): CapabilitySpecRow =
  var values: seq[CapabilityScalar]
  for root in roots:
    values.add capabilityText(root)
  registry.normalizeCapabilityRow(buildCapabilityLiteral([
    CapabilityEntryLiteral(name: name, body: values)], use,
    CapabilitySourceContext(kind: csoBuilder, name: "fs-test", baseDirectory: "/")), use)

proc fsProfileGrant(registry: CapabilityRegistry, provider: FilesystemProvider,
                    name: string, roots: openArray[string]): CapabilityGrant =
  provider.initializeFilesystemGrant(
    registry.fsProfilePolicy(name, roots, cuGrant).entries[0].policy)

proc fsProfileTemporary(): string =
  expandFilename(createTempDir("gene-capability-v1-", ""))

suite "normalized filesystem policy and descriptor guards":
  test "overlapping roots resolve only through bindings that remain live":
    let parent = fsProfileTemporary()
    defer: os.removeDir(parent)
    let root = parent / "allowed"
    let child = root / "child"
    createDir(child)
    writeFile(child / "data", "original")
    let (registry, provider) = fsProfileCatalog()
    let grant = registry.fsProfileGrant(provider, "fs/ReadWrite", [root, child])
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let retained = provider.openFilesystemFile(context, child / "data")
    defer: retained.close()
    moveDir(child, parent / "outside")
    createDir(child)
    writeFile(child / "data", "replacement")
    check provider.readText(context, child / "data") == "replacement"
    provider.writeText(context, child / "data", "updated")
    check readFile(parent / "outside" / "data") == "original"
    check readFile(child / "data") == "updated"
    expect CapabilityGuardError: discard retained.readBytes(context)

  when defined(posix):
    test "root inspection errors retain their cause instead of becoming missing authority":
      if geteuid() == 0:
        skip()
      else:
        let root = fsProfileTemporary()
        defer: os.removeDir(root)
        let (registry, provider) = fsProfileCatalog()
        let grant = registry.fsProfileGrant(provider, "fs/Read", [root])
        defer: provider.releaseFilesystemGrant(grant)
        let context = registry.newPolicyContext([grant])
        let permissions = getFilePermissions(root)
        setFilePermissions(root, {})
        defer: setFilePermissions(root, permissions)
        let operation = provider.describeFilesystemOperation("read", [root / "data"])
        let decision = registry.checkCapabilityOperation(context, operation)
        check decision.kind == cdProviderFailure
        check decision.reason == "entry_provider_failure"
        try:
          registry.guardCapabilityOperation(context, operation)
          check false
        except CapabilityGuardError as error:
          require error.parent != nil
          require error.parent.parent != nil
          check error.parent.parent of OSError
          check cast[ref OSError](error.parent.parent).errorCode == int32(EACCES)
        let request = registry.fsProfilePolicy("fs/Read", [root])
        let report = registry.checkCapabilityRequirements(context, request)
        check not report.admitted
        check report.entries[0].status == caProviderFailure
  test "normalization is pure, multi-root and context-sensitive":
    let (registry, _) = fsProfileCatalog()
    let row = registry.fsProfilePolicy("fs/Read", ["/does-not-exist-a", "/does-not-exist-b"])
    check row.entries[0].policy.body.kind == cckAlternatives
    let literal = readCapabilityLiteral("[(fs/Read \"data\")]", cuRequest,
      CapabilitySourceContext(baseDirectory: "/source", name: "module.gene"))
    let normalized = registry.normalizeCapabilityRow(literal, cuRequest)
    check normalized.entries[0].policy.body.matches(capabilityText("/source/data/x"))
    expect CapabilityError:
      discard registry.normalizeCapabilityRow(readCapabilityLiteral(
        "[(fs/Read ^^optional ^follow_symlinks true)]", cuRequest,
        CapabilitySourceContext()), cuRequest)

  test "actual reads and writes honor current selection before mutation":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let (registry, provider) = fsProfileCatalog()
    let grant = registry.fsProfileGrant(provider, "fs/ReadWrite", [root])
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let path = root / "data.txt"
    provider.writeText(context, path, "original")
    check provider.readText(context, path) == "original"
    let readOnly = registry.attenuateCapabilities(context,
      registry.fsProfilePolicy("fs/Read", [root], cuBound))
    check provider.readText(readOnly, path) == "original"
    expect CapabilityError:
      provider.writeText(readOnly, path, "changed")
    check system.readFile(path) == "original"
    let empty = registry.attenuateCapabilities(context,
      registry.normalizeCapabilityRow(readCapabilityLiteral("[]", cuBound,
        CapabilitySourceContext()), cuBound))
    expect CapabilityError:
      discard provider.readText(empty, path)

  test "write demands include the containing directory":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let (registry, provider) = fsProfileCatalog()
    let grant = registry.fsProfileGrant(provider, "fs/Write", [root])
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let path = root / "only.txt"
    let leafOnly = registry.attenuateCapabilities(context,
      registry.fsProfilePolicy("fs/Write", [path], cuBound))
    expect CapabilityError:
      provider.writeText(leafOnly, path, "forbidden")
    check not fileExists(path)
    provider.writeText(context, path, "allowed")
    check system.readFile(path) == "allowed"

  test "prefix confusion and symlink traversal cannot escape a root":
    let parent = fsProfileTemporary()
    defer: os.removeDir(parent)
    let root = parent / "allowed"
    let outside = parent / "allowed-other"
    createDir(root)
    createDir(outside)
    system.writeFile(outside / "secret", "outside")
    let (registry, provider) = fsProfileCatalog()
    let grant = registry.fsProfileGrant(provider, "fs/ReadWrite", [root])
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    expect CapabilityError:
      discard provider.readText(context, outside / "secret")
    createSymlink(outside, root / "link")
    expect CapabilityError:
      discard provider.readText(context, root / "link" / "secret")
    expect CapabilityError:
      provider.writeText(context, root / "link" / "secret", "changed")
    check system.readFile(outside / "secret") == "outside"

  test "symlink roots and partial initialization fail without publishing handles":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let actual = root / "actual"
    createDir(actual)
    createSymlink(actual, root / "alias")
    let (registry, provider) = fsProfileCatalog()
    expect CapabilityError:
      discard registry.fsProfileGrant(provider, "fs/Read", [root / "alias"])
    for attempt in 0..5:
      expect CapabilityError:
        discard registry.fsProfileGrant(provider, "fs/Read", [actual, root / "missing"])
    check provider.initializedFilesystemRoots == 0

  test "root replacement invalidates its portion instead of retargeting authority":
    let parent = fsProfileTemporary()
    defer: os.removeDir(parent)
    let first = parent / "first"
    let second = parent / "second"
    createDir(first)
    createDir(second)
    system.writeFile(first / "data", "original")
    system.writeFile(second / "data", "second")
    let (registry, provider) = fsProfileCatalog()
    let grant = registry.fsProfileGrant(provider, "fs/Read", [first, second])
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    let identity = context.domainKey
    moveDir(first, parent / "moved")
    createDir(first)
    system.writeFile(first / "data", "replacement")
    expect CapabilityError:
      discard provider.readText(context, first / "data")
    check provider.readText(context, second / "data") == "second"
    check not registry.checkCapabilityRequirements(context,
      registry.fsProfilePolicy("fs/Read", [first])).admitted
    check registry.checkCapabilityRequirements(context,
      registry.fsProfilePolicy("fs/Read", [second])).admitted
    check context.domainKey == identity

  test "overlapping independent grants remain usable after one revokes":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let sub = root / "sub"
    createDir(sub)
    system.writeFile(sub / "data", "shared")
    let (registry, provider) = fsProfileCatalog()
    let broad = registry.fsProfileGrant(provider, "fs/Read", [root])
    let narrow = registry.fsProfileGrant(provider, "fs/Read", [sub])
    defer:
      provider.releaseFilesystemGrant(broad)
      provider.releaseFilesystemGrant(narrow)
    let context = registry.newPolicyContext([broad, narrow])
    check provider.readText(context, sub / "data") == "shared"
    provider.revoke(broad)
    check provider.readText(context, sub / "data") == "shared"
    check provider.pathExists(context, sub)

  test "independent root ceilings agree on the actual directory descriptor":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let sub = root / "sub"
    createDir(sub)
    system.writeFile(sub / "data", "shared")
    let (registry, provider) = fsProfileCatalog()
    let broad = registry.fsProfileGrant(provider, "fs/Read", [root])
    let narrow = registry.fsProfileGrant(provider, "fs/Read", [sub])
    defer:
      provider.releaseFilesystemGrant(broad)
      provider.releaseFilesystemGrant(narrow)
    let context = intersectContexts(registry.newPolicyContext([broad]),
      registry.newPolicyContext([narrow]))
    check provider.readText(context, sub / "data") == "shared"
    check provider.pathExists(context, sub)
    check provider.listDir(context, sub) == @["data"]

  test "rename requires one complete grant for both source and destination":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let a = root / "a"
    let b = root / "b"
    createDir(a)
    createDir(b)
    system.writeFile(a / "data", "value")
    let (registry, provider) = fsProfileCatalog()
    let first = registry.fsProfileGrant(provider, "fs/Write", [a])
    let second = registry.fsProfileGrant(provider, "fs/Write", [b])
    let whole = registry.fsProfileGrant(provider, "fs/Write", [a, b])
    defer:
      provider.releaseFilesystemGrant(first)
      provider.releaseFilesystemGrant(second)
      provider.releaseFilesystemGrant(whole)
    let separate = registry.newPolicyContext([first, second])
    expect CapabilityError:
      provider.renamePath(separate, a / "data", b / "data")
    check fileExists(a / "data")
    check not fileExists(b / "data")
    check not registry.checkCapabilityRequirements(separate,
      registry.fsProfilePolicy("fs/Write", [a, b])).admitted
    provider.renamePath(registry.newPolicyContext([whole]), a / "data", b / "data")
    check not fileExists(a / "data")
    check system.readFile(b / "data") == "value"

  test "copy uses separately guarded read and write demands":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let a = root / "a"
    let b = root / "b"
    createDir(a)
    createDir(b)
    system.writeFile(a / "data", "copied")
    let (registry, provider) = fsProfileCatalog()
    let read = registry.fsProfileGrant(provider, "fs/Read", [a])
    let write = registry.fsProfileGrant(provider, "fs/Write", [b])
    defer:
      provider.releaseFilesystemGrant(read)
      provider.releaseFilesystemGrant(write)
    expect CapabilityError:
      provider.copyFile(registry.newPolicyContext([read]), a / "data", b / "data")
    check not fileExists(b / "data")
    provider.copyFile(registry.newPolicyContext([read, write]), a / "data", b / "data")
    check system.readFile(b / "data") == "copied"

  test "directory mutations and literal asterisks use the same guarded adapters":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let (registry, provider) = fsProfileCatalog()
    let grant = registry.fsProfileGrant(provider, "fs/ReadWrite", [root])
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    provider.makeDir(context, root / "child")
    provider.writeText(context, root / "child" / "a*b", "literal")
    check provider.readText(context, root / "child" / "a*b") == "literal"
    check provider.listDir(context, root / "child") == @["a*b"]
    provider.removeFile(context, root / "child" / "a*b")
    provider.removeDir(context, root / "child")
    check not dirExists(root / "child")

  test "unsupported metadata and lock effects do not inherit write permission":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let (registry, provider) = fsProfileCatalog()
    let grant = registry.fsProfileGrant(provider, "fs/ReadWrite", [root])
    defer: provider.releaseFilesystemGrant(grant)
    let context = registry.newPolicyContext([grant])
    expect CapabilityError:
      provider.restrictDirToOwner(context, root)
    expect CapabilityError:
      discard provider.tryFileLock(context, root / "lock")
    check not fileExists(root / "lock")

  test "root resource release remains possible after revocation":
    let root = fsProfileTemporary()
    defer: os.removeDir(root)
    let (registry, provider) = fsProfileCatalog()
    let grant = registry.fsProfileGrant(provider, "fs/Read", [root])
    check provider.initializedFilesystemRoots == 1
    provider.revoke(grant)
    provider.releaseFilesystemGrant(grant)
    check provider.initializedFilesystemRoots == 0
    check not grant.isValid
