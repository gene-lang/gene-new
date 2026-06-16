## Core microbenchmarks for performance-sensitive changes.
##
## These benchmarks are intentionally dependency-free and print comparable
## numbers. They do not enforce thresholds; compare output before/after changes
## and explain any regression in the final report.
##
## Run:
##   nimble perf

import gene/[equality, printer, reader, types]
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

  let left = read("(user ^name \"Ada\" 1 2 3)")
  let right = read("(user ^name \"Ada\" 1 2 3)")
  bench("equality.structural_node", 500_000, i):
    if equal(left, right):
      checksum = checksum + 1

main()
