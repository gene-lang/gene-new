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

    test "Runtime/gc_stats exposes live managed count":
      let scope = newGlobalScope()
      let stats = run(compileSource("(Runtime/gc_stats)"), scope)
      check stats.kind == vkMap
      check stats.mapEntries["rc_stats?"].boolVal
      check stats.mapEntries["live_managed"].kind == vkInt
      check stats.mapEntries["live_managed"].intVal >= 0

    test "transient anonymous closures are reclaimed":
      check leakedManaged("((fn [] (fn [] 1)))") == 0
      check leakedManaged("((fn [n] (* n n)) 5)") == 0

    test "scope-owned named functions are reclaimed":
      check leakedManaged("(fn f [] 1)") == 0
      check leakedManaged("(fn make [] (var x 1) (fn [] x)) (make)") == 0
      check leakedManaged("(fn fac [n] (if (== n 0) 1 (* n (fac (- n 1))))) (fac 5)") == 0

    test "self-referential closures stored in their scope are reclaimed":
      check leakedManaged("(var f nil) (set f (fn [] f))") == 0

    test "eval overlays without escaping functions are reclaimed":
      check leakedManaged("(eval (quote (+ 1 2)) ^in (env))") == 0
      check leakedManaged("(eval (quote cap) " &
                          "^in (env ^capabilities {^cap [1]}))") == 0
      check leakedManaged("(eval (quote (do " &
                          "  (protocol P (message value [self] : Int)) " &
                          "  (type T ^props {}) " &
                          "  (impl P for T (message value [self] : Int 1)))) " &
                          "^in (env))") == 0

    test "eval named functions are reclaimed when the result does not escape":
      check leakedManaged("(eval (quote (fn f [] f)) ^in (env))") == 0

    test "borrowed caller environments and snapshots are reclaimed":
      check leakedManaged(
        "(fn! inspect! [] (eval (quote 1) ^in caller_env)) (inspect!)") == 0
      check leakedManaged(
        "(fn! reject! [] (try [caller_env] catch * nil)) (reject!)") == 0
      check leakedManaged(
        "(var x 1) " &
        "(fn! snapshot! [] (Env/snapshot caller_env [\"x\"])) " &
        "(snapshot!)") == 0

    test "namespace and stream values are reclaimed when they do not capture functions":
      check leakedManaged("(ns m (var x 1))") == 0
      check leakedManaged("(var s (read_all \"(a) (b)\")) (s ~ Stream/next)") == 0
      check leakedManaged("(var s (to_stream [1 2 3])) (s ~ Stream/next)") == 0
      check leakedManaged("(var s (map (to_stream [1]) (fn [x] x)))") == 0
      check leakedManaged("(var s (filter (to_stream [1]) (fn [x] true)))") == 0
      # Regression: a transient stream whose callable captures an inner scope
      # that has already returned must keep that scope alive while pulling
      # (no use-after-free) and leave nothing behind once consumed.
      check leakedManaged("(fn mk [] (fn [x] (> x 1))) " &
                          "(into (filter (to_stream [1 2 3]) (mk)) [])") == 0
      check leakedManaged("(var items [1 2 3]) " &
                          "(fn mk [k] (match k (else (fn [x] true)))) " &
                          "(fn go [k] (into (filter (to_stream items) (mk k)) [])) " &
                          "(go \"a\")") == 0
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
      # A top-level `impl Send for Get` belongs in the global-retention test
      # below. Eval impls, tested above, remain reclaimable overlays.

    test "impls are globally retained, not reclaimed with their scope (design §10)":
      # A protocol impl registers on the shared application root and lives for the
      # app's lifetime, so a program that defines one retains the impl and its
      # receiver type. Eval/Env REPL impls are overlay-local and do not take this
      # path.
      check leakedManaged("(type Get ^props {^reply (ReplyTo Int)}) " &
                          "(impl Send for Get)") > 0                       # manual impl
      check leakedManaged("(protocol HasLabel " &
                          "  (message label [self] : Str) " &
                          "  (derive [t : Type, req] " &
                          "    `(impl HasLabel for %t " &
                          "       (message label [self] : Str self/name)))) " &
                          "(type User ^props {^name Str} " &
                          "  ^impl [HasLabel] " &
                          "  ^derive [HasLabel]) " &
                          "((User ^name \"Ada\") ~ label)") > 0        # generated impl
      # Control: the same type without an impl reclaims fully.
      check leakedManaged("(type User ^props {^name Str}) (User ^name \"Ada\")") == 0

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

    test "returned Env values strengthen contained functions":
      var env = NIL
      block:
        var scope = newGlobalScope()
        env = run(compileSource(
          "(var x 41) (env ^bindings {^f (fn [] (+ x 1))})"), scope)
        scope = nil
      GC_fullCollect()
      block:
        var scope = newGlobalScope()
        scope.define("e", env)
        check run(compileSource("(eval (quote (f)) ^in e)"), scope).intVal == 42
      env = NIL

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
  # Cycles involving Cell/Env objects reached through a Value are reclaimed either
  # by conservative trial deletion (direct value edges) or weak Env-bound closure
  # captures. `liveManaged` only counts manually-RC'd objects, so these cases
  # measure occupied heap growth instead.
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

  suite "rc — mutable-object cycles (geneRcStats)":
    const N = 30000

    test "control: acyclic cell mutation does not grow the heap":
      check heapGrowth("(var c (cell 0)) (Cell/set c 5)", N) < 100_000

    test "a self-referential cell is reclaimed":
      check heapGrowth("(var c (cell 0)) (Cell/set c c)", N) < 100_000

    test "a two-cell cycle is reclaimed":
      check heapGrowth(
        "(var a (cell 0)) (var b (cell 0)) (Cell/set a b) (Cell/set b a)",
        N) < 100_000

    test "an Env binding closure cycle is reclaimed":
      check heapGrowth(
        "(var e nil) (set e (env ^bindings {^f (fn [] e)}))",
        N) < 100_000

    test "an Env/extend binding closure cycle is reclaimed":
      check heapGrowth(
        "(var e (env)) (set e (e ~ Env/extend {^f (fn [] e)}))",
        N) < 100_000
else:
  echo "test_rc: compile with -d:geneRcStats to run leak assertions; skipping."
