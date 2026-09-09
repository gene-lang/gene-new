import std/unittest
import gene/[compiler, printer, types, vm]

proc nilVoidEval(source: string): string =
  run(compileSource(source), newGlobalScope()).print()

suite "nil/void — optional parameters":
  test "nullable fixed parameters default to nil":
    check nilVoidEval("""
      (fn f [x : Int?] : Int? x)
      [(f) (f nil) (f 4) (try (f void) catch TypeError "bad")]
    """) == "[nil nil 4 \"bad\"]"
  test "explicit defaults preserve explicit nil and evaluate only when omitted":
    check nilVoidEval("""
      (var calls 0)
      (fn f [x : Int? = (do (set calls (+ calls 1)) 9)] : Int? x)
      [(f nil) calls (f) calls (f 3) calls]
    """) == "[nil 0 9 1 3 1]"
  test "aliases and equivalent nil-admitting forms get the same arity":
    check nilVoidEval("""
      (alias MaybeInt Int?)
      (fn a [x : MaybeInt] x)
      (fn b [x : (? Int)] x)
      (fn c [x : (| Str Nil)] x)
      (fn d [^x : MaybeInt] x)
      [(a) (b) (c) (d)]
    """) == "[nil nil nil nil]"
  test "required arguments cannot follow optional positionals and Any stays required":
    for source in ["(fn f [x : Int? y : Int] y)",
                   "(alias Maybe Int?) (fn f [x : Maybe y : Int] y)",
                   "(fn f [x : Any] x) (f)"]:
      expect GeneError: discard nilVoidEval(source)
  test "named omission and literal void use defaults but nil stays supplied":
    check nilVoidEval("""
      (fn f [^x : Int? = 9] x)
      [(f) (f ^x void) (f ^x nil)]
    """) == "[9 9 nil]"
  test "messages constructors and callable views share the optional arity":
    check nilVoidEval("""
      (protocol P (message value [x : Int?] : Int?))
      (type A ^props {^value Int?}
        (ctor [value : Int?] (self .set_prop `value value))
        (message value [x : Int?] : Int? x))
      (impl P for A (message value [x : Int?] : Int? x))
      (fn f [x : Int?] : Int? x)
      (let view : (Callable [] Int?) f)
      (let a (new A))
      [a/value (a .value) (a .P:value) (view)]
    """) == "[nil nil nil nil]"

suite "nil/void — map and explicit dropping":
  test "eager and lazy map normalize void and retain every other value":
    check nilVoidEval("""
      (fn f [x] (if (== x -1) void x))
      [($map [-1 nil false 0 ""] f)
       ($into ($map ($to_stream [-1 nil false 0 ""]) f) [])]
    """) == "[[nil nil false 0 \"\"] [nil nil false 0 \"\"]]"
  test "filter_map drops only void across eager and lazy inputs":
    check nilVoidEval("""
      (fn f [x] (if (== x -1) void x))
      [($filter_map [-1 nil false 0 ""] f)
       ($into ($filter_map ($to_stream [-1 nil false 0 ""]) f) [])]
    """) == "[[nil false 0 \"\"] [nil false 0 \"\"]]"
  test "sets deduplicate normalized nil and expose explicit dropping":
    check nilVoidEval("""
      (fn f [x] (if (|| (== x -2) (== x -1)) void x))
      [($map (Set -2 -1 false 0) f)
       ((Set -2 -1 false 0) .filter_map f)
       ((Set nil false 0) .filter_map f)]
    """) == "[(Set nil false 0) (Set false 0) (Set nil false 0)]"
  test "map composition retains intermediate nil normalization":
    check nilVoidEval("""
      (fn f [x] void)
      (fn g [x] (if ($nil? x) "nil" "other"))
      [($map ($map [1 2] f) g)
       ($into ($map ($map ($to_stream [1 2]) f) g) [])]
    """) == "[[\"nil\" \"nil\"] [\"nil\" \"nil\"]]"
  test "map preserves keys while filter_map explicitly removes void results":
    check nilVoidEval("""
      (fn f [x] (if (== x 1) void x))
      [($map {^a 1 ^b 2} f) ($filter_map {^a 1 ^b 2} f)
       ($map {{"a": 1 "b": 2}} f) ($filter_map {{"a": 1 "b": 2}} f)]
    """) == "[{^a nil ^b 2} {^b 2} {{\"a\" : nil \"b\" : 2}} {{\"b\" : 2}}]"
  test "iteration pipelines map void to nil while yield still skips void":
    check nilVoidEval("""
      (fn f [x] (if (> x 0) x void))
      (fn ^^generator producer [] (yield void) (yield nil) (yield 2))
      [([-1 2] => f -> $into []) ($into (producer) [])]
    """) == "[[nil 2] [nil 2]]"
  test "optional fields keep missing separate from present nil":
    check nilVoidEval("""
      (type Person ^props {^age Int?})
      (fn raw [p : Person] : (| Int Nil Void) p/age)
      (fn normalized [p : Person] : Int? (?? p/age nil))
      (fn invalid [p : Person] : Int? p/age)
      [($void? (raw (Person))) ($nil? (raw (Person ^age nil)))
       (normalized (Person)) (try (invalid (Person)) catch TypeError "bad")]
    """) == "[true true nil \"bad\"]"

suite "nil/void — forward alias arity":
  test "qualified forward aliases preserve optionality":
    check nilVoidEval("""
      (fn f [x : p/Maybe] : Int? x)
      (ns p (alias Maybe Int?))
      (f)
    """) == "nil"
  test "forward aliases expose the same optional parameter shape":
    check nilVoidEval("""
      (fn f [x : Maybe] : Int? x)
      (alias Maybe Int?)
      (f)
    """) == "nil"
    check nilVoidEval("""
      (fn outer []
        (fn inner [x : Maybe] : Int? x)
        (alias Maybe Int?)
        (inner))
      (outer)
    """) == "nil"
