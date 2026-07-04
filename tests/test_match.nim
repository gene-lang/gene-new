import gene/[compiler, types, vm, printer]
import std/unittest

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

suite "match — scalars and selection":
  test "first matching clause wins":
    ck "(match 2 (when 1 \"one\") (when 2 \"two\") (else \"other\"))", "\"two\""
  test "else runs when nothing matches":
    ck "(match 5 (when 1 \"one\") (else \"other\"))", "\"other\""
  test "no clause and no else raises MatchError":
    expect MatchError: discard runStr("(match 9 (when 1 \"one\"))")
  test "bare name binds the whole value":
    ck "(match 7 (when x (* x x)))", "49"
  test "wildcard matches anything":
    ck "(match 42 (when _ \"yes\"))", "\"yes\""
  test "%name compares to a lexical value":
    ck "(var k 3) (match 3 (when %k \"hit\") (else \"miss\"))", "\"hit\""
    ck "(var k 3) (match 4 (when %k \"hit\") (else \"miss\"))", "\"miss\""

suite "match — structural patterns":
  test "list pattern binds positionally":
    ck "(match [1 2 3] (when [a b c] (+ a b c)))", "6"
  test "list arity must match without a rest":
    ck "(match [1 2] (when [a b c] \"3\") (else \"no\"))", "\"no\""
  test "rest pattern captures the tail":
    ck "(match [1 2 3 4] (when [head rest...] rest))", "[2 3 4]"
    ck "(match [1 2 3 4] (when [head rest...] head))", "1"
  test "map pattern is open and binds fields":
    ck "(match {^type \"circle\" ^r 5} (when {^type \"circle\" ^r r} r))", "5"
  test "map pattern fails on a missing key":
    ck "(match {^a 1} (when {^b b} \"yes\") (else \"no\"))", "\"no\""
  test "ordinary node patterns ignore meta":
    ck "(match (quote (x @line 7 ^a 1)) (when (x ^a a) a))", "1"
  test "meta patterns match explicit node meta":
    ck "(match (quote (x @line 7 ^name \"Ada\")) " &
       "(when (@ {^line l} (x ^name n)) [l n]))",
       "[7 \"Ada\"]"
    ck "(match (quote (x @line 7)) " &
       "(when (@ {^line 8} x) \"bad\") (else \"ok\"))",
       "\"ok\""
  test "meta patterns treat scalars as empty meta":
    ck "(match 42 (when (@ {} n) n))", "42"
  test "meta patterns require meta and value patterns":
    expect GeneError: discard runStr("(match 1 (when (@ {}) 1))")

suite "match — typed patterns":
  test "typed patterns bind only matching values":
    ck "(match \"hi\" (when (s : Str) s) (else \"no\"))", "\"hi\""
    ck "(match 1 (when (s : Str) s) (else \"no\"))", "\"no\""
    ck "(match \"hi\" (when (_ : Str) \"str\") (else \"no\"))", "\"str\""
  test "typed patterns adapt streams lazily":
    ck "(try (match (to_stream [\"bad\"]) " &
       "       (when (s : (Stream Int Never)) (s ~ Stream/next))) " &
       "catch (TypeError ^where w) w)",
       "\"Stream/next item\""
  test "typed catch patterns match error types":
    ck "(try (fn f [x : Int] x) (f \"bad\") " &
       "catch (e : TypeError) e/where)",
       "\"parameter 'x'\""
  test "typed patterns require exactly one type":
    expect GeneError: discard runStr("(match 1 (when (x :) x))")

suite "match — combinators":
  test "alternation matches any branch":
    ck "(match 3 (when (| 1 2 3) \"small\") (else \"big\"))", "\"small\""
    ck "(match 9 (when (| 1 2 3) \"small\") (else \"big\"))", "\"big\""
  test "alternation branches must bind the same names":
    ck "(match [2 7] (when (| [1 a] [2 a]) a))", "7"
    expect GeneError: discard runStr("(match [1] (when (| [a] [b]) a))")
    expect GeneError: discard runStr("(match [1] (when (| [a] [_]) a))")
  test "conjunction requires all and binds":
    ck "(match 5 (when (& x (| 4 5 6)) x))", "5"
  test "negation matches the complement":
    ck "(match 7 (when (not 0) \"nonzero\") (else \"zero\"))", "\"nonzero\""
  test "negation must not bind names":
    expect GeneError: discard runStr("(match 1 (when (not x) \"no\") (else \"ok\"))")
    expect GeneError: discard runStr("(match 1 (when (| _ (not x)) \"no\"))")

suite "match — branch scope":
  test "pattern bindings are local to the selected branch":
    expect GeneError: discard runStr("(match [1 2] (when [a b] (+ a b))) a")
  test "branch body declarations are local":
    expect GeneError:
      discard runStr("(match 1 (when x (var y x) y)) y")
  test "branch bodies can update outer bindings":
    ck "(var total 0) (match [1 2] (when [a b] (set total (+ a b)))) total", "3"

suite "destructuring — var":
  test "list destructuring":
    ck "(var [x y] [10 20]) (+ x y)", "30"
  test "nested list destructuring":
    ck "(var [a [b c]] [1 [2 3]]) (+ a b c)", "6"
  test "rest in var":
    ck "(var [first rest...] [1 2 3 4]) rest", "[2 3 4]"
  test "map destructuring":
    ck "(var {^name n ^age a} {^name \"Ada\" ^age 36}) (+ a 0)", "36"
  test "destructuring failure raises MatchError":
    expect MatchError: discard runStr("(var [a b c] [1 2])")

suite "loops — while":
  test "while accumulates until the condition is false":
    ck "(var i 0) (var s 0) (while (< i 5) (set s (+ s i)) (set i (+ i 1))) s", "10"
  test "while with a false condition runs zero times":
    ck "(var s 99) (while false (set s 0)) s", "99"
  test "while evaluates to nil":
    ck "(while false 1)", "nil"
  test "while supports break and continue":
    ck "(var i 0) (var s 0) " &
       "(while true " &
       "  (set i (+ i 1)) " &
       "  (if (= i 2) (then (continue))) " &
       "  (if (> i 4) (then (break))) " &
       "  (set s (+ s i))) " &
       "[s i]",
       "[8 5]"
  test "loop supports break and continue":
    ck "(var i 0) (var s 0) " &
       "(loop " &
       "  (set i (+ i 1)) " &
       "  (if (= i 2) (then (continue))) " &
       "  (if (> i 4) (then (break))) " &
       "  (set s (+ s i))) " &
       "[s i]",
       "[8 5]"
  test "repeat supports break and continue":
    ck "(var i 0) (var s 0) " &
       "(repeat 6 " &
       "  (set i (+ i 1)) " &
       "  (if (= i 2) (then (continue))) " &
       "  (if (> i 4) (then (break))) " &
       "  (set s (+ s i))) " &
       "[s i]",
       "[8 5]"
  test "indexed repeat provides a zero-based index":
    ck "(var s 0) " &
       "(repeat i in 5 " &
       "  (set s (+ s i))) " &
       "s",
       "10"
  test "indexed repeat supports break and continue":
    ck "(var s 0) " &
       "(repeat i in 6 " &
       "  (if (= i 2) (then (continue))) " &
       "  (if (> i 4) (then (break))) " &
       "  (set s (+ s i))) " &
       "s",
       "8"
  test "repeat evaluates count once":
    ck "(var n 0) (repeat (do (set n (+ n 1)) 3) nil) n", "1"
    ck "(var n 0) (repeat i in (do (set n (+ n 1)) 3) nil) n", "1"
  test "repeat non-positive count runs zero times":
    ck "(var n 0) (repeat 0 (set n 1)) (repeat -1 (set n 2)) " &
       "(repeat i in 0 (set n 3)) (repeat j in -1 (set n 4)) n",
       "0"
  test "loop and repeat validate shape":
    expect GeneError: discard runStr("(loop)")
    expect GeneError: discard runStr("(repeat)")
    expect GeneError: discard runStr("(repeat [i] in 3 nil)")

suite "loops — for":
  test "for over a list":
    ck "(var s 0) (for x in [1 2 3 4] (set s (+ s x))) s", "10"
  test "for with a destructuring pattern":
    ck "(var s 0) (for [a b] in [[1 2] [3 4]] (set s (+ s (* a b)))) s", "14"
  test "for over a map yields key/value pairs":
    ck "(var pair nil) (for [k v] in {^a 1} (set pair [k v])) pair", "[a 1]"
  test "for over a stream pulls items lazily":
    ck "(var hits (cell 0)) " &
       "(var source (map (to_stream [1 2 3]) " &
       "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
       "(var first-hits 0) " &
       "(for x in source " &
       "  (if (= x 1) (set first-hits (hits ~ Cell/get)))) " &
       "first-hits",
       "1"
  test "for closes stream on destructuring failure":
    ck "(var hits (cell 0)) " &
       "(var source (map (to_stream [1 2 3]) " &
       "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
       "(try (for [a b] in source nil) catch (MatchError ^message m) nil) " &
       "[(hits ~ Cell/get) (source ~ Stream/has_next)]",
       "[1 false]"
  test "for closes stream on body error":
    ck "(var hits (cell 0)) " &
       "(var source (map (to_stream [1 2 3]) " &
       "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
       "(try (for x in source (/ 1 0)) catch {^message m} nil) " &
       "[(hits ~ Cell/get) (source ~ Stream/has_next)]",
       "[1 false]"
  test "for supports break and continue":
    ck "(var s 0) " &
       "(for x in [1 2 3 4 5] " &
       "  (if (= x 2) (then (continue))) " &
       "  (if (> x 4) (then (break))) " &
       "  (set s (+ s x))) " &
       "s",
       "8"
  test "for break closes streams":
    ck "(var hits (cell 0)) " &
       "(var source (map (to_stream [1 2 3]) " &
       "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
       "(for x in source (break)) " &
       "[(hits ~ Cell/get) (source ~ Stream/has_next)]",
       "[1 false]"
  test "for over a string yields chars":
    ck "(var out [nil nil]) (var i 0) " &
       "(for ch in \"Aé\" " &
       "  (set out (List/assoc out i ch)) " &
       "  (set i (+ i 1))) " &
       "out",
       "['A' 'é']"
  test "for evaluates to nil":
    ck "(for x in [1 2 3] x)", "nil"
  test "for over nil iterates zero times":
    ck "(var s 0) (for x in nil (set s 1)) s", "0"
  test "for requires in":
    expect GeneError: discard runStr("(for x [1] x)")
  test "break and continue require a loop":
    expect GeneError: discard runStr("(break)")
    expect GeneError: discard runStr("(continue)")
