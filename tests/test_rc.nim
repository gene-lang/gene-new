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

  proc leakedManaged(src: string, useLocalSlots = true): int =
    ## Managed heap objects surviving one run of `src` after the program scope is
    ## dropped. The shared built-ins root is primed once below, so it cancels out.
    GC_fullCollect()
    let before = liveManaged
    block:
      var scope = newGlobalScope()
      discard run(compileSource(src, useLocalSlots = useLocalSlots), scope)
      scope = nil
    GC_fullCollect()
    result = liveManaged - before

  initModuleContext(getCurrentDir())
  discard newGlobalScope()   # build the built-ins root into the baseline
  GC_fullCollect()

  suite "rc — closures and scopes (geneRcStats)":
    test "returned local types retain and release their declaration scopes":
      for slots in [true, false]:
        check leakedManaged("""
          (type A ^props {} (message m [] : Str "A"))
          (type B ^props {} (message m [] : Str "B"))
          (fn make [p label]
            (type C : p ^props {}
              (message up [] : Str ($ label (super .m)))
              (message own_type [] C))
            C)
          (var C1 (make A "first:"))
          (var C2 (make B "second:"))
          ($assert (== ((C1) .up) "first:A"))
          ($assert (== ((C2) .up) "second:B"))
          ($assert (== ((C1) .own_type) C1))
          (set C1 nil)
          (set C2 nil)
        """, useLocalSlots = slots) == 0

      GC_fullCollect()
      let before = liveManaged
      var saved = NIL
      block:
        var scope = newGlobalScope()
        saved = run(compileSource("""
          (fn make [label]
            (type Local ^props {} (message value [] label))
            Local)
          (make "retained")
        """), scope)
        scope = nil
      GC_fullCollect()
      block:
        let scope = newGlobalScope()
        scope.define("Saved", saved)
        check run(compileSource("((Saved) .value)"), scope).strVal == "retained"
      saved = NIL
      GC_fullCollect()
      check liveManaged == before

    test "Self contracts and declaration assemblies release their receiver identities":
      check leakedManaged("""
        (type A ^props {^next Self?}
          (message copy [] : Self self)
          (message checker [] (fn [x : Self] : Bool true)))
        (type B : A ^props {})
        (let b (B ^next nil))
        (var checker (b .checker))
        (checker (A ^next nil))
        (set checker nil)
        (A .fields)
      """) == 0
      check leakedManaged("""
        (type A ^props {} (message check [x : Later] : Bool true))
        (alias Later Self)
        ((A) .check (A))
      """) == 0
      check leakedManaged("""
        (fn test []
          (type Boom ^props {} (message raise [] : Int ^errors [Self] (fail self)))
          (impl Error for Boom
            (message message [] : Str ^errors [] "boom"))
          (try ((Boom) .raise) catch Boom nil))
        (test)
      """) == 0

    test "scalar program leaks nothing (measurement sanity)":
      check leakedManaged("(+ 1 2)") == 0

    test "strict message proof signatures do not retain their owning scope":
      check leakedManaged("""
        (mod checked ^errors_mode strict)
        (type Item ^props {}
          (message copy [] : Self ^errors [] self)
          (message value [] : Int ^errors [] 7))
        (fn read [item : Item] : Int ^errors [] ((item .copy) .value))
        (read (Item))
      """) == 0

    test "inferred returned-callable proofs release their source scopes":
      check leakedManaged("""
        (mod checked ^errors_mode strict)
        (fn source ^private true [] 1)
        (fn factory ^private true [] (fn [] (source)))
        (fn client [] ^errors [] ((factory)))
        (client)
      """) == 0
      GC_fullCollect()
      let before = liveManaged
      var saved = NIL
      block:
        var scope = newGlobalScope()
        saved = run(compileSource("""
          (mod checked ^errors_mode strict)
          (fn factory ^private true []
            (fn callback [] ^errors [] 1)
            callback)
          (factory)
        """), scope)
        scope = nil
      GC_fullCollect()
      check saved.call().intVal == 1
      saved = NIL
      GC_fullCollect()
      check liveManaged == before

    test "returned protocol messages retain and release their binding scope":
      GC_fullCollect()
      let before = liveManaged
      var saved = NIL
      block:
        var scope = newGlobalScope()
        # A canonical impl intentionally remains an application root. Use an
        # overlay so the escaped message is the only owner after this block.
        scope.implOverlayRoot = true
        saved = run(compileSource("""
          (mod checked ^errors_mode strict)
          (protocol P (message value [] : Int ^errors []))
          (type Item ^props {})
          (impl P for Item (message value [] : Int ^errors [] 7))
          (fn factory ^private true [unused : Int] P:value)
          [(factory 1) (Item)]
        """), scope)
        scope = nil
      GC_fullCollect()
      check saved.listItems[0].call(@[saved.listItems[1]]).intVal == 7
      saved = NIL
      GC_fullCollect()
      check liveManaged == before

    test "released error witnesses reclaim their formatter environments":
      check leakedManaged("""
        (fn raise_local []
          (type Local ^props {^message Str})
          (impl Error for Local
            (message message [] : Str ^errors [] self/message))
          (let original (Local ^message "local"))
          (fail original))
        (repeat 10 (try (raise_local) catch Error $err_msg))
      """) == 0
      check leakedManaged("""
        (scope
          (type Local ^props {^message Str}
            (impl Error (message message [] : Str ^errors [] self/message)))
          (var original (Local ^message "named"))
          (try (fail original) catch Error $err_msg))
      """, useLocalSlots = false) == 0
      check leakedManaged("""
        (fn error_factory []
          (type Local ^props {^message Str})
          (impl Error for Local)
          (try (fail (Local ^message "saved")) catch Error
            (fn [] $err_msg)))
        (var display (error_factory))
        (display)
        (set display nil)
      """) == 0

    test "$runtime/gc_stats exposes live managed count":
      let scope = newGlobalScope()
      let stats = run(compileSource("($runtime/gc_stats)"), scope)
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

    test "escaped named functions release their scope once only it holds them":
      # A returned container also kept in a local, and a named function stored
      # into a local cell, must not keep their defining call scope in a cycle.
      check leakedManaged("(fn make [] (fn local [] 1) (var box {^f local}) box) " &
                          "(repeat 50 (make))") == 0
      check leakedManaged("(fn run [] (fn local [] 1) (var c ($cell nil)) " &
                          "(c .set local) nil) (repeat 50 (run))") == 0
      check leakedManaged("(type Box ^props {^f Any}) " &
                          "(fn make [] (fn local [] 1) (var box (Box ^f local)) box) " &
                          "(repeat 50 (make))") == 0

    test "released bound calls reclaim captures arguments and policy metadata":
      check leakedManaged("(fn target [x] (+ x 1)) " &
        "(var bound ($runtime/bind_call target [2] ^policy {^max_steps 100})) " &
        "(bound) (set bound nil)") == 0
      check leakedManaged("(fn make [x] " &
        " ($runtime/bind_call (fn [y] (+ x y)) [2])) " &
        "((make 40))") == 0
      check leakedManaged("(fn target [] 1) " &
        "(repeat 100 (var bound ($runtime/bind_call target [])) " &
        " (try (bound) ensure (set bound nil)))") == 0
      # Model an invocation adapter that owns a durable binding only until the
      # call settles. Ordinary factory closures also need their local cycle
      # broken; GC of arbitrary mixed scope/Value cycles is not implemented.
      check leakedManaged("(fn target [] (fail \"expected\")) " &
        "(fn invoke [] (var bound ($runtime/bind_call target [])) " &
        " (try (bound) catch Any nil ensure (set bound nil))) " &
        "(repeat 100 (invoke))") == 0

    test "checked callable views reclaim targets and invocation scopes":
      check leakedManaged("(let f : (Callable [Int] Int) (fn [x] (+ x 1))) (f 2)") == 0
      check leakedManaged("(fn make [n] : (Callable [Int] Int) (fn [x] (+ n x))) " &
        "(repeat 100 ((make 3) 2))") == 0
      check leakedManaged("(fn use [f : (Callable [Int] Int)] (f 1)) " &
        "(repeat 100 (use (fn [x] x)))") == 0
      check leakedManaged("(fn bad [x] (fail \"expected\")) " &
        "(fn use [f : (Callable [Int] Int)] (try (f 1) catch Any nil)) " &
        "(repeat 100 (use bad))") == 0
      check leakedManaged("(let f : (Callable [] Any ^errors []) " &
        "(fn [] ($assert false))) (try (f) catch ErrorContractViolation nil)") == 0

    test "prepared pipeline captures are released on close and exhaustion":
      check leakedManaged("(let s ([1 2] => + 3)) (s .close)") == 0
      check leakedManaged("([1 2] => + 3 -> $into [])") == 0
      check leakedManaged("(fn make [n] ([1 2] => + n)) " &
        "(repeat 100 (let s (make 3)) (s .close))") == 0
      check leakedManaged("(let args [2 3]) " &
        "(fn collect [items...] items) " &
        "(let s ([1] => collect args...)) (s .close)") == 0
      check leakedManaged("(fn broken [x] (fail \"expected\")) " &
        "(let s ([1] => broken)) (try (s .next) catch Any nil)") == 0

    test "packed and generic buffer backing values are reclaimed":
      check leakedManaged("(repeat 100 (var b ($buffer U8 65536)) (b .fill 7))") == 0
      check leakedManaged("(var b ($buffer [(fn [] 7)])) " &
        "((b .get 0)) (set b nil)") == 0

    test "proper tail transfers reclaim frames scopes and trace windows":
      check leakedManaged(
        "(fn is_even [n] (if (== n 0) true (is_odd (- n 1)))) " &
        "(fn is_odd [n] (if (== n 0) false (is_even (- n 1)))) " &
        "(is_even 10000)") == 0
      check leakedManaged(
        "(fn consume [xs n] " &
        "  (match xs " &
        "    (when [] (if (== n 0) 0 (consume [n] (- n 1)))) " &
        "    (else (consume [] n)))) " &
        "(consume [] 5000)") == 0

    test "tail fallback retains no more than the equivalent non-tail closure":
      let nonTailLeak = leakedManaged(
        "(var saved nil) " &
        "(fn retain [f] (set saved f) 0) " &
        "(fn outer [x] (var inner (fn [] x)) (+ 0 (retain inner))) " &
        "(outer 7) (saved)")
      let tailLeak = leakedManaged(
        "(var saved nil) " &
        "(fn retain [f] (set saved f) 0) " &
        "(fn outer [x] (var inner (fn [] x)) (retain inner)) " &
        "(outer 7) (saved)")
      check tailLeak == nonTailLeak

    test "module reference targets and structural fixups are reclaimed":
      check leakedManaged("#Ref shared [1 2] ($deref shared)") == 0
      check leakedManaged(
        "(var before #Deref shared) #Ref shared [1] " &
        "(same? before ($deref shared))") == 0
      check leakedManaged("#Ref callable (fn [] 1) (($deref callable))") == 0
      check leakedManaged("#Ref cycle ($cell #Deref cycle) " &
                          "(same? (($deref cycle) .get) ($deref cycle))") == 0

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

    test "protocol-typed cells do not retain their annotation scope":
      check leakedManaged(
        "(fn make [] " &
        "  (protocol Tagged) " &
        "  (type Item ^props {}) " &
        "  (impl Tagged for Item) " &
        "  (var cell : (Cell Tagged) ($cell (Item)))) " &
        "(repeat 500 (make))") == 0

    test "eval named functions are reclaimed when the result does not escape":
      check leakedManaged("(eval (quote (fn f [] f)) ^in (env))") == 0

    test "borrowed caller environments and snapshots are reclaimed":
      check leakedManaged(
        "(fn inspect! [] (eval (quote 1) ^in caller_env)) (inspect!)") == 0
      check leakedManaged(
        "(fn reject! [] (try [caller_env] catch Any nil)) (reject!)") == 0
      check leakedManaged(
        "(var x 1) " &
        "(fn snapshot! [] (caller_env .snapshot [\"x\"])) " &
        "(snapshot!)") == 0

    test "namespace and stream values are reclaimed when they do not capture functions":
      check leakedManaged("(ns m (var x 1))") == 0
      check leakedManaged("(var s ($read_all \"(a) (b)\")) (s .next)") == 0
      check leakedManaged("(var s ($to_stream [1 2 3])) (s .next)") == 0
      check leakedManaged("(var s ($map ($to_stream [1]) (fn [x] x)))") == 0
      check leakedManaged("(var s ($filter ($to_stream [1]) (fn [x] true)))") == 0
      # Regression: a transient stream whose callable captures an inner scope
      # that has already returned must keep that scope alive while pulling
      # (no use-after-free) and leave nothing behind once consumed.
      check leakedManaged("(fn mk [] (fn [x] (> x 1))) " &
                          "($into ($filter ($to_stream [1 2 3]) (mk)) [])") == 0
      check leakedManaged("(var items [1 2 3]) " &
                          "(fn mk [k] (match k (else (fn [x] true)))) " &
                          "(fn go [k] ($into ($filter ($to_stream items) (mk k)) [])) " &
                          "(go \"a\")") == 0
      check leakedManaged("($freeze [1 {^a [2]}])") == 0
      check leakedManaged("(fn ^^generator gen [] (yield 1)) " &
                          "(var s (gen)) " &
                          "(s .next) " &
                          "(s .close)") == 0
      check leakedManaged("(scope (var t (spawn (fn [] 1))) (await t))") == 0
      check leakedManaged("(scope " &
                          "  (var t : (Task Int Never) (spawn 1)) " &
                          "  (await t))") == 0
      check leakedManaged("(scope " &
                          "  (fn use [t : (Task Int Never)] " &
                          "    (try (await t) catch TypeError nil)) " &
                          "  (use (spawn \"bad\")))") == 0
      check leakedManaged("(var ch ($channel)) " &
                          "(ch .send 1) " &
                          "(ch .recv)") == 0
      check leakedManaged("(var ch : (Channel Int) ($channel))") == 0
      check leakedManaged("(var a ($actor/spawn ^init (fn [] 0) " &
                          "  ^handle (fn [ctx state msg] " &
                          "    ($actor/continue state))))") == 0
      check leakedManaged("(scope " &
                          "  ($actor/spawn ^init (fn [] 0) " &
                          "    ^handle (fn [ctx state msg] " &
                          "      ($actor/continue state))))") == 0
      check leakedManaged("(supervisor ^strategy restart " &
                          "  (var a ($actor/spawn ^init (fn [] 0) " &
                          "    ^handle (fn [ctx state msg] 99))) " &
                          "  (a .send 1))") == 0
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
                          "((User ^name \"Ada\") .HasLabel:label)") > 0 # generated impl
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
          "(var x 40) (fn f [] (+ x 2)) ($buffer [f])"), scope)
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
          "($map ($to_stream [1]) (fn [n] (+ x n)))"), scope)
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
          "  ($map ($to_stream [1]) (fn [n] (+ x n)))) " &
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
          "(fn ^^generator gen [] : (Stream Int Never) (yield (+ x 1))) " &
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
          "(var ch ($channel)) " &
          "(ch .send #[1 2]) " &
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
          "($actor/spawn ^init (fn [] 0) " &
          "  ^handle (fn [ctx state msg] ($actor/stop)))"), scope)
        scope = nil
      GC_fullCollect()
      block:
        var scope = newGlobalScope()
        scope.define("a", actor)
        discard run(compileSource("(a .send 1)"), scope)
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
      check heapGrowth("(var c ($cell 0)) (c .set 5)", N) < 100_000

    test "a self-referential cell is reclaimed":
      check heapGrowth("(var c ($cell 0)) (c .set c)", N) < 100_000

    test "a two-cell cycle is reclaimed":
      check heapGrowth(
        "(var a ($cell 0)) (var b ($cell 0)) (a .set b) (b .set a)",
        N) < 100_000

    test "an Env binding closure cycle is reclaimed":
      check heapGrowth(
        "(var e nil) (set e (env ^bindings {^f (fn [] e)}))",
        N) < 100_000

    test "an Env extend binding closure cycle is reclaimed":
      check heapGrowth(
        "(var e (env)) (set e (e .extend {^f (fn [] e)}))",
        N) < 100_000
else:
  echo "test_rc: compile with -d:geneRcStats to run leak assertions; skipping."
