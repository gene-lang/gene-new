## PKG-3 client-side staged publication. Authentication authorizes an owner;
## the Ed25519 signature authenticates the exact immutable release bytes.

import std/[os, sets, strutils, tables, tempfiles]
import ./[digest, package, printer, registry_config, registry_https, registry_release,
          release_crypto, types]

proc checkedUpload(registry: ConfiguredRegistry, httpMethod, path,
                   source, token: string, what: string) =
  let status = registry.transport.uploadRegistryFile(httpMethod, path,
    source, token)
  if status notin [200, 201, 204]:
    raisePackageError(pecIdentityMismatch,
      "registry rejected staged " & what & " with HTTP " & $status)

proc publishPackage*(registry: ConfiguredRegistry, pkg: Package,
                     privateSeed: string, signer = "owner"): string =
  if registry == nil or pkg == nil or pkg.kind != pkRegular or
      signer notin ["owner", "registry"]:
    raisePackageError(pecManifestInvalid,
      "publish requires a regular package, registry, and owner/registry signer")
  if registry.publishTokenFile.len == 0 or
      not fileExists(registry.publishTokenFile) or
      getFileInfo(registry.publishTokenFile, followSymlink = true).isSpecial or
      getFileSize(registry.publishTokenFile) > 4096:
    raisePackageError(pecNotFound,
      "publish token file is missing or exceeds 4096 bytes")
  let token = readFile(registry.publishTokenFile).strip()
  let index = buildReleaseIndex(pkg)
  result = canonicalDigest(index)
  let signature = registry.crypto.signReleaseIndex(privateSeed, index)
  let publicKey = registry.crypto.ed25519PublicKey(privateSeed)
  let keyId = releaseKeyId(publicKey)
  let parts = pkg.name.split('/')
  var ownerRecord = NIL
  var ownerSignature = ""
  if signer == "owner" and not registry.trust.pinnedOwnerKeys.hasKey(parts[0]):
    let keyPrefix = "/v1/owners/" & parts[0] & "/keys/" & keyId[7 .. ^1]
    ownerRecord = readOwnerKeyRecord(
      registry.transport.fetchRegistryBytes(keyPrefix & "/record", 4096))
    ownerSignature = registry.transport.fetchRegistryBytes(
      keyPrefix & "/signature", 64)
  discard verifyTrustedRelease(registry.trust, registry.crypto, index,
    signature, signer, ownerRecord, ownerSignature)
  let envelope = releaseSignatureEnvelope(signer, keyId, signature)
  let stagePrefix = "/v1/staging/" & parts[0] & "/" & parts[1] & "/" &
    pkg.version
  var uploaded = initHashSet[string]()
  for item in index.mapEntries["files"].listItems:
    let fields = item.mapEntries
    let digest = fields["digest"].strVal
    if digest in uploaded:
      continue
    uploaded.incl digest
    let source = pkg.root / fields["path"].strVal
    if not fileExists(source) or symlinkExists(source) or
        getFileInfo(source, followSymlink = false).isSpecial or
        getFileSize(source) != fields["size"].intVal or
        "sha256:" & sha256File(source) != digest:
      raisePackageError(pecIdentityMismatch,
        "source file changed before staged upload", [source])
    checkedUpload(registry, "PUT", stagePrefix & "/objects/" &
      digest[7 .. ^1], source, token, "object")
  let (indexFile, indexPath) = createTempFile("gene-release-index-", ".gene")
  let (signatureFile, signaturePath) =
    createTempFile("gene-release-signature-", ".gene")
  let (commitFile, commitPath) = createTempFile("gene-release-commit-", ".gene")
  defer:
    for path in [indexPath, signaturePath, commitPath]:
      if fileExists(path): removeFile(path)
  indexFile.write(print(index) & "\n")
  indexFile.close()
  signatureFile.write(print(envelope) & "\n")
  signatureFile.close()
  var commit = initPropTable()
  commit["publish_format"] = newInt(1)
  commit["index_digest"] = newStr(result)
  commitFile.write(print(newMap(commit)) & "\n")
  commitFile.close()
  checkedUpload(registry, "PUT", stagePrefix & "/index/" & result[7 .. ^1],
    indexPath, token, "index")
  checkedUpload(registry, "PUT", stagePrefix & "/signature/" &
    result[7 .. ^1], signaturePath, token, "signature")
  let current = canonicalDigest(buildReleaseIndex(pkg))
  if current != result:
    raisePackageError(pecIdentityMismatch,
      "source tree changed before registry commit", [pkg.root])
  let status = registry.transport.uploadRegistryFile("POST",
    "/v1/publish/" & parts[0] & "/" & parts[1] & "/" & pkg.version,
    commitPath, token)
  if status == 409:
    raisePackageError(pecVersionConflict,
      "registry version already names a different release",
      [pkg.name & "@" & pkg.version])
  if status notin [200, 201]:
    raisePackageError(pecIdentityMismatch,
      "registry publish failed with HTTP " & $status)
  let published = fetchVerifiedRelease(registry.transport, registry.crypto,
    registry.trust, result)
  if published.indexDigest != result:
    raisePackageError(pecIdentityMismatch,
      "registry published a different release index")
