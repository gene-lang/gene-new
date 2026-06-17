## Executable Gene language surface spec.
##
## This file intentionally checks behavior from docs/design.md and
## examples/web_demo.gene at a higher level than unit tests. Run after changes:
##   nimble spec

import gene/[compiler, printer, reader, vm]
import std/[sequtils, strutils, unittest]

template check_read(src: string, expected: string) =
  check read(src).print() == expected

template check_eval(src: string, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

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

suite "spec — templates from design":
  test "quasiquote unquote builds generated nodes":
    check_eval("(var name \"Ada\") `(div %name)", "(div \"Ada\")")

  test "eval executes generated template nodes":
    check_eval("(var x 40) (eval `(+ %x 2) ^in (env))", "42")

  test "quasiquote unquote-splicing merges generated bodies":
    check_eval("(var body [(quote (p \"a\")) (quote (p \"b\"))]) `(div %body...)",
               "(div (p \"a\") (p \"b\"))")

suite "spec — strings from design":
  test "dollar interpolation calls to-str-style display conversion":
    check_eval("(var name \"Ada\") $\"hello ${name}\"", "\"hello Ada\"")
    check_eval("$\"sum = $(+ 1 2)\"", "\"sum = 3\"")

suite "spec — equality and identity from design":
  test "same question mark is scalar identity or heap identity":
    check_eval("(var xs [1]) [(= [1] [1]) (same? [1] [1]) (same? xs xs)]",
               "[true false true]")

suite "spec — protocol derive from design":
  test "protocol-local derive can generate an impl":
    check_eval("(protocol HasLabel " &
               "  (message label [self] : Str) " &
               "  (derive [t : Type, req] " &
               "    `(impl HasLabel %t " &
               "       (message label [self] : Str self/name)))) " &
               "(type MenuItem ^props {^name Str} ^derive [HasLabel]) " &
               "(label (MenuItem ^name \"Soup\"))",
               "\"Soup\"")

suite "spec — cells from design":
  test "Cell get, set, swap, and update are explicit mutation":
    check_eval("(var count (cell 0)) " &
               "[(count ~ Cell/get) " &
               " (count ~ Cell/set 10) " &
               " (count ~ Cell/swap 20) " &
               " (count ~ Cell/update (fn [x] (+ x 1))) " &
               " (count ~ Cell/get)]",
               "[0 10 10 21 21]")

suite "spec — atomic cells from design":
  test "AtomicCell load, store, swap, and compare-exchange are explicit mutation":
    check_eval("(var state (atomic-cell 0)) " &
               "[(state ~ AtomicCell/load) " &
               " (state ~ AtomicCell/store 1) " &
               " (state ~ AtomicCell/swap 2) " &
               " (state ~ AtomicCell/compare-exchange 2 3) " &
               " (state ~ AtomicCell/load)]",
               "[0 1 1 true 3]")

suite "spec — streams from design":
  test "list-backed streams expose pull operations":
    check_eval("(var s (to_stream [1 2])) " &
               "[(s ~ Stream/has_next) " &
               " (s ~ Stream/peek) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/has_next)]",
               "[true 1 1 2 false]")

  test "next on an exhausted stream raises EndOfStream":
    check_eval("(try (var s (to_stream [])) (s ~ Stream/next) " &
               "catch (EndOfStream ^message m) m)",
               "\"end of stream\"")

  test "stream helpers map, filter, take, and materialize":
    check_eval("(var s (take " &
               "  (filter " &
               "    (map (to_stream [1 2 3]) (fn [x] (+ x 1))) " &
               "    (fn [x] (> x 2))) " &
               "  2)) " &
               "[(s ~ Stream/next) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/has_next) " &
               " (into (to_pairs_stream {^a 1}) {})]",
               "[3 4 false {^a 1}]")

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
