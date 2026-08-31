## Core microbenchmarks for performance-sensitive changes.
##
## These benchmarks are intentionally dependency-free and print comparable
## numbers. They do not enforce thresholds; compare output before/after changes
## and explain any regression in the final report.
##
## Run:
##   nimble perf

import gene/ext/logging
import gene/[compiler, equality, gir, printer, reader, types, vm]
import std/[json, monotimes, os, osproc, strutils, tables, times]

var positiveZeroInput {.volatile.}: float64 = 0.0

type BenchNativeRecord = object
  value: int64

proc benchTypedNativeLoad(record: ptr BenchNativeRecord): int64 {.inline.} =
  record.value

proc benchGeneratedCFieldLoad(iterations: int) =
  ## Time the C the backend actually emits.
  ##
  ## §10 of docs/proposals/native-type.md gates this feature on the emitted
  ## path being a direct load. A hand-written Nim analogue cannot answer that:
  ## it measures a different compiler's output, and it stays green even when
  ## the backend emits nothing for the function at all. Skip cleanly when no C
  ## compiler is available — `nimble perf` enforces no thresholds.
  let cc = getEnv("CC", "cc")
  if findExe(cc).len == 0:
    echo "typed_native.generated_c_field_load: skipped (no C compiler on PATH)"
    return
  let chunk = compileSource(
    "(ffi/struct CNode ^fields [[value C/Int64]]) " &
    "(type Node ^native {^abi CNode ^lifecycle manual}) " &
    "(fn load_value [node : Node] : I64 node/value)")
  let generated = chunk.emitExperimentalC()
  if "int64_t gene_native_load_value(CNode * node)" notin generated:
    echo "typed_native.generated_c_field_load: FAILED (getter was not emitted)"
    return
  let harness = """
#include <stdio.h>
#include <time.h>
int main(void) {
  CNode record;
  record.value = 42;
  CNode *volatile slot = &record;
  long long checksum = 0;
  struct timespec started, ended;
  clock_gettime(CLOCK_MONOTONIC, &started);
  for (long long i = 0; i < ITERATIONS; ++i) {
    checksum += gene_native_load_value(slot) + (i & 1);
  }
  clock_gettime(CLOCK_MONOTONIC, &ended);
  double nanos = (double)(ended.tv_sec - started.tv_sec) * 1000000000.0 +
                 (double)(ended.tv_nsec - started.tv_nsec);
  printf("%.0f %lld\n", nanos, checksum);
  return 0;
}
"""
  let sourcePath = getTempDir() / "gene_bench_typed_native.c"
  let exePath = getTempDir() / ("gene_bench_typed_native" & ExeExt)
  writeFile(sourcePath, generated & harness)
  defer:
    removeFile(sourcePath)
    if fileExists(exePath):
      removeFile(exePath)
  let built = execCmdEx(quoteShell(cc) & " -std=c11 -O2 -DITERATIONS=" &
    $iterations & " " & quoteShell(sourcePath) & " -o " & quoteShell(exePath))
  if built.exitCode != 0:
    echo "typed_native.generated_c_field_load: FAILED to build generated C"
    echo built.output.strip()
    return
  let ran = execCmdEx(quoteShell(exePath))
  if ran.exitCode != 0:
    echo "typed_native.generated_c_field_load: FAILED to run generated C"
    return
  let fields = ran.output.strip().split(' ')
  if fields.len != 2:
    echo "typed_native.generated_c_field_load: FAILED to parse harness output"
    return
  let nanos = max(1.0, parseFloat(fields[0]))
  let opsPerSec = float(iterations) * 1_000_000_000.0 / nanos
  echo "typed_native.generated_c_field_load: ", iterations, " ops in ",
       formatFloat(nanos / 1_000_000.0, ffDecimal, 2), " ms (",
       formatFloat(opsPerSec, ffDecimal, 0),
       " ops/s, checksum=", fields[1], ")"

proc benchWrapperNativeGetter(args: openArray[Value]): Value {.nimcall.} =
  let record = cast[ptr BenchNativeRecord](
    args[0].props["handle"].cPtrAddress)
  newInt(record.value)

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

  let styleSource = readFile("examples/style_guide.gene")
  bench("reader.style_guide.read_all", 1_000, i):
    let forms = readAll(styleSource)
    checksum = checksum + int64(forms.len)

  let styleForms = readAll(styleSource)
  bench("printer.style_guide.forms", 1_000, i):
    for f in styleForms:
      checksum = checksum + int64(f.print().len)

  let simpleProgram = "(+ 1 2 3 4)"
  bench("compiler.simple_call.source_to_gir", 100_000, i):
    let chunk = compileSource(simpleProgram)
    checksum = checksum + int64(chunk.instructions.len + chunk.constants.len)

  let agentUnit = readAllWithLocs(readFile("examples/ai_agent/src/tui.gene"),
                                  "examples/ai_agent/src/tui.gene")
  bench("compiler.ai_agent.source_unit_to_gir", 1, i):
    let chunk = compileSourceUnit(agentUnit)
    checksum = checksum + int64(chunk.instructions.len + chunk.constants.len)

  let simpleChunk = compileSource(simpleProgram)
  let simpleScope = newGlobalScope()
  bench("vm.simple_call.compiled_chunk", 500_000, i):
    let v = run(simpleChunk, simpleScope)
    checksum = checksum + v.intVal

  let tailMutualChunk = compileSource(
    "(fn is_even [n] (if (== n 0) true (is_odd (- n 1)))) " &
    "(fn is_odd [n] (if (== n 0) false (is_even (- n 1)))) " &
    "(is_even 100000)")
  bench("vm.tail_mutual.100k", 20, i):
    let value = run(tailMutualChunk, newGlobalScope())
    if value.kind == vkBool and value.boolVal:
      checksum = checksum + 1

  let tailMatchChunk = compileSource(
    "(fn consume [xs n] " &
    "  (match xs " &
    "    (when [] (if (== n 0) 0 (consume [n] (- n 1)))) " &
    "    (else (consume [] n)))) " &
    "(consume [] 100000)")
  bench("vm.tail_match.100k", 20, i):
    let value = run(tailMatchChunk, newGlobalScope())
    checksum = checksum + value.intVal

  var loggingConfig = defaultLoggingConfig()
  loggingConfig.rootLevel = llWarn
  installLoggingConfig(loggingConfig)
  let disabledRuntimeLogger = newRuntimeLogger("gene/bench")
  bench("logging.native_disabled", 20_000_000, i):
    if disabledRuntimeLogger.enabled(llDebug):
      checksum = checksum + int64(i)

  let disabledGeneScope = newGlobalScope()
  discard run(compileSource(
    "(import $log [new_logger log_debug]) " &
    "(var logger (new_logger \"app/bench\")) " &
    "(var drive (fn [] (log_debug logger \"disabled\")))"),
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

  # Float-annotated calls. Every other typed benchmark here annotates `Int`,
  # which has had a boundary fast path since long before `bareScalarSatisfied`
  # generalized it — so an `Int` benchmark cannot see a regression in the path
  # every *other* scalar annotation takes. These can, and they are the shape
  # numeric code actually has: `examples/miclone`'s noise kernels are F64
  # throughout, and their annotations used to cost more than the calls they
  # annotated (183 ns/call untyped against 557 ns for `[x : F64] : F64`).
  let typedFloatScope = newGlobalScope()
  typedFloatScope.define("scale_f64",
    run(compileSource("(fn [x : F64] : F64 (* x 1.5))"), typedFloatScope))
  let typedFloatChunk = compileSource("(scale_f64 2.0)")
  bench("vm.typed_f64_call.compiled_chunk", 500_000, i):
    let v = run(typedFloatChunk, typedFloatScope)
    checksum = checksum + int(v.floatVal)

  # Seven F64 parameters, the arity of `fbm3`. Guards the per-parameter half of
  # the boundary cost, which a one-argument benchmark barely exercises.
  let typedFloat7Scope = newGlobalScope()
  typedFloat7Scope.define("sum7_f64",
    run(compileSource(
      "(fn [a : F64 b : F64 c : F64 d : F64 e : F64 f : F64 g : F64] : F64 " &
      "  (+ a (+ b (+ c (+ d (+ e (+ f g)))))))"), typedFloat7Scope))
  let typedFloat7Chunk =
    compileSource("(sum7_f64 1.0 2.0 3.0 4.0 5.0 6.0 7.0)")
  bench("vm.typed_f64_call7.compiled_chunk", 500_000, i):
    let v = run(typedFloat7Chunk, typedFloat7Scope)
    checksum = checksum + int(v.floatVal)

  # Buffer element access. `Buffer/get` reached its elements through a proc
  # returning the backing seq *by value*, so a read copied the whole buffer and
  # any scan was O(n^2) — a 512,000-element chunk moved 4 MB per read. This
  # benchmark is sized so that regression would be unmissable rather than slow.
  let bufferScope = newGlobalScope()
  discard run(compileSource(
    "(var buf ($buffer F64 4096.0)) " &
    "(var scan (fn [] " &
    "  (var i 0.0) (var acc 0.0) " &
    "  (while (< i 4096.0) " &
    "    (do (set acc (+ acc (buf ~ get i))) (set i (+ i 1.0)))) " &
    "  acc))"), bufferScope)
  let bufferChunk = compileSource("(scan)")
  bench("vm.buffer_scan_4096.compiled_chunk", 200, i):
    let v = run(bufferChunk, bufferScope)
    checksum = checksum + int(v.floatVal)

  # The write side, which is the more expensive half and was unmeasured until
  # this was added. Any elementwise numeric pass — meshing, a vector op, an
  # image filter — is `n` reads and `n` writes, so a regression in
  # `Buffer/set` is a regression in every one of them at once.
  let bufferWriteScope = newGlobalScope()
  discard run(compileSource(
    "(var wbuf ($buffer F64 4096.0)) " &
    "(var fill (fn [] " &
    "  (var i 0.0) " &
    "  (while (< i 4096.0) " &
    "    (do (wbuf ~ set i 1.0) (set i (+ i 1.0)))) " &
    "  i))"), bufferWriteScope)
  let bufferWriteChunk = compileSource("(fill)")
  bench("vm.buffer_fill_4096.compiled_chunk", 200, i):
    let v = run(bufferWriteChunk, bufferWriteScope)
    checksum = checksum + int(v.floatVal)

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
    "(var c ($cell 10)) " &
    # Reference: a 1-arg Gene function call — the target sends aim to approach.
    "(var identity (fn [x] x))"), protocolScope)
  # Message names are not lexical bindings (docs/core.md §1); the hot dispatch
  # path is the send form, resolved receiver-first (§9.1). Protocol messages are
  # always qualified (`box ~ Proto:msg`); only type-direct messages take the bare
  # name (`box ~ get`). The per-call-site inline cache collapses the resolution
  # walk, so a trivial-body qualified send (`box ~ Triv:triv`) sits right on the
  # 1-arg Gene call reference: the extra cost of the other sends is impl-body work
  # (a `self/x` selector plus a `: Int` return-type check), not the dispatch
  # walk. A qualified send pushes the protocol and resolves the name against the
  # receiver; it never materializes a message value.
  let referenceCallChunk = compileSource("(identity box)")
  bench("vm.call.gene_one_arg.compiled_chunk", 500_000, i):
    let v = run(referenceCallChunk, protocolScope)
    checksum = checksum + int64(v.props["x"].intVal)
  let trivialSendChunk = compileSource("(box ~ Triv:triv)")
  bench("vm.protocol_message.trivial_body.compiled_chunk", 500_000, i):
    let v = run(trivialSendChunk, protocolScope)
    checksum = checksum + int64(v.props["x"].intVal)
  let protocolChunk = compileSource("(box ~ ToInt:to_int)")
  bench("vm.protocol_message.compiled_chunk", 500_000, i):
    let v = run(protocolChunk, protocolScope)
    checksum = checksum + v.intVal
  let inheritedChunk = compileSource("(dog ~ ToInt:to_int)")
  bench("vm.protocol_message.inherited.compiled_chunk", 500_000, i):
    let v = run(inheritedChunk, protocolScope)
    checksum = checksum + v.intVal
  let typeDirectChunk = compileSource("(box ~ get)")
  bench("vm.protocol_message.type_direct.compiled_chunk", 500_000, i):
    let v = run(typeDirectChunk, protocolScope)
    checksum = checksum + v.intVal
  let sendArgChunk = compileSource("(box ~ Adder:add 5)")
  bench("vm.protocol_message.with_arg.compiled_chunk", 500_000, i):
    let v = run(sendArgChunk, protocolScope)
    checksum = checksum + v.intVal
  # `Self:` names no type at all and lowers to the bare send, so it should sit
  # on the type-direct line rather than the qualified one.
  let colonSelfChunk = compileSource("(box ~ Self:get)")
  bench("vm.type_message.self_colon.compiled_chunk", 500_000, i):
    let v = run(colonSelfChunk, protocolScope)
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
  let projectionStageChunk = compileSource("user/%$props/age")
  bench("vm.selector_projection_stage.compiled_chunk", 500_000, i):
    let v = run(projectionStageChunk, projectionStageScope)
    checksum = checksum + v.intVal

  # Managed wrapper cost (docs/proposals/native-type.md §4.6). The open question
  # is whether the shipped shape — wrapper node + prop table + CPtrData — is
  # worth replacing with one compact object, so the handle here is a real owned
  # pointer; a `Str` stand-in would allocate no CPtrData and measure the wrong
  # thing. The decomposition is what decides it, and each step differs from the
  # one above it by exactly one factor:
  #
  #   handle_alloc                  the CPtrData alone
  #   factory_construct_untyped     + node + prop table + an `Any` field check
  #   factory_construct             + the `(C/OwnedPtr T)` field check
  #   ctor_construct                + ctor dispatch and the compiled chunk
  #
  # The two factory rows are the same `newNativeWrapper` call with the same
  # fresh pointer and string allocations, differing only in the declared handle
  # type, so their difference isolates the boundary check. (`plain_direct_
  # construct` is a different path — ordinary `(T ...)` data construction — and
  # is here for scale, not for subtraction.)
  #
  # As measured (2026-07-28, release, this machine): ~50 ns, ~615 ns, ~3.13 us,
  # ~7.96 us. So the compound C-pointer check, not allocation, is ~2.5 us of the
  # factory cost, and a compact single-allocation wrapper would attack the
  # ~565 ns term instead. That is the §4.6 answer until the compound C-type
  # check gets cheaper. Compare either total against the foreign work it wraps —
  # a SQLite `open` is microseconds — before spending VM representation cases.
  proc benchReleaseHandle(p: pointer) {.nimcall.} = discard
  proc benchOpenHandle(args: openArray[Value]): Value {.nimcall.} =
    newCOwnedPtr(cast[pointer](0xB10B), benchReleaseHandle, newSym("Blob"))
  let wrapperScope = newGlobalScope()
  wrapperScope.define("open_handle",
                      newNativeFn("open_handle", benchOpenHandle))
  discard run(compileSource(
    "(type WrapperLike ^repr native_wrapper " &
    "  ^props {^handle (C/OwnedPtr Blob) ^backend Str} " &
    "  (ctor [] (set self/handle (open_handle)) " &
    "           (set self/backend \"demo\"))) " &
    "(type UntypedWrapperLike ^repr native_wrapper " &
    "  ^props {^handle Any ^backend Str}) " &
    "(type PlainLike ^props {^handle Any ^backend Str})"), wrapperScope)
  let wrapperType = run(compileSource("WrapperLike"), wrapperScope)
  let untypedWrapperType = run(compileSource("UntypedWrapperLike"), wrapperScope)

  var nativeRecord {.volatile.} = BenchNativeRecord(value: 42)
  let nativeRecordPtr = addr nativeRecord
  # A hand-written inlined Nim load. This is a theoretical ceiling for
  # comparison, NOT the backend: it says nothing about what the C emitter
  # produced. `typed_native.generated_c_field_load` below is the real gate.
  bench("typed_native.inline_nim_ceiling", 20_000_000, i):
    checksum = checksum + benchTypedNativeLoad(nativeRecordPtr) +
      int64(i and 1)
  benchGeneratedCFieldLoad(20_000_000)

  wrapperScope.define("native_value",
    newNativeFn("native_value", benchWrapperNativeGetter))
  wrapperScope.define("bench_wrapper", newNativeWrapper(untypedWrapperType,
    {"handle": newCPtr(nativeRecordPtr, newSym("BenchNativeRecord")),
     "backend": newStr("bench")}))
  let wrapperGetterChunk = compileSource("(native_value bench_wrapper)")
  bench("typed_native.dynamic_wrapper_getter", 500_000, i):
    let value = run(wrapperGetterChunk, wrapperScope)
    checksum = checksum + value.intVal + int64(i and 1)

  bench("vm.native_wrapper.handle_alloc", 250_000, i):
    let h = newCOwnedPtr(cast[pointer](0xB10B), benchReleaseHandle,
                         newSym("Blob"))
    checksum = checksum + int64(h.cPtrOwned)

  bench("vm.native_wrapper.factory_construct_untyped", 250_000, i):
    let v = newNativeWrapper(untypedWrapperType,
      {"handle": newCOwnedPtr(cast[pointer](0xB10B), benchReleaseHandle,
                              newSym("Blob")),
       "backend": newStr("demo")})
    checksum = checksum + int64(v.props.len)

  bench("vm.native_wrapper.factory_construct", 250_000, i):
    let v = newNativeWrapper(wrapperType,
      {"handle": newCOwnedPtr(cast[pointer](0xB10B), benchReleaseHandle,
                              newSym("Blob")),
       "backend": newStr("demo")})
    checksum = checksum + int64(v.props.len)

  let wrapperNewChunk = compileSource("(new WrapperLike)")
  bench("vm.native_wrapper.ctor_construct", 250_000, i):
    let v = run(wrapperNewChunk, wrapperScope)
    checksum = checksum + int64(v.props.len)

  let plainNewChunk = compileSource("(PlainLike ^handle \"h\" ^backend \"demo\")")
  bench("vm.native_wrapper.plain_direct_construct", 250_000, i):
    let v = run(plainNewChunk, wrapperScope)
    checksum = checksum + int64(v.props.len)

  wrapperScope.define("wrapper", run(wrapperNewChunk, wrapperScope))
  let wrapperFieldChunk = compileSource("wrapper/backend")
  bench("vm.native_wrapper.field_read", 500_000, i):
    let v = run(wrapperFieldChunk, wrapperScope)
    checksum = checksum + int64(v.strVal.len)

  let sqliteScope = newGlobalScope()
  discard run(compileSource(
    "(import $db/sqlite [open Db]) " &
    "(var sqlite_conn (open \":memory:\"))"), sqliteScope)
  let sqliteQueryChunk = compileSource(
    "(sqlite_conn ~ Db:query \"select 1 as value\")")
  # Named for what it measures: the interpreted managed-wrapper path through
  # $db/sqlite. It exercises none of the typed_native C backend, and the old
  # `typed_native.` prefix implied otherwise — the proposal's §10 question is
  # whether foreign work dominates, and this row is the "dominated by foreign
  # work" reference point, not a compiled-code measurement.
  bench("vm.native_wrapper.sqlite_query", 2_000, i):
    let rows = run(sqliteQueryChunk, sqliteScope)
    checksum = checksum + rows.listItems[0].mapEntries["value"].intVal +
      int64(i and 1)
  discard run(compileSource("(sqlite_conn ~ Db:close)"), sqliteScope)

  let assocScope = newGlobalScope()
  assocScope.define("user", run(compileSource("{^name \"Ada\" ^age 37}"), assocScope))
  let assocChunk = compileSource("($assoc_in user /age 38)")
  bench("vm.assoc_in.compiled_chunk", 250_000, i):
    let v = run(assocChunk, assocScope)
    checksum = checksum + v.mapEntries["age"].intVal

  # `match` arm selection. The four targets cover both matcher paths — a typed
  # instance reads node fields directly, the literal/list/map cases read the
  # node projection — and every arm but the last is a *failed* head comparison,
  # which is the cost an added arm actually imposes.
  let matchScope = newGlobalScope()
  discard run(compileSource(
    "(type Task ^props {^id Int}) " &
    "(fn pick [v] " &
    "  (match v " &
    "    (when (Task ^id id) id) " &
    "    (when (Int n) n) " &
    "    (when (List a b) a) " &
    "    (when (Map ^k x) x) " &
    "    (else 0)))"), matchScope)
  let matchChunk = compileSource(
    "(+ (pick (Task ^id 1)) (pick 2) (pick [3 9]) (pick {^k 4}))")
  bench("vm.match_arms.compiled_chunk", 100_000, i):
    let v = run(matchChunk, matchScope)
    checksum = checksum + v.intVal

  # What an added arm costs when it does *not* fire. A cell's canonical head
  # (design §1.3) matches none of `pick`'s arms, so every arm is a failed head
  # comparison and the arm count is the only variable — this is the half of
  # `match` that stays behaviour-identical across changes to what the arms
  # accept, and so the half a before/after comparison can actually read.
  let matchMissChunk = compileSource("(pick ($cell 1))")
  bench("vm.match_fallthrough.compiled_chunk", 200_000, i):
    let v = run(matchMissChunk, matchScope)
    checksum = checksum + v.intVal + 1

  # The scalar hot path (design §1.3/§8): `(Int n)` on a fixnum matches the
  # canonical body in place. This is the arm a hot numeric loop pays per
  # iteration; everything above the ordinary bind is projection machinery,
  # and the projection must not allocate. `vm.match_bind` is the floor — a
  # plain symbol bind, no node pattern at all — so the *delta* of the two
  # benches in the same run isolates the projection cost from process noise.
  let scalarScope = newGlobalScope()
  discard run(compileSource(
    "(fn pick_int [v] (match v (when (Int n) n) (else 0)))"), scalarScope)
  let matchScalarChunk = compileSource("(pick_int 2)")
  bench("vm.match_scalar.compiled_chunk", 200_000, i):
    let v = run(matchScalarChunk, scalarScope)
    checksum = checksum + v.intVal + 1
  let bindScope = newGlobalScope()
  discard run(compileSource(
    "(fn pick_bind [v] (match v (when v2 v2) (else 0)))"), bindScope)
  let matchBindChunk = compileSource("(pick_bind 2)")
  bench("vm.match_bind.compiled_chunk", 200_000, i):
    let v = run(matchBindChunk, bindScope)
    checksum = checksum + v.intVal + 1

  # Application event bus (docs/events.md §17.3). Freeze and dispatch
  # are reported separately and deliberately: deep-freezing a freshly
  # constructed event is O(payload) and dominates publishing a small event to
  # few handlers, so a payload-size regression must not read as a dispatch
  # regression. `publish_frozen` isolates dispatch by republishing one
  # already-deep-frozen value; `publish_small` is the whole documented path.
  let eventScope = newGlobalScope()
  discard run(compileSource(
    "(ns bench " &
    "  (type Event ^is $event/Event) " &
    "  (type Placed ^is Event ^props {^order_id Str ^total F64})) " &
    "(var sink ($cell 0)) " &
    "(fn note [e] (sink ~ set (+ sink/~get 1))) " &
    "(var bus ($event/Bus)) " &
    "(bus ~ subscribe bench/Placed note) " &
    "(var one (bench/Placed ^order_id \"o1\" ^total 1.5)) " &
    "(var frozen ($freeze one)) " &
    "(var wide ($event/Bus)) " &
    "(fn a [e] 1) (fn b [e] 2) (fn c [e] 3) (fn d [e] 4) " &
    "(wide ~ subscribe bench/Event a) (wide ~ subscribe bench/Placed b) " &
    "(wide ~ subscribe ($event/exact bench/Placed) c) " &
    "(wide ~ subscribe $event/Event d) " &
    # Declared in the same setup chunk: a slot-compiled chunk owns its scope's
    # local layout, so a second chunk that declares new locals cannot share it.
    "(type Unrelated ^is $event/Event) " &
    "(var miss ($freeze (Unrelated)))"), eventScope)

  let publishSmallChunk = compileSource(
    "(bus ~ publish (bench/Placed ^order_id \"o1\" ^total 1.5))")
  bench("event.publish_small.one_subscriber", 200_000, i):
    let r = run(publishSmallChunk, eventScope)
    checksum = checksum + r.props["delivered"].intVal

  let publishFrozenChunk = compileSource("(bus ~ publish frozen)")
  bench("event.publish_frozen.one_subscriber", 200_000, i):
    let r = run(publishFrozenChunk, eventScope)
    checksum = checksum + r.props["delivered"].intVal

  let publishFanoutChunk = compileSource("(wide ~ publish frozen)")
  bench("event.publish_frozen.four_subscribers", 200_000, i):
    let r = run(publishFanoutChunk, eventScope)
    checksum = checksum + r.props["delivered"].intVal

  # An unmatched publication is what "scans no unrelated subscriptions" costs:
  # the bus holds four subscriptions and none of them can match.
  let publishMissChunk = compileSource("(wide ~ publish miss)")
  bench("event.publish_frozen.no_match", 200_000, i):
    let r = run(publishMissChunk, eventScope)
    checksum = checksum + r.props["matched"].intVal + 1

  let subscribeChunk = compileSource(
    "((bus ~ subscribe bench/Placed a) ~ cancel)")
  bench("event.subscribe_cancel", 100_000, i):
    let v = run(subscribeChunk, eventScope)
    checksum = checksum + (if v.isTruthy: 1 else: 0)

  let left = read("(user ^name \"Ada\" 1 2 3)")
  let right = read("(user ^name \"Ada\" 1 2 3)")
  bench("equality.structural_node", 500_000, i):
    if equal(left, right):
      checksum = checksum + 1

main()
