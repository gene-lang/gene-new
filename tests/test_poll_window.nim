## Dispatch counts the polls between two samples of a policy in a window,
## instead of moving every countdown of the budget chain on each instruction.
## Built with -d:genePollWindowTests, each program here also runs with every
## poll exact, as dispatch polled before windows; the samples of the two runs
## must land on the same instructions, in the same order, for the same budgets.
import gene/[compiler, execution_limits, printer, types, vm]
import std/[os, strutils, unittest]

const policy = "^policy {^max_memory_mb 1024 ^timeout_ms 600000}"

proc underPolicy(body: string): string =
  "(($runtime/bind_call (fn [] " & body & ") [] " & policy & "))"

proc traced(source: string, exact: bool): tuple[value: string, samples: seq[string]] =
  # A fresh compile for each run: a first run's lazy work must not move the
  # second's samples.
  let chunk = compileSource(source, sourceName = "poll_window.gene")
  pollWindowExact = exact
  pollSampleTrace.setLen(0)
  compilePollCount = 0
  try:
    result.value = run(chunk, newGlobalScope()).print()
  finally:
    pollWindowExact = false
  result.samples = pollSampleTrace

template sameSamples(source: string, expected: string) =
  let exact = traced(source, true)
  let windowed = traced(source, false)
  check exact.value == expected
  check windowed.value == expected
  check exact.samples.len > 4
  check exact.samples == windowed.samples

suite "poll windows sample where exact polls do":
  test "loops and fused instructions":
    # Compare-locals and constant-compare fusions, a set-and-pop, field reads
    # from a map and an instance, and a stdlib path, each charging its tail.
    sameSamples("""
      (type P ^props {^x Int ^y Int})
      (fn f [n]
        (var t 0) (var i 0)
        (let p (P ^x 3 ^y 4)) (let m {^a 1})
        (while (< i n)
          (if (== (// i 3) 0) (set t (+ t p/x)) (set t (+ t m/a)))
          (set t (+ t ($str/byte_size "ab")))
          (set i (+ i 1)))
        t)
    """ & underPolicy("[(f 700) (f 3)]"), "[2568 11]")

  test "calls, recursion and tail calls":
    sameSamples("""
      (fn fib [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
      (fn fib_typed [n : Int] : Int
        (if (< n 2) n (+ (fib_typed (- n 1)) (fib_typed (- n 2)))))
      (fn down [n] (if (< n 1) n (down (- n 1))))
    """ & underPolicy("[(fib 12) (fib_typed 11) (down 500)]"), "[144 89 0]")

  test "a policy inside a policy, and code after it returns":
    # The inner call changes the dispatch budget twice, and the chain's two
    # countdowns fall out of step.
    sameSamples("""
      (fn spin [n] (var t 0) (repeat i in n (set t (+ t i))) t)
      (fn inner [] (($runtime/bind_call (fn [] (spin 300)) []
                     ^policy {^timeout_ms 600000})))
    """ & underPolicy("[(spin 37) (inner) (spin 200) (inner)]"),
      "[666 44850 19900 44850]")

  test "natives that call back into the VM":
    sameSamples("""
      (fn spin [n] (var t 0) (repeat i in n (set t (+ t i))) t)
    """ & underPolicy(
      "[($map [10 20 30] (fn [x] (spin x))) " &
      " ([5 50] .map (fn [x] (spin x))) " &
      " ($order/sort_by [3 1 2] (fn [x] (spin x)))]"),
      "[[45 190 435] [10 1225] [1 2 3]]")

  test "errors caught inside the policy":
    sameSamples(underPolicy(
      "(do (var t 0) (repeat i in 60 " &
      "  (try (if (== (// i 2) 0) (fail \"x\") (set t (+ t 1))) " &
      "   catch Any (set t (+ t 2)))) t)"), "90")

  test "generators and spawned tasks":
    sameSamples("""
      (fn ^^generator nums [n] (repeat i in n (yield i)))
      (fn pull [n] (var t 0) (for x in (nums n) (set t (+ t x))) t)
      (fn work [n] (var s 0) (repeat j in n (set s (+ s j))) s)
    """ & underPolicy(
      "[(pull 80) (await (spawn (work 300))) (await (spawn (pull 40)))]"),
      "[3160 44850 780]")

  test "runtime compilation and macro expansion":
    # Compiling polls the chain of the code that called eval, while that
    # code's window is part used, long enough to take samples of its own
    # before a macro body runs.
    var forms = ""
    for i in 0 ..< 60: forms.add "(set t (+ t " & $i & ")) "
    sameSamples(underPolicy(
      "(do (var u 0) (repeat i in 40 (set u (+ u i))) " &
      " (eval ^in (env ^policy {^timeout_ms 600000}) (quote " &
      "  (do (var t 0) " & forms & "(macro twice [x] `(do %x %x)) " &
      "      (repeat i in 50 (twice (set t (+ t i)))) t))))"), "4220")

  test "sandbox compilation under the caller's policy":
    # A sandbox with no limits of its own compiles under the caller's chain,
    # from a native call made while the caller's window is part used.
    let directory = getTempDir() / ("gene_poll_window_" & $getCurrentProcessId())
    createDir(directory)
    var forms = ""
    for i in 0 ..< 100: forms.add "(var a" & $i & " " & $i & ")\n"
    writeFile(directory / "forms.gene", forms)
    defer:
      removeFile(directory / "forms.gene")
      removeDir(directory)
    sameSamples("(let transaction ($runtime/sandbox_transaction)) " & underPolicy(
      "(do (var u 0) (repeat i in 40 (set u (+ u i))) " &
      " (transaction .prepare {^dir " & directory.replace('\\', '/').escape() &
      "   ^entry \"forms.gene\" ^grants [] ^shared [] ^policy {}}) " &
      " transaction/.discard u)"), "780")
