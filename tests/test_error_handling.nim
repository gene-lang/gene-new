import gene/[compiler, error_analysis, gir, gir_codec, printer, reader, types, vm]
import std/[json, os, strutils, tables, unittest]

const probePrelude = "(type Probe : Error) "
  ## An ordinary Error for snippets that need one. Assertions and type
  ## failures are Faults, which rows and `catch Error` do not see.

proc probeCompile(source: string): Chunk =
  compileSource(probePrelude & source)

proc gradualErrorEval(source: string): Value =
  run(compileSource(probePrelude & source, sourceName = "error_handling_spec.gene"),
      newGlobalScope(newApplication()))

template errorContractCheck(source, expected: string) =
  check gradualErrorEval(source).print() == expected

proc widenInitializerDependency(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope = call.dispatchScope
  let candidate = run(compileSource("(fn [] ^errors [Error] (/ 1 0))"),
                      newGlobalScope(scope.application()))
  scope.assign("helper", candidate)
  NIL

var spoofedNativeCalls = 0

proc spoofedNativePredicate(args: openArray[Value]): Value {.nimcall.} =
  inc spoofedNativeCalls
  raise newException(GeneError, "native body must not run under another model's proof")

suite "errors — gradual runtime contract":
  test "catch names an error type; Any and value types are rejected":
    for (clause, expected) in [
        ("Any", "Any is not an error type; use `catch Error`"),
        ("Str", "Str is not an error type"),
        ("Int", "Int is not an error type"),
        ("(| JsonError Any)", "Any is not an error type"),
        ("(| Str Error)", "Str is not an error type")]:
      var message = ""
      try:
        discard gradualErrorEval("(try (fail (Probe)) catch " & clause & " 1)")
      except GeneError as error:
        message = error.msg
      check expected in message
    errorContractCheck """(try (fail (Probe)) catch Error 7)""", "7"
    errorContractCheck """(try (fail (Probe)) catch (| JsonError Error) 7)""", "7"

  test "a raised error is the original value and answers message":
    errorContractCheck """
      (let original (Probe ^_msg "same"))
      (try (fail original)
        catch Error [(same? original $err) (== original $err)
          $err/.message $err/_msg])
    """, "[true true \"same\" \"same\"]"

  test "Throwable Error and user errors are nominal types":
    errorContractCheck """
      (type InputError : Error ^props {^field Str})
      (type NotFound : Error)
      (let input (InputError ^field "age" ^_msg "age must be positive"))
      (let missing (NotFound))
      [input/field input/_msg input/.message
       missing/.message missing/_msg
       (try (fail (NotFound)) catch InputError "wrong" catch NotFound "typed")
       (try (fail input) catch Error $err/.message)
       (try (fail (Error ^_msg "plain")) catch Error $err/.message)]
    """, "[\"age\" \"age must be positive\" \"age must be positive\" \"\" nil " &
         "\"typed\" \"age must be positive\" \"plain\"]"

  test "fail admits only values of the Error branch":
    errorContractCheck """
      (type JustData ^props {^message Str})
      [(try (fail (JustData ^message "data")) catch TypeFault true)
       (try (fail (Throwable ^_msg "root")) catch TypeFault true)
       (try (fail "text") catch TypeFault true)
       (try (fail nil) catch TypeFault true)]
    """, "[true true true true]"

  test "a caught error reads an undeclared name as nil":
    errorContractCheck """
      (type NotFound : Error ^props {^path Str})
      (try (fail (NotFound ^path "/x")) catch Error [$err/path $err/code $err/_cause])
    """, "[\"/x\" nil nil]"

  test "a message override runs on each read":
    errorContractCheck """
      (var calls 0)
      (type StatusError : Error ^props {^code Int}
        (message message [] : Str ^errors [] ^^override
          (set calls (+ calls 1)) $"status ${self/code}"))
      (try (fail (StatusError ^code 503)) catch Error nil)
      (let before calls)
      (let texts (try (fail (StatusError ^code 404))
        catch Error [$err/.message $err/.message]))
      [before calls texts]
    """, "[0 2 [\"status 404\" \"status 404\"]]"

  test "an override is the error's message and the stored field stays readable":
    errorContractCheck """
      (type Distinct : Error
        (message message [] : Str ^errors [] ^^override "direct"))
      (try (fail (Distinct ^_msg "stored"))
        catch Error [$err/.message $err/_msg])
    """, "[\"direct\" \"stored\"]"

  test "message overrides keep the inherited contract":
    for declaration in [
        "(type Bad : Error (message message [] : Str? ^errors [] ^^override nil))",
        "(type Bad : Error (message message [] : Str ^^override \"x\"))",
        "(type Bad : Error (message message [] : Str ^errors [Error] ^^override \"x\"))",
        "(type Bad : Error ^props {^_msg Str})",
        "(type Bad : Error ^props {^_cause Any})"]:
      expect GeneError: discard gradualErrorEval(declaration)

  test "the Error protocol forms and the message shortcut are gone":
    for source in [
        "(type Old ^props {^message Str}) (impl Error for Old)",
        "(type Old ^props {^message Str} ^impl [Error])",
        "(try (fail (Probe ^_msg \"x\")) catch Error $err_msg)",
        "(try (fail (Probe ^_msg \"x\")) catch Error $err/.Error:message)"]:
      expect GeneError: discard gradualErrorEval(source)

  test "the catch binding is lexical and respects nesting":
    errorContractCheck """
      (let later (try (fail (Probe ^_msg "outer"))
        catch Error
          (let inner (try (fail (Probe ^_msg "inner"))
            catch Error $err/.message))
          (fn [] [inner $err/.message])))
      (later)
    """, "[\"inner\" \"outer\"]"
    for source in ["$err", "$err/.message", "(set $err/.message \"changed\")"]:
      expect GeneError: discard gradualErrorEval(source)

  test "open error rows admit unknown ordinary errors without changing them":
    errorContractCheck """
      (fn open [callback] ^errors [Probe Error] (callback))
      (try (open (fn [] (/ 1 0))) catch RuntimeFault $err/.message)
    """, "\"division by zero\""

  test "row aliases unions Never and redundant subtypes normalize by coverage":
    errorContractCheck """
      (type ParentError : Error)
      (type ChildError : ParentError ^props {})
      (alias Empty Never)
      (alias Both (| ParentError ChildError))
      (alias Open Error)
      (fn closed [] ^errors [Empty Both ParentError]
        (fail (ChildError ^_msg "child")))
      (fn opened [] ^errors [ParentError Open Empty]
        (fail (Probe ^_msg "other")))
      [(try (closed) catch ParentError $err/.message)
       (try (opened) catch Probe $err/.message)]
    """, "[\"child\" \"other\"]"

  test "error rows name Error types only":
    for row in ["[Str]", "[Throwable]", "[(| Int Error)]"]:
      expect GeneError:
        discard gradualErrorEval("(fn f [] ^errors " & row & " nil) (f)")

  test "nested callable signatures compare semantic open error coverage":
    errorContractCheck """
      (type Known : Error)
      (protocol Invoke
        (message invoke [callback : (Callable [] Any ^errors [Known Error])]
          : Any ^errors [Error]))
      (type Receiver ^props {})
      (impl Invoke for Receiver
        (message invoke [callback : (Callable [] Any ^errors [Error Known Known Never])]
          : Any ^errors [Error] (callback)))
      (try ((Receiver) .Invoke:invoke (fn [] (fail (Known ^_msg "known"))))
        catch Known $err/.message)
    """, "\"known\""

  test "a checked row creates one violation and retains the original cause":
    errorContractCheck """
      (fn closed [] ^errors [] (fail (Probe ^_msg "cause")))
      (fn middle [] ^errors [] (closed))
      (fn outer [] ^errors [] (middle))
      (try (outer)
        catch Probe "wrong"
        catch ContractViolation [$err/where $err/_cause/_msg
          $err/_cause/.message])
    """, "[\"closed\" \"cause\" \"cause\"]"

  test "checked callable views create the same single violation":
    errorContractCheck """
      (let guarded : (Callable [] Any ^errors [])
        (fn [] (fail (Probe ^_msg "view cause"))))
      (fn outer [] ^errors [] (guarded))
      (try (outer) catch ContractViolation
        [$err/where $err/_cause/.message])
    """, "[\"Callable contract\" \"view cause\"]"

  test "faults pass error rows, errors are checked, whoever builds them":
    errorContractCheck """
      (fn generated [] ^errors [] (let n : Int "bad"))
      (fn explicit [] ^errors []
        (fail (TypeFault ^_msg "user" ^where "x" ^expected "Int" ^actual "Str")))
      (fn ordinary [] ^errors [] (fail (Probe ^_msg "probe")))
      (var original nil)
      (fn again [] ^errors []
        (try (generated) catch Throwable (set original $err) (fail $err)))
      [(try (generated) catch Error "wrong" catch TypeFault "generated")
       (try (explicit) catch Error "wrong" catch TypeFault $err/.message)
       (try (ordinary) catch ContractViolation $err/_cause/.message)
       (try (again) catch TypeFault (same? original $err))]
    """, "[\"generated\" \"user\" \"probe\" true]"

  test "a cause is a Throwable":
    errorContractCheck """
      (type Outer : Error)
      (let inner (Probe ^_msg "inner"))
      (let outer (Outer ^_msg "outer" ^_cause inner))
      [outer/_cause/.message
       (try (Outer ^_cause 3) catch TypeFault "rejected")]
    """, "[\"inner\" \"rejected\"]"

  test "default-expression failures belong to the callee's row":
    errorContractCheck """
      (fn with_default [x = (fail (Probe ^_msg "default"))] ^errors [] x)
      [(with_default 7)
       (try (with_default) catch ContractViolation
         [$err/where $err/_cause/.message])]
    """, "[7 [\"with_default\" \"default\"]]"

  test "an error formats through its own type wherever it is caught":
    errorContractCheck """
      (fn raise_local []
        (type Local : Error
          (message message [] : Str ^errors [] ^^override "declaring scope"))
        (fail (Local ^_msg "raw")))
      (try (raise_local) catch Error [$err/_msg $err/.message])
    """, "[\"raw\" \"declaring scope\"]"

  test "freezing and thawing an error preserve its type and message":
    errorContractCheck """
      (type Local : Error ^props {^code Int}
        (message message [] : Str ^errors [] ^^override $"local ${self/code}"))
      (fn snapshots []
        (try (fail (Local ^code 7)) catch Error
          [($freeze $err) ($freeze_shallow $err) ($thaw ($freeze $err))]))
      (let errors (snapshots))
      [(try (fail errors/0) catch Error $err/.message)
       (try (fail errors/1) catch Error $err/.message)
       (try (fail errors/2) catch Error $err/.message)]
    """, "[\"local 7\" \"local 7\" \"local 7\"]"

  test "container copies preserve generated failure provenance":
    errorContractCheck """
      (let saved (try (let n : Int "bad") catch TypeFault ($freeze $err)))
      (fn rethrow [error] ^errors [] (fail ($thaw error)))
      (try (rethrow saved) catch TypeFault "generated")
    """, "\"generated\""

  test "an escaped error outlives the scope that declared its type":
    errorContractCheck """
      (fn make []
        (type Local : Error
          (message message [] : Str ^errors [] ^^override self/_msg))
        (var original (Local ^_msg "still alive"))
        (let saved (try (fail original) catch Error $err))
        (set original nil)
        saved)
      (let saved (make))
      (try (fail saved) catch Error $err/.message)
    """, "\"still alive\""

  test "an override returning a non-Str raises a generated TypeFault":
    errorContractCheck """
      (type Broken : Error ^props {^code Int}
        (message message [] : Str ^errors [] ^^override self/_msg))
      (fn recover [] ^errors []
        (try (fail (Broken ^code 1)) catch Error $err/.message))
      (try (recover) catch TypeFault "bad formatter")
    """, "\"bad formatter\""

  test "terminal reporting uses the message with a type-name fallback":
    for bad in [false, true]:
      let scope = newGlobalScope(newApplication())
      let body = if bad: "(/ 1 0)" else: "\"display text\""
      let source = "(var calls 0) (type Custom : Error ^props {^code Int} " &
        "(message message [] : Str ^errors [] ^^override " &
        "(set calls (+ calls 1)) " & body & ")) " &
        "(fail (Custom ^code 7))"
      try:
        discard run(compileSource(source), scope)
        check false
      except GeneError as error:
        let original = error.errVal
        let displayed = errorDiagnosticMessage(error, scope)
        if bad: check displayed == "Custom"
        else: check displayed == "Custom: display text"
        check error.errVal.bits == original.bits
        check scope.lookup("calls").intVal == 1
    let scope = newGlobalScope(newApplication())
    try:
      discard run(compileSource("(type NotFound : Error) (fail (NotFound))"), scope)
      check false
    except GeneError as error:
      check errorDiagnosticMessage(error, scope) == "NotFound"

  test "unwind runs only when the try is left by unwinding":
    errorContractCheck """
      (type E : Error)
      (fn run [body] : Any
        (var log [])
        (try
          (try (body log) catch E (log .push "catch")
            unwind (log .push "unwind") ensure (log .push "ensure"))
          catch Error (log .push $err/.message))
        log)
      (fn returning [log] (try (return 1) unwind (log .push "unwind") ensure (log .push "ensure")))
      (var looped [])
      (for x in [1]
        (try (break) unwind (looped .push "unwind") ensure (looped .push "ensure")))
      [(run (fn [log] (log .push "body")))
       (run (fn [log] (fail (E ^_msg "caught"))))
       (run (fn [log] (fail (Probe ^_msg "escaped"))))
       (do (var log []) (returning log) log)
       looped]
    """, "[[\"body\" \"ensure\"] [\"catch\" \"ensure\"] " &
         "[\"unwind\" \"ensure\" \"escaped\"] [\"ensure\"] [\"ensure\"]]"

  test "unwind runs for a failing catch body and keeps the original on its own failure":
    errorContractCheck """
      (type E : Error)
      (var log [])
      [(try
         (try (fail (E ^_msg "a")) catch E (fail (E ^_msg "from catch"))
           unwind (log .push "unwind"))
         catch Error $err/.message)
       (try
         (try (fail (E ^_msg "orig")) unwind (fail (E ^_msg "cleanup"))
           ensure (log .push "ensure"))
         catch Error $err/.message)
       log]
    """, "[\"from catch\" \"orig\" [\"unwind\" \"ensure\"]]"

  test "unwind runs on cancellation and panic":
    errorContractCheck """
      (var log [])
      (let task (spawn (try ($sleep 1000) unwind (log .push "cancel unwind"))))
      ($sleep 10)
      task/.cancel
      [(task .join) log]
    """, "[TaskOutcome/cancelled [\"cancel unwind\"]]"
    let scope = newGlobalScope(newApplication())
    expect GeneError:
      discard run(compileSource(
        "(var log []) (try (panic \"p\") unwind (log .push \"panic unwind\"))"), scope)
    check scope.lookup("log").print() == "[\"panic unwind\"]"

  test "try clauses must be ordered catch then unwind then ensure":
    for source in ["(try 1 ensure 2 unwind 3)", "(try 1 unwind 2 catch Error 3)",
                   "(try 1 unwind 2 unwind 3)"]:
      expect GeneError: discard gradualErrorEval(source)

  test "a failure escaping a nested frame of a cleanup keeps the original error":
    errorContractCheck """
      (type E : Error)
      (fn bad [] (fail (E ^_msg "call")))
      [(try (try (fail (E ^_msg "orig")) ensure (bad)) catch Error $err/.message)
       (try (try (fail (E ^_msg "orig")) ensure (try (fail (E ^_msg "inner")) ensure nil))
         catch Error $err/.message)
       (try (try 1 ensure (try (fail (E ^_msg "cleanup")) ensure nil))
         catch Error $err/.message)]
    """, "[\"orig\" \"orig\" \"cleanup\"]"

  test "propagation restores the host exception context":
    for source in [
      "(try (let n : Int \"bad\") catch Throwable nil)",
      "(let f : (Callable [] Any ^errors []) (fn [] (fail (Probe)))) " &
        "(try (f) catch ContractViolation nil)",
      "(let stream ([1] => (fn [x] (fail \"invalid\")))) " &
        "(try (stream .next) catch Throwable nil)"
    ]:
      let previous = getCurrentException()
      discard gradualErrorEval(source)
      check getCurrentException() == previous

  test "a native task failure is admitted by its type alone":
    let scope = newGlobalScope(newApplication())
    let error = run(compileSource("""
      (type Local : Error ^props {^code Int}
        (message message [] : Str ^errors [] ^^override $"native ${self/code}"))
      (Local ^code 7)
    """), scope)
    let rejected = nativeNewAsyncTask()
    expect GeneError:
      discard nativeTaskFail(rejected, "native", newStr("not an error"), hasValue = true)
    check not rejected.taskDone
    let task = nativeNewAsyncTask()
    check nativeTaskFail(task, "native", error, hasValue = true)
    check not nativeTaskFail(task, "already settled", NIL, hasValue = true)
    # A separately rooted scope needs nothing from the producer to format it.
    let consumer = newGlobalScope(scope.application())
    consumer.define("task", task)
    check run(compileSource("(try (await task) catch Error $err/.message)"), consumer).strVal == "native 7"

  test "native failures retain generated provenance":
    let producer = newGlobalScope(newApplication())
    let error = run(compileSource("(try (let n : Int \"bad\") catch TypeFault $err)"), producer)
    let task = nativeNewAsyncTask()
    check nativeTaskFail(task, "generated", error, hasValue = true)
    let scope = newGlobalScope(producer.application())
    scope.define("task", task)
    check run(compileSource("""
      (fn consume [] ^errors [] (await task))
      (try (consume) catch TypeFault "generated")
    """), scope).strVal == "generated"

  test "empty native failure messages retain their error and panic states":
    for constructed in [false, true]:
      let scope = newGlobalScope(newApplication())
      let failed = if constructed: newFailedTask("") else: nativeNewAsyncTask()
      if not constructed: check nativeTaskFail(failed, "", scope = scope)
      scope.define("failed", failed)
      let outcome = run(compileSource("(failed .join)"), scope)
      check outcome.head.enumVariantName == "fault"
      check outcome.body[0].head.typeName == "RuntimeFault"
      check outcome.body[0].props["_msg"].strVal == ""
      check not failed.taskPayloadReleased
      check run(compileSource("(try (await failed) catch RuntimeFault true)"), scope).boolVal
      let panicked = if constructed: newPanickedTask("") else: nativeNewAsyncTask()
      if not constructed: check tryPanicTask(panicked, "")
      scope.define("panicked", panicked)
      check run(compileSource("(panicked .join)"), scope).head.enumVariantName == "fault"
      expect GeneError:
        discard run(compileSource("(try (await panicked) catch Error false)"), scope)

  test "join reports a message-only native failure as a fault past deferred rows":
    let task = nativeNewAsyncTask()
    check nativeTaskFail(task, "native failure")
    let scope = newGlobalScope(newApplication())
    scope.define("task", task)
    let outcome = run(compileSource("""
      (let bounded : (Task Any Never) task)
      (bounded .join)
    """), scope)
    check outcome.head.enumVariantName == "fault"
    let error = outcome.body[0]
    check error.head.typeName == "RuntimeFault"
    check error.props["_msg"].strVal == "native failure"

proc strictErrorCompile(source: string): Chunk =
  compileSource("(mod checked ^errors_mode strict)\n" & probePrelude & source,
                 sourceName = "strict_error_spec.gene")

suite "errors — static catch or declare":
  test "runtime local macro calls require an open or caught error row":
    expect GeneError:
      discard strictErrorCompile("(fn f [n] ^errors [] (macro m [] n) (m))")
    discard strictErrorCompile("(fn f [n] ^errors [Error] (macro m [] n) (m))")
    discard strictErrorCompile("(fn f [n] ^errors [] (macro m [] n) " &
      "(try (m) catch Error nil))")

  test "macro block loop exits keep following errors reachable":
    let setup = "(type AfterLoop : Error) " &
      "(macro scoped [body...] `(do (let keep (fn [] 1)) %body...)) "
    for loopBody in ["(scoped (break))", "(try (scoped (break)) ensure nil)"]:
      expect GeneError:
        discard strictErrorCompile(setup & "(fn bad [] ^errors [] " &
          "(while true " & loopBody & ") (fail (AfterLoop ^_msg \"after\")))")
      discard strictErrorCompile(setup & "(fn allowed [] ^errors [AfterLoop] " &
        "(while true " & loopBody & ") (fail (AfterLoop ^_msg \"after\")))")

  test "macro-local callable bindings do not replace caller error contracts":
    let setup = "(type HiddenError : Error) " &
      "(fn risky ^^private [] ^errors [HiddenError] (fail (HiddenError ^_msg \"bad\"))) " &
      "(macro locally [] `(do (let risky (fn [] nil)) nil)) "
    expect GeneError:
      discard strictErrorCompile(setup & "(fn bad [] ^errors [] (locally) (risky))")
    discard strictErrorCompile(setup & "(fn allowed [] ^errors [HiddenError] (locally) (risky))")

  test "macro returns and ensure returns end the caller's error path":
    let setup = "(type UnreachableError : Error) " &
      "(macro scoped [body...] `(do (let keep (fn [] 1)) %body...)) "
    discard strictErrorCompile(setup & "(fn finish [] ^errors [] " &
      "(scoped (return 7)) (fail (UnreachableError ^_msg \"unreachable\")))")
    discard strictErrorCompile(setup & "(fn finish [] ^errors [] " &
      "(while true (try (scoped (break)) ensure (return 7))) " &
      "(fail (UnreachableError ^_msg \"unreachable\")))")

  test "strict public functions require explicit rows while private helpers infer":
    expect GeneError: discard strictErrorCompile("(fn public [] 1)")
    discard strictErrorCompile("(fn helper ^^private [] 1) " &
      "(fn public [] ^errors [] (helper))")

  test "strict checking follows unannotated helper chains":
    let helpers = """
      (type ConfigError : Error)
      (fn decode ^^private [bad : Bool] : Str
        (if bad (fail (ConfigError ^_msg "bad")) "ready"))
      (fn load_config ^^private [bad : Bool] : Str (decode bad))
    """
    try:
      discard strictErrorCompile(helpers & "(fn start [bad : Bool] ^errors [] (load_config bad))")
      check false
    except GeneError as error:
      check "start" in error.msg
      check "ConfigError" in error.msg
      check "load_config" in error.msg
      check "decode" in error.msg
    discard strictErrorCompile(helpers &
      "(fn start [bad : Bool] ^errors [ConfigError] (load_config bad))")
    discard strictErrorCompile(helpers &
      "(fn start [bad : Bool] ^errors [] (try (load_config bad) catch ConfigError \"default\"))")

  test "opaque calls require Error rather than a closed row":
    discard strictErrorCompile("(fn invoke [callback : Callable] ^errors [Error] (callback))")
    discard strictErrorCompile("(fn invoke [callback : Callable] ^errors [] " &
      "(try (callback) catch Error $err/.message))")
    expect GeneError:
      discard strictErrorCompile("(fn invoke [callback : Callable] ^errors [] (callback))")

  test "an unresolved catch or row cannot masquerade as Error":
    expect GeneError:
      discard strictErrorCompile("(fn invoke [callback : Callable] ^errors [] " &
        "(try (callback) catch MissingError nil))")
    expect GeneError:
      discard strictErrorCompile("(fn invoke [callback : Callable] ^errors [MissingError] (callback))")
    discard strictErrorCompile("(alias AllErrors Error) " &
      "(fn invoke [callback : Callable] ^errors [AllErrors] (callback))")

  test "specific catches preserve the open remainder":
    let declarations = "(type Known : Error) "
    expect GeneError:
      discard strictErrorCompile(declarations &
        "(fn invoke [callback : Callable] ^errors [Known] " &
        "(try (callback) catch Known \"handled\"))")
    discard strictErrorCompile(declarations &
      "(fn invoke [callback : Callable] ^errors [Known Error] " &
      "(try (callback) catch Known \"handled\"))")

  test "recovery and cleanup introduce their own errors":
    let helper = "(fn failure ^^private [] (fail (Probe))) "
    for expression in ["(try (failure) catch Error (fail (Probe)))",
                       "(try (failure) catch Error nil ensure (fail (Probe)))"]:
      expect GeneError:
        discard strictErrorCompile(helper & "(fn main [] ^errors [] " & expression & ")")

  test "ranges retain iterable behavior without inheriting eager List messages":
    expect GeneError:
      discard strictErrorCompile("""
        (fn same [n : Int] : Int ^errors [] n)
        (fn invalid [] ^errors [] ($map ($range 0 3) same))
      """)
    check run(strictErrorCompile("""
      (fn plus_one [n : Int] : Int ^errors [] (+ n 1))
      (fn values [] ^errors []
        ($into ($map ($to_stream ($range 0 3)) plus_one) []))
      (values)
    """), newGlobalScope(newApplication())).print() == "[1 2 3]"

  test "recursive inference converges without hiding an error":
    let source = """
      (fn left ^^private [n : Int]
        (if (== n 0) (fail (Probe)) (right (- n 1))))
      (fn right ^^private [n : Int] (left n))
    """
    expect GeneError:
      discard strictErrorCompile(source & "(fn start [] ^errors [] (left 3))")
    discard strictErrorCompile(source & "(fn start [] ^errors [Probe] (left 3))")

  test "defaults contribute to the callee's invocation row":
    expect GeneError:
      discard strictErrorCompile("(fn load [value = (fail (Probe))] ^errors [] value)")
    discard strictErrorCompile("(fn load [value = (fail (Probe))] ^errors [Probe] value)")

  test "generated-only rethrows have no ordinary error obligation":
    discard strictErrorCompile("(fn checked [] ^errors [] " &
      "(try (let x : Int \"bad\") catch TypeFault (let alias $err) (fail alias)))")

  test "ordinary rethrows retain their obligation":
    expect GeneError:
      discard strictErrorCompile("(fn checked [callback : Callable] ^errors [] " &
        "(try (callback) catch Error (fail $err)))")

  test "checked callable parameters supply their enforced row":
    discard strictErrorCompile("(fn invoke [callback : (Callable [] Any ^errors [])] " &
      "^errors [] (callback))")

  test "warning mode reports the same violation without rejecting code":
    let source = probePrelude & "(fn checked [] ^errors [] (fail (Probe)))"
    let warned = compileSource("(mod checked ^errors_mode warn) " & source)
    check warned.compilerDiagnostics.len > 0
    check "Probe" in warned.compilerDiagnostics[0].message
    let dynamic = compileSource("(mod checked ^errors_mode dynamic) " & source)
    check dynamic.compilerDiagnostics.len == 0

  test "module initialization has an empty escaping row":
    expect GeneError: discard strictErrorCompile("(fail (Probe))")
    discard strictErrorCompile("(try (fail (Probe)) catch Error nil)")

  test "a forward call during initialization adds only a fault":
    # The name is unbound when initialization reaches the call, which raises
    # a RuntimeFault: a defect, so no row has to declare it.
    discard strictErrorCompile("(later) (fn later [] ^errors [] 1)")
    discard strictErrorCompile("(fn first ^^private [] (later)) " &
      "(first) (fn later ^^private [] 1)")
    discard strictErrorCompile("(fn first ^^private [] (later/helper)) " &
      "(first) (ns later (fn helper [] ^errors [] 1))")
    let unbound = run(strictErrorCompile("(var seen nil) " &
      "(try (later) catch RuntimeFault (set seen $err/.message)) " &
      "(fn later [] ^errors [] 1) seen"), newGlobalScope(newApplication()))
    check unbound.kind == vkString and "later" in unbound.strVal
    discard strictErrorCompile("(fn first ^^private [] 1) (first)")
    discard strictErrorCompile("(fn first ^^private [] 1) (let result (first))")

  test "public message and constructor contracts are explicit":
    expect GeneError:
      discard strictErrorCompile("(type Example ^props {} (message value [] 1))")
    expect GeneError:
      discard strictErrorCompile("(type Example ^props {} (ctor [] nil))")
    expect GeneError:
      discard strictErrorCompile("(protocol Example (message value [] : Int))")

  test "constructor calls and inherited defaults contribute invocation errors":
    let declarations = """
      (type Parent ^props {}
        (ctor [value = (fail (Probe ^_msg "default"))] ^errors [Probe] nil))
      (type Child : Parent ^props {})
    """
    for typ in ["Parent", "Child"]:
      expect GeneError:
        discard strictErrorCompile(declarations &
          "(fn make [] ^errors [] (new " & typ & "))")
      discard strictErrorCompile(declarations &
        "(fn make [] ^errors [Probe] (new " & typ & "))")
      discard strictErrorCompile(declarations &
        "(fn make [] ^errors [] (try (new " & typ & ") catch Probe nil))")
      # Direct data construction never invokes the custom ctor or its defaults.
      discard strictErrorCompile(declarations & "(fn direct [] ^errors [] (" & typ & "))")

  test "an unannotated protocol default does not bound overriding impl errors":
    let body = """
      (protocol P (message value [] : Int 1))
      (type Receiver ^props {})
      (impl P for Receiver (message value [] : Int (fail (Probe)) 1))
      ((Receiver) .P:value)
    """
    expect GeneError:
      discard strictErrorCompile("(fn work [] ^errors [] " & body & ")")
    discard strictErrorCompile("(fn work [] ^errors [Error] " & body & ")")

  test "a nominal parameter does not fix an unannotated override target":
    let body = """
      (type Parent ^props {} (message value [] : Int 1))
      (type Child : Parent ^props {}
        (message value [] : Int ^^override (fail (Probe)) 1))
      (let receiver : Parent (Child))
      (receiver .value)
    """
    expect GeneError:
      discard strictErrorCompile("(fn work [] ^errors [] " & body & ")")
    discard strictErrorCompile("(fn work [] ^errors [Error] " & body & ")")

  test "inherited direct messages retain declaration-bound Self error rows":
    let source = """
      (type Problem : Error
        (message raise [] : Nil ^errors [Self] (fail self)))
      (type Specific : Problem ^props {})
      (fn propagate [] : Nil ^errors [Problem]
        ((Specific ^_msg "specific") .raise))
      (fn recover [] : Str ^errors []
        (try (propagate) "wrong" catch Problem $err/.message))
    """
    discard strictErrorCompile(source)
    check run(strictErrorCompile(source & "(recover)"),
              newGlobalScope(newApplication())).strVal == "specific"

  test "defects from natives add no obligation, and awaits repeat":
    # Wrong arity and invalid arguments are Faults: strict code does not
    # declare them, and catch Error does not catch them. A second await
    # returns the same value, and a join after it the same outcome.
    discard strictErrorCompile("""
      (fn add [a : Int, b : Int] : Int ^errors [] (+ a b))
      (fn twice [task] : Any ^errors [Error] (await task) (await task))
      (fn sized [items : List] : Int ^errors [] (items .size))
    """)
    check gradualErrorEval("""
      (let task (spawn 1))
      (await task)
      [(await task) (task .join)]
    """).print() == "[1 #(TaskOutcome/ok 1)]"
    check gradualErrorEval("""
      (type Boom : Error)
      (let task (spawn (fail (Boom ^_msg "boom"))))
      (try (await task) catch Boom nil)
      [(try (await task) catch Boom $err/.message) ($head (task .join))]
    """).print() == "[\"boom\" TaskOutcome/error]"

suite "errors — module summaries":
  proc errorModuleRoot(): string =
    result = getCurrentDir() / "tmp" / "error_module_tests"
    createDir(result)

  test "a strict caller infers a dynamic dependency without changing its policy":
    let root = errorModuleRoot()
    writeFile(root / "dep.gene", """
      (type ConfigError : Error)
      (fn decode ^^private [] (fail (ConfigError ^_msg "dependency")))
      (fn load [] (decode))
    """)
    writeFile(root / "good.gene", """
      (mod good ^errors_mode strict)
      (import [load ConfigError] ^from "./dep.gene")
      (fn main [] ^errors [] (try (load) catch ConfigError nil))
    """)
    writeFile(root / "bad.gene", """
      (mod bad ^errors_mode strict)
      (import [load] ^from "./dep.gene")
      (fn main [] ^errors [] (load))
    """)
    let app = newApplication(root)
    discard app.compileFileModule(root / "good.gene")
    expect GeneError: discard app.compileFileModule(root / "bad.gene")
    # A rejected cached artifact must not become runnable on the next request.
    expect GeneError: discard app.compileFileModule(root / "bad.gene")

  test "initialization summaries do not depend on a warm runtime module cache":
    let root = errorModuleRoot()
    writeFile(root / "fallible.gene", """
      (if ($runtime/callable? 1) (fail (Probe)) nil)
      (fn value [] 1)
    """)
    writeFile(root / "initialization.gene", """
      (mod initialization ^errors_mode strict)
      (import [value] ^from "./fallible.gene")
      (fn main [] ^errors [] (value))
    """)
    for warm in [false, true]:
      let app = newApplication(root)
      if warm: discard app.loadFileModule(root / "fallible.gene")
      expect GeneError: discard app.compileFileModule(root / "initialization.gene")

  test "imported types publish constructor invocation contracts":
    let root = errorModuleRoot()
    writeFile(root / "constructors.gene", """
      (type Probe : Error)
      (type Resource ^props {}
        (ctor [ready = (fail (Probe ^_msg "not ready"))]
          ^errors [Probe] nil))
      (type Plain ^props {})
    """)
    writeFile(root / "constructors_good.gene", """
      (mod good ^errors_mode strict)
      (import [Probe Resource Plain] ^from "./constructors.gene")
      (fn make [] ^errors [Probe] (new Resource))
      (fn plain [] ^errors [] (Plain))
    """)
    writeFile(root / "constructors_bad.gene", """
      (mod bad ^errors_mode strict)
      (import [Resource] ^from "./constructors.gene")
      (fn make [] ^errors [] (new Resource))
    """)
    let app = newApplication(root)
    discard app.loadFileModule(root / "constructors_good.gene")
    expect GeneError: discard app.compileFileModule(root / "constructors_bad.gene")

  test "imports preserve direct inherited and protocol message contracts":
    let root = errorModuleRoot()
    writeFile(root / "messages.gene", """
      (type Failure : Error)
      (type Base ^props {}
        (message label [] : Str ^errors [] "base")
        (message copy [] : Self ^errors [] self)
        (message query [value : Str = (fail (Failure ^_msg "default"))]
          : Str ^errors [Failure] value))
      (type Child : Base ^props {})
      (protocol P (message value [] : Str ^errors [Failure]))
      (protocol Left ^inherit [P])
      (protocol Right ^inherit [P])
      (protocol Diamond ^inherit [Left Right])
      (type Box ^props {})
      (impl Diamond for Box
        (message value [] : Str ^errors [Failure]
          (fail (Failure ^_msg "protocol"))))
    """)
    writeFile(root / "messages_good.gene", """
      (mod good ^errors_mode strict)
      (import [Child Box Diamond Failure] ^from "./messages.gene")
      (fn label [] : Str ^errors [] ((Child) .label))
      (fn copy_label [child : Child] : Str ^errors [] ((child .copy) .label))
      (fn query [child : Child] : Str ^errors [Failure] (child .query))
      (fn recover [] : Str ^errors []
        (try ((Box) .Diamond:value) catch Failure $err/.message))
    """)
    writeFile(root / "messages_bad.gene", """
      (mod bad ^errors_mode strict)
      (import [Box Diamond] ^from "./messages.gene")
      (fn unchecked [] : Str ^errors [] ((Box) .Diamond:value))
    """)
    writeFile(root / "messages_default_bad.gene", """
      (mod bad ^errors_mode strict)
      (import [Child] ^from "./messages.gene")
      (fn unchecked [] : Str ^errors [] ((Child) .query "supplied"))
    """)
    let app = newApplication(root)
    let loaded = app.loadFileModule(root / "messages_good.gene")
    let scope = loaded.moduleRootNamespace.nsScope
    check run(compileSource("(label)", useLocalSlots = false), scope).strVal == "base"
    check run(compileSource("(copy_label (Child))", useLocalSlots = false), scope).strVal == "base"
    try:
      check run(compileSource("(recover)", useLocalSlots = false), scope).strVal == "protocol"
    except GeneError as error:
      checkpoint error.errVal.print()
      raise
    expect GeneError: discard app.compileFileModule(root / "messages_bad.gene")
    expect GeneError: discard app.compileFileModule(root / "messages_default_bad.gene")

  test "protocol-typed bare sends cannot assume a qualified protocol body":
    expect GeneError:
      discard strictErrorCompile("""
        (protocol P (message value [] : Int ^errors []))
        (fn use [receiver : P] : Int ^errors [] (receiver .value))
      """)
    discard strictErrorCompile("""
      (protocol P (message value [] : Int ^errors []))
      (fn use [receiver : P] : Int ^errors [] (receiver .P:value))
    """)
    expect GeneError:
      discard strictErrorCompile("""
        (type Receiver ^props {} (message value [] : Int ^errors [] 1))
        (fn use [qualifier receiver : Receiver] : Int ^errors []
          (receiver .qualifier:value))
      """)
    expect GeneError:
      discard strictErrorCompile("""
        (fn outer [] ^errors [] 1)
        (ns empty)
        (fn use [] ^errors [] (empty/outer))
      """)

  test "renamed error imports retain both nominal identity and usable proof names":
    let root = errorModuleRoot()
    writeFile(root / "renamed_provider.gene", """
      (type Original : Error)
      (fn produce [] : Nil ^errors [Original] (fail (Original ^_msg "renamed")))
    """)
    writeFile(root / "renamed_client.gene", """
      (mod renamed ^errors_mode strict)
      (import [Original : Expected produce] ^from "./renamed_provider.gene")
      (fn helper ^^private [] (produce))
      (fn run [] : Str ^errors []
        (try (helper) "wrong" catch Expected $err/.message))
    """)
    let app = newApplication(root)
    let module = app.loadFileModule(root / "renamed_client.gene")
    check run(compileSource("(run)", useLocalSlots = false),
              module.moduleRootNamespace.nsScope).strVal == "renamed"

  test "compiled interfaces round-trip message rows and declaring Self":
    let source = """
      (mod library ^errors_mode strict)
      (type Failure : Error)
      (protocol P (message check [] : Int ^errors [Failure]))
      (type Base ^props {} (message same [] : Self ^errors [] self))
      (type Child : Base ^props {})
      (fn ready [] : Bool ^errors [] (not false))
      (fn factory ^^private [] (fn [] ^errors [] 1))
      (fn client [] ^errors [] ((factory)))
      (fn native_factory [] ^errors [] $assert)
      (fn type_factory [] ^errors [] Child)
      (fn message_factory [] ^errors [] P:check)
    """
    let unit = readAllWithLocs(source, "library.gene")
    let chunk = compileSourceUnit(unit)
    let iface = buildCompileInterface(unit.forms, sourceName = unit.sourceName)
    analyzeErrorEffects(chunk).attachErrorInterfaces(iface)
    let artifact = ExecutableGir(entryIdentity: "test/library",
      modules: @[CompiledModule(identity: "test/library", chunk: chunk,
        compileInterface: iface)])
    let decoded = decodeExecutableGir(encodeExecutableGir(artifact))
    let restored = decoded.modules[0].compileInterface
    check errorInterfaceKey(restored) == errorInterfaceKey(iface)
    check restored.entries["P"].messageErrorsKnown
    check restored.entries["P"].messageErrors["check"].declaredRow.named[0].name == "Failure"
    check restored.entries["Child"].messageErrors["same"].receiverType.identity ==
      restored.entries["Base"].errorType.identity
    var hasNativeDependency = false
    for dependency in restored.entries["ready"].callableErrors.dependencies:
      if dependency.nativeMetadata.identity == "gene/not":
        hasNativeDependency = true
        check dependency.nativeMetadata.version.len > 0
    check hasNativeDependency
    check restored.entries["native_factory"].callableErrors.returnContracts[0].nativeMetadata.identity == "gene/assert"
    check restored.entries["type_factory"].callableErrors.returnContracts[0].typeIdentity ==
      restored.entries["Child"].errorType.identity
    check restored.entries["message_factory"].callableErrors.returnContracts[0].kind == "message"
    check restored.entries["message_factory"].callableErrors.returnContracts[0].messageIdentity.len > 0
    var hasResultDependency = false
    for dependency in restored.entries["client"].callableErrors.dependencies:
      if dependency.returnDepth == 1:
        hasResultDependency = true
        check dependency.returnKind == "callable"
    check hasResultDependency
    var malformed = parseJson(encodeExecutableGir(artifact))
    for fn in malformed["modules"][0]["chunk"]["functions"]:
      if fn["name"].getStr == "client":
        for dependency in fn["errorSummary"]["dependencies"]:
          if dependency["returnDepth"].getInt == 1:
            dependency["returnDepth"] = %(-1)
    expect ValueError: discard decodeExecutableGir($malformed)

  test "protocol closures preserve hidden same-name identities across imports":
    let root = errorModuleRoot()
    writeFile(root / "protocol_names.gene", """
      (protocol Parent (message value [] : Int ^errors []))
      (protocol Own ^inherit [Parent] (message value [] : Int ^errors []))
    """)
    writeFile(root / "protocol_names_good.gene", """
      (mod good ^errors_mode strict)
      (import [Own] ^from "./protocol_names.gene")
      (protocol Child ^inherit [Own])
      (fn read [receiver : Child] : Int ^errors [] (receiver .Own:value))
    """)
    writeFile(root / "protocol_names_bad.gene", """
      (mod bad ^errors_mode strict)
      (import [Own] ^from "./protocol_names.gene")
      (protocol Child ^inherit [Own])
      (fn read [receiver : Child] : Int ^errors [] (receiver .Child:value))
    """)
    let app = newApplication(root)
    discard app.compileFileModule(root / "protocol_names_good.gene")
    expect GeneError: discard app.compileFileModule(root / "protocol_names_bad.gene")

  test "an Error parameter and an exported alias keep the builtin contract":
    discard strictErrorCompile("""
      (type Detailed : Error ^props {^code Int})
      (fn text [error : Error] : Str ^errors [] error/.message)
      (fn detail [error : Detailed] : Str ^errors [] error/.message)
    """)
    let root = errorModuleRoot()
    writeFile(root / "error_alias.gene", "(alias AllErrors Error)")
    writeFile(root / "error_alias_client.gene", """
      (mod aliases ^errors_mode strict)
      (import [AllErrors] ^from "./error_alias.gene")
      (fn invoke [callback : Callable] : Any ^errors [AllErrors] (callback))
    """)
    discard newApplication(root).loadFileModule(root / "error_alias_client.gene")

  test "an exported checked callable publishes its explicit invocation contract":
    let root = errorModuleRoot()
    writeFile(root / "checked_value.gene", """
      (mod values ^errors_mode strict)
      (let exported : (Callable [] Int ^errors []) (fn [] : Int ^errors [] 7))
    """)
    writeFile(root / "checked_value_client.gene", """
      (mod client ^errors_mode strict)
      (import [exported] ^from "./checked_value.gene")
      (fn value [] : Int ^errors [] (exported))
    """)
    let app = newApplication(root)
    let loaded = app.loadFileModule(root / "checked_value_client.gene")
    check run(compileSource("(value)", useLocalSlots = false),
              loaded.moduleRootNamespace.nsScope).intVal == 7
    expect GeneError:
      discard strictErrorCompile("(let exported : Callable (fn [] 1))")

suite "errors — retained strict assumptions":
  test "unannotated factory data is not a retained type assumption":
    for expression in ["(+ (factory) 1)", "($into (factory) [])"]:
      expect GeneError:
        discard strictErrorCompile("""
          (fn factory ^^private [] 1)
          (fn client [] ^errors [] EXPRESSION)
        """.replace("EXPRESSION", expression))
    expect GeneError:
      discard strictErrorCompile("""
        (fn factory ^^private [] [1])
        (fn client [] ^errors [] ($into (factory) []))
      """)
    let app = newApplication()
    let scope = newGlobalScope(app)
    check run(strictErrorCompile("""
      (fn factory ^^private [] : Int 1)
      (fn client [] ^errors [] (+ (factory) 1))
      (client)
    """), scope).intVal == 2
    let replacement = run(compileSource("(fn [] ^errors [] \"changed\")"),
                          newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)

  test "private factories can return known native callables":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^^private [] $assert)
      (fn client [] ^errors []
        (try ((factory) true) catch Probe nil))
    """), scope)
    check run(compileSource("(client)"), scope).kind == vkNil
    let changed = run(strictErrorCompile("(fn [] $parse/parse_int)"), newGlobalScope(app))
    expect GeneError: scope.assign("factory", changed)
    let sameModel = run(strictErrorCompile("(fn [] $assert)"), newGlobalScope(app))
    scope.assign("factory", sameModel)
    check run(compileSource("(client)"), scope).kind == vkNil
    let stdlib = scope.lookup("gene").nsScope
    let parseInt = stdlib.lookup("parse").nsScope.lookup("parse_int")
    expect GeneError: stdlib.assign("assert", parseInt)
    check run(compileSource("(client)"), scope).kind == vkNil

  test "returned constructors retain nominal and source type identities":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (type Item ^props {})
      (type Other ^props {})
      (fn factory ^^private [] Item)
      (fn client [] ^errors [] ((factory)))
    """), scope)
    let instance = run(compileSource("(client)"), scope)
    check instance.head.typeName == "Item"
    expect GeneError: scope.assign("Item", scope.lookup("Other"))
    check run(compileSource("(client)"), scope).head.bits == instance.head.bits
    let changed = run(strictErrorCompile("(type Other ^props {}) (fn [] Other)"), newGlobalScope(app))
    expect GeneError: scope.assign("factory", changed)

  test "generative constructor factories remain usable with retained code contracts":
    let app = newApplication()
    let scope = newGlobalScope(app)
    try:
      check run(strictErrorCompile("""
        (type Base ^props {} (message value [] : Int ^errors [] 7))
        (type Other ^props {})
        (fn factory ^^private [] (type Local : Base ^props {}) Local)
        (fn client [] ^errors [] ((factory)))
        (client)
      """), scope).head.typeName == "Local"
      expect GeneError: scope.assign("Base", scope.lookup("Other"))
    except GeneError as error:
      checkpoint error.errVal.print()
      raise

  test "returned protocol messages retain identity and invocation failures":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (protocol P (message value [] : Int ^errors []))
      (type Item ^props {})
      (impl P for Item (message value [] : Int ^errors [] 7))
      (fn factory ^^private [] P:value)
      (fn client [] ^errors [] ((factory) (Item)))
      (fn saved [] ^errors [] (let held (factory)) (held (Item)))
      (fn sent [] ^errors [] (let held (factory)) ((Item) .%held))
      (fn absent [] ^errors [] ((factory)))
      (fn mismatch [] ^errors [] ((factory) 1))
    """), scope)
    check run(compileSource("(client)"), scope).intVal == 7
    check run(compileSource("[(saved) (sent)]"), scope).print() == "[7 7]"
    check run(compileSource("(try (absent) catch Error false catch RuntimeFault true)"),
              scope).boolVal
    check run(compileSource("(try (mismatch) catch Error false catch MessageFault true)"),
              scope).boolVal
    let replacement = run(strictErrorCompile("""
      (protocol Q (message value [] : Int ^errors []))
      (fn [] Q:value)
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)
    check run(compileSource("(client)"), scope).intVal == 7

  test "bound message dispatch failures are faults outside implementation rows":
    let held = run(strictErrorCompile("""
      (protocol P (message value [] : Int ^errors []))
      (fn invalid [] ^errors [] (let held P:value) (held 1))
      (try (invalid) catch Error "error" catch MessageFault "fault")
    """), newGlobalScope(newApplication()))
    check held.strVal == "fault"

  test "inferred returned callable contracts reject broadening before publication":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^^private [] (fn [] ^errors [] 1))
      (fn client [] ^errors [] ((factory)))
    """), scope)
    let broader = run(compileSource("""
      (fn [] ^errors [] (fn [] ^errors [Probe] (fail (Probe))))
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", broader)
    check run(compileSource("(client)"), scope).intVal == 1
    let checkedBroader = run(strictErrorCompile("""
      (fn [] ^errors [] (fn [] ^errors [Probe] (fail (Probe))))
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", checkedBroader)
    let compatible = run(strictErrorCompile("(fn [] (fn [] ^errors [] 2))"),
                         newGlobalScope(app))
    scope.assign("factory", compatible)
    check run(compileSource("(client)"), scope).intVal == 2

  test "inferred returned contracts retain forwarding helpers and callback sources":
    for body in ["(helper)", "(fn [] (callback))", "callback",
                 "(fn [] (fn local [] (callback)) (local))"]:
      let app = newApplication()
      let scope = newGlobalScope(app)
      discard run(strictErrorCompile("""
        (fn callback ^^private [] 1)
        (fn helper ^^private [] (fn [] ^errors [] 1))
        (fn factory ^^private [] BODY)
        (fn client [] ^errors [] ((factory)))
      """.replace("BODY", body)), scope)
      let widerHelper = run(strictErrorCompile("""
        (fn [] (fn [] ^errors [Probe] (fail (Probe))))
      """), newGlobalScope(app))
      let widerCallback = run(probeCompile("(fn [] ^errors [Probe] (fail (Probe)))"),
                              newGlobalScope(app))
      if body == "(helper)":
        expect GeneError: scope.assign("helper", widerHelper)
      else:
        expect GeneError: scope.assign("callback", widerCallback)
      check run(compileSource("(client)"), scope).intVal == 1

  test "inferred deferred contracts are retained where their results are consumed":
    for kind in ["task", "stream"]:
      let app = newApplication()
      let scope = newGlobalScope(app)
      let initial = if kind == "task": "(spawn 1)" else: "($to_stream [1])"
      let consume = if kind == "task": "(await (factory))" else: "($into (factory) [])"
      discard run(strictErrorCompile("""
        (fn factory ^^private [] INITIAL)
        (fn client [] ^errors [] CONSUME)
      """.replace("INITIAL", initial).replace("CONSUME", consume)), scope)
      let changed = if kind == "task": "(spawn (fail (Probe)))"
                    else: "($map ($to_stream [1]) (fn [x] ^errors [Probe] (fail (Probe))))"
      let replacement = run(strictErrorCompile("(fn [] " & changed & ")"), newGlobalScope(app))
      expect GeneError: scope.assign("factory", replacement)
      check run(compileSource("(client)"), scope).print() == (if kind == "task": "1" else: "[1]")

  test "awaiting a task again adds no obligation, directly or forwarded":
    # Await is idempotent, so the checker keeps no await state: a strict
    # caller that awaits a task twice, or one already awaited, handles only
    # the task's own row.
    for (defs, call, expected) in [
        ("(fn factory ^^private [] (spawn 1)) " &
           "(fn twice [] ^errors [] (let task (factory)) (await task) (await task))",
         "(twice)", "1"),
        ("(fn helper ^^private [] (spawn 1)) (fn factory ^^private [] (helper)) " &
           "(fn twice [] ^errors [] (let task (factory)) " &
           "[(await task) (await task) (task .join)])",
         "(twice)", "[1 1 #(TaskOutcome/ok 1)]"),
        ("(fn client [task : (Task Int Never)] ^errors [] (await task))",
         "(do (var t (spawn 1)) (await t) (client t))", "1")]:
      let scope = newGlobalScope(newApplication())
      discard run(strictErrorCompile(defs), scope)
      check run(compileSource(call, useLocalSlots = false), scope).print() == expected

  test "lazy adapters retain source and callback assumptions until consumption":
    for wrap in ["($map (factory) callback)", "(forward)",
                 "($map ($map (factory) callback) callback)"]:
      let app = newApplication()
      let scope = newGlobalScope(app)
      discard run(strictErrorCompile("""
        (fn factory ^^private [] ($to_stream [1]))
        (fn callback ^^private [value] value)
        (fn forward ^^private [] ($map (factory) callback))
        (fn client [] ^errors [] ($into SOURCE []))
      """.replace("SOURCE", wrap)), scope)
      let broader = run(probeCompile("(fn [value] ^errors [Probe] (fail (Probe)))"),
                        newGlobalScope(app))
      expect GeneError: scope.assign("callback", broader)
      let widerStream = run(strictErrorCompile("""
        (fn [] ($map ($to_stream [1])
          (fn [x] ^errors [Probe] (fail (Probe)))))
      """), newGlobalScope(app))
      expect GeneError: scope.assign("factory", widerStream)
      check run(compileSource("(client)"), scope).print() == "[1]"

  test "lazy creation preserves stream classification without consuming producer errors":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^^private [] ($to_stream [1]))
      (fn callback [value] ^errors [Probe] (fail (Probe)))
      (fn ignore [] ^errors [] ($map ($map (factory) callback) callback) nil)
    """), scope)
    let stream = run(strictErrorCompile("""
      (fn [] ($map ($to_stream [1])
        (fn [x] ^errors [Probe] (fail (Probe)))))
    """), newGlobalScope(app))
    scope.assign("factory", stream)
    check run(compileSource("(ignore)"), scope).kind == vkNil
    let eager = run(strictErrorCompile("(fn [] [1])"), newGlobalScope(app))
    expect GeneError: scope.assign("factory", eager)

  test "a compatible factory replacement protects its new inferred sources":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^^private [] (fn [] ^errors [] 1))
      (fn client [] ^errors [] ((factory)))
    """), scope)
    let replacementScope = newGlobalScope(app)
    let replacement = run(strictErrorCompile("""
      (fn callback ^^private [] 2)
      (fn [] callback)
    """), replacementScope)
    scope.assign("factory", replacement)
    let wider = run(probeCompile("(fn [] ^errors [Probe] (fail (Probe)))"),
                    newGlobalScope(app))
    expect GeneError: replacementScope.assign("callback", wider)
    check run(compileSource("(client)"), scope).intVal == 2
    let unguarded = run(compileSource("""
      (fn callback ^^private [] 3)
      (fn [] callback)
    """, errorsMode = "warn"), newGlobalScope(app))
    expect GeneError: scope.assign("factory", unguarded)

  test "unused factory results do not create returned-callable assumptions":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^^private [] (fn [] ^errors [] 1))
      (fn client [] ^errors [] (factory) 7)
    """), scope)
    let replacement = run(probeCompile("""
      (fn [] ^errors [] (fn [] ^errors [Probe] (fail (Probe))))
    """), newGlobalScope(app))
    scope.assign("factory", replacement)
    check run(compileSource("(client)"), scope).intVal == 7

  test "nested factory results keep each consumed callable contract":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^^private [] (fn [] ^errors [] (fn [] ^errors [] 1)))
      (fn client [] ^errors [] (((factory))))
    """), scope)
    let replacement = run(strictErrorCompile("""
      (fn [] (fn [] ^errors [] (fn [] ^errors [Probe] (fail (Probe)))))
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)
    check run(compileSource("(client)"), scope).intVal == 1

  test "inferred return paths survive annotations on intermediate callables":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^^private []
        (fn [] : (Callable [] Any ^errors []) ^errors []
          (fn [] ^errors [] 1)))
      (fn client [] ^errors [] (((factory))))
    """), scope)
    let replacement = run(strictErrorCompile("""
      (fn [] (fn [] : (Callable [] Any ^errors [Probe]) ^errors []
        (fn [] ^errors [Probe] (fail (Probe)))))
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)
    check run(compileSource("(client)"), scope).intVal == 1

  test "branches returning named callbacks retain both source bindings":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn first ^^private [] ^errors [] 1)
      (fn second ^^private [] ^errors [] 2)
      (fn factory ^^private [flag : Bool] (if flag first second))
      (fn client [flag : Bool] ^errors [] ((factory flag)))
    """), scope)
    let replacement = run(probeCompile("(fn [] ^errors [Probe] (fail (Probe)))"),
                          newGlobalScope(app))
    expect GeneError: scope.assign("second", replacement)
    check run(compileSource("[(client true) (client false)]"), scope).print() == "[1 2]"

  test "branches returning checked callbacks retain their combined contract":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^^private [flag : Bool]
        (if flag (fn [] ^errors [] 1) (fn [] ^errors [] 2)))
      (fn client [flag : Bool] ^errors [] ((factory flag)))
    """), scope)
    let replacement = run(strictErrorCompile("""
      (fn [flag : Bool]
        (if flag (fn [] ^errors [] 1)
          (fn [] ^errors [Probe] (fail (Probe)))))
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)
    check run(compileSource("[(client true) (client false)]"), scope).print() == "[1 2]"

  test "eager collection callbacks retain their inferred error dependencies":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn callback ^^private [value] value)
      (fn mapped [] ^errors [] ($map [1] callback))
    """), scope)
    let broader = run(probeCompile("(fn [value] ^errors [Probe] (fail (Probe)))"),
                       newGlobalScope(app))
    expect GeneError: scope.assign("callback", broader)
    check run(compileSource("(mapped)"), scope).print() == "[1]"
    let compatible = run(compileSource("(fn [value] ^errors [] 2)"), newGlobalScope(app))
    scope.assign("callback", compatible)
    check run(compileSource("(mapped)"), scope).print() == "[2]"

  test "native effect assumptions require metadata rather than a matching name":
    let app = newApplication()
    let scope = newGlobalScope(app)
    let original = app.builtinsScope().lookup("not")
    spoofedNativeCalls = 0
    scope.define("not", newNativeFn("not", spoofedNativePredicate))
    discard run(strictErrorCompile("(fn client [] : Bool ^errors [] (not false))"), scope)
    try:
      discard run(compileSource("(client)"), scope)
      check false
    except GeneError as error:
      require error.hasErrVal
      # A stale assumption is a defect: it passes through the empty row.
      check error.errVal.head.typeName == "RuntimeFault"
      check "requires revalidation" in error.errVal.props["_msg"].strVal
    check spoofedNativeCalls == 0
    # The trusted implementation remains usable through a lexical alias.
    let valid = newGlobalScope(app)
    valid.define("not", original)
    check run(strictErrorCompile("(fn client [] : Bool ^errors [] (not false)) (client)"),
              valid).boolVal
    expect GeneError:
      valid.assign("not", newNativeFn("not", spoofedNativePredicate))
    expect GeneError:
      valid.assign("not", gradualErrorEval("(fn [] ^errors [] 1)"))
    check run(compileSource("(client)"), valid).boolVal
    var stale = original.nativeErrorMetadata
    stale.version = "obsolete"
    let staleScope = newGlobalScope(app)
    staleScope.define("not", newNativeFn("not", spoofedNativePredicate,
      errorMetadata = stale))
    expect GeneError:
      discard run(strictErrorCompile("(not false)"), staleScope)
    check spoofedNativeCalls == 0

  test "native namespace aliases retain the implementation's effect model":
    errorContractCheck """
      (mod aliases ^errors_mode strict)
      (import gene/stream [map : map_values])
      (fn positive [n : Int] : Bool ^errors [] (> n 0))
      (fn values [] ^errors []
        [(map_values [1 2] positive) ($stream/map [1 2] positive)])
      (values)
    """, "[[true true] [true true]]"

  test "compatible namespace replacements keep their new member slots protected":
    let scope = newGlobalScope(newApplication())
    discard run(strictErrorCompile("""
      (ns library (fn provider [] : Int ^errors [] 1))
      (fn client [] : Int ^errors [] (library/provider))
    """), scope)
    let replacement = run(compileSource("(ns library (fn provider [] : Int ^errors [] 2))"),
                          newGlobalScope(scope.application()))
    let foreign = gradualErrorEval("(ns library (fn provider [] : Int ^errors [] 2))")
    expect GeneError: scope.assign("library", foreign)
    scope.assign("library", replacement)
    let broader = gradualErrorEval("(fn [] : Int ^errors [Error] (/ 1 0))")
    # No intervening call is needed to refresh the new namespace dependency.
    expect GeneError: replacement.nsScope.assign("provider", broader)
    try:
      check run(compileSource("(client)", useLocalSlots = false), scope).intVal == 2
    except GeneError as error:
      checkpoint error.errVal.print()
      raise
    let missing = run(compileSource("(fn provider [] : Int ^errors [] 9) (ns empty)"),
                      newGlobalScope(scope.application()))
    expect GeneError: scope.assign("library", missing)
    check run(compileSource("(client)", useLocalSlots = false), scope).intVal == 2
    check gradualErrorEval("""
      (mod init ^errors_mode strict)
      (ns library (fn provider [] : Int ^errors [] 3))
      (library/provider)
    """).intVal == 3

  test "a parameter shadowing its type name does not hide a message proof":
    let scope = newGlobalScope(newApplication())
    check run(strictErrorCompile("""
      (ns model (type Item ^props {} (message value [] : Int ^errors [] 7)))
      (fn read [Item : model/Item] : Int ^errors [] (Item .value))
      (read (model/Item))
    """), scope).intVal == 7
    let replacement = gradualErrorEval("""
      (type Other ^props {} (message value [] : Int ^errors [] 9)) Other
    """)
    expect GeneError: scope.lookup("model").nsScope.assign("Item", replacement)

  test "initialization assumptions protect root and nested declaration groups":
    for localSlots in [false, true]:
      let scope = newGlobalScope(newApplication())
      scope.define("trigger", newNativeCallFn("trigger", widenInitializerDependency))
      let source = """
        (mod initial ^errors_mode strict)
        (fn helper [] ^errors [] 1)
        (try (trigger) catch Throwable nil)
        (helper)
      """
      check run(compileSource(source, useLocalSlots = localSlots), scope).intVal == 1
      # Only the initialization depended on this provider; its lease is gone.
      scope.assign("helper", gradualErrorEval("(fn [] ^errors [Error] 2)"))
    let scope = newGlobalScope(newApplication())
    scope.define("trigger", newNativeCallFn("trigger", widenInitializerDependency))
    let namespace = run(strictErrorCompile("""
      (ns inner
        (fn helper [] ^errors [] 1)
        (try (trigger) catch Throwable nil)
        (helper))
    """), scope)
    check run(compileSource("(helper)", useLocalSlots = false), namespace.nsScope).intVal == 1
    namespace.nsScope.assign("helper", gradualErrorEval("(fn [] ^errors [Error] 2)"))

  test "a retained error formats after its sandbox generation is released":
    let root = getCurrentDir() / "tmp" / "error_generation_release"
    createDir(root)
    writeFile(root / "plugin.gene", """
      (type Local : Error ^props {^code Int} (message message [] : Str ^errors [] ^^override "retained generation"))
      (fn raise_error [] ^errors [Error] (fail (Local ^code 7)))
    """)
    let app = newApplication(root)
    let scope = newGlobalScope(app)
    let program = """
      (var tx ($runtime/sandbox_transaction))
      (var generation (tx .prepare {^dir DIR ^entry "plugin.gene" ^grants [] ^shared []
        ^policy {^max_memory_mb 16 ^timeout_ms 1000}}))
      (tx .commit)
      (var plugin (generation .module))
      (var held (try (plugin/raise_error) catch Error $err))
      (generation .release)
      (set plugin nil)
      (set generation nil)
      (set tx nil)
      (try (fail held) catch Error $err/.message)
    """.replace("DIR", newStr(root).print())
    check run(compileSource(program), scope).strVal == "retained generation"

  test "retaining an error does not restore authority removed from its caller":
    let root = getCurrentDir() / "tmp" / "error_formatter_authority"
    createDir(root)
    let path = root / "message.txt"
    writeFile(path, "permitted")
    let app = newApplication(root)
    let producer = newGlobalScope(app)
    producer.implOverlayRoot = true
    let held = run(compileSource("""
      (type Local : Error ^props {^code Int} (message message [] : Str ^errors [] ^^override ($fs/read_text PATH)))
      (try (fail (Local ^code 7)) catch Error $err)
    """.replace("PATH", newStr(path).print())), producer)
    producer.define("held", held)
    try:
      check run(compileSource("(try (fail held) catch Error $err/.message)"), producer).strVal == "permitted"
    except GeneError as error:
      checkpoint error.errVal.print()
      raise
    let restricted = newGlobalScope(app)

  test "removing a canonical provider rejects publication until the caller is released":
    let root = getCurrentDir() / "tmp" / "error_provider_removal"
    createDir(root)
    writeFile(root / "protocol.gene", "(protocol P (message value [] : Int ^errors []))")
    writeFile(root / "provider.gene", """
      (import [P] ^from "./protocol.gene")
      (type Item ^props {})
      (impl P for Item (message value [] : Int ^errors [] 1))
      (fn make [] (Item))
    """)
    writeFile(root / "client.gene", """
      (mod client ^errors_mode strict)
      (import [P] ^from "./protocol.gene")
      (import * : provider ^from "./provider.gene")
      (fn invoke [item : P] : Int ^errors [] (item .P:value))
    """)
    let app = newApplication(root)
    let loaded = app.loadFileModule(root / "client.gene")
    let scope = loaded.moduleRootNamespace.nsScope
    let value = run(compileSource("(provider/make)", useLocalSlots = false), scope)
    scope.define("instance", value)
    check run(compileSource("(invoke instance)", useLocalSlots = false), scope).intVal == 1
    writeFile(root / "provider.gene", """
      (import [P] ^from "./protocol.gene")
      (type Item ^props {})
      (fn make [] (Item))
    """)
    let epoch = app.implActivationEpoch
    try:
      discard app.reloadFileModule(root / "provider.gene")
      check false
    except GeneError as error:
      check "impl replacement/removal" in error.msg
      check "invoke" in error.msg
    check app.implActivationEpoch == epoch
    check run(compileSource("(invoke instance)", useLocalSlots = false), scope).intVal == 1
    scope.assign("invoke", NIL)
    GC_fullCollect()
    discard app.reloadFileModule(root / "provider.gene")

  test "sandbox release preserves external strict protocol callers atomically":
    let root = getCurrentDir() / "tmp" / "error_generation_strict_release"
    let pluginDir = root / "plugin"
    createDir(pluginDir)
    writeFile(root / "contract.gene",
      "(protocol P (message value [] : Int ^errors []))")
    writeFile(root / "client.gene", """
      (mod client ^errors_mode strict)
      (import [P] ^from "./contract.gene")
      (fn invoke [item : P] : Int ^errors [] (item .P:value))
    """)
    writeFile(pluginDir / "main.gene", """
      (import [P] ^from "../contract.gene")
      (type Item ^props {})
      (impl P for Item (message value [] : Int ^errors [] 42))
      (fn make [] (Item))
    """)
    let app = newApplication(root)
    let client = app.loadFileModule(root / "client.gene")
    let scope = client.moduleRootNamespace.nsScope
    let beforeModules = app.moduleCacheEntryCount()
    let beforeImpls = app.canonicalImplCount()
    check run(compileSource("""
      (var tx ($runtime/sandbox_transaction))
      (var generation (tx .prepare {^dir DIR ^entry "main.gene" ^grants []
        ^shared [CONTRACT]
        ^policy {^max_memory_mb 16 ^timeout_ms 1000}}))
      (tx .commit)
      (var plugin (generation .module))
      (var instance (plugin/make))
      (invoke instance)
    """.replace("DIR", newStr(pluginDir).print())
       .replace("CONTRACT", newStr(root / "contract.gene").print()),
       useLocalSlots = false), scope).intVal == 42
    let moduleCount = app.moduleCacheEntryCount()
    let headerCount = app.moduleCompileHeaderCount()
    let artifactCount = app.moduleCompileArtifactCount()
    let epoch = app.implActivationEpoch
    try:
      discard run(compileSource("(generation .release)"), scope)
      check false
    except GeneError as error:
      check "impl replacement/removal" in error.msg
      check "invoke" in error.msg
    check app.moduleCacheEntryCount() == moduleCount
    check app.moduleCompileHeaderCount() == headerCount
    check app.moduleCompileArtifactCount() == artifactCount
    check app.implActivationEpoch == epoch
    check run(compileSource("(invoke instance)", useLocalSlots = false), scope).intVal == 42
    scope.assign("invoke", NIL)
    GC_fullCollect()
    discard run(compileSource("(generation .release)"), scope)
    check app.moduleCacheEntryCount() == beforeModules
    check app.canonicalImplCount() == beforeImpls

  test "protocol replacement is rejected before invalidating a retained caller":
    let root = getCurrentDir() / "tmp" / "error_dispatch_updates"
    createDir(root)
    writeFile(root / "model.gene", "(type Item ^props {})")
    writeFile(root / "provider.gene", """
      (import [Item] ^from "./model.gene")
      (protocol P (message value [] : Int ^errors []))
      (impl P for Item (message value [] : Int ^errors [] 1))
    """)
    writeFile(root / "client.gene", """
      (mod client ^errors_mode strict)
      (import [Item] ^from "./model.gene")
      (import [P] ^from "./provider.gene")
      (fn value [item : Item] : Int ^errors [] (item .P:value))
    """)
    let app = newApplication(root)
    let client = app.loadFileModule(root / "client.gene")
    let scope = client.moduleRootNamespace.nsScope
    check run(compileSource("(value (Item))", useLocalSlots = false), scope).intVal == 1
    let epoch = app.implActivationEpoch
    writeFile(root / "provider.gene", """
      (import [Item] ^from "./model.gene")
      (protocol P (message value [] : Int ^errors [Error]))
      (impl P for Item (message value [] : Int ^errors [Error] (/ 1 0)))
    """)
    expect GeneError: discard app.reloadFileModule(root / "provider.gene")
    check app.implActivationEpoch == epoch
    check run(compileSource("(value (Item))", useLocalSlots = false), scope).intVal == 1

  test "a same-contract scoped impl can change under a retained strict caller":
    let root = getCurrentDir() / "tmp" / "error_impl_updates"
    createDir(root)
    writeFile(root / "model.gene", """
      (type Item ^props {})
      (protocol P (message value [] : Int ^errors []))
    """)
    writeFile(root / "provider.gene", """
      (import [P Item] ^from "./model.gene")
      (impl P for Item ^^export (message value [] : Int ^errors [] 1))
    """)
    writeFile(root / "client.gene", """
      (mod client ^errors_mode strict)
      (import [P Item] ^from "./model.gene")
      (import_impl P for Item ^from "./provider.gene")
      (fn value [item : Item] : Int ^errors [] (item .P:value))
    """)
    let app = newApplication(root)
    let loaded = app.loadFileModule(root / "client.gene")
    let scope = loaded.moduleRootNamespace.nsScope
    check run(compileSource("(value (Item))", useLocalSlots = false), scope).intVal == 1
    writeFile(root / "provider.gene", """
      (import [P Item] ^from "./model.gene")
      (impl P for Item ^^export (message value [] : Int ^errors [] 2))
    """)
    discard app.reloadFileModule(root / "provider.gene")
    check run(compileSource("(value (Item))", useLocalSlots = false), scope).intVal == 2

  test "a replacement must preserve the returned callback's own contract":
    let scope = newGlobalScope(newApplication())
    discard run(strictErrorCompile("""
      (fn factory ^^private [] : (Callable [] Int ^errors []) ^errors []
        (fn [] : Int ^errors [] 1))
      (fn client [] : Int ^errors [] ((factory)))
    """), scope)
    let broader = gradualErrorEval("""
      (fn [] : (Callable [] Int ^errors [Probe]) ^errors []
        (fn [] : Int ^errors [Probe] (fail (Probe)) 0))
    """)
    expect GeneError: scope.assign("factory", broader)
    let compatible = gradualErrorEval("""
      (fn [] : (Callable [] Int ^errors []) ^errors []
        (fn [] : Int ^errors [] 2))
    """)
    scope.assign("factory", compatible)
    check run(compileSource("(client)", useLocalSlots = false), scope).intVal == 2

  test "a constructor replacement cannot broaden a retained caller's row":
    let scope = newGlobalScope(newApplication())
    discard run(strictErrorCompile("""
      (type Resource ^props {} (ctor [] ^errors [] nil))
      (fn make [] ^errors [] (new Resource))
    """), scope)
    let replacement = gradualErrorEval("""
      (type Replacement ^props {}
        (ctor [] ^errors [Probe] (fail (Probe))))
      Replacement
    """)
    expect GeneError: scope.assign("Resource", replacement)
    check scope.lookup("Resource").typeName == "Resource"

  test "catch aliases and failed nominal types retain their identities":
    for target in ["Caught", "First"]:
      let app = newApplication()
      let scope = newGlobalScope(app)
      discard run(strictErrorCompile("""
        (type First : Error)
        (type Second : Error)
        (alias Caught First)
        (fn failer ^^private [] (fail (First ^_msg "original")))
        (fn client [] ^errors [] (try (failer) catch Caught 7))
      """), scope)
      let replacement = run(compileSource("Second"), scope)
      expect GeneError: scope.assign(target, replacement)
      check run(compileSource("(client)"), scope).intVal == 7

  test "widening a live provider is rejected before its binding changes":
    let scope = newGlobalScope(newApplication())
    discard run(strictErrorCompile("""
      (fn provider ^^private [] ^errors [] 1)
      (fn client [] ^errors [] (provider))
    """), scope)
    let replacement = gradualErrorEval("(fn [] ^errors [Probe] (fail (Probe)))")
    expect GeneError: scope.assign("provider", replacement)
    check run(compileSource("(client)", useLocalSlots = false), scope).intVal == 1
    let compatible = gradualErrorEval("(fn [] ^errors [] 2)")
    scope.assign("provider", compatible)
    check run(compileSource("(client)", useLocalSlots = false), scope).intVal == 2

  test "retained callable values keep their assumptions alive until released":
    let scope = newGlobalScope(newApplication())
    var declarationResult = run(strictErrorCompile("""
      (fn provider ^^private [] ^errors [] 1)
      (fn client [] ^errors [] (provider))
    """), scope)
    # A named function declaration is itself a value. Release the escaped
    # result too; Nim may keep a discarded return temporary until block exit.
    declarationResult = NIL
    var retained = scope.lookup("client")
    scope.assign("client", NIL)
    let replacement = gradualErrorEval("(fn [] ^errors [Error] (/ 1 0))")
    expect GeneError: scope.assign("provider", replacement)
    check retained.kind == vkFunction
    retained = NIL
    GC_fullCollect()
    scope.assign("provider", replacement)

  test "strict recursion executes with forward dependency declarations":
    errorContractCheck """
      (mod recursive ^errors_mode strict)
      (fn left ^^private [n : Int] ^errors [Probe]
        (if (== n 0) (fail (Probe)) (right (- n 1))))
      (fn right ^^private [n : Int] ^errors [Probe] (left n))
      (fn main [] ^errors [] (try (left 3) catch Probe 7))
      (main)
    """, "7"
