import gene/[compiler, types, vm, printer]
import std/unittest

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

suite "errors — fail and catch":
  test "a failed value is caught and bound":
    ck "(try (fail \"boom\") catch e e)", "\"boom\""
  test "the body result is returned when nothing fails":
    ck "(try (+ 1 2) catch e \"caught\")", "3"
  test "catch by node-shape error type binds props":
    ck "(try (fail (quote (parse-error ^line 3))) catch (parse-error ^line l) l)", "3"
  test "catch clauses are tried in order, with a wildcard fallback":
    ck "(try (fail (quote (io-error ^m \"x\"))) " &
       "catch (parse-error ^line l) \"parse\" catch _ \"other\")", "\"other\""
  test "internal errors are catchable as (Error ^message ..)":
    ck "(try (/ 1 0) catch {^message m} m)", "\"division by zero\""
  test "a MatchError from the body is catchable":
    ck "(try (var [a b] [1]) catch _ \"bad\")", "\"bad\""
  test "an unmatched catch re-raises":
    expect GeneError: discard runStr("(try (fail \"x\") catch 99 \"no\")")
  test "the recovery value is returned on a caught error":
    ck "(try (fail \"x\") catch _ 7)", "7"

suite "errors — ensure":
  test "ensure runs on success":
    ck "(var log \"\") (try 42 ensure (set log \"ran\")) log", "\"ran\""
  test "ensure runs on a caught error":
    ck "(var log \"\") (try (fail \"x\") catch _ 0 ensure (set log \"ran\")) log", "\"ran\""
  test "ensure runs even when the error re-raises":
    ck "(var log \"\") (try (try (fail \"x\") ensure (set log \"ran\")) catch _ 0) log",
       "\"ran\""
  test "try returns the body value, not the ensure value":
    ck "(try 42 ensure 99)", "42"

suite "errors — panic":
  test "panic is not caught by try":
    expect GenePanic: discard runStr("(try (panic \"halt\") catch _ \"caught\")")
  test "panic propagates through ensure":
    expect GenePanic: discard runStr("(try (panic \"halt\") ensure 1)")
