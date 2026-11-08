import std/unittest
import gene/[compiler, printer, types, vm]

proc nilEval(source: string): string =
  run(compileSource(source), newGlobalScope()).print()

suite "nil — optional parameters":
  test "nullable fixed parameters default to nil":
    check nilEval("""
      (fn f [x : Int?] : Int? x)
      [(f) (f nil) (f 4) (try (f "s") catch TypeError "bad")]
    """) == "[nil nil 4 \"bad\"]"
  test "explicit defaults preserve explicit nil and evaluate only when omitted":
    check nilEval("""
      (var calls 0)
      (fn f [x : Int? = (do (set calls (+ calls 1)) 9)] : Int? x)
      [(f nil) calls (f) calls (f 3) calls]
    """) == "[nil 0 9 1 3 1]"
  test "aliases and equivalent nil-admitting forms get the same arity":
    check nilEval("""
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
      expect GeneError: discard nilEval(source)
  test "named nil stays supplied":
    check nilEval("""
      (fn f [^x : Int? = 9] x)
      [(f) (f ^x nil)]
    """) == "[9 nil]"

suite "nil — Present":
  test "Present rejects nil and accepts every other value":
    check nilEval("""
      (fn f [x : Present] x)
      [(f false) (f 0) (f "") (f []) (try (f nil) catch TypeError "rejected")]
    """) == "[false 0 \"\" [] \"rejected\"]"
  test "Present? is optional and Any is required":
    check nilEval("(fn g [x : Present?] x) [(g) (g 1)]") == "[nil 1]"
    expect GeneError: discard nilEval("(fn h [x : Any] x) (h)")
  test "Present uses value semantics for Range and identity for containers":
    check nilEval("""
      (fn same_p [a : Present b : Present] : Bool (same? a b))
      [(same_p ($range 1 3) ($range 1 3)) (same_p [1] [1])]
    """) == "[true false]"

suite "nil — map and filter_map":
  test "map keeps one result per input including nil":
    check nilEval("""
      (fn f [x] (if (== x -1) nil x))
      [($map [-1 nil false 0 ""] f)
       ($into ($map ($to_stream [-1 nil false 0 ""]) f) [])]
    """) == "[[nil nil false 0 \"\"] [nil nil false 0 \"\"]]"
  test "filter_map drops only nil across eager and lazy inputs":
    check nilEval("""
      (fn f [x] (if (== x -1) nil x))
      [($filter_map [-1 nil false 0 ""] f)
       ($into ($filter_map ($to_stream [-1 nil false 0 ""]) f) [])]
    """) == "[[false 0 \"\"] [false 0 \"\"]]"
  test "map preserves keys and filter_map removes nil results":
    check nilEval("""
      (fn f [x] (if (== x 1) nil x))
      [($map {^a 1 ^b 2} f) ($filter_map {^a 1 ^b 2} f)]
    """) == "[{^a nil ^b 2} {^b 2}]"
  test "a generator yields nil as an item":
    check nilEval("""
      (fn ^^generator producer [] : (Stream Int? Never) (yield nil) (yield 2))
      ($into (producer) [])
    """) == "[nil 2]"

suite "nil — stored versus missing":
  test "a missing field reads nil and has_key? tells the two apart":
    check nilEval("""
      (type Person ^props {^age Int?})
      (let missing (Person))
      (let stored (Person ^age nil))
      [missing/age stored/age ($has_key? missing "age") ($has_key? stored "age")
       (== missing stored)]
    """) == "[nil nil false true false]"
  test "an Int? return accepts a missing field read":
    check nilEval("""
      (type Person ^props {^age Int?})
      (fn age_of [p : Person] : Int? p/age)
      [(age_of (Person)) (age_of (Person ^age 3))]
    """) == "[nil 3]"
  test "writing nil stores it; delete removes it":
    check nilEval("""
      (var m {^a 1})
      (set m/a nil)
      [m/a ($has_key? m "a") (m .delete "a") ($has_key? m "a")]
    """) == "[nil true nil false]"
  test "dissoc and dissoc_in build new roots and share untouched children":
    check nilEval("""
      (let m {^x {^a 1 ^b 2} ^y {^c 3}})
      (let r ($dissoc_in m /x/a))
      [r (same? r/y m/y) (same? r m) ($dissoc_in m /q/a) (m .dissoc "zz")]
    """) == "[{^x {^b 2} ^y {^c 3}} true false {^x {^a 1 ^b 2} ^y {^c 3}} {^x {^a 1 ^b 2} ^y {^c 3}}]"
  test "typed records keep required fields on delete":
    check nilEval("""
      (type P ^props {^name Str ^age Int?})
      (let p (P ^name "A" ^age 3))
      [(p .delete "age") p/age (try (p .delete "name") catch Error $err/message)]
    """) == "[3 nil \"cannot remove required field 'name' from P\"]"

suite "nil — statement returns":
  test "a bare Nil return discards the body value, also through aliases":
    check nilEval("""
      (alias Unit Nil)
      (fn a [] : Nil 42)
      (fn b [] : Unit 42)
      (fn c [] : Nil? nil)
      [(a) (b) (c)]
    """) == "[nil nil nil]"
  test "Nil? and unions are ordinary return types":
    check nilEval("""
      (fn f [] : Nil? 42)
      (fn g [] : (| Int Nil) 42)
      [(try (f) catch TypeError "TypeError") (g)]
    """) == "[\"TypeError\" 42]"

suite "nil — review regressions":
  test "explicit return nil cannot bypass the declared result boundary":
    for source in [
        "(fn f [] : Int (if true (then (return nil))) 42) (try (f) catch TypeError \"type error\")",
        "(fn f [] : Str (if true (then (return nil))) \"ok\") (try (f) catch TypeError \"type error\")"]:
      check nilEval(source) == "\"type error\""

  test "stream projection misses are normalized to nil before publication":
    check nilEval("""
      (let direct ($into (/missing ($to_stream [{} {^missing nil}])) []))
      (let nested ($into (/a/b ($to_stream [{^a {^b 1}} {}])) []))
      [($map direct (fn [v] [(== v nil) (same? v nil) ($absent? v)]))
       ($map nested (fn [v] [(== v nil) (same? v nil) ($absent? v)]))]
    """) == "[[[true true true] [true true true]] [[false false false] [true true true]]]"

  test "dissoc_in refuses to copy native wrappers":
    expect GeneError: discard nilEval("""
      (type Conn ^repr native_wrapper ^props {^handle Str}
        (ctor [h : Str] (set self/handle h)))
      (let original (new Conn "H"))
      ($dissoc_in original /missing/child)
    """)

  test "native wrapper construction cannot escape through dissoc_in":
    check nilEval("""
      (var escaped nil)
      (type Conn ^repr native_wrapper ^props {^handle Str}
        (ctor [h : Str]
          (set escaped ($dissoc_in self /missing/child))
          (set self/handle h)))
      [(try (new Conn "H") catch Error "failed") escaped]
    """) == "[\"failed\" nil]"
