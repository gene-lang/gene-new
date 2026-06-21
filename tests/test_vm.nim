import gene/[compiler, gir, printer, types, vm]
import std/[strutils, unittest]

template ck(src, expected: string) =
  ## Compile and run a program string, then compare its printed result.
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

proc nativeEnvelopeEcho(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  if call == nil:
    raise newException(GeneError, "native envelope missing")
  var items = @[newStr(call[].calleeName), newInt(args.len),
                newInt(call[].namedNames.len)]
  if call[].namedNames.len > 0:
    items.add newSym(call[].namedNames[0])
    items.add call[].namedValues[0]
  if args.len > 0:
    items.add args[0]
  newList(items)

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
    check chunk.instructions[1].op == opDefineLocal
    check chunk.instructions[1].name == "inc"
    check chunk.localNames == @["inc"]
    check chunk.instructions[2].op == opReturn

    let proto = chunk.functions[0]
    check proto.name == "inc"
    check proto.params == @["x"]
    check proto.requiredPositional == 1
    check proto.simpleCall
    check proto.restParam == ""
    check proto.namedParams.len == 0
    check proto.chunk.instructions.len == 5
    check proto.chunk.instructions[0].op == opLoadName
    check proto.chunk.instructions[0].name == "+"
    check proto.chunk.instructions[^1].op == opReturn

  test "emits generic function type parameters":
    let chunk = compileSource("(fn (identity item) [x : item] : item x)")
    let proto = chunk.functions[0]
    check proto.name == "identity"
    check proto.typeParams == @["item"]
    check proto.params == @["x"]
    check proto.requiredPositional == 1
    check not proto.simpleCall
    check proto.paramTypes[0].print() == "item"
    check proto.returnType.print() == "item"

  test "emits local slots for function parameters and locals":
    let chunk = compileSource("(fn f [x ^scale s rest...] " &
                              "  (var y (+ x s)) " &
                              "  (set y (+ y 1)) " &
                              "  [y rest])")
    let proto = chunk.functions[0]
    check proto.localNames == @["x", "s", "rest", "y"]
    check proto.positionalSlots == @[0]
    check proto.namedSlots == @[1]
    check proto.restSlot == 2

    var sawLoadX = false
    var sawDefineY = false
    var sawSetY = false
    for inst in proto.chunk.instructions:
      if inst.op == opLoadLocal and inst.name == "x" and inst.intArg == 0:
        sawLoadX = true
      if inst.op == opDefineLocal and inst.name == "y" and inst.intArg == 3:
        sawDefineY = true
      if inst.op == opSetLocal and inst.name == "y" and inst.intArg == 3:
        sawSetY = true
    check sawLoadX
    check sawDefineY
    check sawSetY

  test "emits outer slots for recursive var-bound closures":
    let chunk = compileSource("(var fib (fn [n] (if (< n 2) n (fib (- n 1)))))")
    check chunk.localNames == @["fib"]
    let proto = chunk.functions[0]
    var sawOuterFib = false
    for inst in proto.chunk.instructions:
      if inst.op == opLoadOuterLocal and inst.name == "fib" and
          inst.depth == 1 and inst.intArg == 0:
        sawOuterFib = true
    check sawOuterFib

  test "emits slots for match branch bindings and outer updates":
    let chunk = compileSource(
      "(var total 0) (match [1 2] (when [a b] (set total (+ a b))))")
    check chunk.localNames == @["total"]
    let body = chunk.matches[0].clauses[0].body
    check body.localNames == @["a", "b"]
    var sawLoadA = false
    var sawSetTotal = false
    for inst in body.instructions:
      if inst.op == opLoadLocal and inst.name == "a" and inst.intArg == 0:
        sawLoadA = true
      if inst.op == opSetOuterLocal and inst.name == "total" and
          inst.depth == 1 and inst.intArg == 0:
        sawSetTotal = true
    check sawLoadA
    check sawSetTotal

  test "emits one branch slot for typed pattern binders":
    let chunk = compileSource("(match \"hi\" (when (s : Str) s))")
    let body = chunk.matches[0].clauses[0].body
    check body.localNames == @["s"]
    check body.instructions[0].op == opLoadLocal
    check body.instructions[0].name == "s"

  test "emits slots for for and catch child scopes":
    let loopChunk = compileSource(
      "(var total 0) (for [a b] [[1 2]] (set total (+ total a b)))")
    let loopBody = loopChunk.forLoops[0].body
    check loopBody.localNames == @["a", "b"]

    let tryChunk = compileSource("(try 1 catch {^message m} m)")
    let catchBody = tryChunk.tries[0].catches[0].body
    check catchBody.localNames == @["m"]
    check catchBody.instructions[0].op == opLoadLocal
    check catchBody.instructions[0].name == "m"

  test "normalizes checked error rows":
    let neverChunk = compileSource("(fn f ^errors [Never Never] [] 1)")
    check neverChunk.functions[0].checksErrors
    check neverChunk.functions[0].errorTypeCount == 0

    let dedupeChunk = compileSource("(fn f ^errors [Boom Never Boom] [] 1)")
    check dedupeChunk.functions[0].checksErrors
    check dedupeChunk.functions[0].errorTypeCount == 1

  test "emits slots for imported bindings":
    let selectedChunk = compileSource(
      "(import [foo, bar : baz] from \"./lib\") (fn use [] [foo baz])")
    check selectedChunk.localNames == @["foo", "baz", "use"]
    let selectedProto = selectedChunk.functions[0]
    var sawFoo = false
    var sawBaz = false
    for inst in selectedProto.chunk.instructions:
      if inst.op == opLoadOuterLocal and inst.name == "foo" and
          inst.depth == 1 and inst.intArg == 0:
        sawFoo = true
      if inst.op == opLoadOuterLocal and inst.name == "baz" and
          inst.depth == 1 and inst.intArg == 1:
        sawBaz = true
    check sawFoo
    check sawBaz

    let aliasChunk = compileSource(
      "(import std/stream ^as stream) (fn use [] stream)")
    check aliasChunk.localNames == @["stream", "use"]
    check aliasChunk.functions[0].chunk.instructions[0].op == opLoadOuterLocal
    check aliasChunk.functions[0].chunk.instructions[0].name == "stream"
    check aliasChunk.functions[0].chunk.instructions[0].intArg == 0

  test "emits slots for namespace declarations and captures":
    let chunk = compileSource(
      "(var base 1) (ns math (fn get [] base)) (fn use [] math)")
    check chunk.localNames == @["base", "math", "use"]

    let nsChunk = chunk.subchunks[0]
    check nsChunk.localNames == @["get"]
    var sawBaseCapture = false
    for inst in nsChunk.functions[0].chunk.instructions:
      if inst.op == opLoadOuterLocal and inst.name == "base" and
          inst.depth == 2 and inst.intArg == 0:
        sawBaseCapture = true
    check sawBaseCapture

    let useProto = chunk.functions[0]
    check useProto.chunk.instructions[0].op == opLoadOuterLocal
    check useProto.chunk.instructions[0].name == "math"
    check useProto.chunk.instructions[0].depth == 1
    check useProto.chunk.instructions[0].intArg == 1

  test "emits slots for generated protocol messages":
    let chunk = compileSource(
      "(protocol P (message ping [x])) (fn use [x] (ping x))")
    check chunk.localNames == @["ping", "P", "use"]

    let useProto = chunk.functions[0]
    var sawPing = false
    for inst in useProto.chunk.instructions:
      if inst.op == opLoadOuterLocal and inst.name == "ping" and
          inst.depth == 1 and inst.intArg == 0:
        sawPing = true
    check sawPing

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

  test "emits runtime construction for value-position spreads":
    let callChunk = compileSource("(f xs... 3)")
    var sawCallSplice = false
    for inst in callChunk.instructions:
      if inst.op == opCallSplice:
        sawCallSplice = true
        check callChunk.listBuilds[inst.intArg].splices == @[true, false]
    check sawCallSplice

    let postfixCallChunk = compileSource("(f [1 2]... 3)")
    sawCallSplice = false
    for inst in postfixCallChunk.instructions:
      if inst.op == opCallSplice:
        sawCallSplice = true
        check postfixCallChunk.listBuilds[inst.intArg].splices == @[true, false]
    check sawCallSplice

    let listChunk = compileSource("[1 xs... 4]")
    var sawListSplice = false
    for inst in listChunk.instructions:
      if inst.op == opMakeListSplice:
        sawListSplice = true
        check listChunk.listBuilds[inst.intArg].splices == @[false, true, false]
    check sawListSplice

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
    check proto.requiredPositional == 1
    check not proto.simpleCall

  test "emits typed var boundary checks":
    let chunk = compileSource("(var x : Int 1)")
    check chunk.localNames == @["x"]
    check chunk.instructions[0].op == opPushConst
    check chunk.instructions[1].op == opCheckType
    check chunk.instructions[1].name == "var 'x'"
    check chunk.constants[chunk.instructions[1].intArg].print() == "Int"
    check chunk.instructions[2].op == opDefineLocal
    check chunk.instructions[2].name == "x"
    check chunk.instructions[3].op == opDeclareType
    check chunk.instructions[3].name == "x"
    check chunk.constants[chunk.instructions[3].intArg].print() == "Int"

  test "compile errors use the runtime error channel":
    expect GeneError: discard compileSource("(var)")
    expect GeneError: discard compileSource("(var x :)")
    expect GeneError: discard compileSource("(fn missing-params 1)")
    expect GeneError: discard compileSource("(fn bad [^])")
    expect GeneError: discard compileSource("(fn bad [xs... y] y)")
    expect GeneError: discard compileSource("(fn bad [xs... ^scale] scale)")
    expect GeneError: discard compileSource("(fn bad [x? y] y)")
    expect GeneError: discard compileSource("(fn bad [x? ys...] ys)")
    expect GeneError: discard compileSource("(fn bad [xs... = 1] xs)")
    expect GeneError: discard compileSource("(fn bad [x =] x)")
    expect GeneError: discard compileSource("(fn (bad 1) [x] x)")
    expect GeneError: discard compileSource("(fn (bad t t) [x] x)")

  test "leading flipped calls require lexical self":
    expect GeneError: discard compileSource("(~ + 1)")
    ck "(fn inc [self] (~ + 1)) (inc 2)", "3"

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
  test "value-position spread flattens lists and nodes":
    ck "(var xs [2 3]) (+ 1 xs... 4)", "10"
    ck "(var xs [2 3]) [1 xs... 4]", "[1 2 3 4]"
    ck "(var xs #[2 3]) #[1 xs...]", "#[1 2 3]"
    ck "(var n (quote (pair 2 3))) [1 n... 4]", "[1 2 3 4]"
    ck "(var xs [[2 3]]) [1 xs/0... 4]", "[1 2 3 4]"
    ck "[1 [2 3]... 4]", "[1 2 3 4]"
    ck "(var f (fn [x ^scale, ys...] [x scale ys])) " &
       "(f ^scale 9 [1 2]... 3)",
       "[1 9 [2 3]]"
    expect GeneError:
      discard runStr("(var x 1) (+ x...)")
    expect GeneError:
      discard runStr("(+ ... [1])")
  test "map evaluates its values":
    ck "{^a (+ 1 1) ^b 3}", "{^a 2 ^b 3}"
  test "map and node storage drops void props":
    ck "{^a void ^b 1}", "{^b 1}"
    ck "(quote (x ^a void ^b 1 @m void @n 2))", "(x @n 2 ^b 1)"
  test "quote suppresses evaluation":
    ck "(quote (+ 1 2))", "(+ 1 2)"
    ck "(quote (~ f a))", "(~ f a)"

suite "vm — strings and interpolation":
  test "to-str converts values to display text":
    ck "[(to-str \"Ada\") (to-str (quote (user ^name \"Ada\")))]",
       "[\"Ada\" \"(user ^name \\\"Ada\\\")\"]"

  test "strings iterate explicitly by chars and bytes":
    ck "[(chars \"Aé\") (bytes \"Aé\")]", "[['A' 'é'] [65 195 169]]"
    ck "(try (chars 1) catch {^message m} m)", "\"chars expects a Str\""
    ck "(try (bytes) catch {^message m} m)",
       "\"bytes expects 1 argument, got 0\""

  test "graphemes group combining scalars":
    let s = "e\u0301x"
    ck "(var s \"" & s & "\") [(chars s) (graphemes s) (bytes s)]",
       "[['e' '\u0301' 'x'] [\"e\u0301\" \"x\"] [101 204 129 120]]"
    ck "(try (graphemes 1) catch {^message m} m)",
       "\"graphemes expects a Str\""

  test "dollar concatenates display text":
    ck "(var concat $) (concat \"name=\" \"Ada\" \" score=\" 10)",
       "\"name=Ada score=10\""

  test "interpolated strings execute through dollar":
    ck "(var name \"Ada\") $\"hello ${name}\"", "\"hello Ada\""
    ck "$\"sum = $(+ 1 2)\"", "\"sum = 3\""

suite "vm — quasiquote templates":
  test "quasiquote evaluates unquoted body values":
    ck "(var name \"Ada\") `(hello %name)", "(hello \"Ada\")"

  test "quasiquote evaluates unquoted heads, props, and map values":
    ck "(var h (quote button)) (var cls \"primary\") " &
       "`(%h ^class %cls {^label %cls})",
       "(button ^class \"primary\" {^label \"primary\"})"
  test "quasiquote drops void props and map entries":
    ck "(var skip void) `(x ^a %skip ^b 1 {^a %skip ^b 1})",
       "(x ^b 1 {^b 1})"

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

suite "vm — macros":
  test "macro calls bind named syntax props":
    ck "(macro scaled! [value ^by n] `(+ %value %n)) " &
       "(scaled! ^by 3 7)",
       "10"
    ck "(macro scaled! [value ^by amount] `(+ %value %amount)) " &
       "(scaled! ^by 4 9)",
       "13"
    ck "(macro tagged! [value ^tag t] `(quote (%t %value))) " &
       "(tagged! ^tag item 7)",
       "(item 7)"
    expect GeneError:
      discard runStr("(macro scaled! [value ^by n] `(+ %value %n)) " &
                     "(scaled! 7)")
    expect GeneError:
      discard runStr("(macro scaled! [value ^by n] `(+ %value %n)) " &
                     "(scaled! ^other 3 7)")

  test "macro parameters destructure syntax patterns":
    ck "(macro second! [[_ value]] `%value) " &
       "(second! [ignored (+ 1 2)])",
       "3"
    ck "(macro pick-prop! [{^value v}] `%v) " &
       "(pick-prop! {^value (+ 2 3)})",
       "5"
    ck "(macro call-arg! [(call ^arg v)] `%v) " &
       "(call-arg! (call ^arg (+ 4 5)))",
       "9"
    ck "(macro rest-items! [[head tail...]] `(quote %tail)) " &
       "(rest-items! [1 2 3])",
       "[2 3]"
    ck "(macro eval-node! [(form : Node)] `%form) " &
       "(eval-node! (+ 1 2))",
       "3"
    ck "(macro eval-flat! [form : Node] `%form) " &
       "(eval-flat! (+ 2 3))",
       "5"
    ck "(macro keep-syms! [(items : (List Sym))] `(quote %items)) " &
       "(keep-syms! [a b])",
       "[a b]"
    ck "(macro keep-entry! [^entry item : (List Sym)] `(quote %item)) " &
       "(keep-entry! ^entry [a b])",
       "[a b]"
    expect GeneError:
      discard runStr("(macro eval-node! [(form : Node)] `%form) " &
                     "(eval-node! 1)")
    expect GeneError:
      discard runStr("(macro eval-flat! [form : Node] `%form) " &
                     "(eval-flat! 1)")
    expect GeneError:
      discard runStr("(macro keep-syms! [(items : (List Sym))] `(quote %items)) " &
                     "(keep-syms! [a 1])")
    ck "(macro named-pair! [^entry [k v]] `(+ %k %v)) " &
       "(named-pair! ^entry [2 3])",
       "5"
    expect GeneError:
      discard runStr("(macro second! [[_ value]] `%value) " &
                     "(second! [only-one])")
    ck "(macro default-value! [x = 7] `%x) " &
       "[(default-value!) (default-value! 9)]",
       "[7 9]"
    ck "(macro second-or-first! [x y = x] `%y) " &
       "[(second-or-first! (+ 1 2)) (second-or-first! 1 4)]",
       "[3 4]"
    ck "(macro named-default! [^value v = (+ 2 3)] `%v) " &
       "[(named-default!) (named-default! ^value 8)]",
       "[5 8]"
    ck "(macro optional! [x?] `%x) (optional!)", "void"
    expect GeneError:
      discard compileSource("(macro bad! [x = 1 y] `%y)")

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
  test "integer arithmetic promotes beyond int64":
    ck "(+ 9223372036854775807 1)", "9223372036854775808"
    ck "(+ 9223372036854775808 -9223372036854775808)", "0"
    ck "(- -9223372036854775808 1)", "-9223372036854775809"
    ck "(- -9223372036854775808)", "9223372036854775808"
    ck "(* 100000000000000000000 100000000000000000000)",
       "10000000000000000000000000000000000000000"
    ck "(* -9223372036854775808 -1)", "9223372036854775808"
    ck "(/ 10000000000000000000000000000000000000000 " &
       "   100000000000000000000)",
       "100000000000000000000"
    ck "(/ -100000000000000000000 3)", "-33333333333333333333"
    ck "(/ 100000000000000000000 -3)", "-33333333333333333333"
    ck "(/ -9223372036854775808 -1)", "9223372036854775808"
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
    ck "(< 9223372036854775808 9223372036854775809)", "true"
    ck "(= (+ 9223372036854775807 1) 9223372036854775808)", "true"
    ck "(< 1 3 2)", "false"
    ck "(>= 3 3 1)", "true"
  test "structural equality":
    ck "(= 2 2)", "true"
    ck "(= [1 2] [1 2])", "true"
    ck "(= 1 2)", "false"
  test "hash follows stable structural equality":
    ck "(= (hash #[1 2]) (hash (freeze [1 2])))", "true"
    ck "(= (hash (quote #(x @line 1 ^a 2))) " &
       "   (hash (quote #(x @line 99 ^a 2))))", "true"
    ck "(try (hash [1 2]) catch {^message m} m)",
       "\"hash expects a hash-stable value\""
    ck "(try (hash #[(cell 1)]) catch {^message m} m)",
       "\"hash expects a hash-stable value\""
    expect GeneError: discard runStr("(hash)")
  test "same compares scalar values and heap identity":
    ck "(same? 2 2)", "true"
    ck "(same? \"x\" \"x\")", "true"
    ck "(same? [1 2] [1 2])", "false"
    ck "(var xs [1 2]) (same? xs xs)", "true"
    expect GeneError: discard runStr("(same? 1)")
  test "freeze and thaw convert container mutability explicitly":
    ck "(freeze-shallow [1 [2]])", "#[1 [2]]"
    ck "(freeze [1 {^a [2]}])", "#[1 #{^a #[2]}]"
    ck "(thaw (freeze [1 {^a [2]}]))", "[1 {^a [2]}]"
    ck "(try (freeze [(cell 1)]) catch {^message m} m)",
       "\"freeze cannot freeze Cell\""
    expect GeneError: discard runStr("(freeze)")
  test "not":
    ck "(not false)", "true"
    ck "(not nil)", "true"
    ck "(not 1)", "false"

suite "vm — special forms":
  test "derive is reserved for protocol-local use only":
    expect GeneError:
      discard compileSource("(derive [t req] nil)")

  test "task scopes, spawn, and await produce completed Task values":
    ck "(scope (var a (spawn (+ 1 2))) (await a))", "3"
    ck "(scope (var t : (Task Int Never) (spawn 1)) t)", "(task)"
    ck "(scope (var t (spawn 1)) (t ~ Task/cancel))", "nil"

  test "task scope and spawn bodies are branch-local":
    expect GeneError:
      discard runStr("(scope (var local 1) local) local")
    expect GeneError:
      discard runStr("(supervisor ^strategy stop (var local 1) local) local")
    expect GeneError:
      discard runStr("(scope (var t (spawn (do (var child 1) child))) " &
                     "(await t) child)")
    ck "(var scope 3) scope", "3"
    ck "(var spawn 1) spawn", "1"
    ck "(var await 2) await", "2"
    ck "(var supervisor 4) supervisor", "4"

  test "await propagates recoverable task errors":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(scope (var t (spawn (fail (Boom ^message \"x\")))) " &
       "  (try (await t) catch (Boom ^message m) m))",
       "\"x\""

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
  test "typed var checks gradual boundaries":
    ck "(var x : Int 5) (+ x 1)", "6"
    ck "(var maybe : (opt Int)) maybe", "nil"
    ck "(try (var x : Int \"no\") x catch (TypeError ^where w) w)",
       "\"var 'x'\""
    ck "(type Request ^props {^path Str}) " &
       "(fn app [raw] (var req : Request raw) req/path) " &
       "(app (Request ^path \"/\"))",
       "\"/\""
    ck "(try (var s : (Stream Int Never) (to_stream [\"bad\"])) " &
       "     (s ~ Stream/next) " &
       "catch (TypeError ^where w) w)",
       "\"Stream/next item\""
  test "set reassigns an existing binding":
    ck "(var x 1) (set x 99) x", "99"
  test "set checks typed binding boundaries":
    ck "(var x : Int 1) (set x 2) x", "2"
    ck "(try (var x : Int 1) (set x \"bad\") x " &
       "catch (TypeError ^where w) w)",
       "\"set 'x'\""
    ck "(try (fn f [x : Int] (set x \"bad\") x) (f 1) " &
       "catch (TypeError ^where w) w)",
       "\"set 'x'\""
    ck "(try (fn f [^x : Int] (set x \"bad\") x) (f ^x 1) " &
       "catch (TypeError ^where w) w)",
       "\"set 'x'\""
    ck "(try (fn (f item) [x : item] (set x \"bad\") x) (f 1) " &
       "catch (TypeError ^where w) w)",
       "\"set 'x'\""
    ck "(try (fn outer [] (var x : Int 1) (fn [] (set x \"bad\"))) " &
       "     ((outer)) " &
       "catch (TypeError ^where w) w)",
       "\"set 'x'\""
  test "slotted conditional locals remain undefined when not executed":
    ck "((fn [flag] (if flag (var x 1) nil) x) true)", "1"
    expect GeneError:
      discard runStr("((fn [flag] (if flag (var x 1) nil) x) false)")
  test "set on an undefined name raises":
    expect GeneError: discard runStr("(set nope 1)")
  test "undefined symbol raises":
    expect GeneError: discard runStr("nope")
  test "duplicate bindings in one scope are rejected":
    expect GeneError: discard runStr("(var x 1) (var x 2)")
    expect GeneError: discard runStr("(fn f [] 1) (fn f [] 2)")
    ck "(var x 1) (set x 2) x", "2"

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
  test "closures see updates to slot-backed locals":
    ck "(fn outer [x] (var get (fn [] x)) (set x 2) (get)) (outer 1)", "2"
  test "default expressions see earlier slot-backed parameters":
    ck "((fn [x y = x] y) 7)", "7"
  test "recursion via a var-bound self reference":
    ck "(var fib (fn [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib 10)", "55"
  test "recursion via a named function declaration":
    ck "(fn fib [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10)", "55"
  test "deep non-tail recursion runs on the heap frame stack, not the Nim stack":
    # Pre-trampoline this recursed one Nim frame per call and overflowed the
    # OS stack. Now simple calls push heap Frames, so deep call chains succeed.
    ck "(fn count [n] (if (= n 0) 0 (+ 1 (count (- n 1))))) (count 200000)",
       "200000"
  test "deep recursion through a typed (general-path) function uses heap frames":
    # Typed params / return types take the general call path; it is now on the
    # frame stack too, so deep recursion through it no longer grows the Nim stack.
    ck "(fn count [n : Int] : Int (if (= n 0) 0 (+ 1 (count (- n 1))))) " &
       "(count 200000)", "200000"
  test "deep recursion through an ^errors function uses heap frames":
    # ^errors functions also push heap frames now; the loop's exception handler
    # applies the undeclared-error boundary on unwind, so deep recursion through
    # a checked function no longer grows the Nim stack on the success path.
    ck "(fn count ^errors [] [n] (if (= n 0) 0 (+ 1 (count (- n 1))))) " &
       "(count 200000)", "200000"
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
  test "native call envelope carries named arguments":
    let scope = newGlobalScope()
    scope.define("native-envelope",
                 newNativeCallFn("native-envelope", nativeEnvelopeEcho))
    check run(compileSource("(native-envelope ^scale 3 4)"), scope).print() ==
      "[\"native-envelope\" 1 1 scale 3 4]"

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
    ck "(var xs [10 20 30]) [xs/empty? xs/first xs/last]",
       "[false 10 30]"
    ck "(var xs []) [xs/empty? xs/first xs/last]", "[true void void]"
  test "selectors read node props, body indexes, and projections":
    ck "(var n (quote (user ^name \"Ada\" 10 20))) n/name", "\"Ada\""
    ck "(var n (quote (user ^name \"Ada\" 10 20))) n/1", "20"
    ck "(var n (quote (user ^name \"Ada\" 10 20))) n/head", "user"
    ck "(var n (quote (user ^name \"Ada\" 10 20))) n/body", "[10 20]"
  test "selector calls validate their call envelope":
    expect GeneError: discard runStr("(/name)")
    expect GeneError: discard runStr("(/name ^unused 1 {^name \"Ada\"})")

  test "static selector lookup maps over streams and skips void":
    ck "(var users [{^name \"Ada\"} {^age 37} {^name \"Bob\"}]) " &
       "(var names users/%to_stream/name) " &
       "[(names ~ Stream/next) (names ~ Stream/next) (names ~ Stream/has_next)]",
       "[\"Ada\" \"Bob\" false]"

  test "first-class selectors map over streams":
    ck "(var get-name /name) " &
       "(var names (get-name (to_stream [{^name \"Ada\"} {^name \"Bob\"}]))) " &
       "[(names ~ Stream/next) (names ~ Stream/next) (names ~ Stream/has_next)]",
       "[\"Ada\" \"Bob\" false]"

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
  test "dynamic selector keys can be forced explicitly":
    ck "(var field \"name\") " &
       "(var get (select %(key field))) " &
       "(get {^name \"Ada\"})",
       "\"Ada\""
    ck "(var plus +) " &
       "[((select %plus) 4) ((select %(key plus)) 4)]",
       "[4 void]"
    ck "(var field \"name\") " &
       "(var users [{^name \"Ada\"} {^age 37} {^name \"Bob\"}]) " &
       "(var names ((select %to_stream %(key field)) users)) " &
       "[(names ~ Stream/next) (names ~ Stream/next) (names ~ Stream/has_next)]",
       "[\"Ada\" \"Bob\" false]"
  test "complex selector stages adapt stream helpers":
    ck "(var users [{^name \"Ada\" ^adult true} " &
       "            {^name \"Tim\" ^adult false} " &
       "            {^name \"Bob\" ^adult true}]) " &
       "(var names ((select %to_stream %(filter /adult) name) users)) " &
       "[(names ~ Stream/next) (names ~ Stream/next) (names ~ Stream/has_next)]",
       "[\"Ada\" \"Bob\" false]"
    ck "(var users [{^name \"Ada\"} {^name \"Bob\"} {^name \"Cy\"}]) " &
       "((select %to_stream %(map /name) %(take 2) %(into [])) users)",
       "[\"Ada\" \"Bob\"]"

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

suite "vm — container update built-ins":
  test "List/assoc returns an updated copy":
    ck "(var xs #[1 2 3]) (var ys (xs ~ List/assoc 1 20)) [xs ys]",
       "[#[1 2 3] #[1 20 3]]"
    ck "([1 2] ~ List/assoc 1 void)", "[1 nil]"

  test "List/set! mutates mutable lists":
    ck "(var xs [1 2]) [(xs ~ List/set! 1 9) xs]", "[9 [1 9]]"
    ck "(var xs [1 2]) [(xs ~ List/set! 0 void) xs]", "[nil [nil 2]]"
    expect GeneError:
      discard runStr("(#[1] ~ List/set! 0 2)")

  test "Map/put! mutates mutable maps":
    ck "(var m {^a 1}) [(m ~ Map/put! \"b\" 2) (m ~ /b)]", "[2 2]"
    ck "(var m {^a 1}) [(m ~ Map/put! \"a\" void) (m ~ /a)]", "[void void]"
    expect GeneError:
      discard runStr("(#{^a 1} ~ Map/put! \"a\" 2)")
  test "Map/assoc returns an updated copy":
    ck "(var m #{^a 1}) (var n (m ~ Map/assoc \"b\" 2)) [m n]",
       "[#{^a 1} #{^a 1 ^b 2}]"
    ck "({^a 1} ~ Map/assoc \"a\" void)", "{}"
    expect GeneError: discard runStr("(Map/assoc [1] \"a\" 2)")
  test "Map/get reads entries without selector staging":
    ck "(var m {^a 1}) [(m ~ Map/get \"a\") (m ~ Map/get \"missing\")]",
       "[1 void]"
    ck "(var m {^a 1}) (m ~ Map/get (quote a))", "1"
    expect GeneError: discard runStr("(Map/get [1] \"a\")")

  test "Node/set-prop! mutates mutable node props":
    ck "(var n (quote (user ^name \"Ada\"))) " &
       "[(n ~ Node/set-prop! \"name\" \"Bob\") (n ~ /name)]",
       "[\"Bob\" \"Bob\"]"
    ck "(var n (quote (user ^name \"Ada\"))) " &
       "[(n ~ Node/set-prop! \"name\" void) (n ~ /name)]",
       "[void void]"
    expect GeneError:
      discard runStr("(#(user ^name \"Ada\") ~ Node/set-prop! \"name\" \"Bob\")")

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
  test "ns rejects duplicate local bindings only":
    expect GeneError: discard runStr("(ns m (var x 1) (var x 2))")
    ck "(var x 1) (ns m (var x 2)) [x (/x m)]", "[1 2]"
  test "a missing namespace member is void":
    ck "(ns n (var a 1)) n/nope", "void"
  test "namespace exports do not leak into the enclosing scope":
    expect GeneError: discard runStr("(ns m (var secret 1)) secret")
  test "namespaces compare by identity":
    ck "(ns m (var a 1)) (= m m)", "true"
  test "namespace reflection exposes bindings and lookup":
    ck "(ns m (var b 2) (var a 1)) [(Namespace/lookup m \"a\") (Namespace/lookup m \"missing\")]",
       "[1 void]"
    ck "(ns m (var b 2) (var a 1)) (Namespace/bindings m)",
       "{^a 1 ^b 2}"
  test "declarations exposes namespace bindings as a stream":
    ck "(ns m (var b 2) (var a 1)) " &
       "(var names m/%declarations/name) " &
       "[(names ~ Stream/next) (names ~ Stream/next) (names ~ Stream/has_next)]",
       "[\"a\" \"b\" false]"
    ck "(ns m (var a 1)) (var ds (Namespace/declarations m)) (ds ~ Stream/next)",
       "(Declaration ^name \"a\" ^kind \"Int\" ^value 1)"
  test "namespace reflection operations require namespaces":
    expect GeneError: discard runStr("(declarations [1])")
    expect GeneError: discard runStr("(Namespace/bindings [1])")
    expect GeneError: discard runStr("(Namespace/lookup [1] \"a\")")

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

  test "env child bindings shadow parent bindings":
    ck "(var base (env ^bindings {^x 10})) " &
       "(var child (env ^parent base ^bindings {^x 20})) " &
       "(eval (quote x) ^in child)",
       "20"

  test "eval sees explicit Env capabilities":
    ck "(var e (env ^capabilities {^fs \"sandbox\"})) " &
       "(eval (quote fs) ^in e)",
       "\"sandbox\""
    ck "(var e (env ^bindings {^fs \"binding\"} " &
       "           ^capabilities {^fs \"capability\"})) " &
       "(eval (quote fs) ^in e)",
       "\"binding\""
    ck "(var base (env ^capabilities {^fs \"sandbox\"})) " &
       "(var child (base ~ Env/extend {^x 1})) " &
       "(eval (quote [fs x]) ^in child)",
       "[\"sandbox\" 1]"
    expect GeneError:
      discard runStr("(env ^capabilities [1])")

  test "eval policy max-steps limits execution":
    ck "(eval (quote (+ 1 2)) ^in (env ^policy {^max-steps 20}))",
       "3"
    ck "(type EvalPolicy ^props {^max-steps Int " &
       "                         ^allow-ffi? Bool " &
       "                         ^allow-native-compile? Bool}) " &
       "(var p (EvalPolicy ^max-steps 20 " &
       "                   ^allow-ffi false " &
       "                   ^allow-native-compile false)) " &
       "(eval (quote (+ 1 2)) ^in (env ^policy p))",
       "3"
    ck "(try (eval (quote (while true nil)) " &
       "           ^in (env ^policy {^max-steps 20})) " &
       "catch {^message m} m)",
       "\"eval max steps exceeded\""
    ck "(try (eval (quote (eval (quote (while true nil)) ^in (env))) " &
       "           ^in (env ^policy {^max-steps 40})) " &
       "catch {^message m} m)",
       "\"eval max steps exceeded\""
    expect GeneError:
      discard runStr("(env ^policy [1])")
    expect GeneError:
      discard runStr("(env ^policy {^max-steps \"bad\"})")
    expect GeneError:
      discard runStr("(env ^policy {^max-steps -1})")
    expect GeneError:
      discard runStr("(env ^policy {^max-memory-mb 128})")
    expect GeneError:
      discard runStr("(env ^policy {^timeout-ms 5000})")
    expect GeneError:
      discard runStr("(env ^policy {^allow-ffi true})")
    expect GeneError:
      discard runStr("(env ^policy {^allow-native-compile true})")
    expect GeneError:
      discard runStr("(env ^policy {^allow-ffi 1})")
    expect GeneError:
      discard runStr("(env ^policy {^max-step 20})")

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

suite "vm — atomic cells":
  test "atomic cell values are opaque display values":
    ck "(atomic-cell 0)", "(atomic-cell)"

  test "atomic cell load, store, and swap mutate the referenced value":
    ck "(var a (atomic-cell 0)) " &
       "[(a ~ AtomicCell/load) (a ~ AtomicCell/store 10) " &
       " (a ~ AtomicCell/swap 20) (a ~ AtomicCell/load)]",
       "[0 10 10 20]"

  test "atomic compare-exchange stores when the expected value matches":
    ck "(var a (atomic-cell 2)) " &
       "[(a ~ AtomicCell/compare-exchange 2 3) " &
       " (a ~ AtomicCell/load) " &
       " (a ~ AtomicCell/compare-exchange 2 4) " &
       " (a ~ AtomicCell/load)]",
       "[true 3 false 3]"

  test "atomic cells compare by identity":
    ck "(var a (atomic-cell 1)) (var b (atomic-cell 1)) [(= a a) (= a b)]",
       "[true false]"

  test "AtomicCell annotations accept atomic cells only":
    ck "(fn read [a : AtomicCell] (a ~ AtomicCell/load)) (read (atomic-cell 3))",
       "3"
    expect GeneError:
      discard runStr("(fn read [a : AtomicCell] a) (read (cell 3))")

  test "atomic cell operations require atomic cells":
    expect GeneError: discard runStr("(AtomicCell/load 1)")
    expect GeneError: discard runStr("(AtomicCell/store (atomic-cell 1))")

suite "vm — channels":
  test "channel values are opaque display values":
    ck "(channel)", "(channel)"

  test "channels send and receive FIFO values":
    ck "(var ch (channel ^capacity 2)) " &
       "(ch ~ Channel/send 1) " &
       "(ch ~ Channel/send 2) " &
       "[(ch ~ Channel/recv) (ch ~ Channel/recv)]",
       "[1 2]"

  test "try-send and try-recv are non-blocking":
    ck "(var ch (channel ^capacity 1)) " &
       "[(ch ~ Channel/try-send 1) " &
       " (ch ~ Channel/try-send 2) " &
       " (ch ~ Channel/recv) " &
       " (same? (ch ~ Channel/try-recv) void)]",
       "[true false 1 true]"

  test "closed channels drain buffered values before ChannelClosed":
    ck "(var ch (channel ^capacity 1)) " &
       "(ch ~ Channel/send 9) " &
       "(ch ~ Channel/close) " &
       "[(ch ~ Channel/recv) " &
       " (try (ch ~ Channel/recv) catch (ChannelClosed ^message m) m)]",
       "[9 \"channel is closed\"]"
    ck "(var ch (channel)) " &
       "(ch ~ Channel/close) " &
       "(try (ch ~ Channel/send 1) catch (ChannelClosed ^message m) m)",
       "\"channel is closed\""

  test "typed channels check items on send":
    ck "(var ch : (Channel Int) (channel)) " &
       "(try (ch ~ Channel/send \"bad\") catch (TypeError ^where w) w)",
       "\"Channel/send item\""
    ck "(var ch : (Channel Int) (channel)) " &
       "(ch ~ Channel/send 7) " &
       "(ch ~ Channel/recv)",
       "7"
    ck "(var raw (channel)) " &
       "(raw ~ Channel/send \"bad\") " &
       "(var ch : (Channel Int) raw) " &
       "(try (ch ~ Channel/recv) catch (TypeError ^where w) w)",
       "\"Channel/recv item\""

  test "channel sends require Send values":
    ck "(var ch (channel)) " &
       "(ch ~ Channel/send #[1 #{^a 2}]) " &
       "(ch ~ Channel/recv)",
       "#[1 #{^a 2}]"
    ck "(var ch (channel)) " &
       "(var captured #[1 #{^a 2}]) " &
       "(var f (fn [] captured)) " &
       "(ch ~ Channel/send f) " &
       "(var g (ch ~ Channel/recv)) " &
       "(g)",
       "#[1 #{^a 2}]"
    ck "(var ch (channel)) " &
       "(var f (fn [x y = x] y)) " &
       "(ch ~ Channel/send f) " &
       "(var g (ch ~ Channel/recv)) " &
       "(g 7)",
       "7"
    ck "(var ch (channel)) " &
       "(try (ch ~ Channel/send [1]) catch (TypeError ^expected e) e)",
       "\"Send\""
    ck "(var ch (channel)) " &
       "(try (ch ~ Channel/send #[(cell 1)]) catch (TypeError ^where w) w)",
       "\"Channel/send item\""
    ck "(var ch (channel)) " &
       "(var captured (cell 1)) " &
       "(var f (fn [] (captured ~ Cell/get))) " &
       "(try (ch ~ Channel/send f) catch (TypeError ^expected e) e)",
       "\"Send\""
    ck "(var ch (channel)) " &
       "(var captured 1) " &
       "(var f (fn [] (set captured (+ captured 1)))) " &
       "(try (ch ~ Channel/send f) catch (TypeError ^expected e) e)",
       "\"Send\""
    ck "(type Msg ^props {^x Int} ^impl [Send]) " &
       "(impl Send Msg) " &
       "(var ch (channel)) " &
       "(ch ~ Channel/send (Msg ^x 7)) " &
       "(var msg (ch ~ Channel/recv)) " &
       "msg/x",
       "7"

  test "channel operations require channels":
    expect GeneError: discard runStr("(channel ^capacity 0)")
    expect GeneError: discard runStr("(Channel/send 1 2)")
    expect GeneError: discard runStr("(Channel/recv 1)")

suite "vm — cooperative scheduler":
  test "a task blocked on recv is woken by a sender task":
    # The consumer parks on an empty channel; the producer's send wakes it and the
    # whole task resumes — real cooperative suspension across the frame stack.
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var c (spawn (ch ~ Channel/recv))) " &
       "  (var p (spawn (ch ~ Channel/send 7))) " &
       "  (await c))", "7"
  test "a producer that fills the channel parks until the root drains it":
    # send on a full channel parks the producer fiber; each root recv frees space
    # and wakes it to push the next value.
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var p (spawn (do (ch ~ Channel/send 1) (ch ~ Channel/send 2) 99))) " &
       "  (var a (ch ~ Channel/recv)) (var b (ch ~ Channel/recv)) " &
       "  [a b (await p)])", "[1 2 99]"
  test "multiple producers blocked on a full channel are all drained":
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var p1 (spawn (ch ~ Channel/send 10))) " &
       "  (var p2 (spawn (ch ~ Channel/send 20))) " &
       "  (+ (ch ~ Channel/recv) (ch ~ Channel/recv)))", "30"
  test "suspension preserves a deep call chain across the channel block":
    # The recv happens inside a nested call; resuming restores the whole frame
    # stack, so the caller continues correctly after the value arrives.
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (fn get-one [c] (+ 1 (c ~ Channel/recv))) " &
       "  (var t (spawn (get-one ch))) " &
       "  (var p (spawn (ch ~ Channel/send 41))) " &
       "  (await t))", "42"
  test "await with no way to make progress is a deadlock error":
    expect GeneError:
      discard runStr("(scope (var ch (channel ^capacity 1)) " &
                     "  (var c (spawn (ch ~ Channel/recv))) " &
                     "  (await c))")

suite "vm — actors":
  test "actor values are opaque display values":
    ck "(actor/spawn ^init (fn [] 0) " &
       "             ^handle (fn [ctx state msg] (actor/continue state)))",
       "(actor)"

  test "actor send processes messages sequentially":
    ck "(var out (cell 0)) " &
       "(fn handle [ctx state msg] : (ActorStep Int) " &
       "  (var next (+ state msg)) " &
       "  (out ~ Cell/set next) " &
       "  (actor/continue next)) " &
       "(var counter : (ActorRef Int) " &
       "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(counter ~ actor/send 2) " &
       "(counter ~ actor/send 5) " &
       "(out ~ Cell/get)",
       "7"

  test "actor stop closes the actor":
    ck "(var a : (ActorRef Int) " &
       "  (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] (actor/stop)))) " &
       "(a ~ actor/send 1) " &
       "(try (a ~ actor/send 2) catch (ActorClosed ^message m) m)",
       "\"actor is closed\""
    ck "(var a : (ActorRef Int) " &
       "  (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] (actor/stop)))) " &
       "(a ~ actor/send 1) " &
       "(a ~ actor/try-send 2)",
       "false"

  test "actor sends check message type and Send":
    ck "(var a : (ActorRef Int) " &
       "  (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] (actor/continue state)))) " &
       "(try (a ~ actor/send \"bad\") catch (TypeError ^where w) w)",
       "\"actor/send message\""
    ck "(var a (actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg] (actor/continue state)))) " &
       "(try (a ~ actor/send [1]) catch (TypeError ^expected e) e)",
       "\"Send\""

  test "actor refs are Send values":
    ck "(var a (actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg] (actor/continue state)))) " &
       "(var ch (channel)) " &
       "(ch ~ Channel/send a) " &
       "(ch ~ Channel/recv)",
       "(actor)"

  test "actor ask returns a task with a one-shot reply":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(fn handle [ctx state msg] : (ActorStep Int) " &
       "  (match msg " &
       "    (when (Get ^reply reply) " &
       "      (reply ~ ReplyTo/send state) " &
       "      (actor/continue state)))) " &
       "(var a : (ActorRef Get) " &
       "  (actor/spawn ^init (fn [] 41) ^handle handle)) " &
       "(await (a ~ actor/ask (fn [reply] (Get ^reply reply))))",
       "41"

  test "actor ask enforces ReplyTo result type and reports missing replies":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(var a : (ActorRef Get) " &
       "  (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (match msg " &
       "        (when (Get ^reply reply) " &
       "          (reply ~ ReplyTo/send \"bad\") " &
       "          (actor/continue state)))))) " &
       "(try (await (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
       "catch (TypeError ^where w) w)",
       "\"ReplyTo/send value\""
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(var a : (ActorRef Get) " &
       "  (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] (actor/continue state)))) " &
       "(try (await (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
       "catch (ActorError ^message m) m)",
       "\"actor/ask did not receive a reply\""

  test "task scopes close owned actors on exit":
    ck "(var a (scope " &
       "  (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] (actor/continue state))))) " &
       "(a ~ actor/try-send 1)",
       "false"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var a nil) " &
       "(try " &
       "  (scope " &
       "    (set a (actor/spawn ^init (fn [] 0) " &
       "      ^handle (fn [ctx state msg] (actor/continue state)))) " &
       "    (fail (Boom ^message \"x\"))) " &
       "catch (Boom ^message m) m) " &
       "(a ~ actor/try-send 1)",
       "false"

  test "supervisors own actors and apply failure strategies":
    ck "(var a (supervisor ^strategy stop " &
       "  (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] (actor/continue state))))) " &
       "(a ~ actor/try-send 1)",
       "false"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var seen (cell 0)) " &
       "(supervisor ^strategy restart " &
       "  (var a (actor/spawn ^init (fn [] 10) " &
       "    ^handle (fn [ctx state msg] " &
       "      (if (= msg 1) " &
       "        (fail (Boom ^message \"bad\")) " &
       "        (do " &
       "          (seen ~ Cell/set state) " &
       "          (actor/continue (+ state msg))))))) " &
       "  (a ~ actor/send 1) " &
       "  (a ~ actor/send 5) " &
       "  (seen ~ Cell/get))",
       "10"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var a nil) " &
       "[(try " &
       "   (supervisor ^strategy escalate " &
       "     (set a (actor/spawn ^init (fn [] 0) " &
       "       ^handle (fn [ctx state msg] " &
       "         (fail (Boom ^message \"bad\"))))) " &
       "     (a ~ actor/send 1)) " &
       "   catch (Boom ^message m) m) " &
       " (a ~ actor/try-send 2)]",
       "[\"bad\" false]"
    expect GeneError:
      discard runStr("(supervisor nil)")
    expect GeneError:
      discard runStr("(supervisor ^strategy unknown nil)")

  test "actor handler must return an ActorStep":
    ck "(var a : (ActorRef Int) " &
       "  (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] 99))) " &
       "(try (a ~ actor/send 1) catch (TypeError ^where w) w)",
       "\"actor handler return\""

  test "actor operations require actors":
    expect GeneError:
      discard runStr("(actor/spawn ^handle (fn [ctx state msg] (actor/stop)))")
    expect GeneError: discard runStr("(actor/send 1 2)")
    expect GeneError: discard runStr("(ReplyTo/send 1 2)")

suite "vm — streams":
  test "read-one and read-all expose parsed forms":
    ck "(read-one \"(+ 1 2)\")", "(+ 1 2)"
    ck "(eval (read-one \"(+ 1 2)\") ^in (env))", "3"
    ck "(read-one \"#_ (ignored)\")", "nil"
    ck "(var s (read-all \"(a) #_ (ignored) (b 2)\")) " &
       "[(s ~ Stream/next) (s ~ Stream/next) (s ~ Stream/has_next)]",
       "[(a) (b 2) false]"
    ck "(try (read-one \"(a\") catch {^message m} m)",
       "\"read-one: unexpected EOF: unclosed '('\""
    ck "(try (read-one \"(a\") catch (ParseError ^message m) m)",
       "\"read-one: unexpected EOF: unclosed '('\""
    expect GeneError: discard runStr("(read-one 1)")
    expect GeneError: discard runStr("(read-all 1)")
    expect GeneError: discard runStr("(read-one \"1 2\")")

  test "lex-all exposes typed reader tokens":
    ck "(var s (lex-all \"(+ 1)\")) " &
       "(var t (s ~ Stream/next)) " &
       "(var k t/kind) (var x t/lexeme) (var l t/line) (var c t/col) " &
       "[k x l c]",
       "[l-paren \"(\" 1 1]"
    ck "(fn first-token [s : (Stream Token Never)] (s ~ Stream/next)) " &
       "(var t (first-token (lex-all \"name\"))) " &
       "(var k t/kind) (var x t/lexeme) [k x]",
       "[symbol \"name\"]"
    ck "(try (lex-all \"\\\"\") catch (LexError ^message m) m)",
       "\"lex-all: unterminated string literal\""
    expect GeneError: discard runStr("(lex-all 1)")

  test "stream values are opaque display values":
    ck "(to_stream [1 2])", "(stream)"

  test "stream has_next, peek, next, and close pull values":
    ck "(var s (to_stream [1 2])) " &
       "[(s ~ Stream/has_next) " &
       " (s ~ Stream/peek) " &
       " (s ~ Stream/next) " &
       " (s ~ Stream/peek) " &
       " (s ~ Stream/next) " &
       " (s ~ Stream/has_next) " &
       " (s ~ Stream/close) " &
       " (s ~ Stream/has_next)]",
       "[true 1 1 2 2 false nil false]"

  test "streams skip void items":
    ck "(var s (to_stream [1 void 2])) " &
       "[(s ~ Stream/next) (s ~ Stream/next) (s ~ Stream/has_next)]",
       "[1 2 false]"

  test "map pairs can be streamed":
    ck "(var s (to_pairs_stream {^a 1 ^b 2})) " &
       "[(s ~ Stream/next) (s ~ Stream/next) (s ~ Stream/has_next)]",
       "[[a 1] [b 2] false]"
    ck "(var s (to_pairs_stream {^a 1})) " &
       "(var pair (s ~ Stream/next)) " &
       "(fn key [x : Sym] x) (key pair/0)",
       "a"

  test "stream map transforms pulled values":
    ck "(var s (map (to_stream [1 2 3]) (fn [x] (* x 2)))) " &
       "[(s ~ Stream/next) (s ~ Stream/next) (s ~ Stream/next) " &
       " (s ~ Stream/has_next)]",
       "[2 4 6 false]"

  test "stream map skips void results":
    ck "(var s (map (to_stream [1 2]) (fn [x] (if (= x 1) void x)))) " &
       "[(s ~ Stream/next) (s ~ Stream/has_next)]",
       "[2 false]"

  test "stream map is lazy":
    ck "(var hits (cell 0)) " &
       "(var s (map (to_stream [1 2 3]) " &
       "            (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) (* x 2)))) " &
       "[(hits ~ Cell/get) " &
       " (s ~ Stream/next) (hits ~ Cell/get) " &
       " (s ~ Stream/next) (hits ~ Cell/get)]",
       "[0 2 1 4 2]"

  test "stream filter keeps truthy predicate results":
    ck "(var s (filter (to_stream [1 2 3]) (fn [x] (> x 1)))) " &
       "[(s ~ Stream/next) (s ~ Stream/next) (s ~ Stream/has_next)]",
       "[2 3 false]"

  test "stream filter is lazy":
    ck "(var hits (cell 0)) " &
       "(var s (filter (to_stream [1 2 3]) " &
       "               (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) (> x 1)))) " &
       "[(hits ~ Cell/get) " &
       " (s ~ Stream/next) (hits ~ Cell/get) " &
       " (s ~ Stream/next) (hits ~ Cell/get)]",
       "[0 2 2 3 3]"

  test "stream take limits pulled values":
    ck "(var s (take (to_stream [1 2 3]) 2)) " &
       "[(s ~ Stream/next) (s ~ Stream/next) (s ~ Stream/has_next)]",
       "[1 2 false]"

  test "stream take does not over-pull upstream":
    ck "(var hits (cell 0)) " &
       "(var source (map (to_stream [1 2 3]) " &
       "                 (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
       "(var s (take source 1)) " &
       "[(hits ~ Cell/get) " &
       " (s ~ Stream/next) (hits ~ Cell/get) " &
       " (s ~ Stream/has_next) (hits ~ Cell/get)]",
       "[0 1 1 false 1]"

  test "stream into materializes list and map targets":
    ck "[(into (to_stream [2 3]) [1]) " &
       " (into (to_pairs_stream {^b 2}) {^a 1})]",
       "[[1 2 3] {^a 1 ^b 2}]"

  test "stream next and peek raise EndOfStream shape":
    ck "(try (var s (to_stream [])) (s ~ Stream/next) " &
       "catch (EndOfStream ^message m) m)",
       "\"end of stream\""
    ck "(try (var s (to_stream [])) (s ~ Stream/peek) " &
       "catch (EndOfStream ^message m) m)",
       "\"end of stream\""

  test "Stream annotations accept streams only":
    ck "(fn first [s : Stream] (s ~ Stream/next)) (first (to_stream [3]))", "3"
    ck "(fn first [s : (Stream Int Never)] (s ~ Stream/next)) " &
       "(first (to_stream [4]))", "4"
    ck "(fn accept [s : (Stream Int Never)] 7) " &
       "(accept (to_stream [\"bad\"]))", "7"
    ck "(try (fn first [s : (Stream Int Never)] (s ~ Stream/next)) " &
       "     (first (to_stream [\"bad\"])) " &
       "catch (TypeError ^where w) w)",
       "\"Stream/next item\""
    ck "(try (fn typed [s] : (Stream Int Never) s) " &
       "     (var s (typed (to_stream [\"bad\"]))) " &
       "     (s ~ Stream/next) " &
       "catch (TypeError ^expected e) e)",
       "\"Int\""
    expect GeneError:
      discard runStr("(fn first [s : Stream] s) (first [1])")

  test "stream operations require streams":
    expect GeneError: discard runStr("(Stream/next [1])")
    expect GeneError: discard runStr("(to_stream {^a 1})")
    expect GeneError: discard runStr("(to_pairs_stream [1])")
    expect GeneError: discard runStr("(map [1] (fn [x] x))")
    expect GeneError: discard runStr("(filter [1] (fn [x] true))")
    expect GeneError: discard runStr("(take [1] 1)")
    expect GeneError: discard runStr("(take (to_stream [1]) -1)")
    expect GeneError: discard runStr("(into [1] [])")
    expect GeneError: discard runStr("(into (to_stream [1]) {})")

suite "vm — printer view of callables":
  test "functions print a display form":
    ck "(fn [x] x)", "(fn)"                  # anonymous
    ck "(fn double [x] (* x 2))", "(fn double)"  # named form sets the name
    check runStr("+").print() == "(native-fn +)"
  test "namespaces print a display form":
    ck "(ns math (var pi 3))", "(ns math)"
