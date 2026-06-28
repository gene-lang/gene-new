## Recursive Fibonacci benchmarks for the current bytecode VM.
##
## The benchmark compiles each Gene program once, then measures VM execution.

import gene/[compiler, printer, types, vm]
import std/[os, strformat, strutils, times]

proc fibNumber(n: int): int64 =
  var a = 0'i64
  var b = 1'i64
  for _ in 0 ..< n:
    let next = a + b
    a = b
    b = next
  a

proc fibCallCount(n: int): int64 =
  ## Naive recursive fib(n) makes 2 * fib(n + 1) - 1 calls.
  2'i64 * fibNumber(n + 1) - 1'i64

proc parseFibInput(): int =
  result = 28
  let args = commandLineParams()
  if args.len > 0:
    try:
      result = parseInt(args[0])
    except ValueError:
      quit("Error: n must be an integer", 1)
  if result < 0:
    quit("Error: n must be non-negative", 1)

proc fibSource(n: int, typed: bool): string =
  if typed:
    return fmt"""
(var fib (fn [n : Int] : Int
  (if (< n 2)
    n
    (+ (fib (- n 1)) (fib (- n 2))))))
(fib {n})
"""
  fmt"""
(var fib (fn [n]
  (if (< n 2)
    n
    (+ (fib (- n 1)) (fib (- n 2))))))
(fib {n})
"""

proc runBenchmark(source, label: string, n: int) =
  let chunk = compileSource(source)
  let scope = newGlobalScope()

  let start = cpuTime()
  let result = run(chunk, scope)
  let duration = cpuTime() - start

  let intResult =
    case result.kind
    of vkInt:
      result.intVal
    of vkFloat:
      result.floatVal.int64
    else:
      echo "Unexpected result kind: ", result.kind, "; value: ", result.print()
      0'i64

  echo fmt"{label}:"
  echo fmt"  result: fib({n}) = {intResult}"
  echo fmt"  duration: {duration:.6f} seconds"
  echo "  mode: bytecode-vm"

  if duration > 0.0:
    let calls = fibCallCount(n)
    let callsPerSecond = calls.float / duration
    let roundedCallsPerSecond = int64(callsPerSecond + 0.5)
    echo fmt"  fib calls: {calls}"
    echo fmt"  calls/sec: {roundedCallsPerSecond}"
  echo ""

proc main() =
  let n = parseFibInput()
  runBenchmark(fibSource(n, typed = false), "untyped recursive fib", n)
  runBenchmark(fibSource(n, typed = true), "typed recursive fib", n)

main()
