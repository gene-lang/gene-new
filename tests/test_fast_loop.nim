import gene/[types, compiler, vm, printer, gir]
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
  # Floats, mixed with Ints, and Ints past the small range through constants.
  """(fn f [] (var t 0.5) (repeat i in 10 (set t (+ t 1))) t) (f)""",
  """(fn f [n] (var x 0.0) (repeat i in n (set x (+ (* x 0.999) 1.5))) x)
     (f 1000)""",
  """(fn f [] (var x 0.0) (var i 0)
       (while (< x 10.5) (set x (+ x 0.75)) (set i (+ i 1)))
       [x i])
     (f)""",
  """(fn f [] (var x 1.5) (var y 7) (var c 0)
       (while (> y x) (set y (- y 1)) (set c (+ c 1)))
       [x y c])
     (f)""",
  """(fn f [] (var x 2) (repeat i in 40 (set x (* x 3))) x) (f)""",
  """(fn f [] (var x 2.5) (var c 0)
       (repeat i in 20 (if (>= x 100.0) (set c (+ c 1))) (set x (* x 1.5)))
       [x c])
     (f)""",
  # `for` over a range: steps, an empty range, a body with its own binding,
  # a List, and a range that ends at the top of the Int range.
  """(fn f [n] (var total 0) (for i in ($range 0 n) (set total (+ total i))) total)
     (f 1000)""",
  """(fn f [] (var t 0) (for i in ($range 10 0 -3) (set t (+ (* t 10) i))) t) (f)""",
  """(fn f [] (var t 0) (for i in ($range 5 5) (set t (+ t 1))) t) (f)""",
  """(fn f [] (var t 0) (for i in ($range 0 6) (let d (* i 2)) (set t (+ t d))) t)
     (f)""",
  """(fn f [] (var t 0) (for i in [3 4 5] (set t (+ t i))) t) (f)""",
  # Hand the current item back to runLoop after earlier items ran in fastLoop.
  """(fn f [xs] (var t 0) (for x in xs (set t (+ t x))) t)
     [(f []) (f #[1 2 3]) (f [1 2 3.5 4]) (f [1 2 9223372036854775807 4])]""",
  """(fn f [] (var c 0)
       (for i in ($range 9223372036854775800 9223372036854775807)
         (set c (+ c 1)))
       c)
     (f)""",
  # A division by zero inside the loop.
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
  # Calls to small-Int closures from a loop: a callee in the parent scope, in
  # the loop's own scope, one reading an outer local, a callee that leaves the
  # small range or raises mid-loop, and one that is not a leaf at all.
  """(fn add1 [x] (+ x 1))
     (fn f [n] (var t 0) (repeat i in n (set t (add1 t))) t)
     (f 1000)""",
  """(fn add1 [x] (+ x 1)) (var t 0) (repeat i in 100 (set t (add1 t))) t""",
  """(var k 5) (fn addk [x] (+ x k))
     (fn f [n] (var t 0) (repeat i in n (set t (addk t))) t)
     (f 100)""",
  """(fn dbl [x] (+ x x))
     (fn f [] (var t 1) (repeat i in 70 (set t (dbl t))) t)
     (f)""",
  """(fn inv [x] (// 7 x))
     (fn f [] (var t 0) (repeat i in 4 (set t (+ t (inv (- 2 i))))) t)
     (f)""",
  """(fn bump [x] (if (> x 3) (return 10)) (+ x 1))
     (fn f [] (var t 0) (while (< t 10) (set t (bump t))) t)
     (f)""",
  """(fn id [x] x)
     (fn f [n] (var t 0) (var i 0) (while (< i n) (set t (+ t (id i))) (set i (+ i 1))) t)
     (f 50)""",
  # A float argument, a callee that is rebound mid-loop, and a nested loop.
  """(fn add1 [x] (+ x 1))
     (fn f [] (var t 0) (repeat i in 5 (set t (add1 (+ t 0.5)))) t)
     (f)""",
  """(fn a [x] (+ x 1)) (fn b [x] (+ x 100))
     (var g a) (var t 0)
     (repeat i in 6 (if (== i 3) (set g b)) (set t (g t)))
     t""",
  """(fn add1 [x] (+ x 1))
     (fn f [] (var t 0) (repeat i in 10 (repeat j in 10 (set t (add1 t)))) t)
     (f)""",
  """(fn mix [a b] (let c (* a 2)) (+ c b))
     (fn f [n] (var t 0) (repeat i in n (set t (mix i t))) t) (f 50)""",
  """(fn mix [a b] (let c (* a 2)) (+ c b))
     (fn f [n] (var t 0) (repeat i in n (set t (mix i t))) t) (f 5000)""",
  # A callee held two scopes up, one passed in and one held in a list.
  """(fn add1 [x] (+ x 1))
     (fn outer [] (fn inner [n] (var t 0) (repeat i in n (set t (add1 t))) t) (inner 30))
     (outer)""",
  """(fn add1 [x] (+ x 1))
     (fn f [g n] (var t 0) (repeat i in n (set t (g t))) t)
     [(f add1 40) (f (fn [x] (* x 2)) 3)]""",
  """(fn add1 [x] (+ x 1)) (fn sub1 [x] (- x 1))
     (fn f [fs n] (var t 0) (repeat i in n (set t ((fs/0) t)) (set t ((fs/1) t))) t)
     (f [(fn [] add1) (fn [] sub1)] 20)""",
  """(fn add3 [a b c] (+ a (+ b c)))
     (fn f [n] (var t 0) (repeat i in n (set t (add3 t i 1))) t) (f 40)""",
  """(fn zero [] 0) (fn f [n] (var t 0) (repeat i in n (set t (+ t (zero)))) t)
     (f 40)""",
  # The general call: three and four arguments, typed ones, a named argument.
  """(fn u3 [a b c] (+ a (+ b c)))
     (fn f [n] (var t 0) (repeat i in n (set t (+ t (u3 i 1 2)))) t) (f 60)""",
  """(fn u4 [a b c d] (let e (* a d)) (+ e (+ b c)))
     (fn f [n] (var t 0) (repeat i in n (set t (+ t (u4 i 1 2 3)))) t) (f 60)""",
  """(fn t3 [a : Int b : Int c : Int] : Int (+ a (+ b c)))
     (fn f [n] (var t 0) (repeat i in n (set t (+ t (t3 i 1 2)))) t) (f 60)""",
  """(fn t3 [a : Int b : Int c : Int] : Int (+ a (+ b c)))
     (fn f [] (var t 0) (repeat i in 3 (set t (+ t (t3 i 1.5 2)))) t) (f)""",
  """(fn k3 [a b c ^k] (+ a (+ b (+ c k))))
     (fn f [n] (var t 0) (repeat i in n (set t (+ t (k3 i 1 2 ^k 7)))) t) (f 20)""",
  """(fn u3 [a b c] (+ a (+ b c)))
     (fn f [] (var t 0) (repeat i in 70 (set t (u3 t t 1))) t) (f)""",
  # Typed arithmetic compiled to a native op: add, subtract, multiply, an
  # overflowing add and multiply, a Float argument, a mismatched annotation.
  """(fn add [a : Int b : Int] : Int (+ a b))
     (fn f [n] (var t 0) (repeat i in n (set t (add t i))) t) (f 200)""",
  """(fn sub [a : Int b : Int] : Int (- a b))
     (fn f [n] (var t 0) (repeat i in n (set t (sub t i))) t) (f 200)""",
  """(fn mul [a : Int b : Int] : Int (* a b))
     (fn f [] (var t 3) (repeat i in 40 (set t (mul t 3))) t) (f)""",
  """(fn add [a : Int b : Int] : Int (+ a b))
     (fn f [] (var t 1) (repeat i in 60 (set t (add t t))) t) (f)""",
  """(fn add [a : Int b : Int] : Int (+ a b))
     (fn f [] (var t 0) (repeat i in 3 (set t (add t (if (== i 1) 1.5 else 2)))) t)
     (f)""",
  """(fn add [a : Float b : Float] : Float (+ a b))
     (fn f [] (var t 0.5) (repeat i in 5 (set t (add t 1.25))) t) (f)""",
  """(fn zero [] 7) (fn f [n] (var t 0) (repeat i in n (set t (+ t (zero)))) t)
     (f 100)""",
  """(fn pick [a b] (if (> a b) a else b))
     (fn f [n] (var t 0) (repeat i in n (set t (+ t (pick i 25)))) t) (f 50)""",
  """(fn big [x] (* x 1000000007))
     (fn f [] (var t 3) (repeat i in 8 (set t (big t))) t) (f)""",
  """(fn show [x] x) (fn f [] (var t nil) (repeat i in 3 (set t (show "s"))) t) (f)""",
  """(fn typed [x : Int] : Int (+ x 1))
     (fn f [n] (var t 0) (repeat i in n (set t (typed t))) t) (f 100)""",
  """(fn typed [x : Int] : Int (+ x 1))
     (fn f [] (var t 0) (repeat i in 3 (set t (typed (if (== i 1) 1.5 else t)))) t)
     (f)""",
  """(fn make [k] (fn [x] (+ x k)))
     (fn f [n] (var g (make 3)) (var t 0) (repeat i in n (set t (g t))) t)
     (f 100)""",
]

const forRangeKernel = """(fn f [n] (var total 0)
  (for i in ($range 0 n) (set total (+ total i))) total) (f 1000)"""

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
      discard fastLoopOutcome(forRangeKernel, true)
      check fastLoopRuns >= before + 3
      before = fastLoopRuns
      discard fastLoopOutcome(fastLoopPrograms[0], false)
      check fastLoopRuns == before

    test "calls run inside fastLoop, and a loop that cannot is demoted":
      # A scopeless leaf runs in place, without a frame.
      let leaf = """(fn add1 [x] (+ x 1))
        (fn f [n] (var t 0) (repeat i in n (set t (add1 t))) t) (f 1000)"""
      var runs = fastLoopRuns
      var inlined = fastLoopInlineCalls
      check fastLoopOutcome(leaf, true) == "1000"
      check fastLoopRuns == runs + 1           # one entry for the whole loop
      check fastLoopInlineCalls == inlined + 1000
      runs = fastLoopRuns
      inlined = fastLoopInlineCalls
      check fastLoopOutcome(leaf, false) == "1000"
      check fastLoopRuns == runs
      check fastLoopInlineCalls == inlined
      # Two arguments and a local of the callee's own.
      let two = """(fn mix [a b] (let c (* a 2)) (+ c b))
        (fn f [n] (var t 0) (repeat i in n (set t (mix i t))) t) (f 50)"""
      inlined = fastLoopInlineCalls
      check fastLoopOutcome(two, true) == fastLoopOutcome(two, false)
      check fastLoopInlineCalls >= inlined + 50
      # A closure over a captured Int is answered by trySmallIntClosure.
      let closure = """(fn make [k] (fn [x] (+ x k)))
        (fn f [n] (var g (make 3)) (var t 0) (repeat i in n (set t (g t))) t)
        (f 100)"""
      let attempts = smallIntClosureAttempts
      check fastLoopOutcome(closure, true) == "300"
      check smallIntClosureAttempts >= attempts + 100
      # `bump` branches and returns early, so no scopeless body: the first
      # entry misses, and the loop is not entered again.
      let miss = """(fn bump [x] (if (> x 3) (return 10)) (+ x 1))
        (fn f [] (var t 0) (while (< t 10) (set t (bump t))) t)
        [(f) (f) (f)]"""
      runs = fastLoopRuns
      check fastLoopOutcome(miss, true) == "[10 10 10]"
      check fastLoopRuns <= runs + 1

    test "mirrored loops complete slot writes in fastLoop":
      for source in [
        "(var total 0) (repeat i in 100 (set total (+ total i))) total",
        """(ns totals
             (var total 0)
             (repeat i in 100 (set total (+ total i))))
           totals/total"""
      ]:
        let before = fastLoopMirroredWrites
        check fastLoopOutcome(source, true) == "4950"
        check fastLoopMirroredWrites >= before + 100
        check fastLoopOutcome(source, false) == "4950"

  test "a verified loop is trusted, and a malformed one keeps its guards":
    # fastLoopJumps holds one verdict per opLoopEnter: 3 for a loop with a call,
    # 4 for one whose indexes and jump targets were all proved in range, 1 for
    # a plain loop that could not be proved.
    proc verdicts(chunk: Chunk): seq[uint8] =
      for fn in chunk.functions:
        for v in fn.chunk.fastLoopJumps:
          if v != 0: result.add v
    let plain = compileSource(
      "(fn f [n] (var t 0) (repeat i in n (set t (+ t 1))) t) (f 10)")
    check run(plain, newGlobalScope()).print() == "10"
    check verdicts(plain) == @[4'u8]
    let calling = compileSource(
      "(fn g [x] (+ x 1)) (fn f [n] (var t 0) (repeat i in n (set t (g t))) t) " &
      "(f 10)")
    check run(calling, newGlobalScope()).print() == "10"
    check 3'u8 in verdicts(calling)
    # What the verifier accepts, and what it refuses. A damaged chunk is never
    # run: with panics on, an index past a table ends the process.
    proc loopOf(source: string): tuple[chunk: Chunk, first, last: int] =
      let compiled = compileSource(source)
      result.chunk = compiled.functions[0].chunk
      for i, inst in result.chunk.instructions:
        if inst.op == opLoopEnter:
          result.first = i + 1
          result.last = inst.intArg
    let source = "(fn f [n] (var t 0) (repeat i in n (set t (+ t 1))) t) (f 10)"
    var good = loopOf(source)
    check fastLoopVerified(good.chunk, good.first, good.last)
    proc damaged(change: proc (body: Chunk, first, last: int)): bool =
      var loop = loopOf(source)
      change(loop.chunk, loop.first, loop.last)
      fastLoopVerified(loop.chunk, loop.first, loop.last)
    template firstIn(body: Chunk, first, last: int, wanted: OpCode): int =
      var found = -1
      for i in first ..< last:
        if body.instructions[i].op == wanted and found < 0: found = i
      found
    check not damaged(proc (b: Chunk, first, last: int) =
      b.instructions[firstIn(b, first, last, opPushConst)].intArg =
        b.constants.len)
    check not damaged(proc (b: Chunk, first, last: int) =
      b.instructions[firstIn(b, first, last, opJump)].intArg =
        b.instructions.len)
    check not damaged(proc (b: Chunk, first, last: int) =
      b.instructions[firstIn(b, first, last, opJump)].intArg = first - 1)
    check not damaged(proc (b: Chunk, first, last: int) =
      b.instructions[firstIn(b, first, last, opSetLocalPop) + 1].op = opNoop)
    check not damaged(proc (b: Chunk, first, last: int) =
      b.instructions[firstIn(b, first, last, opCompareLocalsJumpIfFalse) + 3]
        .intArg = last + 5)
    check not damaged(proc (b: Chunk, first, last: int) =
      b.instructions[last].op = opJump)       # the loop no longer ends at `last`
    check not fastLoopVerified(good.chunk, good.first, good.chunk.instructions.len)
    check not fastLoopVerified(good.chunk, -1, good.last)

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
