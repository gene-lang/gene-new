import std/[os, strutils]
import gene/[package, registry_https, registry_release, release_crypto]

proc fromHex(hex: string): string =
  if hex.len mod 2 != 0: quit("invalid public key hex", 2)
  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(hex[i * 2 ..< i * 2 + 2]))

if paramCount() notin [6, 8]:
  quit("usage: probe <base> <curl> <ca> <libcrypto> <registry-key-hex> <digest> [tree <staging-parent>]", 2)
try:
  let transport = newRegistryHttpsTransport(paramStr(1), paramStr(2),
                                            paramStr(3))
  let crypto = loadReleaseCrypto(paramStr(4))
  defer: crypto.close()
  let trust = newReleaseTrust(fromHex(paramStr(5)))
  if paramStr(6) == "versions":
    for version in fetchRegistryVersions(transport, "acme/release"):
      stdout.writeLine version.version & ":" & $version.yanked
  else:
    let release = fetchVerifiedRelease(transport, crypto, trust, paramStr(6))
    if paramCount() == 8 and paramStr(7) == "tree":
      stdout.write fetchVerifiedTree(transport, release, paramStr(8))
    else:
      stdout.write release.signerIdentity
except CatchableError as error:
  stderr.writeLine error.msg
  quit(2)
