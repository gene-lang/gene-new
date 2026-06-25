import gene/[compiler, native_api, printer, types, vm]
import std/[strutils, tables, unittest]

proc nativeInc(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 1 or args[0].kind != vkInt:
    raise newException(GeneError, "inc expects one Int")
  newInt(args[0].intVal + 1)

proc nativeModuleEnvelopeEcho(args: openArray[Value],
                              call: ptr NativeCall): Value {.nimcall.} =
  if call == nil:
    raise newException(GeneError, "native envelope missing")
  var items = @[newStr(call[].calleeName), newInt(args.len),
                newInt(call[].namedNames.len)]
  if call[].namedNames.len > 0:
    items.add newSym(call[].namedNames[0])
    items.add call[].namedValues[0]
  if args.len > 0:
    items.add args[0]
  newList(items)

var releasedPointers = 0

proc releaseNativePointer(address: pointer) {.nimcall.} =
  inc releasedPointers

proc initNativeSample(api: ptr GeneApi,
                      module: GeneModule): GeneResult {.nimcall.} =
  result = api[].moduleDefine(module, "answer", newInt(40))
  if result.status != gsOk:
    return
  result = api[].moduleDefineNative(module, "inc", nativeInc)
  if result.status != gsOk:
    return
  result = api[].moduleDefineNativeCall(module, "envelope",
                                        nativeModuleEnvelopeEcho, true)

suite "native api — roots and trampoline":
  test "roots retain values until released":
    let root = geneRoot(newStr("kept"))
    check geneRootGet(root).print() == "\"kept\""
    geneRootRelease(root)
    expect GeneError:
      discard geneRootGet(root)

  test "geneCall invokes Gene callables through the dynamic trampoline":
    let scope = newGlobalScope()
    let callee = run(compileSource("(fn [x] (+ x 1))"), scope)
    let called = geneCall(callee, GeneCall(args: @[newInt(41)],
                                           dispatchScope: scope))
    check called.status == gsOk
    check called.value.print() == "42"

  test "geneCall preserves named arguments and call status":
    let scope = newGlobalScope()
    let callee = run(compileSource("(fn [x ^scale s] (* x s))"), scope)
    let called = geneCall(callee, GeneCall(args: @[newInt(6)],
                                           namedNames: @["scale"],
                                           namedValues: @[newInt(7)],
                                           dispatchScope: scope))
    check called.status == gsOk
    check called.value.print() == "42"

  test "geneCall preserves call-site metadata for Callable values":
    let scope = newGlobalScope()
    let callee = run(compileSource("(type Probe) " &
                                   "(impl Callable Probe " &
                                   "  (message apply [self call] call/site)) " &
                                   "(Probe)"),
                     scope)
    let site = newNode(newSym("native-site"), body = @[newInt(7)])
    let called = geneCall(callee, GeneCall(dispatchScope: scope, site: site))
    check called.status == gsOk
    check called.value.print() == "(native-site 7)"

  test "geneCall reports recoverable errors and panics without exposing exceptions":
    let scope = newGlobalScope()
    discard run(compileSource("(type Boom ^props {^message Str} ^impl [Error]) " &
                              "(impl Error Boom)"),
                scope)
    let failer = run(compileSource("(fn [] (fail (Boom ^message \"bad\")))"),
                     scope)
    let failed = geneCall(failer, GeneCall(dispatchScope: scope))
    check failed.status == gsError
    check failed.hasErrorValue
    check failed.errorValue.kind == vkNode
    check failed.errorValue.props["message"].strVal == "bad"

    let panicker = run(compileSource("(fn [] (panic \"halt\"))"), scope)
    let panicked = geneCall(panicker, GeneCall(dispatchScope: scope))
    check panicked.status == gsPanic
    check panicked.message == "halt"

  test "versioned API table exposes roots and trampoline":
    let api = geneApi()
    let scope = newGlobalScope()
    let root = api.root(newInt(12))
    check api.rootGet(root).print() == "12"
    api.rootRelease(root)

    let callee = run(compileSource("(fn [x] (* x 2))"), scope)
    let called = api.call(callee, GeneCall(args: @[newInt(21)],
                                           dispatchScope: scope))
    check api.version == GeneApiVersion
    check api.featureCount == GeneApiFeatureCount
    check called.status == gsOk
    check called.value.print() == "42"

  test "versioned API table exposes C pointer slice and buffer construction":
    releasedPointers = 0
    let api = geneApi()
    let scope = newGlobalScope()
    let pointerValue = api.newCPtr(cast[pointer](0x1234'u), newSym("C/Char"))
    check pointerValue.kind == vkCPtr
    check pointerValue.cPtrMutable
    check not pointerValue.cPtrOwned
    check pointerValue.cPtrTargetType.print() == "C/Char"

    let constPtr = api.newCConstPtr(cast[pointer](0x2345'u), newSym("C/Char"))
    check constPtr.kind == vkCPtr
    check not constPtr.cPtrMutable
    check not constPtr.cPtrOwned

    let owned = api.newCOwnedPtr(cast[pointer](0x3456'u),
                                 releaseNativePointer,
                                 newSym("C/Char"))
    check owned.kind == vkCPtr
    check owned.cPtrOwned
    check not owned.cPtrClosed
    let closed = api.closeCPtr(owned)
    check closed.status == gsOk
    check owned.cPtrClosed
    check releasedPointers == 1
    discard api.closeCPtr(owned)
    check releasedPointers == 1

    let closeBorrowed = api.closeCPtr(pointerValue)
    check closeBorrowed.status == gsError
    check closeBorrowed.message.contains("borrowed C pointer")

    let slice = api.newCSlice(cast[pointer](0x4567'u), 8, newSym("C/Char"))
    check slice.kind == vkCSlice
    check slice.cSliceLen == 8
    check slice.cSliceTargetType.print() == "C/Char"
    check not slice.cSliceIsNull

    let buffer = api.newBuffer(newSym("C/UInt8"),
                               @[newInt(1), newInt(2)], scope)
    check buffer.status == gsOk
    check buffer.value.kind == vkBuffer
    check buffer.value.bufferElemType.print() == "C/UInt8"
    check api.bufferLen(buffer.value).value.print() == "2"
    check api.bufferGet(buffer.value, 1).value.print() == "2"
    let set = api.bufferSet(buffer.value, 0, newInt(255), scope)
    check set.status == gsOk
    check set.value.print() == "255"
    check api.bufferGet(buffer.value, 0).value.print() == "255"
    let outOfRange = api.bufferGet(buffer.value, 99)
    check outOfRange.status == gsOk
    check outOfRange.value.kind == vkVoid
    check api.newBuffer(newSym("C/UInt8"), @[newInt(256)], scope).status == gsError
    check api.bufferSet(buffer.value, 0, newInt(256), scope).status == gsError
    check api.bufferLen(newInt(1)).status == gsError

    let ffiLoad = api.newFfiLoad()
    check ffiLoad.kind == vkFfiLoad
    check ffiLoad.print() == "(ffi-load)"

  test "native module initializer registers exports through the API table":
    let module = newGeneModule("sample-native")
    let initialized = geneInitModule(initNativeSample, module)
    check initialized.status == gsOk
    check initialized.value.moduleName == "sample-native"

    let scope = geneModuleScope(module)
    check run(compileSource("(+ answer (inc 1))"), scope).print() == "42"
    check run(compileSource("(envelope ^tag \"ok\" 3)"), scope).print() ==
      "[\"envelope\" 1 1 tag \"ok\" 3]"

  test "native module registration failures return status values":
    let module = newGeneModule("dupe-native")
    check geneModuleDefine(module, "x", newInt(1)).status == gsOk
    let duplicate = geneModuleDefine(module, "x", newInt(2))
    check duplicate.status == gsError
    check duplicate.message.contains("duplicate binding: x")
