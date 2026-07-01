import gene/[compiler, printer, types, vm]
import std/[os, unittest]

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template withGeneWorkerSetting(value: string, body: untyped) =
  let previousWorkers = getEnv("GENE_WORKERS")
  putEnv("GENE_WORKERS", value)
  try:
    body
  finally:
    putEnv("GENE_WORKERS", previousWorkers)

template withGeneWorkers(body: untyped) =
  withGeneWorkerSetting("2"):
    body

suite "threaded scheduler workers":
  test "threaded build starts default worker pool":
    withGeneWorkerSetting "":
      let task = run(compileSource(
        "(var t (spawn 42)) " &
        "(var i 0) " &
        "(while (< i 200000) (set i (+ i 1))) " &
        "t"), newGlobalScope())
      check task.kind == vkTask
      check task.taskDone

  test "GENE_WORKERS=0 disables worker pool":
    withGeneWorkerSetting "0":
      let task = run(compileSource(
        "(var t (spawn 42)) " &
        "(var i 0) " &
        "(while (< i 200000) (set i (+ i 1))) " &
        "t"), newGlobalScope())
      check task.kind == vkTask
      check not task.taskDone

  test "high worker counts do not false-deadlock task await chains":
    withGeneWorkerSetting "8":
      ck "(scope (var ch (channel ^capacity 1)) " &
         "  (var producer (spawn (do (ch ~ Channel/recv) 5))) " &
         "  (var doubler (spawn (* 2 (await producer)))) " &
         "  (ch ~ Channel/send 1) " &
         "  (await doubler))", "10"

  test "high worker counts wake task cancellation awaiters":
    withGeneWorkerSetting "8":
      expect GeneCancel:
        discard run(compileSource(
          "(scope (var ch (channel ^capacity 1)) " &
          "  (var t (spawn (ch ~ Channel/recv))) " &
          "  (var w (spawn (await t))) " &
          "  (t ~ Task/cancel) " &
          "  (await w))"), newGlobalScope())

  test "high worker counts wake sleeping task cancellation":
    withGeneWorkerSetting "8":
      expect GeneCancel:
        discard run(compileSource(
          "(scope (var t (spawn (sleep 1000))) " &
          "  (t ~ Task/cancel) " &
          "  (await t))"), newGlobalScope())

  test "worker pool runs worker-candidate tasks":
    withGeneWorkers:
      ck "(scope (var x 20) " &
         "  (var a (spawn (+ x 1))) " &
         "  (var b (spawn (+ x 2))) " &
         "  (+ (await a) (await b)))",
         "43"

  test "worker-candidate tasks share AtomicCell through CAS":
    withGeneWorkerSetting "8":
      ck "(scope " &
         "  (var counter (atomic-cell 0)) " &
         "  (fn inc_many [limit] " &
         "    (var i 0) " &
         "    (var stored false) " &
         "    (var old 0) " &
         "    (while (< i limit) " &
         "      (set stored false) " &
         "      (while (not stored) " &
         "        (set old (counter ~ AtomicCell/load)) " &
         "        (set stored (counter ~ AtomicCell/compare-exchange old (+ old 1)))) " &
         "      (set i (+ i 1))) " &
         "    nil) " &
         "  (var a (spawn (inc_many 200))) " &
         "  (var b (spawn (inc_many 200))) " &
         "  (var c (spawn (inc_many 200))) " &
         "  (var d (spawn (inc_many 200))) " &
         "  (var e (spawn (inc_many 200))) " &
         "  (var f (spawn (inc_many 200))) " &
         "  (var g (spawn (inc_many 200))) " &
         "  (var h (spawn (inc_many 200))) " &
         "  (await a) (await b) (await c) (await d) " &
         "  (await e) (await f) (await g) (await h) " &
         "  (counter ~ AtomicCell/load))",
         "1600"

  test "root await helps drain worker-candidate queue":
    withGeneWorkerSetting "1":
      ck "(scope " &
         "  (fn work [base] " &
         "    (var i 0) " &
         "    (var acc base) " &
         "    (while (< i 50000) " &
         "      (set acc (+ acc 1)) " &
         "      (set i (+ i 1))) " &
         "    acc) " &
         "  (var a (spawn (work 1))) " &
         "  (var b (spawn (work 2))) " &
         "  [(await a) (await b)])",
         "[50001 50002]"

  test "worker-candidate task errors wake root awaiters":
    withGeneWorkerSetting "8":
      ck "(scope " &
         "  (type Boom ^props {^message Str} ^impl [Error]) " &
         "  (impl Error Boom) " &
         "  (var t (spawn (fail (Boom ^message \"worker\")))) " &
         "  (var i 0) " &
         "  (while (< i 200000) (set i (+ i 1))) " &
         "  (try (await t) catch (Boom ^message m) m))",
         "\"worker\""

  test "worker-candidate task panics wake root awaiters":
    withGeneWorkerSetting "8":
      expect GenePanic:
        discard run(compileSource(
          "(scope " &
          "  (var t (spawn (panic \"worker\"))) " &
          "  (var i 0) " &
          "  (while (< i 200000) (set i (+ i 1))) " &
          "  (await t))"), newGlobalScope())

  test "root channel waits run worker-candidate tasks on workers":
    withGeneWorkers:
      ck "(scope (var ch (channel ^capacity 1)) " &
         "  (var x 40) " &
         "  (spawn (ch ~ Channel/send (+ x 2))) " &
         "  (ch ~ Channel/recv))",
         "42"

  test "root execution lease runs worker-candidate tasks before blocking waits":
    withGeneWorkers:
      let task = run(compileSource(
        "(var t (spawn 42)) " &
        "(var i 0) " &
        "(while (< i 200000) (set i (+ i 1))) " &
        "t"), newGlobalScope())
      check task.kind == vkTask
      check task.taskDone

  test "root function calls lease workers for worker-candidate tasks":
    withGeneWorkers:
      let fn = run(compileSource(
        "(fn [] " &
        "  (var t (spawn 42)) " &
        "  (var i 0) " &
        "  (while (< i 200000) (set i (+ i 1))) " &
        "  t)"), newGlobalScope())
      check fn.kind == vkFunction
      let task = fn.call()
      check task.kind == vkTask
      check task.taskDone

  test "generator pulls lease workers for worker-candidate tasks":
    withGeneWorkers:
      let task = run(compileSource(
        "(fn gen [] " &
        "  (var t (spawn 42)) " &
        "  (var i 0) " &
        "  (while (< i 200000) (set i (+ i 1))) " &
        "  (yield t)) " &
        "(var s (gen)) " &
        "(s ~ Stream/next)"), newGlobalScope())
      check task.kind == vkTask
      check task.taskDone

  test "worker pool wakes sleeping worker-candidate tasks while root runs":
    withGeneWorkers:
      let task = run(compileSource(
        "(var t (spawn (do (sleep 1) 42))) " &
        "(var i 0) " &
        "(while (< i 800000) (set i (+ i 1))) " &
        "t"), newGlobalScope())
      check task.kind == vkTask
      check task.taskDone

  test "root await treats sleeping worker-candidate tasks as progress":
    withGeneWorkers:
      ck "(await (spawn (do (sleep 1) 42)))", "42"

  test "ask timeouts wake parked workers while root runs":
    withGeneWorkerSetting "1":
      let task = run(compileSource(
        "(type Get ^props {^reply (ReplyTo Int)}) " &
        "(impl Send Get) " &
        "(var gate (channel ^capacity 1)) " &
        "(var a (actor/spawn ^init (fn [] 0) " &
        "  ^handle (fn [ctx state msg] " &
        "    (var (Get ^reply reply) msg) " &
        "    (var value (gate ~ Channel/recv)) " &
        "    (reply ~ ReplyTo/send value) " &
        "    (actor/continue state)))) " &
        "(var pending (a ~ actor/ask ^timeout-ms 5 " &
        "  (fn [reply] (Get ^reply reply)))) " &
        "(var i 0) " &
        "(while (< i 800000) (set i (+ i 1))) " &
        "pending"), newGlobalScope())
      check task.kind == vkTask
      check task.taskDone

  test "root await treats pending ask timeouts as worker progress":
    withGeneWorkerSetting "1":
      ck "(scope " &
         "  (type Get ^props {^reply (ReplyTo Int)}) " &
         "  (impl Send Get) " &
         "  (var gate (channel ^capacity 1)) " &
         "  (var a (actor/spawn ^init (fn [] 0) " &
         "    ^handle (fn [ctx state msg] " &
         "      (var (Get ^reply reply) msg) " &
         "      (var value (gate ~ Channel/recv)) " &
         "      (reply ~ ReplyTo/send value) " &
         "      (actor/continue state)))) " &
         "  (var pending (a ~ actor/ask ^timeout-ms 5 " &
         "    (fn [reply] (Get ^reply reply)))) " &
         "  (try (await pending) catch (ActorError ^message m) m))",
         "\"actor/ask timed out\""
