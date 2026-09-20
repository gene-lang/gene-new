import std/[os, tempfiles, unittest]
import gene/[capabilities, fs_capabilities, module_sources, vm]

suite "private loader source capture":
  test "capture freezes exact source bytes and releases private authority":
    let root = expandFilename(createTempDir("gene-source-capture-", ""))
    defer: removeDir(root)
    createDir(root / "nested")
    writeFile(root / "entry.gene", "(var value 1)")
    writeFile(root / "nested" / "child.gene", "(var value 2)")
    writeFile(root / "private.txt", "not source")
    let app = newApplication(root)
    app.setRootCapabilities(app.capabilities.newPolicyContext([]))
    let provider = app.filesystemCapabilities
    let roots = provider.initializedFilesystemRoots
    let snapshot = provider.captureModuleSources(root)
    check snapshot.sourceCount == 2
    check not snapshot.hasSource(root / "private.txt")
    check provider.initializedFilesystemRoots == roots
    check provider.initializedFilesystemFiles == 0
    check app.rootCapabilities.grants.len == 0
    expect CapabilityError: discard provider.readText(app.rootCapabilities, root / "entry.gene")
    let again = provider.captureModuleSources(root)
    check snapshot.sourceDigest == again.sourceDigest
    writeFile(root / "entry.gene", "(var value 3)")
    var copied = snapshot.sourceText(root / "entry.gene")
    copied[0] = 'X'
    check snapshot.sourceText(root / "entry.gene") == "(var value 1)"
    let changed = provider.captureModuleSources(root)
    check snapshot.sourceDigest != changed.sourceDigest

  test "source file and root symlinks are rejected without leaked handles":
    let root = expandFilename(createTempDir("gene-source-links-", ""))
    defer: removeDir(root)
    createDir(root / "source")
    writeFile(root / "private.gene", "(var secret 42)")
    createSymlink(root / "private.gene", root / "source" / "entry.gene")
    let app = newApplication(root)
    let provider = app.filesystemCapabilities
    expect CapabilityError: discard provider.captureModuleSources(root / "source")
    check provider.initializedFilesystemRoots == 0
    check provider.initializedFilesystemFiles == 0
    removeFile(root / "source" / "entry.gene")
    createSymlink(root / "source", root / "linked")
    expect CapabilityError: discard provider.captureModuleSources(root / "linked")
    check provider.initializedFilesystemRoots == 0

  test "symlink directories are not traversed or treated as admitted sources":
    let root = expandFilename(createTempDir("gene-source-directory-link-", ""))
    defer: removeDir(root)
    createDir(root / "source")
    createDir(root / "private")
    writeFile(root / "source" / "entry.gene", "(var value 1)")
    writeFile(root / "private" / "secret.gene", "(var value 42)")
    createSymlink(root / "private", root / "source" / "hidden")
    let app = newApplication(root)
    let snapshot = app.filesystemCapabilities.captureModuleSources(root / "source")
    check snapshot.sourceCount == 1
    check not snapshot.hasSource(root / "source" / "hidden" / "secret.gene")

  test "capture limits reject before publishing a partial bundle":
    let root = expandFilename(createTempDir("gene-source-limits-", ""))
    defer: removeDir(root)
    createDir(root / "nested")
    writeFile(root / "first.gene", "1234")
    writeFile(root / "nested" / "second.gene", "5678")
    let app = newApplication(root)
    for mode in 0..4:
      var limits = DefaultModuleSourceLimits
      case mode
      of 0: limits.maxFileBytes = 3
      of 1: limits.maxTotalBytes = 7
      of 2: limits.maxFiles = 1
      of 3: limits.maxEntries = 1
      else: limits.maxDepth = 0
      expect CapabilityError: discard app.filesystemCapabilities.captureModuleSources(root, limits)
      check app.filesystemCapabilities.initializedFilesystemRoots == 0
      check app.filesystemCapabilities.initializedFilesystemFiles == 0
