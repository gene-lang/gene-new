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
var v5InitCalls = 0
var ingressCalls = 0
var ingressPayloads: seq[string]
var ingressFirstTask = NIL
var ingressReentrantSubscription: GeneIngressSubscription
var ingressReentrantTask = NIL

proc recordedIngress(args: openArray[Value]): Value {.nimcall.} =
  inc ingressCalls
  ingressPayloads.add args[0].bytesVal
  if ingressCalls == 1:
    ingressFirstTask = nativeNewAsyncTask()
    return ingressFirstTask
  NIL

proc failingIngress(args: openArray[Value]): Value {.nimcall.} =
  raise newException(GeneError, "native ingress handler failed")

proc panickingIngress(args: openArray[Value]): Value {.nimcall.} =
  raise newException(GenePanic, "native ingress handler panicked")

proc cancellingIngress(args: openArray[Value]): Value {.nimcall.} =
  raise newException(GeneCancel, "native ingress handler cancelled")

proc reentrantClosingIngress(args: openArray[Value]): Value {.nimcall.} =
  geneIngressRequestCloseSubscription(ingressReentrantSubscription)
  ingressReentrantTask = nativeNewAsyncTask()
  ingressReentrantTask

proc initV5Probe(api: ptr GeneApiV5, module: pointer): cint {.cdecl.} =
  inc v5InitCalls
  if module == nil or api.version != GeneApiV5Version or
      api.structSize != uint32(sizeof(GeneApiV5)) or
      api.ingressEnqueue == nil:
    return 7
  0

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
    let errorRoot = api.root(run(compileSource("(RuntimeError ^message \"detail\")"), scope))
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
      check e.errVal.head.typeName == "RuntimeError"
      check e.errVal.props["message"].strVal == "detail"
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
      "(try (conn .set_prop `handle \"junk\") catch Error $err/message)"),
      scope).print() ==
      "\"cannot set field 'handle' on Conn: native wrapper fields are " &
      "initializer-only\""
    check run(compileSource(
      "(try (Conn ^handle \"junk\" ^backend \"x\") catch Error $err/message)"),
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
    discard run(compileSource("(type Tagged : Conn)"), scope)
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
    let releasedAfterOwned = releasedPointers
    check releasedAfterOwned == 1 # abandoned successful owner now auto-retires
    # A borrowed pointer fails the declared field type, and the ctor's own
    # owned handle count is untouched because it never installed one.
    check "field 'handle' for Blob" in run(compileSource(
      "(try (new Blob ^borrowed true) catch TypeError $err/where)"),
      scope).print()
    check releasedPointers == releasedAfterOwned

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
      "  (ctor [] (self .push_body (open_handle))))"), scope)
    let failed = run(compileSource(
      "(try (new Conn) catch Error $err/message)"), scope)
    check "left required field 'label' unset" in failed.print()
    check releasedPointers == 1

    releasedPointers = 0
    let failedBody = run(compileSource(
      "(try (new Bag) catch Error $err/message)"), scope)
    check "left required field 'label' unset" in failedBody.print()
    check releasedPointers == 1

  test "native module initializer rejects incompatible API versions":
    let module = newGeneModule("versioned-native")
    var incompatible = geneApi()
    incompatible.version = GeneApiVersion + 1
    let initialized = geneInitModule(initNativeSample, module, incompatible)
    check initialized.status == gsError
    check initialized.message.contains("native API version mismatch")

  test "v5 uses a separate sized table and exact initializer path":
    let module = newGeneModule("v5-probe")
    var api = geneApiV5()
    check api.version == 5
    check api.structSize == uint32(sizeof(GeneApiV5))
    check (api.featureBits and GeneApiV5IngressFeature) != 0
    let before = v5InitCalls
    api.structSize = api.structSize - 1
    let short = geneInitModuleV5(initV5Probe, module, api)
    check short.status == gsError
    check short.message.contains("layout or feature mismatch")
    check v5InitCalls == before
    api = geneApiV5()
    api.featureBits = 0
    check geneInitModuleV5(initV5Probe, module, api).status == gsError
    check v5InitCalls == before
    check geneInitModuleV5(initV5Probe, module).status == gsOk
    check v5InitCalls == before + 1
    check geneLoadModuleVersioned(newInt(1), "bad", 6).status == gsError
    check geneLoadModuleVersioned(newInt(1), "bad", 6).message.contains(
      "unsupported native module ABI version")

  test "v5 ingress copies bounded FIFO payloads and retains first failure":
    let context = newGeneIngressContext(17, maxCount = 2,
      maxBytes = 4, maxPayload = 3)
    check geneIngressBegin(context, 16) == 0
    check geneIngressBegin(context, 17) == 1
    var first = "ab"
    var second = "cd"
    var extra = "z"
    check geneIngressEnqueue(context, addr first[0], csize_t(first.len)) ==
      GeneIngressAccepted
    first[0] = 'X' # the queued notification owns its copy
    check geneIngressEnqueue(context, addr second[0], csize_t(second.len)) ==
      GeneIngressAccepted
    check geneIngressEnqueue(context, addr extra[0], 1) ==
      GeneIngressOverflow
    geneIngressEnd(context)
    var snapshot = geneIngressStats(context)
    check snapshot.queuedCount == 2
    check snapshot.queuedBytes == 4
    check snapshot.received == 2
    check snapshot.rejected == 1
    check snapshot.firstFailure == GeneIngressOverflow
    check snapshot.wakePending
    var payload = ""
    check geneIngressPop(context, payload)
    check payload == "ab"
    check geneIngressPop(context, payload)
    check payload == "cd"
    check not geneIngressPop(context, payload)
    geneIngressFailNextAllocation(context)
    check geneIngressBegin(context, 17) == 1
    check geneIngressEnqueue(context, addr extra[0], 1) ==
      GeneIngressAllocationFailed
    geneIngressEnd(context)
    snapshot = geneIngressStats(context)
    check snapshot.firstFailure == GeneIngressOverflow
    check snapshot.delivered == 2
    check snapshot.queuedBytes == 0
    check not geneIngressCanRetire(context)
    geneIngressClose(context)
    check geneIngressBegin(context, 17) == 0
    geneIngressConfirmUnregistered(context)
    check geneIngressCanRetire(context)
    geneIngressDestroy(context)

  test "v5 subscription roots its handler until physical retirement":
    let scope = newGlobalScope()
    let handler = run(compileSource("(fn on_notice [value] value)"), scope)
    let baseline = nativeRootCount()
    expect GeneError:
      discard newGeneIngressSubscription(handler, scope, maxCount = 0)
    check nativeRootCount() == baseline
    let subscription = newGeneIngressSubscription(handler, scope)
    check subscription.id > 0
    check geneIngressHandler(subscription).bits == handler.bits
    when defined(geneRcStats):
      check nativeRootCount() == baseline + 1
    expect GeneError:
      geneIngressReleaseSubscription(subscription)
    geneIngressClose(subscription.context)
    geneIngressConfirmUnregistered(subscription.context)
    geneIngressReleaseSubscription(subscription)
    check subscription.released
    check nativeRootCount() == baseline

  test "v5 ingress nested C entries keep their contexts separate":
    let outer = newGeneIngressContext(101)
    let inner = newGeneIngressContext(102)
    var data = "x"
    check geneIngressBegin(outer, 101) == 1
    check geneIngressBegin(inner, 102) == 1
    check geneIngressEnqueue(outer, addr data[0], 1) ==
      GeneIngressEntryMissing
    check geneIngressEnqueue(inner, addr data[0], 1) ==
      GeneIngressAccepted
    geneIngressEnd(inner)
    check geneIngressEnqueue(outer, addr data[0], 1) ==
      GeneIngressAccepted
    geneIngressEnd(outer)
    for context in [inner, outer]:
      geneIngressClose(context)
      geneIngressConfirmUnregistered(context)
      check geneIngressCanRetire(context)
      geneIngressDestroy(context)

  test "v5 root poll serializes handler Tasks and retains failures":
    let scope = newGlobalScope()
    ingressCalls = 0
    ingressPayloads.setLen(0)
    ingressFirstTask = NIL
    let subscription = newGeneIngressSubscription(
      newNativeFn("recorded_ingress", recordedIngress), scope)
    var one = "one"
    var two = "two"
    check geneIngressBegin(subscription.context, subscription.id) == 1
    check geneIngressEnqueue(subscription.context, addr one[0], 3) == 0
    check geneIngressEnqueue(subscription.context, addr two[0], 3) == 0
    geneIngressEnd(subscription.context)
    check geneIngressPollSubscription(subscription) == 1
    check ingressCalls == 1
    check subscription.handled == 0
    check geneIngressSubscriptionStatus(subscription).state == "active"
    check geneIngressStats(subscription.context).queuedCount == 1
    check geneIngressPollSubscription(subscription) == 0
    check ingressCalls == 1
    discard nativeTaskComplete(ingressFirstTask, NIL, scope)
    check geneIngressPollSubscription(subscription) == 1
    check ingressCalls == 2
    check ingressPayloads == @["one", "two"]
    check subscription.handled == 2
    geneIngressRequestCloseSubscription(subscription)
    geneIngressConfirmUnregistered(subscription.context)
    check geneIngressSubscriptionStatus(subscription).state == "closing"
    geneIngressReleaseSubscription(subscription)
    check geneIngressSubscriptionStatus(subscription).state == "closed"

    let failed = newGeneIngressSubscription(
      newNativeFn("failing_ingress", failingIngress), scope)
    let failedWait = geneIngressWaitClosed(failed, scope)
    check geneIngressBegin(failed.context, failed.id) == 1
    check geneIngressEnqueue(failed.context, addr one[0], 3) == 0
    check geneIngressEnqueue(failed.context, addr two[0], 3) == 0
    geneIngressEnd(failed.context)
    check geneIngressPollSubscription(failed) == 1
    check failed.terminalStatus == gsError
    check failed.terminalMessage.contains("handler failed")
    check geneIngressStats(failed.context).discarded == 1
    geneIngressConfirmUnregistered(failed.context)
    geneIngressReleaseSubscription(failed)
    check failedWait.taskDone and failedWait.taskHasError

    for (handler, expected) in [
        (newNativeFn("panicking_ingress", panickingIngress), gsPanic),
        (newNativeFn("cancelling_ingress", cancellingIngress), gsCancelled)]:
      let typed = newGeneIngressSubscription(handler, scope)
      let waiting = geneIngressWaitClosed(typed, scope)
      check geneIngressBegin(typed.context, typed.id) == 1
      check geneIngressEnqueue(typed.context, addr one[0], 3) == 0
      geneIngressEnd(typed.context)
      check geneIngressPollSubscription(typed) == 1
      check typed.terminalStatus == expected
      geneIngressConfirmUnregistered(typed.context)
      geneIngressReleaseSubscription(typed)
      check waiting.taskDone
      let repeat = geneIngressWaitClosed(typed, scope)
      check repeat.taskDone and repeat.bits != waiting.bits
      if expected == gsPanic:
        check waiting.taskHasPanic and repeat.taskHasPanic
      else:
        check waiting.taskCancelled and repeat.taskCancelled

  test "v5 close cancels one active handler before retirement":
    let scope = newGlobalScope()
    ingressCalls = 0
    ingressFirstTask = NIL
    let subscription = newGeneIngressSubscription(
      newNativeFn("recorded_ingress", recordedIngress), scope)
    var byte = "c"
    check geneIngressBegin(subscription.context, subscription.id) == 1
    check geneIngressEnqueue(subscription.context, addr byte[0], 1) == 0
    geneIngressEnd(subscription.context)
    check geneIngressPollSubscription(subscription) == 1
    check not geneIngressCanRetire(subscription.context)
    geneIngressRequestCloseSubscription(subscription)
    check ingressFirstTask.taskCancelled
    discard geneIngressPollSubscription(subscription)
    check subscription.terminalStatus == gsOk
    geneIngressConfirmUnregistered(subscription.context)
    geneIngressReleaseSubscription(subscription)

    ingressCalls = 0
    ingressFirstTask = NIL
    let failedLate = newGeneIngressSubscription(
      newNativeFn("recorded_ingress", recordedIngress), scope)
    check geneIngressBegin(failedLate.context, failedLate.id) == 1
    check geneIngressEnqueue(failedLate.context, addr byte[0], 1) == 0
    geneIngressEnd(failedLate.context)
    check geneIngressPollSubscription(failedLate) == 1
    discard nativeTaskFail(ingressFirstTask, "late handler error", scope = scope)
    geneIngressClose(failedLate.context)
    geneIngressConfirmUnregistered(failedLate.context)
    geneIngressReleaseSubscription(failedLate)
    check failedLate.terminalStatus == gsError
    check failedLate.terminalMessage.contains("late handler error")

  test "v5 overflow cancels an awaiting handler and reentrant close is safe":
    let scope = newGlobalScope()
    ingressCalls = 0
    ingressFirstTask = NIL
    let overflowed = newGeneIngressSubscription(
      newNativeFn("recorded_ingress", recordedIngress), scope,
      maxCount = 1, maxBytes = 2, maxPayload = 1)
    var byte = "x"
    check geneIngressBegin(overflowed.context, overflowed.id) == 1
    check geneIngressEnqueue(overflowed.context, addr byte[0], 1) == 0
    geneIngressEnd(overflowed.context)
    check geneIngressPollSubscription(overflowed) == 1
    check geneIngressBegin(overflowed.context, overflowed.id) == 1
    check geneIngressEnqueue(overflowed.context, addr byte[0], 1) == 0
    check geneIngressEnqueue(overflowed.context, addr byte[0], 1) ==
      GeneIngressOverflow
    geneIngressEnd(overflowed.context)
    discard geneIngressPollSubscription(overflowed)
    check ingressFirstTask.taskCancelled
    check overflowed.terminalStatus == gsError
    check geneIngressStats(overflowed.context).discarded == 1
    geneIngressConfirmUnregistered(overflowed.context)
    geneIngressReleaseSubscription(overflowed)

    ingressReentrantTask = NIL
    let reentrant = newGeneIngressSubscription(
      newNativeFn("reentrant_close", reentrantClosingIngress), scope)
    ingressReentrantSubscription = reentrant
    check geneIngressBegin(reentrant.context, reentrant.id) == 1
    check geneIngressEnqueue(reentrant.context, addr byte[0], 1) == 0
    geneIngressEnd(reentrant.context)
    check geneIngressPollSubscription(reentrant) == 1
    check reentrant.closeRequested
    check ingressReentrantTask.taskCancelled
    geneIngressConfirmUnregistered(reentrant.context)
    geneIngressReleaseSubscription(reentrant)
    ingressReentrantSubscription = nil

  test "v5 scheduler completion poll dispatches queued notifications":
    let scope = newGlobalScope()
    ingressCalls = 1 # recordedIngress returns nil on the next call
    ingressPayloads.setLen(0)
    let subscription = newGeneIngressSubscription(
      newNativeFn("recorded_ingress", recordedIngress), scope)
    var byte = "z"
    check geneIngressBegin(subscription.context, subscription.id) == 1
    check geneIngressEnqueue(subscription.context, addr byte[0], 1) == 0
    geneIngressEnd(subscription.context)
    discard run(compileSource("($sleep 5)"), scope)
    check ingressPayloads == @["z"]
    check subscription.handled == 1
    geneIngressRequestCloseSubscription(subscription)
    geneIngressConfirmUnregistered(subscription.context)
    geneIngressReleaseSubscription(subscription)

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
