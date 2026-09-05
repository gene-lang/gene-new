import gene/[types, compiler, vm, printer]
import std/unittest

proc evalBuffer(source: string): Value =
  run(compileSource(source), newGlobalScope())

suite "packed numeric buffers":
  test "fixed-width element types use their declared storage width":
    for (name, width, storage) in [
        ("I8", 1, bskI8), ("U8", 1, bskU8),
        ("I16", 2, bskI16), ("U16", 2, bskU16),
        ("I32", 4, bskI32), ("U32", 4, bskU32),
        ("I64", 8, bskI64), ("U64", 8, bskU64),
        ("F32", 4, bskF32), ("F64", 8, bskF64)]:
      let buffer = evalBuffer("($buffer " & name & " 1024)")
      check buffer.bufferStorageKind == storage
      check buffer.bufferLen == 1024
      check buffer.bufferStorageBytes == 1024 * width
      check buffer.bufferItem(1023).print() ==
        (if storage in {bskF32, bskF64}: "0.0" else: "0")

  test "signed and unsigned extrema survive storage without truncation":
    for (name, values) in [
        ("I8", "[-128 127]"), ("U8", "[0 255]"),
        ("I16", "[-32768 32767]"), ("U16", "[0 65535]"),
        ("I32", "[-2147483648 2147483647]"),
        ("U32", "[0 4294967295]"),
        ("I64", "[-9223372036854775808 9223372036854775807]"),
        ("U64", "[0 18446744073709551615]")]:
      check evalBuffer("(($buffer " & name & " " & values &
                       ") .to_list)").print() == values

  test "F32 rounds storage while F64 retains its precision":
    let single = evalBuffer("($buffer F32 [0.1 -0.0])")
    check single.bufferItem(0).floatVal == 0.10000000149011612
    check cast[uint64](single.bufferItem(1).floatVal) ==
          cast[uint64](-0.0)
    let double = evalBuffer("($buffer F64 [0.1])")
    check double.bufferItem(0).floatVal == 0.1
    check evalBuffer("(var b ($buffer F32 1)) (b .set 0 0.1) " &
                     "(b .get 0)").floatVal == 0.10000000149011612

  test "invalid writes preserve the old value and remain recoverable":
    check evalBuffer("(var b ($buffer U8 [7])) " &
      "(try (b .set 0 256) catch TypeError nil) (b .to_list)").print() == "[7]"
    check evalBuffer("(var b ($buffer F32 [7.0])) " &
      "(try (b .set 0 1e39) catch TypeError nil) (b .to_list)").print() == "[7.0]"
    check evalBuffer("(var b ($buffer U16 [7])) " &
      "(try (b .set 0 -1) catch TypeError nil) (b .to_list)").print() == "[7]"

  test "alias identity, negative indices, and missing reads are unchanged":
    check evalBuffer("(var b ($buffer I16 [1 2 3])) (let shared b) " &
      "(shared .set -1 9) [(same? b shared) (b .get 2) " &
      "($void? (b .get 99)) ($void? (b .get -99))]").print() ==
      "[true 9 true true]"

  test "bulk fill and copies preserve ranges and overlap in either direction":
    check evalBuffer("(var b ($buffer U8 [0 1 2 3 4 5])) " &
      "(b .copy_from b 0 4 2) (b .to_list)").print() == "[0 1 0 1 2 3]"
    check evalBuffer("(var b ($buffer U8 [0 1 2 3 4 5])) " &
      "(b .copy_from b 2 6 0) (b .to_list)").print() == "[2 3 4 5 4 5]"
    check evalBuffer("(var b ($buffer U16 7)) (b .fill 513 1 6) " &
      "(b .to_list)").print() == "[0 513 513 513 513 513 0]"
    check evalBuffer("(var b ($buffer F32 3)) (b .fill 0.1) " &
      "(b .get 2)").floatVal == 0.10000000149011612

  test "generic and arbitrary-precision buffers retain ordinary values":
    let strings = evalBuffer("($buffer Str [\"a\" \"b\"])")
    check strings.bufferStorageKind == bskValues
    check strings.bufferToItems[1].strVal == "b"
    let integers = evalBuffer("($buffer Int [18446744073709551616])")
    check integers.bufferStorageKind == bskValues
    check integers.bufferItem(0).print() == "18446744073709551616"
    check evalBuffer("(var b ($buffer [(fn [] 7)])) ((b .get 0))").print() == "7"

  test "different storage representations copy through checked values":
    check evalBuffer("(var source ($buffer U8 [1 2 255])) " &
      "(var target ($buffer U16 3)) (target .copy_from source) " &
      "(target .to_list)").print() == "[1 2 255]"
    check evalBuffer("(var source ($buffer F32 [0.1])) " &
      "(var target ($buffer (quote Any) [nil])) (target .copy_from source) " &
      "(target .get 0)").floatVal == 0.10000000149011612

  test "byte bridges use packed storage and round-trip binary and UTF-8":
    let bytes = evalBuffer("($binary/to_buffer ($binary/from_list [0 128 255]))")
    check bytes.bufferStorageKind == bskU8
    check bytes.bufferStorageBytes == 3
    check bytes.bufferByteString == "\x00\x80\xff"
    check evalBuffer("($binary/to_list " &
      "(($binary/to_buffer ($binary/from_list [0 128 255])) .to_bytes))").print() ==
      "[0 128 255]"
    let utf8 = evalBuffer("($str/to_utf8 \"aé界\")")
    check utf8.bufferStorageKind == bskU8
    check evalBuffer("($str/from_utf8 ($str/to_utf8 \"aé界\"))").strVal == "aé界"

  test "raw C ABI buffer construction uses the same checked representation":
    let buffer = newCheckedBuffer(newSym("C/UInt8"), @[newInt(1), newInt(255)])
    check buffer.bufferStorageKind == bskU8
    check buffer.bufferToItems[1].intVal == 255
    expect GeneError:
      discard setCheckedBufferItem(buffer, 1, newInt(256))
    check buffer.bufferItem(1).intVal == 255

  test "oversized lengths fail before allocating and wide misses stay missing":
    expect GeneError:
      discard newPackedBuffer(newSym("F64"), bskF64, high(int) div 8 + 1)
    let buffer = newPackedBuffer(newSym("U8"), bskU8, 1)
    check getCheckedBufferItem(buffer, high(int64)).kind == vkVoid
    check getCheckedBufferItem(buffer, low(int64)).kind == vkVoid
