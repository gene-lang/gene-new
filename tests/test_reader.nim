import gene/reader
import gene/printer
import gene/types
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
  test "big integer":        check_read("9223372036854775808", "9223372036854775808")
  test "float":              check_read("3.14",       "3.14")
  test "bool true":          check_read("true",       "true")
  test "bool false":         check_read("false",      "false")
  test "nil":                check_read("nil",        "nil")
  test "string":             check_read("\"hello\"",  "\"hello\"")
  test "string escapes":
    check_read("\"line\\n\\\"slash\\\\\"", "\"line\\n\\\"slash\\\\\"")
    check_read("\"\\u00E9\\u{1F600}\"", "\"é😀\"")

suite "reader — char literals":
  test "ASCII char":
    let v = read("'a'")
    check v.kind == vkChar
    check int32(v.charVal) == int32(ord('a'))
    check v.print() == "'a'"

  test "escaped chars":
    check int32(read("'\\n'").charVal) == int32(ord('\n'))
    check read("'\\n'").print() == "'\\n'"
    check int32(read("'\\\\'").charVal) == int32(ord('\\'))
    check read("'\\\\'").print() == "'\\\\'"
    check int32(read("'\\''").charVal) == int32(ord('\''))
    check read("'\\''").print() == "'\\''"

  test "UTF-8 scalar char":
    let v = read("'é'")
    check v.kind == vkChar
    check int32(v.charVal) == 0x00e9
    check v.print() == "'é'"

  test "Unicode escape char":
    check int32(read("'\\u00E9'").charVal) == 0x00e9
    check read("'\\u00E9'").print() == "'é'"
    check int32(read("'\\U0001F600'").charVal) == 0x1f600
    check read("'\\u{1F600}'").print() == "'😀'"

suite "reader — sugars":
  test "pipe folding":       check_read("(a; b; c)",    "(((a) b) c)")
  test "pipe slot form":
    check_read("(x; parse; (or _ default))", "(or ((x) parse) default)")
    check_read("(x; f _ y)", "(f (x) y)")
  test "pipe with flipped call":
    check_read("(xs ~ filter; ~ map f; ~ take 10)",
               "(take (map (filter xs) f) 10)")
  test "flipped call":       check_read("(x ~ f a b)", "(f x a b)")
  test "flipped standalone": check_read("(~ f a b)",   "(~ f a b)")
  test "spread":             check_read("x...",         "(... x)")
  test "bare at can be a node head":
    check_read("(@ {^line l} (x ^name n))", "(@ {^line l} (x ^name n))")
    check_read("(x @line 7)", "(x @line 7)")
  test "string interpolation":
    check_read("$\"hello ${name}\"", "($ \"hello \" name)")
    check_read("($ \"hello \" name)", "($ \"hello \" name)")

suite "reader — paths":
  test "absolute path":      check_read("/user/name",   "(select user name)")
  test "numeric selector segment": check_read("/users/0/name", "(select users 0 name)")
  test "relative path":      check_read("user/name",    "(path user name)")
  test "negative path segment": check_read("users/-1/name", "(path users -1 name)")
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
  test "empty char literal":
    expect ReadError: discard read("''")
  test "unterminated char literal":
    expect ReadError: discard read("'a")
  test "char literal with multiple Unicode scalars":
    expect ReadError: discard read("'é'")
  test "invalid Unicode char escape":
    expect ReadError: discard read("'\\uD800'")
    expect ReadError: discard read("'\\U00110000'")
  test "invalid string escape":
    expect ReadError: discard read("\"\\q\"")
    expect ReadError: discard read("\"\\uD800\"")
    expect ReadError: discard read("\"\\u{110000}\"")
  test "stray closing paren":
    expect ReadError: discard read(")")
  test "stray closing bracket":
    expect ReadError: discard read("]")
  test "stray closing brace":
    expect ReadError: discard read("}")
