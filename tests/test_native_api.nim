import gene/ext/logging
import gene/[compiler, native_api, native_managed, printer, types, vm]
# native_managed installs the owned ingress adapter exercised below.
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
var nativeLoggingCaptured {.threadvar.}: seq[string]
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

proc captureNativeLog(line: string) {.gcsafe.} =
  nativeLoggingCaptured.add line

proc releaseNativePointer(address: pointer) {.nimcall.} =
  inc releasedPointers

proc initNativeSample(module: GeneModule): GeneResult {.nimcall.} =
  result = geneModuleDefine(module, "answer", newInt(40))
  if result.status != gsOk:
    return
  result = geneModuleDefineNative(module, "inc", nativeInc)
  if result.status != gsOk:
    return
  result = geneModuleDefineNativeCall(module, "envelope",
                                        nativeModuleEnvelopeEcho, true)
  if result.status == gsOk:
    result.value = module.geneModuleValue

suite "native api — roots and trampoline":
  test "roots retain values until released":
    let root = geneRoot(newStr("kept"))
    check geneRootGet(root).print() == "\"kept\""
    geneRootRelease(root)
    expect GeneError:
      discard geneRootGet(root)

  test "roots escape scope-owned Paths with held messages":
    var scope = newGlobalScope()
    discard run(compileSource("(let p (Path \".Self:head\"))"), scope)
    let stored = scope.lookup("p")
    let root = geneRoot(stored)
    check geneRootGet(root).bits != stored.bits
    check escapeWeakFunctions(geneRootGet(root)).bits == geneRootGet(root).bits
    scope = nil
    GC_fullCollect()
    let called = geneCall(geneRootGet(root),
      GeneCall(args: @[newNode(newSym("payload"))]))
    check called.status == gsOk
    check called.value.print() == "payload"
    geneRootRelease(root)

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

  test "native helpers expose roots and trampoline":
    let scope = newGlobalScope()
    let root = geneRoot(newInt(12))
    check geneRootGet(root).print() == "12"
    geneRootRelease(root)

    let callee = run(compileSource("(fn [x] (* x 2))"), scope)
    let called = geneCall(callee, GeneCall(args: @[newInt(21)],
                                           dispatchScope: scope))
    check called.status == gsOk
    check called.value.print() == "42"

  test "native helpers expose guarded structured logging":
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
    let logger = geneNewLogger("extension/example")
    check geneLogEnabled(logger, llInfo)
    check not geneLogEnabled(logger, llDebug)
    check geneLogEmit(logger, llInfo, "native", "{\"answer\":42}").status == gsOk
    check nativeLoggingCaptured.len == 1
    check "\"answer\":42" in nativeLoggingCaptured[0]
    check geneLogEmit(logger, llInfo, "bad", "[]").status == gsError

  test "native helpers expose C pointer slice and buffer construction":
    releasedPointers = 0
    let scope = newGlobalScope()
    let pointerValue = geneNewCPtr(cast[pointer](0x1234'u), newSym("C/Char"))
    check pointerValue.kind == vkCPtr
    check pointerValue.cPtrMutable
    check not pointerValue.cPtrOwned
    check pointerValue.cPtrTargetType.print() == "C/Char"

    let constPtr = geneNewCConstPtr(cast[pointer](0x2345'u), newSym("C/Char"))
    check constPtr.kind == vkCPtr
    check not constPtr.cPtrMutable
    check not constPtr.cPtrOwned

    let owned = geneNewCOwnedPtr(cast[pointer](0x3456'u),
                                 releaseNativePointer,
                                 newSym("C/Char"))
    check owned.kind == vkCPtr
    check owned.cPtrOwned
    check not owned.cPtrClosed
    let closed = geneCloseCPtr(owned)
    check closed.status == gsOk
    check owned.cPtrClosed
    check releasedPointers == 1
    discard geneCloseCPtr(owned)
    check releasedPointers == 1

    let closeBorrowed = geneCloseCPtr(pointerValue)
    check closeBorrowed.status == gsError
    check closeBorrowed.message.contains("borrowed C pointer")

    let slice = geneNewCSlice(cast[pointer](0x4567'u), 8, newSym("C/Char"))
    check slice.kind == vkCSlice
    check slice.cSliceLen == 8
    check slice.cSliceTargetType.print() == "C/Char"
    check not slice.cSliceIsNull

    let buffer = geneNewBuffer(newSym("C/UInt8"),
                               @[newInt(1), newInt(2)], scope)
    check buffer.status == gsOk
    check buffer.value.kind == vkBuffer
    check buffer.value.bufferElemType.print() == "C/UInt8"
    check geneBufferLen(buffer.value).value.print() == "2"
    check geneBufferGet(buffer.value, 1).value.print() == "2"
    let set = geneBufferSet(buffer.value, 0, newInt(255), scope)
    check set.status == gsOk
    check set.value.print() == "255"
    check geneBufferGet(buffer.value, 0).value.print() == "255"
    let outOfRange = geneBufferGet(buffer.value, 99)
    check outOfRange.status == gsOk
    check outOfRange.value.kind == vkVoid
    check geneNewBuffer(newSym("C/UInt8"), @[newInt(256)], scope).status == gsError
    check geneBufferSet(buffer.value, 0, newInt(256), scope).status == gsError
    check geneBufferLen(newInt(1)).status == gsError

  test "native helpers expose rooted channel and actor sends":
    let scope = newGlobalScope()
    let channel = run(compileSource("($channel ^capacity 1)"), scope)
    let itemRoot = geneRoot(newInt(7))
    let sent = geneChannelTrySend(channel, itemRoot, scope)
    check sent.status == gsOk
    check sent.value == TRUE
    let full = geneChannelTrySend(channel, itemRoot, scope)
    check full.status == gsOk
    check full.value == FALSE
    let received = geneChannelTryRecv(channel, scope)
    check received.status == gsOk
    check received.value.print() == "#(TryRecv/value 7)"
    let empty = geneChannelTryRecv(channel, scope)
    check empty.status == gsOk
    check empty.value.print() == "TryRecv/empty"
    geneRootRelease(itemRoot)

    let typedChannel = run(compileSource("(var ch : (Channel Int) " &
                                         "  ($channel ^capacity 1)) ch"),
                           scope)
    let badRoot = geneRoot(newStr("bad"))
    let rejected = geneChannelTrySend(typedChannel, badRoot, scope)
    check rejected.status == gsError
    check rejected.message.contains("native channel item")
    geneRootRelease(badRoot)

    let actor = run(compileSource(
      "($actor/spawn ^init (fn [] 0) " &
      "  ^handle (fn [ctx state msg] ($actor/continue (+ state msg))))"),
      scope)
    let msgRoot = geneRoot(newInt(5))
    let actorSent = geneActorTrySend(actor, msgRoot, scope)
    check actorSent.status == gsOk
    check actorSent.value == TRUE
    check actor.actorState.print() == "0"
    discard run(compileSource("($sleep 1)"), scope)
    check actor.actorState.print() == "5"
    geneRootRelease(msgRoot)

    let released = geneChannelTrySend(channel, msgRoot, scope)
    check released.status == gsError
    check released.message.contains("native root has been released")

  test "native helpers expose external async task settlement":
    let scope = newGlobalScope()
    let task = geneNewAsyncTask()
    check task.kind == vkTask
    check not task.taskDone
    let valueRoot = geneRoot(newInt(42))
    let completed = geneTaskComplete(task, valueRoot, scope)
    check completed.status == gsOk
    check completed.value == TRUE
    scope.define("completed-task", task)
    check run(compileSource("(await completed-task)"), scope).print() == "42"
    let again = geneTaskComplete(task, valueRoot, scope)
    check again.status == gsOk
    check again.value == FALSE
    geneRootRelease(valueRoot)

    let failedTask = geneNewAsyncTask()
    scope.define("failed-task", failedTask)
    let errorRoot = geneRoot(run(compileSource("(RuntimeError ^message \"detail\")"), scope))
    let failed = geneTaskFail(failedTask, "native async failed", errorRoot,
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
    geneRootRelease(errorRoot)

    let cancelledTask = geneNewAsyncTask()
    scope.define("cancelled-task", cancelledTask)
    let cancelled = geneTaskCancel(cancelledTask, scope)
    check cancelled.status == gsOk
    check cancelled.value == TRUE
    expect GeneCancel:
      discard run(compileSource("(await cancelled-task)"), scope)
    let cancelAgain = geneTaskCancel(cancelledTask, scope)
    check cancelAgain.status == gsOk
    check cancelAgain.value == FALSE

    let invalidCancel = geneTaskCancel(newInt(1), scope)
    check invalidCancel.status == gsError
    check invalidCancel.message.contains("native task cancel expects a Task")

  test "native helpers expose rooted callback handles":
    let scope = newGlobalScope()
    let callee = run(compileSource("(fn [x] (+ x 10))"), scope)
    let callback = geneNewCallback(callee)
    check not geneThreadAttached()
    let unattached = geneCallCallback(callback,
                                      GeneCall(args: @[newInt(32)],
                                               dispatchScope: scope))
    check unattached.status == gsError
    check unattached.message.contains("native thread is not attached")

    let attachment = geneAttachThread()
    check geneThreadAttached()
    let called = geneCallCallback(callback,
                                  GeneCall(args: @[newInt(32)],
                                           dispatchScope: scope))
    check called.status == gsOk
    check called.value.print() == "42"

    discard run(compileSource("(type Bad ^props {^message Str} ^impl [Error]) " &
                              "(impl Error for Bad)"),
                scope)
    let failer = run(compileSource("(fn [] (fail (Bad ^message \"callback\")))"),
                     scope)
    let failingCallback = geneNewCallback(failer)
    let failed = geneCallCallback(failingCallback,
                                  GeneCall(dispatchScope: scope))
    check failed.status == gsError
    check failed.hasErrorValue
    check failed.errorValue.props["message"].strVal == "callback"
    geneReleaseCallback(failingCallback)

    geneReleaseCallback(callback)
    let released = geneCallCallback(callback,
                                    GeneCall(args: @[newInt(1)],
                                             dispatchScope: scope))
    check released.status == gsError
    check released.message.contains("native callback has been released")
    geneReleaseCallback(callback)
    geneDetachThread(attachment)
    check not geneThreadAttached()
    geneDetachThread(attachment)

  test "native module initializer registers exports":
    let module = newGeneModule("sample-native")
    let initialized = initNativeSample(module)
    check initialized.status == gsOk
    check initialized.value.moduleName == "sample-native"

    let scope = geneModuleScope(module)
    check run(compileSource("(+ answer (inc 1))"), scope).print() == "42"
    check run(compileSource("(envelope ^tag \"ok\" 3)"), scope).print() ==
      "[\"envelope\" 1 1 tag \"ok\" 3]"

  test "native helpers can build the wrapper-type pattern":
    # In-repo native helpers can create a wrapper whose payload is
    # unforgeable from Gene without reaching VM constructors directly.
    let module = newGeneModule("wrapper-native")
    let defined = geneDefineWrapperType(module, "Conn", [
      GeneWrapperField(name: "handle", typeExpr: NIL),
      GeneWrapperField(name: "backend", typeExpr: newSym("Str"))])
    check defined.status == gsOk
    let connType = defined.value
    check connType.kind == vkType
    check connType.isNativeWrapperType

    proc release(p: pointer) {.nimcall.} = discard
    let handle = geneNewCOwnedPtr(cast[pointer](0xBEEF), release, NIL)
    let made = geneNewWrapper(connType, {"handle": handle,
                                         "backend": newStr("demo")})
    check made.status == gsOk
    let conn = made.value
    check conn.head.typeName == "Conn"

    # Native code reads its own props back under a nominal check.
    check geneWrapperField(conn, connType, "backend").value.print() == "\"demo\""
    check geneWrapperField(newInt(1), connType, "backend").status == gsError

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
    let module = newGeneModule("wrapper-schema")
    let connType = geneDefineWrapperType(module, "Conn", [
      GeneWrapperField(name: "handle", typeExpr: NIL),
      GeneWrapperField(name: "backend", typeExpr: newSym("Str"))]).value

    let missing = geneNewWrapper(connType, {"handle": newInt(1)})
    check missing.status == gsError
    check "missing required field 'backend'" in missing.message

    let mistyped = geneNewWrapper(connType, {"handle": newInt(1),
                                             "backend": newInt(2)})
    check mistyped.status == gsError

    let undeclared = geneNewWrapper(connType, {"handle": newInt(1),
                                               "backend": newStr("demo"),
                                               "extra": newInt(3)})
    check undeclared.status == gsError
    check "has no field 'extra'" in undeclared.message

  test "wrapperField accepts a Gene-side subtype of the wrapper":
    # A subtype inherits the wrapper rule (design §16.6), so it is a legitimate
    # receiver. A leaf-equality check would accept the parent and reject its own
    # subtype — while still admitting nothing else.
    let module = newGeneModule("wrapper-subtype")
    let connType = geneDefineWrapperType(module, "Conn", [
      GeneWrapperField(name: "backend", typeExpr: newSym("Str"))]).value
    let scope = geneModuleScope(module)
    discard geneModuleDefine(module, "Conn", connType)
    discard run(compileSource("(type Tagged : Conn)"), scope)
    var taggedType: Value
    check scope.lookupOptional("Tagged", taggedType)

    let tagged = geneNewWrapper(taggedType, {"backend": newStr("demo")}).value
    check geneWrapperField(tagged, connType, "backend").value.print() ==
      "\"demo\""
    # …and the relationship does not run the other way.
    let base = geneNewWrapper(connType, {"backend": newStr("demo")}).value
    check geneWrapperField(base, taggedType, "backend").status == gsError

  test "wrapper identity is the Type value, never its name":
    # Two modules may each define a `Conn`. A name-based check would let one
    # module's wrapper carry its pointer into the other's native code, which
    # would then dereference memory it does not own.
    let fields = [GeneWrapperField(name: "handle", typeExpr: NIL)]
    let a = geneDefineWrapperType(newGeneModule("mod-a"), "Conn", fields).value
    let b = geneDefineWrapperType(newGeneModule("mod-b"), "Conn", fields).value
    check a.typeName == b.typeName
    check a.bits != b.bits

    proc release(p: pointer) {.nimcall.} = discard
    let handle = geneNewCOwnedPtr(cast[pointer](0xA), release, NIL)
    let instA = geneNewWrapper(a, {"handle": handle}).value
    check geneWrapperField(instA, a, "handle").status == gsOk
    check geneWrapperField(instA, b, "handle").status == gsError

  test "the wrapper factory refuses a type that is not a native wrapper":
    # An ordinary Gene type stays ordinary data: `newWrapper` must not be the
    # back door that gives it native-owned props no construction path checks.
    let scope = newGlobalScope()
    discard run(compileSource("(type Schemaed ^props {^n Int})"), scope)
    var declared: Value
    check scope.lookupOptional("Schemaed", declared)
    let rejected = geneNewWrapper(declared, {"n": newInt(1)})
    check rejected.status == gsError
    check "native wrapper" in rejected.message

  test "a wrapper ctor validates the declared C/OwnedPtr target":
    # The declared schema is the invariant (§16.6): the handle field checks the
    # exact pointer flavour and target, so a borrowed or wrong-target pointer
    # never reaches the native code that will dereference it.
    let module = newGeneModule("wrapper-typed-handle")
    releasedPointers = 0
    proc openBlob(args: openArray[Value]): Value {.nimcall.} =
      newCOwnedPtr(cast[pointer](0xB10B), releaseNativePointer, newSym("Blob"))
    proc borrowBlob(args: openArray[Value]): Value {.nimcall.} =
      newCPtr(cast[pointer](0xB10B), newSym("Blob"))
    discard geneModuleDefineNative(module, "open_blob", openBlob)
    discard geneModuleDefineNative(module, "borrow_blob", borrowBlob)
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
    let module = newGeneModule("wrapper-unwind")
    releasedPointers = 0
    proc openHandle(args: openArray[Value]): Value {.nimcall.} =
      newCOwnedPtr(cast[pointer](0xC0FFEE), releaseNativePointer, NIL)
    discard geneModuleDefineNative(module, "open_handle", openHandle)
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

  test "native ingress uses the single sized C API table":
    let api = geneApiIngress()
    check api.version == GeneApiVersion
    check api.structSize == uint32(sizeof(GeneApi))
    check (api.featureBits and GeneApiIngressFeature) != 0
    check api.ingressBegin != nil
    check api.ingressEnqueue != nil
    check api.ingressEnd != nil
    check api.retain == nil

  test "ingress copies bounded FIFO payloads and retains first failure":
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

  test "ingress subscription mediates its handler until physical retirement":
    let scope = newGlobalScope()
    let handler = run(compileSource("(fn on_notice [value] value)"), scope)
    let baseline = nativeRootCount()
    expect GeneError:
      discard newGeneIngressSubscription(handler, scope, maxCount = 0)
    check nativeRootCount() == baseline
    let subscription = newGeneIngressSubscription(handler, scope)
    check subscription.id > 0
    when defined(geneRcStats):
      check nativeRootCount() == baseline
    expect GeneError:
      geneIngressReleaseSubscription(subscription)
    geneIngressClose(subscription.context)
    geneIngressConfirmUnregistered(subscription.context)
    geneIngressReleaseSubscription(subscription)
    check subscription.released
    check nativeRootCount() == baseline

  test "managed ingress ownership retires across repeated subscriptions":
    let scope = newGlobalScope()
    let handler = run(compileSource("(fn [payload] nil)"), scope)
    let baselineRoots = nativeRootCount()
    when defined(geneRcStats):
      var warmManaged = -1
    for i in 0 ..< 1000:
      let subscription = newGeneIngressSubscription(handler, scope)
      geneIngressRequestCloseSubscription(subscription)
      geneIngressConfirmUnregistered(subscription.context)
      geneIngressReleaseSubscription(subscription)
      if i in [0, 1, 99, 999]:
        discard run(compileSource("nil"), scope)
        when defined(geneRcStats):
          if i == 0: warmManaged = liveManaged
          else: check liveManaged == warmManaged
    check nativeRootCount() == baselineRoots

  test "nested C ingress entries keep their contexts separate":
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

  test "ingress root poll serializes handler Tasks and retains failures":
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

  test "ingress close cancels one active handler before retirement":
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

  test "ingress overflow cancels an awaiting handler and reentrant close is safe":
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
    check reentrant.terminalStatus == gsOk
    geneIngressConfirmUnregistered(reentrant.context)
    geneIngressReleaseSubscription(reentrant)
    ingressReentrantSubscription = nil

  test "ingress scheduler completion poll dispatches queued notifications":
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

  test "native module registration failures return status values":
    let module = newGeneModule("dupe-native")
    check geneModuleDefine(module, "x", newInt(1)).status == gsOk
    let duplicate = geneModuleDefine(module, "x", newInt(2))
    check duplicate.status == gsError
    check duplicate.message.contains("duplicate binding: x")
