import gene/reader
import gene/printer
import std/unittest

template check_read(src: string, expected: string) =
  check read(src).print() == expected

suite "reader — atoms and containers":
  test "node":               check_read("(a b c)",   "(a b c)")
  test "list":               check_read("[1 2 3]",   "[1 2 3]")
  test "map":                check_read("{^name \"Alice\" ^age 30}", "{^name \"Alice\" ^age 30}")
  test "immutable node":     check_read("#(h ^p v b)", "#(h ^p v b)")
  test "immutable list":     check_read("#[1 2 3]",  "#[1 2 3]")
  test "immutable map":      check_read("#{^a 1}",   "#{^a 1}")
  test "integer":            check_read("42",         "42")
  test "float":              check_read("3.14",       "3.14")
  test "bool true":          check_read("true",       "true")
  test "bool false":         check_read("false",      "false")
  test "nil":                check_read("nil",        "nil")
  test "string":             check_read("\"hello\"",  "\"hello\"")

suite "reader — sugars":
  test "pipe folding":       check_read("(a; b; c)",    "(((a) b) c)")
  test "flipped call":       check_read("(x ~ f a b)", "(f x a b)")
  test "flipped standalone": check_read("(~ f a b)",   "(f self a b)")
  test "spread":             check_read("x...",         "(... x)")
  test "string interpolation":
    check_read("$\"hello ${name}\"", "($ \"hello \" name)")

suite "reader — paths":
  test "absolute path":      check_read("/user/name",   "(select user name)")
  test "relative path":      check_read("user/name",    "(path user name)")
  test "path with unquote":  check_read("user/%field",  "(path user (unquote field))")
  test "qualified import path stays neutral":
    check_read("(import net/http)", "(import (path net http))")

suite "reader — unquote":
  test "unquote symbol":     check_read("%name",         "(unquote name)")
  test "unquote form":       check_read("%(label self)", "(unquote (label self))")
  test "unquote path":       check_read("%self/tag",     "(unquote (path self tag))")
  test "unquote interpolated string":
    check_read("%$\"a ${x}\"", "(unquote ($ \"a \" x))")
  test "unquote interpolated string with literal dollar":
    check_read("%$\"$${self/price}\"", "(unquote ($ \"$\" (path self price)))")

suite "reader — comments":
  test "datum comment":      check_read("(a #_ b c)",            "(a c)")
  test "block comment":      check_read("#< block ># (a b)",     "(a b)")
  test "shebang":            check_read("#!/usr/bin/env gene\n(a b)", "(a b)")

suite "reader — datum comments are spacing":
  test "discards next top-level form":
    check readAll("#_ (a) (b)").len == 1
    check readAll("#_ (a) (b)")[0].print() == "(b)"
  test "datum comment then EOF leaves no form":
    check readAll("#_ (a)").len == 0
  test "stacked datum comments discard two forms":
    let forms = readAll("#_ #_ a b c")
    check forms.len == 1
    check forms[0].print() == "c"
  test "datum comment mid-node is spacing":
    check_read("(a #_ b)", "(a)")
  test "datum comment before closing produces no synthetic value":
    check_read("(a b #_ c)", "(a b)")

suite "reader — vectors (flat token stream)":
  test "vector preserves tokens":
    check_read("[req : Request, ^color : \"red\"]",
               "[req : Request , ^ color : \"red\"]")

suite "readAll — multi-form programs":
  test "two forms":
    let forms = readAll("(a b) (c d)")
    check forms.len == 2
    check forms[0].print() == "(a b)"
    check forms[1].print() == "(c d)"
  test "three forms":
    let forms = readAll("1 2 3")
    check forms.len == 3
  test "empty source":
    check readAll("").len == 0
  test "with comments between forms":
    let forms = readAll("(a b) # comment\n(c d)")
    check forms.len == 2

suite "reader — malformed input is rejected":
  test "unclosed node":      expect ReadError: discard read("(a b")
  test "unclosed vector":    expect ReadError: discard read("[1 2")
  test "unclosed map":       expect ReadError: discard read("{^a 1")
  test "unterminated block comment":
    expect ReadError: discard read("#< open")
  test "datum comment at EOF":
    expect ReadError: discard read("#_")
  test "datum comment with no datum in node":
    expect ReadError: discard read("(a #_)")
  test "unterminated string":
    expect ReadError: discard read("\"unterminated")
  test "unterminated triple-quoted string":
    expect ReadError: discard read("\"\"\"abc")
  test "unterminated interpolation":
    expect ReadError: discard read("$\"hello ${name\"")
  test "char literal with extra chars":
    expect ReadError: discard read("'ab'")
  test "unterminated char literal":
    expect ReadError: discard read("'a")
  test "stray closing paren":
    expect ReadError: discard read(")")
  test "stray closing bracket":
    expect ReadError: discard read("]")
  test "stray closing brace":
    expect ReadError: discard read("}")
