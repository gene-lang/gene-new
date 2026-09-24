import std/[os, strutils, tables]
import gene/[hosted_registry, package, registry_https, release_crypto]

proc fromHex(hex: string): string =
  if hex.len mod 2 != 0: quit("invalid registry key", 2)
  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(hex[i * 2 ..< i * 2 + 2]))

if paramCount() != 9:
  quit("usage: probe <online|offline> <app> <cache> <store> <base> <curl> <ca> <crypto> <registry-key-hex>", 2)
let mode = paramStr(1)
let app = paramStr(2)
let cache = paramStr(3)
let store = paramStr(4)
try:
  var manager: PackageManager
  if mode == "online":
    let transport = newRegistryHttpsTransport(paramStr(5), paramStr(6),
                                               paramStr(7))
    let crypto = loadReleaseCrypto(paramStr(8))
    let trust = newReleaseTrust(fromHex(paramStr(9)))
    manager = newPackageManager(store,
      @[newHostedRegistry("test", transport, crypto, trust, cache)],
      defaultRegistry = "test")
    let resolved = manager.resolve(ResolveRequest(startDir: app,
                                                  userStoreRoot: store))
    discard resolved.writeResolutionLock()
    let graph = manager.sync(resolved,
      SyncPolicy(offline: false, locked: true, userStoreRoot: store))
    let root = graph.packagesById[graph.activePackageId]
    let dependency = graph.packageForAlias(root.id, "release")
    stdout.write readFile(dependency.root / "src/index.gene")
    crypto.close()
  elif mode == "offline":
    manager = newPackageManager(store)
    let locked = manager.loadResolutionLock(app)
    let graph = manager.sync(locked,
      SyncPolicy(offline: true, locked: true, userStoreRoot: store))
    let root = graph.packagesById[graph.activePackageId]
    let dependency = graph.packageForAlias(root.id, "release")
    stdout.write readFile(dependency.root / "src/index.gene")
  else:
    quit("invalid probe mode", 2)
except CatchableError as error:
  stderr.writeLine error.msg
  quit(2)
