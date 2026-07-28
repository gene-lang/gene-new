## Executable Gene language surface spec.
##
## This file intentionally checks behavior from docs/spec/ and
## examples/web_demo.gene at a higher level than unit tests. Run after changes:
##   nimble spec

import gene/[compiler, gir, printer, reader, types, vm]
# Side-effect import: puts the {.exportc, dynlib.} AOT boundary helpers into
# this test binary's dynamic symbol table so a dlopened AOT library resolves
# them, exactly as the gene executable does.
import gene/aot_runtime
import std/[algorithm, monotimes, os, osproc, sequtils, sets, strutils, tables,
            times, unittest]

proc sharedNativeIdentity(scope: Scope, typeName, msg, rootName: string): bool =
  ## A native bound both into the lexical root and into a type's message table
  ## must be one object. `T/m` used to make that observable from Gene; decision
  ## 4 withdrew it, so the invariant is checked directly against the table.
  let typ = run(compileSource(typeName), scope)
  let rootFn = run(compileSource(rootName), scope)
  typeDirectMessage(typ, msg).bits == rootFn.bits

template check_shared_native(typeName, msg, rootName: string) =
  check sharedNativeIdentity(newGlobalScope(), typeName, msg, rootName)

template check_read(src: string, expected: string) =
  check read(src).print() == expected

template check_eval(src: string, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template check_compile_error(src: string, fragment: string) =
  ## Asserts that compiling `src` raises with `fragment` in the message.
  var raised = false
  try:
    discard compileSource(src)
  except CatchableError as e:
    raised = true
    check fragment in e.msg
  check raised

template check_emit_c_error(src: string, fragment: string) =
  ## Asserts that C emission raises with `fragment`. Analysis and emission
  ## re-derive lowerability from different data, so a gap can survive
  ## compilation and only appear when the backend runs; it must fail loudly
  ## rather than emit a placeholder.
  var raised = false
  try:
    discard compileSource(src).emitExperimentalC()
  except CatchableError as e:
    raised = true
    check fragment in e.msg
  check raised

template check_runtime_error(src: string, fragment: string) =
  ## Asserts that *running* `src` raises with `fragment` in the message. Some
  ## rules cannot be checked at compile time — the compiler does not track
  ## which names are types, so `(T/m x)` is only recognizable once `T` resolves.
  var raised = false
  try:
    discard run(compileSource(src), newGlobalScope())
  except CatchableError as e:
    raised = true
    check fragment in e.msg
  check raised

proc geneString(s: string): string =
  "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc checkCCompiles(source, label: string) =
  ## Syntax-checks with GENE_AOT_DYNAMIC_ENTRIES defined so the guarded dynamic
  ## entry wrappers stay covered. -fsyntax-only never links, so the helpers
  ## those wrappers call need no definitions here.
  let path = getTempDir() / ("gene_" & label & "_generated.c")
  writeFile(path, source)
  defer:
    removeFile(path)
  let checked = execCmdEx(
    quoteShell(getEnv("CC", "cc")) &
      " -std=c11 -DGENE_AOT_DYNAMIC_ENTRIES=1 -fsyntax-only " &
      quoteShell(path))
  checkpoint checked.output
  check checked.exitCode == 0

proc checkCRuns(source, label, expected: string,
                dynamicEntries = false) =
  ## `dynamicEntries` compiles the guarded wrappers in. Only a caller that also
  ## supplies implementations of the gene_ffi_* / gene_typed_native_* helpers
  ## can link with it; everything else must leave them out.
  let sourcePath = getTempDir() / ("gene_" & label & "_generated.c")
  let exePath = getTempDir() / ("gene_" & label & ExeExt)
  writeFile(sourcePath, source)
  defer:
    if fileExists(sourcePath):
      removeFile(sourcePath)
    if fileExists(exePath):
      removeFile(exePath)
  let built = execCmdEx(
    quoteShell(getEnv("CC", "cc")) & " -std=c11 " &
      (if dynamicEntries: "-DGENE_AOT_DYNAMIC_ENTRIES=1 " else: "") &
      quoteShell(sourcePath) & " -o " & quoteShell(exePath))
  checkpoint built.output
  check built.exitCode == 0
  if built.exitCode == 0:
    let ran = execCmdEx(quoteShell(exePath))
    checkpoint ran.output
    check ran.exitCode == 0
    check ran.output.strip() == expected

suite "spec — reader surface from design":
  test "programs contain multiple top-level forms":
    let forms = readAll("(mod app) (import gene/stream [map]) (fn main [] nil)")
    check forms.len == 3
    check forms[0].print() == "(mod app)"
    check forms[1].print() == "(import (path gene stream) [map])"
    check forms[2].print() == "(fn main [] nil)"

  test "$x selects from the gene root without occupying a bare name":
    check_read("$x", "(path gene x)")
    check_read("gene/str/join", "(path gene str join)")
    check_read("$Actor", "(path gene Actor)")
    # The bare `$` concat head and `$"..."` interpolation are unaffected: `\"`
    # is not a symbol character, so neither can be read as a member path.
    check_read("($ \"a\" 1)", "($ \"a\" 1)")
    check_eval("($println \"x\") (gene/str/join [\"a\" \"b\"] \"-\")", "\"a-b\"")
    check_eval("[(same? $Actor Actor) (same? $Env Env) ($ \"a\" 1)]",
               "[true true \"a1\"]")
    check_eval("(var x 5) $\"v=${x}\"", "\"v=5\"")

  test "selector literals and context-neutral paths stay distinct":
    check_read("/user/name", "(select user name)")
    check_read("user/name", "(path user name)")
    check_read("/users/0/name", "(select users 0 name)")
    check_read("users/-1/name", "(path users -1 name)")
    check_read("(import $net/http [Request])", "(import (path gene net http) [Request])")
    check_read("xs/~size", "(path xs ~size)")
    check_read("(fn f [^server : Http/Server] nil)",
               "(fn f [^ server : Http/Server] nil)")
    check_read("(~ f a)", "(~ f a)")
    check_read("(x; $parse; (|| _ default))", "(|| ((x) (path gene parse)) default)")
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

  test "an immutable node used as data is quoted before evaluation":
    check_eval("`#(user ^name \"Alice\")",
               "#(user ^name \"Alice\")")

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
    fixture(["let"], "(let x 1)")
    fixture(["set!"], "(var m {^a 1}) (set! m/a 2)")
    fixture(["new"],
      "(type FixtureNew ^props {} (ctor [] nil)) (new FixtureNew)")
    expect GeneError:
      discard compileSource("(const K 1)")
    covered.add "const"
    fixture(["if_yes"], "(if_yes true 1 2)")
    fixture(["if_not"], "(if_not false 1 2)")
    fixture(["&&", "||", "??", "!"],
            "[(&& true 1) (|| nil 2) (?? nil 2) (! false)]")
    fixture(["~"], "(fn size-of [self] (~ size))")
    fixture(["fn"], "(fn identity [x] x)")
    fixture(["fn!"], "(fn! syntax-id! [x] x)")
    fixture(["macro"], "(macro identity! [x] `%x) (identity! 1)")
    fixture(["quote", "quasiquote", "select", "path"],
      "(do (quote x) (quasiquote x) (select name) (path a b))")
    # `msg` is what the reader gives `Proto:msg`; `/` stays `path`.
    fixture(["msg"], "(protocol FixtureMsgProto (message m [] : Int)) " &
                     "(fn use [x] (x ~ FixtureMsgProto:m))")
    fixture(["ns"], "(ns sample (var x 1))")
    fixture(["env"], "(env ^bindings {^x 1})")
    fixture(["eval"], "(eval (quote 1) ^in (env))")
    fixture(["import"], "(import gene/stream [map])")
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
    fixture(["alias"], "(alias FixtureAlias (| Int Str))")
    fixture(["enum"], "(enum FixtureEnum one two)")
    fixture(["protocol"], "(protocol FixtureProtocol)")
    fixture(["impl"],
      "(protocol EmptyProtocol) (type EmptyType ^props {}) " &
      "(impl EmptyProtocol for EmptyType)")
    fixture(["?~"],
      "(type Guarded ^props {} (message g [] : Int 1) " &
      "  (message lead [] : Int (?~ g))) " &
      "[((Guarded) ?~ g) (nil ?~ g) (void ?~ g) ((Guarded) ~ lead)]")
    fixture(["import_impl"],
      "(protocol ImportedProtocol) (type ImportedType ^props {}) " &
      "(import_impl ImportedProtocol for ImportedType from \"./elsewhere\")")
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
               "(Light/on ~ Label:label)",
               "\"on\"")
    check_eval("(protocol Code (message code [self] : Int)) " &
               "(enum Status active closed) " &
               "(impl Code for Status " &
               "  (message code [self] : Int (self ~ ordinal))) " &
               "(Status/closed ~ Code:code)",
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
    # docs/macro-design.md §12.5: binders introduced by a template's
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
    check_eval("(var hit ($cell 0)) " &
               "(fn! ignore! [e] nil) " &
               "(ignore! (hit ~ set 9)) " &
               "(hit ~ get)",
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
    check_eval("(var f (fn [x] x)) (var side 0) " &
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

  test "sends resolve receiver-first and raise before evaluating arguments":
    # D6: `~` dispatches only. A bare name that is not a message on the
    # receiver's type is a recoverable MessageError, with a hint when the name
    # is a lexical callable (there is no lexical send fallback).
    check_eval("(fn f [self y] [self y]) " &
               "(try ([1] ~ f 2) catch (MessageError ^receiver_type rt) rt)",
               "\"List\"")
    check_eval("(try ([1] ~ nope 1) catch (MessageError ^message m) m)",
               "\"no message 'nope' on List\"")
    # The MessageError is raised before any send argument runs.
    check_eval("(var side 0) (try ([1] ~ nope (set side 1)) catch _ side)",
               "0")
    # An expression callee that is a fn! is rejected as a CallKindError, also
    # before evaluating any send argument (design §3/§7).
    check_eval("(fn! q! [x] x) (var side 0) " &
               "(try ([1] ~ (do q!) (set side 1)) catch _ side)",
               "0")
    check_eval("(fn! q! [x] x) " &
               "(try ([1] ~ (do q!) 1) " &
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
               "(fn! capture! [] (caller_env ~ snapshot [\"x\"])) " &
               "(var saved (capture!)) (eval (quote (+ x 1)) ^in saved)",
               "42")
    check_eval("(var x 1) (var secret 9) " &
               "(fn! capture! [] (caller_env ~ snapshot [\"x\"])) " &
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
    check_eval("(fn! leak! [] ($cell caller_env)) " &
               "(try (leak!) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(var leaked nil) (fn! leak! [] (set leaked caller_env)) " &
               "(try (leak!) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(var leaked []) " &
               "(fn! leak! [] (leaked ~ push! caller_env)) " &
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
    check_eval("(import $serde [write SerdeError]) " &
               "(fn! leak! [] " &
               "  (try (write caller_env) catch (SerdeError) \"blocked\")) " &
               "(leak!)",
               "\"blocked\"")
    check_eval("(var ch ($channel ^capacity 1)) " &
               "(fn! leak! [] " &
               "  (try (ch ~ send caller_env) " &
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
    check "const char *entry_symbol;" in c
    check "static const GeneNativeFrameInfo gene_frame_add64 GENE_MAYBE_UNUSED = {\"add64\", GENE_NATIVE_FRAME_TYPED};" in c
    check "(void)&gene_frame_add64;" in c
    check "const GeneAotModuleFunction gene_aot_module[] GENE_MAYBE_UNUSED = {" in c
    check "{\"add64\", \"gene_native_add64\", \"\", \"I64\", 2, " &
      "&gene_frame_add64}," in c
    check "const size_t gene_aot_module_count GENE_MAYBE_UNUSED = 2;" in c
    check "int64_t gene_native_add64_twice(int64_t x, int64_t y)" in c
    check "return gene_native_add64(gene_native_add64(x, y), y);" in c
    check_eval("(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
               "(fn add64_twice [x : I64 y : I64] : I64 " &
               "  (add64 (add64 x y) y)) " &
               "(add64_twice 20 2)",
               "24")

  test "typed-native pointer parameters lower foreign fields to direct C loads":
    let chunk = compileSource(
      "(ffi/struct CTimespec " &
      "  ^fields [[tv_sec C/Long] [tv_nsec C/Long]]) " &
      "(type Timespec " &
      "  ^native {^abi CTimespec ^lifecycle manual ^mutable true}) " &
      "(fn seconds [t : Timespec] : I64 t/tv_sec)")
    let c = chunk.emitExperimentalC()
    check "int64_t gene_native_seconds(CTimespec * t)" in c
    check "return t->tv_sec;" in c
    check "gene_native_seconds(GeneValue" notin c

  test "a generated typed-native getter executes against a real C struct":
    let chunk = compileSource(
      "(ffi/struct CTimespec " &
      "  ^fields [[tv_sec C/Int64] [tv_nsec C/Int64]]) " &
      "(type Timespec ^native {^abi CTimespec ^lifecycle manual}) " &
      "(fn seconds [t : Timespec] : I64 t/tv_sec)")
    let harness = """
#include <stdio.h>
int main(void) {
  CTimespec value = {42, 7};
  printf("%lld\n", (long long)gene_native_seconds(&value));
  return 0;
}
"""
    checkCRuns(chunk.emitExperimentalC() & harness,
               "typed_native_direct_getter", "42")

  test "typed-native functions require a machine representation for every parameter":
    check_compile_error(
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(fn bad [node : Node callback] : I64 node/value)",
      "typed_native function bad cannot lower its body statically")

  test "typed-native metadata remains available inside lexical child units":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec ^native {^abi CTimespec ^lifecycle manual}) " &
      "(ns util (fn seconds [t : Timespec] : I64 t/tv_sec))")
    let c = chunk.emitExperimentalC()
    check "int64_t gene_native_ns0_seconds(CTimespec * t)" in c
    check "return t->tv_sec;" in c
    checkCCompiles(c, "typed_native_lexical_child")

  test "a namespace-local native Type is visible to forms that precede it":
    ## A child compiler inherits the module-root compile interface, so a
    ## namespace could not see its own declarations: this function compiled
    ## with no native representation and emitted no C at all, silently and
    ## with a zero exit. The same forward reference at module level worked.
    let chunk = compileSource(
      "(ns geom " &
      "  (fn value_of [node : Node] : I64 node/value) " &
      "  (ffi/struct CNode ^fields [[value C/Int64]]) " &
      "  (type Node ^native {^abi CNode ^lifecycle manual}))")
    let c = chunk.emitExperimentalC()
    check "int64_t gene_native_ns0_value_of(CNode * node)" in c
    check "return node->value;" in c
    checkCCompiles(c, "typed_native_ns_forward_ref")

  test "a nested namespace resolves its own native Type":
    let chunk = compileSource(
      "(ns outer (ns inner " &
      "  (fn deep_value [node : Node] : I64 node/value) " &
      "  (ffi/struct CNode ^fields [[value C/Int64]]) " &
      "  (type Node ^native {^abi CNode ^lifecycle manual})))")
    let c = chunk.emitExperimentalC()
    check "return node->value;" in c
    checkCCompiles(c, "typed_native_nested_ns")

  test "a private namespace still resolves its own native Type":
    ## A private namespace is absent from the parent interface, so this path
    ## builds one at the namespace's own path — identities stay qualified.
    let chunk = compileSource(
      "(ns geom ^private true " &
      "  (fn value_of [node : Node] : I64 node/value) " &
      "  (ffi/struct CNode ^fields [[value C/Int64]]) " &
      "  (type Node ^native {^abi CNode ^lifecycle manual}))")
    let c = chunk.emitExperimentalC()
    check "return node->value;" in c
    checkCCompiles(c, "typed_native_private_ns")

  test "typed-native mutable fields lower stores without dynamic helpers":
    let chunk = compileSource(
      "(ffi/struct CTimespec " &
      "  ^fields [[tv_sec C/Int64] [tv_nsec C/Int64]]) " &
      "(type Timespec " &
      "  ^native {^abi CTimespec ^lifecycle manual ^mutable true}) " &
      "(fn set_seconds [t : Timespec value : I64] : I64 " &
      "  (do (set! t/tv_sec value) value))")
    let c = chunk.emitExperimentalC()
    check "int64_t gene_native_set_seconds(CTimespec * t, int64_t value)" in c
    check "(void)(t->tv_sec = value);" in c
    check "return value;" in c

  test "typed-native stores reject narrowing ABI conversions":
    check_compile_error(
      "(ffi/struct CByte ^fields [[value C/UInt8]]) " &
      "(type BytePtr " &
      "  ^native {^abi CByte ^lifecycle manual ^mutable true}) " &
      "(fn set_byte [p : BytePtr value : I64] : I64 " &
      "  (set! p/value value))",
      "typed_native function set_byte cannot lower its body statically")

  test "typed-native bodies compute with arithmetic, comparison and if":
    ## The emitter always rendered these; analysis had no case for them, so a
    ## native-pointer function that computed anything at all was rejected.
    let chunk = compileSource(
      "(ffi/struct CPoint ^fields [[x C/Int64] [y C/Int64]]) " &
      "(type Point ^native {^abi CPoint ^lifecycle manual}) " &
      "(fn area [p : Point] : I64 (* p/x p/y)) " &
      "(fn shifted [p : Point] : I64 (+ p/x 1)) " &
      "(fn larger [p : Point] : I64 (if (< p/x p/y) p/y p/x)) " &
      "(fn nested [p : Point] : I64 (+ (* p/x p/x) (* p/y p/y)))")
    let c = chunk.emitExperimentalC()
    check "return (p->x * p->y);" in c
    check "return (p->x + 1);" in c
    check "return ((p->x < p->y) ? p->y : p->x);" in c
    check "return ((p->x * p->x) + (p->y * p->y));" in c
    let harness = """
#include <stdio.h>
int main(void) {
  CPoint p; p.x = 3; p.y = 4;
  printf("%lld %lld %lld %lld\n", (long long)gene_native_area(&p),
         (long long)gene_native_shifted(&p), (long long)gene_native_larger(&p),
         (long long)gene_native_nested(&p));
  return 0;
}
"""
    checkCRuns(c & harness, "typed_native_arithmetic", "12 4 4 25")

  test "typed-native if arms must share the result representation":
    ## A C ternary has one type and there is no boxing available to reconcile
    ## two, so a pointer arm cannot join a scalar one.
    check_compile_error(
      "(ffi/struct CPoint ^fields [[x C/Int64] [y C/Int64]]) " &
      "(type Point ^native {^abi CPoint ^lifecycle manual}) " &
      "(fn bad [p : Point] : I64 (if (< p/x p/y) p p/x))",
      "typed_native function bad cannot lower its body statically")

  test "typed-native paths reject operations that require runtime dispatch":
    check_compile_error(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^native {^abi CTimespec ^lifecycle manual ^mutable true}) " &
      "(fn bad [t : Timespec] : I64 (t ~ missing))",
      "typed_native function bad cannot lower its body statically")

  test "typed-native sends specialize a visible impl for a concrete receiver":
    let chunk = compileSource(
      "(protocol ReadValue (message read_value [] : I64)) " &
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(impl ReadValue for Node " &
      "  (message read_value [] : I64 self/value)) " &
      "(fn read [node : Node] : I64 (node ~ ReadValue:read_value))")
    let c = chunk.emitExperimentalC()
    check chunk.directProtocolCalls.len == 1
    check chunk.directProtocolCalls[0].messageName == "read_value"
    check chunk.directProtocolCalls[0].protocolExpr.print() == "ReadValue"
    check chunk.directProtocolCalls[0].receiverExpr.print() == "Node"
    check "int64_t gene_native_impl_0_read_value(CNode * self)" in c
    check "return self->value;" in c
    check "return gene_native_impl_0_read_value(node);" in c
    checkCCompiles(c, "typed_native_specialized_send")

  test "two slot-compiled chunks cannot silently share one scope":
    ## Each slot layout numbers its locals from zero, so a second such chunk
    ## in the same scope read the resident layout's slot 0: `join` resolved to
    ## whatever the first chunk bound, failing later as "value is not callable:
    ## vkInt". Refuse the layout collision instead of misbinding.
    let scope = newGlobalScope()
    discard run(compileSource("(var q 1)"), scope)
    var raised = false
    try:
      discard run(compileSource("(import $str [join]) (join [\"a\"] \",\")"),
                  scope)
    except CatchableError as e:
      raised = true
      check "cannot run a second slot-compiled chunk" in e.msg
    check raised

  test "name-bound chunks accumulate in one scope":
    ## The supported way to run several sources against one scope. Unlike
    ## compileEvalSource this keeps ambient import authority.
    let scope = newGlobalScope()
    discard run(compileSource("(var q 1)", useLocalSlots = false), scope)
    check run(compileSource("(import $str [join]) (join [\"a\" \"b\"] \",\")",
                            useLocalSlots = false), scope).strVal == "a,b"
    check run(compileSource("q", useLocalSlots = false), scope).intVal == 1

  test "Gene calls a natively compiled function through an AOT library":
    ## The §6.4 dynamic boundary, end to end: compile a function to C, build it
    ## as a shared library, load it, and call it from ordinary Gene code. The
    ## library resolves gene_ffi_* from this test binary's dynamic symbol
    ## table, which is why aot_runtime is imported above.
    let chunk = compileSource(
      "(fn triple ^native_entry {} [x : I64] : I64 (* x 3))")
    let c = chunk.emitExperimentalC()
    check "GeneStatus gene_entry_triple(" in c
    check "const GeneAotModuleFunction gene_aot_module[]" in c

    let sourcePath = getTempDir() / "gene_aot_roundtrip.c"
    const libExt = when defined(macosx): ".dylib"
                   elif defined(windows): ".dll"
                   else: ".so"
    let libPath = getTempDir() / ("libgene_aot_roundtrip" & libExt)
    writeFile(sourcePath, c)
    defer:
      if fileExists(sourcePath): removeFile(sourcePath)
      if fileExists(libPath): removeFile(libPath)
    let built = execCmdEx(
      quoteShell(getEnv("CC", "cc")) &
        " -std=c11 -O2 -DGENE_AOT_DYNAMIC_ENTRIES=1 -shared -fPIC " &
        (when defined(macosx): "-undefined dynamic_lookup " else: "") &
        quoteShell(sourcePath) & " -o " & quoteShell(libPath))
    checkpoint built.output
    check built.exitCode == 0
    if built.exitCode == 0:
      let scope = newGlobalScope()
      check run(compileSource(
        "(import $aot [load]) " &
        "(var native (load " & geneString(libPath) & ")) " &
        "(native/triple 14)"), scope).intVal == 42

  test "AOT ffi wrappers marshal strings, bools and sized integers":
    ## Generated ffi/fn wrappers share the entry signature, so `aot/load` binds
    ## them too and a foreign call goes through compiled marshalling code.
    ## Every integral C parameter narrows from Gene's 64-bit Int, so the range
    ## check is a correctness condition, not a nicety.
    let src =
      "(ffi/fn shout ^symbol \"shout\" [s : C/CStr] : C/Int) " &
      "(ffi/fn clamp_byte ^symbol \"clamp_byte\" [b : C/Int8] : C/Int8) " &
      "(ffi/fn flip ^symbol \"flip\" [b : C/Bool] : C/Bool) " &
      "(ffi/fn total ^symbol \"total\" [a : C/UInt32 b : C/Size] : C/Size)"
    let impl = """
#include <string.h>
int shout(const char *s) { return (int)strlen(s); }
int8_t clamp_byte(int8_t b) { return b; }
bool flip(bool b) { return !b; }
size_t total(uint32_t a, size_t b) { return (size_t)a + b; }
"""
    const libExt = when defined(macosx): ".dylib"
                   elif defined(windows): ".dll"
                   else: ".so"
    let sourcePath = getTempDir() / "gene_aot_marshal.c"
    let libPath = getTempDir() / ("libgene_aot_marshal" & libExt)
    writeFile(sourcePath, compileSource(src).emitExperimentalC() & impl)
    defer:
      if fileExists(sourcePath): removeFile(sourcePath)
      if fileExists(libPath): removeFile(libPath)
    let built = execCmdEx(
      quoteShell(getEnv("CC", "cc")) &
        " -std=c11 -O2 -DGENE_AOT_DYNAMIC_ENTRIES=1 -shared -fPIC " &
        (when defined(macosx): "-undefined dynamic_lookup " else: "") &
        quoteShell(sourcePath) & " -o " & quoteShell(libPath))
    checkpoint built.output
    check built.exitCode == 0
    if built.exitCode == 0:
      let prelude = "(import $aot [load]) " &
        "(var n (load " & geneString(libPath) & ")) "
      proc runAot(program: string): Value =
        run(compileSource(prelude & program), newGlobalScope())
      check runAot("(n/shout \"hello\")").intVal == 5
      check runAot("(n/clamp_byte 127)").intVal == 127
      check runAot("(n/flip false)").boolVal
      check runAot("(n/total 40 2)").intVal == 42

      # Narrowing must fail rather than truncate: 200 as int8 is -56.
      check_runtime_error(prelude & "(n/clamp_byte 200)",
                          "out of range: 200 does not fit -128..127")
      check_runtime_error(prelude & "(n/total -1 2)", "does not fit 0..")
      check_runtime_error(prelude & "(n/shout 42)", "expects Str")
      check_runtime_error(prelude & "(n/flip 1)", "expects Bool")

  test "a managed wrapper crosses the AOT boundary in both directions":
    ## §6.4 proper: native code hands back a managed wrapper, Gene passes it
    ## in again, and ownership is honoured. The library and the running module
    ## come from one `compileSource`, so the type identity baked into the
    ## generated C is the identity the runtime registers.
    let src =
      "(ffi/struct CPoint ^fields [[x C/Int64] [y C/Int64]]) " &
      "(type Point ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CPoint)} " &
      "  ^native {^abi CPoint ^lifecycle manual ^wrapper handle " &
      "           ^release \"point_free\" ^copy \"point_copy\"}) " &
      "(ffi/fn make_point ^symbol \"make_point\" [] : Point) " &
      "(fn make ^native_entry {^result transfer} [] : Point (make_point)) " &
      "(fn get_x ^native_entry {^p borrow} [p : Point] : I64 p/x) " &
      "(fn consume ^native_entry {^p transfer} [p : Point] : I64 p/x)"
    let chunk = compileSource(src)
    let impl = """
#include <stdlib.h>
CPoint *make_point(void) {
  CPoint *p = malloc(sizeof *p); p->x = 3; p->y = 4; return p;
}
CPoint *point_copy(const CPoint *src) {
  CPoint *p = malloc(sizeof *p); *p = *src; return p;
}
void point_free(CPoint *p) { free(p); }
"""
    const libExt = when defined(macosx): ".dylib"
                   elif defined(windows): ".dll"
                   else: ".so"
    let sourcePath = getTempDir() / "gene_aot_wrapper.c"
    let libPath = getTempDir() / ("libgene_aot_wrapper" & libExt)
    writeFile(sourcePath, chunk.emitExperimentalC() & impl)
    defer:
      if fileExists(sourcePath): removeFile(sourcePath)
      if fileExists(libPath): removeFile(libPath)
    let built = execCmdEx(
      quoteShell(getEnv("CC", "cc")) &
        " -std=c11 -O2 -DGENE_AOT_DYNAMIC_ENTRIES=1 -shared -fPIC " &
        (when defined(macosx): "-undefined dynamic_lookup " else: "") &
        quoteShell(sourcePath) & " -o " & quoteShell(libPath))
    checkpoint built.output
    check built.exitCode == 0
    if built.exitCode == 0:
      # Each program is one compilation unit: the module declarations (which
      # create Point and register its native identity), the library load, and
      # the calls. `compileSource` names every unit "<memory>", so the identity
      # baked into the library above is the identity registered here.
      let prelude = src & " (import $aot [load]) " &
        "(var native (load " & geneString(libPath) & ")) "
      proc runAot(program: string): Value =
        run(compileSource(prelude & program), newGlobalScope())

      # Native code allocated this and handed back a real managed wrapper.
      check runAot("(var p (native/make)) ($head p)").typeName == "Point"
      check runAot("(var p (native/make)) (native/get_x p)").intVal == 3

      # A look-alike may not carry a forged pointer into compiled code.
      check_runtime_error(prelude &
        "(type Impostor ^props {^handle Any}) " &
        "(native/get_x (Impostor ^handle 12345))",
        "expects a Point value")
      check_runtime_error(prelude & "(native/get_x nil)", "must not be nil")

      # Transfer moves ownership, so the wrapper is closed and cannot be
      # handed to native code a second time — no double free is reachable.
      check runAot("(var p (native/make)) (native/consume p)").intVal == 3
      check_runtime_error(prelude &
        "(var p (native/make)) (native/consume p) (native/get_x p)",
        "is closed")

  test "a protocol message may return a native pointer":
    ## A message declaration carries only a signature. Treating it as an
    ## executable typed-native function rejected it for having no lowerable
    ## body, so a protocol returning a native pointer could not be declared.
    let chunk = compileSource(
      "(ffi/struct CNode " &
      "  ^fields [[next (C/NullablePtr Node)] [value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(protocol Nav (message hop [] : Node?)) " &
      "(impl Nav for Node (message hop [] : Node? self/next)) " &
      "(fn step [node : Node] : Node? (node ~ Nav:hop))")
    let c = chunk.emitExperimentalC()
    check "CNode * gene_native_impl_0_hop(CNode * self)" in c
    check "return self->next;" in c
    check "return gene_native_impl_0_hop(node);" in c
    checkCCompiles(c, "typed_native_protocol_pointer_result")

  test "a bare typed-native send never resolves to a protocol impl":
    ## Bare is type-direct, qualified is protocol (docs/core.md §3.6.1). The
    ## interpreter answers "no message 'read_value' on Node" for this source,
    ## so the backend must not lower it to a direct impl call.
    check_compile_error(
      "(protocol ReadValue (message read_value [] : I64)) " &
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(impl ReadValue for Node " &
      "  (message read_value [] : I64 self/value)) " &
      "(fn read [node : Node] : I64 (node ~ read_value))",
      "typed_native function read cannot lower its body statically")

  test "a lexical binding shadows a protocol name during send lowering":
    check_compile_error(
      "(protocol ReadValue (message read_value [] : I64)) " &
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(impl ReadValue for Node " &
      "  (message read_value [] : I64 self/value)) " &
      "(fn read [node : Node ReadValue : Node] : I64 " &
      "  (node ~ ReadValue:read_value))",
      "typed_native function read cannot lower its body statically")

  test "an overlay impl anywhere in the unit blocks a direct send":
    ## docs/scoped-impls.md §7: a direct protocol call needs the winning
    ## unconditional canonical pair with no reachable overlay. Overlay-only
    ## impls are collected before compilation, so the check does not depend on
    ## where the overlay sits or whether it precedes the send — a per-chunk
    ## check made at the send missed both of the last two cases.
    let base =
      "(protocol ReadValue (message read_value [] : I64)) " &
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(impl ReadValue for Node " &
      "  (message read_value [] : I64 self/value)) "
    let send = "(fn read [node : Node] : I64 (node ~ ReadValue:read_value)) "
    let overlay = "(impl ReadValue for Node (message read_value [] : I64 0)) "
    let cannotLower = "typed_native function read cannot lower its body statically"

    # Conditional, same chunk.
    check_compile_error(base & "(if true " & overlay & ") " & send, cannotLower)
    # Inside a function body: a subchunk, invisible to a per-chunk scan.
    check_compile_error(base & "(fn install [] " & overlay & ") " & send,
                        cannotLower)
    # Declared after the send: not yet compiled when the send is analysed.
    check_compile_error(base & send & "(if true " & overlay & ")", cannotLower)

    # Control: with no overlay the canonical impl is still called directly.
    let chunk = compileSource(base & send)
    check "return gene_native_impl_0_read_value(node);" in
      chunk.emitExperimentalC()

  test "an unlowerable impl body fails emission instead of returning 0":
    ## Impl functions are emitted before ordinary module functions, so an impl
    ## calling an earlier typed-native helper passes analysis but has no
    ## emittable target. The old `"0"` fallback made this compile to
    ## `return 0;`, and for a pointer local to `T *x = 0;` followed by a field
    ## load — clean C that dereferences null.
    check_emit_c_error(
      "(protocol ReadValue (message read_value [] : I64)) " &
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(fn helper [node : Node] : I64 node/value) " &
      "(impl ReadValue for Node " &
      "  (message read_value [] : I64 (helper self))) " &
      "(fn read [node : Node] : I64 (node ~ ReadValue:read_value))",
      "typed_native function read_value: typed_native backend has no " &
      "lowering for (helper self)")

  test "native release and copy symbols must be C identifiers":
    ## `^release`/`^copy` are interpolated into generated C declarations
    ## verbatim, so an unchecked value injects arbitrary C into the build.
    check_compile_error(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual ^wrapper handle " &
      "           ^release \"ts_free\" " &
      "           ^copy \"evil(void); } int pwned(void) { return 1\"})",
      "^native ^copy must be a C identifier")

  test "an ffi symbol must be a C identifier":
    ## `cIdent` would otherwise rewrite this silently into a name that cannot
    ## link, turning a typo into a confusing link error.
    check_compile_error(
      "(ffi/fn sneaky ^symbol \"legit(void); } int injected(void) { return 1\" " &
      "  [x : C/Int64] : C/Int64)",
      "ffi/fn ^symbol must be a C identifier")

  test "typed-native functions call typed FFI symbols directly":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^native {^abi CTimespec ^lifecycle manual ^mutable true}) " &
      "(ffi/fn read_seconds ^symbol \"read_seconds\" " &
      "  [t : Timespec] : C/Long) " &
      "(fn seconds_via_call [t : Timespec] : I64 (read_seconds t))")
    let c = chunk.emitExperimentalC()
    check "extern long GENE_FFI_CDECL read_seconds(CTimespec * t);" in c
    check "return read_seconds(t);" in c
    check "gene_ffi_arg_ptr" notin c[c.find("gene_native_seconds_via_call") .. ^1]
    checkCCompiles(c, "typed_native_direct_ffi")

  test "an ffi/fn-bearing module links without the dynamic entry helpers":
    ## The dynamic entry wrapper is a non-static definition calling
    ## gene_ffi_* helpers no runtime defines, so before it was guarded its
    ## undefined calls sank any translation unit containing an ffi/fn — even
    ## though the typed path calls the foreign symbol directly and needs none
    ## of them. examples/native depends on this linking.
    let chunk = compileSource(
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(ffi/fn scale_node ^symbol \"scale_node\" [n : Node] : C/Int64) " &
      "(fn scaled [n : Node] : I64 (scale_node n))")
    let c = chunk.emitExperimentalC()
    check "#ifdef GENE_AOT_DYNAMIC_ENTRIES" in c
    check "GeneStatus gene_ffi_scale_node" in c
    let harness = """
#include <stdio.h>
int64_t scale_node(CNode *n) { return n->value * 2; }
int main(void) {
  CNode node;
  node.value = 21;
  printf("%lld\n", (long long)gene_native_scaled(&node));
  return 0;
}
"""
    checkCRuns(c & harness, "typed_native_ffi_standalone_link", "42")

  test "a lexical binding shadows a typed FFI symbol during lowering":
    check_compile_error(
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(ffi/fn read_node ^symbol \"foreign_read_node\" " &
      "  [node : Node] : C/Int64) " &
      "(fn shadowed [node : Node read_node : Node] : I64 " &
      "  (read_node node))",
      "typed_native function shadowed cannot lower its body statically")

  test "typed-native pointer locals stay unboxed":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^native {^abi CTimespec ^lifecycle manual}) " &
      "(ffi/fn choose_timespec ^symbol \"choose_timespec\" " &
      "  [t : Timespec] : Timespec) " &
      "(fn seconds_via_local [t : Timespec] : I64 " &
      "  (do " &
      "    (let selected : Timespec (choose_timespec t)) " &
      "    selected/tv_sec))")
    let c = chunk.emitExperimentalC()
    let start = c.find("gene_native_seconds_via_local")
    check start >= 0
    let generated = c[start .. ^1]
    check "CTimespec * selected = choose_timespec(t);" in generated
    check "return selected->tv_sec;" in generated
    check "GeneValue" notin generated[0 ..< generated.find("}")]
    checkCCompiles(c, "typed_native_pointer_local")

  test "typed-native pointer vars rebind without boxing":
    let chunk = compileSource(
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(fn value_after_replace [node : Node replacement : Node] : I64 " &
      "  (do " &
      "    (var selected : Node node) " &
      "    (set selected replacement) " &
      "    selected/value))")
    let c = chunk.emitExperimentalC()
    let start = c.find("gene_native_value_after_replace")
    check start >= 0
    let generated = c[start .. ^1]
    check "CNode * selected = node;" in generated
    check "selected = replacement;" in generated
    check "return selected->value;" in generated
    check "GeneValue" notin generated[0 ..< generated.find("}")]
    checkCCompiles(c, "typed_native_pointer_var")

  test "typed-native functions call other typed-native functions directly":
    let chunk = compileSource(
      "(ffi/struct CNode ^fields [[value C/Int64]]) " &
      "(type Node ^native {^abi CNode ^lifecycle manual}) " &
      "(fn identity_node [node : Node] : Node node) " &
      "(fn value_via_identity [node : Node] : I64 " &
      "  (do " &
      "    (let selected : Node (identity_node node)) " &
      "    selected/value))")
    let c = chunk.emitExperimentalC()
    let start = c.find("gene_native_value_via_identity")
    check start >= 0
    let generated = c[start .. ^1]
    check "CNode * selected = gene_native_identity_node(node);" in generated
    check "return selected->value;" in generated
    check "GeneValue" notin generated[0 ..< generated.find("}")]
    checkCCompiles(c, "typed_native_direct_function")

  test "typed-native pointer fields preserve nominal type and nullability":
    let chunk = compileSource(
      "(ffi/struct CNode " &
      "  ^fields [[next (C/NullablePtr Node)] [value C/Int64]]) " &
      "(type Node " &
      "  ^native {^abi CNode ^lifecycle manual ^mutable true}) " &
      "(fn next_node [node : Node] : Node? node/next) " &
      "(fn set_next [node : Node child : Node] : Node " &
      "  (do (set! node/next child) child))")
    let c = chunk.emitExperimentalC()
    check "CNode * gene_native_next_node(CNode * node)" in c
    check "return node->next;" in c
    check "(void)(node->next = child);" in c
    check "return child;" in c
    checkCCompiles(c, "typed_native_pointer_field")

  test "typed-native field stores preserve their result's nominal type":
    check_compile_error(
      "(ffi/struct CNode ^fields [[next (C/NullablePtr Node)]]) " &
      "(ffi/struct COther ^fields [[value C/Int64]]) " &
      "(type Node " &
      "  ^native {^abi CNode ^lifecycle manual ^mutable true}) " &
      "(type Other ^native {^abi COther ^lifecycle manual}) " &
      "(fn lie [node : Node child : Node] : Other " &
      "  (set! node/next child))",
      "typed_native function lie cannot lower its body statically")

  test "an explicit native entry borrows a managed wrapper for the call":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual " &
      "           ^wrapper handle}) " &
      "(fn seconds ^native_entry {^t borrow} " &
      "  [t : Timespec] : I64 t/tv_sec)")
    let c = chunk.emitExperimentalC()
    check "GeneStatus gene_entry_seconds(" in c
    check "gene_typed_native_arg_borrow(ctx, call, 0, \"t\", " &
      "\"<memory>::Timespec\", \"<memory>::CTimespec\", \"handle\", " &
      "false, &t_raw)" in c
    check "CTimespec * t = NULL;" in c
    check "t = (CTimespec *)t_raw;" in c
    check "int64_t native_result = gene_native_seconds(t);" in c
    check "return gene_ffi_result_int64(ctx, native_result, result);" in c
    check "{\"seconds\", \"gene_native_seconds\", \"gene_entry_seconds\", " &
      "\"I64\", 1, &gene_frame_seconds}," in c
    checkCCompiles(c, "typed_native_borrow_entry")

  test "an explicit native entry transfers a wrapper pointer and result":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual " &
      "           ^wrapper handle ^release \"timespec_free\"}) " &
      "(fn handoff ^native_entry {^t transfer ^result transfer} " &
      "  [t : Timespec] : Timespec t)")
    let c = chunk.emitExperimentalC()
    check "gene_typed_native_arg_transfer(ctx, call, 0, \"t\", " &
      "\"<memory>::Timespec\", \"<memory>::CTimespec\", \"handle\", " &
      "false, &t_raw)" in c
    check "static void gene_entry_handoff_result_release(void *value)" in c
    check "timespec_free((CTimespec *)value);" in c
    check "CTimespec * native_result = gene_native_handoff(t);" in c
    check "gene_typed_native_result_transfer(ctx, (void *)native_result, " &
      "\"<memory>::Timespec\", \"<memory>::CTimespec\", \"handle\", " &
      "false, gene_entry_handoff_result_release, result)" in c
    checkCCompiles(c, "typed_native_transfer_entry")

  test "native entry argument acquisition rolls back before returning an error":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Int64]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual ^wrapper handle " &
      "           ^release \"timespec_free\"}) " &
      "(fn consume ^native_entry {^t transfer} " &
      "  [t : Timespec count : I64] : I64 t/tv_sec)")
    let c = chunk.emitExperimentalC()
    check "goto gene_entry_consume_arg_error;" in c
    check "gene_typed_native_arg_restore(ctx, call, 0, t_raw);" in c
    check "gene_entry_consume_arg_error:" in c
    checkCCompiles(c, "typed_native_argument_rollback")

  test "an explicit native entry copies a wrapper pointer before reboxing":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual ^wrapper handle " &
      "           ^release \"timespec_free\" ^copy \"timespec_copy\"}) " &
      "(fn duplicate ^native_entry {^t copy ^result transfer} " &
      "  [t : Timespec] : Timespec t)")
    let c = chunk.emitExperimentalC()
    check "static void *gene_entry_duplicate_t_copy(const void *value)" in c
    check "timespec_copy((const CTimespec *)value)" in c
    check "gene_typed_native_arg_copy(ctx, call, 0, \"t\", " &
      "\"<memory>::Timespec\", \"<memory>::CTimespec\", \"handle\", " &
      "false, gene_entry_duplicate_t_copy, &t_raw)" in c
    check "gene_typed_native_result_transfer(ctx, (void *)native_result" in c
    checkCCompiles(c, "typed_native_copy_entry")

  test "an explicit native entry copies a borrowed native result":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual ^wrapper handle " &
      "           ^release \"timespec_free\" ^copy \"timespec_copy\"}) " &
      "(fn copied_result ^native_entry {^t borrow ^result copy} " &
      "  [t : Timespec] : Timespec t)")
    let c = chunk.emitExperimentalC()
    check "static void *gene_entry_copied_result_result_copy(" in c
    check "static void gene_entry_copied_result_result_release(" in c
    check "gene_typed_native_result_copy(ctx, (void *)native_result, " &
      "\"<memory>::Timespec\", \"<memory>::CTimespec\", \"handle\", " &
      "false, gene_entry_copied_result_result_copy, " &
      "gene_entry_copied_result_result_release, result)" in c
    checkCCompiles(c, "typed_native_copied_result")

  test "a native entry cannot expose a borrowed pointer result":
    check_compile_error(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual ^wrapper handle}) " &
      "(fn dangling ^native_entry {^t borrow ^result borrow} " &
      "  [t : Timespec] : Timespec t)",
      "function dangling ^native_entry cannot borrow a native-pointer result")

  test "a native entry cannot transfer a result derived from a borrowed parameter":
    check_compile_error(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual ^wrapper handle " &
      "           ^release \"timespec_free\"}) " &
      "(fn double_owner ^native_entry {^t borrow ^result transfer} " &
      "  [t : Timespec] : Timespec t)",
      "function double_owner ^native_entry cannot transfer a result " &
      "derived from borrowed parameter t")

  test "a native entry executes null and copied wrapper boundaries":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^repr native_wrapper " &
      "  ^props {^handle (C/OwnedPtr CTimespec)} " &
      "  ^native {^abi CTimespec ^lifecycle manual ^wrapper handle " &
      "           ^release \"timespec_free\" ^copy \"timespec_copy\"}) " &
      "(fn round_trip ^native_entry {^t borrow ^result copy} " &
      "  [t : Timespec?] : Timespec? t)",
      sourceName = "adapter.gene")
    let harness = """
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct GeneContext { int unused; };
struct GeneValue {
  int kind;
  void *pointer;
  bool closed;
  const char *type_identity;
  const char *abi_identity;
  GeneTypedNativeReleaseFn release;
};
struct GeneCall { size_t len; GeneValue *args; };

static int copy_calls;
static int release_calls;

CTimespec *timespec_copy(const CTimespec *value) {
  ++copy_calls;
  CTimespec *result = malloc(sizeof(*result));
  if (result != NULL) *result = *value;
  return result;
}

void timespec_free(CTimespec *value) {
  ++release_calls;
  free(value);
}

GeneStatus gene_ffi_check_arity(GeneContext *ctx, const GeneCall *call,
                                size_t expected) {
  (void)ctx;
  return call != NULL && call->len == expected ? GENE_OK : GENE_ERROR;
}

GeneStatus gene_typed_native_arg_borrow(
    GeneContext *ctx, const GeneCall *call, size_t index, const char *name,
    const char *type_identity, const char *abi_identity,
    const char *handle_field, bool nullable, void **out) {
  (void)ctx;
  (void)name;
  if (call == NULL || index >= call->len || out == NULL) return GENE_ERROR;
  GeneValue *value = &call->args[index];
  if (value->kind == 0) {
    if (!nullable) return GENE_ERROR;
    *out = NULL;
    return GENE_OK;
  }
  if (value->kind != 1 || value->closed ||
      strcmp(value->type_identity, type_identity) != 0 ||
      strcmp(value->abi_identity, abi_identity) != 0 ||
      strcmp(handle_field, "handle") != 0 ||
      (value->pointer == NULL && !nullable)) return GENE_ERROR;
  *out = value->pointer;
  return GENE_OK;
}

GeneStatus gene_typed_native_result_copy(
    GeneContext *ctx, const void *value, const char *type_identity,
    const char *abi_identity, const char *handle_field, bool nullable,
    GeneTypedNativeCopyFn copy, GeneTypedNativeReleaseFn release,
    GeneValue *out) {
  (void)ctx;
  if (out == NULL || strcmp(handle_field, "handle") != 0) return GENE_ERROR;
  if (value == NULL) {
    if (!nullable) return GENE_ERROR;
    *out = (GeneValue){0};
    return GENE_OK;
  }
  void *owned = copy(value);
  if (owned == NULL) return GENE_ERROR;
  *out = (GeneValue){1, owned, false, type_identity, abi_identity, release};
  return GENE_OK;
}

int main(void) {
  GeneContext ctx = {0};
  GeneValue arg = {0};
  GeneCall call = {1, &arg};
  GeneValue result = {0};

  if (gene_entry_round_trip(&ctx, &call, &result) != GENE_OK ||
      result.kind != 0 || copy_calls != 0) return 1;

  CTimespec original = {42};
  arg = (GeneValue){1, &original, false,
                    "adapter.gene::Timespec",
                    "adapter.gene::CTimespec", NULL};
  if (gene_entry_round_trip(&ctx, &call, &result) != GENE_OK ||
      result.kind != 1 || result.pointer == &original ||
      ((CTimespec *)result.pointer)->tv_sec != 42 || copy_calls != 1)
    return 2;
  result.release(result.pointer);
  if (release_calls != 1) return 3;
  puts("nil->null->nil; copy->wrapper");
  return 0;
}
"""
    checkCRuns(chunk.emitExperimentalC() & harness,
               "typed_native_adapter_runtime",
               "nil->null->nil; copy->wrapper",
               dynamicEntries = true)

  test "typed-native FFI calls reject narrowing scalar arguments":
    check_compile_error(
      "(ffi/struct CUnit ^fields [[value C/Int64]]) " &
      "(type UnitPtr ^native {^abi CUnit ^lifecycle manual}) " &
      "(ffi/fn take_byte ^symbol \"take_byte\" " &
      "  [value : C/UInt8] : C/Int64) " &
      "(fn call_take_byte [p : UnitPtr value : I64] : I64 " &
      "  (take_byte value))",
      "typed_native function call_take_byte cannot lower its body statically")

  test "typed-native scalar loads reject values wider than I64":
    check_compile_error(
      "(ffi/struct CCount ^fields [[value C/UInt64]]) " &
      "(type CountPtr ^native {^abi CCount ^lifecycle manual}) " &
      "(fn count [p : CountPtr] : I64 p/value)",
      "typed_native function count cannot lower its body statically")

  test "nullable typed-native pointers stay unboxed and guard field loads":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec " &
      "  ^native {^abi CTimespec ^lifecycle manual ^mutable false}) " &
      "(fn maybe_seconds [t : Timespec?] : I64 t/tv_sec)")
    let c = chunk.emitExperimentalC()
    check "int64_t gene_native_maybe_seconds(CTimespec * t)" in c
    check "return (t != NULL ? t->tv_sec : " &
      "gene_typed_native_null_i64(\"Timespec\", \"tv_sec\"));" in c

  test "nullable typed-native pointers cannot flow into non-null FFI parameters":
    check_compile_error(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Long]]) " &
      "(type Timespec ^native {^abi CTimespec ^lifecycle manual}) " &
      "(ffi/fn read_seconds ^symbol \"read_seconds\" " &
      "  [t : Timespec] : C/Long) " &
      "(fn maybe_seconds [t : Timespec?] : I64 (read_seconds t))",
      "typed_native function maybe_seconds cannot lower its body statically")

  test "nullable typed-native stores guard before assigning":
    let chunk = compileSource(
      "(ffi/struct CTimespec ^fields [[tv_sec C/Int64]]) " &
      "(type Timespec " &
      "  ^native {^abi CTimespec ^lifecycle manual ^mutable true}) " &
      "(fn maybe_set [t : Timespec? value : I64] : I64 " &
      "  (set! t/tv_sec value))")
    let c = chunk.emitExperimentalC()
    check "t != NULL ? (t->tv_sec = value)" in c
    checkCCompiles(c, "typed_native_nullable_store")

  test "nullable typed-native bases guard pointer-valued fields with a pointer trap":
    let chunk = compileSource(
      "(ffi/struct CNode ^fields [[next (C/NullablePtr Node)]]) " &
      "(type Node " &
      "  ^native {^abi CNode ^lifecycle manual ^mutable true}) " &
      "(fn maybe_next [node : Node?] : Node? node/next) " &
      "(fn maybe_set_next [node : Node? child : Node] : Node " &
      "  (set! node/next child))")
    let c = chunk.emitExperimentalC()
    check "node != NULL ? node->next : " &
      "gene_typed_native_null_ptr(\"Node\", \"next\")" in c
    check "node != NULL ? (node->next = child) : " &
      "gene_typed_native_null_ptr(\"Node\", \"next\")" in c
    checkCCompiles(c, "typed_native_nullable_pointer_field")

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
    check "const GeneFfiFnInfo gene_ffi_fns[] GENE_MAYBE_UNUSED = {" in c
    check "{\"strlen\", \"libc\", false, \"strlen\", \"C\", \"cdecl\", " &
      "\"gene_ffi_strlen\", \"\", 1, \"C/Size\"}," in c
    check "const size_t gene_ffi_fns_count GENE_MAYBE_UNUSED = 1;" in c
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
    check "const size_t gene_ffi_fns_count GENE_MAYBE_UNUSED = 6;" in c
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
    check_eval("[($chars \"Aé\") ($bytes \"Aé\")]",
               "[['A' 'é'] [65 195 169]]")

  test "graphemes expose combining scalar clusters":
    let s = "e\u0301x"
    check_eval("($graphemes \"" & s & "\")", "[\"e\u0301\" \"x\"]")

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
    check_eval("[(Set 1 2 1) ($set_has? (Set \"a\" \"b\") \"b\")]",
               "[(Set 1 2) true]")
    check_eval("(try (Set [1]) catch (TypeError ^expected e) e)",
               "\"HashStable\"")

  test "general maps evaluate any hash-stable keys":
    check_eval("(var k \"a\") [({{k : (+ 1 2)}} ~ get \"a\") " &
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
               "[m/text m/groups (m/named ~ get \"word\") m/start m/end]",
               "[\"ab-12\" #[\"ab\" \"12\"] \"ab\" 0 5]")
    check_eval("(var xs ($into (#\"\\d+\" ~ find_all \"a12b3\") [])) " &
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
    check_eval("[(== ($hash #[1 2]) ($hash ($freeze [1 2]))) " &
               " (== ($hash (quote #(x @line 1 ^a 2))) " &
               "    ($hash (quote #(x @line 99 ^a 2))))]",
               "[true true]")
    check_eval("(try ($hash [1 2]) catch {^message m} m)",
               "\"hash expects a hash-stable value\"")
    check_eval("(try ($hash #[($cell 1)]) catch {^message m} m)",
               "\"hash expects a hash-stable value\"")

  test "freeze helpers make mutability explicit":
    check_eval("[($freeze_shallow [1 [2]]) " &
               " ($freeze [1 {^a [2]}]) " &
               " ($thaw ($freeze [1 {^a [2]}]))]",
               "[#[1 [2]] #[1 #{^a #[2]}] [1 {^a [2]}]]")
    check_eval("(try ($freeze [($cell 1)]) catch {^message m} m)",
               "\"freeze cannot freeze Cell\"")

  test "deep freeze traverses node metadata":
    let frozen = run(compileSource("($freeze `(x @info {^items [1]}))"),
                     newGlobalScope())
    check frozen.meta["info"].isImmutable
    check frozen.meta["info"].mapEntries["items"].isImmutable

  test "Send validation traverses node metadata":
    expect GeneError:
      discard run(compileSource(
        "(var n ($freeze_shallow `(x @state %($cell 1)))) " &
        "(var ch ($channel ^capacity 1)) (ch ~ send n)"),
        newGlobalScope())

suite "spec — numeric boundaries from design":
  test "Int has mathematical integer semantics":
    check_eval("[(+ 9223372036854775807 1) " &
               " (* 100000000000000000000 100000000000000000000) " &
               " (< 9223372036854775808 9223372036854775809)]",
               "[9223372036854775808 " &
               "10000000000000000000000000000000000000000 " &
               "true]")

  test "// is truncated remainder; sign follows the dividend":
    check_eval("[(// 17 5) (// -17 5) (// 17 -5) (// 10 2) (// 5.5 2.0)]",
               "[2 -2 2 0 1.5]")
    expect GeneError:
      discard run(compileSource("(// 1 0)"), newGlobalScope())

  test "// is an operator, never the empty selector":
    # A selector needs at least one segment, so `//` reads back as the operator
    # symbol; an interior `//` in a path still collapses (design §7.4).
    check_eval("(quote //)", "//")
    check_eval("[(quote a//b) (quote /a/b)]", "[(path a b) (select a b)]")

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
    check_eval("(var b ($buffer C/UInt8 [1 2])) " &
               "[(b ~ len) (b ~ get 1) " &
               "(b ~ set! 0 9) (b ~ to_list)]",
               "[2 2 9 [9 2]]")
    check_eval("((fn [b : (Buffer C/UInt8)] true) " &
               "($buffer C/UInt8 [1 2]))",
               "true")
    check_eval("((fn [b : (Buffer Int)] true) ($buffer [1 2]))", "true")
    # A Gene scalar type names an element type too, not just a C ABI type.
    # This reaches the boundary as a resolved `vkType` value rather than a
    # name, so it exercises the built-in arm of `isInstanceOfType`.
    check_eval("(var b ($buffer Int [1 2 3])) [(b ~ len) (b ~ to_list)]",
               "[3 [1 2 3]]")
    check_eval("(var b ($buffer Str [\"a\"])) (b ~ to_list)", "[\"a\"]")
    expect GeneError:
      discard run(compileSource("($buffer Int [\"a\"])"), newGlobalScope())
    expect GeneError:
      discard run(compileSource("($buffer C/UInt8 [256])"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("((fn [b : (Buffer C/UInt8)] b) " &
                                "($buffer C/Int32 [1]))"),
                  newGlobalScope())

  test "Device buffers are opaque native-compute handles":
    check_eval("(var b ($device/buffer $device/Compute \"mock\" C/Int64 4)) " &
               "[($device/Buffer/backend b) " &
               " ($device/Buffer/elem_type b) " &
               " ($device/Buffer/len b) " &
               " ((fn [buf : device/Buffer] ($device/Buffer/len buf)) b) " &
               " ((fn [buf : (device/Buffer C/Int64)] " &
               "    ($device/Buffer/elem_type buf)) b) " &
               " b]",
               "[\"mock\" C/Int64 4 4 C/Int64 (device-buffer mock C/Int64 4)]")
    expect GeneError:
      discard run(compileSource("($device/buffer nil \"mock\" C/Int64 1)"),
                  newGlobalScope())
    check_eval("(var b ($device/buffer $device/Compute \"mock\" C/Int64 4)) " &
               "(try ((fn [buf : (device/Buffer F64)] buf) b) " &
               "catch (TypeError ^expected e) e)",
               "\"(device/Buffer F64)\"")

  test "FFI runtime loading requires explicit authority":
    check_eval("$ffi/Load", "(ffi_type Load)")
    let scope = newGlobalScope()
    scope.define("native", newFfiLoadCapability())
    check run(compileSource("((fn [cap : ffi/Load] cap) native)"),
              scope).print() == "(ffi-load)"
    expect GeneError:
      discard run(compileSource("((fn [cap : ffi/Load] cap) nil)"), scope)
    expect GeneError:
      discard run(compileSource("($ffi/open nil \"libmissing-gene-new\")"),
                  scope)
    expect GeneError:
      discard run(compileSource("($ffi/open native \"libmissing-gene-new\")"),
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
  test "new is a keyword that invokes the type constructor":
    check_eval("(type Point ^props {^x Int} " &
               "  (ctor [x : Int] (self ~ set_prop! `x x))) " &
               "(let new (fn [_] \"shadowed\")) " &
               "(var point (new Point 42)) point/x",
               "42")

  test "ctor mutates pre-created self and returns the validated instance":
    check_eval("(type Point ^props {^x F64 ^y F64} " &
               "  (ctor [x : F64, y : F64] " &
               "    (self ~ set_prop! `x x) " &
               "    (self ~ set_prop! `y y))) " &
               "(var p (new Point 10.0 20.0)) [p/x p/y]",
               "[10.0 20.0]")

  test "ctor uses function-style argument matching with named defaults":
    check_eval("(type User ^props {^name Str ^age Int ^active Bool} " &
               "  (ctor [name : Str, ^age : Int = 0, ^active : Bool = true] " &
               "    (self ~ set_prop! `name name) " &
               "    (self ~ set_prop! `age age) " &
               "    (self ~ set_prop! `active active))) " &
               "(var u (new User \"Ada\" ^age 37)) [u/name u/age u/active]",
               "[\"Ada\" 37 true]")

  test "ctor declares checked errors":
    check_eval("(type ValidationError ^props {^message Str} ^impl [Error]) " &
               "(impl Error for ValidationError) " &
               "(type Port ^props {^value Int} " &
               "  (ctor [n : Int] ^errors [ValidationError] " &
               "    (if (&& (>= n 0) (<= n 65535)) " &
               "      (self ~ set_prop! `value n) " &
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
               "  (ctor [] (self ~ set_prop! `a 1) " &
               "           (self ~ set_prop! `zzz 9))) " &
               "(try (new Sneaky) catch _ \"unknown field\")",
               "\"unknown field\"")
    check_eval("(type Typed ^props {^a Int} " &
               "  (ctor [] (self ~ set_prop! `a \"nope\"))) " &
               "(try (new Typed) catch (TypeError ^where w) w)",
               "\"field 'a' for Typed\"")

  test "(T ...) is direct data construction and never runs the ctor":
    check_eval("(type Port2 ^props {^value Int} " &
               "  (ctor [n : Int] (self ~ set_prop! `value (* n 2)))) " &
               "(var direct (Port2 ^value 8080)) " &
               "(var made (new Port2 8080)) " &
               "[direct/value made/value]",
               "[8080 16160]")

  test "direct construction still schema-validates on a ctor type":
    check_eval("(type Port3 ^props {^value Int} " &
               "  (ctor [n : Int] (self ~ set_prop! `value n))) " &
               "(try (Port3 ^value \"nope\") catch (TypeError ^where w) w)",
               "\"field 'value' for Port3\"")
    check_eval("(type Port4 ^props {^value Int} " &
               "  (ctor [n : Int] (self ~ set_prop! `value n))) " &
               "(try (Port4) catch _ \"missing field\")",
               "\"missing field\"")

  test "typed instance property writes preserve field types":
    check_eval("(type Counter ^props {^n Int}) " &
               "(var counter (Counter ^n 1)) " &
               "[(try (counter ~ set_prop! `n \"bad\") " &
               "  catch (TypeError ^where where) where) counter/n]",
               "[\"field 'n' for Counter\" 1]")
    check_eval("(type Counter ^props {^n Int}) " &
               "(var counter (Counter ^n 1)) " &
               "[(try (counter ~ set_prop! `n void) " &
               "  catch (Error ^message message) message) counter/n]",
               "[\"cannot remove required field 'n' from Counter\" 1]")
    check_eval("(type MaybeCounter ^props {^n Int?}) " &
               "(var counter (MaybeCounter ^n 1)) " &
               "(counter ~ set_prop! `n void) (counter ~ props)",
               "{}")

  test "functional updates preserve typed instance schemas":
    check_eval("(type Counter ^props {^n Int}) " &
               "(var counter (Counter ^n 1)) " &
               "[(try ($assoc_in counter /n \"bad\") " &
               "  catch (TypeError ^where where) where) " &
               " (try ($update_in counter /n (fn [_] \"bad\")) " &
               "  catch (TypeError ^where where) where) counter/n]",
               "[\"field 'n' for Counter\" \"field 'n' for Counter\" 1]")
    check_eval("(type Counter ^props {^n Int}) " &
               "(try ($assoc_in (quote (data ^n \"bad\")) /head Counter) " &
               " catch (TypeError ^where where) where)",
               "\"field 'n' for Counter\"")

  test "typed instance body mutation preserves the declared body schema":
    check_eval("(type NamedOnly ^props {^n Int}) " &
               "(var value (NamedOnly ^n 1)) " &
               "[(try (value ~ set_body! [\"undeclared\"]) " &
               "  catch (Error ^message message) message) " &
               " (try (value ~ push_body! \"undeclared\") " &
               "  catch (Error ^message message) message) value]",
               "[\"NamedOnly expects 0 body item(s), got 1\" " &
               "\"NamedOnly expects 0 body item(s), got 1\" " &
               "((type NamedOnly) ^n 1)]")
    check_eval("(type Pair ^body [Int Int]) (var pair (Pair 1 2)) " &
               "[(try (pair ~ set_body! [1 \"bad\"]) " &
               "  catch (TypeError ^where where) where) pair]",
               "[\"body field 1 for Pair\" ((type Pair) 1 2)]")

  test "the immutable node reader preserves typed-instance immutability":
    check_eval("(type Counter ^props {^n Int}) " &
               "(var counter #(Counter ^n 1)) " &
               "[(try (counter ~ set_prop! `n 2) " &
               "  catch (Error ^message message) message) counter]",
               "[\"cannot mutate immutable Node\" #((type Counter) ^n 1)]")

  test "construct_type validates a runtime map against one real type schema":
    check_eval("(type Request ^props {^name Str ^count Int?}) " &
               "(var request_type Request) " &
               "($construct_type request_type {^name \"build\" ^count 2})",
               "((type Request) ^name \"build\" ^count 2)")
    check_eval("(type Request ^props {^name Str}) " &
               "(try ($construct_type Request {^name 7}) " &
               " catch (TypeError ^where w) w)",
               "\"field 'name' for Request\"")

  test "types reflect their closed property schema as Gene data":
    check_eval("(type Request ^props {^name Str ^count Int?}) " &
               "(var f (Request ~ fields)) " &
               "[(Request ~ name) f/0/name f/0/optional f/0/type " &
               " f/1/name f/1/optional f/1/type]",
               "[\"Request\" \"name\" false Str \"count\" true Int?]")

  test "new fails when the type hierarchy has no ctor":
    check_eval("(type Plain ^props {^name Str ^age Int}) " &
               "(try (new Plain ^name \"Ada\" ^age 37) " &
               " catch (Error ^message message) message)",
               "\"type Plain has no constructor\"")
    check_eval("(try (new 5) catch _ \"not a type\")",
               "\"not a type\"")

  test "child ctor covers inherited schema; parent ctor is not chained":
    check_eval("(type Animal ^props {^name Str}) " &
               "(type Dog ^is Animal ^props {^breed Str} " &
               "  (ctor [name : Str, breed : Str] " &
               "    (self ~ set_prop! `name name) " &
               "    (self ~ set_prop! `breed breed))) " &
               "(var d (new Dog \"Rex\" \"Lab\")) [d/name d/breed]",
               "[\"Rex\" \"Lab\"]")

  test "new inherits the nearest ancestor ctor":
    check_eval("(type Animal ^props {^name Str} " &
               "  (ctor [name : Str] (self ~ set_prop! `name name))) " &
               "(type Dog ^is Animal) " &
               "(var dog (new Dog \"Rex\")) dog",
               "((type Dog) ^name \"Rex\")")

  test "ctor fills body fields through mutable node APIs":
    check_eval("(type Pair ^body [Int Int] " &
               "  (ctor [a : Int, b : Int] " &
               "    (self ~ push_body! a) " &
               "    (self ~ push_body! b))) " &
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
               "    (self ~ set_prop! `x 1))) " &
               "[(try (new T) catch _ \"blocked\") leaked]",
               "[\"blocked\" nil]")
    check_eval("(var box ($cell nil)) " &
               "(type T ^props {^x Int} " &
               "  (ctor [] (box ~ set self) " &
               "    (self ~ set_prop! `x 1))) " &
               "[(try (new T) catch _ \"blocked\") (box ~ get)]",
               "[\"blocked\" nil]")
    check_eval("(type T ^props {^x Int} " &
               "  (ctor [] [self] (self ~ set_prop! `x 1))) " &
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
               "    (self ~ set_prop! `x 1))) " &
               "[(try (new T) catch _ \"blocked\") leaked]",
               "[\"blocked\" nil]")
    check_eval("(type T ^props {^x Int} " &
               "  (message inspect [self] self/x) " &
               "  (ctor [] (self ~ inspect) " &
               "    (self ~ set_prop! `x 1))) " &
               "(try (new T) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(type T ^props {^x Int} " &
               "  (ctor [] (spawn self) " &
               "    (self ~ set_prop! `x 1))) " &
               "(try (new T) catch _ \"blocked\")",
               "\"blocked\"")
    check_eval("(var ch ($channel ^capacity 1)) " &
               "(type T ^props {^x Int} ^impl [Send] " &
               "  (ctor [] (ch ~ send self) " &
               "    (self ~ set_prop! `x 1))) " &
               "(impl Send for T) " &
               "(try (new T) catch _ \"blocked\")",
               "\"blocked\"")

  test "successful construction clears the publication guard":
    check_eval("(type T ^props {^x Int} ^impl [Send] " &
               "  (ctor [] (self ~ set_prop! `x 1))) " &
               "(impl Send for T) " &
               "(var ch ($channel ^capacity 1)) (var value (new T)) " &
               "(ch ~ send value) " &
               "(var received (ch ~ recv)) received/x",
               "1")

  test "failed construction unwinds ensure cleanup":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) (var cleaned ($cell false)) " &
               "(type T ^props {^x Int} " &
               "  (ctor [] " &
               "    (try (fail (Boom ^message \"bad\")) " &
               "      ensure (cleaned ~ set true)))) " &
               "(try (new T) catch (Boom) nil) (cleaned ~ get)",
               "true")

suite "spec — native wrapper types (design §16.6)":
  test "^repr native_wrapper marks the type and admits only ctor construction":
    check_eval("(type Conn ^repr native_wrapper ^props {^handle Str} " &
               "  (ctor [h : Str] (set! self/handle h))) " &
               "(var c (new Conn \"H\")) [c/handle ($head c)]",
               "[\"H\" (type Conn)]")
    check_eval("(type Conn ^repr native_wrapper ^props {^handle Str} " &
               "  (ctor [h : Str] (set! self/handle h))) " &
               "(try (Conn ^handle \"junk\") catch (Error ^message m) m)",
               "\"direct construction cannot construct Conn: it is a native " &
               "wrapper; construct it with (new Conn ...)\"")

  test "every other construction path rejects a native wrapper head":
    # Each of these would otherwise mint a value that passes the `Conn`
    # nominal boundary while carrying no native payload.
    check_eval("(type Conn ^repr native_wrapper ^props {^handle Str} " &
               "  (ctor [h : Str] (set! self/handle h))) " &
               "[(try ($construct_type Conn {^handle \"x\"}) catch _ \"no\") " &
               " (try `(%Conn ^handle \"x\") catch _ \"no\") " &
               " (try ($assoc_in (quote (data ^handle \"x\")) /head Conn) " &
               "  catch _ \"no\")]",
               "[\"no\" \"no\" \"no\"]")

  test "wrapper fields are initializer-only after construction":
    check_eval("(type Conn ^repr native_wrapper ^props {^handle Str} " &
               "  (ctor [h : Str] (set! self/handle h))) " &
               "(var c (new Conn \"H\")) " &
               "[(try (set! c/handle \"junk\") catch (Error ^message m) m) " &
               " (try (c ~ set_prop! `handle \"junk\") catch _ \"no\") " &
               " (try ($assoc_in c /handle \"junk\") catch _ \"no\") " &
               " c/handle]",
               "[\"cannot set field 'handle' on Conn: native wrapper fields " &
               "are initializer-only\" \"no\" \"no\" \"H\"]")

  test "the wrapper rule is inherited through ^is":
    # A Gene-side subtype may add messages and impls; it must not reopen
    # construction on the parent's native payload.
    check_eval("(type Conn ^repr native_wrapper ^props {^handle Str} " &
               "  (ctor [h : Str] (set! self/handle h))) " &
               "(type Tagged ^is Conn " &
               "  (message tag [self] : Str self/handle)) " &
               "[(try (Tagged ^handle \"x\") catch _ \"no\") " &
               " ((new Tagged \"H\") ~ tag)]",
               "[\"no\" \"H\"]")

  test "^repr accepts only the native_wrapper marker":
    expect GeneError:
      discard compileSource("(type T ^repr packed ^props {^n Int})")
    expect GeneError:
      discard compileSource("(type T ^sealed true ^props {^n Int})")

  test "in-tree native surfaces are wrapper types":
    check_eval("(try (SqliteDb) catch (Error ^message m) m)",
               "\"direct construction cannot construct SqliteDb: it is a " &
               "native wrapper; construct it with (new SqliteDb ...)\"")
    check_eval("(import $db/sqlite [open Db]) (var c (open \":memory:\")) " &
               "[(try (set! c/handle \"junk\") catch _ \"no\") " &
               " (try ($assoc_in c /backend \"junk\") catch _ \"no\") " &
               " c/backend]",
               "[\"no\" \"no\" \"sqlite\"]")

  test "shipped wrappers declare their schema, including the handle flavour":
    # The backends build through the same validated factory an extension uses,
    # so `Type/fields` reports what the value really holds instead of `[]`.
    check_eval("(var f (SqliteDb ~ fields)) [f/0/name f/0/type f/1/name]",
               "[\"handle\" (C/OwnedPtr sqlite3) \"backend\"]")
    check_eval("(var f (PostgresDb ~ fields)) f/0/type",
               "(C/OwnedPtr PGconn)")

  test "native receivers are admitted by Type identity, never by name":
    # The guard turns a prop into an index into a native session table, so a
    # look-alike declaration must not reach state the program never opened.
    check_eval("(import $terminal [write]) " &
               "(type TerminalSession ^props {^id Int ^closed Any}) " &
               "(var fake (TerminalSession ^id 1 ^closed ($cell false))) " &
               "(try (write fake ^bytes \"x\") catch e e/message)",
               "\"terminal/write expects a terminal/Session\"")

  test "deep freeze rejects a wrapper; shallow freeze and thaw pass it through":
    # Deep freeze is a promise about everything reachable, and a live handle
    # cannot keep it: the `closed` Cell and the pointer still change through the
    # original. Shallow freeze promises only that the container's own structure
    # is fixed, which a completed wrapper already satisfies.
    check_eval("(import $db/sqlite [open]) (var c (open \":memory:\")) " &
               "(try ($freeze c) catch (Error ^message m) m)",
               "\"freeze cannot freeze SqliteDb: a native wrapper owns " &
               "native state; freeze_shallow returns it unchanged\"")
    check_eval("(import $db/sqlite [open]) (var c (open \":memory:\")) " &
               "(try ($freeze [c]) catch _ \"rejected through a container\")",
               "\"rejected through a container\"")
    check_eval("(import $db/sqlite [open]) (var c (open \":memory:\")) " &
               "[(same? c ($thaw c)) (same? c ($freeze_shallow c))]",
               "[true true]")

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
    check_eval("(try (var s : (Stream Int Never) ($to_stream [1])) " &
               "     (set s ($to_stream [\"bad\"])) " &
               "     (s ~ next) " &
               "catch (TypeError ^where w) w)",
               "\"Stream/next item\"")

  test "optional type sugar T? is (? T) (design §7.2)":
    check_eval("(var a : Int? nil) a", "nil")
    check_eval("(var b : Int? 5) b", "5")
    check_eval("(fn f [x : Str?] : Str? x) [(f nil) (f \"hi\")]",
               "[nil \"hi\"]")
    check_eval("(fn g [xs : (List Int?)] ($size xs)) (g [1 nil 3])", "3")
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
               "  (s ~ next)) " &
               "(first (ints))",
               "7")
    check_eval("(fn (first item) [b : (Buffer item)] : item " &
               "  (b ~ get 0)) " &
               "(first ($buffer [5 6]))",
               "5")
    check_eval("(var count ($cell 7)) " &
               "(fn (read item) [cell : (Cell item)] : item " &
               "  (cell ~ get)) " &
               "[(read count) " &
               " (try (count ~ set \"bad\") " &
               "  catch (TypeError ^where where) where)]",
               "[7 \"Cell/set value\"]")

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

suite "spec — absence vocabulary from design §1.6":
  test "nil?/void?/absent?/present? follow the two-absence truth table":
    check_eval("[($nil? nil) ($nil? void) ($nil? false) ($nil? 0)]",
               "[true false false false]")
    check_eval("[($void? void) ($void? nil) ($void? false)]",
               "[true false false]")
    check_eval("[($absent? nil) ($absent? void) ($absent? false) ($absent? 0) ($absent? \"\")]",
               "[true true false false false]")
    check_eval("[($present? nil) ($present? void) ($present? false) ($present? 0)]",
               "[false false true true]")

  test "?? yields the first present operand and keeps stored false":
    check_eval("[(?? nil 5) (?? void 5) (?? nil void 7) (?? \"a\" \"b\") (??)]",
               "[5 5 7 \"a\" nil]")
    # The B1 distinction: `||` replaces a stored false, `??` keeps it.
    check_eval("[(?? false 5) (|| false 5)]", "[false 5]")
    check_eval("[(?? 0 5) (?? \"\" \"d\")]", "[0 \"\"]")

  test "?? short-circuits at the first present operand":
    check_eval("(var n 0) (?? 1 (set n 9)) n", "0")
    check_eval("(?? nil void 3 (panic \"not reached\"))", "3")

suite "spec — type aliases from design §7.4.1":
  test "(alias ...) expands transparently in annotation position":
    check_eval("(alias Id Str) (var x : Id \"ok\") x", "\"ok\"")
    check_eval("(alias U (| Int Str)) " &
               "(fn f [v : U] : Str ($to_str v)) [(f 5) (f \"a\")]",
               "[\"5\" \"a\"]")

  test "a type alias rejects a non-conforming value and is not constructible":
    expect GeneError:
      discard run(compileSource("(alias U (| Int Str)) (var x : U true)"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(alias U (| Int Str)) (U)"), newGlobalScope())

  test "an alias may be marked ^private":
    check_eval("(alias Id ^private true Str) (var x : Id \"ok\") x", "\"ok\"")

  test "a cyclic alias raises rather than crashing":
    expect GeneError:
      discard run(compileSource("(alias A A) (var v : A 1)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource("(alias A B) (alias B A) (var v : A 1)"),
                  newGlobalScope())

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
               "  (when [a] $map) " &
               "  (when [map] $map))",
               "(native-fn map)")
    # Arm 1 doesn't match `[9]` (2-tuple needed, 1-tuple given); arm 2
    # matches and references `map`. Sibling-leak would surface as
    # something else; runtime isolation gives us the global.
    check_eval("(match [9] " &
               "  (when [a b] \"first\") " &
               "  (when [c] $map))",
               "(native-fn map)")
    # Arm 1 matches `[1]` and returns the literal; arm 2 never runs.
    check_eval("(match [1] " &
               "  (when [a] \"first\") " &
               "  (when [c] $map))",
               "\"first\"")
  test "for iterates streams lazily and closes on pattern failure":
    check_eval("(var hits ($cell 0)) " &
               "(var source ($map ($to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ update (fn [n] (+ n 1))) x))) " &
               "(var first-hits 0) " &
               "(for x in source " &
               "  (if (== x 1) (set first-hits (hits ~ get)))) " &
               "first-hits",
               "1")
    check_eval("(var hits ($cell 0)) " &
               "(var source ($map ($to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ update (fn [n] (+ n 1))) x))) " &
               "(try (for [a b] in source nil) " &
               " catch (MatchError ^message m) nil) " &
               "[(hits ~ get) (source ~ has_next)]",
               "[1 false]")

  test "for treats strings as char streams":
    check_eval("(var out [nil nil]) " &
               "(var i 0) " &
               "(for ch in \"Aé\" " &
               "  (set out (out ~ assoc i ch)) " &
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
    check_eval("(var hits ($cell 0)) " &
               "(var source ($map ($to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ update (fn [n] (+ n 1))) x))) " &
               "(for x in source (break)) " &
               "[(hits ~ get) (source ~ has_next)]",
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
               "(for x in ($range 0 4 2 true) (set acc [acc... x])) " &
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
    check_eval("(var empty ($to_stream [])) " &
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

suite "spec — Fn type call-shape admission per design §7.4.1":
  test "an Fn type admits every usable call shape of an ordinary fn":
    check_eval("(fn f [x : Int, y : Int = 1] : Int (+ x y)) " &
               "(fn use [g : (Fn [Int] Int)] (g 41)) (use f)", "42")
    check_eval("(fn f [x : Int, ^y : Int] : Int (+ x y)) " &
               "(fn use [g : (Fn [Int] Int ^named {^y Int})] (g 40 ^y 2)) " &
               "(use f)", "42")
    check_eval("(fn f [x : Int, xs...] : Int x) " &
               "(fn use [g : (Fn [Int Any...] Int)] (g 7 1 2 3)) (use f)",
               "7")
    # A typed rest binder `xs... : T` admits `(Fn [T...] R)`.
    check_eval("(fn f [xs... : Int] : Int ($size xs)) " &
               "(fn use [g : (Fn [Int...] Int)] (g 1 2)) (use f)", "2")
    check_eval("(try (fn f [xs... : Str] : Int 0) " &
               "(fn use [g : (Fn [Int...] Int)] g) (use f) " &
               "catch (e : TypeError) \"rejected\")", "\"rejected\"")
  test "unlisted required named parameters stay outside the typed view":
    check_eval("(try (fn f [x : Int, ^y : Int] x) " &
               "(fn use [g : (Fn [Int] Any)] g) (use f) " &
               "catch (e : TypeError) \"rejected\")", "\"rejected\"")
  test "a typed rest parameter checks each gathered argument":
    check_eval("(fn f [xs... : Int] : Int ($size xs)) [(f) (f 1 2 3)]", "[0 3]")
    check_eval("(fn f [a : Str, xs... : Int] xs) (f \"p\" 1 2)", "[1 2]")
    check_eval("(try (fn f [xs... : Int] xs) (f 1 \"bad\") " &
               "catch (e : TypeError) \"rejected\")", "\"rejected\"")

  test "generic fns instantiate consistently and T? equals (? T)":
    check_eval("(fn (identity T) [x : T] : T x) " &
               "(fn use [g : (Fn [Int] Int)] (g 42)) (use identity)", "42")
    check_eval("(fn f [x : (? Int)] : Int 1) " &
               "(fn use [g : (Fn [Int?] Int)] (g 5)) (use f)", "1")

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
    check_eval("($range 1 4)", "(range 1 4)")
    check_eval("[(== ($range 0 3) ($range 0 3)) " &
               " (== ($range 0 3) ($range 0 4)) " &
               " (== ($hash ($range 0 3)) ($hash ($range 0 3)))]",
               "[true false true]")
    expect GeneError:
      discard run(compileSource("($range 0 10 0)"), newGlobalScope())

  test "range exposes start stop step inclusive and size":
    check_eval("(var r ($range 2 8 2)) " &
               "[(r ~ start) (r ~ stop) (r ~ step) " &
               " (r ~ inclusive?) (r ~ size)]",
               "[2 8 2 false 3]")
    check_eval("(var r ($range 0 4 2 true)) " &
               "[(r ~ inclusive?) (r ~ size) r]",
               "[true 3 (range 0 4 2 true)]")
    check_eval("(($range -9223372036854775808 9223372036854775807 1 true) ~ size)",
               "18446744073709551616")

  test "range streams lazily and for iterates ranges":
    check_eval("($into ($to_stream ($range 0 5)) [])",
               "[0 1 2 3 4]")
    check_eval("($into ($to_stream ($range 5 0 -2)) [])",
               "[5 3 1]")
    check_eval("($into ($to_stream ($range 0 4 2 true)) [])",
               "[0 2 4]")
    check_eval("(var sum 0) " &
               "(for x in ($range 0 5) " &
               "  (set sum (+ sum x))) " &
               "sum",
               "10")

  test "range satisfies Range and typed Stream boundaries":
    check_eval("(fn size-of [r : Range] (r ~ size)) " &
               "(size-of ($range 0 3))",
               "3")
    check_eval("(fn first-int [s : (Stream Int Never)] (s ~ next)) " &
               "(first-int ($to_stream ($range 5 6)))",
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
    check_eval("[($date 2026 7 4) ($time 9 30 15 123400 -240 \"America/New_York\") " &
               " ($datetime 2026 7 4 9 30 15 123456 0 \"UTC\") " &
               " ($timezone \"UTC\") ($duration 1500000)]",
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
    check_eval("(var z ($timezone \"+08:00\" \"Asia/Shanghai\")) " &
               "[(z ~ offset) (z ~ name)]",
               "[480 \"Asia/Shanghai\"]")
    check_eval("(var d ($duration 1500000)) " &
               "[(d ~ microseconds) (d ~ milliseconds) (d ~ seconds)]",
               "[1500000 1500.0 1.5]")
    check_eval("(fn f [d : Duration] (d ~ seconds)) (f ($duration 2000000))",
               "2.0")

  test "date time values are immutable and hash stable":
    check_eval("[(== 2026-07-04 2026-07-04) " &
               " (== 09:30 09:31) " &
               " (== ($hash 2026-07-04T09:30Z) ($hash 2026-07-04T09:30Z))]",
               "[true false true]")

suite "spec — implicit self in message bodies from design §10":
  test "self is implicit; the receiver leaves the parameter vector":
    check_eval("(type Box ^props {^val Int} " &
               "  (message get [] self/val) " &
               "  (message add [n] (+ self/val n))) " &
               "(var b (Box ^val 10)) [(b ~ get) (b ~ add 5)]",
               "[10 15]")

  test "a held message value is sent with (x ~ %m)":
    check_eval("(protocol ToHtml (message to_html [] : Str)) " &
               "(type M ^props {^name Str} " &
               "  (impl ToHtml (message to_html [] : Str self/name))) " &
               "(var m ToHtml:to_html) " &
               "(var items [(M ^name \"a\") (M ^name \"b\")]) " &
               "(($map ($to_stream items) (fn [x] (x ~ %m))) ~ into [])",
               "[\"a\" \"b\"]")

  test "sending a held fn! value is a CallKindError":
    check_eval("(fn! q! [x] x) (var f q!) " &
               "(try ([1] ~ %f 1) catch (CallKindError ^where w) w)",
               "\"message send\"")

  test "a dynamic send requires a message value, not an arbitrary function":
    # (x ~ %m) / (x ~ (expr)) dispatch only: a plain function held in the
    # callee value is rejected, so `~` never invokes an arbitrary function.
    check_eval("(fn f [x] x) (var m f) " &
               "(try ([1] ~ %m) catch (CallKindError ^expected e) e)",
               "\"Message\"")
    check_eval("(fn f [x] x) " &
               "(try ([1] ~ (do f)) catch (CallKindError ^where w) w)",
               "\"message send\"")

  test "a qualified send requires a protocol message, not a namespace member":
    # Only a protocol gives a message a qualified spelling, so the qualifier is
    # a reliable signal: bare means type-direct, qualified means protocol.
    check_eval("(import $str [join]) " &
               "(try ([\"a\" \"b\"] ~ gene/str/join \"-\") " &
               "catch (CallKindError ^expected e) e)",
               "\"Message\"")
    # A built-in operation is type-direct, so it takes the bare form.
    # Neither `Cell/get` nor `Cell:get` is a callable/message spelling.
    check_eval("(var c ($cell 7)) " &
               "[(c ~ get) " &
               " (try (c ~ Cell:get) catch (CallKindError ^expected e) e)]",
               "[7 \"Protocol\"]")
    check_runtime_error("(Cell/get ($cell 7))", "not a callable path")

  test "a built-in surface is a type, so it can receive impls":
    # `Cell` is a real type whose message table holds get/set/swap/update
    # (design §12.2), not a namespace of natives. That is what lets a protocol
    # name it as a receiver — the same declaration used to crash with
    # `FieldDefect: value is not a Type`.
    check_eval("[Cell Buffer Node Map List Channel Stream Actor]",
               "[(type Cell) (type Buffer) (type Node) (type Map) " &
               "(type List) (type Channel) (type Stream) (type Actor)]")
    # The receiver-shaped surfaces are types too now, so the rule is uniform:
    # an uppercase built-in surface is a type. What stays a namespace is a
    # namespace *of* things (`C`'s ABI types, `gene/fs`' capabilities), not a
    # surface whose members all take a receiver.
    check_eval("[AtomicCell Task ReplyTo Module Namespace Capability]",
               "[(type AtomicCell) (type Task) (type ReplyTo) (type Module) " &
               "(type Namespace) (type Capability)]")
    # `snapshot` used to make `Env` look like a namespace: it takes a
    # **CallerEnv**, not an `Env`, so as a static factory it had no receiver and
    # `T/m` is not a callable path. Giving it its real receiver settles it —
    # `Env` keeps only the message that genuinely takes an `Env`.
    check_eval("[Env CallerEnv]", "[(type Env) (type CallerEnv)]")
    check_eval("(var x 1) (fn! capture! [] (caller_env ~ snapshot [\"x\"])) " &
               "($nil? (capture!))",
               "false")
    check_eval("[Date Time DateTime Timezone Duration Range]",
               "[(type Date) (type Time) (type DateTime) (type Timezone) " &
               "(type Duration) (type Range)]")
    check_eval("(var ac ($atomic_cell 1)) (ac ~ store 5) (ac ~ load)", "5")
    check_eval("[(($range 0 5) ~ size) (($date 2026 7 4) ~ year) " &
               " ((($range 0 3) ~ to_stream) ~ into [])]",
               "[5 2026 [0 1 2]]")
    # Which is what makes them impl receivers — the point of the rule.
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(impl Shown for Range (message show [] : Str " &
               "  ($to_str (self ~ size)))) " &
               "(impl Shown for Date (message show [] : Str " &
               "  ($to_str (self ~ year)))) " &
               "[(($range 0 7) ~ Shown:show) (($date 2026 7 4) ~ Shown:show)]",
               "[\"7\" \"2026\"]")
    # `each` has no bare root binding — it lives only in the `stream`
    # namespace — so the type's table has to hold that same value.
    check_shared_native("Stream", "map", "$map")
    check_shared_native("Stream", "into", "$into")
    check_shared_native("Stream", "each", "$stream/each")
    check_eval("(var c ($cell 0)) " &
               "((([1 2 3 4] ~ to_stream) ~ filter (fn [x] (> x 2))) " &
               "  ~ each (fn [x] (c ~ set (+ (c ~ get) x)))) " &
               "(c ~ get)",
               "7")
    # `Channel` is one of the names a program may redeclare, so the annotation
    # path lets a scope lookup win. Now that the built-in is itself a type,
    # landing back on the built-in must not read as a shadow: the generic form
    # still applies, and a real local declaration still wins.
    check_eval("(var ch ($channel ^capacity 2)) " &
               "[((fn [c : Channel] 1) ch) ((fn [c : (Channel Int)] 2) ch)]",
               "[1 2]")
    check_eval("(type Channel ^props {^a Int}) " &
               "[((fn [c : Channel] 3) (Channel ^a 1)) " &
               " (try ((fn [c : Channel] 3) ($channel ^capacity 1)) " &
               "  catch (TypeError ^expected e) e)]",
               "[3 \"Channel\"]")
    # A name that is both a bare library function and a type message names one
    # function value, not two natives that behave alike.
    check_shared_native("List", "size", "$size")
    check_shared_native("Node", "head", "$head")
    check_shared_native("List", "to_stream", "$to_stream")
    # Kinds that are still namespace-backed keep reaching the same natives.
    check_eval("(var s ($Set 1 2)) (var r ($range 0 3)) " &
               "[(s ~ contains? 1) ((s ~ to_stream) ~ into []) " &
               " ((r ~ to_stream) ~ into [])]",
               "[true [1 2] [0 1 2]]")
    # Both map representations dispatch as `Map`; `PropMap`/`HashMap` name the
    # representations in annotations and carry no messages of their own.
    check_eval("(protocol Sz (message sz [] : Int)) " &
               "(impl Sz for Map (message sz [] : Int 7)) " &
               "[({^a 1} ~ Sz:sz) ({{\"a\" : 1}} ~ Sz:sz) " &
               " ({{\"a\" : 1}} ~ get \"a\") " &
               " ((fn [m : PropMap] 1) {^a 1}) " &
               " ((fn [m : (Map Sym Any)] 2) {^a 1})]",
               "[7 7 1 1 2]")
    check_eval("[(Cell ~ name) (Cell ~ fields)]", "[\"Cell\" []]")
    # A generic annotation on a built-in stays on the symbolic matching path,
    # so making the surface a type does not disturb `(Buffer T)`.
    check_eval("(var b ($buffer [1 2 3])) " &
               "[((fn [x : (Buffer Int)] (x ~ len)) b) " &
               " ((fn [x : Buffer] (x ~ get 0)) b)]",
               "[3 1]")
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(impl Shown for Str (message show [] : Str self)) " &
               "(impl Shown for Cell " &
               "  (message show [] : Str ((self ~ get) ~ Shown:show))) " &
               "(($cell \"hi\") ~ Shown:show)",
               "\"hi\"")
    # Bare and selector spellings resolve through the one message table, and a
    # name it does not hold is still a MessageError naming the type.
    check_eval("(var c ($cell 1)) " &
               "[(c ~ get) c/~get " &
               " (try (c ~ nope) catch (MessageError ^receiver_type t) t)]",
               "[1 1 \"Cell\"]")

  test "every reader-produced shape projects as a node":
    # design §1.3: `42` reads as `(Int 42)`, `[1 2]` as `(List 1 2)`, and
    # `{^a 1}` as `(Map ^a 1)`. So `head` is uniformly the type — the same slot
    # a data node fills with its tag and a typed instance with its type — and a
    # literal's `body` is the literal itself.
    check_eval("[(== ($head 42) Int) (== ($head 1.5) Float) " &
               " (== ($head \"s\") Str) (== ($head (quote a)) Sym) " &
               " (== ($head true) Bool) (== ($head nil) Nil) " &
               " (== ($head void) Void) (== ($head 'c') Char)]",
               "[true true true true true true true true]")
    check_eval("[(== ($head [1 2]) List) (== ($head {^a 1}) Map) " &
               " (== ($head {{\"a\" : 1}}) Map)]",
               "[true true true]")
    check_eval("[($body 42) ($body \"s\") ($body nil) ($body [1 2]) " &
               " ($body {^a 1})]",
               "[[42] [\"s\"] [nil] [1 2] []]")
    # Props and meta do not move: only `head` and a literal's `body` change.
    check_eval("[($props 42) ($meta 42) ($props {^a 1}) ($body {^a 1})]",
               "[{} {} {^a 1} []]")
    # A data node keeps its tag and a typed instance keeps its type — both
    # already sat in `head`, which is what the literals now join.
    check_eval("(type P ^props {^a Int}) " &
               "[($head (quote (f 1 2))) (== ($head (P ^a 1)) P)]",
               "[f true]")
    # Values with no source form are not node-shaped, so they stay their own
    # head rather than projecting a type they could not be written as.
    check_eval("(var c ($cell 1)) [(same? ($head c) c) ($body c)]",
               "[true []]")

  test "a rest pattern binds in node-body position, not only in a list":
    # The reader gives `xs...` two shapes: the symbol `xs...` inside a list
    # literal, and the spread node `(... xs)` everywhere else. A pattern has to
    # accept both, or a node-body rest silently takes the exact-arity path.
    check_eval("[(match (quote (f 1 2 3)) (when (f xs...) xs) (else \"no\")) " &
               " (match [1 2 3] (when [a xs...] [a xs]) (else \"no\")) " &
               " (match [1 2 3] (when (List xs...) xs) (else \"no\"))]",
               "[[1 2 3] [1 [2 3]] [1 2 3]]")
    # Patterns before and after the rest, and the `_...` discard.
    check_eval("[(match (quote (f 1 2 3 4)) (when (f a rest... z) [a rest z]) " &
               "  (else \"no\")) " &
               " (match (quote (f 1 2 3)) (when (f a _...) a) (else \"no\"))]",
               "[[1 [2 3] 4] 1]")
    # A typed instance's body destructures the same way.
    check_eval("(type P ^props {^a Int} ^body [Any...]) (var p (P ^a 1)) " &
               "(p ~ push_body! 7) (p ~ push_body! 8) " &
               "(match p (when (P ^a k xs...) [k xs]) (else \"no\"))",
               "[1 [7 8]]")
    # The macro-time matcher is a separate implementation and needs the same
    # rule, or a macro parameter pattern disagrees with a runtime one.
    check_eval("(macro grab [(f a xs...)] `%xs) (grab (f 1 2 3))", "[2 3]")

  test "a node-shape pattern destructures through the projection":
    # `(P ^a x)` already read a typed instance's head/props/body. Now that a
    # literal projects the same anatomy (design §1.3), the same pattern shape
    # reaches every value: `(Int n)` binds `n`, so `(when (Int n) …)` and
    # `(when (Str s) …)` are uniform arms rather than a scalars-only carve-out.
    check_eval("[(match 42 (when (Int n) n) (else \"no\")) " &
               " (match \"hi\" (when (Str s) s) (else \"no\")) " &
               " (match 1.5 (when (Float f) f) (else \"no\")) " &
               " (match true (when (Bool b) b) (else \"no\")) " &
               " (match nil (when (Nil n) \"nil\") (else \"no\"))]",
               "[42 \"hi\" 1.5 true \"nil\"]")
    # Lists and maps destructure through the same one rule.
    check_eval("[(match [1 2] (when (List a b) [a b]) (else \"no\")) " &
               " (match {^a 1} (when (Map ^a x) x) (else \"no\"))]",
               "[[1 2] 1]")
    # The head still has to match, so arms stay discriminating.
    check_eval("[(match 42 (when (Str s) s) (else \"no\")) " &
               " (match [1 2] (when (Map ^a x) x) (else \"no\")) " &
               " (match \"hi\" (when (Int n) n) (else \"no\"))]",
               "[\"no\" \"no\" \"no\"]")
    # Body arity is the ordinary node-pattern rule, applied to a body that now
    # holds the literal: `(Int)` has no slot for the 42 and does not match.
    check_eval("[(match 42 (when (Int) \"none\") (else \"no\")) " &
               " (match 42 (when (Int _) \"wild\") (else \"no\"))]",
               "[\"no\" \"wild\"]")
    # Values with no source form are not node-shaped, so nothing starts
    # matching one by accident.
    check_eval("(match ($cell 1) (when (Cell c) c) (else \"no\"))", "\"no\"")
    # A typed instance is unchanged — it was always read this way.
    check_eval("(type P ^props {^a Int}) " &
               "(match (P ^a 7) (when (P ^a x) x) (else \"no\"))",
               "7")

  test "a gene-root annotation spelling means what the bare name means":
    # `$X/y` and `gene/X/y` are two spellings of one name, so an annotation
    # written either way must answer as bare `X/y` does. `$X/y` reads as a path
    # and `gene/X/y` as a symbol, so the two arrive on different arms and both
    # need normalising — and before this, the path arm re-closed an expression
    # that could not change and recursed until the stack overflowed, i.e.
    # `[x : $ffi/Load]` was a SIGSEGV rather than any kind of error.
    check_eval("[((fn [x : $Int] x) 7) ((fn [x : gene/Int] x) 7) " &
               " ((fn [x : Int] x) 7)]",
               "[7 7 7]")
    check_eval("(try ((fn [x : $Int] x) \"s\") " &
               " catch (TypeError ^expected e) e)",
               "\"gene/Int\"")
    # A path that names nothing is an unknown annotation, not a crash, and it
    # is catchable.
    check_eval("($str/starts_with? " &
               " (try ((fn [x : $fs/ReadDir] x) nil) catch (Error ^message m) m) " &
               " \"unknown type annotation\")",
               "true")

  test "an impl receiver must be a type, and says so catchably":
    # An impl is keyed on the receiver's type identity, so a receiver without
    # one cannot carry it. This used to reach `typeScope` and die on a Nim
    # FieldDefect — a crash with no source location that Gene could not catch.
    # `C` is the durable example: it is a namespace *of* C ABI types and stays
    # one deliberately, so unlike the receiver-shaped surfaces it will not turn
    # into a type later and quietly make this test vacuous.
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(try (impl Shown for C (message show [] : Str \"x\")) " &
               " catch (TypeError ^where w ^expected e ^actual a) [w e a])",
               "[\"impl receiver\" \"Type\" \"Namespace\"]")
    check_runtime_error(
      "(protocol Shown (message show [] : Str)) " &
      "(impl Shown for C (message show [] : Str \"x\"))",
      "a namespace has no type identity")
    check_runtime_error(
      "(protocol Shown (message show [] : Str)) (var x 42) " &
      "(impl Shown for x (message show [] : Str \"y\"))",
      "only a type can receive an impl")
    # The built-in surfaces decision 7 made types still take impls.
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(impl Shown for List (message show [] : Str \"list\")) " &
               "(impl Shown for Int (message show [] : Str \"int\")) " &
               "[([1] ~ Shown:show) (7 ~ Shown:show)]",
               "[\"list\" \"int\"]")

  test "leaf? names the base case for a generic walk":
    # A literal has no interior node structure. Under the projection model its
    # `body` is itself, so a walk that descends through `body` needs an
    # explicit base case; `leaf?` is how a program says so without enumerating
    # kinds. The set is exactly the kinds that carry scalar type identities.
    check_eval("[($leaf? 42) ($leaf? 1.5) ($leaf? \"s\") ($leaf? (quote a)) " &
               " ($leaf? true) ($leaf? nil) ($leaf? void) ($leaf? 'c')]",
               "[true true true true true true true true]")
    check_eval("[($leaf? [1 2]) ($leaf? {^a 1}) ($leaf? (quote (f 1))) " &
               " ($leaf? ($cell 1))]",
               "[false false false false]")
    # The guarded idiom terminates on every shape.
    check_eval("(fn walk [n] " &
               "  (if ($leaf? n) 1 (do ((($body n) ~ to_stream) ~ each walk) 1))) " &
               "[(walk 42) (walk (quote (f 1 2))) (walk [1 [2 3]])]",
               "[1 1 1]")

  test "node anatomy is universal; the Node type is not":
    # A data node's dispatch face is the concrete `Node` type, so it can carry
    # an impl (design §1.2). A typed instance keeps its own type as its
    # dispatch face and still answers the projections, because it is
    # structurally a node — not because it is an instance of `Node`.
    check_eval("(protocol Tag (message tag [] : Any)) " &
               "(impl Tag for Node (message tag [] : Any (self ~ head))) " &
               "((quote (f 1 2)) ~ Tag:tag)",
               "f")
    check_eval("(var n (quote (f 1 2))) " &
               "[(n ~ head) (n ~ props) (n ~ body) (n ~ meta)]",
               "[f {} [1 2] {}]")
    check_eval("(type P ^props {^a Int}) (var p (P ^a 1)) " &
               "[(try (p ~ set_prop! \"b\" 2) " &
               "  catch (Error ^message message) message) " &
               " (p ~ head) (p ~ body) (p ~ props)]",
               "[\"P has no field 'b'\" (type P) [] {^a 1}]")
    # The *annotation* answers exactly what the impl reaches. `Node` is a
    # concrete type, so a typed instance and an enum value are not `Node`s even
    # though both are node-shaped; `Any` is the root type. Node shape for other
    # values is a conversion, not a subtyping relation.
    check_eval("(type P ^props {^a Int}) (enum Color red green) " &
               "(fn takes [n : Node] : Str \"yes\") " &
               "[(takes (quote (f 1 2))) (takes `(tr (td \"x\"))) " &
               " (try (takes (P ^a 1)) catch (TypeError ^expected e) e) " &
               " (try (takes Color/red) catch (TypeError ^expected e) e) " &
               " (try (takes 42) catch (TypeError ^expected e) e)]",
               "[\"yes\" \"yes\" \"Node\" \"Node\" \"Node\"]")
    check_eval("(type P ^props {^a Int}) (fn any [x : Any] : Str \"yes\") " &
               "[(any (P ^a 1)) (any 42) (any (quote (f 1)))]",
               "[\"yes\" \"yes\" \"yes\"]")
    # An *uppercase* head is still only a symbol unless a type is actually
    # there, so a node tagged `Declaration` stays a data node. That is what
    # `$declarations` yields and what `web_demo`'s `[decl : Node]` relies on —
    # a boundary that cannot be checked in that file, because it does not run.
    check_eval("(type Declaration ^props {^name Str}) " &
               "(fn routed? [decl : Node] : Bool true) " &
               "[($leaf? ($head (quote (Declaration ^name \"h\")))) " &
               " (routed? (quote (Declaration ^name \"h\"))) " &
               " (try (routed? (Declaration ^name \"h\")) " &
               "  catch (TypeError ^expected e) e)]",
               "[true true \"Node\"]")
    # An impl on `Node` does not reach a typed instance: `Node` is concrete,
    # not a supertype.
    check_eval("(protocol Tag (message tag [] : Any)) " &
               "(impl Tag for Node (message tag [] : Any (self ~ head))) " &
               "(type P ^props {^a Int}) " &
               "(try ((P ^a 1) ~ Tag:tag) " &
               "catch (MessageError ^receiver_type t) t)",
               "\"P\"")

  test "a message in head position is rejected at compile time":
    # `:` reads as its own node, so the head-position ban no longer waits for
    # the callee to evaluate (design §3, decision 3). It only rejects; it never
    # picks between two meanings.
    check_compile_error("(protocol P (message m [] : Str)) (P:m 1)",
                        "dispatches only through ~")

  test "a message in value position is a dispatching message value":
    # Decision 2. `Proto:msg` is a *message*, not a function: it prints as one,
    # is accepted as a held send callee, and satisfies `Callable` without
    # satisfying `Fn`. Applied, it dispatches on its first argument, so
    # `(map xs P:m)` works and its signature is (receiver, ...send args).
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(type A ^props {^n Int} (impl Shown (message show [] : Str \"A\"))) " &
               "(type B ^props {^n Int} (impl Shown (message show [] : Str \"B\"))) " &
               "(var xs [(A ^n 1) (B ^n 2)]) " &
               "(($map ($to_stream xs) Shown:show) ~ into [])",
               "[\"A\" \"B\"]")
    check_eval("(protocol Add (message plus [n : Int] : Int)) " &
               "(type W ^props {^v Int} " &
               "  (impl Add (message plus [n : Int] : Int (+ self/v n)))) " &
               "(var f Add:plus) (f (W ^v 10) 5)",
               "15")
    # The impl resolves in the scope where the value was *written*. A lazy
    # combinator retains only the callable and applies it with no reachable
    # send scope, which is exactly what defeated the message-identity attempt.
    check_eval("(protocol S (message s [] : Str)) " &
               "(impl S for Int (message s [] : Str \"int\")) " &
               "(var g S:s) " &
               "(($map ($to_stream [1 2]) g) ~ into [])",
               "[\"int\" \"int\"]")
    # It answers as a message: Callable, but not a Fn, and it prints as one.
    check_eval("(protocol S (message s [] : Str)) " &
               "[((fn [f : Callable] true) S:s) " &
               " (try ((fn [f : Fn] true) S:s) catch (TypeError ^expected e) e)]",
               "[true \"Fn\"]")
    check_eval("(protocol S (message s [] : Str)) S:s", "(message s)")
    # A held message value still reaches `(x ~ %m)`, which a function cannot.
    check_eval("(protocol S (message s [] : Str)) " &
               "(impl S for Int (message s [] : Str \"int\")) " &
               "(var m S:s) (5 ~ %m)",
               "\"int\"")
    # The `Callable` boundary used to accept a message and then raise on the
    # call; the closure closes that hole.
    check_eval("(protocol P (message m [] : Str)) " &
               "(type T ^props {} (impl P (message m [] : Str \"ok\"))) " &
               "(fn call_it [f : Callable] (f (T))) (call_it P:m)",
               "\"ok\"")

  test "a dynamic send accepts an expression that yields a message value":
    check_eval("(protocol ToHtml (message to_html [] : Str)) " &
               "(type M ^props {^name Str} " &
               "  (impl ToHtml (message to_html [] : Str self/name))) " &
               "(var m ToHtml:to_html) " &
               "((M ^name \"z\") ~ (do m))",
               "\"z\"")

  test "a leading self send takes held, qualified, and selector callees":
    # `(~ f)` is `(self ~ f)`, so it accepts the same callee forms.
    check_eval("(protocol ToHtml (message to_html [] : Str)) " &
               "(type M ^props {^name Str} " &
               "  (impl ToHtml (message to_html [] : Str self/name)) " &
               "  (message held [] (var m ToHtml:to_html) (~ %m)) " &
               "  (message qual [] (~ ToHtml:to_html)) " &
               "  (message sel  [] (~ /name))) " &
               "(var x (M ^name \"n\")) " &
               "[(x ~ held) (x ~ qual) (x ~ sel)]",
               "[\"n\" \"n\" \"n\"]")

  test "an inline impl message binds self implicitly":
    check_eval("(protocol Greet (message hi [] : Str)) " &
               "(type P ^props {^name Str} " &
               "  (impl Greet (message hi [] : Str $\"hi ${self/name}\"))) " &
               "((P ^name \"Ada\") ~ Greet:hi)",
               "\"hi Ada\"")

  test "enum messages bind self implicitly":
    check_eval("(enum Direction north east south west " &
               "  (message degrees [] : Int (* (self ~ ordinal) 90))) " &
               "(Direction/south ~ degrees)",
               "180")

  test "the legacy explicit-self form still binds the receiver":
    check_eval("(type Box2 ^props {^val Int} (message get [self] self/val)) " &
               "((Box2 ^val 7) ~ get)",
               "7")

  test "Self in annotation position is the receiver's own type":
    # design §10. `Self` means the same thing here as it does as a message
    # qualifier — the receiver's own type — so the name has one rule in both
    # positions. Nothing caught this being broken because doc ```gene blocks are
    # not executed and the two example files using it fail to run for unrelated
    # reasons, so the spec carries it now.
    check_eval("(protocol Eq (message eq [other : Self] : Bool)) " &
               "(type P ^props {^a Int}) " &
               "(impl Eq for P " &
               "  (message eq [other : Self] : Bool (== self/a other/a))) " &
               "[((P ^a 1) ~ Eq:eq (P ^a 1)) ((P ^a 1) ~ Eq:eq (P ^a 2))]",
               "[true false]")
    # Return position, and a nested/optional occurrence.
    check_eval("(type P ^props {^a Int} " &
               "  (message me [] : Self self) " &
               "  (message all [xs : (List Self)] : Int ($size xs)) " &
               "  (message maybe [o : Self?] : Bool ($nil? o))) " &
               "(var p (P ^a 1)) " &
               "[(same? (p ~ me) p) (p ~ all [(P ^a 2)]) (p ~ maybe nil)]",
               "[true 1 true]")
    # Resolved against the receiver, not the enclosing declaration: the
    # constraint follows the receiver down the `^is` chain, so it is asymmetric.
    check_eval("(type Dog ^props {^n Str}) (type Pup ^is Dog ^props {}) " &
               "(protocol Eq (message eq [other : Self] : Bool)) " &
               "(impl Eq for Dog (message eq [other : Self] : Bool true)) " &
               "[((Dog ^n \"d\") ~ Eq:eq (Pup ^n \"p\")) " &
               " (try ((Pup ^n \"p\") ~ Eq:eq (Dog ^n \"d\")) " &
               "  catch (TypeError ^expected e) e)]",
               "[true \"Self\"]")
    # A protocol's *default* body has no enclosing type at all, which is why
    # `Self` cannot be resolved statically.
    check_eval("(protocol Eq (message eq [other : Self] : Bool true)) " &
               "(type A ^props {^a Int}) (type B ^props {^a Int}) " &
               "(impl Eq for A) (impl Eq for B) " &
               "[((A ^a 1) ~ Eq:eq (A ^a 2)) " &
               " (try ((A ^a 1) ~ Eq:eq (B ^a 2)) " &
               "  catch (TypeError ^expected e) e)]",
               "[true \"Self\"]")
    # Annotating the receiver itself is a tautology: accepted, discarded, and
    # builds the same signature as `[self]` — which is what lets a declaration
    # spelled either way satisfy the impl compatibility check.
    check_eval("(protocol L (message label [self : Self] : Str)) " &
               "(type P ^props {^n Str}) " &
               "(impl L for P (message label [] : Str self/n)) " &
               "((P ^n \"x\") ~ L:label)",
               "\"x\"")
    # Outside a message or ctor body there is no receiver to name.
    check_runtime_error("(fn f [x : Self] x) (f 1)",
                        "Self names the receiver's type")

  test "self is immutable inside a message body":
    # The diagnostic names the receiver rather than suggesting `var`, which is
    # not a fix a caller could apply to `self` (design §10).
    check_compile_error(
      "(type Box ^props {^v Int} (message bad [] (set self 42) self))",
      "'self' is the receiver and cannot be reassigned")

  test "super delegates to the implementation above, relative to the enclosing type":
    check_eval("(type A ^props {} (message greet [] : Str \"A\")) " &
               "(type B ^is A ^props {} " &
               "  (message greet [] : Str ($ \"B+\" (super ~ greet)))) " &
               "(type C ^is B ^props {} " &
               "  (message greet [] : Str ($ \"C+\" (super ~ greet)))) " &
               "[((B) ~ greet) ((C) ~ greet)]",
               "[\"B+A\" \"C+B+A\"]")

  test "super passes arguments to the parent implementation":
    check_eval("(type A ^props {} (message scale [n] : Int (* n 2))) " &
               "(type B ^is A ^props {} " &
               "  (message scale [n] : Int (+ (super ~ scale n) 1))) " &
               "((B) ~ scale 10)",
               "21")

  test "super with no parent is a compile error":
    check_compile_error(
      "(type X ^props {} (message m [] : Str (super ~ m)))",
      "super is only valid")

  test "a type cannot qualify a super send":
    check_eval("(type A ^props {} (message m [] : Str \"A\")) " &
               "(type B ^is A ^props {} " &
               "  (message m [] : Str (super ~ A:m))) " &
               "(try ((B) ~ m) " &
               "catch (CallKindError ^where w ^expected e) [w e])",
               "[\"super send\" \"Protocol\"]")

  test "super delegates a protocol message from the ^is parent":
    # `docs/scoped-impls.md` §3.3 already keeps only providers at the nearest
    # applicable receiver depth, so resolving from the parent *is* "continue the
    # walk from above the enclosing type" — no new precedence rule was needed.
    # The qualifier names the message; the parent selects the impl.
    check_eval("(protocol P (message m [] : Str)) " &
               "(type A ^props {}) (impl P for A (message m [] : Str \"A\")) " &
               "(type B ^is A ^props {}) " &
               "(impl P for B (message m [] : Str ($ \"B+\" (super ~ P:m)))) " &
               "((B) ~ P:m)",
               "\"B+A\"")
    # Three deep, and the inline-impl spelling, which shares the enclosing type.
    check_eval("(protocol P (message m [] : Str)) " &
               "(type A ^props {} (impl P (message m [] : Str \"A\"))) " &
               "(type B ^is A ^props {} " &
               "  (impl P (message m [] : Str ($ \"B+\" (super ~ P:m))))) " &
               "(type C ^is B ^props {} " &
               "  (impl P (message m [] : Str ($ \"C+\" (super ~ P:m))))) " &
               "((C) ~ P:m)",
               "\"C+B+A\"")
    # A level with no provider is skipped rather than erroring: nearest
    # applicable receiver depth, not "the immediate parent must implement it".
    check_eval("(protocol P (message m [] : Str)) " &
               "(type A ^props {}) (impl P for A (message m [] : Str \"A\")) " &
               "(type B ^is A ^props {}) " &
               "(type C ^is B ^props {}) " &
               "(impl P for C (message m [] : Str ($ \"C+\" (super ~ P:m)))) " &
               "((C) ~ P:m)",
               "\"C+A\"")
    # Nothing above at all is a recoverable MessageError naming the parent.
    check_eval("(protocol P (message m [] : Str)) " &
               "(type A ^props {}) " &
               "(type B ^is A ^props {}) " &
               "(impl P for B (message m [] : Str (super ~ P:m))) " &
               "(try ((B) ~ P:m) catch (MessageError ^receiver_type t) t)",
               "\"A\"")
    # `Self:` names no qualifier, so it is exactly the bare super send.
    check_eval("(type A ^props {} (message g [] : Str \"A\")) " &
               "(type B ^is A ^props {} " &
               "  (message g [] : Str ($ \"B+\" (super ~ Self:g)))) " &
               "((B) ~ g)",
               "\"B+A\"")

  test "super still rejects a dynamic callee":
    # super's target is fixed statically; an expression yielding a message value
    # cannot be checked against the parent at compile time, so it stays refused.
    check_compile_error(
      "(protocol P (message m [] : Str)) " &
      "(type A ^props {} (impl P (message m [] : Str \"A\"))) " &
      "(type B ^is A ^props {} " &
      "  (message go [] : Str (var q P:m) (super ~ %q)))",
      "is a dynamic callee")

  test "super is robust against a local shadowing the parent or enclosing name":
    # super resolves no user-visible name: the owner's ^is parent is recorded on
    # the message body when the type is created.
    check_eval("(type A ^props {} (message m [] : Str \"A\")) " &
               "(type B ^is A ^props {} " &
               "  (message m [] : Str (do (let A 1) (super ~ m)))) " &
               "((B) ~ m)",
               "\"A\"")
    check_eval("(type A ^props {} (message m [] : Str \"A\")) " &
               "(type B ^is A ^props {} " &
               "  (message m [] : Str (do (let B 1) (super ~ m)))) " &
               "((B) ~ m)",
               "\"A\"")

  test "super works inside a closure nested in the message body":
    check_eval("(type A ^props {} (message m [] : Str \"A\")) " &
               "(type B ^is A ^props {} " &
               "  (message m [] : Str (var f (fn [] (super ~ m))) " &
               "                      ($ \"B+\" (f)))) " &
               "((B) ~ m)",
               "\"B+A\"")

  test "super stays per-type when one declaration is created with two parents":
    # The parent identity lives on the message body, which the compiler emits
    # once for the declaration site. Creating that `type` again with a different
    # ^is must not retarget the delegation of the types created before it.
    check_eval("(type A ^props {} (message m [] : Str \"A\")) " &
               "(type B ^props {} (message m [] : Str \"B\")) " &
               "(fn make [p] " &
               "  (type C ^is p ^props {} (message up [] : Str (super ~ m))) " &
               "  C) " &
               "(let C1 (make A)) (let C2 (make B)) " &
               "[((C1) ~ up) ((C2) ~ up)]",
               "[\"A\" \"B\"]")

  test "self cannot be rebound by a nested binder in a message body":
    check_compile_error(
      "(type T ^props {} (message m [] (fn f [self] self) (f 42)))",
      "cannot be rebound in a message body")

  test "a qualified send with no visible impl raises a catchable MessageError":
    check_eval("(protocol P (message m [] : Int)) (type T ^props {}) " &
               "(try ((T) ~ P:m) catch (MessageError ^protocol pr) pr)",
               "\"P\"")

  test "a receiver with no nominal type still raises a catchable MessageError":
    check_eval("(protocol P (message m [] : Int)) " &
               "(try (nil ~ P:m) catch (MessageError ^protocol pr) pr)",
               "\"P\"")

suite "spec — absence-guarded sends (design §3)":
  # `?~` guards on the *receiver* only. It is a call-site choice, not a rule
  # about nil: `~` on an absent receiver is still an error, and `impl P for Nil`
  # still wins on a plain send.
  const guarded =
    "(type X ^props {^n Int} " &
    "  (message msg [] : Str \"x\") (message add [k] : Int (+ self/n k))) " &
    "(protocol P (message pm [] : Str)) " &
    "(impl P for X (message pm [] : Str \"x-pm\")) "

  test "an absent receiver yields itself; a present one dispatches":
    check_eval(guarded & "[((X ^n 1) ?~ msg) (nil ?~ msg) (void ?~ msg)]",
               "[\"x\" nil void]")
    check_eval(guarded & "[((X ^n 1) ?~ P:pm) (nil ?~ P:pm) (void ?~ P:pm)]",
               "[\"x-pm\" nil void]")
    check_eval(guarded & "[((X ^n 1) ?~ add 10) (nil ?~ add 10)]", "[11 nil]")

  test "absence is decided before the message name, but never hides a typo":
    # An absent receiver short-circuits an unknown message too — the guard is
    # about the receiver. A *present* receiver still reports the bad name.
    check_eval(guarded & "(nil ?~ no_such_message)", "nil")
    check_eval(guarded &
               "(try ((X ^n 1) ?~ no_such_message) " &
               " catch (MessageError ^message m) m)",
               "\"no message 'no_such_message' on X\"")

  test "a guarded send evaluates its receiver once and skips arguments":
    check_eval(guarded &
               "(var hits ($cell 0)) " &
               "(fn bump [] (hits ~ update (fn [n] (+ n 1))) 1) " &
               "(var a (nil ?~ add (bump))) " &
               "(var b ((X ^n 1) ?~ add (bump))) " &
               "[a b (hits ~ get)]",
               "[nil 2 1]")
    check_eval(guarded &
               "(var seen ($cell 0)) " &
               "(fn recv [] (seen ~ update (fn [n] (+ n 1))) nil) " &
               "[((recv) ?~ msg) (seen ~ get)]",
               "[nil 1]")

  test "?~ does not change what plain ~ means for nil":
    # docs/core.md §10: Nil is an ordinary nominal type with no dispatch
    # carve-out, so a bare send still fails and an explicit impl still wins.
    check_eval(guarded &
               "(try (nil ~ msg) catch (MessageError ^message m) m)",
               "\"no message 'msg' on Nil\"")
    # And the two spellings stay distinguishable even then: `~` dispatches to
    # the Nil impl, `?~` short-circuits before any lookup. The guard is a
    # call-site statement that this send tolerates absence — not a lookup that
    # sometimes finds nil's impl and sometimes does not.
    check_eval("(protocol P (message pm [] : Str)) " &
               "(impl P for Nil (message pm [] : Str \"nil-pm\")) " &
               "[(nil ~ P:pm) (nil ?~ P:pm)]",
               "[\"nil-pm\" nil]")

  test "every ~ callee form guards identically":
    # The lowering is shared, so each spelling must guard the same way:
    # held message values, computed callees, Self:m, and the leading self-send.
    check_eval(guarded & "(var m P:pm) [((X ^n 1) ?~ %m) (nil ?~ %m)]",
               "[\"x-pm\" nil]")
    check_eval(guarded &
               "(fn pick [] P:pm) [((X ^n 1) ?~ (pick)) (nil ?~ (pick))]",
               "[\"x-pm\" nil]")
    check_eval(guarded & "[((X ^n 1) ?~ Self:msg) (nil ?~ Self:msg)]",
               "[\"x\" nil]")
    # Leading `(?~ m)` is the guarded self-send. It is observable inside an
    # `impl P for Nil` body, where lexical self is itself absent.
    check_eval("(type L ^props {} (message a [] : Int 7) " &
               "  (message b [] : Int (?~ a))) ((L) ~ b)",
               "7")
    check_eval("(protocol P (message pm [] : Str)) " &
               "(impl P for Nil (message pm [] : Str ($to_str (?~ missing)))) " &
               "(nil ~ P:pm)",
               "\"nil\"")

  test "named arguments and spreads are skipped when the receiver is absent":
    check_eval(guarded &
               "(type Y ^props {} (message k [a, ^b : Int = 0] : Int (+ a b))) " &
               "(var hits ($cell 0)) " &
               "(fn bump [] (hits ~ update (fn [n] (+ n 1))) 5) " &
               "[((Y) ?~ k 1 ^b (bump)) (nil ?~ k 1 ^b (bump)) (hits ~ get)]",
               "[6 nil 1]")
    check_eval(guarded &
               "(type Z ^props {} (message sum [xs...] : Int ($size xs))) " &
               "(var args [1 2 3]) " &
               "[((Z) ?~ sum args...) (nil ?~ sum args...)]",
               "[3 nil]")

  test "?~ is rejected where a receiver cannot be absent or is not a send":
    check_compile_error(
      "(type A ^props {} (message m [] : Int 1)) " &
      "(type B ^is A ^props {} (message m [] : Int (super ?~ m)))",
      "super is never absent")
    check_compile_error("(var x {^a 1}) (x ?~ /a)", "projection")

suite "spec — protocol intersection types":
  # `(& P Q ...)` requires every operand. Single inheritance makes an
  # intersection of *types* uninhabitable, so operands must be protocols.
  const protos =
    "(protocol Shown (message show [] : Str)) " &
    "(protocol Sized (message sz [] : Int)) " &
    "(type Both ^props {}) (type OnlyShown ^props {}) (type Dog ^props {}) " &
    "(impl Shown for Both (message show [] : Str \"b\")) " &
    "(impl Sized for Both (message sz [] : Int 1)) " &
    "(impl Shown for OnlyShown (message show [] : Str \"o\")) "

  test "an intersection requires every operand":
    check_eval(protos & "((fn [a : (& Shown Sized)] \"ok\") (Both))", "\"ok\"")
    check_eval(protos &
               "(try ((fn [a : (& Shown Sized)] \"ok\") (OnlyShown)) " &
               " catch (TypeError ^expected e) e)",
               "\"(& Shown Sized)\"")

  test "intersections compose inside containers and props":
    check_eval(protos &
               "((fn [xs : (List (& Shown Sized))] ($size xs)) [(Both)])", "1")
    check_eval(protos & "(type Box ^props {^item (& Shown Sized)}) " &
               "(var b (Box ^item (Both))) (var it b/item) " &
               "(it ~ Shown:show)", "\"b\"")
    check_eval(protos & "(type Box2 ^props {^item (& Shown Sized)}) " &
               "(try (Box2 ^item (OnlyShown)) catch (TypeError ^where w) w)",
               "\"field 'item' for Box2\"")
    check_eval(protos & "((fn [a : (| Int (& Shown Sized))] \"ok\") (Both))",
               "\"ok\"")

  test "operand order is insignificant at every comparison site":
    # Matching, the stored type of an invariant container, and a callable
    # signature all go through one canonical form, so no site can disagree.
    check_eval(protos & "((fn [a : (& Sized Shown)] \"ok\") (Both))", "\"ok\"")
    check_eval(protos &
               "(fn keep [c : (Cell (& Shown Sized))] c) " &
               "(fn same [c : (Cell (& Sized Shown))] c) " &
               "(((same (keep ($cell (Both)))) ~ get) ~ Shown:show)",
               "\"b\"")
    check_eval(protos &
               "(protocol Q (message m [v : (& Shown Sized)] : Str)) " &
               "(impl Q for Both (message m [v : (& Sized Shown)] : Str \"q\")) " &
               "((Both) ~ Q:m (Both))",
               "\"q\"")

  test "union signatures are order-insensitive too (shared canonical form)":
    # Regression guard: this failed before intersection work introduced the
    # shared `typeExprEquivalent` seam, and it proves the seam reaches
    # signature comparison rather than only boundary closure.
    check_eval("(protocol A) (protocol B) (type X ^props {}) " &
               "(impl A for X) " &
               "(protocol P (message m [v : (| A B)] : Str)) " &
               "(impl P for X (message m [v : (| B A)] : Str \"ok\")) " &
               "((X) ~ P:m (X))",
               "\"ok\"")

  test "operands must be resolved protocols, checked on use not definition":
    # Annotations resolve lazily, so an unused invalid intersection still
    # loads — the same latitude that makes forward references work.
    check_eval(protos & "(fn never [a : (& Shown Dog)] a) \"loaded\"",
               "\"loaded\"")
    check_runtime_error(protos & "((fn [a : (& Shown Dog)] a) (Both))",
                        "intersection of types is uninhabitable")
    check_runtime_error(protos & "((fn [a : (& Shown)] a) (Both))",
                        "requires at least two protocols")
    check_runtime_error(protos &
                        "((fn (g item) [a : (& item Shown)] a) (Both))",
                        "type parameters cannot carry protocol constraints")

  test "intersections honor protocol inheritance and receiver ancestry":
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(protocol Sized (message sz [] : Int)) " &
               "(type Parent ^props {}) (type Child ^is Parent ^props {}) " &
               "(impl Shown for Parent (message show [] : Str \"p\")) " &
               "(impl Sized for Parent (message sz [] : Int 1)) " &
               "((fn [a : (& Shown Sized)] \"ok\") (Child))",
               "\"ok\"")
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(protocol Sized (message sz [] : Int)) " &
               "(protocol SubShown ^inherit [Shown] (message extra [] : Int)) " &
               "(type Q ^props {}) " &
               "(impl SubShown for Q (message show [] : Str \"q\") " &
               "  (message extra [] : Int 2)) " &
               "(impl Sized for Q (message sz [] : Int 3)) " &
               "((fn [a : (& Shown Sized)] \"ok\") (Q))",
               "\"ok\"")

  test "forward-referenced protocols resolve inside an intersection":
    check_eval("(fn takes [a : (& Early Late)] \"ok\") " &
               "(protocol Early) (protocol Late) (type G ^props {}) " &
               "(impl Early for G) (impl Late for G) (takes (G))",
               "\"ok\"")

suite "spec — hidden impl diagnostics (docs/scoped-impls.md §4)":
  # A conformance failure must distinguish "no impl exists" from "an impl
  # exists but is not visible here", and must name the module whose scope
  # governs the check — importing anywhere else is a no-op.
  proc hintDir(): string =
    result = getTempDir() / "gene_spec_hidden_impls"
    removeDir(result)
    createDir(result)
    writeFile(result / "proto.gene",
      "(protocol Shown (message show [] : Str))\n" &
      "(type Widget ^props {})\n" &
      "(type Base ^props {})\n" &
      "(type Derived ^is Base ^props {})\n")
    writeFile(result / "provider.gene",
      "(import [Shown Widget] from \"./proto\")\n" &
      "(impl Shown for Widget ^export true (message show [] : Str \"w\"))\n")
    writeFile(result / "unexported.gene",
      "(import [Shown Base] from \"./proto\")\n" &
      "(impl Shown for Base (message show [] : Str \"b\"))\n")

  proc loadError(dir, name, source: string): string =
    writeFile(dir / name, source)
    let app = newApplication(dir)
    try:
      discard app.loadFileModule(dir / name)
      return ""
    except CatchableError as e:
      return e.msg

  test "an exported scoped impl names the module the import must land in":
    let dir = hintDir()
    let msg = loadError(dir, "main.gene",
      "(import [Shown Widget] from \"./proto\")\n" &
      "(import [] from \"./provider\")\n" &
      "(fn takes [a : Shown] \"ok\")\n" &
      "(takes (Widget))\n")
    check "import_impl Shown for Widget from" in msg
    check "provider.gene" in msg
    check "main.gene" in msg          # the checking module, not the impl's

  test "the named module is the annotation's, not the caller's":
    # The no-op trap: telling an application author to import into their own
    # module does nothing when the failing annotation belongs to a library.
    let dir = hintDir()
    writeFile(dir / "lib.gene",
      "(import [Shown Widget] from \"./proto\")\n" &
      "(fn lib_takes [a : Shown] \"ok\")\n")
    let msg = loadError(dir, "app.gene",
      "(import [Shown Widget] from \"./proto\")\n" &
      "(import [lib_takes] from \"./lib\")\n" &
      "(import [] from \"./provider\")\n" &
      "(lib_takes (Widget))\n")
    check "lib.gene" in msg
    check "app.gene" notin msg

  test "an unexported scoped impl advises export before import":
    let dir = hintDir()
    let msg = loadError(dir, "main.gene",
      "(import [Shown Base] from \"./proto\")\n" &
      "(import [] from \"./unexported\")\n" &
      "(fn takes [a : Shown] \"ok\")\n" &
      "(takes (Base))\n")
    check "^export true" in msg
    check "import_impl" notin msg

  test "a hidden impl found through ancestry names its own pair":
    # `import_impl` copies an exact pair, so advising the *queried* pair would
    # be a command that fails: the impl is for Base, the value is a Derived.
    let dir = hintDir()
    writeFile(dir / "baseprov.gene",
      "(import [Shown Base] from \"./proto\")\n" &
      "(impl Shown for Base ^export true (message show [] : Str \"b\"))\n")
    let msg = loadError(dir, "main.gene",
      "(import [Shown Base Derived] from \"./proto\")\n" &
      "(import [] from \"./baseprov\")\n" &
      "(fn takes [a : Shown] \"ok\")\n" &
      "(takes (Derived))\n")
    check "import_impl Shown for Base from" in msg
    check "for Derived" notin msg

  test "a qualified send gets the same advice":
    let dir = hintDir()
    let msg = loadError(dir, "main.gene",
      "(import [Shown Widget] from \"./proto\")\n" &
      "(import [] from \"./provider\")\n" &
      "((Widget) ~ Shown:show)\n")
    check "no implementation of message 'show'" in msg
    check "import_impl Shown for Widget from" in msg

  test "no hint when nothing is hidden":
    # The negative cases matter most: advice that fires when no impl exists
    # would be worse than today's bare message. Overlay impls are deliberately
    # unenumerable, so they stay silent too — pinned, not silently regressed.
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(type N ^props {}) (fn takes [a : Shown] \"ok\") " &
               "(try (takes (N)) catch (TypeError ^message m) m)",
               "\"parameter 'a' expected Shown, got (type N)\"")
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(type H ^props {}) (fn takes [a : Shown] \"ok\") " &
               "(fn hidden [] (impl Shown for H (message show [] : Str \"h\")) " &
               "  (takes (H))) " &
               "(try (hidden) catch (TypeError ^message m) m)",
               "\"parameter 'a' expected Shown, got (type H)\"")

suite "spec — protocol derive from design":
  test "protocol-local derive can generate an impl":
    check_eval("(protocol HasLabel " &
               "  (message label [self] : Str) " &
               "  (derive [t : Type, req] " &
               "    `(impl HasLabel for %t " &
               "       (message label [self] : Str self/name)))) " &
               "(type MenuItem ^props {^name Str} ^derive [HasLabel]) " &
               "((MenuItem ^name \"Soup\") ~ HasLabel:label)",
               "\"Soup\"")

  test "derive may target another protocol but only the deriving type":
    # Cross-protocol generation (the Delegate case) is allowed.
    check_eval("(protocol Other) " &
               "(protocol HasLabel " &
               "  (derive [t : Type, req] `(impl Other for %t))) " &
               "(type MenuItem ^props {^name Str} ^derive [HasLabel]) " &
               "\"ok\"", "\"ok\"")
    # A generated impl whose receiver is not the deriving type is rejected.
    expect GeneError:
      discard run(compileSource("(protocol Other) " &
                                "(type Elsewhere ^props {}) " &
                                "(protocol HasLabel " &
                                "  (derive [t : Type, req] " &
                                "    `(impl Other for Elsewhere))) " &
                                "(type MenuItem ^props {^name Str} " &
                                "  ^derive [HasLabel])"),
                  newGlobalScope())

suite "spec — binding forms from design §12.1":
  test "let binds a fixed value; var is rebindable":
    check_eval("(let x 10) (var y 1) (set y 2) [x y]", "[10 2]")

  test "set on a let binding is a compile error":
    check_compile_error("(let x 10) (set x 20)",
                        "cannot set 'x'")

  test "set rejects extra arguments instead of silently discarding them":
    check_compile_error("(var x 1) (set x 2 3)",
                        "set requires exactly a name and a value")
    # Both spellings of a path target point at `set!`. The glued form is what
    # people actually type, and it used to fall through to the arity message
    # because the check looked at `body[1]` while the target is `body[0]`.
    check_compile_error("(var x {^n 1}) (set x /n 2)", "use set! for property")
    check_compile_error("(var x {^n 1}) (set x/n 2)", "use set! for property")

  test "set! assigns in place through a path":
    # design §12.1. `set` rebinds a lexical binding and never mutates; `set!` is
    # the explicitly mutating spelling, bang-named like set_prop!/put!/push!.
    check_eval("(type T ^props {^n Int}) (var t (T ^n 1)) (set! t/n 2) t/n", "2")
    check_eval("(var xs [1 2 3]) (set! xs/0 9) xs", "[9 2 3]")
    check_eval("(var m {^a 1}) (set! m/a 2) m", "{^a 2}")
    check_eval("(var xs [1 2 3]) (set! xs/-1 9) xs", "[1 2 9]")
    # Only the final container is mutated; intermediates resolve read-only.
    check_eval("(type T ^props {^n Int}) (type O ^props {^inner T}) " &
               "(var o (O ^inner (T ^n 1))) (set! o/inner/n 5) o/inner/n", "5")
    # It returns the stored value, which is the adapted one at a boundary.
    check_eval("(type T ^props {^n Int}) (var t (T ^n 1)) (set! t/n 7)", "7")

  test "set! is checked by the same rules as construction":
    # The point of routing every write through one seam: the closed schema and
    # the field types hold for assignment exactly as they do for construction.
    check_eval("(type T ^props {^n Int}) (var t (T ^n 1)) " &
               "[(try (set! t/n \"bad\") catch (TypeError ^message m) m) t/n]",
               "[\"field 'n' for T expected Int, got Str\" 1]")
    check_runtime_error("(type T ^props {^n Int}) (var t (T ^n 1)) " &
                        "(set! t/bogus 1)", "T has no field 'bogus'")
    check_runtime_error("(type T ^props {^n Int}) (var f #(T ^n 1)) " &
                        "(set! f/n 2)", "cannot mutate immutable Node")
    # A typed *body* position had no in-place writer at all before `set!`, so
    # it is the case that would have reintroduced unchecked writes.
    check_eval("(type B ^props {^n Int} ^body [Str...]) " &
               "(var b (B ^n 1 \"a\")) (set! b/0 \"z\") b",
               "((type B) ^n 1 \"z\")")
    check_runtime_error("(type B ^props {^n Int} ^body [Str...]) " &
                        "(var b (B ^n 1 \"a\")) (set! b/0 42)",
                        "body field 0 for B expected Str")

  test "set! path segments are keys, never applied":
    # Ordinary selector evaluation *applies* a callable segment; that is
    # incoherent as an assignment target, so `set!` takes keys only.
    check_eval("(type T ^props {^n Int}) (var t (T ^n 1)) " &
               "(var k `n) (set! t/%k 7) t/n", "7")
    check_runtime_error("(type T ^props {^n Int}) (var t (T ^n 1)) " &
                        "(fn f [x] x) (set! t/%f 1)",
                        "set! path segment must be a Sym, Str, or Int")
    check_compile_error("(var t {^n 1}) (set! t/~size 1)",
                        "cannot assign through a message segment")

  test "set! rejects the virtual Node projections":
    # `head`/`props`/`body`/`meta` are detached copies (design §1.3), so
    # assigning through one would silently write to a temporary.
    check_runtime_error("(var n (quote (u ^a 1 \"x\"))) (set! n/body/0 \"z\")",
                        "cannot assign through a Node projection")
    # A real prop of that name keeps ordinary prop precedence and is assignable.
    check_eval("(type P ^props {^body Str}) (var p (P ^body \"ok\")) " &
               "(set! p/body \"new\") p/body",
               "\"new\"")

  test "set! may populate self during construction":
    # A ctor can fill fields incrementally; the completed instance is still
    # validated atomically at publication. The negative case — a ctor that
    # leaves a required field unset — is NOT asserted here: a ctor whose
    # validation raises corrupts the heap, which reproduces on an unmodified
    # build with `set_prop!` and no `set!` at all. Recorded as its own defect.
    check_eval("(type C ^props {^x Int} (ctor [v : Int] (set! self/x v))) " &
               "(var c (new C 5)) c/x",
               "5")

  test "set! requires a path and exactly two operands":
    check_compile_error("(set! x 1)", "set! requires a path; use set to rebind")
    check_compile_error("(var t {^n 1}) (set! t/n)",
                        "set! requires exactly a path and a value")
    check_compile_error("(var t {^n 1}) (set! t/n 1 2)",
                        "set! requires exactly a path and a value")

  test "let destructuring names are immutable":
    check_compile_error("(let [a b] [1 2]) (set a 9)",
                        "cannot set 'a'")

  test "const is reserved but not yet implemented":
    check_compile_error("(const K 10)", "const is reserved")

  test "an inner var shadows an outer let without freezing it":
    check_eval("(let x 1) " &
               "(fn f [] (var x 2) (set x 3) x) " &
               "[(f) x]",
               "[3 1]")

  test "an inner let over an outer var is immutable in that scope":
    check_compile_error("(var x 1) (fn f [] (let x 2) (set x 3) x)",
                        "cannot set 'x'")

  test "a function parameter shadowing an outer let stays rebindable":
    check_eval("(let y 5) (fn g [y] (set y (+ y 1)) y) [(g 10) y]", "[11 5]")

  test "a match-arm binding shadowing an outer let stays rebindable":
    check_eval("(let z 1) " &
               "[(match [7] (when [z] (do (set z (+ z 1)) z))) z]",
               "[8 1]")

  test "typed let checks its value at the boundary":
    check_eval("(let n : Int 5) (+ n 1)", "6")

  test "named declarations are immutable bindings":
    check_compile_error("(fn f [] 1) (set f 2)", "cannot set 'f'")
    check_compile_error("(type T ^props {}) (set T 2)",
                        "cannot set 'T'")
    check_compile_error("(ns n (let x 1)) (set n 2)",
                        "cannot set 'n'")
    check_compile_error("(protocol P) (set P 2)",
                        "cannot set 'P'")
    check_compile_error("(enum E a b) (set E 2)",
                        "cannot set 'E'")

  test "the send operator ~ is reserved and cannot be bound":
    check_compile_error("(var ~ 5)", "reserved")
    check_compile_error("(let ~ 5)", "reserved")
    # still tokenizes inside quoted data
    check_eval("(quote (a ~ b))", "(a ~ b)")

suite "spec — cells from design":
  test "Cell get, set, swap, and update are explicit mutation":
    check_eval("(var count ($cell 0)) " &
               "[(count ~ get) " &
               " (count ~ set 10) " &
               " (count ~ swap 20) " &
               " (count ~ update (fn [x] (+ x 1))) " &
               " (count ~ get)]",
               "[0 10 10 21 21]")

  test "typed cells retain and enforce their value type":
    check_eval("(var count : (Cell Int) ($cell 1)) " &
               "[(count ~ set 2) " &
               " (try (count ~ swap \"bad\") " &
               "  catch (TypeError ^where where) where) " &
               " (try (count ~ update (fn [n] \"bad\")) " &
               "  catch (TypeError ^where where) where) " &
               " (count ~ get)]",
               "[2 \"Cell/swap value\" \"Cell/update result\" 2]")
    check_eval("(try (do (var count : (Cell Int) ($cell \"bad\")) count) " &
               " catch (TypeError ^expected expected) expected)",
               "\"(Cell Int)\"")

  test "typed cell writes use the captured protocol visibility scope":
    check_eval("(protocol Tagged) " &
               "(type Good ^props {}) (type Bad ^props {}) " &
               "(impl Tagged for Good) " &
               "(fn capture [cell : (Cell Tagged)] cell) " &
               "(var item (capture ($cell (Good)))) " &
               "[((item ~ set (Good)) ~ head; ~ name) " &
               " (try (item ~ set (Bad)) " &
               "  catch (TypeError ^where where) where) " &
               " ((item ~ get) ~ head; ~ name)]",
               "[\"Good\" \"Cell/set value\" \"Good\"]")

  test "typed cell aliases retain the write invariant":
    check_eval("(alias IntCell (Cell Int)) " &
               "(var count : IntCell ($cell 1)) " &
               "[(try (count ~ set \"bad\") " &
               "  catch (TypeError ^where where) where) (count ~ get)]",
               "[\"Cell/set value\" 1]")

  test "typed cells retain their invariant inside container boundaries":
    check_eval("(var counts : (List (Cell Int)) [($cell 1)]) " &
               "[(try (counts/0 ~ set \"bad\") " &
               "  catch (TypeError ^where where) where) (counts/0 ~ get)]",
               "[\"Cell/set value\" 1]")

  test "typed cell mismatches report their retained invariant":
    check_eval("(var item ($cell 1)) " &
               "(fn admit_any [cell : (Cell Any)] cell) " &
               "(fn require_int [cell : (Cell Int)] cell) " &
               "(admit_any item) " &
               "(try (require_int item) " &
               " catch (TypeError ^actual actual ^message message) " &
               "   [actual message])",
               "[\"(Cell Any)\" " &
               "\"parameter 'cell' expected (Cell Int), got (Cell Any); " &
               "Cell value types are invariant\"]")

suite "spec — atomic cells from design":
  test "AtomicCell load, store, swap, and compare_exchange are explicit mutation":
    check_eval("(var state ($atomic_cell 0)) " &
               "[(state ~ load) " &
               " (state ~ store 1) " &
               " (state ~ swap 2) " &
               " (state ~ compare_exchange 2 3) " &
               " (state ~ load)]",
               "[0 1 1 true 3]")

suite "spec — mutable containers from design":
  test "persistent and mutating container updates are explicit":
    check_eval("(var xs #[1 2 3]) " &
               "(var xs2 (xs ~ assoc 1 20)) " &
               "(var ys [1 2]) " &
               "(ys ~ set! 0 9) " &
               "(var zs []) " &
               "(var pushed (zs ~ push! void)) " &
               "(var m #{^a 1}) " &
               "(var m2 (m ~ assoc \"b\" 2)) " &
               "(var mm {^a 1}) " &
               "(mm ~ put! \"b\" 3) " &
               "(var n (quote (user ^name \"Ada\"))) " &
               "(n ~ set_prop! \"name\" \"Bob\") " &
               "[xs xs2 ys pushed zs m m2 (mm ~ get \"b\") (n ~ /name)]",
               "[#[1 2 3] #[1 20 3] [9 2] nil [nil] #{^a 1} #{^a 1 ^b 2} 3 \"Bob\"]")

  test "List/push! rejects immutable lists":
    check_eval("(try (#[1] ~ push! 2) " &
               " catch (Error ^message message) message)",
               "\"cannot mutate immutable List\"")

  test "built-in operations are type-direct messages (unqualified and path)":
    # `(x ~ get)` is also reachable as `(x ~ get)` / `x/~get`.
    check_eval("(var c ($cell 7)) (c ~ set 20) [(c ~ get) c/~get]", "[20 20]")
    check_eval("(var xs [1 2 3]) (xs ~ set! 0 9) (xs ~ push! 4) xs",
               "[9 2 3 4]")
    check_eval("(var m {^a 1}) (m ~ put! \"b\" 2) (m ~ get \"b\")", "2")
    check_eval("(var n (quote (user ^name \"Ada\"))) " &
               "(n ~ set_prop! \"name\" \"Bob\") (n ~ /name)",
               "\"Bob\"")

  test "built-in sends use the unqualified form":
    check_eval("(var c ($cell 1)) (c ~ set 5) (c ~ get)", "5")

  test "pipeline operations are messages: to_stream on iterables, map/filter/take/into on streams":
    check_eval("(var xs [1 2 3 4 5]) " &
               "((((xs ~ to_stream) ~ filter (fn [x] (> x 2))) " &
               "  ~ map (fn [x] (* x 10))) ~ into [])",
               "[30 40 50]")
    check_eval("((($range 0 3) ~ to_stream) ~ into [])", "[0 1 2]")
    check_eval("(var m {^a 1 ^b 2}) ((m ~ to_pairs_stream) ~ into [])",
               "[[a 1] [b 2]]")
    # `each` lives only in gene/stream, the rest are reachable directly from the
    # library root — both tiers resolve through `gene`, never the bare surface.
    check_eval("(var acc ($cell 0)) " &
               "(([1 2 3] ~ to_stream) ~ each (fn [x] (acc ~ set (+ (acc ~ get) x)))) " &
               "(acc ~ get)",
               "6")

  test "the Node accessors are messages on a node receiver":
    check_eval("(var n (quote (foo ^a 1 \"x\"))) " &
               "[(n ~ head) (n ~ props) (n ~ body) (n ~ meta)]",
               "[foo {^a 1} [\"x\"] {}]")

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
    check_eval("(var s ($to_stream [1 2])) " &
               "[(s ~ has_next) " &
               " (s ~ peek) " &
               " (s ~ next) " &
               " (s ~ next) " &
               " (s ~ has_next)]",
               "[true 1 1 2 false]")

  test "next on an exhausted stream raises EndOfStream":
    check_eval("(try (var s ($to_stream [])) (s ~ next) " &
               "catch (EndOfStream ^message m) m)",
               "\"end of stream\"")

  test "has_next surfaces producer errors without EndOfStream":
    check_eval("(try " &
               "  (var s ($map ($to_stream [1]) (fn [x] (/ 1 0)))) " &
               "  (s ~ has_next) " &
               "catch {^message m} m)",
               "\"division by zero\"")

  test "stream helpers map, filter, take, and materialize":
    check_eval("(var s ($take " &
               "  ($filter " &
               "    ($map ($to_stream [1 2 3]) (fn [x] (+ x 1))) " &
               "    (fn [x] (> x 2))) " &
               "  2)) " &
               "[(s ~ next) " &
               " (s ~ next) " &
               " (s ~ has_next) " &
               " (do (var pairs ($to_pairs_stream {^a 1})) " &
               "     (pairs ~ next)) " &
               " ($into ($to_pairs_stream {^a 1}) {})]",
               "[3 4 false [a 1] {^a 1}]")
    check_eval("(var pairs ($to_pairs_stream {^a 1})) " &
               "(var pair (pairs ~ next)) " &
               "(fn key [x : Sym] x) (key pair/0)",
               "a")

  test "closing downstream stream helpers closes upstream":
    check_eval("(var source ($to_stream [1 2])) " &
               "(var s ($map source (fn [x] x))) " &
               "(s ~ close) " &
               "(source ~ has_next)",
               "false")
    check_eval("(var hits ($cell 0)) " &
               "(var source ($map ($to_stream [1 2]) " &
               "  (fn [x] (hits ~ update (fn [n] (+ n 1))) x))) " &
               "(var s ($take source 1)) " &
               "[(s ~ next) " &
               " (s ~ has_next) " &
               " (hits ~ get) " &
               " (source ~ has_next)]",
               "[1 false 1 true]")

  test "lazy streams own inline callables beyond the defining frame":
    # Regression: the stream must hold its callable strongly. An inline
    # lambda whose only other reference was the operand stack used to leave
    # the stream with a dangling weak captured-scope edge (use-after-free).
    check_eval("(fn make-pred [] (fn [x] (> x 1))) " &
               "(fn make-stream [] ($filter ($to_stream [1 2 3]) (make-pred))) " &
               "($into (make-stream) [])",
               "[2 3]")
    check_eval("(fn make-stream [] ($map ($to_stream [1 2]) (fn [x] (+ x 10)))) " &
               "($into (make-stream) [])",
               "[11 12]")

  test "stream helpers are lazy":
    check_eval("(var hits ($cell 0)) " &
               "(var s ($map ($to_stream [1 2]) " &
               "            (fn [x] (hits ~ update (fn [n] (+ n 1))) x))) " &
               "[(hits ~ get) " &
               " (s ~ next) " &
               " (hits ~ get)]",
               "[0 1 1]")

  test "yield functions return lazy streams":
    check_eval("(var hits ($cell 0)) " &
               "(fn gen [] : (Stream Int Never) " &
               "  (hits ~ set 1) " &
               "  (yield 10) " &
               "  (hits ~ set 2) " &
               "  (yield 20)) " &
               "(var s (gen)) " &
               "[(hits ~ get) " &
               " (s ~ next) " &
               " (hits ~ get) " &
               " (s ~ next) " &
               " (hits ~ get) " &
               " (s ~ has_next)]",
               "[0 10 1 20 2 false]")

  test "yield skips void and resumes while loops":
    check_eval("(fn nums [] : (Stream Int Never) " &
               "  (var i 0) " &
               "  (while (< i 3) " &
               "    (yield (if (== i 1) void i)) " &
               "    (set i (+ i 1)))) " &
               "(var s (nums)) " &
               "[(s ~ next) " &
               " (s ~ next) " &
               " (s ~ has_next)]",
               "[0 2 false]")

  test "yield resumes for loops lazily":
    check_eval("(var hits ($cell 0)) " &
               "(var source ($map ($to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ update (fn [n] (+ n 1))) x))) " &
               "(fn copy [s] : (Stream Int Never) " &
               "  (for x in s (yield x))) " &
               "(var out (copy source)) " &
               "[(hits ~ get) " &
               " (out ~ next) " &
               " (hits ~ get) " &
               " (out ~ next) " &
               " (hits ~ get)]",
               "[0 1 1 2 2]")
    check_eval("(var hits ($cell 0)) " &
               "(var source ($map ($to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ update (fn [n] (+ n 1))) x))) " &
               "(fn take-one [s] : (Stream Int Never) " &
               "  (for x in s " &
               "    (if (== x 2) (then (break))) " &
               "    (yield x))) " &
               "(var out (take-one source)) " &
               "[(out ~ next) " &
               " (out ~ has_next) " &
               " (hits ~ get) " &
               " (source ~ has_next)]",
               "[1 false 2 false]")

  test "typed stream boundaries check items when pulled":
    check_eval("(try (fn first [s : (Stream Int Never)] (s ~ next)) " &
               "     (first ($to_stream [\"bad\"])) " &
               "catch (TypeError ^where w) w)",
               "\"Stream/next item\"")
    check_eval("(try (fn bad [] : (Stream Int Never) (yield \"bad\")) " &
               "     (var s (bad)) " &
               "     (s ~ next) " &
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
               "[(s ~ next) " &
               " (s ~ next) " &
               " (s ~ has_next)]",
               "[1 2 false]")

  test "natural fall-through closes the generator with no item remaining":
    check_eval("(fn two [] : (Stream Int Never) " &
               "  (yield 1) " &
               "  (yield 2)) " &
               "(var s (two)) " &
               "[(s ~ next) " &
               " (s ~ next) " &
               " (s ~ has_next)]",
               "[1 2 false]")

  test "Stream/close after natural take exhaustion stays local":
    check_eval("(var upstream ($to_stream [1 2 3 4 5])) " &
               "(var taken ($take upstream 2)) " &
               "[(taken ~ next) " &
               " (taken ~ next) " &
               " (taken ~ has_next) " &
               " (upstream ~ has_next) " &
               " (do (taken ~ close) " &
               "     (upstream ~ next))]",
               "[1 2 false true 3]")
    check_eval("(var closes ($cell 0)) " &
               "(fn source [] : (Stream Int Never) " &
               "  (try (yield 1) (yield 2) " &
               "   ensure (closes ~ update (fn [n] (+ n 1))))) " &
               "(var upstream (source)) " &
               "(for x in ($take upstream 2) (break)) " &
               "[(closes ~ get) (upstream ~ has_next)]",
               "[1 false]")

  test "generator return is terminal and close unwinds ensure blocks":
    check_eval("(fn choose [yes] " &
               "  (if yes (then (return 7))) " &
               "  9) " &
               "[(choose true) (choose false)]",
               "[7 9]")
    check_eval("(var log ($cell [])) " &
               "(fn note [x] (log ~ update (fn [xs] [xs... x]))) " &
               "(fn gen [] : (Stream Int Never) " &
               "  (try " &
               "    (try (yield 1) (return) " &
               "     ensure (note `inner)) " &
               "   ensure (note `outer))) " &
               "(var completed (gen)) " &
               "(completed ~ next) " &
               "(var done (completed ~ has_next)) " &
               "(var closed (gen)) " &
               "(closed ~ next) " &
               "(closed ~ close) " &
               "[done (log ~ get)]",
               "[false [inner outer inner outer]]")
    expect GeneError:
      discard compileSource("(fn bad [] : (Stream Int Never) " &
                            "  (yield 1) (return 2))")
    expect GeneError:
      discard compileSource("(return 1)")

  test "producer errors are terminal and close upstream":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var calls ($cell 0)) " &
               "(var closes ($cell 0)) " &
               "(fn source [] : (Stream Int Never) " &
               "  (try (yield 1) " &
               "   ensure (closes ~ update (fn [n] (+ n 1))))) " &
               "(var s ($map (source) " &
               "  (fn [x] (calls ~ update (fn [n] (+ n 1))) " &
               "          (fail (Boom ^message \"boom\"))))) " &
               "(var first (try (s ~ next) " &
               "  catch (Boom ^message m) m)) " &
               "[first (s ~ has_next) " &
               " (try (s ~ next) " &
               "  catch (EndOfStream ^message m) m) " &
               " (calls ~ get) (closes ~ get)]",
               "[\"boom\" false \"end of stream\" 1 1]")
    check_eval("(type GenBoom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for GenBoom) " &
               "(var runs ($cell 0)) " &
               "(fn bad ^errors [GenBoom] [] : (Stream Int GenBoom) " &
               "  (yield 1) " &
               "  (runs ~ update (fn [n] (+ n 1))) " &
               "  (fail (GenBoom ^message \"generator failed\"))) " &
               "(var s (bad)) " &
               "(var first (s ~ next)) " &
               "(var message (try (s ~ has_next) " &
               "  catch (GenBoom ^message m) m)) " &
               "[first message (s ~ has_next) " &
               " (try (s ~ peek) " &
               "  catch (EndOfStream ^message m) m) " &
               " (runs ~ get)]",
               "[1 \"generator failed\" false \"end of stream\" 1]")

  test "has_next on an empty stream returns false without raising":
    check_eval("(var s ($to_stream [])) (s ~ has_next)", "false")

  test "Stream/close is idempotent":
    check_eval("(var s ($to_stream [1])) " &
               "  (do " &
               "    (s ~ close) " &
               "    (s ~ close))",
               "nil")

  test "Stream/try_next returns exhausted when empty":
    check_eval("(var s ($to_stream [])) " &
               "(match (s ~ try_next) " &
               "  (when TryNext/exhausted true) " &
               "  (when (TryNext/value _) false) " &
               "  (when (TryNext/error _) false))",
               "true")

  test "Stream/try_next returns value for each item then exhausted":
    check_eval("(var s ($to_stream [1 2])) " &
               "[(match (s ~ try_next) " &
               "    (when (TryNext/value v) v) " &
               "    (when TryNext/exhausted 0)) " &
               " (match (s ~ try_next) " &
               "    (when (TryNext/value v) v) " &
               "    (when TryNext/exhausted 0)) " &
               " (match (s ~ try_next) " &
               "    (when (TryNext/value v) v) " &
               "    (when TryNext/exhausted 0))]",
               "[1 2 0]")

  test "Stream/try_next preserves nil as a distinct value":
    check_eval("(var s ($to_stream [nil 9])) " &
               "[(match (s ~ try_next) " &
               "    (when (TryNext/value v) v) " &
               "    (when TryNext/exhausted `empty)) " &
               " (match (s ~ try_next) " &
               "    (when (TryNext/value v) v) " &
               "    (when TryNext/exhausted `empty))]",
               "[nil 9]")

  test "Stream/try_next returns error for producer errors":
    check_eval("(var s ($map ($to_stream [1]) (fn [x] (/ x 0)))) " &
               "(match (s ~ try_next) " &
               "  (when (TryNext/error e) true) " &
               "  (when (TryNext/value _) false) " &
               "  (when TryNext/exhausted false))",
               "true")

  test "Stream/try_next returns exhausted after a producer error":
    check_eval("(var s ($map ($to_stream [1]) (fn [x] (/ x 0)))) " &
               "[(match (s ~ try_next) " &
               "    (when (TryNext/error _) true) " &
               "    (when (TryNext/value _) false) " &
               "    (when TryNext/exhausted false)) " &
               " (match (s ~ try_next) " &
               "    (when TryNext/exhausted true) " &
               "    (when (TryNext/value _) false) " &
               "    (when (TryNext/error _) false))]",
               "[true true]")

  test "TryNext can be used as an annotation type":
    check_eval("(fn next_or [s : Stream] : (TryNext Int Error) " &
               "  (s ~ try_next)) " &
               "(match (next_or ($to_stream [42])) " &
               "  (when (TryNext/value v) v) " &
               "  (when TryNext/exhausted 0))",
               "42")

  test "selectors map static lookup over stream items":
    check_eval("(var users [{^name \"Ada\"} {^age 37} {^name \"Bob\"}]) " &
               "(var names users/%$to_stream/name) " &
               "[(names ~ next) " &
               " (names ~ next) " &
               " (names ~ has_next)]",
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
               "(var names ((select %$to_stream %($filter /adult) name) users)) " &
               "[(names ~ next) " &
               " (names ~ next) " &
               " (names ~ has_next)]",
               "[\"Ada\" \"Bob\" false]")
    check_eval("(var users [{^name \"Ada\"} {^name \"Bob\"} {^name \"Cy\"}]) " &
               "((select %$to_stream %($map /name) %($take 2) %($into [])) users)",
               "[\"Ada\" \"Bob\"]")

  test "selector key wrappers force dynamic key lookup":
    check_eval("(var field \"name\") " &
               "(var get-name (select %($key field))) " &
               "(get-name {^name \"Ada\"})",
               "\"Ada\"")
    check_eval("(var plus +) " &
               "[((select %plus) 4) ((select %($key plus)) 4)]",
               "[4 void]")

  test "declarations is an ordinary stream selector stage":
    check_eval("(ns m (var b 2) (var a 1)) " &
               "(var names m/%$declarations/name) " &
               "[(names ~ next) " &
               " (names ~ next) " &
               " (names ~ has_next)]",
               "[\"a\" \"b\" false]")

  test "declaration records expose source @meta through %$meta":
    check_eval("(ns m (fn home [] @doc \"hi\" 1) (var x 2)) " &
               "(var d (($filter m/%$declarations (fn [d] (== d/name \"home\"))) " &
               "        ~ next)) " &
               "(var v (($filter m/%$declarations (fn [d] (== d/name \"x\"))) " &
               "        ~ next)) " &
               "[d/%$meta/doc d/kind (== v/%$meta/doc void)]",
               "[\"hi\" \"Fn\" true]")

  test "this_mod exposes the current module declaration stream":
    let scope = newGlobalScope()
    discard bindThisModule(scope, "spec")
    check run(compileSource("(var x 9) " &
                            "(var ds ($filter (this_mod ~ declarations) " &
                            "  (fn [d] (== d/name \"x\")))) " &
                            "(var decl (ds ~ next)) " &
                            "[(/value decl) (this_mod ~ path)]"),
              scope).print() == "[9 nil]"

suite "spec — structured tasks from design":
  test "scope owns spawned tasks and await returns the result":
    check_eval("(scope " &
               "  (var a (spawn (+ 1 2))) " &
               "  (var b (spawn (+ 3 4))) " &
               "  (+ (await a) (await b)))",
               "10")

  test "spawn queues child work and CPU tasks yield at safepoints":
    check_eval("(scope (var out ($cell 0)) " &
               "  (var slow (spawn (do " &
               "    (var i 0) " &
               "    (while (< i 5000) (set i (+ i 1))) " &
               "    (out ~ set 1)))) " &
               "  (var fast (spawn (out ~ set 2))) " &
               "  (await fast) " &
               "  [(out ~ get) (await slow) (out ~ get)])",
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
    check_eval("(scope (var c ($cell 0)) " &
               "  (var t (spawn (c ~ get))) " &
               "  (c ~ set 2) " &
               "  (await t))",
               "2")
    check_eval("(scope (var x 41) " &
               "  (var t (spawn (fn [] (+ x 1)))) " &
               "  ((await t)))",
               "42")

  test "timer waits suspend only the current task":
    check_eval("(scope (var out ($cell 0)) " &
               "  (var slow (spawn (do ($sleep 5) (out ~ set 1)))) " &
               "  (var fast (spawn (out ~ set 2))) " &
               "  (await fast) " &
               "  [(out ~ get) (await slow) (out ~ get)])",
               "[2 1 1]")

  test "zero-duration sleep yields a scheduler turn":
    check_eval("(var out ($cell 0)) " &
               "(spawn (out ~ set 1)) " &
               "[(out ~ get) ($sleep 0) (out ~ get)]",
               "[0 nil 1]")

  test "scope normal exit waits for live child tasks":
    check_eval("(var out ($cell 0)) " &
               "(scope (var ch ($channel ^capacity 1)) " &
               "  (spawn (do (ch ~ recv) (out ~ set 7))) " &
               "  (spawn (ch ~ send 1)) " &
               "  nil) " &
               "(out ~ get)",
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
      discard run(compileSource("(scope (var ch ($channel ^capacity 1)) " &
                                "  (var t (spawn (ch ~ recv))) " &
                                "  (t ~ cancel) " &
                                "  (try (await t) catch _ \"caught\"))"),
                  newGlobalScope())

  test "scope normal-exit deadlock cancels owned children":
    check_eval("(var ch ($channel ^capacity 1)) " &
               "(var out ($cell 0)) " &
               "(try " &
               "  (scope " &
               "    (spawn (do (ch ~ recv) (out ~ set 1))) " &
               "    nil) " &
               "  catch {^message m} m) " &
               "(ch ~ send 1) " &
               "($sleep 1) " &
               "(out ~ get)",
               "0")

  test "scope error exit cancels pending child tasks":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var ch ($channel ^capacity 1)) " &
               "(var out ($cell 0)) " &
               "(try " &
               "  (scope " &
               "    (spawn (do (ch ~ recv) (out ~ set 1))) " &
               "    (fail (Boom ^message \"stop\"))) " &
               "  catch (Boom) nil) " &
               "(ch ~ send 1) " &
               "(scope nil) " &
               "(out ~ get)",
               "0")

  test "scope error exit waits for child cancellation cleanup":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var ch ($channel ^capacity 1)) " &
               "(var out ($cell 0)) " &
               "(try " &
               "  (scope " &
               "    (spawn (try (ch ~ recv) " &
               "                ensure (out ~ set 9))) " &
               "    ($sleep 1) " &
               "    (fail (Boom ^message \"stop\"))) " &
               "  catch (Boom) nil) " &
               "(out ~ get)",
               "9")

  test "explicit Task/cancel still runs the ensure cleanup":
    check_eval("(var ch ($channel ^capacity 1)) " &
               "(var out ($cell 0)) " &
               "(scope " &
               "  (var t (spawn (try (ch ~ recv) " &
               "                   ensure (out ~ set 7)))) " &
               "  ($sleep 1) " &
               "  (t ~ cancel)) " &
               "($sleep 1) " &
               "(out ~ get)",
               "7")

  test "wildcard catch does not intercept task cancellation":
    expect GeneCancel:
      discard run(compileSource("(scope (var ch ($channel ^capacity 1)) " &
                                "  (var t (spawn (ch ~ recv))) " &
                                "  (t ~ cancel) " &
                                "  (try (await t) catch _ \"caught\"))"),
                  newGlobalScope())

  test "detached tasks outlive scope ownership":
    check_eval("(var out ($cell 0)) " &
               "(scope " &
               "  (var t (spawn (do ($sleep 5) (out ~ set 1)))) " &
               "  (t ~ detach) " &
               "  nil) " &
               "[(out ~ get) ($sleep 10) (out ~ get)]",
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
    check_eval("(var ch ($channel ^capacity 2)) " &
               "(ch ~ send 1) " &
               "(ch ~ send 2) " &
               "(ch ~ close) " &
               "[(ch ~ recv) " &
               " (ch ~ recv) " &
               " (try (ch ~ recv) catch (ChannelClosed ^message m) m)]",
               "[1 2 \"channel is closed\"]")
    check_eval("(scope (var ch ($channel ^capacity 1)) " &
               "  (var t (spawn (try (ch ~ recv) " &
               "                  catch (ChannelClosed ^message m) m))) " &
               "  (spawn (ch ~ close)) " &
               "  (await t))",
               "\"channel is closed\"")
    check_eval("(scope (var ch ($channel ^capacity 1)) " &
               "  (ch ~ send 1) " &
               "  (var t (spawn (try (ch ~ send 2) " &
               "                  catch (ChannelClosed ^message m) m))) " &
               "  (spawn (ch ~ close)) " &
               "  (await t))",
               "\"channel is closed\"")

  test "try_send and try_recv expose non-suspending channel checks":
    check_eval("(var ch ($channel ^capacity 1)) " &
               "[(ch ~ try_send 1) " &
               " (ch ~ try_send 2) " &
               " (ch ~ recv) " &
               " (match (ch ~ try_recv) " &
               "   (when TryRecv/empty true) " &
               "   (when (TryRecv/value _) false))]",
               "[true false 1 true]")

  test "try_recv tags empty and preserves Void and Nil payloads":
    check_eval("(var ch ($channel ^capacity 3)) " &
               "(var empty (ch ~ try_recv)) " &
               "(ch ~ send void) " &
               "(ch ~ send nil) " &
               "(ch ~ send 9) " &
               "[(match empty (when TryRecv/empty `empty)) " &
               " (match (ch ~ try_recv) " &
               "   (when (TryRecv/value v) v)) " &
               " (match (ch ~ try_recv) " &
               "   (when (TryRecv/value v) v)) " &
               " (match (ch ~ try_recv) " &
               "   (when (TryRecv/value v) v))]",
               "[empty void nil 9]")
    check_eval("(fn poll [ch : (Channel Int)] : (TryRecv Int) " &
               "  (ch ~ try_recv)) " &
               "(match (poll ($channel)) (when TryRecv/empty true))",
               "true")

  test "typed channel boundaries check items before enqueue":
    check_eval("(var ch : (Channel Int) ($channel)) " &
               "(try (ch ~ send \"bad\") catch (TypeError ^where w) w)",
               "\"Channel/send item\"")

  test "channel sends enforce dynamic Send values":
    check_eval("(var ch ($channel)) " &
               "(ch ~ send #[1 #{^a 2}]) " &
               "(ch ~ recv)",
               "#[1 #{^a 2}]")
    check_eval("(var ch ($channel)) " &
               "(var captured #[1 #{^a 2}]) " &
               "(var f (fn [] captured)) " &
               "(ch ~ send f) " &
               "(var g (ch ~ recv)) " &
               "(g)",
               "#[1 #{^a 2}]")
    check_eval("(var ch ($channel)) " &
               "(var f (fn [x y = x] y)) " &
               "(ch ~ send f) " &
               "(var g (ch ~ recv)) " &
               "(g 7)",
               "7")
    check_eval("(var ch ($channel)) " &
               "(try (ch ~ send [1]) catch (TypeError ^expected e) e)",
               "\"Send\"")
    check_eval("(var ch ($channel)) " &
               "(try (ch ~ send #[($cell 1)]) " &
               "catch (TypeError ^where w) w)",
               "\"Channel/send item\"")
    check_eval("(var ch ($channel)) " &
               "(var captured ($cell 1)) " &
               "(var f (fn [] (captured ~ get))) " &
               "(try (ch ~ send f) catch (TypeError ^expected e) e)",
               "\"Send\"")

suite "spec — actors from design":
  test "Actor is the type; actor is the function namespace":
    # Case carries meaning: operations with a receiver are messages on the
    # `Actor` type, while the ones without stay functions under `actor`
    # (design §3). `Actor` names the type of an actor reference, so it works
    # in annotation position too — `ActorRef` remains the redeclarable spelling.
    check_eval("(fn handle [ctx, state, msg] ($actor/continue (+ state msg))) " &
               "(var a ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(a ~ send 4) " &
               "[(same? gene/Actor Actor) (same? gene/actor $actor) " &
               " ((a ~ snapshot) ~ /state)]",
               "[true true 4]")
    # `Actor/send` is no longer a callable path; the message is sent bare.
    check_eval("(fn handle [ctx, state, msg] ($actor/continue (+ state msg))) " &
               "(var a ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(a ~ send 6) " &
               "((a ~ snapshot) ~ /state)",
               "6")
    check_runtime_error("(Actor/send 1 2)", "not a callable path")
    check_eval("(fn handle [ctx, state, msg] ($actor/continue state)) " &
               "(var a ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "[((fn [x : Actor] 1) a) ((fn [x : ActorRef] 2) a) " &
               " (try ((fn [x : Actor] 1) 5) " &
               "  catch (TypeError ^expected e) e)]",
               "[1 2 \"Actor\"]")
    # A program may still redeclare `ActorRef` as its own nominal type.
    check_eval("(type ActorRef ^props {^a Int}) " &
               "((fn [x : ActorRef] 3) (ActorRef ^a 1))",
               "3")

  test "namespaces and capabilities receive messages":
    # Module/Namespace/Capability/Env are uppercase namespaces whose operations
    # take the receiver first, so they are sends (design §3). `Module` itself
    # needs a real module and is covered in tests/test_modules.nim.
    check_eval("(import $net/http_client [Http]) (Http ~ name)",
               "\"net/Http\"")
    check_eval("(ns n (var x 1)) ((n ~ bindings) ~ get \"x\")", "1")

  test "actor send processes messages sequentially":
    check_eval("(var out ($cell 0)) " &
               "(fn handle [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  (var next (+ state msg)) " &
               "  (out ~ set next) " &
               "  ($actor/continue next)) " &
               "(var counter : (ActorRef Int) " &
               "  ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(counter ~ send 2) " &
               "(counter ~ send 5) " &
               "(out ~ get)",
               "7")

  test "actor try_send returns immediately":
    check_eval("(var gate ($channel ^capacity 1)) " &
               "(var seen ($cell 0)) " &
               "(var a ($actor/spawn ^init (fn [] 0) " &
               "  ^handle (fn [ctx state msg] " &
               "    (gate ~ recv) " &
               "    (seen ~ set msg) " &
               "    ($actor/continue msg)))) " &
               "(var before [(a ~ try_send 7) (seen ~ get)]) " &
               "(gate ~ send 1) " &
               "($sleep 0) " &
               "before",
               "[true 0]")

  test "actor snapshots expose idle state metadata":
    check_eval("(fn handle [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  ($actor/continue (+ state msg))) " &
               "(var counter : (ActorRef Int) " &
               "  ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(counter ~ send 2) " &
               "(counter ~ send 5) " &
               "(var snap (counter ~ snapshot)) " &
               "[snap/state snap/mailbox snap/closed snap/processing]",
               "[7 0 false false]")

  test "actor upgrade replaces idle handlers with migration rollback":
    check_eval("(fn add [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  ($actor/continue (+ state msg))) " &
               "(fn mul [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  ($actor/continue (* state msg))) " &
               "(var counter : (ActorRef Int) " &
               "  ($actor/spawn ^init (fn [] 1) ^handle add)) " &
               "(counter ~ send 2) " &
               "(counter ~ upgrade mul ^migrate (fn [state] (+ state 1))) " &
               "(counter ~ send 3) " &
               "(var before (counter ~ snapshot)) " &
               "(var err (try (counter ~ upgrade 99) " &
               "  catch (TypeError ^where w) w)) " &
               "(counter ~ send 2) " &
               "(var after (counter ~ snapshot)) " &
               "[before/state err after/state]",
               "[12 \"actor/upgrade handler\" 24]")

  test "actor stop closes the actor":
    check_eval("(var a : (ActorRef Int) " &
               "  ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] ($actor/stop)))) " &
               "(a ~ send 1) " &
               "(try (a ~ send 2) catch (ActorClosed ^message m) m)",
               "\"actor is closed\"")

  test "actor sends require typed Send messages":
    check_eval("(var a : (ActorRef Int) " &
               "  ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] ($actor/continue state)))) " &
               "(try (a ~ send \"bad\") catch (TypeError ^where w) w)",
               "\"actor/send message\"")
    check_eval("(var a ($actor/spawn ^init (fn [] 0) " &
               "  ^handle (fn [ctx state msg] ($actor/continue state)))) " &
               "(try (a ~ send [1]) catch (TypeError ^expected e) e)",
               "\"Send\"")

  test "actor ask uses an explicit one-shot ReplyTo capability":
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (match msg " &
               "    (when (Get ^reply reply) " &
               "      (reply ~ send state) " &
               "      ($actor/continue state)))) " &
               "(var counter : (ActorRef Get) " &
               "  ($actor/spawn ^init (fn [] 41) ^handle handle)) " &
               "(await (counter ~ ask (fn [reply] (Get ^reply reply))))",
               "41")

  test "a second send on a ReplyTo raises ReplyAlreadySent":
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var out ($cell nil)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var (Get ^reply reply) msg) " &
               "  (reply ~ send state) " &
               "  (try (reply ~ send state) " &
               "   catch (ReplyAlreadySent ^message m) (out ~ set m)) " &
               "  ($actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  ($actor/spawn ^init (fn [] 7) ^handle handle)) " &
               "(var got (await (counter ~ ask (fn [reply] (Get ^reply reply))))) " &
               "[got ($sleep 1) (out ~ get)]",
               "[7 nil \"reply has already been sent\"]")
    # ReplyAlreadySent is a subtype of ActorError, so a broad handler-level
    # catch also sees it.
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var out ($cell nil)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var (Get ^reply reply) msg) " &
               "  (reply ~ send state) " &
               "  (try (reply ~ send state) " &
               "   catch (ActorError ^message m) (out ~ set m)) " &
               "  ($actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  ($actor/spawn ^init (fn [] 7) ^handle handle)) " &
               "(await (counter ~ ask (fn [reply] (Get ^reply reply)))) " &
               "[($sleep 1) (out ~ get)]",
               "[nil \"reply has already been sent\"]")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(scope " &
               "  (var counter : (ActorRef Get) " &
               "    ($actor/spawn ^init (fn [] 41) " &
               "      ^handle (fn [ctx state msg] " &
               "        (match msg " &
               "          (when (Get ^reply reply) " &
               "            (reply ~ send state) " &
               "            ($actor/continue state)))))) " &
               "  (fn (choose result err) [t : (Task result err) fallback : result] " &
               "    fallback) " &
               "  (try (choose (counter ~ ask (fn [reply] (Get ^reply reply))) \"bad\") " &
               "       catch (TypeError ^expected e) e))",
               "\"Int\"")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var ch ($channel ^capacity 1)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var got (ch ~ recv)) " &
               "  (match msg " &
               "    (when (Get ^reply reply) " &
               "      (reply ~ send (+ state got)) " &
               "      ($actor/continue state)))) " &
               "(var counter : (ActorRef Get) " &
               "  ($actor/spawn ^init (fn [] 40) ^handle handle)) " &
               "(var pending (counter ~ ask (fn [reply] (Get ^reply reply)))) " &
               "(ch ~ send 2) " &
               "(await pending)",
               "42")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var ch ($channel ^capacity 1)) " &
               "(var out ($cell 0)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var (Get ^reply reply) msg) " &
               "  (var got (ch ~ recv)) " &
               "  (reply ~ send got) " &
               "  (out ~ set got) " &
               "  ($actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(var pending (counter ~ ask ^timeout_ms 5 (fn [reply] (Get ^reply reply)))) " &
               "(var err (try (await pending) catch (ActorError ^message m) m)) " &
               "(ch ~ send 7) " &
               "[err ($sleep 1) (out ~ get)]",
               "[\"actor/ask timed out\" nil 7]")
    check_eval("(scope " &
               "  (type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var saved ($cell nil)) " &
               "(var ch ($channel ^capacity 1)) " &
               "(fn handle [ctx state msg] " &
               "  (var (Get ^reply reply) msg) " &
               "  (var got (ch ~ recv)) " &
               "  (try (reply ~ send got) catch {^message m} m) " &
               "  ($actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(var pending (counter ~ ask ^timeout_ms 5 " &
               "  (fn [reply] (saved ~ set reply) (Get ^reply reply)))) " &
               "(var err (try (await pending) catch (ActorError ^message m) m)) " &
               "(var first-late (try ((saved ~ get) ~ send 9) " &
               "                  catch {^message m} m)) " &
               "(var second-late (try ((saved ~ get) ~ send 10) " &
               "                   catch {^message m} m)) " &
               "[err first-late second-late])",
               "[\"actor/ask timed out\" nil \"reply has already been sent\"]")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var counter : (ActorRef Get) " &
               "  ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (match msg " &
               "        (when (Get ^reply reply) " &
               "          (reply ~ send \"bad\") " &
               "          ($actor/continue state)))))) " &
               "(try (await (counter ~ ask (fn [reply] (Get ^reply reply)))) " &
               "catch (TypeError ^where w) w)",
               "\"ReplyTo/send value\"")

  test "scope shutdown cancels pending actor asks":
    expect GeneCancel:
      discard run(compileSource("(type Get ^props {^reply (ReplyTo Int)}) " &
                                "(impl Send for Get) " &
                                "(var pending nil) " &
                                "(scope " &
                                "  (var a ($actor/spawn ^init (fn [] 41) " &
                                "    ^handle (fn [ctx state msg] " &
                                "      (match msg " &
                                "        (when (Get ^reply reply) " &
                                "          (reply ~ send state) " &
                                "          ($actor/continue state)))))) " &
                                "  (set pending (a ~ ask " &
                                "    (fn [reply] (Get ^reply reply)))) " &
                                "  nil) " &
                                "(await pending)"),
                  newGlobalScope())
    check_eval("(scope " &
               "  (type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(var saved ($cell nil)) " &
               "(var ch ($channel ^capacity 1)) " &
               "(fn handle [ctx state msg] " &
               "  (var (Get ^reply reply) msg) " &
               "  (var got (ch ~ recv)) " &
               "  (try (reply ~ send got) catch {^message m} m) " &
               "  ($actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(var pending (counter ~ ask " &
               "  (fn [reply] (saved ~ set reply) (Get ^reply reply)))) " &
               "(pending ~ cancel) " &
               "(var first-late (try ((saved ~ get) ~ send 9) " &
               "                  catch {^message m} m)) " &
               "(var second-late (try ((saved ~ get) ~ send 10) " &
               "                   catch {^message m} m)) " &
               "[first-late second-late])",
               "[nil \"reply has already been sent\"]")
    expect GeneCancel:
      discard run(compileSource("(type Boom ^props {^message Str} ^impl [Error]) " &
                                "(impl Error for Boom) " &
                                "(type Get ^props {^reply (ReplyTo Int)}) " &
                                "(impl Send for Get) " &
                                "(supervisor ^strategy stop " &
                                "  (var a ($actor/spawn ^mailbox 4 ^init (fn [] 0) " &
                                "    ^handle (fn [ctx state msg] " &
                                "      (fail (Boom ^message \"bad\"))))) " &
                                "  (var first (a ~ ask (fn [reply] (Get ^reply reply)))) " &
                                "  (var second (a ~ ask (fn [reply] (Get ^reply reply)))) " &
                                "  ($sleep 1) " &
                                "  (await second))"),
                  newGlobalScope())

  test "scope owns spawned actors until scope exit":
    check_eval("(var a (scope " &
               "  ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] ($actor/continue state))))) " &
               "(a ~ try_send 1)",
               "false")
    check_eval("(scope " &
               "  (var a (scope " &
               "    ($actor/spawn ^init (fn [] 0) " &
               "      ^handle (fn [ctx state msg] ($actor/continue state))))) " &
               "  (a ~ try_send 1))",
               "false")

  test "restart budget stops the actor when max_restarts is exhausted":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(supervisor ^strategy restart ^max_restarts 1 ^within_ms 60000 " &
               "  (var a ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (fail (Boom ^message \"boom\"))))) " &
               "  (a ~ send 1) " &   # restart consumes the budget
               "  (var second (try (a ~ send 2) catch (Boom ^message m) m)) " &
               "  (var third (try (a ~ send 3) catch (ActorClosed ^message m) m)) " &
               "  [second third])",
               "[\"boom\" \"actor is closed\"]")

  test "restart budget window resets after within_ms":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var seen ($cell 0)) " &
               "(supervisor ^strategy restart ^max_restarts 1 ^within_ms 50 " &
               "  (var a ($actor/spawn ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (== msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do (seen ~ set state) ($actor/continue state)))))) " &
               "  (a ~ send 1) " &
               "  ($sleep 80) " &          # window expires; budget refills
               "  (a ~ send 1) " &
               "  (a ~ send 5) " &
               "  (seen ~ get))",
               "10")

  test "supervisor owns actors and restarts after recoverable handler errors":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var seen ($cell 0)) " &
               "(supervisor ^strategy restart " &
               "  (var a ($actor/spawn ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (== msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do " &
               "          (seen ~ set state) " &
               "          ($actor/continue (+ state msg))))))) " &
               "  (a ~ send 1) " &
               "  (a ~ send 5) " &
               "  (seen ~ get))",
               "10")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events ($channel ^capacity 4)) " &
               "(var seen ($cell 0)) " &
               "(supervisor ^strategy restart ^events events " &
               "  (var a ($actor/spawn ^mailbox 4 ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (== msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do " &
               "          (seen ~ set state) " &
               "          ($actor/continue (+ state msg))))))) " &
               "  (spawn (a ~ send 1)) " &
               "  (spawn (a ~ send 5)) " &
               "  ($sleep 1) " &
               "  (var event (events ~ recv)) " &
               "  (var tries 0) " &
               "  (while (< tries 100) " &
               "    (if (== (seen ~ get) 0) " &
               "      (do ($sleep 1) (set tries (+ tries 1))) " &
               "      (set tries 100))) " &
               "  [(seen ~ get) " &
               "   (match event " &
               "     (when (ActorFailure ^failed_message failed " &
               "                         ^error (Boom ^message m) " &
               "                         ^panic p ^strategy s) " &
               "       [failed m p s]))])",
               "[10 [1 \"bad\" false restart]]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events ($channel ^capacity 1)) " &
               "(var dead ($channel ^capacity 2)) " &
               "(events ~ send \"busy\") " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (fail (Boom ^message \"bad\"))))) " &
               "  (a ~ send 1) " &
               "  ($sleep 1) " &
               "  (var event (dead ~ recv)) " &
               "  (var busy (events ~ recv)) " &
               "  [busy " &
               "   (match event " &
               "     (when (ActorFailure ^failed_message failed " &
               "                         ^error (Boom ^message m) " &
               "                         ^strategy s) " &
               "       [failed m s]))])",
               "[\"busy\" [1 \"bad\" restart]]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events ($channel ^capacity 1)) " &
               "(var dead ($channel ^capacity 1)) " &
               "(events ~ send \"busy\") " &
               "(dead ~ send \"dead-busy\") " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (fail (Boom ^message \"bad\"))))) " &
               "  (a ~ send 4) " &
               "  ($sleep 1) " &
               "  (var dead-busy (dead ~ recv)) " &
               "  (var event (dead ~ recv)) " &
               "  (var busy (events ~ recv)) " &
               "  [busy dead-busy " &
               "   (match event " &
               "     (when (ActorFailure ^failed_message failed " &
               "                         ^error (Boom ^message m) " &
               "                         ^strategy s) " &
               "       [failed m s]))])",
               "[\"busy\" \"dead-busy\" [4 \"bad\" restart]]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events ($channel ^capacity 1)) " &
               "(var dead ($channel ^capacity 1)) " &
               "(events ~ close) " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (fail (Boom ^message \"bad\"))))) " &
               "  (a ~ send 2) " &
               "  ($sleep 1) " &
               "  (var event (dead ~ recv)) " &
               "  (match event " &
               "    (when (ActorFailure ^failed_message failed " &
               "                        ^error (Boom ^message m) " &
               "                        ^strategy s) " &
               "      [failed m s])))",
               "[2 \"bad\" restart]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events : (Channel Int) ($channel ^capacity 1)) " &
               "(var dead ($channel ^capacity 1)) " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (fail (Boom ^message \"bad\"))))) " &
               "  (a ~ send 6) " &
               "  ($sleep 1) " &
               "  (var event (dead ~ recv)) " &
               "  (match event " &
               "    (when (ActorFailure ^failed_message failed " &
               "                        ^error (Boom ^message m) " &
               "                        ^strategy s) " &
               "      [failed m s])))",
               "[6 \"bad\" restart]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var events ($channel ^capacity 1)) " &
               "(var dead ($channel ^capacity 1)) " &
               "(events ~ close) " &
               "(dead ~ close) " &
               "(var seen ($cell 0)) " &
               "(supervisor ^strategy restart ^events events ^dead_letter dead " &
               "  (var a ($actor/spawn ^mailbox 4 ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (== msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do " &
               "          (seen ~ set state) " &
               "          ($actor/continue (+ state msg))))))) " &
               "  (a ~ send 1) " &
               "  (a ~ send 5) " &
               "  ($sleep 1) " &
               "  (seen ~ get))",
               "10")
    check_eval("(var a (supervisor ^strategy stop " &
               "  ($actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] ($actor/continue state))))) " &
               "(a ~ try_send 1)",
               "false")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send for Get) " &
               "(try " &
               "  (supervisor ^strategy escalate " &
               "    (var a ($actor/spawn ^init (fn [] 0) " &
               "      ^handle (fn [ctx state msg] " &
               "        (fail (Boom ^message \"bad\"))))) " &
               "    (var pending (a ~ ask (fn [reply] (Get ^reply reply)))) " &
               "    ($sleep 1) " &
               "    \"after\") " &
               "  catch (Boom ^message m) m)",
               "\"bad\"")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error for Boom) " &
               "(var parent-events ($channel ^capacity 2)) " &
               "(var outcome " &
               "  (try " &
               "    (supervisor ^strategy stop ^events parent-events " &
               "      (supervisor ^strategy escalate " &
               "        (var a ($actor/spawn ^init (fn [] 0) " &
               "          ^handle (fn [ctx state msg] " &
               "            (fail (Boom ^message \"bad\"))))) " &
               "        (a ~ send 7))) " &
               "    catch (Boom ^message m) m)) " &
               "(var event (parent-events ~ recv)) " &
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
                                "  (var a ($actor/spawn ^init (fn [] 0) " &
                                "    ^handle (fn [ctx state msg] " &
                                "      (panic \"halt\")))) " &
                                "  (var pending (a ~ ask " &
                                "    (fn [reply] (Get ^reply reply)))) " &
                                "  ($sleep 1) " &
                                "  \"after\")"),
                  newGlobalScope())

suite "spec — Env and eval from design":
  test "incremental REPL sessions retain declarations and incomplete source":
    check_eval("(import $repl [open eval_source close]) " &
               "(var s (open (env ^bindings {^base 40}))) " &
               "(var declared (eval_source s \"(var x (+ base 1))\")) " &
               "(var used (eval_source s \"(+ x 1)\")) " &
               "(var partial (eval_source s \"(do\")) " &
               "(var completed (eval_source s \"(+ x 2))\")) " &
               "(close s) (close s) " &
               "[declared/status declared/text used/status used/text " &
               " partial/status completed/status completed/text]",
               "[\"ok\" \"41\" \"ok\" \"42\" \"incomplete\" \"ok\" \"43\"]")

  test "Env extend creates a child environment":
    check_eval("(var base (env ^bindings {^x 10})) " &
               "(var child (base ~ extend {^y 20})) " &
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
    check_eval("[$fs/ReadDir " &
               " ($fs/ReadDir ~ name) " &
               " ((fn [cap : Capability] (cap ~ name)) $fs/WriteDir)]",
               "[(capability fs/ReadDir) \"fs/ReadDir\" \"fs/WriteDir\"]")
    check_eval("(var e (env ^capabilities {^fs $fs/ReadDir})) " &
               "(eval (quote (fs ~ name)) ^in e)",
               "\"fs/ReadDir\"")
    check_eval("(var ch ($channel)) " &
               "(try (ch ~ send $fs/ReadDir) " &
               "catch (TypeError ^expected e) e)",
               "\"Send\"")

  test "runtime GC stats expose optimization diagnostics":
    check_eval("(var stats ($runtime/gc_stats)) " &
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
    check_eval("(eval ($read_one \"(+ 1 2)\") ^in (env))", "3")
    check_eval("(var s ($read_all \"(a) (b 2)\")) " &
               "[(s ~ next) (s ~ next) (s ~ has_next)]",
               "[(a) (b 2) false]")

  test "reader failures preserve structured location and open-form context":
    check_eval("(import gene/parse [read_all ParseError]) " &
               "(try (read_all \"(a [b)\") false " &
               " catch (ParseError ^line line ^col col ^contexts frames) " &
               "   [line col frames/0/opener frames/0/expected_closer " &
               "    frames/1/opener frames/1/expected_closer])",
               "[1 6 \"(\" \")\" \"[\" \"]\"]")
    check_eval("(try ($read_all \"(ok) )\") false " &
               " catch (ParseError ^contexts frames) (frames ~ size))",
               "0")

  test "lex_all exposes a token stream":
    check_eval("(fn first-token [s : (Stream Token Never)] (s ~ next)) " &
               "(var t (first-token ($lex_all \"(+ 1)\"))) " &
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
      "(var starts ($cell 0))\n" &
      "(starts ~ update (fn [n] (+ n 1)))\n")
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

  test "a co-located canonical impl dispatches when its protocol is in scope":
    # The impl is co-located with Greet and Cat in ilib, so it is canonical
    # and globally active. A qualified send names the protocol, so `use`
    # imports Greet to make Greet:greet resolvable at the call site.
    let dir = implModuleDir()
    writeFile(dir / "use.gene",
      "(import [Cat Greet] from \"./ilib\")\n" &
      "(var r ((Cat ^name \"Tom\") ~ Greet:greet))\n")
    let app = newApplication(dir)
    check implModuleVar(app.loadFileModule(dir / "use.gene"), "r") == "\"meow Tom\""

  test "a canonical impl dispatches through a transitive value producer":
    let dir = implModuleDir()
    writeFile(dir / "mid.gene",
      "(mod mid)\n" &
      "(import [Cat] from \"./ilib\")\n" &
      "(fn make_cat [n : Str] : Cat (Cat ^name n))\n")
    writeFile(dir / "use.gene",
      "(import [make_cat] from \"./mid\")\n" &
      "(import [Greet] from \"./ilib\")\n" &
      "(var r ((make_cat \"Felix\") ~ Greet:greet))\n")
    let app = newApplication(dir)
    check implModuleVar(app.loadFileModule(dir / "use.gene"), "r") == "\"meow Felix\""

  test "a canonical impl is global without an import path to its own module":
    let dir = implModuleDir()
    # `other` imports only the protocol (to name it in the qualified send),
    # never the Greet/Cat impl. The canonical impl is global once ilib is
    # loaded, so the qualified send in `other` dispatches it.
    writeFile(dir / "other.gene",
      "(mod other)\n" &
      "(import [Greet] from \"./ilib\")\n" &
      "(fn use_cat [c] (c ~ Greet:greet))\n")
    writeFile(dir / "use.gene",
      "(import [Cat] from \"./ilib\")\n" &
      "(import [use_cat] from \"./other\")\n" &
      "(var r (use_cat (Cat ^name \"Zoe\")))\n")
    let app = newApplication(dir)
    check implModuleVar(app.loadFileModule(dir / "use.gene"), "r") == "\"meow Zoe\""

suite "spec — stdlib namespaces from stdlib plan":
  test "gene/stream, gene/node, and gene/parse resolve as namespace imports":
    check_eval("(import gene/stream [to_stream map into]) " &
               "((to_stream [1 2 3]) ~ map (fn [x] (* x x)) ; ~ into [])",
               "[1 4 9]")
    check_eval("(import gene/stream [to_stream each]) " &
               "(var sum ($cell 0)) " &
               "(each (to_stream [1 2 3]) (fn [x] " &
               "  (sum ~ update (fn [s] (+ s x))))) " &
               "(sum ~ get)",
               "6")
    check_eval("(import gene/node [head]) (head (quote (a 1)))", "a")
    check_eval("(import gene/parse [parse_int]) (parse_int \" 42 \")", "42")
    check_eval("(import gene/parse [parse_int ParseError]) " &
               "(try (parse_int \"4x\") catch (ParseError ^message _) -1)",
               "-1")
    # format ends with a newline: it is the gene-fmt source-unit contract.
    check_eval("(import gene/parse [format]) (format \"( + 1   2 )\")",
               "\"(+ 1 2)\\n\"")
    check_eval("(import gene/parse [format ParseError]) " &
               "(try (format \"(((\") catch (ParseError ^message _) -1)",
               "-1")

  test "str module covers join/split/trim/lower and predicates":
    check_eval("(import $str [join]) (join [\"a\" \"b\"] \"-\")", "\"a-b\"")
    # D6: `join` is a function, not a List message — call it, don't send it.
    check_eval("(import $str [join]) (join [\"a\" \"b\"] \"\")", "\"ab\"")
    check_eval("(import $str [split]) (split \"a,b,,c\" \",\")",
               "[\"a\" \"b\" \"\" \"c\"]")
    check_eval("(import $str [trim lower]) (lower (trim \"  MiXeD  \"))",
               "\"mixed\"")
    check_eval("(import $str [starts_with? ends_with? contains?]) " &
               "[(starts_with? \"hello\" \"he\") (ends_with? \"hello\" \"lo\") " &
               " (contains? \"hello\" \"xyz\")]",
               "[true true false]")
    check_eval("(import $str [byte_size]) (byte_size \"Aé\")", "3")
    check_eval("(import $str [slice_bytes]) (slice_bytes \"AéZ\" 1 2)",
               "\"é\"")
    check_eval("(import $str [slice_bytes]) (slice_bytes \"AéZ\" 0 2)",
               "\"A\"")
    expect GeneError:
      discard run(compileSource(
        "(import $str [slice_bytes]) (slice_bytes \"AéZ\" 2 2)"),
        newGlobalScope())

  test "html/escape neutralizes markup and quote characters":
    check_eval("(import $html [escape]) " &
               "(escape \"<a b=\\\"x\\\">&'\")",
               "\"&lt;a b=&quot;x&quot;&gt;&amp;&#39;\"")

  test "url module encodes, decodes, and parses queries":
    check_eval("(import $url [encode_component]) (encode_component \"a b&c\")",
               "\"a%20b%26c\"")
    check_eval("(import $url [decode_component]) (decode_component \"a%20b\")",
               "\"a b\"")
    check_eval("(import $url [parse_query]) " &
               "(parse_query \"text=hello+world&x=%2F\")",
               "{^text \"hello world\" ^x \"/\"}")
    check_eval("(import $url [format_query]) " &
               "(format_query {^a \"1\" ^b \"x y\"})",
               "\"a=1&b=x%20y\"")
    check_eval("(import $url [decode_component UrlError]) " &
               "(try (decode_component \"a%zz\") " &
               "catch (UrlError ^message _) \"bad\")",
               "\"bad\"")

suite "spec — net/http surface from stdlib plan":
  test "response helpers build typed Response nodes":
    check_eval("(import $net/http [text]) (import gene/node [body]) " &
               "(var r (text \"hi\")) " &
               "[r/status r/headers/content-type (body r)]",
               "[200 \"text/plain; charset=utf-8\" [\"hi\"]]")
    check_eval("(import $net/http [json]) (var r (json \"{}\")) " &
               "r/headers/content-type",
               "\"application/json\"")
    check_eval("(import $net/http [redirect]) (var r (redirect \"/x\")) " &
               "[r/status r/headers/location]",
               "[302 \"/x\"]")
    check_eval("(import $net/http [not_found]) (var r (not_found)) r/status",
               "404")

  test "Server and Response types construct with typed props":
    check_eval("(import $net/http [Server]) " &
               "(var s (Server ^host \"127.0.0.1\" ^port 8088)) " &
               "[s/host s/port]",
               "[\"127.0.0.1\" 8088]")
    check_eval("(import $net/http [Response]) " &
               "(var r (Response ^status 201)) r/status",
               "201")

  test "serve validates its Server argument":
    check_eval("(import $net/http [serve HttpError]) " &
               "(try (serve nil (fn [q] q)) " &
               "catch (HttpError ^message _) \"bad server\")",
               "\"bad server\"")

suite "spec — net/http_client native client contract":
  test "client authority and entry points are importable":
    check_eval("(import $net/http_client [Http request stream HttpClientError]) " &
               "[(Http ~ name)]",
               "[\"net/Http\"]")

  test "client rejects non-http URL schemes before starting work":
    check_eval("(import $net/http_client [Http request HttpClientError]) " &
               "(try (request Http ^url \"file:///etc/passwd\") false " &
               " catch (HttpClientError ^message m) " &
               "   ($str/contains? m \"http:// or https://\"))",
               "true")

  test "setup errors carry ^kind so fallbacks match only unavailability":
    # Usage mistakes (bad args/authority) are ^kind "usage" and must not be
    # confused with libcurl load failures (^kind "unavailable"): the agent's
    # curl(1) fallback catches only the latter.
    check_eval("(import $net/http_client [Http request HttpClientError]) " &
               "(try (request Http ^url \"file:///x\") false " &
               " catch (HttpClientError ^kind k) (== k \"usage\"))",
               "true")
    check_eval("(import $net/http_client [Http request HttpClientError]) " &
               "(try (request Http ^url \"file:///x\") false " &
               " catch (HttpClientError ^kind \"unavailable\") \"fallback\" " &
               " catch (HttpClientError ^kind \"usage\") \"surfaced\")",
               geneString("surfaced"))

# Disabled here because spec_runner inherits its caller's terminal: the assertion
# passes under captured CI output but opens curses when run directly from a TTY.
# Non-TTY rejection and terminal restoration are covered by the CLI PTY tests.
# suite "spec — public curses terminal contract":
#   test "owned Screen API is importable and non-TTY open is typed":
#     check_eval("(import $curses [open close dimensions draw read_input " &
#                "refresh_input escape_pressed? next_event Screen CursesError]) " &
#                "(try (open) false " &
#                " catch (CursesError ^message m) ($str/contains? m \"TTY\"))",
#                "true")

suite "spec — structured logging contract":
  test "Logger API is importable and eager/lazy evaluation is explicit":
    check_eval("(import $log [Logger LogLevel new_logger debug!]) " &
               "(var logger (new_logger \"app/spec\" ^payload {^x 1})) " &
               "(var eager ($cell false)) (var lazy ($cell false)) " &
               "(logger ~ info (do (eager ~ set true) \"eager\")) " &
               "(debug! logger (do (lazy ~ set true) \"lazy\")) " &
               "(fn accepts [x : Logger] (x ~ enabled? LogLevel/warn)) " &
               "[(eager ~ get) (lazy ~ get) (accepts logger)]",
               "[true false true]")

  test "built-in namespace macros support selection aliases":
    check_eval("(import $log [new_logger debug! : diagnostic!]) " &
               "(var logger (new_logger \"app/spec\")) " &
               "(var touched ($cell false)) " &
               "(diagnostic! logger (do (touched ~ set true) \"x\")) " &
               "(touched ~ get)",
               "false")

  test "a lazy logging macro carries its LogLevel dependency":
    check_eval("(import $log [new_logger]) " &
               "(var logger (new_logger \"app/spec\")) " &
               "(import $log [debug!]) " &
               "(var touched ($cell false)) " &
               "(debug! logger (do (touched ~ set true) \"x\")) " &
               "(touched ~ get)",
               "false")

  test "logging payload rejects process-bound values":
    check_eval("(import $log [new_logger]) " &
               "(try (new_logger \"app/spec\" ^payload {^bad ($cell 1)}) " &
               "  false catch _ true)",
               "true")

  test "logging payload reserves event envelope keys":
    check_eval("(import $log [new_logger]) " &
               "(try (new_logger \"app/spec\" ^payload {^message \"fake\"}) " &
               "  false catch _ true)",
               "true")

suite "spec — db protocol from stdlib plan":
  test "sqlite backend covers CRUD, typed params, and typed rows":
    check_eval("(import $db/sqlite [open Db]) (var c (open \":memory:\")) " &
               "(c ~ Db:exec \"create table t (id integer primary key, x text, f float, b integer)\") " &
               "(c ~ Db:execute \"insert into t(x, f, b) values (?, ?, ?)\" \"a\" 1.5 true) " &
               "(c ~ Db:query \"select * from t\")",
               "[{^id 1 ^x \"a\" ^f 1.5 ^b 1}]")
    check_eval("(import $db/sqlite [open Db]) (var c (open \":memory:\")) " &
               "(c ~ Db:exec \"create table t (x text)\") " &
               "(c ~ Db:query_one \"select * from t where x = ?\" \"missing\")",
               "nil")
    check_eval("(import $db/sqlite [open Db DbError]) " &
               "(var c (open \":memory:\")) " &
               "(try (c ~ Db:query \"select * from missing\") " &
               "catch (DbError ^message _) \"caught\")",
               "\"caught\"")

  test "sqlite transactions roll back on recoverable failure":
    check_eval("(import $db/sqlite [open Db]) (var c (open \":memory:\")) " &
               "(c ~ Db:exec \"create table t (x text)\") " &
               "(try (c ~ Db:transaction (fn [d] " &
               "  (d ~ Db:execute \"insert into t(x) values (?)\" \"doomed\") " &
               "  (fail \"abort\"))) catch _ nil) " &
               "(c ~ Db:transaction (fn [d] " &
               "  (d ~ Db:execute \"insert into t(x) values (?)\" \"kept\"))) " &
               "(c ~ Db:query \"select x from t\")",
               "[{^x \"kept\"}]")

  test "connections close explicitly and reject further use":
    check_eval("(import $db/sqlite [open Db DbError]) " &
               "(var c (open \":memory:\")) " &
               "(var before (c ~ Db:closed?)) (c ~ Db:close) " &
               "[before (c ~ Db:closed?) " &
               " (try (c ~ Db:query \"select 1\") " &
               " catch (DbError ^message _) \"rejected\")]",
               "[false true \"rejected\"]")

  test "sqlite and postgres share one Db protocol":
    check_eval("(import $db [Db]) " &
               "[(same? Db ($db/sqlite ~ lookup \"Db\")) " &
               " (same? Db ($db/postgres ~ lookup \"Db\")) " &
               " (not (== ($db/postgres ~ lookup \"open\") void))]",
               "[true true true]")

suite "spec — store persistence protocol":
  test "crypto sha256 matches the standard known vector":
    check_eval("(import $crypto [sha256]) (sha256 \"abc\")",
               "\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"")

  test "crypto random_hex returns the requested number of random bytes":
    check_eval("(import $crypto [random_hex]) " &
               "(import $str [byte_size]) " &
               "(byte_size (random_hex 16))", "32")
    check_eval("(import $crypto [random_hex]) " &
      "(try (random_hex 0) catch {^message m} m)",
      "\"crypto/random_hex byte count must be between 1 and 1024\"")

  test "crypto secure_equal? compares credentials without an early-exit API":
    check_eval("(import $crypto [secure_equal?]) " &
      "[(secure_equal? \"secret\" \"secret\") " &
      " (secure_equal? \"secret\" \"secrex\") " &
      " (secure_equal? \"secret\" \"short\")]", "[true false false]")

  test "sqlite store round-trips data records and missing/default semantics":
    check_eval("(import $db/sqlite [open]) " &
               "(import $store/sqlite [open : store-open Store StoreError]) " &
               "(var db (open \":memory:\")) " &
               "(var s (store-open db)) " &
               "(s ~ Store:put \"a\" {^x 1}) " &
               "(s ~ Store:put \"void\" void) " &
               "[(s ~ Store:get \"a\") " &
               " (s ~ Store:get \"void\") " &
               " (s ~ Store:has? \"a\") " &
               " (s ~ Store:has? \"missing\") " &
               " (s ~ Store:get \"missing\" ^default \"fallback\") " &
               " (try (s ~ Store:get \"missing\") catch (StoreError ^kind k) k)]",
               "[{^x 1} void true false \"fallback\" missing]")

  test "sqlite store supports full mode refs, keys, delete, clear, and close":
    check_eval("(import $db/sqlite [open]) " &
               "(import $store/sqlite [open : store-open Store StoreError]) " &
               "(var db (open \":memory:\")) " &
               "(var s (store-open db)) " &
               "(s ~ Store:put \"fn\" gene/str/join ^mode \"full\") " &
               "(s ~ Store:put \"n\" 1) " &
               "(var got (s ~ Store:get \"fn\" ^mode \"full\")) " &
               "(var before (s ~ Store:keys)) " &
               "(s ~ Store:delete \"n\") " &
               "(var after-delete [(s ~ Store:has? \"n\") (s ~ Store:keys)]) " &
               "(s ~ Store:clear) " &
               "(var after-clear (s ~ Store:keys)) " &
               "(s ~ Store:close) " &
               "[(same? got gene/str/join) before after-delete after-clear " &
               " (try (s ~ Store:keys) catch (StoreError ^kind k) k)]",
               "[true [\"fn\" \"n\"] [false [\"fn\"]] [] closed]")

  test "filesystem store uses encoded keys and ignores junk files":
    let dir = getTempDir() / "gene-store-fs-spec"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    writeFile(dir / "junk.tmp", "not a record")
    check_eval("(import $store/fs [open : store-open Store StoreError]) " &
               "(import $fs [ReadWriteDir]) " &
               "(var s (store-open ReadWriteDir ^root " & geneString(dir) & ")) " &
               "(s ~ Store:put \"session:tg/42\" {^x 1}) " &
               "[(s ~ Store:get \"session:tg/42\") " &
               " (s ~ Store:keys) " &
               " (try (s ~ Store:put \"\" 1) catch (StoreError ^kind k) k)]",
               "[{^x 1} [\"session:tg/42\"] invalid_key]")

  test "sqlite checkpoints publish one hash-validated generation atomically":
    check_eval("(import $db/sqlite [open]) " &
               "(import $store/sqlite [open : store-open Store]) " &
               "(var db (open \":memory:\")) " &
               "(var s (store-open db)) " &
               "(s ~ Store:checkpoint 1 {^session {^schema 1 ^data {^x 1}}}) " &
               "(s ~ Store:checkpoint 2 {^session {^schema 1 ^data {^x 2}} " &
               "                   ^events {^schema 1 ^data [\"ok\"]}}) " &
               "(var loaded (s ~ Store:load_checkpoint)) " &
               "[loaded/generation loaded/schema " &
               " loaded/records/session/data/x loaded/records/events/data]",
               "[2 1 2 [\"ok\"]]")

  test "sqlite store files are owner-only":
    when defined(posix):
      let path = getTempDir() / "gene-store-owner-only-spec.sqlite"
      for suffix in ["", "-wal", "-shm", "-journal"]:
        if fileExists(path & suffix): removeFile(path & suffix)
      check_eval("(import $db/sqlite [open Db]) " &
                 "(import $store/sqlite [open : store-open Store]) " &
                 "(var db (open " & geneString(path) & ")) " &
                 "(var s (store-open db)) " &
                 "(s ~ Store:checkpoint 1 {^session {^schema 1 ^data {^x 1}}}) " &
                 "(s ~ Store:close) (db ~ Db:close) true",
                 "true")
      check getFilePermissions(path) == {fpUserRead, fpUserWrite}

  test "filesystem checkpoints fall back from a corrupt newest generation":
    let dir = getTempDir() / "gene-store-fs-checkpoint-spec"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    check_eval("(import $store/fs [open : store-open Store]) " &
               "(import $fs [ReadWriteDir]) " &
               "(var s (store-open ReadWriteDir ^root " & geneString(dir) & ")) " &
               "(s ~ Store:checkpoint 1 {^session {^schema 1 ^data {^x 1}}}) " &
               "(s ~ Store:checkpoint 2 {^session {^schema 1 ^data {^x 2}}}) " &
               "(var loaded (s ~ Store:load_checkpoint)) " &
               "[loaded/generation loaded/records/session/data/x]",
               "[2 2]")
    let newest = dir / "generations" / "00000000000000000002" /
                 "session.gene"
    writeFile(newest, "corrupt")
    check_eval("(import $store/fs [open : store-open Store]) " &
               "(import $fs [ReadWriteDir]) " &
               "(var s (store-open ReadWriteDir ^root " & geneString(dir) & ")) " &
               "(var loaded (s ~ Store:load_checkpoint)) " &
               "[loaded/generation loaded/records/session/data/x]",
               "[1 1]")
    when defined(posix):
      check getFilePermissions(dir) ==
        {fpUserRead, fpUserWrite, fpUserExec}

suite "spec — os and json from ai-agent plan":
  test "os/get_env reads, defaults, and errors under Os/Env":
    check_eval("(import $os [get_env env? Env]) " &
               "[(env? Env \"GENE_SPEC_UNSET_XYZ\") " &
               " (get_env Env \"GENE_SPEC_UNSET_XYZ\" \"fallback\")]",
               "[nil \"fallback\"]")
    check_eval("(import $os [get_env Env OsError]) " &
               "(try (get_env Env \"GENE_SPEC_UNSET_XYZ\") " &
               "catch (OsError ^message _) \"unset\")",
               "\"unset\"")

  test "os/get_env rejects a non-Os/Env capability":
    check_eval("(import $os [get_env OsError]) " &
               "(try (get_env $net/Connect \"HOME\") " &
               "catch (OsError ^message _) \"denied\")",
               "\"denied\"")

  test "os/executable_path identifies the running Gene executable":
    check_eval("(import $os [executable_path]) " &
               "(import $str [byte_size]) " &
               "(> (byte_size (executable_path)) 0)",
               "true")

  test "os/exec runs a program, captures output, and enforces timeout":
    check_eval("(import $os [exec Exec]) " &
               "(var r (exec Exec ^cmd \"echo\" ^args [\"hi\"])) " &
               "[r/status r/timed_out]",
               "[0 false]")
    check_eval("(import $os [exec Exec]) " &
               "(var r (exec Exec ^cmd \"sleep\" ^args [\"5\"] ^timeout_ms 150)) " &
               "r/timed_out",
               "true")

    check_eval("(import $os [exec Exec]) " &
               "(var r (exec Exec ^cmd \"printf\" ^args [\"abcdef\"] ^max_bytes 3)) " &
               "[r/stdout r/stdout_truncated r/truncated]",
               "[\"abc\" true true]")

  test "os/exec_stream invokes stdout callbacks while retaining captured output":
    check_eval("(import $os [exec_stream Exec]) " &
               "(import gene/stream [to_stream into]) " &
               "(var seen ($cell [])) " &
               "(var r (exec_stream Exec ^cmd \"printf\" ^args [\"a\\nb\\n\"] " &
               "                    ^stdout_line (fn [line] " &
               "                      (seen ~ set ((to_stream [line]) ~ into (seen ~ get)))))) " &
               "[r/status r/stdout (seen ~ get)]",
               "[0 \"a\\nb\\n\" [\"a\" \"b\"]]")

  test "os/exec_stdio runs with parent streams and returns status":
    check_eval("(import $os [exec_stdio Exec]) " &
               "(exec_stdio Exec ^cmd \"sh\" ^args [\"-c\" \"exit 7\"])",
               "7")

  test "os/exec_stdio_async inherits streams without blocking the scheduler":
    check_eval("(import $os [exec_stdio_async Exec]) " &
               "(var ticks ($cell 0)) " &
               "(var status ($cell -1)) " &
               "(scope " &
               "  (spawn (repeat 5 (do ($sleep 20) " &
               "    (ticks ~ set (+ (ticks ~ get) 1))))) " &
               "  (status ~ set " &
               "    (await (exec_stdio_async Exec ^cmd \"sh\" " &
               "      ^args [\"-c\" \"sleep 0.2; exit 7\"])))) " &
               "[(status ~ get) (ticks ~ get)]",
               "[7 5]")

  test "os/exec_async settles a task off-thread with the exec result map":
    check_eval("(import $os [exec_async Exec]) " &
               "(var r (await (exec_async Exec ^cmd \"echo\" ^args [\"hi\"]))) " &
               "[r/status r/timed_out]",
               "[0 false]")
    check_eval("(import $os [exec_async Exec]) " &
               "(var r (await (exec_async Exec ^cmd \"sleep\" ^args [\"5\"] " &
               "                          ^timeout_ms 150))) " &
               "r/timed_out",
               "true")
    check_eval("(import $os [exec_async Exec]) " &
               "(var status 1) " &
               "(repeat 20 " &
               "  (set status ((await (exec_async Exec ^cmd \"true\")) ~ /status))) " &
               "status",
               "0")

  test "root await polls external tasks before unrelated distant timers":
    let started = getMonoTime()
    check_eval("(import $os [exec_async Exec]) " &
               "(var status -1) " &
               "(scope " &
               "  (var distant (spawn ($sleep 1500))) " &
               "  (var r (await (exec_async Exec ^cmd \"sh\" " &
               "    ^args [\"-c\" \"sleep 0.05\"]))) " &
               "  (set status r/status) " &
               "  (distant ~ cancel)) " &
               "status",
               "0")
    check getMonoTime() - started < initDuration(milliseconds = 800)

  test "os/exec_stream_async feeds stdout lines through a channel then closes it":
    check_eval("(import $os [exec_stream_async Exec]) " &
               "(import gene/stream [to_stream into]) " &
               "(var ch ($channel ^capacity 8)) " &
               "(var t (exec_stream_async Exec ^cmd \"printf\" " &
               "         ^args [\"a\\nb\\n\"] ^stdout_chan ch)) " &
               "(var seen ($cell [])) (var line nil) " &
               "(try (loop (set line (ch ~ recv)) " &
               "  (seen ~ set ((to_stream [line]) ~ into (seen ~ get)))) " &
               "catch (ChannelClosed) nil) " &
               "(var r (await t)) " &
               "[(seen ~ get) r/stdout r/status]",
               "[[\"a\" \"b\"] \"a\\nb\\n\" 0]")

  test "os turn interrupt polling is scoped and consumptive":
    when defined(posix) and not defined(emscripten) and not defined(geneWasm):
      check_eval("(import $os [begin_interrupt take_interrupt end_interrupt]) " &
                 "[(begin_interrupt) (take_interrupt) (end_interrupt)]",
                 "[true false nil]")
    else:
      check_eval("(import $os [begin_interrupt take_interrupt end_interrupt]) " &
                 "[(begin_interrupt) (take_interrupt) (end_interrupt)]",
                 "[false false nil]")

  test "os/monotonic_ms is nondecreasing":
    check_eval("(import $os [monotonic_ms]) " &
               "(var a (monotonic_ms)) ($sleep 2) (>= (monotonic_ms) a)",
               "true")

  test "Task/cancel terminates an async exec child and closes its channel":
    let started = getMonoTime()
    check_eval("(import $os [exec_stream_async Exec]) " &
               "(scope " &
               "  (var ch ($channel ^capacity 1)) " &
               "  (var t (exec_stream_async Exec ^cmd \"sleep\" ^args [\"2\"] " &
               "           ^stdout_chan ch)) " &
               "  (spawn (do ($sleep 50) (t ~ cancel))) " &
               "  (try (loop (ch ~ recv)) " &
               "    catch (ChannelClosed) \"closed\"))",
               "\"closed\"")
    check getMonoTime() - started < initDuration(milliseconds = 1200)

  test "Task/cancel terminates an inherited-stream async child":
    let started = getMonoTime()
    check_eval("(import $os [exec_stdio_async Exec]) " &
               "(scope " &
               "  (var t (exec_stdio_async Exec ^cmd \"sleep\" ^args [\"2\"])) " &
               "  (spawn (do ($sleep 50) (t ~ cancel))) " &
               "  ($sleep 200) " &
               "  \"cancelled\")",
               "\"cancelled\"")
    check getMonoTime() - started < initDuration(milliseconds = 1200)

  test "scheduler stays live while an async exec child runs":
    # The whole point of the async variants (examples/ai_agent/design.md §12.9 gap 1):
    # fibers must make progress during a subprocess. The snapshot is taken
    # right after the await — a blocking exec would leave it at 0.
    check_eval("(import $os [exec_async Exec]) " &
               "(var ticks ($cell 0)) " &
               "(var during ($cell 0)) " &
               "(scope " &
               "  (spawn (repeat 5 (do ($sleep 20) " &
               "    (ticks ~ set (+ (ticks ~ get) 1))))) " &
               "  (var r (await (exec_async Exec ^cmd \"sleep\" ^args [\"0.3\"]))) " &
               "  (during ~ set (ticks ~ get))) " &
               "(during ~ get)",
               "5")

  test "fs sync helpers read, write, and list under capabilities":
    let dir = getTempDir() / "gene-ai-agent-fs-spec"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    let path = dir / "note.txt"
    let made = dir / "made"
    let removable = dir / "remove-me.txt"
    check_eval("(import $fs [read_text write_text exists? list_dir make_dir remove " &
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

  test "$fs/real_path resolves an existing file and a not-yet-created path":
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
    check_eval("(import $fs [real_path write_text ReadDir WriteDir]) " &
               "(import $str [starts_with?]) " &
               "(var base (real_path ReadDir " & geneString(dir) & ")) " &
               "(var direct (real_path ReadDir " & geneString(path) & ")) " &
               "(var detour (real_path ReadDir " &
               geneString(dir / "sub" / ".." / "new.txt") & ")) " &
               "[(== direct (real_path ReadDir " & geneString(dir & "/here.txt") & ")) " &
               " (starts_with? direct base) " &
               " (starts_with? detour base)]",
               "[true true true]")

  test "$fs/real_path follows a dangling final symlink to its real target":
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
    check_eval("(import $fs [real_path ReadDir]) " &
               "(import $str [starts_with?]) " &
               "(var base (real_path ReadDir " & geneString(ws) & ")) " &
               "(var outside-real (real_path ReadDir " & geneString(outside) & ")) " &
               "(var rp (real_path ReadDir " & geneString(ws / "escape") & ")) " &
               "[(starts_with? rp base) (starts_with? rp outside-real)]",
               "[false true]")

  test "json round-trips objects, arrays, scalars, and escapes":
    check_eval("(import $json [parse stringify]) " &
               "(stringify (parse \"{\\\"a\\\":1,\\\"b\\\":[true,null,2.5]}\"))",
               "\"{\\\"a\\\":1,\\\"b\\\":[true,null,2.5]}\"")
    check_eval("(import $json [parse]) (var m (parse \"{\\\"x\\\":\\\"a\\\\nb\\\"}\")) m/x",
               "\"a\\nb\"")

  test "json/parse raises JsonError on malformed input and trailing junk":
    check_eval("(import $json [parse JsonError]) " &
               "(try (parse \"{bad}\") catch (JsonError ^message _) \"e1\")",
               "\"e1\"")
    check_eval("(import $json [parse JsonError]) " &
               "(try (parse \"[1] extra\") catch (JsonError ^message _) \"e2\")",
               "\"e2\"")

  test "json/stringify raises JsonError for unsupported values":
    check_eval("(import $json [stringify JsonError]) " &
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
    check_eval("($contains? #[1 2] 2)", "true")

  test "contains? rejects non-collection receivers":
    expect GeneError:
      discard run(compileSource("({^a 1} ~ contains? \"a\")"),
                  newGlobalScope())

suite "spec — serde data core (docs/serialization.md stage 1)":
  test "scalars and containers round-trip under structural equality":
    check_eval("(import $serde [write_data read_data]) " &
               "(var v {^a 1 ^b [1 2.5 \"x\" true nil void] " &
               "        ^c {^nested \"y\"} ^d 'q' ^e 0x0aff " &
               "        ^f 123456789012345678901234567890}) " &
               "(== v (read_data (write_data v)))",
               "true")
    check_eval("(import $serde [write_data read_data]) " &
               "(import $str [contains?]) " &
               "(var v #[1 #{^k 2} [3]]) " &
               "(var rt (read_data (write_data v))) " &
               "[(== v rt) (contains? (write_data rt) \"#[1 #{\")]",
               "[true true]")

  test "dates, times, ranges, sets, durations, timezones round-trip":
    check_eval("(import $serde [write_data read_data]) " &
               "(var v [2026-07-08 12:30:05 2026-07-08T12:30:05Z " &
               "        ($range 1 10 2) (Set 1 2 3) ($duration 1500000) " &
               "        ($timezone 120 \"CEST\")]) " &
               "(== v (read_data (write_data v)))",
               "true")

  test "regexes round-trip as source plus flags":
    check_eval("(import $serde [write_data read_data]) " &
               "(var v #\"ab+c\"i) " &
               "(== v (read_data (write_data v)))",
               "true")

  test "nodes round-trip including props, meta, children, immutability":
    check_eval("(import $serde [write_data read_data]) " &
               "(var v `(p @m 1 ^x 2 \"c\" [3])) " &
               "(== v (read_data (write_data v)))",
               "true")

  test "reserved serde heads in user data are escaped and round-trip":
    check_eval("(import $serde [write_data read_data]) " &
               "(import $str [contains?]) " &
               "(var evil `(serde_float \"nan\")) " &
               "(var text (write_data evil)) " &
               "[(contains? text \"serde_data_node\") " &
               " (== evil (read_data text))]",
               "[true true]")
    check_eval("(import $serde [write_data read_data]) " &
               "(var evil2 `(serde_data_node 1)) " &
               "(== evil2 (read_data (write_data evil2)))",
               "true")

  test "float specials use canonical serde_float forms":
    check_eval("(import $serde [write_data read_data]) " &
               "(import $str [contains?]) " &
               "(var nanv (read_data \"(serde_v1 (serde_float \\\"nan\\\"))\")) " &
               "(var back (write_data nanv)) " &
               "[(contains? back \"serde_float\") " &
               " (!= nanv nanv)]",   # NaN != NaN
               "[true true]")
    check_eval("(import $serde [write_data read_data]) " &
               "(var inf (read_data \"(serde_v1 (serde_float \\\"+inf\\\"))\")) " &
               "(== inf (read_data (write_data inf)))",
               "true")

  test "symbols that do not re-read verbatim are escaped":
    check_eval("(import $serde [write_data read_data]) " &
               "(import $str [contains?]) " &
               "(var s (read_data \"(serde_v1 (serde_sym \\\"a/b\\\"))\")) " &
               "(var text (write_data s)) " &
               "[(contains? text \"serde_sym\") " &
               " (== s (read_data text))]",
               "[true true]")

  test "maps with non-literal keys use the serde_map escape":
    check_eval("(import $serde [write_data read_data]) " &
               "(import $str [contains?]) " &
               "(var m {}) (m ~ put! \"weird key\" 1) " &
               "(var text (write_data m)) " &
               "[(contains? text \"serde_map\") " &
               " (== m (read_data text))]",
               "[true true]")

  test "cells and capabilities are rejected with clear errors":
    check_eval("(import $serde [write_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (write_data [1 ($cell 2)]) " &
               "catch (SerdeError ^message m) " &
               "  [(contains? m \"at 1:\") (contains? m \"not data\")])",
               "[true true]")
    check_eval("(import $serde [write_data SerdeError]) " &
               "(try (write_data {^net $net/Connect}) " &
               "catch (SerdeError ^path p) p)",
               "\"net\"")

  test "serde/data? classifies without raising":
    check_eval("(import $serde [data?]) " &
               "[(data? [1 {^a 2}]) (data? ($cell 1)) (data? (fn [] 1))]",
               "[true false false]")
    check_eval("(import $serde [write_data data?]) " &
               "[(try (write_data 1 ^policy nil) catch _ \"rejected\") " &
               " (try (data? 1 ^policy nil) catch _ \"rejected\")]",
               "[\"rejected\" \"rejected\"]")

  test "serde rejects executable selectors and traverses node metadata":
    check_eval("(import $serde [data? write_data read_data SerdeError]) " &
               "(var pure /name) " &
               "(var executable (select %($map /name))) " &
               "[(data? pure) (== pure (read_data (write_data pure))) " &
               " (data? executable) " &
               " (try (write_data executable) catch (SerdeError) \"rejected\") " &
               " (data? `(x @state %($cell 1)))]",
               "[true true false \"rejected\" false]")

  test "cycles are detected with a path":
    check_eval("(import $serde [write_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(var m {}) (m ~ put! \"self\" m) " &
               "(try (write_data m) " &
               "catch (SerdeError ^message msg) (contains? msg \"cycle\"))",
               "true")

  test "policy limits are enforced and named":
    check_eval("(import $serde [read_data SerdeError SerdePolicy]) " &
               "(import $str [contains?]) " &
               "(try (read_data \"(serde_v1 [[[[1]]]])\" " &
               "               ^policy (SerdePolicy ^max_depth 2)) " &
               "catch (SerdeError ^message m) (contains? m \"max_depth\"))",
               "true")
    let deep = "(serde_v1 " & repeat("[", 20) & "1" & repeat("]", 20) & ")"
    check_eval("(import $serde [read_data SerdeError SerdePolicy]) " &
               "(import $str [contains?]) " &
               "(try (read_data " & geneString(deep) &
               "               ^policy (SerdePolicy ^max_depth 2)) " &
               "catch (SerdeError ^message m) " &
               "  (&& (contains? m \"parse\") (contains? m \"max_depth\")))",
               "true")
    check_eval("(import $serde [read_data SerdeError SerdePolicy]) " &
               "(import $str [contains?]) " &
               "(try (read_data \"(serde_v1 [1 2 3 4 5])\" " &
               "               ^policy (SerdePolicy ^max_nodes 3)) " &
               "catch (SerdeError ^message m) (contains? m \"max_nodes\"))",
               "true")
    check_eval("(import $serde [read_data SerdeError SerdePolicy]) " &
               "(import $str [contains?]) " &
               "(try (read_data \"(serde_v1 [a b c])\" " &
               "               ^policy (SerdePolicy ^max_symbols 2)) " &
               "catch (SerdeError ^message m) (contains? m \"max_symbols\"))",
               "true")
    check_eval("(import $serde [read_data SerdeError SerdePolicy]) " &
               "(import $str [contains?]) " &
               "(try (read_data \"(serde_v1 nil)\" " &
               "               ^policy (SerdePolicy ^max_bytes 5)) " &
               "catch (SerdeError ^message m) (contains? m \"max_bytes\"))",
               "true")

  test "envelope versioning is enforced":
    check_eval("(import $serde [read_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read_data \"(serde_v2 nil)\") " &
               "catch (SerdeError ^message m) " &
               "  (contains? m \"unsupported serde envelope\"))",
               "true")
    check_eval("(import $serde [read_data SerdeError]) " &
               "(try (read_data \"[1 2]\") " &
               "catch (SerdeError ^message _) \"no-envelope\")",
               "\"no-envelope\"")

  test "unknown control tags and malformed shapes are rejected":
    check_eval("(import $serde [read_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read_data \"(serde_v1 (serde_bogus 1))\") " &
               "catch (SerdeError ^message m) (contains? m \"serde_bogus\"))",
               "true")
    check_eval("(import $serde [read_data SerdeError]) " &
               "(try (read_data \"(serde_v1 (serde_range 1 2))\") " &
               "catch (SerdeError ^message _) \"bad-range\")",
               "\"bad-range\"")
    check_eval("(import $serde [read_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read_data \"(serde_v1 (serde_map false [\\\"a\\\" 1 \\\"a\\\" 2]))\") " &
               "catch (SerdeError ^message m) (contains? m \"duplicate key\"))",
               "true")
    check_eval("(import $serde [read_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read_data \"(serde_v1 (serde_set 1 1))\") " &
               "catch (SerdeError ^message m) (contains? m \"duplicate\"))",
               "true")
    check_eval("(import $serde [read_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read_data \"(serde_v1 (serde_set [1]))\") " &
               "catch (SerdeError ^message m) (contains? m \"hash-stable\"))",
               "true")

suite "spec — serde references (stage 3)":
  test "builtin function references round-trip by identity":
    check_eval("(import $serde [write read]) " &
               "(== gene/str/join (read (write gene/str/join)))",
               "true")
    check_eval("(import $serde [write read]) " &
               "(var f (read (write gene/str/join))) (f [\"a\" \"b\"] \"-\")",
               "\"a-b\"")

  test "builtin references carry a path but no module":
    check_eval("(import $serde [write]) " &
               "(import $str [contains?]) " &
               "(var t (write gene/str/join)) " &
               "[(contains? t \"serde_fn_ref\") (contains? t \"str/join\") " &
               " (contains? t \"^module\")]",
               "[true true false]")

  test "write_data refuses references":
    check_eval("(import $serde [write_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (write_data gene/str/join) " &
               "catch (SerdeError ^message m) (contains? m \"not data\"))",
               "true")

  test "read_data refuses reference tags":
    check_eval("(import $serde [write read_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read_data (write gene/str/join)) " &
               "catch (SerdeError ^message m) (contains? m \"serde/read\"))",
               "true")

  test "unresolved module reference errors without loading":
    check_eval("(import $serde [read SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read \"(serde_v1 (serde_type_ref ^module \\\"no/such\\\" " &
               "^path \\\"X\\\"))\") " &
               "catch (SerdeError ^message m) (contains? m \"not loaded\"))",
               "true")

  test "reserved ref props are rejected":
    check_eval("(import $serde [read SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read \"(serde_v1 (serde_type_ref ^package \\\"p\\\" " &
               "^path \\\"X\\\"))\") " &
               "catch (SerdeError ^message m) (contains? m \"reserved\"))",
               "true")

  test "a reference resolving to the wrong kind errors":
    check_eval("(import $serde [read SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read \"(serde_v1 (serde_type_ref ^path \\\"gene/str/join\\\"))\") " &
               "catch (SerdeError ^message m) (contains? m \"not the expected kind\"))",
               "true")

  test "cells snapshot through serde/write, outside the equality guarantee":
    check_eval("(import $serde [write read]) " &
               "(var c ($cell 41)) (var c2 (read (write c))) " &
               "[(c2 ~ get) (!= c c2)]",
               "[41 true]")

  test "write_data refuses cells; read_data refuses snapshot-cells":
    check_eval("(import $serde [write_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (write_data ($cell 1)) " &
               "catch (SerdeError ^message m) (contains? m \"not data\"))",
               "true")
    check_eval("(import $serde [write read_data SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (read_data (write ($cell 1))) " &
               "catch (SerdeError ^message m) (contains? m \"read_data\"))",
               "true")

  test "atomic cells never serialize":
    check_eval("(import $serde [write SerdeError]) " &
               "(import $str [contains?]) " &
               "(try (write ($atomic_cell 1)) " &
               "catch (SerdeError ^message m) (contains? m \"atomic\"))",
               "true")

suite "spec — web demo remains parseable":
  test "web demo parses as a module source unit":
    let forms = readAll(readFile("examples/web_demo.gene"))
    check forms.len == 35
    check forms[0].print().startsWith("(mod @doc ")
    check forms[1].print() == "(import (path gene net http) [Request Response serve])"
    check forms[^1].print().startsWith("(fn main ")

  test "web demo exercises selector-core examples":
    let rendered = readAll(readFile("examples/web_demo.gene")).mapIt(it.print()).join("\n")
    check "(unquote ($ \"$\" (path self price)))" in rendered
    check "(path routes (unquote (path gene to_pairs_stream)))" in rendered
    check "(path req params name)" in rendered

suite "spec — qualified message spelling":
  test "Proto:msg names a protocol message":
    check_eval("(protocol P (message m [] : Str)) (type T ^props {}) " &
               "(impl P for T (message m [] : Str \"impl\")) " &
               "[((T) ~ P:m) ((T) ~ P:m)]",
               "[\"impl\" \"impl\"]")
    # `:` is its own node: `/` selects a member, `:` names a message, and the
    # two compile differently in value position.
    check_read("A:b", "(msg A b)")
    check_read("a/b", "(path a b)")

  test "a type cannot qualify a direct message send":
    check_eval("(type Dog ^props {} (message bark [] : Str \"woof\")) " &
               "(try ((Dog) ~ Dog:bark) " &
               "catch (CallKindError ^where w ^expected e) [w e])",
               "[\"message send\" \"Protocol\"]")

  test "a type cannot qualify a message value":
    check_eval("(type Dog ^props {} (message bark [] : Str \"woof\")) " &
               "(try Dog:bark " &
               "catch (CallKindError ^where w ^expected e) [w e])",
               "[\"message value\" \"Protocol\"]")

  test "Self:msg is the value spelling for a type-direct message":
    # `Self:msg` names no type and dispatches on the runtime receiver, so an
    # override wins and one value can be applied to unrelated receiver types.
    check_eval("(type Dog ^props {} (message bark [] : Str \"woof\")) " &
               "(type Pup ^is Dog (message bark [] : Str \"yip\")) " &
               "(type Cat ^props {} (message bark [] : Str \"meow\")) " &
               "(var xs [(Dog) (Pup) (Cat)]) " &
               "[((Pup) ~ bark) ((Pup) ~ Self:bark) " &
               " (($map ($to_stream xs) Self:bark) ~ into [])]",
               "[\"yip\" \"yip\" [\"woof\" \"yip\" \"meow\"]]")
    # A protocol qualifier still resolves a visible impl. The receiver is a user
    # type, not `Int`: an impl on a *built-in* type is keyed on an identity that
    # `gScalarTypes` hands out process-wide, so it stops resolving once a second
    # Application rebuilds the built-ins. That is a real bug, reproduced and
    # recorded separately; it is not what this test is about.
    check_eval("(protocol Shown (message show [] : Str)) " &
               "(type N ^props {^v Int} (impl Shown (message show [] : Str \"n\"))) " &
               "(var xs [(N ^v 1) (N ^v 2)]) " &
               "[((N ^v 3) ~ Shown:show) " &
               " (($map ($to_stream xs) Shown:show) ~ into [])]",
               "[\"n\" [\"n\" \"n\"]]")

  test "built-in type identity is process-wide, not per application":
    # An impl is keyed on the receiver's type, so two `Int` objects that do not
    # compare equal silently lose impls. Built-in surface types and the natives
    # they share with the lexical root are therefore built once per process.
    let app1 = newApplication(getCurrentDir())
    let s1 = newGlobalScope(app1)
    discard run(compileSource(
      "(protocol Shown (message show [] : Str)) " &
      "(impl Shown for Int (message show [] : Str \"int\"))"), s1)
    check run(compileSource("(5 ~ Shown:show)"), s1).print() == "\"int\""
    # Building a second application used to overwrite the type table and break
    # the first one's impls in a scope that had been working.
    let s2 = newGlobalScope(newApplication(getCurrentDir()))
    check run(compileSource("(5 ~ Shown:show)"), s1).print() == "\"int\""
    check run(compileSource("(same? Cell Cell)"), s2).print() == "true"
    # A native bound both into the root and into a type's message table has to
    # be one value in *every* application, not just the first.
    for (typeName, msg, rootName) in [("List", "size", "$size"),
                                      ("Node", "head", "$head"),
                                      ("List", "to_stream", "$to_stream"),
                                      ("Stream", "each", "$stream/each")]:
      check sharedNativeIdentity(s2, typeName, msg, rootName)
    check run(compileSource("[(($cell 7) ~ get) ([1 2 3] ~ size)]"),
              s2).print() == "[7 3]"

  test "Self is reserved":
    # `Self` denotes the receiver's type rather than binding one, so a program
    # may not declare it — otherwise the qualifier would mean two things.
    check_compile_error("(type Self ^props {})", "reserved")
    check_compile_error("(var Self 1)", "reserved")

  test "a delimited colon keeps its existing meanings":
    # annotation, general-map entry, and a trailing `^key:` are untouched: `:`
    # is structural only when glued between two symbol characters.
    check_eval("(var x : Int 5) x", "5")
    check_read("{^a: 1}", "{^a: 1}")
    check_eval("(fn f [n : Int] : Int n) (f 7)", "7")

suite "spec — declaration case":
  test "types and protocols are uppercase, namespaces lowercase":
    check_eval("(ns util (var x 1)) (type T ^props {}) (protocol P) 1", "1")
    check_compile_error("(ns Util (var x 1))", "must start lowercase")
    check_compile_error("(type thing ^props {})", "must start uppercase")
    check_compile_error("(protocol shown)", "must start uppercase")
    check_compile_error("(enum colour red)", "must start uppercase")

type DocBlock = object
  ## One ` ```gene ` fence in a Markdown file. `line` is the fence's own
  ## 1-based line, so a failure points at the block rather than the file.
  line: int
  src: string
  runnable: bool  ## fence spelled ` ```gene runnable `

iterator geneBlocks(path: string): DocBlock =
  ## The one definition of "a documented Gene example", shared by every check
  ## below so they cannot disagree about which blocks exist.
  var cur: seq[string]
  var start = 0
  var inBlock = false
  var runnable = false
  var lineNo = 0
  for line in readFile(path).splitLines():
    inc lineNo
    if not inBlock and line.startsWith("```gene"):
      inBlock = true
      runnable = "runnable" in line
      cur = @[]
      start = lineNo
    elif inBlock and line.startsWith("```"):
      if cur.len > 0:
        yield DocBlock(line: start, src: cur.join("\n"), runnable: runnable)
      inBlock = false
    elif inBlock:
      cur.add line

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

  test "documented examples never call a pruned stdlib name bare":
    # The standard library moved under the `gene` root (design §2.1), so a bare
    # `(println …)` in a ```gene block no longer resolves. Catch that
    # mechanically: a lowercase call head that is not a special form, not kept
    # bare by `staysBare`, and not declared somewhere in the same file must not
    # also name a `gene` member — if it does, the example needs `$`.
    let geneNs = newGlobalScope().lookup("gene")
    check geneNs.kind == vkNamespace
    let stdlib = geneNs.nsScope
    let forms = toHashSet(@CoreSpecialFormNames) +
      toHashSet(@["then", "elif", "else", "when", "catch", "ensure", "ctor",
                  "message", "in", "for", "from"])
    var offenders: seq[string]
    for path in walkDirRec("docs"):
      if not path.endsWith(".md"):
        continue
      let lines = readFile(path).splitLines()
      var blocks: seq[seq[string]]
      var cur: seq[string]
      var inBlock = false
      for line in lines:
        if line.startsWith("```gene"):
          inBlock = true
          cur = @[]
        elif line.startsWith("```"):
          if inBlock and cur.len > 0:
            blocks.add cur
          inBlock = false
        elif inBlock:
          cur.add line
      var declared: HashSet[string]
      for blk in blocks:
        for line in blk:
          for kw in ["(fn ", "(fn! ", "(var ", "(let ", "(const ", "(macro ",
                     "(type ", "(enum ", "(protocol ", "(ns ", "(alias "]:
            var at = line.find(kw)
            while at >= 0:
              var i = at + kw.len
              var name = ""
              while i < line.len and line[i] notin {' ', ')', '\t', ']'}:
                name.add line[i]
                inc i
              if name.len > 0:
                declared.incl name
              at = line.find(kw, at + 1)
          # `(import ns [a b : alias c])` binds those names locally too.
          if "(import " in line or "(import_impl " in line:
            let lb = line.find('[')
            if lb >= 0:
              var word = ""
              for ch in line[lb + 1 .. ^1]:
                if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_', '?', '!'}:
                  word.add ch
                else:
                  if word.len > 0:
                    declared.incl word
                  word = ""
              if word.len > 0:
                declared.incl word
      for blk in blocks:
        # A block containing a template builds data nodes, whose heads are tags
        # (`(html (body …))`), not calls. Skip it rather than flag the tags.
        var isTemplate = false
        for line in blk:
          if '`' in line:
            isTemplate = true
        if isTemplate:
          continue
        for line in blk:
          var i = 0
          while i < line.len:
            if line[i] == '(' and i + 1 < line.len and
                line[i + 1] in {'a'..'z', '_'}:
              var j = i + 1
              var head = ""
              while j < line.len and line[j] notin {' ', ')', '\t'}:
                head.add line[j]
                inc j
              if head.len > 0 and head notin forms and head notin declared and
                  not staysBare(head) and stdlib.vars.hasKey(head):
                offenders.add path & ": (" & head & " …) -> ($" & head & " …)"
            inc i
    if offenders.len > 0:
      checkpoint offenders.join("\n")
    check offenders.len == 0

  test "every documented gene block parses":
    # design.md is unverified prose, and the two ways it rots are syntax and
    # semantics. Syntax is checkable over *all* blocks with no marking, because
    # a fragment still has to read: `{...}` is not a prop map, and `# ...`
    # comments to end of line, so `(when X # ...)` ate its own closing paren
    # and nothing noticed. Evaluation is opt-in below, because most blocks are
    # deliberately fragments.
    var offenders: seq[string]
    for path in walkDirRec("docs"):
      if not path.endsWith(".md"):
        continue
      for blk in geneBlocks(path):
        try:
          discard readAll(blk.src)
        except CatchableError as e:
          offenders.add path & ":" & $blk.line & "  " & e.msg.splitLines()[0]
    if offenders.len > 0:
      checkpoint offenders.join("\n")
    check offenders.len == 0

  test "documented gene blocks marked runnable actually run":
    # ```gene runnable is the opt-in: a block spelled that way is a claim that
    # it executes, and this is what makes the claim true. `Self` stayed broken
    # across a whole release because design.md §10's own normative example was
    # never run — marking an example is how a doc stops being prose.
    var offenders: seq[string]
    var ran = 0
    for path in walkDirRec("docs"):
      if not path.endsWith(".md"):
        continue
      for blk in geneBlocks(path):
        if not blk.runnable:
          continue
        inc ran
        try:
          discard run(compileSource(blk.src), newGlobalScope())
        except CatchableError as e:
          offenders.add path & ":" & $blk.line & "  " & e.msg.splitLines()[0]
    if offenders.len > 0:
      checkpoint offenders.join("\n")
    check offenders.len == 0
    # A marker that stops matching any block would make this vacuously green.
    check ran > 0

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
