import gene/[compiler, execution_limits, printer, reader, types, vm]
import std/[monotimes, os, osproc, streams, strtabs, strutils, tables, times, unittest]

const childSourceKey = "GENE_TEST_EXECUTION_EXPIRY_SOURCE"

# Imported first by test_all: children stop here before running other suites.
let childSource = getEnv(childSourceKey)
if childSource.len > 0:
  try:
    echo run(compileSource(childSource, sourceName = "execution_expiry.gene"),
             newGlobalScope()).print()
    quit(0)
  except CatchableError as error:
    stderr.writeLine $error.name & ": " & error.msg
    quit(1)

proc watched(source: string): string =
  let environment = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): environment[key] = value
  environment[childSourceKey] = source
  let process = startProcess(getAppFilename(), env = environment,
                            options = {poStdErrToStdOut})
  try:
    var status = process.waitForExit(5000)
    if status == -1:
      process.kill()
      discard process.waitForExit()
      raise newException(ValueError, "execution expiry subprocess exceeded 5 seconds")
    result = process.outputStream.readAll().strip()
    if status != 0:
      raise newException(ValueError, "execution expiry subprocess failed: " & result)
  finally:
    process.close()

const spin = "(fn spin [] (var n 0) (while true (set n (+ n 1)))) "

suite "execution expiry":
  test "deadline skips inner catches and remains catchable outside its owner":
    check watched(spin & """
      (let caught ($cell 0))
      (let invoke ($runtime/bind_call
        (fn [] (while true (try (spin) catch Any (caught .set (+ caught/.get 1))))) []
        ^policy {^timeout_ms 20}))
      [(try (invoke) false catch Any ($str/contains? $err/message "timeout"))
       caught/.get (+ 1 2)]
    """) == "[true 0 3]"

  test "an inner deadline can be handled under an unexpired outer policy":
    check watched(spin & """
      (let inner ($runtime/bind_call spin [] ^policy {^timeout_ms 10}))
      (let outer ($runtime/bind_call (fn []
        (try (inner) "escaped" catch Any "handled")) [] ^policy {^timeout_ms 500}))
      (outer)
    """) == "\"handled\""

  test "outer expiry cannot be handled inside a longer inner policy":
    check watched(spin & """
      (let caught ($cell 0))
      (let outer ($runtime/bind_call (fn []
        (let inner ($runtime/bind_call
          (fn [] (try (spin) catch Any (caught .set 1))) []
          ^policy {^timeout_ms 1000}))
        (try (inner) catch Any (caught .set 2))) [] ^policy {^timeout_ms 20}))
      [(try (outer) false catch Any ($str/contains? $err/message "timeout")) caught/.get]
    """) == "[true 0]"

  test "time expiry allows finite cleanup and cleanup-local control flow":
    check watched(spin & """
      (let trace [])
      (let invoke ($runtime/bind_call (fn []
        (try (spin)
          ensure
            (fn helper [] (return 7))
            (trace .push (helper))
            (while true (trace .push 8) (break))
            (repeat i in 3 (if (== i 1) (continue)) (trace .push i))
            (repeat 1000 nil)
            (trace .push 9))) [] ^policy {^timeout_ms 100}))
      (try (invoke) catch Any nil)
      trace
    """) == "[7 8 0 2 9]"

  test "return, break and continue cannot suppress deadline expiry":
    for exit in ["(return 1)", "(break)", "(continue)"]:
      check watched(spin & """
        (let resumed ($cell false))
        (let invoke ($runtime/bind_call (fn []
          (while true (try (spin) ensure EXIT))
          (resumed .set true)) [] ^policy {^timeout_ms 20}))
        [(try (invoke) false catch Any ($str/contains? $err/message "timeout")) resumed/.get]
      """.replace("EXIT", exit)) == "[true false]"

  test "infinite cleanup shares a bounded grace and preserves the timeout":
    check watched(spin & """
      (let invoke ($runtime/bind_call (fn []
        (try (spin) ensure (while true nil))) [] ^policy {^timeout_ms 20}))
      (try (invoke) nil catch Any
        [($str/contains? $err/message "timeout") $err/cleanup_truncated $err/cleanup_reason])
    """) == "[true true \"timeout\"]"

  test "memory expiry cannot be caught and cleanup stops at its fixed ceiling":
    check watched("""
      (let held [])
      (let caught ($cell false))
      (let invoke ($runtime/bind_call (fn []
        (try
          (while true (held .push {^value [1 2 3 4 5 6 7 8]}))
          catch Any (caught .set true)
          ensure (while true (held .push {^value [1 2 3 4 5 6 7 8]})))) []
        ^policy {^max_memory_mb 1}))
      (try (invoke) nil catch Any
        [($str/contains? $err/message "memory limit") caught/.get
         $err/cleanup_truncated $err/cleanup_reason])
    """) == "[true false true \"memory\"]"

  test "memory-only expiry also bounds cleanup that stops allocating":
    check watched("""
      (let held [])
      (let invoke ($runtime/bind_call (fn []
        (try (while true (held .push [1 2 3 4 5 6 7 8]))
          ensure (while true nil))) [] ^policy {^max_memory_mb 1}))
      (try (invoke) nil catch Any
        [($str/contains? $err/message "memory limit")
         $err/cleanup_truncated $err/cleanup_reason])
    """) == "[true true \"timeout\"]"

  test "memory expiry cannot be suppressed by cleanup exits":
    for exit in ["(return 1)", "(break)", "(continue)"]:
      check watched("""
        (let held [])
        (let resumed ($cell false))
        (let invoke ($runtime/bind_call (fn []
          (while true
            (try (while true (held .push [1 2 3 4 5 6 7 8])) ensure EXIT))
          (resumed .set true)) [] ^policy {^max_memory_mb 1}))
        [(try (invoke) false catch Any ($str/contains? $err/message "memory limit"))
         resumed/.get]
      """.replace("EXIT", exit)) == "[true false]"

  test "cleanup can suspend and resume without a fresh allowance":
    check watched(spin & """
      (let trace [])
      (let invoke ($runtime/bind_call (fn []
        (try (spin) ensure (trace .push 1) ($sleep 5) (trace .push 2))) []
        ^policy {^timeout_ms 100}))
      (scope
        (let task (spawn ^lane root
          (try (invoke) false catch Any ($str/contains? $err/message "timeout"))))
        [(await task) trace])
    """) == "[true [1 2]]"

  test "a nested cleanup cannot renew an exhausted grace":
    check watched(spin & """
      (let trace [])
      (let invoke ($runtime/bind_call (fn []
        (try (try (spin) ensure (while true nil))
          ensure (trace .push "too late"))) [] ^policy {^timeout_ms 20}))
      [(try (invoke) false catch Any $err/cleanup_truncated) trace]
    """) == "[true []]"

  test "an enclosing policy expiring during cleanup is terminal too":
    check watched(spin & """
      (let resumed ($cell false))
      (let inner ($runtime/bind_call (fn []
        (try (spin) ensure (while true nil))) [] ^policy {^timeout_ms 50}))
      (let outer ($runtime/bind_call (fn []
        (try (try (inner) catch Any (resumed .set true))
          ensure (while true nil))) [] ^policy {^timeout_ms 60}))
      [(try (outer) false catch Any
          [($str/contains? $err/message "timeout") $err/cleanup_truncated])
       resumed/.get]
    """) == "[[true true] false]"

  test "a live outer memory guard does not remove the cleanup grace cap":
    check watched(spin & """
      (let inner ($runtime/bind_call (fn []
        (try (spin) ensure (while true nil))) [] ^policy {^timeout_ms 20}))
      (let outer ($runtime/bind_call (fn []
        (try (inner) false catch Any $err/cleanup_truncated)) []
        ^policy {^max_memory_mb 64}))
      (outer)
    """) == "true"

  test "cleanup failures cannot replace expiry, but local catches still work":
    check watched(spin & """
      (let trace [])
      (let invoke ($runtime/bind_call (fn []
        (try
          (try (spin)
            ensure
              (try (/ 1 0) catch Any (trace .push "handled"))
              (/ 1 0))
          ensure (trace .push "outer"))) [] ^policy {^timeout_ms 100}))
      [(try (invoke) false catch Any ($str/contains? $err/message "timeout")) trace]
    """) == "[true [\"handled\" \"outer\"]]"

  test "generator pulls and native re-entry retain terminal expiry":
    check watched(spin & """
      (fn ^^generator items []
        (try (yield 1) ensure (/ 1 0)))
      (let invoke ($runtime/bind_call (fn []
        (for item in (items) (spin))) [] ^policy {^timeout_ms 20}))
      (try (invoke) false catch Any ($str/contains? $err/message "timeout"))
    """) == "true"
    check watched("""
      (let invoke ($runtime/bind_call (fn []
        ($map [1] (fn [item] (while true (try (repeat 100 nil) catch Any nil))))) []
        ^policy {^timeout_ms 20}))
      (try (invoke) false catch Any ($str/contains? $err/message "timeout"))
    """) == "true"

  test "expiry reached in a child task still terminates the owning policy":
    check watched(spin & """
      (let resumed ($cell false))
      (let invoke ($runtime/bind_call (fn []
        (scope
          (let child (spawn ^lane root (spin)))
          (try (await child) catch Any (resumed .set true)))) []
        ^policy {^timeout_ms 20}))
      [(try (invoke) false catch Any ($str/contains? $err/message "timeout")) resumed/.get]
    """) == "[true false]"

  test "expired defaults never enter the function body":
    check watched("""
      (let entered ($cell false))
      (let invoke ($runtime/bind_call (fn [x = (do ($sleep 30) (repeat 100 nil) 7)]
        (entered .set true)) [] ^policy {^timeout_ms 10}))
      [(try (invoke) false catch Any ($str/contains? $err/message "timeout")) entered/.get]
    """) == "[true false]"

  test "eval and runtime compilation keep the owning deadline":
    check watched("""
      (try
        (eval ^in (env ^policy {^timeout_ms 20}) (quote
          (do (macro looping [] (while true nil))
              (try (looping) catch Any "escaped"))))
        false
        catch Any ($str/contains? $err/message "timeout"))
    """) == "true"

  test "ordinary error cleanup can still return successfully":
    check watched("""
      (fn recover [] (try (/ 1 0) ensure (return 7)))
      (recover)
    """) == "7"

  test "a real panic in expiry cleanup retains its panic outcome":
    check watched(spin & """
      (let invoke ($runtime/bind_call (fn []
        (try (spin) ensure (panic "cleanup panic"))) [] ^policy {^timeout_ms 20}))
      (scope
        (let task (spawn ^lane root (invoke)))
        (match task/.join (when (TaskOutcome/panic _) true) (else false)))
    """) == "true"

  test "observed task cancellation cannot be suppressed by cleanup exits":
    for exit in ["(return 1)", "(break)", "(continue)"]:
      check watched("""
        (scope
          (let started ($cell false))
          (let resumed ($cell false))
          (let channel ($channel))
          (fn worker []
            (while true
              (try (started .set true) channel/.recv ensure EXIT)))
          (let task (spawn ^lane root (do (worker) (resumed .set true))))
          (spawn ^lane root
            (do (while (! started/.get) ($sleep 0)) task/.cancel))
          [(== task/.join TaskOutcome/cancelled) resumed/.get])
      """.replace("EXIT", exit)) == "[true false]"

  test "policy expiry and host cancellation retain their distinct task outcomes":
    check watched(spin & """
      (let invoke ($runtime/bind_call spin [] ^policy {^timeout_ms 20}))
      (scope
        (let task (spawn ^lane root (invoke)))
        (match task/.join
          (when (TaskOutcome/error error)
            ($str/contains? error/message "eval timeout exceeded"))
          (else false)))
    """) == "true"
    check watched("""
      (let entered ($cell false))
      (let invoke ($runtime/bind_call (fn []
        (entered .set true) (while true nil)) [] ^policy {^timeout_ms 5000}))
      (scope
        (let task (spawn ^lane root (invoke)))
        (spawn ^lane root (do (while (! entered/.get) ($sleep 0)) task/.cancel))
        (== task/.join TaskOutcome/cancelled))
    """) == "true"

  test "standalone compilation exposes a normal timeout error at its boundary":
    let budget = newCompileBudget(-1, 0)
    var message = ""
    try:
      discard compileFormsWithMacros(readAll("(+ 1 2)"),
        initTable[string, Table[string, MacroDef]](), budget = budget)
    except GeneError as error:
      message = error.msg
    check "compile timeout exceeded" in message

  test "compilation without local limits retains its caller's deadline":
    var outer = newExecutionBudget(-1, 0)
    let previous = activeVmBudget
    var expired = false
    activeVmBudget = addr outer
    try:
      discard compileFormsWithMacros(readAll("(+ 1 2)"),
        initTable[string, Table[string, MacroDef]](),
        budget = newCompileBudget(-1, -1))
    except GeneBudgetExpiry as error:
      expired = error.budget == outer
    finally:
      activeVmBudget = previous
    check expired
    check not outer.closed # the caller, not this compiler, owns the unwind

  test "sandbox initialization cannot extend or omit its caller's deadline":
    let directory = getTempDir() / ("gene_expiry_module_" & $getCurrentProcessId())
    createDir(directory)
    let file = directory / "busy.gene"
    writeFile(file, "(while true nil)")
    defer:
      removeFile(file)
      removeDir(directory)
    for policy in ["{}", "{^timeout_ms 2000 ^max_memory_mb 128}"]:
      check watched("""
        (let caught ($cell false))
        (let transaction ($runtime/sandbox_transaction))
        (let invoke ($runtime/bind_call (fn []
          (try (transaction .prepare {^dir DIRECTORY ^entry "busy.gene"
            ^grants [] ^shared [] ^policy POLICY})
            catch Any (caught .set true))) [] ^policy {^timeout_ms 100}))
        (let start ($os/monotonic_ms))
        (let expired (try (invoke) false catch Any
          ($str/contains? $err/message "timeout")))
        transaction/.discard
        [expired caught/.get (< (- ($os/monotonic_ms) start) 800)]
      """.replace("DIRECTORY", directory.replace('\\', '/').escape())
          .replace("POLICY", policy)) == "[true false true]"

  test "zero timeout and a retained expired budget never execute normal code":
    let scope = newGlobalScope()
    let budget = newExecutionBudget(-1, 0)
    scope.evalBudget = budget
    let code = compileSource("(panic \"body ran\")")
    for attempt in 0 .. 1:
      var message = ""
      try:
        discard run(code, scope)
      except GeneError as error:
        message = error.msg
      check message == "eval timeout exceeded"
      check budget.closed

  test "cleanup caps are fixed, shared, and saturate instead of overflowing":
    let longTimeout = newExecutionBudget(-1, 2000)
    let before = getMonoTime()
    discard markBudgetExpiry(longTimeout, longTimeout, false)
    check (longTimeout.cleanup.deadline - before).inMilliseconds in 990'i64 .. 1100'i64
    let shared = longTimeout.cleanup
    let originalDeadline = shared.deadline
    discard markBudgetExpiry(longTimeout, longTimeout, false)
    check longTimeout.cleanup == shared
    check shared.deadline == originalDeadline

    let memory = newExecutionBudget(1, -1)
    let baseline = memory.memoryBaseline
    discard markBudgetExpiry(memory, memory, true)
    check memory.memoryBaseline == baseline
    check memory.memoryLimitBytes == 2 * 1024 * 1024
    discard markBudgetExpiry(memory, memory, true)
    check memory.memoryLimitBytes == 2 * 1024 * 1024

    let huge = EvalBudget(hasMemoryLimit: true,
                         memoryLimitBytes: high(int64), memoryBaseline: 0)
    discard markBudgetExpiry(huge, huge, true)
    check huge.memoryLimitBytes == high(int64)

    let overshot = EvalBudget(hasMemoryLimit: true,
                             memoryLimitBytes: 1, memoryBaseline: 0)
    let failure = markBudgetExpiry(overshot, overshot, true)
    check failure.skipCleanup
    check overshot.cleanup.truncated == "memory"
