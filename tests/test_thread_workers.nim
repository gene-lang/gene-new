import gene/[compiler, printer, types, vm]
import std/[locks, os, sets, unittest]

var probeLock: Lock
var probeLockReady = false
var probeNextThread = 0
var probeSeenThreads = initHashSet[int]()
var probeThreadId {.threadvar.}: int

proc ensureProbeLock() =
  if not probeLockReady:
    initLock(probeLock)
    probeLockReady = true

proc resetThreadProbe() =
  ensureProbeLock()
  acquire(probeLock)
  try:
    probeNextThread = 0
    probeSeenThreads.clear()
  finally:
    release(probeLock)

proc seenThreadCount(): int =
  acquire(probeLock)
  try:
    result = probeSeenThreads.len
  finally:
    release(probeLock)

proc biRecordThread(args: openArray[Value]): Value {.nimcall.} =
  let sleepMs = if args.len > 0 and args[0].kind == vkInt: int(args[0].intVal) else: 1
  ensureProbeLock()
  acquire(probeLock)
  try:
    if probeThreadId == 0:
      inc probeNextThread
      probeThreadId = probeNextThread
    probeSeenThreads.incl(probeThreadId)
  finally:
    release(probeLock)
  os.sleep(sleepMs)
  NIL

proc biResizeAndRun(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let workerCount =
    if args.len > 0 and args[0].kind == vkInt: args[0].intVal else: 1
  putEnv("GENE_WORKERS", $workerCount)
  let src =
    "(scope " &
    "  (fn work [] (record-thread 20)) " &
    "  (var a (spawn (work))) " &
    "  (var b (spawn (work))) " &
    "  (var c (spawn (work))) " &
    "  (var d (spawn (work))) " &
    "  (var e (spawn (work))) " &
    "  (var f (spawn (work))) " &
    "  (var g (spawn (work))) " &
    "  (var h (spawn (work))) " &
    "  (await a) (await b) (await c) (await d) " &
    "  (await e) (await f) (await g) (await h))"
  run(compileSource(src), call[].dispatchScope)

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

  test "nested worker leases can grow the running pool":
    resetThreadProbe()
    let scope = newGlobalScope()
    scope.define("record-thread", newNativeFn("record-thread", biRecordThread))
    scope.define("resize-and-run", newNativeCallFn("resize-and-run",
                                                   biResizeAndRun,
                                                   acceptsNamed = false))
    withGeneWorkerSetting "1":
      discard run(compileSource("(resize-and-run 4)"), scope)
    check seenThreadCount() >= 3

  test "worker lease spreads worker-candidate backlog across workers":
    resetThreadProbe()
    let scope = newGlobalScope()
    scope.define("record-thread", newNativeFn("record-thread", biRecordThread))
    withGeneWorkerSetting "4":
      discard run(compileSource(
        "(scope " &
        "  (fn work [] (record-thread 20)) " &
        "  (var a (spawn (work))) " &
        "  (var b (spawn (work))) " &
        "  (var c (spawn (work))) " &
        "  (var d (spawn (work))) " &
        "  (var e (spawn (work))) " &
        "  (var f (spawn (work))) " &
        "  (var g (spawn (work))) " &
        "  (var h (spawn (work))) " &
        "  (await a) (await b) (await c) (await d) " &
        "  (await e) (await f) (await g) (await h))"), scope)
    check seenThreadCount() >= 3

  test "worker leases keep application scheduler queues isolated":
    let app1 = newApplication()
    let scope1 = newGlobalScope(app1)
    let ch = run(compileSource("(channel ^capacity 1)"), scope1)
    scope1.define("ch", ch)
    var pending: Value
    withGeneWorkerSetting "0":
      pending = run(compileSource("(spawn (ch ~ Channel/send 42))"), scope1)
    check pending.kind == vkTask
    check not pending.taskDone
    check ch.channelLen == 0

    withGeneWorkerSetting "2":
      let app2 = newApplication()
      let scope2 = newGlobalScope(app2)
      let other = run(compileSource(
        "(var t (spawn 99)) " &
        "(var i 0) " &
        "(while (< i 200000) (set i (+ i 1))) " &
        "t"), scope2)
      check other.kind == vkTask
      check other.taskDone

    check ch.channelLen == 0
    check not pending.taskDone
    scope1.define("pending", pending)
    withGeneWorkerSetting "2":
      check run(compileSource("(await pending)"), scope1).kind == vkNil
    check pending.taskDone
    check ch.channelLen == 1

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

  test "active worker-candidate cancellation wakes root awaiters":
    withGeneWorkerSetting "1":
      expect GeneCancel:
        discard run(compileSource(
          "(scope " &
          "  (var started (atomic-cell 0)) " &
          "  (var t (spawn (do " &
          "    (started ~ AtomicCell/store 1) " &
          "    (var i 0) " &
          "    (while (< i 50000000) (set i (+ i 1))) " &
          "    i))) " &
          "  (sleep 10) " &
          "  (if (< (started ~ AtomicCell/load) 1) (panic \"worker did not start\") nil) " &
          "  (t ~ Task/cancel) " &
          "  (await t))"), newGlobalScope())

  test "worker pool runs worker-candidate tasks":
    withGeneWorkers:
      ck "(scope (var x 20) " &
         "  (var a (spawn (+ x 1))) " &
         "  (var b (spawn (+ x 2))) " &
         "  (+ (await a) (await b)))",
         "43"

  test "worker pool runs sendable actor handlers while root runs":
    resetThreadProbe()
    let scope = newGlobalScope()
    scope.define("record-thread", newNativeFn("record-thread", biRecordThread))
    withGeneWorkers:
      let pending = run(compileSource(
        "(type Get ^props {^reply (ReplyTo Int)}) " &
        "(impl Send Get) " &
        "(var a (actor/spawn ^init (fn [] 41) " &
        "  ^handle (fn [ctx state msg] " &
        "    (var (Get ^reply reply) msg) " &
        "    (record-thread 1) " &
        "    (reply ~ ReplyTo/send state) " &
        "    (actor/continue state)))) " &
        "(var pending (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
        "(var i 0) " &
        "(while (< i 800000) (set i (+ i 1))) " &
        "pending"), scope)
      check pending.kind == vkTask
      check pending.taskDone
      check seenThreadCount() >= 1

  test "worker pool runs sendable actor sends while root runs":
    resetThreadProbe()
    let scope = newGlobalScope()
    scope.define("record-thread", newNativeFn("record-thread", biRecordThread))
    withGeneWorkers:
      check run(compileSource(
        "(type Put ^props {^value Int}) " &
        "(impl Send Put) " &
        "(var seen (atomic-cell 0)) " &
        "(var a (actor/spawn ^init (fn [] 0) " &
        "  ^handle (fn [ctx state msg] " &
        "    (var (Put ^value value) msg) " &
        "    (record-thread 1) " &
        "    (seen ~ AtomicCell/store value) " &
        "    (actor/continue value)))) " &
        "(spawn (a ~ actor/try-send (Put ^value 42))) " &
        "(var i 0) " &
        "(while (< i 800000) (set i (+ i 1))) " &
        "(seen ~ AtomicCell/load)"), scope).print() == "42"
      check seenThreadCount() >= 1

  test "root actor send errors stay on root lane":
    withGeneWorkers:
      expect GeneError:
        discard run(compileSource(
          "(var a (actor/spawn ^init (fn [] 0) " &
          "  ^handle (fn [ctx state msg] 99))) " &
          "(a ~ actor/send 1)"), newGlobalScope())

  test "worker-candidate snapshots publish cloned closures":
    withGeneWorkerSetting "8":
      ck "(scope " &
         "  (var base 1) " &
         "  (fn add [x] (+ base x)) " &
         "  (var a (spawn (add 40))) " &
         "  (set base 100) " &
         "  [(await a) (add 40)])",
         "[41 140]"

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

  test "worker-candidate channel try-send respects capacity":
    withGeneWorkerSetting "8":
      ck "(scope " &
         "  (var ch (channel ^capacity 1)) " &
         "  (var success (atomic-cell 0)) " &
         "  (fn mark_success [] " &
         "    (var stored false) " &
         "    (var old 0) " &
         "    (while (not stored) " &
         "      (set old (success ~ AtomicCell/load)) " &
         "      (set stored (success ~ AtomicCell/compare-exchange old (+ old 1))))) " &
         "  (fn send_once [value] " &
         "    (if (ch ~ Channel/try-send value) (mark_success) nil)) " &
         "  (var a (spawn (send_once 1))) " &
         "  (var b (spawn (send_once 2))) " &
         "  (var c (spawn (send_once 3))) " &
         "  (var d (spawn (send_once 4))) " &
         "  (var e (spawn (send_once 5))) " &
         "  (var f (spawn (send_once 6))) " &
         "  (var g (spawn (send_once 7))) " &
         "  (var h (spawn (send_once 8))) " &
         "  (await a) (await b) (await c) (await d) " &
         "  (await e) (await f) (await g) (await h) " &
         "  (success ~ AtomicCell/load))",
         "1"

  test "worker-candidate channel try-recv claims one item":
    withGeneWorkerSetting "8":
      ck "(scope " &
         "  (var ch (channel ^capacity 1)) " &
         "  (var success (atomic-cell 0)) " &
         "  (ch ~ Channel/send 99) " &
         "  (fn mark_success [] " &
         "    (var stored false) " &
         "    (var old 0) " &
         "    (while (not stored) " &
         "      (set old (success ~ AtomicCell/load)) " &
         "      (set stored (success ~ AtomicCell/compare-exchange old (+ old 1))))) " &
         "  (fn recv_once [] " &
         "    (var got (ch ~ Channel/try-recv)) " &
         "    (if (same? got void) nil (mark_success))) " &
         "  (var a (spawn (recv_once))) " &
         "  (var b (spawn (recv_once))) " &
         "  (var c (spawn (recv_once))) " &
         "  (var d (spawn (recv_once))) " &
         "  (var e (spawn (recv_once))) " &
         "  (var f (spawn (recv_once))) " &
         "  (var g (spawn (recv_once))) " &
         "  (var h (spawn (recv_once))) " &
         "  (await a) (await b) (await c) (await d) " &
         "  (await e) (await f) (await g) (await h) " &
         "  (success ~ AtomicCell/load))",
         "1"

  test "worker-candidate actor try-send respects mailbox capacity":
    withGeneWorkerSetting "8":
      ck "(scope " &
         "  (var gate (channel ^capacity 1)) " &
         "  (var success (atomic-cell 0)) " &
         "  (var a (actor/spawn ^mailbox 1 ^init (fn [] 0) " &
         "    ^handle (fn [ctx state msg] " &
         "      (gate ~ Channel/recv) " &
         "      (actor/continue (+ state msg))))) " &
         "  (a ~ actor/send 0) " &
         "  (fn mark_success [] " &
         "    (var stored false) " &
         "    (var old 0) " &
         "    (while (not stored) " &
         "      (set old (success ~ AtomicCell/load)) " &
         "      (set stored (success ~ AtomicCell/compare-exchange old (+ old 1))))) " &
         "  (fn send_once [value] " &
         "    (if (a ~ actor/try-send value) (mark_success) nil)) " &
         "  (var t1 (spawn (send_once 1))) " &
         "  (var t2 (spawn (send_once 2))) " &
         "  (var t3 (spawn (send_once 3))) " &
         "  (var t4 (spawn (send_once 4))) " &
         "  (var t5 (spawn (send_once 5))) " &
         "  (var t6 (spawn (send_once 6))) " &
         "  (var t7 (spawn (send_once 7))) " &
         "  (var t8 (spawn (send_once 8))) " &
         "  (await t1) (await t2) (await t3) (await t4) " &
         "  (await t5) (await t6) (await t7) (await t8) " &
         "  (success ~ AtomicCell/load))",
         "1"

  test "actor mailbox reservations count toward capacity":
    let actor = newActorRef(1, NIL, NIL, NIL)
    let reserved = actor.tryReserveActorMessage()
    check reserved.reserved
    check actor.actorFull
    check actor.tryPushActorMessage(newInt(1)).full
    actor.releaseReservedActorMessage()
    let reservedAgain = actor.tryReserveActorMessage()
    check reservedAgain.reserved
    let committed = actor.commitReservedActorMessage(newInt(2), NIL)
    check committed.pushed
    check actor.actorQueueLen == 1
    check actor.actorFull

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

  test "root await drives worker-backed async file read":
    let path = getTempDir() / "gene-threaded-read-text-async-test.txt"
    writeFile(path, "worker async")
    defer:
      if fileExists(path):
        removeFile(path)
    let scope = newGlobalScope()
    scope.define("path", newStr(path))
    withGeneWorkerSetting "2":
      check run(compileSource(
        "(scope " &
        "  (var out (atomic-cell 0)) " &
        "  (var read-task (Fs/read-text-async Fs/ReadDir path)) " &
        "  (var marker (spawn (out ~ AtomicCell/store 1))) " &
        "  (await marker) " &
        "  [(out ~ AtomicCell/load) (await read-task)])"), scope).print() ==
        "[1 \"worker async\"]"

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

  test "worker-candidate tasks race one ReplyTo safely":
    withGeneWorkerSetting "8":
      ck "(scope " &
         "  (type Get ^props {^reply (ReplyTo Int)}) " &
         "  (impl Send Get) " &
         "  (var reply_cell (atomic-cell nil)) " &
         "  (var success (atomic-cell 0)) " &
         "  (var gate (channel ^capacity 1)) " &
         "  (var a (actor/spawn ^init (fn [] 0) " &
         "    ^handle (fn [ctx state msg] " &
         "      (var (Get ^reply reply) msg) " &
         "      (var value (gate ~ Channel/recv)) " &
         "      (try (reply ~ ReplyTo/send value) catch _ nil) " &
         "      (actor/continue state)))) " &
         "  (var pending (a ~ actor/ask " &
         "    (fn [reply] " &
         "      (reply_cell ~ AtomicCell/store reply) " &
         "      (Get ^reply reply)))) " &
         "  (fn mark_success [] " &
         "    (var stored false) " &
         "    (var old 0) " &
         "    (while (not stored) " &
         "      (set old (success ~ AtomicCell/load)) " &
         "      (set stored (success ~ AtomicCell/compare-exchange old (+ old 1))))) " &
         "  (fn send_once [value] " &
         "    (try (do ((reply_cell ~ AtomicCell/load) ~ ReplyTo/send value) " &
         "             (mark_success)) " &
         "      catch _ nil)) " &
         "  (var a1 (spawn (send_once 1))) " &
         "  (var a2 (spawn (send_once 2))) " &
         "  (var a3 (spawn (send_once 3))) " &
         "  (var a4 (spawn (send_once 4))) " &
         "  (var a5 (spawn (send_once 5))) " &
         "  (var a6 (spawn (send_once 6))) " &
         "  (var a7 (spawn (send_once 7))) " &
         "  (var a8 (spawn (send_once 8))) " &
         "  (await a1) (await a2) (await a3) (await a4) " &
         "  (await a5) (await a6) (await a7) (await a8) " &
         "  (var got (await pending)) " &
         "  (gate ~ Channel/send 99) " &
         "  (success ~ AtomicCell/load))",
         "1"

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
