import gene/[types, compiler, vm, printer]
import std/[strutils, unittest]

proc fastLoopOutcome(source: string, enabled: bool): string =
  ## What `source` prints, or the message it fails with, with `fastLoop` on or
  ## off (vm.nim `fastLoopEnabled`).
  let saved = fastLoopEnabled
  fastLoopEnabled = enabled
  try:
    result = run(compileSource(source), newGlobalScope()).print()
  except GeneError as error:
    result = "error: " & error.msg
  finally:
    fastLoopEnabled = saved

const fastLoopPrograms = [
  # The while and repeat kernels.
  """(fn f [n] (var i 0) (var total 0)
       (while (< i n) (set total (+ total (// (* i 7) 13))) (set i (+ i 1)))
       total)
     (f 1000)""",
  """(fn f [n] (var total 0) (repeat i in n (set total (+ total i))) total)
     (f 1000)""",
  # Small Ints that leave the small range: the fast path hands them back.
  """(fn f [] (var x 1) (repeat i in 70 (set x (+ x x))) x) (f)""",
  """(fn f [] (var x 0) (repeat i in 5 (set x (- x 140737488355327))) x) (f)""",
  """(fn f [] (var x 3) (repeat i in 30 (set x (* x 7))) x) (f)""",
  # Floats, and a division by zero inside the loop.
  """(fn f [] (var t 0.5) (repeat i in 10 (set t (+ t 1))) t) (f)""",
  """(fn f [] (var r 0) (repeat i in 3 (set r (// 7 (- 1 i)))) r) (f)""",
  """(fn f [] (var r 0) (repeat i in 3 (set r (/ 7 (- 1 i)))) r) (f)""",
  # Truthiness of nil and Bools, `!`, `&&` and `||`.
  """(fn f [] (var c 0) (var flag nil)
       (repeat i in 6 (if flag (set c (+ c 1))) (set flag (! flag)))
       c)
     (f)""",
  """(fn f [] (var k 0)
       (repeat i in 8
         (if (&& (> i 1) (< i 5)) (set k (+ k i)))
         (if (|| (== i 0) (== i 7)) (set k (+ k 100))))
       k)
     (f)""",
  # A typed local and a typed function.
  """(fn f [] (var x : Int 0) (repeat i in 5 (set x (+ x i))) x) (f)""",
  """(fn f [n : Int] : Int (var t 0) (var i 0)
       (while (< i n) (set t (+ t (* i 3))) (set i (+ i 1)))
       t)
     (f 100)""",
  # Comparisons with constants, negative remainders, == and !=.
  """(fn f [] (var c 0) (var i -10)
       (while (< i 10)
         (if (>= i 5) (set c (+ c (// i 3))))
         (if (<= i -5) (set c (- c (// i 4))))
         (set i (+ i 1)))
       c)
     (f)""",
  """(fn f [] (var c 0)
       (repeat i in 10
         (if (== (// i 2) 0) (set c (+ c 1)))
         (if (!= i 3) (set c (+ c 10))))
       c)
     (f)""",
  # Nested loops, an outer variable, `break`, and a loop at module level.
  """(fn f [] (var t 0) (repeat i in 10 (repeat j in 10 (set t (+ t (* i j))))) t)
     (f)""",
  """(var outer 0) (fn f [] (repeat i in 5 (set outer (+ outer i))) outer) (f)""",
  """(fn f [] (var i 0) (while true (if (> i 5) (break)) (set i (+ i 1))) i) (f)""",
  """(var total 0) (repeat i in 100 (set total (+ total i))) total""",
]

suite "fastLoop":
  test "every program gives the same result with fastLoop on and off":
    for source in fastLoopPrograms:
      checkpoint source
      check fastLoopOutcome(source, true) == fastLoopOutcome(source, false)

  when defined(geneFastLoopTests):
    test "the kernels run in fastLoop when it is on, and not when it is off":
      var before = fastLoopRuns
      discard fastLoopOutcome(fastLoopPrograms[0], true)
      discard fastLoopOutcome(fastLoopPrograms[1], true)
      check fastLoopRuns >= before + 2
      before = fastLoopRuns
      discard fastLoopOutcome(fastLoopPrograms[0], false)
      check fastLoopRuns == before

  test "the kernels give their known results":
    check fastLoopOutcome(fastLoopPrograms[1], true) == "499500"
    check fastLoopOutcome(fastLoopPrograms[2], true) == "1180591620717411303424"

  test "a loop under a budget still stops at its deadline":
    let outcome = fastLoopOutcome("""
      (let run ($runtime/bind_call ^policy {^timeout_ms 50}
        (fn [] (var i 0) (while true (set i (+ i 1)))) []))
      (run)
    """, true)
    check outcome.startsWith("error: ")
    check "timeout" in outcome.toLowerAscii
