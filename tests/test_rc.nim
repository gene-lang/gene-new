## Runtime leak tests for closures, scopes, and eval overlays.
##
## Managed heap values (strings, lists, maps, nodes, functions, native fns) are
## manually refcounted; `Scope` is an ORC ref. A function captures its defining
## `Scope` (an ORC ref inside the manually-allocated `GeneFunction`), and a
## `Scope` holds the function `Value` in `vars`. ORC cannot trace through a
## NaN-boxed `Value` into the manually-RC'd function, and manual RC cannot break
## cycles, so a `Scope -> Value(fn) -> GeneFunction.scope -> Scope` cycle is
## collectable by neither side.
##
## Empirically (see assertions below):
##   * anonymous / transient closures that are never bound into a surviving scope
##     ARE reclaimed — no leak;
##   * any *named* function binding leaks its `GeneFunction` (and the captured
##     scope) because the binding closes the cycle.
##
## This is a KNOWN, accepted short-term limitation. It bites long-lived processes
## (REPL, servers, repeated eval overlays), not run-once scripts. Tracked here so
## the behavior is pinned: if a count drops to 0, real cycle collection landed and
## the assertion should be tightened; if it grows, something regressed.
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

    test "KNOWN LIMITATION: a named function leaks its scope cycle":
      check leakedManaged("(fn f [] 1)") == 1
      check leakedManaged("(fn make [] (var x 1) (fn [] x)) (make)") == 1
      check leakedManaged("(fn fac [n] (if (= n 0) 1 (* n (fac (- n 1))))) (fac 5)") == 1

    test "KNOWN LIMITATION: a self-referential closure leaks":
      check leakedManaged("(var f nil) (set f (fn [] f))") == 1

    test "eval overlays without escaping functions are reclaimed":
      check leakedManaged("(eval (quote (+ 1 2)) ^in (env))") == 0

    test "KNOWN LIMITATION: eval named functions leak their overlay scope cycle":
      check leakedManaged("(eval (quote (fn f [] f)) ^in (env))") == 1

    test "namespace and stream values are reclaimed when they do not capture functions":
      check leakedManaged("(ns m (var x 1))") == 0
      check leakedManaged("(var s (to_stream [1 2 3])) (s ~ Stream/next)") == 0

    test "KNOWN LIMITATION: protocol derive retains function scope cycles":
      check leakedManaged("(protocol HasLabel " &
                          "  (message label [self] : Str) " &
                          "  (derive [t : Type, req] " &
                          "    `(impl HasLabel %t " &
                          "       (message label [self] : Str self/name)))) " &
                          "(type User ^props {^name Str} " &
                          "  ^impl [HasLabel] " &
                          "  ^derive [HasLabel]) " &
                          "(label (User ^name \"Ada\"))") == 3
else:
  echo "test_rc: compile with -d:geneRcStats to run leak assertions; skipping."
