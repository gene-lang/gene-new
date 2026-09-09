## Pipeline construction, demand, and retention measurements.
## Run: nim c -r -d:release -d:nimAllocStats -d:geneGeneratorStats --path:src benchmarks/bench_pipeline.nim
## Allocations include call frames and user callback work, not just adapters.

import std/[monotimes, strutils, tables, times]
import gene/[compiler, types, vm]

when not defined(nimAllocStats):
  {.error: "bench_pipeline requires -d:nimAllocStats".}

var sourcePulls = 0

proc measuredSource(stream: Value): StreamPullResult {.nimcall.} =
  inc sourcePulls
  let remaining = stream.streamRemaining
  if remaining == 0:
    return StreamPullResult(has: false, item: NIL)
  stream.setStreamRemaining(remaining - 1)
  StreamPullResult(has: true, item: newInt(1001 - remaining))

proc allocated(stats: AllocStats): int =
  for name, value in fieldPairs(stats):
    when name == "allocCount":
      result = value

proc measure(name, expression: string, expectedChecksum: int64,
             expectedItems = 1000, expectedPulls = 1001, collect = false,
             lookahead = false, consume = true) =
  let scope = newGlobalScope()
  # Independent root chunks share this scope; named bindings avoid replacing
  # one root chunk's local-slot layout with another's.
  discard run(compileSource("""
    (fn step [x] (+ x 1))
    (var selected step)
    (fn ^^generator running_total [source]
      (var total 0)
      (for value in source
        (set total (+ total value))
        (yield total)))
    (fn numberer []
      (let count ($cell 0))
      (fn [value] (count .update (fn [n] (+ n 1))) (+ value (count .get))))
    (type A ^props {^n Int} (message value [] self/n))
    (type B ^props {^n Int} (message value [] self/n))
  """, useLocalSlots = false), scope)
  let construction = compileSource(expression, useLocalSlots = false)
  let collector = compileSource("(pending -> $into [])", useLocalSlots = false)
  const samples = 20
  var constructionAllocations, demandAllocations, items, pulls: int
  var elapsedNs: int64
  var retainedBytes: int
  # Warm call-scope pools before measuring retained memory.
  for sample in 0 ..< samples + 2:
    GC_fullCollect()
    let beforeMemory = getOccupiedMem()
    sourcePulls = 0
    var source = newLazyStream(NIL, measuredSource, remaining = 1000)
    scope.vars["source"] = source
    let beforeConstruction = getAllocStats()
    let started = getMonoTime()
    var pending = run(construction, scope)
    let afterConstruction = getAllocStats()
    var count = 0
    var checksum = 0'i64
    var output = NIL
    if consume:
      if collect:
        scope.vars["pending"] = pending
        output = run(collector, scope)
        count = output.listItems.len
        for item in output.listItems: checksum += item.intVal
      else:
        while pending.streamHasNext:
          if lookahead:
            discard pending.streamHasNext
            discard pending.streamPeek
            discard pending.streamPeek
          checksum += pending.streamNext.intVal
          inc count
    let finished = getMonoTime()
    let afterDemand = getAllocStats()
    doAssert count == expectedItems, name & ": wrong emitted count"
    doAssert sourcePulls == expectedPulls, name & ": wrong source demand"
    doAssert checksum == expectedChecksum, name & ": wrong result"
    pending.closeStream()
    source.closeStream()
    scope.vars["pending"] = NIL
    scope.vars["source"] = NIL
    pending = NIL
    output = NIL
    source = NIL
    GC_fullCollect()
    if sample >= 2:
      constructionAllocations += allocated(afterConstruction - beforeConstruction)
      demandAllocations += allocated(afterDemand - afterConstruction)
      elapsedNs += inNanoseconds(finished - started)
      items += count
      pulls += sourcePulls
      retainedBytes += getOccupiedMem() - beforeMemory
  let seconds = float(elapsedNs) / 1_000_000_000.0
  echo name,
    " | pipelines/s=", formatFloat(float(samples) / seconds, ffDecimal, 1),
    " | construction allocs/pipeline=",
      formatFloat(float(constructionAllocations) / samples, ffDecimal, 1),
    " | demand allocs/emitted item=",
      (if items == 0: "n/a"
       else: formatFloat(float(demandAllocations) / float(items), ffDecimal, 2)),
    " | source pulls/pipeline=", float(pulls) / samples,
    " | emitted items/pipeline=", float(items) / samples,
    " | retained bytes after close/pipeline=", float(retainedBytes) / samples

measure("construct_close", "(source => step)", 0,
        expectedItems = 0, expectedPulls = 0, consume = false)
measure("one_map", "(source => step)", 501500)
measure("many_maps", "(source => step => step => step => step => step => step)", 506500)
measure("map_take_collect", "(source => step -> $take 10)", 65,
        expectedItems = 10, expectedPulls = 10, collect = true)
measure("early_take", "(source -> $take 10 => step)", 65,
        expectedItems = 10, expectedPulls = 10)
measure("filter_map_void_heavy", "(source -> $filter_map (fn [x] (if (< x 901) void x)))", 95050,
        expectedItems = 100)
measure("stateful_factory", "(source => (numberer))", 1001000)
measure("custom_generator", "(source => step -> running_total => step)", 167668500)
measure("dynamic_callable", "(source => selected)", 501500)
measure("heterogeneous_sends", """
  (source => (fn [x] (if (< x 501) (A ^n x) (B ^n x))) => _ .value)
""", 500500)
measure("repeated_lookahead", "(source => step)", 501500, lookahead = true)

proc measureGenerator(name: string, limit, consume: int, lookahead = false) =
  let scope = newGlobalScope()
  discard run(compileSource("""
    (let closed ($cell 0))
    (fn ^^generator count_to [limit : Int] : (Stream Int Never)
      (try
        (var n 0)
        (while (< n limit) (yield n) (set n (+ n 1)))
        ensure (closed .update (fn [n] (+ n 1)))))
  """, useLocalSlots = false), scope)
  let creation = compileSource("(count_to " & $limit & ")", useLocalSlots = false)
  const samples = 20
  var createNs, firstNs, iterateNs, closeNs, continuations: int64
  var createAllocs, firstAllocs, heldBytes, retainedBytes: int
  for sample in 0 ..< samples + 2:
    GC_fullCollect()
    let memoryBefore = getOccupiedMem()
    let closesBefore = scope.vars["closed"].cellValue.intVal
    let allocationsBefore = getAllocStats()
    when defined(geneGeneratorStats):
      let framesBefore = generatorContinuationAllocations
    let started = getMonoTime()
    var stream = run(creation, scope)
    let created = getMonoTime()
    let allocationsCreated = getAllocStats()
    var checksum = 0'i64
    if consume > 0:
      checksum += stream.streamNext.intVal
    let first = getMonoTime()
    let allocationsFirst = getAllocStats()
    for i in 1 ..< consume:
      if lookahead:
        doAssert stream.streamHasNext
        doAssert stream.streamPeek.intVal == int64(i)
        doAssert stream.streamPeek.intVal == int64(i)
      checksum += stream.streamNext.intVal
    doAssert checksum == int64(consume) * int64(consume - 1) div 2
    if consume == limit:
      doAssert not stream.streamHasNext
    let iterated = getMonoTime()
    let held = getOccupiedMem() - memoryBefore
    stream.closeStream()
    let closed = getMonoTime()
    doAssert scope.vars["closed"].cellValue.intVal == closesBefore +
      (if consume > 0: 1 else: 0), name & ": cleanup count"
    stream = NIL
    GC_fullCollect()
    if sample >= 2:
      createNs += inNanoseconds(created - started)
      firstNs += inNanoseconds(first - created)
      iterateNs += inNanoseconds(iterated - first)
      closeNs += inNanoseconds(closed - iterated)
      createAllocs += allocated(allocationsCreated - allocationsBefore)
      firstAllocs += allocated(allocationsFirst - allocationsCreated)
      heldBytes += held
      retainedBytes += getOccupiedMem() - memoryBefore
      when defined(geneGeneratorStats):
        continuations += generatorContinuationAllocations - framesBefore
  echo "generator_", name,
    " | create ns=", createNs div samples,
    " | first pull ns=", (if consume > 0: $(firstNs div samples) else: "n/a"),
    " | remaining iteration ns=", iterateNs div samples,
    " | close ns=", closeNs div samples,
    " | create allocations=", createAllocs div samples,
    " | first pull allocations=", firstAllocs div samples,
    " | continuations=", (when defined(geneGeneratorStats): $(continuations div samples)
                          else: "n/a (enable geneGeneratorStats)"),
    " | held bytes=", heldBytes div samples,
    " | retained bytes after close=", retainedBytes div samples

measureGenerator("create_close", 10000, 0)
measureGenerator("first_pull", 10000, 1)
measureGenerator("long_iteration", 10000, 10000)
measureGenerator("lookahead", 10000, 10000, lookahead = true)
measureGenerator("early_cleanup", 10000, 10)
