## Executable Gene language surface spec.
##
## This file intentionally checks behavior from docs/design.md and
## examples/web_demo.gene at a higher level than unit tests. Run after changes:
##   nimble spec

import gene/[compiler, printer, reader, types, vm]
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
    check_read("(~ f a)", "(~ f a)")

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

suite "spec — macros from design":
  test "template macros expand before calls":
    check_eval("(macro when! [cond, body...] " &
               "  `(if %cond (then %body...) (else nil))) " &
               "[(when! true 1) (when! false 2)]",
               "[1 nil]")
    check_eval("(macro when! [cond, body...] " &
               "  `(if %cond (then %body...) (else nil))) " &
               "(when! true (var x 1) (+ x 1))",
               "2")

  test "macro call arguments are syntax nodes":
    check_eval("(var hit 0) " &
               "(macro ignore! [ignored] 7) " &
               "[(ignore! (set hit 1)) hit]",
               "[7 0]")

  test "template macros expand in default arguments":
    check_eval("(macro seven! [] 7) (fn f [x = (seven!)] x) (f)", "7")

  test "template macros avoid introduced local capture":
    check_eval("(macro local! [x] `(do (var tmp 1) (+ tmp %x))) " &
               "(var tmp 100) [(local! 2) tmp]",
               "[3 100]")

  test "template macros avoid introduced helper capture":
    check_eval("(macro helper! [x] " &
               "  `(do (fn helper [y] (+ y 1)) (helper %x))) " &
               "(fn helper [y] 100) [(helper! 2) (helper 2)]",
               "[3 100]")
    check_eval("(macro recursive! [x] " &
               "  `(do (fn helper [n] " &
               "          (if (= n 0) 0 (helper (- n 1)))) " &
               "       (helper %x))) " &
               "(fn helper [n] 99) [(recursive! 3) (helper 3)]",
               "[0 99]")

suite "spec — strings from design":
  test "dollar interpolation calls to-str-style display conversion":
    check_eval("(var name \"Ada\") $\"hello ${name}\"", "\"hello Ada\"")
    check_eval("$\"sum = $(+ 1 2)\"", "\"sum = 3\"")

suite "spec — equality and identity from design":
  test "same question mark is scalar identity or heap identity":
    check_eval("(var xs [1]) [(= [1] [1]) (same? [1] [1]) (same? xs xs)]",
               "[true false true]")

suite "spec — numeric boundaries from design":
  test "Int has mathematical integer semantics":
    check_eval("[(+ 9223372036854775807 1) " &
               " (* 100000000000000000000 100000000000000000000) " &
               " (< 9223372036854775808 9223372036854775809)]",
               "[9223372036854775808 " &
               "10000000000000000000000000000000000000000 " &
               "true]")

  test "fixed-width integer annotations are range checked":
    check_eval("(fn byte [x : U8] x) [(byte 0) (byte 255)]", "[0 255]")
    expect GeneError:
      discard run(compileSource("(fn byte [x : U8] x) (byte 256)"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(fn small [x : I8] x) (small -129)"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(fn fixed [x : I64] x) " &
                                "(fixed 9223372036854775808)"),
                  newGlobalScope())

suite "spec — nominal types from design":
  test "child types preserve inherited field schemas":
    expect GeneError:
      discard run(compileSource("(type Animal ^props {^name Str}) " &
                                "(type Dog ^is Animal ^props {^name Any})"),
                  newGlobalScope())

suite "spec — typed variable boundaries from design":
  test "var annotations check gradual boundaries":
    check_eval("(var result : Int (eval (quote (+ 20 22)) ^in (env))) result",
               "42")
    check_eval("(try (var result : Int (eval (quote \"bad\") ^in (env))) result " &
               "catch (TypeError ^where w) w)",
               "\"var 'result'\"")
  test "set checks typed variable boundaries":
    check_eval("(var result : Int 1) (set result 42) result", "42")
    check_eval("(try (var result : Int 1) (set result \"bad\") result " &
               "catch (TypeError ^where w) w)",
               "\"set 'result'\"")
    check_eval("(try (fn f [x : Int] (set x \"bad\") x) (f 1) " &
               "catch (TypeError ^where w) w)",
               "\"set 'x'\"")
    check_eval("(try (var s : (Stream Int Never) (to_stream [1])) " &
               "     (set s (to_stream [\"bad\"])) " &
               "     (s ~ Stream/next) " &
               "catch (TypeError ^where w) w)",
               "\"Stream/next item\"")

suite "spec — generic functions from design":
  test "generic function calls infer type parameters locally":
    check_eval("(fn (identity item) [x : item] : item x) " &
               "[(identity 1) (identity \"ok\")]",
               "[1 \"ok\"]")
    check_eval("(fn (get key value) [m : (Map key value)] : value m/a) " &
               "(get {^a 9})",
               "9")
    check_eval("(fn ints [] : (Stream Int Never) (yield 7)) " &
               "(fn (first item err) [s : (Stream item err)] : item " &
               "  (s ~ Stream/next)) " &
               "(first (ints))",
               "7")

suite "spec — pattern destructuring from design":
  test "match and catch bindings are branch-local":
    expect GeneError:
      discard run(compileSource("(match [1 2] (when [a b] (+ a b))) a"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(type Boom ^props {^message Str} ^impl [Error]) " &
                                "(impl Error Boom) " &
                                "(try (fail (Boom ^message \"x\")) " &
                                "catch (Boom ^message m) m) m"),
                  newGlobalScope())
  test "alternation alternatives bind the same names":
    check_eval("(match [2 7] (when (| [1 a] [2 a]) a))", "7")
    expect GeneError:
      discard run(compileSource("(match [1] (when (| [a] [b]) a))"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(match 1 (when (not x) \"no\") (else \"ok\"))"),
                  newGlobalScope())
  test "meta patterns opt into matching meta":
    check_eval("(match (quote (x @line 7 ^name \"Ada\")) " &
               "  (when (@ {^line l} (x ^name n)) [l n]))",
               "[7 \"Ada\"]")
    check_eval("(match (quote (x @line 7 ^name \"Ada\")) " &
               "  (when (x ^name n) n))",
               "\"Ada\"")
  test "typed patterns bind and require the declared type":
    check_eval("(match \"Ada\" (when (s : Str) s) (else \"no\"))",
               "\"Ada\"")
    check_eval("(match 7 (when (s : Str) s) (else \"no\"))",
               "\"no\"")
    check_eval("(try (fn f [x : Int] x) (f \"bad\") " &
               "catch (e : TypeError) e/where)",
               "\"parameter 'x'\"")

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

  test "protocol-local derive is limited to its own impls":
    expect GeneError:
      discard run(compileSource("(protocol Other) " &
                                "(protocol HasLabel " &
                                "  (derive [t : Type, req] `(impl Other %t))) " &
                                "(type MenuItem ^props {^name Str} " &
                                "  ^derive [HasLabel])"),
                  newGlobalScope())

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

suite "spec — void normalization from design":
  test "void does not persist in prop storage":
    check_eval("[{^a void ^b 1} " &
               " (quote (x ^a void ^b 1)) " &
               " (do (type T ^props {^a? Int}) " &
               "     (var t (T ^a void)) " &
               "     t/a)]",
               "[{^b 1} (x ^b 1) void]")

suite "spec — streams from design":
  test "streams expose pull operations":
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
               " (do (var pairs (to_pairs_stream {^a 1})) " &
               "     (pairs ~ Stream/next)) " &
               " (into (to_pairs_stream {^a 1}) {})]",
               "[3 4 false [a 1] {^a 1}]")

  test "stream helpers are lazy":
    check_eval("(var hits (cell 0)) " &
               "(var s (map (to_stream [1 2]) " &
               "            (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
               "[(hits ~ Cell/get) " &
               " (s ~ Stream/next) " &
               " (hits ~ Cell/get)]",
               "[0 1 1]")

  test "yield functions return lazy streams":
    check_eval("(var hits (cell 0)) " &
               "(fn gen [] : (Stream Int Never) " &
               "  (hits ~ Cell/set 1) " &
               "  (yield 10) " &
               "  (hits ~ Cell/set 2) " &
               "  (yield 20)) " &
               "(var s (gen)) " &
               "[(hits ~ Cell/get) " &
               " (s ~ Stream/next) " &
               " (hits ~ Cell/get) " &
               " (s ~ Stream/next) " &
               " (hits ~ Cell/get) " &
               " (s ~ Stream/has_next)]",
               "[0 10 1 20 2 false]")

  test "yield skips void and resumes while loops":
    check_eval("(fn nums [] : (Stream Int Never) " &
               "  (var i 0) " &
               "  (while (< i 3) " &
               "    (yield (if (= i 1) void i)) " &
               "    (set i (+ i 1)))) " &
               "(var s (nums)) " &
               "[(s ~ Stream/next) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/has_next)]",
               "[0 2 false]")

  test "yield resumes for loops lazily":
    check_eval("(var hits (cell 0)) " &
               "(var source (map (to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
               "(fn copy [s] : (Stream Int Never) " &
               "  (for x s (yield x))) " &
               "(var out (copy source)) " &
               "[(hits ~ Cell/get) " &
               " (out ~ Stream/next) " &
               " (hits ~ Cell/get) " &
               " (out ~ Stream/next) " &
               " (hits ~ Cell/get)]",
               "[0 1 1 2 2]")

  test "typed stream boundaries check items when pulled":
    check_eval("(try (fn first [s : (Stream Int Never)] (s ~ Stream/next)) " &
               "     (first (to_stream [\"bad\"])) " &
               "catch (TypeError ^where w) w)",
               "\"Stream/next item\"")
    check_eval("(try (fn bad [] : (Stream Int Never) (yield \"bad\")) " &
               "     (var s (bad)) " &
               "     (s ~ Stream/next) " &
               "catch (TypeError ^where w) w)",
               "\"Stream/next item\"")

  test "yield is only valid inside functions":
    expect GeneError:
      discard compileSource("(yield 1)")

  test "selectors map static lookup over stream items":
    check_eval("(var users [{^name \"Ada\"} {^age 37} {^name \"Bob\"}]) " &
               "(var names users/%to_stream/name) " &
               "[(names ~ Stream/next) " &
               " (names ~ Stream/next) " &
               " (names ~ Stream/has_next)]",
               "[\"Ada\" \"Bob\" false]")

  test "declarations is an ordinary stream selector stage":
    check_eval("(ns m (var b 2) (var a 1)) " &
               "(var names m/%declarations/name) " &
               "[(names ~ Stream/next) " &
               " (names ~ Stream/next) " &
               " (names ~ Stream/has_next)]",
               "[\"a\" \"b\" false]")

  test "this-mod exposes the current module declaration stream":
    let scope = newGlobalScope()
    discard bindThisModule(scope, "spec")
    check run(compileSource("(var x 9) " &
                            "(var ds (filter (this-mod ~ Module/declarations) " &
                            "  (fn [d] (= d/name \"x\")))) " &
                            "(var decl (ds ~ Stream/next)) " &
                            "[(/value decl) (this-mod ~ Module/path)]"),
              scope).print() == "[9 nil]"

suite "spec — structured tasks from design":
  test "scope owns spawned tasks and await returns the result":
    check_eval("(scope " &
               "  (var a (spawn (+ 1 2))) " &
               "  (var b (spawn (+ 3 4))) " &
               "  (+ (await a) (await b)))",
               "10")

  test "await propagates recoverable task errors":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(scope " &
               "  (var t (spawn (fail (Boom ^message \"boom\")))) " &
               "  (try (await t) catch (Boom ^message m) m))",
               "\"boom\"")

  test "Task annotations accept task handles":
    check_eval("(scope (var t : (Task Int Never) (spawn 1)) t)", "(task)")

suite "spec — Env and eval from design":
  test "Env/extend creates a child environment":
    check_eval("(var base (env ^bindings {^x 10})) " &
               "(var child (base ~ Env/extend {^y 20})) " &
               "[(eval (quote x) ^in child) " &
               " (eval (quote y) ^in child) " &
               " (try (eval (quote y) ^in base) catch {^message m} m)]",
               "[10 20 \"undefined symbol: y\"]")

  test "eval sees explicit Env imports before built-ins":
    check_eval("(ns math (var forty-two 42)) " &
               "(var e (env ^imports [math])) " &
               "(eval (quote forty-two) ^in e)",
               "42")

  test "eval sees an optional Env module namespace":
    check_eval("(ns app (var from-module \"ok\")) " &
               "(var e (env ^module app)) " &
               "(eval (quote from-module) ^in e)",
               "\"ok\"")

  test "eval module context does not mutate the source namespace":
    check_eval("(ns app (var x 1)) " &
               "(var e (env ^module app)) " &
               "[(eval (quote (set x 2)) ^in e) (/x app)]",
               "[2 1]")

  test "eval declarations shadow Env bindings without mutating Env":
    check_eval("(var e (env ^bindings {^x 1})) " &
               "[(eval (quote (do (var x 2) x)) ^in e) " &
               " (eval (quote x) ^in e)]",
               "[2 1]")

  test "eval rejects ambient imports inside evaluated code":
    check_eval("(try " &
               "  (eval (quote (import [answer] from \"./envlib\")) ^in (env)) " &
               "catch (CompileError ^message m) m)",
               "\"eval cannot use import; add imports to Env\"")

suite "spec — modules from design":
  test "explicit mod declarations are top-level and unique":
    check_eval("(mod app) (var x 1) x", "1")
    expect GeneError:
      discard compileSource("(mod)")
    expect GeneError:
      discard compileSource("(mod a) (mod b)")
    expect GeneError:
      discard compileSource("(do (mod nested))")

  test "explicit mod names the current module root":
    let scope = newGlobalScope()
    discard bindThisModule(scope, "implicit")
    check run(compileSource("(mod app) this-mod"), scope).print() == "(mod app)"

  test "duplicate bindings in one namespace are rejected":
    expect GeneError:
      discard run(compileSource("(var x 1) (var x 2)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource("(ns m (var x 1) (var x 2))"),
                  newGlobalScope())
    check_eval("(var x 1) (ns m (var x 2)) [x (/x m)]", "[1 2]")

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
