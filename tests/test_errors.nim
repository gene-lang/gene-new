import gene/[compiler, types, vm, printer]
import std/[strutils, unittest]

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

var cancellationEnsureRan = false
var childCancellationEnsureRan = false

proc markCancellationEnsure(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError, "mark-cancellation-ensure expects no arguments")
  cancellationEnsureRan = true
  NIL

proc markChildCancellationEnsure(args: openArray[Value]): Value {.nimcall.} =
  if args.len != 0:
    raise newException(GeneError,
      "mark-child-cancellation-ensure expects no arguments")
  childCancellationEnsureRan = true
  NIL

suite "errors — fail and catch":
  test "non-callable diagnostics name authored heads and missing namespace segments":
    ck "(try ($nope 1) catch RuntimeFault $err/.message)",
       "\"cannot call $nope: gene/nope is not defined here\""
    ck "(try ($str/nope \"a\") catch RuntimeFault $err/.message)",
       "\"cannot call $str/nope: gene/str/nope is not defined here\""
    ck "(let o {^a 1}) (try (o/b 1) catch RuntimeFault $err/.message)",
       "\"cannot call o/b: the value is nil\""
    ck "(let n 1) (try (n 2) catch RuntimeFault $err/.message)",
       "\"cannot call n: value is Int, which is not callable\""
    ck "(let datum (quote (entry))) (try (datum) catch RuntimeFault $err/.message)",
       "\"cannot call datum: value is Node, which is not callable\""
    ck "(let o {^a 1}) ($absent? o/b)", "true"

  test "call diagnostic does not repeat the callee or argument effects":
    ck "(var hits 0) " &
       "(fn absent [] (set hits (+ hits 1)) nil) " &
       "(try ((absent) (set hits (+ hits 1))) catch RuntimeFault nil) hits", "2"

  test "native calls without an authored site keep the fallback diagnostic":
    var raised = false
    try:
      discard call(newInt(1))
    except GeneError as error:
      raised = true
      check error.msg == "value is not callable: vkInt"
    check raised

  test "catch selects by type and exposes the error as $err":
    ck "(type Boom : Error) " &
       " " &
       "(type Other : Error) " &
       " " &
       "(try (fail (Boom ^_msg \"boom\")) " &
       "  catch Other \"wrong\" " &
       "  catch Boom $err/.message)", "\"boom\""

  test "a typed failed value is caught and bound":
    ck "(type Boom : Error) " &
       " " &
       "(try (fail (Boom ^_msg \"boom\")) catch Boom $err/.message)", "\"boom\""
  test "fail only raises values implementing Error":
    expect GeneError: discard runStr("(fail \"boom\")")
  test "the body result is returned when nothing fails":
    ck "(try (+ 1 2) catch Error \"caught\")", "3"
  test "catch exposes typed error properties through $err":
    ck "(type ParseError : Error ^props {^line Int} (message message [] : Str ^errors [] ^^override \"parse error\")) " &
       "" &
       "(try (fail (ParseError ^line 3)) catch ParseError $err/line)", "3"
  test "catch clauses are tried in order, with an Any fallback":
    ck "(type ParseError : Error ^props {^line Int} (message message [] : Str ^errors [] ^^override \"parse error\")) " &
       "" &
       "(type IoError : Error ^props {^m Str} (message message [] : Str ^errors [] ^^override self/m)) " &
       "" &
       "(try (fail (IoError ^m \"x\")) " &
       "catch ParseError \"parse\" catch Error \"other\")", "\"other\""
  test "a message-only internal failure is a RuntimeFault":
    ck "(try (/ 1 0) catch RuntimeFault $err/.message)", "\"division by zero\""
  test "runtime diagnostics carry RuntimeFault, which catch Error does not see":
    ck "(try undefined_name catch RuntimeFault $err/.message)",
       "\"undefined symbol: undefined_name\""
    ck "(try (try (/ 1 0) catch Error \"error\") catch Fault $err/.message)",
       "\"division by zero\""
  test "$err is captured by a function created in the catch body":
    ck "(try (/ 1 0) catch RuntimeFault " &
       "  (var message (fn [] $err/.message)) (message))",
       "\"division by zero\""
  test "catch headers reject patterns and wildcard spelling":
    expect GeneError:
      discard compileSource("(try (/ 1 0) catch _ 0)")
    expect GeneError:
      discard compileSource("(try (/ 1 0) catch (RuntimeFault ^_msg m) m)")
  test "a MatchFault from the body is catchable by type":
    ck "(try (var [a b] [1]) catch MatchFault $err/.message)",
       "\"destructuring pattern did not match\""
  test "an unmatched catch re-raises":
    expect GeneError:
      discard runStr("(type Boom : Error) " &
                     " " &
                     "(type Other : Error) " &
                     " " &
                     "(try (fail (Boom ^_msg \"x\")) catch Other \"no\")")
  test "the recovery value is returned on a caught error":
    ck "(type Boom : Error) " &
       " " &
       "(try (fail (Boom ^_msg \"x\")) catch Error 7)", "7"
  test "built-in TypeFault implements Error":
    ck "(try (fail (TypeFault ^_msg \"m\" ^where \"w\" ^expected \"Int\" ^actual \"Str\")) " &
       "catch TypeFault $err/.message)", "\"m\""
  test "built-in CompileError implements Error":
    ck "(try (fail (CompileError ^_msg \"bad syntax\")) " &
       "catch CompileError $err/.message)", "\"bad syntax\""
  test "Error marker impls apply to child error types":
    ck "(type BaseError : Error) " &
       " " &
       "(type ChildError : BaseError ^props {}) " &
       "(try (fail (ChildError ^_msg \"child\")) catch BaseError $err/.message)",
       "\"child\""
  test "$err is local to the recovery branch":
    expect GeneError:
      discard runStr("(type Boom : Error) " &
                     " " &
                     "(try (fail (Boom ^_msg \"x\")) catch Boom $err/.message) " &
                     "$err")
  test "catch recovery declarations are local":
    expect GeneError:
      discard runStr("(type Boom : Error) " &
                     " " &
                     "(try (fail (Boom ^_msg \"x\")) catch Error (var recovered true) recovered) " &
                     "recovered")

suite "errors — checked rows":
  test "a checked row passes a RuntimeFault through and cannot name one":
    ck "(fn missing ^errors [] [] undefined_name) " &
       "(try (missing) catch RuntimeFault $err/.message)",
       "\"undefined symbol: undefined_name\""
    expect GeneError:
      discard runStr("(fn missing ^errors [RuntimeFault] [] undefined_name) (missing)")

  test "functions may raise declared errors":
    ck "(type Boom : Error) " &
       " " &
       "(fn raise-boom ^errors [Boom] [] (fail (Boom ^_msg \"x\"))) " &
       "(try (raise-boom) catch Boom $err/.message)", "\"x\""

  test "missing error row remains dynamic":
    ck "(type Boom : Error) " &
       " " &
       "(fn raise-boom [] (fail (Boom ^_msg \"x\"))) " &
       "(try (raise-boom) catch Boom $err/.message)", "\"x\""

  test "^errors [] rejects recoverable errors":
    expect GeneError:
      discard runStr("(type Boom : Error) " &
                     " " &
                     "(fn quiet ^errors [] [] (fail (Boom ^_msg \"x\"))) " &
                     "(quiet)")

  test "^errors rows normalize Never and duplicates":
    ck "(fn quiet ^errors [Never] [] 1) (quiet)", "1"
    expect GeneError:
      discard runStr("(type Boom : Error) " &
                     " " &
                     "(fn quiet ^errors [Never] [] (fail (Boom ^_msg \"x\"))) " &
                     "(quiet)")
    ck "(type Boom : Error) " &
       " " &
       "(fn raise-boom ^errors [Never Boom Boom] [] (fail (Boom ^_msg \"x\"))) " &
       "(try (raise-boom) catch Boom $err/.message)",
       "\"x\""

  test "undeclared recoverable errors are rejected":
    expect GeneError:
      discard runStr("(type AError : Error) " &
                     " " &
                     "(type BError : Error) " &
                     " " &
                     "(fn f ^errors [AError] [] (fail (BError ^_msg \"x\"))) " &
                     "(f)")

  test "^errors entries must implement Error":
    expect GeneError:
      discard runStr("(type NotError ^props {^message Str}) " &
                     "(fn f ^errors [NotError] [] 1)")

  test "impl message functions enforce checked rows":
    ck "(type Boom : Error) " &
       " " &
       "(protocol Run (message run ^errors [Boom] [self])) " &
       "(type Job ^props {}) " &
       "(impl Run for Job " &
       "  (message run ^errors [Boom] [self] (fail (Boom ^_msg \"x\")))) " &
       "(try ((Job) .Run:run) catch Boom $err/.message)", "\"x\""

  test "a checked row passes a MatchFault through and cannot name one":
    ck "(fn first-two ^errors [] [xs] (var [a b] xs) a) " &
       "(try (first-two [1]) catch MatchFault $err/.message)",
       "\"destructuring pattern did not match\""
    var message = ""
    try:
      discard runStr("(fn first-two ^errors [MatchFault] [xs] (var [a b] xs) a)")
    except GeneError as error:
      message = error.msg
    check "Fault types are unchecked" in message

  test "checked rows can declare built-in CompileError":
    ck "(fn bad ^errors [CompileError] [] (fail (CompileError ^_msg \"compile\"))) " &
       "(try (bad) catch CompileError $err/.message)", "\"compile\""

  test "^effects is reserved":
    expect GeneError:
      discard compileSource("(fn f ^effects [fs] [] 1)")
    expect GeneError:
      discard compileSource("(protocol Run " &
                            "  (message run ^effects [fs] [self]))")
    expect GeneError:
      discard compileSource("(protocol Run (message run [self])) " &
                            "(impl Run for Job " &
                            "  (message run ^effects [fs] [self] 1))")

suite "errors — ensure":
  test "ensure runs on success":
    ck "(var log \"\") (try 42 ensure (set log \"ran\")) log", "\"ran\""
  test "ensure runs on a caught error":
    ck "(type Boom : Error) " &
       " " &
       "(var log \"\") (try (fail (Boom ^_msg \"x\")) catch Error 0 " &
       "ensure (set log \"ran\")) log", "\"ran\""
  test "ensure runs even when the error re-raises":
    ck "(type Boom : Error) " &
       " " &
       "(var log \"\") " &
       "(try (try (fail (Boom ^_msg \"x\")) ensure (set log \"ran\")) catch Error 0) log",
       "\"ran\""
  test "try returns the body value, not the ensure value":
    ck "(try 42 ensure 99)", "42"
  test "nested ensures run inner-first as an error re-raises":
    # An ordering counter: the inner ensure stamps 1, the outer stamps 2.
    ck "(type Boom : Error) " &
       "(var n 0) (var i 0) (var o 0) " &
       "(try (try (try (fail (Boom ^_msg \"x\")) " &
       "               ensure (do (set n (+ n 1)) (set i n))) " &
       "          ensure (do (set n (+ n 1)) (set o n))) catch Error 0) [i o]", "[1 2]"
  test "the catch value survives the ensure that runs after it":
    ck "(type Boom : Error) " &
       "(var ran 0) " &
       "(var r (try (fail (Boom ^_msg \"x\")) catch Error 7 ensure (set ran 1))) " &
       "[r ran]", "[7 1]"
  test "cancellation is not caught but still runs ensure":
    cancellationEnsureRan = false
    let scope = newGlobalScope()
    scope.define("mark-cancellation-ensure",
                 newNativeFn("mark-cancellation-ensure", markCancellationEnsure))
    expect GeneCancel:
      discard run(compileSource("(scope (var ch ($channel ^capacity 1)) " &
                                "  (var t (spawn (ch .recv))) " &
                                "  (t .cancel) " &
                                "  (try (await t) catch Error \"caught\" " &
                                "       ensure (mark-cancellation-ensure)))"),
                  scope)
    check cancellationEnsureRan

  test "task cancellation runs child ensure before await observes cancellation":
    childCancellationEnsureRan = false
    let scope = newGlobalScope()
    scope.define("mark-child-cancellation-ensure",
                 newNativeFn("mark-child-cancellation-ensure",
                             markChildCancellationEnsure))
    expect GeneCancel:
      discard run(compileSource("(scope (var ch ($channel ^capacity 1)) " &
                                "  (var t (spawn " &
                                "    (try (ch .recv) " &
                                "         ensure " &
                                "           (mark-child-cancellation-ensure)))) " &
                                "  ($sleep 1) " &
                                "  (t .cancel) " &
                                "  (await t))"),
                  scope)
    check childCancellationEnsureRan

  test "checked task cancellation runs child ensure before await observes cancellation":
    childCancellationEnsureRan = false
    let scope = newGlobalScope()
    scope.define("mark-child-cancellation-ensure",
                 newNativeFn("mark-child-cancellation-ensure",
                             markChildCancellationEnsure))
    expect GeneCancel:
      discard run(compileSource("(scope (var ch ($channel ^capacity 1)) " &
                                "  (var t : (Task Int Never) " &
                                "    (spawn " &
                                "      (try (ch .recv) " &
                                "           ensure " &
                                "             (mark-child-cancellation-ensure)))) " &
                                "  ($sleep 1) " &
                                "  (t .cancel) " &
                                "  (await t))"),
                  scope)
    check childCancellationEnsureRan

suite "errors — try on the frame stack":
  test "deep recursion through a try-wrapped function does not overflow":
    # Each level used to start a nested runLoop for the try body and overflow the
    # Nim stack in the low hundreds; the try body now runs as a heap Frame.
    ck "(fn f [n] (try (if (== n 0) 0 else (+ 1 (f (- n 1)))) catch Error -1)) (f 200000)",
       "200000"
  test "an inner try catches before the enclosing ^errors boundary applies":
    # The undeclared error is caught by the function's own inner try, so the
    # ^errors row never sees it — the function returns normally.
    ck "(type Boom : Error) " &
       "(fn quiet ^errors [] [] (try (fail (Boom ^_msg \"x\")) catch Error 42)) " &
       "(quiet)", "42"
  test "an error escaping an inner try still hits the ^errors boundary":
    # No catch matches inside quiet, so the undeclared error escapes the function
    # body and the ^errors [] boundary rejects it.
    expect GeneError:
      discard runStr("(type Boom : Error) " &
                     "(fn quiet ^errors [] [] (try (fail (Boom ^_msg \"x\")) ensure 1)) " &
                     "(quiet)")
  test "an error raised in a catch body unwinds to the enclosing try":
    ck "(type A : Error) " &
       "(type B : Error) " &
       "(try (try (fail (A ^_msg \"a\")) catch A (fail (B ^_msg \"b\"))) " &
       "     catch B $err/.message)", "\"b\""
  test "an error raised in an ensure body overrides and unwinds outward":
    ck "(type A : Error) " &
       "(try (try 5 ensure (fail (A ^_msg \"e\"))) catch A $err/.message)", "\"e\""

proc panicked(src: string): Value =
  ## The Panic value `(panic v)` raised, which no `catch Error` saw.
  try:
    discard runStr(src)
  except GeneError as error:
    if error.hasErrVal and error.errVal.kind == vkNode and
        error.errVal.head.kind == vkType:
      return error.errVal
  NIL

suite "errors — panic":
  test "panic is a Panic fault that catch Error does not catch":
    let value = panicked("(try (panic \"halt\") catch Error \"caught\")")
    check value.kind == vkNode and value.head.typeName == "Panic"
    check value.props["_msg"].strVal == "halt"
    check value.props["value"].strVal == "halt"
  test "catch Panic, catch Fault and catch Throwable catch a panic":
    ck "[(try (panic 3) catch Panic $err/value) " &
       " (try (panic \"x\") catch Fault $err/.message) " &
       " (try (panic [1]) catch Throwable ($head $err))]", "[3 \"x\" (type Panic)]"
  test "panic propagates through ensure":
    let value = panicked("(var log []) (try (try (panic \"halt\") ensure (log .push 1)) " &
                         "catch Error nil)")
    check value.kind == vkNode and value.head.typeName == "Panic"
    ck "(var log []) (try (try (panic \"halt\") ensure (log .push 1)) " &
       "catch Panic nil) log", "[1]"
  test "panic head is a special form":
    check panicked("(panic \"halt\")").head.typeName == "Panic"
    expect GeneError:
      discard runStr("(var panic (fn [x] nil)) (panic \"halt\")")
    expect GeneError:
      discard compileSource("(panic \"x\" \"y\")")
  test "await propagates task panic outside catch Error":
    let value = panicked("(scope (var t (spawn (panic \"halt\"))) " &
                         "(try (await t) catch Error \"caught\"))")
    check value.kind == vkNode and value.head.typeName == "Panic"
