## A stored or returned value is scanned for weak scope edges. A container the
## scan proved to hold none is stamped, and the next scan stops there. These
## cases put something that needs the pass into a container after it was
## stamped, by every route the runtime has, and then let the container outlive
## the scope: the function or type must still work. Built with
## -d:geneInertStampTests they also check that the stamp is used at all.
import gene/[compiler, printer, types, vm]
import std/unittest

template inertCk(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

const inertPass = "(fn pass [x] x) "

suite "escape-inert stamps":
  test "a function pushed into a stamped list's child survives the return":
    inertCk inertPass & """
      (fn outer []
        (var x 41)
        (fn local [] (+ x 1))
        (var inner ($thaw #[]))
        (var p [inner])
        (pass p) (pass p)
        (inner .push local)
        (pass 1)
        p)
      (var r (outer))
      (var f r/0/0)
      (f)""", "42"

  test "a function put into a stamped map's child survives the return":
    inertCk inertPass & """
      (fn outer []
        (var x 41)
        (fn local [] (+ x 1))
        (var inner {^a 1})
        (var p {^inner inner})
        (pass p) (pass p)
        (inner .put "f" local)
        (pass 1)
        p)
      (var r (outer))
      ((r/inner .get "f"))""", "42"

  test "a literal holding a function, pushed into a stamped list":
    inertCk inertPass & """
      (fn build []
        (var x 5)
        (fn local [] (* x 2))
        (var holder [1 2])
        (pass holder) (pass holder)
        (var wrapped [local])
        (holder .push wrapped)
        holder)
      (var h (build))
      (h/2/0)""", "10"

  test "a function reached through a typed record's field":
    inertCk inertPass & """
      (type R ^props {^x Int ^items (List Any)})
      (fn make []
        (var y 3)
        (fn local [] (+ y 1))
        (var r (R ^x 1 ^items []))
        (pass r) (pass [r])
        (r/items .push local)
        (set r/x 2)
        r)
      (var r (make))
      ((r/items .get 0))""", "4"

  test "a record of a local type, stamped while the type held its scope":
    inertCk inertPass & """
      (fn late []
        (var k 10)
        (type T ^props {^v Int} (message get [] (+ self/v k)))
        (var xs [])
        (xs .push (T ^v 1))
        (pass xs) (pass 1)
        (var ys [xs])
        (pass ys) (pass ys)
        ys)
      (var ts (late))
      (ts/0/0 .get)""", "11"

  test "a cycle is never stamped, and a function added to it survives":
    inertCk inertPass & """
      (fn cyc []
        (var a ($thaw #[])) (var b ($thaw #[])) (a .push b) (b .push a)
        (pass a) (pass a)
        (var z 1) (fn local [] (+ z 6))
        (b .push [local])
        a)
      (var c (cyc))
      (c/0/1/0)""", "7"

  test "a shared child is stamped once and retired through either parent":
    inertCk inertPass & """
      (fn shared []
        (var leaf [1 2 3])
        (var x [leaf leaf])
        (pass x) (pass x)
        (var q 2) (fn local [] (* q 21))
        (leaf .push {^f local})
        x)
      (var s (shared))
      (s/1/3/f)""", "42"

  test "a node body push and a node prop set after stamping":
    inertCk inertPass & """
      (fn make []
        (var n 20)
        (fn local [] (+ n 2))
        (var node (quote (data ^x 1)))
        (var top [node])
        (pass top) (pass top)
        (node .push local)
        top)
      (var t (make))
      (var f t/0/0)
      (f)""", "22"

  test "a stamped value stays the same object and keeps its contents":
    inertCk inertPass & """
      (var state {^items [1 2 3] ^name "s"})
      (var a (pass state)) (var b (pass state))
      (state/items .push 4)
      (var again (pass state))
      [(same? a state) (same? b state) (pass state/items) ($size again/items)]""",
      "[true true [1 2 3 4] 4]"

  when defined(geneInertStampTests):
    test "the second scan of the same data is answered by its stamp":
      var items: seq[Value]
      for i in 0 ..< 100:
        var entries = initPropTable()
        entries["id"] = newInt(i)
        entries["name"] = newStr("item")
        items.add newMap(entries)
      let data = newList(items)
      let before = inertStampSkips
      check escapeWeakFunctions(data).bits == data.bits
      check inertStampSkips == before
      check escapeWeakFunctions(data).bits == data.bits
      check inertStampSkips == before + 1

    test "storing plain data keeps the stamp; storing a task retires it":
      let inner = newList(@[newInt(1)])
      let outer = newList(@[inner, newStr("x")])
      discard escapeWeakFunctions(outer)
      let epoch = inertEpochForTest()
      inner.pushListItem(newInt(2))
      inner.pushListItem(newStr("two"))
      let fresh = newList(@[newInt(3)])
      discard escapeWeakFunctions(fresh)
      inner.pushListItem(fresh)
      check inertEpochForTest() == epoch
      let skips = inertStampSkips
      discard escapeWeakFunctions(outer)
      check inertStampSkips == skips + 1
      # A task is a kind the pass must look at every time.
      inner.pushListItem(newPendingTask())
      check inertEpochForTest() == epoch + 1
      discard escapeWeakFunctions(outer)
      check inertStampSkips == skips + 1

    test "a container that was never scanned is not trusted when stored":
      let outer = newList(@[newInt(1)])
      discard escapeWeakFunctions(outer)
      let epoch = inertEpochForTest()
      outer.pushListItem(newList(@[newInt(2)]))
      check inertEpochForTest() == epoch + 1

    test "a store into an unstamped container costs nothing":
      let plain = newList(@[newInt(1)])
      let epoch = inertEpochForTest()
      plain.pushListItem(newPendingTask())
      check inertEpochForTest() == epoch

    test "sets and hash maps carry the stamp for what they reach":
      let inner = newList(@[newInt(1)])
      let table = newHashMap(@[HashMapEntry(key: newStr("k"), val: inner)])
      let outer = newList(@[table, newSet(@[newInt(1), newInt(2)])])
      discard escapeWeakFunctions(outer)
      let skips = inertStampSkips
      discard escapeWeakFunctions(outer)
      discard escapeWeakFunctions(table)
      check inertStampSkips == skips + 2
      let epoch = inertEpochForTest()
      inner.pushListItem(newPendingTask())
      check inertEpochForTest() == epoch + 1

    test "a published container is never stamped, nor anything holding it":
      let published = newList(@[newInt(1)])
      markSharedValue(published)
      let holder = newList(@[published])
      let skips = inertStampSkips
      discard escapeWeakFunctions(published)
      discard escapeWeakFunctions(published)
      discard escapeWeakFunctions(holder)
      discard escapeWeakFunctions(holder)
      check inertStampSkips == skips

    test "a container stamped before publication keeps its stamp":
      let data = newList(@[newInt(1)])
      discard escapeWeakFunctions(data)
      markSharedValue(data)
      let skips = inertStampSkips
      discard escapeWeakFunctions(data)
      check inertStampSkips == skips + 1
