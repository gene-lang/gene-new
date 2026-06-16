import gene/[types, eval, printer]
import std/unittest

template ck(src, expected: string) =
  ## Evaluate a program string and compare its printed result.
  check evalStr(src).print() == expected

suite "eval — literals and self-evaluation":
  test "scalars evaluate to themselves":
    ck "42", "42"
    ck "3.5", "3.5"
    ck "\"hi\"", "\"hi\""
    ck "true", "true"
    ck "nil", "nil"
    ck "'a'", "'a'"
  test "empty program is nil":
    ck "", "nil"
  test "vector evaluates its elements":
    ck "[1 (+ 1 2) 3]", "[1 3 3]"
  test "map evaluates its values":
    ck "{^a (+ 1 1) ^b 3}", "{^a 2 ^b 3}"
  test "quote suppresses evaluation":
    ck "(quote (+ 1 2))", "(+ 1 2)"

suite "eval — arithmetic":
  test "addition":
    ck "(+ 1 2 3)", "6"
  test "subtraction and negation":
    ck "(- 10 3 2)", "5"
    ck "(- 7)", "-7"
  test "multiplication":
    ck "(* 2 3 4)", "24"
  test "integer division":
    ck "(/ 12 3 2)", "2"
  test "float contagion":
    ck "(+ 1 2.5)", "3.5"
    ck "(/ 7.0 2)", "3.5"
  test "division by zero raises":
    expect GeneError: discard evalStr("(/ 1 0)")
  test "non-numbers raise":
    expect GeneError: discard evalStr("(+ 1 \"x\")")

suite "eval — comparison and logic":
  test "ordering is chained":
    ck "(< 1 2 3)", "true"
    ck "(< 1 3 2)", "false"
    ck "(>= 3 3 1)", "true"
  test "structural equality":
    ck "(= 2 2)", "true"
    ck "(= [1 2] [1 2])", "true"
    ck "(= 1 2)", "false"
  test "not":
    ck "(not false)", "true"
    ck "(not nil)", "true"
    ck "(not 1)", "false"

suite "eval — special forms":
  test "do returns last":
    ck "(do 1 2 3)", "3"
    ck "(do)", "nil"
  test "if compact form":
    ck "(if true 1 2)", "1"
    ck "(if false 1 2)", "2"
    ck "(if nil 1 2)", "2"
    ck "(if void 1 2)", "2"
    ck "(if 0 1 2)", "1"     # 0 is truthy; only false/nil/void are falsy
    ck "(if false 1)", "nil"
  test "if full form with then/elif/else":
    ck "(if (< 2 1) (then 10) (elif (< 1 2) 20) (else 30))", "20"
    ck "(if (< 2 1) (then 10) (else 30))", "30"
    ck "(if (< 1 2) (then 10) (else 30))", "10"
  test "var binds and returns the value":
    ck "(var x 5) x", "5"
    ck "(var x 5) (+ x 1)", "6"
  test "set reassigns an existing binding":
    ck "(var x 1) (set x 99) x", "99"
  test "set on an undefined name raises":
    expect GeneError: discard evalStr("(set nope 1)")
  test "undefined symbol raises":
    expect GeneError: discard evalStr("nope")

suite "eval — functions and closures":
  test "anonymous function application":
    ck "((fn [x] (+ x 1)) 41)", "42"
  test "named function in scope":
    ck "(var add (fn [a b] (+ a b))) (add 3 4)", "7"
  test "arity mismatch raises":
    expect GeneError: discard evalStr("((fn [x] x) 1 2)")
  test "closures capture their environment":
    ck "(var adder (fn [a] (fn [b] (+ a b)))) ((adder 10) 5)", "15"
  test "lexical capture is by reference to the defining scope":
    ck "(var x 1) (var get (fn [] x)) (set x 2) (get)", "2"
  test "recursion via a var-bound self reference":
    ck "(var fib (fn [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib 10)", "55"
  test "calling a non-callable raises":
    expect GeneError: discard evalStr("(1 2 3)")

suite "eval — printer view of callables":
  test "functions print a display form":
    ck "(fn [x] x)", "(fn)"                  # anonymous
    ck "(fn double [x] (* x 2))", "(fn double)"  # named form sets the name
    check evalStr("+").print() == "(native-fn +)"
