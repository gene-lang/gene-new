import std/[strutils, unittest]
import gene/[compiler, equality, printer, types, vm]

const cyclicPrelude = """
  (type Parent ^props {^name Str ^child Any?})
  (type Child ^props {^name Str ^parent Any})
  (fn cyclic [name : Str]
    (var p (Parent ^name name ^child nil))
    (var c (Child ^name "c" ^parent p))
    (set p/child c)
    p)
  (fn self_map []
    (let m {^name "m"})
    (m .put "self" m)
    m)
  (fn make_nodes [count : Int]
    (let nodes [])
    (var i 0)
    (while (< i count)
      (nodes .push {^id i})
      (set i (+ i 1)))
    nodes)
  (fn ring [last : Int]
    (let nodes (make_nodes 100))
    ((nodes .get 99) .put "id" last)
    (var i 0)
    (while (< i 100)
      ((nodes .get i) .put "next" (nodes .get (if (== i 99) 0 (+ i 1))))
      (set i (+ i 1)))
    (nodes .get 0))
  (fn nest [depth : Int]
    (var v [0])
    (var i 0)
    (while (< i depth)
      (set v [v])
      (set i (+ i 1)))
    v)
"""

proc evalCyclic(source: string): Value =
  run(compileSource(cyclicPrelude & source), newGlobalScope())

template cyclicCheck(source, expected: string) =
  check evalCyclic(source).print() == expected

suite "cyclic values":
  test "printing marks a cycle in a map, a list and typed values":
    let map = evalCyclic("($to_str (self_map))").strVal
    check map.contains("(cycle)")
    check map.contains("^name \"m\"")
    let list = evalCyclic("(let l [1]) (l .push l) ($to_str l)").strVal
    check list.contains("(cycle)")
    let typed = evalCyclic("($to_str (cyclic \"p\"))").strVal
    check typed.contains("(cycle)")
    check typed.contains("^name \"p\"")
    check typed.contains("^name \"c\"")

  test "printing a densely connected cyclic graph finishes":
    let text = evalCyclic("""
      (let nodes (make_nodes 40))
      (for a in nodes
        (for b in nodes (a .put ($to_str "n" b/id) b)))
      ($to_str (nodes .get 0))
    """).strVal
    check text.contains("(cycle)")
    check text.contains("(seen)")

  test "ordinary values print exactly as before":
    cyclicCheck """
      (let shared [1 2])
      ($to_str [shared shared {^a shared}])
    """, "\"[[1 2] [1 2] {^a [1 2]}]\""

  test "a deep acyclic value prints in full with no markers":
    let text = evalCyclic("($to_str (nest 200))").strVal
    check not text.contains("(cycle)")
    check not text.contains("(seen)")
    check text.count('[') == 201

  test "equality terminates on cycles":
    cyclicCheck "(let p (cyclic \"p\")) (== p p)", "true"
    cyclicCheck "(== (cyclic \"p\") (cyclic \"p\"))", "true"
    cyclicCheck "(== (cyclic \"p\") (cyclic \"q\"))", "false"
    cyclicCheck "(== (self_map) (self_map))", "true"

  test "equality distinguishes cycles that differ deep inside":
    cyclicCheck "[(== (ring 99) (ring 99)) (== (ring 99) (ring -1))]", "[true false]"

  test "ordinary equality keeps its meaning":
    cyclicCheck "(let l [1 [2]]) (== l [1 [2]])", "true"
    cyclicCheck "(== [1 [2]] [1 [3]])", "false"
    cyclicCheck "(== (nest 200) (nest 200))", "true"
    cyclicCheck "(== (nest 200) (nest 201))", "false"

  test "freeze and thaw raise a catchable error on a cycle":
    cyclicCheck """
      (try ($freeze (cyclic "p")) "frozen" catch Any $err/message)
    """, "\"freeze cannot freeze a cyclic value\""
    cyclicCheck """
      (try ($freeze (self_map)) "frozen" catch Any $err/message)
    """, "\"freeze cannot freeze a cyclic value\""
    cyclicCheck """
      (try ($thaw (self_map)) "thawed" catch Any $err/message)
    """, "\"thaw cannot copy a cyclic value\""

  test "a failed freeze leaves later freezes working":
    cyclicCheck """
      (try ($freeze (self_map)) catch Any nil)
      ($freeze [1 [2]])
    """, "#[1 #[2]]"

  test "deep acyclic values still freeze":
    cyclicCheck """
      (let v (nest 400))
      (== ($freeze v) v)
    """, "true"

  test "the structural equal operation also terminates on cycles":
    let left = evalCyclic("(cyclic \"p\")")
    let right = evalCyclic("(cyclic \"p\")")
    let different = evalCyclic("(cyclic \"q\")")
    check equal(left, left)
    # Separate programs declare separate types, so these heads differ by identity.
    check not equal(left, right)
    check not equal(left, different)
    let map = evalCyclic("(self_map)")
    let otherMap = evalCyclic("(self_map)")
    check equal(map, otherMap)

  test "an evaluation environment can hold a cyclic value":
    cyclicCheck """
      (let p (cyclic "p"))
      (let e (env ^bindings {^p p ^m (self_map)}))
      (eval `[p/name p/child/parent/name m/name] ^in e)
    """, "[\"p\" \"p\" \"m\"]"

  test "a function in a cyclic binding stays callable":
    cyclicCheck """
      (let m (self_map))
      (m .put "f" (fn [] "called"))
      (let e (env ^bindings {^m m}))
      (eval `((/f m)) ^in e)
    """, "\"called\""

  test "a repl session can hold a densely connected cyclic value":
    cyclicCheck """
      (let nodes (make_nodes 30))
      (for a in nodes
        (for b in nodes (a .put ($to_str "n" b/id) b)))
      (let session ($repl/open (env ^bindings {^n (nodes .get 0)})))
      ($repl/eval session "n/id")
    """, "0"
