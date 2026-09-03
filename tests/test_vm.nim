import gene/[capabilities, compiler, fs_capabilities, gir, gir_codec, printer,
             reader, types, vm]
import std/[os, strutils, tables, unittest]

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

suite "VM — proper tail calls":
  test "mutual and higher-order tail chains keep physical frames flat":
    beginTailCallStats()
    let mutual = runStr(
      "(fn is_even [n] (if (== n 0) true (is_odd (- n 1)))) " &
      "(fn is_odd [n] (if (== n 0) false (is_even (- n 1)))) " &
      "(is_even 20000)")
    let mutualStats = finishTailCallStats()
    check mutual == TRUE
    check mutualStats.transfers >= 19_000
    check mutualStats.maxPhysicalFrames <= 2

    beginTailCallStats()
    let higherOrder = runStr(
      "(fn bounce [f n] (if (== n 0) 0 (f f (- n 1)))) " &
      "(bounce bounce 20000)")
    let higherOrderStats = finishTailCallStats()
    check higherOrder == newInt(0)
    check higherOrderStats.transfers >= 19_000
    check higherOrderStats.maxPhysicalFrames <= 2

    beginTailCallStats()
    let spliceValue = runStr(
      "(fn bounce_splice [f n] " &
      "  (if (== n 0) 0 (f [f (- n 1)]...))) " &
      "(bounce_splice bounce_splice 10000)")
    let spliceStats = finishTailCallStats()
    check spliceValue == newInt(0)
    check spliceStats.transfers >= 9_000
    check spliceStats.maxPhysicalFrames <= 2

    beginTailCallStats()
    let namedValue = runStr(
      "(fn bounce_named [n ^step] " &
      "  (if (== n 0) 0 " &
      "    (bounce_named ^step step (- n step)))) " &
      "(bounce_named ^step 1 10000)")
    let namedStats = finishTailCallStats()
    check namedValue == newInt(0)
    check namedStats.transfers >= 9_000
    check namedStats.maxPhysicalFrames <= 2

  test "tail match arms collapse expression frames":
    beginTailCallStats()
    let value = runStr(
      "(fn consume [xs n] " &
      "  (match xs " &
      "    (when [] (if (== n 0) 0 (consume [n] (- n 1)))) " &
      "    (else (consume [] n)))) " &
      "(consume [] 10000)")
    let stats = finishTailCallStats()
    check value == newInt(0)
    check stats.transfers >= 19_000
    check stats.collapsedExpressionFrames >= 19_000
    check stats.maxPhysicalFrames <= 3

    beginTailCallStats()
    let nestedValue = runStr(
      "(fn nested_match [n] " &
      "  (match n " &
      "    (when 0 0) " &
      "    (else (match n " &
      "      (else (nested_match (- n 1))))))) " &
      "(nested_match 5000)")
    let nestedStats = finishTailCallStats()
    check nestedValue == newInt(0)
    check nestedStats.transfers >= 4_000
    check nestedStats.collapsedExpressionFrames >= 8_000
    check nestedStats.maxPhysicalFrames <= 4

  test "proven exact typed returns remain tail-elidable":
    beginTailCallStats()
    let value = runStr(
      "(fn count_down [n] : F64 " &
      "  (if (== n 0) 0.0 (count_down (- n 1)))) " &
      "(count_down 10000)")
    let stats = finishTailCallStats()
    check value == newFloat(0.0)
    check stats.transfers >= 9_000
    check stats.maxPhysicalFrames <= 2

    beginTailCallStats()
    let scalars = runStr(
      "(fn bool_down [n] : Bool " &
      "  (if (== n 0) true (bool_down (- n 1)))) " &
      "(fn str_down [n] : Str " &
      "  (if (== n 0) \"done\" (str_down (- n 1)))) " &
      "(fn nil_down [n] : Nil " &
      "  (if (== n 0) nil (nil_down (- n 1)))) " &
      "[(bool_down 2000) (str_down 2000) (nil_down 2000)]")
    let scalarStats = finishTailCallStats()
    check scalars.print() == "[true \"done\" nil]"
    check scalarStats.transfers >= 5_000
    check scalarStats.maxPhysicalFrames <= 2

  test "dynamic return policies fall back without changing semantics":
    beginTailCallStats()
    let value = runStr(
      "(fn typed_bounce [f n] : Str " &
      "  (if (== n 0) \"done\" (f f (- n 1)))) " &
      "(typed_bounce typed_bounce 100)")
    let stats = finishTailCallStats()
    check value.print() == "\"done\""
    check stats.fallbacks >= 90
    check stats.fallbackByReason[tfrReturnType] >= 90
    check stats.maxPhysicalFrames >= 90

    beginTailCallStats()
    let checked = runStr(
      "(fn checked_count ^errors [] [n] " &
      "  (if (== n 0) 0 (checked_count (- n 1)))) " &
      "(checked_count 100)")
    let checkedStats = finishTailCallStats()
    check checked == newInt(0)
    check checkedStats.fallbacks >= 90
    check checkedStats.fallbackByReason[tfrCheckedErrors] >= 90
    check checkedStats.maxPhysicalFrames >= 90

    beginTailCallStats()
    let structured = runStr(
      "(fn identity [x] x) " &
      "(fn guarded [x] " &
      "  (try (return (identity x)) catch Any 0)) " &
      "(guarded 7)")
    let structuredStats = finishTailCallStats()
    check structured == newInt(7)
    check structuredStats.fallbackByReason[tfrStructuredFrame] >= 1

  test "a passed closure keeps its captured pooled caller scope alive":
    beginTailCallStats()
    let value = runStr(
      "(var saved nil) " &
      "(fn retain [f] (set saved f) 0) " &
      "(fn outer [x] " &
      "  (var inner (fn [] x)) " &
      "  (retain inner)) " &
      "(outer 7) (saved)")
    let stats = finishTailCallStats()
    check value == newInt(7)
    check stats.fallbacks >= 1
    check stats.fallbackByReason[tfrCapturedScope] >= 1

    beginTailCallStats()
    let armValue = runStr(
      "(var saved nil) " &
      "(fn retain [f] (set saved f) 0) " &
      "(fn outer [x] " &
      "  (match true " &
      "    (when true " &
      "      (var inner (fn [] x)) " &
      "      (retain inner)))) " &
      "(outer 9) (saved)")
    let armStats = finishTailCallStats()
    check armValue == newInt(9)
    check armStats.fallbackByReason[tfrStructuredFrame] >= 1
    check armStats.collapsedExpressionFrames == 0

  test "defensive eligibility guards preserve malformed internal GIR":
    let operandChunk = compileSource(
      "(fn target [] 1) (fn caller [] [0 (target)]) (caller)")
    for inst in operandChunk.functions[1].chunk.instructions.mitems:
      if inst.name == "target":
        inst.tail = true
    beginTailCallStats()
    let operandValue = run(operandChunk, newGlobalScope())
    let operandStats = finishTailCallStats()
    check operandValue.print() == "[0 1]"
    check operandStats.fallbackByReason[tfrOperandRegion] >= 1

    let validationChunk = compileSource(
      "(fn target [] 1) (fn caller [] (target)) (caller)")
    validationChunk.functions[1].frameNeedsImplValidation = true
    beginTailCallStats()
    let validationValue = run(validationChunk, newGlobalScope())
    let validationStats = finishTailCallStats()
    check validationValue == newInt(1)
    check validationStats.fallbackByReason[tfrImplValidation] >= 1

  test "user Callable bytecode participates in tail transfer":
    beginTailCallStats()
    let value = runStr(
      "(type Bounce ^props {}) " &
      "(impl Callable for Bounce " &
      "  (message apply [self call] " &
      "    (var n (/0 call)) " &
      "    (if (== n 0) 0 (self (- n 1))))) " &
      "(var bounce (Bounce)) (bounce 10000)")
    let stats = finishTailCallStats()
    check value == newInt(0)
    check stats.transfers >= 9_000
    check stats.maxPhysicalFrames <= 2

  test "tail sends and bound protocol messages share call entry":
    beginTailCallStats()
    let sendValue = runStr(
      "(type Box ^props {^n Int} " &
      "  (ctor [n] (self .set_prop `n n)) " &
      "  (message down [] " &
      "    (if (== self/n 0) 0 " &
      "      ((new Box (- self/n 1)) .down)))) " &
      "((new Box 5000) .down)")
    let sendStats = finishTailCallStats()
    check sendValue == newInt(0)
    check sendStats.transfers >= 4_000
    check sendStats.maxPhysicalFrames <= 3

    beginTailCallStats()
    let qualifiedValue = runStr(
      "(protocol Down (message down [n])) " &
      "(type QualifiedWalker ^props {}) " &
      "(impl Down for QualifiedWalker " &
      "  (message down [n] " &
      "    (if (== n 0) 0 (self .Down:down (- n 1))))) " &
      "((QualifiedWalker) .Down:down 5000)")
    let qualifiedStats = finishTailCallStats()
    check qualifiedValue == newInt(0)
    check qualifiedStats.transfers >= 4_000
    check qualifiedStats.maxPhysicalFrames <= 3

    beginTailCallStats()
    let superValue = runStr(
      "(type ParentWalker ^props {} " &
      "  (message down [n] " &
      "    (if (== n 0) 0 (self .down (- n 1))))) " &
      "(type ChildWalker ^is ParentWalker ^props {} " &
      "  (message down [n] (super .down n))) " &
      "((ChildWalker) .down 5000)")
    let superStats = finishTailCallStats()
    check superValue == newInt(0)
    check superStats.transfers >= 9_000
    check superStats.maxPhysicalFrames <= 3

    beginTailCallStats()
    let optionalValue = runStr(
      "(type OptionalWalker ^props {} " &
      "  (message down [n] " &
      "    (if (== n 0) 0 (self ?.down (- n 1))))) " &
      "((OptionalWalker) .down 5000)")
    let optionalStats = finishTailCallStats()
    check optionalValue == newInt(0)
    check optionalStats.transfers >= 4_000
    check optionalStats.maxPhysicalFrames <= 3

    beginTailCallStats()
    let messageValue = runStr(
      "(protocol Step (message step [n])) " &
      "(type Walker ^props {} " &
      "  (impl Step " &
      "    (message step [n] " &
      "      (if (== n 0) 0 (next self (- n 1)))))) " &
      "(var next Step:step) (next (Walker) 5000)")
    let messageStats = finishTailCallStats()
    check messageValue == newInt(0)
    check messageStats.transfers >= 4_000
    check messageStats.maxPhysicalFrames <= 3

  test "explicit return tail calls transfer from plain functions":
    beginTailCallStats()
    let value = runStr(
      "(fn finish_a [n] " &
      "  (if (== n 0) 0 (return (finish_b (- n 1))))) " &
      "(fn finish_b [n] " &
      "  (if (== n 0) 0 (return (finish_a (- n 1))))) " &
      "(finish_a 10000)")
    let stats = finishTailCallStats()
    check value == newInt(0)
    check stats.transfers >= 9_000
    check stats.maxPhysicalFrames <= 2

  test "tail trace history is bounded and reports elision":
    var caught: ref GeneError
    try:
      discard runStr(
        "(fn explode [] (var value : Int \"bad\") value) " &
        "(fn left [n] (if (== n 0) (explode) (right (- n 1)))) " &
        "(fn right [n] (if (== n 0) (explode) (left (- n 1)))) " &
        "(left 500)")
    except GeneError as error:
      caught = error
    check caught != nil
    check caught.hasErrVal
    check caught.errVal.props.hasKey("trace")
    let trace = caught.errVal.props["trace"]
    check trace.kind == vkList
    check trace.listItems.len <= 67
    check trace.print().contains("tail calls elided")

  test "fiber suspension preserves bounded tail continuation state":
    beginTailCallStats()
    let value = runStr(
      "(fn is_even [n] (if (== n 0) true (is_odd (- n 1)))) " &
      "(fn is_odd [n] (if (== n 0) false (is_even (- n 1)))) " &
      "(scope (var task (spawn (is_even 10000))) (await task))")
    let stats = finishTailCallStats()
    check value == TRUE
    check stats.transfers >= 9_000
    check stats.maxPhysicalFrames <= 4

suite "compiler — GIR emission":
  test "tail-position proof reaches calls, match arms, and callable bodies":
    let chunk = compileSource(
      "(fn g [x] x) (fn h [x] x) (fn k [x] x) " &
      "(fn f [x] (if x (g x) (h (k x)))) " &
      "(fn walk [xs] (match xs (when [] 0) (else (walk [])))) " &
      "(type T ^props {} (ctor [] (g 1)) (message m [] (g 1))) " &
      "(g 1)")
    var f: FunctionProto
    var loopFn: FunctionProto
    for proto in chunk.functions:
      if proto.name == "f": f = proto
      elif proto.name == "walk": loopFn = proto
    check f != nil
    var callTail = initTable[string, bool]()
    for inst in f.chunk.instructions:
      if inst.name in ["g", "h", "k"]:
        callTail[inst.name] = inst.tail
    check callTail["g"]
    check callTail["h"]
    check not callTail["k"]

    check loopFn != nil
    check loopFn.chunk.matches.len == 1
    check loopFn.chunk.matches[0].tailResult
    var sawTailLoop = false
    for inst in loopFn.chunk.matches[0].elseBody.instructions:
      if inst.name == "walk":
        sawTailLoop = inst.tail
    check sawTailLoop

    let typeProto = chunk.typeProtos[0]
    var ctorTail = false
    for inst in typeProto.ctorFn.chunk.instructions:
      if inst.name == "g": ctorTail = inst.tail
    var messageTail = false
    for inst in typeProto.messages[0].fn.chunk.instructions:
      if inst.name == "g": messageTail = inst.tail
    check not ctorTail
    check messageTail

    var topLevelTail = false
    for inst in chunk.instructions:
      if inst.name == "g": topLevelTail = inst.tail
    check not topLevelTail

  test "tail context propagates only through the documented control forms":
    proc findNamedCall(chunk: Chunk, name: string): tuple[found, tail: bool] =
      if chunk == nil:
        return
      for inst in chunk.instructions:
        if inst.name == name and inst.op in {
            opCall0, opCall1, opCall2, opCall, opCallSplice,
            opCallName0, opCallName1, opCallNameN,
            opCallLocal0, opCallLocal1, opCallLocalN,
            opCallParentLocal0, opCallParentLocal1,
            opCallOuterLocal0, opCallOuterLocal1}:
          return (true, inst.tail)
      for match in chunk.matches:
        for clause in match.clauses:
          let found = findNamedCall(clause.body, name)
          if found.found: return found
        let found = findNamedCall(match.elseBody, name)
        if found.found: return found
      for attempt in chunk.tries:
        let bodyFound = findNamedCall(attempt.body, name)
        if bodyFound.found: return bodyFound
        for clause in attempt.catches:
          let catchFound = findNamedCall(clause.body, name)
          if catchFound.found: return catchFound
        let ensureFound = findNamedCall(attempt.ensureBody, name)
        if ensureFound.found: return ensureFound

    for body in [
      "(do 1 (g))",
      "(if_yes true (g))",
      "(if_not false (g))",
      "(&& true (g))",
      "(|| false (g))",
      "(?? nil (g))",
      "(return (g))"
    ]:
      let root = compileSource("(fn g [] 1) (fn f [] " & body & ")")
      let found = findNamedCall(root.functions[1].chunk, "g")
      check found.found
      check found.tail

    let protected = compileSource(
      "(fn g [] 1) " &
      "(fn f [] (try (g) catch Any 0)) " &
      "(fn w [] (while false (g)))")
    let tryCall = findNamedCall(protected.functions[1].chunk, "g")
    let loopCall = findNamedCall(protected.functions[2].chunk, "g")
    check tryCall.found
    check not tryCall.tail
    check loopCall.found
    check not loopCall.tail

  test "GIR v5 round-trips tail metadata":
    let chunk = compileSource(
      "(fn walk [xs] (match xs (when [] 0) (else (walk []))))")
    let iface = CompileNamespaceInterface(
      entries: initTable[string, CompileInterfaceEntry]())
    let artifact = ExecutableGir(entryIdentity: "test/module",
      modules: @[CompiledModule(identity: "test/module", chunk: chunk,
        macroExports: initTable[string, MacroDef](), syntaxFnExports: @[],
        compileInterface: iface)])
    let payload = encodeExecutableGir(artifact)
    check "\"gir_format\":5" in payload
    let decoded = decodeExecutableGir(payload)
    expect ValueError:
      discard decodeExecutableGir(
        payload.replace("\"gir_format\":5", "\"gir_format\":4"))
    let loopFn = decoded.modules[0].chunk.functions[0]
    check loopFn.chunk.matches[0].tailResult
    var sawTailCall = false
    for inst in loopFn.chunk.matches[0].elseBody.instructions:
      sawTailCall = sawTailCall or inst.tail
    check sawTailCall

  test "GIR values round-trip quoted pipeline syntax":
    let chunk = compileSource(
      "(fn syntax [x] `(1 -> + %x)) (quote (1 -> + 2 => * 3))")
    let iface = CompileNamespaceInterface(
      entries: initTable[string, CompileInterfaceEntry]())
    let artifact = ExecutableGir(entryIdentity: "test/pipeline",
      modules: @[CompiledModule(identity: "test/pipeline", chunk: chunk,
        macroExports: initTable[string, MacroDef](), syntaxFnExports: @[],
        compileInterface: iface)])
    let decoded = decodeExecutableGir(encodeExecutableGir(artifact))
    check decoded.modules[0].chunk.functions[0].chunk.pipelineBuilds.len == 1
    var found = false
    for value in decoded.modules[0].chunk.constants:
      if value.kind == vkPipeline:
        found = true
        check value.print() == "(1 -> + 2 => * 3)"
    check found

  test "compiler-owned pipeline locals stay out of reflected bindings":
    let scope = newGlobalScope()
    discard run(compileSource(
      "(fn twice [n] (* n 2)) (fn wrap [n] [n]) " &
      "((1 -> + 2) -> wrap => twice)"), scope)
    scope.materializeMirroredVars()
    for name, _ in scope.vars:
      check not name.startsWith("\x00gene_pipeline_")
      check not name.startsWith("\x00gene_iterate_")
      check not name.startsWith("\x00gene_item_")

  test "emits a callable-first bytecode sequence":
    let chunk = compileSource("(+ 1 2)")
    check chunk.instructions.len == 3
    check chunk.instructions[0].op == opPushConst
    check chunk.constants[chunk.instructions[0].intArg].intVal == 1
    check chunk.instructions[1].op == opIntAddConst
    check chunk.instructions[1].name == "+"
    check chunk.constants[chunk.instructions[1].depth].intVal == 2
    check chunk.instructions[2].op == opReturn

  test "ordinary callees evaluate argument bytecode eagerly":
    let dynamic = compileSource("(fn hof [f] (f 1))").functions[0].chunk
    check dynamic.instructions[0].op == opLoadLocal
    check dynamic.instructions[1].op == opPushConst
    check dynamic.instructions[2].op == opCall1

    let ambient = compileSource("(external 1)")
    check ambient.instructions[0].op == opLoadName
    check ambient.instructions[1].op == opPushConst
    check ambient.instructions[2].op == opCall1

    let typed = compileSource("(fn hof [f : Fn] (f 1))").functions[0].chunk
    check typed.instructions[0].op == opPushConst
    check typed.instructions[1].op == opCallLocal1

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

    let named = compileSource("(fn [x ^scale] (+ x scale))").functions[0]
    check named.fastBindRequiredNamed

    let optionalNamed = compileSource("(fn [x ^scale = 1] (+ x scale))").functions[0]
    check not optionalNamed.fastBindRequiredNamed

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
                                "  (.to_name ^protocol ToName ^receiver User))")
    check flipped.functions[0].chunk.directProtocolCalls.len == 1
    check flipped.functions[0].chunk.directProtocolCalls[0].messageName == "to_name"

  test "marks simple typed Int arithmetic as native compiled":
    let chunk = compileSource("(fn add [x : Int y : Int] : Int (+ x y))")
    let proto = chunk.functions[0]
    check proto.nativeOp == ncoIntAdd
    check "native=int_add" in chunk.disassemble()

    let identityChunk = compileSource("(fn id [x : Int] : Int x)")
    check identityChunk.functions[0].nativeOp == ncoIntIdentity
    check identityChunk.functions[0].nativeParamIndex == 0
    check "native=int_identity" in identityChunk.disassemble()

    let pickChunk = compileSource(
      "(fn pick [a : Int b : Int c : Int] : Int b)")
    check pickChunk.functions[0].nativeOp == ncoIntIdentity
    check pickChunk.functions[0].nativeParamIndex == 1

    let i64Chunk = compileSource("(fn add64 [x : I64 y : I64] : I64 (+ x y))")
    check i64Chunk.functions[0].nativeOp == ncoI64Add
    check "native=i64_add" in i64Chunk.disassemble()

    let f64Chunk = compileSource("(fn mul64 [x : F64 y : F64] : F64 (* x y))")
    check f64Chunk.functions[0].nativeOp == ncoF64Mul
    check "native=f64_mul" in f64Chunk.disassemble()

    let dynamicChunk = compileSource("(fn add [x : Int y : Int] : Int (+ y x))")
    check dynamicChunk.functions[0].nativeOp == ncoNone

    let aotChunk = compileSource("(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
                                 "(fn add64_twice [x : I64 y : I64] : I64 " &
                                 "  (add64 (add64 x y) y))")
    check aotChunk.functions[0].aotExpr.kind != vkNil
    check aotChunk.functions[1].aotExpr.kind != vkNil
    check aotChunk.functions[0].aotFrameKind == afkTypedNative
    check not aotChunk.functions[0].aotFrameCanSuspend
    check "aot=c frame=typed_native" in aotChunk.disassemble()
    check "typed-module-aot:" in aotChunk.disassemble()
    check "add64 repr=I64 arity=2 frame=typed_native" in aotChunk.disassemble()

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

  test "keeps mutable recursive var-bound calls callable-first":
    let chunk = compileSource(
      "(var fib (fn [n] (if (< n 2) n (fib (- n 1))))) " &
      "(set fib (fn [n] n))")
    let proto = chunk.functions[0]
    check proto.chunk.instructions[5].op == opLoadOuterLocal
    check proto.chunk.instructions[5].name == "fib"
    check proto.chunk.instructions[8].op == opCall1

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

    let explicitRoot = compileSource(
      "(scope (var x 1) (spawn ^lane root (+ x 1)))").disassemble()
    check explicitRoot.contains("opSpawn body=0")
    check not explicitRoot.contains("worker-candidate=true")

  test "spawn validates explicit lane placement":
    expect GeneError:
      discard compileSource("(spawn ^lane worker 1)")
    expect GeneError:
      discard compileSource("(spawn ^unknown true 1)")

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
      "(var total 0) (for [a b] in [[1 2]] (set total (+ total a b)))")
    let loopBody = loopChunk.forLoops[0].body
    check loopBody.localNames == @["a", "b"]

    let tryChunk = compileSource("(try 1 catch Any $ex/message)")
    let catchBody = tryChunk.tries[0].catches[0].body
    check catchBody.localNames == @["$ex"]
    check catchBody.instructions[0].op == opLoadLocal
    check catchBody.instructions[0].name == "$ex"

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
      "(import gene/stream : stream) (fn use [] stream)")
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
      "(protocol P (message ping [x])) (fn use [x] (x .ping))")
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
    let chunk = compileSource("`(tag ^class %cls $body)")
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
    let fnChunk = compileSource(
      "(fn f [x, y : Int? = nil, ^scale = (+ x 1), ^opt : Str?] [x y scale opt])")
    let proto = fnChunk.functions[0]
    check proto.params == @["x", "y"]
    check proto.paramDefaults.len == 2
    check proto.paramDefaults[0].optional == false
    check proto.paramDefaults[1].optional == true
    check proto.paramDefaults[1].defaultChunk != nil
    check proto.namedParams.len == 2
    check proto.namedParams[0].arg == "scale"
    check proto.namedParams[0].defaultValue.optional == true
    check proto.namedParams[0].defaultValue.defaultChunk != nil
    # ^opt : Str? — nil-admitting type: optional with no default chunk;
    # the runtime binds nil when the argument is omitted.
    check proto.namedParams[1].arg == "opt"
    check proto.namedParams[1].defaultValue.optional == true
    check proto.namedParams[1].defaultValue.defaultChunk == nil
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
    expect GeneError: discard compileSource("(.+ 1)")
    # D6: `(.msg)` dispatches on self's type; use a real message, not a
    # lexical function like `+` (Int has no `+` message).
    ck "(type Box ^props {^n Int} (message plus1 [self] (+ self/n 1))) " &
       "(fn run [self] (.plus1)) (run (Box ^n 2))", "3"

suite "module references":
  test "all reader and runtime forms share one module table":
    ck "#Ref shared [1 2] " &
       "[(same? #Deref shared ($deref shared)) " &
       " (same? #Deref shared (gene/deref shared))]", "[true true]"
    ck "($ref shared [1 2]) " &
       "[(same? #Deref shared ($deref shared)) " &
       " (same? #Deref shared (gene/deref shared))]", "[true true]"
    ck "#Ref shared [1 2] (fn get_shared [] #Deref shared) " &
       "(same? (get_shared) ($deref shared))", "true"
    ck "(fn get_missing [] " &
       "  (try #Deref missing catch UnknownRef $ex/name)) " &
       "(get_missing)", "\"missing\""

  test "reference namespace is separate from lexical bindings":
    ck "(var shared 10) #Ref shared [1 2] " &
       "[shared ($size #Deref shared)]", "[10 2]"

  test "identity-bearing values are shared and scalar values compare by value":
    ck "#Ref shared [1] " &
       "(var a #Deref shared) (var b ($deref shared)) " &
       "(a .set 0 9) [(same? a b) (b .first)]", "[true 9]"
    ck "#Ref answer 42 [#Deref answer ($deref answer)]", "[42 42]"
    ck "#Ref flag true [#Deref flag ($deref flag)]", "[true true]"
    ck "#Ref absent nil [#Deref absent ($deref absent)]", "[nil nil]"
    ck "#Ref skipped void [#Deref skipped ($deref skipped)]", "[void void]"
    ck "#Ref text \"hello\" [#Deref text ($deref text)]",
       "[\"hello\" \"hello\"]"

  test "structural dereferences support forward definitions":
    ck "(var x #Deref shared) #Ref shared [1 2] " &
       "(same? x ($deref shared))", "true"
    ck "(var x #Deref config) ($ref config [3 4]) " &
       "(same? x ($deref config))", "true"
    ck "(var pair [#Deref later #Deref later]) #Ref later [7] " &
       "(same? (pair .first) (pair .last))", "true"
    ck "(type App ^props {^config (List Int)}) " &
       "(var app (App ^config #Deref config)) #Ref config [1 2] " &
       "[(same? app/config ($deref config)) ($size app/config)]",
       "[true 2]"
    expect GeneError:
      discard runStr("(type App ^props {^config (List Int)}) " &
                     "(var app (App ^config #Deref config)) " &
                     "#Ref config [1 \"bad\"]")
    ck "#Ref cycle ($cell #Deref cycle) " &
       "(same? (($deref cycle) .get) ($deref cycle))", "true"
    ck "(macro define_shared [] `#Ref shared [1]) " &
       "(define_shared) (($deref shared) .first)", "1"

  test "runtime errors are typed and initializers can retry after failure":
    ck "(try ($deref missing) " &
       " catch UnknownRef $ex/name)", "\"missing\""
    ck "(var pending #Deref later) " &
       "(try pending catch RefNotResolved $ex/name) " &
       "#Ref later 1", "1"
    ck "(var holder {^value #Deref later}) " &
       "(var observed (try holder/value " &
       " catch RefNotResolved $ex/name)) " &
       "#Ref later 1 observed", "\"later\""
    ck "#Ref once 1 " &
       "(try ($ref once 2) catch RefAlreadyResolved $ex/name)",
       "\"once\""
    ck "(var caught (try ($ref circular ($deref circular)) " &
       " catch CircularRefResolution $ex/name)) " &
       "($ref circular 1) caught", "\"circular\""
    ck "(try ($ref retry (fail (MatchError ^message \"no\"))) " &
       " catch MatchError nil) ($ref retry 9) ($deref retry)", "9"

  test "invalid definitions and unresolved completed units fail":
    expect GeneError:
      discard runStr("(fn bad [] ($ref local 1))")
    expect GeneError:
      discard runStr("(var pending #Deref never)")
    expect GeneError:
      discard runStr("(macro leave_pending [] `#Deref never) " &
                     "(leave_pending)")
    expect GeneError:
      discard runStr("(var values (Set #Deref item 1)) " &
                     "#Ref item 1 values")
    expect GeneError:
      discard runStr("(var values (Set #Deref item)) " &
                     "#Ref item [1] values")
    ck "(var caught (try #Ref cycle [#Deref cycle] " &
       " catch InvalidRefDefinition $ex/name)) " &
       "($ref cycle 1) caught", "\"cycle\""

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

  test "runs same-scope tail recursion through recur ops":
    let src =
      "(var countdown (fn [n] (if (< n 1) n (countdown (- n 1))))) " &
      "(countdown 128)"
    let dump = compileSource(src).disassemble()
    check dump.contains("opRecur1LocalIntSubImmSameScope slot=0 name=n imm=1")
    check dump.contains("8: opReturn")
    ck src, "0"

  test "runs simple tail-call wrappers":
    let src =
      "(var id (fn [x] x)) " &
      "(var wrap (fn [x] (id x))) " &
      "(wrap 9)"
    let dump = compileSource(src).disassemble()
    check dump.contains("opCallParentLocal1 slot=0 name=id argc=1")
    check dump.contains("2: opReturn")
    ck src, "9"

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
    let globalDump = compileSource("(call_four 1 2 3 4)").disassemble()
    check globalDump.contains("opLoadName name=call_four")
    check not globalDump.contains("opSyntaxGuard")
    check globalDump.contains("opCall argc=4")

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
  test "general map evaluates keys and values":
    ck "(var k \"a\") ({{k : (+ 1 2)}} .get \"a\")", "3"
    ck "{{\"a\" : 1 \"a\" : 2}}", "{{\"a\" : 2}}"
    ck "{{\"a\" : 1 \"a\" : void}}", "{{}}"
    expect GeneError:
      discard runStr("{{[1] : 2}}")
  test "set constructor deduplicates hash-stable values":
    ck "(Set 1 2 1)", "(Set 1 2)"
    ck "($set_has? (Set \"a\" \"b\") \"b\")", "true"
    ck "($size (Set 1 2 1))", "2"
    expect GeneError:
      discard runStr("(Set [1])")
    ck "(Set #[1])", "(Set #[1])"
  test "bytes literals are self-evaluating":
    ck "[#B#01000001 #B16#4869 #B64#SGk=]",
       "[#B16#41 #B16#4869 #B16#4869]"
  test "regex literals and constructor are self-evaluating":
    ck "[#\"\\d+\" (Regex \"\\\\d+\") (Regex ^flags \"mi\" \"abc\")]",
       "[#\"\\d+\" #\"\\d+\" #\"abc\"im]"
    ck "((fn [r : Regex] true) #\"x\")", "true"
  test "regex match returns a typed Match node":
    ck "(var m (#\"(?<word>\\w+)-(\\d+)\" .match \"ab-12 zz\")) " &
       "[m/text m/groups (m/named .get \"word\") m/start m/end]",
       "[\"ab-12\" #[\"ab\" \"12\"] \"ab\" 0 5]"
    ck "(#\"z+\" .match \"abc\")", "void"
  test "regex find_all returns a stream":
    ck "(var xs ($into (#\"\\d+\" .find_all \"a12b3\") [])) " &
       "[xs/0/text xs/0/start xs/0/end xs/1/text xs/1/start xs/1/end]",
       "[\"12\" 1 3 \"3\" 4 5]"
  test "regex replace and split":
    ck "(#\"(\\w+)=(\\d+)\" .replace \"a=1 b=22\" \"\\\\2/\\\\1\")",
       "\"1/a b=22\""
    ck "(#\"(\\w+)=(?<n>\\d+)\" .replace_all \"a=1 b=22\" \"\\\\k<n>\")",
       "\"1 22\""
    ck "(#\"\\s*,\\s*\" .split \"a, b,c\")", "[\"a\" \"b\" \"c\"]"
  test "map and node storage drops void props":
    ck "{^a void ^b 1}", "{^b 1}"
    ck "(quote (x ^a void ^b 1 @m void @n 2))", "(x @n 2 ^b 1)"
  test "quote suppresses evaluation":
    ck "(quote (+ 1 2))", "(+ 1 2)"
    ck "(quote (.f a))", "(.f a)"

suite "vm — strings and interpolation":
  test "to_str converts values to display text":
    ck "[($to_str \"Ada\") ($to_str (quote (user ^name \"Ada\")))]",
       "[\"Ada\" \"(user ^name \\\"Ada\\\")\"]"

  test "strings iterate explicitly by chars and bytes":
    ck "[($chars \"Aé\") ($bytes \"Aé\")]", "[['A' 'é'] [65 195 169]]"
    ck "(try ($chars 1) catch Any $ex/message)", "\"chars expects a Str\""
    ck "(try ($bytes) catch Any $ex/message)",
       "\"bytes expects 1 argument, got 0\""

  test "graphemes group combining scalars":
    let s = "e\u0301x"
    ck "(var s \"" & s & "\") [($chars s) ($graphemes s) ($bytes s)]",
       "[['e' '\u0301' 'x'] [\"e\u0301\" \"x\"] [101 204 129 120]]"
    ck "(try ($graphemes 1) catch Any $ex/message)",
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
  test "shared expansion artifact preserves source and macro provenance":
    let source = "(macro choose_unless [condition yes no] " &
      "`(if (! %condition) %yes %no))\n" &
      "(choose_unless false \"expanded\" \"wrong\")"
    let artifact = expandSourceUnitMacros(
      readAllWithLocs(source, "macro_provenance.gene"))
    check artifact.original.forms.len == 2
    check artifact.expanded.forms.len == 1
    check artifact.macroExports.hasKey("choose_unless")
    check artifact.expanded.forms[0].print() ==
      "(if (! false) \"expanded\" \"wrong\")"
    var sawCallSite = false
    for _, provenance in artifact.provenance:
      if provenance.macroName == "choose_unless" and
          provenance.sourceLoc.sourceName == "macro_provenance.gene" and
          provenance.sourceLoc.line == 2:
        sawCallSite = true
    check sawCallSite
    check run(compileSource(source), newGlobalScope()).print() == "\"expanded\""

  test "macro calls bind named syntax props":
    ck "(macro scaled [value ^by n] `(+ %value %n)) " &
       "(scaled ^by 3 7)",
       "10"
    ck "(macro scaled [value ^by amount] `(+ %value %amount)) " &
       "(scaled ^by 4 9)",
       "13"
    ck "(macro tagged [value ^tag t] `(quote (%t %value))) " &
       "(tagged ^tag item 7)",
       "(item 7)"
    expect GeneError:
      discard runStr("(macro scaled [value ^by n] `(+ %value %n)) " &
                     "(scaled 7)")
    expect GeneError:
      discard runStr("(macro scaled [value ^by n] `(+ %value %n)) " &
                     "(scaled ^other 3 7)")

  test "macro parameters destructure syntax patterns":
    ck "(macro second [[_ value]] `%value) " &
       "(second [ignored (+ 1 2)])",
       "3"
    ck "(macro pick_prop [{^value v}] `%v) " &
       "(pick_prop {^value (+ 2 3)})",
       "5"
    ck "(macro call_arg [(call ^arg v)] `%v) " &
       "(call_arg (call ^arg (+ 4 5)))",
       "9"
    ck "(macro rest_items [[head tail...]] `(quote %tail)) " &
       "(rest_items [1 2 3])",
       "[2 3]"
    ck "(macro eval_node [(form : Node)] `%form) " &
       "(eval_node (+ 1 2))",
       "3"
    ck "(macro eval_flat [form : Node] `%form) " &
       "(eval_flat (+ 2 3))",
       "5"
    ck "(macro keep_syms [(items : (List Sym))] `(quote %items)) " &
       "(keep_syms [a b])",
       "[a b]"
    ck "(macro keep_entry [^entry item : (List Sym)] `(quote %item)) " &
       "(keep_entry ^entry [a b])",
       "[a b]"
    expect GeneError:
      discard runStr("(macro eval_node [(form : Node)] `%form) " &
                     "(eval_node 1)")
    expect GeneError:
      discard runStr("(macro eval_flat [form : Node] `%form) " &
                     "(eval_flat 1)")
    expect GeneError:
      discard runStr("(macro keep_syms [(items : (List Sym))] `(quote %items)) " &
                     "(keep_syms [a 1])")
    ck "(macro named_pair [^entry [k v]] `(+ %k %v)) " &
       "(named_pair ^entry [2 3])",
       "5"
    expect GeneError:
      discard runStr("(macro second [[_ value]] `%value) " &
                     "(second [only-one])")
    ck "(macro default_value [x = 7] `%x) " &
       "[(default_value) (default_value 9)]",
       "[7 9]"
    ck "(macro second_or_first [x y = x] `%y) " &
       "[(second_or_first (+ 1 2)) (second_or_first 1 4)]",
       "[3 4]"
    ck "(macro named_default [^value v = (+ 2 3)] `%v) " &
       "[(named_default) (named_default ^value 8)]",
       "[5 8]"
    ck "(macro optional [x = nil] `%x) (optional)", "nil"
    expect GeneError:
      discard compileSource("(macro bad [x = 1 y] `%y)")

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
    ck "(== (+ 9223372036854775807 1) 9223372036854775808)", "true"
    ck "(< 1 3 2)", "false"
    ck "(>= 3 3 1)", "true"
  test "structural equality":
    ck "(== 2 2)", "true"
    ck "(== [1 2] [1 2])", "true"
    ck "(== 1 2)", "false"
  test "hash follows stable structural equality":
    ck "(== ($hash #[1 2]) ($hash ($freeze [1 2])))", "true"
    ck "(== ($hash (quote #(x @line 1 ^a 2))) " &
       "   ($hash (quote #(x @line 99 ^a 2))))", "true"
    ck "(try ($hash [1 2]) catch Any $ex/message)",
       "\"hash expects a hash-stable value\""
    ck "(try ($hash #[($cell 1)]) catch Any $ex/message)",
       "\"hash expects a hash-stable value\""
    expect GeneError: discard runStr("($hash)")
  test "same compares scalar values and heap identity":
    ck "(same? 2 2)", "true"
    ck "(same? \"x\" \"x\")", "true"
    ck "(same? [1 2] [1 2])", "false"
    ck "(var xs [1 2]) (same? xs xs)", "true"
    expect GeneError: discard runStr("(same? 1)")
  test "freeze and thaw convert container mutability explicitly":
    ck "($freeze_shallow [1 [2]])", "#[1 [2]]"
    ck "($freeze [1 {^a [2]}])", "#[1 #{^a #[2]}]"
    ck "($thaw ($freeze [1 {^a [2]}]))", "[1 {^a [2]}]"
    ck "(try ($freeze [($cell 1)]) catch Any $ex/message)",
       "\"freeze cannot freeze Cell\""
    expect GeneError: discard runStr("($freeze)")
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
    ck "(scope (var t (spawn 1)) (t .cancel))", "nil"

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
       "(impl Error for Boom) " &
       "(scope (var t (spawn (fail (Boom ^message \"x\")))) " &
       "  (try (await t) catch Boom $ex/message))",
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
    ck "(var maybe : (? Int)) maybe", "nil"
    ck "(try (var x : Int \"no\") x catch TypeError $ex/where)",
       "\"var 'x'\""
    ck "(type Request ^props {^path Str}) " &
       "(fn app [raw] (var req : Request raw) req/path) " &
       "(app (Request ^path \"/\"))",
       "\"/\""
    ck "(try (var s : (Stream Int Never) ($to_stream [\"bad\"])) " &
       "     (s .next) " &
       "catch TypeError $ex/where)",
       "\"Stream/next item\""
  test "set reassigns an existing binding":
    ck "(var x 1) (set x 99) x", "99"
  test "set checks typed binding boundaries":
    ck "(var x : Int 1) (set x 2) x", "2"
    ck "(try (var x : Int 1) (set x \"bad\") x " &
       "catch TypeError $ex/where)",
       "\"set 'x'\""
    ck "(try (fn f [x : Int] (set x \"bad\") x) (f 1) " &
       "catch TypeError $ex/where)",
       "\"set 'x'\""
    ck "(try (fn f [^x : Int] (set x \"bad\") x) (f ^x 1) " &
       "catch TypeError $ex/where)",
       "\"set 'x'\""
    ck "(try (fn (f item) [x : item] (set x \"bad\") x) (f 1) " &
       "catch TypeError $ex/where)",
       "\"set 'x'\""
    ck "(try (fn outer [] (var x : Int 1) (fn [] (set x \"bad\"))) " &
       "     ((outer)) " &
       "catch TypeError $ex/where)",
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
    ck "(fn count [n] (if (== n 0) 0 (+ 1 (count (- n 1))))) (count 200000)",
       "200000"
  test "deep recursion through a typed (general-path) function uses heap frames":
    # Typed params / return types take the general call path; it is now on the
    # frame stack too, so deep recursion through it no longer grows the Nim stack.
    ck "(fn count [n : Int] : Int (if (== n 0) 0 (+ 1 (count (- n 1))))) " &
       "(count 200000)", "200000"
  test "deep recursion through an ^errors function uses heap frames":
    # ^errors functions also push heap frames now; the loop's exception handler
    # applies the undeclared-error boundary on unwind, so deep recursion through
    # a checked function no longer grows the Nim stack on the success path.
    ck "(fn count ^errors [] [n] (if (== n 0) 0 (+ 1 (count (- n 1))))) " &
       "(count 200000)", "200000"
  test "recoverable errors expose bytecode frame traces":
    ck "(fn outer [] (inner)) " &
       "(fn inner [] (var x : Int \"bad\") x) " &
       "(try (outer) catch TypeError " &
       "  [$ex/trace/0/name $ex/trace/0/kind " &
       "   $ex/trace/1/name $ex/trace/1/kind])",
       "[\"inner\" \"bytecode\" \"outer\" \"bytecode\"]"
  test "native-compiled typed Int arithmetic uses dynamic boundary adapters":
    ck "(fn add [x : Int y : Int] : Int (+ x y)) (add 20 22)", "42"
    ck "(fn sub [x : Int y : Int] : Int (- x y)) (sub 20 7)", "13"
    ck "(fn mul [x : Int y : Int] : Int (* x y)) (mul 6 7)", "42"
    ck "(fn add64 [x : I64 y : I64] : I64 (+ x y)) (add64 20 22)", "42"
    ck "(fn mul64 [x : F64 y : F64] : F64 (* x y)) (mul64 3.5 2.0)", "7.0"
    ck "(fn add [x : Int y : Int] : Int (+ x y)) " &
       "(try (add \"bad\" 1) catch TypeError $ex/where)",
       "\"parameter 'x'\""
    ck "(fn pick [a : Int b : Int c : Int] : Int b) " &
       "(try (pick 1 2 \"bad\") catch TypeError $ex/where)",
       "\"parameter 'c'\""
    ck "(fn outer [] (add \"bad\" 1)) " &
       "(fn add [x : Int y : Int] : Int (+ x y)) " &
       "(try (outer) catch TypeError " &
       "  [$ex/trace/0/name $ex/trace/0/kind " &
       "   $ex/trace/1/name $ex/trace/1/kind])",
       "[\"add\" \"typed_native\" \"outer\" \"bytecode\"]"
    ck "(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
       "(try (add64 9223372036854775807 1) " &
       "catch TypeError $ex/where)",
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
  test "optional positional parameters use defaults":
    ck "(var f (fn [x : Int? = nil] x)) (f)", "nil"
    ck "(var f (fn [x : Int? = nil] x)) (f 7)", "7"
  test "positional defaults are evaluated at call time":
    ck "(var f (fn [x = 4] x)) (f)", "4"
    ck "(var f (fn [x = 4] x)) (f 9)", "9"
  test "positional defaults can reference earlier parameters":
    ck "(var f (fn [x y = (+ x 1)] y)) (f 4)", "5"
  test "defaults see the call-time captured scope":
    ck "(var base 1) (var f (fn [x = base] x)) (set base 2) (f)", "2"
  test "optional named parameters bind nil when omitted":
    ck "(var f (fn [^width : Int?] width)) (f)", "nil"
    ck "(var f (fn [^width : Int?] width)) (f ^width 8)", "8"
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
    ck "(try ((select ^strict true name) {^age 37}) catch Any $ex/message)",
       "\"selector lookup failed at segment: name\""
    ck "(try ((select ^strict true ^default \"unknown\" name) {^age 37}) " &
       "catch Any $ex/message)",
       "\"selector lookup failed at segment: name\""
    expect GeneError:
      discard runStr("((select ^strict 1 name) {^age 37})")
  test "selectors read list indexes and path sends expose list behavior":
    ck "(var xs [10 20 30]) xs/1", "20"
    ck "(var xs [10 20 30]) xs/-1", "30"
    ck "(var xs [10 20 30]) xs/size", "void"
    ck "(var xs [10 20 30]) [xs/.size xs/.empty? xs/.first xs/.last]",
       "[3 false 10 30]"
    ck "(var xs []) [xs/.empty? xs/.first xs/.last]", "[true void void]"
    ck "(fn size [xs] xs/.size) (size [1 2 3])", "3"
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
       "(var names users/%$to_stream/name) " &
       "[(names .next) (names .next) (names .has_next)]",
       "[\"Ada\" \"Bob\" false]"

  test "first-class selectors map over streams":
    ck "(var get-name /name) " &
       "(var names (get-name ($to_stream [{^name \"Ada\"} {^name \"Bob\"}]))) " &
       "[(names .next) (names .next) (names .has_next)]",
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
       "(var get (select %($key field))) " &
       "(get {^name \"Ada\"})",
       "\"Ada\""
    ck "(var plus +) " &
       "[((select %plus) 4) ((select %($key plus)) 4)]",
       "[4 void]"
    ck "(var field \"name\") " &
       "(var users [{^name \"Ada\"} {^age 37} {^name \"Bob\"}]) " &
       "(var names ((select %$to_stream %($key field)) users)) " &
       "[(names .next) (names .next) (names .has_next)]",
       "[\"Ada\" \"Bob\" false]"
  test "complex selector stages adapt stream helpers":
    ck "(var users [{^name \"Ada\" ^adult true} " &
       "            {^name \"Tim\" ^adult false} " &
       "            {^name \"Bob\" ^adult true}]) " &
       "(var names ((select %$to_stream %($filter /adult) name) users)) " &
       "[(names .next) (names .next) (names .has_next)]",
       "[\"Ada\" \"Bob\" false]"
    ck "(var users [{^name \"Ada\"} {^name \"Bob\"} {^name \"Cy\"}]) " &
       "((select %$to_stream %($map /name) %($take 2) %($into [])) users)",
       "[\"Ada\" \"Bob\"]"

suite "vm — node projection built-ins":
  test "projection built-ins expose value anatomy":
    ck "($head 42)", "(type Int)"
    ck "($head [1 2])", "(type List)"
    ck "($head {^a 1})", "(type Map)"
    ck "($head (quote (user ^name \"Ada\" 10 20)))", "user"
    ck "($props {^name \"Ada\"})", "{^name \"Ada\"}"
    ck "($props (quote (user ^name \"Ada\" 10 20)))", "{^name \"Ada\"}"
    ck "($body 42)", "[42]"
    ck "($body [10 20])", "[10 20]"
    ck "($body {^a 1})", "[]"
    ck "($body (quote (user ^name \"Ada\" 10 20)))", "[10 20]"
    ck "($meta (quote (user @line 7 ^name \"Ada\")))", "{^line 7}"
  test "projection built-ins work as dynamic selector stages":
    ck "(var user (quote (user @line 7 ^name \"Ada\" 10 20))) user/%$head",
       "user"
    ck "(var user (quote (user @line 7 ^name \"Ada\" 10 20))) user/%$props/name",
       "\"Ada\""
    ck "(var user (quote (user @line 7 ^name \"Ada\" 10 20))) user/%$body/1",
       "20"
    ck "(var user (quote (user @line 7 ^name \"Ada\" 10 20))) user/%$meta/line",
       "7"
  test "projection built-ins validate arity":
    expect GeneError: discard runStr("($props)")
    expect GeneError: discard runStr("($body 1 2)")
  test "projection containers are detached shallow snapshots":
    ck "(var child [1]) " &
       "(var n `(user @note %child ^data %child %child)) " &
       "(var ps ($props n)) (var bs ($body n)) (var ms ($meta n)) " &
       "(ps .put `extra 2) " &
       "(bs .set 0 3) " &
       "(ms .put `other 4) " &
       "[(== n/extra void) n/0 (== n/%$meta/other void)]",
       "[true [1] true]"
    ck "(var child [1]) " &
       "(var n `(user @note %child ^data %child %child)) " &
       "(var projected ($props n)) " &
       "(projected/data .set 0 9) " &
       "[n/data/0 n/0/0 n/%$meta/note/0]",
       "[9 9 9]"

suite "vm — functional selector updates":
  test "assoc_in updates maps without mutating the original":
    ck "(var user {^name \"Ada\" ^age 37}) (var user2 ($assoc_in user /age 38)) (+ (* user/age 100) user2/age)",
       "3738"
    ck "($assoc_in {^name \"Ada\"} /city \"Raleigh\")",
       "{^name \"Ada\" ^city \"Raleigh\"}"
  test "assoc_in updates lists and node bodies":
    ck "($assoc_in [10 20 30] /1 99)", "[10 99 30]"
    ck "($assoc_in [10 20 30] /-1 99)", "[10 20 99]"
    ck "($assoc_in (quote (user ^name \"Ada\" 10 20)) /1 99)",
       "(user ^name \"Ada\" 10 99)"
  test "assoc_in preserves immutable container class":
    ck "($assoc_in #{^age 37} /age 38)", "#{^age 38}"
    ck "($assoc_in #[10 20] /1 99)", "#[10 99]"
  test "assoc_in writes void as delete for maps and nil for positions":
    ck "($assoc_in {^name \"Ada\" ^age 37} /age void)", "{^name \"Ada\"}"
    ck "($assoc_in (quote (user ^name \"Ada\" 10 20)) /0 void)",
       "(user ^name \"Ada\" nil 20)"
    ck "($assoc_in [10 20] /1 void)", "[10 nil]"
  test "assoc_in updates nested existing paths":
    ck "(var user {^address {^city \"Durham\"}}) ($assoc_in user /address/city \"Raleigh\")",
       "{^address {^city \"Raleigh\"}}"
    ck "(var user (quote (user ^address (addr ^city \"Durham\")))) ($assoc_in user /address/city \"Raleigh\")",
       "(user ^address (addr ^city \"Raleigh\"))"
  test "update_in applies a callable to the selected value":
    ck "(var user {^score 2}) ($update_in user /score (fn [x] (+ x 1)))",
       "{^score 3}"
    ck "(var n (quote (user ^name \"Ada\"))) ($update_in {^n n} /n /name)",
       "{^n \"Ada\"}"
  test "functional updates reject unsupported paths":
    expect GeneError: discard runStr("($assoc_in {^name \"Ada\"} /address/city \"Raleigh\")")
    expect GeneError: discard runStr("($assoc_in [1] /2 9)")
    expect GeneError: discard runStr("($assoc_in 1 /x 2)")
    expect GeneError: discard runStr("($update_in {^score 1} /score 1)")
    expect GeneError:
      discard runStr("(var s (select %($map /name))) " &
                     "($assoc_in {^name \"Ada\"} s \"Bob\")")

suite "vm — container update built-ins":
  test "List/assoc returns an updated copy":
    ck "(var xs #[1 2 3]) (var ys (xs .assoc 1 20)) [xs ys]",
       "[#[1 2 3] #[1 20 3]]"
    ck "([1 2] .assoc 1 void)", "[1 nil]"

  test "List/set mutates mutable lists":
    ck "(var xs [1 2]) [(xs .set 1 9) xs]", "[9 [1 9]]"
    ck "(var xs [1 2]) [(xs .set 0 void) xs]", "[nil [nil 2]]"
    expect GeneError:
      discard runStr("(#[1] .set 0 2)")

  test "List/push grows mutable lists in place":
    ck "(var xs [1]) [(xs .push 2) xs]", "[2 [1 2]]"
    ck "(var xs []) [(xs .push void) xs]", "[nil [nil]]"
    expect GeneError:
      discard runStr("(#[1] .push 2)")

  test "List/push supports linear accumulator growth":
    ck "(var xs []) (var i 0) " &
       "(while (< i 20000) (xs .push i) (set i (+ i 1))) " &
       "[($size xs) ($first xs) ($last xs)]",
       "[20000 0 19999]"

  test "Map/put mutates mutable maps":
    ck "(var m {^a 1}) [(m .put \"b\" 2) (/b m)]", "[2 2]"
    ck "(var m {^a 1}) [(m .put \"a\" void) (/a m)]", "[void void]"
    expect GeneError:
      discard runStr("(#{^a 1} .put \"a\" 2)")
  test "Map/delete removes an entry and returns what was there":
    ck "(var m {^a 1 ^b 2}) [(m .delete \"a\") m]", "[1 {^b 2}]"
    # Absent key is `void`, so a caller can tell "removed something" from
    # "there was nothing" without a second lookup.
    ck "(var m {^a 1}) [(m .delete \"zz\") m]", "[void {^a 1}]"
    # Symbol and string keys both work: the key is converted before comparing,
    # the same normalization `get` and `put` use. Map iteration yields symbols,
    # so an iterated key can be deleted directly.
    ck "(var m {^a 1 ^b 2}) (m .delete (quote a)) m", "{^b 2}"
    ck "(var m {^a 1 ^b 2}) (for [k v] in {^a 1} (m .delete k)) m", "{^b 2}"
    expect GeneError:
      discard runStr("(#{^a 1} .delete \"a\")")
    expect GeneError:
      discard runStr("([1] .delete \"a\")")

  test "to_sym is the inverse of to_str for names":
    ck "[($to_sym \"a\") ($to_str ($to_sym \"a\")) ($to_sym ($to_sym \"a\"))]",
       "[a \"a\" a]"
    ck "(== ($to_sym \"a\") (quote a))", "true"
    # `==` stays type-respecting — it does not coerce Sym to Str any more than
    # it coerces Int to Float — so conversion is explicit.
    ck "[(== (quote a) \"a\") (== 1 1.0)]", "[false false]"
    expect GeneError: discard runStr("($to_sym 1)")

  test "Map/assoc returns an updated copy":
    ck "(var m #{^a 1}) (var n (m .assoc \"b\" 2)) [m n]",
       "[#{^a 1} #{^a 1 ^b 2}]"
    ck "({^a 1} .assoc \"a\" void)", "{}"
    expect GeneError: discard runStr("([1] .assoc \"a\" 2)")
  test "Map/get reads entries without selector staging":
    ck "(var m {^a 1}) [(m .get \"a\") (m .get \"missing\")]",
       "[1 void]"
    ck "(var m {^a 1}) (m .get (quote a))", "1"
    expect GeneError: discard runStr("([1] .get \"a\")")

  test "Node/set_prop mutates mutable node props":
    ck "(var n (quote (user ^name \"Ada\"))) " &
       "[(n .set_prop \"name\" \"Bob\") (/name n)]",
       "[\"Bob\" \"Bob\"]"
    ck "(var n (quote (user ^name \"Ada\"))) " &
       "[(n .set_prop \"name\" void) (/name n)]",
       "[void void]"
    expect GeneError:
      discard runStr("(#(user ^name \"Ada\") .set_prop \"name\" \"Bob\")")

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

  test "undefined symbols identify their containing top-level form":
    try:
      discard run(compileSource("(var ok 1)\nout", "broken.gene"),
                  newGlobalScope())
      check false
    except GeneError as e:
      check "undefined symbol: out" in e.msg
      check "in top-level form opened at broken.gene:2:1: out" in e.msg

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
    ck "(ns m (var a 1)) (== m m)", "true"
  test "namespace reflection exposes bindings and lookup":
    ck "(ns m (var b 2) (var a 1)) [(m .lookup \"a\") (m .lookup \"missing\")]",
       "[1 void]"
    ck "(ns m (var b 2) (var a 1)) (m .bindings)",
       "{^a 1 ^b 2}"
  test "declarations exposes namespace bindings as a stream":
    ck "(ns m (var b 2) (var a 1)) " &
       "(var names m/%$declarations/name) " &
       "[(names .next) (names .next) (names .has_next)]",
       "[\"a\" \"b\" false]"
    ck "(ns m (var a 1)) (var ds (m .declarations)) (ds .next)",
       "(Declaration ^name \"a\" ^kind \"Int\" ^value 1)"
  test "namespace reflection operations require namespaces":
    expect GeneError: discard runStr("($declarations [1])")
    expect GeneError: discard runStr("([1] .bindings)")
    expect GeneError: discard runStr("([1] .lookup \"a\")")

suite "vm — env and eval":
  test "env values are opaque display values":
    ck "(env)", "(env)"

  test "eval compiles and executes a quoted node inside env bindings":
    ck "(var e (env ^bindings {^x 10})) (eval (quote (+ x 5)) ^in e)", "15"

  test "eval inherits the scope it is written in, and Env bindings add to it":
    # capabilities.md §14: evaluated code runs under the target environment's
    # lexical bindings *and* the evaluator's. This reversed an earlier contract
    # in which an Env hid the surrounding scope; sealing is now something a
    # program states rather than a default it receives.
    ck "(var visible \"seen\") (var e (env ^bindings {^x 1})) " &
       "[(eval (quote visible) ^in e) (eval (quote x) ^in e)]",
       "[\"seen\" 1]"

  test "a caller_env snapshot stays closed over the evaluating scope":
    # The one Env that does *not* inherit: a snapshot promises exactly the names
    # it captured, so a window onto the live scope would defeat naming them.
    ck "(var x 1) (var secret 9) " &
       "(fn capture! [] (caller_env .snapshot [\"x\"])) " &
       "(var saved (capture!)) " &
       "[(eval (quote x) ^in saved) " &
       " (try (eval (quote secret) ^in saved) catch Any \"absent\")]",
       "[1 \"absent\"]"

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
       "(var child (base .extend {^x 1})) " &
       "(eval (quote [fs x]) ^in child)",
       "[\"sandbox\" 1]"
    expect GeneError:
      discard runStr("(env ^capabilities [1])")

  test "eval policy limits execution by steps, time, and memory":
    ck "(eval (quote (+ 1 2)) ^in (env ^policy {^max_steps 20}))",
       "3"
    ck "(type EvalPolicy ^props {^max_steps Int " &
       "                         ^allow_ffi Bool? " &
       "                         ^allow_native_compile Bool?}) " &
       "(var p (EvalPolicy ^max_steps 20 " &
       "                   ^allow_ffi false " &
       "                   ^allow_native_compile false)) " &
       "(eval (quote (+ 1 2)) ^in (env ^policy p))",
       "3"
    ck "(try (eval (quote (while true nil)) " &
       "           ^in (env ^policy {^max_steps 20})) " &
       "catch Any $ex/message)",
       "\"eval max steps exceeded\""
    ck "(try (eval (quote (eval (quote (while true nil)) ^in (env))) " &
       "           ^in (env ^policy {^max_steps 40})) " &
       "catch Any $ex/message)",
       "\"eval max steps exceeded\""
    # A step budget is transitive across an ordinary call. The callee's bound
    # scope descends from its own lexical scope, so without this the first call
    # out of the evaluated form silently left the limit behind.
    ck "(fn spin [n : Int] (while true (set n (+ n 1))) n) " &
       "(try (eval (quote (spin 1)) ^in (env ^policy {^max_steps 200})) " &
       "catch Any $ex/message)",
       "\"eval max steps exceeded\""
    # A wall clock and a process-memory ceiling are the two limits a step count
    # cannot express: an allocating loop can exhaust memory in few steps, and a
    # step is not a unit of time. Both are sampled on the budgeted dispatch
    # path, so a runaway form is stopped rather than the process.
    ck "(try (eval (quote (while true nil)) " &
       "           ^in (env ^policy {^timeout_ms 50})) " &
       "catch Any $ex/message)",
       "\"eval timeout exceeded\""
    ck "(try (eval (quote (do (var xs ($thaw #[])) " &
       "                      (while true (xs .push ($str/join [\"x\"] \"\"))))) " &
       "           ^in (env ^policy {^max_memory_mb 1})) " &
       "catch Any $ex/message)",
       "\"eval memory limit exceeded\""
    ck "(eval (quote (+ 1 2)) " &
       "      ^in (env ^policy {^max_steps 200 ^timeout_ms 5000 " &
       "                        ^max_memory_mb 128}))",
       "3"
    expect GeneError:
      discard runStr("(env ^policy [1])")
    expect GeneError:
      discard runStr("(env ^policy {^max_steps \"bad\"})")
    expect GeneError:
      discard runStr("(env ^policy {^max_steps -1})")
    expect GeneError:
      discard runStr("(env ^policy {^max_memory_mb \"bad\"})")
    expect GeneError:
      discard runStr("(env ^policy {^max_memory_mb -1})")
    expect GeneError:
      discard runStr("(env ^policy {^timeout_ms \"bad\"})")
    expect GeneError:
      discard runStr("(env ^policy {^timeout_ms -1})")
    expect GeneError:
      discard runStr("(env ^policy {^allow_ffi true})")
    expect GeneError:
      discard runStr("(env ^policy {^allow_native_compile true})")
    expect GeneError:
      discard runStr("(env ^policy {^allow_ffi 1})")
    expect GeneError:
      discard runStr("(env ^policy {^max-step 20})")

  test "eval compile failures are typed CompileError values":
    ck "(try (eval (quote (var)) ^in (env)) " &
       "catch CompileError $ex/message)",
       "\"var requires a name or pattern\""

  test "Env annotations accept env values":
    ck "(fn run-it [e : Env] (eval (quote (+ 1 2)) ^in e)) (run-it (env))",
       "3"

  test "functions returned from eval retain their evaluation scope":
    ck "(var e (env ^bindings {^x 10})) " &
       "(var f (eval (quote (fn [] x)) ^in e)) (f)",
       "10"

  test "eval impls stay in the retained overlay":
    let scope = newGlobalScope()
    check run(compileSource(
      "(protocol P (message value [self] : Str)) " &
      "(type T ^props {}) " &
      "(var e (env ^bindings {^P P ^T T})) " &
      "(var f (eval " &
      "  (quote (do " &
      "    (impl P for T (message value [self] : Str \"local\")) " &
      "    (fn [] ((T) .P:value)))) " &
      "  ^in e)) " &
      "(f)"), scope).print() == "\"local\""
    # The function retains the eval scope and its impl. The sibling program
    # scope sees the same explicit P/T values but not the overlay registration.
    expect GeneError:
      discard run(compileSource("((T) .P:value)"), scope)

suite "vm — cells":
  test "cell values are opaque display values":
    ck "($cell 0)", "(cell)"

  test "cell get and set mutate the referenced value":
    ck "(var c ($cell 0)) [(c .get) (c .set 10) (c .get)]",
       "[0 10 10]"

  test "cell swap returns the old value":
    ck "(var c ($cell \"a\")) [(c .swap \"b\") (c .get)]",
       "[\"a\" \"b\"]"

  test "cell update applies a callable and stores the result":
    ck "(var c ($cell 1)) [(c .update (fn [x] (+ x 1))) (c .get)]",
       "[2 2]"

  test "cells compare by identity":
    ck "(var a ($cell 1)) (var b ($cell 1)) [(== a a) (== a b)]",
       "[true false]"

  test "Cell annotations accept cells only":
    ck "(fn read [c : Cell] (c .get)) (read ($cell 3))", "3"
    expect GeneError:
      discard runStr("(fn read [c : Cell] c) (read 3)")

  test "env eval can mutate explicitly passed cells":
    ck "(var c ($cell 0)) (var e (env ^bindings {^c c})) " &
       "(eval (quote (c .set 5)) ^in e) (c .get)",
       "5"

  test "cell operations require cells":
    expect GeneError: discard runStr("(1 .get)")
    expect GeneError: discard runStr("(($cell 1) .set)")

suite "vm — atomic cells":
  test "atomic cell values are opaque display values":
    ck "($atomic_cell 0)", "(atomic_cell)"

  test "atomic cell load, store, and swap mutate the referenced value":
    ck "(var a ($atomic_cell 0)) " &
       "[(a .load) (a .store 10) " &
       " (a .swap 20) (a .load)]",
       "[0 10 10 20]"

  test "atomic compare_exchange stores when the expected value matches":
    ck "(var a ($atomic_cell 2)) " &
       "[(a .compare_exchange 2 3) " &
       " (a .load) " &
       " (a .compare_exchange 2 4) " &
       " (a .load)]",
       "[true 3 false 3]"

  test "atomic cells compare by identity":
    ck "(var a ($atomic_cell 1)) (var b ($atomic_cell 1)) [(== a a) (== a b)]",
       "[true false]"

  test "AtomicCell annotations accept atomic cells only":
    ck "(fn read [a : AtomicCell] (a .load)) (read ($atomic_cell 3))",
       "3"
    expect GeneError:
      discard runStr("(fn read [a : AtomicCell] a) (read ($cell 3))")

  test "atomic cell operations require atomic cells":
    # `AtomicCell` is a type, so the receiver check is reached through a send.
    # `(AtomicCell/load 1)` no longer reaches the native at all — it is the
    # decision-4 "not a callable path" error — so asserting on it would stop
    # testing what this test is named for.
    expect GeneError: discard runStr("(1 .AtomicCell:load)")
    expect GeneError: discard runStr("(($atomic_cell 1) .store)")

suite "vm — channels":
  test "channel values are opaque display values":
    ck "($channel)", "(channel)"

  test "channels send and receive FIFO values":
    ck "(var ch ($channel ^capacity 2)) " &
       "(ch .send 1) " &
       "(ch .send 2) " &
       "[(ch .recv) (ch .recv)]",
       "[1 2]"

  test "try_send and try_recv are non-blocking":
    ck "(var ch ($channel ^capacity 1)) " &
       "[(ch .try_send 1) " &
       " (ch .try_send 2) " &
       " (ch .recv) " &
       " (match (ch .try_recv) " &
       "   (when TryRecv/empty true) " &
       "   (when (TryRecv/value _) false))]",
       "[true false 1 true]"

  test "try_recv distinguishes empty, Void, Nil, and ordinary payloads":
    ck "(var ch ($channel ^capacity 3)) " &
       "(var empty-result (ch .try_recv)) " &
       "(ch .send void) " &
       "(ch .send nil) " &
       "(ch .send 7) " &
       "[(match empty-result (when TryRecv/empty `empty)) " &
       " (match (ch .try_recv) (when (TryRecv/value v) v)) " &
       " (match (ch .try_recv) (when (TryRecv/value v) v)) " &
       " (match (ch .try_recv) (when (TryRecv/value v) v))]",
       "[empty void nil 7]"

  test "closed channels drain buffered values before ChannelClosed":
    ck "(var ch ($channel ^capacity 1)) " &
       "(ch .send 9) " &
       "(ch .close) " &
       "[(ch .recv) " &
       " (try (ch .recv) catch ChannelClosed $ex/message)]",
       "[9 \"channel is closed\"]"
    ck "(var ch ($channel)) " &
       "(ch .close) " &
       "(try (ch .send 1) catch ChannelClosed $ex/message)",
       "\"channel is closed\""

  test "typed channels check items on send":
    ck "(var ch : (Channel Int) ($channel)) " &
       "(try (ch .send \"bad\") catch TypeError $ex/where)",
       "\"Channel/send item\""
    ck "(var ch : (Channel Int) ($channel)) " &
       "(ch .send 7) " &
       "(ch .recv)",
       "7"
    ck "(var raw ($channel)) " &
       "(raw .send \"bad\") " &
       "(var ch : (Channel Int) raw) " &
       "(try (ch .recv) catch TypeError $ex/where)",
       "\"Channel/recv item\""

  test "channel sends require Send values":
    ck "(var ch ($channel)) " &
       "(ch .send #[1 #{^a 2}]) " &
       "(ch .recv)",
       "#[1 #{^a 2}]"
    ck "(var ch ($channel)) " &
       "(var captured #[1 #{^a 2}]) " &
       "(var f (fn [] captured)) " &
       "(ch .send f) " &
       "(var g (ch .recv)) " &
       "(g)",
       "#[1 #{^a 2}]"
    ck "(var ch ($channel)) " &
       "(var f (fn [x y = x] y)) " &
       "(ch .send f) " &
       "(var g (ch .recv)) " &
       "(g 7)",
       "7"
    ck "(var ch ($channel ^capacity 1)) " &
       "(var t (spawn 7)) " &
       "(ch .send t) " &
       "(await (ch .recv))",
       "7"
    ck "(var ch ($channel ^capacity 1)) " &
       "(var inner ($channel ^capacity 1)) " &
       "(inner .send 7) " &
       "(ch .send inner) " &
       "((ch .recv) .recv)",
       "7"
    ck "(var ch ($channel ^capacity 1)) " &
       "(var a ($atomic_cell 7)) " &
       "(ch .send a) " &
       "((ch .recv) .load)",
       "7"
    ck "(var ch ($channel)) " &
       "(try (ch .send [1]) catch TypeError $ex/expected)",
       "\"Send\""
    ck "(var ch ($channel)) " &
       "(try (ch .send #[($cell 1)]) catch TypeError $ex/where)",
       "\"Channel/send item\""
    ck "(var ch ($channel)) " &
       "(var captured ($cell 1)) " &
       "(var f (fn [] (captured .get))) " &
       "(try (ch .send f) catch TypeError $ex/expected)",
       "\"Send\""
    ck "(var ch ($channel)) " &
       "(var captured 1) " &
       "(var f (fn [] (set captured (+ captured 1)))) " &
       "(try (ch .send f) catch TypeError $ex/expected)",
       "\"Send\""
    ck "(type Msg ^props {^x Int} ^impl [Send]) " &
       "(impl Send for Msg) " &
       "(var ch ($channel)) " &
       "(ch .send (Msg ^x 7)) " &
       "(var msg (ch .recv)) " &
       "msg/x",
       "7"

  test "channel operations require channels":
    expect GeneError: discard runStr("($channel ^capacity 0)")
    expect GeneError: discard runStr("(1 .send 2)")
    expect GeneError: discard runStr("(1 .recv)")

suite "vm — cooperative scheduler":
  test "a task blocked on recv is woken by a sender task":
    # The consumer parks on an empty channel; the producer's send wakes it and the
    # whole task resumes — real cooperative suspension across the frame stack.
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var c (spawn (ch .recv))) " &
       "  (var p (spawn (ch .send 7))) " &
       "  (await c))", "7"
  test "a producer that fills the channel parks until the root drains it":
    # send on a full channel parks the producer fiber; each root recv frees space
    # and wakes it to push the next value.
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var p (spawn (do (ch .send 1) (ch .send 2) 99))) " &
       "  (var a (ch .recv)) (var b (ch .recv)) " &
       "  [a b (await p)])", "[1 2 99]"
  test "multiple producers blocked on a full channel are all drained":
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var p1 (spawn (ch .send 10))) " &
       "  (var p2 (spawn (ch .send 20))) " &
       "  (+ (ch .recv) (ch .recv)))", "30"
  test "suspension preserves a deep call chain across the channel block":
    # The recv happens inside a nested call; resuming restores the whole frame
    # stack, so the caller continues correctly after the value arrives.
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (fn get-one [c] (+ 1 (c .recv))) " &
       "  (var t (spawn (get-one ch))) " &
       "  (var p (spawn (ch .send 41))) " &
       "  (await t))", "42"
  test "suspension preserves match, for, and catch sub-bodies":
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var t (spawn (match 1 " &
       "                  (when 1 (ch .recv))))) " &
       "  (spawn (ch .send 7)) " &
       "  (await t))", "7"
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var out ($cell 0)) " &
       "  (var t (spawn (for x in [1] " &
       "                  (out .set (ch .recv))))) " &
       "  (spawn (ch .send 8)) " &
       "  (await t) " &
       "  (out .get))", "8"
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var t (spawn (try (fail (Error ^message \"x\")) " &
       "                  catch Any (ch .recv)))) " &
       "  (spawn (ch .send 9)) " &
       "  (await t))", "9"
  test "suspension preserves scope, supervisor, eval, and namespace sub-bodies":
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var t (spawn (scope (ch .recv)))) " &
       "  (spawn (ch .send 7)) " &
       "  (await t))", "7"
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var t (spawn (supervisor ^strategy stop " &
       "                  (ch .recv)))) " &
       "  (spawn (ch .send 8)) " &
       "  (await t))", "8"
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var e (env ^bindings {^ch ch})) " &
       "  (var t (spawn (eval (quote (ch .recv)) ^in e))) " &
       "  (spawn (ch .send 9)) " &
       "  (await t))", "9"
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var t (spawn (ns m (var x (ch .recv))))) " &
       "  (spawn (ch .send 10)) " &
       "  ((await t) .lookup (quote x)))", "10"
  test "await with no way to make progress is a deadlock error":
    expect GeneError:
      discard runStr("(scope (var ch ($channel ^capacity 1)) " &
                     "  (var c (spawn (ch .recv))) " &
                     "  (await c))")
  test "a task awaiting another parks until it settles":
    # `doubler` awaits `producer` while producer is still blocked on recv; it parks
    # on the task (does not busy-pump) and resumes once producer completes.
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var producer (spawn (do (ch .recv) 5))) " &
       "  (var doubler (spawn (* 2 (await producer)))) " &
       "  (ch .send 1) " &
       "  (await doubler))", "10"
  test "a chain of awaiting tasks resolves in order":
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var a (spawn (do (ch .recv) 1))) " &
       "  (var b (spawn (+ 10 (await a)))) " &
       "  (var c (spawn (+ 100 (await b)))) " &
       "  (ch .send 0) " &
       "  (await c))", "111"

  test "spawn queues child work instead of running inline":
    ck "(scope (var out ($cell 0)) " &
       "  (var t (spawn (out .set 1))) " &
       "  [(out .get) (await t) (out .get)])",
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
    ck "(scope (var c ($cell 0)) " &
       "  (var t (spawn (c .get))) " &
       "  (c .set 2) " &
       "  (await t))",
       "2"
    ck "(scope (var c ($cell 7)) (var t (spawn c)) " &
       "  (same? (await t) c))",
       "true"

  test "applications keep scheduler queues isolated":
    withoutGeneWorkers:
      let app1 = newApplication()
      let scope1 = newGlobalScope(app1)
      let ch = run(compileSource("($channel ^capacity 1)"), scope1)
      scope1.define("ch", ch)
      let pending = run(compileSource("(spawn (ch .send 1))"), scope1)
      check pending.kind == vkTask
      check not pending.taskDone
      check ch.channelLen == 0

      let app2 = newApplication()
      let scope2 = newGlobalScope(app2)
      expect GeneError:
        discard run(compileSource(
          "(var ch ($channel ^capacity 1)) (ch .recv)"), scope2)

      check ch.channelLen == 0
      check not pending.taskDone
      scope1.define("pending", pending)
      check run(compileSource("(await pending)"), scope1).kind == vkNil
      check pending.taskDone
      check ch.channelLen == 1

  test "CPU-bound fibers yield at scheduler safepoints":
    ck "(scope (var out ($cell 0)) " &
       "  (var slow (spawn (do " &
       "    (var i 0) " &
       "    (while (< i 5000) (set i (+ i 1))) " &
       "    (out .set 1)))) " &
       "  (var fast (spawn (out .set 2))) " &
       "  (await fast) " &
       "  [(out .get) (await slow) (out .get)])",
       "[2 1 1]"

  test "sleep parks only the current task":
    ck "(scope (var out ($cell 0)) " &
       "  (var slow (spawn (do ($sleep 5) (out .set 1)))) " &
       "  (var fast (spawn (out .set 2))) " &
       "  (await fast) " &
       "  [(out .get) (await slow) (out .get)])",
       "[2 1 1]"

  test "sleep zero yields one scheduler turn":
    ck "(var out ($cell 0)) " &
       "(spawn (out .set 1)) " &
       "[(out .get) ($sleep 0) (out .get)]",
       "[0 nil 1]"

  test "$fs/read_bytes is the read half fs/write_bytes was missing":
    # The bytes here are the point: 0x80 and 0xFF are not valid UTF-8 on their
    # own, so `read_text` would mangle them. A binary format needs the pair
    # (design.md §D7.3), and until now only the write half existed.
    let path = getTempDir() / "gene-read-bytes-test.bin"
    defer:
      if fileExists(path):
        removeFile(path)
    let app = newApplication()
    app.setRootCapabilities(newCapabilityContext([
      app.filesystemCapabilities.grantReadWriteDir(getTempDir())
    ]))
    let scope = newGlobalScope(app)
    scope.define("path", newStr(path))
    check run(compileSource(
        "(var payload ($binary/from_list [0 127 128 255 10])) " &
        "($fs/write_bytes path payload) " &
        "(== ($binary/to_list ($fs/read_bytes path)) " &
        "    ($binary/to_list payload))"),
      scope).print() == "true"
    # Reading needs active read authority, not merely some filesystem grant.
    let writeOnly = newApplication()
    writeOnly.setRootCapabilities(newCapabilityContext([
      writeOnly.filesystemCapabilities.grantWriteDir(getTempDir())
    ]))
    let writeOnlyScope = newGlobalScope(writeOnly)
    writeOnlyScope.define("path", newStr(path))
    expect GeneError:
      discard run(compileSource("($fs/read_bytes path)"), writeOnlyScope)

  test "$fs/read_text_async returns an awaitable task":
    let path = getTempDir() / "gene-read-text-async-test.txt"
    writeFile(path, "hello async")
    defer:
      if fileExists(path):
        removeFile(path)
    let app = newApplication()
    app.setRootCapabilities(newCapabilityContext([
      app.filesystemCapabilities.grantReadDir(getTempDir())
    ]))
    let scope = newGlobalScope(app)
    scope.define("path", newStr(path))
    check run(compileSource("(await ($fs/read_text_async path))"),
              scope).print() == "\"hello async\""
    let deniedApp = newApplication()
    deniedApp.setRootCapabilities(newCapabilityContext([
      deniedApp.filesystemCapabilities.grantWriteDir(getTempDir())
    ]))
    let deniedScope = newGlobalScope(deniedApp)
    deniedScope.define("path", newStr(path))
    expect GeneError:
      discard run(compileSource("(await ($fs/read_text_async path))"), deniedScope)

  test "$fs/write_text_async returns an awaitable task":
    let path = getTempDir() / "gene-write-text-async-test.txt"
    defer:
      if fileExists(path):
        removeFile(path)
    let app = newApplication()
    app.setRootCapabilities(newCapabilityContext([
      app.filesystemCapabilities.grantWriteDir(getTempDir())
    ]))
    let scope = newGlobalScope(app)
    scope.define("path", newStr(path))
    check run(compileSource(
      "(await ($fs/write_text_async path \"written async\"))"),
      scope).kind == vkNil
    check readFile(path) == "written async"
    let deniedApp = newApplication()
    deniedApp.setRootCapabilities(newCapabilityContext([
      deniedApp.filesystemCapabilities.grantReadDir(getTempDir())
    ]))
    let deniedScope = newGlobalScope(deniedApp)
    deniedScope.define("path", newStr(path))
    expect GeneError:
      discard run(compileSource(
        "(await ($fs/write_text_async path \"nope\"))"), deniedScope)

  test "net TCP async operations require connect authority":
    let app = newApplication()
    app.setRootCapabilities(newCapabilityContext())
    let scope = newGlobalScope(app)
    expect GeneError:
      discard run(compileSource(
        "($net/tcp_read_text_async \"127.0.0.1\" 1 1 1)"), scope)
    expect GeneError:
      discard run(compileSource(
        "($net/tcp_write_text_async \"127.0.0.1\" 1 \"x\" 1)"), scope)

  test "root channel waits can be unblocked by sleeping tasks":
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (spawn (do ($sleep 5) (ch .send 7))) " &
       "  (ch .recv))", "7"
  test "closing a channel wakes parked receivers and senders":
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var t (spawn (try (ch .recv) " &
       "                  catch ChannelClosed $ex/message))) " &
       "  (spawn (ch .close)) " &
       "  (await t))",
       "\"channel is closed\""
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (ch .send 1) " &
       "  (var t (spawn (try (ch .send 2) " &
       "                  catch ChannelClosed $ex/message))) " &
       "  (spawn (ch .close)) " &
       "  (await t))",
       "\"channel is closed\""
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var a (spawn (try (ch .recv) " &
       "                  catch ChannelClosed $ex/message))) " &
       "  (var b (spawn (try (ch .recv) " &
       "                  catch ChannelClosed $ex/message))) " &
       "  (spawn (ch .close)) " &
       "  [(await a) (await b)])",
       "[\"channel is closed\" \"channel is closed\"]"
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (ch .send 1) " &
       "  (var a (spawn (try (ch .send 2) " &
       "                  catch ChannelClosed $ex/message))) " &
       "  (var b (spawn (try (ch .send 3) " &
       "                  catch ChannelClosed $ex/message))) " &
       "  (spawn (ch .close)) " &
       "  [(await a) (await b)])",
       "[\"channel is closed\" \"channel is closed\"]"
  test "cancelling a pending task makes await observe cancellation":
    expect GeneCancel:
      discard runStr("(scope (var ch ($channel ^capacity 1)) " &
                     "  (var t (spawn (ch .recv))) " &
                     "  (t .cancel) " &
                     "  (await t))")
  test "cancelling a sleeping task wakes it for cleanup":
    expect GeneCancel:
      discard runStr("(scope " &
                     "  (var t (spawn ($sleep 1000))) " &
                     "  (t .cancel) " &
                     "  (await t))")
  test "cancelling a task wakes fibers awaiting it":
    expect GeneCancel:
      discard runStr("(scope (var ch ($channel ^capacity 1)) " &
                     "  (var t (spawn (ch .recv))) " &
                     "  (var w (spawn (await t))) " &
                     "  (t .cancel) " &
                     "  (await w))")
  test "cancelled task fibers do not resume when their blocker clears":
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var out ($cell 0)) " &
       "  (var t (spawn (do (ch .recv) (out .set 1)))) " &
       "  (t .cancel) " &
       "  (ch .send 99) " &
       "  (out .get))", "0"
  test "task scope normal exit waits for live child tasks":
    ck "(var out ($cell 0)) " &
       "(scope (var ch ($channel ^capacity 1)) " &
       "  (spawn (do (ch .recv) (out .set 7))) " &
       "  (spawn (ch .send 1)) " &
       "  nil) " &
       "(out .get)", "7"
  test "task scope normal exit reports deadlocked child tasks":
    expect GeneError:
      discard runStr("(scope (var ch ($channel ^capacity 1)) " &
                     "  (spawn (ch .recv)) " &
                     "  nil)")
    ck "(var ch ($channel ^capacity 1)) " &
       "(var out ($cell 0)) " &
       "(try (scope " &
       "       (spawn (do (ch .recv) (out .set 1))) " &
       "       nil) " &
       "  catch Any $ex/message) " &
       "(ch .send 1) " &
       "($sleep 1) " &
       "(out .get)", "0"
  test "task scope error exit cancels pending child tasks":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var ch ($channel ^capacity 1)) " &
       "(var out ($cell 0)) " &
       "(try " &
       "  (scope " &
       "    (spawn (do (ch .recv) (out .set 1))) " &
       "    (fail (Boom ^message \"stop\"))) " &
       "  catch Boom nil) " &
       "(ch .send 1) " &
       "(scope nil) " &
       "(out .get)", "0"
  test "task scope error exit waits for child cancellation cleanup":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var ch ($channel ^capacity 1)) " &
       "(var out ($cell 0)) " &
       "(try " &
       "  (scope " &
       "    (spawn (try (ch .recv) " &
       "                ensure (out .set 9))) " &
       "    ($sleep 1) " &
       "    (fail (Boom ^message \"stop\"))) " &
       "  catch Boom nil) " &
       "(out .get)", "9"

  test "task cancellation cleanup can suspend before await observes cancellation":
    let scope = newGlobalScope()
    expect GeneCancel:
      discard run(compileSource("(var out ($cell 0)) " &
                                "(scope (var ch ($channel ^capacity 1)) " &
                                "  (var t (spawn " &
                                "    (try (ch .recv) " &
                                "         ensure " &
                                "           (do ($sleep 1) " &
                                "               (out .set 9))))) " &
                                "  ($sleep 1) " &
                                "  (t .cancel) " &
                                "  (await t))"),
                  scope)
    check scope.lookup("out").cellValue.intVal == 9

  test "detached tasks are not awaited on normal scope exit":
    ck "(var out ($cell 0)) " &
       "(scope " &
       "  (var t (spawn (do ($sleep 5) (out .set 1)))) " &
       "  (t .detach) " &
       "  nil) " &
       "[(out .get) ($sleep 10) (out .get)]",
       "[0 nil 1]"

  test "detached tasks are not cancelled on scope error exit":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var out ($cell 0)) " &
       "(try " &
       "  (scope " &
       "    (var t (spawn (do ($sleep 5) (out .set 9)))) " &
       "    (t .detach) " &
       "    (fail (Boom ^message \"stop\"))) " &
       "  catch Boom nil) " &
       "[(out .get) ($sleep 10) (out .get)]",
       "[0 nil 9]"

  test "an actor handler can suspend on a channel mid-message":
    # The handler recvs from a channel while processing a message: its fiber parks,
    # the scheduler runs a producer task to feed the channel, and the handler
    # resumes and finishes the message. Proves actor handlers run as fibers.
    ck "(var out ($cell 0)) " &
       "(var ch ($channel ^capacity 1)) " &
       "(fn handle [ctx state msg] " &
       "  (var got (ch .recv)) " &
       "  (out .set (+ msg got)) " &
       "  ($actor/continue state)) " &
       "(var a ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(var p (spawn (ch .send 100))) " &
       "(a .send 5) " &
       "(out .get)", "105"
  test "an actor handler can suspend on a timer mid-message":
    ck "(var out ($cell 0)) " &
       "(fn handle [ctx state msg] " &
       "  ($sleep 5) " &
       "  (out .set msg) " &
       "  ($actor/continue state)) " &
       "(var a ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(a .send 42) " &
       "(out .get)", "42"
  test "actor ask returns a pending task instead of driving synchronously":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(var ch ($channel ^capacity 1)) " &
       "(fn handle [ctx state msg] " &
       "  (var got (ch .recv)) " &
       "  (match msg " &
       "    (when (Get ^reply reply) " &
       "      (reply .send (+ state got)) " &
       "      ($actor/continue state)))) " &
       "(var a ($actor/spawn ^init (fn [] 40) ^handle handle)) " &
       "(var pending (a .ask (fn [reply] (Get ^reply reply)))) " &
       "(ch .send 2) " &
       "(await pending)", "42"
  test "actor ask awaited inside a fiber parks until the reply is sent":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(scope " &
       "  (var a ($actor/spawn ^init (fn [] 41) " &
       "    ^handle (fn [ctx state msg] " &
       "      (match msg " &
       "        (when (Get ^reply reply) " &
       "          (reply .send state) " &
       "          ($actor/continue state)))))) " &
       "  (var t (spawn (await (a .ask (fn [reply] (Get ^reply reply)))))) " &
       "  (await t))", "41"

  test "actor ask timeout fails pending request and ignores late reply":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(var ch ($channel ^capacity 1)) " &
       "(var out ($cell 0)) " &
       "(fn handle [ctx state msg] " &
       "  (var (Get ^reply reply) msg) " &
       "  (var got (ch .recv)) " &
       "  (reply .send got) " &
       "  (out .set got) " &
       "  ($actor/continue state)) " &
       "(var a ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(var pending (a .ask ^timeout_ms 5 (fn [reply] (Get ^reply reply)))) " &
       "(var err (try (await pending) catch ActorError $ex/message)) " &
       "(ch .send 7) " &
       "[err ($sleep 1) (out .get)]",
       "[\"actor/ask timed out\" nil 7]"
    ck "(scope " &
       "  (type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(var saved ($cell nil)) " &
       "(var ch ($channel ^capacity 1)) " &
       "(fn handle [ctx state msg] " &
       "  (var (Get ^reply reply) msg) " &
       "  (var got (ch .recv)) " &
       "  (try (reply .send got) catch Any $ex/message) " &
       "  ($actor/continue state)) " &
       "(var a ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(var pending (a .ask ^timeout_ms 5 " &
       "  (fn [reply] (saved .set reply) (Get ^reply reply)))) " &
       "(var err (try (await pending) catch ActorError $ex/message)) " &
       "(var first-late (try ((saved .get) .send 9) " &
       "                  catch Any $ex/message)) " &
       "(var second-late (try ((saved .get) .send 10) " &
       "                   catch Any $ex/message)) " &
       "[err first-late second-late])",
       "[\"actor/ask timed out\" nil \"reply has already been sent\"]"

  test "a cancelled actor ask task is not completed by a late reply":
    expect GeneCancel:
      discard runStr("(type Get ^props {^reply (ReplyTo Int)}) " &
                     "(impl Send for Get) " &
                     "(type Tick ^impl [Send]) " &
                     "(impl Send for Tick) " &
                     "(var ch ($channel ^capacity 1)) " &
                     "(fn handle [ctx state msg] " &
                     "  (match msg " &
                     "    (when (Get ^reply reply) " &
                     "      (var got (ch .recv)) " &
                     "      (reply .send got) " &
                     "      ($actor/continue state)) " &
                     "    (when (Tick) ($actor/continue state)))) " &
                     "(var a ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
                     "(var pending (a .ask (fn [reply] (Get ^reply reply)))) " &
                     "(pending .cancel) " &
                     "(ch .send 7) " &
                     "(a .send (Tick)) " &
                     "(await pending)")
    ck "(scope " &
       "  (type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(var saved ($cell nil)) " &
       "(var ch ($channel ^capacity 1)) " &
       "(fn handle [ctx state msg] " &
       "  (var (Get ^reply reply) msg) " &
       "  (var got (ch .recv)) " &
       "  (try (reply .send got) catch Any $ex/message) " &
       "  ($actor/continue state)) " &
       "(var a ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(var pending (a .ask " &
       "  (fn [reply] (saved .set reply) (Get ^reply reply)))) " &
       "(pending .cancel) " &
       "(var first-late (try ((saved .get) .send 9) " &
       "                  catch Any $ex/message)) " &
       "(var second-late (try ((saved .get) .send 10) " &
       "                   catch Any $ex/message)) " &
       "[first-late second-late])",
       "[nil \"reply has already been sent\"]"

  test "closing an owned actor cancels a scheduled ask reply":
    expect GeneCancel:
      discard runStr("(type Get ^props {^reply (ReplyTo Int)}) " &
                     "(impl Send for Get) " &
                     "(var pending nil) " &
                     "(scope " &
                     "  (var a ($actor/spawn ^init (fn [] 41) " &
                     "    ^handle (fn [ctx state msg] " &
                     "      (match msg " &
                     "        (when (Get ^reply reply) " &
                     "          (reply .send state) " &
                     "          ($actor/continue state)))))) " &
                     "  (set pending (a .ask " &
                     "    (fn [reply] (Get ^reply reply)))) " &
                     "  nil) " &
                     "(await pending)")

  test "closing an owned actor removes blocked handler fibers":
    ck "(var out ($cell 0)) " &
       "(var ch ($channel ^capacity 1)) " &
       "(scope " &
       "  (var a ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (var got (ch .recv)) " &
       "      (out .set got) " &
       "      ($actor/continue state)))) " &
       "  (a .send 1) " &
       "  nil) " &
       "(ch .send 7) " &
       "(var gate ($channel ^capacity 1)) " &
       "(var t (spawn (gate .recv))) " &
       "(gate .send 1) " &
       "(await t) " &
       "(out .get)", "0"

  test "try_send in a fiber wakes a peer parked in recv":
    # Regression: biChannelTrySend was missing wakeChannelWaiters.
    # The receiver fiber runs first (schedRunQueue ordering), parks on the empty
    # channel, and the try_send fiber runs second. Without the fix, the receiver
    # stays in schedWaiters after try_send and the await deadlocks.
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (var t (spawn (ch .recv))) " &
       "  (spawn (ch .try_send 42)) " &
       "  (await t))", "42"

  test "try_recv in a fiber wakes a peer parked in send":
    # Regression: biChannelTryRecv was missing wakeChannelWaiters.
    # Fill the channel at root, spawn a sender (parks when it runs), then spawn a
    # try_recv (runs second, pops the item). Without the fix, the parked sender
    # stays in schedWaiters after try_recv and the await deadlocks.
    ck "(scope (var ch ($channel ^capacity 1)) " &
       "  (ch .send 1) " &
       "  (var t (spawn (ch .send 2))) " &
       "  (spawn (ch .try_recv)) " &
       "  (await t) " &
       "  (ch .recv))", "2"

suite "vm — actors":
  test "actor values are opaque display values":
    ck "($actor/spawn ^init (fn [] 0) " &
       "             ^handle (fn [ctx state msg] ($actor/continue state)))",
       "(actor)"

  test "actor send processes messages sequentially":
    ck "(var out ($cell 0)) " &
       "(fn handle [ctx state msg] : (ActorStep Int) " &
       "  (var next (+ state msg)) " &
       "  (out .set next) " &
       "  ($actor/continue next)) " &
       "(var counter : (ActorRef Int) " &
       "  ($actor/spawn ^init (fn [] 0) ^handle handle)) " &
       "(counter .send 2) " &
       "(counter .send 5) " &
       "(out .get)",
       "7"

  test "actor try_send returns before running the handler":
    ck "(var gate ($channel ^capacity 1)) " &
       "(var seen ($cell 0)) " &
       "(var a ($actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg] " &
       "    (gate .recv) " &
       "    (seen .set msg) " &
       "    ($actor/continue msg)))) " &
       "(var before [(a .try_send 7) (seen .get)]) " &
       "(gate .send 1) " &
       "($sleep 0) " &
       "before",
       "[true 0]"
    ck "(var gate ($channel ^capacity 1)) " &
       "(var seen ($cell 0)) " &
       "(var a ($actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg] " &
       "    (gate .recv) " &
       "    (seen .set msg) " &
       "    ($actor/continue msg)))) " &
       "(a .try_send 7) " &
       "(gate .send 1) " &
       "($sleep 0) " &
       "(seen .get)",
       "7"

  test "actor stop closes the actor":
    ck "(var a : (ActorRef Int) " &
       "  ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] ($actor/stop)))) " &
       "(a .send 1) " &
       "(try (a .send 2) catch ActorClosed $ex/message)",
       "\"actor is closed\""
    ck "(var a : (ActorRef Int) " &
       "  ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] ($actor/stop)))) " &
       "(a .send 1) " &
       "(a .try_send 2)",
       "false"

  test "actor sends check message type and Send":
    ck "(var a : (ActorRef Int) " &
       "  ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] ($actor/continue state)))) " &
       "(try (a .send \"bad\") catch TypeError $ex/where)",
       "\"actor/send message\""
    ck "(var a ($actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg] ($actor/continue state)))) " &
       "(try (a .send [1]) catch TypeError $ex/expected)",
       "\"Send\""

  test "actor message type is explicit inferred or Any":
    ck "(type Msg ^props {^n Int}) (impl Send for Msg) " &
       "(var a ($actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg : Msg] ($actor/continue state)))) " &
       "(fn use [x : (ActorRef Msg)] true) (use a)",
       "true"
    ck "(type Msg ^props {^n Int}) (impl Send for Msg) " &
       "(var a ($actor/spawn ^type Msg ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg : Int] ($actor/continue state)))) " &
       "(fn use [x : (ActorRef Msg)] true) (use a)",
       "true"
    ck "(var a ($actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg] ($actor/continue state)))) " &
       "(fn use [x : (ActorRef Any)] true) (use a)",
       "true"
    expect GeneError:
      discard runStr("(var a : (ActorRef Int) " &
        "($actor/spawn ^type Any ^init (fn [] 0) " &
        "  ^handle (fn [ctx state msg] ($actor/continue state))))")

  test "actor refs are Send values":
    ck "(var a ($actor/spawn ^init (fn [] 0) " &
       "  ^handle (fn [ctx state msg] ($actor/continue state)))) " &
       "(var ch ($channel)) " &
       "(ch .send a) " &
       "(ch .recv)",
       "(actor)"

  test "actor ask returns a task with a one-shot reply":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(fn handle [ctx state msg] : (ActorStep Int) " &
       "  (match msg " &
       "    (when (Get ^reply reply) " &
       "      (reply .send state) " &
       "      ($actor/continue state)))) " &
       "(var a : (ActorRef Get) " &
       "  ($actor/spawn ^init (fn [] 41) ^handle handle)) " &
       "(await (a .ask (fn [reply] (Get ^reply reply))))",
       "41"
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(scope " &
       "  (var a : (ActorRef Get) " &
       "    ($actor/spawn ^init (fn [] 41) " &
       "      ^handle (fn [ctx state msg] " &
       "        (match msg " &
       "          (when (Get ^reply reply) " &
       "            (reply .send state) " &
       "            ($actor/continue state)))))) " &
       "  (fn (choose result err) [t : (Task result err) fallback : result] " &
       "    fallback) " &
       "  (try (choose (a .ask (fn [reply] (Get ^reply reply))) \"bad\") " &
       "       catch TypeError $ex/expected))",
       "\"Int\""

  test "actor ask enforces ReplyTo result type and reports missing replies":
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(var a : (ActorRef Get) " &
       "  ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (match msg " &
       "        (when (Get ^reply reply) " &
       "          (reply .send \"bad\") " &
       "          ($actor/continue state)))))) " &
       "(try (await (a .ask (fn [reply] (Get ^reply reply)))) " &
       "catch TypeError $ex/where)",
       "\"ReplyTo/send value\""
    ck "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(var a : (ActorRef Get) " &
       "  ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] ($actor/continue state)))) " &
       "(try (await (a .ask (fn [reply] (Get ^reply reply)))) " &
       "catch ActorError $ex/message)",
       "\"actor/ask did not receive a reply\""

  test "task scopes close owned actors on exit":
    ck "(var a (scope " &
       "  ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] ($actor/continue state))))) " &
       "(a .try_send 1)",
       "false"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var a nil) " &
       "(try " &
       "  (scope " &
       "    (set a ($actor/spawn ^init (fn [] 0) " &
       "      ^handle (fn [ctx state msg] ($actor/continue state)))) " &
       "    (fail (Boom ^message \"x\"))) " &
       "catch Boom $ex/message) " &
       "(a .try_send 1)",
       "false"

  test "supervisors own actors and apply failure strategies":
    ck "(var a (supervisor ^strategy stop " &
       "  ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] ($actor/continue state))))) " &
       "(a .try_send 1)",
       "false"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var seen ($cell 0)) " &
       "(supervisor ^strategy restart " &
       "  (var a ($actor/spawn ^init (fn [] 10) " &
       "    ^handle (fn [ctx state msg] " &
       "      (if (== msg 1) " &
       "        (fail (Boom ^message \"bad\")) " &
       "        (do " &
       "          (seen .set state) " &
       "          ($actor/continue (+ state msg))))))) " &
       "  (a .send 1) " &
       "  (a .send 5) " &
       "  (seen .get))",
       "10"

  test "supervisor failure retries are bounded FIFO with observable drops":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var events ($channel ^capacity 1)) " &
       "(supervisor ^strategy restart ^events events " &
       "  (var i 0) (var a nil) " &
       "  (while (< i 66) " &
       "    (set a ($actor/spawn ^init (fn [] 0) " &
       "      ^handle (fn [ctx state msg] " &
       "        (fail (Boom ^message \"bad\"))))) " &
       "    (spawn (a .send i)) " &
       "    (set i (+ i 1))) " &
       "  ($sleep 20) " &
       "  (var stats ($runtime/gc_stats)) " &
       "  (var first (events .recv)) " &
       "  (var second (events .recv)) " &
       "  (var drained 0) " &
       "  (while (< drained 62) " &
       "    (events .recv) " &
       "    (set drained (+ drained 1))) " &
       "  [stats/supervisor_retry_pending " &
       "   stats/supervisor_retry_capacity " &
       "   stats/supervisor_retry_high_water " &
       "   stats/supervisor_retry_drops " &
       "   first/failed_message second/failed_message])",
       "[64 64 64 1 0 1]"

  test "supervisor failure delivery uses event and dead_letter channels":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var events ($channel ^capacity 4)) " &
       "(var seen ($cell 0)) " &
       "(supervisor ^strategy restart ^events events " &
       "  (var a ($actor/spawn ^mailbox 4 ^init (fn [] 10) " &
       "    ^handle (fn [ctx state msg] " &
       "      (if (== msg 1) " &
       "        (fail (Boom ^message \"bad\")) " &
       "        (do " &
       "          (seen .set state) " &
       "          ($actor/continue (+ state msg))))))) " &
       "  (spawn (a .send 1)) " &
       "  (spawn (a .send 5)) " &
       "  ($sleep 1) " &
       "  (var event (events .recv)) " &
       "  (var tries 0) " &
       "  (while (< tries 100) " &
       "    (if (== (seen .get) 0) " &
       "      (do ($sleep 1) (set tries (+ tries 1))) " &
       "      (set tries 100))) " &
       "  [(seen .get) " &
       "   (match event " &
       "     (when (ActorFailure ^failed_message failed " &
       "                         ^error (Boom ^message m) " &
       "                         ^panic p ^strategy s) " &
       "       [failed m p s]))])",
       "[10 [1 \"bad\" false restart]]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var events ($channel ^capacity 1)) " &
       "(var dead ($channel ^capacity 2)) " &
       "(events .send \"busy\") " &
       "(supervisor ^strategy restart ^events events ^dead_letter dead " &
       "  (var a ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (fail (Boom ^message \"bad\"))))) " &
       "  (a .send 1) " &
       "  ($sleep 1) " &
       "  (var event (dead .recv)) " &
       "  (var busy (events .recv)) " &
       "  [busy " &
       "   (match event " &
       "     (when (ActorFailure ^failed_message failed " &
       "                         ^error (Boom ^message m) " &
       "                         ^strategy s) " &
       "       [failed m s]))])",
       "[\"busy\" [1 \"bad\" restart]]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var events ($channel ^capacity 1)) " &
       "(var dead ($channel ^capacity 1)) " &
       "(events .send \"busy\") " &
       "(dead .send \"dead-busy\") " &
       "(supervisor ^strategy restart ^events events ^dead_letter dead " &
       "  (var a ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (fail (Boom ^message \"bad\"))))) " &
       "  (a .send 4) " &
       "  ($sleep 1) " &
       "  (var dead-busy (dead .recv)) " &
       "  (var event (dead .recv)) " &
       "  (var busy (events .recv)) " &
       "  [busy dead-busy " &
       "   (match event " &
       "     (when (ActorFailure ^failed_message failed " &
       "                         ^error (Boom ^message m) " &
       "                         ^strategy s) " &
       "       [failed m s]))])",
       "[\"busy\" \"dead-busy\" [4 \"bad\" restart]]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var events ($channel ^capacity 1)) " &
       "(events .send \"busy\") " &
       "(supervisor ^strategy restart ^events events " &
       "  (var a ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (fail (Boom ^message \"bad\"))))) " &
       "  (a .send 3) " &
       "  (var busy (events .recv)) " &
       "  (var event (events .recv)) " &
       "  [busy " &
       "   (match event " &
       "     (when (ActorFailure ^failed_message failed " &
       "                         ^error (Boom ^message m) " &
       "                         ^strategy s) " &
       "       [failed m s]))])",
       "[\"busy\" [3 \"bad\" restart]]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var events ($channel ^capacity 1)) " &
       "(var dead ($channel ^capacity 1)) " &
       "(events .close) " &
       "(supervisor ^strategy restart ^events events ^dead_letter dead " &
       "  (var a ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (fail (Boom ^message \"bad\"))))) " &
       "  (a .send 2) " &
       "  ($sleep 1) " &
       "  (var event (dead .recv)) " &
       "  (match event " &
       "    (when (ActorFailure ^failed_message failed " &
       "                        ^error (Boom ^message m) " &
       "                        ^strategy s) " &
       "      [failed m s])))",
       "[2 \"bad\" restart]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var events : (Channel Int) ($channel ^capacity 1)) " &
       "(var dead ($channel ^capacity 1)) " &
       "(supervisor ^strategy restart ^events events ^dead_letter dead " &
       "  (var a ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] " &
       "      (fail (Boom ^message \"bad\"))))) " &
       "  (a .send 6) " &
       "  ($sleep 1) " &
       "  (var event (dead .recv)) " &
       "  (match event " &
       "    (when (ActorFailure ^failed_message failed " &
       "                        ^error (Boom ^message m) " &
       "                        ^strategy s) " &
       "      [failed m s])))",
       "[6 \"bad\" restart]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var events ($channel ^capacity 1)) " &
       "(var dead ($channel ^capacity 1)) " &
       "(events .close) " &
       "(dead .close) " &
       "(var seen ($cell 0)) " &
       "(supervisor ^strategy restart ^events events ^dead_letter dead " &
       "  (var a ($actor/spawn ^mailbox 4 ^init (fn [] 10) " &
       "    ^handle (fn [ctx state msg] " &
       "      (if (== msg 1) " &
       "        (fail (Boom ^message \"bad\")) " &
       "        (do " &
       "          (seen .set state) " &
       "          ($actor/continue (+ state msg))))))) " &
       "  (a .send 1) " &
       "  (a .send 5) " &
       "  ($sleep 1) " &
       "  (seen .get))",
       "10"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var a nil) " &
       "[(try " &
       "   (supervisor ^strategy escalate " &
       "     (set a ($actor/spawn ^init (fn [] 0) " &
       "       ^handle (fn [ctx state msg] " &
       "         (fail (Boom ^message \"bad\"))))) " &
       "     (a .send 1)) " &
       "   catch Boom $ex/message) " &
       " (a .try_send 2)]",
       "[\"bad\" false]"
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(type Get ^props {^reply (ReplyTo Int)}) " &
       "(impl Send for Get) " &
       "(try " &
       "  (supervisor ^strategy escalate " &
       "    (var a ($actor/spawn ^init (fn [] 0) " &
       "      ^handle (fn [ctx state msg] " &
       "        (fail (Boom ^message \"bad\"))))) " &
       "    (var pending (a .ask (fn [reply] (Get ^reply reply)))) " &
       "    ($sleep 1) " &
       "    \"after\") " &
       "  catch Boom $ex/message)",
       "\"bad\""
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var parent-events ($channel ^capacity 2)) " &
       "(var outcome " &
       "  (try " &
       "    (supervisor ^strategy stop ^events parent-events " &
       "      (supervisor ^strategy escalate " &
       "        (var a ($actor/spawn ^init (fn [] 0) " &
       "          ^handle (fn [ctx state msg] " &
       "            (fail (Boom ^message \"bad\"))))) " &
       "        (a .send 7))) " &
       "    catch Boom $ex/message)) " &
       "(var event (parent-events .recv)) " &
       "[outcome " &
       " (match event " &
       "   (when (ActorFailure ^failed_message failed " &
       "                       ^error (Boom ^message m) " &
       "                       ^strategy s) " &
       "     [failed m s]))]",
       "[\"bad\" [7 \"bad\" escalate]]"
    expect GenePanic:
      discard runStr("(type Get ^props {^reply (ReplyTo Int)}) " &
                     "(impl Send for Get) " &
                     "(supervisor ^strategy stop " &
                     "  (var a ($actor/spawn ^init (fn [] 0) " &
                     "    ^handle (fn [ctx state msg] " &
                     "      (panic \"halt\")))) " &
                     "  (var pending (a .ask (fn [reply] (Get ^reply reply)))) " &
                     "  ($sleep 1) " &
                     "  \"after\")")
    expect GeneCancel:
      discard runStr("(type Boom ^props {^message Str} ^impl [Error]) " &
                     "(impl Error for Boom) " &
                     "(type Get ^props {^reply (ReplyTo Int)}) " &
                     "(impl Send for Get) " &
                     "(supervisor ^strategy stop " &
                     "  (var a ($actor/spawn ^mailbox 4 ^init (fn [] 0) " &
                     "    ^handle (fn [ctx state msg] " &
                     "      (fail (Boom ^message \"bad\"))))) " &
                     "  (var first (a .ask (fn [reply] (Get ^reply reply)))) " &
                     "  (var second (a .ask (fn [reply] (Get ^reply reply)))) " &
                     "  ($sleep 1) " &
                     "  (await second))")
    expect GeneError:
      discard runStr("(supervisor nil)")
    expect GeneError:
      discard runStr("(supervisor ^strategy unknown nil)")
    expect GeneError:
      discard runStr("(supervisor ^strategy stop ^events 1 nil)")
    expect GeneError:
      discard runStr("(supervisor ^strategy stop ^dead_letter 1 nil)")

  test "actor handler must return an ActorStep":
    ck "(var a : (ActorRef Int) " &
       "  ($actor/spawn ^init (fn [] 0) " &
       "    ^handle (fn [ctx state msg] 99))) " &
       "(try (a .send 1) catch TypeError $ex/where)",
       "\"actor handler return\""

  test "actor operations require actors":
    expect GeneError:
      discard runStr("($actor/spawn ^handle (fn [ctx state msg] ($actor/stop)))")
    expect GeneError: discard runStr("(1 .send 2)")
    expect GeneError: discard runStr("(1 .ReplyTo:send 2)")

suite "vm — streams":
  test "read_one and read_all expose parsed forms":
    ck "($read_one \"(+ 1 2)\")", "(+ 1 2)"
    ck "(eval ($read_one \"(+ 1 2)\") ^in (env))", "3"
    ck "($read_one \"#_ (ignored)\")", "nil"
    ck "(var s ($read_all \"(a) #_ (ignored) (b 2)\")) " &
       "[(s .next) (s .next) (s .has_next)]",
       "[(a) (b 2) false]"
    ck "(try ($read_one \"(a\") catch Any $ex/message)",
       "\"read_one: unexpected EOF: unclosed '('\\n  while reading '(' opened at 1:1; expected ')'\""
    ck "(try ($read_one \"(a\") catch ParseError $ex/message)",
       "\"read_one: unexpected EOF: unclosed '('\\n  while reading '(' opened at 1:1; expected ')'\""
    expect GeneError: discard runStr("($read_one 1)")
    expect GeneError: discard runStr("($read_all 1)")
    expect GeneError: discard runStr("($read_one \"1 2\")")

  test "lex_all exposes typed reader tokens":
    ck "(var s ($lex_all \"(+ 1)\")) " &
       "(var t (s .next)) " &
       "(var k t/kind) (var x t/lexeme) (var l t/line) (var c t/col) " &
       "[k x l c]",
       "[l_paren \"(\" 1 1]"
    ck "(fn first-token [s : (Stream Token Never)] (s .next)) " &
       "(var t (first-token ($lex_all \"name\"))) " &
       "(var k t/kind) (var x t/lexeme) [k x]",
       "[symbol \"name\"]"
    ck "(try ($lex_all \"\\\"\") catch LexError $ex/message)",
       "\"lex_all: unterminated string literal\""
    expect GeneError: discard runStr("($lex_all 1)")

  test "stream values are opaque display values":
    ck "($to_stream [1 2])", "(stream)"

  test "stream has_next, peek, next, and close pull values":
    ck "(var s ($to_stream [1 2])) " &
       "[(s .has_next) " &
       " (s .peek) " &
       " (s .next) " &
       " (s .peek) " &
       " (s .next) " &
       " (s .has_next) " &
       " (s .close) " &
       " (s .has_next)]",
       "[true 1 1 2 2 false nil false]"

  test "streams skip void items":
    ck "(var s ($to_stream [1 void 2])) " &
       "[(s .next) (s .next) (s .has_next)]",
       "[1 2 false]"

  test "map pairs can be streamed":
    ck "(var s ($to_pairs_stream {^a 1 ^b 2})) " &
       "[(s .next) (s .next) (s .has_next)]",
       "[[a 1] [b 2] false]"
    ck "(var s ($to_pairs_stream {^a 1})) " &
       "(var pair (s .next)) " &
       "(fn key [x : Sym] x) (key pair/0)",
       "a"

  test "stream map transforms pulled values":
    ck "(var s ($map ($to_stream [1 2 3]) (fn [x] (* x 2)))) " &
       "[(s .next) (s .next) (s .next) " &
       " (s .has_next)]",
       "[2 4 6 false]"

  test "stream map skips void results":
    ck "(var s ($map ($to_stream [1 2]) (fn [x] (if (== x 1) void x)))) " &
       "[(s .next) (s .has_next)]",
       "[2 false]"

  test "stream map is lazy":
    ck "(var hits ($cell 0)) " &
       "(var s ($map ($to_stream [1 2 3]) " &
       "            (fn [x] (hits .update (fn [n] (+ n 1))) (* x 2)))) " &
       "[(hits .get) " &
       " (s .next) (hits .get) " &
       " (s .next) (hits .get)]",
       "[0 2 1 4 2]"

  test "stream filter keeps truthy predicate results":
    ck "(var s ($filter ($to_stream [1 2 3]) (fn [x] (> x 1)))) " &
       "[(s .next) (s .next) (s .has_next)]",
       "[2 3 false]"

  test "stream filter is lazy":
    ck "(var hits ($cell 0)) " &
       "(var s ($filter ($to_stream [1 2 3]) " &
       "               (fn [x] (hits .update (fn [n] (+ n 1))) (> x 1)))) " &
       "[(hits .get) " &
       " (s .next) (hits .get) " &
       " (s .next) (hits .get)]",
       "[0 2 2 3 3]"

  test "stream take limits pulled values":
    ck "(var s ($take ($to_stream [1 2 3]) 2)) " &
       "[(s .next) (s .next) (s .has_next)]",
       "[1 2 false]"

  test "stream take does not over-pull upstream":
    ck "(var hits ($cell 0)) " &
       "(var source ($map ($to_stream [1 2 3]) " &
       "                 (fn [x] (hits .update (fn [n] (+ n 1))) x))) " &
       "(var s ($take source 1)) " &
       "[(hits .get) " &
       " (s .next) (hits .get) " &
       " (s .has_next) (hits .get)]",
       "[0 1 1 false 1]"

  test "naturally exhausted take detaches and leaves upstream resumable":
    ck "(var source ($to_stream [1 2 3])) " &
       "(for x in ($take source 2) x) " &
       "[(source .has_next) (source .next)]",
       "[true 3]"

  test "producer errors are terminal and close owned upstream once":
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(var calls ($cell 0)) " &
       "(var closes ($cell 0)) " &
       "(fn source [] : (Stream Int Never) " &
       "  (try (yield 1) (yield 2) " &
       "   ensure (closes .update (fn [n] (+ n 1))))) " &
       "(var s ($map (source) " &
       "  (fn [x] (calls .update (fn [n] (+ n 1))) " &
       "          (fail (Boom ^message \"boom\"))))) " &
       "(var first (try (s .has_next) " &
       "  catch Boom $ex/message)) " &
       "(var after (s .has_next)) " &
       "(var terminal (try (s .next) " &
       "  catch EndOfStream $ex/message)) " &
       "[first after terminal (calls .get) (closes .get)]",
       "[\"boom\" false \"end of stream\" 1 1]"
    ck "(type PredBoom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for PredBoom) " &
       "(var calls ($cell 0)) " &
       "(var s ($filter ($to_stream [1 2]) " &
       "  (fn [x] (calls .update (fn [n] (+ n 1))) " &
       "          (fail (PredBoom ^message \"predicate\"))))) " &
       "(var first (try (s .next) " &
       "  catch PredBoom $ex/message)) " &
       "[first (s .has_next) (calls .get)]",
       "[\"predicate\" false 1]"

  test "generator close unwinds nested ensures in LIFO order":
    ck "(var log ($cell [])) " &
       "(fn note [x] (log .update (fn [xs] [xs... x]))) " &
       "(fn gen [] : (Stream Int Never) " &
       "  (try " &
       "    (try (yield 1) (yield 2) ensure (note `inner)) " &
       "   ensure (note `outer))) " &
       "(var s (gen)) " &
       "(s .next) " &
       "(s .close) " &
       "(s .close) " &
       "[(log .get) (s .has_next)]",
       "[[inner outer] false]"

  test "generator close preserves the first cleanup error and finishes ensures":
    ck "(type Cleanup ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Cleanup) " &
       "(var outer-ran ($cell false)) " &
       "(fn gen ^errors [Cleanup] [] : (Stream Int Cleanup) " &
       "  (try " &
       "    (try (yield 1) " &
       "     ensure (fail (Cleanup ^message \"first\"))) " &
       "   ensure " &
       "     (outer-ran .set true) " &
       "     (fail (Cleanup ^message \"second\")))) " &
       "(var s (gen)) " &
       "(s .next) " &
       "(var message (try (s .close) " &
       "  catch Cleanup $ex/message)) " &
       "[message (outer-ran .get) (s .has_next)]",
       "[\"first\" true false]"

  test "task cancellation closes an active generator and runs ensure once":
    let scope = newGlobalScope()
    var cancelled = false
    try:
      discard run(compileSource(
        "(var closes ($cell 0)) " &
        "(fn gen [] : (Stream Int Never) " &
        "  (try (while true (yield 1)) " &
        "   ensure (closes .update (fn [n] (+ n 1))))) " &
        "(scope " &
        "  (var t (spawn (for x in (gen) ($sleep 10)))) " &
        "  ($sleep 0) " &
        "  (t .cancel) " &
        "  (await t))"), scope)
    except GeneCancel:
      cancelled = true
    check cancelled
    check scope.lookup("closes").cellValue.intVal == 1

  test "return exits functions and terminates generators without an item":
    ck "(fn choose [yes] (if yes (then (return 7))) 9) " &
       "[(choose true) (choose false)]",
       "[7 9]"
    ck "(var cleaned ($cell 0)) " &
       "(fn stop [] " &
       "  (try (return 8) " &
       "   ensure (cleaned .update (fn [n] (+ n 1))))) " &
       "[(stop) (cleaned .get)]",
       "[8 1]"
    ck "(fn outer [] " &
       "  (fn inner [] (return 1) 99) " &
       "  [(inner) 2]) " &
       "(outer)",
       "[1 2]"
    ck "(var cleaned ($cell 0)) " &
       "(fn inner [] (return 3) 99) " &
       "(fn outer [] " &
       "  (try (var value (inner)) (+ value 4) " &
       "   ensure (cleaned .update (fn [n] (+ n 1))))) " &
       "[(outer) (cleaned .get)]",
       "[7 1]"
    ck "(var closes ($cell 0)) " &
       "(fn source [] : (Stream Int Never) " &
       "  (try (yield 4) (yield 5) " &
       "   ensure (closes .update (fn [n] (+ n 1))))) " &
       "(fn first [s] " &
       "  (for x in s (return x)) " &
       "  0) " &
       "(var s (source)) " &
       "[(first s) (closes .get) (s .has_next)]",
       "[4 1 false]"
    ck "(fn gen [] : (Stream Int Never) " &
       "  (yield 1) (return) (yield 2)) " &
       "(var s (gen)) " &
       "[(s .next) (s .has_next) " &
       " (try (s .peek) catch EndOfStream $ex/message)]",
       "[1 false \"end of stream\"]"
    expect GeneError:
      discard compileSource("(fn bad [] : (Stream Int Never) " &
                            "  (yield 1) (return 2))")

  test "stream into materializes list and map targets":
    ck "[($into ($to_stream [2 3]) [1]) " &
       " ($into ($to_pairs_stream {^b 2}) {^a 1})]",
       "[[1 2 3] {^a 1 ^b 2}]"

  test "stream next and peek raise EndOfStream shape":
    ck "(try (var s ($to_stream [])) (s .next) " &
       "catch EndOfStream $ex/message)",
       "\"end of stream\""
    ck "(try (var s ($to_stream [])) (s .peek) " &
       "catch EndOfStream $ex/message)",
       "\"end of stream\""

  test "Stream annotations accept streams only":
    ck "(fn first [s : Stream] (s .next)) (first ($to_stream [3]))", "3"
    ck "(fn first [s : (Stream Int Never)] (s .next)) " &
       "(first ($to_stream [4]))", "4"
    ck "(fn accept [s : (Stream Int Never)] 7) " &
       "(accept ($to_stream [\"bad\"]))", "7"
    ck "(try (fn first [s : (Stream Int Never)] (s .next)) " &
       "     (first ($to_stream [\"bad\"])) " &
       "catch TypeError $ex/where)",
       "\"Stream/next item\""
    ck "(try (fn typed [s] : (Stream Int Never) s) " &
       "     (var s (typed ($to_stream [\"bad\"]))) " &
       "     (s .next) " &
       "catch TypeError $ex/expected)",
       "\"Int\""
    expect GeneError:
      discard runStr("(fn first [s : Stream] s) (first [1])")

  test "stream operations require streams":
    expect GeneError: discard runStr("([1] .next)")
    expect GeneError: discard runStr("($to_stream {^a 1})")
    expect GeneError: discard runStr("($to_pairs_stream [1])")
    expect GeneError: discard runStr("($take ($to_stream [1]) -1)")
    expect GeneError: discard runStr("($into ($to_stream [1]) {})")
    # The generic collection operations dispatch on the receiver (design §6.2):
    # eager kinds answer in their own kind, and a receiver whose type declares
    # no such method raises the send path's MessageError (§9) from both the
    # send and the function spelling.
    expect GeneError: discard runStr("($map 42 (fn [x] x))")
    expect GeneError: discard runStr("(42 .filter (fn [x] true))")
    ck "($map [1 2] (fn [x] (* x 10)))", "[10 20]"
    ck "($take [1 2 3] 2)", "[1 2]"
    ck "($into [1] [])", "[1]"

suite "vm — printer view of callables":
  test "functions print a display form":
    ck "(fn [x] x)", "(fn)"                  # anonymous
    ck "(fn double [x] (* x 2))", "(fn double)"  # named form sets the name
    check runStr("+").print() == "(native-fn +)"
  test "namespaces print a display form":
    ck "(ns math (var pi 3))", "(ns math)"
