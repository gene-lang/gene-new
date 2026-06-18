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
  import std/[os, unittest]

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

    test "eval named functions are reclaimed when the result does not escape":
      check leakedManaged("(eval (quote (fn f [] f)) ^in (env))") == 0

    test "namespace and stream values are reclaimed when they do not capture functions":
      check leakedManaged("(ns m (var x 1))") == 0
      check leakedManaged("(var s (to_stream [1 2 3])) (s ~ Stream/next)") == 0
      check leakedManaged("(var s (map (to_stream [1]) (fn [x] x)))") == 0
      check leakedManaged("(var s (filter (to_stream [1]) (fn [x] true)))") == 0
      check leakedManaged("(fn gen [] (yield 1)) " &
                          "(var s (gen)) " &
                          "(s ~ Stream/next) " &
                          "(s ~ Stream/close)") == 0
      check leakedManaged("(scope (var t (spawn (fn [] 1))) (await t))") == 0

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
else:
  echo "test_rc: compile with -d:geneRcStats to run leak assertions; skipping."
