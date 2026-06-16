import gene/types
import gene/equality
import std/[tables, unittest]

suite "value — NaN boxing":
  test "value is one machine word":
    check sizeof(Value) == sizeof(uint64)

  test "zero-initialized values are nil":
    let empty: Value = default(Value)
    let slots = newSeq[Value](3)
    check empty.kind == vkNil
    check empty.isNil
    check slots[0].kind == vkNil
    check slots[1].isNil

  test "small ints are immediate and preserve signed payloads":
    let a = newInt(42)
    let b = newInt(-17)
    check a.kind == vkInt
    check b.kind == vkInt
    check not a.isHeapBacked
    check not b.isHeapBacked
    check a.intVal == 42
    check b.intVal == -17

  test "large ints fall back to heap payloads":
    let x = newInt(1'i64 shl 50)
    check x.kind == vkInt
    check x.isHeapBacked
    check x.intVal == (1'i64 shl 50)

  test "non-zero floats are stored directly":
    let x = newFloat(3.5)
    check x.kind == vkFloat
    check not x.isHeapBacked
    check x.floatVal == 3.5

  test "positive zero float is boxed immediate because zero bits mean nil":
    let x = newFloat(0.0)
    let y = newFloat(0.0)
    check x.kind == vkFloat
    check not x.isHeapBacked
    check x.floatVal == 0.0
    check x.bits == y.bits

  test "heap values preserve structure":
    var props = initOrderedTable[string, Value]()
    props["name"] = newStr("Ada")
    let n = newNode(newSym("user"), props = props, body = @[newInt(1)])
    check n.kind == vkNode
    check n.isHeapBacked
    check n.head.symVal == "user"
    check n.props["name"].strVal == "Ada"
    check n.body[0].intVal == 1

  test "symbols are interned":
    let a = newSym("user")
    let b = newSym("user")
    check a.bits == b.bits
    check a.symVal == "user"

suite "value — equality":
  test "structural equality is meta-blind":
    var metaA = initOrderedTable[string, Value]()
    var metaB = initOrderedTable[string, Value]()
    metaA["line"] = newInt(1)
    metaB["line"] = newInt(2)
    let a = newNode(newSym("x"), body = @[newInt(1)], meta = metaA)
    let b = newNode(newSym("x"), body = @[newInt(1)], meta = metaB)
    check equal(a, b)

  test "same uses scalar value identity and container heap identity":
    check same(newInt(10), newInt(10))
    check same(newInt(1'i64 shl 50), newInt(1'i64 shl 50))
    check same(newStr("x"), newStr("x"))
    check not same(newList(@[newInt(1)]), newList(@[newInt(1)]))

suite "value — reference counting":
  # Managed values are manually heap-allocated and refcounted via Value's
  # =copy/=sink/=dup/=destroy hooks. This stress builds and drops nested, aliased
  # structures; it catches double-frees/corruption always, and (under
  # -d:geneRcStats) proves retain/release balance to zero.
  proc buildDrop() =
    var props = initOrderedTable[string, Value]()
    props["name"] = newStr("a-heap-allocated-string")
    let shared = newStr("shared")              # aliased -> refCount 2
    let n = newNode(newSym("user"), props = props,
                    body = @[shared, shared,
                             newList(@[newInt(1), newInt(1'i64 shl 50)]),
                             newMap(props)])
    check n.head.symVal == "user"
    check n.body[0].strVal == "shared"
    check n.body[2].listItems[1].intVal == (1'i64 shl 50)

  test "build/drop nested aliased structures does not crash or leak":
    when defined(geneRcStats):
      check liveManaged == 0
    for _ in 0 ..< 20_000:
      buildDrop()
    when defined(geneRcStats):
      check liveManaged == 0   # retain/release balanced after all drops
