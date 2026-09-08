import gene/[compiler, gir, printer, types, vm, web]
import std/[strutils, unittest]

proc testingEval(source: string): Value =
  run(compileSource(source, sourceName = "testing_spec.gene"),
      newGlobalScope(newApplication()))

template testingCheck(source, expected: string) =
  check testingEval(source).print() == expected

suite "testing — standalone assertions":
  test "assert uses ordinary truthiness and returns nil":
    testingCheck """
      [($assert true) ($assert 0) ($assert "") ($assert []) ($assert {})
       #@$assert (== 2 (+ 1 1))]
    """, "[nil nil nil nil nil nil]"
    for condition in ["false", "nil", "void"]:
      testingCheck "(try ($assert " & condition & ") catch AssertionError $ex/message)",
        "\"assertion failed\""

  test "arguments run once in order including successful messages":
    testingCheck """
      (var events [])
      (let check $assert)
      (check (do (events .push 1) true) (do (events .push 2) "ok"))
      (try
        (check (do (events .push 3) false) (do (events .push 4) "bad"))
        catch AssertionError (events .push $ex/message))
      events
    """, "[1 2 3 4 \"bad\"]"

  test "argument errors propagate and validation still runs on success":
    testingCheck """
      (try ($assert (/ 1 0) "unreached") catch RuntimeError $ex/message)
    """, "\"division by zero\""
    for source in ["($assert)", "($assert true nil nil)",
                    "($assert true ^message \"bad\")"]:
      expect GeneError: discard testingEval(source)
    testingCheck "(try ($assert true 1) catch TypeError true)", "true"
    testingCheck "(try ($assert false nil) catch AssertionError $ex/message)",
      "\"assertion failed\""

  test "assertion failures implement Error and obey checked rows":
    testingCheck """
      (fn checked [] ^errors [AssertionError] ($assert false "detail"))
      (try (checked) catch Error $ex/message)
    """, "\"detail\""
    testingCheck """
      (fn checked [] ^errors [] ($assert false))
      (try (checked) catch AssertionError false catch RuntimeError true)
    """, "true"

  test "assertion location and stack refer to authored calls":
    let value = testingEval("(fn check []\n  ($assert false))\n" &
      "(try (check) catch AssertionError $ex)")
    check value.head.typeName == "AssertionError"
    check value.props["file"].strVal == "testing_spec.gene"
    check value.props["line"].intVal == 2
    check value.props["trace"].listItems.len > 0

suite "testing — assertion helpers":
  test "equality uses == and records both absence operands":
    testingCheck """
      (import $test [assert_equal])
      [(assert_equal [1 2] #[1 2])
       (try (assert_equal void nil)
         catch AssertionError [$ex/has_comparison $ex/actual_present
           $ex/expected_present $ex/actual $ex/expected])]
    """, "[nil [true true true void nil]]"

  test "assert_raises invokes once and returns the matched typed error":
    testingCheck """
      (import $test [assert_raises])
      (var calls 0)
      (let error (assert_raises (fn []
        (set calls (+ calls 1)) ($assert false "detail")) Error))
      [calls error/message]
    """, "[1 \"detail\"]"

  test "assert_raises matches ancestry and preserves unexpected errors":
    testingCheck """
      (import $test [assert_raises])
      (type Base ^props {^message Str})
      (impl Error for Base)
      (type Child : Base ^props {})
      (let caught (assert_raises (fn [] (fail (Child ^message "child"))) Base))
      [caught/message
       (try (assert_raises (fn [] (/ 1 0)) AssertionError)
         catch RuntimeError $ex/message)]
    """, "[\"child\" \"division by zero\"]"

  test "normal return fails even when the value is an error":
    testingCheck """
      (import $test [assert_raises])
      (try (assert_raises (fn [] (AssertionError ^message "returned")) Error "missing")
        catch AssertionError $ex/message)
    """, "\"missing\""

  test "thunk validation happens before invocation and panic is not caught":
    testingCheck """
      (import $test [assert_raises])
      (var calls 0)
      (try (assert_raises (fn [] (set calls 1)) "not a type")
        catch TypeError nil)
      calls
    """, "0"
    expect GenePanic:
      discard testingEval("($test/assert_raises (fn [] (panic \"stop\")) Error)")

suite "testing — example lifecycle":
  test "declarations defer bodies, capture lexical values, and rerun with fresh fixtures":
    testingCheck """
      (import $test [describe context it before_each run])
      (var calls 0)
      (describe "list"
        (let number 7)
        (before_each [t] (set t/items []))
        (it "empty" [t] ($assert (== t/items [])) (set calls (+ calls 1)))
        (context "filled"
          (before_each [t] (t/items .push number))
          (it "has a value" [t] ($assert (== t/items [7])) (set calls (+ calls 1)))))
      (let before calls)
      (let first (run ^report false))
      (let second (run ^report false))
      [before calls first/passed second/passed second/exit_code]
    """, "[0 4 2 2 0]"

  test "hooks follow ancestry and reverse cleanup order":
    testingCheck """
      (import $test [describe context it before_each after_each run])
      (var events [])
      (describe "outer"
        (before_each [] (events .push "b1"))
        (before_each [] (events .push "b2"))
        (after_each [] (events .push "a1"))
        (after_each [] (events .push "a2"))
        (context "inner"
          (before_each [] (events .push "ib"))
          (after_each [] (events .push "ia"))
          (it "body" [] (events .push "body")))
        (it "sibling" [] (events .push "sibling")))
      (run ^report false)
      events
    """, "[\"b1\" \"b2\" \"ib\" \"body\" \"ia\" \"a2\" \"a1\" " &
      "\"b1\" \"b2\" \"sibling\" \"a2\" \"a1\"]"

  test "failed setup skips the body and unentered groups but cleans entered groups":
    testingCheck """
      (import $test [describe context it before_each after_each run])
      (var events [])
      (describe "outer"
        (before_each [] ($assert false "setup"))
        (before_each [] (events .push "unreached setup"))
        (after_each [] (events .push "outer cleanup"))
        (context "inner"
          (after_each [] (events .push "unentered cleanup"))
          (it "body" [] (events .push "unreached body"))))
      (let result (run ^report false))
      [events result/failed result/exit_code result/examples/0/diagnostics/0/phase]
    """, "[[\"outer cleanup\"] 1 1 \"before_each\"]"

  test "multiple failures retain phases, finish cleanup, and continue the suite":
    testingCheck """
      (import $test [describe it after_each run])
      (var events [])
      (describe "broken"
        (after_each [] (events .push "cleanup"))
        (after_each [] (/ 1 0))
        (after_each [] ($assert false "cleanup failure"))
        (it "fails" [] ($assert false "body failure")))
      (describe "next" (it "passes" [] (events .push "next")))
      (let result (run ^report false))
      [events result/passed result/failed result/errors result/exit_code
       (result/examples/0/diagnostics .size)]
    """, "[[\"cleanup\" \"next\"] 1 0 1 1 3]"

  test "skips run no hooks and false return passes":
    testingCheck """
      (import $test [describe it before_each run])
      (var calls 0)
      (describe "group"
        (before_each [] (set calls (+ calls 1)))
        (it "later" [] ^skip "not ready" ($assert false))
        (it "false is a value" [] false)
        (it "return is local" [] (return nil) ($assert false)))
      (let result (run ^report false))
      [calls result/passed result/skipped result/exit_code]
    """, "[2 2 1 0]"

  test "filter applies to full names and empty selection has its own status":
    testingCheck """
      (import $test [describe it run])
      (describe "math" (it "adds" [] nil) (it "subtracts" [] nil))
      (let selected (run ^name "math adds" ^report false))
      (let empty (run ^name "missing" ^report false))
      [selected/passed selected/examples/0/name empty/exit_code]
    """, "[1 \"math adds\" 2]"

  test "registration errors prevent a partial run even when caught":
    testingCheck """
      (import $test [describe it run])
      (var called false)
      (describe "ready" (it "must not run" [] (set called true)))
      (try (it "outside" [] nil) catch Error nil)
      (let result (run ^report false))
      [called result/exit_code (result/diagnostics .size)]
    """, "[false 1 1]"
    for source in [
      "(describe \"x\" (it \"bad\" [a b] nil))",
      "(describe \"x\" (it \"bad\" [] ^skip true nil))",
      "(describe \"x\" (it \"bad\" [] ^skip nil nil))",
      "(describe \"x\" (it \"bad\" [] ^skip \"\" nil))",
      "(describe \"x\" (let why \"later\") (it \"bad\" [] ^skip why nil))",
      "(describe \"x\" (it \"bad\" [] ^unknown true nil))",
      "(before_each [] nil)"]:
      expect GeneError:
        discard testingEval("(import $test [describe it before_each]) " & source)

  test "registration and nested runs are rejected during execution":
    testingCheck """
      (import $test [describe it run])
      (describe "group"
        (it "register" [] (describe "late" (it "late" [] nil)))
        (it "nested run" [] (run ^report false)))
      (let result (run ^report false))
      [result/errors (result/examples .size)]
    """, "[2 2]"

  test "example source locations survive macro expansion":
    let value = testingEval("(import $test [describe it run])\n" &
      "(describe \"group\"\n  (it \"fails\" []\n    ($assert false)))\n" &
      "(run ^report false)")
    let example = value.props["examples"].listItems[0].mapEntries
    check example["location"].mapEntries["line"].intVal == 3
    let diagnostic = example["diagnostics"].listItems[0].mapEntries
    check diagnostic["location"].mapEntries["line"].intVal == 4

  test "reporting bounds huge and cyclic operands without re-running code":
    let value = testingEval("""
      (import $test [describe it run assert_equal])
      (var cycle [])
      (cycle .push cycle)
      (describe "report" (it "cycle" [] (assert_equal cycle nil)))
      (run ^report false)
    """)
    let report = formatTestReport(value)
    check "<cycle>" in report
    check "expected: nil" in report
    check "testing_spec.gene" in report
    check "1 failed" in report
    let huge = testingEval("(import $test [describe it run assert_equal]) " &
      "(describe \"report\" (it \"large\" [] (assert_equal \"" &
      repeat('x', 5000) & "\" nil))) (run ^report false)")
    check formatTestReport(huge).len < 1800

  test "panic aborts after cleanup and registry run state is restored":
    let scope = newGlobalScope(newApplication())
    discard run(compileSource("""
      (import $test [describe it after_each])
      (var cleaned false)
      (describe "panic"
        (after_each [] (set cleaned true))
        (it "aborts" [] (panic "stop")))
    """), scope)
    expect GenePanic: discard runTests(scope, report = false)
    check run(compileSource("cleaned"), scope).boolVal
    expect GenePanic: discard runTests(scope, report = false)

  test "registries belong to their application":
    let left = newGlobalScope(newApplication())
    let right = newGlobalScope(newApplication())
    discard run(compileSource("(import $test [describe it]) " &
      "(describe \"only left\" (it \"example\" [] nil))"), left)
    check runTests(left, report = false).props["passed"].intVal == 1
    check runTests(right, report = false).props["exit_code"].intVal == 2

  test "closures retain scoped protocol implementations":
    testingCheck """
      (import $test [describe it run])
      (protocol Label (message label [] : Int))
      (type Item ^props {})
      (describe "local impl"
        (impl Label for Item (message label [] : Int 7))
        (it "visible in its closure" [] ($assert (== ((Item) .Label:label) 7))))
      (let result (run ^report false))
      [result/passed result/errors]
    """, "[1 0]"

  test "diagnostic operand snapshots precede cleanup mutation":
    testingCheck """
      (import $test [describe it before_each after_each assert_equal run])
      (describe "snapshot"
        (before_each [t] (set t/items []))
        (after_each [t] (t/items .push 99))
        (it "fails" [t] (assert_equal t/items [1])))
      (let result (run ^report false))
      result/examples/0/diagnostics/0/actual
    """, "\"[]\""

  test "diagnostics distinguish absent details from explicit nil and void":
    testingCheck """
      (import $test [describe it run assert_equal])
      (describe "details"
        (it "absent" []
          (fail (AssertionError ^message "custom" ^has_comparison true)))
        (it "present" [] (assert_equal void nil)))
      (let result (run ^report false))
      [result/failed result/examples/0/diagnostics/0/actual
       result/examples/1/diagnostics/0/actual result/examples/1/diagnostics/0/expected]
    """, "[2 \"<unavailable>\" \"void\" \"nil\"]"

  test "explicit awaits complete while returned streams stay lazy":
    testingCheck """
      (import $test [describe it run])
      (describe "deferred work"
        (it "awaits" []
          (scope
            (let task (spawn (do ($sleep 1) 7)))
            ($assert (== (await task) 7))))
        (it "does not drain" []
          ($map ($to_stream [1]) (fn [x] ($assert false)))))
      (let result (run ^report false))
      [result/passed result/errors result/failed]
    """, "[2 0 0]"

  test "cancellation bypasses matching and aborts a run after cleanup":
    proc cancelTesting(args: openArray[Value]): Value {.nimcall.} =
      raise newException(GeneCancel, "test cancellation")
    let scope = newGlobalScope(newApplication())
    scope.define("cancel_testing", newNativeFn("cancel_testing", cancelTesting))
    expect GeneCancel:
      discard run(compileSource("($test/assert_raises cancel_testing Error)"), scope)
    discard run(compileSource("""
      (import $test [describe it after_each])
      (var cleaned false)
      (describe "cancel"
        (after_each [] (set cleaned true))
        (it "aborts" [] (cancel_testing)))
    """), scope)
    expect GeneCancel: discard runTests(scope, report = false)
    check run(compileSource("cleaned"), scope).boolVal
    check runTests(scope, name = "unselected", report = false).props["exit_code"].intVal == 2

suite "testing — backend admission":
  test "the web backend explicitly rejects native assertions":
    expect WebProfileError:
      discard analyzeWebModule("(fn example [] : Nil ($assert true))", "assert_web.gene")
    expect WebProfileError:
      discard analyzeWebModule("(import $test [describe it]) " &
        "(describe \"group\" (it \"example\" [] nil))", "suite_web.gene")

  test "explicit native entries reject unlowerable assertion calls":
    expect GeneError:
      discard compileSource("(fn example [x : I64] : I64 ^native_entry {} " &
        "($assert true) x)").emitExperimentalC()

when defined(geneRcStats):
  # Keep this Application-owned registry measurement separate from the
  # shared-Application exact-zero baselines in test_rc.nim.
  suite "testing — fixture lifetime":
    test "test runs release fresh fixtures and failure snapshots":
      let scope = newGlobalScope(newApplication())
      discard run(compileSource("""
        (import $test [describe it before_each assert_equal])
        (describe "fixtures"
          (before_each [t] (set t/items ["one" "two" "three"]))
          (it "passes" [t] ($assert (== (t/items .size) 3)))
          (it "fails" [t] (assert_equal t/items [])))
      """), scope)
      for i in 0..<3:
        discard runTests(scope, report = false)
      GC_fullCollect()
      let before = liveManaged
      for i in 0..<25:
        block:
          let result = runTests(scope, report = false)
          check result.props["passed"].intVal == 1
          check result.props["failed"].intVal == 1
      GC_fullCollect()
      check liveManaged == before

