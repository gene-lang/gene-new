import gene/ext/logging
import gene/[compiler, native_api, printer, types, vm]
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
    let channel = run(compileSource("($channel ^capacity 1)"), scope)
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
                                         "  ($channel ^capacity 1)) ch"),
                           scope)
    let badRoot = api.root(newStr("bad"))
    let rejected = api.channelTrySend(typedChannel, badRoot, scope)
    check rejected.status == gsError
    check rejected.message.contains("native channel item")
    api.rootRelease(badRoot)

    let actor = run(compileSource(
      "($actor/spawn ^init (fn [] 0) " &
      "  ^handle (fn [ctx state msg] ($actor/continue (+ state msg))))"),
      scope)
    let msgRoot = api.root(newInt(5))
    let actorSent = api.actorTrySend(actor, msgRoot, scope)
    check actorSent.status == gsOk
    check actorSent.value == TRUE
    check actor.actorState.print() == "0"
    discard run(compileSource("($sleep 1)"), scope)
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

  test "an extension can build the wrapper-type pattern through the API table":
    # The whole point of the entry point: an out-of-tree module can create a
    # native type whose payload is unforgeable from Gene, using only the
    # advertised interface — no internal newType/newNode.
    let api = geneApi()
    let module = newGeneModule("wrapper-native")
    let defined = api.defineWrapperType(module, "Conn", [
      GeneWrapperField(name: "handle", typeExpr: NIL),
      GeneWrapperField(name: "backend", typeExpr: newSym("Str"))])
    check defined.status == gsOk
    let connType = defined.value
    check connType.kind == vkType
    check connType.isNativeWrapperType

    proc release(p: pointer) {.nimcall.} = discard
    let handle = api.newCOwnedPtr(cast[pointer](0xBEEF), release, NIL)
    let made = api.newWrapper(connType, {"handle": handle,
                                         "backend": newStr("demo")})
    check made.status == gsOk
    let conn = made.value
    check conn.head.typeName == "Conn"

    # Native code reads its own props back under a nominal check.
    check api.wrapperField(conn, connType, "backend").value.print() == "\"demo\""
    check api.wrapperField(newInt(1), connType, "backend").status == gsError

    # Gene sees a first-class typed value: selectors read the wrapper's props,
    # dispatch works, and the payload can neither be forged nor overwritten —
    # now because the Type is marked, not because its schema is empty.
    let scope = geneModuleScope(module)
    discard geneModuleDefine(module, "conn", conn)
    check run(compileSource("conn/backend"), scope).print() == "\"demo\""
    check run(compileSource("($head conn)"), scope).print() == "(type Conn)"
    check run(compileSource(
      "(try (conn ~ set_prop `handle \"junk\") catch (Error ^message m) m)"),
      scope).print() ==
      "\"cannot set field 'handle' on Conn: native wrapper fields are " &
      "initializer-only\""
    check run(compileSource(
      "(try (Conn ^handle \"junk\" ^backend \"x\") catch (Error ^message m) m)"),
      scope).print() ==
      "\"direct construction cannot construct Conn: it is a native wrapper; " &
      "construct it with (new Conn ...)\""

  test "the wrapper factory validates the declared schema":
    # `newWrapper` is the low-level route for extensions that do not express
    # construction in Gene, so it must reach the same instance a ctor would:
    # every declared field present and boundary-checked, nothing undeclared.
    let api = geneApi()
    let module = newGeneModule("wrapper-schema")
    let connType = api.defineWrapperType(module, "Conn", [
      GeneWrapperField(name: "handle", typeExpr: NIL),
      GeneWrapperField(name: "backend", typeExpr: newSym("Str"))]).value

    let missing = api.newWrapper(connType, {"handle": newInt(1)})
    check missing.status == gsError
    check "missing required field 'backend'" in missing.message

    let mistyped = api.newWrapper(connType, {"handle": newInt(1),
                                             "backend": newInt(2)})
    check mistyped.status == gsError

    let undeclared = api.newWrapper(connType, {"handle": newInt(1),
                                               "backend": newStr("demo"),
                                               "extra": newInt(3)})
    check undeclared.status == gsError
    check "has no field 'extra'" in undeclared.message

  test "wrapperField accepts a Gene-side subtype of the wrapper":
    # A subtype inherits the wrapper rule (design §16.6), so it is a legitimate
    # receiver. A leaf-equality check would accept the parent and reject its own
    # subtype — while still admitting nothing else.
    let api = geneApi()
    let module = newGeneModule("wrapper-subtype")
    let connType = api.defineWrapperType(module, "Conn", [
      GeneWrapperField(name: "backend", typeExpr: newSym("Str"))]).value
    let scope = geneModuleScope(module)
    discard geneModuleDefine(module, "Conn", connType)
    discard run(compileSource("(type Tagged ^is Conn)"), scope)
    var taggedType: Value
    check scope.lookupOptional("Tagged", taggedType)

    let tagged = api.newWrapper(taggedType, {"backend": newStr("demo")}).value
    check api.wrapperField(tagged, connType, "backend").value.print() ==
      "\"demo\""
    # …and the relationship does not run the other way.
    let base = api.newWrapper(connType, {"backend": newStr("demo")}).value
    check api.wrapperField(base, taggedType, "backend").status == gsError

  test "wrapper identity is the Type value, never its name":
    # Two modules may each define a `Conn`. A name-based check would let one
    # module's wrapper carry its pointer into the other's native code, which
    # would then dereference memory it does not own.
    let api = geneApi()
    let fields = [GeneWrapperField(name: "handle", typeExpr: NIL)]
    let a = api.defineWrapperType(newGeneModule("mod-a"), "Conn", fields).value
    let b = api.defineWrapperType(newGeneModule("mod-b"), "Conn", fields).value
    check a.typeName == b.typeName
    check a.bits != b.bits

    proc release(p: pointer) {.nimcall.} = discard
    let handle = api.newCOwnedPtr(cast[pointer](0xA), release, NIL)
    let instA = api.newWrapper(a, {"handle": handle}).value
    check api.wrapperField(instA, a, "handle").status == gsOk
    check api.wrapperField(instA, b, "handle").status == gsError

  test "the wrapper factory refuses a type that is not a native wrapper":
    # An ordinary Gene type stays ordinary data: `newWrapper` must not be the
    # back door that gives it native-owned props no construction path checks.
    let api = geneApi()
    let scope = newGlobalScope()
    discard run(compileSource("(type Schemaed ^props {^n Int})"), scope)
    var declared: Value
    check scope.lookupOptional("Schemaed", declared)
    let rejected = api.newWrapper(declared, {"n": newInt(1)})
    check rejected.status == gsError
    check "native wrapper" in rejected.message

  test "a wrapper ctor validates the declared C/OwnedPtr target":
    # The declared schema is the invariant (§16.6): the handle field checks the
    # exact pointer flavour and target, so a borrowed or wrong-target pointer
    # never reaches the native code that will dereference it.
    let api = geneApi()
    let module = newGeneModule("wrapper-typed-handle")
    releasedPointers = 0
    proc openBlob(args: openArray[Value]): Value {.nimcall.} =
      newCOwnedPtr(cast[pointer](0xB10B), releaseNativePointer, newSym("Blob"))
    proc borrowBlob(args: openArray[Value]): Value {.nimcall.} =
      newCPtr(cast[pointer](0xB10B), newSym("Blob"))
    discard api.moduleDefineNative(module, "open_blob", openBlob)
    discard api.moduleDefineNative(module, "borrow_blob", borrowBlob)
    let scope = geneModuleScope(module)
    discard run(compileSource(
      "(type Blob ^repr native_wrapper ^props {^handle (C/OwnedPtr Blob)} " &
      "  (ctor [^borrowed : Bool = false] " &
      "    (set self/handle (if borrowed (borrow_blob) (open_blob)))))"), scope)
    check run(compileSource("($head (new Blob))"), scope).print() ==
      "(type Blob)"
    # A borrowed pointer fails the declared field type, and the ctor's own
    # owned handle count is untouched because it never installed one.
    check "field 'handle' for Blob" in run(compileSource(
      "(try (new Blob ^borrowed true) catch (TypeError ^where w) w)"),
      scope).print()
    check releasedPointers == 0

  test "a failed ctor releases the owned handles it already installed":
    # §16.6: an in-progress instance is never published, so waiting for
    # reclamation to close what the ctor opened would leak a live connection
    # for an unbounded time.
    let api = geneApi()
    let module = newGeneModule("wrapper-unwind")
    releasedPointers = 0
    proc openHandle(args: openArray[Value]): Value {.nimcall.} =
      newCOwnedPtr(cast[pointer](0xC0FFEE), releaseNativePointer, NIL)
    discard api.moduleDefineNative(module, "open_handle", openHandle)
    let scope = geneModuleScope(module)
    # Each ctor installs a handle and then leaves `label` unset, so schema
    # validation — not the body — is what fails. `Bag` covers the declared
    # *body* position: `push_body` is one of the mutations an in-progress
    # instance may perform, so the unwind has to reach body items too.
    discard run(compileSource(
      "(type Conn ^repr native_wrapper ^props {^handle Any ^label Str} " &
      "  (ctor [] (set self/handle (open_handle)))) " &
      "(type Bag ^repr native_wrapper ^body [Any] ^props {^label Str} " &
      "  (ctor [] (self ~ push_body (open_handle))))"), scope)
    let failed = run(compileSource(
      "(try (new Conn) catch (Error ^message m) m)"), scope)
    check "left required field 'label' unset" in failed.print()
    check releasedPointers == 1

    releasedPointers = 0
    let failedBody = run(compileSource(
      "(try (new Bag) catch (Error ^message m) m)"), scope)
    check "left required field 'label' unset" in failedBody.print()
    check releasedPointers == 1

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
