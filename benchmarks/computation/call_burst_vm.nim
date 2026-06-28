## Function call burst benchmark for the current bytecode VM.
##
## The benchmark compiles each Gene program once, then measures VM execution.

import gene/[compiler, vm]
import std/[os, strformat, strutils, times]

proc parsePositiveInt(raw: string, label: string): int =
  try:
    result = parseInt(raw)
  except ValueError:
    quit("Error: " & label & " must be an integer", 1)
  if result <= 0:
    quit("Error: " & label & " must be positive", 1)

proc callBlock(callLine: string, callsPerRepeat: int): string =
  var lines: seq[string] = @[]
  for _ in 0 ..< callsPerRepeat:
    lines.add("  " & callLine)
  lines.join("\n")

proc runBenchmark(source, label: string, repeats, callsPerRepeat: int) =
  let chunk = compileSource(source)
  let scope = newGlobalScope()

  let start = cpuTime()
  discard run(chunk, scope)
  let duration = cpuTime() - start

  let totalCalls = repeats * callsPerRepeat
  let callsPerSecond =
    if duration > 0.0: totalCalls.float / duration
    else: 0.0

  echo fmt"{label}:"
  echo fmt"  repeat count: {repeats}"
  echo fmt"  calls per repeat: {callsPerRepeat}"
  echo fmt"  total calls: {totalCalls}"
  echo fmt"  duration: {duration:.6f} seconds"
  echo fmt"  calls/sec: {int64(callsPerSecond + 0.5)}"
  echo ""

proc loopProgram(fnDef, callLine: string, repeats, callsPerRepeat: int): string =
  fmt"""
{fnDef}
(var i 0)
(while (< i {repeats})
{callBlock(callLine, callsPerRepeat)}
  (set i (+ i 1)))
"""

proc main() =
  var repeats = 10_000
  var callsPerRepeat = 1_000

  let args = commandLineParams()
  if args.len > 0:
    repeats = parsePositiveInt(args[0], "repeat count")
  if args.len > 1:
    callsPerRepeat = parsePositiveInt(args[1], "calls per repeat")

  runBenchmark(
    loopProgram("(var call_once (fn [] nil))", "(call_once)",
                repeats, callsPerRepeat),
    "zero-arg function call",
    repeats,
    callsPerRepeat)

  runBenchmark(
    loopProgram("(var call_once (fn [x] x))", "(call_once 1)",
                repeats, callsPerRepeat),
    "one-arg function call",
    repeats,
    callsPerRepeat)

  runBenchmark(
    loopProgram("(var call_four (fn [a b c d] nil))",
                "(call_four 1 2 3 4)", repeats, callsPerRepeat),
    "four-arg function call",
    repeats,
    callsPerRepeat)

main()
