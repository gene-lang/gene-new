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

suite "match — combinators":
  test "alternation matches any branch":
    ck "(match 3 (when (| 1 2 3) \"small\") (else \"big\"))", "\"small\""
    ck "(match 9 (when (| 1 2 3) \"small\") (else \"big\"))", "\"big\""
  test "conjunction requires all and binds":
    ck "(match 5 (when (& x (| 4 5 6)) x))", "5"
  test "negation matches the complement":
    ck "(match 7 (when (not 0) \"nonzero\") (else \"zero\"))", "\"nonzero\""

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

suite "loops — for":
  test "for over a list":
    ck "(var s 0) (for x [1 2 3 4] (set s (+ s x))) s", "10"
  test "for with a destructuring pattern":
    ck "(var s 0) (for [a b] [[1 2] [3 4]] (set s (+ s (* a b)))) s", "14"
  test "for over a map yields key/value pairs":
    ck "(var ks \"\") (for [k v] {^a 1 ^b 2} (set ks (+ 0 v))) ks", "2"
  test "for evaluates to nil":
    ck "(for x [1 2 3] x)", "nil"
  test "for over nil iterates zero times":
    ck "(var s 0) (for x nil (set s 1)) s", "0"
