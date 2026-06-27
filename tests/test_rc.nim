## Runtime leak tests for closures, scopes, and eval overlays.
##
## Managed heap values (strings, lists, maps, nodes, functions, native fns) are
## manually refcounted; `Scope` is an ORC ref. Scope-owned functions are stored
## with weak captured-scope back-edges, and values escaping a run/eval boundary
## are strengthened before returning. These tests pin the retain/release behavior
## around the old `Scope -> Value(fn) -> Scope` leak class.
##
## Build with: nim c -r -d:geneRcStats --path:src tests/test_rc.nim

when defined(geneRcStats):
  import gene/[compiler, types, vm]
  import std/[os, tables, unittest]

  proc leakedManaged(src: string): int =
    ## Managed heap objects surviving one run of `src` after the program scope is
    ## dropped. The shared built-ins root is primed once below, so it cancels out.
    GC_fullCollect()
    let before = liveManaged
    block:
      var scope = newGlobalScope()
      discard run(compileSource(src), scope)
      scope = nil
    GC_fullCollect()
    result = liveManaged - before

  initModuleContext(getCurrentDir())
  discard newGlobalScope()   # build the built-ins root into the baseline
  GC_fullCollect()

  suite "rc — closures and scopes (geneRcStats)":
    test "scalar program leaks nothing (measurement sanity)":
      check leakedManaged("(+ 1 2)") == 0

    test "Runtime/gc-stats exposes live managed count":
      let scope = newGlobalScope()
      let stats = run(compileSource("(Runtime/gc-stats)"), scope)
      check stats.kind == vkMap
      check stats.mapEntries["rc-stats?"].boolVal
      check stats.mapEntries["live-managed"].kind == vkInt
      check stats.mapEntries["live-managed"].intVal >= 0

    test "transient anonymous closures are reclaimed":
      check leakedManaged("((fn [] (fn [] 1)))") == 0
      check leakedManaged("((fn [n] (* n n)) 5)") == 0

    test "scope-owned named functions are reclaimed":
      check leakedManaged("(fn f [] 1)") == 0
      check leakedManaged("(fn make [] (var x 1) (fn [] x)) (make)") == 0
      check leakedManaged("(fn fac [n] (if (= n 0) 1 (* n (fac (- n 1))))) (fac 5)") == 0

    test "self-referential closures stored in their scope are reclaimed":
      check leakedManaged("(var f nil) (set f (fn [] f))") == 0

    test "eval overlays without escaping functions are reclaimed":
      check leakedManaged("(eval (quote (+ 1 2)) ^in (env))") == 0
      check leakedManaged("(eval (quote cap) " &
                          "^in (env ^capabilities {^cap [1]}))") == 0

    test "eval named functions are reclaimed when the result does not escape":
      check leakedManaged("(eval (quote (fn f [] f)) ^in (env))") == 0

    test "namespace and stream values are reclaimed when they do not capture functions":
      check leakedManaged("(ns m (var x 1))") == 0
      check leakedManaged("(var s (read-all \"(a) (b)\")) (s ~ Stream/next)") == 0
      check leakedManaged("(var s (to_stream [1 2 3])) (s ~ Stream/next)") == 0
      check leakedManaged("(var s (map (to_stream [1]) (fn [x] x)))") == 0
      check leakedManaged("(var s (filter (to_stream [1]) (fn [x] true)))") == 0
      check leakedManaged("(freeze [1 {^a [2]}])") == 0
      check leakedManaged("(fn gen [] (yield 1)) " &
                          "(var s (gen)) " &
                          "(s ~ Stream/next) " &
                          "(s ~ Stream/close)") == 0
      check leakedManaged("(scope (var t (spawn (fn [] 1))) (await t))") == 0
      check leakedManaged("(scope " &
                          "  (var t : (Task Int Never) (spawn 1)) " &
                          "  (await t))") == 0
      check leakedManaged("(scope " &
                          "  (fn use [t : (Task Int Never)] " &
                          "    (try (await t) catch (TypeError) nil)) " &
                          "  (use (spawn \"bad\")))") == 0
      check leakedManaged("(var ch (channel)) " &
                          "(ch ~ Channel/send 1) " &
                          "(ch ~ Channel/recv)") == 0
      check leakedManaged("(var ch : (Channel Int) (channel))") == 0
      check leakedManaged("(var a (actor/spawn ^init (fn [] 0) " &
                          "  ^handle (fn [ctx state msg] " &
                          "    (actor/continue state))))") == 0
      check leakedManaged("(scope " &
                          "  (actor/spawn ^init (fn [] 0) " &
                          "    ^handle (fn [ctx state msg] " &
                          "      (actor/continue state))))") == 0
      check leakedManaged("(supervisor ^strategy restart " &
                          "  (var a (actor/spawn ^init (fn [] 0) " &
                          "    ^handle (fn [ctx state msg] 99))) " &
                          "  (a ~ actor/send 1))") == 0
      check leakedManaged("(type Get ^props {^reply (ReplyTo Int)}) " &
                          "(impl Send Get) " &
                          "(var a : (ActorRef Get) " &
                          "  (actor/spawn ^init (fn [] 1) " &
                          "    ^handle (fn [ctx state msg] " &
                          "      (match msg " &
                          "        (when (Get ^reply reply) " &
                          "          (reply ~ ReplyTo/send state) " &
                          "          (actor/continue state)))))) " &
                          "(await (a ~ actor/ask " &
                          "  (fn [reply] (Get ^reply reply))))") == 0

    test "protocol derive functions and generated impls are reclaimed":
      check leakedManaged("(protocol HasLabel " &
                          "  (message label [self] : Str) " &
                          "  (derive [t : Type, req] " &
                          "    `(impl HasLabel %t " &
                          "       (message label [self] : Str self/name)))) " &
                          "(type User ^props {^name Str} " &
                          "  ^impl [HasLabel] " &
                          "  ^derive [HasLabel]) " &
                          "(label (User ^name \"Ada\"))") == 0

    test "returned named functions keep their defining scope alive":
      var f = NIL
      block:
        var scope = newGlobalScope()
        f = run(compileSource("(var x 41) (fn f [] (+ x 1)) f"), scope)
        scope = nil
      GC_fullCollect()
      check f.call().intVal == 42
      f = NIL

    test "returned containers strengthen contained functions":
      var functions = NIL
      block:
        var scope = newGlobalScope()
        functions = run(compileSource("(var x 40) (fn f [] (+ x 2)) [f]"), scope)
        scope = nil
      GC_fullCollect()
      check functions.listItems[0].call().intVal == 42
      functions = NIL

    test "returned buffers strengthen contained functions":
      var functions = NIL
      block:
        var scope = newGlobalScope()
        functions = run(compileSource(
          "(var x 40) (fn f [] (+ x 2)) (buffer [f])"), scope)
        scope = nil
      GC_fullCollect()
      check functions.bufferItem(0).call().intVal == 42
      functions = NIL

    test "returned lazy streams keep mapper scopes alive":
      var stream = NIL
      block:
        var scope = newGlobalScope()
        stream = run(compileSource("(var x 41) " &
          "(map (to_stream [1]) (fn [n] (+ x n)))"), scope)
        scope = nil
      GC_fullCollect()
      check stream.streamNext.intVal == 42
      stream = NIL

    test "returned typed lazy streams keep wrapped mapper scopes alive":
      var stream = NIL
      block:
        var scope = newGlobalScope()
        stream = run(compileSource(
          "(fn make [] : (Stream Int Never) " &
          "  (var x 41) " &
          "  (map (to_stream [1]) (fn [n] (+ x n)))) " &
          "(make)"), scope)
        scope = nil
      GC_fullCollect()
      check stream.streamNext.intVal == 42
      stream = NIL

    test "returned generator streams keep their defining scope alive":
      var stream = NIL
      block:
        var scope = newGlobalScope()
        stream = run(compileSource(
          "(var x 41) " &
          "(fn gen [] : (Stream Int Never) (yield (+ x 1))) " &
          "(gen)"), scope)
        scope = nil
      GC_fullCollect()
      check stream.streamNext.intVal == 42
      stream = NIL

    test "returned completed tasks keep result scopes alive":
      var task = NIL
      block:
        var scope = newGlobalScope()
        task = run(compileSource(
          "(var x 41) " &
          "(scope (spawn (fn [] (+ x 1))))"), scope)
        scope = nil
      GC_fullCollect()
      check task.taskResult.call().intVal == 42
      task = NIL

    test "returned channels keep buffered values alive":
      var channel = NIL
      block:
        var scope = newGlobalScope()
        channel = run(compileSource(
          "(var ch (channel)) " &
          "(ch ~ Channel/send #[1 2]) " &
          "ch"), scope)
        scope = nil
      GC_fullCollect()
      let buffered = channel.popChannel()
      check buffered.listImmutable
      check buffered.listItems[0].intVal == 1
      check buffered.listItems[1].intVal == 2
      channel = NIL

    test "returned actors keep handler scopes alive":
      var actor = NIL
      block:
        var scope = newGlobalScope()
        actor = run(compileSource(
          "(actor/spawn ^init (fn [] 0) " &
          "  ^handle (fn [ctx state msg] (actor/stop)))"), scope)
        scope = nil
      GC_fullCollect()
      block:
        var scope = newGlobalScope()
        scope.define("a", actor)
        discard run(compileSource("(a ~ actor/send 1)"), scope)
      check actor.actorClosed
      actor = NIL

  # --------------------------------------------------------------------------
  # KNOWN GAP: cycles among mutable ORC-backed objects (cells, envs, ...) reached
  # through a Value are NOT collected. `liveManaged` only counts manually-RC'd
  # objects, so it cannot see these leaks — we measure heap growth instead.
  #
  # design.md §11.1/§13 requires these to be collectable. The fix is to make
  # OBJECT_TAG objects fully ORC-managed (drop manual GC_ref/GC_unref +
  # immediate-free) so a `=trace` hook on Value can route them through ORC's
  # cycle collector; a scoped =trace alone crashes because ORC's deferred
  # collector traces objects the manual path has already freed at refcount 0.
  #
  # These tests assert the gap STILL EXISTS so it stays visible. When the rework
  # lands they will start failing — that is the signal to flip them to "no leak"
  # (growth near zero), the same way the scope->closure->scope cases were flipped.
  proc heapGrowth(src: string, iters: int): int =
    GC_fullCollect()
    let before = getOccupiedMem()
    for _ in 0 ..< iters:
      block:
        var scope = newGlobalScope()
        discard run(compileSource(src), scope)
        scope = nil
      GC_fullCollect()
    GC_fullCollect()
    result = getOccupiedMem() - before

  suite "rc — KNOWN GAP: mutable-object cycles (geneRcStats)":
    const N = 30000

    test "control: acyclic cell mutation does not grow the heap":
      check heapGrowth("(var c (cell 0)) (Cell/set c 5)", N) < 100_000

    test "KNOWN GAP: a self-referential cell leaks (should be ~0 once fixed)":
      check heapGrowth("(var c (cell 0)) (Cell/set c c)", N) > N * 20

    test "KNOWN GAP: a two-cell cycle leaks (should be ~0 once fixed)":
      check heapGrowth(
        "(var a (cell 0)) (var b (cell 0)) (Cell/set a b) (Cell/set b a)",
        N) > N * 40
else:
  echo "test_rc: compile with -d:geneRcStats to run leak assertions; skipping."
