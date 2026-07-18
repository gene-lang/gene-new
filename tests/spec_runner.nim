## Executable Gene language surface spec.
##
## This file intentionally checks behavior from docs/spec/ and
## examples/web_demo.gene at a higher level than unit tests. Run after changes:
##   nimble spec

import gene/[compiler, gir, printer, reader, types, vm]
import std/[algorithm, monotimes, os, sequtils, sets, strutils, tables, times, unittest]

template check_read(src: string, expected: string) =
  check read(src).print() == expected

template check_eval(src: string, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

proc geneString(s: string): string =
  "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

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
    check_read("xs/~size", "(path xs ~size)")
    check_read("(fn f [^server : Http/Server] nil)",
               "(fn f [^ server : Http/Server] nil)")
    check_read("(~ f a)", "(~ f a)")
    check_read("(x; parse; (|| _ default))", "(|| ((x) parse) default)")
    check_read("(x ~ parse; (|| _ default))", "(|| (x ~ parse) default)")

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

  test "strings decode Unicode escapes":
    check_read("\"\\u00E9\\u{1F600}\"", "\"é😀\"")
    check_read("\"\"\"say \"hi\" now\"\"\"", "\"say \\\"hi\\\" now\"")

  test "dollar interpolation keeps the canonical call form distinct":
    check_read("$\"hello ${name}\"", "($ \"hello \" name)")
    check_read("$\"\"\"hello \"${name}\\\"\"\"\"", "($ \"hello \\\"\" name \"\\\"\")")
    check_read("($ \"hello \" name)", "($ \"hello \" name)")

  test "interpolation closes only at lexer-visible delimiters":
    check_read("$\"$(do \\\"x)\\\")\"", "($ (do \"x)\"))")
    check_read("$\"$(match #\\\"[)]\\\" value)\"", "($ (match #\"[)]\" value))")
    check_read("$\"${{^label \\\"}\\\"}}\"", "($ {^label \"}\"})")
    check_read("$\"${{{\\\"key\\\" : \\\"}\\\"}}}\"", "($ {{\"key\" : \"}\"}})")
    check_read("$\"\"\"$(do \"x)\")\"\"\"", "($ (do \"x)\"))")

  test "ordered literal dispatch covers every documented prefix family":
    check_read("[#(x) #[1] #{^a 1} {{\"k\" : 2}}]",
               "[#(x) #[1] #{^a 1} {{\"k\" : 2}}]")
    check_read("[#\"a#b\"im #\"\"\"x+y\"\"\"i]",
               "[#\"a#b\"im #\"x+y\"i]")
    check_read("[0!01000001 0x41 0#QQ==]", "[0x41 0x41 0x41]")
    check_read("[2026-07-04 09:30 2026-07-04T09:30Z]",
               "[2026-07-04 09:30 2026-07-04T09:30:00Z]")
    check_read("['a' \"s\" \"\"\"long\"\"\" $\"x ${name}\"]",
               "['a' \"s\" \"long\" ($ \"x \" name)]")
    let forms = readAll("0#QQ== # comment\n#\"x#y\"")
    check forms.len == 2
    check forms[0].kind == vkBytes
    check forms[1].kind == vkRegex

  test "each literal family rejects a recognized malformed form":
    for source in ["#(x", "#[1", "#{^a 1", "{{\"k\" : }}",
                   "#\"\"\"unterminated", "0!1", "'ab'", "\"unterminated",
                   "$\"unterminated ${x\"", "2026-02-30", "09:99"]:
      expect ReadError:
        discard read(source)

  test "a line comment requires whitespace or '!' after '#'":
    check readAll("# comment\n#\tcomment\n#\n#!x\n(a)").len == 1
    check readAll("(a) #").len == 1

  test "unrecognized '#' forms are reserved read errors":
    for source in ["#a", "#A", "#1", "#tag x", "##", "#-x", "#=", "#'c'",
                   "(a #b)"]:
      expect ReadError:
        discard read(source)

  test "ordinary props require values and flags are explicit":
    check_read("(x ^^ready @@generated false)",
               "(x @@generated ^^ready false)")
    check_read("{^^ready ^value nil}", "{^^ready ^value nil}")
    for source in ["(x ^name)", "(x @doc)", "{^name}", "#{^name}"]:
      expect ReadError:
        discard read(source)
    let manifest = readAll(readFile("examples/ai_agent/package.gene"))
    check manifest.len == 1
    check manifest[0].kind == vkMap
    check manifest[0].mapEntries.hasKey("name")
    check manifest[0].mapEntries.hasKey("dependencies")

  test "malformed syntax is rejected":
    expect ReadError: discard read("(a b")
    expect ReadError: discard read(")")
    expect ReadError: discard read("$\"hello ${name\"")
    expect ReadError: discard read("'ab'")

suite "spec — compiler special-form inventory from docs/spec/calls.md":
  test "documented inventory matches compiler dispatch and has fixtures":
    let design = readFile("docs/spec/calls.md")
    let marker = "<!-- compiler-head-dispatch:start -->"
    let markerAt = design.find(marker)
    check markerAt >= 0
    let fenceAt = design.find("```text", markerAt)
    let namesAt = design.find('\n', fenceAt) + 1
    let fenceEnd = design.find("```", namesAt)
    var documented = design[namesAt ..< fenceEnd].splitWhitespace()
    var dispatched = CoreSpecialFormNames.toSeq()
    documented.sort()
    dispatched.sort()
    check documented == dispatched
    for i in 1 ..< documented.len:
      check documented[i - 1] != documented[i]

    var covered: seq[string]
    template fixture(names: openArray[string], source: string) =
      discard compileSource(source)
      for name in names:
        covered.add name

    fixture(["do", "var", "set", "if"],
      "(do (var x 1) (set x 2) (if true (then x) (else 0)))")
    fixture(["if_yes"], "(if_yes true 1 2)")
    fixture(["if_not"], "(if_not false 1 2)")
    fixture(["&&", "||", "!"], "[(&& true 1) (|| nil 2) (! false)]")
    fixture(["~"], "(fn size-of [self] (~ size))")
    fixture(["fn"], "(fn identity [x] x)")
    fixture(["fn!"], "(fn! syntax-id! [x] x)")
    fixture(["macro"], "(macro identity! [x] `%x) (identity! 1)")
    fixture(["quote", "quasiquote", "select", "path"],
      "(do (quote x) (quasiquote x) (select name) (path a b))")
    fixture(["ns"], "(ns sample (var x 1))")
    fixture(["env"], "(env ^bindings {^x 1})")
    fixture(["eval"], "(eval (quote 1) ^in (env))")
    fixture(["import"], "(import std/stream [map])")
    fixture(["mod"], "(mod sample)")
    fixture(["match"], "(match 1 (when x x))")
    fixture(["while", "break"], "(while true (break))")
    fixture(["loop", "continue"], "(loop (continue))")
    fixture(["repeat"], "(repeat 0 nil)")
    fixture(["for"], "(for x in [] x)")
    fixture(["yield"], "(fn items [] (yield 1))")
    fixture(["return"], "(fn early [] (return 1))")
    fixture(["try"], "(try 1 ensure nil)")
    fixture(["scope"], "(scope nil)")
    fixture(["supervisor"], "(supervisor ^strategy stop nil)")
    fixture(["spawn"], "(scope (spawn 1))")
    fixture(["await"], "(scope (await (spawn 1)))")
    fixture(["fail"], "(fail error-value)")
    fixture(["panic"], "(panic)")
    fixture(["type"], "(type FixtureType ^props {})")
    fixture(["enum"], "(enum FixtureEnum one two)")
    fixture(["protocol"], "(protocol FixtureProtocol)")
    fixture(["impl"],
      "(protocol EmptyProtocol) (type EmptyType ^props {}) " &
      "(impl EmptyProtocol for EmptyType)")
    expect GeneError:
      discard compileSource("(derive)")
    covered.add "derive"

    covered.sort()
    check covered == dispatched

suite "spec — value spread from design":
  test "spread flattens values in calls and list literals":
    check_eval("(var xs [1 2]) (fn collect [items...] items) (collect xs... 3)",
               "[1 2 3]")
    check_eval("(fn collect [items...] items) (collect [1 2]... 3)",
               "[1 2 3]")
    check_eval("(var xs [2 3]) [1 xs... 4]", "[1 2 3 4]")
    check_eval("[1 [2 3]... 4]", "[1 2 3 4]")
    check_eval("(var n (quote (pair 2 3))) [1 n... 4]", "[1 2 3 4]")

suite "spec — enums from design":
  test "unit variants are qualified singleton values with reflection":
    check_eval("(enum Color red green blue) " &
               "[Color/red Color/green (== Color/red Color/red) " &
               " (same? Color/red Color/red) (Color/red ~ name) " &
               " (Color/green ~ ordinal) (Color ~ names) (Color ~ variants) " &
               " (Color ~ from_name (quote red)) (Color ~ from_name \"red\") " &
               " (Color ~ from_ordinal 2)]",
               "[Color/red Color/green true true red 1 [red green blue] " &
               "[Color/red Color/green Color/blue] Color/red Color/red Color/blue]")

  test "tuple variants construct payload values and match by tag":
    check_eval("(enum Shape (circle Int) (rect Int Int)) " &
               "(match (Shape/circle 5) " &
               "  (when (Shape/circle r) r) " &
               "  (when (Shape/rect w h) (* w h)))",
               "5")
    check_eval("(enum Result (ok Int) (err Str)) " &
               "(match (Result/err \"bad\") " &
               "  (when (Result/ok v) v) " &
               "  (when (Result/err e) e))",
               "\"bad\"")

  test "enums are annotation types and generic arguments erase at runtime":
    check_eval("(enum Color red green blue) " &
               "(fn pick [c : Color] (c ~ name)) " &
               "(pick Color/blue)",
               "blue")
    check_eval("(enum Option [T] none (some T)) " &
               "[(Option/some 7) (Option/some \"x\") " &
               " (match Option/none (when Option/none \"none\"))]",
               "[(Option/some 7) (Option/some \"x\") \"none\"]")
    check_eval("(enum Option [T] none (some T)) " &
               "(fn unwrap [o : (Option Int)] " &
               "  (match o (when (Option/some v) v) (when Option/none 0))) " &
               "(unwrap (Option/some 9))",
               "9")
    check_eval("(enum Tree leaf (node Tree Tree)) " &
               "(match (Tree/node Tree/leaf Tree/leaf) " &
               "  (when (Tree/node left right) [left right]))",
               "[Tree/leaf Tree/leaf]")

  test "backed unit enums round-trip through backing values":
    check_eval("(enum Status ^backing Str (active \"A\") (closed \"C\")) " &
               "[(Status/active ~ backing) (Status ~ from_backing \"A\") " &
               " (Status ~ from_backing \"missing\")]",
               "[\"A\" Status/active void]")

  test "enum messages and inline impls dispatch on variants":
    check_eval("(enum Direction " &
               "  north east south west " &
               "  (message degrees [self] : Int (* (self ~ ordinal) 90))) " &
               "(Direction/east ~ degrees)",
               "90")
    check_eval("(protocol Label (message label [self] : Str)) " &
               "(enum Light " &
               "  off on " &
               "  (impl Label " &
               "    (message label [self] : Str " &
               "      (if (== self Light/on) \"on\" \"off\")))) " &
               "(Light/on ~ label)",
               "\"on\"")
    check_eval("(protocol Code (message code [self] : Int)) " &
               "(enum Status active closed) " &
               "(impl Code for Status " &
               "  (message code [self] : Int (self ~ ordinal))) " &
               "(Status/closed ~ code)",
               "1")

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

  test "MVP macros are template macros: exactly one body expression":
    expect GeneError:
      discard run(compileSource("(macro two! [x] (var t 1) `(+ %x %t)) " &
                                "(two! 1)"),
                  newGlobalScope())

  test "macro call props bind named syntax parameters":
    check_eval("(macro scaled! [value ^by n] `(+ %value %n)) " &
               "(scaled! ^by 3 7)",
               "10")
    check_eval("(macro scaled! [value ^by amount] `(+ %value %amount)) " &
               "(scaled! ^by 4 9)",
               "13")
    check_eval("(macro tagged! [value ^tag t] `(quote (%t %value))) " &
               "(tagged! ^tag item 7)",
               "(item 7)")
    expect GeneError:
      discard run(compileSource(
        "(macro scaled! [value ^by n] `(+ %value %n)) " &
        "(scaled! 7)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource(
        "(macro scaled! [value ^by n] `(+ %value %n)) " &
        "(scaled! ^other 3 7)"), newGlobalScope())

  test "macro parameters destructure syntax patterns":
    check_eval("(macro second! [[_ value]] `%value) " &
               "(second! [ignored (+ 1 2)])",
               "3")
    check_eval("(macro pick-prop! [{^value v}] `%v) " &
               "(pick-prop! {^value (+ 2 3)})",
               "5")
    check_eval("(macro named-pair! [^entry [k v]] `(+ %k %v)) " &
               "(named-pair! ^entry [2 3])",
               "5")
    expect GeneError:
      discard run(compileSource(
        "(macro second! [[_ value]] `%value) " &
        "(second! [only-one])"), newGlobalScope())

  test "macro typed patterns match syntax values":
    check_eval("(macro eval-node! [(form : Node)] `%form) " &
               "(eval-node! (+ 1 2))",
               "3")
    check_eval("(macro eval-flat! [form : Node] `%form) " &
               "(eval-flat! (+ 2 3))",
               "5")
    check_eval("(macro keep-syms! [(items : (List Sym))] `(quote %items)) " &
               "(keep-syms! [a b])",
               "[a b]")
    check_eval("(macro keep-entry! [^entry item : (List Sym)] `(quote %item)) " &
               "(keep-entry! ^entry [a b])",
               "[a b]")
    expect GeneError:
      discard run(compileSource(
        "(macro eval-node! [(form : Node)] `%form) " &
        "(eval-node! 1)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource(
        "(macro eval-flat! [form : Node] `%form) " &
        "(eval-flat! 1)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource(
        "(macro keep-syms! [(items : (List Sym))] `(quote %items)) " &
        "(keep-syms! [a 1])"), newGlobalScope())

  test "macro parameter defaults bind syntax values":
    check_eval("(macro default-value! [x = 7] `%x) " &
               "[(default-value!) (default-value! 9)]",
               "[7 9]")
    check_eval("(macro second-or-first! [x y = x] `%y) " &
               "[(second-or-first! (+ 1 2)) (second-or-first! 1 4)]",
               "[3 4]")
    check_eval("(macro named-default! [^value v = (+ 2 3)] `%v) " &
               "[(named-default!) (named-default! ^value 8)]",
               "[5 8]")
    check_eval("(macro optional! [x = nil] `%x) (optional!)", "nil")
    expect GeneError:
      discard compileSource("(macro bad! [x = 1 y] `%y)")

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
               "          (if (== n 0) 0 (helper (- n 1)))) " &
               "       (helper %x))) " &
               "(fn helper [n] 99) [(recursive! 3) (helper 3)]",
               "[0 99]")

  test "template macros avoid introduced pattern-binder capture":
    # docs/proposals/macro-design.md §12.5: binders introduced by a template's
    # match pattern are hygienically fresh, like var/fn binders.
    check_eval("(macro first-of! [x] " &
               "  `(match %x (when [tmp] tmp))) " &
               "(var tmp 100) [(first-of! [1]) tmp]",
               "[1 100]")

suite "spec — fn! runtime fexprs from design (§3/§11.1)":
  test "fn! receives raw syntax and evaluates through caller_env":
    check_eval("(fn! unless! [cond, body...] " &
               "  (if (! (eval cond ^in caller_env)) " &
               "    (eval `(do %body...) ^in caller_env) " &
               "    nil)) " &
               "(var x 10) " &
               "[(unless! (> x 5) \"small\") (unless! (< x 5) \"not-small\")]",
               "[nil \"not-small\"]")

  test "fn! call arguments are not evaluated":
    check_eval("(var hit (cell 0)) " &
               "(fn! ignore! [e] nil) " &
               "(ignore! (hit ~ Cell/set 9)) " &
               "(hit ~ Cell/get)",
               "0")

  test "syntax_call carries the raw envelope including site":
    check_eval("(fn! probe! [a b] syntax_call) " &
               "(probe! foo (bar 1))",
               "((type SyntaxCall) ^named {} ^site (probe! foo (bar 1)) " &
               "foo (bar 1))")

  test "fn! values are first-class: aliases and expression heads":
    check_eval("(fn! quote-it! [e] e) (var q quote-it!) (q (+ 1 2))",
               "(+ 1 2)")
    check_eval("(fn! quote-it! [e] e) ((do quote-it!) (+ 1 2))",
               "(+ 1 2)")

  test "Fn! is a sibling of Fn, not a subtype":
    check_eval("(fn! q! [e] e) (fn keep [f : Fn!] \"ok\") (keep q!)",
               "\"ok\"")
    check_eval("(fn! q! [e] e) " &
               "(try (fn keep [f : Fn] f) (keep q!) " &
               "catch (TypeError ^expected e) e)",
               "\"Fn\"")
    check_eval("(fn! q! [e] e) " &
               "(try (fn keep [f : Callable] f) (keep q!) " &
               "catch (TypeError ^expected e) e)",
               "\"Callable\"")

  test "dynamic callees choose fn! before evaluating arguments":
    check_eval("(fn! q! [e] e) (var side 0) " &
               "(fn hof [f] (f (set side 1))) " &
               "[(hof q!) side]",
               "[(set side 1) 0]")
    check_eval("(fn! q! [e] e) " &
               "(fn hof [f : Any] (f (+ 1 2))) (hof q!)",
               "(+ 1 2)")
    check_eval("(fn! q! [^x] x) (var side 0) " &
               "(fn hof [f] (f ^x (set side 1))) " &
               "[(hof q!) side]",
               "[(set side 1) 0]")
    check_eval("(fn! z! [] 42) (fn hof [f] (f)) (hof z!)", "42")
    check_eval("(fn f [x] x) (var side 0) " &
               "(fn invoke [] (f (set side 1))) " &
               "(set f (fn! [x] x)) [(invoke) side]",
               "[(set side 1) 0]")

  test "eval Env bindings use callable-first fn! dispatch":
    check_eval("(fn! q! [e] e) " &
               "(var e (env ^bindings {^q q!})) " &
               "(eval (quote (q (+ 1 2))) ^in e)",
               "(+ 1 2)")
    check_eval("(fn! q! [e] e) " &
               "(var e (env ^bindings {^+ q!})) " &
               "(eval (quote (+ (set never 1))) ^in e)",
               "(set never 1)")

  test "message sends reject fn! before evaluating send arguments":
    check_eval("(fn f [self y ^x] [self y x]) ([1] ~ f ^x 2 3)",
               "[[1] 3 2]")
    check_eval("(fn! q! [x] x) (var side 0) " &
               "(try ([1] ~ q! (set side 1)) catch _ side)",
               "0")
    check_eval("(fn! q! [^x] x) (var side 0) " &
               "(try ([1] ~ q! ^x (set side 1)) catch _ side)",
               "0")
    check_eval("(fn! q! [x] x) (var side 0) " &
               "(try ([1] ~ (do q!) (set side 1)) catch _ side)",
               "0")
    check_eval("(fn! q! [x] x) " &
               "(try ([1] ~ q! 1) " &
               " catch (CallKindError ^where w ^expected e ^actual a) " &
               " [w e a])",
               "[\"message send\" \"Callable\" \"SyntaxCallable\"]")

  test "fn! prints as a fn! value":
    check_eval("(fn! q! [e] e) q!", "(fn! q!)")

  test "fn! arity errors count only syntax parameters":
    # caller_env and syntax_call bind as implicit leading parameters but must
    # not surface in arity diagnostics.
    check_eval("(fn! q! [e] e) (try (q!) catch (Error ^message m) m)",
               "\"fn! 'q!' expects 1..1 syntax argument(s), got 0\"")

  test "caller_env is borrowed and explicit snapshots are durable":
    check_eval("(var x 41) " &
               "(fn! capture! [] (Env/snapshot caller_env [\"x\"])) " &
               "(var saved (capture!)) (eval (quote (+ x 1)) ^in saved)",
               "42")
    check_eval("(var x 1) (var secret 9) " &
               "(fn! capture! [] (Env/snapshot caller_env [\"x\"])) " &
               "(var saved (capture!)) " &
               "(try (eval (quote secret) ^in saved) catch _ \"absent\")",
               "\"absent\"")
    check_eval("(fn! type! [] (var e : CallerEnv caller_env) \"ok\") " &
               "(type!)",
               "\"ok\"")

  test "caller_env escape boundaries reject borrowed authority":
    check_eval("(fn! leak! [] caller_env) " &
               "(try (leak!) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(fn! leak! [] [caller_env]) " &
               "(try (leak!) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(fn! leak! [] (cell caller_env)) " &
               "(try (leak!) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(var leaked nil) (fn! leak! [] (set leaked caller_env)) " &
               "(try (leak!) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(var leaked []) " &
               "(fn! leak! [] (leaked ~ List/push! caller_env)) " &
               "[(try (leak!) catch _ \"blocked\") leaked]",
               "[\"blocked\" []]")
    check_eval("(fn! leak! [] (fn [] (eval (quote 1) ^in caller_env))) " &
               "(try (leak!) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(fn! leak! [] (fail caller_env)) " &
               "(try (leak!) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(fn! leak! [] (scope (spawn caller_env))) " &
               "(try (leak!) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(import serde [write SerdeError]) " &
               "(fn! leak! [] " &
               "  (try (write caller_env) catch (SerdeError) \"blocked\")) " &
               "(leak!)",
               "\"blocked\"")
    check_eval("(var ch (channel ^capacity 1)) " &
               "(fn! leak! [] " &
               "  (try (ch ~ Channel/send caller_env) " &
               "   catch (TypeError ^expected e) e)) " &
               "(leak!)",
               "\"Send\"")

suite "spec — typed native compilation prototype from design":
  test "simple typed Int arithmetic can use a native direct op":
    let chunk = compileSource("(fn add [x : Int y : Int] : Int (+ x y))")
    check chunk.functions[0].nativeOp == ncoIntAdd
    check "native=int_add" in chunk.disassemble()
    check_eval("(fn add [x : Int y : Int] : Int (+ x y)) (add 20 22)",
               "42")
    check_eval("(fn add [x : Int y : Int] : Int (+ x y)) " &
               "(try (add \"bad\" 1) catch (TypeError ^where w) w)",
               "\"parameter 'x'\"")
    check_eval("(fn outer [] (add \"bad\" 1)) " &
               "(fn add [x : Int y : Int] : Int (+ x y)) " &
               "(try (outer) catch (TypeError ^trace t) " &
               "  [t/0/name t/0/kind t/1/name t/1/kind])",
               "[\"add\" \"typed_native\" \"outer\" \"bytecode\"]")

  test "fixed representation functions expose an experimental C backend":
    let chunk = compileSource("(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
                              "(fn scale [x : F64 y : F64] : F64 (* x y))")
    check chunk.functions[0].nativeOp == ncoI64Add
    check chunk.functions[1].nativeOp == ncoF64Mul
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneFfiAbiTypeInfo" in c
    check "_Static_assert(sizeof(int64_t) == 8, \"C/Int64 must be 8 bytes\");" in c
    check "static const GeneFfiAbiTypeInfo gene_ffi_abi_types[] GENE_MAYBE_UNUSED = {" in c
    check "{\"C/Int64\", \"int64_t\", sizeof(int64_t), GENE_ALIGNOF(int64_t)}," in c
    check "static const size_t gene_ffi_abi_types_count GENE_MAYBE_UNUSED = 22;" in c
    check "int64_t gene_native_add64(int64_t x, int64_t y)" in c
    check "double gene_native_scale(double x, double y)" in c
    check_eval("(fn add64 [x : I64 y : I64] : I64 (+ x y)) (add64 20 22)",
               "42")

  test "selected typed functions AOT emit direct typed C calls":
    let chunk = compileSource("(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
                              "(fn add64_twice [x : I64 y : I64] : I64 " &
                              "  (add64 (add64 x y) y))")
    check chunk.functions[0].aotExpr.kind != vkNil
    check chunk.functions[1].aotExpr.kind != vkNil
    check chunk.functions[0].aotFrameKind == afkTypedNative
    check not chunk.functions[0].aotFrameCanSuspend
    check "aot=c frame=typed_native" in chunk.disassemble()
    check "typed-module-aot:" in chunk.disassemble()
    check "add64 repr=I64 arity=2 frame=typed_native" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneNativeFrameInfo" in c
    check "typedef struct GeneAotModuleFunction" in c
    check "static const GeneNativeFrameInfo gene_frame_add64 GENE_MAYBE_UNUSED = {\"add64\", GENE_NATIVE_FRAME_TYPED};" in c
    check "(void)&gene_frame_add64;" in c
    check "static const GeneAotModuleFunction gene_aot_module[] GENE_MAYBE_UNUSED = {" in c
    check "{\"add64\", \"gene_native_add64\", \"I64\", 2, &gene_frame_add64}," in c
    check "static const size_t gene_aot_module_count GENE_MAYBE_UNUSED = 2;" in c
    check "int64_t gene_native_add64_twice(int64_t x, int64_t y)" in c
    check "return gene_native_add64(gene_native_add64(x, y), y);" in c
    check_eval("(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
               "(fn add64_twice [x : I64 y : I64] : I64 " &
               "  (add64 (add64 x y) y)) " &
               "(add64_twice 20 2)",
               "24")

  test "fixed scalar AOT covers branching and direct recursion":
    let chunk = compileSource(
      "(fn clamp64 [x : I64 lo : I64 hi : I64] : I64 " &
      "  (if (< x lo) lo (if (> x hi) hi x))) " &
      "(fn fib64 [n : I64] : I64 " &
      "  (if (< n 2) n (+ (fib64 (- n 1)) (fib64 (- n 2)))))")
    check chunk.functions[0].aotExpr.kind != vkNil
    check chunk.functions[1].aotExpr.kind != vkNil
    check chunk.functions[0].aotFrameKind == afkTypedNative
    check chunk.functions[1].aotFrameKind == afkTypedNative
    let c = chunk.emitExperimentalC()
    check "int64_t gene_native_clamp64(int64_t x, int64_t lo, int64_t hi)" in c
    check "return ((x < lo) ? lo : ((x > hi) ? hi : x));" in c
    check "int64_t gene_native_fib64(int64_t n)" in c
    check "return ((n < 2) ? n : (gene_native_fib64((n - 1)) + gene_native_fib64((n - 2))));" in c
    check_eval(
      "(fn clamp64 [x : I64 lo : I64 hi : I64] : I64 " &
      "  (if (< x lo) lo (if (> x hi) hi x))) " &
      "(fn fib64 [n : I64] : I64 " &
      "  (if (< n 2) n (+ (fib64 (- n 1)) (fib64 (- n 2))))) " &
      "[(clamp64 -2 0 10) (clamp64 12 0 10) (fib64 10)]",
      "[0 10 55]")

  test "task-frame lowering metadata is emitted for resumable functions":
    let chunk = compileSource("(fn wait [t : (Task Int Never)] : Int (await t)) " &
                              "(fn ints [] : (Stream Int Never) (yield 1))")
    check chunk.functions[0].taskFrameKind == tfkVm
    check chunk.functions[1].taskFrameKind == tfkGenerator
    check "task-frame=vm" in chunk.disassemble()
    check "task-frame=generator" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneTaskFrameInfo" in c
    check "static const GeneTaskFrameInfo gene_task_frames[] GENE_MAYBE_UNUSED = {" in c
    check "{\"wait\", \"vm\", true}," in c
    check "{\"ints\", \"generator\", false}," in c

  test "direct protocol calls record selected impl dependencies":
    let source = "(protocol ToName (message to_name [self] : Str)) " &
                 "(type User ^props {^name Str}) " &
                 "(impl ToName for User (message to_name [self] : Str self/name)) " &
                 "(to_name ^protocol ToName ^receiver User (User ^name \"Ada\"))"
    let chunk = compileSource(source)
    check chunk.directProtocolCalls.len == 1
    check chunk.directProtocolCalls[0].messageName == "to_name"
    check chunk.directProtocolCalls[0].protocolExpr.print() == "ToName"
    check chunk.directProtocolCalls[0].receiverExpr.print() == "User"
    check "direct-protocol-calls:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "direct-protocol to_name ToName/User" in c
    check "static const GeneDirectProtocolCall gene_direct_protocol_calls[] GENE_MAYBE_UNUSED = {" in c
    check "{\"to_name\", \"ToName\", \"User\"}," in c
    check "static const size_t gene_direct_protocol_calls_count GENE_MAYBE_UNUSED = 1;" in c
    check_eval(source, "\"Ada\"")
    expect GeneError:
      discard compileSource("(to_name ^protocol ToName x)")

  test "ffi/library declarations expose target metadata manifests":
    let chunk = compileSource(
      "(ffi/library libc " &
      "  ^linux \"libc.so.6\" " &
      "  ^macos \"libSystem.B.dylib\" " &
      "  ^windows \"msvcrt.dll\") " &
      "(ffi/fn strlen ^library libc ^symbol \"strlen\" [s : C/CStr] : C/Size)")
    check chunk.ffiLibraries.len == 1
    check chunk.ffiLibraries[0].name == "libc"
    check chunk.ffiLibraries[0].linux == "libc.so.6"
    check chunk.ffiLibraries[0].macos == "libSystem.B.dylib"
    check chunk.ffiLibraries[0].windows == "msvcrt.dll"
    check "ffi-libraries:" in chunk.disassemble()
    check "linux=libc.so.6" in chunk.disassemble()
    check chunk.ffiFns[0].libraryDeclared
    check "declared-library=true" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneFfiLibraryInfo" in c
    check "static const GeneFfiLibraryInfo gene_ffi_libraries[] GENE_MAYBE_UNUSED = {" in c
    check "{\"libc\", \"libc.so.6\", \"libSystem.B.dylib\", \"msvcrt.dll\"}," in c
    check "static const size_t gene_ffi_libraries_count GENE_MAYBE_UNUSED = 1;" in c
    check "{\"strlen\", \"libc\", true, \"strlen\", \"C\", \"C\", " &
      "\"gene_ffi_strlen\", \"\", 1, \"C/Size\"}," in c
    check_eval("(ffi/library libc ^linux \"libc.so.6\") libc", "libc")
    expect GeneError:
      discard compileSource("(ffi/library libc)")
    expect GeneError:
      discard compileSource("(ffi/library libc ^freebsd \"libc.so\")")
    expect GeneError:
      discard compileSource("(ffi/library libc ^linux \"libc.so.6\") " &
                            "(ffi/library libc ^linux \"libc.so.6\")")

  test "ffi/fn declarations expose generated C wrappers":
    let chunk = compileSource("(ffi/fn strlen " &
                              "  ^library libc ^symbol \"strlen\" " &
                              "  ^abi C ^calling cdecl " &
                              "  [s : C/CStr] : C/Size)")
    check chunk.ffiFns.len == 1
    check chunk.ffiFns[0].name == "strlen"
    check chunk.ffiFns[0].library == "libc"
    check not chunk.ffiFns[0].libraryDeclared
    check chunk.ffiFns[0].symbol == "strlen"
    check chunk.ffiFns[0].abi == "C"
    check chunk.ffiFns[0].calling == "cdecl"
    check "ffi-fns:" in chunk.disassemble()
    check "calling=cdecl" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "generated FFI adapter wrappers" in c
    check "adapter skeletons" notin c
    check "typedef struct GeneFfiFnInfo" in c
    check "bool library_declared;" in c
    check "const char *calling;" in c
    check "#define GENE_FFI_CDECL" in c
    check "#define GENE_FFI_STDCALL __stdcall" in c
    check "static const GeneFfiFnInfo gene_ffi_fns[] GENE_MAYBE_UNUSED = {" in c
    check "{\"strlen\", \"libc\", false, \"strlen\", \"C\", \"cdecl\", " &
      "\"gene_ffi_strlen\", \"\", 1, \"C/Size\"}," in c
    check "static const size_t gene_ffi_fns_count GENE_MAYBE_UNUSED = 1;" in c
    check "extern size_t GENE_FFI_CDECL strlen(const char * s);" in c
    check "GeneStatus gene_ffi_strlen" in c
    check "calling: cdecl" in c
    check "arg 0 s: C/CStr -> const char *" in c
    check "result: C/Size -> GeneValue" in c
    check "GeneStatus status = gene_ffi_check_arity(ctx, call, 1);" in c
    check "status = gene_ffi_arg_cstr(ctx, call, 0, \"s\", &s);" in c
    check "size_t native_result = strlen(s);" in c
    check "return gene_ffi_result_size(ctx, native_result, result);" in c
    check "return GENE_FFI_WRAPPER_UNIMPLEMENTED;" notin c
    let stdcallC =
      compileSource("(ffi/fn WindowProc ^symbol \"WindowProc\" " &
                    "^calling stdcall [x : C/Int] : C/Int)").emitExperimentalC()
    check "extern int GENE_FFI_STDCALL WindowProc(int x);" in stdcallC
    expect GeneError:
      discard compileSource("(ffi/fn bad_calling ^symbol \"bad\" " &
                            "^calling vectorcall [] : C/Void)")
    expect GeneError:
      discard compileSource("(ffi/fn bad_abi ^symbol \"bad\" " &
                            "^abi Rust [] : C/Void)")
    expect GeneError:
      discard compileSource("(ffi/fn bad_library ^library \"\" [] : C/Void)")
    check_eval("(ffi/fn strlen ^symbol \"strlen\" [s : C/CStr] : C/Size) strlen",
               "(native-fn strlen)")

  test "ffi/fn C wrappers marshal scalar, pointer, slice, and buffer ABI shapes":
    let source =
      "(ffi/fn c_abs ^symbol \"abs\" [x : C/Int] : C/Int) " &
      "(ffi/fn c_strerror ^symbol \"strerror\" [x : C/Int] : C/CStr) " &
      "(ffi/fn c_memchr ^symbol \"memchr\" " &
      "  [p : (C/ConstPtr C/Char) ch : C/Int n : C/Size] " &
      "  : (C/NullablePtr C/Char)) " &
      "(ffi/fn consume_slice ^symbol \"consume_slice\" " &
      "  [s : (C/Slice C/UInt8)] : C/Void) " &
      "(ffi/fn consume_buffer ^symbol \"consume_buffer\" " &
      "  [b : (Buffer C/UInt8)] : C/Void) " &
      "(ffi/fn make_owned ^symbol \"make_owned\" ^release \"destroy_owned\" " &
      "  [] : (C/OwnedPtr C/Char))"
    let c = compileSource(source).emitExperimentalC()
    check "static const size_t gene_ffi_fns_count GENE_MAYBE_UNUSED = 6;" in c
    check "{\"make_owned\", \"\", false, \"make_owned\", \"C\", " &
      "\"C\", \"gene_ffi_make_owned\", \"destroy_owned\", 0, " &
      "\"(C/OwnedPtr C/Char)\"}," in c
    check "status = gene_ffi_arg_int(ctx, call, 0, \"x\", &x);" in c
    check "int native_result = abs(x);" in c
    check "return gene_ffi_result_int(ctx, native_result, result);" in c
    check "extern const char * GENE_FFI_CDECL strerror(int x);" in c
    check "const char * native_result = strerror(x);" in c
    check "return gene_ffi_result_cstr(ctx, native_result, result);" in c
    check "status = gene_ffi_arg_const_ptr(ctx, call, 0, \"p\", " &
      "\"(C/ConstPtr C/Char)\", &p);" in c
    check "return gene_ffi_result_ptr(ctx, (void *)native_result, " &
      "\"(C/NullablePtr C/Char)\", NULL, result);" in c
    check "extern void GENE_FFI_CDECL consume_slice(const void * s, size_t s_len);" in c
    check "status = gene_ffi_arg_buffer(ctx, call, 0, \"s\", " &
      "\"(C/Slice C/UInt8)\", &s_view);" in c
    check "consume_slice(s_view.data, s_view.len);" in c
    check "extern void GENE_FFI_CDECL consume_buffer(const void * b, size_t b_len);" in c
    check "GeneFfiBufferView b_view;" in c
    check "status = gene_ffi_arg_buffer(ctx, call, 0, \"b\", " &
      "\"(Buffer C/UInt8)\", &b_view);" in c
    check "consume_buffer(b_view.data, b_view.len);" in c
    check "return gene_ffi_result_void(ctx, result);" in c
    check "return gene_ffi_result_ptr(ctx, (void *)native_result, " &
      "\"(C/OwnedPtr C/Char)\", \"destroy_owned\", result);" in c
    check "return GENE_FFI_WRAPPER_UNIMPLEMENTED;" notin c
    expect GeneError:
      discard compileSource("(ffi/fn bad_any ^symbol \"bad\" [x : Any] : C/Int)")
    expect GeneError:
      discard compileSource("(ffi/fn bad_slice_result ^symbol \"bad\" " &
                            "[] : (C/Slice C/UInt8))")
    expect GeneError:
      discard compileSource("(ffi/fn bad_owned ^symbol \"bad\" " &
                            "[] : (C/OwnedPtr C/Char))")
    expect GeneError:
      discard compileSource("(ffi/fn bad_release ^symbol \"bad\" " &
                            "^release \"free\" [] : (C/Ptr C/Char))")
    expect GeneError:
      discard compileSource("(ffi/fn empty_release ^symbol \"bad\" " &
                            "^release \"\" [] : (C/OwnedPtr C/Char))")
    expect GeneError:
      discard compileSource("(ffi/fn bad_ptr_shape ^symbol \"bad\" " &
                            "[p : (C/Ptr C/Char C/Int)] : C/Void)")
    expect GeneError:
      discard compileSource("(ffi/fn bad_slice_shape ^symbol \"bad\" " &
                            "[s : (C/Slice C/UInt8 C/UInt16)] : C/Void)")
    expect GeneError:
      discard compileSource("(ffi/fn bad_buffer_shape ^symbol \"bad\" " &
                            "[b : (Buffer C/UInt8 C/UInt16)] : C/Void)")
    expect GeneError:
      discard compileSource("(ffi/fn bad_result_shape ^symbol \"bad\" " &
                            "^release \"free\" [] : (C/OwnedPtr C/Char C/Int))")

  test "ffi/struct declarations expose C layout metadata manifests":
    let chunk = compileSource("(ffi/struct Timespec " &
                              "  ^size 16 ^align 8 " &
                              "  ^fields [[tv_sec C/Long ^offset 0] " &
                              "           [tv_nsec C/Long ^offset 8]])")
    check chunk.ffiStructs.len == 1
    check chunk.ffiStructs[0].name == "Timespec"
    check chunk.ffiStructs[0].layout == "C"
    check chunk.ffiStructs[0].hasSize
    check chunk.ffiStructs[0].size == 16
    check chunk.ffiStructs[0].hasAlign
    check chunk.ffiStructs[0].align == 8
    check chunk.ffiStructs[0].fields.len == 2
    check chunk.ffiStructs[0].fields[0].name == "tv_sec"
    check chunk.ffiStructs[0].fields[0].typeExpr.print() == "C/Long"
    check chunk.ffiStructs[0].fields[0].hasOffset
    check chunk.ffiStructs[0].fields[0].offset == 0
    check "ffi-structs:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneFfiStructInfo" in c
    check "typedef struct GeneFfiStructFieldInfo" in c
    check "typedef struct Timespec {" in c
    check "long tv_sec;" in c
    check "_Static_assert(sizeof(Timespec) == 16, " &
      "\"ffi/struct Timespec size mismatch\");" in c
    check "_Static_assert(GENE_ALIGNOF(Timespec) == 8, " &
      "\"ffi/struct Timespec align mismatch\");" in c
    check "_Static_assert(offsetof(Timespec, tv_nsec) == 8, " &
      "\"ffi/struct Timespec.tv_nsec offset mismatch\");" in c
    check "static const GeneFfiStructInfo gene_ffi_structs[] GENE_MAYBE_UNUSED = {" in c
    check "{\"Timespec\", \"C\", 16, 8, 2}," in c
    check "{\"Timespec\", \"tv_sec\", \"C/Long\", 0}," in c
    let ptrChunk = compileSource("(ffi/struct HandleBox " &
                                 "  ^fields [[handle (C/Ptr C/Void)]])")
    let ptrC = ptrChunk.emitExperimentalC()
    check "typedef struct HandleBox {" in ptrC
    check "void * handle;" in ptrC
    check_eval("(ffi/struct Timespec ^fields [[tv_sec C/Long]]) Timespec",
               "Timespec")
    expect GeneError:
      discard compileSource("(ffi/struct BadSlice " &
                            "  ^fields [[view (C/Slice C/UInt8)]])")
    expect GeneError:
      discard compileSource("(ffi/struct BadBuffer " &
                            "  ^fields [[buf (Buffer C/UInt8)]])")
    expect GeneError:
      discard compileSource("(ffi/struct BadLayout ^layout packed " &
                            "  ^fields [[x C/Int]])")

  test "ffi/union declarations expose C layout metadata manifests":
    let chunk = compileSource("(ffi/union IntOrDouble " &
                              "  ^size 8 ^align 8 " &
                              "  ^fields [[i C/Int] [d C/Double]])")
    check chunk.ffiUnions.len == 1
    check chunk.ffiUnions[0].name == "IntOrDouble"
    check chunk.ffiUnions[0].layout == "C"
    check chunk.ffiUnions[0].hasSize
    check chunk.ffiUnions[0].size == 8
    check chunk.ffiUnions[0].hasAlign
    check chunk.ffiUnions[0].align == 8
    check chunk.ffiUnions[0].fields.len == 2
    check chunk.ffiUnions[0].fields[0].name == "i"
    check chunk.ffiUnions[0].fields[0].typeExpr.print() == "C/Int"
    check "ffi-unions:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneFfiUnionInfo" in c
    check "typedef struct GeneFfiUnionFieldInfo" in c
    check "typedef union IntOrDouble {" in c
    check "int i;" in c
    check "double d;" in c
    check "_Static_assert(sizeof(IntOrDouble) == 8, " &
      "\"ffi/union IntOrDouble size mismatch\");" in c
    check "_Static_assert(GENE_ALIGNOF(IntOrDouble) == 8, " &
      "\"ffi/union IntOrDouble align mismatch\");" in c
    check "static const GeneFfiUnionInfo gene_ffi_unions[] GENE_MAYBE_UNUSED = {" in c
    check "{\"IntOrDouble\", \"C\", 8, 8, 2}," in c
    check "{\"IntOrDouble\", \"i\", \"C/Int\"}," in c
    check_eval("(ffi/union IntOrDouble ^fields [[i C/Int]]) IntOrDouble",
               "IntOrDouble")
    expect GeneError:
      discard compileSource("(ffi/union Bad ^fields [[i C/Int ^offset 0]])")
    expect GeneError:
      discard compileSource("(ffi/union BadBuffer " &
                            "  ^fields [[buf (Buffer C/UInt8)]])")
    expect GeneError:
      discard compileSource("(ffi/union BadLayout ^layout packed " &
                            "  ^fields [[x C/Int]])")

  test "callback and dynamic FFI signatures expose metadata manifests":
    let chunk = compileSource(
      "(ffi/callback Comparator " &
      "  [lhs : (C/Ptr C/Void) rhs : (C/Ptr C/Void)] : C/Int) " &
      "(ffi/signature RuntimeCall ^abi C " &
      "  [value : Any] : C/Int)")
    check chunk.ffiSignatures.len == 2
    check chunk.ffiSignatures[0].name == "Comparator"
    check chunk.ffiSignatures[0].kind == fskCallback
    check not chunk.ffiSignatures[0].escaping
    check not chunk.ffiSignatures[0].runtimeConstructible
    check chunk.ffiSignatures[1].name == "RuntimeCall"
    check chunk.ffiSignatures[1].kind == fskDynamic
    check chunk.ffiSignatures[1].runtimeConstructible
    check "ffi-signatures:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneFfiSignatureInfo" in c
    check "static const GeneFfiSignatureInfo gene_ffi_signatures[] GENE_MAYBE_UNUSED = {" in c
    check "{\"Comparator\", \"callback\", \"C\", " &
      "\"lhs:(C/Ptr C/Void),rhs:(C/Ptr C/Void)\", \"C/Int\", false, false}," in c
    check "{\"RuntimeCall\", \"dynamic\", \"C\", \"value:Any\", " &
      "\"C/Int\", false, true}," in c
    expect GeneError:
      discard compileSource("(ffi/callback BadAny [value : Any] : C/Int)")
    expect GeneError:
      discard compileSource("(ffi/callback BadSliceResult " &
                            "[] : (C/Slice C/UInt8))")
    expect GeneError:
      discard compileSource("(ffi/callback BadOwnedResult " &
                            "[] : (C/OwnedPtr C/Char))")
    expect GeneError:
      discard compileSource("(ffi/callback BadPtrShape " &
                            "[p : (C/Ptr C/Char C/Int)] : C/Void)")
    expect GeneError:
      discard compileSource("(ffi/callback Escaping ^escaping true " &
                            "[p : (C/Ptr C/Void)] : C/Void)")
    expect GeneError:
      discard compileSource("(ffi/callback BadAbi ^abi Rust " &
                            "[p : (C/Ptr C/Void)] : C/Void)")
    expect GeneError:
      discard compileSource("(ffi/signature BadAbi ^abi Rust [value : Any] : C/Int)")

suite "spec — strings from design":
  test "strings expose explicit chars and bytes iteration":
    check_eval("[(chars \"Aé\") (bytes \"Aé\")]",
               "[['A' 'é'] [65 195 169]]")

  test "graphemes expose combining scalar clusters":
    let s = "e\u0301x"
    check_eval("(graphemes \"" & s & "\")", "[\"e\u0301\" \"x\"]")

  test "dollar interpolation calls to_str-style display conversion":
    check_eval("(var name \"Ada\") $\"hello ${name}\"", "\"hello Ada\"")
    check_eval("$\"sum = $(+ 1 2)\"", "\"sum = 3\"")
    check_eval("(type User ^props {^name Str}) " &
               "(impl ToStr for User (message to_str [self] : Str self/name)) " &
               "(var user (User ^name \"Ada\")) " &
               "$\"hello ${user}\"",
               "\"hello Ada\"")

suite "spec — hashable collections and bytes from design":
  test "Bytes literals read as immutable byte strings":
    check_eval("[0!01000001 0x4869 0#SGk=]", "[0x41 0x4869 0x4869]")
    check_eval("[0!01001000~ 01101001 0x48~ 69 0#SGk=]",
               "[0x4869 0x4869 0x4869]")

  test "Set deduplicates hash-stable values in insertion order":
    check_eval("[(Set 1 2 1) (set_has? (Set \"a\" \"b\") \"b\")]",
               "[(Set 1 2) true]")
    check_eval("(try (Set [1]) catch (TypeError ^expected e) e)",
               "\"HashStable\"")

  test "general maps evaluate any hash-stable keys":
    check_eval("(var k \"a\") [(Map/get {{k : (+ 1 2)}} \"a\") " &
               "{{\"x\" : 1 \"x\" : 2}}]",
               "[3 {{\"x\" : 2}}]")
    check_eval("(try {{[1] : 2}} catch (TypeError ^expected e) e)",
               "\"HashStable\"")

suite "spec — regular expressions from design":
  test "Regex literals are raw and constructor strings escape normally":
    check_eval("[#\"\\d+\" (Regex \"\\\\d+\") (Regex ^flags \"mi\" \"abc\")]",
               "[#\"\\d+\" #\"\\d+\" #\"abc\"im]")

  test "regex sends return Match values and streams":
    check_eval("(var m (#\"(?<word>\\w+)-(\\d+)\" ~ match \"ab-12 zz\")) " &
               "[m/text m/groups (Map/get m/named \"word\") m/start m/end]",
               "[\"ab-12\" #[\"ab\" \"12\"] \"ab\" 0 5]")
    check_eval("(var xs (into (#\"\\d+\" ~ find_all \"a12b3\") [])) " &
               "[xs/0/text xs/1/text]",
               "[\"12\" \"3\"]")

  test "regex replacement templates and split use PCRE captures":
    check_eval("(#\"(\\w+)=(?<n>\\d+)\" ~ replace_all \"a=1 b=22\" \"\\\\k<n>\")",
               "\"1 22\"")
    check_eval("(#\"\\s*,\\s*\" ~ split \"a, b,c\")",
               "[\"a\" \"b\" \"c\"]")

suite "spec — equality and identity from design":
  test "same question mark is scalar identity or heap identity":
    check_eval("(var xs [1]) [(== [1] [1]) (same? [1] [1]) (same? xs xs)]",
               "[true false true]")

  test "hash follows equality for hash-stable values":
    check_eval("[(== (hash #[1 2]) (hash (freeze [1 2]))) " &
               " (== (hash (quote #(x @line 1 ^a 2))) " &
               "    (hash (quote #(x @line 99 ^a 2))))]",
               "[true true]")
    check_eval("(try (hash [1 2]) catch {^message m} m)",
               "\"hash expects a hash-stable value\"")
    check_eval("(try (hash #[(cell 1)]) catch {^message m} m)",
               "\"hash expects a hash-stable value\"")

  test "freeze helpers make mutability explicit":
    check_eval("[(freeze_shallow [1 [2]]) " &
               " (freeze [1 {^a [2]}]) " &
               " (thaw (freeze [1 {^a [2]}]))]",
               "[#[1 [2]] #[1 #{^a #[2]}] [1 {^a [2]}]]")
    check_eval("(try (freeze [(cell 1)]) catch {^message m} m)",
               "\"freeze cannot freeze Cell\"")

  test "deep freeze traverses node metadata":
    let frozen = run(compileSource("(freeze `(x @info {^items [1]}))"),
                     newGlobalScope())
    check frozen.meta["info"].isImmutable
    check frozen.meta["info"].mapEntries["items"].isImmutable

  test "Send validation traverses node metadata":
    expect GeneError:
      discard run(compileSource(
        "(var n (freeze_shallow `(x @state %(cell 1)))) " &
        "(var ch (channel ^capacity 1)) (ch ~ send n)"),
        newGlobalScope())

suite "spec — numeric boundaries from design":
  test "Int has mathematical integer semantics":
    check_eval("[(+ 9223372036854775807 1) " &
               " (* 100000000000000000000 100000000000000000000) " &
               " (< 9223372036854775808 9223372036854775809)]",
               "[9223372036854775808 " &
               "10000000000000000000000000000000000000000 " &
               "true]")

  test "fixed-width integer annotations are range checked":
    check_eval("(fn signed [x : SignedInt] x) " &
               "(fn unsigned [x : UnsignedInt] x) " &
               "[(signed -1) (unsigned 18446744073709551616)]",
               "[-1 18446744073709551616]")
    expect GeneError:
      discard run(compileSource("(fn unsigned [x : UnsignedInt] x) " &
                                "(unsigned -1)"),
                  newGlobalScope())
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
    check_eval("(fn single [x : F32] x) (single 3.5)", "3.5")
    check_eval("(try (fn single [x : F32] x) (single 1e39) " &
               "catch (TypeError ^expected e) e)",
               "\"F32\"")
    check_eval("(fn double [x : F64] 1) (double 1e39)", "1")

  test "C ABI scalar annotations are explicit range checked boundaries":
    check_eval("C/Int32", "(c_abi_type Int32)")
    check_eval("(fn int32 [x : C/Int32] x) " &
               "[(int32 -2147483648) (int32 2147483647)]",
               "[-2147483648 2147483647]")
    check_eval("(fn byte [x : C/UInt8] x) [(byte 0) (byte 255)]",
               "[0 255]")
    check_eval("(fn cbool [x : C/Bool] x) (cbool false)", "false")
    check_eval("(fn cstr [x : C/CStr] x) (cstr \"ok\")", "\"ok\"")
    check_eval("(try (fn int32 [x : C/Int32] x) (int32 2147483648) " &
               "catch (TypeError ^expected e) e)",
               "\"C/Int32\"")
    check_eval("(try (fn cstr [x : C/CStr] x) (cstr \"bad\\0str\") " &
               "catch (TypeError ^expected e) e)",
               "\"C/CStr\"")

  test "C pointer annotations are opaque checked boundaries":
    var releases = 0
    proc releasePtr(address: pointer) {.nimcall.} =
      inc releases

    let scope = newGlobalScope()
    scope.define("ptr", newCPtr(cast[pointer](0x1234'u), newSym("C/Char")))
    scope.define("const_ptr",
                 newCConstPtr(cast[pointer](0x2345'u), newSym("C/Char")))
    scope.define("owned",
                 newCOwnedPtr(cast[pointer](0x3456'u), releasePtr,
                              newSym("C/Char")))

    check run(compileSource("((fn [p : (C/Ptr C/Char)] p) ptr)"),
              scope).print() == "(c_ptr)"
    check run(compileSource("((fn [p : (C/ConstPtr C/Char)] p) const_ptr)"),
              scope).print() == "(c_const_ptr)"
    check run(compileSource("((fn [p : (C/NullablePtr C/Char)] true) nil)"),
              scope).print() == "true"
    check run(compileSource("((fn [p : (C/OwnedPtr C/Char)] true) owned)"),
              scope).print() == "true"
    expect GeneError:
      discard run(compileSource("((fn [p : (C/Ptr C/Char)] p) const_ptr)"),
                  scope)
    check run(compileSource("[(C/close owned) (C/closed? owned)]"),
              scope).print() == "[nil true]"
    check releases == 1

  test "C slice annotations are opaque pointer-length boundaries":
    let scope = newGlobalScope()
    scope.define("slice", newCSlice(cast[pointer](0x4567'u), 8,
                                    newSym("C/Char")))
    scope.define("empty", newCSlice(nil, 0, newSym("C/Char")))
    scope.define("other", newCSlice(cast[pointer](0x5678'u), 8,
                                    newSym("C/Int32")))

    check run(compileSource("((fn [s : (C/Slice C/Char)] s) slice)"),
              scope).print() == "(c-slice 8)"
    check run(compileSource("((fn [s : (C/Slice C/Char)] s) empty)"),
              scope).print() == "(c-slice null 0)"
    expect GeneError:
      discard run(compileSource("((fn [s : (C/Slice C/Char)] s) other)"),
                  scope)

  test "Buffer annotations are Gene-owned typed storage":
    check_eval("(var b (buffer C/UInt8 [1 2])) " &
               "[(Buffer/len b) (Buffer/get b 1) " &
               "(Buffer/set! b 0 9) (Buffer/to_list b)]",
               "[2 2 9 [9 2]]")
    check_eval("((fn [b : (Buffer C/UInt8)] true) " &
               "(buffer C/UInt8 [1 2]))",
               "true")
    check_eval("((fn [b : (Buffer Int)] true) (buffer [1 2]))", "true")
    expect GeneError:
      discard run(compileSource("(buffer C/UInt8 [256])"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("((fn [b : (Buffer C/UInt8)] b) " &
                                "(buffer C/Int32 [1]))"),
                  newGlobalScope())

  test "Device buffers are opaque native-compute handles":
    check_eval("(var b (Device/buffer Device/Compute \"mock\" C/Int64 4)) " &
               "[(Device/Buffer/backend b) " &
               " (Device/Buffer/elem_type b) " &
               " (Device/Buffer/len b) " &
               " ((fn [buf : Device/Buffer] (Device/Buffer/len buf)) b) " &
               " ((fn [buf : (Device/Buffer C/Int64)] " &
               "    (Device/Buffer/elem_type buf)) b) " &
               " b]",
               "[\"mock\" C/Int64 4 4 C/Int64 (device-buffer mock C/Int64 4)]")
    expect GeneError:
      discard run(compileSource("(Device/buffer nil \"mock\" C/Int64 1)"),
                  newGlobalScope())
    check_eval("(var b (Device/buffer Device/Compute \"mock\" C/Int64 4)) " &
               "(try ((fn [buf : (Device/Buffer F64)] buf) b) " &
               "catch (TypeError ^expected e) e)",
               "\"(Device/Buffer F64)\"")

  test "FFI runtime loading requires explicit authority":
    check_eval("Ffi/Load", "(ffi_type Load)")
    let scope = newGlobalScope()
    scope.define("native", newFfiLoadCapability())
    check run(compileSource("((fn [cap : Ffi/Load] cap) native)"),
              scope).print() == "(ffi-load)"
    expect GeneError:
      discard run(compileSource("((fn [cap : Ffi/Load] cap) nil)"), scope)
    expect GeneError:
      discard run(compileSource("(ffi/open nil \"libmissing-gene-new\")"),
                  scope)
    expect GeneError:
      discard run(compileSource("(ffi/open native \"libmissing-gene-new\")"),
                  scope)

suite "spec — nominal types from design":
  test "child types preserve inherited field schemas":
    expect GeneError:
      discard run(compileSource("(type Animal ^props {^name Str}) " &
                                "(type Dog ^is Animal ^props {^name Any})"),
                  newGlobalScope())

  test "type body schemas validate positional node body":
    check_eval("(type Note ^props {^text Str}) " &
               "(type Task ^props {^id Int} ^body [Note...]) " &
               "(var t (Task ^id 1 (Note ^text \"a\") (Note ^text \"b\"))) " &
               "[(t ~ /id) ((t ~ /0) ~ /text) ((t ~ /1) ~ /text)]",
               "[1 \"a\" \"b\"]")
    check_eval("(type Pair ^body [Int Str]) " &
               "(try (Pair 1 2) catch (TypeError ^where w) w)",
               "\"body field 1 for Pair\"")

  test "type layout promises are reserved":
    expect GeneError:
      discard compileSource("(type Packed ^sealed true ^props {})")

suite "spec — direct construction, new, and ctor (design §7.1.1)":
  test "ctor mutates pre-created self and returns the validated instance":
    check_eval("(type Point ^props {^x F64 ^y F64} " &
               "  (ctor [x : F64, y : F64] " &
               "    (self ~ Node/set_prop! `x x) " &
               "    (self ~ Node/set_prop! `y y))) " &
               "(var p (new Point 10.0 20.0)) [p/x p/y]",
               "[10.0 20.0]")

  test "ctor uses function-style argument matching with named defaults":
    check_eval("(type User ^props {^name Str ^age Int ^active Bool} " &
               "  (ctor [name : Str, ^age : Int = 0, ^active : Bool = true] " &
               "    (self ~ Node/set_prop! `name name) " &
               "    (self ~ Node/set_prop! `age age) " &
               "    (self ~ Node/set_prop! `active active))) " &
               "(var u (new User \"Ada\" ^age 37)) [u/name u/age u/active]",
               "[\"Ada\" 37 true]")

  test "ctor declares checked errors":
    check_eval("(type ValidationError ^props {^message Str} ^impl [Error]) " &
               "(impl Error for ValidationError) " &
               "(type Port ^props {^value Int} " &
               "  (ctor [n : Int] ^errors [ValidationError] " &
               "    (if (&& (>= n 0) (<= n 65535)) " &
               "      (self ~ Node/set_prop! `value n) " &
               "      (fail (ValidationError ^message \"invalid port\"))))) " &
               "(var ok (new Port 8080)) " &
               "[(try (new Port 99999) catch (ValidationError ^message m) m) " &
               " ok/value]",
               "[\"invalid port\" 8080]")

  test "new validates the completed instance against the schema":
    check_eval("(type Bad ^props {^v Int} (ctor [] nil)) " &
               "(try (new Bad) catch _ \"required field unset\")",
               "\"required field unset\"")
    check_eval("(type Sneaky ^props {^a Int} " &
               "  (ctor [] (self ~ Node/set_prop! `a 1) " &
               "           (self ~ Node/set_prop! `zzz 9))) " &
               "(try (new Sneaky) catch _ \"unknown field\")",
               "\"unknown field\"")
    check_eval("(type Typed ^props {^a Int} " &
               "  (ctor [] (self ~ Node/set_prop! `a \"nope\"))) " &
               "(try (new Typed) catch (TypeError ^where w) w)",
               "\"field 'a' for Typed\"")

  test "(T ...) is direct data construction and never runs the ctor":
    check_eval("(type Port2 ^props {^value Int} " &
               "  (ctor [n : Int] (self ~ Node/set_prop! `value (* n 2)))) " &
               "(var direct (Port2 ^value 8080)) " &
               "(var made (new Port2 8080)) " &
               "[direct/value made/value]",
               "[8080 16160]")

  test "direct construction still schema-validates on a ctor type":
    check_eval("(type Port3 ^props {^value Int} " &
               "  (ctor [n : Int] (self ~ Node/set_prop! `value n))) " &
               "(try (Port3 ^value \"nope\") catch (TypeError ^where w) w)",
               "\"field 'value' for Port3\"")
    check_eval("(type Port4 ^props {^value Int} " &
               "  (ctor [n : Int] (self ~ Node/set_prop! `value n))) " &
               "(try (Port4) catch _ \"missing field\")",
               "\"missing field\"")

  test "construct_type validates a runtime map against one real type schema":
    check_eval("(type Request ^props {^name Str ^count Int?}) " &
               "(var request_type Request) " &
               "(construct_type request_type {^name \"build\" ^count 2})",
               "((type Request) ^name \"build\" ^count 2)")
    check_eval("(type Request ^props {^name Str}) " &
               "(try (construct_type Request {^name 7}) " &
               " catch (TypeError ^where w) w)",
               "\"field 'name' for Request\"")

  test "types reflect their closed property schema as Gene data":
    check_eval("(type Request ^props {^name Str ^count Int?}) " &
               "(var f (Request ~ fields)) " &
               "[(Request ~ name) f/0/name f/0/optional f/0/type " &
               " f/1/name f/1/optional f/1/type]",
               "[\"Request\" \"name\" false Str \"count\" true Int?]")

  test "new without a ctor falls back to direct schema mapping":
    check_eval("(type Plain ^props {^name Str ^age Int}) " &
               "(var p (new Plain ^name \"Ada\" ^age 37)) [p/name p/age]",
               "[\"Ada\" 37]")
    check_eval("(try (new 5) catch _ \"not a type\")",
               "\"not a type\"")

  test "child ctor covers inherited schema; parent ctor is not chained":
    check_eval("(type Animal ^props {^name Str}) " &
               "(type Dog ^is Animal ^props {^breed Str} " &
               "  (ctor [name : Str, breed : Str] " &
               "    (self ~ Node/set_prop! `name name) " &
               "    (self ~ Node/set_prop! `breed breed))) " &
               "(var d (new Dog \"Rex\" \"Lab\")) [d/name d/breed]",
               "[\"Rex\" \"Lab\"]")

  test "ctor fills body fields through mutable node APIs":
    check_eval("(type Pair ^body [Int Int] " &
               "  (ctor [a : Int, b : Int] " &
               "    (self ~ Node/push_body! a) " &
               "    (self ~ Node/push_body! b))) " &
               "(var pr (new Pair 1 2)) [pr/0 pr/1]",
               "[1 2]")
    check_eval("(type Solo ^body [Int] (ctor [] nil)) " &
               "(try (new Solo) catch _ \"body count\")",
               "\"body count\"")

  test "a type defines at most one ctor":
    expect GeneError:
      discard compileSource("(type T ^props {} (ctor [] nil) (ctor [] nil))")

  test "in-progress instances cannot escape construction":
    check_eval("(var leaked nil) " &
               "(type T ^props {^x Int} " &
               "  (ctor [] (set leaked self) " &
               "    (self ~ Node/set_prop! `x 1))) " &
               "[(try (new T) catch _ \"blocked\") leaked]",
               "[\"blocked\" nil]")
    check_eval("(var box (cell nil)) " &
               "(type T ^props {^x Int} " &
               "  (ctor [] (box ~ Cell/set self) " &
               "    (self ~ Node/set_prop! `x 1))) " &
               "[(try (new T) catch _ \"blocked\") (box ~ Cell/get)]",
               "[\"blocked\" nil]")
    check_eval("(type T ^props {^x Int} " &
               "  (ctor [] [self] (self ~ Node/set_prop! `x 1))) " &
               "(try (new T) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(type T ^props {^x Int} ^impl [Error] " &
               "  (ctor [] (fail self))) " &
               "(impl Error for T) " &
               "(try (new T) catch (T) \"leaked\" catch _ \"blocked\")",
               "\"blocked\"")
    expect GeneError:
      discard run(compileSource(
        "(type T ^props {^x Int} (ctor [] (panic self))) (new T)"),
        newGlobalScope())
    check_eval("(var leaked nil) " &
               "(type T ^props {^x Int} " &
               "  (ctor [] (set leaked (fn [] self)) " &
               "    (self ~ Node/set_prop! `x 1))) " &
               "[(try (new T) catch _ \"blocked\") leaked]",
               "[\"blocked\" nil]")
    check_eval("(type T ^props {^x Int} " &
               "  (message inspect [self] self/x) " &
               "  (ctor [] (self ~ inspect) " &
               "    (self ~ Node/set_prop! `x 1))) " &
               "(try (new T) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(type T ^props {^x Int} " &
               "  (ctor [] (spawn self) " &
               "    (self ~ Node/set_prop! `x 1))) " &
               "(try (new T) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(var ch (channel ^capacity 1)) " &
               "(type T ^props {^x Int} ^impl [Send] " &
               "  (ctor [] (ch ~ Channel/send self) " &
               "    (self ~ Node/set_prop! `x 1))) " &
               "(impl Send for T) " &
               "(try (new T) catch _ \"blocked\")",
               "\"blocked\"")

  test "successful construction clears the publication guard":
    check_eval("(type T ^props {^x Int} ^impl [Send] " &
               "  (ctor [] (self ~ Node/set_prop! `x 1))) " &
               "(impl Send for T) " &
               "(var ch (channel ^capacity 1)) (var value (new T)) " &
               "(ch ~ Channel/send value) " &
               "(var received (ch ~ Channel/recv)) received/x",
               "1")

  test "failed construction unwinds ensure cleanup":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) (var cleaned (cell false)) " &
               "(type T ^props {^x Int} " &
               "  (ctor [] " &
               "    (try (fail (Boom ^message \"bad\")) " &
               "      ensure (cleaned ~ Cell/set true)))) " &
               "(try (new T) catch (Boom) nil) (cleaned ~ Cell/get)",
               "true")

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

  test "optional type sugar T? is (? T) (design §7.2)":
    check_eval("(var a : Int? nil) a", "nil")
    check_eval("(var b : Int? 5) b", "5")
    check_eval("(fn f [x : Str?] : Str? x) [(f nil) (f \"hi\")]",
               "[nil \"hi\"]")
    check_eval("(fn g [xs : (List Int?)] (size xs)) (g [1 nil 3])", "3")
    check_eval("(type Box ^props {^v Int}) (fn h [b : Box?] : Box? b) (h nil)",
               "nil")
    check_eval("(try (var a : Int? \"bad\") a catch (TypeError ^expected e) e)",
               "\"Int?\"")
    # `?` is special only in type position; a `name?` predicate call is untouched.
    check_eval("(fn done? [x] (== x 0)) [(done? 0) (done? 1)]", "[true false]")

  test "callable runtime values have explicit boundary types":
    check_eval("(fn keep-native [f : NativeFn] f) (keep-native +)",
               "(native-fn +)")
    check_eval("(try (fn keep-fn [f : Fn] f) (keep-fn +) " &
               "catch (TypeError ^expected e) e)",
               "\"Fn\"")
    check_eval("(fn keep-selector [s : Selector] s) (keep-selector /name)",
               "(select name)")
    check_eval("(try (fn keep-selector [s : Selector] s) " &
               "     (keep-selector (quote (name))) " &
               "catch (TypeError ^expected e) e)",
               "\"Selector\"")
    check_eval("(fn keep-callable [f : Callable] f) (keep-callable +)",
               "(native-fn +)")
    check_eval("(type AddN ^props {^n Int}) " &
               "(impl Callable for AddN " &
               "  (message apply [self call] (+ self/n (call ~ /0)))) " &
               "(fn invoke [f : Callable] (f 2)) " &
               "(invoke (AddN ^n 3))",
               "5")
    # The Call envelope exposes the source call site (design §3 `^site Node?`).
    check_eval("(type Probe ^props {}) " &
               "(impl Callable for Probe (message apply [self call] call/site)) " &
               "(var p (Probe)) (p 1 2)",
               "(p 1 2)")

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
    check_eval("(fn (first item) [b : (Buffer item)] : item " &
               "  (Buffer/get b 0)) " &
               "(first (buffer [5 6]))",
               "5")

  test "generic calls can request selective monomorphization metadata":
    let chunk = compileSource("(fn (identity item) [x : item] : item x) " &
                              "(identity ^types [Int] 1)")
    check chunk.monomorphizations.len == 1
    check chunk.monomorphizations[0].functionName == "identity"
    check chunk.monomorphizations[0].typeArgs[0].print() == "Int"
    check "monomorphizations:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "identity<Int>" in c
    check "static const GeneMonomorphizationSpec gene_monomorphizations[] GENE_MAYBE_UNUSED = {" in c
    check "{\"identity\", \"Int\"}," in c
    check_eval("(fn (identity item) [x : item] : item x) " &
               "(identity ^types [Int] 1)",
               "1")
    expect GeneError:
      discard compileSource("(fn (identity item) [x : item] : item x) " &
                            "(identity ^types Int 1)")

suite "spec — static effects from design":
  test "^effects rows are reserved in MVP":
    expect GeneError:
      discard compileSource("(fn f ^effects [fs] [] 1)")
    expect GeneError:
      discard compileSource("(protocol Run " &
                            "  (message run ^effects [fs] [self]))")
    expect GeneError:
      discard compileSource("(protocol Run (message run [self])) " &
                            "(impl Run for Job " &
                            "  (message run ^effects [fs] [self] 1))")

suite "spec — short-circuit operators from design":
  test "&& and || yield the last operand evaluated":
    check_eval("[(&& 1 2) (&& nil 2) (&& false 2) (&& 1 2 nil 4) (&&)]",
               "[2 nil false nil true]")
    check_eval("[(|| nil \"d\") (|| void \"d\") (|| \"a\" \"b\") (||)]",
               "[\"d\" \"d\" \"a\" nil]")

  test "&& and || stop evaluating at the deciding operand":
    check_eval("(var n 0) (&& false (set n 1)) (|| true (set n 2)) n", "0")
    check_eval("(|| nil false 3 (panic \"not reached\"))", "3")
    check_eval("(&& 1 nil (panic \"not reached\"))", "nil")

  test "! is unary truthiness negation over false, nil, void":
    check_eval("[(! nil) (! void) (! false) (! 1) (! \"\")]",
               "[true true true false false]")
    expect GeneError:
      discard compileSource("(! 1 2)")
    expect GeneError:
      discard compileSource("(!)")

suite "spec — checked errors from design":
  test "Never contributes no errors and rows deduplicate":
    check_eval("(fn quiet ^errors [Never] [] 1) (quiet)", "1")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(fn raise-boom ^errors [Never Boom Boom] [] " &
               "  (fail (Boom ^message \"x\"))) " &
               "(try (raise-boom) catch (Boom ^message m) m)",
               "\"x\"")

suite "spec — pattern destructuring from design":
  test "match, catch, and for bindings are branch-local":
    expect GeneError:
      discard run(compileSource("(match [1 2] (when [a b] (+ a b))) a"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(type Boom ^props {^message Str} ^impl [Error]) " &
                                "(impl Error for Boom) " &
                                "(try (fail (Boom ^message \"x\")) " &
                                "catch (Boom ^message m) m) m"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(for x in [1 2 3] x) x"), newGlobalScope())

  test "var pattern bindings extend the enclosing scope per design §8.0.1":
    check_eval("(var [x y] [10 20]) (+ x y)", "30")
    check_eval("(var [a [b c]] [1 [2 3]]) [a b c]", "[1 2 3]")
    check_eval("(var {^name n ^age a} {^name \"Ada\" ^age 36}) (+ a 0)",
               "36")
    check_eval("(var s 0) " &
               "(match [1 2] " &
               "  (when [a b] " &
               "    (do (set s (+ a b)) nil)) " &
               "  (else nil)) " &
               "s",
               "3")
    check_eval("(var n 0) " &
               "(for x in [1 2 3] " &
               "  (do (set n (+ n x)) nil)) " &
               "n",
               "6")
    check_eval("(var [a b] [1 2]) [a b]",
               "[1 2]")
    check_eval("(var [a b] [1 2]) " &
               "(var [c d] [3 4]) " &
               "[a b c d]",
               "[1 2 3 4]")
    expect MatchError:
      discard run(compileSource("(var [a b] [1 2 3]) (+ a b)"),
                  newGlobalScope())

  test "match and catch bindings are branch-local at runtime per §8.0.1":
    # Arm 1 binds `a`; arm 2 binds `map`. The body of arm 1 references
    # `map`. Because each arm's slot table is fresh, `map` here resolves
    # to the runtime global, not the sibling's pattern binding — the
    # false positive the previous compile-time cross-check had was
    # rejecting exactly this case.
    check_eval("(match [1] " &
               "  (when [a] map) " &
               "  (when [map] map))",
               "(native-fn map)")
    # Arm 1 doesn't match `[9]` (2-tuple needed, 1-tuple given); arm 2
    # matches and references `map`. Sibling-leak would surface as
    # something else; runtime isolation gives us the global.
    check_eval("(match [9] " &
               "  (when [a b] \"first\") " &
               "  (when [c] map))",
               "(native-fn map)")
    # Arm 1 matches `[1]` and returns the literal; arm 2 never runs.
    check_eval("(match [1] " &
               "  (when [a] \"first\") " &
               "  (when [c] map))",
               "\"first\"")
  test "for iterates streams lazily and closes on pattern failure":
    check_eval("(var hits (cell 0)) " &
               "(var source (map (to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
               "(var first-hits 0) " &
               "(for x in source " &
               "  (if (== x 1) (set first-hits (hits ~ Cell/get)))) " &
               "first-hits",
               "1")
    check_eval("(var hits (cell 0)) " &
               "(var source (map (to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
               "(try (for [a b] in source nil) " &
               " catch (MatchError ^message m) nil) " &
               "[(hits ~ Cell/get) (source ~ Stream/has_next)]",
               "[1 false]")

  test "for treats strings as char streams":
    check_eval("(var out [nil nil]) " &
               "(var i 0) " &
               "(for ch in \"Aé\" " &
               "  (set out (List/assoc out i ch)) " &
               "  (set i (+ i 1))) " &
               "out",
               "['A' 'é']")
    expect GeneError:
      discard compileSource("(for ch \"Aé\" ch)")

  test "loops support break and continue":
    check_eval("(var i 0) (var sum 0) " &
               "(while true " &
               "  (set i (+ i 1)) " &
               "  (if (== i 2) (then (continue))) " &
               "  (if (> i 4) (then (break))) " &
               "  (set sum (+ sum i))) " &
               "[sum i]",
               "[8 5]")
    check_eval("(var i 0) (var sum 0) " &
               "(loop " &
               "  (set i (+ i 1)) " &
               "  (if (== i 2) (then (continue))) " &
               "  (if (> i 4) (then (break))) " &
               "  (set sum (+ sum i))) " &
               "[sum i]",
               "[8 5]")
    check_eval("(var i 0) (var sum 0) " &
               "(repeat 6 " &
               "  (set i (+ i 1)) " &
               "  (if (== i 2) (then (continue))) " &
               "  (if (> i 4) (then (break))) " &
               "  (set sum (+ sum i))) " &
               "[sum i]",
               "[8 5]")
    check_eval("(var sum 0) " &
               "(repeat i in 5 " &
               "  (set sum (+ sum i))) " &
               "sum",
               "10")
    check_eval("(var sum 0) " &
               "(repeat i in 6 " &
               "  (if (== i 2) (then (continue))) " &
               "  (if (> i 4) (then (break))) " &
               "  (set sum (+ sum i))) " &
               "sum",
               "8")
    check_eval("(var n 0) (repeat (do (set n (+ n 1)) 3) nil) n", "1")
    check_eval("(var n 0) (repeat i in (do (set n (+ n 1)) 3) nil) n", "1")
    check_eval("(var n 0) (repeat 0 (set n 1)) (repeat -1 (set n 2)) " &
               "(repeat i in 0 (set n 3)) (repeat j in -1 (set n 4)) n",
               "0")
    check_eval("(var s 0) " &
               "(for x in [1 2 3 4 5] " &
               "  (if (== x 2) (then (continue))) " &
               "  (if (> x 4) (then (break))) " &
               "  (set s (+ s x))) " &
               "s",
               "8")
    check_eval("(var hits (cell 0)) " &
               "(var source (map (to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
               "(for x in source (break)) " &
               "[(hits ~ Cell/get) (source ~ Stream/has_next)]",
               "[1 false]")
    expect GeneError:
      discard compileSource("(break)")
    expect GeneError:
      discard compileSource("(continue)")
    expect GeneError:
      discard compileSource("(loop)")
    expect GeneError:
      discard compileSource("(repeat)")
    expect GeneError:
      discard compileSource("(repeat [i] in 3 nil)")

  test "for iterates maps sets nodes and ranges per design §8.1":
    # Drive `for` itself (its iteratorStream path), not the to_stream helpers,
    # accumulating each visited item so ordering is asserted.
    check_eval("(var acc []) " &
               "(for [k v] in {^a 1 ^b 2} (set acc [acc... [k v]])) " &
               "acc",
               "[[a 1] [b 2]]")
    check_eval("(var acc []) " &
               "(for [k v] in {{\"x\" : 1 \"y\" : 2}} (set acc [acc... [k v]])) " &
               "acc",
               "[[\"x\" 1] [\"y\" 2]]")
    check_eval("(var acc []) " &
               "(for x in (Set 3 1 2) (set acc [acc... x])) " &
               "acc",
               "[3 1 2]")
    check_eval("(var acc []) " &
               "(for x in (quote (foo 1 2 3)) (set acc [acc... x])) " &
               "acc",
               "[1 2 3]")
    check_eval("(var acc []) " &
               "(for x in (range 0 4 2 true) (set acc [acc... x])) " &
               "acc",
               "[0 2 4]")
    check_eval("[(for item in nil item) " &
               " (for item in void item) " &
               " (for item in [] item)]",
               "[nil nil nil]")
    expect GeneError:
      discard run(compileSource("(for x in 7 x)"),
                  newGlobalScope())

  test "for over streams returns nil and skips the body when empty":
    check_eval("(var empty (to_stream [])) " &
               "(var seen 0) " &
               "(var done " &
               "  (for _ in empty " &
               "    (set seen (+ seen 1)) " &
               "    \"miss\")) " &
               "[seen done]",
               "[0 nil]")

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

suite "spec — Int overflow contract per design §7.4":
  test "small Int arithmetic stays in the int64 fixnum fast path":
    check_eval("(+ 1 2)", "3")
    check_eval("(- 10 4)", "6")
    check_eval("(* 3 7)", "21")
    check_eval("(+ 1 2 3 4 5)", "15")
  test "int64 boundary arithmetic promotes to an exact bignum":
    check_eval("(+ 9223372036854775807 1)", "9223372036854775808")
    check_eval("(- (- 0 9223372036854775807) 1)", "-9223372036854775808")
    check_eval("(* 9223372036854775807 9223372036854775807)",
               "85070591730234615847396907784232501249")
  test "Int arithmetic never wraps silently":
    # Pin the contract: the result is the exact mathematical sum,
    # not a wraparound into the int64 fast path.
    check_eval("(+ 9223372036854775807 1)", "9223372036854775808")
    check_eval("(* 2 4611686018427387904)", "9223372036854775808")
    check_eval("(+ 9223372036854775807 9223372036854775807)",
               "18446744073709551614")

suite "spec — Range type":
  test "range constructs immutable integer ranges":
    check_eval("(range 1 4)", "(range 1 4)")
    check_eval("[(== (range 0 3) (range 0 3)) " &
               " (== (range 0 3) (range 0 4)) " &
               " (== (hash (range 0 3)) (hash (range 0 3)))]",
               "[true false true]")
    expect GeneError:
      discard run(compileSource("(range 0 10 0)"), newGlobalScope())

  test "range exposes start stop step inclusive and size":
    check_eval("(var r (range 2 8 2)) " &
               "[(r ~ start) (r ~ stop) (r ~ step) " &
               " (r ~ inclusive?) (r ~ size)]",
               "[2 8 2 false 3]")
    check_eval("(var r (range 0 4 2 true)) " &
               "[(r ~ inclusive?) (r ~ size) r]",
               "[true 3 (range 0 4 2 true)]")
    check_eval("((range -9223372036854775808 9223372036854775807 1 true) ~ size)",
               "18446744073709551616")

  test "range streams lazily and for iterates ranges":
    check_eval("(into (to_stream (range 0 5)) [])",
               "[0 1 2 3 4]")
    check_eval("(into (to_stream (range 5 0 -2)) [])",
               "[5 3 1]")
    check_eval("(into (to_stream (range 0 4 2 true)) [])",
               "[0 2 4]")
    check_eval("(var sum 0) " &
               "(for x in (range 0 5) " &
               "  (set sum (+ sum x))) " &
               "sum",
               "10")

  test "range satisfies Range and typed Stream boundaries":
    check_eval("(fn size-of [r : Range] (r ~ size)) " &
               "(size-of (range 0 3))",
               "3")
    check_eval("(fn first-int [s : (Stream Int Never)] (s ~ Stream/next)) " &
               "(first-int (to_stream (range 5 6)))",
               "5")

suite "spec — Date/time type family":
  test "date time and datetime literals print canonically":
    check_read("2026-07-04", "2026-07-04")
    check_read("09:30", "09:30")
    check_read("09:30:15.123400", "09:30:15.1234")
    check_read("2026-07-04T09:30", "2026-07-04T09:30")
    check_read("2026-07-04T09:30Z", "2026-07-04T09:30:00Z")
    check_read("2026-07-04T09:30:15.123456-04:00[America/New_York]",
               "2026-07-04T09:30:15.123456-04:00[America/New_York]")
    check_read("09:30[America/New_York]", "09:30:00[America/New_York]")
    expect ReadError:
      discard read("2026-07-04T09:30[America/New_York]")
    expect ReadError:
      discard read("2026-02-30")

  test "constructors expose date time timezone and duration values":
    check_eval("[(date 2026 7 4) (time 9 30 15 123400 -240 \"America/New_York\") " &
               " (datetime 2026 7 4 9 30 15 123456 0 \"UTC\") " &
               " (timezone \"UTC\") (duration 1500000)]",
               "[2026-07-04 09:30:15.1234-04:00[America/New_York] " &
               "2026-07-04T09:30:15.123456Z (timezone 0 \"UTC\") " &
               "(duration 1500000)]")

  test "date time family accessors and annotations work":
    check_eval("(fn y [d : Date] (d ~ year)) (y 2026-07-04)", "2026")
    check_eval("(var t 09:30:15.123456-04:00[America/New_York]) " &
               "[(t ~ hour) (t ~ minute) (t ~ second) " &
               " (t ~ microsecond) (t ~ offset) (t ~ timezone)]",
               "[9 30 15 123456 -240 \"America/New_York\"]")
    check_eval("(var dt 2026-07-04T09:30Z) " &
               "[(dt ~ year) (dt ~ month) (dt ~ day) " &
               " (dt ~ hour) (dt ~ minute) (dt ~ second) " &
               " (dt ~ offset) (dt ~ timezone)]",
               "[2026 7 4 9 30 0 0 \"UTC\"]")
    check_eval("(var z (timezone \"+08:00\" \"Asia/Shanghai\")) " &
               "[(z ~ offset) (z ~ name)]",
               "[480 \"Asia/Shanghai\"]")
    check_eval("(var d (duration 1500000)) " &
               "[(d ~ microseconds) (d ~ milliseconds) (d ~ seconds)]",
               "[1500000 1500.0 1.5]")
    check_eval("(fn f [d : Duration] (d ~ seconds)) (f (duration 2000000))",
               "2.0")

  test "date time values are immutable and hash stable":
    check_eval("[(== 2026-07-04 2026-07-04) " &
               " (== 09:30 09:31) " &
               " (== (hash 2026-07-04T09:30Z) (hash 2026-07-04T09:30Z))]",
               "[true false true]")

suite "spec — protocol derive from design":
  test "protocol-local derive can generate an impl":
    check_eval("(protocol HasLabel " &
               "  (message label [self] : Str) " &
               "  (derive [t : Type, req] " &
               "    `(impl HasLabel for %t " &
               "       (message label [self] : Str self/name)))) " &
               "(type MenuItem ^props {^name Str} ^derive [HasLabel]) " &
               "((MenuItem ^name \"Soup\") ~ label)",
               "\"Soup\"")

  test "protocol-local derive is limited to its own impls":
    expect GeneError:
      discard run(compileSource("(protocol Other) " &
                                "(protocol HasLabel " &
                                "  (derive [t : Type, req] `(impl Other for %t))) " &
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
  test "AtomicCell load, store, swap, and compare_exchange are explicit mutation":
    check_eval("(var state (atomic_cell 0)) " &
               "[(state ~ AtomicCell/load) " &
               " (state ~ AtomicCell/store 1) " &
               " (state ~ AtomicCell/swap 2) " &
               " (state ~ AtomicCell/compare_exchange 2 3) " &
               " (state ~ AtomicCell/load)]",
               "[0 1 1 true 3]")

suite "spec — mutable containers from design":
  test "persistent and mutating container updates are explicit":
    check_eval("(var xs #[1 2 3]) " &
               "(var xs2 (xs ~ List/assoc 1 20)) " &
               "(var ys [1 2]) " &
               "(ys ~ List/set! 0 9) " &
               "(var zs []) " &
               "(var pushed (zs ~ List/push! void)) " &
               "(var m #{^a 1}) " &
               "(var m2 (m ~ Map/assoc \"b\" 2)) " &
               "(var mm {^a 1}) " &
               "(mm ~ Map/put! \"b\" 3) " &
               "(var n (quote (user ^name \"Ada\"))) " &
               "(n ~ Node/set_prop! \"name\" \"Bob\") " &
               "[xs xs2 ys pushed zs m m2 (mm ~ Map/get \"b\") (n ~ /name)]",
               "[#[1 2 3] #[1 20 3] [9 2] nil [nil] #{^a 1} #{^a 1 ^b 2} 3 \"Bob\"]")

  test "List/push! rejects immutable lists":
    check_eval("(try (#[1] ~ List/push! 2) " &
               " catch (Error ^message message) message)",
               "\"cannot mutate immutable List\"")

suite "spec — void normalization from design":
  test "void does not persist in prop storage":
    check_eval("[{^a void ^b 1} " &
               " (quote (x ^a void ^b 1)) " &
               " (do (type T ^props {^a Int?}) " &
               "     (var t (T ^a void)) " &
               "     t/a)]",
               "[{^b 1} (x ^b 1) void]")

suite "spec — optionality lives on the type, not the key":
  test "a nil-admitting field type is omissible and nilable":
    check_eval("(type T ^props {^a Str?}) " &
               "(var t (T)) [(if t/a 1 0) t/a]", "[0 void]")
    check_eval("(type T ^props {^a Str?}) (T ^a nil)",
               "((type T) ^a nil)")
    check_eval("(type T ^props {^a (? Str)}) (T)", "((type T))")
    check_eval("(type T ^props {^a (| Str Nil)}) (T)", "((type T))")
  test "present nil and absent stay distinguishable by pattern":
    check_eval("(type T ^props {^a Str?}) " &
               "(fn has_a [t] (match t (when (T ^a x) true) (else false))) " &
               "[(has_a (T ^a nil)) (has_a (T))]",
               "[true false]")
  test "Any stays a required field — gradual slack is not optionality":
    check_eval("(type T ^props {^a Any}) " &
               "(try (T) catch {^message m} m)",
               geneString("missing required field 'a' for T"))
  test "an omitted nil-admitting named parameter binds nil":
    check_eval("(fn f [^w : Int?] [(if w 1 0) w]) (f)", "[0 nil]")
    check_eval("(fn f [^w : Int?] w) (f ^w 3)", "3")
  test "positional parameters stay positional under nilable types":
    check_eval("(fn f [a : Str?, b : Int] (if a b (- 0 b))) (f nil 5)", "-5")
    check_eval("(fn f [x : Int? = nil, y : Str = \"d\"] (if x \"x\" y)) (f)",
               geneString("d"))
  test "?-suffixed declaration names are loud errors with hints":
    for source in ["(type T ^props {^a? Str})",
                   "(fn f [^w? : Int] nil)",
                   "(fn f [x?] nil)",
                   "(macro m! [^a? x] `x)"]:
      try:
        discard run(compileSource(source), newGlobalScope())
        check false
      except GeneError as e:
        check "optionality moved to the type" in e.msg

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

  test "has_next surfaces producer errors without EndOfStream":
    check_eval("(try " &
               "  (var s (map (to_stream [1]) (fn [x] (/ 1 0)))) " &
               "  (s ~ Stream/has_next) " &
               "catch {^message m} m)",
               "\"division by zero\"")

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
    check_eval("(var pairs (to_pairs_stream {^a 1})) " &
               "(var pair (pairs ~ Stream/next)) " &
               "(fn key [x : Sym] x) (key pair/0)",
               "a")

  test "closing downstream stream helpers closes upstream":
    check_eval("(var source (to_stream [1 2])) " &
               "(var s (map source (fn [x] x))) " &
               "(s ~ Stream/close) " &
               "(source ~ Stream/has_next)",
               "false")
    check_eval("(var hits (cell 0)) " &
               "(var source (map (to_stream [1 2]) " &
               "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
               "(var s (take source 1)) " &
               "[(s ~ Stream/next) " &
               " (s ~ Stream/has_next) " &
               " (hits ~ Cell/get) " &
               " (source ~ Stream/has_next)]",
               "[1 false 1 true]")

  test "lazy streams own inline callables beyond the defining frame":
    # Regression: the stream must hold its callable strongly. An inline
    # lambda whose only other reference was the operand stack used to leave
    # the stream with a dangling weak captured-scope edge (use-after-free).
    check_eval("(fn make-pred [] (fn [x] (> x 1))) " &
               "(fn make-stream [] (filter (to_stream [1 2 3]) (make-pred))) " &
               "(into (make-stream) [])",
               "[2 3]")
    check_eval("(fn make-stream [] (map (to_stream [1 2]) (fn [x] (+ x 10)))) " &
               "(into (make-stream) [])",
               "[11 12]")

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
               "    (yield (if (== i 1) void i)) " &
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
               "  (for x in s (yield x))) " &
               "(var out (copy source)) " &
               "[(hits ~ Cell/get) " &
               " (out ~ Stream/next) " &
               " (hits ~ Cell/get) " &
               " (out ~ Stream/next) " &
               " (hits ~ Cell/get)]",
               "[0 1 1 2 2]")
    check_eval("(var hits (cell 0)) " &
               "(var source (map (to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
               "(fn take-one [s] : (Stream Int Never) " &
               "  (for x in s " &
               "    (if (== x 2) (then (break))) " &
               "    (yield x))) " &
               "(var out (take-one source)) " &
               "[(out ~ Stream/next) " &
               " (out ~ Stream/has_next) " &
               " (hits ~ Cell/get) " &
               " (source ~ Stream/has_next)]",
               "[1 false 2 false]")

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

  test "yield-void skips the item but does not leave the generator":
    check_eval("(fn skip [] : (Stream Int Never) " &
               "  (yield 1) " &
               "  (yield void) " &
               "  (yield 2)) " &
               "(var s (skip)) " &
               "[(s ~ Stream/next) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/has_next)]",
               "[1 2 false]")

  test "natural fall-through closes the generator with no item remaining":
    check_eval("(fn two [] : (Stream Int Never) " &
               "  (yield 1) " &
               "  (yield 2)) " &
               "(var s (two)) " &
               "[(s ~ Stream/next) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/has_next)]",
               "[1 2 false]")

  test "Stream/close after natural take exhaustion stays local":
    check_eval("(var upstream (to_stream [1 2 3 4 5])) " &
               "(var taken (take upstream 2)) " &
               "[(taken ~ Stream/next) " &
               " (taken ~ Stream/next) " &
               " (taken ~ Stream/has_next) " &
               " (upstream ~ Stream/has_next) " &
               " (do (taken ~ Stream/close) " &
               "     (upstream ~ Stream/next))]",
               "[1 2 false true 3]")
    check_eval("(var closes (cell 0)) " &
               "(fn source [] : (Stream Int Never) " &
               "  (try (yield 1) (yield 2) " &
               "   ensure (closes ~ Cell/update (fn [n] (+ n 1))))) " &
               "(var upstream (source)) " &
               "(for x in (take upstream 2) (break)) " &
               "[(closes ~ Cell/get) (upstream ~ Stream/has_next)]",
               "[1 false]")

  test "generator return is terminal and close unwinds ensure blocks":
    check_eval("(fn choose [yes] " &
               "  (if yes (then (return 7))) " &
               "  9) " &
               "[(choose true) (choose false)]",
               "[7 9]")
    check_eval("(var log (cell [])) " &
               "(fn note [x] (log ~ Cell/update (fn [xs] [xs... x]))) " &
               "(fn gen [] : (Stream Int Never) " &
               "  (try " &
               "    (try (yield 1) (return) " &
               "     ensure (note `inner)) " &
               "   ensure (note `outer))) " &
               "(var completed (gen)) " &
               "(completed ~ Stream/next) " &
               "(var done (completed ~ Stream/has_next)) " &
               "(var closed (gen)) " &
               "(closed ~ Stream/next) " &
               "(closed ~ Stream/close) " &
               "[done (log ~ Cell/get)]",
               "[false [inner outer inner outer]]")
    expect GeneError:
      discard compileSource("(fn bad [] : (Stream Int Never) " &
                            "  (yield 1) (return 2))")
    expect GeneError:
      discard compileSource("(return 1)")

  test "producer errors are terminal and close upstream":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var calls (cell 0)) " &
               "(var closes (cell 0)) " &
               "(fn source [] : (Stream Int Never) " &
               "  (try (yield 1) " &
               "   ensure (closes ~ Cell/update (fn [n] (+ n 1))))) " &
               "(var s (map (source) " &
               "  (fn [x] (calls ~ Cell/update (fn [n] (+ n 1))) " &
               "          (fail (Boom ^message \"boom\"))))) " &
               "(var first (try (s ~ Stream/next) " &
               "  catch (Boom ^message m) m)) " &
               "[first (s ~ Stream/has_next) " &
               " (try (s ~ Stream/next) " &
               "  catch (EndOfStream ^message m) m) " &
               " (calls ~ Cell/get) (closes ~ Cell/get)]",
               "[\"boom\" false \"end of stream\" 1 1]")
    check_eval("(type GenBoom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for GenBoom) " &
               "(var runs (cell 0)) " &
               "(fn bad ^errors [GenBoom] [] : (Stream Int GenBoom) " &
               "  (yield 1) " &
               "  (runs ~ Cell/update (fn [n] (+ n 1))) " &
               "  (fail (GenBoom ^message \"generator failed\"))) " &
               "(var s (bad)) " &
               "(var first (s ~ Stream/next)) " &
               "(var message (try (s ~ Stream/has_next) " &
               "  catch (GenBoom ^message m) m)) " &
               "[first message (s ~ Stream/has_next) " &
               " (try (s ~ Stream/peek) " &
               "  catch (EndOfStream ^message m) m) " &
               " (runs ~ Cell/get)]",
               "[1 \"generator failed\" false \"end of stream\" 1]")

  test "has_next on an empty stream returns false without raising":
    check_eval("(var s (to_stream [])) (s ~ Stream/has_next)", "false")

  test "Stream/close is idempotent":
    check_eval("(var s (to_stream [1])) " &
               "  (do " &
               "    (s ~ Stream/close) " &
               "    (s ~ Stream/close))",
               "nil")

  test "selectors map static lookup over stream items":
    check_eval("(var users [{^name \"Ada\"} {^age 37} {^name \"Bob\"}]) " &
               "(var names users/%to_stream/name) " &
               "[(names ~ Stream/next) " &
               " (names ~ Stream/next) " &
               " (names ~ Stream/has_next)]",
               "[\"Ada\" \"Bob\" false]")

  test "selector strict and default options make missing lookup explicit":
    check_eval("(var fallback \"unknown\") " &
               "[((select ^default fallback name) {^age 37}) " &
               " ((select ^default fallback name) {^name nil})]",
               "[\"unknown\" nil]")
    check_eval("(try ((select ^strict true name) {^age 37}) " &
               "catch {^message m} m)",
               "\"selector lookup failed at segment: name\"")
    check_eval("(try ((select ^strict true ^default \"unknown\" name) {^age 37}) " &
               "catch {^message m} m)",
               "\"selector lookup failed at segment: name\"")
    check_eval("(try ((select ^strict true name) {^age 37}) " &
               "catch (SelectorMissing ^segment s) s)",
               "name")

  test "list path sends expose behavior while selectors stay generic":
    check_eval("(var xs [10 20 30]) " &
               "[xs/~size xs/~empty? xs/~first xs/~last xs/size]",
               "[3 false 10 30 void]")
    check_eval("(var xs []) [xs/~empty? xs/~first xs/~last]",
               "[true void void]")
    check_eval("(fn size [xs] xs/~size) (size [1 2 3])", "3")

  test "complex selector stages adapt stream helpers":
    check_eval("(var users [{^name \"Ada\" ^adult true} " &
               "            {^name \"Tim\" ^adult false} " &
               "            {^name \"Bob\" ^adult true}]) " &
               "(var names ((select %to_stream %(filter /adult) name) users)) " &
               "[(names ~ Stream/next) " &
               " (names ~ Stream/next) " &
               " (names ~ Stream/has_next)]",
               "[\"Ada\" \"Bob\" false]")
    check_eval("(var users [{^name \"Ada\"} {^name \"Bob\"} {^name \"Cy\"}]) " &
               "((select %to_stream %(map /name) %(take 2) %(into [])) users)",
               "[\"Ada\" \"Bob\"]")

  test "selector key wrappers force dynamic key lookup":
    check_eval("(var field \"name\") " &
               "(var get-name (select %(key field))) " &
               "(get-name {^name \"Ada\"})",
               "\"Ada\"")
    check_eval("(var plus +) " &
               "[((select %plus) 4) ((select %(key plus)) 4)]",
               "[4 void]")

  test "declarations is an ordinary stream selector stage":
    check_eval("(ns m (var b 2) (var a 1)) " &
               "(var names m/%declarations/name) " &
               "[(names ~ Stream/next) " &
               " (names ~ Stream/next) " &
               " (names ~ Stream/has_next)]",
               "[\"a\" \"b\" false]")

  test "declaration records expose source @meta through %meta":
    check_eval("(ns m (fn home [] @doc \"hi\" 1) (var x 2)) " &
               "(var d ((filter m/%declarations (fn [d] (== d/name \"home\"))) " &
               "        ~ Stream/next)) " &
               "(var v ((filter m/%declarations (fn [d] (== d/name \"x\"))) " &
               "        ~ Stream/next)) " &
               "[d/%meta/doc d/kind (== v/%meta/doc void)]",
               "[\"hi\" \"Fn\" true]")

  test "this_mod exposes the current module declaration stream":
    let scope = newGlobalScope()
    discard bindThisModule(scope, "spec")
    check run(compileSource("(var x 9) " &
                            "(var ds (filter (this_mod ~ Module/declarations) " &
                            "  (fn [d] (== d/name \"x\")))) " &
                            "(var decl (ds ~ Stream/next)) " &
                            "[(/value decl) (this_mod ~ Module/path)]"),
              scope).print() == "[9 nil]"

suite "spec — structured tasks from design":
  test "scope owns spawned tasks and await returns the result":
    check_eval("(scope " &
               "  (var a (spawn (+ 1 2))) " &
               "  (var b (spawn (+ 3 4))) " &
               "  (+ (await a) (await b)))",
               "10")

  test "spawn queues child work and CPU tasks yield at safepoints":
    check_eval("(scope (var out (cell 0)) " &
               "  (var slow (spawn (do " &
               "    (var i 0) " &
               "    (while (< i 5000) (set i (+ i 1))) " &
               "    (out ~ Cell/set 1)))) " &
               "  (var fast (spawn (out ~ Cell/set 2))) " &
               "  (await fast) " &
               "  [(out ~ Cell/get) (await slow) (out ~ Cell/get)])",
               "[2 1 1]")

  test "worker-candidate spawns snapshot Send captures":
    check_eval("(scope (var x 1) " &
               "  (var t (spawn x)) " &
               "  (set x 2) " &
               "  (await t))",
               "1")
    check_eval("(scope (var x 1) " &
               "  (fn read [n] (+ x n)) " &
               "  (var t (spawn (read 2))) " &
               "  (set x 10) " &
               "  (await t))",
               "3")
    check_eval("(scope (var c (cell 0)) " &
               "  (var t (spawn (c ~ Cell/get))) " &
               "  (c ~ Cell/set 2) " &
               "  (await t))",
               "2")
    check_eval("(scope (var x 41) " &
               "  (var t (spawn (fn [] (+ x 1)))) " &
               "  ((await t)))",
               "42")

  test "timer waits suspend only the current task":
    check_eval("(scope (var out (cell 0)) " &
               "  (var slow (spawn (do (sleep 5) (out ~ Cell/set 1)))) " &
               "  (var fast (spawn (out ~ Cell/set 2))) " &
               "  (await fast) " &
               "  [(out ~ Cell/get) (await slow) (out ~ Cell/get)])",
               "[2 1 1]")

  test "zero-duration sleep yields a scheduler turn":
    check_eval("(var out (cell 0)) " &
               "(spawn (out ~ Cell/set 1)) " &
               "[(out ~ Cell/get) (sleep 0) (out ~ Cell/get)]",
               "[0 nil 1]")

  test "scope normal exit waits for live child tasks":
    check_eval("(var out (cell 0)) " &
               "(scope (var ch (channel ^capacity 1)) " &
               "  (spawn (do (ch ~ Channel/recv) (out ~ Cell/set 7))) " &
               "  (spawn (ch ~ Channel/send 1)) " &
               "  nil) " &
               "(out ~ Cell/get)",
               "7")

  test "spawn can require the owning root lane":
    check_eval("(scope (var t (spawn ^lane root (+ 20 22))) (await t))",
               "42")

  test "await propagates recoverable task errors":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(scope " &
               "  (var t (spawn (fail (Boom ^message \"boom\")))) " &
               "  (try (await t) catch (Boom ^message m) m))",
               "\"boom\"")

  test "await propagates task cancellation outside catch":
    expect GeneCancel:
      discard run(compileSource("(scope (var ch (channel ^capacity 1)) " &
                                "  (var t (spawn (ch ~ Channel/recv))) " &
                                "  (t ~ Task/cancel) " &
                                "  (try (await t) catch _ \"caught\"))"),
                  newGlobalScope())

  test "scope normal-exit deadlock cancels owned children":
    check_eval("(var ch (channel ^capacity 1)) " &
               "(var out (cell 0)) " &
               "(try " &
               "  (scope " &
               "    (spawn (do (ch ~ Channel/recv) (out ~ Cell/set 1))) " &
               "    nil) " &
               "  catch {^message m} m) " &
               "(ch ~ Channel/send 1) " &
               "(sleep 1) " &
               "(out ~ Cell/get)",
               "0")

  test "scope error exit cancels pending child tasks":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var ch (channel ^capacity 1)) " &
               "(var out (cell 0)) " &
               "(try " &
               "  (scope " &
               "    (spawn (do (ch ~ Channel/recv) (out ~ Cell/set 1))) " &
               "    (fail (Boom ^message \"stop\"))) " &
               "  catch (Boom) nil) " &
               "(ch ~ Channel/send 1) " &
               "(scope nil) " &
               "(out ~ Cell/get)",
               "0")

  test "scope error exit waits for child cancellation cleanup":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var ch (channel ^capacity 1)) " &
               "(var out (cell 0)) " &
               "(try " &
               "  (scope " &
               "    (spawn (try (ch ~ Channel/recv) " &
               "                ensure (out ~ Cell/set 9))) " &
               "    (sleep 1) " &
               "    (fail (Boom ^message \"stop\"))) " &
               "  catch (Boom) nil) " &
               "(out ~ Cell/get)",
               "9")

  test "explicit Task/cancel still runs the ensure cleanup":
    check_eval("(var ch (channel ^capacity 1)) " &
               "(var out (cell 0)) " &
               "(scope " &
               "  (var t (spawn (try (ch ~ Channel/recv) " &
               "                   ensure (out ~ Cell/set 7)))) " &
               "  (sleep 1) " &
               "  (t ~ Task/cancel)) " &
               "(sleep 1) " &
               "(out ~ Cell/get)",
               "7")

  test "wildcard catch does not intercept task cancellation":
    expect GeneCancel:
      discard run(compileSource("(scope (var ch (channel ^capacity 1)) " &
                                "  (var t (spawn (ch ~ Channel/recv))) " &
                                "  (t ~ Task/cancel) " &
                                "  (try (await t) catch _ \"caught\"))"),
                  newGlobalScope())

  test "detached tasks outlive scope ownership":
    check_eval("(var out (cell 0)) " &
               "(scope " &
               "  (var t (spawn (do (sleep 5) (out ~ Cell/set 1)))) " &
               "  (t ~ Task/detach) " &
               "  nil) " &
               "[(out ~ Cell/get) (sleep 10) (out ~ Cell/get)]",
               "[0 nil 1]")

  test "Task annotations accept task handles":
    check_eval("(scope (var t : (Task Int Never) (spawn 1)) t)", "(task)")

  test "Task annotations validate results and errors when awaited":
    check_eval("(scope " &
               "  (fn use [t : (Task Int Never)] (await t)) " &
               "  (use (spawn 5)))",
               "5")
    check_eval("(scope " &
               "  (fn use [t : (Task Int Never)] " &
               "    (try (await t) catch (TypeError ^where w) w)) " &
               "  (use (spawn \"bad\")))",
               "\"await task result\"")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(type Other ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Other) " &
               "(scope " &
               "  (fn use [t : (Task Int Boom)] " &
               "    (try (await t) catch (TypeError ^where w) w)) " &
               "  (use (spawn (fail (Other ^message \"bad\")))))",
               "\"await task error\"")

suite "spec — bounded channels from design":
  test "channels send, receive, and close in FIFO order":
    check_eval("(var ch (channel ^capacity 2)) " &
               "(ch ~ Channel/send 1) " &
               "(ch ~ Channel/send 2) " &
               "(ch ~ Channel/close) " &
               "[(ch ~ Channel/recv) " &
               " (ch ~ Channel/recv) " &
               " (try (ch ~ Channel/recv) catch (ChannelClosed ^message m) m)]",
               "[1 2 \"channel is closed\"]")
    check_eval("(scope (var ch (channel ^capacity 1)) " &
               "  (var t (spawn (try (ch ~ Channel/recv) " &
               "                  catch (ChannelClosed ^message m) m))) " &
               "  (spawn (ch ~ Channel/close)) " &
               "  (await t))",
               "\"channel is closed\"")
    check_eval("(scope (var ch (channel ^capacity 1)) " &
               "  (ch ~ Channel/send 1) " &
               "  (var t (spawn (try (ch ~ Channel/send 2) " &
               "                  catch (ChannelClosed ^message m) m))) " &
               "  (spawn (ch ~ Channel/close)) " &
               "  (await t))",
               "\"channel is closed\"")

  test "try_send and try_recv expose non-suspending channel checks":
    check_eval("(var ch (channel ^capacity 1)) " &
               "[(ch ~ Channel/try_send 1) " &
               " (ch ~ Channel/try_send 2) " &
               " (ch ~ Channel/recv) " &
               " (match (ch ~ Channel/try_recv) " &
               "   (when TryRecv/empty true) " &
               "   (when (TryRecv/value _) false))]",
               "[true false 1 true]")

  test "try_recv tags empty and preserves Void and Nil payloads":
    check_eval("(var ch (channel ^capacity 3)) " &
               "(var empty (ch ~ Channel/try_recv)) " &
               "(ch ~ Channel/send void) " &
               "(ch ~ Channel/send nil) " &
               "(ch ~ Channel/send 9) " &
               "[(match empty (when TryRecv/empty `empty)) " &
               " (match (ch ~ Channel/try_recv) " &
               "   (when (TryRecv/value v) v)) " &
               " (match (ch ~ Channel/try_recv) " &
               "   (when (TryRecv/value v) v)) " &
               " (match (ch ~ Channel/try_recv) " &
               "   (when (TryRecv/value v) v))]",
               "[empty void nil 9]")
    check_eval("(fn poll [ch : (Channel Int)] : (TryRecv Int) " &
               "  (ch ~ Channel/try_recv)) " &
               "(match (poll (channel)) (when TryRecv/empty true))",
               "true")

  test "typed channel boundaries check items before enqueue":
    check_eval("(var ch : (Channel Int) (channel)) " &
               "(try (ch ~ Channel/send \"bad\") catch (TypeError ^where w) w)",
               "\"Channel/send item\"")

  test "channel sends enforce dynamic Send values":
    check_eval("(var ch (channel)) " &
               "(ch ~ Channel/send #[1 #{^a 2}]) " &
               "(ch ~ Channel/recv)",
               "#[1 #{^a 2}]")
    check_eval("(var ch (channel)) " &
               "(var captured #[1 #{^a 2}]) " &
               "(var f (fn [] captured)) " &
               "(ch ~ Channel/send f) " &
               "(var g (ch ~ Channel/recv)) " &
               "(g)",
               "#[1 #{^a 2}]")
    check_eval("(var ch (channel)) " &
               "(var f (fn [x y = x] y)) " &
               "(ch ~ Channel/send f) " &
               "(var g (ch ~ Channel/recv)) " &
               "(g 7)",
               "7")
    check_eval("(var ch (channel)) " &
               "(try (ch ~ Channel/send [1]) catch (TypeError ^expected e) e)",
               "\"Send\"")
    check_eval("(var ch (channel)) " &
               "(try (ch ~ Channel/send #[(cell 1)]) " &
               "catch (TypeError ^where w) w)",
               "\"Channel/send item\"")
    check_eval("(var ch (channel)) " &
               "(var captured (cell 1)) " &
               "(var f (fn [] (captured ~ Cell/get))) " &
               "(try (ch ~ Channel/send f) catch (TypeError ^expected e) e)",
               "\"Send\"")

suite "spec — actors from design":
  test "actor send processes messages sequentially":
    check_eval("(var out (cell 0)) " &
               "(fn handle [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  (var next (+ state msg)) " &
               "  (out ~ Cell/set next) " &
               "  (actor/continue next)) " &
               "(var counter : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(counter ~ actor/send 2) " &
               "(counter ~ actor/send 5) " &
               "(out ~ Cell/get)",
               "7")

  test "actor try_send returns immediately":
    check_eval("(var gate (channel ^capacity 1)) " &
               "(var seen (cell 0)) " &
               "(var a (actor/spawn ^init (fn [] 0) " &
               "  ^handle (fn [ctx state msg] " &
               "    (gate ~ Channel/recv) " &
               "    (seen ~ Cell/set msg) " &
               "    (actor/continue msg)))) " &
               "(var before [(a ~ actor/try_send 7) (seen ~ Cell/get)]) " &
               "(gate ~ Channel/send 1) " &
               "(sleep 0) " &
               "before",
               "[true 0]")

  test "actor snapshots expose idle state metadata":
    check_eval("(fn handle [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  (actor/continue (+ state msg))) " &
               "(var counter : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(counter ~ actor/send 2) " &
               "(counter ~ actor/send 5) " &
               "(var snap (counter ~ actor/snapshot)) " &
               "[snap/state snap/mailbox snap/closed snap/processing]",
               "[7 0 false false]")

  test "actor upgrade replaces idle handlers with migration rollback":
    check_eval("(fn add [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  (actor/continue (+ state msg))) " &
               "(fn mul [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  (actor/continue (* state msg))) " &
               "(var counter : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 1) ^handle add)) " &
               "(counter ~ actor/send 2) " &
               "(actor/upgrade counter mul ^migrate (fn [state] (+ state 1))) " &
               "(counter ~ actor/send 3) " &
               "(var before (counter ~ actor/snapshot)) " &
               "(var err (try (actor/upgrade counter 99) " &
               "  catch (TypeError ^where w) w)) " &
               "(counter ~ actor/send 2) " &
               "(var after (counter ~ actor/snapshot)) " &
               "[before/state err after/state]",
               "[12 \"actor/upgrade handler\" 24]")

  test "actor stop closes the actor":
    check_eval("(var a : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (actor/stop)))) " &
               "(a ~ actor/send 1) " &
               "(try (a ~ actor/send 2) catch (ActorClosed ^message m) m)",
               "\"actor is closed\"")

  test "actor sends require typed Send messages":
    check_eval("(var a : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (actor/continue state)))) " &
               "(try (a ~ actor/send \"bad\") catch (TypeError ^where w) w)",
               "\"actor/send message\"")
    check_eval("(var a (actor/spawn ^init (fn [] 0) " &
               "  ^handle (fn [ctx state msg] (actor/continue state)))) " &
               "(try (a ~ actor/send [1]) catch (TypeError ^expected e) e)",
               "\"Send\"")

  test "actor ask uses an explicit one-shot ReplyTo capability":
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (match msg " &
               "    (when (Get ^reply reply) " &
               "      (reply ~ ReplyTo/send state) " &
               "      (actor/continue state)))) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 41) ^handle handle)) " &
               "(await (counter ~ actor/ask (fn [reply] (Get ^reply reply))))",
               "41")

  test "a second send on a ReplyTo raises ReplyAlreadySent":
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var out (cell nil)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var (Get ^reply reply) msg) " &
               "  (reply ~ ReplyTo/send state) " &
               "  (try (reply ~ ReplyTo/send state) " &
               "   catch (ReplyAlreadySent ^message m) (out ~ Cell/set m)) " &
               "  (actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 7) ^handle handle)) " &
               "(var got (await (counter ~ actor/ask (fn [reply] (Get ^reply reply))))) " &
               "[got (sleep 1) (out ~ Cell/get)]",
               "[7 nil \"reply has already been sent\"]")
    # ReplyAlreadySent is a subtype of ActorError, so a broad handler-level
    # catch also sees it.
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var out (cell nil)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var (Get ^reply reply) msg) " &
               "  (reply ~ ReplyTo/send state) " &
               "  (try (reply ~ ReplyTo/send state) " &
               "   catch (ActorError ^message m) (out ~ Cell/set m)) " &
               "  (actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 7) ^handle handle)) " &
               "(await (counter ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
               "[(sleep 1) (out ~ Cell/get)]",
               "[nil \"reply has already been sent\"]")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(scope " &
               "  (var counter : (ActorRef Get) " &
               "    (actor/spawn ^init (fn [] 41) " &
               "      ^handle (fn [ctx state msg] " &
               "        (match msg " &
               "          (when (Get ^reply reply) " &
               "            (reply ~ ReplyTo/send state) " &
               "            (actor/continue state)))))) " &
               "  (fn (choose result err) [t : (Task result err) fallback : result] " &
               "    fallback) " &
               "  (try (choose (counter ~ actor/ask (fn [reply] (Get ^reply reply))) \"bad\") " &
               "       catch (TypeError ^expected e) e))",
               "\"Int\"")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var ch (channel ^capacity 1)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var got (ch ~ Channel/recv)) " &
               "  (match msg " &
               "    (when (Get ^reply reply) " &
               "      (reply ~ ReplyTo/send (+ state got)) " &
               "      (actor/continue state)))) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 40) ^handle handle)) " &
               "(var pending (counter ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
               "(ch ~ Channel/send 2) " &
               "(await pending)",
               "42")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var ch (channel ^capacity 1)) " &
               "(var out (cell 0)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var (Get ^reply reply) msg) " &
               "  (var got (ch ~ Channel/recv)) " &
               "  (reply ~ ReplyTo/send got) " &
               "  (out ~ Cell/set got) " &
               "  (actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(var pending (actor/ask ^timeout_ms 5 counter (fn [reply] (Get ^reply reply)))) " &
               "(var err (try (await pending) catch (ActorError ^message m) m)) " &
               "(ch ~ Channel/send 7) " &
               "[err (sleep 1) (out ~ Cell/get)]",
               "[\"actor/ask timed out\" nil 7]")
    check_eval("(scope " &
               "  (type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var saved (cell nil)) " &
               "(var ch (channel ^capacity 1)) " &
               "(fn handle [ctx state msg] " &
               "  (var (Get ^reply reply) msg) " &
               "  (var got (ch ~ Channel/recv)) " &
               "  (try (reply ~ ReplyTo/send got) catch {^message m} m) " &
               "  (actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(var pending (actor/ask ^timeout_ms 5 counter " &
               "  (fn [reply] (saved ~ Cell/set reply) (Get ^reply reply)))) " &
               "(var err (try (await pending) catch (ActorError ^message m) m)) " &
               "(var first-late (try ((saved ~ Cell/get) ~ ReplyTo/send 9) " &
               "                  catch {^message m} m)) " &
               "(var second-late (try ((saved ~ Cell/get) ~ ReplyTo/send 10) " &
               "                   catch {^message m} m)) " &
               "[err first-late second-late])",
               "[\"actor/ask timed out\" nil \"reply has already been sent\"]")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (match msg " &
               "        (when (Get ^reply reply) " &
               "          (reply ~ ReplyTo/send \"bad\") " &
               "          (actor/continue state)))))) " &
               "(try (await (counter ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
               "catch (TypeError ^where w) w)",
               "\"ReplyTo/send value\"")

  test "scope shutdown cancels pending actor asks":
    expect GeneCancel:
      discard run(compileSource("(type Get ^props {^reply (ReplyTo Int)}) " &
                                "(impl Send for Get) " &
                                "(var pending nil) " &
                                "(scope " &
                                "  (var a (actor/spawn ^init (fn [] 41) " &
                                "    ^handle (fn [ctx state msg] " &
                                "      (match msg " &
                                "        (when (Get ^reply reply) " &
                                "          (reply ~ ReplyTo/send state) " &
                                "          (actor/continue state)))))) " &
                                "  (set pending (a ~ actor/ask " &
                                "    (fn [reply] (Get ^reply reply)))) " &
                                "  nil) " &
                                "(await pending)"),
                  newGlobalScope())
    check_eval("(scope " &
               "  (type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var saved (cell nil)) " &
               "(var ch (channel ^capacity 1)) " &
               "(fn handle [ctx state msg] " &
               "  (var (Get ^reply reply) msg) " &
               "  (var got (ch ~ Channel/recv)) " &
               "  (try (reply ~ ReplyTo/send got) catch {^message m} m) " &
               "  (actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(var pending (counter ~ actor/ask " &
               "  (fn [reply] (saved ~ Cell/set reply) (Get ^reply reply)))) " &
               "(pending ~ Task/cancel) " &
               "(var first-late (try ((saved ~ Cell/get) ~ ReplyTo/send 9) " &
               "                  catch {^message m} m)) " &
               "(var second-late (try ((saved ~ Cell/get) ~ ReplyTo/send 10) " &
               "                   catch {^message m} m)) " &
               "[first-late second-late])",
               "[nil \"reply has already been sent\"]")
    expect GeneCancel:
      discard run(compileSource("(type Boom ^props {^message Str} ^impl [Error]) " &
                                "(impl Error for Boom) " &
                                "(type Get ^props {^reply (ReplyTo Int)}) " &
                                "(impl Send for Get) " &
                                "(supervisor ^strategy stop " &
                                "  (var a (actor/spawn ^mailbox 4 ^init (fn [] 0) " &
                                "    ^handle (fn [ctx state msg] " &
                                "      (fail (Boom ^message \"bad\"))))) " &
                                "  (var first (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
                                "  (var second (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
                                "  (sleep 1) " &
                                "  (await second))"),
                  newGlobalScope())

  test "scope owns spawned actors until scope exit":
    check_eval("(var a (scope " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (actor/continue state))))) " &
               "(a ~ actor/try_send 1)",
               "false")
    check_eval("(scope " &
               "  (var a (scope " &
               "    (actor/spawn ^init (fn [] 0) " &
               "      ^handle (fn [ctx state msg] (actor/continue state))))) " &
               "  (a ~ actor/try_send 1))",
               "false")

  test "restart budget stops the actor when max_restarts is exhausted":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(supervisor ^strategy restart ^max_restarts 1 ^within_ms 60000 " &
               "  (var a (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (fail (Boom ^message \"boom\"))))) " &
               "  (a ~ actor/send 1) " &   # restart consumes the budget
               "  (var second (try (a ~ actor/send 2) catch (Boom ^message m) m)) " &
               "  (var third (try (a ~ actor/send 3) catch (ActorClosed ^message m) m)) " &
               "  [second third])",
               "[\"boom\" \"actor is closed\"]")

  test "restart budget window resets after within_ms":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var seen (cell 0)) " &
               "(supervisor ^strategy restart ^max_restarts 1 ^within_ms 50 " &
               "  (var a (actor/spawn ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (== msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do (seen ~ Cell/set state) (actor/continue state)))))) " &
               "  (a ~ actor/send 1) " &
               "  (sleep 80) " &          # window expires; budget refills
               "  (a ~ actor/send 1) " &
               "  (a ~ actor/send 5) " &
               "  (seen ~ Cell/get))",
               "10")

  test "supervisor owns actors and restarts after recoverable handler errors":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var seen (cell 0)) " &
               "(supervisor ^strategy restart " &
               "  (var a (actor/spawn ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (== msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do " &
               "          (seen ~ Cell/set state) " &
               "          (actor/continue (+ state msg))))))) " &
               "  (a ~ actor/send 1) " &
               "  (a ~ actor/send 5) " &
               "  (seen ~ Cell/get))",
               "10")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events (channel ^capacity 4)) " &
               "(var seen (cell 0)) " &
               "(supervisor ^strategy restart ^events events " &
               "  (var a (actor/spawn ^mailbox 4 ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (== msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do " &
               "          (seen ~ Cell/set state) " &
               "          (actor/continue (+ state msg))))))) " &
               "  (spawn (a ~ actor/send 1)) " &
               "  (spawn (a ~ actor/send 5)) " &
               "  (sleep 1) " &
               "  (var event (events ~ Channel/recv)) " &
               "  (var tries 0) " &
               "  (while (< tries 100) " &
               "    (if (== (seen ~ Cell/get) 0) " &
               "      (do (sleep 1) (set tries (+ tries 1))) " &
               "      (set tries 100))) " &
               "  [(seen ~ Cell/get) " &
               "   (match event " &
               "     (when (ActorFailure ^failed_message failed " &
               "                         ^error (Boom ^message m) " &
               "                         ^panic p ^strategy s) " &
               "       [failed m p s]))])",
               "[10 [1 \"bad\" false restart]]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events (channel ^capacity 1)) " &
               "(var dead (channel ^capacity 2)) " &
               "(events ~ Channel/send \"busy\") " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (fail (Boom ^message \"bad\"))))) " &
               "  (a ~ actor/send 1) " &
               "  (sleep 1) " &
               "  (var event (dead ~ Channel/recv)) " &
               "  (var busy (events ~ Channel/recv)) " &
               "  [busy " &
               "   (match event " &
               "     (when (ActorFailure ^failed_message failed " &
               "                         ^error (Boom ^message m) " &
               "                         ^strategy s) " &
               "       [failed m s]))])",
               "[\"busy\" [1 \"bad\" restart]]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events (channel ^capacity 1)) " &
               "(var dead (channel ^capacity 1)) " &
               "(events ~ Channel/send \"busy\") " &
               "(dead ~ Channel/send \"dead-busy\") " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (fail (Boom ^message \"bad\"))))) " &
               "  (a ~ actor/send 4) " &
               "  (sleep 1) " &
               "  (var dead-busy (dead ~ Channel/recv)) " &
               "  (var event (dead ~ Channel/recv)) " &
               "  (var busy (events ~ Channel/recv)) " &
               "  [busy dead-busy " &
               "   (match event " &
               "     (when (ActorFailure ^failed_message failed " &
               "                         ^error (Boom ^message m) " &
               "                         ^strategy s) " &
               "       [failed m s]))])",
               "[\"busy\" \"dead-busy\" [4 \"bad\" restart]]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events (channel ^capacity 1)) " &
               "(var dead (channel ^capacity 1)) " &
               "(events ~ Channel/close) " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (fail (Boom ^message \"bad\"))))) " &
               "  (a ~ actor/send 2) " &
               "  (sleep 1) " &
               "  (var event (dead ~ Channel/recv)) " &
               "  (match event " &
               "    (when (ActorFailure ^failed_message failed " &
               "                        ^error (Boom ^message m) " &
               "                        ^strategy s) " &
               "      [failed m s])))",
               "[2 \"bad\" restart]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events : (Channel Int) (channel ^capacity 1)) " &
               "(var dead (channel ^capacity 1)) " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (fail (Boom ^message \"bad\"))))) " &
               "  (a ~ actor/send 6) " &
               "  (sleep 1) " &
               "  (var event (dead ~ Channel/recv)) " &
               "  (match event " &
               "    (when (ActorFailure ^failed_message failed " &
               "                        ^error (Boom ^message m) " &
               "                        ^strategy s) " &
               "      [failed m s])))",
               "[6 \"bad\" restart]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events (channel ^capacity 1)) " &
               "(var dead (channel ^capacity 1)) " &
               "(events ~ Channel/close) " &
               "(dead ~ Channel/close) " &
               "(var seen (cell 0)) " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a (actor/spawn ^mailbox 4 ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (== msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do " &
               "          (seen ~ Cell/set state) " &
               "          (actor/continue (+ state msg))))))) " &
               "  (a ~ actor/send 1) " &
               "  (a ~ actor/send 5) " &
               "  (sleep 1) " &
               "  (seen ~ Cell/get))",
               "10")
    check_eval("(var a (supervisor ^strategy stop " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (actor/continue state))))) " &
               "(a ~ actor/try_send 1)",
               "false")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(try " &
               "  (supervisor ^strategy escalate " &
               "    (var a (actor/spawn ^init (fn [] 0) " &
               "      ^handle (fn [ctx state msg] " &
               "        (fail (Boom ^message \"bad\"))))) " &
               "    (var pending (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
               "    (sleep 1) " &
               "    \"after\") " &
               "  catch (Boom ^message m) m)",
               "\"bad\"")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var parent-events (channel ^capacity 2)) " &
               "(var outcome " &
               "  (try " &
               "    (supervisor ^strategy stop ^events parent-events " &
               "      (supervisor ^strategy escalate " &
               "        (var a (actor/spawn ^init (fn [] 0) " &
               "          ^handle (fn [ctx state msg] " &
               "            (fail (Boom ^message \"bad\"))))) " &
               "        (a ~ actor/send 7))) " &
               "    catch (Boom ^message m) m)) " &
               "(var event (parent-events ~ Channel/recv)) " &
               "[outcome " &
               " (match event " &
               "   (when (ActorFailure ^failed_message failed " &
               "                       ^error (Boom ^message m) " &
               "                       ^strategy s) " &
               "     [failed m s]))]",
               "[\"bad\" [7 \"bad\" escalate]]")
    expect GenePanic:
      discard run(compileSource("(type Get ^props {^reply (ReplyTo Int)}) " &
                                "(impl Send for Get) " &
                                "(supervisor ^strategy stop " &
                                "  (var a (actor/spawn ^init (fn [] 0) " &
                                "    ^handle (fn [ctx state msg] " &
                                "      (panic \"halt\")))) " &
                                "  (var pending (a ~ actor/ask " &
                                "    (fn [reply] (Get ^reply reply)))) " &
                                "  (sleep 1) " &
                                "  \"after\")"),
                  newGlobalScope())

suite "spec — Env and eval from design":
  test "incremental REPL sessions retain declarations and incomplete source":
    check_eval("(import repl [open eval_source close]) " &
               "(var s (open (env ^bindings {^base 40}))) " &
               "(var declared (eval_source s \"(var x (+ base 1))\")) " &
               "(var used (eval_source s \"(+ x 1)\")) " &
               "(var partial (eval_source s \"(do\")) " &
               "(var completed (eval_source s \"(+ x 2))\")) " &
               "(close s) (close s) " &
               "[declared/status declared/text used/status used/text " &
               " partial/status completed/status completed/text]",
               "[\"ok\" \"41\" \"ok\" \"42\" \"incomplete\" \"ok\" \"43\"]")

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

  test "eval sees explicit Env capability values":
    check_eval("(var e (env ^bindings {^fs \"binding\"} " &
               "           ^capabilities {^fs \"capability\" ^net \"closed\"})) " &
               "[(eval (quote fs) ^in e) (eval (quote net) ^in e)]",
               "[\"binding\" \"closed\"]")

  test "runtime capabilities are opaque library values":
    check_eval("[Fs/ReadDir " &
               " (Capability/name Fs/ReadDir) " &
               " ((fn [cap : Capability] (Capability/name cap)) Fs/WriteDir)]",
               "[(capability Fs/ReadDir) \"Fs/ReadDir\" \"Fs/WriteDir\"]")
    check_eval("(var e (env ^capabilities {^fs Fs/ReadDir})) " &
               "(eval (quote (Capability/name fs)) ^in e)",
               "\"Fs/ReadDir\"")
    check_eval("(var ch (channel)) " &
               "(try (ch ~ Channel/send Fs/ReadDir) " &
               "catch (TypeError ^expected e) e)",
               "\"Send\"")

  test "runtime GC stats expose optimization diagnostics":
    check_eval("(var stats (Runtime/gc_stats)) " &
               "[stats/live_managed stats/rc_stats?]",
               "[0 false]")

  test "eval policy can limit execution steps":
    check_eval("(type EvalPolicy ^props {^max_steps Int " &
               "                         ^allow_ffi Bool? " &
               "                         ^allow_native_compile Bool?}) " &
               "(var p (EvalPolicy ^max_steps 20 " &
               "                   ^allow_ffi false " &
               "                   ^allow_native_compile false)) " &
               "(eval (quote (+ 1 2)) ^in (env ^policy p))",
               "3")
    check_eval("(try (eval (quote (while true nil)) " &
               "           ^in (env ^policy {^max_steps 20})) " &
               "catch {^message m} m)",
               "\"eval max steps exceeded\"")
    expect GeneError:
      discard run(compileSource("(env ^policy {^max_memory_mb 128})"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(env ^policy {^allow_ffi true})"),
                  newGlobalScope())

suite "spec — parser helpers from design":
  test "read_one feeds eval and read_all returns a stream":
    check_eval("(eval (read_one \"(+ 1 2)\") ^in (env))", "3")
    check_eval("(var s (read_all \"(a) (b 2)\")) " &
               "[(s ~ Stream/next) (s ~ Stream/next) (s ~ Stream/has_next)]",
               "[(a) (b 2) false]")

  test "reader failures preserve structured location and open-form context":
    check_eval("(import std/parse [read_all ParseError]) " &
               "(try (read_all \"(a [b)\") false " &
               " catch (ParseError ^line line ^col col ^contexts frames) " &
               "   [line col frames/0/opener frames/0/expected_closer " &
               "    frames/1/opener frames/1/expected_closer])",
               "[1 6 \"(\" \")\" \"[\" \"]\"]")
    check_eval("(try (read_all \"(ok) )\") false " &
               " catch (ParseError ^contexts frames) (frames ~ size))",
               "0")

  test "lex_all exposes a token stream":
    check_eval("(fn first-token [s : (Stream Token Never)] (s ~ Stream/next)) " &
               "(var t (first-token (lex_all \"(+ 1)\"))) " &
               "(var k t/kind) (var x t/lexeme) " &
               "(var l t/line) (var c t/col) [k x l c]",
               "[l_paren \"(\" 1 1]")

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
    check run(compileSource("(mod app) this_mod"), scope).print() == "(mod app)"

  test "duplicate bindings in one namespace are rejected":
    expect GeneError:
      discard run(compileSource("(var x 1) (var x 2)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource("(ns m (var x 1) (var x 2))"),
                  newGlobalScope())
    check_eval("(var x 1) (ns m (var x 2)) [x (/x m)]", "[1 2]")

suite "spec — macros across modules (design §11/§15)":
  # Macros are compile-time definitions, so `from "path"` imports pre-load the
  # dependency and splice its macro exports into the importer's compiler.
  proc macroModuleDir(): string =
    result = getTempDir() / "gene_spec_macro_modules"
    removeDir(result)
    createDir(result)
    writeFile(result / "mlib.gene",
      "(mod mlib)\n" &
      "(macro triple! [x] `(* 3 %x))\n" &
      "(fn use_it [] (triple! 5))\n")

  proc moduleVar(m: Value, name: string): string =
    let nsScope = m.moduleRootNamespace.nsScope
    nsScope.materializeMirroredVars()
    nsScope.vars[name].print()

  test "module macros import alongside values and expand at compile time":
    let dir = macroModuleDir()
    writeFile(dir / "muse.gene",
      "(import [triple! use_it] from \"./mlib\")\n" &
      "(var a (triple! 7))\n" &
      "(var b (use_it))\n")
    let app = newApplication(dir)
    let m = app.loadFileModule(dir / "muse.gene")
    check moduleVar(m, "a") == "21"
    check moduleVar(m, "b") == "15"

  test "macro-only imports and selection aliases work":
    let dir = macroModuleDir()
    writeFile(dir / "muse.gene",
      "(import [triple! : t3!] from \"./mlib\")\n" &
      "(var a (t3! 4))\n")
    let app = newApplication(dir)
    check moduleVar(app.loadFileModule(dir / "muse.gene"), "a") == "12"

  test "compile artifacts expose macros without running dependency top levels":
    let dir = macroModuleDir()
    writeFile(dir / "compile_only.gene",
      "(macro twice! [x] `(+ %x %x))\n" &
      "(panic \"runtime phase executed\")\n")
    writeFile(dir / "consumer.gene",
      "(import [twice!] from \"./compile_only\")\n" &
      "(var answer (twice! 21))\n")
    let app = newApplication(dir)
    let first = app.compileFileModule(dir / "consumer.gene")
    let second = app.compileFileModule(dir / "consumer.gene")
    check first == second
    check not first.disassemble().contains("twice!")
    expect GenePanic:
      discard app.loadFileModule(dir / "consumer.gene")

  test "runtime initialization remains separate and runs once":
    let dir = macroModuleDir()
    writeFile(dir / "phase_dep.gene",
      "(macro identity! [x] `%x)\n" &
      "(var starts (cell 0))\n" &
      "(starts ~ Cell/update (fn [n] (+ n 1)))\n")
    writeFile(dir / "phase_user.gene",
      "(import [identity!] from \"./phase_dep\")\n" &
      "(var answer (identity! 42))\n")
    let app = newApplication(dir)
    discard app.compileFileModule(dir / "phase_user.gene")
    let user = app.loadFileModule(dir / "phase_user.gene")
    check moduleVar(user, "answer") == "42"
    let dependency = app.loadFileModule(dir / "phase_dep.gene")
    dependency.moduleRootNamespace.nsScope.materializeMirroredVars()
    let starts = dependency.moduleRootNamespace.nsScope.vars["starts"]
    check starts.cellValue.intVal == 1
    discard app.loadFileModule(dir / "phase_user.gene")
    check starts.cellValue.intVal == 1

  test "macro dependency cycles have a compile-phase diagnostic":
    let dir = macroModuleDir()
    writeFile(dir / "a.gene",
      "(macro a! [x] `%x)\n" &
      "(import [b!] from \"./b\")\n")
    writeFile(dir / "b.gene",
      "(macro b! [x] `%x)\n" &
      "(import [a!] from \"./a\")\n")
    var message = ""
    try:
      discard newApplication(dir).compileFileModule(dir / "a.gene")
    except GeneError as e:
      message = e.msg
    check message.contains("compile-time macro dependency cycle")

  test "imported macros are usable but not re-exported":
    let dir = macroModuleDir()
    writeFile(dir / "mid.gene",
      "(mod mid)\n" &
      "(import [triple!] from \"./mlib\")\n" &
      "(fn nine_x [x] (triple! (triple! x)))\n")
    writeFile(dir / "muse.gene",
      "(import [nine_x] from \"./mid\")\n" &
      "(var a (nine_x 2))\n")
    let app = newApplication(dir)
    check moduleVar(app.loadFileModule(dir / "muse.gene"), "a") == "18"
    writeFile(dir / "reexport.gene",
      "(import [triple!] from \"./mid\")\n")
    let app2 = newApplication(dir)
    expect GeneError:
      discard app2.loadFileModule(dir / "reexport.gene")

  test "importing a macro over a local macro name is a duplicate":
    let dir = macroModuleDir()
    writeFile(dir / "muse.gene",
      "(import [triple!] from \"./mlib\")\n" &
      "(macro triple! [x] `(+ %x %x %x))\n")
    let app = newApplication(dir)
    expect GeneError:
      discard app.loadFileModule(dir / "muse.gene")

  test "one name means one thing in head and value positions":
    # fn then macro, macro then fn, macro-as-value, param over macro: all
    # rejected so a name can never dispatch differently by position.
    expect GeneError:
      discard compileSource("(fn f [x] x) (macro f [x] `%x)")
    expect GeneError:
      discard compileSource("(macro f [x] `%x) (fn f [x] x)")
    expect GeneError:
      discard compileSource("(macro f [x] `%x) (var g f)")
    expect GeneError:
      discard compileSource("(macro f [x] `%x) (fn g [f] f)")

  test "importing a macro over a value binding is rejected both ways":
    let dir = macroModuleDir()
    writeFile(dir / "clash1.gene",
      "(fn triple! [x] x)\n" &
      "(import [triple!] from \"./mlib\")\n")
    expect GeneError:
      discard newApplication(dir).loadFileModule(dir / "clash1.gene")
    writeFile(dir / "clash2.gene",
      "(import [triple!] from \"./mlib\")\n" &
      "(var triple! 5)\n")
    expect GeneError:
      discard newApplication(dir).loadFileModule(dir / "clash2.gene")

suite "spec — fn! across modules (design §11.1/§15)":
  # fn! values import as ordinary runtime bindings; the exported name set
  # travels to the importer's compiler so call sites keep raw syntax.
  test "imported fn! names keep syntax_call sites":
    let dir = getTempDir() / "gene_spec_fnbang_modules"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "flib.gene",
      "(mod flib)\n" &
      "(fn! unless! [cond, body...]\n" &
      "  (if (! (eval cond ^in caller_env))\n" &
      "    (eval `(do %body...) ^in caller_env)\n" &
      "    nil))\n")
    writeFile(dir / "fuse.gene",
      "(import [unless!] from \"./flib\")\n" &
      "(var x 1)\n" &
      "(var a (unless! (> x 5) \"ok\"))\n")
    let app = newApplication(dir)
    let m = app.loadFileModule(dir / "fuse.gene")
    m.moduleRootNamespace.nsScope.materializeMirroredVars()
    check m.moduleRootNamespace.nsScope.vars["a"].print() == "\"ok\""

suite "spec — impl visibility across modules (design §10)":
  proc implModuleDir(): string =
    result = getTempDir() / "gene_spec_impl_modules"
    removeDir(result)
    createDir(result)
    writeFile(result / "ilib.gene",
      "(mod ilib)\n" &
      "(protocol Greet (message greet [self] : Str))\n" &
      "(type Cat ^props {^name Str})\n" &
      "(impl Greet for Cat (message greet [self] : Str $\"meow ${self/name}\"))\n")

  proc implModuleVar(m: Value, name: string): string =
    let nsScope = m.moduleRootNamespace.nsScope
    nsScope.materializeMirroredVars()
    nsScope.vars[name].print()

  test "importing a module makes its impls visible":
    let dir = implModuleDir()
    writeFile(dir / "use.gene",
      "(import [Cat] from \"./ilib\")\n" &
      "(var r ((Cat ^name \"Tom\") ~ greet))\n")
    let app = newApplication(dir)
    check implModuleVar(app.loadFileModule(dir / "use.gene"), "r") == "\"meow Tom\""

  test "impls travel transitively through imports":
    let dir = implModuleDir()
    writeFile(dir / "mid.gene",
      "(mod mid)\n" &
      "(import [Cat] from \"./ilib\")\n" &
      "(fn make_cat [n : Str] : Cat (Cat ^name n))\n")
    writeFile(dir / "use.gene",
      "(import [make_cat] from \"./mid\")\n" &
      "(var r ((make_cat \"Felix\") ~ greet))\n")
    let app = newApplication(dir)
    check implModuleVar(app.loadFileModule(dir / "use.gene"), "r") == "\"meow Felix\""

  test "an impl is global once its module is loaded (no import path needed)":
    let dir = implModuleDir()
    # `other` uses the Greet/Cat impl but never imports ilib.
    writeFile(dir / "other.gene",
      "(mod other)\n" &
      "(fn use_cat [c] (c ~ greet))\n")
    # loading ilib (via this import) registers the impl globally, so `other`
    # dispatches it despite having no import path to ilib.
    writeFile(dir / "use.gene",
      "(import [Cat] from \"./ilib\")\n" &
      "(import [use_cat] from \"./other\")\n" &
      "(var r (use_cat (Cat ^name \"Zoe\")))\n")
    let app = newApplication(dir)
    check implModuleVar(app.loadFileModule(dir / "use.gene"), "r") == "\"meow Zoe\""

suite "spec — stdlib namespaces from stdlib plan":
  test "std/stream, std/node, and std/parse resolve as namespace imports":
    check_eval("(import std/stream [to_stream map into]) " &
               "((to_stream [1 2 3]) ~ map (fn [x] (* x x)) ; ~ into [])",
               "[1 4 9]")
    check_eval("(import std/stream [to_stream each]) " &
               "(var sum (cell 0)) " &
               "(each (to_stream [1 2 3]) (fn [x] " &
               "  (Cell/update sum (fn [s] (+ s x))))) " &
               "(Cell/get sum)",
               "6")
    check_eval("(import std/node [head]) (head (quote (a 1)))", "a")
    check_eval("(import std/parse [parse_int]) (parse_int \" 42 \")", "42")
    check_eval("(import std/parse [parse_int ParseError]) " &
               "(try (parse_int \"4x\") catch (ParseError ^message _) -1)",
               "-1")
    # format ends with a newline: it is the gene-fmt source-unit contract.
    check_eval("(import std/parse [format]) (format \"( + 1   2 )\")",
               "\"(+ 1 2)\\n\"")
    check_eval("(import std/parse [format ParseError]) " &
               "(try (format \"(((\") catch (ParseError ^message _) -1)",
               "-1")

  test "str module covers join/split/trim/lower and predicates":
    check_eval("(import str [join]) (join [\"a\" \"b\"] \"-\")", "\"a-b\"")
    check_eval("(import str [join]) ([\"a\" \"b\"] ~ join \"\")", "\"ab\"")
    check_eval("(import str [split]) (split \"a,b,,c\" \",\")",
               "[\"a\" \"b\" \"\" \"c\"]")
    check_eval("(import str [trim lower]) (lower (trim \"  MiXeD  \"))",
               "\"mixed\"")
    check_eval("(import str [starts_with? ends_with? contains?]) " &
               "[(starts_with? \"hello\" \"he\") (ends_with? \"hello\" \"lo\") " &
               " (contains? \"hello\" \"xyz\")]",
               "[true true false]")
    check_eval("(import str [byte_size]) (byte_size \"Aé\")", "3")
    check_eval("(import str [slice_bytes]) (slice_bytes \"AéZ\" 1 2)",
               "\"é\"")
    check_eval("(import str [slice_bytes]) (slice_bytes \"AéZ\" 0 2)",
               "\"A\"")
    expect GeneError:
      discard run(compileSource(
        "(import str [slice_bytes]) (slice_bytes \"AéZ\" 2 2)"),
        newGlobalScope())

  test "html/escape neutralizes markup and quote characters":
    check_eval("(import html [escape]) " &
               "(escape \"<a b=\\\"x\\\">&'\")",
               "\"&lt;a b=&quot;x&quot;&gt;&amp;&#39;\"")

  test "url module encodes, decodes, and parses queries":
    check_eval("(import url [encode_component]) (encode_component \"a b&c\")",
               "\"a%20b%26c\"")
    check_eval("(import url [decode_component]) (decode_component \"a%20b\")",
               "\"a b\"")
    check_eval("(import url [parse_query]) " &
               "(parse_query \"text=hello+world&x=%2F\")",
               "{^text \"hello world\" ^x \"/\"}")
    check_eval("(import url [format_query]) " &
               "(format_query {^a \"1\" ^b \"x y\"})",
               "\"a=1&b=x%20y\"")
    check_eval("(import url [decode_component UrlError]) " &
               "(try (decode_component \"a%zz\") " &
               "catch (UrlError ^message _) \"bad\")",
               "\"bad\"")

suite "spec — net/http surface from stdlib plan":
  test "response helpers build typed Response nodes":
    check_eval("(import net/http [text]) (import std/node [body]) " &
               "(var r (text \"hi\")) " &
               "[r/status r/headers/content-type (body r)]",
               "[200 \"text/plain; charset=utf-8\" [\"hi\"]]")
    check_eval("(import net/http [json]) (var r (json \"{}\")) " &
               "r/headers/content-type",
               "\"application/json\"")
    check_eval("(import net/http [redirect]) (var r (redirect \"/x\")) " &
               "[r/status r/headers/location]",
               "[302 \"/x\"]")
    check_eval("(import net/http [not_found]) (var r (not_found)) r/status",
               "404")

  test "Server and Response types construct with typed props":
    check_eval("(import net/http [Server]) " &
               "(var s (Server ^host \"127.0.0.1\" ^port 8088)) " &
               "[s/host s/port]",
               "[\"127.0.0.1\" 8088]")
    check_eval("(import net/http [Response]) " &
               "(var r (Response ^status 201)) r/status",
               "201")

  test "serve validates its Server argument":
    check_eval("(import net/http [serve HttpError]) " &
               "(try (serve nil (fn [q] q)) " &
               "catch (HttpError ^message _) \"bad server\")",
               "\"bad server\"")

suite "spec — net/http_client native client contract":
  test "client authority and entry points are importable":
    check_eval("(import net/http_client [Http request stream HttpClientError]) " &
               "[(Http ~ Capability/name)]",
               "[\"Net/Http\"]")

  test "client rejects non-http URL schemes before starting work":
    check_eval("(import net/http_client [Http request HttpClientError]) " &
               "(try (request Http ^url \"file:///etc/passwd\") false " &
               " catch (HttpClientError ^message m) " &
               "   (str/contains? m \"http:// or https://\"))",
               "true")

  test "setup errors carry ^kind so fallbacks match only unavailability":
    # Usage mistakes (bad args/authority) are ^kind "usage" and must not be
    # confused with libcurl load failures (^kind "unavailable"): the agent's
    # curl(1) fallback catches only the latter.
    check_eval("(import net/http_client [Http request HttpClientError]) " &
               "(try (request Http ^url \"file:///x\") false " &
               " catch (HttpClientError ^kind k) (== k \"usage\"))",
               "true")
    check_eval("(import net/http_client [Http request HttpClientError]) " &
               "(try (request Http ^url \"file:///x\") false " &
               " catch (HttpClientError ^kind \"unavailable\") \"fallback\" " &
               " catch (HttpClientError ^kind \"usage\") \"surfaced\")",
               geneString("surfaced"))

# Disabled here because spec_runner inherits its caller's terminal: the assertion
# passes under captured CI output but opens curses when run directly from a TTY.
# Non-TTY rejection and terminal restoration are covered by the CLI PTY tests.
# suite "spec — public curses terminal contract":
#   test "owned Screen API is importable and non-TTY open is typed":
#     check_eval("(import curses [open close dimensions draw read_input " &
#                "refresh_input escape_pressed? next_event Screen CursesError]) " &
#                "(try (open) false " &
#                " catch (CursesError ^message m) (str/contains? m \"TTY\"))",
#                "true")

suite "spec — structured logging contract":
  test "Logger API is importable and eager/lazy evaluation is explicit":
    check_eval("(import log [Logger LogLevel new_logger debug!]) " &
               "(var logger (new_logger \"app/spec\" ^payload {^x 1})) " &
               "(var eager (cell false)) (var lazy (cell false)) " &
               "(logger ~ info (do (Cell/set eager true) \"eager\")) " &
               "(debug! logger (do (Cell/set lazy true) \"lazy\")) " &
               "(fn accepts [x : Logger] (x ~ enabled? LogLevel/warn)) " &
               "[(Cell/get eager) (Cell/get lazy) (accepts logger)]",
               "[true false true]")

  test "built-in namespace macros support selection aliases":
    check_eval("(import log [new_logger debug! : diagnostic!]) " &
               "(var logger (new_logger \"app/spec\")) " &
               "(var touched (cell false)) " &
               "(diagnostic! logger (do (Cell/set touched true) \"x\")) " &
               "(Cell/get touched)",
               "false")

  test "a lazy logging macro carries its LogLevel dependency":
    check_eval("(import log [new_logger]) " &
               "(var logger (new_logger \"app/spec\")) " &
               "(import log [debug!]) " &
               "(var touched (cell false)) " &
               "(debug! logger (do (Cell/set touched true) \"x\")) " &
               "(Cell/get touched)",
               "false")

  test "logging payload rejects process-bound values":
    check_eval("(import log [new_logger]) " &
               "(try (new_logger \"app/spec\" ^payload {^bad (cell 1)}) " &
               "  false catch _ true)",
               "true")

  test "logging payload reserves event envelope keys":
    check_eval("(import log [new_logger]) " &
               "(try (new_logger \"app/spec\" ^payload {^message \"fake\"}) " &
               "  false catch _ true)",
               "true")

suite "spec — db protocol from stdlib plan":
  test "sqlite backend covers CRUD, typed params, and typed rows":
    check_eval("(import db/sqlite [open]) (var c (open \":memory:\")) " &
               "(c ~ exec \"create table t (id integer primary key, x text, f float, b integer)\") " &
               "(c ~ execute \"insert into t(x, f, b) values (?, ?, ?)\" \"a\" 1.5 true) " &
               "(c ~ query \"select * from t\")",
               "[{^id 1 ^x \"a\" ^f 1.5 ^b 1}]")
    check_eval("(import db/sqlite [open]) (var c (open \":memory:\")) " &
               "(c ~ exec \"create table t (x text)\") " &
               "(c ~ query_one \"select * from t where x = ?\" \"missing\")",
               "nil")
    check_eval("(import db/sqlite [open DbError]) " &
               "(var c (open \":memory:\")) " &
               "(try (c ~ query \"select * from missing\") " &
               "catch (DbError ^message _) \"caught\")",
               "\"caught\"")

  test "sqlite transactions roll back on recoverable failure":
    check_eval("(import db/sqlite [open]) (var c (open \":memory:\")) " &
               "(c ~ exec \"create table t (x text)\") " &
               "(try (c ~ transaction (fn [d] " &
               "  (d ~ execute \"insert into t(x) values (?)\" \"doomed\") " &
               "  (fail \"abort\"))) catch _ nil) " &
               "(c ~ transaction (fn [d] " &
               "  (d ~ execute \"insert into t(x) values (?)\" \"kept\"))) " &
               "(c ~ query \"select x from t\")",
               "[{^x \"kept\"}]")

  test "connections close explicitly and reject further use":
    check_eval("(import db/sqlite [open DbError]) " &
               "(var c (open \":memory:\")) " &
               "(var before (c ~ closed?)) (c ~ close) " &
               "[before (c ~ closed?) " &
               " (try (c ~ query \"select 1\") " &
               " catch (DbError ^message _) \"rejected\")]",
               "[false true \"rejected\"]")

  test "sqlite and postgres share one Db protocol":
    check_eval("(import db [Db]) " &
               "[(same? Db (Namespace/lookup db/sqlite \"Db\")) " &
               " (same? Db (Namespace/lookup db/postgres \"Db\")) " &
               " (not (== (Namespace/lookup db/postgres \"open\") void))]",
               "[true true true]")

suite "spec — store persistence protocol":
  test "crypto sha256 matches the standard known vector":
    check_eval("(import crypto [sha256]) (sha256 \"abc\")",
               "\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"")

  test "crypto random_hex returns the requested number of random bytes":
    check_eval("(import crypto [random_hex]) " &
               "(import str [byte_size]) " &
               "(byte_size (random_hex 16))", "32")
    check_eval("(import crypto [random_hex]) " &
      "(try (random_hex 0) catch {^message m} m)",
      "\"crypto/random_hex byte count must be between 1 and 1024\"")

  test "crypto secure_equal? compares credentials without an early-exit API":
    check_eval("(import crypto [secure_equal?]) " &
      "[(secure_equal? \"secret\" \"secret\") " &
      " (secure_equal? \"secret\" \"secrex\") " &
      " (secure_equal? \"secret\" \"short\")]", "[true false false]")

  test "sqlite store round-trips data records and missing/default semantics":
    check_eval("(import db/sqlite [open]) " &
               "(import store/sqlite [open : store-open StoreError]) " &
               "(var db (open \":memory:\")) " &
               "(var s (store-open db)) " &
               "(s ~ put \"a\" {^x 1}) " &
               "(s ~ put \"void\" void) " &
               "[(s ~ get \"a\") " &
               " (s ~ get \"void\") " &
               " (s ~ has? \"a\") " &
               " (s ~ has? \"missing\") " &
               " (s ~ get \"missing\" ^default \"fallback\") " &
               " (try (s ~ get \"missing\") catch (StoreError ^kind k) k)]",
               "[{^x 1} void true false \"fallback\" missing]")

  test "sqlite store supports full mode refs, keys, delete, clear, and close":
    check_eval("(import db/sqlite [open]) " &
               "(import store/sqlite [open : store-open StoreError]) " &
               "(var db (open \":memory:\")) " &
               "(var s (store-open db)) " &
               "(s ~ put \"fn\" str/join ^mode \"full\") " &
               "(s ~ put \"n\" 1) " &
               "(var got (s ~ get \"fn\" ^mode \"full\")) " &
               "(var before (s ~ keys)) " &
               "(s ~ delete \"n\") " &
               "(var after-delete [(s ~ has? \"n\") (s ~ keys)]) " &
               "(s ~ clear) " &
               "(var after-clear (s ~ keys)) " &
               "(s ~ close) " &
               "[(same? got str/join) before after-delete after-clear " &
               " (try (s ~ keys) catch (StoreError ^kind k) k)]",
               "[true [\"fn\" \"n\"] [false [\"fn\"]] [] closed]")

  test "filesystem store uses encoded keys and ignores junk files":
    let dir = getTempDir() / "gene-store-fs-spec"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    writeFile(dir / "junk.tmp", "not a record")
    check_eval("(import store/fs [open : store-open StoreError]) " &
               "(import Fs [ReadWriteDir]) " &
               "(var s (store-open ReadWriteDir ^root " & geneString(dir) & ")) " &
               "(s ~ put \"session:tg/42\" {^x 1}) " &
               "[(s ~ get \"session:tg/42\") " &
               " (s ~ keys) " &
               " (try (s ~ put \"\" 1) catch (StoreError ^kind k) k)]",
               "[{^x 1} [\"session:tg/42\"] invalid_key]")

  test "sqlite checkpoints publish one hash-validated generation atomically":
    check_eval("(import db/sqlite [open]) " &
               "(import store/sqlite [open : store-open]) " &
               "(var db (open \":memory:\")) " &
               "(var s (store-open db)) " &
               "(s ~ checkpoint 1 {^session {^schema 1 ^data {^x 1}}}) " &
               "(s ~ checkpoint 2 {^session {^schema 1 ^data {^x 2}} " &
               "                   ^events {^schema 1 ^data [\"ok\"]}}) " &
               "(var loaded (s ~ load_checkpoint)) " &
               "[loaded/generation loaded/schema " &
               " loaded/records/session/data/x loaded/records/events/data]",
               "[2 1 2 [\"ok\"]]")

  test "sqlite store files are owner-only":
    when defined(posix):
      let path = getTempDir() / "gene-store-owner-only-spec.sqlite"
      for suffix in ["", "-wal", "-shm", "-journal"]:
        if fileExists(path & suffix): removeFile(path & suffix)
      check_eval("(import db/sqlite [open]) " &
                 "(import store/sqlite [open : store-open]) " &
                 "(var db (open " & geneString(path) & ")) " &
                 "(var s (store-open db)) " &
                 "(s ~ checkpoint 1 {^session {^schema 1 ^data {^x 1}}}) " &
                 "(s ~ close) (db ~ close) true",
                 "true")
      check getFilePermissions(path) == {fpUserRead, fpUserWrite}

  test "filesystem checkpoints fall back from a corrupt newest generation":
    let dir = getTempDir() / "gene-store-fs-checkpoint-spec"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    check_eval("(import store/fs [open : store-open]) " &
               "(import Fs [ReadWriteDir]) " &
               "(var s (store-open ReadWriteDir ^root " & geneString(dir) & ")) " &
               "(s ~ checkpoint 1 {^session {^schema 1 ^data {^x 1}}}) " &
               "(s ~ checkpoint 2 {^session {^schema 1 ^data {^x 2}}}) " &
               "(var loaded (s ~ load_checkpoint)) " &
               "[loaded/generation loaded/records/session/data/x]",
               "[2 2]")
    let newest = dir / "generations" / "00000000000000000002" /
                 "session.gene"
    writeFile(newest, "corrupt")
    check_eval("(import store/fs [open : store-open]) " &
               "(import Fs [ReadWriteDir]) " &
               "(var s (store-open ReadWriteDir ^root " & geneString(dir) & ")) " &
               "(var loaded (s ~ load_checkpoint)) " &
               "[loaded/generation loaded/records/session/data/x]",
               "[1 1]")
    when defined(posix):
      check getFilePermissions(dir) ==
        {fpUserRead, fpUserWrite, fpUserExec}

suite "spec — os and json from ai-agent plan":
  test "os/get_env reads, defaults, and errors under Os/Env":
    check_eval("(import os [get_env env? Env]) " &
               "[(env? Env \"GENE_SPEC_UNSET_XYZ\") " &
               " (get_env Env \"GENE_SPEC_UNSET_XYZ\" \"fallback\")]",
               "[nil \"fallback\"]")
    check_eval("(import os [get_env Env OsError]) " &
               "(try (get_env Env \"GENE_SPEC_UNSET_XYZ\") " &
               "catch (OsError ^message _) \"unset\")",
               "\"unset\"")

  test "os/get_env rejects a non-Os/Env capability":
    check_eval("(import os [get_env OsError]) " &
               "(try (get_env Net/Connect \"HOME\") " &
               "catch (OsError ^message _) \"denied\")",
               "\"denied\"")

  test "os/executable_path identifies the running Gene executable":
    check_eval("(import os [executable_path]) " &
               "(import str [byte_size]) " &
               "(> (byte_size (executable_path)) 0)",
               "true")

  test "os/exec runs a program, captures output, and enforces timeout":
    check_eval("(import os [exec Exec]) " &
               "(var r (exec Exec ^cmd \"echo\" ^args [\"hi\"])) " &
               "[r/status r/timed_out]",
               "[0 false]")
    check_eval("(import os [exec Exec]) " &
               "(var r (exec Exec ^cmd \"sleep\" ^args [\"5\"] ^timeout_ms 150)) " &
               "r/timed_out",
               "true")

    check_eval("(import os [exec Exec]) " &
               "(var r (exec Exec ^cmd \"printf\" ^args [\"abcdef\"] ^max_bytes 3)) " &
               "[r/stdout r/stdout_truncated r/truncated]",
               "[\"abc\" true true]")

  test "os/exec_stream invokes stdout callbacks while retaining captured output":
    check_eval("(import os [exec_stream Exec]) " &
               "(import std/stream [to_stream into]) " &
               "(var seen (cell [])) " &
               "(var r (exec_stream Exec ^cmd \"printf\" ^args [\"a\\nb\\n\"] " &
               "                    ^stdout_line (fn [line] " &
               "                      (seen ~ Cell/set ((to_stream [line]) ~ into (seen ~ Cell/get)))))) " &
               "[r/status r/stdout (seen ~ Cell/get)]",
               "[0 \"a\\nb\\n\" [\"a\" \"b\"]]")

  test "os/exec_stdio runs with parent streams and returns status":
    check_eval("(import os [exec_stdio Exec]) " &
               "(exec_stdio Exec ^cmd \"sh\" ^args [\"-c\" \"exit 7\"])",
               "7")

  test "os/exec_stdio_async inherits streams without blocking the scheduler":
    check_eval("(import os [exec_stdio_async Exec]) " &
               "(var ticks (cell 0)) " &
               "(var status (cell -1)) " &
               "(scope " &
               "  (spawn (repeat 5 (do (sleep 20) " &
               "    (ticks ~ Cell/set (+ (ticks ~ Cell/get) 1))))) " &
               "  (status ~ Cell/set " &
               "    (await (exec_stdio_async Exec ^cmd \"sh\" " &
               "      ^args [\"-c\" \"sleep 0.2; exit 7\"])))) " &
               "[(status ~ Cell/get) (ticks ~ Cell/get)]",
               "[7 5]")

  test "os/exec_async settles a task off-thread with the exec result map":
    check_eval("(import os [exec_async Exec]) " &
               "(var r (await (exec_async Exec ^cmd \"echo\" ^args [\"hi\"]))) " &
               "[r/status r/timed_out]",
               "[0 false]")
    check_eval("(import os [exec_async Exec]) " &
               "(var r (await (exec_async Exec ^cmd \"sleep\" ^args [\"5\"] " &
               "                          ^timeout_ms 150))) " &
               "r/timed_out",
               "true")
    check_eval("(import os [exec_async Exec]) " &
               "(var status 1) " &
               "(repeat 20 " &
               "  (set status ((await (exec_async Exec ^cmd \"true\")) ~ /status))) " &
               "status",
               "0")

  test "root await polls external tasks before unrelated distant timers":
    let started = getMonoTime()
    check_eval("(import os [exec_async Exec]) " &
               "(var status -1) " &
               "(scope " &
               "  (var distant (spawn (sleep 1500))) " &
               "  (var r (await (exec_async Exec ^cmd \"sh\" " &
               "    ^args [\"-c\" \"sleep 0.05\"]))) " &
               "  (set status r/status) " &
               "  (distant ~ Task/cancel)) " &
               "status",
               "0")
    check getMonoTime() - started < initDuration(milliseconds = 800)

  test "os/exec_stream_async feeds stdout lines through a channel then closes it":
    check_eval("(import os [exec_stream_async Exec]) " &
               "(import std/stream [to_stream into]) " &
               "(var ch (channel ^capacity 8)) " &
               "(var t (exec_stream_async Exec ^cmd \"printf\" " &
               "         ^args [\"a\\nb\\n\"] ^stdout_chan ch)) " &
               "(var seen (cell [])) (var line nil) " &
               "(try (loop (set line (ch ~ Channel/recv)) " &
               "  (seen ~ Cell/set ((to_stream [line]) ~ into (seen ~ Cell/get)))) " &
               "catch (ChannelClosed) nil) " &
               "(var r (await t)) " &
               "[(seen ~ Cell/get) r/stdout r/status]",
               "[[\"a\" \"b\"] \"a\\nb\\n\" 0]")

  test "os turn interrupt polling is scoped and consumptive":
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      check_eval("(import os [begin_interrupt take_interrupt end_interrupt]) " &
                 "[(begin_interrupt) (take_interrupt) (end_interrupt)]",
                 "[true false nil]")
    else:
      check_eval("(import os [begin_interrupt take_interrupt end_interrupt]) " &
                 "[(begin_interrupt) (take_interrupt) (end_interrupt)]",
                 "[false false nil]")

  test "os/monotonic_ms is nondecreasing":
    check_eval("(import os [monotonic_ms]) " &
               "(var a (monotonic_ms)) (sleep 2) (>= (monotonic_ms) a)",
               "true")

  test "Task/cancel terminates an async exec child and closes its channel":
    let started = getMonoTime()
    check_eval("(import os [exec_stream_async Exec]) " &
               "(scope " &
               "  (var ch (channel ^capacity 1)) " &
               "  (var t (exec_stream_async Exec ^cmd \"sleep\" ^args [\"2\"] " &
               "           ^stdout_chan ch)) " &
               "  (spawn (do (sleep 50) (t ~ Task/cancel))) " &
               "  (try (loop (ch ~ Channel/recv)) " &
               "    catch (ChannelClosed) \"closed\"))",
               "\"closed\"")
    check getMonoTime() - started < initDuration(milliseconds = 1200)

  test "Task/cancel terminates an inherited-stream async child":
    let started = getMonoTime()
    check_eval("(import os [exec_stdio_async Exec]) " &
               "(scope " &
               "  (var t (exec_stdio_async Exec ^cmd \"sleep\" ^args [\"2\"])) " &
               "  (spawn (do (sleep 50) (t ~ Task/cancel))) " &
               "  (sleep 200) " &
               "  \"cancelled\")",
               "\"cancelled\"")
    check getMonoTime() - started < initDuration(milliseconds = 1200)

  test "scheduler stays live while an async exec child runs":
    # The whole point of the async variants (examples/ai_agent/design.md §12.9 gap 1):
    # fibers must make progress during a subprocess. The snapshot is taken
    # right after the await — a blocking exec would leave it at 0.
    check_eval("(import os [exec_async Exec]) " &
               "(var ticks (cell 0)) " &
               "(var during (cell 0)) " &
               "(scope " &
               "  (spawn (repeat 5 (do (sleep 20) " &
               "    (ticks ~ Cell/set (+ (ticks ~ Cell/get) 1))))) " &
               "  (var r (await (exec_async Exec ^cmd \"sleep\" ^args [\"0.3\"]))) " &
               "  (during ~ Cell/set (ticks ~ Cell/get))) " &
               "(during ~ Cell/get)",
               "5")

  test "Fs sync helpers read, write, and list under capabilities":
    let dir = getTempDir() / "gene-ai-agent-fs-spec"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    let path = dir / "note.txt"
    let made = dir / "made"
    let removable = dir / "remove-me.txt"
    check_eval("(import Fs [read_text write_text exists? list_dir make_dir remove " &
               "ReadDir WriteDir]) " &
               "(write_text WriteDir " & geneString(path) & " \"hello\") " &
               "(write_text WriteDir " & geneString(removable) & " \"bye\") " &
               "(make_dir WriteDir " & geneString(made) & ") " &
               "(remove WriteDir " & geneString(removable) & ") " &
               "[(read_text ReadDir " & geneString(path) & ") " &
               " (exists? ReadDir " & geneString(path) & ") " &
               " (exists? ReadDir " & geneString(removable) & ") " &
               " (list_dir ReadDir " & geneString(dir) & ")]",
               "[\"hello\" true false [\"made\" \"note.txt\"]]")

  test "Fs/real_path resolves an existing file and a not-yet-created path":
    ## examples/ai_agent/design.md §8.5: workspace confinement resolves real paths before
    ## the containment check. An existing file and a to-be-created file under
    ## the same directory must resolve to sibling absolute paths, so a `..`
    ## detour still lands inside the resolved root.
    let dir = getTempDir() / "gene-ai-agent-realpath-spec"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    let path = dir / "here.txt"
    writeFile(path, "x")
    check_eval("(import Fs [real_path write_text ReadDir WriteDir]) " &
               "(import str [starts_with?]) " &
               "(var base (real_path ReadDir " & geneString(dir) & ")) " &
               "(var direct (real_path ReadDir " & geneString(path) & ")) " &
               "(var detour (real_path ReadDir " &
               geneString(dir / "sub" / ".." / "new.txt") & ")) " &
               "[(== direct (real_path ReadDir " & geneString(dir & "/here.txt") & ")) " &
               " (starts_with? direct base) " &
               " (starts_with? detour base)]",
               "[true true true]")

  test "Fs/real_path follows a dangling final symlink to its real target":
    ## examples/ai_agent/design.md §8.5: a workspace symlink whose target does not exist
    ## yet must still resolve to (and be confined against) where a write would
    ## land, not be treated as an ordinary in-workspace name — otherwise a
    ## dangling symlink is a write escape.
    let root = getTempDir() / "gene-ai-agent-symlink-spec"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    let ws = root / "ws"
    let outside = root / "outside"
    createDir(ws)
    createDir(outside)
    createSymlink(outside / "new-file", ws / "escape")
    # Compare against the resolved outside dir (getTempDir may itself sit under
    # a symlink, e.g. macOS /var -> /private/var), so both sides are real paths.
    check_eval("(import Fs [real_path ReadDir]) " &
               "(import str [starts_with?]) " &
               "(var base (real_path ReadDir " & geneString(ws) & ")) " &
               "(var outside-real (real_path ReadDir " & geneString(outside) & ")) " &
               "(var rp (real_path ReadDir " & geneString(ws / "escape") & ")) " &
               "[(starts_with? rp base) (starts_with? rp outside-real)]",
               "[false true]")

  test "json round-trips objects, arrays, scalars, and escapes":
    check_eval("(import json [parse stringify]) " &
               "(stringify (parse \"{\\\"a\\\":1,\\\"b\\\":[true,null,2.5]}\"))",
               "\"{\\\"a\\\":1,\\\"b\\\":[true,null,2.5]}\"")
    check_eval("(import json [parse]) (var m (parse \"{\\\"x\\\":\\\"a\\\\nb\\\"}\")) m/x",
               "\"a\\nb\"")

  test "json/parse raises JsonError on malformed input and trailing junk":
    check_eval("(import json [parse JsonError]) " &
               "(try (parse \"{bad}\") catch (JsonError ^message _) \"e1\")",
               "\"e1\"")
    check_eval("(import json [parse JsonError]) " &
               "(try (parse \"[1] extra\") catch (JsonError ^message _) \"e2\")",
               "\"e2\"")

  test "json/stringify raises JsonError for unsupported values":
    check_eval("(import json [stringify JsonError]) " &
               "(try (stringify (fn [] nil)) " &
               "catch (JsonError ^message _) \"bad\")",
               "\"bad\"")

suite "spec — equality and guard sugar (design §1.5/§3)":
  test "== is structural equality and chains":
    check_eval("(== 1 1)", "true")
    check_eval("(== 1 2)", "false")
    check_eval("(== [1 {^a 2}] [1 {^a 2}])", "true")
    check_eval("(== 1 1 1)", "true")
    check_eval("(== 1 1 2)", "false")

  test "!= is exactly (! (== ...))":
    check_eval("(!= 1 2)", "true")
    check_eval("(!= 1 1)", "false")
    check_eval("(!= [1] [2])", "true")
    check_eval("(!= 1 1 2)", "true")

  test "bare = is no longer bound":
    expect GeneError:
      discard run(compileSource("(" & "= 1 1)"), newGlobalScope())

  test "if_yes evaluates its whole tail as the then branch":
    check_eval("(if_yes true 1 2 3)", "3")
    check_eval("(if_yes false 1 2 3)", "nil")
    check_eval("(if_yes true)", "nil")
    check_eval("(var a 1) (if_yes true (set a 5) (+ a 10))", "15")

  test "if_not evaluates its whole tail as the else branch":
    check_eval("(if_not false 1 2 3)", "3")
    check_eval("(if_not true 1 2 3)", "nil")
    check_eval("(if_not false)", "nil")

  test "map ^^k is true-flag sugar, consistent with node props":
    check_eval("(var m {^^ok}) m/ok", "true")
    check_eval("(var m {^^ok ^n 1}) m/n", "1")
    check_eval("(var n (quote (x ^^ok))) n/ok", "true")

  test "contains? is structural membership on lists and sets":
    check_eval("([\"a\" \"b\"] ~ contains? \"b\")", "true")
    check_eval("([\"a\" \"b\"] ~ contains? \"c\")", "false")
    check_eval("([[1 2]] ~ contains? [1 2])", "true")
    check_eval("((Set 1 2) ~ contains? 2)", "true")
    check_eval("((Set 1 2) ~ contains? 3)", "false")
    check_eval("(contains? #[1 2] 2)", "true")

  test "contains? rejects non-collection receivers":
    expect GeneError:
      discard run(compileSource("({^a 1} ~ contains? \"a\")"),
                  newGlobalScope())

suite "spec — serde data core (docs/proposals/serialization.md stage 1)":
  test "scalars and containers round-trip under structural equality":
    check_eval("(import serde [write_data read_data]) " &
               "(var v {^a 1 ^b [1 2.5 \"x\" true nil void] " &
               "        ^c {^nested \"y\"} ^d 'q' ^e 0x0aff " &
               "        ^f 123456789012345678901234567890}) " &
               "(== v (read_data (write_data v)))",
               "true")
    check_eval("(import serde [write_data read_data]) " &
               "(import str [contains?]) " &
               "(var v #[1 #{^k 2} [3]]) " &
               "(var rt (read_data (write_data v))) " &
               "[(== v rt) (contains? (write_data rt) \"#[1 #{\")]",
               "[true true]")

  test "dates, times, ranges, sets, durations, timezones round-trip":
    check_eval("(import serde [write_data read_data]) " &
               "(var v [2026-07-08 12:30:05 2026-07-08T12:30:05Z " &
               "        (range 1 10 2) (Set 1 2 3) (duration 1500000) " &
               "        (timezone 120 \"CEST\")]) " &
               "(== v (read_data (write_data v)))",
               "true")

  test "regexes round-trip as source plus flags":
    check_eval("(import serde [write_data read_data]) " &
               "(var v #\"ab+c\"i) " &
               "(== v (read_data (write_data v)))",
               "true")

  test "nodes round-trip including props, meta, children, immutability":
    check_eval("(import serde [write_data read_data]) " &
               "(var v `(p @m 1 ^x 2 \"c\" [3])) " &
               "(== v (read_data (write_data v)))",
               "true")

  test "reserved serde heads in user data are escaped and round-trip":
    check_eval("(import serde [write_data read_data]) " &
               "(import str [contains?]) " &
               "(var evil `(serde_float \"nan\")) " &
               "(var text (write_data evil)) " &
               "[(contains? text \"serde_data_node\") " &
               " (== evil (read_data text))]",
               "[true true]")
    check_eval("(import serde [write_data read_data]) " &
               "(var evil2 `(serde_data_node 1)) " &
               "(== evil2 (read_data (write_data evil2)))",
               "true")

  test "float specials use canonical serde_float forms":
    check_eval("(import serde [write_data read_data]) " &
               "(import str [contains?]) " &
               "(var nanv (read_data \"(serde_v1 (serde_float \\\"nan\\\"))\")) " &
               "(var back (write_data nanv)) " &
               "[(contains? back \"serde_float\") " &
               " (!= nanv nanv)]",   # NaN != NaN
               "[true true]")
    check_eval("(import serde [write_data read_data]) " &
               "(var inf (read_data \"(serde_v1 (serde_float \\\"+inf\\\"))\")) " &
               "(== inf (read_data (write_data inf)))",
               "true")

  test "symbols that do not re-read verbatim are escaped":
    check_eval("(import serde [write_data read_data]) " &
               "(import str [contains?]) " &
               "(var s (read_data \"(serde_v1 (serde_sym \\\"a/b\\\"))\")) " &
               "(var text (write_data s)) " &
               "[(contains? text \"serde_sym\") " &
               " (== s (read_data text))]",
               "[true true]")

  test "maps with non-literal keys use the serde_map escape":
    check_eval("(import serde [write_data read_data]) " &
               "(import str [contains?]) " &
               "(var m {}) (m ~ Map/put! \"weird key\" 1) " &
               "(var text (write_data m)) " &
               "[(contains? text \"serde_map\") " &
               " (== m (read_data text))]",
               "[true true]")

  test "cells and capabilities are rejected with clear errors":
    check_eval("(import serde [write_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (write_data [1 (cell 2)]) " &
               "catch (SerdeError ^message m) " &
               "  [(contains? m \"at 1:\") (contains? m \"not data\")])",
               "[true true]")
    check_eval("(import serde [write_data SerdeError]) " &
               "(try (write_data {^net Net/Connect}) " &
               "catch (SerdeError ^path p) p)",
               "\"net\"")

  test "serde/data? classifies without raising":
    check_eval("(import serde [data?]) " &
               "[(data? [1 {^a 2}]) (data? (cell 1)) (data? (fn [] 1))]",
               "[true false false]")
    check_eval("(import serde [write_data data?]) " &
               "[(try (write_data 1 ^policy nil) catch _ \"rejected\") " &
               " (try (data? 1 ^policy nil) catch _ \"rejected\")]",
               "[\"rejected\" \"rejected\"]")

  test "serde rejects executable selectors and traverses node metadata":
    check_eval("(import serde [data? write_data read_data SerdeError]) " &
               "(var pure /name) " &
               "(var executable (select %(map /name))) " &
               "[(data? pure) (== pure (read_data (write_data pure))) " &
               " (data? executable) " &
               " (try (write_data executable) catch (SerdeError) \"rejected\") " &
               " (data? `(x @state %(cell 1)))]",
               "[true true false \"rejected\" false]")

  test "cycles are detected with a path":
    check_eval("(import serde [write_data SerdeError]) " &
               "(import str [contains?]) " &
               "(var m {}) (m ~ Map/put! \"self\" m) " &
               "(try (write_data m) " &
               "catch (SerdeError ^message msg) (contains? msg \"cycle\"))",
               "true")

  test "policy limits are enforced and named":
    check_eval("(import serde [read_data SerdeError SerdePolicy]) " &
               "(import str [contains?]) " &
               "(try (read_data \"(serde_v1 [[[[1]]]])\" " &
               "               ^policy (SerdePolicy ^max_depth 2)) " &
               "catch (SerdeError ^message m) (contains? m \"max_depth\"))",
               "true")
    let deep = "(serde_v1 " & repeat("[", 20) & "1" & repeat("]", 20) & ")"
    check_eval("(import serde [read_data SerdeError SerdePolicy]) " &
               "(import str [contains?]) " &
               "(try (read_data " & geneString(deep) &
               "               ^policy (SerdePolicy ^max_depth 2)) " &
               "catch (SerdeError ^message m) " &
               "  (&& (contains? m \"parse\") (contains? m \"max_depth\")))",
               "true")
    check_eval("(import serde [read_data SerdeError SerdePolicy]) " &
               "(import str [contains?]) " &
               "(try (read_data \"(serde_v1 [1 2 3 4 5])\" " &
               "               ^policy (SerdePolicy ^max_nodes 3)) " &
               "catch (SerdeError ^message m) (contains? m \"max_nodes\"))",
               "true")
    check_eval("(import serde [read_data SerdeError SerdePolicy]) " &
               "(import str [contains?]) " &
               "(try (read_data \"(serde_v1 [a b c])\" " &
               "               ^policy (SerdePolicy ^max_symbols 2)) " &
               "catch (SerdeError ^message m) (contains? m \"max_symbols\"))",
               "true")
    check_eval("(import serde [read_data SerdeError SerdePolicy]) " &
               "(import str [contains?]) " &
               "(try (read_data \"(serde_v1 nil)\" " &
               "               ^policy (SerdePolicy ^max_bytes 5)) " &
               "catch (SerdeError ^message m) (contains? m \"max_bytes\"))",
               "true")

  test "envelope versioning is enforced":
    check_eval("(import serde [read_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read_data \"(serde_v2 nil)\") " &
               "catch (SerdeError ^message m) " &
               "  (contains? m \"unsupported serde envelope\"))",
               "true")
    check_eval("(import serde [read_data SerdeError]) " &
               "(try (read_data \"[1 2]\") " &
               "catch (SerdeError ^message _) \"no-envelope\")",
               "\"no-envelope\"")

  test "unknown control tags and malformed shapes are rejected":
    check_eval("(import serde [read_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read_data \"(serde_v1 (serde_bogus 1))\") " &
               "catch (SerdeError ^message m) (contains? m \"serde_bogus\"))",
               "true")
    check_eval("(import serde [read_data SerdeError]) " &
               "(try (read_data \"(serde_v1 (serde_range 1 2))\") " &
               "catch (SerdeError ^message _) \"bad-range\")",
               "\"bad-range\"")
    check_eval("(import serde [read_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read_data \"(serde_v1 (serde_map false [\\\"a\\\" 1 \\\"a\\\" 2]))\") " &
               "catch (SerdeError ^message m) (contains? m \"duplicate key\"))",
               "true")
    check_eval("(import serde [read_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read_data \"(serde_v1 (serde_set 1 1))\") " &
               "catch (SerdeError ^message m) (contains? m \"duplicate\"))",
               "true")
    check_eval("(import serde [read_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read_data \"(serde_v1 (serde_set [1]))\") " &
               "catch (SerdeError ^message m) (contains? m \"hash-stable\"))",
               "true")

suite "spec — serde references (stage 3)":
  test "builtin function references round-trip by identity":
    check_eval("(import serde [write read]) " &
               "(== str/join (read (write str/join)))",
               "true")
    check_eval("(import serde [write read]) " &
               "(var f (read (write str/join))) (f [\"a\" \"b\"] \"-\")",
               "\"a-b\"")

  test "builtin references carry a path but no module":
    check_eval("(import serde [write]) " &
               "(import str [contains?]) " &
               "(var t (write str/join)) " &
               "[(contains? t \"serde_fn_ref\") (contains? t \"str/join\") " &
               " (contains? t \"^module\")]",
               "[true true false]")

  test "write_data refuses references":
    check_eval("(import serde [write_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (write_data str/join) " &
               "catch (SerdeError ^message m) (contains? m \"not data\"))",
               "true")

  test "read_data refuses reference tags":
    check_eval("(import serde [write read_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read_data (write str/join)) " &
               "catch (SerdeError ^message m) (contains? m \"serde/read\"))",
               "true")

  test "unresolved module reference errors without loading":
    check_eval("(import serde [read SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read \"(serde_v1 (serde_type_ref ^module \\\"no/such\\\" " &
               "^path \\\"X\\\"))\") " &
               "catch (SerdeError ^message m) (contains? m \"not loaded\"))",
               "true")

  test "reserved ref props are rejected":
    check_eval("(import serde [read SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read \"(serde_v1 (serde_type_ref ^package \\\"p\\\" " &
               "^path \\\"X\\\"))\") " &
               "catch (SerdeError ^message m) (contains? m \"reserved\"))",
               "true")

  test "a reference resolving to the wrong kind errors":
    check_eval("(import serde [read SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read \"(serde_v1 (serde_type_ref ^path \\\"str/join\\\"))\") " &
               "catch (SerdeError ^message m) (contains? m \"not the expected kind\"))",
               "true")

  test "cells snapshot through serde/write, outside the equality guarantee":
    check_eval("(import serde [write read]) " &
               "(var c (cell 41)) (var c2 (read (write c))) " &
               "[(c2 ~ Cell/get) (!= c c2)]",
               "[41 true]")

  test "write_data refuses cells; read_data refuses snapshot-cells":
    check_eval("(import serde [write_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (write_data (cell 1)) " &
               "catch (SerdeError ^message m) (contains? m \"not data\"))",
               "true")
    check_eval("(import serde [write read_data SerdeError]) " &
               "(import str [contains?]) " &
               "(try (read_data (write (cell 1))) " &
               "catch (SerdeError ^message m) (contains? m \"read_data\"))",
               "true")

  test "atomic cells never serialize":
    check_eval("(import serde [write SerdeError]) " &
               "(import str [contains?]) " &
               "(try (write (atomic_cell 1)) " &
               "catch (SerdeError ^message m) (contains? m \"atomic\"))",
               "true")

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

suite "spec — documentation contract":
  test "focused normative specification files exist":
    for path in ["docs/spec/README.md", "docs/spec/reader.md",
                 "docs/spec/calls.md", "docs/spec/types.md",
                 "docs/spec/protocols.md", "docs/spec/streams.md",
                 "docs/spec/concurrency.md", "docs/spec/modules.md",
                 "docs/implementation-status.md"]:
      check fileExists(path)

  test "referenced concrete example files exist":
    var sources = @["README.md"]
    for path in walkDirRec("docs"):
      if path.endsWith(".md"):
        sources.add path
    for source in sources:
      let text = readFile(source)
      var at = 0
      while true:
        at = text.find("examples/", at)
        if at < 0:
          break
        var stop = at
        while stop < text.len and
            (text[stop].isAlphaNumeric or text[stop] in {'/', '_', '-', '.'}):
          inc stop
        let referenced = text[at ..< stop].strip(chars = {'.'})
        if referenced.endsWith(".gene") or referenced.endsWith(".md"):
          check fileExists(referenced)
        at = max(stop, at + 1)

suite "spec — naming convention":
  test "registered names use underscores, never hyphens":
    # The stdlib naming convention is snake_case. Walk every binding reachable
    # from the global scope (namespaces recursively, protocol message names)
    # and reject any registered name containing a hyphen. Wire-format strings
    # (HTTP header names, MIME types) are not bindings and stay untouched.
    var offenders: seq[string]
    var seen: HashSet[uint64]
    var stack = @[("", newGlobalScope())]
    while stack.len > 0:
      let (prefix, scope) = stack.pop()
      if scope == nil:
        continue
      scope.materializeMirroredVars()
      for name, v in scope.vars:
        let qual = if prefix.len > 0: prefix & "/" & name else: name
        if '-' in name:
          offenders.add qual
        if v.kind == vkNamespace and not seen.containsOrIncl(v.bits):
          stack.add((qual, v.nsScope))
        elif v.kind == vkProtocol and not seen.containsOrIncl(v.bits):
          for msgName, _ in v.protocolMessages:
            if '-' in msgName:
              offenders.add qual & "/" & msgName
    sort(offenders)
    check offenders == newSeq[string]()
