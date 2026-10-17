import gene/[types, compiler, vm, printer]
import std/[strutils, unittest]

proc evaluate(source: string): Value =
  run(compileSource(source), newGlobalScope())

suite "read-only execution budget":
  test "unlimited evaluation has no fabricated deadline":
    check evaluate("""
      (let budget ($runtime/execution_budget))
      [($absent? budget/deadline_ms) ($absent? budget/remaining_ms)]
    """).print() == "[true true]"

  test "reports active limits independently of task context":
    check evaluate("""
      (let environment (env ^policy {^timeout_ms 500 ^max_steps 100000 ^max_memory_mb 64}))
      (eval ^in environment (quote
        ($runtime/with_context {^deadline_ms 9223372036854775807}
          (fn []
            (let budget ($runtime/execution_budget))
            [(&& (> budget/remaining_ms 0) (<= budget/remaining_ms 500))
             (<= budget/remaining_steps 100000)
             (== budget/memory_limit_bytes 67108864)
             (>= budget/deadline_ms budget/now_ms)]))))
    """).print() == "[true true true true]"

  test "a nested larger policy cannot extend the parent deadline":
    check evaluate("""
      (eval ^in (env ^policy {^timeout_ms 500}) (quote
        (do
          (let outer ($runtime/execution_budget))
          (let invoke ($runtime/bind_call ^policy {^timeout_ms 5000}
            (fn [] ($runtime/execution_budget)) []))
          (let inner (invoke))
          [(<= inner/deadline_ms outer/deadline_ms)
           (<= inner/remaining_ms outer/remaining_ms)])))
    """).print() == "[true true]"

  test "snapshots cannot mutate the actual budget or their fields":
    check evaluate("""
      (let budget ($runtime/execution_budget))
      (try (budget .put "deadline_ms" 0) false catch Any true)
    """).print() == "true"

  test "an observed deadline still expires normally":
    var message = ""
    try:
      discard evaluate("""
        (eval ^in (env ^policy {^timeout_ms 20}) (quote
          (do ($runtime/execution_budget) (while true nil))))
      """)
    except CatchableError as error:
      message = error.msg
    check "timeout" in message
