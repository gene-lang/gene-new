import gene/[types, compiler, vm, printer]
import std/[os, strutils, unittest]

proc evaluate(source: string): Value =
  run(compileSource(source), newGlobalScope())

suite "read-only execution budget":
  test "captured positional and named defaults use the new invocation budget":
    check evaluate("""
      (let make ($runtime/bind_call ^policy {^timeout_ms 20}
        (fn []
          (let captured 40)
          (fn [x = 1, ^y y = (do (repeat 100 nil) 1)] (+ captured x y))) []))
      (let callback (make))
      ($sleep 50)
      (let args [1])
      [(callback) (callback 1) (callback ^y 1) (callback args...)]
    """).print() == "[42 42 42 42]"

  test "captured required named arguments also discard an expired creation budget":
    check evaluate("""
      (let make ($runtime/bind_call ^policy {^timeout_ms 20}
        (fn [] (let captured 40) (fn [^x x : Int] (+ captured x))) []))
      (let callback (make))
      ($sleep 50)
      (repeat 100 ($assert (== (callback ^x 2) 42)))
      42
    """).print() == "42"

  test "module call limits cover default computation before entering the body":
    let app = newApplication(getCurrentDir())
    let moduleScope = newGlobalScope(app)
    moduleScope.moduleRoot = true
    moduleScope.moduleExecutionPolicy = ModuleExecutionPolicy(
      maxSteps: high(int64), maxMemoryMb: -1, timeoutMs: 20)
    let callback = run(compileSource("""
      (let captured 42)
      (fn [^value value = (do ($sleep 40) (repeat 100 nil) captured)] value)
    """), moduleScope)
    let caller = newGlobalScope(app)
    caller.define("callback", callback)
    var message = ""
    try:
      discard run(compileSource("(callback)"), caller)
    except GeneError as error:
      message = error.msg
    check "timeout" in message

  test "default computation and body share one module invocation deadline":
    let app = newApplication(getCurrentDir())
    let moduleScope = newGlobalScope(app)
    moduleScope.moduleRoot = true
    moduleScope.moduleExecutionPolicy = ModuleExecutionPolicy(
      maxSteps: high(int64), maxMemoryMb: -1, timeoutMs: 500)
    let callback = run(compileSource("""
      (let captured 42)
      (fn [^value value = (do ($sleep 150) captured)]
        (let budget ($runtime/execution_budget))
        [value (> budget/remaining_ms 0) (<= budget/remaining_ms 400)])
    """), moduleScope)
    let caller = newGlobalScope(app)
    caller.define("callback", callback)
    check run(compileSource("(callback)"), caller).print() == "[42 true true]"

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
