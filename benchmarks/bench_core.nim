## Core microbenchmarks for performance-sensitive changes.
##
## These benchmarks are intentionally dependency-free and print comparable
## numbers. They do not enforce thresholds; compare output before/after changes
## and explain any regression in the final report.
##
## Run:
##   nimble perf

import gene/[compiler, equality, printer, reader, types, vm]
import std/[monotimes, strutils, tables, times]

var positiveZeroInput {.volatile.}: float64 = 0.0

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
    var props = initOrderedTable[string, Value]()
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

  let simpleChunk = compileSource(simpleProgram)
  let simpleScope = newGlobalScope()
  bench("vm.simple_call.compiled_chunk", 500_000, i):
    let v = run(simpleChunk, simpleScope)
    checksum = checksum + v.intVal

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
    "(type Box ^props {^x Int}) " &
    "(impl ToInt for Box (message to_int [self] : Int self/x)) " &
    "(var box (Box ^x 10))"), protocolScope)
  # Message names are not lexical bindings (docs/core.md §1); the hot
  # dispatch path is now the send form, resolved receiver-first (§9.1).
  let protocolChunk = compileSource("(box ~ to_int)")
  bench("vm.protocol_message.compiled_chunk", 500_000, i):
    let v = run(protocolChunk, protocolScope)
    checksum = checksum + v.intVal
  let qualifiedChunk = compileSource("(box ~ ToInt/to_int)")
  bench("vm.protocol_message.qualified.compiled_chunk", 500_000, i):
    let v = run(qualifiedChunk, protocolScope)
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
  let assocChunk = compileSource("(assoc-in user /age 38)")
  bench("vm.assoc_in.compiled_chunk", 250_000, i):
    let v = run(assocChunk, assocScope)
    checksum = checksum + v.mapEntries["age"].intVal

  let left = read("(user ^name \"Ada\" 1 2 3)")
  let right = read("(user ^name \"Ada\" 1 2 3)")
  bench("equality.structural_node", 500_000, i):
    if equal(left, right):
      checksum = checksum + 1

main()
