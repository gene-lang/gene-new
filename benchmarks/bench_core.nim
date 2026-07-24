## Core microbenchmarks for performance-sensitive changes.
##
## These benchmarks are intentionally dependency-free and print comparable
## numbers. They do not enforce thresholds; compare output before/after changes
## and explain any regression in the final report.
##
## Run:
##   nimble perf

import gene/[compiler, equality, logging, printer, reader, types, vm]
import std/[json, monotimes, strutils, tables, times]

var positiveZeroInput {.volatile.}: float64 = 0.0

proc discardLogLine(line: string) {.gcsafe.} =
  discard line

template bench(name: string, iterations: int, loopVar: untyped, body: untyped) =
  block:
    var checksum {.inject.} = 0'i64
    let started = getMonoTime()
    for loopVar in 0 ..< iterations:
      body
    let elapsed = getMonoTime() - started
    let nanos = max(1'i64, inNanoseconds(elapsed))
    let millis = float(nanos) / 1_000_000.0
    let opsPerSec = float(iterations) * 1_000_000_000.0 / float(nanos)
    echo name, ": ", iterations, " ops in ",
         formatFloat(millis, ffDecimal, 2), " ms (",
         formatFloat(opsPerSec, ffDecimal, 0),
         " ops/s, checksum=", checksum, ")"

proc main() =
  bench("value.small_int.construct", 20_000_000, i):
    let v = newInt(int64(i and 0xffff))
    checksum = checksum + int64(v.bits and 0xffff'u64)

  bench("value.small_int.construct_access", 2_000_000, i):
    let v = newInt(int64(i and 0xffff))
    checksum = checksum + v.intVal

  bench("value.zero_float.immediate_access", 2_000_000, i):
    let v = newFloat(positiveZeroInput)
    if v.kind == vkFloat and v.floatVal == positiveZeroInput:
      checksum = checksum + 1

  let nodeHead = newSym("item")
  bench("value.node.construct_access", 250_000, i):
    var props = initPropTable()
    props["id"] = newInt(i)
    let n = newNode(nodeHead, props = props, body = @[newInt(i)])
    checksum = checksum + n.props["id"].intVal + n.body[0].intVal

  let sample = "(page ^title \"Home\" (section (h1 \"Gene\") (p $\"hello ${name}\")))"
  bench("reader.single_form", 100_000, i):
    let v = read(sample)
    checksum = checksum + int64(v.body.len)

  let demoSource = readFile("examples/web_demo.gene")
  bench("reader.web_demo.read_all", 1_000, i):
    let forms = readAll(demoSource)
    checksum = checksum + int64(forms.len)

  let demoForms = readAll(demoSource)
  bench("printer.web_demo.forms", 1_000, i):
    for f in demoForms:
      checksum = checksum + int64(f.print().len)

  let simpleProgram = "(+ 1 2 3 4)"
  bench("compiler.simple_call.source_to_gir", 100_000, i):
    let chunk = compileSource(simpleProgram)
    checksum = checksum + int64(chunk.instructions.len + chunk.constants.len)

  let agentUnit = readAllWithLocs(readFile("examples/ai_agent/tui.gene"),
                                  "examples/ai_agent/tui.gene")
  bench("compiler.ai_agent.source_unit_to_gir", 1, i):
    let chunk = compileSourceUnit(agentUnit)
    checksum = checksum + int64(chunk.instructions.len + chunk.constants.len)

  let simpleChunk = compileSource(simpleProgram)
  let simpleScope = newGlobalScope()
  bench("vm.simple_call.compiled_chunk", 500_000, i):
    let v = run(simpleChunk, simpleScope)
    checksum = checksum + v.intVal

  var loggingConfig = defaultLoggingConfig()
  loggingConfig.rootLevel = llWarn
  installLoggingConfig(loggingConfig)
  let disabledRuntimeLogger = newRuntimeLogger("gene/bench")
  bench("logging.native_disabled", 20_000_000, i):
    if disabledRuntimeLogger.enabled(llDebug):
      checksum = checksum + int64(i)

  let disabledGeneScope = newGlobalScope()
  discard run(compileSource(
    "(import log [new_logger debug!]) " &
    "(var logger (new_logger \"app/bench\")) " &
    "(var drive (fn [] (debug! logger \"disabled\")))"),
    disabledGeneScope)
  let disabledGeneChunk = compileSource("(drive)")
  bench("logging.gene_disabled_macro", 500_000, i):
    let value = run(disabledGeneChunk, disabledGeneScope)
    if value.kind == vkNil:
      checksum = checksum + 1

  var enabledTextConfig = defaultLoggingConfig()
  for _, sink in enabledTextConfig.sinks: closeLogSink(sink)
  enabledTextConfig.sinks = initTable[string, LogSink]()
  enabledTextConfig.sinks["text"] =
    newCallbackLogSink("text", discardLogLine, lfText)
  enabledTextConfig.rootTargets = @["text"]
  enabledTextConfig.rootLevel = llInfo
  installLoggingConfig(enabledTextConfig)
  let enabledTextLogger = newRuntimeLogger("gene/bench")
  bench("logging.enabled_text_no_payload", 100_000, i):
    enabledTextLogger.emit(llInfo, "ready")
    checksum = checksum + int64(i and 1)

  var enabledJsonConfig = defaultLoggingConfig()
  for _, sink in enabledJsonConfig.sinks: closeLogSink(sink)
  enabledJsonConfig.sinks = initTable[string, LogSink]()
  enabledJsonConfig.sinks["json"] =
    newCallbackLogSink("json", discardLogLine, lfJsonl)
  enabledJsonConfig.rootTargets = @["json"]
  enabledJsonConfig.rootLevel = llInfo
  installLoggingConfig(enabledJsonConfig)
  let enabledJsonLogger = newRuntimeLogger("gene/bench")
  let eightEntryPayload = %*{
    "a": 1, "b": 2, "c": 3, "d": 4,
    "e": 5, "f": 6, "g": 7, "h": 8}

  var enabledGeneConfig = defaultLoggingConfig()
  for _, sink in enabledGeneConfig.sinks: closeLogSink(sink)
  enabledGeneConfig.sinks = initTable[string, LogSink]()
  enabledGeneConfig.sinks["gene"] =
    newCallbackLogSink("gene", discardLogLine, lfGene)
  enabledGeneConfig.rootTargets = @["gene"]
  enabledGeneConfig.rootLevel = llInfo
  installLoggingConfig(enabledGeneConfig)
  let enabledGeneLogger = newRuntimeLogger("gene/bench")
  bench("logging.enabled_gene_payload_8", 50_000, i):
    enabledGeneLogger.emit(llInfo, "structured", eightEntryPayload)
    checksum = checksum + int64(i and 1)

  installLoggingConfig(enabledJsonConfig)
  bench("logging.enabled_json_payload_8", 50_000, i):
    enabledJsonLogger.emit(llInfo, "structured", eightEntryPayload)
    checksum = checksum + int64(i and 1)

  var sameRendererConfig = defaultLoggingConfig()
  for _, sink in sameRendererConfig.sinks: closeLogSink(sink)
  sameRendererConfig.sinks = initTable[string, LogSink]()
  sameRendererConfig.sinks["a"] =
    newCallbackLogSink("a", discardLogLine, lfJsonl)
  sameRendererConfig.sinks["b"] =
    newCallbackLogSink("b", discardLogLine, lfJsonl)
  sameRendererConfig.rootTargets = @["a", "b"]
  sameRendererConfig.rootLevel = llInfo
  installLoggingConfig(sameRendererConfig)
  let sameRendererLogger = newRuntimeLogger("gene/bench")
  bench("logging.fanout_same_renderer", 50_000, i):
    sameRendererLogger.emit(llInfo, "fanout", eightEntryPayload)
    checksum = checksum + int64(i and 1)

  var mixedRendererConfig = defaultLoggingConfig()
  for _, sink in mixedRendererConfig.sinks: closeLogSink(sink)
  mixedRendererConfig.sinks = initTable[string, LogSink]()
  mixedRendererConfig.sinks["text"] =
    newCallbackLogSink("text", discardLogLine, lfText)
  mixedRendererConfig.sinks["json"] =
    newCallbackLogSink("json", discardLogLine, lfJsonl)
  mixedRendererConfig.rootTargets = @["text", "json"]
  mixedRendererConfig.rootLevel = llInfo
  installLoggingConfig(mixedRendererConfig)
  let mixedRendererLogger = newRuntimeLogger("gene/bench")
  bench("logging.fanout_mixed_renderers", 50_000, i):
    mixedRendererLogger.emit(llInfo, "fanout", eightEntryPayload)
    checksum = checksum + int64(i and 1)

  let noArgScope = newGlobalScope()
  noArgScope.define("seven", run(compileSource("(fn [] 7)"), noArgScope))
  let noArgChunk = compileSource("(seven)")
  bench("vm.no_arg_fn.compiled_chunk", 500_000, i):
    let v = run(noArgChunk, noArgScope)
    checksum = checksum + v.intVal

  let parentNoArgScope = newGlobalScope()
  discard run(compileSource(
    "(var runner (do (var call_once (fn [] 7)) " &
    "  (fn [] (call_once))))"), parentNoArgScope)
  let parentNoArgChunk = compileSource("(runner)")
  bench("vm.parent_no_arg_fn.compiled_chunk", 500_000, i):
    let v = run(parentNoArgChunk, parentNoArgScope)
    checksum = checksum + v.intVal

  let outerNoArgScope = newGlobalScope()
  discard run(compileSource(
    "(var runner (do (var call_once (fn [] 7)) " &
    "  ((fn [] (fn [] (call_once))))))"), outerNoArgScope)
  let outerNoArgChunk = compileSource("(runner)")
  bench("vm.outer_no_arg_fn.compiled_chunk", 500_000, i):
    let v = run(outerNoArgChunk, outerNoArgScope)
    checksum = checksum + v.intVal

  let varHeavyScope = newGlobalScope()
  varHeavyScope.define("var3", run(compileSource(
    "(fn [x] (var a (+ x 1)) (var b (+ a 1)) (var c (+ b 1)) c)"),
    varHeavyScope))
  let varHeavyChunk = compileSource("(var3 5)")
  bench("vm.var_heavy_fn.compiled_chunk", 500_000, i):
    let v = run(varHeavyChunk, varHeavyScope)
    checksum = checksum + v.intVal

  let listFnScope = newGlobalScope()
  listFnScope.define("pair", run(compileSource(
    "(fn [x y] [x y])"), listFnScope))
  let listFnChunk = compileSource("((pair 1 2) ~ size)")
  bench("vm.list_leaf_fn.compiled_chunk", 500_000, i):
    let v = run(listFnChunk, listFnScope)
    checksum = checksum + v.intVal

  let oneArgScope = newGlobalScope()
  oneArgScope.define("inc1", run(compileSource("(fn [x] (+ x 1))"), oneArgScope))
  let oneArgChunk = compileSource("(inc1 9)")
  bench("vm.one_arg_fn.compiled_chunk", 500_000, i):
    let v = run(oneArgChunk, oneArgScope)
    checksum = checksum + v.intVal

  let typedUnaryScope = newGlobalScope()
  typedUnaryScope.define("typed-inc",
    run(compileSource("(fn [x : Int] : Int (+ x 1))"), typedUnaryScope))
  let typedUnaryChunk = compileSource("(typed-inc 9)")
  bench("vm.typed_unary_int_call.compiled_chunk", 500_000, i):
    let v = run(typedUnaryChunk, typedUnaryScope)
    checksum = checksum + v.intVal

  let namedScope = newGlobalScope()
  namedScope.define("pick", run(compileSource("(fn [x ^scale] (+ x scale))"), namedScope))
  let namedChunk = compileSource("(pick ^scale 4 6)")
  bench("vm.named_call.compiled_chunk", 500_000, i):
    let v = run(namedChunk, namedScope)
    checksum = checksum + v.intVal

  let typedScope = newGlobalScope()
  typedScope.define("typed-pick",
    run(compileSource("(fn [x : Int ^scale : Int] : Int (+ x scale))"), typedScope))
  let typedChunk = compileSource("(typed-pick ^scale 4 6)")
  bench("vm.typed_call.compiled_chunk", 500_000, i):
    let v = run(typedChunk, typedScope)
    checksum = checksum + v.intVal

  let globalFourScope = newGlobalScope()
  globalFourScope.define("sum4",
    run(compileSource("(fn [a b c d] (+ (+ a b) (+ c d)))"), globalFourScope))
  let globalFourChunk = compileSource("(sum4 1 2 3 4)")
  bench("vm.global_four_arg_fn.compiled_chunk", 500_000, i):
    let v = run(globalFourChunk, globalFourScope)
    checksum = checksum + v.intVal

  let tailCallScope = newGlobalScope()
  discard run(compileSource(
    "(var id (fn [x] x)) " &
    "(var wrap1 (fn [x] (id x))) " &
    "(var wrap2 (fn [x] (wrap1 x))) " &
    "(var wrap3 (fn [x] (wrap2 x))) " &
    "(var wrap4 (fn [x] (wrap3 x)))"),
    tailCallScope)
  let tailCallChunk = compileSource("(wrap4 9)")
  bench("vm.tail_call_chain.compiled_chunk", 500_000, i):
    let v = run(tailCallChunk, tailCallScope)
    checksum = checksum + v.intVal

  let tailRecurScope = newGlobalScope()
  discard run(compileSource(
    "(var countdown (fn [n] (if (< n 1) n (countdown (- n 1)))))"),
    tailRecurScope)
  let tailRecurChunk = compileSource("(countdown 64)")
  bench("vm.tail_recur_countdown.compiled_chunk", 200_000, i):
    let v = run(tailRecurChunk, tailRecurScope)
    checksum = checksum + v.intVal

  # Sustained untyped calls through the generic frame path: an in-function
  # loop (plain slot scope, like real code) calling a 1-arg untyped fn from
  # the parent scope 1000 times per run. Covers scope-pool acquire/release,
  # frame push/pop, and run-stack recycling per call.
  let callLoopScope = newGlobalScope()
  discard run(compileSource(
    "(var f1 (fn [x] x)) " &
    "(var drive (fn [] " &
    "  (var i 0) (var acc 0) " &
    "  (while (< i 1000) " &
    "    (do (set acc (+ acc (f1 1))) (set i (+ i 1)))) " &
    "  acc))"), callLoopScope)
  let callLoopChunk = compileSource("(drive)")
  bench("vm.untyped_call_loop.compiled_chunk", 2_000, i):
    let v = run(callLoopChunk, callLoopScope)
    checksum = checksum + v.intVal

  # Top-level (module/eval) sets: the chunk's own scope is slot-mirrored, so
  # every set also maintains the vars view. 1000 iterations x 2 sets per run
  # on a fresh scope, the shape of script/REPL top-level loops.
  let topSetChunk = compileSource(
    "(var i 0) (var acc 0) " &
    "(while (< i 1000) " &
    "  (do (set acc (+ acc i)) (set i (+ i 1)))) " &
    "acc")
  bench("vm.top_level_set_loop.compiled_chunk", 2_000, i):
    let v = run(topSetChunk, newGlobalScope())
    checksum = checksum + v.intVal

  # Untyped self-recursion (the fused recur path): fib(18) = 2584,
  # ~8360 calls per run. The typical call-heavy workload shape.
  let fibScope = newGlobalScope()
  discard run(compileSource(
    "(var fib (fn [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))"),
    fibScope)
  let fibChunk = compileSource("(fib 18)")
  bench("vm.fib_untyped.compiled_chunk", 500, i):
    let v = run(fibChunk, fibScope)
    checksum = checksum + v.intVal

  let trampolineNamedScope = newGlobalScope()
  let trampolineNamedFn =
    run(compileSource("(fn [x ^scale] (+ x scale))"), trampolineNamedScope)
  let trampolineArgs = @[newInt(6)]
  let trampolineNames = @["scale"]
  let trampolineValues = @[newInt(4)]
  bench("vm.named_call.apply_trampoline", 500_000, i):
    let v = call(trampolineNamedFn, trampolineArgs, trampolineNames,
                 trampolineValues, trampolineNamedScope)
    checksum = checksum + v.intVal

  let protocolScope = newGlobalScope()
  discard run(compileSource(
    "(protocol ToInt (message to_int [self] : Int)) " &
    "(protocol Adder (message add [self n] : Int)) " &
    # Triv's impl body just returns self, matching `identity` below so the send
    # and the plain 1-arg call differ only in dispatch, not in body work.
    "(protocol Triv (message triv [self]))" &
    # Box also carries a type-direct message `get` alongside its protocol impls.
    "(type Box ^props {^x Int} (message get [self] : Int self/x)) " &
    # Animal/Dog exercise inherited dispatch: the impl lives on the parent, so
    # resolution walks the ^is chain (receiverDistance 1) before the cache warms.
    "(type Animal ^props {^x Int}) " &
    "(type Dog ^is Animal ^props {}) " &
    "(impl ToInt for Box (message to_int [self] : Int self/x)) " &
    "(impl Adder for Box (message add [self n] : Int (+ self/x n))) " &
    "(impl Triv for Box (message triv [self] self)) " &
    "(impl ToInt for Animal (message to_int [self] : Int self/x)) " &
    # Base/Derived measure `super`: the override delegates one level up the ^is
    # chain, so the send pays parent lookup on top of the impl body.
    "(type Base ^props {} (message tag [] : Int 1)) " &
    "(type Derived ^is Base ^props {} " &
    "  (message tag [] : Int (super ~ tag))) " &
    "(var box (Box ^x 10)) " &
    "(var dog (Dog ^x 10)) " &
    "(var derived (Derived)) " &
    # A built-in receiver: `(c ~ get)` resolves through the Cell type namespace
    # rather than a user type's message table.
    "(var c (cell 10)) " &
    # Reference: a 1-arg Gene function call — the target sends aim to approach.
    "(var identity (fn [x] x))"), protocolScope)
  # Message names are not lexical bindings (docs/core.md §1); the hot dispatch
  # path is the send form, resolved receiver-first (§9.1). Protocol messages are
  # always qualified (`box ~ Proto/msg`); only type-direct messages take the bare
  # name (`box ~ get`). The per-call-site inline cache collapses the resolution
  # walk, so a trivial-body qualified send (`box ~ Triv/triv`) sits right on the
  # 1-arg Gene call reference: the extra cost of the other sends is impl-body work
  # (a `self/x` selector plus a `: Int` return-type check) plus the qualified
  # selector extraction of `Proto/msg`, not the dispatch walk.
  let referenceCallChunk = compileSource("(identity box)")
  bench("vm.call.gene_one_arg.compiled_chunk", 500_000, i):
    let v = run(referenceCallChunk, protocolScope)
    checksum = checksum + int64(v.props["x"].intVal)
  let trivialSendChunk = compileSource("(box ~ Triv/triv)")
  bench("vm.protocol_message.trivial_body.compiled_chunk", 500_000, i):
    let v = run(trivialSendChunk, protocolScope)
    checksum = checksum + int64(v.props["x"].intVal)
  let protocolChunk = compileSource("(box ~ ToInt/to_int)")
  bench("vm.protocol_message.compiled_chunk", 500_000, i):
    let v = run(protocolChunk, protocolScope)
    checksum = checksum + v.intVal
  let inheritedChunk = compileSource("(dog ~ ToInt/to_int)")
  bench("vm.protocol_message.inherited.compiled_chunk", 500_000, i):
    let v = run(inheritedChunk, protocolScope)
    checksum = checksum + v.intVal
  let typeDirectChunk = compileSource("(box ~ get)")
  bench("vm.protocol_message.type_direct.compiled_chunk", 500_000, i):
    let v = run(typeDirectChunk, protocolScope)
    checksum = checksum + v.intVal
  let sendArgChunk = compileSource("(box ~ Adder/add 5)")
  bench("vm.protocol_message.with_arg.compiled_chunk", 500_000, i):
    let v = run(sendArgChunk, protocolScope)
    checksum = checksum + v.intVal
  # Built-in and `super` dispatch are measured separately from protocol sends.
  # The built-in send resolves through its type namespace and lands slightly
  # above the 1-arg call reference. `super` reads the parent identity stamped on
  # the body's chunk, then resolves in that type's message table; the site is
  # statically monomorphic (fixed parent, fixed name), so it is cached under an
  # impl-epoch guard. This case runs two dispatches and two bodies (the override
  # plus the parent), so ~0.6x the one-call reference is the expected shape.
  let builtinSendChunk = compileSource("(c ~ get)")
  bench("vm.builtin_message.compiled_chunk", 500_000, i):
    let v = run(builtinSendChunk, protocolScope)
    checksum = checksum + v.intVal
  let superSendChunk = compileSource("(derived ~ tag)")
  bench("vm.super_send.compiled_chunk", 500_000, i):
    let v = run(superSendChunk, protocolScope)
    checksum = checksum + v.intVal

  let restScope = newGlobalScope()
  restScope.define("collect", run(compileSource("(fn [head tail...] tail)"), restScope))
  let restChunk = compileSource("(collect 6 4 3 2)")
  bench("vm.rest_call.compiled_chunk", 500_000, i):
    let v = run(restChunk, restScope)
    checksum = checksum + int64(v.listItems.len)

  let defaultScope = newGlobalScope()
  defaultScope.define("scaled", run(compileSource("(fn [x y = (+ x 1)] (+ x y))"), defaultScope))
  let defaultChunk = compileSource("(scaled 4)")
  bench("vm.default_call.compiled_chunk", 500_000, i):
    let v = run(defaultChunk, defaultScope)
    checksum = checksum + v.intVal

  let selectorScope = newGlobalScope()
  selectorScope.define("user", run(compileSource("{^name \"Ada\" ^age 37}"), selectorScope))
  let selectorChunk = compileSource("user/age")
  bench("vm.selector_path.compiled_chunk", 500_000, i):
    let v = run(selectorChunk, selectorScope)
    checksum = checksum + v.intVal

  let dynamicSelectorScope = newGlobalScope()
  dynamicSelectorScope.define("field", newStr("age"))
  dynamicSelectorScope.define("user", run(compileSource("{^name \"Ada\" ^age 37}"), dynamicSelectorScope))
  let dynamicSelectorChunk = compileSource("user/%field")
  bench("vm.dynamic_selector_path.compiled_chunk", 500_000, i):
    let v = run(dynamicSelectorChunk, dynamicSelectorScope)
    checksum = checksum + v.intVal

  let projectionStageScope = newGlobalScope()
  projectionStageScope.define("user",
    run(compileSource("(quote (user ^name \"Ada\" ^age 37 10 20))"), projectionStageScope))
  let projectionStageChunk = compileSource("user/%props/age")
  bench("vm.selector_projection_stage.compiled_chunk", 500_000, i):
    let v = run(projectionStageChunk, projectionStageScope)
    checksum = checksum + v.intVal

  let assocScope = newGlobalScope()
  assocScope.define("user", run(compileSource("{^name \"Ada\" ^age 37}"), assocScope))
  let assocChunk = compileSource("(assoc_in user /age 38)")
  bench("vm.assoc_in.compiled_chunk", 250_000, i):
    let v = run(assocChunk, assocScope)
    checksum = checksum + v.mapEntries["age"].intVal

  let left = read("(user ^name \"Ada\" 1 2 3)")
  let right = read("(user ^name \"Ada\" 1 2 3)")
  bench("equality.structural_node", 500_000, i):
    if equal(left, right):
      checksum = checksum + 1

main()
