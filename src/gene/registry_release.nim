## Read-only PKG-3 release admission over the explicit HTTPS transport.
## Index and signature are immutable objects addressed by the index digest.
## Their publication/version mapping is a separate registry operation.

import std/[algorithm, base64, os, sets, strutils, tables, tempfiles]
import ./[package, reader, registry_https, release_crypto, types]

type
  RegistryVersion* = object
    version*: string
    indexDigest*: string
    yanked*: bool

  VerifiedRelease* = ref object
    verifiedIndex: Value
    verifiedDigest: string
    verifiedSigner: string
    indexText: string
    envelopeText: string
    ownerText: string
    ownerSignature: string

  ReleaseSignatureEnvelope = object
    signer: string
    keyId: string
    signature: string

proc index*(release: VerifiedRelease): Value =
  if release == nil:
    raisePackageError(pecIdentityMismatch, "verified release is absent")
  release.verifiedIndex

proc indexDigest*(release: VerifiedRelease): string =
  if release == nil:
    raisePackageError(pecIdentityMismatch, "verified release is absent")
  release.verifiedDigest

proc signerIdentity*(release: VerifiedRelease): string =
  if release == nil:
    raisePackageError(pecIdentityMismatch, "verified release is absent")
  release.verifiedSigner

const
  MaxRegistryVersionPageBytes* = 512 * 1024
  MaxRegistryVersionPages* = 64
  MaxRegistryVersionsPerPage* = 500

proc registryListingDigest*(versions: openArray[RegistryVersion]): string =
  ## Canonical complete-set commitment, in descending semantic-version order.
  var values: seq[Value]
  for version in versions:
    var fields = initPropTable()
    fields["version"] = newStr(version.version)
    fields["index_digest"] = newStr(version.indexDigest)
    fields["yanked"] = newBool(version.yanked)
    values.add newMap(fields)
  canonicalDigest(newList(values))

proc requireDigest*(digest, field: string) =
  if digest.len != 71 or not digest.startsWith("sha256:"):
    raisePackageError(pecManifestInvalid,
      field & " must be a SHA-256 digest")
  for ch in digest[7 .. ^1]:
    if ch notin {'0' .. '9', 'a' .. 'f'}:
      raisePackageError(pecManifestInvalid,
        field & " must use lowercase hexadecimal")

proc exactFields(value: Value, names: openArray[string], context: string) =
  if value.kind != vkMap:
    raisePackageError(pecManifestInvalid, context & " must be a Map")
  let fields = value.mapEntries
  for name in fields.keys:
    if name notin names:
      raisePackageError(pecManifestInvalid,
        context & " has unexpected field: " & name)
  for name in names:
    if not fields.hasKey(name):
      raisePackageError(pecManifestInvalid,
        context & " requires ^" & name)

proc parseVersionPage(source, name: string, requestedPage: int):
    tuple[pageCount: int, listingDigest: string,
          releases: seq[RegistryVersion]] =
  if source.len > MaxRegistryVersionPageBytes:
    raisePackageError(pecManifestInvalid,
      "registry version page exceeds the byte limit")
  var forms: seq[Value]
  try:
    forms = readAll(source, "registry version page",
      ReadOptions(maxDepth: 8, rejectDuplicateProps: true))
  except ReadError as error:
    raisePackageError(pecManifestInvalid, error.msg,
      ["registry version page"])
  if forms.len != 1:
    raisePackageError(pecManifestInvalid,
      "registry version page must contain one Map")
  let page = forms[0]
  exactFields(page,
    ["metadata_format", "name", "page", "page_count", "listing_digest",
     "releases"],
    "registry version page")
  let fields = page.mapEntries
  if fields["metadata_format"].kind != vkInt or
      fields["metadata_format"].intVal != 1 or
      fields["name"].kind != vkString or fields["name"].strVal != name or
      fields["page"].kind != vkInt or
      fields["page"].intVal != requestedPage or
      fields["page_count"].kind != vkInt or
      fields["page_count"].intVal < 1 or
      fields["page_count"].intVal > MaxRegistryVersionPages:
    raisePackageError(pecManifestInvalid,
      "registry version page header is inconsistent")
  result.pageCount = int(fields["page_count"].intVal)
  if fields["listing_digest"].kind != vkString:
    raisePackageError(pecManifestInvalid,
      "registry version page ^listing_digest must be Str")
  result.listingDigest = fields["listing_digest"].strVal
  requireDigest(result.listingDigest, "registry listing_digest")
  if requestedPage >= result.pageCount:
    raisePackageError(pecManifestInvalid,
      "registry version page is outside declared coverage")
  if fields["releases"].kind != vkList or
      fields["releases"].listItems.len > MaxRegistryVersionsPerPage:
    raisePackageError(pecManifestInvalid,
      "registry version entries exceed the page limit")
  for item in fields["releases"].listItems:
    exactFields(item, ["version", "index_digest", "yanked"],
      "registry version entry")
    let entry = item.mapEntries
    if entry["version"].kind != vkString or
        entry["index_digest"].kind != vkString or
        entry["yanked"].kind != vkBool:
      raisePackageError(pecManifestInvalid,
        "registry version entry has invalid field types")
    discard parseSemVersion(entry["version"].strVal,
      "registry version entry")
    requireDigest(entry["index_digest"].strVal,
      "registry version index_digest")
    result.releases.add RegistryVersion(
      version: entry["version"].strVal,
      indexDigest: entry["index_digest"].strVal,
      yanked: entry["yanked"].boolVal)

proc fetchRegistryVersions*(transport: RegistryHttpsTransport,
                            name: string): seq[RegistryVersion] =
  validatePackageName(name, "registry version listing")
  let parts = name.split('/')
  let prefix = "/v1/packages/" & parts[0] & "/" & parts[1] & "/versions/"
  let first = parseVersionPage(transport.fetchRegistryBytes(prefix & "0",
    MaxRegistryVersionPageBytes), name, 0)
  result = first.releases
  for page in 1 ..< first.pageCount:
    let next = parseVersionPage(transport.fetchRegistryBytes(prefix & $page,
      MaxRegistryVersionPageBytes), name, page)
    if next.pageCount != first.pageCount or
        next.listingDigest != first.listingDigest:
      raisePackageError(pecIdentityMismatch,
        "registry version pagination changed during retrieval")
    result.add next.releases
  var seen = initHashSet[string]()
  for release in result:
    if release.version in seen:
      raisePackageError(pecIdentityMismatch,
        "registry version listing repeats a version", [release.version])
    seen.incl release.version
  result.sort(proc (a, b: RegistryVersion): int =
    result = -cmpSemVersion(parseSemVersion(a.version,
      "registry version listing"), parseSemVersion(b.version,
      "registry version listing"))
    if result == 0: result = -cmp(a.version, b.version))
  if registryListingDigest(result) != first.listingDigest:
    raisePackageError(pecIdentityMismatch,
      "registry version pages do not cover the committed listing")

proc readSignatureEnvelope(source: string): ReleaseSignatureEnvelope =
  if source.len > 4096:
    raisePackageError(pecManifestInvalid,
      "release signature envelope exceeds the byte limit")
  var forms: seq[Value]
  try:
    forms = readAll(source, "release signature",
      ReadOptions(maxDepth: 4, rejectDuplicateProps: true))
  except ReadError as error:
    raisePackageError(pecManifestInvalid, error.msg,
      ["release signature"])
  if forms.len != 1 or forms[0].kind != vkMap:
    raisePackageError(pecManifestInvalid,
      "release signature must contain one Map")
  let fields = forms[0].mapEntries
  for name in fields.keys:
    if name notin ["signature_format", "signer", "key_id", "signature"]:
      raisePackageError(pecManifestInvalid,
        "release signature has unexpected field: " & name)
  for name in ["signature_format", "signer", "key_id", "signature"]:
    if not fields.hasKey(name):
      raisePackageError(pecManifestInvalid,
        "release signature requires ^" & name)
  if fields["signature_format"].kind != vkInt or
      fields["signature_format"].intVal != 1:
    raisePackageError(pecManifestInvalid,
      "release signature ^signature_format must be 1")
  if fields["signer"].kind != vkString or
      fields["signer"].strVal notin ["registry", "owner"]:
    raisePackageError(pecManifestInvalid,
      "release signature ^signer must be registry or owner")
  result.signer = fields["signer"].strVal
  if fields["key_id"].kind != vkString:
    raisePackageError(pecManifestInvalid,
      "release signature ^key_id must be Str")
  result.keyId = fields["key_id"].strVal
  requireDigest(result.keyId, "release signature key_id")
  if fields["signature"].kind != vkString:
    raisePackageError(pecManifestInvalid,
      "release signature ^signature must be Str")
  let encoded = fields["signature"].strVal
  if encoded.len != 88:
    raisePackageError(pecManifestInvalid,
      "release signature must be canonical base64")
  try:
    result.signature = base64.decode(encoded)
  except ValueError:
    raisePackageError(pecManifestInvalid,
      "release signature is not base64")
  if result.signature.len != 64 or base64.encode(result.signature) != encoded:
    raisePackageError(pecManifestInvalid,
      "release signature must be canonical base64")

proc releaseSignatureEnvelope*(signer, keyId, signature: string): Value =
  ## Publication helper; the reader above is still the admission authority.
  if signer notin ["registry", "owner"] or signature.len != 64:
    raisePackageError(pecManifestInvalid,
      "release signature envelope has invalid signer or bytes")
  requireDigest(keyId, "release signature key_id")
  var fields = initPropTable()
  fields["signature_format"] = newInt(1)
  fields["signer"] = newStr(signer)
  fields["key_id"] = newStr(keyId)
  fields["signature"] = newStr(base64.encode(signature))
  newMap(fields)

proc verifyReleaseMaterial*(crypto: ReleaseCrypto, trust: ReleaseTrust,
                           indexDigest, indexText, envelopeText, ownerText,
                           ownerSignature: string): VerifiedRelease =
  requireDigest(indexDigest, "release index digest")
  let index = readReleaseIndex(indexText)
  if canonicalDigest(index) != indexDigest:
    raisePackageError(pecIdentityMismatch,
      "release index digest does not match its address")
  let envelope = readSignatureEnvelope(envelopeText)
  let ownerRecord =
    if ownerText.len > 0: readOwnerKeyRecord(ownerText)
    else: NIL
  let identity = verifyTrustedRelease(trust, crypto, index,
    envelope.signature, envelope.signer, ownerRecord, ownerSignature)
  if not identity.endsWith(envelope.keyId):
    raisePackageError(pecIdentityMismatch,
      "release signature key ID disagrees with the verified signer")
  VerifiedRelease(verifiedIndex: index, verifiedDigest: indexDigest,
    verifiedSigner: identity, indexText: indexText,
    envelopeText: envelopeText, ownerText: ownerText,
    ownerSignature: ownerSignature)

proc fetchVerifiedRelease*(transport: RegistryHttpsTransport,
                           crypto: ReleaseCrypto, trust: ReleaseTrust,
                           indexDigest: string): VerifiedRelease =
  requireDigest(indexDigest, "release index digest")
  let hex = indexDigest[7 .. ^1]
  let prefix = "/v1/releases/" & hex
  let indexText = transport.fetchRegistryBytes(prefix & "/index",
    MaxReleaseIndexBytes)
  let index = readReleaseIndex(indexText)
  if canonicalDigest(index) != indexDigest:
    raisePackageError(pecIdentityMismatch,
      "downloaded release index digest does not match its address")
  let envelopeText = transport.fetchRegistryBytes(prefix & "/signature", 4096)
  let envelope = readSignatureEnvelope(envelopeText)
  var ownerText = ""
  var ownerRecordSignature = ""
  if envelope.signer == "owner":
    let owner = index.mapEntries["name"].strVal.split('/')[0]
    if not trust.pinnedOwnerKeys.hasKey(owner):
      let keyPrefix = "/v1/owners/" & owner & "/keys/" &
        envelope.keyId[7 .. ^1]
      ownerText = transport.fetchRegistryBytes(keyPrefix & "/record", 4096)
      ownerRecordSignature = transport.fetchRegistryBytes(
        keyPrefix & "/signature", 64)
  verifyReleaseMaterial(crypto, trust, indexDigest, indexText, envelopeText,
    ownerText, ownerRecordSignature)

proc saveVerifiedRelease*(release: VerifiedRelease, directory: string) =
  if release == nil or not directory.isAbsolute or not dirExists(directory):
    raisePackageError(pecBoundary,
      "verified release cache directory must exist")
  writeFile(directory / "index.gene", release.indexText)
  writeFile(directory / "signature.gene", release.envelopeText)
  if release.ownerText.len > 0:
    writeFile(directory / "owner.gene", release.ownerText)
    writeFile(directory / "owner.sig", release.ownerSignature)

proc loadVerifiedRelease*(directory: string, crypto: ReleaseCrypto,
                          trust: ReleaseTrust,
                          indexDigest: string): VerifiedRelease =
  if not directory.isAbsolute or not dirExists(directory) or
      symlinkExists(directory):
    raisePackageError(pecNotFound,
      "cached signed release is unavailable", [directory])
  proc boundedFile(name: string, limit: int, required: bool): string =
    let path = directory / name
    if not fileExists(path):
      if required:
        raisePackageError(pecNotFound,
          "cached signed release is missing " & name, [directory])
      return ""
    if symlinkExists(path) or
        getFileInfo(path, followSymlink = false).isSpecial:
      raisePackageError(pecBoundary,
        "cached signed release contains an unsafe file", [path])
    if getFileSize(path) > limit:
      raisePackageError(pecManifestInvalid,
        "cached signed release file exceeds limit", [path])
    readFile(path)
  let indexText = boundedFile("index.gene", MaxReleaseIndexBytes, true)
  let envelopeText = boundedFile("signature.gene", 4096, true)
  let ownerText = boundedFile("owner.gene", 4096, false)
  let ownerSignature = boundedFile("owner.sig", 64, false)
  verifyReleaseMaterial(crypto, trust, indexDigest, indexText, envelopeText,
    ownerText, ownerSignature)

proc fetchVerifiedTree*(transport: RegistryHttpsTransport,
                        release: VerifiedRelease,
                        stagingParent: string): string =
  ## A private, complete source tree is returned only after every object and
  ## the tree/manifest identities have been verified. The caller owns this
  ## staging directory and publishes it through the existing store transaction.
  if release == nil or release.verifiedIndex.kind != vkMap or
      not stagingParent.isAbsolute or not dirExists(stagingParent):
    raisePackageError(pecBoundary,
      "verified release needs an absolute staging parent")
  let stage = createTempDir("gene-release-", "", stagingParent)
  var admitted = false
  try:
    for item in release.verifiedIndex.mapEntries["files"].listItems:
      let fields = item.mapEntries
      let path = fields["path"].strVal
      let digest = fields["digest"].strVal
      let target = stage / path
      createDir(parentDir(target))
      let objectPath = "/v1/objects/" & digest[7 .. ^1]
      let fetched = transport.fetchRegistryObject(objectPath, digest,
        fields["size"].intVal, stage)
      if fileExists(target) or dirExists(target):
        raisePackageError(pecIdentityMismatch,
          "release target already exists in staging", [path])
      moveFile(fetched, target)
      when defined(posix):
        var permissions = {fpUserRead, fpUserWrite}
        if fields["executable"].boolVal:
          permissions.incl fpUserExec
        setFilePermissions(target, permissions)
    verifyReleaseTree(release.verifiedIndex, stage)
    result = stage
    admitted = true
  finally:
    if not admitted and dirExists(stage):
      makeMaterializedTreeWritable(stage)
      removeDir(stage)
