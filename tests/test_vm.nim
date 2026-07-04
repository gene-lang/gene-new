import gene/[compiler, gir, printer, types, vm]
import std/[os, strutils, unittest]

template ck(src, expected: string) =
  ## Compile and run a program string, then compare its printed result.
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

template withoutGeneWorkers(body: untyped) =
  when compileOption("threads") and defined(gcAtomicArc):
    let previousWorkers = getEnv("GENE_WORKERS")
    putEnv("GENE_WORKERS", "0")
    try:
      body
    finally:
      putEnv("GENE_WORKERS", previousWorkers)
  else:
    body

proc collectSpawnFlags(chunk: Chunk, flags: var seq[bool]) =
  if chunk == nil:
    return
  for inst in chunk.instructions:
    if inst.op == opSpawn:
      flags.add inst.flag
  for body in chunk.subchunks:
    collectSpawnFlags(body, flags)
  for loop in chunk.forLoops:
    collectSpawnFlags(loop.body, flags)
  for match in chunk.matches:
    for clause in match.clauses:
      collectSpawnFlags(clause.body, flags)
    collectSpawnFlags(match.elseBody, flags)
  for attempt in chunk.tries:
    collectSpawnFlags(attempt.body, flags)
    for clause in attempt.catches:
      collectSpawnFlags(clause.body, flags)
    collectSpawnFlags(attempt.ensureBody, flags)
  for proto in chunk.functions:
    collectSpawnFlags(proto.chunk, flags)
    for defaultValue in proto.paramDefaults:
      if defaultValue.optional and defaultValue.defaultChunk != nil:
        collectSpawnFlags(defaultValue.defaultChunk, flags)
    for param in proto.namedParams:
      if param.defaultValue.optional and param.defaultValue.defaultChunk != nil:
        collectSpawnFlags(param.defaultValue.defaultChunk, flags)

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
    check chunk.instructions.len == 3
    check chunk.instructions[0].op == opPushConst
    check chunk.constants[chunk.instructions[0].intArg].intVal == 1
    check chunk.instructions[1].op == opIntAddConst
    check chunk.instructions[1].name == "+"
    check chunk.constants[chunk.instructions[1].depth].intVal == 2
    check chunk.instructions[2].op == opReturn

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
    check proto.chunk.instructions.len == 3
    check proto.chunk.instructions[0].op == opLoadLocal
    check proto.chunk.instructions[1].op == opNativeFastConst
    check proto.chunk.instructions[1].name == "+"
    check proto.chunk.constants[proto.chunk.instructions[1].depth].intVal == 1
    check proto.chunk.instructions[^1].op == opReturn

  test "marks trivial functions as not requiring a call scope":
    let trivial = compileSource("(fn [] 7)")
    check trivial.functions.len == 1
    check trivial.functions[0].simpleCall
    check not trivial.functions[0].needsCallScope
    check not trivial.functions[0].poolCallScope

    let withLocal = compileSource("(fn [x] x)")
    check withLocal.functions.len == 1
    check withLocal.functions[0].simpleCall
    check withLocal.functions[0].needsCallScope
    check withLocal.functions[0].poolCallScope

    let withClosure = compileSource("(fn [x] (fn [] x))")
    check withClosure.functions.len == 1
    check withClosure.functions[0].simpleCall
    check withClosure.functions[0].needsCallScope
    check not withClosure.functions[0].poolCallScope

  test "emits generic function type parameters":
    let chunk = compileSource("(fn (identity item) [x : item] : item x)")
    let proto = chunk.functions[0]
    check proto.name == "identity"
    check proto.typeParams == @["item"]
    check proto.params == @["x"]
    check proto.requiredPositional == 1
    check not proto.simpleCall
    check not proto.fastBindUnaryInt
    check not proto.fastBindPositionalInt
    check proto.paramTypes[0].print() == "item"
    check proto.returnType.print() == "item"

  test "caches typed Int call fast-bind metadata":
    let unary = compileSource("(fn [x : Int] : Int x)").functions[0]
    check unary.fastBindUnaryInt
    check unary.fastBindPositionalInt

    let positional = compileSource(
      "(fn [a : Int b : Int c : Int d : Int] : Int a)").functions[0]
    check not positional.fastBindUnaryInt
    check positional.fastBindPositionalInt

  test "records generic monomorphization requests":
    let chunk = compileSource("(fn (identity item) [x : item] : item x) " &
                              "(identity ^types [Int] 1)")
    check chunk.monomorphizations.len == 1
    check chunk.monomorphizations[0].functionName == "identity"
    check chunk.monomorphizations[0].typeArgs[0].print() == "Int"
    check "monomorphizations:" in chunk.disassemble()

  test "records direct protocol call dependencies":
    let chunk = compileSource("(to_name ^protocol ToName ^receiver User user)")
    check chunk.directProtocolCalls.len == 1
    check chunk.directProtocolCalls[0].messageName == "to_name"
    check chunk.directProtocolCalls[0].protocolExpr.print() == "ToName"
    check chunk.directProtocolCalls[0].receiverExpr.print() == "User"
    check "direct-protocol-calls:" in chunk.disassemble()

    let flipped = compileSource("(fn f [self] " &
                                "  (~ ^protocol ToName ^receiver User to_name))")
    check flipped.functions[0].chunk.directProtocolCalls.len == 1
    check flipped.functions[0].chunk.directProtocolCalls[0].messageName == "to_name"

  test "marks simple typed Int arithmetic as native compiled":
    let chunk = compileSource("(fn add [x : Int y : Int] : Int (+ x y))")
    let proto = chunk.functions[0]
    check proto.nativeOp == ncoIntAdd
    check "native=int-add" in chunk.disassemble()

    let identityChunk = compileSource("(fn id [x : Int] : Int x)")
    check identityChunk.functions[0].nativeOp == ncoIntIdentity
    check identityChunk.functions[0].nativeParamIndex == 0
    check "native=int-identity" in identityChunk.disassemble()

    let pickChunk = compileSource(
      "(fn pick [a : Int b : Int c : Int] : Int b)")
    check pickChunk.functions[0].nativeOp == ncoIntIdentity
    check pickChunk.functions[0].nativeParamIndex == 1

    let i64Chunk = compileSource("(fn add64 [x : I64 y : I64] : I64 (+ x y))")
    check i64Chunk.functions[0].nativeOp == ncoI64Add
    check "native=i64-add" in i64Chunk.disassemble()

    let f64Chunk = compileSource("(fn mul64 [x : F64 y : F64] : F64 (* x y))")
    check f64Chunk.functions[0].nativeOp == ncoF64Mul
    check "native=f64-mul" in f64Chunk.disassemble()

    let dynamicChunk = compileSource("(fn add [x : Int y : Int] : Int (+ y x))")
    check dynamicChunk.functions[0].nativeOp == ncoNone

    let aotChunk = compileSource("(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
                                 "(fn add64_twice [x : I64 y : I64] : I64 " &
                                 "  (add64 (add64 x y) y))")
    check aotChunk.functions[0].aotExpr.kind != vkNil
    check aotChunk.functions[1].aotExpr.kind != vkNil
    check aotChunk.functions[0].aotFrameKind == afkTypedNative
    check not aotChunk.functions[0].aotFrameCanSuspend
    check "aot=c frame=typed-native" in aotChunk.disassemble()
    check "typed-module-aot:" in aotChunk.disassemble()
    check "add64 repr=I64 arity=2 frame=typed-native" in aotChunk.disassemble()

    let awaitChunk = compileSource("(fn wait [t : (Task Int Never)] : Int (await t))")
    check awaitChunk.functions[0].taskFrameKind == tfkVm
    check "task-frame=vm" in awaitChunk.disassemble()

    let yieldChunk = compileSource("(fn ints [] : (Stream Int Never) (yield 1))")
    check yieldChunk.functions[0].taskFrameKind == tfkGenerator
    check "task-frame=generator" in yieldChunk.disassemble()

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

  test "rewrites stable recursive var-bound closures to recur":
    let chunk = compileSource("(var fib (fn [n] (if (< n 2) n (fib (- n 1)))))")
    check chunk.localNames == @["fib"]
    let proto = chunk.functions[0]
    var sawRecur = false
    for inst in proto.chunk.instructions:
      if inst.op in {opRecur1LocalIntSubConst, opRecur1LocalIntSubImm,
                     opRecur1LocalIntSubConstSameScope,
                     opRecur1LocalIntSubImmSameScope}:
        sawRecur = true
    check sawRecur

  test "keeps mutable recursive var-bound calls indirect":
    let chunk = compileSource(
      "(var fib (fn [n] (if (< n 2) n (fib (- n 1))))) " &
      "(set fib (fn [n] n))")
    let proto = chunk.functions[0]
    var sawOuterFib = false
    for inst in proto.chunk.instructions:
      if inst.op == opCallParentLocal1 and inst.name == "fib" and
          inst.intArg == 0:
        sawOuterFib = true
    check sawOuterFib

  test "marks worker-candidate spawns without outer mutation":
    let readOnly = compileSource(
      "(scope (var x 1) (spawn (+ x 1)))").disassemble()
    check readOnly.contains("opSpawn body=0 worker-candidate=true")

    let mutating = compileSource(
      "(scope (var x 1) (spawn (set x 2)))").disassemble()
    check mutating.contains("opSpawn body=0")
    check not mutating.contains("worker-candidate=true")

    var nestedFlags: seq[bool]
    collectSpawnFlags(
      compileSource("(scope (spawn (scope (var t (spawn 1)) (await t))))"),
      nestedFlags)
    check nestedFlags.len == 2
    check nestedFlags[0] == false
    check nestedFlags[1] == true

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

  test "emits slots for var destructuring bindings":
    let chunk = compileSource("(var [a b] [1 2]) (+ a b)")
    check chunk.localNames == @["a", "b"]
    var sawLoadA = false
    var sawLoadB = false
    for inst in chunk.instructions:
      if inst.op == opLoadLocal and inst.name == "a" and inst.intArg == 0:
        sawLoadA = true
      if inst.op == opLoadLocal and inst.name == "b" and inst.intArg == 1:
        sawLoadB = true
    check sawLoadA
    check sawLoadB

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

  test "protocol messages get no scope slots; sends resolve by name":
    # Message names are not bound in the enclosing scope (docs/core.md §1);
    # a send compiles to opResolveMessage with the message name.
    let chunk = compileSource(
      "(protocol P (message ping [x])) (fn use [x] (x ~ ping))")
    check chunk.localNames == @["P", "use"]

    let useProto = chunk.functions[0]
    var sawPing = false
    for inst in useProto.chunk.instructions:
      if inst.op == opResolveMessage and inst.name == "ping":
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
    check dump.contains("1: opIntAddConst name=+ const=1")
    check dump.contains("2: opReturn")

  test "prints nested function chunks":
    let dump = compileSource("(fn inc [x] (+ x 1))").disassemble()
    check dump.contains("functions:")
    check dump.contains("[0] inc params=[x]")
    check dump.contains("0: opMakeFn fn=0")
    check dump.contains("1: opNativeFastConst name=+ const=0")

  test "prints typed integer fast ops":
    let dump = compileSource("(fn add [x : Int y : Int] : Int (+ x y))").disassemble()
    check dump.contains("0: opLoadLocalFast slot=0 name=x")
    check dump.contains("1: opLoadLocalFast slot=1 name=y")
    check dump.contains("2: opIntAdd2 name=+")

  test "prints same-scope typed integer recur ops":
    let dump = compileSource(
      "(var fib (fn [n : Int] : Int " &
      "  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))").disassemble()
    check dump.contains("opRecur1LocalIntSubImmSameScope slot=0 name=n imm=1")
    check dump.contains("opRecur1LocalIntSubImmSameScope slot=0 name=n imm=2")
    check dump.contains("opReturnIntAdd2 name=+")

  test "prints direct local zero-arg calls":
    let dump = compileSource("(var call_once (fn [] nil)) (call_once)").disassemble()
    check dump.contains("opCallLocal0 slot=0 name=call_once argc=0")
    let parentDump = compileSource(
      "(var call_once (fn [] nil)) ((fn [] (call_once)))").disassemble()
    check parentDump.contains("opCallParentLocal0 slot=0 name=call_once argc=0")
    let outerDump = compileSource(
      "(var call_once (fn [] nil)) ((fn [] ((fn [] (call_once)))))").disassemble()
    check outerDump.contains("opCallOuterLocal0 depth=2 slot=0 name=call_once argc=0")

  test "prints direct local multi-arg calls":
    let dump = compileSource(
      "(var call_four (fn [a b c d] nil)) (call_four 1 2 3 4)").disassemble()
    check dump.contains("opCallLocalN slot=0 name=call_four argc=4")

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
    ck "(var name \"Ada\") $\"\"\"hello \"${name}\\\"\"\"\"",
       "\"hello \\\"Ada\\\"\""
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
  test "native fast loads respect shadowing":
    ck "(var + (fn [a b] a)) (+ 1 2)", "1"
    ck "(var make (fn [] (var + (fn [a b] b)) (fn [x] (+ x 9)))) ((make) 4)", "9"
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
  test "duplicate parameter bindings are rejected":
    expect GeneError: discard runStr("(fn [x x] x)")
    expect GeneError: discard runStr("(fn [x ^scale x] x)")
    expect GeneError: discard runStr("(fn [x x...] x)")
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
  test "recoverable errors expose bytecode frame traces":
    ck "(fn outer [] (inner)) " &
       "(fn inner [] (var x : Int \"bad\") x) " &
       "(try (outer) catch (TypeError ^trace t) " &
       "  [t/0/name t/0/kind t/1/name t/1/kind])",
       "[\"inner\" \"bytecode\" \"outer\" \"bytecode\"]"
  test "native-compiled typed Int arithmetic uses dynamic boundary adapters":
    ck "(fn add [x : Int y : Int] : Int (+ x y)) (add 20 22)", "42"
    ck "(fn sub [x : Int y : Int] : Int (- x y)) (sub 20 7)", "13"
    ck "(fn mul [x : Int y : Int] : Int (* x y)) (mul 6 7)", "42"
    ck "(fn add64 [x : I64 y : I64] : I64 (+ x y)) (add64 20 22)", "42"
    ck "(fn mul64 [x : F64 y : F64] : F64 (* x y)) (mul64 3.5 2.0)", "7.0"
    ck "(fn add [x : Int y : Int] : Int (+ x y)) " &
       "(try (add \"bad\" 1) catch (TypeError ^where w) w)",
       "\"parameter 'x'\""
    ck "(fn pick [a : Int b : Int c : Int] : Int b) " &
       "(try (pick 1 2 \"bad\") catch (TypeError ^where w) w)",
       "\"parameter 'c'\""
    ck "(fn outer [] (add \"bad\" 1)) " &
       "(fn add [x : Int y : Int] : Int (+ x y)) " &
       "(try (outer) catch (TypeError ^trace t) " &
       "  [t/0/name t/0/kind t/1/name t/1/kind])",
       "[\"add\" \"typed-native\" \"outer\" \"bytecode\"]"
    ck "(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
       "(try (add64 9223372036854775807 1) " &
       "catch (TypeError ^where w) w)",
       "\"return from 'add64'\""
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
  test "selector options handle missing lookups explicitly":
    ck "(var fallback \"unknown\") " &
       "((select ^default fallback name) {^age 37})",
       "\"unknown\""
    ck "((select ^default \"unknown\" name) {^name nil})", "nil"
    ck "(try ((select ^strict true name) {^age 37}) catch {^message m} m)",
       "\"selector lookup failed at segment: name\""
    ck "(try ((select ^strict true ^default \"unknown\" name) {^age 37}) " &
       "catch {^message m} m)",
       "\"selector lookup failed at segment: name\""
    expect GeneError:
      discard runStr("((select ^strict 1 name) {^age 37})")
  test "selectors read list indexes and path sends expose list behavior":
    ck "(var xs [10 20 30]) xs/1", "20"
    ck "(var xs [10 20 30]) xs/-1", "30"
    ck "(var xs [10 20 30]) xs/size", "void"
    ck "(var xs [10 20 30]) [xs/~size xs/~empty? xs/~first xs/~last]",
       "[3 false 10 30]"
    ck "(var xs []) [xs/~empty? xs/~first xs/~last]", "[true void void]"
    ck "(fn size [xs] xs/~size) (size [1 2 3])", "3"
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
    ck "(var ch (channel ^capacity 1)) " &
       "(var t (spawn 7)) " &
       "(ch ~ Channel/send t) " &
       "(await (ch ~ Channel/recv))",
       "7"
    ck "(var ch (channel ^capacity 1)) " &
       "(var inner (channel ^capacity 1)) " &
       "(inner ~ Channel/send 7) " &
       "(ch ~ Channel/send inner) " &
       "((ch ~ Channel/recv) ~ Channel/recv)",
       "7"
    ck "(var ch (channel ^capacity 1)) " &
       "(var a (atomic-cell 7)) " &
       "(ch ~ Channel/send a) " &
       "((ch ~ Channel/recv) ~ AtomicCell/load)",
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
  test "suspension preserves match, for, and catch sub-bodies":
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var t (spawn (match 1 " &
       "                  (when 1 (ch ~ Channel/recv))))) " &
       "  (spawn (ch ~ Channel/send 7)) " &
       "  (await t))", "7"
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var out (cell 0)) " &
       "  (var t (spawn (for x [1] " &
       "                  (out ~ Cell/set (ch ~ Channel/recv))))) " &
       "  (spawn (ch ~ Channel/send 8)) " &
       "  (await t) " &
       "  (out ~ Cell/get))", "8"
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var t (spawn (try (fail (Error ^message \"x\")) " &
       "                  catch _ (ch ~ Channel/recv)))) " &
       "  (spawn (ch ~ Channel/send 9)) " &
       "  (await t))", "9"
  test "suspension preserves scope, supervisor, eval, and namespace sub-bodies":
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var t (spawn (scope (ch ~ Channel/recv)))) " &
       "  (spawn (ch ~ Channel/send 7)) " &
       "  (await t))", "7"
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var t (spawn (supervisor ^strategy stop " &
       "                  (ch ~ Channel/recv)))) " &
       "  (spawn (ch ~ Channel/send 8)) " &
       "  (await t))", "8"
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var e (env ^bindings {^ch ch})) " &
       "  (var t (spawn (eval (quote (ch ~ Channel/recv)) ^in e))) " &
       "  (spawn (ch ~ Channel/send 9)) " &
       "  (await t))", "9"
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var t (spawn (ns m (var x (ch ~ Channel/recv))))) " &
       "  (spawn (ch ~ Channel/send 10)) " &
       "  ((await t) ~ Namespace/lookup (quote x)))", "10"
  test "await with no way to make progress is a deadlock error":
    expect GeneError:
      discard runStr("(scope (var ch (channel ^capacity 1)) " &
                     "  (var c (spawn (ch ~ Channel/recv))) " &
                     "  (await c))")
  test "a task awaiting another parks until it settles":
    # `doubler` awaits `producer` while producer is still blocked on recv; it parks
    # on the task (does not busy-pump) and resumes once producer completes.
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var producer (spawn (do (ch ~ Channel/recv) 5))) " &
       "  (var doubler (spawn (* 2 (await producer)))) " &
       "  (ch ~ Channel/send 1) " &
       "  (await doubler))", "10"
  test "a chain of awaiting tasks resolves in order":
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var a (spawn (do (ch ~ Channel/recv) 1))) " &
       "  (var b (spawn (+ 10 (await a)))) " &
       "  (var c (spawn (+ 100 (await b)))) " &
       "  (ch ~ Channel/send 0) " &
       "  (await c))", "111"

  test "spawn queues child work instead of running inline":
    ck "(scope (var out (cell 0)) " &
       "  (var t (spawn (out ~ Cell/set 1))) " &
       "  [(out ~ Cell/get) (await t) (out ~ Cell/get)])",
       "[0 1 1]"

  test "worker-candidate spawns snapshot sendable captures":
    ck "(scope (var x 1) " &
       "  (var t (spawn x)) " &
       "  (set x 2) " &
       "  (await t))",
       "1"
    ck "(scope (var x 1) " &
       "  (fn read [n] (+ x n)) " &
       "  (var t (spawn (read 2))) " &
       "  (set x 10) " &
       "  (await t))",
       "3"
    ck "(scope " &
       "  (var fib (fn [n : Int] : Int " &
       "    (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) " &
       "  (var t (spawn (fib 5))) " &
       "  (set fib (fn [n : Int] : Int 0)) " &
       "  (await t))",
       "5"
    ck "(scope (var x 41) " &
       "  (var t (spawn (fn [] (+ x 1)))) " &
       "  ((await t)))",
       "42"

  test "non-worker-safe spawns keep cooperative shared captures":
    ck "(scope (var c (cell 0)) " &
       "  (var t (spawn (c ~ Cell/get))) " &
       "  (c ~ Cell/set 2) " &
       "  (await t))",
       "2"

  test "applications keep scheduler queues isolated":
    withoutGeneWorkers:
      let app1 = newApplication()
      let scope1 = newGlobalScope(app1)
      let ch = run(compileSource("(channel ^capacity 1)"), scope1)
      scope1.define("ch", ch)
      let pending = run(compileSource("(spawn (ch ~ Channel/send 1))"), scope1)
      check pending.kind == vkTask
      check not pending.taskDone
      check ch.channelLen == 0

      let app2 = newApplication()
      let scope2 = newGlobalScope(app2)
      expect GeneError:
        discard run(compileSource(
          "(var ch (channel ^capacity 1)) (ch ~ Channel/recv)"), scope2)

      check ch.channelLen == 0
      check not pending.taskDone
      scope1.define("pending", pending)
      check run(compileSource("(await pending)"), scope1).kind == vkNil
      check pending.taskDone
      check ch.channelLen == 1

  test "CPU-bound fibers yield at scheduler safepoints":
    ck "(scope (var out (cell 0)) " &
       "  (var slow (spawn (do " &
       "    (var i 0) " &
       "    (while (< i 5000) (set i (+ i 1))) " &
       "    (out ~ Cell/set 1)))) " &
       "  (var fast (spawn (out ~ Cell/set 2))) " &
       "  (await fast) " &
       "  [(out ~ Cell/get) (await slow) (out ~ Cell/get)])",
       "[2 1 1]"

  test "sleep parks only the current task":
    ck "(scope (var out (cell 0)) " &
       "  (var slow (spawn (do (sleep 5) (out ~ Cell/set 1)))) " &
       "  (var fast (spawn (out ~ Cell/set 2))) " &
       "  (await fast) " &
       "  [(out ~ Cell/get) (await slow) (out ~ Cell/get)])",
       "[2 1 1]"

  test "sleep zero yields one scheduler turn":
    ck "(var out (cell 0)) " &
       "(spawn (out ~ Cell/set 1)) " &
       "[(out ~ Cell/get) (sleep 0) (out ~ Cell/get)]",
       "[0 nil 1]"

  test "Fs/read-text-async returns an awaitable task":
    let path = getTempDir() / "gene-read-text-async-test.txt"
    writeFile(path, "hello async")
    defer:
      if fileExists(path):
        removeFile(path)
    let scope = newGlobalScope()
    scope.define("path", newStr(path))
    check run(compileSource("(await (Fs/read-text-async Fs/ReadDir path))"),
              scope).print() == "\"hello async\""
    expect GeneError:
      discard run(compileSource("(Fs/read-text-async Fs/WriteDir path)"), scope)

  test "Fs/write-text-async returns an awaitable task":
    let path = getTempDir() / "gene-write-text-async-test.txt"
    defer:
      if fileExists(path):
        removeFile(path)
    let scope = newGlobalScope()
    scope.define("path", newStr(path))
    check run(compileSource(
      "(await (Fs/write-text-async Fs/WriteDir path \"written async\"))"),
      scope).kind == vkNil
    check readFile(path) == "written async"
    expect GeneError:
      discard run(compileSource(
        "(Fs/write-text-async Fs/ReadDir path \"nope\")"), scope)

  test "Net TCP async operations require connect authority":
    expect GeneError:
      discard run(compileSource(
        "(Net/tcp-read-text-async Fs/ReadDir \"127.0.0.1\" 1 1 1)"),
        newGlobalScope())
    expect GeneError:
      discard run(compileSource(
        "(Net/tcp-write-text-async Fs/ReadDir \"127.0.0.1\" 1 \"x\" 1)"),
        newGlobalScope())

  test "root channel waits can be unblocked by sleeping tasks":
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (spawn (do (sleep 5) (ch ~ Channel/send 7))) " &
       "  (ch ~ Channel/recv))", "7"
  test "closing a channel wakes parked receivers and senders":
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var t (spawn (try (ch ~ Channel/recv) " &
       "                  catch (ChannelClosed ^message m) m))) " &
       "  (spawn (ch ~ Channel/close)) " &
       "  (await t))",
       "\"channel is closed\""
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (ch ~ Channel/send 1) " &
       "  (var t (spawn (try (ch ~ Channel/send 2) " &
       "                  catch (ChannelClosed ^message m) m))) " &
       "  (spawn (ch ~ Channel/close)) " &
       "  (await t))",
       "\"channel is closed\""
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var a (spawn (try (ch ~ Channel/recv) " &
       "                  catch (ChannelClosed ^message m) m))) " &
       "  (var b (spawn (try (ch ~ Channel/recv) " &
       "                  catch (ChannelClosed ^message m) m))) " &
       "  (spawn (ch ~ Channel/close)) " &
       "  [(await a) (await b)])",
       "[\"channel is closed\" \"channel is closed\"]"
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (ch ~ Channel/send 1) " &
       "  (var a (spawn (try (ch ~ Channel/send 2) " &
       "                  catch (ChannelClosed ^message m) m))) " &
       "  (var b (spawn (try (ch ~ Channel/send 3) " &
       "                  catch (ChannelClosed ^message m) m))) " &
       "  (spawn (ch ~ Channel/close)) " &
       "  [(await a) (await b)])",
       "[\"channel is closed\" \"channel is closed\"]"
  test "cancelling a pending task makes await observe cancellation":
    expect GeneCancel:
      discard runStr("(scope (var ch (channel ^capacity 1)) " &
                     "  (var t (spawn (ch ~ Channel/recv))) " &
                     "  (t ~ Task/cancel) " &
                     "  (await t))")
  test "cancelling a sleeping task wakes it for cleanup":
    expect GeneCancel:
      discard runStr("(scope " &
                     "  (var t (spawn (sleep 1000))) " &
                     "  (t ~ Task/cancel) " &
                     "  (await t))")
  test "cancelling a task wakes fibers awaiting it":
    expect GeneCancel:
      discard runStr("(scope (var ch (channel ^capacity 1)) " &
                     "  (var t (spawn (ch ~ Channel/recv))) " &
                     "  (var w (spawn (await t))) " &
                     "  (t ~ Task/cancel) " &
                     "  (await w))")
  test "cancelled task fibers do not resume when their blocker clears":
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var out (cell 0)) " &
       "  (var t (spawn (do (ch ~ Channel/recv) (out ~ Cell/set 1)))) " &
       "  (t ~ Task/cancel) " &
       "  (ch ~ Channel/send 99) " &
       "  (out ~ Cell/get))", "0"
  test "task scope normal exit waits for live child tasks":
    ck "(var out (cell 0)) " &
       "(scope (var ch (channel ^capacity 1)) " &
       "  (spawn (do (ch ~ Channel/recv) (out ~ Cell/set 7))) " &
       "  (spawn (ch ~ Channel/send 1)) " &
       "  nil) " &
       "(out ~ Cell/get)", "7"
  test "task scope normal exit reports deadlocked child tasks":
    expect GeneError:
      discard runStr("(scope (var ch (channel ^capacity 1)) " &
                     "  (spawn (ch ~ Channel/recv)) " &
                     "  nil)")
    ck "(var ch (channel ^capacity 1)) " &
       "(var out (cell 0)) " &
       "(try (scope " &
       "       (spawn (do (ch ~ Channel/recv) (out ~ Cell/set 1))) " &
       "       nil) " &
       "  catch {^message m} m) " &
       "(ch ~ Channel/send 1) " &
       "(sleep 1) " &
       "(out ~ Cell/get)", "0"
  test "task scope error exit cancels pending child tasks":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var ch (channel ^capacity 1)) " &
       "(var out (cell 0)) " &
       "(try " &
       "  (scope " &
       "    (spawn (do (ch ~ Channel/recv) (out ~ Cell/set 1))) " &
       "    (fail (Boom ^message \"stop\"))) " &
       "  catch (Boom) nil) " &
       "(ch ~ Channel/send 1) " &
       "(scope nil) " &
       "(out ~ Cell/get)", "0"
  test "task scope error exit waits for child cancellation cleanup":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var ch (channel ^capacity 1)) " &
       "(var out (cell 0)) " &
       "(try " &
       "  (scope " &
       "    (spawn (try (ch ~ Channel/recv) " &
       "                ensure (out ~ Cell/set 9))) " &
       "    (sleep 1) " &
       "    (fail (Boom ^message \"stop\"))) " &
       "  catch (Boom) nil) " &
       "(out ~ Cell/get)", "9"

  test "task cancellation cleanup can suspend before await observes cancellation":
    let scope = newGlobalScope()
    expect GeneCancel:
      discard run(compileSource("(var out (cell 0)) " &
                                "(scope (var ch (channel ^capacity 1)) " &
                                "  (var t (spawn " &
                                "    (try (ch ~ Channel/recv) " &
                                "         ensure " &
                                "           (do (sleep 1) " &
                                "               (out ~ Cell/set 9))))) " &
                                "  (sleep 1) " &
                                "  (t ~ Task/cancel) " &
                                "  (await t))"),
                  scope)
    check scope.lookup("out").cellValue.intVal == 9

  test "detached tasks are not awaited on normal scope exit":
    ck "(var out (cell 0)) " &
       "(scope " &
       "  (var t (spawn (do (sleep 5) (out ~ Cell/set 1)))) " &
       "  (t ~ Task/detach) " &
       "  nil) " &
       "[(out ~ Cell/get) (sleep 10) (out ~ Cell/get)]",
       "[0 nil 1]"

  test "detached tasks are not cancelled on scope error exit":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var out (cell 0)) " &
       "(try " &
       "  (scope " &
       "    (var t (spawn (do (sleep 5) (out ~ Cell/set 9)))) " &
       "    (t ~ Task/detach) " &
       "    (fail (Boom ^message \"stop\"))) " &
       "  catch (Boom) nil) " &
       "[(out ~ Cell/get) (sleep 10) (out ~ Cell/get)]",
       "[0 nil 9]"

  test "an actor handler can suspend on a channel mid-message":
    # The handler recvs from a channel while processing a message: its fiber parks,
    # the scheduler runs a producer task to feed the channel, and the handler
    # resumes and finishes the message. Proves actor handlers run as fibers.
    ck "(var out (cell 0)) " &
       "(var ch (channel ^capacity 1)) " &
       "(fn handle [ctx state msg] " &
       "  (var got (ch ~ Channel/recv)) " &
       "  (out ~ Cell/set (+ msg got)) " &
       "  (actor/continue state)) " &
       "(var a (actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(var p (spawn (ch ~ Channel/send 100))) " &
       "(a ~ actor/send 5) " &
       "(out ~ Cell/get)", "105"
  test "an actor handler can suspend on a timer mid-message":
    ck "(var out (cell 0)) " &
       "(fn handle [ctx state msg] " &
       "  (sleep 5) " &
       "  (out ~ Cell/set msg) " &
       "  (actor/continue state)) " &
       "(var a (actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(a ~ actor/send 42) " &
       "(out ~ Cell/get)", "42"
  test "actor ask returns a pending task instead of driving synchronously":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(var ch (channel ^capacity 1)) " &
       "(fn handle [ctx state msg] " &
       "  (var got (ch ~ Channel/recv)) " &
       "  (match msg " &
       "    (when (Get ^reply reply) " &
       "      (reply ~ ReplyTo/send (+ state got)) " &
       "      (actor/continue state)))) " &
       "(var a (actor/spawn ^init (fn [] 40) ^handle handle)) " &
       "(var pending (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
       "(ch ~ Channel/send 2) " &
       "(await pending)", "42"
  test "actor ask awaited inside a fiber parks until the reply is sent":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(scope " &
       "  (var a (actor/spawn ^init (fn [] 41) " &
       "    ^handle (fn [ctx state msg] " &
       "      (match msg " &
       "        (when (Get ^reply reply) " &
       "          (reply ~ ReplyTo/send state) " &
       "          (actor/continue state)))))) " &
       "  (var t (spawn (await (a ~ actor/ask (fn [reply] (Get ^reply reply)))))) " &
       "  (await t))", "41"

  test "actor ask timeout fails pending request and ignores late reply":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(var ch (channel ^capacity 1)) " &
       "(var out (cell 0)) " &
       "(fn handle [ctx state msg] " &
       "  (var (Get ^reply reply) msg) " &
       "  (var got (ch ~ Channel/recv)) " &
       "  (reply ~ ReplyTo/send got) " &
       "  (out ~ Cell/set got) " &
       "  (actor/continue state)) " &
       "(var a (actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(var pending (actor/ask ^timeout-ms 5 a (fn [reply] (Get ^reply reply)))) " &
       "(var err (try (await pending) catch (ActorError ^message m) m)) " &
       "(ch ~ Channel/send 7) " &
       "[err (sleep 1) (out ~ Cell/get)]",
       "[\"actor/ask timed out\" nil 7]"
    ck "(scope " &
       "  (type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(var saved (cell nil)) " &
       "(var ch (channel ^capacity 1)) " &
       "(fn handle [ctx state msg] " &
       "  (var (Get ^reply reply) msg) " &
       "  (var got (ch ~ Channel/recv)) " &
       "  (try (reply ~ ReplyTo/send got) catch {^message m} m) " &
       "  (actor/continue state)) " &
       "(var a (actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(var pending (actor/ask ^timeout-ms 5 a " &
       "  (fn [reply] (saved ~ Cell/set reply) (Get ^reply reply)))) " &
       "(var err (try (await pending) catch (ActorError ^message m) m)) " &
       "(var first-late (try ((saved ~ Cell/get) ~ ReplyTo/send 9) " &
       "                  catch {^message m} m)) " &
       "(var second-late (try ((saved ~ Cell/get) ~ ReplyTo/send 10) " &
       "                   catch {^message m} m)) " &
       "[err first-late second-late])",
       "[\"actor/ask timed out\" nil \"reply has already been sent\"]"

  test "a cancelled actor ask task is not completed by a late reply":
    expect GeneCancel:
      discard runStr("(type Get ^props {^reply (ReplyTo Int)}) " &
                     "(impl Send Get) " &
                     "(type Tick ^impl [Send]) " &
                     "(impl Send Tick) " &
                     "(var ch (channel ^capacity 1)) " &
                     "(fn handle [ctx state msg] " &
                     "  (match msg " &
                     "    (when (Get ^reply reply) " &
                     "      (var got (ch ~ Channel/recv)) " &
                     "      (reply ~ ReplyTo/send got) " &
                     "      (actor/continue state)) " &
                     "    (when (Tick) (actor/continue state)))) " &
                     "(var a (actor/spawn ^init (fn [] 0) ^handle handle)) " &
                     "(var pending (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
                     "(pending ~ Task/cancel) " &
                     "(ch ~ Channel/send 7) " &
                     "(a ~ actor/send (Tick)) " &
                     "(await pending)")
    ck "(scope " &
       "  (type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(var saved (cell nil)) " &
       "(var ch (channel ^capacity 1)) " &
       "(fn handle [ctx state msg] " &
       "  (var (Get ^reply reply) msg) " &
       "  (var got (ch ~ Channel/recv)) " &
       "  (try (reply ~ ReplyTo/send got) catch {^message m} m) " &
       "  (actor/continue state)) " &
       "(var a (actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(var pending (a ~ actor/ask " &
       "  (fn [reply] (saved ~ Cell/set reply) (Get ^reply reply)))) " &
       "(pending ~ Task/cancel) " &
       "(var first-late (try ((saved ~ Cell/get) ~ ReplyTo/send 9) " &
       "                  catch {^message m} m)) " &
       "(var second-late (try ((saved ~ Cell/get) ~ ReplyTo/send 10) " &
       "                   catch {^message m} m)) " &
       "[first-late second-late])",
       "[nil \"reply has already been sent\"]"

  test "closing an owned actor cancels a scheduled ask reply":
    expect GeneCancel:
      discard runStr("(type Get ^props {^reply (ReplyTo Int)}) " &
                     "(impl Send Get) " &
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
                     "(await pending)")

  test "closing an owned actor removes blocked handler fibers":
    ck "(var out (cell 0)) " &
       "(var ch (channel ^capacity 1)) " &
       "(scope " &
       "  (var a (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (var got (ch ~ Channel/recv)) " &
       "      (out ~ Cell/set got) " &
       "      (actor/continue state)))) " &
       "  (a ~ actor/send 1) " &
       "  nil) " &
       "(ch ~ Channel/send 7) " &
       "(var gate (channel ^capacity 1)) " &
       "(var t (spawn (gate ~ Channel/recv))) " &
       "(gate ~ Channel/send 1) " &
       "(await t) " &
       "(out ~ Cell/get)", "0"

  test "try-send in a fiber wakes a peer parked in recv":
    # Regression: biChannelTrySend was missing wakeChannelWaiters.
    # The receiver fiber runs first (schedRunQueue ordering), parks on the empty
    # channel, and the try-send fiber runs second. Without the fix, the receiver
    # stays in schedWaiters after try-send and the await deadlocks.
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (var t (spawn (ch ~ Channel/recv))) " &
       "  (spawn (ch ~ Channel/try-send 42)) " &
       "  (await t))", "42"

  test "try-recv in a fiber wakes a peer parked in send":
    # Regression: biChannelTryRecv was missing wakeChannelWaiters.
    # Fill the channel at root, spawn a sender (parks when it runs), then spawn a
    # try-recv (runs second, pops the item). Without the fix, the parked sender
    # stays in schedWaiters after try-recv and the await deadlocks.
    ck "(scope (var ch (channel ^capacity 1)) " &
       "  (ch ~ Channel/send 1) " &
       "  (var t (spawn (ch ~ Channel/send 2))) " &
       "  (spawn (ch ~ Channel/try-recv)) " &
       "  (await t) " &
       "  (ch ~ Channel/recv))", "2"

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

  test "actor try-send returns before running the handler":
    ck "(var gate (channel ^capacity 1)) " &
       "(var seen (cell 0)) " &
       "(var a (actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg] " &
       "    (gate ~ Channel/recv) " &
       "    (seen ~ Cell/set msg) " &
       "    (actor/continue msg)))) " &
       "(var before [(a ~ actor/try-send 7) (seen ~ Cell/get)]) " &
       "(gate ~ Channel/send 1) " &
       "(sleep 0) " &
       "before",
       "[true 0]"
    ck "(var gate (channel ^capacity 1)) " &
       "(var seen (cell 0)) " &
       "(var a (actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg] " &
       "    (gate ~ Channel/recv) " &
       "    (seen ~ Cell/set msg) " &
       "    (actor/continue msg)))) " &
       "(a ~ actor/try-send 7) " &
       "(gate ~ Channel/send 1) " &
       "(sleep 0) " &
       "(seen ~ Cell/get)",
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
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(scope " &
       "  (var a : (ActorRef Get) " &
       "    (actor/spawn ^init (fn [] 41) " &
       "      ^handle (fn [ctx state msg] " &
       "        (match msg " &
       "          (when (Get ^reply reply) " &
       "            (reply ~ ReplyTo/send state) " &
       "            (actor/continue state)))))) " &
       "  (fn (choose result err) [t : (Task result err) fallback : result] " &
       "    fallback) " &
       "  (try (choose (a ~ actor/ask (fn [reply] (Get ^reply reply))) \"bad\") " &
       "       catch (TypeError ^expected e) e))",
       "\"Int\""

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
       "(var events (channel ^capacity 4)) " &
       "(var seen (cell 0)) " &
       "(supervisor ^strategy restart ^events events " &
       "  (var a (actor/spawn ^mailbox 4 ^init (fn [] 10) " &
       "    ^handle (fn [ctx state msg] " &
       "      (if (= msg 1) " &
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
       "    (if (= (seen ~ Cell/get) 0) " &
       "      (do (sleep 1) (set tries (+ tries 1))) " &
       "      (set tries 100))) " &
       "  [(seen ~ Cell/get) " &
       "   (match event " &
       "     (when (ActorFailure ^failed-message failed " &
       "                         ^error (Boom ^message m) " &
       "                         ^panic p ^strategy s) " &
       "       [failed m p s]))])",
       "[10 [1 \"bad\" false restart]]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var events (channel ^capacity 1)) " &
       "(var dead (channel ^capacity 2)) " &
       "(events ~ Channel/send \"busy\") " &
       "(supervisor ^strategy restart ^events events ^dead-letter dead " &
       "  (var a (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (fail (Boom ^message \"bad\"))))) " &
       "  (a ~ actor/send 1) " &
       "  (sleep 1) " &
       "  (var event (dead ~ Channel/recv)) " &
       "  (var busy (events ~ Channel/recv)) " &
       "  [busy " &
       "   (match event " &
       "     (when (ActorFailure ^failed-message failed " &
       "                         ^error (Boom ^message m) " &
       "                         ^strategy s) " &
       "       [failed m s]))])",
       "[\"busy\" [1 \"bad\" restart]]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var events (channel ^capacity 1)) " &
       "(var dead (channel ^capacity 1)) " &
       "(events ~ Channel/send \"busy\") " &
       "(dead ~ Channel/send \"dead-busy\") " &
       "(supervisor ^strategy restart ^events events ^dead-letter dead " &
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
       "     (when (ActorFailure ^failed-message failed " &
       "                         ^error (Boom ^message m) " &
       "                         ^strategy s) " &
       "       [failed m s]))])",
       "[\"busy\" \"dead-busy\" [4 \"bad\" restart]]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var events (channel ^capacity 1)) " &
       "(events ~ Channel/send \"busy\") " &
       "(supervisor ^strategy restart ^events events " &
       "  (var a (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (fail (Boom ^message \"bad\"))))) " &
       "  (a ~ actor/send 3) " &
       "  (var busy (events ~ Channel/recv)) " &
       "  (var event (events ~ Channel/recv)) " &
       "  [busy " &
       "   (match event " &
       "     (when (ActorFailure ^failed-message failed " &
       "                         ^error (Boom ^message m) " &
       "                         ^strategy s) " &
       "       [failed m s]))])",
       "[\"busy\" [3 \"bad\" restart]]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var events (channel ^capacity 1)) " &
       "(var dead (channel ^capacity 1)) " &
       "(events ~ Channel/close) " &
       "(supervisor ^strategy restart ^events events ^dead-letter dead " &
       "  (var a (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (fail (Boom ^message \"bad\"))))) " &
       "  (a ~ actor/send 2) " &
       "  (sleep 1) " &
       "  (var event (dead ~ Channel/recv)) " &
       "  (match event " &
       "    (when (ActorFailure ^failed-message failed " &
       "                        ^error (Boom ^message m) " &
       "                        ^strategy s) " &
       "      [failed m s])))",
       "[2 \"bad\" restart]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var events : (Channel Int) (channel ^capacity 1)) " &
       "(var dead (channel ^capacity 1)) " &
       "(supervisor ^strategy restart ^events events ^dead-letter dead " &
       "  (var a (actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (fail (Boom ^message \"bad\"))))) " &
       "  (a ~ actor/send 6) " &
       "  (sleep 1) " &
       "  (var event (dead ~ Channel/recv)) " &
       "  (match event " &
       "    (when (ActorFailure ^failed-message failed " &
       "                        ^error (Boom ^message m) " &
       "                        ^strategy s) " &
       "      [failed m s])))",
       "[6 \"bad\" restart]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(var events (channel ^capacity 1)) " &
       "(var dead (channel ^capacity 1)) " &
       "(events ~ Channel/close) " &
       "(dead ~ Channel/close) " &
       "(var seen (cell 0)) " &
       "(supervisor ^strategy restart ^events events ^dead-letter dead " &
       "  (var a (actor/spawn ^mailbox 4 ^init (fn [] 10) " &
       "    ^handle (fn [ctx state msg] " &
       "      (if (= msg 1) " &
       "        (fail (Boom ^message \"bad\")) " &
       "        (do " &
       "          (seen ~ Cell/set state) " &
       "          (actor/continue (+ state msg))))))) " &
       "  (a ~ actor/send 1) " &
       "  (a ~ actor/send 5) " &
       "  (sleep 1) " &
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
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
       "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send Get) " &
       "(try " &
       "  (supervisor ^strategy escalate " &
       "    (var a (actor/spawn ^init (fn [] 0) " &
       "      ^handle (fn [ctx state msg] " &
       "        (fail (Boom ^message \"bad\"))))) " &
       "    (var pending (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
       "    (sleep 1) " &
       "    \"after\") " &
       "  catch (Boom ^message m) m)",
       "\"bad\""
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error Boom) " &
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
       "   (when (ActorFailure ^failed-message failed " &
       "                       ^error (Boom ^message m) " &
       "                       ^strategy s) " &
       "     [failed m s]))]",
       "[\"bad\" [7 \"bad\" escalate]]"
    expect GenePanic:
      discard runStr("(type Get ^props {^reply (ReplyTo Int)}) " &
                     "(impl Send Get) " &
                     "(supervisor ^strategy stop " &
                     "  (var a (actor/spawn ^init (fn [] 0) " &
                     "    ^handle (fn [ctx state msg] " &
                     "      (panic \"halt\")))) " &
                     "  (var pending (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
                     "  (sleep 1) " &
                     "  \"after\")")
    expect GeneCancel:
      discard runStr("(type Boom ^props {^message Str} ^impl [Error]) " &
                     "(impl Error Boom) " &
                     "(type Get ^props {^reply (ReplyTo Int)}) " &
                     "(impl Send Get) " &
                     "(supervisor ^strategy stop " &
                     "  (var a (actor/spawn ^mailbox 4 ^init (fn [] 0) " &
                     "    ^handle (fn [ctx state msg] " &
                     "      (fail (Boom ^message \"bad\"))))) " &
                     "  (var first (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
                     "  (var second (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
                     "  (sleep 1) " &
                     "  (await second))")
    expect GeneError:
      discard runStr("(supervisor nil)")
    expect GeneError:
      discard runStr("(supervisor ^strategy unknown nil)")
    expect GeneError:
      discard runStr("(supervisor ^strategy stop ^events 1 nil)")
    expect GeneError:
      discard runStr("(supervisor ^strategy stop ^dead-letter 1 nil)")

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
