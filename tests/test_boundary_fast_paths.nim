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

suite "scalar annotations on the scopeless calling convention":
  const calls = """
    (fn id_int [a : Int] a)
    (fn add_p [a : Int b : Int] (+ a b))
    (fn addf [a : Float b : Float] (+ a b))
    (fn mixed [a : Str b c : Bool] [a b c])
    (fn ret_any [a : Int] : Any a)
    (fn ret_const [a : Str] : Int 5)
    (fn ret_checked [a : Str] : Int a)
    (fn deep [n : Int] (id_int (id_int n)))
    (fn down [n : Int] (if (< n 1) 0 (+ n (down (- n 1)))))
    (fn named_like [Int : Str] Int)
    """

  test "the admitted shapes get a scopeless chunk, the others do not":
    let chunk = compileSource(calls & " nil")
    for name in ["id_int", "add_p", "addf", "mixed", "ret_any", "ret_const"]:
      checkpoint name
      check chunk.protoNamed(name).scopelessChunk != nil
    # A declared result the compiler cannot prove keeps its return boundary.
    check chunk.protoNamed("ret_checked").scopelessChunk == nil

  test "arguments that satisfy the annotations":
    fastCk calls & """
      [(id_int 5) (add_p 2 3) (addf 1.5 2.0) (mixed "s" [1] true)
       (ret_any 3) (ret_const "x") (deep 4) (down 100) (named_like "x")]""",
      """[5 5 3.5 ["s" [1] true] 3 5 4 5050 "x"]"""

  test "an argument the scan rejects takes the classic convention":
    # A big integer is an Int that is not a small one; the classic binder
    # accepts it.
    fastCk calls & "(id_int 99999999999999999999999)", "99999999999999999999999"

  test "mismatches raise the same errors as before":
    fastCk calls & """
      [(try (id_int "s") catch TypeError $err_msg)
       (try (add_p 2 "x") catch TypeError $err_msg)
       (try (add_p 2 1.5) catch TypeError $err_msg)
       (try (addf 1 2) catch TypeError $err_msg)
       (try (addf 1.5 2) catch TypeError $err_msg)
       (try (mixed "s" [1] 1) catch TypeError $err_msg)
       (try (mixed nil 1 true) catch TypeError $err_msg)
       (try (ret_const 1) catch TypeError $err_msg)
       (try (ret_checked "s") catch TypeError $err_msg)
       (try (id_int 1 2) catch Error $err_msg)
       (try (id_int) catch Error $err_msg)]""",
      """["parameter 'a' expected Int, got Str" """ &
      """"parameter 'b' expected Int, got Str" """ &
      """"parameter 'b' expected Int, got Float" """ &
      """"parameter 'a' expected Float, got Int" """ &
      """"parameter 'b' expected Float, got Int" """ &
      """"parameter 'c' expected Bool, got Int" """ &
      """"parameter 'a' expected Str, got Nil" """ &
      """"parameter 'a' expected Str, got Int" """ &
      """"return from 'ret_checked' expected Int, got Str" """ &
      """"function 'id_int' expects 1..1 argument(s), got 2" """ &
      """"function 'id_int' expects 1..1 argument(s), got 0"]"""

  test "calls through a value and through a native":
    fastCk calls & """
      (var f id_int)
      [(f 6) (try (f (quote sym)) catch TypeError $err_msg) ([1 2 3] .map id_int)]""",
      """[6 "parameter 'a' expected Int, got Sym" [1 2 3]]"""

suite "field writes by key id":
  const fieldPrelude = """
    (type P ^props {^x Int ^y Float ^name Str? ^tags (List Str) ^any Any})
    (let p (P ^x 1 ^y 2.0 ^tags ["a"] ^any nil))
    """

  test "writes through a path, put with a string, and put with a symbol":
    fastCk fieldPrelude & """
      (set p/x 5) (set p/y 1.5) (set p/name "n") (set p/any [1 2])
      (let a (p .put "x" 7)) (let b (p .put (quote x) 8)) (let c (set p/x 9))
      [a b c p]""",
      """[7 8 9 ((type P) ^x 9 ^y 1.5 ^tags ["a"] ^any [1 2] ^name "n")]"""

  test "a value the field rejects, and a field that does not exist":
    fastCk fieldPrelude & """
      [(try (set p/x "s") catch TypeError $err_msg)
       (try (set p/y 1) catch TypeError $err_msg)
       (try (set p/tags [1]) catch TypeError $err_msg)
       (try (set p/x nil) catch TypeError $err_msg)
       (try (p .put "x" 1.5) catch TypeError $err_msg)
       (try (set p/zzz 1) catch Error $err_msg)
       (try (p .put "nope" 1) catch Error $err_msg)
       p]""",
      """["field 'x' for P expected Int, got Str" """ &
      """"field 'y' for P expected Float, got Int" """ &
      """"field 'tags' for P expected (List Str), got (List Int)" """ &
      """"field 'x' for P expected Int, got Nil" """ &
      """"field 'x' for P expected Int, got Float" """ &
      """"P has no field 'zzz'" "P has no field 'nope'" """ &
      """((type P) ^x 1 ^y 2.0 ^tags ["a"] ^any nil)]"""

  test "an optional field takes nil and an Int field takes a big integer":
    fastCk fieldPrelude & """
      (set p/name "n") (set p/name nil) (set p/x 99999999999999999999999)
      [p/name p/x]""", "[nil 99999999999999999999999]"

  test "a frozen typed node and an untyped node":
    fastCk fieldPrelude & """
      (let frozen ($freeze p))
      (let plain (quote (data ^a 1)))
      (set plain/a 2) (set plain/b "new")
      [(try (set frozen/x 2) catch Error $err_msg) plain]""",
      """["cannot mutate immutable Node" (data ^a 2 ^b "new")]"""

  test "a message that writes its own field":
    fastCk """
      (type C ^props {^n Int} (message inc [d] (set self/n (+ self/n d))))
      (let c (C ^n 0)) (repeat i in 1000 (c .inc 1))
      c/n""", "1000"

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
