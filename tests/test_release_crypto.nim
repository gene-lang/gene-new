import std/[os, osproc, strutils, unittest]
import ../src/gene/release_crypto

proc fromHex(hex: string): string =
  doAssert hex.len mod 2 == 0
  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(hex[i * 2 ..< i * 2 + 2]))

let pkgConfig = execCmdEx("pkg-config --variable=libdir openssl")
let library = if pkgConfig.exitCode == 0:
  pkgConfig.output.strip() /
    (when defined(macosx): "libcrypto.3.dylib" else: "libcrypto.so.3")
  else: ""

suite "release Ed25519 OpenSSL adapter":
  test "RFC 8032 vectors, rejection, and explicit library path":
    if not fileExists(library):
      skip()
    else:
      let crypto = loadReleaseCrypto(library)
      defer: crypto.close()
      let seed = fromHex("9d61b19deffd5a60ba844af492ec2cc4" &
                         "4449c5697b326919703bac031cae7f60")
      let publicKey = fromHex("d75a980182b10ab7d54bfed3c964073a" &
                              "0ee172f3daa62325af021a68f707511a")
      let signature = fromHex(
        "e5564300c360ac729086e2cc806e828a" &
        "84877f1eb8e5d974d873e06522490155" &
        "5fb8821590a33bacc61e39701cf9b46b" &
        "d25bf5f0595bbe24655141438e7a100b")
      check crypto.ed25519PublicKey(seed) == publicKey
      check crypto.ed25519Sign(seed, "") == signature
      check crypto.ed25519Verify(publicKey, "", signature)
      check not crypto.ed25519Verify(publicKey, "x", signature)
      check not crypto.ed25519Verify(publicKey, "", signature[0 ..< 63])
      let secondSeed = fromHex("4ccd089b28ff96da9db6c346ec114e0f" &
                               "5b8a319f35aba624da8cf6ed4fb8a6fb")
      let secondPublic = fromHex("3d4017c3e843895a92b70aa74d1b7ebc" &
                                "9c982ccf2ec4968cc0cd55f12af4660c")
      let secondSignature = fromHex(
        "92a009a9f0d4cab8720e820b5f642540" &
        "a2b27b5416503f8fb3762223ebdb69da" &
        "085ac1e43e15996e458f3613d0f11d8c" &
        "387b2eaeb4302aeeb00d291612bb0c00")
      check crypto.ed25519PublicKey(secondSeed) == secondPublic
      check crypto.ed25519Sign(secondSeed, fromHex("72")) == secondSignature
      check crypto.ed25519Verify(secondPublic, fromHex("72"), secondSignature)
      check not crypto.ed25519Verify(publicKey, fromHex("72"), secondSignature)
      expect ValueError:
        discard crypto.ed25519Sign("short", "message")
      expect IOError:
        discard loadReleaseCrypto("libcrypto.so.3")
