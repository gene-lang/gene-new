## Executable Gene language surface spec.
##
## This file intentionally checks behavior from docs/design.md and
## examples/web_demo.gene at a higher level than unit tests. Run after changes:
##   nimble spec

import gene/[reader, printer]
import std/[sequtils, strutils, unittest]

template check_read(src: string, expected: string) =
  check read(src).print() == expected

suite "spec — reader surface from design":
  test "programs contain multiple top-level forms":
    let forms = readAll("(mod app) (import std/stream [map]) (fn main [] nil)")
    check forms.len == 3
    check forms[0].print() == "(mod app)"
    check forms[1].print() == "(import (path std stream) [map])"
    check forms[2].print() == "(fn main [] nil)"

  test "selector literals and context-neutral paths stay distinct":
    check_read("/user/name", "(select user name)")
    check_read("user/name", "(path user name)")
    check_read("/users/0/name", "(select users 0 name)")
    check_read("users/-1/name", "(path users -1 name)")
    check_read("(import net/http [Request])", "(import (path net http) [Request])")
    check_read("(fn f [^server : Http/Server] nil)",
               "(fn f [^ server : Http/Server] nil)")

  test "template unquote supports interpolation and dynamic paths":
    check_read("%$\"$${self/price}\"", "(unquote ($ \"$\" (path self price)))")
    check_read("`(td %$\"$${self/price}\")",
               "(quasiquote (td (unquote ($ \"$\" (path self price)))))")
    check_read("`(div %children...)", "(quasiquote (div (unquote (... children))))")

  test "datum comments are spacing, not values":
    check readAll("#_ (discarded) (kept)").len == 1
    check readAll("#_ (discarded) (kept)")[0].print() == "(kept)"
    check_read("(a #_ b c)", "(a c)")
    check_read("(a #_ b)", "(a)")

  test "malformed syntax is rejected":
    expect ReadError: discard read("(a b")
    expect ReadError: discard read(")")
    expect ReadError: discard read("$\"hello ${name\"")
    expect ReadError: discard read("'ab'")

suite "spec — web demo remains parseable":
  test "web demo parses as a module source unit":
    let forms = readAll(readFile("examples/web_demo.gene"))
    check forms.len == 35
    check forms[0].print().startsWith("(mod @doc ")
    check forms[1].print() == "(import (path net http) [Request Response serve])"
    check forms[^1].print().startsWith("(fn main ")

  test "web demo exercises selector-core examples":
    let rendered = readAll(readFile("examples/web_demo.gene")).mapIt(it.print()).join("\n")
    check "(unquote ($ \"$\" (path self price)))" in rendered
    check "(path routes (unquote to_pairs_stream))" in rendered
    check "(path req params name)" in rendered
