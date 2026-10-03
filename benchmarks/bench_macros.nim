## Compare macros with their equivalent marked expansions, excluding compilation.
## Like bench_core, this compiler/VM benchmark uses the host monotonic clock.
## Run: nim c -r -d:release --path:src benchmarks/bench_macros.nim

import gene/[compiler, printer, types, vm]
import std/[algorithm, monotimes, os, strutils, times]

type Sample = object
  name: string
  definition: string
  expansion: string
  iterations: int

initModuleContext(getCurrentDir())
discard newGlobalScope()

for sample in [
  Sample(name: "expression", iterations: 500_000,
    definition: "(macro advance [value] `(+ %value 1)) ",
    expansion: "(do ^^macro_result (+ i 1))"),
  Sample(name: "local_slots", iterations: 500_000,
    definition: "(macro advance [value] `(do (let delta 1) (+ %value delta))) ",
    expansion: "(do ^^macro_result (let delta 1) (+ i delta))"),
  Sample(name: "closure_scope", iterations: 50_000,
    definition: "(macro advance [value] `(do (var local %value) " &
      "(let get (fn [] local)) (+ (get) 1))) ",
    expansion: "(do ^^macro_result (var local i) " &
      "(let get (fn [] local)) (+ (get) 1))")
]:
  proc program(body: string): string =
    "(fn run [] (var total 0) (repeat i in " & $sample.iterations &
      " (set total (+ total " & body & "))) total) (run)"
  let macroCode = compileSource(sample.definition & program("(advance i)"))
  let directCode = compileSource(program(sample.expansion))
  let expected = int64(sample.iterations) * int64(sample.iterations + 1) div 2
  var macroTimes, directTimes: seq[float]
  for round in 0 ..< 7:
    # Alternate order to reduce warm-cache and scheduler bias. Round 0 is warmup.
    for variant in 0 ..< 2:
      let useMacro = ((round + variant) and 1) == 0
      let scope = newGlobalScope()
      let started = getMonoTime()
      let value = run(if useMacro: macroCode else: directCode, scope)
      let nanos = inNanoseconds(getMonoTime() - started)
      doAssert value.intVal == expected, sample.name & ": " & value.print()
      if round > 0:
        if useMacro: macroTimes.add float(nanos) / 1_000_000.0
        else: directTimes.add float(nanos) / 1_000_000.0
  macroTimes.sort()
  directTimes.sort()
  let macroMs = (macroTimes[2] + macroTimes[3]) / 2
  let directMs = (directTimes[2] + directTimes[3]) / 2
  echo sample.name, ": iterations=", sample.iterations,
    " macro_ms=", formatFloat(macroMs, ffDecimal, 3),
    " expanded_ms=", formatFloat(directMs, ffDecimal, 3),
    " ratio=", formatFloat(macroMs / directMs, ffDecimal, 3),
    " checksum=", expected
