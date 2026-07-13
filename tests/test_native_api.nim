import gene/[compiler, logging, native_api, printer, types, vm]
import std/[dynlib, strutils, tables, unittest]

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
var nativeLoggingCaptured {.threadvar.}: seq[string]

proc captureNativeLog(line: string) {.gcsafe.} =
  nativeLoggingCaptured.add line

proc releaseNativePointer(address: pointer) {.nimcall.} =
  inc releasedPointers

proc unloadTestLibrary(address: pointer) {.nimcall.} =
  unloadLib(cast[LibHandle](address))

proc loadableNativeApiLibrary(): string =
  var candidates: seq[string] = @[]
  when defined(macosx):
    candidates = @["/usr/lib/libSystem.B.dylib", "/usr/lib/libSystem.dylib"]
  elif defined(linux):
    candidates = @["libc.so.6", "libm.so.6"]
  elif defined(windows):
    candidates = @["kernel32.dll"]
  for candidate in candidates:
    let handle = loadLib(candidate)
    if handle != nil:
      unloadLib(handle)
      return candidate
  ""

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

  test "roots reject in-progress constructed instances":
    let partial = newNode(newSym("Partial"), constructing = true)
    expect GeneError:
      discard geneRoot(partial)
    partial.finishNodeConstruction()
    let root = geneRoot(partial)
    check geneRootGet(root).print() == "(Partial)"
    geneRootRelease(root)

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
                                   "(impl Callable for Probe " &
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
                              "(impl Error for Boom)"),
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

  test "versioned API table exposes guarded structured logging":
    nativeLoggingCaptured.setLen(0)
    var config = defaultLoggingConfig()
    for _, sink in config.sinks: closeLogSink(sink)
    config.sinks = initTable[string, LogSink]()
    config.sinks["capture"] = newCallbackLogSink(
      "capture", captureNativeLog, lfJsonl)
    config.rootTargets = @["capture"]
    config.rootLevel = llInfo
    installLoggingConfig(config)
    defer: resetLogging()
    let api = geneApi()
    let logger = api.newLogger("extension/example")
    check api.logEnabled(logger, llInfo)
    check not api.logEnabled(logger, llDebug)
    check api.logEmit(logger, llInfo, "native", "{\"answer\":42}").status == gsOk
    check nativeLoggingCaptured.len == 1
    check "\"answer\":42" in nativeLoggingCaptured[0]
    check api.logEmit(logger, llInfo, "bad", "[]").status == gsError

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

  test "versioned API table exposes rooted channel and actor sends":
    let api = geneApi()
    let scope = newGlobalScope()
    let channel = run(compileSource("(channel ^capacity 1)"), scope)
    let itemRoot = api.root(newInt(7))
    let sent = api.channelTrySend(channel, itemRoot, scope)
    check sent.status == gsOk
    check sent.value == TRUE
    let full = api.channelTrySend(channel, itemRoot, scope)
    check full.status == gsOk
    check full.value == FALSE
    let received = api.channelTryRecv(channel, scope)
    check received.status == gsOk
    check received.value.print() == "#(TryRecv/value 7)"
    let empty = api.channelTryRecv(channel, scope)
    check empty.status == gsOk
    check empty.value.print() == "TryRecv/empty"
    api.rootRelease(itemRoot)

    let typedChannel = run(compileSource("(var ch : (Channel Int) " &
                                         "  (channel ^capacity 1)) ch"),
                           scope)
    let badRoot = api.root(newStr("bad"))
    let rejected = api.channelTrySend(typedChannel, badRoot, scope)
    check rejected.status == gsError
    check rejected.message.contains("native channel item")
    api.rootRelease(badRoot)

    let actor = run(compileSource(
      "(actor/spawn ^init (fn [] 0) " &
      "  ^handle (fn [ctx state msg] (actor/continue (+ state msg))))"),
      scope)
    let msgRoot = api.root(newInt(5))
    let actorSent = api.actorTrySend(actor, msgRoot, scope)
    check actorSent.status == gsOk
    check actorSent.value == TRUE
    check actor.actorState.print() == "0"
    discard run(compileSource("(sleep 1)"), scope)
    check actor.actorState.print() == "5"
    api.rootRelease(msgRoot)

    let released = api.channelTrySend(channel, msgRoot, scope)
    check released.status == gsError
    check released.message.contains("native root has been released")

  test "versioned API table exposes external async task settlement":
    let api = geneApi()
    let scope = newGlobalScope()
    let task = api.newAsyncTask()
    check task.kind == vkTask
    check not task.taskDone
    let valueRoot = api.root(newInt(42))
    let completed = api.taskComplete(task, valueRoot, scope)
    check completed.status == gsOk
    check completed.value == TRUE
    scope.define("completed-task", task)
    check run(compileSource("(await completed-task)"), scope).print() == "42"
    let again = api.taskComplete(task, valueRoot, scope)
    check again.status == gsOk
    check again.value == FALSE
    api.rootRelease(valueRoot)

    let failedTask = api.newAsyncTask()
    scope.define("failed-task", failedTask)
    let errorRoot = api.root(newStr("detail"))
    let failed = api.taskFail(failedTask, "native async failed", errorRoot,
                              true, scope)
    check failed.status == gsOk
    check failed.value == TRUE
    try:
      discard run(compileSource("(await failed-task)"), scope)
      check false
    except GeneError as e:
      check e.msg == "native async failed"
      check e.hasErrVal
      check e.errVal.print() == "\"detail\""
    api.rootRelease(errorRoot)

    let cancelledTask = api.newAsyncTask()
    scope.define("cancelled-task", cancelledTask)
    let cancelled = api.taskCancel(cancelledTask, scope)
    check cancelled.status == gsOk
    check cancelled.value == TRUE
    expect GeneCancel:
      discard run(compileSource("(await cancelled-task)"), scope)
    let cancelAgain = api.taskCancel(cancelledTask, scope)
    check cancelAgain.status == gsOk
    check cancelAgain.value == FALSE

    let invalidCancel = api.taskCancel(newInt(1), scope)
    check invalidCancel.status == gsError
    check invalidCancel.message.contains("native task cancel expects a Task")

  test "versioned API table exposes rooted callback handles":
    let api = geneApi()
    let scope = newGlobalScope()
    let callee = run(compileSource("(fn [x] (+ x 10))"), scope)
    let callback = api.newCallback(callee)
    check not api.threadAttached()
    let unattached = api.callCallback(callback,
                                      GeneCall(args: @[newInt(32)],
                                               dispatchScope: scope))
    check unattached.status == gsError
    check unattached.message.contains("native thread is not attached")

    let attachment = api.attachThread()
    check api.threadAttached()
    let called = api.callCallback(callback,
                                  GeneCall(args: @[newInt(32)],
                                           dispatchScope: scope))
    check called.status == gsOk
    check called.value.print() == "42"

    discard run(compileSource("(type Bad ^props {^message Str} ^impl [Error]) " &
                              "(impl Error for Bad)"),
                scope)
    let failer = run(compileSource("(fn [] (fail (Bad ^message \"callback\")))"),
                     scope)
    let failingCallback = api.newCallback(failer)
    let failed = api.callCallback(failingCallback,
                                  GeneCall(dispatchScope: scope))
    check failed.status == gsError
    check failed.hasErrorValue
    check failed.errorValue.props["message"].strVal == "callback"
    api.releaseCallback(failingCallback)

    api.releaseCallback(callback)
    let released = api.callCallback(callback,
                                    GeneCall(args: @[newInt(1)],
                                             dispatchScope: scope))
    check released.status == gsError
    check released.message.contains("native callback has been released")
    api.releaseCallback(callback)
    api.detachThread(attachment)
    check not api.threadAttached()
    api.detachThread(attachment)

  test "native module initializer registers exports through the API table":
    let module = newGeneModule("sample-native")
    let initialized = geneInitModule(initNativeSample, module)
    check initialized.status == gsOk
    check initialized.value.moduleName == "sample-native"

    let scope = geneModuleScope(module)
    check run(compileSource("(+ answer (inc 1))"), scope).print() == "42"
    check run(compileSource("(envelope ^tag \"ok\" 3)"), scope).print() ==
      "[\"envelope\" 1 1 tag \"ok\" 3]"

  test "native module initializer rejects incompatible API versions":
    let module = newGeneModule("versioned-native")
    var incompatible = geneApi()
    incompatible.version = GeneApiVersion + 1
    let initialized = geneInitModule(initNativeSample, module, incompatible)
    check initialized.status == gsError
    check initialized.message.contains("native API version mismatch")

  test "dynamic native module loading requires an open library initializer":
    check geneLoadModule(newInt(1), "bad").status == gsError
    let libName = loadableNativeApiLibrary()
    if libName.len == 0:
      checkpoint("no loadable system library available for dynamic module test")
      check true
    else:
      let handle = loadLib(libName)
      check handle != nil
      let library = newFfiLibrary(cast[pointer](handle), libName,
                                  unloadTestLibrary)
      let missing = geneLoadModule(library, "missing-native",
                                   initSymbol = "gene_missing_module_init_for_test")
      check missing.status == gsError
      check missing.message.contains("native module initializer not found")
      library.closeFfiLibrary()
      let closed = geneLoadModule(library, "closed-native")
      check closed.status == gsError
      check closed.message.contains("library is closed")

  test "native module registration failures return status values":
    let module = newGeneModule("dupe-native")
    check geneModuleDefine(module, "x", newInt(1)).status == gsOk
    let duplicate = geneModuleDefine(module, "x", newInt(2))
    check duplicate.status == gsError
    check duplicate.message.contains("duplicate binding: x")
