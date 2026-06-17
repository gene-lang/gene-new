import gene/[compiler, types, vm, printer]
import std/unittest

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

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
  test "a MatchError from the body is catchable":
    ck "(try (var [a b] [1]) catch _ \"bad\")", "\"bad\""
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

suite "errors — panic":
  test "panic is not caught by try":
    expect GenePanic: discard runStr("(try (panic \"halt\") catch _ \"caught\")")
  test "panic propagates through ensure":
    expect GenePanic: discard runStr("(try (panic \"halt\") ensure 1)")
