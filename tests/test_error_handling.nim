import gene/[capabilities, compiler, error_analysis, fs_capabilities, gir, gir_codec, printer, reader, types, vm]
import std/[json, os, strutils, tables, unittest]

proc gradualErrorEval(source: string): Value =
  run(compileSource(source, sourceName = "error_handling_spec.gene"),
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
  test "Error default access and the message shortcut use the original value":
    errorContractCheck """
      (let original (AssertionError ^message "same"))
      (try (fail original)
        catch Error [(same? original $err) (== original $err)
          $err/message $err/.Error:message $err_msg])
    """, "[true true \"same\" \"same\" \"same\"]"

  test "custom Error messages are lazy and called on each shortcut use":
    errorContractCheck """
      (var calls 0)
      (type StatusError ^props {^code Int})
      (impl Error for StatusError
        (message message [] : Str ^errors []
          (set calls (+ calls 1)) $"status ${self/code}"))
      (try (fail (StatusError ^code 503)) catch Error nil)
      (let before calls)
      (let texts (try (fail (StatusError ^code 404))
        catch Error [$err_msg $err_msg]))
      [before calls texts]
    """, "[0 2 [\"status 404\" \"status 404\"]]"

  test "message shortcuts capture the lexical catch and respect nesting":
    errorContractCheck """
      (let later (try (fail (AssertionError ^message "outer"))
        catch Error
          (let inner (try (fail (AssertionError ^message "inner"))
            catch Error $err_msg))
          (fn [] [inner $err_msg])))
      (later)
    """, "[\"inner\" \"outer\"]"
    for source in ["$err", "$err_msg", "(set $err_msg \"changed\")"]:
      expect GeneError: discard gradualErrorEval(source)

  test "a type-direct message coexists with the Error message":
    errorContractCheck """
      (type Distinct ^props {^message Str}
        (message message [] : Str ^errors [] "direct"))
      (impl Error for Distinct)
      (try (fail (Distinct ^message "protocol"))
        catch Error [$err/.message $err/.Error:message $err_msg])
    """, "[\"direct\" \"protocol\" \"protocol\"]"

  test "invalid default backing schemas are rejected":
    for fields in ["{}", "{^message Str?}", "{^message Int}"]:
      expect GeneError:
        discard gradualErrorEval("(type Invalid ^props " & fields & ") (impl Error for Invalid)")

  test "message-shaped values do not implicitly become errors":
    errorContractCheck """
      (type JustData ^props {^message Str})
      (try (fail (JustData ^message "data")) catch TypeError true)
    """, "true"

  test "open error rows admit unknown ordinary errors without changing them":
    errorContractCheck """
      (fn open [callback] ^errors [AssertionError Error] (callback))
      (try (open (fn [] (/ 1 0))) catch RuntimeError $err_msg)
    """, "\"division by zero\""

  test "row aliases unions Never and redundant subtypes normalize by coverage":
    errorContractCheck """
      (type ParentError ^props {^message Str})
      (impl Error for ParentError)
      (type ChildError : ParentError ^props {})
      (alias Empty Never)
      (alias Both (| ParentError ChildError))
      (alias Open Error)
      (fn closed [] ^errors [Empty Both ParentError]
        (fail (ChildError ^message "child")))
      (fn opened [] ^errors [ParentError Open Empty]
        ($assert false "other"))
      [(try (closed) catch ParentError $err_msg)
       (try (opened) catch AssertionError $err_msg)]
    """, "[\"child\" \"other\"]"

  test "nested callable signatures compare semantic open error coverage":
    errorContractCheck """
      (type Known ^props {^message Str})
      (impl Error for Known)
      (protocol Invoke
        (message invoke [callback : (Callable [] Any ^errors [Known Error])]
          : Any ^errors [Error]))
      (type Receiver ^props {})
      (impl Invoke for Receiver
        (message invoke [callback : (Callable [] Any ^errors [Error Known Known Never])]
          : Any ^errors [Error] (callback)))
      (try ((Receiver) .Invoke:invoke (fn [] (fail (Known ^message "known"))))
        catch Known $err_msg)
    """, "\"known\""

  test "a checked row creates one violation and retains the original cause":
    errorContractCheck """
      (fn closed [] ^errors [] ($assert false "cause"))
      (fn middle [] ^errors [] (closed))
      (fn outer [] ^errors [] (middle))
      (try (outer)
        catch AssertionError "wrong"
        catch ErrorContractViolation [$err/where $err/cause/message
          $err/cause/.Error:message])
    """, "[\"closed\" \"cause\" \"cause\"]"

  test "checked callable views create the same single violation":
    errorContractCheck """
      (let guarded : (Callable [] Any ^errors [])
        (fn [] ($assert false "view cause")))
      (fn outer [] ^errors [] (guarded))
      (try (outer) catch ErrorContractViolation
        [$err/where $err/cause/message])
    """, "[\"Callable contract\" \"view cause\"]"

  test "generated and freshly constructed TypeErrors have different provenance":
    errorContractCheck """
      (fn generated [] ^errors [] (let n : Int "bad"))
      (fn explicit [] ^errors []
        (fail (TypeError ^message "user" ^where "x" ^expected "Int" ^actual "Str")))
      [(try (generated) catch TypeError "generated")
       (try (explicit) catch ErrorContractViolation $err/cause/message)]
    """, "[\"generated\" \"user\"]"

  test "rethrow aliases preserve generated classification and identity":
    errorContractCheck """
      (var original nil)
      (fn inner [] ^errors [] (let n : Int "bad"))
      (fn again [] ^errors []
        (try (inner) catch Error
          (set original $err)
          (let alias $err)
          (fail alias)))
      (try (again) catch TypeError (same? original $err))
    """, "true"

  test "freshly wrapping a generated failure produces an ordinary error":
    errorContractCheck """
      (fn wrapper [] ^errors []
        (try (let n : Int "bad") catch TypeError
          (fail (ErrorContractViolation ^message "new" ^where "user"
            ^expected [] ^actual TypeError ^cause $err))))
      (try (wrapper) catch ErrorContractViolation
        [$err/where $err/cause/where])
    """, "[\"wrapper\" \"user\"]"

  test "default-expression failures belong to the callee's row":
    errorContractCheck """
      (fn with_default [x = ($assert false "default")] ^errors [] x)
      [(with_default 7)
       (try (with_default) catch ErrorContractViolation
         [$err/where $err/cause/message])]
    """, "[7 [\"with_default\" \"default\"]]"

  test "scoped Error conformance travels with an escaping failure":
    errorContractCheck """
      (type Local ^props {^message Str})
      (fn raise_local []
        (impl Error for Local
          (message message [] : Str ^errors [] "raising scope"))
        (fail (Local ^message "raw")))
      (try (raise_local) catch Error [$err/message $err_msg])
    """, "[\"raw\" \"raising scope\"]"

  test "a catcher's local provider does not replace an incoming witness":
    errorContractCheck """
      (type Local ^props {^message Str})
      (fn raise_local []
        (impl Error for Local
          (message message [] : Str ^errors [] "original"))
        (fail (Local ^message "raw")))
      (fn recover []
        (impl Error for Local
          (message message [] : Str ^errors [] "catcher"))
        (try (raise_local) catch Error $err_msg))
      (recover)
    """, "\"original\""

  test "freezing and thawing an error preserve its retained conformance":
    errorContractCheck """
      (type Local ^props {^code Int})
      (fn snapshots []
        (impl Error for Local
          (message message [] : Str ^errors [] $"local ${self/code}"))
        (try (fail (Local ^code 7)) catch Error
          [($freeze $err) ($freeze_shallow $err) ($thaw ($freeze $err))]))
      (let errors (snapshots))
      [(try (fail errors/0) catch Error $err_msg)
       (try (fail errors/1) catch Error $err_msg)
       (try (fail errors/2) catch Error $err_msg)]
    """, "[\"local 7\" \"local 7\" \"local 7\"]"

  test "container copies preserve generated failure provenance":
    errorContractCheck """
      (let saved (try (let n : Int "bad") catch TypeError ($freeze $err)))
      (fn rethrow [error] ^errors [] (fail ($thaw error)))
      (try (rethrow saved) catch TypeError "generated")
    """, "\"generated\""

  test "overwriting an owning binding does not invalidate an escaped witness":
    errorContractCheck """
      (fn make []
        (type Local ^props {^message Str})
        (impl Error for Local
          (message message [] : Str ^errors [] self/message))
        (var original (Local ^message "still alive"))
        (let saved (try (fail original) catch Error $err))
        (set original nil)
        saved)
      (let saved (make))
      (try (fail saved) catch Error $err_msg)
    """, "\"still alive\""

  test "Send checks a retained formatter even on a nominal Send type":
    errorContractCheck """
      (type Local ^props {^code Int})
      (impl Send for Local)
      (fn saved_error []
        (let secret ($cell "local only"))
        (impl Error for Local
          (message message [] : Str ^errors [] (secret .get)))
        (try (fail (Local ^code 7)) catch Error ($freeze $err)))
      (let saved (saved_error))
      (let channel ($channel))
      [(try (channel .try_send saved) catch TypeError "not Send")
       (try (fail saved) catch Error $err_msg)]
    """, "[\"not Send\" \"local only\"]"

  test "formatter return checks remain generated failures":
    errorContractCheck """
      (type Broken ^props {^code Int})
      (impl Error for Broken
        (message message [] : Str ^errors [] 7))
      (fn recover [] ^errors []
        (try (fail (Broken ^code 1)) catch Error $err_msg))
      (try (recover) catch TypeError "bad formatter")
    """, "\"bad formatter\""

  test "terminal reporting uses custom messages with a nonrecursive fallback":
    for bad in [false, true]:
      let scope = newGlobalScope(newApplication())
      let body = if bad: "(/ 1 0)" else: "\"display text\""
      let source = "(var calls 0) (type Custom ^props {^code Int}) " &
        "(impl Error for Custom (message message [] : Str ^errors [] " &
        "(set calls (+ calls 1)) " & body & ")) (fail (Custom ^code 7))"
      try:
        discard run(compileSource(source), scope)
        check false
      except GeneError as error:
        let original = error.errVal
        let displayed = errorDiagnosticMessage(error, scope)
        if bad: check error.msg in displayed
        else: check displayed == "Custom: display text"
        check error.errVal.bits == original.bits
        check not error.errVal.generatedFailure
        check scope.lookup("calls").intVal == 1

  test "propagation restores the host exception context":
    for source in [
      "(try (let n : Int \"bad\") catch Error nil)",
      "(let f : (Callable [] Any ^errors []) (fn [] ($assert false))) " &
        "(try (f) catch ErrorContractViolation nil)",
      "(let stream ([1] => (fn [x] (fail \"invalid\")))) " &
        "(try (stream .next) catch Error nil)"
    ]:
      let previous = getCurrentException()
      discard gradualErrorEval(source)
      check getCurrentException() == previous

  test "native task admission retains the producing scope's Error provider":
    let scope = newGlobalScope(newApplication())
    scope.implOverlayRoot = true
    let error = run(compileSource("""
      (type Local ^props {^code Int})
      (impl Error for Local
        (message message [] : Str ^errors [] $"native ${self/code}"))
      (Local ^code 7)
    """), scope)
    let task = nativeNewAsyncTask()
    expect GeneError:
      discard nativeTaskFail(task, "native", error, hasValue = true)
    check not task.taskDone
    check nativeTaskFail(task, "native", error, hasValue = true, scope = scope)
    check not nativeTaskFail(task, "already settled", NIL, hasValue = true)
    # A separately rooted scope has not imported the Local implementation.
    let consumer = newGlobalScope(scope.application())
    consumer.define("task", task)
    check run(compileSource("(try (await task) catch Error $err_msg)"), consumer).strVal == "native 7"

  test "already-admitted native failures retain generated provenance":
    let producer = newGlobalScope(newApplication())
    let error = run(compileSource("(try (let n : Int \"bad\") catch TypeError $err)"), producer)
    let task = nativeNewAsyncTask()
    check nativeTaskFail(task, "generated", error, hasValue = true)
    let scope = newGlobalScope(producer.application())
    scope.define("task", task)
    check run(compileSource("""
      (fn consume [] ^errors [] (await task))
      (try (consume) catch TypeError "generated")
    """), scope).strVal == "generated"

  test "empty native failure messages retain their error and panic states":
    for constructed in [false, true]:
      let scope = newGlobalScope(newApplication())
      let failed = if constructed: newFailedTask("") else: nativeNewAsyncTask()
      if not constructed: check nativeTaskFail(failed, "", scope = scope)
      scope.define("failed", failed)
      let outcome = run(compileSource("(failed .join)"), scope)
      check outcome.head.enumVariantName == "error"
      check outcome.body[0].head.typeName == "RuntimeError"
      check outcome.body[0].props["message"].strVal == ""
      check not failed.taskAwaited
      check run(compileSource("(try (await failed) catch RuntimeError true)"), scope).boolVal
      let panicked = if constructed: newPanickedTask("") else: nativeNewAsyncTask()
      if not constructed: check tryPanicTask(panicked, "")
      scope.define("panicked", panicked)
      check run(compileSource("(panicked .join)"), scope).head.enumVariantName == "panic"
      expect GenePanic:
        discard run(compileSource("(try (await panicked) catch Error false)"), scope)

  test "join validates message-only native failures against deferred rows":
    let task = nativeNewAsyncTask()
    check nativeTaskFail(task, "native failure")
    let scope = newGlobalScope(newApplication())
    scope.define("task", task)
    let outcome = run(compileSource("""
      (let bounded : (Task Any Never) task)
      (bounded .join)
    """), scope)
    let error = outcome.body[0]
    check error.head.typeName == "ErrorContractViolation"
    check error.generatedFailure
    check error.props["cause"].head.typeName == "RuntimeError"
    check error.props["cause"].props["message"].strVal == "native failure"
    check error.props["cause"].hasErrorWitness

proc strictErrorCompile(source: string): Chunk =
  compileSource("(mod checked ^errors_mode strict)\n" & source,
                 sourceName = "strict_error_spec.gene")

suite "errors — static catch or declare":
  test "strict public functions require explicit rows while private helpers infer":
    expect GeneError: discard strictErrorCompile("(fn public [] 1)")
    discard strictErrorCompile("(fn helper ^private true [] 1) " &
      "(fn public [] ^errors [] (helper))")

  test "strict checking follows unannotated helper chains":
    let helpers = """
      (type ConfigError ^props {^message Str})
      (impl Error for ConfigError)
      (fn decode ^private true [bad : Bool] : Str
        (if bad (fail (ConfigError ^message "bad")) "ready"))
      (fn load_config ^private true [bad : Bool] : Str (decode bad))
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
      "(try (callback) catch Error $err_msg))")
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
    let declarations = "(type Known ^props {^message Str}) (impl Error for Known) "
    expect GeneError:
      discard strictErrorCompile(declarations &
        "(fn invoke [callback : Callable] ^errors [Known] " &
        "(try (callback) catch Known \"handled\"))")
    discard strictErrorCompile(declarations &
      "(fn invoke [callback : Callable] ^errors [Known Error] " &
      "(try (callback) catch Known \"handled\"))")

  test "recovery and cleanup introduce their own errors":
    let helper = "(fn failure ^private true [] ($assert false)) "
    for expression in ["(try (failure) catch Error ($assert false))",
                       "(try (failure) catch Error nil ensure ($assert false))"]:
      expect GeneError:
        discard strictErrorCompile(helper & "(fn main [] ^errors [] " & expression & ")")

  test "native call shapes contribute ordinary errors before their body":
    for expression in ["(not)", "(not false true)", "(not false ^extra 1)",
                       "(same? 1)", "($assert)", "($parse/parse_int)",
                       "($map [] (fn [x] x) 3)", "($into [] [] [] )"]:
      expect GeneError:
        discard strictErrorCompile("(fn invalid [] ^errors [] " & expression & ")")
      discard strictErrorCompile("(fn allowed [] ^errors [RuntimeError] " & expression & ")")
    check run(strictErrorCompile("""
      (fn invalid [] ^errors [RuntimeError] (not false true))
      (try (invalid) catch RuntimeError true)
    """), newGlobalScope(newApplication())).boolVal
    check run(strictErrorCompile("[(+) (-) (*) (==) (<)]"),
              newGlobalScope(newApplication())).print() == "[0 0 1 true true]"

  test "native collection summaries preserve shape and validation effects":
    for expression in ["($take [1] -1)", "($take -1)",
                       "($into ($to_stream [1]) 0)", "($into [1] {})",
                       "($read_one \"1 2\")"]:
      expect GeneError:
        discard strictErrorCompile("(fn invalid [] ^errors [] " & expression & ")")
    discard strictErrorCompile("""
      (fn parse [] ^errors [ParseError RuntimeError] ($read_one "1 2"))
      (fn collect [] ^errors [RuntimeError] ($into [1] {}))
    """)
    check run(strictErrorCompile("""
      (fn same [x : Int] : Int ^errors [] x)
      (fn collect [] ^errors []
        [($into ($range 0 3) [])
         ($map {^a 1} same)
         ($into ($take ($to_stream [1 2 3]) 2) [])])
      (collect)
    """), newGlobalScope(newApplication())).print() == "[[0 1 2] {^a 1} [1 2]]"
    expect GeneError:
      discard strictErrorCompile("""
        (fn same [x : Int] : Int ^errors [] x)
        (fn invalid [] ^errors [] ($take ($map {^a 1} same) 1))
      """)

  test "native message summaries include invocation state failures":
    for expression in ["(#[1] .push 2)", "([1] .size 2)", "({^a 1} .push 2)",
                       "({^a 1} .size)", "({^a 1} .empty?)",
                       "(($to_stream []) .next)"]:
      expect GeneError:
        discard strictErrorCompile("(fn invalid [] ^errors [] " & expression & ")")
    check run(strictErrorCompile("""
      (fn exhausted [] ^errors [EndOfStream RuntimeError]
        (($to_stream []) .next))
      (try (exhausted) catch EndOfStream true catch RuntimeError false)
    """), newGlobalScope(newApplication())).boolVal
    check run(strictErrorCompile("""
      (fn mutate [] ^errors [RuntimeError] (#[1] .push 2))
      (try (mutate) catch RuntimeError true)
    """), newGlobalScope(newApplication())).boolVal
    check run(strictErrorCompile("[([1 2] .size) ($empty? {^a 1})]"),
              newGlobalScope(newApplication())).print() == "[2 false]"

  test "outcome-returning methods contain producer errors but retain state errors":
    let outcome = run(strictErrorCompile("""
      (fn inspect [source : (Stream Any AssertionError)] ^errors [] (source .try_next))
      (let source ($map ($to_stream [1])
        (fn [x] ^errors [AssertionError] ($assert false))))
      (inspect source)
    """), newGlobalScope(newApplication()))
    check outcome.head.enumVariantName == "error"
    expect GeneError:
      discard strictErrorCompile("(fn join [task : (Task Any Never)] ^errors [] (task .join))")
    check run(strictErrorCompile("""
      (fn consume [task : (Task Int Never)] ^errors [RuntimeError]
        (await task)
        (task .join))
      (try (consume (spawn 1)) catch RuntimeError true)
    """), newGlobalScope(newApplication())).boolVal

  test "range construction includes ordinary bounds and step failures":
    for expression in ["($range 0 3 0)", "($range 0)",
                       "($range 0 9223372036854775808)",
                       "($range 0 3 1 7)"]:
      expect GeneError:
        discard strictErrorCompile("(fn invalid [] ^errors [] " & expression & ")")
      discard strictErrorCompile("(fn allowed [] ^errors [RuntimeError] " & expression & ")")
    expect GeneError:
      discard strictErrorCompile("(fn uncertain [stop : Int] ^errors [] ($range 0 stop))")
    expect GeneError:
      discard strictErrorCompile("(fn uncertain [step : I64] ^errors [] ($range 0 3 step))")
    check run(strictErrorCompile("""
      (fn fixed [stop : I64] : Range ^errors [] ($range 0 stop))
      (fixed 3)
    """), newGlobalScope(newApplication())).rangeStop == 3
    check run(strictErrorCompile("""
      (fn invalid [] ^errors [RuntimeError] ($range 0 3 0))
      (try (invalid) catch RuntimeError $err_msg)
    """), newGlobalScope(newApplication())).strVal == "range step must not be zero"

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
      (fn left ^private true [n : Int]
        (if (== n 0) ($assert false) (right (- n 1))))
      (fn right ^private true [n : Int] (left n))
    """
    expect GeneError:
      discard strictErrorCompile(source & "(fn start [] ^errors [] (left 3))")
    discard strictErrorCompile(source & "(fn start [] ^errors [AssertionError] (left 3))")

  test "defaults contribute to the callee's invocation row":
    expect GeneError:
      discard strictErrorCompile("(fn load [value = ($assert false)] ^errors [] value)")
    discard strictErrorCompile("(fn load [value = ($assert false)] ^errors [AssertionError] value)")

  test "generated-only rethrows have no ordinary error obligation":
    discard strictErrorCompile("(fn checked [] ^errors [] " &
      "(try (let x : Int \"bad\") catch TypeError (let alias $err) (fail alias)))")

  test "ordinary rethrows retain their obligation":
    expect GeneError:
      discard strictErrorCompile("(fn checked [callback : Callable] ^errors [] " &
        "(try (callback) catch Error (fail $err)))")

  test "checked callable parameters supply their enforced row":
    discard strictErrorCompile("(fn invoke [callback : (Callable [] Any ^errors [])] " &
      "^errors [] (callback))")

  test "warning mode reports the same violation without rejecting code":
    let source = "(fn checked [] ^errors [] ($assert false))"
    let warned = compileSource("(mod checked ^errors_mode warn) " & source)
    check warned.compilerDiagnostics.len > 0
    check "AssertionError" in warned.compilerDiagnostics[0].message
    let dynamic = compileSource("(mod checked ^errors_mode dynamic) " & source)
    check dynamic.compilerDiagnostics.len == 0

  test "module initialization has an empty escaping row":
    expect GeneError: discard strictErrorCompile("($assert false)")
    discard strictErrorCompile("(try ($assert false) catch Error nil)")

  test "initialization cannot assume a forward declaration is already usable":
    expect GeneError:
      discard strictErrorCompile("(later) (fn later [] ^errors [] 1)")
    expect GeneError:
      discard strictErrorCompile("(fn first ^private true [] (later)) " &
        "(first) (fn later ^private true [] 1)")
    expect GeneError:
      discard strictErrorCompile("(fn first ^private true [] (later/helper)) " &
        "(first) (ns later (fn helper [] ^errors [] 1))")
    discard strictErrorCompile("(fn first ^private true [] 1) (first)")
    discard strictErrorCompile("(fn first ^private true [] 1) (let result (first))")

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
        (ctor [value = ($assert false "default")] ^errors [AssertionError] nil))
      (type Child : Parent ^props {})
    """
    for typ in ["Parent", "Child"]:
      expect GeneError:
        discard strictErrorCompile(declarations &
          "(fn make [] ^errors [] (new " & typ & "))")
      discard strictErrorCompile(declarations &
        "(fn make [] ^errors [AssertionError] (new " & typ & "))")
      discard strictErrorCompile(declarations &
        "(fn make [] ^errors [] (try (new " & typ & ") catch AssertionError nil))")
      # Direct data construction never invokes the custom ctor or its defaults.
      discard strictErrorCompile(declarations & "(fn direct [] ^errors [] (" & typ & "))")

  test "an unannotated protocol default does not bound overriding impl errors":
    let body = """
      (protocol P (message value [] : Int 1))
      (type Receiver ^props {})
      (impl P for Receiver (message value [] : Int ($assert false) 1))
      ((Receiver) .P:value)
    """
    expect GeneError:
      discard strictErrorCompile("(fn work [] ^errors [] " & body & ")")
    discard strictErrorCompile("(fn work [] ^errors [Error] " & body & ")")

  test "a nominal parameter does not fix an unannotated override target":
    let body = """
      (type Parent ^props {} (message value [] : Int 1))
      (type Child : Parent ^props {}
        (message value [] : Int ^^override ($assert false) 1))
      (let receiver : Parent (Child))
      (receiver .value)
    """
    expect GeneError:
      discard strictErrorCompile("(fn work [] ^errors [] " & body & ")")
    discard strictErrorCompile("(fn work [] ^errors [Error] " & body & ")")

  test "inherited direct messages retain declaration-bound Self error rows":
    let source = """
      (type Problem ^props {^message Str}
        (impl Error)
        (message raise [] : Nil ^errors [Self] (fail self)))
      (type Specific : Problem ^props {})
      (fn propagate [] : Nil ^errors [Problem]
        ((Specific ^message "specific") .raise))
      (fn recover [] : Str ^errors []
        (try (propagate) "wrong" catch Problem $err_msg))
    """
    discard strictErrorCompile(source)
    check run(strictErrorCompile(source & "(recover)"),
              newGlobalScope(newApplication())).strVal == "specific"

  test "task creation is separate from awaiting its failure":
    discard strictErrorCompile("(fn create [] ^errors [] " &
      "(spawn ($assert false)))")
    expect GeneError:
      discard strictErrorCompile("(fn consume [task : (Task Any AssertionError)] " &
        "^errors [] (await task))")
    discard strictErrorCompile("(fn consume [task : (Task Any AssertionError)] " &
      "^errors [RuntimeError] (try (await task) catch AssertionError nil))")
    expect GeneError:
      discard strictErrorCompile("(fn consume [task : (Task Any Never)] " &
        "^errors [] (await task))")

  test "await state follows aliases and conditional consumption":
    for body in [
        "(let task (spawn 1)) (await task) (await task)",
        "(let task (spawn 1)) (let alias task) (await alias) (await task)",
        "(let task (spawn 1)) (if flag (await task)) (await task)",
        "(let task (spawn 1)) (repeat 2 (await task))"]:
      expect GeneError:
        discard strictErrorCompile("(fn invalid [flag : Bool] ^errors [] " & body & ")")
    check run(strictErrorCompile("""
      (fn valid [] ^errors [] (let task (spawn 7)) (await task))
      (valid)
    """), newGlobalScope(newApplication())).intVal == 7
    check run(strictErrorCompile("""
      (fn repeat_await [] ^errors [RuntimeError]
        (let task (spawn 1)) (await task) (await task))
      (try (repeat_await) catch RuntimeError true)
    """), newGlobalScope(newApplication())).boolVal
    check run(strictErrorCompile("""
      (fn independent [] ^errors []
        (let first (spawn 1))
        (let second (spawn 2))
        (+ (await first) (await second)))
      (independent)
    """), newGlobalScope(newApplication())).intVal == 3
    check run(strictErrorCompile("""
      (fn fresh_each_time [] ^errors []
        (try (scope (repeat 3 (let task (spawn 1)) (await task)))
          catch RuntimeError nil) 7)
      (fresh_each_time)
    """), newGlobalScope(newApplication())).intVal == 7
    expect GeneError:
      discard strictErrorCompile("""
        (fn consume [task : (Task Int Never)] ^errors [RuntimeError] (await task))
        (fn invalid [] ^errors []
          (let task (spawn 1))
          (try (consume task) catch RuntimeError nil)
          (await task))
      """)

  test "opaque evaluation invalidates task freshness even when its errors are caught":
    expect GeneError:
      discard strictErrorCompile("""
        (fn invalid [] ^errors []
          (let task (spawn 1))
          (try (eval (quote (await task)) ^in (env)) catch Error nil)
          (await task))
      """)
    check run(strictErrorCompile("""
      (fn consume [] ^errors [RuntimeError]
        (let task (spawn 1))
        (try (eval (quote (await task)) ^in (env)) catch Error nil)
        (await task))
      (try (consume) catch RuntimeError true)
    """), newGlobalScope(newApplication())).boolVal

  test "nested task code cannot hide consumption of a captured task":
    for body in [
        "(try (await first) catch Error nil)",
        "(try 1 ensure (try (await first) catch Error nil))",
        "(try ($assert false) catch AssertionError (try (await first) catch Error nil))",
        "(match true (when true (try (await first) catch Error nil)) (else nil))",
        "(spawn (try (await first) catch Error nil))"]:
      checkpoint body
      expect GeneError:
        discard strictErrorCompile("""
          (fn invalid [] ^errors []
            (let first (spawn 1))
            (let second (spawn BODY))
            (await second)
            (await first))
        """.replace("BODY", body))

  test "catch and ensure paths preserve actual task consumption obligations":
    check run(strictErrorCompile("""
      (fn valid [] ^errors []
        (let task (spawn ($assert false)))
        (try ($assert false) (await task) catch AssertionError nil)
        (try (await task) catch AssertionError 7))
      (valid)
    """), newGlobalScope(newApplication())).intVal == 7
    for body in [
        "(try (await task) catch AssertionError nil)",
        "(try ($assert false) catch AssertionError (try (await task) catch Error nil))",
        "(try 1 ensure (try (await task) catch Error nil))"]:
      checkpoint body
      check run(strictErrorCompile("""
        (fn valid [] ^errors []
          (let task (spawn ($assert false))) BODY 7)
        (valid)
      """.replace("BODY", body)), newGlobalScope(newApplication())).intVal == 7
      expect GeneError:
        discard strictErrorCompile("""
          (fn invalid [] ^errors []
            (let task (spawn ($assert false))) BODY
            (try (await task) catch AssertionError nil))
        """.replace("BODY", body))

  test "match branches preserve task identity and possible consumption":
    for branch in ["(when true (await task)) (else nil)",
                   "(when true nil) (else (await task))"]:
      expect GeneError:
        discard strictErrorCompile("""
          (fn invalid [flag : Bool] ^errors []
            (let task (spawn 1))
            (match flag BRANCH)
            (await task))
        """.replace("BRANCH", branch))
    check run(strictErrorCompile("""
      (fn valid [flag : Bool] ^errors []
        (let task (spawn 7))
        (match flag (when true 1) (else 2))
        (await task))
      (valid true)
    """), newGlobalScope(newApplication())).intVal == 7

  test "scope waiting does not consume or propagate child outcomes":
    expect GeneError:
      discard strictErrorCompile("(fn work [] ^errors [] (scope (spawn ($assert false)) nil))")
    check run(strictErrorCompile("""
      (fn work [] ^errors [RuntimeError]
        (scope (spawn ($assert false)) 7))
      (try (work) catch RuntimeError 0)
    """), newGlobalScope(newApplication())).intVal == 7
    check run(strictErrorCompile("""
      (fn work [] ^errors [RuntimeError]
        (let task (scope (spawn ($assert false))))
        (try (await task) catch AssertionError 7))
      (try (work) catch RuntimeError 0)
    """), newGlobalScope(newApplication())).intVal == 7

suite "errors — module summaries":
  proc errorModuleRoot(): string =
    result = getCurrentDir() / "tmp" / "error_module_tests"
    createDir(result)

  test "a strict caller infers a dynamic dependency without changing its policy":
    let root = errorModuleRoot()
    writeFile(root / "dep.gene", """
      (type ConfigError ^props {^message Str})
      (impl Error for ConfigError)
      (fn decode ^private true [] (fail (ConfigError ^message "dependency")))
      (fn load [] (decode))
    """)
    writeFile(root / "good.gene", """
      (mod good ^errors_mode strict)
      (import [load ConfigError] from "./dep.gene")
      (fn main [] ^errors [] (try (load) catch ConfigError nil))
    """)
    writeFile(root / "bad.gene", """
      (mod bad ^errors_mode strict)
      (import [load] from "./dep.gene")
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
      (if ($runtime/callable? 1) ($assert false) nil)
      (fn value [] 1)
    """)
    writeFile(root / "initialization.gene", """
      (mod initialization ^errors_mode strict)
      (import [value] from "./fallible.gene")
      (fn main [] ^errors [] (value))
    """)
    for warm in [false, true]:
      let app = newApplication(root)
      if warm: discard app.loadFileModule(root / "fallible.gene")
      expect GeneError: discard app.compileFileModule(root / "initialization.gene")

  test "imported types publish constructor invocation contracts":
    let root = errorModuleRoot()
    writeFile(root / "constructors.gene", """
      (type Resource ^props {}
        (ctor [ready = ($assert false "not ready")]
          ^errors [AssertionError] nil))
      (type Plain ^props {})
    """)
    writeFile(root / "constructors_good.gene", """
      (mod good ^errors_mode strict)
      (import [Resource Plain] from "./constructors.gene")
      (fn make [] ^errors [AssertionError] (new Resource))
      (fn plain [] ^errors [] (Plain))
    """)
    writeFile(root / "constructors_bad.gene", """
      (mod bad ^errors_mode strict)
      (import [Resource] from "./constructors.gene")
      (fn make [] ^errors [] (new Resource))
    """)
    let app = newApplication(root)
    discard app.loadFileModule(root / "constructors_good.gene")
    expect GeneError: discard app.compileFileModule(root / "constructors_bad.gene")

  test "imports preserve direct inherited and protocol message contracts":
    let root = errorModuleRoot()
    writeFile(root / "messages.gene", """
      (type Failure ^props {^message Str})
      (impl Error for Failure)
      (type Base ^props {}
        (message label [] : Str ^errors [] "base")
        (message copy [] : Self ^errors [] self)
        (message query [value : Str = (fail (Failure ^message "default"))]
          : Str ^errors [Failure] value))
      (type Child : Base ^props {})
      (protocol P (message value [] : Str ^errors [Failure]))
      (protocol Left ^inherit [P])
      (protocol Right ^inherit [P])
      (protocol Diamond ^inherit [Left Right])
      (type Box ^props {})
      (impl Diamond for Box
        (message value [] : Str ^errors [Failure]
          (fail (Failure ^message "protocol"))))
    """)
    writeFile(root / "messages_good.gene", """
      (mod good ^errors_mode strict)
      (import [Child Box Diamond Failure] from "./messages.gene")
      (fn label [] : Str ^errors [] ((Child) .label))
      (fn copy_label [child : Child] : Str ^errors [] ((child .copy) .label))
      (fn query [child : Child] : Str ^errors [Failure] (child .query))
      (fn recover [] : Str ^errors []
        (try ((Box) .Diamond:value) catch Failure $err_msg))
    """)
    writeFile(root / "messages_bad.gene", """
      (mod bad ^errors_mode strict)
      (import [Box Diamond] from "./messages.gene")
      (fn unchecked [] : Str ^errors [] ((Box) .Diamond:value))
    """)
    writeFile(root / "messages_default_bad.gene", """
      (mod bad ^errors_mode strict)
      (import [Child] from "./messages.gene")
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
      (type Original ^props {^message Str})
      (impl Error for Original)
      (fn produce [] : Nil ^errors [Original] (fail (Original ^message "renamed")))
    """)
    writeFile(root / "renamed_client.gene", """
      (mod renamed ^errors_mode strict)
      (import [Original : Expected produce] from "./renamed_provider.gene")
      (fn helper ^private true [] (produce))
      (fn run [] : Str ^errors []
        (try (helper) "wrong" catch Expected $err_msg))
    """)
    let app = newApplication(root)
    let module = app.loadFileModule(root / "renamed_client.gene")
    check run(compileSource("(run)", useLocalSlots = false),
              module.moduleRootNamespace.nsScope).strVal == "renamed"

  test "compiled interfaces round-trip message rows and declaring Self":
    let source = """
      (mod library ^errors_mode strict)
      (type Failure ^props {^message Str})
      (impl Error for Failure)
      (protocol P (message check [] : Int ^errors [Failure]))
      (type Base ^props {} (message same [] : Self ^errors [] self))
      (type Child : Base ^props {})
      (fn ready [] : Bool ^errors [] (not false))
      (fn factory ^private true [] (fn [] ^errors [] 1))
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
      (import [Own] from "./protocol_names.gene")
      (protocol Child ^inherit [Own])
      (fn read [receiver : Child] : Int ^errors [] (receiver .Own:value))
    """)
    writeFile(root / "protocol_names_bad.gene", """
      (mod bad ^errors_mode strict)
      (import [Own] from "./protocol_names.gene")
      (protocol Child ^inherit [Own])
      (fn read [receiver : Child] : Int ^errors [] (receiver .Child:value))
    """)
    let app = newApplication(root)
    discard app.compileFileModule(root / "protocol_names_good.gene")
    expect GeneError: discard app.compileFileModule(root / "protocol_names_bad.gene")

  test "Error inheritance and exported aliases preserve the builtin contract":
    discard strictErrorCompile("""
      (protocol Detailed ^inherit [Error] (message code [] : Int ^errors []))
      (fn text [error : Detailed] : Str ^errors [] (error .Detailed:message))
    """)
    let root = errorModuleRoot()
    writeFile(root / "error_alias.gene", "(alias AllErrors Error)")
    writeFile(root / "error_alias_client.gene", """
      (mod aliases ^errors_mode strict)
      (import [AllErrors] from "./error_alias.gene")
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
      (import [exported] from "./checked_value.gene")
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
          (fn factory ^private true [] 1)
          (fn client [] ^errors [] EXPRESSION)
        """.replace("EXPRESSION", expression))
    expect GeneError:
      discard strictErrorCompile("""
        (fn factory ^private true [] [1])
        (fn client [] ^errors [] ($into (factory) []))
      """)
    let app = newApplication()
    let scope = newGlobalScope(app)
    check run(strictErrorCompile("""
      (fn factory ^private true [] : Int 1)
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
      (fn factory ^private true [] $assert)
      (fn client [] ^errors []
        (try ((factory) true) catch AssertionError nil))
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
      (fn factory ^private true [] Item)
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
        (fn factory ^private true [] (type Local : Base ^props {}) Local)
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
      (fn factory ^private true [] P:value)
      (fn client [] ^errors [MessageError] ((factory) (Item)))
      (fn saved [] ^errors [MessageError] (let held (factory)) (held (Item)))
      (fn sent [] ^errors [MessageError] (let held (factory)) ((Item) .%held))
      (fn absent [] ^errors [MessageError RuntimeError] ((factory)))
      (fn mismatch [] ^errors [MessageError] ((factory) 1))
    """), scope)
    check run(compileSource("(client)"), scope).intVal == 7
    check run(compileSource("[(saved) (sent)]"), scope).print() == "[7 7]"
    check run(compileSource("(try (absent) catch RuntimeError true)"), scope).boolVal
    check run(compileSource("(try (mismatch) catch MessageError true)"), scope).boolVal
    let replacement = run(strictErrorCompile("""
      (protocol Q (message value [] : Int ^errors []))
      (fn [] Q:value)
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)
    check run(compileSource("(client)"), scope).intVal == 7

  test "bound message dispatch errors are distinct from implementation rows":
    expect GeneError:
      discard strictErrorCompile("""
        (protocol P (message value [] : Int ^errors []))
        (fn invalid [] ^errors [] (let held P:value) (held 1))
      """)
    check run(strictErrorCompile("""
      (fn factory ^private true [] Error:message)
      (fn text [error : Error] : Str ^errors [MessageError] ((factory) error))
      (try (text (AssertionError ^message "bound error")) catch MessageError "wrong")
    """), newGlobalScope(newApplication())).strVal == "bound error"

  test "inferred returned callable contracts reject broadening before publication":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^private true [] (fn [] ^errors [] 1))
      (fn client [] ^errors [] ((factory)))
    """), scope)
    let broader = run(compileSource("""
      (fn [] ^errors [] (fn [] ^errors [AssertionError] ($assert false)))
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", broader)
    check run(compileSource("(client)"), scope).intVal == 1
    let checkedBroader = run(strictErrorCompile("""
      (fn [] ^errors [] (fn [] ^errors [AssertionError] ($assert false)))
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
        (fn callback ^private true [] 1)
        (fn helper ^private true [] (fn [] ^errors [] 1))
        (fn factory ^private true [] BODY)
        (fn client [] ^errors [] ((factory)))
      """.replace("BODY", body)), scope)
      let widerHelper = run(strictErrorCompile("""
        (fn [] (fn [] ^errors [AssertionError] ($assert false)))
      """), newGlobalScope(app))
      let widerCallback = run(compileSource("(fn [] ^errors [AssertionError] ($assert false))"),
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
        (fn factory ^private true [] INITIAL)
        (fn client [] ^errors [] CONSUME)
      """.replace("INITIAL", initial).replace("CONSUME", consume)), scope)
      let changed = if kind == "task": "(spawn ($assert false))"
                    else: "($map ($to_stream [1]) (fn [x] ^errors [AssertionError] ($assert false)))"
      let replacement = run(strictErrorCompile("(fn [] " & changed & ")"), newGlobalScope(app))
      expect GeneError: scope.assign("factory", replacement)
      check run(compileSource("(client)"), scope).print() == (if kind == "task": "1" else: "[1]")

  test "a factory cannot replace a fresh task result with an already-awaited task":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^private true [] (spawn 1))
      (fn client [] ^errors [] (await (factory)))
    """), scope)
    let replacement = run(strictErrorCompile("""
      (fn [] (let task (spawn 1)) (await task) task)
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)
    check run(compileSource("(client)"), scope).intVal == 1

  test "task freshness is retained through forwarding factories":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn helper ^private true [] (spawn 1))
      (fn factory ^private true [] (helper))
      (fn client [] ^errors [] (await (factory)))
    """), scope)
    let replacement = run(strictErrorCompile("""
      (fn [] (let task (spawn 1)) (await task) task)
    """), newGlobalScope(app))
    expect GeneError: scope.assign("helper", replacement)
    check run(compileSource("(client)"), scope).intVal == 1

  test "lazy adapters retain source and callback assumptions until consumption":
    for wrap in ["($map (factory) callback)", "(forward)",
                 "($map ($map (factory) callback) callback)"]:
      let app = newApplication()
      let scope = newGlobalScope(app)
      discard run(strictErrorCompile("""
        (fn factory ^private true [] ($to_stream [1]))
        (fn callback ^private true [value] value)
        (fn forward ^private true [] ($map (factory) callback))
        (fn client [] ^errors [] ($into SOURCE []))
      """.replace("SOURCE", wrap)), scope)
      let broader = run(compileSource("(fn [value] ^errors [AssertionError] ($assert false))"),
                        newGlobalScope(app))
      expect GeneError: scope.assign("callback", broader)
      let widerStream = run(strictErrorCompile("""
        (fn [] ($map ($to_stream [1])
          (fn [x] ^errors [AssertionError] ($assert false))))
      """), newGlobalScope(app))
      expect GeneError: scope.assign("factory", widerStream)
      check run(compileSource("(client)"), scope).print() == "[1]"

  test "lazy creation preserves stream classification without consuming producer errors":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^private true [] ($to_stream [1]))
      (fn callback [value] ^errors [AssertionError] ($assert false))
      (fn ignore [] ^errors [] ($map ($map (factory) callback) callback) nil)
    """), scope)
    let stream = run(strictErrorCompile("""
      (fn [] ($map ($to_stream [1])
        (fn [x] ^errors [AssertionError] ($assert false))))
    """), newGlobalScope(app))
    scope.assign("factory", stream)
    check run(compileSource("(ignore)"), scope).kind == vkNil
    let eager = run(strictErrorCompile("(fn [] [1])"), newGlobalScope(app))
    expect GeneError: scope.assign("factory", eager)

  test "a compatible factory replacement protects its new inferred sources":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^private true [] (fn [] ^errors [] 1))
      (fn client [] ^errors [] ((factory)))
    """), scope)
    let replacementScope = newGlobalScope(app)
    let replacement = run(strictErrorCompile("""
      (fn callback ^private true [] 2)
      (fn [] callback)
    """), replacementScope)
    scope.assign("factory", replacement)
    let wider = run(compileSource("(fn [] ^errors [AssertionError] ($assert false))"),
                    newGlobalScope(app))
    expect GeneError: replacementScope.assign("callback", wider)
    check run(compileSource("(client)"), scope).intVal == 2
    let unguarded = run(compileSource("""
      (fn callback ^private true [] 3)
      (fn [] callback)
    """, errorsMode = "warn"), newGlobalScope(app))
    expect GeneError: scope.assign("factory", unguarded)

  test "unused factory results do not create returned-callable assumptions":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^private true [] (fn [] ^errors [] 1))
      (fn client [] ^errors [] (factory) 7)
    """), scope)
    let replacement = run(compileSource("""
      (fn [] ^errors [] (fn [] ^errors [AssertionError] ($assert false)))
    """), newGlobalScope(app))
    scope.assign("factory", replacement)
    check run(compileSource("(client)"), scope).intVal == 7

  test "nested factory results keep each consumed callable contract":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^private true [] (fn [] ^errors [] (fn [] ^errors [] 1)))
      (fn client [] ^errors [] (((factory))))
    """), scope)
    let replacement = run(strictErrorCompile("""
      (fn [] (fn [] ^errors [] (fn [] ^errors [AssertionError] ($assert false))))
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)
    check run(compileSource("(client)"), scope).intVal == 1

  test "inferred return paths survive annotations on intermediate callables":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^private true []
        (fn [] : (Callable [] Any ^errors []) ^errors []
          (fn [] ^errors [] 1)))
      (fn client [] ^errors [] (((factory))))
    """), scope)
    let replacement = run(strictErrorCompile("""
      (fn [] (fn [] : (Callable [] Any ^errors [AssertionError]) ^errors []
        (fn [] ^errors [AssertionError] ($assert false))))
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)
    check run(compileSource("(client)"), scope).intVal == 1

  test "branches returning named callbacks retain both source bindings":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn first ^private true [] ^errors [] 1)
      (fn second ^private true [] ^errors [] 2)
      (fn factory ^private true [flag : Bool] (if flag first second))
      (fn client [flag : Bool] ^errors [] ((factory flag)))
    """), scope)
    let replacement = run(compileSource("(fn [] ^errors [AssertionError] ($assert false))"),
                          newGlobalScope(app))
    expect GeneError: scope.assign("second", replacement)
    check run(compileSource("[(client true) (client false)]"), scope).print() == "[1 2]"

  test "branches returning checked callbacks retain their combined contract":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn factory ^private true [flag : Bool]
        (if flag (fn [] ^errors [] 1) (fn [] ^errors [] 2)))
      (fn client [flag : Bool] ^errors [] ((factory flag)))
    """), scope)
    let replacement = run(strictErrorCompile("""
      (fn [flag : Bool]
        (if flag (fn [] ^errors [] 1)
          (fn [] ^errors [AssertionError] ($assert false))))
    """), newGlobalScope(app))
    expect GeneError: scope.assign("factory", replacement)
    check run(compileSource("[(client true) (client false)]"), scope).print() == "[1 2]"

  test "eager collection callbacks retain their inferred error dependencies":
    let app = newApplication()
    let scope = newGlobalScope(app)
    discard run(strictErrorCompile("""
      (fn callback ^private true [value] value)
      (fn mapped [] ^errors [] ($map [1] callback))
    """), scope)
    let broader = run(compileSource("(fn [value] ^errors [AssertionError] ($assert false))"),
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
      check error.errVal.head.typeName == "ErrorContractViolation"
      check "requires revalidation" in error.errVal.props["cause"].props["message"].strVal
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
        (try (trigger) catch Error nil)
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
        (try (trigger) catch Error nil)
        (helper))
    """), scope)
    check run(compileSource("(helper)", useLocalSlots = false), namespace.nsScope).intVal == 1
    namespace.nsScope.assign("helper", gradualErrorEval("(fn [] ^errors [Error] 2)"))

  test "a retained Error formatter survives sandbox generation release":
    let root = getCurrentDir() / "tmp" / "error_generation_release"
    createDir(root)
    writeFile(root / "plugin.gene", """
      (type Local ^props {^code Int})
      (impl Error for Local (message message [] : Str ^errors [] "retained generation"))
      (fn raise_error [] ^errors [Error] (fail (Local ^code 7)))
    """)
    let app = newApplication(root)
    app.setRootCapabilities(newCapabilityContext(@(app.rootCapabilities.grants) &
      @[app.filesystemCapabilities.grantReadWriteDir(root)]))
    let scope = newGlobalScope(app)
    let program = """
      (var tx ($runtime/sandbox_transaction))
      (var generation (tx .prepare {^dir DIR ^entry "plugin.gene" ^grants [] ^shared []
        ^policy {^max_steps 10000 ^max_memory_mb 16 ^timeout_ms 1000}}))
      (tx .commit)
      (var plugin (generation .module))
      (var held (try (plugin/raise_error) catch Error $err))
      (generation .release)
      (set plugin nil)
      (set generation nil)
      (set tx nil)
      (try (fail held) catch Error $err_msg)
    """.replace("DIR", newStr(root).print())
    check run(compileSource(program), scope).strVal == "retained generation"

  test "retaining an error does not restore authority removed from its caller":
    let root = getCurrentDir() / "tmp" / "error_formatter_authority"
    createDir(root)
    let path = root / "message.txt"
    writeFile(path, "permitted")
    let app = newApplication(root)
    app.setRootCapabilities(newCapabilityContext(
      @[app.filesystemCapabilities.grantReadWriteDir(root)]))
    let producer = newGlobalScope(app)
    producer.implOverlayRoot = true
    let held = run(compileSource("""
      (type Local ^props {^code Int})
      (impl Error for Local
        (message message [] : Str ^errors [] ($fs/read_text PATH)))
      (try (fail (Local ^code 7)) catch Error $err)
    """.replace("PATH", newStr(path).print())), producer)
    producer.define("held", held)
    try:
      check run(compileSource("(try (fail held) catch Error $err_msg)"), producer).strVal == "permitted"
    except GeneError as error:
      checkpoint error.errVal.print()
      raise
    let restricted = newGlobalScope(app)
    restricted.evalCapabilityCeiling = newCapabilityContext()
    restricted.define("held", held)
    let rejected = run(compileSource("""
      (try (try (fail held) catch Error $err_msg)
        catch ErrorContractViolation $err/cause)
    """), restricted)
    check rejected.head.typeName == "MissingCapability"

  test "removing a canonical provider rejects publication until the caller is released":
    let root = getCurrentDir() / "tmp" / "error_provider_removal"
    createDir(root)
    writeFile(root / "protocol.gene", "(protocol P (message value [] : Int ^errors []))")
    writeFile(root / "provider.gene", """
      (import [P] from "./protocol.gene")
      (type Item ^props {})
      (impl P for Item (message value [] : Int ^errors [] 1))
      (fn make [] (Item))
    """)
    writeFile(root / "client.gene", """
      (mod client ^errors_mode strict)
      (import [P] from "./protocol.gene")
      (import * : provider from "./provider.gene")
      (fn invoke [item : P] : Int ^errors [] (item .P:value))
    """)
    let app = newApplication(root)
    let loaded = app.loadFileModule(root / "client.gene")
    let scope = loaded.moduleRootNamespace.nsScope
    let value = run(compileSource("(provider/make)", useLocalSlots = false), scope)
    scope.define("instance", value)
    check run(compileSource("(invoke instance)", useLocalSlots = false), scope).intVal == 1
    writeFile(root / "provider.gene", """
      (import [P] from "./protocol.gene")
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
      (import [P] from "./contract.gene")
      (fn invoke [item : P] : Int ^errors [] (item .P:value))
    """)
    writeFile(pluginDir / "main.gene", """
      (import [P] from "../contract.gene")
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
        ^policy {^max_steps 10000 ^max_memory_mb 16 ^timeout_ms 1000}}))
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

  test "an admitted error keeps the old formatter after a scoped provider reload":
    let root = getCurrentDir() / "tmp" / "error_formatter_reload"
    createDir(root)
    writeFile(root / "model.gene", "(type Local ^props {^code Int})")
    writeFile(root / "provider.gene", """
      (import [Local] from "./model.gene")
      (impl Error for Local ^export true
        (message message [] : Str ^errors [] "old formatter"))
    """)
    let app = newApplication(root)
    let scope = newGlobalScope(app)
    let held = run(compileSource("""
      (import [Local] from "./model.gene")
      (import_impl Error for Local from "./provider.gene")
      (try (fail (Local ^code 1)) catch Error $err)
    """), scope)
    scope.define("held", held)
    writeFile(root / "provider.gene", """
      (import [Local] from "./model.gene")
      (impl Error for Local ^export true
        (message message [] : Str ^errors [] "new formatter"))
    """)
    discard app.reloadFileModule(root / "provider.gene")
    check run(compileSource("""
      [(try (fail held) catch Error $err_msg)
       (try (fail (Local ^code 2)) catch Error $err_msg)]
    """, useLocalSlots = false), scope).print() == "[\"old formatter\" \"new formatter\"]"

  test "protocol replacement is rejected before invalidating a retained caller":
    let root = getCurrentDir() / "tmp" / "error_dispatch_updates"
    createDir(root)
    writeFile(root / "model.gene", "(type Item ^props {})")
    writeFile(root / "provider.gene", """
      (import [Item] from "./model.gene")
      (protocol P (message value [] : Int ^errors []))
      (impl P for Item (message value [] : Int ^errors [] 1))
    """)
    writeFile(root / "client.gene", """
      (mod client ^errors_mode strict)
      (import [Item] from "./model.gene")
      (import [P] from "./provider.gene")
      (fn value [item : Item] : Int ^errors [] (item .P:value))
    """)
    let app = newApplication(root)
    let client = app.loadFileModule(root / "client.gene")
    let scope = client.moduleRootNamespace.nsScope
    check run(compileSource("(value (Item))", useLocalSlots = false), scope).intVal == 1
    let epoch = app.implActivationEpoch
    writeFile(root / "provider.gene", """
      (import [Item] from "./model.gene")
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
      (import [P Item] from "./model.gene")
      (impl P for Item ^export true (message value [] : Int ^errors [] 1))
    """)
    writeFile(root / "client.gene", """
      (mod client ^errors_mode strict)
      (import [P Item] from "./model.gene")
      (import_impl P for Item from "./provider.gene")
      (fn value [item : Item] : Int ^errors [] (item .P:value))
    """)
    let app = newApplication(root)
    let loaded = app.loadFileModule(root / "client.gene")
    let scope = loaded.moduleRootNamespace.nsScope
    check run(compileSource("(value (Item))", useLocalSlots = false), scope).intVal == 1
    writeFile(root / "provider.gene", """
      (import [P Item] from "./model.gene")
      (impl P for Item ^export true (message value [] : Int ^errors [] 2))
    """)
    discard app.reloadFileModule(root / "provider.gene")
    check run(compileSource("(value (Item))", useLocalSlots = false), scope).intVal == 2

  test "a replacement must preserve the returned callback's own contract":
    let scope = newGlobalScope(newApplication())
    discard run(strictErrorCompile("""
      (fn factory ^private true [] : (Callable [] Int ^errors []) ^errors []
        (fn [] : Int ^errors [] 1))
      (fn client [] : Int ^errors [] ((factory)))
    """), scope)
    let broader = gradualErrorEval("""
      (fn [] : (Callable [] Int ^errors [AssertionError]) ^errors []
        (fn [] : Int ^errors [AssertionError] ($assert false) 0))
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
        (ctor [] ^errors [AssertionError] ($assert false)))
      Replacement
    """)
    expect GeneError: scope.assign("Resource", replacement)
    check scope.lookup("Resource").typeName == "Resource"

  test "catch aliases and failed nominal types retain their identities":
    for target in ["Caught", "First"]:
      let app = newApplication()
      let scope = newGlobalScope(app)
      discard run(strictErrorCompile("""
        (type First ^props {^message Str})
        (impl Error for First)
        (type Second ^props {^message Str})
        (impl Error for Second)
        (alias Caught First)
        (fn failer ^private true [] (fail (First ^message "original")))
        (fn client [] ^errors [] (try (failer) catch Caught 7))
      """), scope)
      let replacement = run(compileSource("Second"), scope)
      expect GeneError: scope.assign(target, replacement)
      check run(compileSource("(client)"), scope).intVal == 7

  test "widening a live provider is rejected before its binding changes":
    let scope = newGlobalScope(newApplication())
    discard run(strictErrorCompile("""
      (fn provider ^private true [] ^errors [] 1)
      (fn client [] ^errors [] (provider))
    """), scope)
    let replacement = gradualErrorEval("(fn [] ^errors [AssertionError] ($assert false))")
    expect GeneError: scope.assign("provider", replacement)
    check run(compileSource("(client)", useLocalSlots = false), scope).intVal == 1
    let compatible = gradualErrorEval("(fn [] ^errors [] 2)")
    scope.assign("provider", compatible)
    check run(compileSource("(client)", useLocalSlots = false), scope).intVal == 2

  test "retained callable values keep their assumptions alive until released":
    let scope = newGlobalScope(newApplication())
    var declarationResult = run(strictErrorCompile("""
      (fn provider ^private true [] ^errors [] 1)
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
      (fn left ^private true [n : Int] ^errors [AssertionError]
        (if (== n 0) ($assert false) (right (- n 1))))
      (fn right ^private true [n : Int] ^errors [AssertionError] (left n))
      (fn main [] ^errors [] (try (left 3) catch AssertionError 7))
      (main)
    """, "7"
