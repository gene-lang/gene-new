import std/[os, osproc, strutils, tables, unittest]
import gene/[package, printer, release_crypto, types]

proc fromHex(hex: string): string =
  doAssert hex.len mod 2 == 0
  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(hex[i * 2 ..< i * 2 + 2]))

proc releaseRoot(): string =
  result = getTempDir() / "gene_release_index_test"
  if dirExists(result):
    removeDir(result)
  createDir(result / "src")
  writeFile(result / "package.gene", """
{^format 1 ^name "acme/release" ^version "1.2.3"
 ^library {^entry "src/index.gene"}
 ^files {^include ["package.gene" "src/**"]}}
""")
  writeFile(result / "src/index.gene", "(let answer 42)\n")

proc asInvalid(body: proc ()) : bool =
  try:
    body()
  except PackageError:
    return true
  false

proc withField(value: Value, name: string, replacement: Value): Value =
  var fields = value.mapEntries
  fields[name] = replacement
  newMap(fields)

proc withFilePath(index: Value, number: int, path: string): Value =
  var files = index.mapEntries["files"].listItems
  files[number] = withField(files[number], "path", newStr(path))
  withField(index, "files", newList(files))

let pkgConfig = execCmdEx("pkg-config --variable=libdir openssl")
let library = if pkgConfig.exitCode == 0:
  pkgConfig.output.strip() /
    (when defined(macosx): "libcrypto.3.dylib" else: "libcrypto.so.3")
  else: ""

suite "PKG-3 release index and signatures":
  test "signed canonical metadata binds every selected source byte":
    let root = releaseRoot()
    defer: removeDir(root)
    let pkg = loadPackageAt(root, poRegistrySource)
    let index = buildReleaseIndex(pkg)
    let wire = print(index)
    let parsed = readReleaseIndex(wire)
    check canonicalDigest(index) == canonicalDigest(parsed)
    check parsed.mapEntries["files"].listItems.len == 2
    check parsed.mapEntries["tree_digest"].strVal == sourceTreeDigest(pkg)
    verifyReleaseTree(parsed, root)
    writeFile(root / "src/unlisted.txt", "unlisted")
    check asInvalid(proc () = verifyReleaseTree(parsed, root))
    removeFile(root / "src/unlisted.txt")
    if fileExists(library):
      let crypto = loadReleaseCrypto(library)
      defer: crypto.close()
      let seed = fromHex("9d61b19deffd5a60ba844af492ec2cc4" &
                         "4449c5697b326919703bac031cae7f60")
      let publicKey = crypto.ed25519PublicKey(seed)
      let signature = crypto.signReleaseIndex(seed, parsed)
      check crypto.verifyReleaseSignature(publicKey, signature, index)
      check not crypto.ed25519Verify(publicKey, canonicalGeneData(index),
                                     signature)
      let altered = withField(readReleaseIndex(wire), "version",
                              newStr("1.2.4"))
      check not crypto.verifyReleaseSignature(publicKey, signature, altered)
      check asInvalid(proc () = verifyReleaseTree(altered, root))
    writeFile(root / "src/index.gene", "(let answer 43)\n")
    check asInvalid(proc () = verifyReleaseTree(parsed, root))

  test "index reader rejects hostile paths, duplicates, limits, and extra data":
    let root = releaseRoot()
    defer: removeDir(root)
    let pkg = loadPackageAt(root, poRegistrySource)
    let index = buildReleaseIndex(pkg)
    let indexText = print(index)
    check asInvalid(proc () =
      discard readReleaseIndex(indexText & " nil"))
    check asInvalid(proc () =
      discard readReleaseIndex(repeat("x", MaxReleaseIndexBytes + 1)))
    let traversal = withFilePath(readReleaseIndex(indexText), 0, "../escape")
    check asInvalid(proc () = validateReleaseIndex(traversal))
    let unsorted = withFilePath(readReleaseIndex(indexText), 1, "aaa")
    check asInvalid(proc () = validateReleaseIndex(unsorted))
    let collision = withFilePath(readReleaseIndex(indexText), 1,
                                 "PACKAGE.GENE")
    check asInvalid(proc () = validateReleaseIndex(collision))
    let unknown = withField(readReleaseIndex(indexText), "unexpected",
                            newBool(true))
    check asInvalid(proc () = validateReleaseIndex(unknown))

  test "owner delegation follows only the configured trust path":
    if not fileExists(library):
      skip()
    else:
      let root = releaseRoot()
      defer: removeDir(root)
      let index = buildReleaseIndex(loadPackageAt(root, poRegistrySource))
      let crypto = loadReleaseCrypto(library)
      defer: crypto.close()
      let registrySeed = fromHex("9d61b19deffd5a60ba844af492ec2cc4" &
                                  "4449c5697b326919703bac031cae7f60")
      let ownerSeed = fromHex("4ccd089b28ff96da9db6c346ec114e0f" &
                               "5b8a319f35aba624da8cf6ed4fb8a6fb")
      let registryKey = crypto.ed25519PublicKey(registrySeed)
      let ownerKey = crypto.ed25519PublicKey(ownerSeed)
      let trust = newReleaseTrust(registryKey)
      let record = readOwnerKeyRecord(print(ownerKeyRecord("acme", ownerKey)))
      let delegation = crypto.ed25519Sign(registrySeed,
                                           ownerKeySignaturePayload(record))
      let ownerSignature = crypto.signReleaseIndex(ownerSeed, index)
      let registrySignature = crypto.signReleaseIndex(registrySeed, index)
      check verifyTrustedRelease(trust, crypto, index, registrySignature,
        "registry") == "registry:" & releaseKeyId(registryKey)
      check verifyTrustedRelease(trust, crypto, index, ownerSignature,
        "owner", record, delegation) ==
        "owner:acme:" & releaseKeyId(ownerKey)
      check asInvalid(proc () =
        discard verifyTrustedRelease(trust, crypto, index, ownerSignature,
          "owner", record, registrySignature))
      check asInvalid(proc () =
        discard verifyTrustedRelease(trust, crypto, index, ownerSignature,
          "owner"))
      let alienTrust = newReleaseTrust(ownerKey)
      check asInvalid(proc () =
        discard verifyTrustedRelease(alienTrust, crypto, index,
          ownerSignature, "owner", record, delegation))
      let wrongOwner = ownerKeyRecord("other", ownerKey)
      let wrongDelegation = crypto.ed25519Sign(registrySeed,
        ownerKeySignaturePayload(wrongOwner))
      check asInvalid(proc () =
        discard verifyTrustedRelease(trust, crypto, index, ownerSignature,
          "owner", wrongOwner, wrongDelegation))
      var pins = initTable[string, string]()
      pins["acme"] = ownerKey
      let pinned = newReleaseTrust(registryKey, pins)
      check verifyTrustedRelease(pinned, crypto, index, ownerSignature,
        "owner") == "owner:acme:" & releaseKeyId(ownerKey)
      let rotatedSeed = fromHex("c5aa8df43f9f837bedb7442f31dcb7b1" &
                                 "66d38535076f094b85ce3a2e0b4458f7")
      let rotatedKey = crypto.ed25519PublicKey(rotatedSeed)
      let rotatedRecord = ownerKeyRecord("acme", rotatedKey)
      let rotatedDelegation = crypto.ed25519Sign(registrySeed,
        ownerKeySignaturePayload(rotatedRecord))
      let rotatedSignature = crypto.signReleaseIndex(rotatedSeed, index)
      check verifyTrustedRelease(trust, crypto, index, rotatedSignature,
        "owner", rotatedRecord, rotatedDelegation) ==
          "owner:acme:" & releaseKeyId(rotatedKey)
      check asInvalid(proc () =
        discard verifyTrustedRelease(pinned, crypto, index,
          rotatedSignature, "owner", rotatedRecord, rotatedDelegation))
      let badRecord = withField(record, "public_key", newStr("invalid"))
      check asInvalid(proc () =
        discard readOwnerKeyRecord(print(badRecord)))

  test "v1 publication refuses source symlinks":
    when defined(posix):
      let root = releaseRoot()
      defer: removeDir(root)
      createSymlink("index.gene", root / "src/link.gene")
      let pkg = loadPackageAt(root, poRegistrySource)
      check asInvalid(proc () = discard buildReleaseIndex(pkg))
