## Fast paths at typed boundaries. None of them may change what a program
## observes, so every expected value here was taken from the runtime before
## the fast path existed.
import gene/[compiler, gir, printer, types, vm]
import std/unittest

template fastCk(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

proc protoNamed(chunk: Chunk, name: string): FunctionProto =
  for proto in chunk.functions:
    if proto.name == name:
      return proto
  nil

suite "typed node push checks only the new item when that is exact":
  test "an alias that broke a container field is still reported":
    fastCk """
      (type B ^props {^xs (List Int)} ^body [Int...])
      (let xs [1]) (let b (B ^xs xs)) (b .push 1) (xs .push "bad")
      [(try (b .push 2) catch TypeError $err/where) b]""",
      """["field 'xs' for B" ((type B) ^xs [1 "bad"] 1)]"""

  test "a rejected item leaves the node as it was and later pushes work":
    fastCk """
      (type Bag ^props {^x Int} ^body [Int...])
      (let bag (Bag ^x 1)) (bag .push 1) (bag .push 2)
      (let rejected (try (bag .push "no") catch TypeError $err/where))
      (let pushed (bag .push 3))
      [rejected pushed bag]""",
      """["body field 2 for Bag" 3 ((type Bag) ^x 1 1 2 3)]"""

  test "a field write between pushes":
    fastCk """
      (type Bag ^props {^x Int} ^body [Int...])
      (let bag (Bag ^x 1)) (bag .push 1) (set bag/x 5) (bag .push 2)
      (let rejected (try (set bag/x "s") catch TypeError $err/where))
      (bag .push 3)
      [rejected bag]""",
      """["field 'x' for Bag" ((type Bag) ^x 5 1 2 3)]"""

  test "fixed body items, a rest type, and an Any field that changes":
    fastCk """
      (type F ^props {^n Any} ^body [Str Float...])
      (let anyv [1 2])
      (let f (F ^n anyv "head"))
      (let rejected (try (f .push 1) catch TypeError $err/where))
      (f .push 1.5) (anyv .push "x") (f .push 2.5)
      [rejected f]""",
      """["body field 1 for F" ((type F) ^n [1 2 "x"] "head" 1.5 2.5)]"""

  test "a frozen node, a fixed-length body, and an optional field":
    fastCk """
      (type Bag ^props {^x Int} ^body [Int...])
      (type Fixed ^props {^x Int} ^body [Int Int])
      (type Opt ^props {^x Int ^y Int?} ^body [Int...])
      (let frozen ($freeze (Bag ^x 1 7)))
      (let fx (Fixed ^x 1 2 3))
      (let o (Opt ^x 1)) (o .push 1) (o .push 2)
      [(try (frozen .push 8) catch Error $err_msg)
       (try (frozen .push "s") catch TypeError $err/where)
       (try (fx .push 4) catch Error $err_msg)
       o]""",
      """["cannot mutate immutable Node" "body field 1 for Bag" """ &
      """"Fixed expects 2 body item(s), got 3" ((type Opt) ^x 1 1 2)]"""

  test "many pushes keep every item":
    fastCk """
      (type Bag ^props {^x Int} ^body [Int...])
      (let bag (Bag ^x 1))
      (repeat i in 5000 (bag .push i))
      (var total 0)
      (repeat i in 5000 (set total (+ total bag/%i)))
      [total bag/4999 bag/x]""", "[12497500 4999 1]"

suite "a List boundary with a scalar item type":
  const listPrelude = """
    (fn total [xs : (List Int)] ($size xs))
    (fn names [xs : (List Str)] ($size xs))
    (fn floats [xs : (List Float)] ($size xs))
    (fn nested [xs : (List (List Int))] ($size xs))
    (fn anys [xs : (List Any)] ($size xs))
    """

  test "a list checked once is rechecked after a store of another kind":
    fastCk listPrelude & """
      (let xs [1 2 3]) (let first [(total xs) (total xs)])
      (xs .push "s")
      (let ys [1 2]) (total ys) (set ys/0 "a")
      (let es []) (let empty (total es)) (es .push "s")
      [first
       (try (total xs) catch TypeError $err_msg)
       (try (total ys) catch TypeError $err_msg)
       empty
       (try (total es) catch TypeError $err_msg)]""",
      """[[3 3] "parameter 'xs' expected (List Int), got (List Any)" """ &
      """"parameter 'xs' expected (List Int), got (List Any)" 0 """ &
      """"parameter 'xs' expected (List Int), got (List Str)"]"""

  test "stores of the same kind keep the list accepted":
    fastCk listPrelude & """
      (let ms [1 2]) (total ms) (ms .push 3) (ms .push 4)
      (let zs [1 2]) (total zs) (zs .push 99999999999999999999999)
      (let fr ($freeze [1 2]))
      [(total ms) (total zs) (total fr) (total fr)]""", "[4 3 2 2]"

  test "the same list against other item types":
    fastCk listPrelude & """
      (let ws [1 2]) (total ws)
      (let fs [1.5 2.5]) (let ok [(floats fs) (floats fs)]) (fs .push 3)
      [(try (names ws) catch TypeError $err_msg)
       (try (floats ws) catch TypeError $err_msg)
       (anys ws) ok
       (try (floats fs) catch TypeError $err_msg)]""",
      """["parameter 'xs' expected (List Str), got (List Int)" """ &
      """"parameter 'xs' expected (List Float), got (List Int)" 2 [2 2] """ &
      """"parameter 'xs' expected (List Float), got (List Any)"]"""

  test "a nested item type is still checked item by item":
    fastCk listPrelude & """
      (let ns [[1] [2]]) (let ok [(nested ns) (nested ns)])
      (ns/0 .push "x")
      [ok (try (nested ns) catch TypeError $err_msg)]""",
      """[[2 2] "parameter 'xs' expected (List (List Int)), got (List Any)"]"""

  test "a function pushed into a checked list":
    fastCk listPrelude & """
      (fn outer [] (var q 2) (fn local [] q) (let hs [1]) (total hs) (hs .push local) hs)
      (try (total (outer)) catch TypeError $err_msg)""",
      """"parameter 'xs' expected (List Int), got (List Any)""""
