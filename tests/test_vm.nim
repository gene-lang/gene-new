import gene/[compiler, gir, printer, types, vm]
import std/[strutils, unittest]

template ck(src, expected: string) =
  ## Compile and run a program string, then compare its printed result.
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

suite "compiler — GIR emission":
  test "emits a callable-first bytecode sequence":
    let chunk = compileSource("(+ 1 2)")
    check chunk.instructions.len == 5
    check chunk.instructions[0].op == opLoadName
    check chunk.instructions[0].name == "+"
    check chunk.instructions[1].op == opPushConst
    check chunk.constants[chunk.instructions[1].intArg].intVal == 1
    check chunk.instructions[2].op == opPushConst
    check chunk.constants[chunk.instructions[2].intArg].intVal == 2
    check chunk.instructions[3].op == opCall
    check chunk.instructions[3].intArg == 2
    check chunk.instructions[4].op == opReturn

  test "emits nested function prototypes":
    let chunk = compileSource("(fn inc [x] (+ x 1))")
    check chunk.functions.len == 1
    check chunk.instructions.len == 3
    check chunk.instructions[0].op == opMakeFn
    check chunk.instructions[1].op == opDefineName
    check chunk.instructions[1].name == "inc"
    check chunk.instructions[2].op == opReturn

    let proto = chunk.functions[0]
    check proto.name == "inc"
    check proto.params == @["x"]
    check proto.restParam == ""
    check proto.namedParams.len == 0
    check proto.chunk.instructions.len == 5
    check proto.chunk.instructions[0].op == opLoadName
    check proto.chunk.instructions[0].name == "+"
    check proto.chunk.instructions[^1].op == opReturn

  test "emits call prop names and named parameter specs":
    let callChunk = compileSource("(draw ^color (+ 1 2) \"circle\")")
    check callChunk.instructions[^2].op == opCall
    check callChunk.instructions[^2].intArg == 1
    check callChunk.instructions[^2].names == @["color"]

    let fnChunk = compileSource("(fn draw [shape ^color c] [shape c])")
    let proto = fnChunk.functions[0]
    check proto.params == @["shape"]
    check proto.namedParams.len == 1
    check proto.namedParams[0].arg == "color"
    check proto.namedParams[0].local == "c"

  test "emits rest parameter specs":
    let fnChunk = compileSource("(fn collect [head tail...] [head tail])")
    let proto = fnChunk.functions[0]
    check proto.params == @["head"]
    check proto.restParam == "tail"
    check proto.namedParams.len == 0

  test "emits runtime construction for dynamic selectors":
    let chunk = compileSource("/%field")
    check chunk.instructions.len == 3
    check chunk.instructions[0].op == opLoadName
    check chunk.instructions[0].name == "field"
    check chunk.instructions[1].op == opMakeSelector
    check chunk.instructions[1].intArg == 1
    check chunk.instructions[2].op == opReturn

  test "emits runtime construction for quasiquote nodes":
    let chunk = compileSource("`(tag ^class %cls body)")
    var sawMakeNode = false
    for inst in chunk.instructions:
      if inst.op == opMakeNode:
        sawMakeNode = true
    check sawMakeNode

  test "emits runtime construction for quasiquote list splices":
    let chunk = compileSource("`[(unquote (... xs)) tail]")
    var sawMakeListSplice = false
    for inst in chunk.instructions:
      if inst.op == opMakeListSplice:
        sawMakeListSplice = true
    check sawMakeListSplice

  test "emits optional and default parameter specs":
    let fnChunk = compileSource("(fn f [x y? ^scale = (+ x 1)] [x y scale])")
    let proto = fnChunk.functions[0]
    check proto.params == @["x", "y"]
    check proto.paramDefaults.len == 2
    check proto.paramDefaults[0].optional == false
    check proto.paramDefaults[1].optional == true
    check proto.paramDefaults[1].defaultChunk == nil
    check proto.namedParams.len == 1
    check proto.namedParams[0].arg == "scale"
    check proto.namedParams[0].defaultValue.optional == true
    check proto.namedParams[0].defaultValue.defaultChunk != nil

  test "compile errors use the runtime error channel":
    expect GeneError: discard compileSource("(var)")
    expect GeneError: discard compileSource("(fn missing-params 1)")
    expect GeneError: discard compileSource("(fn bad [^])")
    expect GeneError: discard compileSource("(fn bad [xs... y] y)")
    expect GeneError: discard compileSource("(fn bad [xs... ^scale] scale)")
    expect GeneError: discard compileSource("(fn bad [x? y] y)")
    expect GeneError: discard compileSource("(fn bad [x? ys...] ys)")
    expect GeneError: discard compileSource("(fn bad [xs... = 1] xs)")
    expect GeneError: discard compileSource("(fn bad [x =] x)")

suite "gir — disassembly":
  test "prints constants and instructions":
    let dump = compileSource("(+ 1 2)").disassemble()
    check dump.contains("constants:")
    check dump.contains("[0] 1")
    check dump.contains("[1] 2")
    check dump.contains("0: opLoadName name=+")
    check dump.contains("3: opCall argc=2")
    check dump.contains("4: opReturn")

  test "prints nested function chunks":
    let dump = compileSource("(fn inc [x] (+ x 1))").disassemble()
    check dump.contains("functions:")
    check dump.contains("[0] inc params=[x]")
    check dump.contains("0: opMakeFn fn=0")
    check dump.contains("0: opLoadName name=+")

suite "vm — literals and self-evaluation":
  test "scalars evaluate to themselves":
    ck "42", "42"
    ck "3.5", "3.5"
    ck "\"hi\"", "\"hi\""
    ck "true", "true"
    ck "nil", "nil"
    ck "'a'", "'a'"
  test "empty program is nil":
    ck "", "nil"
  test "vector evaluates its elements":
    ck "[1 (+ 1 2) 3]", "[1 3 3]"
  test "map evaluates its values":
    ck "{^a (+ 1 1) ^b 3}", "{^a 2 ^b 3}"
  test "quote suppresses evaluation":
    ck "(quote (+ 1 2))", "(+ 1 2)"

suite "vm — quasiquote templates":
  test "quasiquote evaluates unquoted body values":
    ck "(var name \"Ada\") `(hello %name)", "(hello \"Ada\")"

  test "quasiquote evaluates unquoted heads, props, and map values":
    ck "(var h (quote button)) (var cls \"primary\") " &
       "`(%h ^class %cls {^label %cls})",
       "(button ^class \"primary\" {^label \"primary\"})"

  test "nested quasiquote preserves inner unquote depth":
    ck "(var x 1) `(outer `(inner %x) %x)",
       "(outer (quasiquote (inner (unquote x))) 1)"

  test "quasiquote splices list values into node bodies":
    ck "(var xs [1 2]) `(items %xs... 3)", "(items 1 2 3)"

  test "quasiquote splices map and node anatomy into nodes":
    ck "(var attrs {^class \"red\" ^id \"x\"}) `(div %attrs... \"hi\")",
       "(div ^class \"red\" ^id \"x\" \"hi\")"
    ck "(var child (quote (span ^role \"item\" \"a\" \"b\"))) `(div %child...)",
       "(div ^role \"item\" \"a\" \"b\")"

  test "quasiquote splices list values into list literals":
    ck "(var xs [1 2]) `[(unquote (... xs)) 3]", "[1 2 3]"

  test "nested quasiquote preserves inner splice depth":
    ck "(var xs [1 2]) `(outer `(inner %xs...))",
       "(outer (quasiquote (inner (unquote (... xs)))))"

  test "quasiquote rejects scalar splices":
    expect GeneError: discard runStr("(var x 1) `(items %x...)")

  test "eval executes generated template nodes":
    ck "(var x 7) (var t `(+ %x 5)) (eval t ^in (env))", "12"

  test "malformed template forms are compile errors":
    expect GeneError: discard compileSource("(quasiquote)")
    expect GeneError: discard compileSource("(quasiquote (unquote))")

suite "vm — arithmetic":
  test "addition":
    ck "(+ 1 2 3)", "6"
  test "subtraction and negation":
    ck "(- 10 3 2)", "5"
    ck "(- 7)", "-7"
  test "multiplication":
    ck "(* 2 3 4)", "24"
  test "integer division":
    ck "(/ 12 3 2)", "2"
  test "float contagion":
    ck "(+ 1 2.5)", "3.5"
    ck "(/ 7.0 2)", "3.5"
  test "division by zero raises":
    expect GeneError: discard runStr("(/ 1 0)")
  test "non-numbers raise":
    expect GeneError: discard runStr("(+ 1 \"x\")")

suite "vm — comparison and logic":
  test "ordering is chained":
    ck "(< 1 2 3)", "true"
    ck "(< 1 3 2)", "false"
    ck "(>= 3 3 1)", "true"
  test "structural equality":
    ck "(= 2 2)", "true"
    ck "(= [1 2] [1 2])", "true"
    ck "(= 1 2)", "false"
  test "not":
    ck "(not false)", "true"
    ck "(not nil)", "true"
    ck "(not 1)", "false"

suite "vm — special forms":
  test "do returns last":
    ck "(do 1 2 3)", "3"
    ck "(do)", "nil"
  test "if compact form":
    ck "(if true 1 2)", "1"
    ck "(if false 1 2)", "2"
    ck "(if nil 1 2)", "2"
    ck "(if void 1 2)", "2"
    ck "(if 0 1 2)", "1"     # 0 is truthy; only false/nil/void are falsy
    ck "(if false 1)", "nil"
  test "if full form with then/elif/else":
    ck "(if (< 2 1) (then 10) (elif (< 1 2) 20) (else 30))", "20"
    ck "(if (< 2 1) (then 10) (else 30))", "30"
    ck "(if (< 1 2) (then 10) (else 30))", "10"
  test "var binds and returns the value":
    ck "(var x 5) x", "5"
    ck "(var x 5) (+ x 1)", "6"
  test "set reassigns an existing binding":
    ck "(var x 1) (set x 99) x", "99"
  test "set on an undefined name raises":
    expect GeneError: discard runStr("(set nope 1)")
  test "undefined symbol raises":
    expect GeneError: discard runStr("nope")

suite "vm — functions and closures":
  test "anonymous function application":
    ck "((fn [x] (+ x 1)) 41)", "42"
  test "named function in scope":
    ck "(var add (fn [a b] (+ a b))) (add 3 4)", "7"
  test "named function declarations bind in scope":
    ck "(fn add [a b] (+ a b)) (add 3 4)", "7"
  test "arity mismatch raises":
    expect GeneError: discard runStr("((fn [x] x) 1 2)")
  test "closures capture their environment":
    ck "(var adder (fn [a] (fn [b] (+ a b)))) ((adder 10) 5)", "15"
  test "lexical capture is by reference to the defining scope":
    ck "(var x 1) (var get (fn [] x)) (set x 2) (get)", "2"
  test "recursion via a var-bound self reference":
    ck "(var fib (fn [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib 10)", "55"
  test "recursion via a named function declaration":
    ck "(fn fib [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10)", "55"
  test "calling a non-callable raises":
    expect GeneError: discard runStr("(1 2 3)")

suite "vm — named arguments":
  test "function calls bind node props to named parameters":
    ck "(var draw (fn [shape ^color] [shape color])) (draw ^color \"red\" \"circle\")",
       "[\"circle\" \"red\"]"
  test "named argument values are evaluated":
    ck "(var draw (fn [shape ^color] [shape color])) (draw ^color (+ 1 2) 5)",
       "[5 3]"
  test "named parameters can bind to a custom local":
    ck "(var draw (fn [shape ^color c] [shape c])) (draw ^color \"blue\" \"square\")",
       "[\"square\" \"blue\"]"
  test "missing and unexpected named arguments raise":
    expect GeneError: discard runStr("(var draw (fn [shape ^color] [shape color])) (draw \"circle\")")
    expect GeneError: discard runStr("(var draw (fn [shape ^color] [shape color])) (draw ^width 2 \"circle\")")
  test "native functions reject named arguments":
    expect GeneError: discard runStr("(+ ^base 1 2)")

suite "vm — rest parameters":
  test "rest parameter gathers extra positional args":
    ck "(var collect (fn [head tail...] [head tail])) (collect 1 2 3 4)",
       "[1 [2 3 4]]"
  test "rest parameter can gather zero args":
    ck "(var collect (fn [head tail...] [head tail])) (collect 1)",
       "[1 []]"
  test "rest-only functions gather all positional args":
    ck "(var all (fn [items...] items)) (all 1 (+ 1 1) 3)",
       "[1 2 3]"
  test "rest parameters still require fixed positional args":
    expect GeneError: discard runStr("(var collect (fn [head tail...] [head tail])) (collect)")
  test "rest and named parameters compose when named params come first":
    ck "(var f (fn [head ^scale, tail...] [head scale tail])) (f ^scale 9 1 2 3)",
       "[1 9 [2 3]]"

suite "vm — optional and default parameters":
  test "omitted optional positional parameters bind void":
    ck "(var f (fn [x?] x)) (f)", "void"
    ck "(var f (fn [x?] x)) (f 7)", "7"
  test "positional defaults are evaluated at call time":
    ck "(var f (fn [x = 4] x)) (f)", "4"
    ck "(var f (fn [x = 4] x)) (f 9)", "9"
  test "positional defaults can reference earlier parameters":
    ck "(var f (fn [x y = (+ x 1)] y)) (f 4)", "5"
  test "defaults see the call-time captured scope":
    ck "(var base 1) (var f (fn [x = base] x)) (set base 2) (f)", "2"
  test "optional named parameters bind void when omitted":
    ck "(var f (fn [^width?] width)) (f)", "void"
    ck "(var f (fn [^width?] width)) (f ^width 8)", "8"
  test "named defaults are evaluated at call time":
    ck "(var f (fn [base ^width = (+ base 1)] width)) (f 4)", "5"
    ck "(var f (fn [base ^width = (+ base 1)] width)) (f ^width 10 4)", "10"
  test "custom local named defaults bind the local":
    ck "(var f (fn [^width w = 2] w)) (f)", "2"
  test "too many positional arguments still raise":
    expect GeneError: discard runStr("(var f (fn [x = 1] x)) (f 1 2)")

suite "vm — selectors":
  test "selector literals are first-class values":
    ck "/name", "(select name)"
    ck "(var get-name /name) (get-name {^name \"Ada\"})", "\"Ada\""
  test "expression paths apply static selectors to lexical values":
    ck "(var user {^name \"Ada\" ^age 37}) user/name", "\"Ada\""
    ck "(var user {^address {^city \"Raleigh\"}}) user/address/city", "\"Raleigh\""
  test "missing selector lookup propagates void":
    ck "(var user {^name \"Ada\"}) user/missing/name", "void"
    ck "(var user {^name nil}) user/name", "nil"
  test "selectors read list indexes and fixed list members":
    ck "(var xs [10 20 30]) xs/1", "20"
    ck "(var xs [10 20 30]) xs/-1", "30"
    ck "(var xs [10 20 30]) xs/size", "3"
    ck "(var xs []) xs/first", "void"
  test "selectors read node props, body indexes, and projections":
    ck "(var n (quote (user ^name \"Ada\" 10 20))) n/name", "\"Ada\""
    ck "(var n (quote (user ^name \"Ada\" 10 20))) n/1", "20"
    ck "(var n (quote (user ^name \"Ada\" 10 20))) n/head", "user"
    ck "(var n (quote (user ^name \"Ada\" 10 20))) n/body", "[10 20]"
  test "selector calls validate their call envelope":
    expect GeneError: discard runStr("(/name)")
    expect GeneError: discard runStr("(/name ^unused 1 {^name \"Ada\"})")

suite "vm — dynamic selectors":
  test "dynamic selector keys are evaluated":
    ck "(var field \"name\") (var user {^name \"Ada\"}) user/%field", "\"Ada\""
    ck "(var field (quote name)) (var user {^name \"Ada\"}) user/%field", "\"Ada\""
  test "dynamic selector indexes are evaluated":
    ck "(var i 1) (var xs [10 20 30]) xs/%i", "20"
  test "selector values capture dynamic segments":
    ck "(var field \"name\") (var get /%field) (set field \"age\") (get {^name \"Ada\" ^age 37})",
       "\"Ada\""
  test "explicit select can capture dynamic segments":
    ck "(var field \"name\") (var get (select %field)) (get {^name \"Ada\"})",
       "\"Ada\""
  test "callable dynamic segments act as selector stages":
    ck "(var stage not) (var s /%stage) (s false)", "true"

suite "vm — node projection built-ins":
  test "projection built-ins expose value anatomy":
    ck "(head 42)", "42"
    ck "(head (quote (user ^name \"Ada\" 10 20)))", "user"
    ck "(props {^name \"Ada\"})", "{^name \"Ada\"}"
    ck "(props (quote (user ^name \"Ada\" 10 20)))", "{^name \"Ada\"}"
    ck "(body [10 20])", "[10 20]"
    ck "(body (quote (user ^name \"Ada\" 10 20)))", "[10 20]"
    ck "(meta (quote (user @line 7 ^name \"Ada\")))", "{^line 7}"
  test "projection built-ins work as dynamic selector stages":
    ck "(var user (quote (user @line 7 ^name \"Ada\" 10 20))) user/%head",
       "user"
    ck "(var user (quote (user @line 7 ^name \"Ada\" 10 20))) user/%props/name",
       "\"Ada\""
    ck "(var user (quote (user @line 7 ^name \"Ada\" 10 20))) user/%body/1",
       "20"
    ck "(var user (quote (user @line 7 ^name \"Ada\" 10 20))) user/%meta/line",
       "7"
  test "projection built-ins validate arity":
    expect GeneError: discard runStr("(props)")
    expect GeneError: discard runStr("(body 1 2)")

suite "vm — functional selector updates":
  test "assoc-in updates maps without mutating the original":
    ck "(var user {^name \"Ada\" ^age 37}) (var user2 (assoc-in user /age 38)) (+ (* user/age 100) user2/age)",
       "3738"
    ck "(assoc-in {^name \"Ada\"} /city \"Raleigh\")",
       "{^name \"Ada\" ^city \"Raleigh\"}"
  test "assoc-in updates lists and node bodies":
    ck "(assoc-in [10 20 30] /1 99)", "[10 99 30]"
    ck "(assoc-in [10 20 30] /-1 99)", "[10 20 99]"
    ck "(assoc-in (quote (user ^name \"Ada\" 10 20)) /1 99)",
       "(user ^name \"Ada\" 10 99)"
  test "assoc-in preserves immutable container class":
    ck "(assoc-in #{^age 37} /age 38)", "#{^age 38}"
    ck "(assoc-in #[10 20] /1 99)", "#[10 99]"
  test "assoc-in writes void as delete for maps and nil for positions":
    ck "(assoc-in {^name \"Ada\" ^age 37} /age void)", "{^name \"Ada\"}"
    ck "(assoc-in (quote (user ^name \"Ada\" 10 20)) /0 void)",
       "(user ^name \"Ada\" nil 20)"
    ck "(assoc-in [10 20] /1 void)", "[10 nil]"
  test "assoc-in updates nested existing paths":
    ck "(var user {^address {^city \"Durham\"}}) (assoc-in user /address/city \"Raleigh\")",
       "{^address {^city \"Raleigh\"}}"
    ck "(var user (quote (user ^address (addr ^city \"Durham\")))) (assoc-in user /address/city \"Raleigh\")",
       "(user ^address (addr ^city \"Raleigh\"))"
  test "update-in applies a callable to the selected value":
    ck "(var user {^score 2}) (update-in user /score (fn [x] (+ x 1)))",
       "{^score 3}"
    ck "(var n (quote (user ^name \"Ada\"))) (update-in {^n n} /n /name)",
       "{^n \"Ada\"}"
  test "functional updates reject unsupported paths":
    expect GeneError: discard runStr("(assoc-in {^name \"Ada\"} /address/city \"Raleigh\")")
    expect GeneError: discard runStr("(assoc-in [1] /2 9)")
    expect GeneError: discard runStr("(assoc-in 1 /x 2)")
    expect GeneError: discard runStr("(update-in {^score 1} /score 1)")

suite "vm — entrypoint support":
  test "top-level bindings can be looked up and called after run":
    let scope = newGlobalScope()
    discard run(compileSource("(fn main [args] args/0)"), scope)
    var mainBinding: Value
    check scope.lookupOptional("main", mainBinding)
    check mainBinding.call(@[newList(@[newStr("Gene")])]).print() == "\"Gene\""

  test "optional lookup reports missing bindings without raising":
    let scope = newGlobalScope()
    var missing: Value
    check not scope.lookupOptional("main", missing)

suite "vm — namespaces":
  test "ns declares a namespace and binds it":
    ck "(ns math (var pi 3)) math", "(ns math)"
  test "qualified access reads namespace exports":
    ck "(ns math (var pi 3) (fn square [x] (* x x))) math/pi", "3"
    ck "(ns math (var pi 3) (fn square [x] (* x x))) (math/square 5)", "25"
  test "nested namespaces resolve through a qualified path":
    ck "(ns a (ns b (var x 42))) a/b/x", "42"
  test "ns body sees outer bindings and built-ins":
    ck "(var base 100) (ns m (var total (+ base 1))) m/total", "101"
  test "a missing namespace member is void":
    ck "(ns n (var a 1)) n/nope", "void"
  test "namespace exports do not leak into the enclosing scope":
    expect GeneError: discard runStr("(ns m (var secret 1)) secret")
  test "namespaces compare by identity":
    ck "(ns m (var a 1)) (= m m)", "true"

suite "vm — env and eval":
  test "env values are opaque display values":
    ck "(env)", "(env)"

  test "eval compiles and executes a quoted node inside env bindings":
    ck "(var e (env ^bindings {^x 10})) (eval (quote (+ x 5)) ^in e)", "15"

  test "eval sees explicit env bindings, not caller locals":
    ck "(var secret \"hidden\") (var e (env ^bindings {^x 1})) " &
       "(try (eval (quote secret) ^in e) catch {^message m} m)",
       "\"undefined symbol: secret\""

  test "env parent bindings are visible to eval":
    ck "(var base (env ^bindings {^x 10})) " &
       "(var child (env ^parent base ^bindings {^y 20})) " &
       "[(eval (quote x) ^in child) (eval (quote y) ^in child)]",
       "[10 20]"

  test "eval compile failures are typed CompileError values":
    ck "(try (eval (quote (var)) ^in (env)) " &
       "catch (CompileError ^message m) m)",
       "\"var requires a name or pattern\""

  test "Env annotations accept env values":
    ck "(fn run-it [e : Env] (eval (quote (+ 1 2)) ^in e)) (run-it (env))",
       "3"

  test "functions returned from eval retain their evaluation scope":
    ck "(var e (env ^bindings {^x 10})) " &
       "(var f (eval (quote (fn [] x)) ^in e)) (f)",
       "10"

suite "vm — cells":
  test "cell values are opaque display values":
    ck "(cell 0)", "(cell)"

  test "cell get and set mutate the referenced value":
    ck "(var c (cell 0)) [(c ~ Cell/get) (c ~ Cell/set 10) (c ~ Cell/get)]",
       "[0 10 10]"

  test "cell swap returns the old value":
    ck "(var c (cell \"a\")) [(c ~ Cell/swap \"b\") (c ~ Cell/get)]",
       "[\"a\" \"b\"]"

  test "cell update applies a callable and stores the result":
    ck "(var c (cell 1)) [(c ~ Cell/update (fn [x] (+ x 1))) (c ~ Cell/get)]",
       "[2 2]"

  test "cells compare by identity":
    ck "(var a (cell 1)) (var b (cell 1)) [(= a a) (= a b)]",
       "[true false]"

  test "Cell annotations accept cells only":
    ck "(fn read [c : Cell] (c ~ Cell/get)) (read (cell 3))", "3"
    expect GeneError:
      discard runStr("(fn read [c : Cell] c) (read 3)")

  test "env eval can mutate explicitly passed cells":
    ck "(var c (cell 0)) (var e (env ^bindings {^c c})) " &
       "(eval (quote (c ~ Cell/set 5)) ^in e) (c ~ Cell/get)",
       "5"

  test "cell operations require cells":
    expect GeneError: discard runStr("(Cell/get 1)")
    expect GeneError: discard runStr("(Cell/set (cell 1))")

suite "vm — printer view of callables":
  test "functions print a display form":
    ck "(fn [x] x)", "(fn)"                  # anonymous
    ck "(fn double [x] (* x 2))", "(fn double)"  # named form sets the name
    check runStr("+").print() == "(native-fn +)"
  test "namespaces print a display form":
    ck "(ns math (var pi 3))", "(ns math)"
