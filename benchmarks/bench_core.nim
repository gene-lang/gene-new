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

  let namedScope = newGlobalScope()
  namedScope.define("pick", run(compileSource("(fn [x ^scale] (+ x scale))"), namedScope))
  let namedChunk = compileSource("(pick ^scale 4 6)")
  bench("vm.named_call.compiled_chunk", 500_000, i):
    let v = run(namedChunk, namedScope)
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

  let left = read("(user ^name \"Ada\" 1 2 3)")
  let right = read("(user ^name \"Ada\" 1 2 3)")
  bench("equality.structural_node", 500_000, i):
    if equal(left, right):
      checksum = checksum + 1

main()
