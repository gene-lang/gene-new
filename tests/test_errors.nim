import gene/[compiler, types, vm, printer]
import std/unittest

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
  test "a typed failed value is caught and bound":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(try (fail (Boom ^message \"boom\")) catch e e/message)", "\"boom\""
  test "fail only raises values implementing Error":
    expect GeneError: discard runStr("(fail \"boom\")")
  test "the body result is returned when nothing fails":
    ck "(try (+ 1 2) catch e \"caught\")", "3"
  test "catch by node-shape error type binds props":
    ck "(type ParseError ^props {^line Int} ^impl [Error]) " &
       "(impl Error ParseError) " &
       "(try (fail (ParseError ^line 3)) catch (ParseError ^line l) l)", "3"
  test "catch clauses are tried in order, with a wildcard fallback":
    ck "(type ParseError ^props {^line Int} ^impl [Error]) " &
       "(impl Error ParseError) " &
       "(type IoError ^props {^m Str} ^impl [Error]) " &
       "(impl Error IoError) " &
       "(try (fail (IoError ^m \"x\")) " &
       "catch (ParseError ^line l) \"parse\" catch _ \"other\")", "\"other\""
  test "internal errors are catchable by message shape":
    ck "(try (/ 1 0) catch {^message m} m)", "\"division by zero\""
  test "a MatchError from the body is catchable by type":
    ck "(try (var [a b] [1]) catch (MatchError ^message m) m)",
       "\"destructuring pattern did not match\""
  test "an unmatched catch re-raises":
    expect GeneError:
      discard runStr("(type Boom ^props {^message Str} ^impl [Error]) " &
                     "(impl Error Boom) " &
                     "(try (fail (Boom ^message \"x\")) catch 99 \"no\")")
  test "the recovery value is returned on a caught error":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(try (fail (Boom ^message \"x\")) catch _ 7)", "7"
  test "built-in TypeError implements Error":
    ck "(try (fail (TypeError ^message \"m\" ^where \"w\" ^expected \"Int\" ^actual \"Str\")) " &
       "catch (TypeError ^message m) m)", "\"m\""
  test "built-in CompileError implements Error":
    ck "(try (fail (CompileError ^message \"bad syntax\")) " &
       "catch (CompileError ^message m) m)", "\"bad syntax\""
  test "Error marker impls apply to child error types":
    ck "(type BaseError ^props {^message Str} ^impl [Error]) " &
       "(impl Error BaseError) " &
       "(type ChildError ^is BaseError ^props {}) " &
       "(try (fail (ChildError ^message \"child\")) catch (BaseError ^message m) m)",
       "\"child\""
  test "catch pattern bindings are local to the recovery branch":
    expect GeneError:
      discard runStr("(type Boom ^props {^message Str} ^impl [Error]) " &
                     "(impl Error Boom) " &
                     "(try (fail (Boom ^message \"x\")) catch (Boom ^message m) m) " &
                     "m")
  test "catch recovery declarations are local":
    expect GeneError:
      discard runStr("(type Boom ^props {^message Str} ^impl [Error]) " &
                     "(impl Error Boom) " &
                     "(try (fail (Boom ^message \"x\")) catch _ (var recovered true) recovered) " &
                     "recovered")

suite "errors — checked rows":
  test "functions may raise declared errors":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(fn raise-boom ^errors [Boom] [] (fail (Boom ^message \"x\"))) " &
       "(try (raise-boom) catch (Boom ^message m) m)", "\"x\""

  test "missing error row remains dynamic":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(fn raise-boom [] (fail (Boom ^message \"x\"))) " &
       "(try (raise-boom) catch (Boom ^message m) m)", "\"x\""

  test "^errors [] rejects recoverable errors":
    expect GeneError:
      discard runStr("(type Boom ^props {^message Str} ^impl [Error]) " &
                     "(impl Error Boom) " &
                     "(fn quiet ^errors [] [] (fail (Boom ^message \"x\"))) " &
                     "(quiet)")

  test "^errors rows normalize Never and duplicates":
    ck "(fn quiet ^errors [Never] [] 1) (quiet)", "1"
    expect GeneError:
      discard runStr("(type Boom ^props {^message Str} ^impl [Error]) " &
                     "(impl Error Boom) " &
                     "(fn quiet ^errors [Never] [] (fail (Boom ^message \"x\"))) " &
                     "(quiet)")
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(fn raise-boom ^errors [Never Boom Boom] [] (fail (Boom ^message \"x\"))) " &
       "(try (raise-boom) catch (Boom ^message m) m)",
       "\"x\""

  test "undeclared recoverable errors are rejected":
    expect GeneError:
      discard runStr("(type AError ^props {^message Str} ^impl [Error]) " &
                     "(impl Error AError) " &
                     "(type BError ^props {^message Str} ^impl [Error]) " &
                     "(impl Error BError) " &
                     "(fn f ^errors [AError] [] (fail (BError ^message \"x\"))) " &
                     "(f)")

  test "^errors entries must implement Error":
    expect GeneError:
      discard runStr("(type NotError ^props {^message Str}) " &
                     "(fn f ^errors [NotError] [] 1)")

  test "impl message functions enforce checked rows":
    ck "(protocol Run (message run [self])) " &
       "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(type Job ^props {}) " &
       "(impl Run Job " &
       "  (message run ^errors [Boom] [self] (fail (Boom ^message \"x\")))) " &
       "(try (run (Job)) catch (Boom ^message m) m)", "\"x\""

  test "checked rows can declare built-in MatchError":
    ck "(fn first-two ^errors [MatchError] [xs] (var [a b] xs) a) " &
       "(try (first-two [1]) catch (MatchError ^message m) m)",
       "\"destructuring pattern did not match\""

  test "checked rows can declare built-in CompileError":
    ck "(fn bad ^errors [CompileError] [] (fail (CompileError ^message \"compile\"))) " &
       "(try (bad) catch (CompileError ^message m) m)", "\"compile\""

  test "^effects is reserved":
    expect GeneError:
      discard compileSource("(fn f ^effects [fs] [] 1)")
    expect GeneError:
      discard compileSource("(protocol Run " &
                            "  (message run ^effects [fs] [self]))")
    expect GeneError:
      discard compileSource("(protocol Run (message run [self])) " &
                            "(impl Run Job " &
                            "  (message run ^effects [fs] [self] 1))")

suite "errors — ensure":
  test "ensure runs on success":
    ck "(var log \"\") (try 42 ensure (set log \"ran\")) log", "\"ran\""
  test "ensure runs on a caught error":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var log \"\") (try (fail (Boom ^message \"x\")) catch _ 0 " &
       "ensure (set log \"ran\")) log", "\"ran\""
  test "ensure runs even when the error re-raises":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var log \"\") " &
       "(try (try (fail (Boom ^message \"x\")) ensure (set log \"ran\")) catch _ 0) log",
       "\"ran\""
  test "try returns the body value, not the ensure value":
    ck "(try 42 ensure 99)", "42"
  test "nested ensures run inner-first as an error re-raises":
    # An ordering counter: the inner ensure stamps 1, the outer stamps 2.
    ck "(type Boom ^props {^message Str} ^impl [Error]) (impl Error Boom) " &
       "(var n 0) (var i 0) (var o 0) " &
       "(try (try (try (fail (Boom ^message \"x\")) " &
       "               ensure (do (set n (+ n 1)) (set i n))) " &
       "          ensure (do (set n (+ n 1)) (set o n))) catch _ 0) [i o]", "[1 2]"
  test "the catch value survives the ensure that runs after it":
    ck "(type Boom ^props {^message Str} ^impl [Error]) (impl Error Boom) " &
       "(var ran 0) " &
       "(var r (try (fail (Boom ^message \"x\")) catch _ 7 ensure (set ran 1))) " &
       "[r ran]", "[7 1]"
  test "cancellation is not caught but still runs ensure":
    cancellationEnsureRan = false
    let scope = newGlobalScope()
    scope.define("mark-cancellation-ensure",
                 newNativeFn("mark-cancellation-ensure", markCancellationEnsure))
    expect GeneCancel:
      discard run(compileSource("(scope (var ch (channel ^capacity 1)) " &
                                "  (var t (spawn (ch ~ Channel/recv))) " &
                                "  (t ~ Task/cancel) " &
                                "  (try (await t) catch _ \"caught\" " &
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
      discard run(compileSource("(scope (var ch (channel ^capacity 1)) " &
                                "  (var t (spawn " &
                                "    (try (ch ~ Channel/recv) " &
                                "         ensure " &
                                "           (mark-child-cancellation-ensure)))) " &
                                "  (sleep 1) " &
                                "  (t ~ Task/cancel) " &
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
      discard run(compileSource("(scope (var ch (channel ^capacity 1)) " &
                                "  (var t : (Task Int Never) " &
                                "    (spawn " &
                                "      (try (ch ~ Channel/recv) " &
                                "           ensure " &
                                "             (mark-child-cancellation-ensure)))) " &
                                "  (sleep 1) " &
                                "  (t ~ Task/cancel) " &
                                "  (await t))"),
                  scope)
    check childCancellationEnsureRan

suite "errors — try on the frame stack":
  test "deep recursion through a try-wrapped function does not overflow":
    # Each level used to start a nested runLoop for the try body and overflow the
    # Nim stack in the low hundreds; the try body now runs as a heap Frame.
    ck "(fn f [n] (try (if (= n 0) 0 (+ 1 (f (- n 1)))) catch _ -1)) (f 200000)",
       "200000"
  test "an inner try catches before the enclosing ^errors boundary applies":
    # The undeclared error is caught by the function's own inner try, so the
    # ^errors row never sees it — the function returns normally.
    ck "(type Boom ^props {^message Str} ^impl [Error]) (impl Error Boom) " &
       "(fn quiet ^errors [] [] (try (fail (Boom ^message \"x\")) catch _ 42)) " &
       "(quiet)", "42"
  test "an error escaping an inner try still hits the ^errors boundary":
    # No catch matches inside quiet, so the undeclared error escapes the function
    # body and the ^errors [] boundary rejects it.
    expect GeneError:
      discard runStr("(type Boom ^props {^message Str} ^impl [Error]) (impl Error Boom) " &
                     "(fn quiet ^errors [] [] (try (fail (Boom ^message \"x\")) ensure 1)) " &
                     "(quiet)")
  test "an error raised in a catch body unwinds to the enclosing try":
    ck "(type A ^props {^message Str} ^impl [Error]) (impl Error A) " &
       "(type B ^props {^message Str} ^impl [Error]) (impl Error B) " &
       "(try (try (fail (A ^message \"a\")) catch (A) (fail (B ^message \"b\"))) " &
       "     catch (B ^message m) m)", "\"b\""
  test "an error raised in an ensure body overrides and unwinds outward":
    ck "(type A ^props {^message Str} ^impl [Error]) (impl Error A) " &
       "(try (try 5 ensure (fail (A ^message \"e\"))) catch (A ^message m) m)", "\"e\""

suite "errors — panic":
  test "panic is not caught by try":
    expect GenePanic: discard runStr("(try (panic \"halt\") catch _ \"caught\")")
  test "panic propagates through ensure":
    expect GenePanic: discard runStr("(try (panic \"halt\") ensure 1)")
  test "panic head is a special form":
    expect GenePanic:
      discard runStr("(var panic (fn [x] nil)) (panic \"halt\")")
    expect GeneError:
      discard compileSource("(panic \"x\" \"y\")")
  test "await propagates task panic outside try":
    expect GenePanic:
      discard runStr("(scope (var t (spawn (panic \"halt\"))) " &
                     "(try (await t) catch _ \"caught\"))")
