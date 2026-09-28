import gene/[compiler, native_api, native_managed, types, vm]
import std/[dynlib, os, osproc, strtabs, streams, strutils, unittest]

type
  SetMode = proc(value: uint32) {.cdecl.}
  ReadCalls = proc(): uint32 {.cdecl.}

proc unloadFixture(address: pointer) {.nimcall.} =
  unloadLib(cast[LibHandle](address))

proc buildFixture(noInit = false): string =
  let compiler = findExe("cc")
  if compiler.len == 0:
    return ""
  let root = getTempDir() / "gene-native-managed-v6-fixture"
  createDir(root)
  result = root / (if noInit: "no_init.dylib" else: "managed_v6.dylib")
  when not defined(macosx):
    result = result.replace(".dylib", ".so")
  var args = when defined(macosx): @["-dynamiclib", "-fPIC"]
             else: @["-shared", "-fPIC"]
  args.add @["-std=c11", "-Isrc/gene",
              "tests/fixtures/native_managed_v6_fixture.c"]
  if noInit: args.add "-DGENE_V6_NO_INIT"
  args.add @["-o", result]
  let environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): environment[key] = value
  when defined(macosx):
    let pinned = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if dirExists(pinned): environment["SDKROOT"] = pinned
  let process = startProcess(compiler, getCurrentDir(), args,
                             env = environment,
                             options = {poStdErrToStdOut})
  let diagnostics = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  if code != 0:
    raise newException(ValueError,
      "v6 C fixture failed to compile: " & diagnostics)

initModuleContext(getCurrentDir())
let host = newGlobalScope()
discard run(compileSource("nil"), host)

suite "managed native extension ABI v6":
  test "exact layout and feature negotiation preserve opaque module entry":
    let path = buildFixture()
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      if handle != nil:
        let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
        defer: library.closeFfiLibrary()
        let domain = geneNewManagedDomain(host)
        let environment = geneNewManagedEnvironment(domain, host)
        let libraryRoot = geneManagedRootFromVm(domain, host, library)
        let calls = cast[ReadCalls](symAddr(handle, "gene_test_v6_calls"))
        let setMode = cast[SetMode](symAddr(handle, "gene_test_v6_set_mode"))
        check calls != nil and setMode != nil
        let unavailable = geneManagedLoadModuleV6(domain, libraryRoot,
          environment, "need-core", requiredFeatures = 1'u64)
        check unavailable.status == gsError
        check unavailable.message.contains("required feature bits")
        check calls() == 0
        let loaded = geneManagedLoadModuleV6(domain, libraryRoot,
                                               environment, "v6-fixture")
        check loaded.status == gsOk and loaded.value != nil
        check geneWithNativeBorrow(loaded.value,
          proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b)) == vkModule
        check calls() == 1
        geneManagedRelease(loaded.value)
        setMode(1)
        let rejected = geneManagedLoadModuleV6(domain, libraryRoot,
                                                 environment, "v6-rejected")
        check rejected.status == gsError
        check rejected.message.contains("rejected")
        check calls() == 2
        let before = geneManagedStats(domain).roots
        when defined(geneRcStats):
          let managedBefore = liveManaged
        for i in 0 ..< 100:
          let failed = geneManagedLoadModuleV6(domain, libraryRoot,
                                                 environment, "v6-repeated")
          check failed.status == gsError
          check geneManagedStats(domain).roots == before
        when defined(geneRcStats):
          check liveManaged == managedBefore
        geneManagedRelease(libraryRoot)
        let stale = geneManagedLoadModuleV6(domain, libraryRoot,
                                               environment, "v6-stale")
        check stale.status == gsError
        geneManagedEnvironmentRelease(environment)
        check geneManagedClose(domain)

  test "missing v6 symbol is rejected without calling library code":
    let path = buildFixture(noInit = true)
    if path.len == 0:
      skip()
    else:
      let handle = loadLib(path)
      check handle != nil
      if handle != nil:
        let library = newFfiLibrary(cast[pointer](handle), path, unloadFixture)
        defer: library.closeFfiLibrary()
        let domain = geneNewManagedDomain(host)
        let environment = geneNewManagedEnvironment(domain, host)
        let libraryRoot = geneManagedRootFromVm(domain, host, library)
        let loaded = geneManagedLoadModuleV6(domain, libraryRoot,
                                               environment, "v6-missing")
        check loaded.status == gsError
        check loaded.message.contains("initializer not found")
        geneManagedRelease(libraryRoot)
        geneManagedEnvironmentRelease(environment)
        check geneManagedClose(domain)
