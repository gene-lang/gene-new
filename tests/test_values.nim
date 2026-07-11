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

  test "big ints preserve arbitrary precision decimal values":
    let x = newIntFromDecimal("9223372036854775808")
    let y = newIntFromDecimal("-9223372036854775809")
    check x.kind == vkInt
    check y.kind == vkInt
    check x.isHeapBacked
    check y.isHeapBacked
    check x.intToString == "9223372036854775808"
    check y.intToString == "-9223372036854775809"
    check intCompare(x, newInt(high(int64))) > 0
    expect FieldDefect:
      discard x.intVal

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
    var props = initPropTable()
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
    var metaA = initPropTable()
    var metaB = initPropTable()
    metaA["line"] = newInt(1)
    metaB["line"] = newInt(2)
    let a = newNode(newSym("x"), body = @[newInt(1)], meta = metaA)
    let b = newNode(newSym("x"), body = @[newInt(1)], meta = metaB)
    check equal(a, b)

  test "same uses scalar value identity and container heap identity":
    check same(newInt(10), newInt(10))
    check same(newInt(1'i64 shl 50), newInt(1'i64 shl 50))
    check same(newIntFromDecimal("9223372036854775808"),
               newIntFromDecimal("9223372036854775808"))
    check same(newStr("x"), newStr("x"))
    check not same(newList(@[newInt(1)]), newList(@[newInt(1)]))

  test "hash is meta-blind and restricted to stable values":
    var metaA = initPropTable()
    var metaB = initPropTable()
    metaA["line"] = newInt(1)
    metaB["line"] = newInt(2)
    let a = newNode(newSym("x"), body = @[newInt(1)], meta = metaA,
                    immutable = true)
    let b = newNode(newSym("x"), body = @[newInt(1)], meta = metaB,
                    immutable = true)
    check hash(a) == hash(b)
    check isHashStable(newList(@[newInt(1)], immutable = true))
    check not isHashStable(newList(@[newInt(1)]))
    check not isHashStable(newList(@[newCell(newInt(1))], immutable = true))

  test "float key equality and hashing follow the numeric contract":
    let positiveZero = newFloat(0.0)
    let negativeZero = newFloat(-0.0)
    let nan = newFloat(NaN)
    check equal(positiveZero, negativeZero)
    check hash(positiveZero) == hash(negativeZero)
    check not equal(nan, nan)
    check not isHashStable(nan)

suite "value — reference counting":
  # Managed values are manually heap-allocated and refcounted via Value's
  # =copy/=sink/=dup/=destroy hooks. This stress builds and drops nested, aliased
  # structures; it catches double-frees/corruption always, and (under
  # -d:geneRcStats) proves retain/release balance to zero.
  proc buildDrop() =
    var props = initPropTable()
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
