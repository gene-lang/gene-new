import std/[os, tempfiles, unittest]
import gene/[compiler, native_api, printer, types, vm]

{.compile: "fixtures/native_callback_fixture.c".}
type VisitCallback = proc(context: pointer, value: int64): cint {.cdecl, raises: [].}
proc visitC(count: cint, callback: VisitCallback, context: pointer,
             returned: ptr cint): cint {.cdecl, importc: "gene_test_callback_visit".}
when defined(posix):
  proc visitForeign(callback: VisitCallback, context: pointer): cint
      {.cdecl, importc: "gene_test_callback_foreign".}

proc visitEntry(context: pointer, value: int64): cint {.cdecl, raises: [].} =
  result = 1
  let callback {.cursor.} = cast[NativeSyncCallback](context)
  withNativeSyncCallback(callback):
    let keepGoing = invokeNativeSyncCallback(callback, [newInt(value)])
    if keepGoing.boolVal: result = 0

proc visitorContract(): Value =
  newNode(newSym("Callable"), body = @[
    newList(@[newSym("I64")]), newSym("Bool")])

var currentTestCallback {.threadvar.}: NativeSyncCallback
var callbacksReturned {.threadvar.}: cint

proc reenterVisitor(args: openArray[Value]): Value {.nimcall.} =
  var returned: cint
  discard visitC(1, visitEntry, cast[pointer](currentTestCallback), addr returned)
  TRUE

proc closeActiveVisitor(args: openArray[Value]): Value {.nimcall.} =
  finishNativeCallbackCall(currentTestCallback)
  TRUE

proc fixtureVisit(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let callback = newNativeSyncCallback(args[0], call[].dispatchScope, visitorContract())
  let previous = currentTestCallback
  currentTestCallback = callback
  callbacksReturned = 0
  try:
    beginNativeCallbackCall(callback)
    let status = visitC(3, visitEntry, cast[pointer](callback), addr callbacksReturned)
    finishNativeCallbackCall(callback)
    result = newInt(status)
  finally:
    currentTestCallback = previous
    finishNativeCallbackCall(callback)

proc callbackScope(): Scope =
  result = newGlobalScope()
  result.define("visit", newNativeCallFn("test/visit", fixtureVisit))
  result.define("reenter", newNativeFn("test/reenter", reenterVisitor))
  result.define("close_active", newNativeFn("test/close_active", closeActiveVisitor))

proc callbackEval(source: string): string =
  run(compileSource(source), callbackScope()).print()

suite "native synchronous callback boundary":
  test "real C calls reach Gene and false stops the enclosing visitor":
    check callbackEval("""
      (let seen [])
      (let all (visit (fn [value : I64] : Bool (seen .push value) true)))
      (let stopped (visit (fn [value : I64] : Bool (< value 1))))
      [seen all stopped]
    """) == "[[0 1 2] 0 1]"
    check callbacksReturned == 2

  test "callable and result contracts are checked without unwinding C frames":
    expect GeneError:
      discard callbackEval("(visit 7)")
    check callbackEval("""
      (try (visit (fn [value] "wrong")) false catch TypeError true)
    """) == "true"
    check callbacksReturned == 1

  test "typed failures and retained Error witnesses survive the C boundary":
    check callbackEval("""
      (type Failure ^props {^code Int})
      (fn make []
        (impl Error for Failure (message message [] : Str ^errors [] "original"))
        (fn [value] (fail (Failure ^code value))))
      (try (visit (make)) catch Error [$err/code $err_msg])
    """) == "[0 \"original\"]"
    check callbacksReturned == 1

  test "generated failure provenance passes through enclosing empty rows":
    check callbackEval("""
      (fn outer [] ^errors []
        (visit (fn [value] (let wrong : Int "bad") true)))
      (try (outer) false catch TypeError true)
    """) == "true"

  test "callback execution consumes the enclosing invocation budget":
    check callbackEval("""
      (fn work [value]
        (var n 0)
        (while (< n 10000) (set n (+ n 1)))
        true)
      (let bounded ($runtime/bind_call visit [work] ^policy {^max_steps 200}))
      (try (bounded) false catch Error true)
    """) == "true"

  test "panics and cancellation return from C before resuming control propagation":
    expect GenePanic:
      discard callbackEval("(visit (fn [value] ($panic \"stop\")))")
    check callbacksReturned == 1
    let scope = callbackScope()
    let cancelled = nativeNewAsyncTask()
    discard nativeTaskCancel(cancelled, scope)
    scope.define("cancelled", cancelled)
    expect GeneCancel:
      discard run(compileSource("(visit (fn [value] (await cancelled) true))"), scope)
    check callbacksReturned == 1

  test "callback waits fail before pumping scheduled work":
    check callbackEval("""
      (scope
        (let channel ($channel))
        (let seen [])
        (let task (spawn (do (seen .push "ran") (channel .send 1))))
        (let refused (try
          (visit (fn [value] (await task) true)) false catch Error true))
        (let before (seen .size))
        (await task)
        [refused before seen])
    """) == "[true 0 [\"ran\"]]"
    check callbackEval("""
      (let channel ($channel))
      (try (visit (fn [value] (channel .recv) true)) false catch Error true)
    """) == "true"

  test "callbacks from scheduled root-lane tasks use the same boundary":
    check callbackEval("""
      (scope
        (let result (spawn ^lane root (visit (fn [value] true))))
        (await result))
    """) == "0"
    check callbackEval("""
      (scope
        (let channel ($channel))
        (let result (spawn ^lane root
          (visit (fn [value] (channel .recv) true))))
        (try (await result) false catch Error
          ($str/contains? $err_msg "synchronous native callback")))
    """) == "true"
    check callbackEval("""
      (let channel ($channel ^capacity 1)) (channel .send 1)
      (try (visit (fn [value] (channel .send 2) true)) false catch Error true)
    """) == "true"

  test "join, sleep and spawning are rejected inside a callback":
    let scope = callbackScope()
    scope.define("pending", nativeNewAsyncTask())
    check run(compileSource("""
      [(try (visit (fn [value] (pending .join) true)) false
         catch Error ($str/contains? $err_msg "synchronous native callback"))
       (try (visit (fn [value] ($sleep 0) true)) false
         catch Error ($str/contains? $err_msg "synchronous native callback"))
       (try (visit (fn [value] (spawn true) true)) false
         catch Error ($str/contains? $err_msg "synchronous native callback"))]
    """), scope).print() == "[true true true]"

  test "re-entry and closing an executing callback fail safely":
    expect GeneError:
      discard callbackEval("(visit (fn [value] (reenter)))")
    check callbacksReturned == 1
    expect GeneError:
      discard callbackEval("(visit (fn [value] (close_active)))")
    check callbackEval("(visit (fn [value] true))") == "0"

  test "a finished context rejects late calls while its storage is still retained":
    let scope = newGlobalScope()
    let target = run(compileSource("(fn [value] true)"), scope)
    let callback = newNativeSyncCallback(target, scope, visitorContract())
    beginNativeCallbackCall(callback)
    var returned: cint
    check visitC(1, visitEntry, cast[pointer](callback), addr returned) == 0
    finishNativeCallbackCall(callback)
    check visitC(1, visitEntry, cast[pointer](callback), addr returned) == 1
    finishNativeCallbackCall(callback)

  when defined(posix):
    test "foreign-thread entry is refused before Gene allocation or execution":
      let scope = newGlobalScope()
      let target = run(compileSource("(fn [value] ($panic \"must not execute\"))"), scope)
      let callback = newNativeSyncCallback(target, scope, visitorContract())
      beginNativeCallbackCall(callback)
      check visitForeign(visitEntry, cast[pointer](callback)) == 1
      expect GeneError:
        finishNativeCallbackCall(callback)

  test "Nim-facing API transports cancellation explicitly":
    let scope = newGlobalScope()
    let cancelled = nativeNewAsyncTask()
    discard nativeTaskCancel(cancelled, scope)
    scope.define("cancelled", cancelled)
    let callee = run(compileSource("(fn [] (await cancelled))"), scope)
    check geneCall(callee, GeneCall(dispatchScope: scope)).status == gsCancelled
    let second = nativeNewAsyncTask()
    discard nativeTaskCancel(second, scope)
    scope.assign("cancelled", second)
    let callback = geneNewCallback(callee)
    let attachment = geneAttachThread()
    try:
      let outcome = geneCallCallback(callback, GeneCall(dispatchScope: scope))
      if outcome.status != gsCancelled: checkpoint outcome.message
      check outcome.status == gsCancelled
    finally:
      geneReleaseCallback(callback)
      geneDetachThread(attachment)

  test "native borrow pins block close and transfer through aliases":
    let pointerValue = newCOwnedPtr(cast[pointer](1), nil)
    borrowCPtr(pointerValue)
    expect GeneError: closeCPtr(pointerValue)
    expect GeneError: relinquishCPtr(pointerValue)
    releaseCPtrBorrow(pointerValue)
    closeCPtr(pointerValue)
    check pointerValue.cPtrClosed

  test "native roots reject borrowed CallerEnv outside an active VM invocation":
    let scope = newGlobalScope()
    let borrowed = newCallerEnv(scope)
    expect GeneError: discard geneRoot(borrowed)

suite "SQLite synchronous native callbacks":
  test "text rows preserve duplicate columns and copied values after close":
    check callbackEval("""
      (import $db/sqlite [open Db visit_text_rows])
      (let db (open ":memory:")) (let seen [])
      (let count (visit_text_rows db "select 1 as x, 2 as x, NULL as missing"
        (fn [names values] (seen .push [names values]) true)))
      (db .Db:close)
      [count seen]
    """) == "[1 [[[\"x\" \"x\" \"missing\"] [\"1\" \"2\" nil]]]]"

  test "false stops rows normally and callback failures preserve their type":
    check callbackEval("""
      (import $db/sqlite [open Db visit_text_rows])
      (let db (open ":memory:"))
      (try
        (let count (visit_text_rows db "select 1 union all select 2"
          (fn [names values] false)))
        (let failed (try (visit_text_rows db "select 1"
          (fn [names values] (fail (AssertionError ^message "original"))))
          catch AssertionError $err/message))
        [count failed]
      ensure (db .Db:close))
    """) == "[1 \"original\"]"

  test "same-connection re-entry and direct pointer disposal are blocked":
    check callbackEval("""
      (import $db/sqlite [open Db visit_text_rows])
      (let db (open ":memory:"))
      (try
        (let close_failed (try (visit_text_rows db "select 1"
          (fn [names values] (db .Db:close) true)) false catch Error true))
        (let raw_failed (try (visit_text_rows db "select 1"
          (fn [names values] (db/handle .close) true)) false catch Error true))
        (let query_failed (try (visit_text_rows db "select 1"
          (fn [names values] (db .Db:query "select 2") true)) false catch Error true))
        [close_failed raw_failed query_failed (db .Db:closed?)]
      ensure (db .Db:close))
    """) == "[true true true false]"

  test "only one read-only query without parameters is admitted":
    check callbackEval("""
      (import $db/sqlite [open Db visit_text_rows])
      (let db (open ":memory:")) (var called 0)
      (fn row [names values] (set called (+ called 1)) true)
      (try
        [(try (visit_text_rows db "create table t(x)" row) false catch Error true)
         (try (visit_text_rows db "select 1; select 2" row) false catch Error true)
         (try (visit_text_rows db "select ?" row) false catch Error true) called]
      ensure (db .Db:close))
    """) == "[true true true 0]"
