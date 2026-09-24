import std/[os, strutils]
import gene/[package, printer, registry_release, release_crypto, types]

const hexLower = "0123456789abcdef"

proc fromHex(hex: string): string =
  doAssert hex.len mod 2 == 0
  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(hex[i * 2 ..< i * 2 + 2]))

proc toHex(bytes: string): string =
  for ch in bytes:
    result.add hexLower[int(byte(ch) shr 4)]
    result.add hexLower[int(byte(ch) and 15)]

if paramCount() != 3:
  quit("usage: fixture <package-root> <libcrypto> <output-dir>", 2)
let pkg = loadPackageAt(paramStr(1), poRegistrySource)
let crypto = loadReleaseCrypto(paramStr(2))
let registrySeed = fromHex("9d61b19deffd5a60ba844af492ec2cc4" &
                           "4449c5697b326919703bac031cae7f60")
let ownerSeed = fromHex("4ccd089b28ff96da9db6c346ec114e0f" &
                        "5b8a319f35aba624da8cf6ed4fb8a6fb")
let index = buildReleaseIndex(pkg)
let digest = canonicalDigest(index)
let registryKey = crypto.ed25519PublicKey(registrySeed)
let ownerKey = crypto.ed25519PublicKey(ownerSeed)
let record = ownerKeyRecord("acme", ownerKey)
let output = paramStr(3)
createDir(output)
writeFile(output / "digest.txt", digest)
writeFile(output / "tree-digest.txt",
  index.mapEntries["tree_digest"].strVal)
writeFile(output / "registry-key.hex", toHex(registryKey))
writeFile(output / "owner-key.hex", toHex(ownerKey))
writeFile(output / "index.gene", print(index))
writeFile(output / "registry-signature.gene", print(
  releaseSignatureEnvelope("registry", releaseKeyId(registryKey),
    signReleaseIndex(crypto, registrySeed, index))))
writeFile(output / "owner-signature.gene", print(
  releaseSignatureEnvelope("owner", releaseKeyId(ownerKey),
    signReleaseIndex(crypto, ownerSeed, index))))
writeFile(output / "owner-record.gene", print(record))
writeFile(output / "owner-record.sig", ed25519Sign(crypto, registrySeed,
  ownerKeySignaturePayload(record)))
writeFile(output / "owner-key-id.txt", releaseKeyId(ownerKey))
writeFile(output / "listing-digest.txt", registryListingDigest(@[
  RegistryVersion(version: "2.0.0", indexDigest: digest, yanked: true),
  RegistryVersion(version: "1.2.3", indexDigest: digest, yanked: false),
  RegistryVersion(version: "0.9.0", indexDigest: digest, yanked: false)]))
writeFile(output / "single-listing-digest.txt", registryListingDigest(@[
  RegistryVersion(version: "1.2.3", indexDigest: digest, yanked: false)]))
writeFile(output / "yanked-listing-digest.txt", registryListingDigest(@[
  RegistryVersion(version: "1.2.3", indexDigest: digest, yanked: true)]))
var objects = ""
for item in index.mapEntries["files"].listItems:
  let fields = item.mapEntries
  objects.add fields["digest"].strVal & "\t" & fields["path"].strVal & "\n"
writeFile(output / "objects.tsv", objects)
crypto.close()
