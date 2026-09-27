## Persistent PKG-3 registry. One writer owns the store; version selection is
## the final fsynced rename after complete signature/tree admission.
import std/[algorithm, base64, os, sets, strutils, tables, tempfiles, times]
import ./[digest, package, printer, process_lock, reader, registry_release,
          release_crypto, types]
when defined(posix): import std/posix

type
  RegistryServiceError* = object of CatchableError
    status*: int
  RegistryPublisher = object
    token: string
    keys: seq[string]
  RegistryReply* = object
    status*: int
    body*, file*: string
  RegistryStore* = ref object
    root*: string
    port*, requestTimeoutMs*: int
    maxObjectBytes*, maxStorageBytes*, maxReleaseBytes*: int64
    maxStages*, stageTtlSeconds*: int
    crypto: ReleaseCrypto
    registryKey: string
    publishers: Table[string, RegistryPublisher]
    delegations: Table[string, tuple[record, signature: string]]
    lock: ProcessFileLock
    locked: bool

proc refuse(status: int, message: string) {.noreturn.} =
  var error = newException(RegistryServiceError, message)
  error.status = status
  raise error

proc publicationCheckpoint(name: string) =
  when defined(geneRegistryFaultInjection) and defined(posix):
    if getEnv("GENE_REGISTRY_FAILPOINT") == name: posix.exitnow(73)

proc datum(source, context: string, limit: int,
           required: openArray[string], optional: openArray[string] = []): Value =
  if source.len > limit: refuse(413, context & " exceeds byte limit")
  let forms = readAll(source, context,
    ReadOptions(maxDepth: 8, rejectDuplicateProps: true))
  if forms.len != 1 or forms[0].kind != vkMap:
    refuse(400, context & " requires one inert Map")
  result = forms[0]
  let fields = result.mapEntries
  for name in fields.keys:
    if name notin required and name notin optional:
      refuse(400, context & " has unknown field " & name)
  for name in required:
    if not fields.hasKey(name): refuse(400, context & " requires " & name)

proc text(value: Value, context: string): string =
  if value.kind != vkString: refuse(400, context & " requires Str")
  value.strVal

proc keyBytes(value: Value): string =
  let encoded = text(value, "public key")
  result = base64.decode(encoded)
  if result.len != 32 or base64.encode(result) != encoded:
    refuse(400, "public key requires canonical base64 for 32 bytes")

proc integer(fields: PropTable, name: string, fallback, low, high: int64): int64 =
  if not fields.hasKey(name): return fallback
  if fields[name].kind != vkInt: refuse(400, name & " requires Int")
  result = fields[name].intVal
  if result < low or result > high: refuse(400, name & " is outside its limit")

proc syncPath(path: string) =
  when defined(posix):
    let fd = posix.open(path.cstring, posix.O_RDONLY, 0)
    if fd < 0: raiseOSError(osLastError())
    defer: discard posix.close(fd)
    if posix.fsync(fd) != 0: raiseOSError(osLastError())
  else:
    refuse(500, "registry storage currently requires POSIX durability")

proc durableDir(path: string) =
  if symlinkExists(path): refuse(500, "registry storage contains a symlink")
  if dirExists(path): return
  durableDir(parentDir(path))
  createDir(path)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  syncPath(path)
  syncPath(parentDir(path))

proc safeFile(path: string, limit: int64): bool =
  if symlinkExists(path): refuse(500, "registry storage contains a symlink")
  if not fileExists(path): return false
  if getFileInfo(path, followSymlink = false).isSpecial or
      getFileSize(path) > limit:
    refuse(500, "registry storage contains an invalid file")
  true

proc boundedFile(path: string, limit: int64): string =
  if not safeFile(path, limit): refuse(404, "registry record is absent")
  readFile(path)

proc atomicFile(path, bytes: string) =
  durableDir(parentDir(path))
  let (handle, temp) = createTempFile("write-", "", parentDir(path))
  var moved = false
  try:
    try: handle.write(bytes)
    finally: handle.close()
    setFilePermissions(temp, {fpUserRead, fpUserWrite})
    syncPath(temp)
    moveFile(temp, path)
    moved = true
    syncPath(parentDir(path))
  finally:
    if not moved and fileExists(temp): removeFile(temp)

proc immutableFile(path, bytes: string): bool =
  if safeFile(path, int64(bytes.len)):
    if readFile(path) != bytes: refuse(409, "immutable registry record conflicts")
    return false
  atomicFile(path, bytes)
  true

proc close*(store: RegistryStore) =
  if store != nil:
    if store.crypto != nil: store.crypto.close()
    if store.locked:
      store.lock.release()
      store.locked = false

proc storageBytes(store: RegistryStore): int64 =
  var bytes = 0'i64
  proc walk(path: string) =
    for kind, child in walkDir(path):
      case kind
      of pcDir:
        bytes += 4096
        walk(child)
      of pcFile:
        if getFileInfo(child, followSymlink = false).isSpecial:
          refuse(500, "registry storage contains a special file")
        bytes += max(4096'i64, getFileSize(child))
      of pcLinkToFile, pcLinkToDir:
        refuse(500, "registry storage contains a symlink")
  walk(store.root)
  result = bytes

proc pruneStages*(store: RegistryStore)

proc checkUploadCapacity*(store: RegistryStore, size: int64) =
  store.pruneStages()
  if store.storageBytes() + max(4096'i64, size) > store.maxStorageBytes:
    refuse(507, "registry storage budget exhausted")

proc pruneStages*(store: RegistryStore) =
  let root = store.root / "staging"
  for kind, path in walkDir(root):
    if kind != pcDir: refuse(500, "invalid staging directory")
    let touched = path / "touched"
    if not fileExists(touched) or
        (getTime() - getLastModificationTime(touched)).inSeconds >= store.stageTtlSeconds:
      removeDir(path)
  syncPath(root)

proc openRegistryStore*(configPath: string): RegistryStore =
  let config = datum(boundedFile(configPath, 65536), "registry service config", 65536,
    ["registry_service_format", "root", "registry_key", "crypto", "publishers"],
    ["port", "request_timeout_ms", "max_object_bytes", "max_release_bytes",
     "max_storage_bytes", "max_stages", "stage_ttl_seconds", "delegations"])
  let fields = config.mapEntries
  if fields["registry_service_format"].kind != vkInt or
      fields["registry_service_format"].intVal != 1:
    refuse(400, "registry_service_format must be 1")
  result = RegistryStore(root: text(fields["root"], "root"),
    registryKey: keyBytes(fields["registry_key"]))
  let store = result
  try:
    if not store.root.isAbsolute: refuse(400, "registry root must be absolute")
    store.root = normalizedPath(store.root)
    durableDir(store.root)
    setFilePermissions(store.root, {fpUserRead, fpUserWrite, fpUserExec})
    store.lock = acquireProcessFileLock(store.root / "service.lock", 50)
    store.locked = true
    store.crypto = loadReleaseCrypto(text(fields["crypto"], "crypto"))
    store.port = int(integer(fields, "port", 8080, 0, 65535))
    store.requestTimeoutMs = int(integer(fields, "request_timeout_ms", 30000, 100, 300000))
    store.maxObjectBytes = integer(fields, "max_object_bytes", 64*1024*1024, 1, MaxReleaseObjectBytes)
    store.maxReleaseBytes = integer(fields, "max_release_bytes", 1024*1024*1024, 1, 16'i64*1024*1024*1024)
    store.maxStorageBytes = integer(fields, "max_storage_bytes", 10'i64*1024*1024*1024, 1, 1024'i64*1024*1024*1024)
    store.maxStages = int(integer(fields, "max_stages", 128, 1, 4096))
    store.stageTtlSeconds = int(integer(fields, "stage_ttl_seconds", 86400, 60, 604800))
    if fields["publishers"].kind != vkList or fields["publishers"].listItems.len > 128:
      refuse(400, "publishers requires a List of at most 128 entries")
    for value in fields["publishers"].listItems:
      let item = datum(print(value), "publisher", 8192, ["owner", "public_keys", "token_file"]).mapEntries
      let owner = text(item["owner"], "owner")
      validatePackageName(owner & "/probe", "publisher owner")
      if store.publishers.hasKey(owner): refuse(400, "publisher owner is repeated")
      let tokenPath = text(item["token_file"], "token_file")
      if not tokenPath.isAbsolute: refuse(400, "token_file must be absolute")
      if (getFilePermissions(tokenPath) * {fpGroupRead, fpGroupWrite,
          fpOthersRead, fpOthersWrite}).len > 0:
        refuse(400, "publisher token file must be private to its owner")
      let token = boundedFile(tokenPath, 4096).strip()
      if token.len < 16 or not token.allCharsInSet({'a'..'z','A'..'Z','0'..'9','-','.', '_','~','+','/','='}):
        refuse(400, "publisher token requires 16..4096 bearer characters")
      if item["public_keys"].kind != vkList or
          item["public_keys"].listItems.len notin 1..16:
        refuse(400, "publisher public_keys requires 1..16 keys")
      var publisher = RegistryPublisher(token: token)
      for key in item["public_keys"].listItems: publisher.keys.add keyBytes(key)
      store.publishers[owner] = publisher
    if fields.hasKey("delegations"):
      if fields["delegations"].kind != vkList or fields["delegations"].listItems.len > 2048:
        refuse(400, "delegations requires at most 2048 entries")
      for value in fields["delegations"].listItems:
        let item = datum(print(value), "delegation", 8192, ["record_file", "signature_file"]).mapEntries
        let recordPath = text(item["record_file"], "record_file")
        let signaturePath = text(item["signature_file"], "signature_file")
        if not recordPath.isAbsolute or not signaturePath.isAbsolute:
          refuse(400, "delegation files must be absolute")
        let recordText = boundedFile(recordPath, 4096)
        let record = readOwnerKeyRecord(recordText)
        let signature = boundedFile(signaturePath, 64)
        if signature.len != 64 or not store.crypto.ed25519Verify(store.registryKey,
            ownerKeySignaturePayload(record), signature):
          refuse(400, "owner delegation signature is invalid")
        let f = record.mapEntries
        let address = f["owner"].strVal & "/" & f["key_id"].strVal[7..^1]
        if store.delegations.hasKey(address): refuse(400, "delegation is repeated")
        store.delegations[address] = (recordText, signature)
    for dir in ["objects", "releases", "packages", "staging", "tmp"]:
      durableDir(store.root / dir)
    discard store.storageBytes() # reject unsafe pre-existing storage before cleanup
    for kind, path in walkDir(store.root / "tmp"):
      if kind == pcDir: removeDir(path)
      elif kind == pcFile: removeFile(path)
    let identity = base64.encode(store.registryKey) & "\n"
    discard immutableFile(store.root / "registry-key", identity)
    store.pruneStages()
  except:
    store.close()
    raise

proc pathParts(path: string): seq[string] =
  if path.len > 4096 or not path.startsWith("/") or
      not path.allCharsInSet({'a'..'z','A'..'Z','0'..'9','/','-','_','.','+'}):
    refuse(400, "invalid registry path")
  result = path.split('/')[1..^1]
  for part in result:
    if part.len == 0 or part in [".", ".."]: refuse(400, "invalid registry path segment")

proc coordinate(parts: seq[string]): tuple[name, version, owner: string] =
  result = (parts[2] & "/" & parts[3], parts[4], parts[2])
  validatePackageName(result.name, "publication coordinate")
  discard parseSemVersion(result.version, "publication coordinate")

proc authorized(store: RegistryStore, owner, authorization: string) =
  if not store.publishers.hasKey(owner): refuse(403, "owner is not authorized")
  let expected = "Bearer " & store.publishers[owner].token
  var difference = expected.len xor authorization.len
  for i in 0..<expected.len:
    difference = difference or (ord(expected[i]) xor
      (if i < authorization.len: ord(authorization[i]) else: 0))
  if difference != 0: refuse(403, "owner is not authorized")

proc requestBodyLimit*(store: RegistryStore, verb, path, authorization: string): int64 =
  let parts = pathParts(path)
  if verb == "GET": return 0
  if (verb == "PUT" and parts.len == 7 and parts[0..1] == @["v1", "staging"]) or
      (verb == "POST" and parts.len == 5 and parts[0] == "v1" and parts[1] in ["publish", "yank"]):
    let coord = coordinate(parts)
    store.authorized(coord.owner, authorization)
    if verb == "POST": return 4096
    requireDigest("sha256:" & parts[6], "staging digest")
    case parts[5]
    of "objects": return store.maxObjectBytes
    of "index": return MaxReleaseIndexBytes
    of "signature": return 4096
    else: refuse(404, "staging kind is absent")
  refuse(404, "registry endpoint is absent")

proc stagePath(store: RegistryStore, name, version: string): string =
  store.root / "staging" / sha256Hex(name & "\0" & version)

proc versionPath(store: RegistryStore, name, version: string): string =
  store.root / "packages" / name / (version & ".gene")

proc readVersion(path: string): RegistryVersion =
  let fields = datum(boundedFile(path, 4096), "version record", 4096,
    ["version", "index_digest", "yanked"]).mapEntries
  result.version = text(fields["version"], "version")
  discard parseSemVersion(result.version, "version record")
  result.indexDigest = text(fields["index_digest"], "index_digest")
  requireDigest(result.indexDigest, "version index_digest")
  if fields["yanked"].kind != vkBool: refuse(500, "invalid yanked record")
  result.yanked = fields["yanked"].boolVal

proc versionValue(version: RegistryVersion): Value =
  var fields = initPropTable()
  fields["version"] = newStr(version.version)
  fields["index_digest"] = newStr(version.indexDigest)
  fields["yanked"] = newBool(version.yanked)
  newMap(fields)

proc versions(store: RegistryStore, name: string): seq[RegistryVersion] =
  let directory = store.root / "packages" / name
  if not dirExists(directory): return
  for kind, path in walkDir(directory):
    if kind != pcFile: refuse(500, "invalid package version storage")
    if path.endsWith(".gene"):
      let version = readVersion(path)
      if extractFilename(path) != version.version & ".gene": refuse(500, "version path disagrees")
      result.add version
  if result.len > MaxRegistryVersionsPerPage * MaxRegistryVersionPages:
    refuse(500, "package version limit exceeded")
  result.sort(proc(a, b: RegistryVersion): int =
    result = -cmpSemVersion(parseSemVersion(a.version, "version"),
                            parseSemVersion(b.version, "version"))
    if result == 0: result = -cmp(a.version, b.version))

proc verifySignature(store: RegistryStore, coord: tuple[name, version, owner: string],
                     digest, indexText, envelopeText: string): VerifiedRelease =
  let envelope = datum(envelopeText, "release signature", 4096,
    ["signature_format", "signer", "key_id", "signature"]).mapEntries
  let keyId = text(envelope["key_id"], "signature key_id")
  requireDigest(keyId, "signature key_id")
  var trust = newReleaseTrust(store.registryKey)
  for key in store.publishers[coord.owner].keys:
    if releaseKeyId(key) == keyId: trust.pinnedOwnerKeys[coord.owner] = key
  if text(envelope["signer"], "signer") == "owner" and
      not trust.pinnedOwnerKeys.hasKey(coord.owner):
    refuse(403, "release signer is not authorized for owner")
  result = verifyReleaseMaterial(store.crypto, trust, digest, indexText,
                                 envelopeText, "", "")
  let index = result.index.mapEntries
  if index["name"].strVal != coord.name or index["version"].strVal != coord.version:
    refuse(400, "signed release disagrees with publication coordinate")

proc verifyStaged(store: RegistryStore, coord: tuple[name, version, owner: string],
                  digest, stage: string): VerifiedRelease =
  let hex = digest[7..^1]
  store.verifySignature(coord, digest,
    boundedFile(stage / "index" / hex, MaxReleaseIndexBytes),
    boundedFile(stage / "signature" / hex, 4096))

proc commit(store: RegistryStore, coord: tuple[name, version, owner: string],
            digest: string): int =
  let stage = store.stagePath(coord.name, coord.version)
  let release = store.verifyStaged(coord, digest, stage)
  let mapping = store.versionPath(coord.name, coord.version)
  if safeFile(mapping, 4096):
    if readVersion(mapping).indexDigest != digest: refuse(409, "package version already names another release")
    return 200
  if store.versions(coord.name).len >= MaxRegistryVersionsPerPage * MaxRegistryVersionPages:
    refuse(413, "package version limit exceeded")
  var total = 0'i64
  var reservation = 32768'i64
  var directories = initHashSet[string]()
  for item in release.index.mapEntries["files"].listItems:
    let fields = item.mapEntries
    total += fields["size"].intVal
    reservation += max(4096'i64, fields["size"].intVal) * 2
    var directory = parentDir(fields["path"].strVal)
    while directory.len > 0 and directory != ".":
      directories.incl directory
      directory = parentDir(directory)
    if total > store.maxReleaseBytes: refuse(413, "release exceeds size limit")
  reservation += int64(directories.len) * 4096 +
    getFileSize(stage / "index" / digest[7..^1]) +
    getFileSize(stage / "signature" / digest[7..^1])
  if store.storageBytes() + reservation > store.maxStorageBytes:
    refuse(507, "registry storage budget exhausted")
  let tree = createTempDir("tree-", "", store.root / "tmp")
  defer: removeDir(tree)
  for item in release.index.mapEntries["files"].listItems:
    let fields = item.mapEntries
    let hex = fields["digest"].strVal[7..^1]
    let source = stage / "objects" / hex
    if not safeFile(source, store.maxObjectBytes): refuse(400, "signed object is missing")
    if getFileSize(source) != fields["size"].intVal or sha256File(source) != hex:
      refuse(400, "signed object size or digest disagrees")
    let target = tree / fields["path"].strVal
    createDir(parentDir(target))
    copyFile(source, target)
    var permissions = {fpUserRead, fpUserWrite}
    if fields["executable"].boolVal: permissions.incl fpUserExec
    setFilePermissions(target, permissions)
  verifyReleaseTree(release.index, tree)
  for item in release.index.mapEntries["files"].listItems:
    let hex = item.mapEntries["digest"].strVal[7..^1]
    let destination = store.root / "objects" / hex
    if safeFile(destination, store.maxObjectBytes):
      if sha256File(destination) != hex: refuse(500, "stored object digest disagrees")
    else:
      let source = stage / "objects" / hex
      # Renaming staged objects would prevent an interrupted commit retry.
      let (handle, temporary) = createTempFile("object-", "", store.root / "tmp")
      handle.close()
      try:
        copyFile(source, temporary)
        syncPath(temporary)
        moveFile(temporary, destination)
        syncPath(parentDir(destination))
      finally:
        if fileExists(temporary): removeFile(temporary)
  publicationCheckpoint("objects_durable")
  let destination = store.root / "releases" / digest[7..^1]
  if not dirExists(destination):
    let temporary = createTempDir("release-", "", store.root / "tmp")
    try:
      atomicFile(temporary / "index", boundedFile(stage / "index" / digest[7..^1], MaxReleaseIndexBytes))
      atomicFile(temporary / "signature", boundedFile(stage / "signature" / digest[7..^1], 4096))
      syncPath(temporary)
      moveDir(temporary, destination)
      syncPath(parentDir(destination))
    finally:
      if dirExists(temporary): removeDir(temporary)
  publicationCheckpoint("release_durable")
  # All referenced bytes are durable before this sole visibility switch.
  atomicFile(mapping, print(versionValue(RegistryVersion(
    version: coord.version, indexDigest: digest, yanked: false))) & "\n")
  publicationCheckpoint("version_selected")
  removeDir(stage)
  syncPath(store.root / "staging")
  201

proc handleRegistryRequest*(store: RegistryStore, verb, path, authorization: string,
                            bodyPath = ""): RegistryReply =
  let limit = store.requestBodyLimit(verb, path, authorization)
  let parts = pathParts(path)
  if verb == "PUT":
    let coord = coordinate(parts)
    if not safeFile(bodyPath, limit): refuse(400, "upload body is absent")
    store.pruneStages()
    let stage = store.stagePath(coord.name, coord.version)
    if not dirExists(stage):
      var count = 0
      for kind, directory in walkDir(store.root / "staging"): inc count
      if count >= store.maxStages: refuse(429, "staging admission limit reached")
      durableDir(stage)
    atomicFile(stage / "touched", $getTime().toUnix & "\n")
    if store.storageBytes() + getFileSize(bodyPath) > store.maxStorageBytes:
      refuse(507, "registry storage budget exhausted")
    let target = stage / parts[5] / parts[6]
    if parts[5] == "objects":
      if sha256File(bodyPath) != parts[6]: refuse(400, "uploaded object digest disagrees")
      if safeFile(target, limit):
        if sha256File(target) != parts[6]: refuse(409, "staged object conflicts")
        return RegistryReply(status: 200)
      durableDir(parentDir(target))
      syncPath(bodyPath)
      moveFile(bodyPath, target)
      syncPath(parentDir(target))
      return RegistryReply(status: 201)
    var bytes = boundedFile(bodyPath, limit)
    if parts[5] == "index":
      let index = readReleaseIndex(bytes)
      if canonicalDigest(index) != "sha256:" & parts[6]: refuse(400, "uploaded index digest disagrees")
      bytes = print(index) & "\n"
    else:
      bytes = print(datum(bytes, "release signature", 4096,
        ["signature_format", "signer", "key_id", "signature"])) & "\n"
      discard store.verifySignature(coord, "sha256:" & parts[6],
        boundedFile(stage / "index" / parts[6], MaxReleaseIndexBytes), bytes)
    return RegistryReply(status: if immutableFile(target, bytes): 201 else: 200)
  if verb == "POST":
    let coord = coordinate(parts)
    if parts[1] == "publish":
      let fields = datum(boundedFile(bodyPath, limit), "publish commit", 4096,
        ["publish_format", "index_digest"]).mapEntries
      if fields["publish_format"].kind != vkInt or fields["publish_format"].intVal != 1:
        refuse(400, "publish_format must be 1")
      let digest = text(fields["index_digest"], "index_digest")
      requireDigest(digest, "commit index_digest")
      # Replays need no staging after a successful commit; authenticate and
      # preserve the existing immutable mapping, including its yank state.
      let mapping = store.versionPath(coord.name, coord.version)
      if safeFile(mapping, 4096):
        if readVersion(mapping).indexDigest != digest: refuse(409, "package version already names another release")
        let stage = store.stagePath(coord.name, coord.version)
        if dirExists(stage):
          removeDir(stage)
          syncPath(store.root / "staging")
        return RegistryReply(status: 200)
      return RegistryReply(status: store.commit(coord, digest))
    let fields = datum(boundedFile(bodyPath, limit), "yank commit", 4096,
      ["yank_format", "yanked"]).mapEntries
    if fields["yank_format"].kind != vkInt or fields["yank_format"].intVal != 1 or
        fields["yanked"].kind != vkBool: refuse(400, "invalid yank commit")
    let mapping = store.versionPath(coord.name, coord.version)
    var version = readVersion(mapping)
    version.yanked = fields["yanked"].boolVal
    atomicFile(mapping, print(versionValue(version)) & "\n")
    return RegistryReply(status: 200)
  if parts == @["health"]: return RegistryReply(status: 200, body: "ok\n")
  if parts.len == 3 and parts[0..1] == @["v1", "objects"]:
    requireDigest("sha256:" & parts[2], "object digest")
    let file = store.root / "objects" / parts[2]
    if safeFile(file, store.maxObjectBytes): return RegistryReply(status: 200, file: file)
  if parts.len == 4 and parts[0..1] == @["v1", "releases"] and
      parts[3] in ["index", "signature"]:
    requireDigest("sha256:" & parts[2], "release digest")
    let file = store.root / "releases" / parts[2] / parts[3]
    if safeFile(file, MaxReleaseIndexBytes): return RegistryReply(status: 200, file: file)
  if parts.len == 6 and parts[0..1] == @["v1", "owners"] and
      parts[3] == "keys" and parts[5] in ["record", "signature"]:
    validatePackageName(parts[2] & "/probe", "owner")
    requireDigest("sha256:" & parts[4], "owner key ID")
    let address = parts[2] & "/" & parts[4]
    if store.delegations.hasKey(address):
      let record = store.delegations[address]
      return RegistryReply(status: 200,
        body: if parts[5] == "record": record.record else: record.signature)
  if parts.len == 6 and parts[0..1] == @["v1", "packages"] and parts[4] == "versions":
    let name = parts[2] & "/" & parts[3]
    validatePackageName(name, "version listing")
    if parts[5].len > 2 or not parts[5].allCharsInSet({'0'..'9'}): refuse(400, "invalid page")
    let page = parseInt(parts[5])
    let entries = store.versions(name)
    let pages = max(1, (entries.len + MaxRegistryVersionsPerPage - 1) div MaxRegistryVersionsPerPage)
    if page >= pages: refuse(404, "version page is absent")
    var rows: seq[Value]
    for i in page * MaxRegistryVersionsPerPage ..< min(entries.len, (page+1) * MaxRegistryVersionsPerPage):
      rows.add versionValue(entries[i])
    var fields = initPropTable()
    fields["metadata_format"] = newInt(1)
    fields["name"] = newStr(name)
    fields["page"] = newInt(page)
    fields["page_count"] = newInt(pages)
    fields["listing_digest"] = newStr(registryListingDigest(entries))
    fields["releases"] = newList(rows)
    let body = print(newMap(fields)) & "\n"
    if body.len > MaxRegistryVersionPageBytes: refuse(500, "version page exceeds limit")
    return RegistryReply(status: 200, body: body)
  refuse(404, "registry record is absent")
