## Hosted registry adapter for the existing format-1 package manager. Solver
## candidates need only a verified manifest. The complete signed source tree
## is fetched for selected candidates and when a locked object is reacquired.

import std/[os, strutils, tempfiles]
import ./[digest, package, printer, process_lock, registry_https, registry_release,
          release_crypto, types]

proc indexField(release: VerifiedRelease, name: string): string =
  let value = release.index.mapEntries[name]
  if value.kind != vkString:
    raisePackageError(pecManifestInvalid,
      "verified release index has invalid ^" & name)
  value.strVal

proc manifestObject(release: VerifiedRelease):
    tuple[digest: string, size: int64] =
  for item in release.index.mapEntries["files"].listItems:
    let fields = item.mapEntries
    if fields["path"].strVal == ManifestFileName:
      return (fields["digest"].strVal, fields["size"].intVal)
  raisePackageError(pecManifestInvalid,
    "signed release has no package.gene object")

proc newHostedRegistry*(name: string, transport: RegistryHttpsTransport,
                        crypto: ReleaseCrypto, trust: ReleaseTrust,
                        cacheRoot: string): PackageSourceAdapter =
  if name.len == 0 or transport == nil or crypto == nil or
      not cacheRoot.isAbsolute:
    raisePackageError(pecManifestInvalid,
      "hosted registry needs name, HTTPS/crypto adapters, and absolute cache")
  validatePackageName(name & "/registry", "hosted registry name")
  discard releaseKeyId(trust.registryPublicKey)
  let root = normalizedPath(cacheRoot / name)
  createDir(root)

  proc checkedRelease(indexDigest, expectedName, expectedVersion,
                      expectedManifest, expectedTree: string): VerifiedRelease =
    result = fetchVerifiedRelease(transport, crypto, trust, indexDigest)
    if result.indexField("name") != expectedName or
        result.indexField("version") != expectedVersion or
        (expectedManifest.len > 0 and
         result.indexField("manifest_digest") != expectedManifest) or
        (expectedTree.len > 0 and
         result.indexField("tree_digest") != expectedTree):
      raisePackageError(pecIdentityMismatch,
        "hosted release disagrees with selected package identity",
        [expectedName & "@" & expectedVersion])

  proc ensureManifest(release: VerifiedRelease): string =
    let hex = release.indexDigest[7 .. ^1]
    let target = root / "manifests" / hex
    let manifest = release.manifestObject()
    let lock = acquireProcessFileLock(root / "locks" / "manifests" /
      (hex & ".lock"))
    defer: lock.release()
    proc valid(path: string): bool =
      if not fileExists(path / ManifestFileName):
        return false
      try:
        let file = path / ManifestFileName
        if getFileSize(file) != manifest.size or
            "sha256:" & sha256File(file) != manifest.digest:
          return false
        let pkg = loadPackageAt(path, poRegistrySource)
        pkg.name == release.indexField("name") and
          pkg.version == release.indexField("version") and
          pkg.manifestDigest == release.indexField("manifest_digest")
      except CatchableError:
        false
    if valid(target):
      return target
    if dirExists(target):
      makeMaterializedTreeWritable(target)
      removeDir(target)
    createDir(parentDir(target))
    let stage = createTempDir("gene-manifest-", "", parentDir(target))
    var published = false
    try:
      let objectPath = "/v1/objects/" & manifest.digest[7 .. ^1]
      let source = transport.fetchRegistryObject(objectPath,
        manifest.digest, manifest.size, stage)
      moveFile(source, stage / ManifestFileName)
      if not valid(stage):
        raisePackageError(pecIdentityMismatch,
          "hosted manifest object disagrees with signed release")
      moveDir(stage, target)
      protectMaterializedTree(target)
      published = true
    finally:
      if not published and dirExists(stage):
        makeMaterializedTreeWritable(stage)
        removeDir(stage)
    target

  proc mappingPath(pkgName, version: string): string =
    let parts = pkgName.split('/')
    root / "by-version" / parts[0] / parts[1] / (version & ".digest")

  proc vendorSignaturePath(pkg: Package, vendorRoot: string): string =
    vendorRoot / ".signatures" / name /
      pkg.treeDigest.replace("sha256:", "")

  proc readIndexDigest(path: string): string =
    if not fileExists(path) or symlinkExists(path) or
        getFileInfo(path, followSymlink = false).isSpecial or
        getFileSize(path) > 72:
      raisePackageError(pecBoundary,
        "signed release digest mapping is not a bounded regular file", [path])
    result = readFile(path).strip()
    requireDigest(result, "cached release index digest")

  proc recordVerification(release: VerifiedRelease) =
    let hex = release.indexDigest[7 .. ^1]
    let target = root / "verification" / hex
    let lock = acquireProcessFileLock(root / "locks" / "verification" /
      (hex & ".lock"))
    try:
      var valid = false
      if dirExists(target):
        try:
          let cached = loadVerifiedRelease(target, crypto, trust,
                                           release.indexDigest)
          valid = cached.signerIdentity == release.signerIdentity
          if not valid:
            makeMaterializedTreeWritable(target)
            removeDir(target)
        except CatchableError:
          makeMaterializedTreeWritable(target)
          removeDir(target)
      if not valid:
        createDir(parentDir(target))
        let stage = createTempDir("gene-verification-", "",
                                  parentDir(target))
        var published = false
        try:
          saveVerifiedRelease(release, stage)
          discard loadVerifiedRelease(stage, crypto, trust,
                                     release.indexDigest)
          moveDir(stage, target)
          protectMaterializedTree(target)
          published = true
        finally:
          if not published and dirExists(stage):
            makeMaterializedTreeWritable(stage)
            removeDir(stage)
    finally:
      lock.release()
    let name = release.indexField("name")
    let version = release.indexField("version")
    let mapping = mappingPath(name, version)
    let versionLock = acquireProcessFileLock(root / "locks" / "versions" /
      name / (version & ".lock"))
    defer: versionLock.release()
    if fileExists(mapping):
      if symlinkExists(mapping) or
          getFileInfo(mapping, followSymlink = false).isSpecial or
          getFileSize(mapping) > 72:
        raisePackageError(pecBoundary,
          "hosted version mapping is not a regular file", [mapping])
      if readFile(mapping).strip() != release.indexDigest:
        raisePackageError(pecVersionConflict,
          "hosted registry changed an immutable version mapping",
          [name & "@" & version])
      return
    createDir(parentDir(mapping))
    let (file, temporary) = createTempFile("gene-version-", ".digest",
      parentDir(mapping))
    defer:
      if fileExists(temporary): removeFile(temporary)
    try:
      file.write(release.indexDigest & "\n")
      file.flushFile()
    finally:
      file.close()
    moveFile(temporary, mapping)

  proc ensureTree(release: VerifiedRelease): string =
    let hex = release.indexDigest[7 .. ^1]
    let target = root / "trees" / hex
    let lock = acquireProcessFileLock(root / "locks" / "trees" /
      (hex & ".lock"))
    defer: lock.release()
    proc recordProvenance() =
      let directory = root / "provenance"
      createDir(directory)
      var fields = initPropTable()
      fields["provenance_format"] = newInt(1)
      fields["index_digest"] = newStr(release.indexDigest)
      fields["tree_digest"] = release.index.mapEntries["tree_digest"]
      fields["signer"] = newStr(release.signerIdentity)
      fields["registry_url"] = newStr(transport.baseUrl)
      let (file, temporary) = createTempFile("gene-provenance-", ".gene",
        directory)
      defer:
        if fileExists(temporary): removeFile(temporary)
      try:
        file.write(print(newMap(fields)) & "\n")
        file.flushFile()
      finally:
        file.close()
      moveFile(temporary, directory / (hex & ".gene"))
    if dirExists(target):
      try:
        verifyReleaseTree(release.index, target)
        recordVerification(release)
        recordProvenance()
        return target
      except CatchableError:
        makeMaterializedTreeWritable(target)
        removeDir(target)
    createDir(parentDir(target))
    let stage = fetchVerifiedTree(transport, release, parentDir(target))
    var published = false
    try:
      moveDir(stage, target)
      protectMaterializedTree(target)
      recordVerification(release)
      recordProvenance()
      published = true
    finally:
      if not published and dirExists(stage):
        makeMaterializedTreeWritable(stage)
        removeDir(stage)
    target

  result = PackageSourceAdapter(name: name, root: "", url: transport.baseUrl)
  result.candidateLoader = proc(packageName: string, offline: bool):
      seq[RegistryCandidateSource] =
    if offline:
      raisePackageError(pecNotFound,
        "offline hosted resolution needs a lock and cached objects",
        [packageName])
    for version in fetchRegistryVersions(transport, packageName):
      let release = checkedRelease(version.indexDigest, packageName,
        version.version, "", "")
      result.add RegistryCandidateSource(
        manifestRoot: ensureManifest(release),
        version: version.version,
        manifestDigest: release.indexField("manifest_digest"),
        treeDigest: release.indexField("tree_digest"),
        indexDigest: release.indexDigest,
        yanked: version.yanked)
  result.sourceRootLoader = proc(pkg: Package, offline: bool): string =
    if pkg.sourcePath != canonicalPackageUrl(transport.baseUrl, pkg.name):
      raisePackageError(pecIdentityMismatch,
        "locked registry URL differs from configured hosted source")
    if offline:
      raisePackageError(pecNotFound,
        "offline hosted source needs a cached package object", [pkg.name])
    var indexDigest = pkg.releaseIndexDigest
    if indexDigest.len == 0:
      for version in fetchRegistryVersions(transport, pkg.name):
        if version.version == pkg.version:
          indexDigest = version.indexDigest
          break
    if indexDigest.len == 0:
      raisePackageError(pecNotFound,
        "locked hosted release is absent from registry metadata",
        [pkg.name & "@" & pkg.version])
    requireDigest(indexDigest, "hosted release index digest")
    let release = checkedRelease(indexDigest, pkg.name, pkg.version,
      pkg.manifestDigest, pkg.treeDigest)
    ensureTree(release)
  result.verifyLockedRelease = proc(pkg: Package, offline: bool,
                                    workspaceRoot: string) =
    if pkg.sourcePath != canonicalPackageUrl(transport.baseUrl, pkg.name):
      raisePackageError(pecIdentityMismatch,
        "locked registry URL differs from configured hosted source")
    var digest = pkg.releaseIndexDigest
    let mapping = mappingPath(pkg.name, pkg.version)
    if digest.len == 0 and fileExists(mapping):
      digest = readIndexDigest(mapping)
    let vendorBundle = vendorSignaturePath(pkg,
      workspaceRoot / "vendor" / "packages")
    if digest.len == 0 and dirExists(vendorBundle):
      digest = readIndexDigest(vendorBundle / "index.digest")
    if digest.len == 0:
      if offline:
        raisePackageError(pecNotFound,
          "offline signed release record is unavailable",
          [pkg.name & "@" & pkg.version])
      for version in fetchRegistryVersions(transport, pkg.name):
        if version.version == pkg.version:
          digest = version.indexDigest
          break
    if digest.len == 0:
      raisePackageError(pecNotFound,
        "locked hosted version is unavailable", [pkg.name & "@" & pkg.version])
    requireDigest(digest, "cached release index digest")
    let bundle = root / "verification" / digest[7 .. ^1]
    var release: VerifiedRelease
    try:
      release = loadVerifiedRelease(bundle, crypto, trust, digest)
    except CatchableError:
      if dirExists(vendorBundle):
        try:
          if readIndexDigest(vendorBundle / "index.digest") == digest:
            release = loadVerifiedRelease(vendorBundle, crypto, trust, digest)
        except CatchableError:
          discard
      if release == nil:
        if offline:
          raisePackageError(pecNotFound,
            "offline signed release evidence is unavailable or invalid",
            [pkg.name & "@" & pkg.version])
        release = checkedRelease(digest, pkg.name, pkg.version,
          pkg.manifestDigest, pkg.treeDigest)
        recordVerification(release)
    if release.indexField("name") != pkg.name or
        release.indexField("version") != pkg.version or
        release.indexField("manifest_digest") != pkg.manifestDigest or
        release.indexField("tree_digest") != pkg.treeDigest:
      raisePackageError(pecIdentityMismatch,
        "cached signed release differs from the locked package identity",
        [pkg.name & "@" & pkg.version])
  result.exportVendorSignature = proc(pkg: Package, vendorRoot: string) =
    if pkg.sourcePath != canonicalPackageUrl(transport.baseUrl, pkg.name):
      raisePackageError(pecIdentityMismatch,
        "vendored registry URL differs from configured hosted source")
    let digest = readIndexDigest(mappingPath(pkg.name, pkg.version))
    let release = loadVerifiedRelease(root / "verification" /
      digest[7 .. ^1], crypto, trust, digest)
    if release.indexField("name") != pkg.name or
        release.indexField("version") != pkg.version or
        release.indexField("manifest_digest") != pkg.manifestDigest or
        release.indexField("tree_digest") != pkg.treeDigest:
      raisePackageError(pecIdentityMismatch,
        "vendored signed release differs from package graph",
        [pkg.name & "@" & pkg.version])
    let target = vendorSignaturePath(pkg, vendorRoot)
    let lock = acquireProcessFileLock(vendorRoot / ".locks" / "signatures" /
      name / (pkg.treeDigest.replace("sha256:", "") & ".lock"))
    defer: lock.release()
    if dirExists(target):
      try:
        if readIndexDigest(target / "index.digest") == digest:
          discard loadVerifiedRelease(target, crypto, trust, digest)
          return
      except CatchableError:
        discard
      makeMaterializedTreeWritable(target)
      removeDir(target)
    createDir(parentDir(target))
    let stage = createTempDir("gene-vendor-signature-", "",
                              parentDir(target))
    var published = false
    try:
      saveVerifiedRelease(release, stage)
      writeFile(stage / "index.digest", digest & "\n")
      discard loadVerifiedRelease(stage, crypto, trust, digest)
      moveDir(stage, target)
      protectMaterializedTree(target)
      published = true
    finally:
      if not published and dirExists(stage):
        makeMaterializedTreeWritable(stage)
        removeDir(stage)
