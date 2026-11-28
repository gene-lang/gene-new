import gene/[types, compiler, vm, printer, keyindex]
import std/[hashes, os, unittest]

proc eval(source: string): string =
  run(compileSource(source), newGlobalScope()).print()

suite "KeyIndex":
  test "every position is found, for hashes of any size and sign":
    # The slot is computed from the high word of a 64-bit product. It has to be
    # masked as an unsigned value: narrowing it first raises on wasm32, where
    # `int` is 32 bits wide.
    var hashes: seq[Hash]
    for i in 0 ..< 200:
      hashes.add Hash(i)
      hashes.add Hash(-i - 1)
    hashes.add Hash(high(int))
    hashes.add Hash(low(int))
    hashes.add Hash(0x7fffffff)
    hashes.add Hash(-0x80000000)
    hashes.add Hash(0x9e3779b9)
    var index: KeyIndex
    for position, h in hashes:
      index.add h
      check index.covers(position + 1) == (position + 1 >= KeyIndexMin)
    for position, h in hashes:
      var found = false
      for candidate in index.candidates(h):
        if candidate == position: found = true
      check found

  test "equal hashes yield every position that carries them":
    var index: KeyIndex
    for i in 0 ..< 40: index.add Hash(i mod 3)
    var count = 0
    for candidate in index.candidates(Hash(1)): inc count
    check count == 13

suite "indexed Sets and HashMaps keep the linear scan's answers":
  # The container's own index is only used when its keys are hash-stable and
  # distinct. A raw vector (read, quoted) is checked first, and anything else
  # keeps the scan: these answers are the ones the scan gives.
  test "a quoted map with a repeated key keeps assoc's last-write-wins rebuild":
    check eval("(let m (quote {{\"k\" : 1 \"a\" : 2 \"b\" : 3 \"c\" : 4 " &
      "\"d\" : 5 \"e\" : 6 \"f\" : 7 \"k\" : 2}})) " &
      "[($map_size m) ($map_size (m .assoc \"extra\" 9)) (m .get \"k\")]") ==
      "[8 8 1]"

  test "a key changed after the map was read is found by its new contents":
    check eval("(let n (quote {{[1] : 1 \"a\" : 2 \"b\" : 3 \"c\" : 4 " &
      "\"d\" : 5 \"e\" : 6 \"f\" : 7 \"g\" : 8}})) " &
      "(n .get #[1]) (map_for [k v] in n (if (== v 1) (k .push 2))) " &
      "[(n .get #[1 2]) (n .get #[1])]") == "[1 nil]"

  test "assoc on a map with an unstable key still raises HashStable":
    check eval("(let o (quote {{[1] : 1 \"a\" : 2 \"b\" : 3 \"c\" : 4 " &
      "\"d\" : 5 \"e\" : 6 \"f\" : 7 \"g\" : 8}})) " &
      "(try ($map_size (o .assoc \"x\" 1)) catch TypeFault \"TypeFault\")") ==
      "\"TypeFault\""

  test "colliding witness hashes still resolve by equality":
    # Kept in its own process: run in the spec runner after a witness-heavy
    # case, the actor suite's ReplyTo test fails with "ValueEq cannot be added
    # after Type activation" (the same on main), so some state leaks there.
    proc declare(name: string): string =
      "(type " & name & " ^props {^n Int}) " &
        "(impl ValueEq for " & name &
        " (message equal [other : " & name & "] : Bool " &
        "   (== self/n other/n))) " &
        "(impl ValueHash for " & name & " (message hash [] : Int 5)) "
    var keys = ""
    for i in 0 ..< 24: keys.add "#(CollideSetKey ^n " & $i & ") "
    check eval(declare("CollideSetKey") &
      "(let s (Set " & keys & " #(CollideSetKey ^n 3))) " &
      "[($set_size s) ($set_has? s #(CollideSetKey ^n 23)) " &
      " ($set_has? s #(CollideSetKey ^n 24))]") == "[24 true false]"
    var entries = ""
    for i in 0 ..< 24:
      entries.add "#(CollideMapKey ^n " & $i & ") : " & $i & " "
    check eval(declare("CollideMapKey") & "(let m {{" & entries & "}}) " &
      "(let n (m .assoc #(CollideMapKey ^n 24) 24)) " &
      "(let o (n .assoc #(CollideMapKey ^n 5) 50)) " &
      "[($map_size m) (m .get #(CollideMapKey ^n 17)) " &
      " (m .get #(CollideMapKey ^n 24)) (n .get #(CollideMapKey ^n 24)) " &
      " ($map_size o) (o .get #(CollideMapKey ^n 5)) (== m n)]") ==
      "[24 17 nil 24 25 50 false]"
