import gene/[compiler, native_api, native_managed, types, vm]
import std/[dynlib, os, osproc, strtabs, streams, strutils, unittest]

type
  SetMode = proc(value: uint32) {.cdecl.}
  ReadCalls = proc(): uint32 {.cdecl.}
  TryForeign = proc(): cint {.cdecl.}
  TransferMany = proc(count: uint32): cint {.cdecl.}

proc unloadFixture(address: pointer) {.nimcall.} =
  unloadLib(cast[LibHandle](address))

proc buildFixture(noInit = false): string =
  let compiler = findExe("cc")
  if compiler.len == 0:
    return ""
  let root = getTempDir() / "gene-native-managed-abi-fixture"
  createDir(root)
  result = root / (if noInit: "no_init.dylib" else: "managed_abi.dylib")
  when not defined(macosx):
    result = result.replace(".dylib", ".so")
  var args = when defined(macosx): @["-dynamiclib", "-fPIC"]
             else: @["-shared", "-fPIC"]
  args.add @["-std=c11", "-pthread", "-Isrc/gene",
              "tests/fixtures/native_managed_abi_fixture.c"]
  when defined(geneNativeAsan):
    args.add "-fsanitize=address"
  when defined(geneNativeTsan):
    args.add "-fsanitize=thread"
  if noInit: args.add "-DGENE_NO_INIT"
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
      "abi C fixture failed to compile: " & diagnostics)

initModuleContext(getCurrentDir())
let host = newGlobalScope()
discard run(compileSource("nil"), host)
host.define("abi_plus_one", run(compileSource("(fn [x] (+ x 1))"), host))
host.define("abi_fail", run(compileSource(
  "(fn [] (fail (AssertionError ^message \"abi\")))"), host))
host.define("abi_frozen_list", newList(@[newInt(3), newStr("item")],
  immutable = true, deepFrozen = true))
var frozenMapEntries = initPropTable()
frozenMapEntries["map_key"] = newInt(4)
host.define("abi_frozen_map", newMap(frozenMapEntries,
  immutable = true, deepFrozen = true))
var frozenNodeProps = initPropTable()
frozenNodeProps["node_key"] = newInt(5)
host.define("abi_frozen_node", newNode(newSym("Box"), frozenNodeProps,
  @[newInt(6)], immutable = true, deepFrozen = true))
host.define("abi_mutable_list", newList(@[newInt(7)]))

suite "managed native extension ABI":
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
        let calls = cast[ReadCalls](symAddr(handle, "gene_test_api_calls"))
        let setMode = cast[SetMode](symAddr(handle, "gene_test_api_set_mode"))
        check calls != nil and setMode != nil
        when defined(gcAtomicArc) and compileOption("threads"):
          const unavailableFeature = 1024'u64
          const availableFeatures = 1023'u64
        else:
          const unavailableFeature = 1024'u64
          const availableFeatures = 1007'u64
        let unavailable = geneManagedLoadModule(domain, libraryRoot,
          environment, "need-future", requiredFeatures = unavailableFeature)
        check unavailable.status == gsError
        check unavailable.message.contains("required feature bits")
        check calls() == 0
        let loaded = geneManagedLoadModule(domain, libraryRoot,
                                               environment, "abi-fixture",
                                               requiredFeatures = availableFeatures)
        check loaded.status == gsOk and loaded.value != nil
        check geneWithNativeBorrow(loaded.value,
          proc(b: GeneNativeBorrow): ValueKind = geneManagedKind(b)) == vkModule
        check calls() == 1
        when defined(gcAtomicArc) and compileOption("threads"):
          let beginReader = cast[TryForeign](symAddr(handle,
            "gene_test_api_begin_key_reader"))
          let endReader = cast[TryForeign](symAddr(handle,
            "gene_test_api_end_key_reader"))
          let foreign = cast[TryForeign](symAddr(handle,
            "gene_test_api_try_foreign"))
          let limits = cast[TryForeign](symAddr(handle,
            "gene_test_api_attachment_limits"))
          check beginReader != nil and endReader != nil and
                foreign != nil and limits != nil
          let reading = beginReader()
          check reading == 0
          if reading in [0, 2]:
            for i in 0 ..< 10000:
              discard newSym("abi_race_key_" & $i)
            check endReader() == 0
          check foreign() == 0
          when defined(useMalloc):
            let transferMany = cast[TransferMany](symAddr(handle,
              "gene_test_api_transfer_many"))
            check transferMany != nil and transferMany(2048) == 0
          check limits() == 0
          check geneManagedStats(domain).attachments == 0
        geneManagedRelease(loaded.value)
        setMode(1)
        let rejected = geneManagedLoadModule(domain, libraryRoot,
                                                 environment, "abi-rejected")
        check rejected.status == gsError
        check rejected.message.contains("rejected")
        check calls() == 2
        let before = geneManagedStats(domain).roots
        when defined(geneRcStats):
          let managedBefore = liveManaged
        for i in 0 ..< 100:
          let failed = geneManagedLoadModule(domain, libraryRoot,
                                                 environment, "abi-repeated")
          check failed.status == gsError
          check geneManagedStats(domain).roots == before
        when defined(geneRcStats):
          check liveManaged == managedBefore
        geneManagedRelease(libraryRoot)
        let stale = geneManagedLoadModule(domain, libraryRoot,
                                               environment, "abi-stale")
        check stale.status == gsError
        geneManagedEnvironmentRelease(environment)
        check geneManagedClose(domain)

  test "missing initializer is rejected without calling library code":
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
        let loaded = geneManagedLoadModule(domain, libraryRoot,
                                               environment, "abi-missing")
        check loaded.status == gsError
        check loaded.message.contains("initializer not found")
        geneManagedRelease(libraryRoot)
        geneManagedEnvironmentRelease(environment)
        check geneManagedClose(domain)

  test "attached C lane retires after close despite wrong-lane detach":
    when defined(gcAtomicArc) and compileOption("threads"):
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
          let loaded = geneManagedLoadModule(domain, libraryRoot,
                                                environment, "abi-held")
          check loaded.status == gsOk and loaded.value != nil
          let beginHold = cast[TryForeign](symAddr(handle,
            "gene_test_api_begin_hold"))
          let wrongDetach = cast[TryForeign](symAddr(handle,
            "gene_test_api_wrong_lane_detach"))
          let endHold = cast[TryForeign](symAddr(handle,
            "gene_test_api_end_hold"))
          check beginHold != nil and wrongDetach != nil and endHold != nil
          let began = beginHold()
          check began == 0
          if began == 0:
            check geneManagedStats(domain).attachments == 1
            check wrongDetach() == 0
            check geneManagedStats(domain).attachments == 1
            geneManagedRelease(loaded.value)
            geneManagedRelease(libraryRoot)
            geneManagedEnvironmentRelease(environment)
            check not geneManagedClose(domain)
            check endHold() == 0
            check geneManagedStats(domain).attachments == 0
            check geneManagedStats(domain).roots == 0
            check geneManagedClose(domain)
          elif began == 3:
            discard endHold()
    else:
      skip()
