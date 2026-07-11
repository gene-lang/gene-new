import gene/[compiler, types, vm, printer]
import std/[dynlib, unittest]

when sizeof(pointer) == sizeof(clong):
  type TestCPtrDiff = clong
else:
  type TestCPtrDiff = clonglong

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

proc ffiTestI16Abs(x: int16): int16 {.cdecl.} =
  if x < 0'i16: -x else: x

proc ffiTestU16Inc(x: uint16): uint16 {.cdecl.} =
  x + 1'u16

proc ffiTestShortAbs(x: cshort): cshort {.cdecl.} =
  if x < cshort(0): -x else: x

proc ffiTestShortI8(x: cshort): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestShortChar(x: cshort): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestShortULong(x: cshort): culong {.cdecl.} =
  culong(x + cshort(10))

proc ffiTestShortU8(x: cshort): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestShortUChar(x: cshort): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestShortU64(x: cshort): uint64 {.cdecl.} =
  uint64(x + cshort(12))

proc ffiTestShortDiff(x: cshort): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(x) - clong(6))

proc ffiTestShortPositive(x: cshort): bool {.cdecl.} =
  x > cshort(0)

proc ffiTestUShortInc(x: cushort): cushort {.cdecl.} =
  x + cushort(1)

proc ffiTestUShortI8(x: cushort): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestUShortChar(x: cushort): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestUShortULong(x: cushort): culong {.cdecl.} =
  culong(x + cushort(2))

proc ffiTestUShortU8(x: cushort): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestUShortUChar(x: cushort): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestUShortU64(x: cushort): uint64 {.cdecl.} =
  uint64(x + cushort(4))

proc ffiTestUShortDiff(x: cushort): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(x) - clong(6))

proc ffiTestUShortNonZero(x: cushort): bool {.cdecl.} =
  x != cushort(0)

proc ffiTestI8Abs(x: int8): int8 {.cdecl.} =
  if x < 0'i8: -x else: x

proc ffiTestI8Short(x: int8): cshort {.cdecl.} =
  cshort(x + 7'i8)

proc ffiTestI8Char(x: int8): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestI8ULong(x: int8): culong {.cdecl.} =
  culong(x + 10'i8)

proc ffiTestI8UShort(x: int8): cushort {.cdecl.} =
  cushort(x + 11'i8)

proc ffiTestI8UChar(x: int8): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestI8U64(x: int8): uint64 {.cdecl.} =
  uint64(x + 12'i8)

proc ffiTestI8Diff(x: int8): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(x) - clong(6))

proc ffiTestI8Positive(x: int8): bool {.cdecl.} =
  x > 0'i8

proc ffiTestU8Inc(x: uint8): uint8 {.cdecl.} =
  x + 1'u8

proc ffiTestU8Short(x: uint8): cshort {.cdecl.} =
  cshort(x + 7'u8)

proc ffiTestU8Char(x: uint8): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestU8ULong(x: uint8): culong {.cdecl.} =
  culong(x + 2'u8)

proc ffiTestU8UShort(x: uint8): cushort {.cdecl.} =
  cushort(x + 11'u8)

proc ffiTestU8UChar(x: uint8): uint8 {.cdecl.} =
  x + 13'u8

proc ffiTestU8U64(x: uint8): uint64 {.cdecl.} =
  uint64(x + 4'u8)

proc ffiTestU8Diff(x: uint8): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(x) - clong(6))

proc ffiTestU8NonZero(x: uint8): bool {.cdecl.} =
  x != 0'u8

proc ffiTestCharNext(x: cchar): cchar {.cdecl.} =
  cchar(ord(x) + 1)

proc ffiTestCharI32(x: cchar): int32 {.cdecl.} =
  int32(ord(x) + 5)

proc ffiTestCharI16(x: cchar): int16 {.cdecl.} =
  int16(ord(x) + 6)

proc ffiTestCharShort(x: cchar): cshort {.cdecl.} =
  cshort(ord(x) + 7)

proc ffiTestCharI8(x: cchar): int8 {.cdecl.} =
  int8(ord(x) - 60)

proc ffiTestCharULong(x: cchar): culong {.cdecl.} =
  culong(ord(x) + 2)

proc ffiTestCharU32(x: cchar): uint32 {.cdecl.} =
  uint32(ord(x) + 8)

proc ffiTestCharU16(x: cchar): uint16 {.cdecl.} =
  uint16(ord(x) + 9)

proc ffiTestCharUShort(x: cchar): cushort {.cdecl.} =
  cushort(ord(x) + 10)

proc ffiTestCharU8(x: cchar): uint8 {.cdecl.} =
  uint8(ord(x) + 11)

proc ffiTestCharI64(x: cchar): int64 {.cdecl.} =
  int64(ord(x) + 3)

proc ffiTestCharU64(x: cchar): uint64 {.cdecl.} =
  uint64(ord(x) + 4)

proc ffiTestCharDiff(x: cchar): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(ord(x)) - clong(66))

proc ffiTestUCharInc(x: uint8): uint8 {.cdecl.} =
  x + 1'u8

proc ffiTestUCharI32(x: uint8): int32 {.cdecl.} =
  int32(x) + 5'i32

proc ffiTestUCharI16(x: uint8): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestUCharShort(x: uint8): cshort {.cdecl.} =
  cshort(x) + cshort(7)

proc ffiTestUCharI8(x: uint8): int8 {.cdecl.} =
  int8(x) - 60'i8

proc ffiTestUCharULong(x: uint8): culong {.cdecl.} =
  culong(x + 2'u8)

proc ffiTestUCharU32(x: uint8): uint32 {.cdecl.} =
  uint32(x) + 8'u32

proc ffiTestUCharU16(x: uint8): uint16 {.cdecl.} =
  uint16(x) + 9'u16

proc ffiTestUCharUShort(x: uint8): cushort {.cdecl.} =
  cushort(x) + cushort(10)

proc ffiTestUCharU8(x: uint8): uint8 {.cdecl.} =
  x + 11'u8

proc ffiTestUCharI64(x: uint8): int64 {.cdecl.} =
  int64(x + 3'u8)

proc ffiTestUCharU64(x: uint8): uint64 {.cdecl.} =
  uint64(x + 4'u8)

proc ffiTestUCharDiff(x: uint8): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(x) - clong(66))

proc ffiTestBoolNot(x: bool): bool {.cdecl.} =
  not x

proc ffiTestBoolULong(x: bool): culong {.cdecl.} =
  if x: culong(7) else: culong(2)

proc ffiTestBoolI32(x: bool): int32 {.cdecl.} =
  if x: 8'i32 else: -3'i32

proc ffiTestBoolI16(x: bool): int16 {.cdecl.} =
  if x: 9'i16 else: -4'i16

proc ffiTestBoolShort(x: bool): cshort {.cdecl.} =
  if x: cshort(10) else: cshort(-5)

proc ffiTestBoolI8(x: bool): int8 {.cdecl.} =
  if x: 11'i8 else: -6'i8

proc ffiTestBoolChar(x: bool): cchar {.cdecl.} =
  if x: cchar(ord('T')) else: cchar(ord('F'))

proc ffiTestBoolU32(x: bool): uint32 {.cdecl.} =
  if x: 12'u32 else: 4'u32

proc ffiTestBoolU16(x: bool): uint16 {.cdecl.} =
  if x: 13'u16 else: 5'u16

proc ffiTestBoolUShort(x: bool): cushort {.cdecl.} =
  if x: cushort(14) else: cushort(6)

proc ffiTestBoolU8(x: bool): uint8 {.cdecl.} =
  if x: 15'u8 else: 7'u8

proc ffiTestBoolUChar(x: bool): uint8 {.cdecl.} =
  if x: uint8(ord('Y')) else: uint8(ord('N'))

proc ffiTestBoolI64(x: bool): int64 {.cdecl.} =
  if x: int64(8) else: int64(-3)

proc ffiTestBoolU64(x: bool): uint64 {.cdecl.} =
  if x: uint64(9) else: uint64(4)

proc ffiTestBoolDiff(x: bool): TestCPtrDiff {.cdecl.} =
  if x: TestCPtrDiff(5) else: TestCPtrDiff(-5)

proc ffiTestU64Inc(x: uint64): uint64 {.cdecl.} =
  x + 1'u64

proc ffiTestU64I32(x: uint64): int32 {.cdecl.} =
  int32(x) + 5'i32

proc ffiTestU64I16(x: uint64): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestU64Short(x: uint64): cshort {.cdecl.} =
  cshort(x + 7'u64)

proc ffiTestU64I8(x: uint64): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestU64Char(x: uint64): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestU64U32(x: uint64): uint32 {.cdecl.} =
  uint32(x) + 9'u32

proc ffiTestU64U16(x: uint64): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestU64UShort(x: uint64): cushort {.cdecl.} =
  cushort(x + 11'u64)

proc ffiTestU64U8(x: uint64): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestU64UChar(x: uint64): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestULongInc(x: culong): culong {.cdecl.} =
  x + culong(1)

proc ffiTestULongI32(x: culong): int32 {.cdecl.} =
  int32(x) + 5'i32

proc ffiTestULongI16(x: culong): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestULongShort(x: culong): cshort {.cdecl.} =
  cshort(x + culong(7))

proc ffiTestULongI8(x: culong): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestULongChar(x: culong): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestULongU32(x: culong): uint32 {.cdecl.} =
  uint32(x) + 9'u32

proc ffiTestULongU16(x: culong): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestULongUShort(x: culong): cushort {.cdecl.} =
  cushort(x + culong(11))

proc ffiTestULongU8(x: culong): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestULongUChar(x: culong): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestPtrDiffAbs(x: int): int {.cdecl.} =
  if x < 0: -x else: x

proc ffiTestPtrDiffI32(x: TestCPtrDiff): int32 {.cdecl.} =
  int32(x) + 5'i32

proc ffiTestPtrDiffI16(x: TestCPtrDiff): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestPtrDiffShort(x: TestCPtrDiff): cshort {.cdecl.} =
  cshort(x + TestCPtrDiff(7))

proc ffiTestPtrDiffI8(x: TestCPtrDiff): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestPtrDiffChar(x: TestCPtrDiff): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestPtrDiffU32(x: TestCPtrDiff): uint32 {.cdecl.} =
  uint32(x) + 9'u32

proc ffiTestPtrDiffU16(x: TestCPtrDiff): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestPtrDiffUShort(x: TestCPtrDiff): cushort {.cdecl.} =
  cushort(x + TestCPtrDiff(11))

proc ffiTestPtrDiffU8(x: TestCPtrDiff): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestPtrDiffUChar(x: TestCPtrDiff): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestSizeInc(x: csize_t): csize_t {.cdecl.} =
  x + csize_t(1)

proc ffiTestSizeI32(x: csize_t): int32 {.cdecl.} =
  int32(x) + 5'i32

proc ffiTestSizeI16(x: csize_t): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestSizeShort(x: csize_t): cshort {.cdecl.} =
  cshort(x + csize_t(7))

proc ffiTestSizeI8(x: csize_t): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestSizeChar(x: csize_t): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestSizeU32(x: csize_t): uint32 {.cdecl.} =
  uint32(x) + 9'u32

proc ffiTestSizeU16(x: csize_t): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestSizeUShort(x: csize_t): cushort {.cdecl.} =
  cushort(x + csize_t(11))

proc ffiTestSizeU8(x: csize_t): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestSizeUChar(x: csize_t): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestSizeULong(x: csize_t): culong {.cdecl.} =
  culong(x + csize_t(2))

proc ffiTestSizeI64(x: csize_t): int64 {.cdecl.} =
  int64(x + csize_t(3))

proc ffiTestSizeU64(x: csize_t): uint64 {.cdecl.} =
  uint64(x + csize_t(4))

proc ffiTestSizeUnaryDiff(x: csize_t): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(x) - clong(6))

proc ffiTestSizeNonZero(x: csize_t): bool {.cdecl.} =
  x != 0

proc ffiTestSizeAddUInt(a, b: csize_t): cuint {.cdecl.} =
  cuint(a + b + csize_t(1))

proc ffiTestSizeAddI32(a, b: csize_t): int32 {.cdecl.} =
  int32(a + b + csize_t(5))

proc ffiTestSizeAddI16(a, b: csize_t): int16 {.cdecl.} =
  int16(a + b + csize_t(6))

proc ffiTestSizeAddShort(a, b: csize_t): cshort {.cdecl.} =
  cshort(a + b + csize_t(7))

proc ffiTestSizeAddI8(a, b: csize_t): int8 {.cdecl.} =
  int8(a + b + csize_t(8))

proc ffiTestSizeAddChar(a, b: csize_t): cchar {.cdecl.} =
  cchar(ord('A') + int(a + b))

proc ffiTestSizeDiffLong(a, b: csize_t): clong {.cdecl.} =
  clong(a) - clong(b)

proc ffiTestSizeAddULong(a, b: csize_t): culong {.cdecl.} =
  culong(a + b + csize_t(2))

proc ffiTestSizeAddU32(a, b: csize_t): uint32 {.cdecl.} =
  uint32(a + b + csize_t(9))

proc ffiTestSizeAddU16(a, b: csize_t): uint16 {.cdecl.} =
  uint16(a + b + csize_t(10))

proc ffiTestSizeAddUShort(a, b: csize_t): cushort {.cdecl.} =
  cushort(a + b + csize_t(11))

proc ffiTestSizeAddU8(a, b: csize_t): uint8 {.cdecl.} =
  uint8(a + b + csize_t(12))

proc ffiTestSizeAddUChar(a, b: csize_t): uint8 {.cdecl.} =
  uint8(a + b + csize_t(13))

proc ffiTestSizeAddI64(a, b: csize_t): int64 {.cdecl.} =
  int64(a + b + csize_t(3))

proc ffiTestSizeAddU64(a, b: csize_t): uint64 {.cdecl.} =
  uint64(a + b + csize_t(4))

proc ffiTestSizeDiffPtrDiff(a, b: csize_t): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(a) - clong(b))

proc ffiTestSizeAddFloat(a, b: csize_t): cfloat {.cdecl.} =
  cfloat(a + b) + 0.25

proc ffiTestSizeAddDouble(a, b: csize_t): cdouble {.cdecl.} =
  cdouble(a + b) + 0.5

proc ffiTestSizeEqual(a, b: csize_t): bool {.cdecl.} =
  a == b

var ffiScalarPtrByte: uint8 = 0x41

proc ffiTestDoubleULong(x: cdouble): culong {.cdecl.} =
  culong(int(x) + 2)

proc ffiTestDoubleI32(x: cdouble): int32 {.cdecl.} =
  int32(int(x) + 5)

proc ffiTestDoubleI16(x: cdouble): int16 {.cdecl.} =
  int16(int(x) + 6)

proc ffiTestDoubleShort(x: cdouble): cshort {.cdecl.} =
  cshort(int(x) + 7)

proc ffiTestDoubleI8(x: cdouble): int8 {.cdecl.} =
  int8(int(x) + 8)

proc ffiTestDoubleChar(x: cdouble): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestDoubleU32(x: cdouble): uint32 {.cdecl.} =
  uint32(int(x) + 9)

proc ffiTestDoubleU16(x: cdouble): uint16 {.cdecl.} =
  uint16(int(x) + 10)

proc ffiTestDoubleUShort(x: cdouble): cushort {.cdecl.} =
  cushort(int(x) + 11)

proc ffiTestDoubleU8(x: cdouble): uint8 {.cdecl.} =
  uint8(int(x) + 12)

proc ffiTestDoubleUChar(x: cdouble): uint8 {.cdecl.} =
  uint8(int(x) + 13)

proc ffiTestDoubleI64(x: cdouble): int64 {.cdecl.} =
  int64(int(x) + 3)

proc ffiTestDoubleU64(x: cdouble): uint64 {.cdecl.} =
  uint64(int(x) + 4)

proc ffiTestDoubleDiff(x: cdouble): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(int(x) - 6)

proc ffiTestDoublePositive(x: cdouble): bool {.cdecl.} =
  x > 0.0

proc ffiTestDoubleKind(x: cdouble): cstring {.cdecl.} =
  if x > 0.0: "positive-double" else: "nonpositive-double"

proc ffiTestDoublePtr(x: cdouble): pointer {.cdecl.} =
  if x > 0.0: cast[pointer](addr ffiScalarPtrByte) else: nil

proc ffiTestFloatULong(x: cfloat): culong {.cdecl.} =
  culong(int(x) + 2)

proc ffiTestFloatI32(x: cfloat): int32 {.cdecl.} =
  int32(int(x) + 5)

proc ffiTestFloatI16(x: cfloat): int16 {.cdecl.} =
  int16(int(x) + 6)

proc ffiTestFloatShort(x: cfloat): cshort {.cdecl.} =
  cshort(int(x) + 7)

proc ffiTestFloatI8(x: cfloat): int8 {.cdecl.} =
  int8(int(x) + 8)

proc ffiTestFloatChar(x: cfloat): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestFloatU32(x: cfloat): uint32 {.cdecl.} =
  uint32(int(x) + 9)

proc ffiTestFloatU16(x: cfloat): uint16 {.cdecl.} =
  uint16(int(x) + 10)

proc ffiTestFloatUShort(x: cfloat): cushort {.cdecl.} =
  cushort(int(x) + 11)

proc ffiTestFloatU8(x: cfloat): uint8 {.cdecl.} =
  uint8(int(x) + 12)

proc ffiTestFloatUChar(x: cfloat): uint8 {.cdecl.} =
  uint8(int(x) + 13)

proc ffiTestFloatI64(x: cfloat): int64 {.cdecl.} =
  int64(int(x) + 3)

proc ffiTestFloatU64(x: cfloat): uint64 {.cdecl.} =
  uint64(int(x) + 4)

proc ffiTestFloatDiff(x: cfloat): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(int(x) - 6)

proc ffiTestFloatPositive(x: cfloat): bool {.cdecl.} =
  x > 0.0

proc ffiTestFloatKind(x: cfloat): cstring {.cdecl.} =
  if x > 0.0: "positive-float" else: "nonpositive-float"

proc ffiTestFloatPtr(x: cfloat): pointer {.cdecl.} =
  if x > 0.0: cast[pointer](addr ffiScalarPtrByte) else: nil

proc ffiTestIntULong(x: cint): culong {.cdecl.} =
  culong(x + 2)

proc ffiTestIntI32(x: cint): int32 {.cdecl.} =
  int32(x + 5)

proc ffiTestIntI16(x: cint): int16 {.cdecl.} =
  int16(x + 6)

proc ffiTestIntShort(x: cint): cshort {.cdecl.} =
  cshort(x + 7)

proc ffiTestIntI8(x: cint): int8 {.cdecl.} =
  int8(x + 8)

proc ffiTestIntChar(x: cint): cchar {.cdecl.} =
  cchar(ord('A') + x)

proc ffiTestIntU32(x: cint): uint32 {.cdecl.} =
  uint32(x + 9)

proc ffiTestIntU16(x: cint): uint16 {.cdecl.} =
  uint16(x + 10)

proc ffiTestIntUShort(x: cint): cushort {.cdecl.} =
  cushort(x + 11)

proc ffiTestIntU8(x: cint): uint8 {.cdecl.} =
  uint8(x + 12)

proc ffiTestIntUChar(x: cint): uint8 {.cdecl.} =
  uint8(x + 13)

proc ffiTestIntI64(x: cint): int64 {.cdecl.} =
  int64(x + 3)

proc ffiTestIntU64(x: cint): uint64 {.cdecl.} =
  uint64(x + 4)

proc ffiTestIntUnaryDiff(x: cint): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(x - 6)

proc ffiTestIntPositive(x: cint): bool {.cdecl.} =
  x > 0

proc ffiTestIntPtr(x: cint): pointer {.cdecl.} =
  if x > 0: cast[pointer](addr ffiScalarPtrByte) else: nil

proc ffiTestLongULong(x: clong): culong {.cdecl.} =
  culong(x + 2)

proc ffiTestLongI32(x: clong): int32 {.cdecl.} =
  int32(x) + 5'i32

proc ffiTestLongI16(x: clong): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestLongShort(x: clong): cshort {.cdecl.} =
  cshort(x + 7)

proc ffiTestLongI8(x: clong): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestLongChar(x: clong): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestLongU32(x: clong): uint32 {.cdecl.} =
  uint32(x) + 9'u32

proc ffiTestLongU16(x: clong): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestLongUShort(x: clong): cushort {.cdecl.} =
  cushort(x + 11)

proc ffiTestLongU8(x: clong): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestLongUChar(x: clong): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestLongI64(x: clong): int64 {.cdecl.} =
  int64(x + 3)

proc ffiTestLongU64(x: clong): uint64 {.cdecl.} =
  uint64(x + 4)

proc ffiTestLongDiff(x: clong): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(x - 6)

proc ffiTestLongPositive(x: clong): bool {.cdecl.} =
  x > 0

proc ffiTestI64ULong(x: int64): culong {.cdecl.} =
  culong(x + 2)

proc ffiTestI64I32(x: int64): int32 {.cdecl.} =
  int32(x) + 5'i32

proc ffiTestI64I16(x: int64): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestI64Short(x: int64): cshort {.cdecl.} =
  cshort(x + 7)

proc ffiTestI64I8(x: int64): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestI64Char(x: int64): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestI64U32(x: int64): uint32 {.cdecl.} =
  uint32(x) + 9'u32

proc ffiTestI64U16(x: int64): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestI64UShort(x: int64): cushort {.cdecl.} =
  cushort(x + 11)

proc ffiTestI64U8(x: int64): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestI64UChar(x: int64): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestI64U64(x: int64): uint64 {.cdecl.} =
  uint64(x + 4)

proc ffiTestI64Diff(x: int64): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(x - 6)

proc ffiTestI64Positive(x: int64): bool {.cdecl.} =
  x > 0

proc ffiTestUIntULong(x: cuint): culong {.cdecl.} =
  culong(x + 2)

proc ffiTestUIntI32(x: cuint): int32 {.cdecl.} =
  int32(x) + 5'i32

proc ffiTestUIntI16(x: cuint): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestUIntShort(x: cuint): cshort {.cdecl.} =
  cshort(x) + cshort(7)

proc ffiTestUIntI8(x: cuint): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestUIntChar(x: cuint): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestUIntU32(x: cuint): uint32 {.cdecl.} =
  uint32(x) + 9'u32

proc ffiTestUIntU16(x: cuint): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestUIntUShort(x: cuint): cushort {.cdecl.} =
  cushort(x) + cushort(11)

proc ffiTestUIntU8(x: cuint): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestUIntUChar(x: cuint): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestUIntI64(x: cuint): int64 {.cdecl.} =
  int64(x + 3)

proc ffiTestUIntU64(x: cuint): uint64 {.cdecl.} =
  uint64(x + 4)

proc ffiTestUIntDiff(x: cuint): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(x) - clong(6))

proc ffiTestUIntNonZero(x: cuint): bool {.cdecl.} =
  x != 0

proc ffiTestU32ULong(x: uint32): culong {.cdecl.} =
  culong(x + 2'u32)

proc ffiTestU32I16(x: uint32): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestU32Short(x: uint32): cshort {.cdecl.} =
  cshort(x + 7'u32)

proc ffiTestU32I8(x: uint32): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestU32Char(x: uint32): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestU32U16(x: uint32): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestU32UShort(x: uint32): cushort {.cdecl.} =
  cushort(x + 11'u32)

proc ffiTestU32U8(x: uint32): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestU32UChar(x: uint32): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestU32U64(x: uint32): uint64 {.cdecl.} =
  uint64(x + 4'u32)

proc ffiTestU32Diff(x: uint32): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(x) - clong(6))

proc ffiTestU32NonZero(x: uint32): bool {.cdecl.} =
  x != 0'u32

proc ffiTestI32ULong(x: int32): culong {.cdecl.} =
  culong(x + 2'i32)

proc ffiTestI32I16(x: int32): int16 {.cdecl.} =
  int16(x) + 6'i16

proc ffiTestI32Short(x: int32): cshort {.cdecl.} =
  cshort(x + 7'i32)

proc ffiTestI32I8(x: int32): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestI32Char(x: int32): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestI32U32(x: int32): uint32 {.cdecl.} =
  uint32(x) + 9'u32

proc ffiTestI32U16(x: int32): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestI32UShort(x: int32): cushort {.cdecl.} =
  cushort(x + 11'i32)

proc ffiTestI32U8(x: int32): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestI32UChar(x: int32): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestI32U64(x: int32): uint64 {.cdecl.} =
  uint64(x + 4'i32)

proc ffiTestI32Diff(x: int32): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(x - 6'i32)

proc ffiTestI32Positive(x: int32): bool {.cdecl.} =
  x > 0'i32

proc ffiTestI16ULong(x: int16): culong {.cdecl.} =
  culong(x + 2'i16)

proc ffiTestI16Short(x: int16): cshort {.cdecl.} =
  cshort(x + 7'i16)

proc ffiTestI16I8(x: int16): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestI16Char(x: int16): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestI16U16(x: int16): uint16 {.cdecl.} =
  uint16(x) + 10'u16

proc ffiTestI16UShort(x: int16): cushort {.cdecl.} =
  cushort(x + 11'i16)

proc ffiTestI16U8(x: int16): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestI16UChar(x: int16): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestI16U64(x: int16): uint64 {.cdecl.} =
  uint64(x + 4'i16)

proc ffiTestI16Diff(x: int16): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(x - 6'i16)

proc ffiTestI16Positive(x: int16): bool {.cdecl.} =
  x > 0'i16

proc ffiTestU16ULong(x: uint16): culong {.cdecl.} =
  culong(x + 2'u16)

proc ffiTestU16Short(x: uint16): cshort {.cdecl.} =
  cshort(x + 7'u16)

proc ffiTestU16I8(x: uint16): int8 {.cdecl.} =
  int8(x) + 8'i8

proc ffiTestU16Char(x: uint16): cchar {.cdecl.} =
  cchar(ord('A') + int(x))

proc ffiTestU16UShort(x: uint16): cushort {.cdecl.} =
  cushort(x + 11'u16)

proc ffiTestU16U8(x: uint16): uint8 {.cdecl.} =
  uint8(x) + 12'u8

proc ffiTestU16UChar(x: uint16): uint8 {.cdecl.} =
  uint8(x) + 13'u8

proc ffiTestU16U64(x: uint16): uint64 {.cdecl.} =
  uint64(x + 4'u16)

proc ffiTestU16Diff(x: uint16): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(x) - clong(6))

proc ffiTestU16NonZero(x: uint16): bool {.cdecl.} =
  x != 0'u16

proc ffiTestIntAdd(a, b: cint): cint {.cdecl.} =
  a + b

proc ffiTestIntAddUInt(a, b: cint): cuint {.cdecl.} =
  cuint(a + b + 1)

proc ffiTestIntAddI32(a, b: cint): int32 {.cdecl.} =
  int32(a + b + 5)

proc ffiTestIntAddI16(a, b: cint): int16 {.cdecl.} =
  int16(a + b + 6)

proc ffiTestIntAddShort(a, b: cint): cshort {.cdecl.} =
  cshort(a + b + 7)

proc ffiTestIntAddI8(a, b: cint): int8 {.cdecl.} =
  int8(a + b + 8)

proc ffiTestIntAddChar(a, b: cint): cchar {.cdecl.} =
  cchar(ord('A') + int(a + b))

proc ffiTestIntDiffLong(a, b: cint): clong {.cdecl.} =
  clong(a - b)

proc ffiTestIntAddULong(a, b: cint): culong {.cdecl.} =
  culong(a + b + 2)

proc ffiTestIntAddU32(a, b: cint): uint32 {.cdecl.} =
  uint32(a + b + 9)

proc ffiTestIntAddU16(a, b: cint): uint16 {.cdecl.} =
  uint16(a + b + 10)

proc ffiTestIntAddUShort(a, b: cint): cushort {.cdecl.} =
  cushort(a + b + 11)

proc ffiTestIntAddU8(a, b: cint): uint8 {.cdecl.} =
  uint8(a + b + 12)

proc ffiTestIntAddUChar(a, b: cint): uint8 {.cdecl.} =
  uint8(a + b + 13)

proc ffiTestIntAddI64(a, b: cint): int64 {.cdecl.} =
  int64(a + b + 3)

proc ffiTestIntAddU64(a, b: cint): uint64 {.cdecl.} =
  uint64(a + b + 4)

proc ffiTestIntDiffPtrDiff(a, b: cint): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(a - b)

proc ffiTestIntAddFloat(a, b: cint): cfloat {.cdecl.} =
  cfloat(a + b) + 0.25

proc ffiTestIntAddDouble(a, b: cint): cdouble {.cdecl.} =
  cdouble(a + b) + 0.5

proc ffiTestIntPairKind(a, b: cint): cstring {.cdecl.} =
  if a + b >= 0: "nonnegative-int-pair" else: "negative-int-pair"

proc ffiTestDoubleAdd(a, b: cdouble): cdouble {.cdecl.} =
  a + b

proc ffiTestDoubleDoubleUInt(a, b: cdouble): cuint {.cdecl.} =
  cuint(int(a + b) + 1)

proc ffiTestDoubleDoubleI32(a, b: cdouble): int32 {.cdecl.} =
  int32(int(a + b) + 5)

proc ffiTestDoubleDoubleI16(a, b: cdouble): int16 {.cdecl.} =
  int16(int(a + b) + 6)

proc ffiTestDoubleDoubleShort(a, b: cdouble): cshort {.cdecl.} =
  cshort(int(a + b) + 7)

proc ffiTestDoubleDoubleI8(a, b: cdouble): int8 {.cdecl.} =
  int8(int(a + b) + 8)

proc ffiTestDoubleDoubleChar(a, b: cdouble): cchar {.cdecl.} =
  cchar(ord('A') + int(a + b))

proc ffiTestDoubleDoubleULong(a, b: cdouble): culong {.cdecl.} =
  culong(int(a + b) + 2)

proc ffiTestDoubleDoubleU32(a, b: cdouble): uint32 {.cdecl.} =
  uint32(int(a + b) + 9)

proc ffiTestDoubleDoubleU16(a, b: cdouble): uint16 {.cdecl.} =
  uint16(int(a + b) + 10)

proc ffiTestDoubleDoubleUShort(a, b: cdouble): cushort {.cdecl.} =
  cushort(int(a + b) + 11)

proc ffiTestDoubleDoubleU8(a, b: cdouble): uint8 {.cdecl.} =
  uint8(int(a + b) + 12)

proc ffiTestDoubleDoubleUChar(a, b: cdouble): uint8 {.cdecl.} =
  uint8(int(a + b) + 13)

proc ffiTestDoubleDoubleI64(a, b: cdouble): int64 {.cdecl.} =
  int64(int(a + b) + 3)

proc ffiTestDoubleDoubleU64(a, b: cdouble): uint64 {.cdecl.} =
  uint64(int(a + b) + 4)

proc ffiTestDoubleDoubleDiff(a, b: cdouble): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(int(a - b))

proc ffiTestDoubleDoubleKind(a, b: cdouble): cstring {.cdecl.} =
  if a + b >= 0: "nonnegative-double-pair" else: "negative-double-pair"

proc ffiTestDoubleScale(a: cdouble, factor: cint): cdouble {.cdecl.} =
  a * cdouble(factor)

proc ffiTestDoubleIntUInt(a: cdouble, b: cint): cuint {.cdecl.} =
  cuint(int(a) + b + 1)

proc ffiTestDoubleIntI32(a: cdouble, b: cint): int32 {.cdecl.} =
  int32(int(a) + b + 5)

proc ffiTestDoubleIntI16(a: cdouble, b: cint): int16 {.cdecl.} =
  int16(int(a) + b + 6)

proc ffiTestDoubleIntShort(a: cdouble, b: cint): cshort {.cdecl.} =
  cshort(int(a) + b + 7)

proc ffiTestDoubleIntI8(a: cdouble, b: cint): int8 {.cdecl.} =
  int8(int(a) + b + 8)

proc ffiTestDoubleIntChar(a: cdouble, b: cint): cchar {.cdecl.} =
  cchar(ord('A') + int(a) + b)

proc ffiTestDoubleIntULong(a: cdouble, b: cint): culong {.cdecl.} =
  culong(int(a) + b + 2)

proc ffiTestDoubleIntU32(a: cdouble, b: cint): uint32 {.cdecl.} =
  uint32(int(a) + b + 9)

proc ffiTestDoubleIntU16(a: cdouble, b: cint): uint16 {.cdecl.} =
  uint16(int(a) + b + 10)

proc ffiTestDoubleIntUShort(a: cdouble, b: cint): cushort {.cdecl.} =
  cushort(int(a) + b + 11)

proc ffiTestDoubleIntU8(a: cdouble, b: cint): uint8 {.cdecl.} =
  uint8(int(a) + b + 12)

proc ffiTestDoubleIntUChar(a: cdouble, b: cint): uint8 {.cdecl.} =
  uint8(int(a) + b + 13)

proc ffiTestDoubleIntI64(a: cdouble, b: cint): int64 {.cdecl.} =
  int64(int(a) + b + 3)

proc ffiTestDoubleIntU64(a: cdouble, b: cint): uint64 {.cdecl.} =
  uint64(int(a) + b + 4)

proc ffiTestDoubleIntDiff(a: cdouble, b: cint): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(int(a) - b)

proc ffiTestDoubleIntKind(a: cdouble, b: cint): cstring {.cdecl.} =
  if a + cdouble(b) >= 0: "nonnegative-double-int" else: "negative-double-int"

proc ffiTestIntOffset(a: cint, b: cdouble): cdouble {.cdecl.} =
  cdouble(a) + b

proc ffiTestIntDoubleUInt(a: cint, b: cdouble): cuint {.cdecl.} =
  cuint(a + int(b) + 1)

proc ffiTestIntDoubleI32(a: cint, b: cdouble): int32 {.cdecl.} =
  int32(a + int(b) + 5)

proc ffiTestIntDoubleI16(a: cint, b: cdouble): int16 {.cdecl.} =
  int16(a + int(b) + 6)

proc ffiTestIntDoubleShort(a: cint, b: cdouble): cshort {.cdecl.} =
  cshort(a + int(b) + 7)

proc ffiTestIntDoubleI8(a: cint, b: cdouble): int8 {.cdecl.} =
  int8(a + int(b) + 8)

proc ffiTestIntDoubleChar(a: cint, b: cdouble): cchar {.cdecl.} =
  cchar(ord('A') + a + int(b))

proc ffiTestIntDoubleULong(a: cint, b: cdouble): culong {.cdecl.} =
  culong(a + int(b) + 2)

proc ffiTestIntDoubleU32(a: cint, b: cdouble): uint32 {.cdecl.} =
  uint32(a + int(b) + 9)

proc ffiTestIntDoubleU16(a: cint, b: cdouble): uint16 {.cdecl.} =
  uint16(a + int(b) + 10)

proc ffiTestIntDoubleUShort(a: cint, b: cdouble): cushort {.cdecl.} =
  cushort(a + int(b) + 11)

proc ffiTestIntDoubleU8(a: cint, b: cdouble): uint8 {.cdecl.} =
  uint8(a + int(b) + 12)

proc ffiTestIntDoubleUChar(a: cint, b: cdouble): uint8 {.cdecl.} =
  uint8(a + int(b) + 13)

proc ffiTestIntDoubleI64(a: cint, b: cdouble): int64 {.cdecl.} =
  int64(a + int(b) + 3)

proc ffiTestIntDoubleU64(a: cint, b: cdouble): uint64 {.cdecl.} =
  uint64(a + int(b) + 4)

proc ffiTestIntDoubleDiff(a: cint, b: cdouble): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(a - int(b))

proc ffiTestIntDoubleKind(a: cint, b: cdouble): cstring {.cdecl.} =
  if cdouble(a) + b >= 0: "nonnegative-int-double" else: "negative-int-double"

proc ffiTestFloatAdd(a, b: cfloat): cfloat {.cdecl.} =
  a + b

proc ffiTestFloatFloatUInt(a, b: cfloat): cuint {.cdecl.} =
  cuint(int(a + b) + 1)

proc ffiTestFloatFloatI32(a, b: cfloat): int32 {.cdecl.} =
  int32(int(a + b) + 5)

proc ffiTestFloatFloatI16(a, b: cfloat): int16 {.cdecl.} =
  int16(int(a + b) + 6)

proc ffiTestFloatFloatShort(a, b: cfloat): cshort {.cdecl.} =
  cshort(int(a + b) + 7)

proc ffiTestFloatFloatI8(a, b: cfloat): int8 {.cdecl.} =
  int8(int(a + b) + 8)

proc ffiTestFloatFloatChar(a, b: cfloat): cchar {.cdecl.} =
  cchar(ord('A') + int(a + b))

proc ffiTestFloatFloatULong(a, b: cfloat): culong {.cdecl.} =
  culong(int(a + b) + 2)

proc ffiTestFloatFloatU32(a, b: cfloat): uint32 {.cdecl.} =
  uint32(int(a + b) + 9)

proc ffiTestFloatFloatU16(a, b: cfloat): uint16 {.cdecl.} =
  uint16(int(a + b) + 10)

proc ffiTestFloatFloatUShort(a, b: cfloat): cushort {.cdecl.} =
  cushort(int(a + b) + 11)

proc ffiTestFloatFloatU8(a, b: cfloat): uint8 {.cdecl.} =
  uint8(int(a + b) + 12)

proc ffiTestFloatFloatUChar(a, b: cfloat): uint8 {.cdecl.} =
  uint8(int(a + b) + 13)

proc ffiTestFloatFloatI64(a, b: cfloat): int64 {.cdecl.} =
  int64(int(a + b) + 3)

proc ffiTestFloatFloatU64(a, b: cfloat): uint64 {.cdecl.} =
  uint64(int(a + b) + 4)

proc ffiTestFloatFloatDiff(a, b: cfloat): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(int(a - b))

proc ffiTestFloatFloatKind(a, b: cfloat): cstring {.cdecl.} =
  if a + b >= 0: "nonnegative-float-pair" else: "negative-float-pair"

proc ffiTestFloatScale(a: cfloat, factor: cint): cfloat {.cdecl.} =
  a * cfloat(factor)

proc ffiTestFloatIntUInt(a: cfloat, b: cint): cuint {.cdecl.} =
  cuint(int(a) + b + 1)

proc ffiTestFloatIntI32(a: cfloat, b: cint): int32 {.cdecl.} =
  int32(int(a) + b + 5)

proc ffiTestFloatIntI16(a: cfloat, b: cint): int16 {.cdecl.} =
  int16(int(a) + b + 6)

proc ffiTestFloatIntShort(a: cfloat, b: cint): cshort {.cdecl.} =
  cshort(int(a) + b + 7)

proc ffiTestFloatIntI8(a: cfloat, b: cint): int8 {.cdecl.} =
  int8(int(a) + b + 8)

proc ffiTestFloatIntChar(a: cfloat, b: cint): cchar {.cdecl.} =
  cchar(ord('A') + int(a) + b)

proc ffiTestFloatIntULong(a: cfloat, b: cint): culong {.cdecl.} =
  culong(int(a) + b + 2)

proc ffiTestFloatIntU32(a: cfloat, b: cint): uint32 {.cdecl.} =
  uint32(int(a) + b + 9)

proc ffiTestFloatIntU16(a: cfloat, b: cint): uint16 {.cdecl.} =
  uint16(int(a) + b + 10)

proc ffiTestFloatIntUShort(a: cfloat, b: cint): cushort {.cdecl.} =
  cushort(int(a) + b + 11)

proc ffiTestFloatIntU8(a: cfloat, b: cint): uint8 {.cdecl.} =
  uint8(int(a) + b + 12)

proc ffiTestFloatIntUChar(a: cfloat, b: cint): uint8 {.cdecl.} =
  uint8(int(a) + b + 13)

proc ffiTestFloatIntI64(a: cfloat, b: cint): int64 {.cdecl.} =
  int64(int(a) + b + 3)

proc ffiTestFloatIntU64(a: cfloat, b: cint): uint64 {.cdecl.} =
  uint64(int(a) + b + 4)

proc ffiTestFloatIntDiff(a: cfloat, b: cint): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(int(a) - b)

proc ffiTestFloatIntKind(a: cfloat, b: cint): cstring {.cdecl.} =
  if a + cfloat(b) >= 0: "nonnegative-float-int" else: "negative-float-int"

proc ffiTestIntFloatOffset(a: cint, b: cfloat): cfloat {.cdecl.} =
  cfloat(a) + b

proc ffiTestIntFloatUInt(a: cint, b: cfloat): cuint {.cdecl.} =
  cuint(a + int(b) + 1)

proc ffiTestIntFloatI32(a: cint, b: cfloat): int32 {.cdecl.} =
  int32(a + int(b) + 5)

proc ffiTestIntFloatI16(a: cint, b: cfloat): int16 {.cdecl.} =
  int16(a + int(b) + 6)

proc ffiTestIntFloatShort(a: cint, b: cfloat): cshort {.cdecl.} =
  cshort(a + int(b) + 7)

proc ffiTestIntFloatI8(a: cint, b: cfloat): int8 {.cdecl.} =
  int8(a + int(b) + 8)

proc ffiTestIntFloatChar(a: cint, b: cfloat): cchar {.cdecl.} =
  cchar(ord('A') + a + int(b))

proc ffiTestIntFloatULong(a: cint, b: cfloat): culong {.cdecl.} =
  culong(a + int(b) + 2)

proc ffiTestIntFloatU32(a: cint, b: cfloat): uint32 {.cdecl.} =
  uint32(a + int(b) + 9)

proc ffiTestIntFloatU16(a: cint, b: cfloat): uint16 {.cdecl.} =
  uint16(a + int(b) + 10)

proc ffiTestIntFloatUShort(a: cint, b: cfloat): cushort {.cdecl.} =
  cushort(a + int(b) + 11)

proc ffiTestIntFloatU8(a: cint, b: cfloat): uint8 {.cdecl.} =
  uint8(a + int(b) + 12)

proc ffiTestIntFloatUChar(a: cint, b: cfloat): uint8 {.cdecl.} =
  uint8(a + int(b) + 13)

proc ffiTestIntFloatI64(a: cint, b: cfloat): int64 {.cdecl.} =
  int64(a + int(b) + 3)

proc ffiTestIntFloatU64(a: cint, b: cfloat): uint64 {.cdecl.} =
  uint64(a + int(b) + 4)

proc ffiTestIntFloatDiff(a: cint, b: cfloat): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(a - int(b))

proc ffiTestIntFloatKind(a: cint, b: cfloat): cstring {.cdecl.} =
  if cfloat(a) + b >= 0: "nonnegative-int-float" else: "negative-int-float"

proc ffiTestSliceLen(data: pointer, len: csize_t): csize_t {.cdecl.} =
  len

proc ffiTestSliceFirstByte(data: pointer, len: csize_t): cint {.cdecl.} =
  if data == nil or len == 0:
    -1
  else:
    cint(cast[ptr uint8](data)[])

proc ffiTestBufferFill(data: pointer, len: csize_t) {.cdecl.} =
  if data == nil:
    return
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  if len > 0: bytes[0] = 90'u8
  if len > 1: bytes[1] = 91'u8
  if len > 2: bytes[2] = 92'u8

proc ffiTestSliceLenI32(data: pointer, len: csize_t): int32 {.cdecl.} =
  if data == nil: -1'i32 else: int32(len) + 5'i32

proc ffiTestSliceLenI16(data: pointer, len: csize_t): int16 {.cdecl.} =
  if data == nil: -1'i16 else: int16(len) + 6'i16

proc ffiTestSliceLenShort(data: pointer, len: csize_t): cshort {.cdecl.} =
  if data == nil: cshort(-1) else: cshort(len) + cshort(7)

proc ffiTestSliceLenI8(data: pointer, len: csize_t): int8 {.cdecl.} =
  if data == nil: -1'i8 else: int8(len) + 8'i8

proc ffiTestSliceLenChar(data: pointer, len: csize_t): cchar {.cdecl.} =
  if data == nil: cchar(ord('?')) else: cchar(ord('A') + int(len))

proc ffiTestSliceLenU32(data: pointer, len: csize_t): uint32 {.cdecl.} =
  if data == nil: 0'u32 else: uint32(len) + 9'u32

proc ffiTestSliceLenU16(data: pointer, len: csize_t): uint16 {.cdecl.} =
  if data == nil: 0'u16 else: uint16(len) + 10'u16

proc ffiTestSliceLenUShort(data: pointer, len: csize_t): cushort {.cdecl.} =
  if data == nil: cushort(0) else: cushort(len) + cushort(11)

proc ffiTestSliceLenU8(data: pointer, len: csize_t): uint8 {.cdecl.} =
  if data == nil: 0'u8 else: uint8(len) + 12'u8

proc ffiTestSliceLenUChar(data: pointer, len: csize_t): uint8 {.cdecl.} =
  if data == nil: 0'u8 else: uint8(len) + 13'u8

proc ffiTestSliceLenULong(data: pointer, len: csize_t): culong {.cdecl.} =
  if data == nil: culong(0) else: culong(len) + culong(3)

proc ffiTestSliceLenI64(data: pointer, len: csize_t): int64 {.cdecl.} =
  if data == nil: -1'i64 else: int64(len) + 2'i64

proc ffiTestSliceLenU64(data: pointer, len: csize_t): uint64 {.cdecl.} =
  if data == nil: 0'u64 else: uint64(len) + 1'u64

proc ffiTestSliceLenDiff(data: pointer, len: csize_t): TestCPtrDiff {.cdecl.} =
  if data == nil: TestCPtrDiff(-1) else: TestCPtrDiff(len)

proc ffiTestSliceLenFloat(data: pointer, len: csize_t): cfloat {.cdecl.} =
  if data == nil: -1.0 else: cfloat(len) + 0.25

proc ffiTestSliceLenDouble(data: pointer, len: csize_t): cdouble {.cdecl.} =
  if data == nil: -1.0 else: cdouble(len) + 0.5

proc ffiTestCStrBoundedLen(s: cstring, len: csize_t): csize_t {.cdecl.} =
  var i = 0
  while csize_t(i) < len and s[i] != '\0':
    inc i
  csize_t(i)

proc ffiTestCStrPtrIfLen(s: cstring, len: csize_t): pointer {.cdecl.} =
  if len == 0:
    nil
  else:
    cast[pointer](s)

proc ffiTestCStrLong(s: cstring): clong {.cdecl.} =
  clong(($s).len) - clong(5)

proc ffiTestCStrI16(s: cstring): int16 {.cdecl.} =
  int16(($s).len + 1)

proc ffiTestCStrShort(s: cstring): cshort {.cdecl.} =
  cshort(($s).len + 2)

proc ffiTestCStrI8(s: cstring): int8 {.cdecl.} =
  int8(($s).len - 5)

proc ffiTestCStrFirstChar(s: cstring): cchar {.cdecl.} =
  if ($s).len == 0: cchar(0) else: cchar(ord(s[0]))

proc ffiTestCStrULong(s: cstring): culong {.cdecl.} =
  culong(($s).len + 2)

proc ffiTestCStrU16(s: cstring): uint16 {.cdecl.} =
  uint16(($s).len + 3)

proc ffiTestCStrUShort(s: cstring): cushort {.cdecl.} =
  cushort(($s).len + 4)

proc ffiTestCStrU8(s: cstring): uint8 {.cdecl.} =
  uint8(($s).len + 5)

proc ffiTestCStrFirstUChar(s: cstring): uint8 {.cdecl.} =
  if ($s).len == 0: 0'u8 else: uint8(ord(s[0]))

proc ffiTestCStrI64(s: cstring): int64 {.cdecl.} =
  int64(($s).len + 3)

proc ffiTestCStrU64(s: cstring): uint64 {.cdecl.} =
  uint64(($s).len + 4)

proc ffiTestCStrDiff(s: cstring): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(clong(($s).len) - clong(5))

proc ffiTestCStrNonEmpty(s: cstring): bool {.cdecl.} =
  ($s).len != 0

proc ffiTestCStrIntUInt(s: cstring, x: cint): cuint {.cdecl.} =
  cuint(($s).len + int(x) + 1)

proc ffiTestCStrIntI32(s: cstring, x: cint): int32 {.cdecl.} =
  int32(($s).len + int(x) + 2)

proc ffiTestCStrIntI16(s: cstring, x: cint): int16 {.cdecl.} =
  int16(($s).len + int(x) + 3)

proc ffiTestCStrIntShort(s: cstring, x: cint): cshort {.cdecl.} =
  cshort(($s).len + int(x) + 4)

proc ffiTestCStrIntI8(s: cstring, x: cint): int8 {.cdecl.} =
  int8(($s).len - int(x))

proc ffiTestCStrIntChar(s: cstring, x: cint): cchar {.cdecl.} =
  cchar(ord(s[0]) + x)

proc ffiTestCStrIntU32(s: cstring, x: cint): uint32 {.cdecl.} =
  uint32(($s).len + int(x) + 5)

proc ffiTestCStrIntU16(s: cstring, x: cint): uint16 {.cdecl.} =
  uint16(($s).len + int(x) + 6)

proc ffiTestCStrIntUShort(s: cstring, x: cint): cushort {.cdecl.} =
  cushort(($s).len + int(x) + 7)

proc ffiTestCStrIntU8(s: cstring, x: cint): uint8 {.cdecl.} =
  uint8(($s).len + int(x) + 8)

proc ffiTestCStrIntUChar(s: cstring, x: cint): uint8 {.cdecl.} =
  uint8(ord(s[0]) + x)

proc ffiTestCStrIntLong(s: cstring, x: cint): clong {.cdecl.} =
  clong(($s).len - int(x))

proc ffiTestCStrIntULong(s: cstring, x: cint): culong {.cdecl.} =
  culong(($s).len + int(x) + 2)

proc ffiTestCStrIntI64(s: cstring, x: cint): int64 {.cdecl.} =
  int64(($s).len + int(x) + 3)

proc ffiTestCStrIntU64(s: cstring, x: cint): uint64 {.cdecl.} =
  uint64(($s).len + int(x) + 4)

proc ffiTestCStrIntDiff(s: cstring, x: cint): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(($s).len - int(x))

proc ffiTestCStrIntFloat(s: cstring, x: cint): cfloat {.cdecl.} =
  cfloat(($s).len + int(x)) + 0.25

proc ffiTestCStrIntDouble(s: cstring, x: cint): cdouble {.cdecl.} =
  cdouble(($s).len + int(x)) + 0.5

proc ffiTestCStrIntEqualLen(s: cstring, x: cint): bool {.cdecl.} =
  ($s).len == int(x)

proc ffiTestCStrSizeUInt(s: cstring, n: csize_t): cuint {.cdecl.} =
  cuint(($s).len + int(n) + 1)

proc ffiTestCStrSizeI32(s: cstring, n: csize_t): int32 {.cdecl.} =
  int32(($s).len + int(n) + 2)

proc ffiTestCStrSizeI16(s: cstring, n: csize_t): int16 {.cdecl.} =
  int16(($s).len + int(n) + 3)

proc ffiTestCStrSizeShort(s: cstring, n: csize_t): cshort {.cdecl.} =
  cshort(($s).len + int(n) + 4)

proc ffiTestCStrSizeI8(s: cstring, n: csize_t): int8 {.cdecl.} =
  int8(($s).len - int(n))

proc ffiTestCStrSizeChar(s: cstring, n: csize_t): cchar {.cdecl.} =
  cchar(ord(s[0]) + int(n))

proc ffiTestCStrSizeU32(s: cstring, n: csize_t): uint32 {.cdecl.} =
  uint32(($s).len + int(n) + 5)

proc ffiTestCStrSizeU16(s: cstring, n: csize_t): uint16 {.cdecl.} =
  uint16(($s).len + int(n) + 6)

proc ffiTestCStrSizeUShort(s: cstring, n: csize_t): cushort {.cdecl.} =
  cushort(($s).len + int(n) + 7)

proc ffiTestCStrSizeU8(s: cstring, n: csize_t): uint8 {.cdecl.} =
  uint8(($s).len + int(n) + 8)

proc ffiTestCStrSizeUChar(s: cstring, n: csize_t): uint8 {.cdecl.} =
  uint8(ord(s[0]) + int(n))

proc ffiTestCStrSizeLong(s: cstring, n: csize_t): clong {.cdecl.} =
  clong(($s).len - int(n))

proc ffiTestCStrSizeULong(s: cstring, n: csize_t): culong {.cdecl.} =
  culong(($s).len + int(n) + 2)

proc ffiTestCStrSizeI64(s: cstring, n: csize_t): int64 {.cdecl.} =
  int64(($s).len + int(n) + 3)

proc ffiTestCStrSizeU64(s: cstring, n: csize_t): uint64 {.cdecl.} =
  uint64(($s).len + int(n) + 4)

proc ffiTestCStrSizeDiff(s: cstring, n: csize_t): TestCPtrDiff {.cdecl.} =
  TestCPtrDiff(($s).len - int(n))

proc ffiTestCStrSizeFloat(s: cstring, n: csize_t): cfloat {.cdecl.} =
  cfloat(($s).len + int(n)) + 0.25

proc ffiTestCStrSizeDouble(s: cstring, n: csize_t): cdouble {.cdecl.} =
  cdouble(($s).len + int(n)) + 0.5

proc ffiTestCStrSizeEqualLen(s: cstring, n: csize_t): bool {.cdecl.} =
  ($s).len == int(n)

proc ffiTestCStrPairI32(a, b: cstring): int32 {.cdecl.} =
  int32(($a).len + ($b).len + 2)

proc ffiTestCStrPairI16(a, b: cstring): int16 {.cdecl.} =
  int16(($a).len + ($b).len + 3)

proc ffiTestCStrPairShort(a, b: cstring): cshort {.cdecl.} =
  cshort(($a).len + ($b).len + 4)

proc ffiTestCStrPairI8(a, b: cstring): int8 {.cdecl.} =
  int8(($a).len - ($b).len)

proc ffiTestCStrPairChar(a, b: cstring): cchar {.cdecl.} =
  cchar(ord(a[0]) + ($b).len)

proc ffiTestCStrPairU32(a, b: cstring): uint32 {.cdecl.} =
  uint32(($a).len + ($b).len + 5)

proc ffiTestCStrPairU16(a, b: cstring): uint16 {.cdecl.} =
  uint16(($a).len + ($b).len + 6)

proc ffiTestCStrPairUShort(a, b: cstring): cushort {.cdecl.} =
  cushort(($a).len + ($b).len + 7)

proc ffiTestCStrPairU8(a, b: cstring): uint8 {.cdecl.} =
  uint8(($a).len + ($b).len + 8)

proc ffiTestCStrPairUChar(a, b: cstring): uint8 {.cdecl.} =
  uint8(ord(a[0]) + ($b).len)

proc ffiTestCStrPairU64(a, b: cstring): uint64 {.cdecl.} =
  uint64(($a).len + ($b).len)

proc ffiTestCStrPairDiff(a, b: cstring): TestCPtrDiff {.cdecl.} =
  if $a == $b: TestCPtrDiff(0) else: TestCPtrDiff(-1)

proc ffiTestCStrPairDouble(a, b: cstring): cdouble {.cdecl.} =
  cdouble(($a).len + ($b).len) + 0.5

proc ffiTestCStrPairEqual(a, b: cstring): bool {.cdecl.} =
  $a == $b

proc ffiTestPtrCopy(dst, src: pointer, len: csize_t): pointer {.cdecl.} =
  copyMem(dst, src, len)
  dst

proc ffiTestPtrIfLen(p: pointer, len: csize_t): pointer {.cdecl.} =
  if len == 0:
    nil
  else:
    p

proc ffiTestPtrLen(p: pointer, len: csize_t): csize_t {.cdecl.} =
  if p == nil: 0 else: len

proc ffiTestPtrLenI32(p: pointer, len: csize_t): int32 {.cdecl.} =
  if p == nil: -1'i32 else: int32(len) + 5'i32

proc ffiTestPtrLenI16(p: pointer, len: csize_t): int16 {.cdecl.} =
  if p == nil: -1'i16 else: int16(len) + 6'i16

proc ffiTestPtrLenShort(p: pointer, len: csize_t): cshort {.cdecl.} =
  if p == nil: cshort(-1) else: cshort(len) + cshort(7)

proc ffiTestPtrLenI8(p: pointer, len: csize_t): int8 {.cdecl.} =
  if p == nil: -1'i8 else: int8(len) + 8'i8

proc ffiTestPtrLenChar(p: pointer, len: csize_t): cchar {.cdecl.} =
  if p == nil: cchar(ord('?')) else: cchar(ord('A') + int(len))

proc ffiTestPtrLenU64(p: pointer, len: csize_t): uint64 {.cdecl.} =
  if p == nil: 0'u64 else: uint64(len) + 1'u64

proc ffiTestPtrLenU32(p: pointer, len: csize_t): uint32 {.cdecl.} =
  if p == nil: 0'u32 else: uint32(len) + 9'u32

proc ffiTestPtrLenU16(p: pointer, len: csize_t): uint16 {.cdecl.} =
  if p == nil: 0'u16 else: uint16(len) + 10'u16

proc ffiTestPtrLenUShort(p: pointer, len: csize_t): cushort {.cdecl.} =
  if p == nil: cushort(0) else: cushort(len) + cushort(11)

proc ffiTestPtrLenU8(p: pointer, len: csize_t): uint8 {.cdecl.} =
  if p == nil: 0'u8 else: uint8(len) + 12'u8

proc ffiTestPtrLenUChar(p: pointer, len: csize_t): uint8 {.cdecl.} =
  if p == nil: 0'u8 else: uint8(len) + 13'u8

proc ffiTestPtrLenDiff(p: pointer, len: csize_t): TestCPtrDiff {.cdecl.} =
  if p == nil: TestCPtrDiff(-1) else: TestCPtrDiff(len)

proc ffiTestPtrLenDouble(p: pointer, len: csize_t): cdouble {.cdecl.} =
  if p == nil: -1.0 else: cdouble(len) + 0.5

proc ffiTestPtrHasLen(p: pointer, len: csize_t): bool {.cdecl.} =
  p != nil and len > 0

proc ffiTestPtrIdentity(p: pointer): pointer {.cdecl.} =
  p

proc ffiTestPtrIsNil(p: pointer): bool {.cdecl.} =
  p == nil

proc ffiTestPtrProbeI32(p: pointer): int32 {.cdecl.} =
  if p == nil: -1'i32 else: 8'i32

proc ffiTestPtrProbeI16(p: pointer): int16 {.cdecl.} =
  if p == nil: -1'i16 else: 9'i16

proc ffiTestPtrProbeShort(p: pointer): cshort {.cdecl.} =
  if p == nil: cshort(-1) else: cshort(10)

proc ffiTestPtrProbeI8(p: pointer): int8 {.cdecl.} =
  if p == nil: -1'i8 else: 11'i8

proc ffiTestPtrProbeChar(p: pointer): cchar {.cdecl.} =
  if p == nil: cchar(ord('?')) else: cchar(ord('D'))

proc ffiTestPtrProbeULong(p: pointer): culong {.cdecl.} =
  if p == nil: 0.culong else: 4.culong

proc ffiTestPtrProbeU32(p: pointer): uint32 {.cdecl.} =
  if p == nil: 0'u32 else: 12'u32

proc ffiTestPtrProbeU16(p: pointer): uint16 {.cdecl.} =
  if p == nil: 0'u16 else: 13'u16

proc ffiTestPtrProbeUShort(p: pointer): cushort {.cdecl.} =
  if p == nil: cushort(0) else: cushort(14)

proc ffiTestPtrProbeU8(p: pointer): uint8 {.cdecl.} =
  if p == nil: 0'u8 else: 15'u8

proc ffiTestPtrProbeUChar(p: pointer): uint8 {.cdecl.} =
  if p == nil: 0'u8 else: 16'u8

proc ffiTestPtrProbeI64(p: pointer): int64 {.cdecl.} =
  if p == nil: -1'i64 else: 5'i64

proc ffiTestPtrProbeU64(p: pointer): uint64 {.cdecl.} =
  if p == nil: 0'u64 else: 6'u64

proc ffiTestPtrProbeDiff(p: pointer): TestCPtrDiff {.cdecl.} =
  if p == nil: TestCPtrDiff(-2) else: TestCPtrDiff(7)

proc ffiTestPtrSame(a, b: pointer): cint {.cdecl.} =
  if a == b: 1 else: 0

proc ffiTestPtrSameI32(a, b: pointer): int32 {.cdecl.} =
  if a == b: 8'i32 else: -8'i32

proc ffiTestPtrSameI16(a, b: pointer): int16 {.cdecl.} =
  if a == b: 9'i16 else: -9'i16

proc ffiTestPtrSameShort(a, b: pointer): cshort {.cdecl.} =
  if a == b: cshort(10) else: cshort(-10)

proc ffiTestPtrSameI8(a, b: pointer): int8 {.cdecl.} =
  if a == b: 11'i8 else: -11'i8

proc ffiTestPtrSameChar(a, b: pointer): cchar {.cdecl.} =
  if a == b: cchar(ord('S')) else: cchar(ord('D'))

proc ffiTestPtrSameU64(a, b: pointer): uint64 {.cdecl.} =
  if a == b: 1'u64 else: 0'u64

proc ffiTestPtrSameU32(a, b: pointer): uint32 {.cdecl.} =
  if a == b: 12'u32 else: 0'u32

proc ffiTestPtrSameU16(a, b: pointer): uint16 {.cdecl.} =
  if a == b: 13'u16 else: 0'u16

proc ffiTestPtrSameUShort(a, b: pointer): cushort {.cdecl.} =
  if a == b: cushort(14) else: cushort(0)

proc ffiTestPtrSameU8(a, b: pointer): uint8 {.cdecl.} =
  if a == b: 15'u8 else: 0'u8

proc ffiTestPtrSameUChar(a, b: pointer): uint8 {.cdecl.} =
  if a == b: 16'u8 else: 0'u8

proc ffiTestPtrSameDiff(a, b: pointer): TestCPtrDiff {.cdecl.} =
  if a == b: TestCPtrDiff(1) else: TestCPtrDiff(-1)

proc ffiTestPtrSameDouble(a, b: pointer): cdouble {.cdecl.} =
  if a == b: 1.5 else: -1.5

proc ffiTestPtrPick(a, b: pointer): pointer {.cdecl.} =
  if a != nil: a else: b

proc ffiTestPtrPtrLen(a, b: pointer, len: csize_t): csize_t {.cdecl.} =
  if a == nil or b == nil: 0 else: len

proc ffiTestPtrPtrLenI32(a, b: pointer, len: csize_t): int32 {.cdecl.} =
  if a == nil or b == nil: -1'i32 else: int32(len) + 5'i32

proc ffiTestPtrPtrLenI16(a, b: pointer, len: csize_t): int16 {.cdecl.} =
  if a == nil or b == nil: -1'i16 else: int16(len) + 6'i16

proc ffiTestPtrPtrLenShort(a, b: pointer, len: csize_t): cshort {.cdecl.} =
  if a == nil or b == nil: cshort(-1) else: cshort(len) + cshort(7)

proc ffiTestPtrPtrLenI8(a, b: pointer, len: csize_t): int8 {.cdecl.} =
  if a == nil or b == nil: -1'i8 else: int8(len) + 8'i8

proc ffiTestPtrPtrLenChar(a, b: pointer, len: csize_t): cchar {.cdecl.} =
  if a == nil or b == nil: cchar(ord('?')) else: cchar(ord('A') + int(len))

proc ffiTestPtrPtrLenU64(a, b: pointer, len: csize_t): uint64 {.cdecl.} =
  if a == nil or b == nil: 0'u64 else: uint64(len) + 1'u64

proc ffiTestPtrPtrLenU32(a, b: pointer, len: csize_t): uint32 {.cdecl.} =
  if a == nil or b == nil: 0'u32 else: uint32(len) + 9'u32

proc ffiTestPtrPtrLenU16(a, b: pointer, len: csize_t): uint16 {.cdecl.} =
  if a == nil or b == nil: 0'u16 else: uint16(len) + 10'u16

proc ffiTestPtrPtrLenUShort(a, b: pointer, len: csize_t): cushort {.cdecl.} =
  if a == nil or b == nil: cushort(0) else: cushort(len) + cushort(11)

proc ffiTestPtrPtrLenU8(a, b: pointer, len: csize_t): uint8 {.cdecl.} =
  if a == nil or b == nil: 0'u8 else: uint8(len) + 12'u8

proc ffiTestPtrPtrLenUChar(a, b: pointer, len: csize_t): uint8 {.cdecl.} =
  if a == nil or b == nil: 0'u8 else: uint8(len) + 13'u8

proc ffiTestPtrPtrLenDiff(a, b: pointer, len: csize_t): TestCPtrDiff {.cdecl.} =
  if a == b: TestCPtrDiff(len) else: -TestCPtrDiff(len)

proc ffiTestPtrPtrLenDouble(a, b: pointer, len: csize_t): cdouble {.cdecl.} =
  if a == b: cdouble(len) + 0.5 else: cdouble(len) + 1.5

proc ffiTestPtrPtrHasLen(a, b: pointer, len: csize_t): bool {.cdecl.} =
  a != nil and b != nil and len > 0

proc ffiTestPtrIntLen(p: pointer, x: cint, len: csize_t): csize_t {.cdecl.} =
  if p == nil or x < 0: 0 else: csize_t(x) + len

proc ffiTestPtrIntLenI32(p: pointer, x: cint, len: csize_t): int32 {.cdecl.} =
  if p == nil: -1'i32 else: int32(x) + int32(len) + 5'i32

proc ffiTestPtrIntLenI16(p: pointer, x: cint, len: csize_t): int16 {.cdecl.} =
  if p == nil: -1'i16 else: int16(x) + int16(len) + 6'i16

proc ffiTestPtrIntLenShort(p: pointer, x: cint, len: csize_t): cshort {.cdecl.} =
  if p == nil: cshort(-1) else: cshort(x) + cshort(len) + cshort(7)

proc ffiTestPtrIntLenI8(p: pointer, x: cint, len: csize_t): int8 {.cdecl.} =
  if p == nil: -1'i8 else: int8(x) + int8(len) + 8'i8

proc ffiTestPtrIntLenChar(p: pointer, x: cint, len: csize_t): cchar {.cdecl.} =
  if p == nil: cchar(ord('?')) else: cchar(ord('A') + int(x) + int(len))

proc ffiTestPtrIntLenU64(p: pointer, x: cint, len: csize_t): uint64 {.cdecl.} =
  if p == nil or x < 0: 0'u64 else: uint64(x) + uint64(len) + 1'u64

proc ffiTestPtrIntLenU32(p: pointer, x: cint, len: csize_t): uint32 {.cdecl.} =
  if p == nil: 0'u32 else: uint32(x) + uint32(len) + 9'u32

proc ffiTestPtrIntLenU16(p: pointer, x: cint, len: csize_t): uint16 {.cdecl.} =
  if p == nil: 0'u16 else: uint16(x) + uint16(len) + 10'u16

proc ffiTestPtrIntLenUShort(p: pointer, x: cint, len: csize_t): cushort {.cdecl.} =
  if p == nil: cushort(0) else: cushort(x) + cushort(len) + cushort(11)

proc ffiTestPtrIntLenU8(p: pointer, x: cint, len: csize_t): uint8 {.cdecl.} =
  if p == nil: 0'u8 else: uint8(x) + uint8(len) + 12'u8

proc ffiTestPtrIntLenUChar(p: pointer, x: cint, len: csize_t): uint8 {.cdecl.} =
  if p == nil: 0'u8 else: uint8(x) + uint8(len) + 13'u8

proc ffiTestPtrIntLenDiff(p: pointer, x: cint, len: csize_t): TestCPtrDiff {.cdecl.} =
  if p == nil: TestCPtrDiff(-1)
  else: TestCPtrDiff(x) - TestCPtrDiff(len)

proc ffiTestPtrIntLenDouble(p: pointer, x: cint, len: csize_t): cdouble {.cdecl.} =
  if p == nil: -1.0 else: cdouble(x) + cdouble(len) + 0.5

proc ffiTestPtrIntHasLen(p: pointer, x: cint, len: csize_t): bool {.cdecl.} =
  p != nil and x > 0 and len > 0

proc ffiLibraryCandidates(): seq[string] =
  when defined(macosx):
    @["/usr/lib/libSystem.B.dylib", "/usr/lib/libSystem.dylib"]
  elif defined(linux):
    @["libc.so.6", "libm.so.6"]
  elif defined(windows):
    @["kernel32.dll", "msvcrt.dll"]
  else:
    @[]

proc loadableFfiLibrary(): string =
  for candidate in ffiLibraryCandidates():
    let handle = loadLib(candidate)
    if handle != nil:
      unloadLib(handle)
      return candidate
  ""

proc loadableFfiLibraryWithSymbol(symbol: string): string =
  for candidate in ffiLibraryCandidates():
    let handle = loadLib(candidate)
    if handle != nil:
      let found = symAddr(handle, symbol) != nil
      unloadLib(handle)
      if found:
        return candidate
  ""

suite "types — declaration and construction":
  test "type declaration yields a Type value":
    ck "(type Task ^props {^id Int})", "(type Task)"
  test "construction binds the declared fields":
    ck "(type Task ^props {^id Int ^title Str}) (var t (Task ^id 1 ^title \"x\")) t/title",
       "\"x\""
  test "construction binds typed body fields":
    ck "(type Pair ^body [Int Str]) (var p (Pair 7 \"seven\")) " &
       "[(p ~ /0) (p ~ /1)]",
       "[7 \"seven\"]"
    ck "(type Values ^body [Int...]) (var v (Values 1 2 3)) " &
       "[(v ~ /0) (v ~ /1) (v ~ /2)]",
       "[1 2 3]"
    ck "(type Entry ^props {^name Str} ^body [Int...]) " &
       "(var e (Entry ^name \"scores\" 1 2)) " &
       "[(e ~ /name) (e ~ /0) (e ~ /1)]",
       "[\"scores\" 1 2]"
  test "the instance head is the type value":
    ck "(type Task ^props {^id Int}) (== (head (Task ^id 1)) Task)", "true"
  test "distinct types are not equal":
    ck "(type A ^props {^x Int}) (type B ^props {^x Int}) (== A B)", "false"
  test "type declarations reject unsupported props":
    expect GeneError:
      discard compileSource("(type T ^sealed true ^props {})")
    expect GeneError:
      discard compileSource("(type T ^unknown 1 ^props {})")

suite "types — schema validation":
  test "a missing required field is rejected":
    expect GeneError:
      discard runStr("(type Task ^props {^id Int ^title Str}) (Task ^id 1)")
  test "an unknown field is rejected (closed schema)":
    expect GeneError:
      discard runStr("(type Task ^props {^id Int}) (Task ^id 1 ^extra 2)")
  test "optional fields may be omitted":
    ck "(type Task ^props {^id Int ^done Bool?}) (var t (Task ^id 1)) t/id", "1"
  test "void fields normalize as omitted at construction":
    ck "(type Task ^props {^id Int ^done Bool?}) " &
       "(var t (Task ^id 1 ^done void)) [(t ~ /id) (t ~ /done)]",
       "[1 void]"
    expect GeneError:
      discard runStr("(type Task ^props {^id Int}) (Task ^id void)")
  test "field annotations are checked at construction":
    expect GeneError:
      discard runStr("(type Task ^props {^id Int ^title Str}) (Task ^id \"bad\" ^title \"x\")")
    ck "(try (type Task ^props {^id Int}) (Task ^id \"bad\") " &
       "catch (TypeError ^expected e) e)", "\"Int\""
  test "body schemas are checked at construction":
    expect GeneError:
      discard runStr("(type Pair ^body [Int Str]) (Pair 1)")
    expect GeneError:
      discard runStr("(type Pair ^body [Int Str]) (Pair 1 \"ok\" 3)")
    ck "(try (type Values ^body [Int...]) (Values 1 \"bad\") " &
       "catch (TypeError ^where w) w)", "\"body field 1 for Values\""

suite "types — single inheritance":
  test "a child inherits parent fields":
    ck "(type Animal ^props {^name Str}) (type Dog ^is Animal ^props {^breed Str}) " &
       "(var d (Dog ^name \"Rex\" ^breed \"Lab\")) d/name", "\"Rex\""
  test "a child may add no fields but still requires inherited fields":
    ck "(type Animal ^props {^name Str}) (type Dog ^is Animal ^props {}) " &
       "(var d (Dog ^name \"Rex\")) d/name", "\"Rex\""
    expect GeneError:
      discard runStr("(type Animal ^props {^name Str}) " &
                     "(type Dog ^is Animal ^props {}) (Dog)")
  test "a child inherits parent body fields":
    ck "(type Row ^body [Int]) (type LabeledRow ^is Row ^props {^label Str} ^body [Str]) " &
       "(var r (LabeledRow ^label \"a\" 7 \"ok\")) " &
       "[(r ~ /label) (r ~ /0) (r ~ /1)]",
       "[\"a\" 7 \"ok\"]"
  test "a child requires inherited required fields":
    expect GeneError:
      discard runStr("(type Animal ^props {^name Str}) (type Dog ^is Animal ^props {^breed Str}) " &
                     "(Dog ^breed \"Lab\")")
  test "inherited field annotations use the parent defining scope":
    ck "(ns model (type Id ^props {^raw Int}) (type Entity ^props {^id Id})) " &
       "(type User ^is model/Entity ^props {^name Str}) " &
       "(var u (User ^id (model/Id ^raw 7) ^name \"Ada\")) u/id/raw", "7"
  test "child types cannot redeclare inherited fields":
    expect GeneError:
      discard runStr("(type Animal ^props {^name Str}) " &
                     "(type Dog ^is Animal ^props {^name Any})")
    expect GeneError:
      discard runStr("(type Animal ^props {^name Str}) " &
                     "(type Dog ^is Animal ^props {^name Str})")
  test "^is must reference a type":
    expect GeneError:
      discard runStr("(type Dog ^is 5 ^props {^breed Str})")

suite "types — pattern matching":
  test "instances match a node-shape pattern by type":
    ck "(type Task ^props {^id Int ^title Str}) " &
       "(match (Task ^id 7 ^title \"a\") (when (Task ^id n) n))", "7"
  test "instances match parent type patterns":
    ck "(type Animal ^props {^name Str}) (type Dog ^is Animal ^props {^breed Str}) " &
       "(match (Dog ^name \"Rex\" ^breed \"Lab\") (when (Animal ^name n) n))",
       "\"Rex\""
  test "a different type does not match":
    ck "(type A ^props {^x Int}) (type B ^props {^x Int}) " &
       "(match (B ^x 1) (when (A ^x v) \"a\") (else \"other\"))", "\"other\""
  test "typed binders match nominal types":
    ck "(type Task ^props {^id Int}) " &
       "(match (Task ^id 7) (when (t : Task) t/id))", "7"
    ck "(type Animal ^props {^name Str}) (type Dog ^is Animal ^props {^breed Str}) " &
       "(match (Dog ^name \"Rex\" ^breed \"Lab\") (when (a : Animal) a/name))",
       "\"Rex\""

suite "types — function boundaries":
  test "positional parameter annotations are checked":
    ck "(fn inc [x : Int] (+ x 1)) (inc 4)", "5"
    ck "(try (fn inc [x : Int] (+ x 1)) (inc \"bad\") " &
       "catch (TypeError ^where w) w)", "\"parameter 'x'\""

  test "named parameter annotations are checked":
    ck "(fn label [^name : Str] name) (label ^name \"Ada\")", "\"Ada\""
    ck "(try (fn label [^name : Str] name) (label ^name 3) " &
       "catch (TypeError ^expected e) e)", "\"Str\""

  test "return annotations are checked":
    ck "(fn answer [] : Int 42) (answer)", "42"
    ck "(try (fn answer [] : Int \"no\") (answer) " &
       "catch (TypeError ^where w) w)", "\"return from 'answer'\""

  test "generic functions infer scalar parameter and return boundaries":
    ck "(fn (identity item) [x : item] : item x) [(identity 1) (identity \"ok\")]",
       "[1 \"ok\"]"
    ck "(fn (named-id item) [^x : item] : item x) (named-id ^x \"ok\")",
       "\"ok\""
    ck "(try (fn (bad item) [x : item] : item \"bad\") (bad 1) " &
       "catch (TypeError ^where w) w)", "\"return from 'bad'\""

  test "generic functions enforce repeated type parameters":
    ck "(fn (choose item) [a : item b : item] b) (choose 1 2)", "2"
    ck "(try (fn (choose item) [a : item b : item] b) (choose 1 \"bad\") " &
       "catch (TypeError ^expected e) e)", "\"Int\""

  test "generic functions infer list element types":
    ck "(fn (first item) [xs : (List item)] : item xs/0) (first [1 2])",
       "1"
    ck "(try (fn (first item) [xs : (List item)] : item xs/0) " &
       "(first [1 \"bad\"]) catch (TypeError ^expected e) e)",
       "\"(List Int)\""

  test "generic functions infer map value types":
    ck "(fn (get key value) [m : (Map key value)] : value m/a) " &
       "(get {^a 42})",
       "42"
    ck "(try (fn (choose key value) [m : (Map key value) fallback : value] fallback) " &
       "(choose {^a 1} \"bad\") catch (TypeError ^expected e) e)",
       "\"Int\""

  test "generic functions infer typed stream item types":
    ck "(fn nums [] : (Stream Int Never) (yield 4)) " &
       "(fn (first item err) [s : (Stream item err)] : item (s ~ Stream/next)) " &
       "(first (nums))",
       "4"

  test "generic functions infer buffer element types":
    ck "(fn (first item) [b : (Buffer item)] : item (Buffer/get b 0)) " &
       "(first (buffer [4 5]))",
       "4"
    ck "(try (fn (choose item) [b : (Buffer item) fallback : item] fallback) " &
       "(choose (buffer [1]) \"bad\") catch (TypeError ^expected e) e)",
       "\"Int\""

  test "task annotations check results and recoverable errors at await":
    ck "(scope " &
       "  (fn use [t : (Task Int Never)] (await t)) " &
       "  (use (spawn 7)))",
       "7"
    ck "(scope " &
       "  (fn use [t : (Task Int Never)] " &
       "    (try (await t) catch (TypeError ^where w) w)) " &
       "  (use (spawn \"bad\")))",
       "\"await task result\""
    ck "(type Boom ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Boom) " &
       "(type Other ^props {^message Str} ^impl [Error]) " &
       "(impl Error for Other) " &
       "(scope " &
       "  (fn use [t : (Task Int Boom)] " &
       "    (try (await t) catch (TypeError ^where w) w)) " &
       "  (use (spawn (fail (Other ^message \"bad\")))))",
       "\"await task error\""

  test "generic functions infer checked task result types":
    ck "(scope " &
       "  (var t : (Task Int Never) (spawn 8)) " &
       "  (fn (await-task result err) [t : (Task result err)] : result " &
       "    (await t)) " &
       "  (await-task t))",
       "8"

  test "nominal subtype values pass parent boundaries":
    ck "(type Animal ^props {^name Str}) (type Dog ^is Animal ^props {^breed Str}) " &
       "(fn name-of [x : Animal] x/name) (name-of (Dog ^name \"Rex\" ^breed \"Lab\"))",
       "\"Rex\""
    expect GeneError:
      discard runStr("(type Animal ^props {^name Str}) (type Rock ^props {^name Str}) " &
                     "(fn name-of [x : Animal] x/name) (name-of (Rock ^name \"granite\"))")

  test "simple container annotations check elements":
    ck "(fn size [xs : (List Int)] xs/~size) (size [1 2 3])", "3"
    ck "(try (fn size [xs : (List Int)] xs/~size) (size [1 \"bad\"]) " &
       "catch (TypeError ^expected e) e)", "\"(List Int)\""
    ck "(fn value [m : (Map Sym Int)] m/a) (value {^a 3})", "3"
    ck "(var routes (into (to_stream [[\"handler\" (fn [] 7)]]) {})) " &
       "(fn run [m : (Map Str Fn)] ((m ~ /handler))) " &
       "(run routes)",
       "7"
    ck "(try (fn value [m : (Map Sym Int)] m) (value {^a \"bad\"}) " &
       "catch (TypeError ^expected e) e)", "\"(Map Sym Int)\""
    ck "(try (fn value [m : (Map Int Str)] m) (value {^a \"ok\"}) " &
       "catch (TypeError ^expected e) e)", "\"(Map Int Str)\""
    ck "(fn value [m : (HashMap Str Int)] (Map/get m \"a\")) " &
       "(value {{\"a\" : 3}})", "3"
    ck "(fn value [m : (Map Str Int)] (Map/get m \"a\")) " &
       "(value {{\"a\" : 3}})", "3"
    ck "(try (fn value [m : (HashMap Str Int)] m) (value {{1 : 2}}) " &
       "catch (TypeError ^expected e) e)", "\"(HashMap Str Int)\""
    ck "(fn count [s : (Set Int)] (size s)) (count (Set 1 2 1))", "2"
    ck "(try (fn count [s : (Set Int)] s) (count (Set 1 \"bad\")) " &
       "catch (TypeError ^expected e) e)", "\"(Set Int)\""
    ck "(fn len [b : Bytes] (size b)) (len 0x4869)", "2"

  test "fixed-width integer annotations range-check boundaries":
    ck "(fn f [x : SignedInt] x) [(f -1) (f 0) (f 1)]", "[-1 0 1]"
    ck "(fn f [x : UnsignedInt] x) " &
       "[(f 0) (f 18446744073709551616)]",
       "[0 18446744073709551616]"
    expect GeneError: discard runStr("(fn f [x : UnsignedInt] x) (f -1)")
    ck "(fn f [x : I8] x) [(f -128) (f 127)]", "[-128 127]"
    ck "(fn f [x : U8] x) [(f 0) (f 255)]", "[0 255]"
    ck "(fn f [x : U64] x) (f 18446744073709551615)", "18446744073709551615"
    expect GeneError: discard runStr("(fn f [x : I8] x) (f -129)")
    expect GeneError: discard runStr("(fn f [x : I8] x) (f 128)")
    expect GeneError: discard runStr("(fn f [x : U8] x) (f -1)")
    expect GeneError: discard runStr("(fn f [x : U8] x) (f 256)")
    expect GeneError: discard runStr("(fn f [x : I32] x) (f 2147483648)")
    expect GeneError: discard runStr("(fn f [x : I64] x) (f 9223372036854775808)")
    expect GeneError: discard runStr("(fn f [x : U64] x) (f 18446744073709551616)")
    ck "(fn f [x : F32] x) (f 3.5)", "3.5"
    ck "(fn f [x : F64] 1) (f 1e39)", "1"
    ck "(try (fn f [x : F32] x) (f 1e39) " &
       "catch (TypeError ^expected e) e)", "\"F32\""
    ck "(type Byte ^props {^value U8}) (var b (Byte ^value 255)) b/value", "255"
    expect GeneError:
      discard runStr("(type Byte ^props {^value U8}) (Byte ^value 256)")

  test "C ABI scalar annotations are explicit checked boundaries":
    ck "C/Int32", "(c_abi_type Int32)"
    ck "(fn f [x : C/Int32] x) [(f -2147483648) (f 2147483647)]",
       "[-2147483648 2147483647]"
    ck "(fn f [x : C/UInt8] x) [(f 0) (f 255)]", "[0 255]"
    ck "(fn f [x : C/Bool] x) (f true)", "true"
    ck "(fn f [x : C/CStr] x) (f \"ok\")", "\"ok\""
    ck "(try (fn f [x : C/Int32] x) (f 2147483648) " &
       "catch (TypeError ^expected e) e)", "\"C/Int32\""
    ck "(try (fn f [x : C/CStr] x) (f \"bad\\0str\") " &
       "catch (TypeError ^expected e) e)", "\"C/CStr\""
    expect GeneError: discard runStr("(fn f [x : C/UInt8] x) (f -1)")
    expect GeneError: discard runStr("(fn f [x : C/Bool] x) (f 1)")

  test "C pointer annotations check mutability nullability and target type":
    var releases = 0
    proc releasePtr(address: pointer) {.nimcall.} =
      inc releases

    let scope = newGlobalScope()
    scope.define("p", newCPtr(cast[pointer](0x1234'u), newSym("C/Char")))
    scope.define("constp", newCConstPtr(cast[pointer](0x2345'u), newSym("C/Char")))
    scope.define("nullp", newCPtr(nil, newSym("C/Char")))
    scope.define("other", newCPtr(cast[pointer](0x3456'u), newSym("C/Int32")))
    scope.define("owned",
                 newCOwnedPtr(cast[pointer](0x4567'u), releasePtr,
                              newSym("C/Char")))

    check run(compileSource("((fn [p : (C/Ptr C/Char)] p) p)"),
              scope).print() == "(c_ptr)"
    check run(compileSource("((fn [p : (C/ConstPtr C/Char)] p) constp)"),
              scope).print() == "(c_const_ptr)"
    check run(compileSource("((fn [p : (C/ConstPtr C/Char)] p) p)"),
              scope).print() == "(c_ptr)"
    check run(compileSource("((fn [p : (C/NullablePtr C/Char)] true) nil)"),
              scope).print() == "true"
    check run(compileSource("((fn [p : (C/OwnedPtr C/Char)] true) owned)"),
              scope).print() == "true"

    expect GeneError:
      discard run(compileSource("((fn [p : (C/Ptr C/Char)] p) constp)"),
                  scope)
    expect GeneError:
      discard run(compileSource("((fn [p : (C/Ptr C/Char)] p) nil)"),
                  scope)
    expect GeneError:
      discard run(compileSource("((fn [p : (C/Ptr C/Char)] p) nullp)"),
                  scope)
    expect GeneError:
      discard run(compileSource("((fn [p : (C/Ptr C/Char)] p) other)"),
                  scope)

    check run(compileSource("[(C/closed? owned) (C/close owned) " &
                            "(C/closed? owned)]"),
              scope).print() == "[false nil true]"
    check releases == 1
    check run(compileSource("(C/close owned)"), scope).print() == "nil"
    check releases == 1
    expect GeneError:
      discard run(compileSource("(C/close p)"), scope)

  test "C slice annotations check target type and non-owning shape":
    let scope = newGlobalScope()
    scope.define("slice", newCSlice(cast[pointer](0x5678'u), 4,
                                    newSym("C/Char")))
    scope.define("empty", newCSlice(nil, 0, newSym("C/Char")))
    scope.define("bad-null", newCSlice(nil, 3, newSym("C/Char")))
    scope.define("other", newCSlice(cast[pointer](0x6789'u), 4,
                                    newSym("C/Int32")))

    check run(compileSource("((fn [s : (C/Slice C/Char)] s) slice)"),
              scope).print() == "(c-slice 4)"
    check run(compileSource("((fn [s : (C/Slice C/Char)] s) empty)"),
              scope).print() == "(c-slice null 0)"
    expect GeneError:
      discard run(compileSource("((fn [s : (C/Slice C/Char)] s) nil)"),
                  scope)
    expect GeneError:
      discard run(compileSource("((fn [s : (C/Slice C/Char)] s) bad-null)"),
                  scope)
    expect GeneError:
      discard run(compileSource("((fn [s : (C/Slice C/Char)] s) other)"),
                  scope)

  test "Buffer annotations check Gene-owned typed storage":
    ck "(var b (buffer [1 2 3])) " &
       "[(Buffer/len b) (Buffer/get b 0) (Buffer/get b -1) " &
       "(Buffer/to_list b) (Buffer/elem_type b)]",
       "[3 1 3 [1 2 3] Int]"
    ck "(var b (buffer C/UInt8 [1 2])) " &
       "[(Buffer/set! b 1 255) (Buffer/to_list b) " &
       "((fn [x : (Buffer C/UInt8)] true) b)]",
       "[255 [1 255] true]"
    ck "((fn [b : (Buffer Int)] true) (buffer [1 2]))", "true"
    ck "(try (buffer C/UInt8 [1 256]) " &
       "catch (TypeError ^expected e) e)", "\"C/UInt8\""
    expect GeneError:
      discard runStr("(var b (buffer C/UInt8 [1])) (Buffer/set! b 0 256)")
    expect GeneError:
      discard runStr("((fn [b : (Buffer C/UInt8)] b) (buffer C/Int32 [1]))")
    expect GeneError:
      discard runStr("(hash (buffer [1]))")

    let scope = newGlobalScope()
    scope.define("native-buf", newBuffer(newSym("C/Char"),
                                         @[newInt(65), newInt(66)]))
    check run(compileSource("((fn [b : (Buffer C/Char)] b) native-buf)"),
              scope).print() == "(buffer C/Char 2)"

  test "FFI load capability gates runtime library loading":
    ck "Ffi/Load", "(ffi_type Load)"

    let scope = newGlobalScope()
    scope.define("native", newFfiLoadCapability())
    check run(compileSource("((fn [cap : Ffi/Load] cap) native)"),
              scope).print() == "(ffi-load)"
    expect GeneError:
      discard run(compileSource("((fn [cap : Ffi/Load] cap) nil)"), scope)
    expect GeneError:
      discard run(compileSource("(ffi/open nil \"libmissing-gene-new\")"), scope)
    expect GeneError:
      discard run(compileSource("(ffi/open native \"libmissing-gene-new\")"),
                  scope)

    let libName = loadableFfiLibrary()
    if libName.len > 0:
      scope.define("lib-name", newStr(libName))
      let lib = run(compileSource("(ffi/open native lib-name)"), scope)
      check lib.kind == vkFfiLibrary
      check lib.ffiLibraryPath == libName
      check not lib.ffiLibraryClosed

      scope.define("lib", lib)
      check run(compileSource("((fn [handle : Ffi/Library] handle) lib)"),
                scope).print() == "(ffi-library)"
      check run(compileSource("(var strlen " &
                              "  (ffi/bind lib \"strlen\" [C/CStr] C/Size)) " &
                              "[(strlen \"hello\") " &
                              " ((fn [f : Ffi/Callable] (f \"Ada\")) strlen) " &
                              " strlen]"),
                scope).print() == "[5 3 (ffi-callable strlen)]"
      var dynBytes = [uint8(65), uint8(66), uint8(67)]
      scope.define("dyn-byte-slice",
                   newCSlice(cast[pointer](addr dynBytes[0]), dynBytes.len,
                             newSym("C/UInt8")))
      scope.define("dyn-byte-buffer",
                   newBuffer(newSym("C/UInt8"),
                             @[newInt(65), newInt(66), newInt(67)]))
      expect GeneError:
        discard run(compileSource("(ffi/bind lib \"ignored\" " &
                                  "  [(quote (C/Array C/Char 4))] C/Void)"),
                    scope)
      expect GeneError:
        discard run(compileSource("(ffi/bind lib \"ignored\" " &
                                  "  [(quote (C/Ptr C/Char C/Int))] C/Void)"),
                    scope)
      expect GeneError:
        discard run(compileSource("(ffi/bind lib \"ignored\" " &
                                  "  [(quote (C/Slice C/UInt8 C/UInt16))] C/Void)"),
                    scope)
      expect GeneError:
        discard run(compileSource("(ffi/bind lib \"ignored\" " &
                                  "  [C/CStr] (quote (C/Slice C/UInt8)))"),
                    scope)
      expect GeneError:
        discard run(compileSource("(ffi/bind lib \"ignored\" " &
                                  "  [C/Size] (quote (C/OwnedPtr C/Char C/Int)) " &
                                  "  \"free\")"),
                    scope)
      let handle = cast[LibHandle](lib.ffiLibraryHandle)
      if symAddr(handle, "strnlen") != nil:
        check run(compileSource("((ffi/bind lib \"strnlen\" " &
                                "  [(quote (C/Slice C/UInt8))] C/Size) " &
                                " dyn-byte-slice)"),
                  scope).print() == "3"
        check run(compileSource("((ffi/bind lib \"strnlen\" " &
                                "  [(quote (Buffer C/UInt8))] C/Size) " &
                                " dyn-byte-buffer)"),
                  scope).print() == "3"
      if symAddr(handle, "atoi") != nil:
        check run(compileSource("((ffi/bind lib \"atoi\" [C/CStr] C/Int) " &
                                " \"-42\")"),
                  scope).print() == "-42"
        check run(compileSource("((ffi/bind lib \"atoi\" [C/CStr] C/Int32) " &
                                " \"-42\")"),
                  scope).print() == "-42"
      if symAddr(handle, "atof") != nil:
        let parsed = run(compileSource(
          "((ffi/bind lib \"atof\" [C/CStr] C/Double) \"12.5\")"),
          scope)
        check parsed.kind == vkFloat
        check abs(parsed.floatVal - 12.5) < 0.000001
      let floatLibName = loadableFfiLibraryWithSymbol("sqrtf")
      if floatLibName.len > 0:
        scope.define("float-lib-name", newStr(floatLibName))
        let floatLib =
          if floatLibName == libName:
            lib
          else:
            run(compileSource("(ffi/open native float-lib-name)"), scope)
        scope.define("float-lib", floatLib)
        let root = run(compileSource(
          "((ffi/bind float-lib \"sqrtf\" [C/Float] C/Float) 9.0)"),
          scope)
        check root.kind == vkFloat
        check abs(root.floatVal - 3.0) < 0.0001
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind float-lib \"sqrtf\" [C/Float] C/Float) 1.0e50)"),
            scope)
        if floatLibName != libName:
          check run(compileSource("(Ffi/Library/close float-lib)"),
                    scope).print() == "nil"
      if symAddr(handle, "strcmp") != nil:
        check run(compileSource("((ffi/bind lib \"strcmp\" " &
                                "  [C/CStr C/CStr] C/Int) \"abc\" \"abc\")"),
                  scope).print() == "0"
      if symAddr(handle, "abs") != nil:
        check run(compileSource("((ffi/bind lib \"abs\" [C/Int] C/Int) -9)"),
                  scope).print() == "9"
        check run(compileSource(
          "((ffi/bind lib \"abs\" [C/Int32] C/Int32) -9)"),
          scope).print() == "9"
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"abs\" [C/Int32] C/Int32) 2147483648)"),
            scope)
      if symAddr(handle, "labs") != nil:
        check run(compileSource("((ffi/bind lib \"labs\" [C/Long] C/Long) -9)"),
                  scope).print() == "9"
      if symAddr(handle, "llabs") != nil:
        check run(compileSource(
          "((ffi/bind lib \"llabs\" [C/Int64] C/Int64) -9)"),
          scope).print() == "9"
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"llabs\" [C/Int64] C/Int64) " &
            " 9223372036854775808)"),
            scope)
      if symAddr(handle, "strerror") != nil:
        let message = run(compileSource(
          "((ffi/bind lib \"strerror\" [C/Int] C/CStr) 0)"),
          scope)
        check message.kind == vkString
        check message.strVal.len > 0
      if symAddr(handle, "getpid") != nil:
        let pid = run(compileSource("((ffi/bind lib \"getpid\" [] C/Int))"),
                      scope)
        check pid.kind == vkInt
        check pid.intVal > 0
      if symAddr(handle, "getuid") != nil:
        let uid = run(compileSource("((ffi/bind lib \"getuid\" [] C/UInt))"),
                      scope)
        check uid.kind == vkInt
        check uid.intVal >= 0
      if symAddr(handle, "sleep") != nil:
        check run(compileSource("((ffi/bind lib \"sleep\" [C/UInt] C/UInt) 0)"),
                  scope).print() == "0"
        check run(compileSource(
          "((ffi/bind lib \"sleep\" [C/UInt32] C/UInt32) 0)"),
          scope).print() == "0"
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"sleep\" [C/UInt] C/UInt) -1)"),
            scope)
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"sleep\" [C/UInt32] C/UInt32) -1)"),
            scope)
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"sleep\" [C/UInt] C/UInt) 4294967296)"),
            scope)
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"sleep\" [C/UInt32] C/UInt32) 4294967296)"),
            scope)
      if symAddr(handle, "getenv") != nil:
        check run(compileSource("((ffi/bind lib \"getenv\" [C/CStr] " &
                                "  (quote (C/NullableConstPtr C/Char))) " &
                                " \"GENE_NEW_TEST_ENV_UNSET\")"),
                  scope).print() == "(c_const_ptr null)"
      if symAddr(handle, "getenv") != nil and symAddr(handle, "strlen") != nil:
        let envPtr = run(compileSource("((ffi/bind lib \"getenv\" [C/CStr] " &
                                       "  (quote (C/NullableConstPtr C/Char))) " &
                                       " \"PATH\")"),
                         scope)
        if envPtr.kind == vkCPtr and not envPtr.cPtrIsNull:
          scope.define("env-ptr", envPtr)
          let lenResult = run(compileSource(
            "((ffi/bind lib \"strlen\" [(quote (C/ConstPtr C/Char))] C/Size) env-ptr)"),
            scope)
          check lenResult.kind == vkInt
          check lenResult.intVal > 0
          scope.define("wrong-env-ptr",
                       newCConstPtr(envPtr.cPtrAddress, newSym("C/Int32")))
          if symAddr(handle, "memcmp") != nil:
            check run(compileSource("((ffi/bind lib \"memcmp\" " &
                                    "  [(quote (C/ConstPtr C/Char)) " &
                                    "   (quote (C/ConstPtr C/Char)) C/Size] " &
                                    "  C/Int) env-ptr env-ptr 1)"),
                      scope).print() == "0"
            expect GeneError:
              discard run(compileSource("((ffi/bind lib \"memcmp\" " &
                                        "  [(quote (C/ConstPtr C/Char)) " &
                                        "   (quote (C/ConstPtr C/Char)) C/Size] " &
                                        "  C/Int) wrong-env-ptr env-ptr 1)"),
                          scope)
            expect GeneError:
              discard run(compileSource("((ffi/bind lib \"memcmp\" " &
                                        "  [(quote (C/ConstPtr C/Char)) " &
                                        "   (quote (C/ConstPtr C/Char)) C/Size] " &
                                        "  C/Int) env-ptr env-ptr -1)"),
                          scope)
          if symAddr(handle, "memchr") != nil:
            check run(compileSource("((ffi/bind lib \"memchr\" " &
                                    "  [(quote (C/ConstPtr C/Char)) C/Int C/Size] " &
                                    "  (quote (C/NullableConstPtr C/Char))) " &
                                    " env-ptr 0 1)"),
                      scope).print() == "(c_const_ptr null)"
            expect GeneError:
              discard run(compileSource("((ffi/bind lib \"memchr\" " &
                                        "  [(quote (C/ConstPtr C/Char)) C/Int C/Size] " &
                                        "  (quote (C/NullableConstPtr C/Char))) " &
                                        " wrong-env-ptr 0 1)"),
                          scope)
      if symAddr(handle, "strchr") != nil:
        check run(compileSource("((ffi/bind lib \"strchr\" [C/CStr C/Int] " &
                                "  (quote (C/NullableConstPtr C/Char))) " &
                                " \"abc\" 98)"),
                  scope).print() == "(c_const_ptr)"
        check run(compileSource("((ffi/bind lib \"strchr\" [C/CStr C/Int] " &
                                "  (quote (C/NullableConstPtr C/Char))) " &
                                " \"abc\" 120)"),
                  scope).print() == "(c_const_ptr null)"
      if symAddr(handle, "malloc") != nil and symAddr(handle, "free") != nil:
        let allocated = run(compileSource(
          "((ffi/bind lib \"malloc\" [C/Size] " &
          "   (quote (C/OwnedPtr C/Char)) \"free\") 8)"),
          scope)
        check allocated.kind == vkCPtr
        check allocated.cPtrOwned
        check not allocated.cPtrClosed
        scope.define("allocated", allocated)
        check run(compileSource("[(C/closed? allocated) " &
                                " (C/close allocated) " &
                                " (C/closed? allocated)]"),
                  scope).print() == "[false nil true]"
        let rawAllocated = run(compileSource(
          "((ffi/bind lib \"malloc\" [C/Size] " &
          "   (quote (C/Ptr C/Char))) 8)"),
          scope)
        check rawAllocated.kind == vkCPtr
        check not rawAllocated.cPtrOwned
        scope.define("raw-allocated", rawAllocated)
        check run(compileSource(
          "((ffi/bind lib \"free\" [(quote (C/Ptr C/Char))] C/Void) " &
          " raw-allocated)"),
          scope).print() == "nil"
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"malloc\" [C/Size] " &
            "   (quote (C/OwnedPtr C/Char)) \"free\") -1)"),
            scope)
        expect GeneError:
          discard run(compileSource(
            "(ffi/bind lib \"malloc\" [C/Size] " &
            "  (quote (C/Ptr C/Char)) \"free\")"),
            scope)
      if symAddr(handle, "calloc") != nil and symAddr(handle, "free") != nil:
        let zeroed = run(compileSource(
          "((ffi/bind lib \"calloc\" [C/Size C/Size] " &
          "   (quote (C/OwnedPtr C/Char)) \"free\") 2 4)"),
          scope)
        check zeroed.kind == vkCPtr
        check zeroed.cPtrOwned
        check not zeroed.cPtrClosed
        scope.define("zeroed", zeroed)
        check run(compileSource("[(C/closed? zeroed) " &
                                " (C/close zeroed) " &
                                " (C/closed? zeroed)]"),
                  scope).print() == "[false nil true]"
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"calloc\" [C/Size C/Size] " &
            "   (quote (C/OwnedPtr C/Char)) \"free\") -1 4)"),
            scope)
      if symAddr(handle, "strdup") != nil and symAddr(handle, "free") != nil:
        expect GeneError:
          discard run(compileSource("(ffi/bind lib \"strdup\" [C/CStr] " &
                                    "  (quote (C/OwnedPtr C/Char)))"),
                      scope)
        let ownedDup = run(compileSource(
          "((ffi/bind lib \"strdup\" [C/CStr] " &
          "   (quote (C/OwnedPtr C/Char)) \"free\") \"owned\")"),
          scope)
        check ownedDup.kind == vkCPtr
        check ownedDup.cPtrOwned
        check not ownedDup.cPtrClosed
        check ownedDup.cPtrTargetType.print() == "C/Char"
        scope.define("owned-dup", ownedDup)
        check run(compileSource("[(C/closed? owned-dup) " &
                                " (C/close owned-dup) " &
                                " (C/closed? owned-dup)]"),
                  scope).print() == "[false nil true]"
      check run(compileSource("(Ffi/Library/closed? lib)"),
                scope).print() == "false"
      check run(compileSource("(Ffi/Library/path lib)"), scope).strVal == libName
      check run(compileSource("(Ffi/Library/close lib)"), scope).print() == "nil"
      check run(compileSource("(Ffi/Library/closed? lib)"),
                scope).print() == "true"
      expect GeneError:
        discard run(compileSource("(strlen \"closed\")"), scope)

  test "direct FFI callable supports exact scalar and view ABI":
    let handle = loadLib()
    if handle != nil:
      let scope = newGlobalScope()
      let lib = newFfiLibrary(handle, "<self>", nil)
      scope.define("i16-abs",
                   newFfiCallable("ffiTestI16Abs", "ffiTestI16Abs",
                                  cast[pointer](ffiTestI16Abs), lib,
                                  @[newSym("C/Int16")], newSym("C/Int16")))
      scope.define("u16-inc",
                   newFfiCallable("ffiTestU16Inc", "ffiTestU16Inc",
                                  cast[pointer](ffiTestU16Inc), lib,
                                  @[newSym("C/UInt16")], newSym("C/UInt16")))
      scope.define("short-abs",
                   newFfiCallable("ffiTestShortAbs", "ffiTestShortAbs",
                                  cast[pointer](ffiTestShortAbs), lib,
                                  @[newSym("C/Short")], newSym("C/Short")))
      scope.define("short-i8",
                   newFfiCallable("ffiTestShortI8", "ffiTestShortI8",
                                  cast[pointer](ffiTestShortI8), lib,
                                  @[newSym("C/Short")], newSym("C/Int8")))
      scope.define("short-char",
                   newFfiCallable("ffiTestShortChar",
                                  "ffiTestShortChar",
                                  cast[pointer](ffiTestShortChar), lib,
                                  @[newSym("C/Short")], newSym("C/Char")))
      scope.define("short-ulong",
                   newFfiCallable("ffiTestShortULong",
                                  "ffiTestShortULong",
                                  cast[pointer](ffiTestShortULong), lib,
                                  @[newSym("C/Short")], newSym("C/ULong")))
      scope.define("short-u8",
                   newFfiCallable("ffiTestShortU8", "ffiTestShortU8",
                                  cast[pointer](ffiTestShortU8), lib,
                                  @[newSym("C/Short")], newSym("C/UInt8")))
      scope.define("short-uchar",
                   newFfiCallable("ffiTestShortUChar",
                                  "ffiTestShortUChar",
                                  cast[pointer](ffiTestShortUChar), lib,
                                  @[newSym("C/Short")], newSym("C/UChar")))
      scope.define("short-u64",
                   newFfiCallable("ffiTestShortU64",
                                  "ffiTestShortU64",
                                  cast[pointer](ffiTestShortU64), lib,
                                  @[newSym("C/Short")], newSym("C/UInt64")))
      scope.define("short-diff",
                   newFfiCallable("ffiTestShortDiff",
                                  "ffiTestShortDiff",
                                  cast[pointer](ffiTestShortDiff), lib,
                                  @[newSym("C/Short")], newSym("C/PtrDiff")))
      scope.define("short-positive?",
                   newFfiCallable("ffiTestShortPositive",
                                  "ffiTestShortPositive",
                                  cast[pointer](ffiTestShortPositive), lib,
                                  @[newSym("C/Short")], newSym("C/Bool")))
      scope.define("ushort-inc",
                   newFfiCallable("ffiTestUShortInc", "ffiTestUShortInc",
                                  cast[pointer](ffiTestUShortInc), lib,
                                  @[newSym("C/UShort")], newSym("C/UShort")))
      scope.define("ushort-i8",
                   newFfiCallable("ffiTestUShortI8",
                                  "ffiTestUShortI8",
                                  cast[pointer](ffiTestUShortI8), lib,
                                  @[newSym("C/UShort")], newSym("C/Int8")))
      scope.define("ushort-char",
                   newFfiCallable("ffiTestUShortChar",
                                  "ffiTestUShortChar",
                                  cast[pointer](ffiTestUShortChar), lib,
                                  @[newSym("C/UShort")], newSym("C/Char")))
      scope.define("ushort-ulong",
                   newFfiCallable("ffiTestUShortULong",
                                  "ffiTestUShortULong",
                                  cast[pointer](ffiTestUShortULong), lib,
                                  @[newSym("C/UShort")], newSym("C/ULong")))
      scope.define("ushort-u8",
                   newFfiCallable("ffiTestUShortU8",
                                  "ffiTestUShortU8",
                                  cast[pointer](ffiTestUShortU8), lib,
                                  @[newSym("C/UShort")], newSym("C/UInt8")))
      scope.define("ushort-uchar",
                   newFfiCallable("ffiTestUShortUChar",
                                  "ffiTestUShortUChar",
                                  cast[pointer](ffiTestUShortUChar), lib,
                                  @[newSym("C/UShort")], newSym("C/UChar")))
      scope.define("ushort-u64",
                   newFfiCallable("ffiTestUShortU64",
                                  "ffiTestUShortU64",
                                  cast[pointer](ffiTestUShortU64), lib,
                                  @[newSym("C/UShort")], newSym("C/UInt64")))
      scope.define("ushort-diff",
                   newFfiCallable("ffiTestUShortDiff",
                                  "ffiTestUShortDiff",
                                  cast[pointer](ffiTestUShortDiff), lib,
                                  @[newSym("C/UShort")], newSym("C/PtrDiff")))
      scope.define("ushort-non-zero?",
                   newFfiCallable("ffiTestUShortNonZero",
                                  "ffiTestUShortNonZero",
                                  cast[pointer](ffiTestUShortNonZero), lib,
                                  @[newSym("C/UShort")], newSym("C/Bool")))
      scope.define("i8-abs",
                   newFfiCallable("ffiTestI8Abs", "ffiTestI8Abs",
                                  cast[pointer](ffiTestI8Abs), lib,
                                  @[newSym("C/Int8")], newSym("C/Int8")))
      scope.define("i8-short",
                   newFfiCallable("ffiTestI8Short",
                                  "ffiTestI8Short",
                                  cast[pointer](ffiTestI8Short), lib,
                                  @[newSym("C/Int8")], newSym("C/Short")))
      scope.define("i8-char",
                   newFfiCallable("ffiTestI8Char",
                                  "ffiTestI8Char",
                                  cast[pointer](ffiTestI8Char), lib,
                                  @[newSym("C/Int8")], newSym("C/Char")))
      scope.define("i8-ulong",
                   newFfiCallable("ffiTestI8ULong",
                                  "ffiTestI8ULong",
                                  cast[pointer](ffiTestI8ULong), lib,
                                  @[newSym("C/Int8")], newSym("C/ULong")))
      scope.define("i8-ushort",
                   newFfiCallable("ffiTestI8UShort",
                                  "ffiTestI8UShort",
                                  cast[pointer](ffiTestI8UShort), lib,
                                  @[newSym("C/Int8")], newSym("C/UShort")))
      scope.define("i8-uchar",
                   newFfiCallable("ffiTestI8UChar",
                                  "ffiTestI8UChar",
                                  cast[pointer](ffiTestI8UChar), lib,
                                  @[newSym("C/Int8")], newSym("C/UChar")))
      scope.define("i8-u64",
                   newFfiCallable("ffiTestI8U64",
                                  "ffiTestI8U64",
                                  cast[pointer](ffiTestI8U64), lib,
                                  @[newSym("C/Int8")], newSym("C/UInt64")))
      scope.define("i8-diff",
                   newFfiCallable("ffiTestI8Diff",
                                  "ffiTestI8Diff",
                                  cast[pointer](ffiTestI8Diff), lib,
                                  @[newSym("C/Int8")], newSym("C/PtrDiff")))
      scope.define("i8-positive?",
                   newFfiCallable("ffiTestI8Positive",
                                  "ffiTestI8Positive",
                                  cast[pointer](ffiTestI8Positive), lib,
                                  @[newSym("C/Int8")], newSym("C/Bool")))
      scope.define("u8-inc",
                   newFfiCallable("ffiTestU8Inc", "ffiTestU8Inc",
                                  cast[pointer](ffiTestU8Inc), lib,
                                  @[newSym("C/UInt8")], newSym("C/UInt8")))
      scope.define("u8-short",
                   newFfiCallable("ffiTestU8Short",
                                  "ffiTestU8Short",
                                  cast[pointer](ffiTestU8Short), lib,
                                  @[newSym("C/UInt8")], newSym("C/Short")))
      scope.define("u8-char",
                   newFfiCallable("ffiTestU8Char",
                                  "ffiTestU8Char",
                                  cast[pointer](ffiTestU8Char), lib,
                                  @[newSym("C/UInt8")], newSym("C/Char")))
      scope.define("u8-ulong",
                   newFfiCallable("ffiTestU8ULong",
                                  "ffiTestU8ULong",
                                  cast[pointer](ffiTestU8ULong), lib,
                                  @[newSym("C/UInt8")], newSym("C/ULong")))
      scope.define("u8-ushort",
                   newFfiCallable("ffiTestU8UShort",
                                  "ffiTestU8UShort",
                                  cast[pointer](ffiTestU8UShort), lib,
                                  @[newSym("C/UInt8")], newSym("C/UShort")))
      scope.define("u8-uchar",
                   newFfiCallable("ffiTestU8UChar",
                                  "ffiTestU8UChar",
                                  cast[pointer](ffiTestU8UChar), lib,
                                  @[newSym("C/UInt8")], newSym("C/UChar")))
      scope.define("u8-u64",
                   newFfiCallable("ffiTestU8U64",
                                  "ffiTestU8U64",
                                  cast[pointer](ffiTestU8U64), lib,
                                  @[newSym("C/UInt8")], newSym("C/UInt64")))
      scope.define("u8-diff",
                   newFfiCallable("ffiTestU8Diff",
                                  "ffiTestU8Diff",
                                  cast[pointer](ffiTestU8Diff), lib,
                                  @[newSym("C/UInt8")], newSym("C/PtrDiff")))
      scope.define("u8-non-zero?",
                   newFfiCallable("ffiTestU8NonZero",
                                  "ffiTestU8NonZero",
                                  cast[pointer](ffiTestU8NonZero), lib,
                                  @[newSym("C/UInt8")], newSym("C/Bool")))
      scope.define("char-next",
                   newFfiCallable("ffiTestCharNext", "ffiTestCharNext",
                                  cast[pointer](ffiTestCharNext), lib,
                                  @[newSym("C/Char")], newSym("C/Char")))
      scope.define("char-i32",
                   newFfiCallable("ffiTestCharI32",
                                  "ffiTestCharI32",
                                  cast[pointer](ffiTestCharI32), lib,
                                  @[newSym("C/Char")], newSym("C/Int32")))
      scope.define("char-i16",
                   newFfiCallable("ffiTestCharI16",
                                  "ffiTestCharI16",
                                  cast[pointer](ffiTestCharI16), lib,
                                  @[newSym("C/Char")], newSym("C/Int16")))
      scope.define("char-short",
                   newFfiCallable("ffiTestCharShort",
                                  "ffiTestCharShort",
                                  cast[pointer](ffiTestCharShort), lib,
                                  @[newSym("C/Char")], newSym("C/Short")))
      scope.define("char-i8",
                   newFfiCallable("ffiTestCharI8",
                                  "ffiTestCharI8",
                                  cast[pointer](ffiTestCharI8), lib,
                                  @[newSym("C/Char")], newSym("C/Int8")))
      scope.define("char-ulong",
                   newFfiCallable("ffiTestCharULong",
                                  "ffiTestCharULong",
                                  cast[pointer](ffiTestCharULong), lib,
                                  @[newSym("C/Char")], newSym("C/ULong")))
      scope.define("char-u32",
                   newFfiCallable("ffiTestCharU32",
                                  "ffiTestCharU32",
                                  cast[pointer](ffiTestCharU32), lib,
                                  @[newSym("C/Char")], newSym("C/UInt32")))
      scope.define("char-u16",
                   newFfiCallable("ffiTestCharU16",
                                  "ffiTestCharU16",
                                  cast[pointer](ffiTestCharU16), lib,
                                  @[newSym("C/Char")], newSym("C/UInt16")))
      scope.define("char-ushort",
                   newFfiCallable("ffiTestCharUShort",
                                  "ffiTestCharUShort",
                                  cast[pointer](ffiTestCharUShort), lib,
                                  @[newSym("C/Char")], newSym("C/UShort")))
      scope.define("char-u8",
                   newFfiCallable("ffiTestCharU8",
                                  "ffiTestCharU8",
                                  cast[pointer](ffiTestCharU8), lib,
                                  @[newSym("C/Char")], newSym("C/UInt8")))
      scope.define("char-i64",
                   newFfiCallable("ffiTestCharI64",
                                  "ffiTestCharI64",
                                  cast[pointer](ffiTestCharI64), lib,
                                  @[newSym("C/Char")], newSym("C/Int64")))
      scope.define("char-u64",
                   newFfiCallable("ffiTestCharU64",
                                  "ffiTestCharU64",
                                  cast[pointer](ffiTestCharU64), lib,
                                  @[newSym("C/Char")], newSym("C/UInt64")))
      scope.define("char-diff",
                   newFfiCallable("ffiTestCharDiff",
                                  "ffiTestCharDiff",
                                  cast[pointer](ffiTestCharDiff), lib,
                                  @[newSym("C/Char")], newSym("C/PtrDiff")))
      scope.define("uchar-inc",
                   newFfiCallable("ffiTestUCharInc", "ffiTestUCharInc",
                                  cast[pointer](ffiTestUCharInc), lib,
                                  @[newSym("C/UChar")], newSym("C/UChar")))
      scope.define("uchar-i32",
                   newFfiCallable("ffiTestUCharI32",
                                  "ffiTestUCharI32",
                                  cast[pointer](ffiTestUCharI32), lib,
                                  @[newSym("C/UChar")], newSym("C/Int32")))
      scope.define("uchar-i16",
                   newFfiCallable("ffiTestUCharI16",
                                  "ffiTestUCharI16",
                                  cast[pointer](ffiTestUCharI16), lib,
                                  @[newSym("C/UChar")], newSym("C/Int16")))
      scope.define("uchar-short",
                   newFfiCallable("ffiTestUCharShort",
                                  "ffiTestUCharShort",
                                  cast[pointer](ffiTestUCharShort), lib,
                                  @[newSym("C/UChar")], newSym("C/Short")))
      scope.define("uchar-i8",
                   newFfiCallable("ffiTestUCharI8",
                                  "ffiTestUCharI8",
                                  cast[pointer](ffiTestUCharI8), lib,
                                  @[newSym("C/UChar")], newSym("C/Int8")))
      scope.define("uchar-ulong",
                   newFfiCallable("ffiTestUCharULong",
                                  "ffiTestUCharULong",
                                  cast[pointer](ffiTestUCharULong), lib,
                                  @[newSym("C/UChar")], newSym("C/ULong")))
      scope.define("uchar-u32",
                   newFfiCallable("ffiTestUCharU32",
                                  "ffiTestUCharU32",
                                  cast[pointer](ffiTestUCharU32), lib,
                                  @[newSym("C/UChar")], newSym("C/UInt32")))
      scope.define("uchar-u16",
                   newFfiCallable("ffiTestUCharU16",
                                  "ffiTestUCharU16",
                                  cast[pointer](ffiTestUCharU16), lib,
                                  @[newSym("C/UChar")], newSym("C/UInt16")))
      scope.define("uchar-ushort",
                   newFfiCallable("ffiTestUCharUShort",
                                  "ffiTestUCharUShort",
                                  cast[pointer](ffiTestUCharUShort), lib,
                                  @[newSym("C/UChar")], newSym("C/UShort")))
      scope.define("uchar-u8",
                   newFfiCallable("ffiTestUCharU8",
                                  "ffiTestUCharU8",
                                  cast[pointer](ffiTestUCharU8), lib,
                                  @[newSym("C/UChar")], newSym("C/UInt8")))
      scope.define("uchar-i64",
                   newFfiCallable("ffiTestUCharI64",
                                  "ffiTestUCharI64",
                                  cast[pointer](ffiTestUCharI64), lib,
                                  @[newSym("C/UChar")], newSym("C/Int64")))
      scope.define("uchar-u64",
                   newFfiCallable("ffiTestUCharU64",
                                  "ffiTestUCharU64",
                                  cast[pointer](ffiTestUCharU64), lib,
                                  @[newSym("C/UChar")], newSym("C/UInt64")))
      scope.define("uchar-diff",
                   newFfiCallable("ffiTestUCharDiff",
                                  "ffiTestUCharDiff",
                                  cast[pointer](ffiTestUCharDiff), lib,
                                  @[newSym("C/UChar")], newSym("C/PtrDiff")))
      scope.define("bool-not",
                   newFfiCallable("ffiTestBoolNot", "ffiTestBoolNot",
                                  cast[pointer](ffiTestBoolNot), lib,
                                  @[newSym("C/Bool")], newSym("C/Bool")))
      scope.define("bool-ulong",
                   newFfiCallable("ffiTestBoolULong",
                                  "ffiTestBoolULong",
                                  cast[pointer](ffiTestBoolULong), lib,
                                  @[newSym("C/Bool")], newSym("C/ULong")))
      scope.define("bool-i32",
                   newFfiCallable("ffiTestBoolI32",
                                  "ffiTestBoolI32",
                                  cast[pointer](ffiTestBoolI32), lib,
                                  @[newSym("C/Bool")], newSym("C/Int32")))
      scope.define("bool-i16",
                   newFfiCallable("ffiTestBoolI16",
                                  "ffiTestBoolI16",
                                  cast[pointer](ffiTestBoolI16), lib,
                                  @[newSym("C/Bool")], newSym("C/Int16")))
      scope.define("bool-short",
                   newFfiCallable("ffiTestBoolShort",
                                  "ffiTestBoolShort",
                                  cast[pointer](ffiTestBoolShort), lib,
                                  @[newSym("C/Bool")], newSym("C/Short")))
      scope.define("bool-i8",
                   newFfiCallable("ffiTestBoolI8",
                                  "ffiTestBoolI8",
                                  cast[pointer](ffiTestBoolI8), lib,
                                  @[newSym("C/Bool")], newSym("C/Int8")))
      scope.define("bool-char",
                   newFfiCallable("ffiTestBoolChar",
                                  "ffiTestBoolChar",
                                  cast[pointer](ffiTestBoolChar), lib,
                                  @[newSym("C/Bool")], newSym("C/Char")))
      scope.define("bool-u32",
                   newFfiCallable("ffiTestBoolU32",
                                  "ffiTestBoolU32",
                                  cast[pointer](ffiTestBoolU32), lib,
                                  @[newSym("C/Bool")], newSym("C/UInt32")))
      scope.define("bool-u16",
                   newFfiCallable("ffiTestBoolU16",
                                  "ffiTestBoolU16",
                                  cast[pointer](ffiTestBoolU16), lib,
                                  @[newSym("C/Bool")], newSym("C/UInt16")))
      scope.define("bool-ushort",
                   newFfiCallable("ffiTestBoolUShort",
                                  "ffiTestBoolUShort",
                                  cast[pointer](ffiTestBoolUShort), lib,
                                  @[newSym("C/Bool")], newSym("C/UShort")))
      scope.define("bool-u8",
                   newFfiCallable("ffiTestBoolU8",
                                  "ffiTestBoolU8",
                                  cast[pointer](ffiTestBoolU8), lib,
                                  @[newSym("C/Bool")], newSym("C/UInt8")))
      scope.define("bool-uchar",
                   newFfiCallable("ffiTestBoolUChar",
                                  "ffiTestBoolUChar",
                                  cast[pointer](ffiTestBoolUChar), lib,
                                  @[newSym("C/Bool")], newSym("C/UChar")))
      scope.define("bool-i64",
                   newFfiCallable("ffiTestBoolI64",
                                  "ffiTestBoolI64",
                                  cast[pointer](ffiTestBoolI64), lib,
                                  @[newSym("C/Bool")], newSym("C/Int64")))
      scope.define("bool-u64",
                   newFfiCallable("ffiTestBoolU64",
                                  "ffiTestBoolU64",
                                  cast[pointer](ffiTestBoolU64), lib,
                                  @[newSym("C/Bool")], newSym("C/UInt64")))
      scope.define("bool-diff",
                   newFfiCallable("ffiTestBoolDiff",
                                  "ffiTestBoolDiff",
                                  cast[pointer](ffiTestBoolDiff), lib,
                                  @[newSym("C/Bool")], newSym("C/PtrDiff")))
      scope.define("u64-inc",
                   newFfiCallable("ffiTestU64Inc", "ffiTestU64Inc",
                                  cast[pointer](ffiTestU64Inc), lib,
                                  @[newSym("C/UInt64")], newSym("C/UInt64")))
      scope.define("u64-i32",
                   newFfiCallable("ffiTestU64I32", "ffiTestU64I32",
                                  cast[pointer](ffiTestU64I32), lib,
                                  @[newSym("C/UInt64")], newSym("C/Int32")))
      scope.define("u64-i16",
                   newFfiCallable("ffiTestU64I16", "ffiTestU64I16",
                                  cast[pointer](ffiTestU64I16), lib,
                                  @[newSym("C/UInt64")], newSym("C/Int16")))
      scope.define("u64-short",
                   newFfiCallable("ffiTestU64Short",
                                  "ffiTestU64Short",
                                  cast[pointer](ffiTestU64Short), lib,
                                  @[newSym("C/UInt64")], newSym("C/Short")))
      scope.define("u64-i8",
                   newFfiCallable("ffiTestU64I8", "ffiTestU64I8",
                                  cast[pointer](ffiTestU64I8), lib,
                                  @[newSym("C/UInt64")], newSym("C/Int8")))
      scope.define("u64-char",
                   newFfiCallable("ffiTestU64Char",
                                  "ffiTestU64Char",
                                  cast[pointer](ffiTestU64Char), lib,
                                  @[newSym("C/UInt64")], newSym("C/Char")))
      scope.define("u64-u32",
                   newFfiCallable("ffiTestU64U32", "ffiTestU64U32",
                                  cast[pointer](ffiTestU64U32), lib,
                                  @[newSym("C/UInt64")], newSym("C/UInt32")))
      scope.define("u64-u16",
                   newFfiCallable("ffiTestU64U16", "ffiTestU64U16",
                                  cast[pointer](ffiTestU64U16), lib,
                                  @[newSym("C/UInt64")], newSym("C/UInt16")))
      scope.define("u64-ushort",
                   newFfiCallable("ffiTestU64UShort",
                                  "ffiTestU64UShort",
                                  cast[pointer](ffiTestU64UShort), lib,
                                  @[newSym("C/UInt64")], newSym("C/UShort")))
      scope.define("u64-u8",
                   newFfiCallable("ffiTestU64U8", "ffiTestU64U8",
                                  cast[pointer](ffiTestU64U8), lib,
                                  @[newSym("C/UInt64")], newSym("C/UInt8")))
      scope.define("u64-uchar",
                   newFfiCallable("ffiTestU64UChar",
                                  "ffiTestU64UChar",
                                  cast[pointer](ffiTestU64UChar), lib,
                                  @[newSym("C/UInt64")], newSym("C/UChar")))
      scope.define("ulong-inc",
                   newFfiCallable("ffiTestULongInc", "ffiTestULongInc",
                                  cast[pointer](ffiTestULongInc), lib,
                                  @[newSym("C/ULong")], newSym("C/ULong")))
      scope.define("ulong-i32",
                   newFfiCallable("ffiTestULongI32",
                                  "ffiTestULongI32",
                                  cast[pointer](ffiTestULongI32), lib,
                                  @[newSym("C/ULong")], newSym("C/Int32")))
      scope.define("ulong-i16",
                   newFfiCallable("ffiTestULongI16",
                                  "ffiTestULongI16",
                                  cast[pointer](ffiTestULongI16), lib,
                                  @[newSym("C/ULong")], newSym("C/Int16")))
      scope.define("ulong-short",
                   newFfiCallable("ffiTestULongShort",
                                  "ffiTestULongShort",
                                  cast[pointer](ffiTestULongShort), lib,
                                  @[newSym("C/ULong")], newSym("C/Short")))
      scope.define("ulong-i8",
                   newFfiCallable("ffiTestULongI8",
                                  "ffiTestULongI8",
                                  cast[pointer](ffiTestULongI8), lib,
                                  @[newSym("C/ULong")], newSym("C/Int8")))
      scope.define("ulong-char",
                   newFfiCallable("ffiTestULongChar",
                                  "ffiTestULongChar",
                                  cast[pointer](ffiTestULongChar), lib,
                                  @[newSym("C/ULong")], newSym("C/Char")))
      scope.define("ulong-u32",
                   newFfiCallable("ffiTestULongU32",
                                  "ffiTestULongU32",
                                  cast[pointer](ffiTestULongU32), lib,
                                  @[newSym("C/ULong")], newSym("C/UInt32")))
      scope.define("ulong-u16",
                   newFfiCallable("ffiTestULongU16",
                                  "ffiTestULongU16",
                                  cast[pointer](ffiTestULongU16), lib,
                                  @[newSym("C/ULong")], newSym("C/UInt16")))
      scope.define("ulong-ushort",
                   newFfiCallable("ffiTestULongUShort",
                                  "ffiTestULongUShort",
                                  cast[pointer](ffiTestULongUShort), lib,
                                  @[newSym("C/ULong")], newSym("C/UShort")))
      scope.define("ulong-u8",
                   newFfiCallable("ffiTestULongU8",
                                  "ffiTestULongU8",
                                  cast[pointer](ffiTestULongU8), lib,
                                  @[newSym("C/ULong")], newSym("C/UInt8")))
      scope.define("ulong-uchar",
                   newFfiCallable("ffiTestULongUChar",
                                  "ffiTestULongUChar",
                                  cast[pointer](ffiTestULongUChar), lib,
                                  @[newSym("C/ULong")], newSym("C/UChar")))
      scope.define("ptrdiff-abs",
                   newFfiCallable("ffiTestPtrDiffAbs", "ffiTestPtrDiffAbs",
                                  cast[pointer](ffiTestPtrDiffAbs), lib,
                                  @[newSym("C/PtrDiff")],
                                  newSym("C/PtrDiff")))
      scope.define("ptrdiff-i32",
                   newFfiCallable("ffiTestPtrDiffI32",
                                  "ffiTestPtrDiffI32",
                                  cast[pointer](ffiTestPtrDiffI32), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/Int32")))
      scope.define("ptrdiff-i16",
                   newFfiCallable("ffiTestPtrDiffI16",
                                  "ffiTestPtrDiffI16",
                                  cast[pointer](ffiTestPtrDiffI16), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/Int16")))
      scope.define("ptrdiff-short",
                   newFfiCallable("ffiTestPtrDiffShort",
                                  "ffiTestPtrDiffShort",
                                  cast[pointer](ffiTestPtrDiffShort), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/Short")))
      scope.define("ptrdiff-i8",
                   newFfiCallable("ffiTestPtrDiffI8",
                                  "ffiTestPtrDiffI8",
                                  cast[pointer](ffiTestPtrDiffI8), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/Int8")))
      scope.define("ptrdiff-char",
                   newFfiCallable("ffiTestPtrDiffChar",
                                  "ffiTestPtrDiffChar",
                                  cast[pointer](ffiTestPtrDiffChar), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/Char")))
      scope.define("ptrdiff-u32",
                   newFfiCallable("ffiTestPtrDiffU32",
                                  "ffiTestPtrDiffU32",
                                  cast[pointer](ffiTestPtrDiffU32), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/UInt32")))
      scope.define("ptrdiff-u16",
                   newFfiCallable("ffiTestPtrDiffU16",
                                  "ffiTestPtrDiffU16",
                                  cast[pointer](ffiTestPtrDiffU16), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/UInt16")))
      scope.define("ptrdiff-ushort",
                   newFfiCallable("ffiTestPtrDiffUShort",
                                  "ffiTestPtrDiffUShort",
                                  cast[pointer](ffiTestPtrDiffUShort), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/UShort")))
      scope.define("ptrdiff-u8",
                   newFfiCallable("ffiTestPtrDiffU8",
                                  "ffiTestPtrDiffU8",
                                  cast[pointer](ffiTestPtrDiffU8), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/UInt8")))
      scope.define("ptrdiff-uchar",
                   newFfiCallable("ffiTestPtrDiffUChar",
                                  "ffiTestPtrDiffUChar",
                                  cast[pointer](ffiTestPtrDiffUChar), lib,
                                  @[newSym("C/PtrDiff")], newSym("C/UChar")))
      scope.define("size-inc",
                   newFfiCallable("ffiTestSizeInc", "ffiTestSizeInc",
                                  cast[pointer](ffiTestSizeInc), lib,
                                  @[newSym("C/Size")], newSym("C/Size")))
      scope.define("size-i32",
                   newFfiCallable("ffiTestSizeI32", "ffiTestSizeI32",
                                  cast[pointer](ffiTestSizeI32), lib,
                                  @[newSym("C/Size")], newSym("C/Int32")))
      scope.define("size-i16",
                   newFfiCallable("ffiTestSizeI16", "ffiTestSizeI16",
                                  cast[pointer](ffiTestSizeI16), lib,
                                  @[newSym("C/Size")], newSym("C/Int16")))
      scope.define("size-short",
                   newFfiCallable("ffiTestSizeShort",
                                  "ffiTestSizeShort",
                                  cast[pointer](ffiTestSizeShort), lib,
                                  @[newSym("C/Size")], newSym("C/Short")))
      scope.define("size-i8",
                   newFfiCallable("ffiTestSizeI8", "ffiTestSizeI8",
                                  cast[pointer](ffiTestSizeI8), lib,
                                  @[newSym("C/Size")], newSym("C/Int8")))
      scope.define("size-char",
                   newFfiCallable("ffiTestSizeChar",
                                  "ffiTestSizeChar",
                                  cast[pointer](ffiTestSizeChar), lib,
                                  @[newSym("C/Size")], newSym("C/Char")))
      scope.define("size-u32",
                   newFfiCallable("ffiTestSizeU32", "ffiTestSizeU32",
                                  cast[pointer](ffiTestSizeU32), lib,
                                  @[newSym("C/Size")], newSym("C/UInt32")))
      scope.define("size-u16",
                   newFfiCallable("ffiTestSizeU16", "ffiTestSizeU16",
                                  cast[pointer](ffiTestSizeU16), lib,
                                  @[newSym("C/Size")], newSym("C/UInt16")))
      scope.define("size-ushort",
                   newFfiCallable("ffiTestSizeUShort",
                                  "ffiTestSizeUShort",
                                  cast[pointer](ffiTestSizeUShort), lib,
                                  @[newSym("C/Size")], newSym("C/UShort")))
      scope.define("size-u8",
                   newFfiCallable("ffiTestSizeU8", "ffiTestSizeU8",
                                  cast[pointer](ffiTestSizeU8), lib,
                                  @[newSym("C/Size")], newSym("C/UInt8")))
      scope.define("size-uchar",
                   newFfiCallable("ffiTestSizeUChar",
                                  "ffiTestSizeUChar",
                                  cast[pointer](ffiTestSizeUChar), lib,
                                  @[newSym("C/Size")], newSym("C/UChar")))
      scope.define("size-ulong",
                   newFfiCallable("ffiTestSizeULong",
                                  "ffiTestSizeULong",
                                  cast[pointer](ffiTestSizeULong), lib,
                                  @[newSym("C/Size")], newSym("C/ULong")))
      scope.define("size-i64",
                   newFfiCallable("ffiTestSizeI64",
                                  "ffiTestSizeI64",
                                  cast[pointer](ffiTestSizeI64), lib,
                                  @[newSym("C/Size")], newSym("C/Int64")))
      scope.define("size-u64",
                   newFfiCallable("ffiTestSizeU64",
                                  "ffiTestSizeU64",
                                  cast[pointer](ffiTestSizeU64), lib,
                                  @[newSym("C/Size")], newSym("C/UInt64")))
      scope.define("size-unary-diff",
                   newFfiCallable("ffiTestSizeUnaryDiff",
                                  "ffiTestSizeUnaryDiff",
                                  cast[pointer](ffiTestSizeUnaryDiff), lib,
                                  @[newSym("C/Size")], newSym("C/PtrDiff")))
      scope.define("size-non-zero?",
                   newFfiCallable("ffiTestSizeNonZero",
                                  "ffiTestSizeNonZero",
                                  cast[pointer](ffiTestSizeNonZero), lib,
                                  @[newSym("C/Size")], newSym("C/Bool")))
      scope.define("int-ulong",
                   newFfiCallable("ffiTestIntULong",
                                  "ffiTestIntULong",
                                  cast[pointer](ffiTestIntULong), lib,
                                  @[newSym("C/Int")], newSym("C/ULong")))
      scope.define("int-i32",
                   newFfiCallable("ffiTestIntI32",
                                  "ffiTestIntI32",
                                  cast[pointer](ffiTestIntI32), lib,
                                  @[newSym("C/Int")], newSym("C/Int32")))
      scope.define("int-i16",
                   newFfiCallable("ffiTestIntI16",
                                  "ffiTestIntI16",
                                  cast[pointer](ffiTestIntI16), lib,
                                  @[newSym("C/Int")], newSym("C/Int16")))
      scope.define("int-short",
                   newFfiCallable("ffiTestIntShort",
                                  "ffiTestIntShort",
                                  cast[pointer](ffiTestIntShort), lib,
                                  @[newSym("C/Int")], newSym("C/Short")))
      scope.define("int-i8",
                   newFfiCallable("ffiTestIntI8",
                                  "ffiTestIntI8",
                                  cast[pointer](ffiTestIntI8), lib,
                                  @[newSym("C/Int")], newSym("C/Int8")))
      scope.define("int-char",
                   newFfiCallable("ffiTestIntChar",
                                  "ffiTestIntChar",
                                  cast[pointer](ffiTestIntChar), lib,
                                  @[newSym("C/Int")], newSym("C/Char")))
      scope.define("int-u32",
                   newFfiCallable("ffiTestIntU32",
                                  "ffiTestIntU32",
                                  cast[pointer](ffiTestIntU32), lib,
                                  @[newSym("C/Int")], newSym("C/UInt32")))
      scope.define("int-u16",
                   newFfiCallable("ffiTestIntU16",
                                  "ffiTestIntU16",
                                  cast[pointer](ffiTestIntU16), lib,
                                  @[newSym("C/Int")], newSym("C/UInt16")))
      scope.define("int-ushort",
                   newFfiCallable("ffiTestIntUShort",
                                  "ffiTestIntUShort",
                                  cast[pointer](ffiTestIntUShort), lib,
                                  @[newSym("C/Int")], newSym("C/UShort")))
      scope.define("int-u8",
                   newFfiCallable("ffiTestIntU8",
                                  "ffiTestIntU8",
                                  cast[pointer](ffiTestIntU8), lib,
                                  @[newSym("C/Int")], newSym("C/UInt8")))
      scope.define("int-uchar",
                   newFfiCallable("ffiTestIntUChar",
                                  "ffiTestIntUChar",
                                  cast[pointer](ffiTestIntUChar), lib,
                                  @[newSym("C/Int")], newSym("C/UChar")))
      scope.define("int-i64",
                   newFfiCallable("ffiTestIntI64",
                                  "ffiTestIntI64",
                                  cast[pointer](ffiTestIntI64), lib,
                                  @[newSym("C/Int")], newSym("C/Int64")))
      scope.define("int-u64",
                   newFfiCallable("ffiTestIntU64",
                                  "ffiTestIntU64",
                                  cast[pointer](ffiTestIntU64), lib,
                                  @[newSym("C/Int")], newSym("C/UInt64")))
      scope.define("int-unary-diff",
                   newFfiCallable("ffiTestIntUnaryDiff",
                                  "ffiTestIntUnaryDiff",
                                  cast[pointer](ffiTestIntUnaryDiff), lib,
                                  @[newSym("C/Int")], newSym("C/PtrDiff")))
      scope.define("int-positive?",
                   newFfiCallable("ffiTestIntPositive",
                                  "ffiTestIntPositive",
                                  cast[pointer](ffiTestIntPositive), lib,
                                  @[newSym("C/Int")], newSym("C/Bool")))
      scope.define("int-ptr",
                   newFfiCallable("ffiTestIntPtr",
                                  "ffiTestIntPtr",
                                  cast[pointer](ffiTestIntPtr), lib,
                                  @[newSym("C/Int")],
                                  newNode(newSym("C/NullablePtr"),
                                          body = @[newSym("C/Char")])))
      scope.define("long-ulong",
                   newFfiCallable("ffiTestLongULong",
                                  "ffiTestLongULong",
                                  cast[pointer](ffiTestLongULong), lib,
                                  @[newSym("C/Long")], newSym("C/ULong")))
      scope.define("long-i32",
                   newFfiCallable("ffiTestLongI32",
                                  "ffiTestLongI32",
                                  cast[pointer](ffiTestLongI32), lib,
                                  @[newSym("C/Long")], newSym("C/Int32")))
      scope.define("long-i16",
                   newFfiCallable("ffiTestLongI16",
                                  "ffiTestLongI16",
                                  cast[pointer](ffiTestLongI16), lib,
                                  @[newSym("C/Long")], newSym("C/Int16")))
      scope.define("long-short",
                   newFfiCallable("ffiTestLongShort",
                                  "ffiTestLongShort",
                                  cast[pointer](ffiTestLongShort), lib,
                                  @[newSym("C/Long")], newSym("C/Short")))
      scope.define("long-i8",
                   newFfiCallable("ffiTestLongI8",
                                  "ffiTestLongI8",
                                  cast[pointer](ffiTestLongI8), lib,
                                  @[newSym("C/Long")], newSym("C/Int8")))
      scope.define("long-char",
                   newFfiCallable("ffiTestLongChar",
                                  "ffiTestLongChar",
                                  cast[pointer](ffiTestLongChar), lib,
                                  @[newSym("C/Long")], newSym("C/Char")))
      scope.define("long-u32",
                   newFfiCallable("ffiTestLongU32",
                                  "ffiTestLongU32",
                                  cast[pointer](ffiTestLongU32), lib,
                                  @[newSym("C/Long")], newSym("C/UInt32")))
      scope.define("long-u16",
                   newFfiCallable("ffiTestLongU16",
                                  "ffiTestLongU16",
                                  cast[pointer](ffiTestLongU16), lib,
                                  @[newSym("C/Long")], newSym("C/UInt16")))
      scope.define("long-ushort",
                   newFfiCallable("ffiTestLongUShort",
                                  "ffiTestLongUShort",
                                  cast[pointer](ffiTestLongUShort), lib,
                                  @[newSym("C/Long")], newSym("C/UShort")))
      scope.define("long-u8",
                   newFfiCallable("ffiTestLongU8",
                                  "ffiTestLongU8",
                                  cast[pointer](ffiTestLongU8), lib,
                                  @[newSym("C/Long")], newSym("C/UInt8")))
      scope.define("long-uchar",
                   newFfiCallable("ffiTestLongUChar",
                                  "ffiTestLongUChar",
                                  cast[pointer](ffiTestLongUChar), lib,
                                  @[newSym("C/Long")], newSym("C/UChar")))
      scope.define("long-i64",
                   newFfiCallable("ffiTestLongI64",
                                  "ffiTestLongI64",
                                  cast[pointer](ffiTestLongI64), lib,
                                  @[newSym("C/Long")], newSym("C/Int64")))
      scope.define("long-u64",
                   newFfiCallable("ffiTestLongU64",
                                  "ffiTestLongU64",
                                  cast[pointer](ffiTestLongU64), lib,
                                  @[newSym("C/Long")], newSym("C/UInt64")))
      scope.define("long-diff",
                   newFfiCallable("ffiTestLongDiff",
                                  "ffiTestLongDiff",
                                  cast[pointer](ffiTestLongDiff), lib,
                                  @[newSym("C/Long")], newSym("C/PtrDiff")))
      scope.define("long-positive?",
                   newFfiCallable("ffiTestLongPositive",
                                  "ffiTestLongPositive",
                                  cast[pointer](ffiTestLongPositive), lib,
                                  @[newSym("C/Long")], newSym("C/Bool")))
      scope.define("i64-ulong",
                   newFfiCallable("ffiTestI64ULong",
                                  "ffiTestI64ULong",
                                  cast[pointer](ffiTestI64ULong), lib,
                                  @[newSym("C/Int64")], newSym("C/ULong")))
      scope.define("i64-i32",
                   newFfiCallable("ffiTestI64I32",
                                  "ffiTestI64I32",
                                  cast[pointer](ffiTestI64I32), lib,
                                  @[newSym("C/Int64")], newSym("C/Int32")))
      scope.define("i64-i16",
                   newFfiCallable("ffiTestI64I16",
                                  "ffiTestI64I16",
                                  cast[pointer](ffiTestI64I16), lib,
                                  @[newSym("C/Int64")], newSym("C/Int16")))
      scope.define("i64-short",
                   newFfiCallable("ffiTestI64Short",
                                  "ffiTestI64Short",
                                  cast[pointer](ffiTestI64Short), lib,
                                  @[newSym("C/Int64")], newSym("C/Short")))
      scope.define("i64-i8",
                   newFfiCallable("ffiTestI64I8",
                                  "ffiTestI64I8",
                                  cast[pointer](ffiTestI64I8), lib,
                                  @[newSym("C/Int64")], newSym("C/Int8")))
      scope.define("i64-char",
                   newFfiCallable("ffiTestI64Char",
                                  "ffiTestI64Char",
                                  cast[pointer](ffiTestI64Char), lib,
                                  @[newSym("C/Int64")], newSym("C/Char")))
      scope.define("i64-u32",
                   newFfiCallable("ffiTestI64U32",
                                  "ffiTestI64U32",
                                  cast[pointer](ffiTestI64U32), lib,
                                  @[newSym("C/Int64")], newSym("C/UInt32")))
      scope.define("i64-u16",
                   newFfiCallable("ffiTestI64U16",
                                  "ffiTestI64U16",
                                  cast[pointer](ffiTestI64U16), lib,
                                  @[newSym("C/Int64")], newSym("C/UInt16")))
      scope.define("i64-ushort",
                   newFfiCallable("ffiTestI64UShort",
                                  "ffiTestI64UShort",
                                  cast[pointer](ffiTestI64UShort), lib,
                                  @[newSym("C/Int64")], newSym("C/UShort")))
      scope.define("i64-u8",
                   newFfiCallable("ffiTestI64U8",
                                  "ffiTestI64U8",
                                  cast[pointer](ffiTestI64U8), lib,
                                  @[newSym("C/Int64")], newSym("C/UInt8")))
      scope.define("i64-uchar",
                   newFfiCallable("ffiTestI64UChar",
                                  "ffiTestI64UChar",
                                  cast[pointer](ffiTestI64UChar), lib,
                                  @[newSym("C/Int64")], newSym("C/UChar")))
      scope.define("i64-u64",
                   newFfiCallable("ffiTestI64U64",
                                  "ffiTestI64U64",
                                  cast[pointer](ffiTestI64U64), lib,
                                  @[newSym("C/Int64")], newSym("C/UInt64")))
      scope.define("i64-diff",
                   newFfiCallable("ffiTestI64Diff",
                                  "ffiTestI64Diff",
                                  cast[pointer](ffiTestI64Diff), lib,
                                  @[newSym("C/Int64")], newSym("C/PtrDiff")))
      scope.define("i64-positive?",
                   newFfiCallable("ffiTestI64Positive",
                                  "ffiTestI64Positive",
                                  cast[pointer](ffiTestI64Positive), lib,
                                  @[newSym("C/Int64")], newSym("C/Bool")))
      scope.define("uint-ulong",
                   newFfiCallable("ffiTestUIntULong",
                                  "ffiTestUIntULong",
                                  cast[pointer](ffiTestUIntULong), lib,
                                  @[newSym("C/UInt")], newSym("C/ULong")))
      scope.define("uint-i32",
                   newFfiCallable("ffiTestUIntI32",
                                  "ffiTestUIntI32",
                                  cast[pointer](ffiTestUIntI32), lib,
                                  @[newSym("C/UInt")], newSym("C/Int32")))
      scope.define("uint-i16",
                   newFfiCallable("ffiTestUIntI16",
                                  "ffiTestUIntI16",
                                  cast[pointer](ffiTestUIntI16), lib,
                                  @[newSym("C/UInt")], newSym("C/Int16")))
      scope.define("uint-short",
                   newFfiCallable("ffiTestUIntShort",
                                  "ffiTestUIntShort",
                                  cast[pointer](ffiTestUIntShort), lib,
                                  @[newSym("C/UInt")], newSym("C/Short")))
      scope.define("uint-i8",
                   newFfiCallable("ffiTestUIntI8",
                                  "ffiTestUIntI8",
                                  cast[pointer](ffiTestUIntI8), lib,
                                  @[newSym("C/UInt")], newSym("C/Int8")))
      scope.define("uint-char",
                   newFfiCallable("ffiTestUIntChar",
                                  "ffiTestUIntChar",
                                  cast[pointer](ffiTestUIntChar), lib,
                                  @[newSym("C/UInt")], newSym("C/Char")))
      scope.define("uint-u32",
                   newFfiCallable("ffiTestUIntU32",
                                  "ffiTestUIntU32",
                                  cast[pointer](ffiTestUIntU32), lib,
                                  @[newSym("C/UInt")], newSym("C/UInt32")))
      scope.define("uint-u16",
                   newFfiCallable("ffiTestUIntU16",
                                  "ffiTestUIntU16",
                                  cast[pointer](ffiTestUIntU16), lib,
                                  @[newSym("C/UInt")], newSym("C/UInt16")))
      scope.define("uint-ushort",
                   newFfiCallable("ffiTestUIntUShort",
                                  "ffiTestUIntUShort",
                                  cast[pointer](ffiTestUIntUShort), lib,
                                  @[newSym("C/UInt")], newSym("C/UShort")))
      scope.define("uint-u8",
                   newFfiCallable("ffiTestUIntU8",
                                  "ffiTestUIntU8",
                                  cast[pointer](ffiTestUIntU8), lib,
                                  @[newSym("C/UInt")], newSym("C/UInt8")))
      scope.define("uint-uchar",
                   newFfiCallable("ffiTestUIntUChar",
                                  "ffiTestUIntUChar",
                                  cast[pointer](ffiTestUIntUChar), lib,
                                  @[newSym("C/UInt")], newSym("C/UChar")))
      scope.define("uint-i64",
                   newFfiCallable("ffiTestUIntI64",
                                  "ffiTestUIntI64",
                                  cast[pointer](ffiTestUIntI64), lib,
                                  @[newSym("C/UInt")], newSym("C/Int64")))
      scope.define("uint-u64",
                   newFfiCallable("ffiTestUIntU64",
                                  "ffiTestUIntU64",
                                  cast[pointer](ffiTestUIntU64), lib,
                                  @[newSym("C/UInt")], newSym("C/UInt64")))
      scope.define("uint-diff",
                   newFfiCallable("ffiTestUIntDiff",
                                  "ffiTestUIntDiff",
                                  cast[pointer](ffiTestUIntDiff), lib,
                                  @[newSym("C/UInt")], newSym("C/PtrDiff")))
      scope.define("uint-non-zero?",
                   newFfiCallable("ffiTestUIntNonZero",
                                  "ffiTestUIntNonZero",
                                  cast[pointer](ffiTestUIntNonZero), lib,
                                  @[newSym("C/UInt")], newSym("C/Bool")))
      scope.define("u32-ulong",
                   newFfiCallable("ffiTestU32ULong",
                                  "ffiTestU32ULong",
                                  cast[pointer](ffiTestU32ULong), lib,
                                  @[newSym("C/UInt32")], newSym("C/ULong")))
      scope.define("u32-i16",
                   newFfiCallable("ffiTestU32I16",
                                  "ffiTestU32I16",
                                  cast[pointer](ffiTestU32I16), lib,
                                  @[newSym("C/UInt32")], newSym("C/Int16")))
      scope.define("u32-short",
                   newFfiCallable("ffiTestU32Short",
                                  "ffiTestU32Short",
                                  cast[pointer](ffiTestU32Short), lib,
                                  @[newSym("C/UInt32")], newSym("C/Short")))
      scope.define("u32-i8",
                   newFfiCallable("ffiTestU32I8",
                                  "ffiTestU32I8",
                                  cast[pointer](ffiTestU32I8), lib,
                                  @[newSym("C/UInt32")], newSym("C/Int8")))
      scope.define("u32-char",
                   newFfiCallable("ffiTestU32Char",
                                  "ffiTestU32Char",
                                  cast[pointer](ffiTestU32Char), lib,
                                  @[newSym("C/UInt32")], newSym("C/Char")))
      scope.define("u32-u16",
                   newFfiCallable("ffiTestU32U16",
                                  "ffiTestU32U16",
                                  cast[pointer](ffiTestU32U16), lib,
                                  @[newSym("C/UInt32")], newSym("C/UInt16")))
      scope.define("u32-ushort",
                   newFfiCallable("ffiTestU32UShort",
                                  "ffiTestU32UShort",
                                  cast[pointer](ffiTestU32UShort), lib,
                                  @[newSym("C/UInt32")], newSym("C/UShort")))
      scope.define("u32-u8",
                   newFfiCallable("ffiTestU32U8",
                                  "ffiTestU32U8",
                                  cast[pointer](ffiTestU32U8), lib,
                                  @[newSym("C/UInt32")], newSym("C/UInt8")))
      scope.define("u32-uchar",
                   newFfiCallable("ffiTestU32UChar",
                                  "ffiTestU32UChar",
                                  cast[pointer](ffiTestU32UChar), lib,
                                  @[newSym("C/UInt32")], newSym("C/UChar")))
      scope.define("u32-u64",
                   newFfiCallable("ffiTestU32U64",
                                  "ffiTestU32U64",
                                  cast[pointer](ffiTestU32U64), lib,
                                  @[newSym("C/UInt32")], newSym("C/UInt64")))
      scope.define("u32-diff",
                   newFfiCallable("ffiTestU32Diff",
                                  "ffiTestU32Diff",
                                  cast[pointer](ffiTestU32Diff), lib,
                                  @[newSym("C/UInt32")], newSym("C/PtrDiff")))
      scope.define("u32-non-zero?",
                   newFfiCallable("ffiTestU32NonZero",
                                  "ffiTestU32NonZero",
                                  cast[pointer](ffiTestU32NonZero), lib,
                                  @[newSym("C/UInt32")], newSym("C/Bool")))
      scope.define("i32-ulong",
                   newFfiCallable("ffiTestI32ULong",
                                  "ffiTestI32ULong",
                                  cast[pointer](ffiTestI32ULong), lib,
                                  @[newSym("C/Int32")], newSym("C/ULong")))
      scope.define("i32-i16",
                   newFfiCallable("ffiTestI32I16",
                                  "ffiTestI32I16",
                                  cast[pointer](ffiTestI32I16), lib,
                                  @[newSym("C/Int32")], newSym("C/Int16")))
      scope.define("i32-short",
                   newFfiCallable("ffiTestI32Short",
                                  "ffiTestI32Short",
                                  cast[pointer](ffiTestI32Short), lib,
                                  @[newSym("C/Int32")], newSym("C/Short")))
      scope.define("i32-i8",
                   newFfiCallable("ffiTestI32I8",
                                  "ffiTestI32I8",
                                  cast[pointer](ffiTestI32I8), lib,
                                  @[newSym("C/Int32")], newSym("C/Int8")))
      scope.define("i32-char",
                   newFfiCallable("ffiTestI32Char",
                                  "ffiTestI32Char",
                                  cast[pointer](ffiTestI32Char), lib,
                                  @[newSym("C/Int32")], newSym("C/Char")))
      scope.define("i32-u32",
                   newFfiCallable("ffiTestI32U32",
                                  "ffiTestI32U32",
                                  cast[pointer](ffiTestI32U32), lib,
                                  @[newSym("C/Int32")], newSym("C/UInt32")))
      scope.define("i32-u16",
                   newFfiCallable("ffiTestI32U16",
                                  "ffiTestI32U16",
                                  cast[pointer](ffiTestI32U16), lib,
                                  @[newSym("C/Int32")], newSym("C/UInt16")))
      scope.define("i32-ushort",
                   newFfiCallable("ffiTestI32UShort",
                                  "ffiTestI32UShort",
                                  cast[pointer](ffiTestI32UShort), lib,
                                  @[newSym("C/Int32")], newSym("C/UShort")))
      scope.define("i32-u8",
                   newFfiCallable("ffiTestI32U8",
                                  "ffiTestI32U8",
                                  cast[pointer](ffiTestI32U8), lib,
                                  @[newSym("C/Int32")], newSym("C/UInt8")))
      scope.define("i32-uchar",
                   newFfiCallable("ffiTestI32UChar",
                                  "ffiTestI32UChar",
                                  cast[pointer](ffiTestI32UChar), lib,
                                  @[newSym("C/Int32")], newSym("C/UChar")))
      scope.define("i32-u64",
                   newFfiCallable("ffiTestI32U64",
                                  "ffiTestI32U64",
                                  cast[pointer](ffiTestI32U64), lib,
                                  @[newSym("C/Int32")], newSym("C/UInt64")))
      scope.define("i32-diff",
                   newFfiCallable("ffiTestI32Diff",
                                  "ffiTestI32Diff",
                                  cast[pointer](ffiTestI32Diff), lib,
                                  @[newSym("C/Int32")], newSym("C/PtrDiff")))
      scope.define("i32-positive?",
                   newFfiCallable("ffiTestI32Positive",
                                  "ffiTestI32Positive",
                                  cast[pointer](ffiTestI32Positive), lib,
                                  @[newSym("C/Int32")], newSym("C/Bool")))
      scope.define("i16-ulong",
                   newFfiCallable("ffiTestI16ULong",
                                  "ffiTestI16ULong",
                                  cast[pointer](ffiTestI16ULong), lib,
                                  @[newSym("C/Int16")], newSym("C/ULong")))
      scope.define("i16-short",
                   newFfiCallable("ffiTestI16Short",
                                  "ffiTestI16Short",
                                  cast[pointer](ffiTestI16Short), lib,
                                  @[newSym("C/Int16")], newSym("C/Short")))
      scope.define("i16-i8",
                   newFfiCallable("ffiTestI16I8",
                                  "ffiTestI16I8",
                                  cast[pointer](ffiTestI16I8), lib,
                                  @[newSym("C/Int16")], newSym("C/Int8")))
      scope.define("i16-char",
                   newFfiCallable("ffiTestI16Char",
                                  "ffiTestI16Char",
                                  cast[pointer](ffiTestI16Char), lib,
                                  @[newSym("C/Int16")], newSym("C/Char")))
      scope.define("i16-u16",
                   newFfiCallable("ffiTestI16U16",
                                  "ffiTestI16U16",
                                  cast[pointer](ffiTestI16U16), lib,
                                  @[newSym("C/Int16")], newSym("C/UInt16")))
      scope.define("i16-ushort",
                   newFfiCallable("ffiTestI16UShort",
                                  "ffiTestI16UShort",
                                  cast[pointer](ffiTestI16UShort), lib,
                                  @[newSym("C/Int16")], newSym("C/UShort")))
      scope.define("i16-u8",
                   newFfiCallable("ffiTestI16U8",
                                  "ffiTestI16U8",
                                  cast[pointer](ffiTestI16U8), lib,
                                  @[newSym("C/Int16")], newSym("C/UInt8")))
      scope.define("i16-uchar",
                   newFfiCallable("ffiTestI16UChar",
                                  "ffiTestI16UChar",
                                  cast[pointer](ffiTestI16UChar), lib,
                                  @[newSym("C/Int16")], newSym("C/UChar")))
      scope.define("i16-u64",
                   newFfiCallable("ffiTestI16U64",
                                  "ffiTestI16U64",
                                  cast[pointer](ffiTestI16U64), lib,
                                  @[newSym("C/Int16")], newSym("C/UInt64")))
      scope.define("i16-diff",
                   newFfiCallable("ffiTestI16Diff",
                                  "ffiTestI16Diff",
                                  cast[pointer](ffiTestI16Diff), lib,
                                  @[newSym("C/Int16")], newSym("C/PtrDiff")))
      scope.define("i16-positive?",
                   newFfiCallable("ffiTestI16Positive",
                                  "ffiTestI16Positive",
                                  cast[pointer](ffiTestI16Positive), lib,
                                  @[newSym("C/Int16")], newSym("C/Bool")))
      scope.define("u16-ulong",
                   newFfiCallable("ffiTestU16ULong",
                                  "ffiTestU16ULong",
                                  cast[pointer](ffiTestU16ULong), lib,
                                  @[newSym("C/UInt16")], newSym("C/ULong")))
      scope.define("u16-short",
                   newFfiCallable("ffiTestU16Short",
                                  "ffiTestU16Short",
                                  cast[pointer](ffiTestU16Short), lib,
                                  @[newSym("C/UInt16")], newSym("C/Short")))
      scope.define("u16-i8",
                   newFfiCallable("ffiTestU16I8",
                                  "ffiTestU16I8",
                                  cast[pointer](ffiTestU16I8), lib,
                                  @[newSym("C/UInt16")], newSym("C/Int8")))
      scope.define("u16-char",
                   newFfiCallable("ffiTestU16Char",
                                  "ffiTestU16Char",
                                  cast[pointer](ffiTestU16Char), lib,
                                  @[newSym("C/UInt16")], newSym("C/Char")))
      scope.define("u16-ushort",
                   newFfiCallable("ffiTestU16UShort",
                                  "ffiTestU16UShort",
                                  cast[pointer](ffiTestU16UShort), lib,
                                  @[newSym("C/UInt16")], newSym("C/UShort")))
      scope.define("u16-u8",
                   newFfiCallable("ffiTestU16U8",
                                  "ffiTestU16U8",
                                  cast[pointer](ffiTestU16U8), lib,
                                  @[newSym("C/UInt16")], newSym("C/UInt8")))
      scope.define("u16-uchar",
                   newFfiCallable("ffiTestU16UChar",
                                  "ffiTestU16UChar",
                                  cast[pointer](ffiTestU16UChar), lib,
                                  @[newSym("C/UInt16")], newSym("C/UChar")))
      scope.define("u16-u64",
                   newFfiCallable("ffiTestU16U64",
                                  "ffiTestU16U64",
                                  cast[pointer](ffiTestU16U64), lib,
                                  @[newSym("C/UInt16")], newSym("C/UInt64")))
      scope.define("u16-diff",
                   newFfiCallable("ffiTestU16Diff",
                                  "ffiTestU16Diff",
                                  cast[pointer](ffiTestU16Diff), lib,
                                  @[newSym("C/UInt16")], newSym("C/PtrDiff")))
      scope.define("u16-non-zero?",
                   newFfiCallable("ffiTestU16NonZero",
                                  "ffiTestU16NonZero",
                                  cast[pointer](ffiTestU16NonZero), lib,
                                  @[newSym("C/UInt16")], newSym("C/Bool")))
      scope.define("double-ulong",
                   newFfiCallable("ffiTestDoubleULong",
                                  "ffiTestDoubleULong",
                                  cast[pointer](ffiTestDoubleULong), lib,
                                  @[newSym("C/Double")], newSym("C/ULong")))
      scope.define("double-i32",
                   newFfiCallable("ffiTestDoubleI32",
                                  "ffiTestDoubleI32",
                                  cast[pointer](ffiTestDoubleI32), lib,
                                  @[newSym("C/Double")], newSym("C/Int32")))
      scope.define("double-i16",
                   newFfiCallable("ffiTestDoubleI16",
                                  "ffiTestDoubleI16",
                                  cast[pointer](ffiTestDoubleI16), lib,
                                  @[newSym("C/Double")], newSym("C/Int16")))
      scope.define("double-short",
                   newFfiCallable("ffiTestDoubleShort",
                                  "ffiTestDoubleShort",
                                  cast[pointer](ffiTestDoubleShort), lib,
                                  @[newSym("C/Double")], newSym("C/Short")))
      scope.define("double-i8",
                   newFfiCallable("ffiTestDoubleI8",
                                  "ffiTestDoubleI8",
                                  cast[pointer](ffiTestDoubleI8), lib,
                                  @[newSym("C/Double")], newSym("C/Int8")))
      scope.define("double-char",
                   newFfiCallable("ffiTestDoubleChar",
                                  "ffiTestDoubleChar",
                                  cast[pointer](ffiTestDoubleChar), lib,
                                  @[newSym("C/Double")], newSym("C/Char")))
      scope.define("double-u32",
                   newFfiCallable("ffiTestDoubleU32",
                                  "ffiTestDoubleU32",
                                  cast[pointer](ffiTestDoubleU32), lib,
                                  @[newSym("C/Double")], newSym("C/UInt32")))
      scope.define("double-u16",
                   newFfiCallable("ffiTestDoubleU16",
                                  "ffiTestDoubleU16",
                                  cast[pointer](ffiTestDoubleU16), lib,
                                  @[newSym("C/Double")], newSym("C/UInt16")))
      scope.define("double-ushort",
                   newFfiCallable("ffiTestDoubleUShort",
                                  "ffiTestDoubleUShort",
                                  cast[pointer](ffiTestDoubleUShort), lib,
                                  @[newSym("C/Double")], newSym("C/UShort")))
      scope.define("double-u8",
                   newFfiCallable("ffiTestDoubleU8",
                                  "ffiTestDoubleU8",
                                  cast[pointer](ffiTestDoubleU8), lib,
                                  @[newSym("C/Double")], newSym("C/UInt8")))
      scope.define("double-uchar",
                   newFfiCallable("ffiTestDoubleUChar",
                                  "ffiTestDoubleUChar",
                                  cast[pointer](ffiTestDoubleUChar), lib,
                                  @[newSym("C/Double")], newSym("C/UChar")))
      scope.define("double-i64",
                   newFfiCallable("ffiTestDoubleI64",
                                  "ffiTestDoubleI64",
                                  cast[pointer](ffiTestDoubleI64), lib,
                                  @[newSym("C/Double")], newSym("C/Int64")))
      scope.define("double-u64",
                   newFfiCallable("ffiTestDoubleU64",
                                  "ffiTestDoubleU64",
                                  cast[pointer](ffiTestDoubleU64), lib,
                                  @[newSym("C/Double")], newSym("C/UInt64")))
      scope.define("double-diff",
                   newFfiCallable("ffiTestDoubleDiff",
                                  "ffiTestDoubleDiff",
                                  cast[pointer](ffiTestDoubleDiff), lib,
                                  @[newSym("C/Double")], newSym("C/PtrDiff")))
      scope.define("double-positive?",
                   newFfiCallable("ffiTestDoublePositive",
                                  "ffiTestDoublePositive",
                                  cast[pointer](ffiTestDoublePositive), lib,
                                  @[newSym("C/Double")], newSym("C/Bool")))
      scope.define("double-kind",
                   newFfiCallable("ffiTestDoubleKind",
                                  "ffiTestDoubleKind",
                                  cast[pointer](ffiTestDoubleKind), lib,
                                  @[newSym("C/Double")], newSym("C/CStr")))
      scope.define("double-ptr",
                   newFfiCallable("ffiTestDoublePtr",
                                  "ffiTestDoublePtr",
                                  cast[pointer](ffiTestDoublePtr), lib,
                                  @[newSym("C/Double")],
                                  newNode(newSym("C/NullablePtr"),
                                          body = @[newSym("C/Char")])))
      scope.define("float-ulong",
                   newFfiCallable("ffiTestFloatULong",
                                  "ffiTestFloatULong",
                                  cast[pointer](ffiTestFloatULong), lib,
                                  @[newSym("C/Float")], newSym("C/ULong")))
      scope.define("float-i32",
                   newFfiCallable("ffiTestFloatI32",
                                  "ffiTestFloatI32",
                                  cast[pointer](ffiTestFloatI32), lib,
                                  @[newSym("C/Float")], newSym("C/Int32")))
      scope.define("float-i16",
                   newFfiCallable("ffiTestFloatI16",
                                  "ffiTestFloatI16",
                                  cast[pointer](ffiTestFloatI16), lib,
                                  @[newSym("C/Float")], newSym("C/Int16")))
      scope.define("float-short",
                   newFfiCallable("ffiTestFloatShort",
                                  "ffiTestFloatShort",
                                  cast[pointer](ffiTestFloatShort), lib,
                                  @[newSym("C/Float")], newSym("C/Short")))
      scope.define("float-i8",
                   newFfiCallable("ffiTestFloatI8",
                                  "ffiTestFloatI8",
                                  cast[pointer](ffiTestFloatI8), lib,
                                  @[newSym("C/Float")], newSym("C/Int8")))
      scope.define("float-char",
                   newFfiCallable("ffiTestFloatChar",
                                  "ffiTestFloatChar",
                                  cast[pointer](ffiTestFloatChar), lib,
                                  @[newSym("C/Float")], newSym("C/Char")))
      scope.define("float-u32",
                   newFfiCallable("ffiTestFloatU32",
                                  "ffiTestFloatU32",
                                  cast[pointer](ffiTestFloatU32), lib,
                                  @[newSym("C/Float")], newSym("C/UInt32")))
      scope.define("float-u16",
                   newFfiCallable("ffiTestFloatU16",
                                  "ffiTestFloatU16",
                                  cast[pointer](ffiTestFloatU16), lib,
                                  @[newSym("C/Float")], newSym("C/UInt16")))
      scope.define("float-ushort",
                   newFfiCallable("ffiTestFloatUShort",
                                  "ffiTestFloatUShort",
                                  cast[pointer](ffiTestFloatUShort), lib,
                                  @[newSym("C/Float")], newSym("C/UShort")))
      scope.define("float-u8",
                   newFfiCallable("ffiTestFloatU8",
                                  "ffiTestFloatU8",
                                  cast[pointer](ffiTestFloatU8), lib,
                                  @[newSym("C/Float")], newSym("C/UInt8")))
      scope.define("float-uchar",
                   newFfiCallable("ffiTestFloatUChar",
                                  "ffiTestFloatUChar",
                                  cast[pointer](ffiTestFloatUChar), lib,
                                  @[newSym("C/Float")], newSym("C/UChar")))
      scope.define("float-i64",
                   newFfiCallable("ffiTestFloatI64",
                                  "ffiTestFloatI64",
                                  cast[pointer](ffiTestFloatI64), lib,
                                  @[newSym("C/Float")], newSym("C/Int64")))
      scope.define("float-u64",
                   newFfiCallable("ffiTestFloatU64",
                                  "ffiTestFloatU64",
                                  cast[pointer](ffiTestFloatU64), lib,
                                  @[newSym("C/Float")], newSym("C/UInt64")))
      scope.define("float-diff",
                   newFfiCallable("ffiTestFloatDiff",
                                  "ffiTestFloatDiff",
                                  cast[pointer](ffiTestFloatDiff), lib,
                                  @[newSym("C/Float")], newSym("C/PtrDiff")))
      scope.define("float-positive?",
                   newFfiCallable("ffiTestFloatPositive",
                                  "ffiTestFloatPositive",
                                  cast[pointer](ffiTestFloatPositive), lib,
                                  @[newSym("C/Float")], newSym("C/Bool")))
      scope.define("float-kind",
                   newFfiCallable("ffiTestFloatKind",
                                  "ffiTestFloatKind",
                                  cast[pointer](ffiTestFloatKind), lib,
                                  @[newSym("C/Float")], newSym("C/CStr")))
      scope.define("float-ptr",
                   newFfiCallable("ffiTestFloatPtr",
                                  "ffiTestFloatPtr",
                                  cast[pointer](ffiTestFloatPtr), lib,
                                  @[newSym("C/Float")],
                                  newNode(newSym("C/NullablePtr"),
                                          body = @[newSym("C/Char")])))
      scope.define("size-add-uint",
                   newFfiCallable("ffiTestSizeAddUInt",
                                  "ffiTestSizeAddUInt",
                                  cast[pointer](ffiTestSizeAddUInt), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/UInt")))
      scope.define("size-add-i32",
                   newFfiCallable("ffiTestSizeAddI32",
                                  "ffiTestSizeAddI32",
                                  cast[pointer](ffiTestSizeAddI32), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Int32")))
      scope.define("size-add-i16",
                   newFfiCallable("ffiTestSizeAddI16",
                                  "ffiTestSizeAddI16",
                                  cast[pointer](ffiTestSizeAddI16), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Int16")))
      scope.define("size-add-short",
                   newFfiCallable("ffiTestSizeAddShort",
                                  "ffiTestSizeAddShort",
                                  cast[pointer](ffiTestSizeAddShort), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Short")))
      scope.define("size-add-i8",
                   newFfiCallable("ffiTestSizeAddI8",
                                  "ffiTestSizeAddI8",
                                  cast[pointer](ffiTestSizeAddI8), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Int8")))
      scope.define("size-add-char",
                   newFfiCallable("ffiTestSizeAddChar",
                                  "ffiTestSizeAddChar",
                                  cast[pointer](ffiTestSizeAddChar), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Char")))
      scope.define("size-diff-long",
                   newFfiCallable("ffiTestSizeDiffLong",
                                  "ffiTestSizeDiffLong",
                                  cast[pointer](ffiTestSizeDiffLong), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Long")))
      scope.define("size-add-ulong",
                   newFfiCallable("ffiTestSizeAddULong",
                                  "ffiTestSizeAddULong",
                                  cast[pointer](ffiTestSizeAddULong), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/ULong")))
      scope.define("size-add-u32",
                   newFfiCallable("ffiTestSizeAddU32",
                                  "ffiTestSizeAddU32",
                                  cast[pointer](ffiTestSizeAddU32), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/UInt32")))
      scope.define("size-add-u16",
                   newFfiCallable("ffiTestSizeAddU16",
                                  "ffiTestSizeAddU16",
                                  cast[pointer](ffiTestSizeAddU16), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/UInt16")))
      scope.define("size-add-ushort",
                   newFfiCallable("ffiTestSizeAddUShort",
                                  "ffiTestSizeAddUShort",
                                  cast[pointer](ffiTestSizeAddUShort), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/UShort")))
      scope.define("size-add-u8",
                   newFfiCallable("ffiTestSizeAddU8",
                                  "ffiTestSizeAddU8",
                                  cast[pointer](ffiTestSizeAddU8), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/UInt8")))
      scope.define("size-add-uchar",
                   newFfiCallable("ffiTestSizeAddUChar",
                                  "ffiTestSizeAddUChar",
                                  cast[pointer](ffiTestSizeAddUChar), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/UChar")))
      scope.define("size-add-i64",
                   newFfiCallable("ffiTestSizeAddI64",
                                  "ffiTestSizeAddI64",
                                  cast[pointer](ffiTestSizeAddI64), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Int64")))
      scope.define("size-add-u64",
                   newFfiCallable("ffiTestSizeAddU64",
                                  "ffiTestSizeAddU64",
                                  cast[pointer](ffiTestSizeAddU64), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/UInt64")))
      scope.define("size-diff-ptrdiff",
                   newFfiCallable("ffiTestSizeDiffPtrDiff",
                                  "ffiTestSizeDiffPtrDiff",
                                  cast[pointer](ffiTestSizeDiffPtrDiff), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/PtrDiff")))
      scope.define("size-add-float",
                   newFfiCallable("ffiTestSizeAddFloat",
                                  "ffiTestSizeAddFloat",
                                  cast[pointer](ffiTestSizeAddFloat), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Float")))
      scope.define("size-add-double",
                   newFfiCallable("ffiTestSizeAddDouble",
                                  "ffiTestSizeAddDouble",
                                  cast[pointer](ffiTestSizeAddDouble), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Double")))
      scope.define("size-equal?",
                   newFfiCallable("ffiTestSizeEqual",
                                  "ffiTestSizeEqual",
                                  cast[pointer](ffiTestSizeEqual), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/Bool")))
      scope.define("int_add",
                   newFfiCallable("ffiTestIntAdd", "ffiTestIntAdd",
                                  cast[pointer](ffiTestIntAdd), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Int")))
      scope.define("int-add-uint",
                   newFfiCallable("ffiTestIntAddUInt",
                                  "ffiTestIntAddUInt",
                                  cast[pointer](ffiTestIntAddUInt), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/UInt")))
      scope.define("int-add-i32",
                   newFfiCallable("ffiTestIntAddI32",
                                  "ffiTestIntAddI32",
                                  cast[pointer](ffiTestIntAddI32), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Int32")))
      scope.define("int-add-i16",
                   newFfiCallable("ffiTestIntAddI16",
                                  "ffiTestIntAddI16",
                                  cast[pointer](ffiTestIntAddI16), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Int16")))
      scope.define("int-add-short",
                   newFfiCallable("ffiTestIntAddShort",
                                  "ffiTestIntAddShort",
                                  cast[pointer](ffiTestIntAddShort), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Short")))
      scope.define("int-add-i8",
                   newFfiCallable("ffiTestIntAddI8",
                                  "ffiTestIntAddI8",
                                  cast[pointer](ffiTestIntAddI8), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Int8")))
      scope.define("int-add-char",
                   newFfiCallable("ffiTestIntAddChar",
                                  "ffiTestIntAddChar",
                                  cast[pointer](ffiTestIntAddChar), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Char")))
      scope.define("int-diff-long",
                   newFfiCallable("ffiTestIntDiffLong",
                                  "ffiTestIntDiffLong",
                                  cast[pointer](ffiTestIntDiffLong), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Long")))
      scope.define("int-add-ulong",
                   newFfiCallable("ffiTestIntAddULong",
                                  "ffiTestIntAddULong",
                                  cast[pointer](ffiTestIntAddULong), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/ULong")))
      scope.define("int-add-u32",
                   newFfiCallable("ffiTestIntAddU32",
                                  "ffiTestIntAddU32",
                                  cast[pointer](ffiTestIntAddU32), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/UInt32")))
      scope.define("int-add-u16",
                   newFfiCallable("ffiTestIntAddU16",
                                  "ffiTestIntAddU16",
                                  cast[pointer](ffiTestIntAddU16), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/UInt16")))
      scope.define("int-add-ushort",
                   newFfiCallable("ffiTestIntAddUShort",
                                  "ffiTestIntAddUShort",
                                  cast[pointer](ffiTestIntAddUShort), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/UShort")))
      scope.define("int-add-u8",
                   newFfiCallable("ffiTestIntAddU8",
                                  "ffiTestIntAddU8",
                                  cast[pointer](ffiTestIntAddU8), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/UInt8")))
      scope.define("int-add-uchar",
                   newFfiCallable("ffiTestIntAddUChar",
                                  "ffiTestIntAddUChar",
                                  cast[pointer](ffiTestIntAddUChar), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/UChar")))
      scope.define("int-add-i64",
                   newFfiCallable("ffiTestIntAddI64",
                                  "ffiTestIntAddI64",
                                  cast[pointer](ffiTestIntAddI64), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Int64")))
      scope.define("int-add-u64",
                   newFfiCallable("ffiTestIntAddU64",
                                  "ffiTestIntAddU64",
                                  cast[pointer](ffiTestIntAddU64), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/UInt64")))
      scope.define("int-diff-ptrdiff",
                   newFfiCallable("ffiTestIntDiffPtrDiff",
                                  "ffiTestIntDiffPtrDiff",
                                  cast[pointer](ffiTestIntDiffPtrDiff), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/PtrDiff")))
      scope.define("int-add-float",
                   newFfiCallable("ffiTestIntAddFloat",
                                  "ffiTestIntAddFloat",
                                  cast[pointer](ffiTestIntAddFloat), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Float")))
      scope.define("int-add-double",
                   newFfiCallable("ffiTestIntAddDouble",
                                  "ffiTestIntAddDouble",
                                  cast[pointer](ffiTestIntAddDouble), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/Double")))
      scope.define("int-pair-kind",
                   newFfiCallable("ffiTestIntPairKind",
                                  "ffiTestIntPairKind",
                                  cast[pointer](ffiTestIntPairKind), lib,
                                  @[newSym("C/Int"), newSym("C/Int")],
                                  newSym("C/CStr")))
      scope.define("double-add",
                   newFfiCallable("ffiTestDoubleAdd", "ffiTestDoubleAdd",
                                  cast[pointer](ffiTestDoubleAdd), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/Double")))
      scope.define("double-double-uint",
                   newFfiCallable("ffiTestDoubleDoubleUInt",
                                  "ffiTestDoubleDoubleUInt",
                                  cast[pointer](ffiTestDoubleDoubleUInt), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/UInt")))
      scope.define("double-double-i32",
                   newFfiCallable("ffiTestDoubleDoubleI32",
                                  "ffiTestDoubleDoubleI32",
                                  cast[pointer](ffiTestDoubleDoubleI32), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/Int32")))
      scope.define("double-double-i16",
                   newFfiCallable("ffiTestDoubleDoubleI16",
                                  "ffiTestDoubleDoubleI16",
                                  cast[pointer](ffiTestDoubleDoubleI16), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/Int16")))
      scope.define("double-double-short",
                   newFfiCallable("ffiTestDoubleDoubleShort",
                                  "ffiTestDoubleDoubleShort",
                                  cast[pointer](ffiTestDoubleDoubleShort), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/Short")))
      scope.define("double-double-i8",
                   newFfiCallable("ffiTestDoubleDoubleI8",
                                  "ffiTestDoubleDoubleI8",
                                  cast[pointer](ffiTestDoubleDoubleI8), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/Int8")))
      scope.define("double-double-char",
                   newFfiCallable("ffiTestDoubleDoubleChar",
                                  "ffiTestDoubleDoubleChar",
                                  cast[pointer](ffiTestDoubleDoubleChar), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/Char")))
      scope.define("double-double-ulong",
                   newFfiCallable("ffiTestDoubleDoubleULong",
                                  "ffiTestDoubleDoubleULong",
                                  cast[pointer](ffiTestDoubleDoubleULong), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/ULong")))
      scope.define("double-double-u32",
                   newFfiCallable("ffiTestDoubleDoubleU32",
                                  "ffiTestDoubleDoubleU32",
                                  cast[pointer](ffiTestDoubleDoubleU32), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/UInt32")))
      scope.define("double-double-u16",
                   newFfiCallable("ffiTestDoubleDoubleU16",
                                  "ffiTestDoubleDoubleU16",
                                  cast[pointer](ffiTestDoubleDoubleU16), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/UInt16")))
      scope.define("double-double-ushort",
                   newFfiCallable("ffiTestDoubleDoubleUShort",
                                  "ffiTestDoubleDoubleUShort",
                                  cast[pointer](ffiTestDoubleDoubleUShort), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/UShort")))
      scope.define("double-double-u8",
                   newFfiCallable("ffiTestDoubleDoubleU8",
                                  "ffiTestDoubleDoubleU8",
                                  cast[pointer](ffiTestDoubleDoubleU8), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/UInt8")))
      scope.define("double-double-uchar",
                   newFfiCallable("ffiTestDoubleDoubleUChar",
                                  "ffiTestDoubleDoubleUChar",
                                  cast[pointer](ffiTestDoubleDoubleUChar), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/UChar")))
      scope.define("double-double-i64",
                   newFfiCallable("ffiTestDoubleDoubleI64",
                                  "ffiTestDoubleDoubleI64",
                                  cast[pointer](ffiTestDoubleDoubleI64), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/Int64")))
      scope.define("double-double-u64",
                   newFfiCallable("ffiTestDoubleDoubleU64",
                                  "ffiTestDoubleDoubleU64",
                                  cast[pointer](ffiTestDoubleDoubleU64), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/UInt64")))
      scope.define("double-double-diff",
                   newFfiCallable("ffiTestDoubleDoubleDiff",
                                  "ffiTestDoubleDoubleDiff",
                                  cast[pointer](ffiTestDoubleDoubleDiff), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/PtrDiff")))
      scope.define("double-double-kind",
                   newFfiCallable("ffiTestDoubleDoubleKind",
                                  "ffiTestDoubleDoubleKind",
                                  cast[pointer](ffiTestDoubleDoubleKind), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/CStr")))
      scope.define("double-scale",
                   newFfiCallable("ffiTestDoubleScale", "ffiTestDoubleScale",
                                  cast[pointer](ffiTestDoubleScale), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/Double")))
      scope.define("double-int-uint",
                   newFfiCallable("ffiTestDoubleIntUInt",
                                  "ffiTestDoubleIntUInt",
                                  cast[pointer](ffiTestDoubleIntUInt), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/UInt")))
      scope.define("double-int-i32",
                   newFfiCallable("ffiTestDoubleIntI32",
                                  "ffiTestDoubleIntI32",
                                  cast[pointer](ffiTestDoubleIntI32), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/Int32")))
      scope.define("double-int-i16",
                   newFfiCallable("ffiTestDoubleIntI16",
                                  "ffiTestDoubleIntI16",
                                  cast[pointer](ffiTestDoubleIntI16), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/Int16")))
      scope.define("double-int-short",
                   newFfiCallable("ffiTestDoubleIntShort",
                                  "ffiTestDoubleIntShort",
                                  cast[pointer](ffiTestDoubleIntShort), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/Short")))
      scope.define("double-int-i8",
                   newFfiCallable("ffiTestDoubleIntI8",
                                  "ffiTestDoubleIntI8",
                                  cast[pointer](ffiTestDoubleIntI8), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/Int8")))
      scope.define("double-int-char",
                   newFfiCallable("ffiTestDoubleIntChar",
                                  "ffiTestDoubleIntChar",
                                  cast[pointer](ffiTestDoubleIntChar), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/Char")))
      scope.define("double-int-ulong",
                   newFfiCallable("ffiTestDoubleIntULong",
                                  "ffiTestDoubleIntULong",
                                  cast[pointer](ffiTestDoubleIntULong), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/ULong")))
      scope.define("double-int-u32",
                   newFfiCallable("ffiTestDoubleIntU32",
                                  "ffiTestDoubleIntU32",
                                  cast[pointer](ffiTestDoubleIntU32), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/UInt32")))
      scope.define("double-int-u16",
                   newFfiCallable("ffiTestDoubleIntU16",
                                  "ffiTestDoubleIntU16",
                                  cast[pointer](ffiTestDoubleIntU16), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/UInt16")))
      scope.define("double-int-ushort",
                   newFfiCallable("ffiTestDoubleIntUShort",
                                  "ffiTestDoubleIntUShort",
                                  cast[pointer](ffiTestDoubleIntUShort), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/UShort")))
      scope.define("double-int-u8",
                   newFfiCallable("ffiTestDoubleIntU8",
                                  "ffiTestDoubleIntU8",
                                  cast[pointer](ffiTestDoubleIntU8), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/UInt8")))
      scope.define("double-int-uchar",
                   newFfiCallable("ffiTestDoubleIntUChar",
                                  "ffiTestDoubleIntUChar",
                                  cast[pointer](ffiTestDoubleIntUChar), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/UChar")))
      scope.define("double-int-i64",
                   newFfiCallable("ffiTestDoubleIntI64",
                                  "ffiTestDoubleIntI64",
                                  cast[pointer](ffiTestDoubleIntI64), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/Int64")))
      scope.define("double-int-u64",
                   newFfiCallable("ffiTestDoubleIntU64",
                                  "ffiTestDoubleIntU64",
                                  cast[pointer](ffiTestDoubleIntU64), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/UInt64")))
      scope.define("double-int-diff",
                   newFfiCallable("ffiTestDoubleIntDiff",
                                  "ffiTestDoubleIntDiff",
                                  cast[pointer](ffiTestDoubleIntDiff), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/PtrDiff")))
      scope.define("double-int-kind",
                   newFfiCallable("ffiTestDoubleIntKind",
                                  "ffiTestDoubleIntKind",
                                  cast[pointer](ffiTestDoubleIntKind), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/CStr")))
      scope.define("int-offset",
                   newFfiCallable("ffiTestIntOffset", "ffiTestIntOffset",
                                  cast[pointer](ffiTestIntOffset), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/Double")))
      scope.define("int-double-uint",
                   newFfiCallable("ffiTestIntDoubleUInt",
                                  "ffiTestIntDoubleUInt",
                                  cast[pointer](ffiTestIntDoubleUInt), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/UInt")))
      scope.define("int-double-i32",
                   newFfiCallable("ffiTestIntDoubleI32",
                                  "ffiTestIntDoubleI32",
                                  cast[pointer](ffiTestIntDoubleI32), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/Int32")))
      scope.define("int-double-i16",
                   newFfiCallable("ffiTestIntDoubleI16",
                                  "ffiTestIntDoubleI16",
                                  cast[pointer](ffiTestIntDoubleI16), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/Int16")))
      scope.define("int-double-short",
                   newFfiCallable("ffiTestIntDoubleShort",
                                  "ffiTestIntDoubleShort",
                                  cast[pointer](ffiTestIntDoubleShort), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/Short")))
      scope.define("int-double-i8",
                   newFfiCallable("ffiTestIntDoubleI8",
                                  "ffiTestIntDoubleI8",
                                  cast[pointer](ffiTestIntDoubleI8), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/Int8")))
      scope.define("int-double-char",
                   newFfiCallable("ffiTestIntDoubleChar",
                                  "ffiTestIntDoubleChar",
                                  cast[pointer](ffiTestIntDoubleChar), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/Char")))
      scope.define("int-double-ulong",
                   newFfiCallable("ffiTestIntDoubleULong",
                                  "ffiTestIntDoubleULong",
                                  cast[pointer](ffiTestIntDoubleULong), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/ULong")))
      scope.define("int-double-u32",
                   newFfiCallable("ffiTestIntDoubleU32",
                                  "ffiTestIntDoubleU32",
                                  cast[pointer](ffiTestIntDoubleU32), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/UInt32")))
      scope.define("int-double-u16",
                   newFfiCallable("ffiTestIntDoubleU16",
                                  "ffiTestIntDoubleU16",
                                  cast[pointer](ffiTestIntDoubleU16), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/UInt16")))
      scope.define("int-double-ushort",
                   newFfiCallable("ffiTestIntDoubleUShort",
                                  "ffiTestIntDoubleUShort",
                                  cast[pointer](ffiTestIntDoubleUShort), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/UShort")))
      scope.define("int-double-u8",
                   newFfiCallable("ffiTestIntDoubleU8",
                                  "ffiTestIntDoubleU8",
                                  cast[pointer](ffiTestIntDoubleU8), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/UInt8")))
      scope.define("int-double-uchar",
                   newFfiCallable("ffiTestIntDoubleUChar",
                                  "ffiTestIntDoubleUChar",
                                  cast[pointer](ffiTestIntDoubleUChar), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/UChar")))
      scope.define("int-double-i64",
                   newFfiCallable("ffiTestIntDoubleI64",
                                  "ffiTestIntDoubleI64",
                                  cast[pointer](ffiTestIntDoubleI64), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/Int64")))
      scope.define("int-double-u64",
                   newFfiCallable("ffiTestIntDoubleU64",
                                  "ffiTestIntDoubleU64",
                                  cast[pointer](ffiTestIntDoubleU64), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/UInt64")))
      scope.define("int-double-diff",
                   newFfiCallable("ffiTestIntDoubleDiff",
                                  "ffiTestIntDoubleDiff",
                                  cast[pointer](ffiTestIntDoubleDiff), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/PtrDiff")))
      scope.define("int-double-kind",
                   newFfiCallable("ffiTestIntDoubleKind",
                                  "ffiTestIntDoubleKind",
                                  cast[pointer](ffiTestIntDoubleKind), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/CStr")))
      scope.define("float-add",
                   newFfiCallable("ffiTestFloatAdd", "ffiTestFloatAdd",
                                  cast[pointer](ffiTestFloatAdd), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/Float")))
      scope.define("float-float-uint",
                   newFfiCallable("ffiTestFloatFloatUInt",
                                  "ffiTestFloatFloatUInt",
                                  cast[pointer](ffiTestFloatFloatUInt), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/UInt")))
      scope.define("float-float-i32",
                   newFfiCallable("ffiTestFloatFloatI32",
                                  "ffiTestFloatFloatI32",
                                  cast[pointer](ffiTestFloatFloatI32), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/Int32")))
      scope.define("float-float-i16",
                   newFfiCallable("ffiTestFloatFloatI16",
                                  "ffiTestFloatFloatI16",
                                  cast[pointer](ffiTestFloatFloatI16), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/Int16")))
      scope.define("float-float-short",
                   newFfiCallable("ffiTestFloatFloatShort",
                                  "ffiTestFloatFloatShort",
                                  cast[pointer](ffiTestFloatFloatShort), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/Short")))
      scope.define("float-float-i8",
                   newFfiCallable("ffiTestFloatFloatI8",
                                  "ffiTestFloatFloatI8",
                                  cast[pointer](ffiTestFloatFloatI8), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/Int8")))
      scope.define("float-float-char",
                   newFfiCallable("ffiTestFloatFloatChar",
                                  "ffiTestFloatFloatChar",
                                  cast[pointer](ffiTestFloatFloatChar), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/Char")))
      scope.define("float-float-ulong",
                   newFfiCallable("ffiTestFloatFloatULong",
                                  "ffiTestFloatFloatULong",
                                  cast[pointer](ffiTestFloatFloatULong), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/ULong")))
      scope.define("float-float-u32",
                   newFfiCallable("ffiTestFloatFloatU32",
                                  "ffiTestFloatFloatU32",
                                  cast[pointer](ffiTestFloatFloatU32), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/UInt32")))
      scope.define("float-float-u16",
                   newFfiCallable("ffiTestFloatFloatU16",
                                  "ffiTestFloatFloatU16",
                                  cast[pointer](ffiTestFloatFloatU16), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/UInt16")))
      scope.define("float-float-ushort",
                   newFfiCallable("ffiTestFloatFloatUShort",
                                  "ffiTestFloatFloatUShort",
                                  cast[pointer](ffiTestFloatFloatUShort), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/UShort")))
      scope.define("float-float-u8",
                   newFfiCallable("ffiTestFloatFloatU8",
                                  "ffiTestFloatFloatU8",
                                  cast[pointer](ffiTestFloatFloatU8), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/UInt8")))
      scope.define("float-float-uchar",
                   newFfiCallable("ffiTestFloatFloatUChar",
                                  "ffiTestFloatFloatUChar",
                                  cast[pointer](ffiTestFloatFloatUChar), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/UChar")))
      scope.define("float-float-i64",
                   newFfiCallable("ffiTestFloatFloatI64",
                                  "ffiTestFloatFloatI64",
                                  cast[pointer](ffiTestFloatFloatI64), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/Int64")))
      scope.define("float-float-u64",
                   newFfiCallable("ffiTestFloatFloatU64",
                                  "ffiTestFloatFloatU64",
                                  cast[pointer](ffiTestFloatFloatU64), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/UInt64")))
      scope.define("float-float-diff",
                   newFfiCallable("ffiTestFloatFloatDiff",
                                  "ffiTestFloatFloatDiff",
                                  cast[pointer](ffiTestFloatFloatDiff), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/PtrDiff")))
      scope.define("float-float-kind",
                   newFfiCallable("ffiTestFloatFloatKind",
                                  "ffiTestFloatFloatKind",
                                  cast[pointer](ffiTestFloatFloatKind), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/CStr")))
      scope.define("float-scale",
                   newFfiCallable("ffiTestFloatScale", "ffiTestFloatScale",
                                  cast[pointer](ffiTestFloatScale), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/Float")))
      scope.define("float-int-uint",
                   newFfiCallable("ffiTestFloatIntUInt",
                                  "ffiTestFloatIntUInt",
                                  cast[pointer](ffiTestFloatIntUInt), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/UInt")))
      scope.define("float-int-i32",
                   newFfiCallable("ffiTestFloatIntI32",
                                  "ffiTestFloatIntI32",
                                  cast[pointer](ffiTestFloatIntI32), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/Int32")))
      scope.define("float-int-i16",
                   newFfiCallable("ffiTestFloatIntI16",
                                  "ffiTestFloatIntI16",
                                  cast[pointer](ffiTestFloatIntI16), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/Int16")))
      scope.define("float-int-short",
                   newFfiCallable("ffiTestFloatIntShort",
                                  "ffiTestFloatIntShort",
                                  cast[pointer](ffiTestFloatIntShort), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/Short")))
      scope.define("float-int-i8",
                   newFfiCallable("ffiTestFloatIntI8",
                                  "ffiTestFloatIntI8",
                                  cast[pointer](ffiTestFloatIntI8), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/Int8")))
      scope.define("float-int-char",
                   newFfiCallable("ffiTestFloatIntChar",
                                  "ffiTestFloatIntChar",
                                  cast[pointer](ffiTestFloatIntChar), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/Char")))
      scope.define("float-int-ulong",
                   newFfiCallable("ffiTestFloatIntULong",
                                  "ffiTestFloatIntULong",
                                  cast[pointer](ffiTestFloatIntULong), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/ULong")))
      scope.define("float-int-u32",
                   newFfiCallable("ffiTestFloatIntU32",
                                  "ffiTestFloatIntU32",
                                  cast[pointer](ffiTestFloatIntU32), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/UInt32")))
      scope.define("float-int-u16",
                   newFfiCallable("ffiTestFloatIntU16",
                                  "ffiTestFloatIntU16",
                                  cast[pointer](ffiTestFloatIntU16), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/UInt16")))
      scope.define("float-int-ushort",
                   newFfiCallable("ffiTestFloatIntUShort",
                                  "ffiTestFloatIntUShort",
                                  cast[pointer](ffiTestFloatIntUShort), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/UShort")))
      scope.define("float-int-u8",
                   newFfiCallable("ffiTestFloatIntU8",
                                  "ffiTestFloatIntU8",
                                  cast[pointer](ffiTestFloatIntU8), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/UInt8")))
      scope.define("float-int-uchar",
                   newFfiCallable("ffiTestFloatIntUChar",
                                  "ffiTestFloatIntUChar",
                                  cast[pointer](ffiTestFloatIntUChar), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/UChar")))
      scope.define("float-int-i64",
                   newFfiCallable("ffiTestFloatIntI64",
                                  "ffiTestFloatIntI64",
                                  cast[pointer](ffiTestFloatIntI64), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/Int64")))
      scope.define("float-int-u64",
                   newFfiCallable("ffiTestFloatIntU64",
                                  "ffiTestFloatIntU64",
                                  cast[pointer](ffiTestFloatIntU64), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/UInt64")))
      scope.define("float-int-diff",
                   newFfiCallable("ffiTestFloatIntDiff",
                                  "ffiTestFloatIntDiff",
                                  cast[pointer](ffiTestFloatIntDiff), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/PtrDiff")))
      scope.define("float-int-kind",
                   newFfiCallable("ffiTestFloatIntKind",
                                  "ffiTestFloatIntKind",
                                  cast[pointer](ffiTestFloatIntKind), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/CStr")))
      scope.define("int-float-offset",
                   newFfiCallable("ffiTestIntFloatOffset",
                                  "ffiTestIntFloatOffset",
                                  cast[pointer](ffiTestIntFloatOffset), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/Float")))
      scope.define("int-float-uint",
                   newFfiCallable("ffiTestIntFloatUInt",
                                  "ffiTestIntFloatUInt",
                                  cast[pointer](ffiTestIntFloatUInt), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/UInt")))
      scope.define("int-float-i32",
                   newFfiCallable("ffiTestIntFloatI32",
                                  "ffiTestIntFloatI32",
                                  cast[pointer](ffiTestIntFloatI32), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/Int32")))
      scope.define("int-float-i16",
                   newFfiCallable("ffiTestIntFloatI16",
                                  "ffiTestIntFloatI16",
                                  cast[pointer](ffiTestIntFloatI16), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/Int16")))
      scope.define("int-float-short",
                   newFfiCallable("ffiTestIntFloatShort",
                                  "ffiTestIntFloatShort",
                                  cast[pointer](ffiTestIntFloatShort), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/Short")))
      scope.define("int-float-i8",
                   newFfiCallable("ffiTestIntFloatI8",
                                  "ffiTestIntFloatI8",
                                  cast[pointer](ffiTestIntFloatI8), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/Int8")))
      scope.define("int-float-char",
                   newFfiCallable("ffiTestIntFloatChar",
                                  "ffiTestIntFloatChar",
                                  cast[pointer](ffiTestIntFloatChar), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/Char")))
      scope.define("int-float-ulong",
                   newFfiCallable("ffiTestIntFloatULong",
                                  "ffiTestIntFloatULong",
                                  cast[pointer](ffiTestIntFloatULong), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/ULong")))
      scope.define("int-float-u32",
                   newFfiCallable("ffiTestIntFloatU32",
                                  "ffiTestIntFloatU32",
                                  cast[pointer](ffiTestIntFloatU32), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/UInt32")))
      scope.define("int-float-u16",
                   newFfiCallable("ffiTestIntFloatU16",
                                  "ffiTestIntFloatU16",
                                  cast[pointer](ffiTestIntFloatU16), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/UInt16")))
      scope.define("int-float-ushort",
                   newFfiCallable("ffiTestIntFloatUShort",
                                  "ffiTestIntFloatUShort",
                                  cast[pointer](ffiTestIntFloatUShort), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/UShort")))
      scope.define("int-float-u8",
                   newFfiCallable("ffiTestIntFloatU8",
                                  "ffiTestIntFloatU8",
                                  cast[pointer](ffiTestIntFloatU8), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/UInt8")))
      scope.define("int-float-uchar",
                   newFfiCallable("ffiTestIntFloatUChar",
                                  "ffiTestIntFloatUChar",
                                  cast[pointer](ffiTestIntFloatUChar), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/UChar")))
      scope.define("int-float-i64",
                   newFfiCallable("ffiTestIntFloatI64",
                                  "ffiTestIntFloatI64",
                                  cast[pointer](ffiTestIntFloatI64), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/Int64")))
      scope.define("int-float-u64",
                   newFfiCallable("ffiTestIntFloatU64",
                                  "ffiTestIntFloatU64",
                                  cast[pointer](ffiTestIntFloatU64), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/UInt64")))
      scope.define("int-float-diff",
                   newFfiCallable("ffiTestIntFloatDiff",
                                  "ffiTestIntFloatDiff",
                                  cast[pointer](ffiTestIntFloatDiff), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/PtrDiff")))
      scope.define("int-float-kind",
                   newFfiCallable("ffiTestIntFloatKind",
                                  "ffiTestIntFloatKind",
                                  cast[pointer](ffiTestIntFloatKind), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/CStr")))
      scope.define("slice-len",
                   newFfiCallable("ffiTestSliceLen", "ffiTestSliceLen",
                                  cast[pointer](ffiTestSliceLen), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Size")))
      scope.define("slice-first-byte",
                   newFfiCallable("ffiTestSliceFirstByte",
                                  "ffiTestSliceFirstByte",
                                  cast[pointer](ffiTestSliceFirstByte), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int")))
      scope.define("slice-len-i32",
                   newFfiCallable("ffiTestSliceLenI32",
                                  "ffiTestSliceLenI32",
                                  cast[pointer](ffiTestSliceLenI32), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int32")))
      scope.define("slice-len-i16",
                   newFfiCallable("ffiTestSliceLenI16",
                                  "ffiTestSliceLenI16",
                                  cast[pointer](ffiTestSliceLenI16), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int16")))
      scope.define("slice-len-short",
                   newFfiCallable("ffiTestSliceLenShort",
                                  "ffiTestSliceLenShort",
                                  cast[pointer](ffiTestSliceLenShort), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Short")))
      scope.define("slice-len-i8",
                   newFfiCallable("ffiTestSliceLenI8",
                                  "ffiTestSliceLenI8",
                                  cast[pointer](ffiTestSliceLenI8), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int8")))
      scope.define("slice-len-char",
                   newFfiCallable("ffiTestSliceLenChar",
                                  "ffiTestSliceLenChar",
                                  cast[pointer](ffiTestSliceLenChar), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Char")))
      scope.define("slice-len-u32",
                   newFfiCallable("ffiTestSliceLenU32",
                                  "ffiTestSliceLenU32",
                                  cast[pointer](ffiTestSliceLenU32), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UInt32")))
      scope.define("slice-len-u16",
                   newFfiCallable("ffiTestSliceLenU16",
                                  "ffiTestSliceLenU16",
                                  cast[pointer](ffiTestSliceLenU16), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UInt16")))
      scope.define("slice-len-ushort",
                   newFfiCallable("ffiTestSliceLenUShort",
                                  "ffiTestSliceLenUShort",
                                  cast[pointer](ffiTestSliceLenUShort), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UShort")))
      scope.define("slice-len-u8",
                   newFfiCallable("ffiTestSliceLenU8",
                                  "ffiTestSliceLenU8",
                                  cast[pointer](ffiTestSliceLenU8), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UInt8")))
      scope.define("slice-len-uchar",
                   newFfiCallable("ffiTestSliceLenUChar",
                                  "ffiTestSliceLenUChar",
                                  cast[pointer](ffiTestSliceLenUChar), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UChar")))
      scope.define("slice-len-ulong",
                   newFfiCallable("ffiTestSliceLenULong",
                                  "ffiTestSliceLenULong",
                                  cast[pointer](ffiTestSliceLenULong), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/ULong")))
      scope.define("slice-len-i64",
                   newFfiCallable("ffiTestSliceLenI64",
                                  "ffiTestSliceLenI64",
                                  cast[pointer](ffiTestSliceLenI64), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int64")))
      scope.define("slice-len-u64",
                   newFfiCallable("ffiTestSliceLenU64",
                                  "ffiTestSliceLenU64",
                                  cast[pointer](ffiTestSliceLenU64), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UInt64")))
      scope.define("slice-len-diff",
                   newFfiCallable("ffiTestSliceLenDiff",
                                  "ffiTestSliceLenDiff",
                                  cast[pointer](ffiTestSliceLenDiff), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/PtrDiff")))
      scope.define("slice-len-float",
                   newFfiCallable("ffiTestSliceLenFloat",
                                  "ffiTestSliceLenFloat",
                                  cast[pointer](ffiTestSliceLenFloat), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Float")))
      scope.define("slice-len-double",
                   newFfiCallable("ffiTestSliceLenDouble",
                                  "ffiTestSliceLenDouble",
                                  cast[pointer](ffiTestSliceLenDouble), lib,
                                  @[newNode(newSym("C/Slice"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Double")))
      scope.define("buffer-len",
                   newFfiCallable("ffiTestSliceLen", "ffiTestSliceLen",
                                  cast[pointer](ffiTestSliceLen), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Size")))
      scope.define("buffer-first-byte",
                   newFfiCallable("ffiTestSliceFirstByte",
                                  "ffiTestSliceFirstByte",
                                  cast[pointer](ffiTestSliceFirstByte), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int")))
      scope.define("buffer-fill",
                   newFfiCallable("ffiTestBufferFill",
                                  "ffiTestBufferFill",
                                  cast[pointer](ffiTestBufferFill), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Void")))
      scope.define("buffer-len-i32",
                   newFfiCallable("ffiTestSliceLenI32",
                                  "ffiTestSliceLenI32",
                                  cast[pointer](ffiTestSliceLenI32), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int32")))
      scope.define("buffer-len-i16",
                   newFfiCallable("ffiTestSliceLenI16",
                                  "ffiTestSliceLenI16",
                                  cast[pointer](ffiTestSliceLenI16), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int16")))
      scope.define("buffer-len-short",
                   newFfiCallable("ffiTestSliceLenShort",
                                  "ffiTestSliceLenShort",
                                  cast[pointer](ffiTestSliceLenShort), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Short")))
      scope.define("buffer-len-i8",
                   newFfiCallable("ffiTestSliceLenI8",
                                  "ffiTestSliceLenI8",
                                  cast[pointer](ffiTestSliceLenI8), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int8")))
      scope.define("buffer-len-char",
                   newFfiCallable("ffiTestSliceLenChar",
                                  "ffiTestSliceLenChar",
                                  cast[pointer](ffiTestSliceLenChar), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Char")))
      scope.define("buffer-len-u32",
                   newFfiCallable("ffiTestSliceLenU32",
                                  "ffiTestSliceLenU32",
                                  cast[pointer](ffiTestSliceLenU32), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UInt32")))
      scope.define("buffer-len-u16",
                   newFfiCallable("ffiTestSliceLenU16",
                                  "ffiTestSliceLenU16",
                                  cast[pointer](ffiTestSliceLenU16), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UInt16")))
      scope.define("buffer-len-ushort",
                   newFfiCallable("ffiTestSliceLenUShort",
                                  "ffiTestSliceLenUShort",
                                  cast[pointer](ffiTestSliceLenUShort), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UShort")))
      scope.define("buffer-len-u8",
                   newFfiCallable("ffiTestSliceLenU8",
                                  "ffiTestSliceLenU8",
                                  cast[pointer](ffiTestSliceLenU8), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UInt8")))
      scope.define("buffer-len-uchar",
                   newFfiCallable("ffiTestSliceLenUChar",
                                  "ffiTestSliceLenUChar",
                                  cast[pointer](ffiTestSliceLenUChar), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UChar")))
      scope.define("buffer-len-ulong",
                   newFfiCallable("ffiTestSliceLenULong",
                                  "ffiTestSliceLenULong",
                                  cast[pointer](ffiTestSliceLenULong), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/ULong")))
      scope.define("buffer-len-i64",
                   newFfiCallable("ffiTestSliceLenI64",
                                  "ffiTestSliceLenI64",
                                  cast[pointer](ffiTestSliceLenI64), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Int64")))
      scope.define("buffer-len-u64",
                   newFfiCallable("ffiTestSliceLenU64",
                                  "ffiTestSliceLenU64",
                                  cast[pointer](ffiTestSliceLenU64), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/UInt64")))
      scope.define("buffer-len-diff",
                   newFfiCallable("ffiTestSliceLenDiff",
                                  "ffiTestSliceLenDiff",
                                  cast[pointer](ffiTestSliceLenDiff), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/PtrDiff")))
      scope.define("buffer-len-float",
                   newFfiCallable("ffiTestSliceLenFloat",
                                  "ffiTestSliceLenFloat",
                                  cast[pointer](ffiTestSliceLenFloat), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Float")))
      scope.define("buffer-len-double",
                   newFfiCallable("ffiTestSliceLenDouble",
                                  "ffiTestSliceLenDouble",
                                  cast[pointer](ffiTestSliceLenDouble), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UInt8")])],
                                  newSym("C/Double")))
      scope.define("char-buffer-first-byte",
                   newFfiCallable("ffiTestSliceFirstByte",
                                  "ffiTestSliceFirstByte",
                                  cast[pointer](ffiTestSliceFirstByte), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int")))
      scope.define("uchar-buffer-first-byte",
                   newFfiCallable("ffiTestSliceFirstByte",
                                  "ffiTestSliceFirstByte",
                                  cast[pointer](ffiTestSliceFirstByte), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/UChar")])],
                                  newSym("C/Int")))
      scope.define("i8-buffer-first-byte",
                   newFfiCallable("ffiTestSliceFirstByte",
                                  "ffiTestSliceFirstByte",
                                  cast[pointer](ffiTestSliceFirstByte), lib,
                                  @[newNode(newSym("Buffer"),
                                            body = @[newSym("C/Int8")])],
                                  newSym("C/Int")))
      scope.define("cstr-bounded-len",
                   newFfiCallable("ffiTestCStrBoundedLen",
                                  "ffiTestCStrBoundedLen",
                                  cast[pointer](ffiTestCStrBoundedLen), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Size")))
      scope.define("cstr-ptr-if-len",
                   newFfiCallable("ffiTestCStrPtrIfLen",
                                  "ffiTestCStrPtrIfLen",
                                  cast[pointer](ffiTestCStrPtrIfLen), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newNode(newSym("C/NullableConstPtr"),
                                          body = @[newSym("C/Char")])))
      scope.define("cstr-long",
                   newFfiCallable("ffiTestCStrLong",
                                  "ffiTestCStrLong",
                                  cast[pointer](ffiTestCStrLong), lib,
                                  @[newSym("C/CStr")], newSym("C/Long")))
      scope.define("cstr-i16",
                   newFfiCallable("ffiTestCStrI16",
                                  "ffiTestCStrI16",
                                  cast[pointer](ffiTestCStrI16), lib,
                                  @[newSym("C/CStr")], newSym("C/Int16")))
      scope.define("cstr-short",
                   newFfiCallable("ffiTestCStrShort",
                                  "ffiTestCStrShort",
                                  cast[pointer](ffiTestCStrShort), lib,
                                  @[newSym("C/CStr")], newSym("C/Short")))
      scope.define("cstr-i8",
                   newFfiCallable("ffiTestCStrI8",
                                  "ffiTestCStrI8",
                                  cast[pointer](ffiTestCStrI8), lib,
                                  @[newSym("C/CStr")], newSym("C/Int8")))
      scope.define("cstr-first-char",
                   newFfiCallable("ffiTestCStrFirstChar",
                                  "ffiTestCStrFirstChar",
                                  cast[pointer](ffiTestCStrFirstChar), lib,
                                  @[newSym("C/CStr")], newSym("C/Char")))
      scope.define("cstr-ulong",
                   newFfiCallable("ffiTestCStrULong",
                                  "ffiTestCStrULong",
                                  cast[pointer](ffiTestCStrULong), lib,
                                  @[newSym("C/CStr")], newSym("C/ULong")))
      scope.define("cstr-u16",
                   newFfiCallable("ffiTestCStrU16",
                                  "ffiTestCStrU16",
                                  cast[pointer](ffiTestCStrU16), lib,
                                  @[newSym("C/CStr")], newSym("C/UInt16")))
      scope.define("cstr-ushort",
                   newFfiCallable("ffiTestCStrUShort",
                                  "ffiTestCStrUShort",
                                  cast[pointer](ffiTestCStrUShort), lib,
                                  @[newSym("C/CStr")], newSym("C/UShort")))
      scope.define("cstr-u8",
                   newFfiCallable("ffiTestCStrU8",
                                  "ffiTestCStrU8",
                                  cast[pointer](ffiTestCStrU8), lib,
                                  @[newSym("C/CStr")], newSym("C/UInt8")))
      scope.define("cstr-first-uchar",
                   newFfiCallable("ffiTestCStrFirstUChar",
                                  "ffiTestCStrFirstUChar",
                                  cast[pointer](ffiTestCStrFirstUChar), lib,
                                  @[newSym("C/CStr")], newSym("C/UChar")))
      scope.define("cstr-i64",
                   newFfiCallable("ffiTestCStrI64",
                                  "ffiTestCStrI64",
                                  cast[pointer](ffiTestCStrI64), lib,
                                  @[newSym("C/CStr")], newSym("C/Int64")))
      scope.define("cstr-u64",
                   newFfiCallable("ffiTestCStrU64",
                                  "ffiTestCStrU64",
                                  cast[pointer](ffiTestCStrU64), lib,
                                  @[newSym("C/CStr")], newSym("C/UInt64")))
      scope.define("cstr-diff",
                   newFfiCallable("ffiTestCStrDiff",
                                  "ffiTestCStrDiff",
                                  cast[pointer](ffiTestCStrDiff), lib,
                                  @[newSym("C/CStr")], newSym("C/PtrDiff")))
      scope.define("cstr-non-empty?",
                   newFfiCallable("ffiTestCStrNonEmpty",
                                  "ffiTestCStrNonEmpty",
                                  cast[pointer](ffiTestCStrNonEmpty), lib,
                                  @[newSym("C/CStr")], newSym("C/Bool")))
      scope.define("cstr-int-uint",
                   newFfiCallable("ffiTestCStrIntUInt",
                                  "ffiTestCStrIntUInt",
                                  cast[pointer](ffiTestCStrIntUInt), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/UInt")))
      scope.define("cstr-int-i32",
                   newFfiCallable("ffiTestCStrIntI32",
                                  "ffiTestCStrIntI32",
                                  cast[pointer](ffiTestCStrIntI32), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Int32")))
      scope.define("cstr-int-i16",
                   newFfiCallable("ffiTestCStrIntI16",
                                  "ffiTestCStrIntI16",
                                  cast[pointer](ffiTestCStrIntI16), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Int16")))
      scope.define("cstr-int-short",
                   newFfiCallable("ffiTestCStrIntShort",
                                  "ffiTestCStrIntShort",
                                  cast[pointer](ffiTestCStrIntShort), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Short")))
      scope.define("cstr-int-i8",
                   newFfiCallable("ffiTestCStrIntI8",
                                  "ffiTestCStrIntI8",
                                  cast[pointer](ffiTestCStrIntI8), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Int8")))
      scope.define("cstr-int-char",
                   newFfiCallable("ffiTestCStrIntChar",
                                  "ffiTestCStrIntChar",
                                  cast[pointer](ffiTestCStrIntChar), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Char")))
      scope.define("cstr-int-u32",
                   newFfiCallable("ffiTestCStrIntU32",
                                  "ffiTestCStrIntU32",
                                  cast[pointer](ffiTestCStrIntU32), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/UInt32")))
      scope.define("cstr-int-u16",
                   newFfiCallable("ffiTestCStrIntU16",
                                  "ffiTestCStrIntU16",
                                  cast[pointer](ffiTestCStrIntU16), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/UInt16")))
      scope.define("cstr-int-ushort",
                   newFfiCallable("ffiTestCStrIntUShort",
                                  "ffiTestCStrIntUShort",
                                  cast[pointer](ffiTestCStrIntUShort), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/UShort")))
      scope.define("cstr-int-u8",
                   newFfiCallable("ffiTestCStrIntU8",
                                  "ffiTestCStrIntU8",
                                  cast[pointer](ffiTestCStrIntU8), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/UInt8")))
      scope.define("cstr-int-uchar",
                   newFfiCallable("ffiTestCStrIntUChar",
                                  "ffiTestCStrIntUChar",
                                  cast[pointer](ffiTestCStrIntUChar), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/UChar")))
      scope.define("cstr-int-long",
                   newFfiCallable("ffiTestCStrIntLong",
                                  "ffiTestCStrIntLong",
                                  cast[pointer](ffiTestCStrIntLong), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Long")))
      scope.define("cstr-int-ulong",
                   newFfiCallable("ffiTestCStrIntULong",
                                  "ffiTestCStrIntULong",
                                  cast[pointer](ffiTestCStrIntULong), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/ULong")))
      scope.define("cstr-int-i64",
                   newFfiCallable("ffiTestCStrIntI64",
                                  "ffiTestCStrIntI64",
                                  cast[pointer](ffiTestCStrIntI64), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Int64")))
      scope.define("cstr-int-u64",
                   newFfiCallable("ffiTestCStrIntU64",
                                  "ffiTestCStrIntU64",
                                  cast[pointer](ffiTestCStrIntU64), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/UInt64")))
      scope.define("cstr-int-diff",
                   newFfiCallable("ffiTestCStrIntDiff",
                                  "ffiTestCStrIntDiff",
                                  cast[pointer](ffiTestCStrIntDiff), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/PtrDiff")))
      scope.define("cstr-int-float",
                   newFfiCallable("ffiTestCStrIntFloat",
                                  "ffiTestCStrIntFloat",
                                  cast[pointer](ffiTestCStrIntFloat), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Float")))
      scope.define("cstr-int-double",
                   newFfiCallable("ffiTestCStrIntDouble",
                                  "ffiTestCStrIntDouble",
                                  cast[pointer](ffiTestCStrIntDouble), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Double")))
      scope.define("cstr-int-equal-len?",
                   newFfiCallable("ffiTestCStrIntEqualLen",
                                  "ffiTestCStrIntEqualLen",
                                  cast[pointer](ffiTestCStrIntEqualLen), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/Bool")))
      scope.define("cstr-size-uint",
                   newFfiCallable("ffiTestCStrSizeUInt",
                                  "ffiTestCStrSizeUInt",
                                  cast[pointer](ffiTestCStrSizeUInt), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/UInt")))
      scope.define("cstr-size-i32",
                   newFfiCallable("ffiTestCStrSizeI32",
                                  "ffiTestCStrSizeI32",
                                  cast[pointer](ffiTestCStrSizeI32), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Int32")))
      scope.define("cstr-size-i16",
                   newFfiCallable("ffiTestCStrSizeI16",
                                  "ffiTestCStrSizeI16",
                                  cast[pointer](ffiTestCStrSizeI16), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Int16")))
      scope.define("cstr-size-short",
                   newFfiCallable("ffiTestCStrSizeShort",
                                  "ffiTestCStrSizeShort",
                                  cast[pointer](ffiTestCStrSizeShort), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Short")))
      scope.define("cstr-size-i8",
                   newFfiCallable("ffiTestCStrSizeI8",
                                  "ffiTestCStrSizeI8",
                                  cast[pointer](ffiTestCStrSizeI8), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Int8")))
      scope.define("cstr-size-char",
                   newFfiCallable("ffiTestCStrSizeChar",
                                  "ffiTestCStrSizeChar",
                                  cast[pointer](ffiTestCStrSizeChar), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Char")))
      scope.define("cstr-size-u32",
                   newFfiCallable("ffiTestCStrSizeU32",
                                  "ffiTestCStrSizeU32",
                                  cast[pointer](ffiTestCStrSizeU32), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/UInt32")))
      scope.define("cstr-size-u16",
                   newFfiCallable("ffiTestCStrSizeU16",
                                  "ffiTestCStrSizeU16",
                                  cast[pointer](ffiTestCStrSizeU16), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/UInt16")))
      scope.define("cstr-size-ushort",
                   newFfiCallable("ffiTestCStrSizeUShort",
                                  "ffiTestCStrSizeUShort",
                                  cast[pointer](ffiTestCStrSizeUShort), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/UShort")))
      scope.define("cstr-size-u8",
                   newFfiCallable("ffiTestCStrSizeU8",
                                  "ffiTestCStrSizeU8",
                                  cast[pointer](ffiTestCStrSizeU8), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/UInt8")))
      scope.define("cstr-size-uchar",
                   newFfiCallable("ffiTestCStrSizeUChar",
                                  "ffiTestCStrSizeUChar",
                                  cast[pointer](ffiTestCStrSizeUChar), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/UChar")))
      scope.define("cstr-size-long",
                   newFfiCallable("ffiTestCStrSizeLong",
                                  "ffiTestCStrSizeLong",
                                  cast[pointer](ffiTestCStrSizeLong), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Long")))
      scope.define("cstr-size-ulong",
                   newFfiCallable("ffiTestCStrSizeULong",
                                  "ffiTestCStrSizeULong",
                                  cast[pointer](ffiTestCStrSizeULong), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/ULong")))
      scope.define("cstr-size-i64",
                   newFfiCallable("ffiTestCStrSizeI64",
                                  "ffiTestCStrSizeI64",
                                  cast[pointer](ffiTestCStrSizeI64), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Int64")))
      scope.define("cstr-size-u64",
                   newFfiCallable("ffiTestCStrSizeU64",
                                  "ffiTestCStrSizeU64",
                                  cast[pointer](ffiTestCStrSizeU64), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/UInt64")))
      scope.define("cstr-size-diff",
                   newFfiCallable("ffiTestCStrSizeDiff",
                                  "ffiTestCStrSizeDiff",
                                  cast[pointer](ffiTestCStrSizeDiff), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/PtrDiff")))
      scope.define("cstr-size-float",
                   newFfiCallable("ffiTestCStrSizeFloat",
                                  "ffiTestCStrSizeFloat",
                                  cast[pointer](ffiTestCStrSizeFloat), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Float")))
      scope.define("cstr-size-double",
                   newFfiCallable("ffiTestCStrSizeDouble",
                                  "ffiTestCStrSizeDouble",
                                  cast[pointer](ffiTestCStrSizeDouble), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Double")))
      scope.define("cstr-size-equal-len?",
                   newFfiCallable("ffiTestCStrSizeEqualLen",
                                  "ffiTestCStrSizeEqualLen",
                                  cast[pointer](ffiTestCStrSizeEqualLen), lib,
                                  @[newSym("C/CStr"), newSym("C/Size")],
                                  newSym("C/Bool")))
      scope.define("cstr-pair-u64",
                   newFfiCallable("ffiTestCStrPairU64",
                                  "ffiTestCStrPairU64",
                                  cast[pointer](ffiTestCStrPairU64), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/UInt64")))
      scope.define("cstr-pair-i32",
                   newFfiCallable("ffiTestCStrPairI32",
                                  "ffiTestCStrPairI32",
                                  cast[pointer](ffiTestCStrPairI32), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/Int32")))
      scope.define("cstr-pair-i16",
                   newFfiCallable("ffiTestCStrPairI16",
                                  "ffiTestCStrPairI16",
                                  cast[pointer](ffiTestCStrPairI16), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/Int16")))
      scope.define("cstr-pair-short",
                   newFfiCallable("ffiTestCStrPairShort",
                                  "ffiTestCStrPairShort",
                                  cast[pointer](ffiTestCStrPairShort), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/Short")))
      scope.define("cstr-pair-i8",
                   newFfiCallable("ffiTestCStrPairI8",
                                  "ffiTestCStrPairI8",
                                  cast[pointer](ffiTestCStrPairI8), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/Int8")))
      scope.define("cstr-pair-char",
                   newFfiCallable("ffiTestCStrPairChar",
                                  "ffiTestCStrPairChar",
                                  cast[pointer](ffiTestCStrPairChar), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/Char")))
      scope.define("cstr-pair-u32",
                   newFfiCallable("ffiTestCStrPairU32",
                                  "ffiTestCStrPairU32",
                                  cast[pointer](ffiTestCStrPairU32), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/UInt32")))
      scope.define("cstr-pair-u16",
                   newFfiCallable("ffiTestCStrPairU16",
                                  "ffiTestCStrPairU16",
                                  cast[pointer](ffiTestCStrPairU16), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/UInt16")))
      scope.define("cstr-pair-ushort",
                   newFfiCallable("ffiTestCStrPairUShort",
                                  "ffiTestCStrPairUShort",
                                  cast[pointer](ffiTestCStrPairUShort), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/UShort")))
      scope.define("cstr-pair-u8",
                   newFfiCallable("ffiTestCStrPairU8",
                                  "ffiTestCStrPairU8",
                                  cast[pointer](ffiTestCStrPairU8), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/UInt8")))
      scope.define("cstr-pair-uchar",
                   newFfiCallable("ffiTestCStrPairUChar",
                                  "ffiTestCStrPairUChar",
                                  cast[pointer](ffiTestCStrPairUChar), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/UChar")))
      scope.define("cstr-pair-diff",
                   newFfiCallable("ffiTestCStrPairDiff",
                                  "ffiTestCStrPairDiff",
                                  cast[pointer](ffiTestCStrPairDiff), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/PtrDiff")))
      scope.define("cstr-pair-double",
                   newFfiCallable("ffiTestCStrPairDouble",
                                  "ffiTestCStrPairDouble",
                                  cast[pointer](ffiTestCStrPairDouble), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/Double")))
      scope.define("cstr-pair-equal?",
                   newFfiCallable("ffiTestCStrPairEqual",
                                  "ffiTestCStrPairEqual",
                                  cast[pointer](ffiTestCStrPairEqual), lib,
                                  @[newSym("C/CStr"), newSym("C/CStr")],
                                  newSym("C/Bool")))
      scope.define("ptr-copy",
                   newFfiCallable("ffiTestPtrCopy", "ffiTestPtrCopy",
                                  cast[pointer](ffiTestPtrCopy), lib,
                                  @[newNode(newSym("C/Ptr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newNode(newSym("C/Ptr"),
                                          body = @[newSym("C/Char")])))
      scope.define("ptr-if-len",
                   newFfiCallable("ffiTestPtrIfLen", "ffiTestPtrIfLen",
                                  cast[pointer](ffiTestPtrIfLen), lib,
                                  @[newNode(newSym("C/Ptr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newNode(newSym("C/NullablePtr"),
                                          body = @[newSym("C/Char")])))
      scope.define("ptr-len",
                   newFfiCallable("ffiTestPtrLen", "ffiTestPtrLen",
                                  cast[pointer](ffiTestPtrLen), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Size")))
      scope.define("ptr-len-i32",
                   newFfiCallable("ffiTestPtrLenI32", "ffiTestPtrLenI32",
                                  cast[pointer](ffiTestPtrLenI32), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Int32")))
      scope.define("ptr-len-i16",
                   newFfiCallable("ffiTestPtrLenI16", "ffiTestPtrLenI16",
                                  cast[pointer](ffiTestPtrLenI16), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Int16")))
      scope.define("ptr-len-short",
                   newFfiCallable("ffiTestPtrLenShort",
                                  "ffiTestPtrLenShort",
                                  cast[pointer](ffiTestPtrLenShort), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Short")))
      scope.define("ptr-len-i8",
                   newFfiCallable("ffiTestPtrLenI8", "ffiTestPtrLenI8",
                                  cast[pointer](ffiTestPtrLenI8), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Int8")))
      scope.define("ptr-len-char",
                   newFfiCallable("ffiTestPtrLenChar",
                                  "ffiTestPtrLenChar",
                                  cast[pointer](ffiTestPtrLenChar), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Char")))
      scope.define("ptr-len-u64",
                   newFfiCallable("ffiTestPtrLenU64", "ffiTestPtrLenU64",
                                  cast[pointer](ffiTestPtrLenU64), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UInt64")))
      scope.define("ptr-len-u32",
                   newFfiCallable("ffiTestPtrLenU32", "ffiTestPtrLenU32",
                                  cast[pointer](ffiTestPtrLenU32), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UInt32")))
      scope.define("ptr-len-u16",
                   newFfiCallable("ffiTestPtrLenU16", "ffiTestPtrLenU16",
                                  cast[pointer](ffiTestPtrLenU16), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UInt16")))
      scope.define("ptr-len-ushort",
                   newFfiCallable("ffiTestPtrLenUShort",
                                  "ffiTestPtrLenUShort",
                                  cast[pointer](ffiTestPtrLenUShort), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UShort")))
      scope.define("ptr-len-u8",
                   newFfiCallable("ffiTestPtrLenU8", "ffiTestPtrLenU8",
                                  cast[pointer](ffiTestPtrLenU8), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UInt8")))
      scope.define("ptr-len-uchar",
                   newFfiCallable("ffiTestPtrLenUChar",
                                  "ffiTestPtrLenUChar",
                                  cast[pointer](ffiTestPtrLenUChar), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UChar")))
      scope.define("ptr-len-diff",
                   newFfiCallable("ffiTestPtrLenDiff", "ffiTestPtrLenDiff",
                                  cast[pointer](ffiTestPtrLenDiff), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/PtrDiff")))
      scope.define("ptr-len-double",
                   newFfiCallable("ffiTestPtrLenDouble",
                                  "ffiTestPtrLenDouble",
                                  cast[pointer](ffiTestPtrLenDouble), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Double")))
      scope.define("ptr-has-len?",
                   newFfiCallable("ffiTestPtrHasLen",
                                  "ffiTestPtrHasLen",
                                  cast[pointer](ffiTestPtrHasLen), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Bool")))
      scope.define("ptr-int-len",
                   newFfiCallable("ffiTestPtrIntLen",
                                  "ffiTestPtrIntLen",
                                  cast[pointer](ffiTestPtrIntLen), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/Size")))
      scope.define("ptr-int-len-i32",
                   newFfiCallable("ffiTestPtrIntLenI32",
                                  "ffiTestPtrIntLenI32",
                                  cast[pointer](ffiTestPtrIntLenI32), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/Int32")))
      scope.define("ptr-int-len-i16",
                   newFfiCallable("ffiTestPtrIntLenI16",
                                  "ffiTestPtrIntLenI16",
                                  cast[pointer](ffiTestPtrIntLenI16), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/Int16")))
      scope.define("ptr-int-len-short",
                   newFfiCallable("ffiTestPtrIntLenShort",
                                  "ffiTestPtrIntLenShort",
                                  cast[pointer](ffiTestPtrIntLenShort), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/Short")))
      scope.define("ptr-int-len-i8",
                   newFfiCallable("ffiTestPtrIntLenI8",
                                  "ffiTestPtrIntLenI8",
                                  cast[pointer](ffiTestPtrIntLenI8), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/Int8")))
      scope.define("ptr-int-len-char",
                   newFfiCallable("ffiTestPtrIntLenChar",
                                  "ffiTestPtrIntLenChar",
                                  cast[pointer](ffiTestPtrIntLenChar), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/Char")))
      scope.define("ptr-int-len-u64",
                   newFfiCallable("ffiTestPtrIntLenU64",
                                  "ffiTestPtrIntLenU64",
                                  cast[pointer](ffiTestPtrIntLenU64), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/UInt64")))
      scope.define("ptr-int-len-u32",
                   newFfiCallable("ffiTestPtrIntLenU32",
                                  "ffiTestPtrIntLenU32",
                                  cast[pointer](ffiTestPtrIntLenU32), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/UInt32")))
      scope.define("ptr-int-len-u16",
                   newFfiCallable("ffiTestPtrIntLenU16",
                                  "ffiTestPtrIntLenU16",
                                  cast[pointer](ffiTestPtrIntLenU16), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/UInt16")))
      scope.define("ptr-int-len-ushort",
                   newFfiCallable("ffiTestPtrIntLenUShort",
                                  "ffiTestPtrIntLenUShort",
                                  cast[pointer](ffiTestPtrIntLenUShort), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/UShort")))
      scope.define("ptr-int-len-u8",
                   newFfiCallable("ffiTestPtrIntLenU8",
                                  "ffiTestPtrIntLenU8",
                                  cast[pointer](ffiTestPtrIntLenU8), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/UInt8")))
      scope.define("ptr-int-len-uchar",
                   newFfiCallable("ffiTestPtrIntLenUChar",
                                  "ffiTestPtrIntLenUChar",
                                  cast[pointer](ffiTestPtrIntLenUChar), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/UChar")))
      scope.define("ptr-int-len-diff",
                   newFfiCallable("ffiTestPtrIntLenDiff",
                                  "ffiTestPtrIntLenDiff",
                                  cast[pointer](ffiTestPtrIntLenDiff), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/PtrDiff")))
      scope.define("ptr-int-len-double",
                   newFfiCallable("ffiTestPtrIntLenDouble",
                                  "ffiTestPtrIntLenDouble",
                                  cast[pointer](ffiTestPtrIntLenDouble), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/Double")))
      scope.define("ptr-int-has-len?",
                   newFfiCallable("ffiTestPtrIntHasLen",
                                  "ffiTestPtrIntHasLen",
                                  cast[pointer](ffiTestPtrIntHasLen), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/Bool")))
      scope.define("ptr-identity",
                   newFfiCallable("ffiTestPtrIdentity",
                                  "ffiTestPtrIdentity",
                                  cast[pointer](ffiTestPtrIdentity), lib,
                                  @[newNode(newSym("C/Ptr"),
                                            body = @[newSym("C/Char")])],
                                  newNode(newSym("C/Ptr"),
                                          body = @[newSym("C/Char")])))
      scope.define("ptr-nil?",
                   newFfiCallable("ffiTestPtrIsNil",
                                  "ffiTestPtrIsNil",
                                  cast[pointer](ffiTestPtrIsNil), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Bool")))
      scope.define("ptr-probe-i32",
                   newFfiCallable("ffiTestPtrProbeI32",
                                  "ffiTestPtrProbeI32",
                                  cast[pointer](ffiTestPtrProbeI32), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int32")))
      scope.define("ptr-probe-i16",
                   newFfiCallable("ffiTestPtrProbeI16",
                                  "ffiTestPtrProbeI16",
                                  cast[pointer](ffiTestPtrProbeI16), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int16")))
      scope.define("ptr-probe-short",
                   newFfiCallable("ffiTestPtrProbeShort",
                                  "ffiTestPtrProbeShort",
                                  cast[pointer](ffiTestPtrProbeShort), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Short")))
      scope.define("ptr-probe-i8",
                   newFfiCallable("ffiTestPtrProbeI8",
                                  "ffiTestPtrProbeI8",
                                  cast[pointer](ffiTestPtrProbeI8), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int8")))
      scope.define("ptr-probe-char",
                   newFfiCallable("ffiTestPtrProbeChar",
                                  "ffiTestPtrProbeChar",
                                  cast[pointer](ffiTestPtrProbeChar), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Char")))
      scope.define("ptr-probe-ulong",
                   newFfiCallable("ffiTestPtrProbeULong",
                                  "ffiTestPtrProbeULong",
                                  cast[pointer](ffiTestPtrProbeULong), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/ULong")))
      scope.define("ptr-probe-u32",
                   newFfiCallable("ffiTestPtrProbeU32",
                                  "ffiTestPtrProbeU32",
                                  cast[pointer](ffiTestPtrProbeU32), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UInt32")))
      scope.define("ptr-probe-u16",
                   newFfiCallable("ffiTestPtrProbeU16",
                                  "ffiTestPtrProbeU16",
                                  cast[pointer](ffiTestPtrProbeU16), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UInt16")))
      scope.define("ptr-probe-ushort",
                   newFfiCallable("ffiTestPtrProbeUShort",
                                  "ffiTestPtrProbeUShort",
                                  cast[pointer](ffiTestPtrProbeUShort), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UShort")))
      scope.define("ptr-probe-u8",
                   newFfiCallable("ffiTestPtrProbeU8",
                                  "ffiTestPtrProbeU8",
                                  cast[pointer](ffiTestPtrProbeU8), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UInt8")))
      scope.define("ptr-probe-uchar",
                   newFfiCallable("ffiTestPtrProbeUChar",
                                  "ffiTestPtrProbeUChar",
                                  cast[pointer](ffiTestPtrProbeUChar), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UChar")))
      scope.define("ptr-probe-i64",
                   newFfiCallable("ffiTestPtrProbeI64",
                                  "ffiTestPtrProbeI64",
                                  cast[pointer](ffiTestPtrProbeI64), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int64")))
      scope.define("ptr-probe-u64",
                   newFfiCallable("ffiTestPtrProbeU64",
                                  "ffiTestPtrProbeU64",
                                  cast[pointer](ffiTestPtrProbeU64), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UInt64")))
      scope.define("ptr-probe-diff",
                   newFfiCallable("ffiTestPtrProbeDiff",
                                  "ffiTestPtrProbeDiff",
                                  cast[pointer](ffiTestPtrProbeDiff), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/PtrDiff")))
      scope.define("ptr-same",
                   newFfiCallable("ffiTestPtrSame",
                                  "ffiTestPtrSame",
                                  cast[pointer](ffiTestPtrSame), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int")))
      scope.define("ptr-same-i32",
                   newFfiCallable("ffiTestPtrSameI32",
                                  "ffiTestPtrSameI32",
                                  cast[pointer](ffiTestPtrSameI32), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int32")))
      scope.define("ptr-same-i16",
                   newFfiCallable("ffiTestPtrSameI16",
                                  "ffiTestPtrSameI16",
                                  cast[pointer](ffiTestPtrSameI16), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int16")))
      scope.define("ptr-same-short",
                   newFfiCallable("ffiTestPtrSameShort",
                                  "ffiTestPtrSameShort",
                                  cast[pointer](ffiTestPtrSameShort), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Short")))
      scope.define("ptr-same-i8",
                   newFfiCallable("ffiTestPtrSameI8",
                                  "ffiTestPtrSameI8",
                                  cast[pointer](ffiTestPtrSameI8), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int8")))
      scope.define("ptr-same-char",
                   newFfiCallable("ffiTestPtrSameChar",
                                  "ffiTestPtrSameChar",
                                  cast[pointer](ffiTestPtrSameChar), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Char")))
      scope.define("ptr-same-u64",
                   newFfiCallable("ffiTestPtrSameU64",
                                  "ffiTestPtrSameU64",
                                  cast[pointer](ffiTestPtrSameU64), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UInt64")))
      scope.define("ptr-same-u32",
                   newFfiCallable("ffiTestPtrSameU32",
                                  "ffiTestPtrSameU32",
                                  cast[pointer](ffiTestPtrSameU32), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UInt32")))
      scope.define("ptr-same-u16",
                   newFfiCallable("ffiTestPtrSameU16",
                                  "ffiTestPtrSameU16",
                                  cast[pointer](ffiTestPtrSameU16), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UInt16")))
      scope.define("ptr-same-ushort",
                   newFfiCallable("ffiTestPtrSameUShort",
                                  "ffiTestPtrSameUShort",
                                  cast[pointer](ffiTestPtrSameUShort), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UShort")))
      scope.define("ptr-same-u8",
                   newFfiCallable("ffiTestPtrSameU8",
                                  "ffiTestPtrSameU8",
                                  cast[pointer](ffiTestPtrSameU8), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UInt8")))
      scope.define("ptr-same-uchar",
                   newFfiCallable("ffiTestPtrSameUChar",
                                  "ffiTestPtrSameUChar",
                                  cast[pointer](ffiTestPtrSameUChar), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UChar")))
      scope.define("ptr-same-diff",
                   newFfiCallable("ffiTestPtrSameDiff",
                                  "ffiTestPtrSameDiff",
                                  cast[pointer](ffiTestPtrSameDiff), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/PtrDiff")))
      scope.define("ptr-same-double",
                   newFfiCallable("ffiTestPtrSameDouble",
                                  "ffiTestPtrSameDouble",
                                  cast[pointer](ffiTestPtrSameDouble), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Double")))
      scope.define("ptr-pick",
                   newFfiCallable("ffiTestPtrPick",
                                  "ffiTestPtrPick",
                                  cast[pointer](ffiTestPtrPick), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/Ptr"),
                                            body = @[newSym("C/Char")])],
                                  newNode(newSym("C/Ptr"),
                                          body = @[newSym("C/Char")])))
      scope.define("ptr-ptr-len",
                   newFfiCallable("ffiTestPtrPtrLen",
                                  "ffiTestPtrPtrLen",
                                  cast[pointer](ffiTestPtrPtrLen), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Size")))
      scope.define("ptr-ptr-len-i32",
                   newFfiCallable("ffiTestPtrPtrLenI32",
                                  "ffiTestPtrPtrLenI32",
                                  cast[pointer](ffiTestPtrPtrLenI32), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Int32")))
      scope.define("ptr-ptr-len-i16",
                   newFfiCallable("ffiTestPtrPtrLenI16",
                                  "ffiTestPtrPtrLenI16",
                                  cast[pointer](ffiTestPtrPtrLenI16), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Int16")))
      scope.define("ptr-ptr-len-short",
                   newFfiCallable("ffiTestPtrPtrLenShort",
                                  "ffiTestPtrPtrLenShort",
                                  cast[pointer](ffiTestPtrPtrLenShort), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Short")))
      scope.define("ptr-ptr-len-i8",
                   newFfiCallable("ffiTestPtrPtrLenI8",
                                  "ffiTestPtrPtrLenI8",
                                  cast[pointer](ffiTestPtrPtrLenI8), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Int8")))
      scope.define("ptr-ptr-len-char",
                   newFfiCallable("ffiTestPtrPtrLenChar",
                                  "ffiTestPtrPtrLenChar",
                                  cast[pointer](ffiTestPtrPtrLenChar), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Char")))
      scope.define("ptr-ptr-len-u64",
                   newFfiCallable("ffiTestPtrPtrLenU64",
                                  "ffiTestPtrPtrLenU64",
                                  cast[pointer](ffiTestPtrPtrLenU64), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UInt64")))
      scope.define("ptr-ptr-len-u32",
                   newFfiCallable("ffiTestPtrPtrLenU32",
                                  "ffiTestPtrPtrLenU32",
                                  cast[pointer](ffiTestPtrPtrLenU32), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UInt32")))
      scope.define("ptr-ptr-len-u16",
                   newFfiCallable("ffiTestPtrPtrLenU16",
                                  "ffiTestPtrPtrLenU16",
                                  cast[pointer](ffiTestPtrPtrLenU16), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UInt16")))
      scope.define("ptr-ptr-len-ushort",
                   newFfiCallable("ffiTestPtrPtrLenUShort",
                                  "ffiTestPtrPtrLenUShort",
                                  cast[pointer](ffiTestPtrPtrLenUShort), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UShort")))
      scope.define("ptr-ptr-len-u8",
                   newFfiCallable("ffiTestPtrPtrLenU8",
                                  "ffiTestPtrPtrLenU8",
                                  cast[pointer](ffiTestPtrPtrLenU8), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UInt8")))
      scope.define("ptr-ptr-len-uchar",
                   newFfiCallable("ffiTestPtrPtrLenUChar",
                                  "ffiTestPtrPtrLenUChar",
                                  cast[pointer](ffiTestPtrPtrLenUChar), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UChar")))
      scope.define("ptr-ptr-len-diff",
                   newFfiCallable("ffiTestPtrPtrLenDiff",
                                  "ffiTestPtrPtrLenDiff",
                                  cast[pointer](ffiTestPtrPtrLenDiff), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/PtrDiff")))
      scope.define("ptr-ptr-len-double",
                   newFfiCallable("ffiTestPtrPtrLenDouble",
                                  "ffiTestPtrPtrLenDouble",
                                  cast[pointer](ffiTestPtrPtrLenDouble), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Double")))
      scope.define("ptr-ptr-has-len?",
                   newFfiCallable("ffiTestPtrPtrHasLen",
                                  "ffiTestPtrPtrHasLen",
                                  cast[pointer](ffiTestPtrPtrHasLen), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/NullableConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/Bool")))
      var bytes = [uint8(65), uint8(66), uint8(67)]
      scope.define("byte-slice",
                   newCSlice(cast[pointer](addr bytes[0]), bytes.len,
                             newSym("C/UInt8")))
      scope.define("empty-byte-slice",
                   newCSlice(nil, 0, newSym("C/UInt8")))
      scope.define("wrong-byte-slice",
                   newCSlice(cast[pointer](addr bytes[0]), bytes.len,
                             newSym("C/Int32")))
      scope.define("bad-byte-slice",
                   newCSlice(nil, bytes.len, newSym("C/UInt8")))
      scope.define("byte-buffer",
                   newBuffer(newSym("C/UInt8"),
                             @[newInt(65), newInt(66), newInt(67)]))
      scope.define("empty-byte-buffer",
                   newBuffer(newSym("C/UInt8"), @[]))
      scope.define("char-buffer",
                   newBuffer(newSym("C/Char"), @[newInt(65)]))
      scope.define("uchar-buffer",
                   newBuffer(newSym("C/UChar"), @[newInt(65)]))
      scope.define("i8-buffer",
                   newBuffer(newSym("C/Int8"), @[newInt(-1)]))
      scope.define("wrong-byte-buffer",
                   newBuffer(newSym("C/Int32"), @[newInt(65)]))
      scope.define("bad-byte-buffer",
                   newBuffer(newSym("C/UInt8"), @[newInt(300)]))
      var copySrc = [uint8(68), uint8(69), uint8(70)]
      var copyDst = [uint8(0), uint8(0), uint8(0)]
      scope.define("copy-src",
                   newCConstPtr(cast[pointer](addr copySrc[0]),
                                newSym("C/Char")))
      scope.define("copy-dst",
                   newCPtr(cast[pointer](addr copyDst[0]),
                           newSym("C/Char")))
      check run(compileSource("(i16-abs -9)"), scope).print() == "9"
      expect GeneError:
        discard run(compileSource("(i16-abs 32768)"), scope)
      check run(compileSource("(u16-inc 41)"), scope).print() == "42"
      expect GeneError:
        discard run(compileSource("(u16-inc -1)"), scope)
      expect GeneError:
        discard run(compileSource("(u16-inc 65536)"), scope)
      check run(compileSource("(short-abs -9)"), scope).print() == "9"
      expect GeneError:
        discard run(compileSource("(short-abs 32768)"), scope)
      check run(compileSource("(short-i8 4)"), scope).print() == "12"
      check run(compileSource("(short-char 5)"), scope).print() == "'F'"
      check run(compileSource("(short-ulong -4)"), scope).print() == "6"
      check run(compileSource("(short-u8 4)"), scope).print() == "16"
      check run(compileSource("(short-uchar 4)"), scope).print() == "17"
      check run(compileSource("(short-u64 -4)"), scope).print() == "8"
      check run(compileSource("(short-diff 4)"), scope).print() == "-2"
      check run(compileSource("(short-positive? 4)"), scope).print() == "true"
      check run(compileSource("(short-positive? -1)"), scope).print() ==
        "false"
      check run(compileSource("(ushort-inc 41)"), scope).print() == "42"
      expect GeneError:
        discard run(compileSource("(ushort-inc -1)"), scope)
      expect GeneError:
        discard run(compileSource("(ushort-inc 65536)"), scope)
      check run(compileSource("(ushort-i8 4)"), scope).print() == "12"
      check run(compileSource("(ushort-ulong 4)"), scope).print() == "6"
      check run(compileSource("(ushort-u8 4)"), scope).print() == "16"
      check run(compileSource("(ushort-char 5)"), scope).print() == "'F'"
      check run(compileSource("(ushort-uchar 4)"), scope).print() == "17"
      check run(compileSource("(ushort-u64 4)"), scope).print() == "8"
      check run(compileSource("(ushort-diff 4)"), scope).print() == "-2"
      check run(compileSource("(ushort-non-zero? 4)"), scope).print() ==
        "true"
      check run(compileSource("(ushort-non-zero? 0)"), scope).print() ==
        "false"
      check run(compileSource("(i8-abs -9)"), scope).print() == "9"
      expect GeneError:
        discard run(compileSource("(i8-abs 128)"), scope)
      check run(compileSource("(i8-short 4)"), scope).print() == "11"
      check run(compileSource("(i8-char 5)"), scope).print() == "'F'"
      check run(compileSource("(i8-ulong -4)"), scope).print() == "6"
      check run(compileSource("(i8-ushort 4)"), scope).print() == "15"
      check run(compileSource("(i8-uchar 4)"), scope).print() == "17"
      check run(compileSource("(i8-u64 -4)"), scope).print() == "8"
      check run(compileSource("(i8-diff 4)"), scope).print() == "-2"
      check run(compileSource("(i8-positive? 4)"), scope).print() == "true"
      check run(compileSource("(i8-positive? -1)"), scope).print() == "false"
      check run(compileSource("(u8-inc 41)"), scope).print() == "42"
      expect GeneError:
        discard run(compileSource("(u8-inc -1)"), scope)
      expect GeneError:
        discard run(compileSource("(u8-inc 256)"), scope)
      check run(compileSource("(u8-short 4)"), scope).print() == "11"
      check run(compileSource("(u8-ulong 4)"), scope).print() == "6"
      check run(compileSource("(u8-ushort 4)"), scope).print() == "15"
      check run(compileSource("(u8-char 5)"), scope).print() == "'F'"
      check run(compileSource("(u8-uchar 4)"), scope).print() == "17"
      check run(compileSource("(u8-u64 4)"), scope).print() == "8"
      check run(compileSource("(u8-diff 4)"), scope).print() == "-2"
      check run(compileSource("(u8-non-zero? 4)"), scope).print() == "true"
      check run(compileSource("(u8-non-zero? 0)"), scope).print() == "false"
      check run(compileSource("(char-next 'A')"), scope).print() == "'B'"
      expect GeneError:
        discard run(compileSource("(char-next 128)"), scope)
      check run(compileSource("(char-i32 'A')"), scope).print() == "70"
      check run(compileSource("(char-i16 'A')"), scope).print() == "71"
      check run(compileSource("(char-short 'A')"), scope).print() == "72"
      check run(compileSource("(char-i8 'A')"), scope).print() == "5"
      check run(compileSource("(char-ulong 'A')"), scope).print() == "67"
      check run(compileSource("(char-u32 'A')"), scope).print() == "73"
      check run(compileSource("(char-u16 'A')"), scope).print() == "74"
      check run(compileSource("(char-ushort 'A')"), scope).print() == "75"
      check run(compileSource("(char-u8 'A')"), scope).print() == "76"
      check run(compileSource("(char-i64 'A')"), scope).print() == "68"
      check run(compileSource("(char-u64 'A')"), scope).print() == "69"
      check run(compileSource("(char-diff 'A')"), scope).print() == "-1"
      check run(compileSource("(uchar-inc 41)"), scope).print() == "42"
      check run(compileSource("(uchar-inc 'A')"), scope).print() == "66"
      expect GeneError:
        discard run(compileSource("(uchar-inc -1)"), scope)
      expect GeneError:
        discard run(compileSource("(uchar-inc 256)"), scope)
      check run(compileSource("(uchar-i32 'A')"), scope).print() == "70"
      check run(compileSource("(uchar-i16 'A')"), scope).print() == "71"
      check run(compileSource("(uchar-short 'A')"), scope).print() == "72"
      check run(compileSource("(uchar-i8 'A')"), scope).print() == "5"
      check run(compileSource("(uchar-ulong 'A')"), scope).print() == "67"
      check run(compileSource("(uchar-u32 'A')"), scope).print() == "73"
      check run(compileSource("(uchar-u16 'A')"), scope).print() == "74"
      check run(compileSource("(uchar-ushort 'A')"), scope).print() == "75"
      check run(compileSource("(uchar-u8 'A')"), scope).print() == "76"
      check run(compileSource("(uchar-i64 'A')"), scope).print() == "68"
      check run(compileSource("(uchar-u64 'A')"), scope).print() == "69"
      check run(compileSource("(uchar-diff 'A')"), scope).print() == "-1"
      check run(compileSource("(bool-not true)"), scope).print() == "false"
      check run(compileSource("(bool-not false)"), scope).print() == "true"
      expect GeneError:
        discard run(compileSource("(bool-not 1)"), scope)
      check run(compileSource("(bool-ulong true)"), scope).print() == "7"
      check run(compileSource("(bool-ulong false)"), scope).print() == "2"
      check run(compileSource("(bool-i32 true)"), scope).print() == "8"
      check run(compileSource("(bool-i32 false)"), scope).print() == "-3"
      check run(compileSource("(bool-i16 true)"), scope).print() == "9"
      check run(compileSource("(bool-i16 false)"), scope).print() == "-4"
      check run(compileSource("(bool-short true)"), scope).print() == "10"
      check run(compileSource("(bool-short false)"), scope).print() == "-5"
      check run(compileSource("(bool-i8 true)"), scope).print() == "11"
      check run(compileSource("(bool-i8 false)"), scope).print() == "-6"
      check run(compileSource("(bool-char true)"), scope).print() == "'T'"
      check run(compileSource("(bool-char false)"), scope).print() == "'F'"
      check run(compileSource("(bool-u32 true)"), scope).print() == "12"
      check run(compileSource("(bool-u32 false)"), scope).print() == "4"
      check run(compileSource("(bool-u16 true)"), scope).print() == "13"
      check run(compileSource("(bool-u16 false)"), scope).print() == "5"
      check run(compileSource("(bool-ushort true)"), scope).print() == "14"
      check run(compileSource("(bool-ushort false)"), scope).print() == "6"
      check run(compileSource("(bool-u8 true)"), scope).print() == "15"
      check run(compileSource("(bool-u8 false)"), scope).print() == "7"
      check run(compileSource("(bool-uchar true)"), scope).print() == "89"
      check run(compileSource("(bool-uchar false)"), scope).print() == "78"
      check run(compileSource("(bool-i64 true)"), scope).print() == "8"
      check run(compileSource("(bool-i64 false)"), scope).print() == "-3"
      check run(compileSource("(bool-u64 true)"), scope).print() == "9"
      check run(compileSource("(bool-u64 false)"), scope).print() == "4"
      check run(compileSource("(bool-diff true)"), scope).print() == "5"
      check run(compileSource("(bool-diff false)"), scope).print() == "-5"
      check run(compileSource("(u64-inc 41)"), scope).print() == "42"
      check run(compileSource("(u64-i32 4)"), scope).print() == "9"
      check run(compileSource("(u64-i16 4)"), scope).print() == "10"
      check run(compileSource("(u64-short 4)"), scope).print() == "11"
      check run(compileSource("(u64-i8 4)"), scope).print() == "12"
      check run(compileSource("(u64-char 5)"), scope).print() == "'F'"
      check run(compileSource("(u64-u32 4)"), scope).print() == "13"
      check run(compileSource("(u64-u16 4)"), scope).print() == "14"
      check run(compileSource("(u64-ushort 4)"), scope).print() == "15"
      check run(compileSource("(u64-u8 4)"), scope).print() == "16"
      check run(compileSource("(u64-uchar 4)"), scope).print() == "17"
      check run(compileSource("(u64-inc 9223372036854775808)"),
                scope).print() == "9223372036854775809"
      expect GeneError:
        discard run(compileSource("(u64-inc -1)"), scope)
      expect GeneError:
        discard run(compileSource("(u64-inc 18446744073709551616)"), scope)
      check run(compileSource("(ulong-inc 41)"), scope).print() == "42"
      check run(compileSource("(ulong-i32 4)"), scope).print() == "9"
      check run(compileSource("(ulong-i16 4)"), scope).print() == "10"
      check run(compileSource("(ulong-short 4)"), scope).print() == "11"
      check run(compileSource("(ulong-i8 4)"), scope).print() == "12"
      check run(compileSource("(ulong-char 5)"), scope).print() == "'F'"
      check run(compileSource("(ulong-u32 4)"), scope).print() == "13"
      check run(compileSource("(ulong-u16 4)"), scope).print() == "14"
      check run(compileSource("(ulong-ushort 4)"), scope).print() == "15"
      check run(compileSource("(ulong-u8 4)"), scope).print() == "16"
      check run(compileSource("(ulong-uchar 4)"), scope).print() == "17"
      when sizeof(culong) == 8:
        check run(compileSource("(ulong-inc 9223372036854775808)"),
                  scope).print() == "9223372036854775809"
      expect GeneError:
        discard run(compileSource("(ulong-inc -1)"), scope)
      check run(compileSource("(ptrdiff-abs -9)"), scope).print() == "9"
      check run(compileSource("(ptrdiff-i32 4)"), scope).print() == "9"
      check run(compileSource("(ptrdiff-i16 4)"), scope).print() == "10"
      check run(compileSource("(ptrdiff-short 4)"), scope).print() == "11"
      check run(compileSource("(ptrdiff-i8 4)"), scope).print() == "12"
      check run(compileSource("(ptrdiff-char 5)"), scope).print() == "'F'"
      check run(compileSource("(ptrdiff-u32 4)"), scope).print() == "13"
      check run(compileSource("(ptrdiff-u16 4)"), scope).print() == "14"
      check run(compileSource("(ptrdiff-ushort 4)"), scope).print() == "15"
      check run(compileSource("(ptrdiff-u8 4)"), scope).print() == "16"
      check run(compileSource("(ptrdiff-uchar 4)"), scope).print() == "17"
      expect GeneError:
        discard run(compileSource("(ptrdiff-abs 9223372036854775808)"),
                    scope)
      check run(compileSource("(size-inc 41)"), scope).print() == "42"
      check run(compileSource("(size-i32 4)"), scope).print() == "9"
      check run(compileSource("(size-i16 4)"), scope).print() == "10"
      check run(compileSource("(size-short 4)"), scope).print() == "11"
      check run(compileSource("(size-i8 4)"), scope).print() == "12"
      check run(compileSource("(size-char 5)"), scope).print() == "'F'"
      check run(compileSource("(size-u32 4)"), scope).print() == "13"
      check run(compileSource("(size-u16 4)"), scope).print() == "14"
      check run(compileSource("(size-ushort 4)"), scope).print() == "15"
      check run(compileSource("(size-u8 4)"), scope).print() == "16"
      check run(compileSource("(size-uchar 4)"), scope).print() == "17"
      check run(compileSource("(size-ulong 4)"), scope).print() == "6"
      check run(compileSource("(size-i64 4)"), scope).print() == "7"
      check run(compileSource("(size-u64 4)"), scope).print() == "8"
      check run(compileSource("(size-unary-diff 4)"), scope).print() == "-2"
      check run(compileSource("(size-non-zero? 4)"), scope).print() == "true"
      check run(compileSource("(size-non-zero? 0)"), scope).print() == "false"
      check run(compileSource("(int-ulong 4)"), scope).print() == "6"
      check run(compileSource("(int-i32 4)"), scope).print() == "9"
      check run(compileSource("(int-i16 4)"), scope).print() == "10"
      check run(compileSource("(int-short 4)"), scope).print() == "11"
      check run(compileSource("(int-i8 4)"), scope).print() == "12"
      check run(compileSource("(int-char 5)"), scope).print() == "'F'"
      check run(compileSource("(int-u32 4)"), scope).print() == "13"
      check run(compileSource("(int-u16 4)"), scope).print() == "14"
      check run(compileSource("(int-ushort 4)"), scope).print() == "15"
      check run(compileSource("(int-u8 4)"), scope).print() == "16"
      check run(compileSource("(int-uchar 4)"), scope).print() == "17"
      check run(compileSource("(int-i64 4)"), scope).print() == "7"
      check run(compileSource("(int-u64 4)"), scope).print() == "8"
      check run(compileSource("(int-unary-diff 4)"), scope).print() == "-2"
      check run(compileSource("(int-positive? 4)"), scope).print() == "true"
      check run(compileSource("(int-positive? -1)"), scope).print() == "false"
      check run(compileSource("(int-ptr 4)"), scope).print() == "(c_ptr)"
      check run(compileSource("(int-ptr 0)"), scope).print() ==
        "(c_ptr null)"
      check run(compileSource("(long-ulong 4)"), scope).print() == "6"
      check run(compileSource("(long-i32 4)"), scope).print() == "9"
      check run(compileSource("(long-i16 4)"), scope).print() == "10"
      check run(compileSource("(long-short 4)"), scope).print() == "11"
      check run(compileSource("(long-i8 4)"), scope).print() == "12"
      check run(compileSource("(long-char 5)"), scope).print() == "'F'"
      check run(compileSource("(long-u32 4)"), scope).print() == "13"
      check run(compileSource("(long-u16 4)"), scope).print() == "14"
      check run(compileSource("(long-ushort 4)"), scope).print() == "15"
      check run(compileSource("(long-u8 4)"), scope).print() == "16"
      check run(compileSource("(long-uchar 4)"), scope).print() == "17"
      check run(compileSource("(long-i64 4)"), scope).print() == "7"
      check run(compileSource("(long-u64 4)"), scope).print() == "8"
      check run(compileSource("(long-diff 4)"), scope).print() == "-2"
      check run(compileSource("(long-positive? 4)"), scope).print() == "true"
      check run(compileSource("(long-positive? -1)"), scope).print() == "false"
      check run(compileSource("(i64-ulong 4)"), scope).print() == "6"
      check run(compileSource("(i64-i32 4)"), scope).print() == "9"
      check run(compileSource("(i64-i16 4)"), scope).print() == "10"
      check run(compileSource("(i64-short 4)"), scope).print() == "11"
      check run(compileSource("(i64-i8 4)"), scope).print() == "12"
      check run(compileSource("(i64-char 5)"), scope).print() == "'F'"
      check run(compileSource("(i64-u32 4)"), scope).print() == "13"
      check run(compileSource("(i64-u16 4)"), scope).print() == "14"
      check run(compileSource("(i64-ushort 4)"), scope).print() == "15"
      check run(compileSource("(i64-u8 4)"), scope).print() == "16"
      check run(compileSource("(i64-uchar 4)"), scope).print() == "17"
      check run(compileSource("(i64-u64 4)"), scope).print() == "8"
      check run(compileSource("(i64-diff 4)"), scope).print() == "-2"
      check run(compileSource("(i64-positive? 4)"), scope).print() == "true"
      check run(compileSource("(i64-positive? -1)"), scope).print() == "false"
      check run(compileSource("(uint-ulong 4)"), scope).print() == "6"
      check run(compileSource("(uint-i32 4)"), scope).print() == "9"
      check run(compileSource("(uint-i16 4)"), scope).print() == "10"
      check run(compileSource("(uint-short 4)"), scope).print() == "11"
      check run(compileSource("(uint-i8 4)"), scope).print() == "12"
      check run(compileSource("(uint-char 5)"), scope).print() == "'F'"
      check run(compileSource("(uint-u32 4)"), scope).print() == "13"
      check run(compileSource("(uint-u16 4)"), scope).print() == "14"
      check run(compileSource("(uint-ushort 4)"), scope).print() == "15"
      check run(compileSource("(uint-u8 4)"), scope).print() == "16"
      check run(compileSource("(uint-uchar 4)"), scope).print() == "17"
      check run(compileSource("(uint-i64 4)"), scope).print() == "7"
      check run(compileSource("(uint-u64 4)"), scope).print() == "8"
      check run(compileSource("(uint-diff 4)"), scope).print() == "-2"
      check run(compileSource("(uint-non-zero? 4)"), scope).print() == "true"
      check run(compileSource("(uint-non-zero? 0)"), scope).print() == "false"
      check run(compileSource("(u32-ulong 4)"), scope).print() == "6"
      check run(compileSource("(u32-i16 4)"), scope).print() == "10"
      check run(compileSource("(u32-short 4)"), scope).print() == "11"
      check run(compileSource("(u32-i8 4)"), scope).print() == "12"
      check run(compileSource("(u32-char 5)"), scope).print() == "'F'"
      check run(compileSource("(u32-u16 4)"), scope).print() == "14"
      check run(compileSource("(u32-ushort 4)"), scope).print() == "15"
      check run(compileSource("(u32-u8 4)"), scope).print() == "16"
      check run(compileSource("(u32-uchar 4)"), scope).print() == "17"
      check run(compileSource("(u32-u64 4)"), scope).print() == "8"
      check run(compileSource("(u32-diff 4)"), scope).print() == "-2"
      check run(compileSource("(u32-non-zero? 4)"), scope).print() == "true"
      check run(compileSource("(u32-non-zero? 0)"), scope).print() == "false"
      check run(compileSource("(i32-ulong 4)"), scope).print() == "6"
      check run(compileSource("(i32-i16 4)"), scope).print() == "10"
      check run(compileSource("(i32-short 4)"), scope).print() == "11"
      check run(compileSource("(i32-i8 4)"), scope).print() == "12"
      check run(compileSource("(i32-char 5)"), scope).print() == "'F'"
      check run(compileSource("(i32-u32 4)"), scope).print() == "13"
      check run(compileSource("(i32-u16 4)"), scope).print() == "14"
      check run(compileSource("(i32-ushort 4)"), scope).print() == "15"
      check run(compileSource("(i32-u8 4)"), scope).print() == "16"
      check run(compileSource("(i32-uchar 4)"), scope).print() == "17"
      check run(compileSource("(i32-u64 4)"), scope).print() == "8"
      check run(compileSource("(i32-diff 4)"), scope).print() == "-2"
      check run(compileSource("(i32-positive? 4)"), scope).print() == "true"
      check run(compileSource("(i32-positive? -1)"), scope).print() ==
        "false"
      check run(compileSource("(i16-ulong 4)"), scope).print() == "6"
      check run(compileSource("(i16-short 4)"), scope).print() == "11"
      check run(compileSource("(i16-i8 4)"), scope).print() == "12"
      check run(compileSource("(i16-char 5)"), scope).print() == "'F'"
      check run(compileSource("(i16-u16 4)"), scope).print() == "14"
      check run(compileSource("(i16-ushort 4)"), scope).print() == "15"
      check run(compileSource("(i16-u8 4)"), scope).print() == "16"
      check run(compileSource("(i16-uchar 4)"), scope).print() == "17"
      check run(compileSource("(i16-u64 4)"), scope).print() == "8"
      check run(compileSource("(i16-diff 4)"), scope).print() == "-2"
      check run(compileSource("(i16-positive? 4)"), scope).print() == "true"
      check run(compileSource("(i16-positive? -1)"), scope).print() ==
        "false"
      check run(compileSource("(u16-ulong 4)"), scope).print() == "6"
      check run(compileSource("(u16-short 4)"), scope).print() == "11"
      check run(compileSource("(u16-i8 4)"), scope).print() == "12"
      check run(compileSource("(u16-char 5)"), scope).print() == "'F'"
      check run(compileSource("(u16-ushort 4)"), scope).print() == "15"
      check run(compileSource("(u16-u8 4)"), scope).print() == "16"
      check run(compileSource("(u16-uchar 4)"), scope).print() == "17"
      check run(compileSource("(u16-u64 4)"), scope).print() == "8"
      check run(compileSource("(u16-diff 4)"), scope).print() == "-2"
      check run(compileSource("(u16-non-zero? 4)"), scope).print() == "true"
      check run(compileSource("(u16-non-zero? 0)"), scope).print() == "false"
      check run(compileSource("(double-ulong 4.5)"), scope).print() == "6"
      check run(compileSource("(double-i32 4.5)"), scope).print() == "9"
      check run(compileSource("(double-i16 4.5)"), scope).print() == "10"
      check run(compileSource("(double-short 4.5)"), scope).print() == "11"
      check run(compileSource("(double-i8 4.5)"), scope).print() == "12"
      check run(compileSource("(double-char 5.5)"), scope).print() == "'F'"
      check run(compileSource("(double-u32 4.5)"), scope).print() == "13"
      check run(compileSource("(double-u16 4.5)"), scope).print() == "14"
      check run(compileSource("(double-ushort 4.5)"), scope).print() == "15"
      check run(compileSource("(double-u8 4.5)"), scope).print() == "16"
      check run(compileSource("(double-uchar 4.5)"), scope).print() == "17"
      check run(compileSource("(double-i64 4.5)"), scope).print() == "7"
      check run(compileSource("(double-u64 4.5)"), scope).print() == "8"
      check run(compileSource("(double-diff 4.5)"), scope).print() == "-2"
      check run(compileSource("(double-positive? 4.5)"),
                scope).print() == "true"
      check run(compileSource("(double-positive? -1.5)"),
                scope).print() == "false"
      let doubleKind = run(compileSource("(double-kind 4.5)"), scope)
      check doubleKind.kind == vkString
      check doubleKind.strVal == "positive-double"
      check run(compileSource("(double-ptr 4.5)"), scope).print() ==
        "(c_ptr)"
      check run(compileSource("(double-ptr -1.5)"), scope).print() ==
        "(c_ptr null)"
      check run(compileSource("(float-ulong 4.5)"), scope).print() == "6"
      check run(compileSource("(float-i32 4.5)"), scope).print() == "9"
      check run(compileSource("(float-i16 4.5)"), scope).print() == "10"
      check run(compileSource("(float-short 4.5)"), scope).print() == "11"
      check run(compileSource("(float-i8 4.5)"), scope).print() == "12"
      check run(compileSource("(float-char 5.5)"), scope).print() == "'F'"
      check run(compileSource("(float-u32 4.5)"), scope).print() == "13"
      check run(compileSource("(float-u16 4.5)"), scope).print() == "14"
      check run(compileSource("(float-ushort 4.5)"), scope).print() == "15"
      check run(compileSource("(float-u8 4.5)"), scope).print() == "16"
      check run(compileSource("(float-uchar 4.5)"), scope).print() == "17"
      check run(compileSource("(float-i64 4.5)"), scope).print() == "7"
      check run(compileSource("(float-u64 4.5)"), scope).print() == "8"
      check run(compileSource("(float-diff 4.5)"), scope).print() == "-2"
      check run(compileSource("(float-positive? 4.5)"),
                scope).print() == "true"
      check run(compileSource("(float-positive? -1.5)"),
                scope).print() == "false"
      let floatKind = run(compileSource("(float-kind 4.5)"), scope)
      check floatKind.kind == vkString
      check floatKind.strVal == "positive-float"
      check run(compileSource("(float-ptr 4.5)"), scope).print() ==
        "(c_ptr)"
      check run(compileSource("(float-ptr -1.5)"), scope).print() ==
        "(c_ptr null)"
      check run(compileSource("(size-add-uint 20 22)"), scope).print() == "43"
      check run(compileSource("(size-add-i32 20 22)"), scope).print() == "47"
      check run(compileSource("(size-add-i16 20 22)"), scope).print() == "48"
      check run(compileSource("(size-add-short 20 22)"), scope).print() == "49"
      check run(compileSource("(size-add-i8 20 22)"), scope).print() == "50"
      check run(compileSource("(size-add-char 2 3)"), scope).print() == "'F'"
      check run(compileSource("(size-diff-long 20 22)"), scope).print() == "-2"
      check run(compileSource("(size-add-ulong 20 22)"), scope).print() == "44"
      check run(compileSource("(size-add-u32 20 22)"), scope).print() == "51"
      check run(compileSource("(size-add-u16 20 22)"), scope).print() == "52"
      check run(compileSource("(size-add-ushort 20 22)"), scope).print() == "53"
      check run(compileSource("(size-add-u8 20 22)"), scope).print() == "54"
      check run(compileSource("(size-add-uchar 20 22)"), scope).print() == "55"
      check run(compileSource("(size-add-i64 20 22)"), scope).print() == "45"
      check run(compileSource("(size-add-u64 20 22)"), scope).print() == "46"
      check run(compileSource("(size-diff-ptrdiff 20 22)"),
                scope).print() == "-2"
      check run(compileSource("(size-add-float 20 22)"),
                scope).print() == "42.25"
      check run(compileSource("(size-add-double 20 22)"),
                scope).print() == "42.5"
      check run(compileSource("(size-equal? 20 20)"), scope).print() == "true"
      check run(compileSource("(size-equal? 20 22)"), scope).print() == "false"
      when sizeof(csize_t) == 8:
        check run(compileSource("(size-inc 9223372036854775808)"),
                  scope).print() == "9223372036854775809"
      expect GeneError:
        discard run(compileSource("(size-inc -1)"), scope)
      when sizeof(csize_t) < 8:
        expect GeneError:
          discard run(compileSource("(size-inc 4294967296)"), scope)
      check run(compileSource("(int_add 20 22)"), scope).print() == "42"
      check run(compileSource("(int-add-uint 20 22)"), scope).print() == "43"
      check run(compileSource("(int-add-i32 20 22)"), scope).print() == "47"
      check run(compileSource("(int-add-i16 20 22)"), scope).print() == "48"
      check run(compileSource("(int-add-short 20 22)"), scope).print() == "49"
      check run(compileSource("(int-add-i8 20 22)"), scope).print() == "50"
      check run(compileSource("(int-add-char 2 3)"), scope).print() == "'F'"
      check run(compileSource("(int-diff-long 20 22)"), scope).print() == "-2"
      check run(compileSource("(int-add-ulong 20 22)"), scope).print() == "44"
      check run(compileSource("(int-add-u32 20 22)"), scope).print() == "51"
      check run(compileSource("(int-add-u16 20 22)"), scope).print() == "52"
      check run(compileSource("(int-add-ushort 20 22)"), scope).print() == "53"
      check run(compileSource("(int-add-u8 20 22)"), scope).print() == "54"
      check run(compileSource("(int-add-uchar 20 22)"), scope).print() == "55"
      check run(compileSource("(int-add-i64 20 22)"), scope).print() == "45"
      check run(compileSource("(int-add-u64 20 22)"), scope).print() == "46"
      check run(compileSource("(int-diff-ptrdiff 20 22)"),
                scope).print() == "-2"
      check run(compileSource("(int-add-float 20 22)"),
                scope).print() == "42.25"
      check run(compileSource("(int-add-double 20 22)"),
                scope).print() == "42.5"
      let intPairKind = run(compileSource("(int-pair-kind 2 -1)"), scope)
      check intPairKind.kind == vkString
      check intPairKind.strVal == "nonnegative-int-pair"
      let negativeIntPairKind =
        run(compileSource("(int-pair-kind -3 1)"), scope)
      check negativeIntPairKind.kind == vkString
      check negativeIntPairKind.strVal == "negative-int-pair"
      expect GeneError:
        discard run(compileSource("(int_add 1 2147483648)"), scope)
      check run(compileSource("(double-add 1.25 2.5)"), scope).print() == "3.75"
      check run(compileSource("(double-double-uint 1.25 2.5)"),
                scope).print() == "4"
      check run(compileSource("(double-double-i32 1.25 2.5)"),
                scope).print() == "8"
      check run(compileSource("(double-double-i16 1.25 2.5)"),
                scope).print() == "9"
      check run(compileSource("(double-double-short 1.25 2.5)"),
                scope).print() == "10"
      check run(compileSource("(double-double-i8 1.25 2.5)"),
                scope).print() == "11"
      check run(compileSource("(double-double-char 1.25 2.5)"),
                scope).print() == "'D'"
      check run(compileSource("(double-double-ulong 1.25 2.5)"),
                scope).print() == "5"
      check run(compileSource("(double-double-u32 1.25 2.5)"),
                scope).print() == "12"
      check run(compileSource("(double-double-u16 1.25 2.5)"),
                scope).print() == "13"
      check run(compileSource("(double-double-ushort 1.25 2.5)"),
                scope).print() == "14"
      check run(compileSource("(double-double-u8 1.25 2.5)"),
                scope).print() == "15"
      check run(compileSource("(double-double-uchar 1.25 2.5)"),
                scope).print() == "16"
      check run(compileSource("(double-double-i64 1.25 2.5)"),
                scope).print() == "6"
      check run(compileSource("(double-double-u64 1.25 2.5)"),
                scope).print() == "7"
      check run(compileSource("(double-double-diff 1.25 3.5)"),
                scope).print() == "-2"
      let doubleDoubleKind =
        run(compileSource("(double-double-kind 1.25 2.5)"), scope)
      check doubleDoubleKind.kind == vkString
      check doubleDoubleKind.strVal == "nonnegative-double-pair"
      expect GeneError:
        discard run(compileSource("(double-add 1 2.5)"), scope)
      check run(compileSource("(double-scale 1.5 3)"), scope).print() == "4.5"
      check run(compileSource("(double-int-uint 1.5 3)"),
                scope).print() == "5"
      check run(compileSource("(double-int-i32 1.5 3)"),
                scope).print() == "9"
      check run(compileSource("(double-int-i16 1.5 3)"),
                scope).print() == "10"
      check run(compileSource("(double-int-short 1.5 3)"),
                scope).print() == "11"
      check run(compileSource("(double-int-i8 1.5 3)"),
                scope).print() == "12"
      check run(compileSource("(double-int-char 1.5 3)"),
                scope).print() == "'E'"
      check run(compileSource("(double-int-ulong 1.5 3)"),
                scope).print() == "6"
      check run(compileSource("(double-int-u32 1.5 3)"),
                scope).print() == "13"
      check run(compileSource("(double-int-u16 1.5 3)"),
                scope).print() == "14"
      check run(compileSource("(double-int-ushort 1.5 3)"),
                scope).print() == "15"
      check run(compileSource("(double-int-u8 1.5 3)"),
                scope).print() == "16"
      check run(compileSource("(double-int-uchar 1.5 3)"),
                scope).print() == "17"
      check run(compileSource("(double-int-i64 1.5 3)"),
                scope).print() == "7"
      check run(compileSource("(double-int-u64 1.5 3)"),
                scope).print() == "8"
      check run(compileSource("(double-int-diff 1.5 3)"),
                scope).print() == "-2"
      let doubleIntKind = run(compileSource("(double-int-kind 1.5 3)"), scope)
      check doubleIntKind.kind == vkString
      check doubleIntKind.strVal == "nonnegative-double-int"
      expect GeneError:
        discard run(compileSource("(double-scale 1.5 3.0)"), scope)
      check run(compileSource("(int-offset 4 0.5)"), scope).print() == "4.5"
      check run(compileSource("(int-double-uint 4 2.5)"),
                scope).print() == "7"
      check run(compileSource("(int-double-i32 4 2.5)"),
                scope).print() == "11"
      check run(compileSource("(int-double-i16 4 2.5)"),
                scope).print() == "12"
      check run(compileSource("(int-double-short 4 2.5)"),
                scope).print() == "13"
      check run(compileSource("(int-double-i8 4 2.5)"),
                scope).print() == "14"
      check run(compileSource("(int-double-char 4 2.5)"),
                scope).print() == "'G'"
      check run(compileSource("(int-double-ulong 4 2.5)"),
                scope).print() == "8"
      check run(compileSource("(int-double-u32 4 2.5)"),
                scope).print() == "15"
      check run(compileSource("(int-double-u16 4 2.5)"),
                scope).print() == "16"
      check run(compileSource("(int-double-ushort 4 2.5)"),
                scope).print() == "17"
      check run(compileSource("(int-double-u8 4 2.5)"),
                scope).print() == "18"
      check run(compileSource("(int-double-uchar 4 2.5)"),
                scope).print() == "19"
      check run(compileSource("(int-double-i64 4 2.5)"),
                scope).print() == "9"
      check run(compileSource("(int-double-u64 4 2.5)"),
                scope).print() == "10"
      check run(compileSource("(int-double-diff 4 6.5)"),
                scope).print() == "-2"
      let intDoubleKind =
        run(compileSource("(int-double-kind 4 2.5)"), scope)
      check intDoubleKind.kind == vkString
      check intDoubleKind.strVal == "nonnegative-int-double"
      expect GeneError:
        discard run(compileSource("(int-offset 4.0 0.5)"), scope)
      check run(compileSource("(float-add 1.25 2.5)"), scope).print() == "3.75"
      check run(compileSource("(float-float-uint 1.25 2.5)"),
                scope).print() == "4"
      check run(compileSource("(float-float-i32 1.25 2.5)"),
                scope).print() == "8"
      check run(compileSource("(float-float-i16 1.25 2.5)"),
                scope).print() == "9"
      check run(compileSource("(float-float-short 1.25 2.5)"),
                scope).print() == "10"
      check run(compileSource("(float-float-i8 1.25 2.5)"),
                scope).print() == "11"
      check run(compileSource("(float-float-char 1.25 2.5)"),
                scope).print() == "'D'"
      check run(compileSource("(float-float-ulong 1.25 2.5)"),
                scope).print() == "5"
      check run(compileSource("(float-float-u32 1.25 2.5)"),
                scope).print() == "12"
      check run(compileSource("(float-float-u16 1.25 2.5)"),
                scope).print() == "13"
      check run(compileSource("(float-float-ushort 1.25 2.5)"),
                scope).print() == "14"
      check run(compileSource("(float-float-u8 1.25 2.5)"),
                scope).print() == "15"
      check run(compileSource("(float-float-uchar 1.25 2.5)"),
                scope).print() == "16"
      check run(compileSource("(float-float-i64 1.25 2.5)"),
                scope).print() == "6"
      check run(compileSource("(float-float-u64 1.25 2.5)"),
                scope).print() == "7"
      check run(compileSource("(float-float-diff 1.25 3.5)"),
                scope).print() == "-2"
      let floatFloatKind =
        run(compileSource("(float-float-kind 1.25 2.5)"), scope)
      check floatFloatKind.kind == vkString
      check floatFloatKind.strVal == "nonnegative-float-pair"
      expect GeneError:
        discard run(compileSource("(float-add 1 2.5)"), scope)
      check run(compileSource("(float-scale 1.5 3)"), scope).print() == "4.5"
      check run(compileSource("(float-int-uint 1.5 3)"),
                scope).print() == "5"
      check run(compileSource("(float-int-i32 1.5 3)"),
                scope).print() == "9"
      check run(compileSource("(float-int-i16 1.5 3)"),
                scope).print() == "10"
      check run(compileSource("(float-int-short 1.5 3)"),
                scope).print() == "11"
      check run(compileSource("(float-int-i8 1.5 3)"),
                scope).print() == "12"
      check run(compileSource("(float-int-char 1.5 3)"),
                scope).print() == "'E'"
      check run(compileSource("(float-int-ulong 1.5 3)"),
                scope).print() == "6"
      check run(compileSource("(float-int-u32 1.5 3)"),
                scope).print() == "13"
      check run(compileSource("(float-int-u16 1.5 3)"),
                scope).print() == "14"
      check run(compileSource("(float-int-ushort 1.5 3)"),
                scope).print() == "15"
      check run(compileSource("(float-int-u8 1.5 3)"),
                scope).print() == "16"
      check run(compileSource("(float-int-uchar 1.5 3)"),
                scope).print() == "17"
      check run(compileSource("(float-int-i64 1.5 3)"),
                scope).print() == "7"
      check run(compileSource("(float-int-u64 1.5 3)"),
                scope).print() == "8"
      check run(compileSource("(float-int-diff 1.5 3)"),
                scope).print() == "-2"
      let floatIntKind = run(compileSource("(float-int-kind 1.5 3)"), scope)
      check floatIntKind.kind == vkString
      check floatIntKind.strVal == "nonnegative-float-int"
      expect GeneError:
        discard run(compileSource("(float-scale 1.5 3.0)"), scope)
      check run(compileSource("(int-float-offset 4 0.5)"), scope).print() == "4.5"
      check run(compileSource("(int-float-uint 4 2.5)"),
                scope).print() == "7"
      check run(compileSource("(int-float-i32 4 2.5)"),
                scope).print() == "11"
      check run(compileSource("(int-float-i16 4 2.5)"),
                scope).print() == "12"
      check run(compileSource("(int-float-short 4 2.5)"),
                scope).print() == "13"
      check run(compileSource("(int-float-i8 4 2.5)"),
                scope).print() == "14"
      check run(compileSource("(int-float-char 4 2.5)"),
                scope).print() == "'G'"
      check run(compileSource("(int-float-ulong 4 2.5)"),
                scope).print() == "8"
      check run(compileSource("(int-float-u32 4 2.5)"),
                scope).print() == "15"
      check run(compileSource("(int-float-u16 4 2.5)"),
                scope).print() == "16"
      check run(compileSource("(int-float-ushort 4 2.5)"),
                scope).print() == "17"
      check run(compileSource("(int-float-u8 4 2.5)"),
                scope).print() == "18"
      check run(compileSource("(int-float-uchar 4 2.5)"),
                scope).print() == "19"
      check run(compileSource("(int-float-i64 4 2.5)"),
                scope).print() == "9"
      check run(compileSource("(int-float-u64 4 2.5)"),
                scope).print() == "10"
      check run(compileSource("(int-float-diff 4 6.5)"),
                scope).print() == "-2"
      let intFloatKind = run(compileSource("(int-float-kind 4 2.5)"), scope)
      check intFloatKind.kind == vkString
      check intFloatKind.strVal == "nonnegative-int-float"
      expect GeneError:
        discard run(compileSource("(int-float-offset 4.0 0.5)"), scope)
      check run(compileSource("(slice-len byte-slice)"), scope).print() == "3"
      check run(compileSource("(slice-first-byte byte-slice)"),
                scope).print() == "65"
      check run(compileSource("(slice-len-i32 byte-slice)"),
                scope).print() == "8"
      check run(compileSource("(slice-len-i16 byte-slice)"),
                scope).print() == "9"
      check run(compileSource("(slice-len-short byte-slice)"),
                scope).print() == "10"
      check run(compileSource("(slice-len-i8 byte-slice)"),
                scope).print() == "11"
      check run(compileSource("(slice-len-char byte-slice)"),
                scope).print() == "'D'"
      check run(compileSource("(slice-len-u32 byte-slice)"),
                scope).print() == "12"
      check run(compileSource("(slice-len-u16 byte-slice)"),
                scope).print() == "13"
      check run(compileSource("(slice-len-ushort byte-slice)"),
                scope).print() == "14"
      check run(compileSource("(slice-len-u8 byte-slice)"),
                scope).print() == "15"
      check run(compileSource("(slice-len-uchar byte-slice)"),
                scope).print() == "16"
      check run(compileSource("(slice-len-ulong byte-slice)"),
                scope).print() == "6"
      check run(compileSource("(slice-len-i64 byte-slice)"),
                scope).print() == "5"
      check run(compileSource("(slice-len-u64 byte-slice)"),
                scope).print() == "4"
      check run(compileSource("(slice-len-diff byte-slice)"),
                scope).print() == "3"
      check run(compileSource("(slice-len-float byte-slice)"),
                scope).print() == "3.25"
      check run(compileSource("(slice-len-double byte-slice)"),
                scope).print() == "3.5"
      check run(compileSource("(slice-len empty-byte-slice)"),
                scope).print() == "0"
      check run(compileSource("(slice-first-byte empty-byte-slice)"),
                scope).print() == "-1"
      expect GeneError:
        discard run(compileSource("(slice-len wrong-byte-slice)"), scope)
      expect GeneError:
        discard run(compileSource("(slice-len bad-byte-slice)"), scope)
      check run(compileSource("(buffer-len byte-buffer)"),
                scope).print() == "3"
      check run(compileSource("(buffer-first-byte byte-buffer)"),
                scope).print() == "65"
      check run(compileSource("(buffer-fill byte-buffer) (Buffer/to_list byte-buffer)"),
                scope).print() == "[90 91 92]"
      check run(compileSource("(buffer-len-i32 byte-buffer)"),
                scope).print() == "8"
      check run(compileSource("(buffer-len-i16 byte-buffer)"),
                scope).print() == "9"
      check run(compileSource("(buffer-len-short byte-buffer)"),
                scope).print() == "10"
      check run(compileSource("(buffer-len-i8 byte-buffer)"),
                scope).print() == "11"
      check run(compileSource("(buffer-len-char byte-buffer)"),
                scope).print() == "'D'"
      check run(compileSource("(buffer-len-u32 byte-buffer)"),
                scope).print() == "12"
      check run(compileSource("(buffer-len-u16 byte-buffer)"),
                scope).print() == "13"
      check run(compileSource("(buffer-len-ushort byte-buffer)"),
                scope).print() == "14"
      check run(compileSource("(buffer-len-u8 byte-buffer)"),
                scope).print() == "15"
      check run(compileSource("(buffer-len-uchar byte-buffer)"),
                scope).print() == "16"
      check run(compileSource("(buffer-len-ulong byte-buffer)"),
                scope).print() == "6"
      check run(compileSource("(buffer-len-i64 byte-buffer)"),
                scope).print() == "5"
      check run(compileSource("(buffer-len-u64 byte-buffer)"),
                scope).print() == "4"
      check run(compileSource("(buffer-len-diff byte-buffer)"),
                scope).print() == "3"
      check run(compileSource("(buffer-len-float byte-buffer)"),
                scope).print() == "3.25"
      check run(compileSource("(buffer-len-double byte-buffer)"),
                scope).print() == "3.5"
      check run(compileSource("(char-buffer-first-byte char-buffer)"),
                scope).print() == "65"
      check run(compileSource("(uchar-buffer-first-byte uchar-buffer)"),
                scope).print() == "65"
      check run(compileSource("(i8-buffer-first-byte i8-buffer)"),
                scope).print() == "255"
      check run(compileSource("(buffer-len empty-byte-buffer)"),
                scope).print() == "0"
      check run(compileSource("(buffer-first-byte empty-byte-buffer)"),
                scope).print() == "-1"
      expect GeneError:
        discard run(compileSource("(buffer-len wrong-byte-buffer)"), scope)
      expect GeneError:
        discard run(compileSource("(buffer-len bad-byte-buffer)"), scope)
      check run(compileSource("(cstr-bounded-len \"abcdef\" 3)"),
                scope).print() == "3"
      check run(compileSource("(cstr-bounded-len \"abcdef\" 10)"),
                scope).print() == "6"
      expect GeneError:
        discard run(compileSource("(cstr-bounded-len \"abc\" -1)"), scope)
      check run(compileSource("(cstr-ptr-if-len \"abc\" 3)"), scope).print() ==
        "(c_const_ptr)"
      check run(compileSource("(cstr-ptr-if-len \"abc\" 0)"), scope).print() ==
        "(c_const_ptr null)"
      check run(compileSource("(cstr-long \"abc\")"), scope).print() == "-2"
      check run(compileSource("(cstr-i16 \"abc\")"), scope).print() == "4"
      check run(compileSource("(cstr-short \"abc\")"), scope).print() == "5"
      check run(compileSource("(cstr-i8 \"abc\")"), scope).print() == "-2"
      check run(compileSource("(cstr-first-char \"abc\")"),
                scope).print() == "'a'"
      check run(compileSource("(cstr-ulong \"abc\")"), scope).print() == "5"
      check run(compileSource("(cstr-u16 \"abc\")"), scope).print() == "6"
      check run(compileSource("(cstr-ushort \"abc\")"), scope).print() == "7"
      check run(compileSource("(cstr-u8 \"abc\")"), scope).print() == "8"
      check run(compileSource("(cstr-first-uchar \"abc\")"),
                scope).print() == "97"
      check run(compileSource("(cstr-i64 \"abc\")"), scope).print() == "6"
      check run(compileSource("(cstr-u64 \"abc\")"), scope).print() == "7"
      check run(compileSource("(cstr-diff \"abc\")"), scope).print() == "-2"
      check run(compileSource("(cstr-non-empty? \"abc\")"),
                scope).print() == "true"
      check run(compileSource("(cstr-non-empty? \"\")"),
                scope).print() == "false"
      check run(compileSource("(cstr-int-uint \"abc\" 2)"),
                scope).print() == "6"
      check run(compileSource("(cstr-int-i32 \"abc\" 2)"),
                scope).print() == "7"
      check run(compileSource("(cstr-int-i16 \"abc\" 2)"),
                scope).print() == "8"
      check run(compileSource("(cstr-int-short \"abc\" 2)"),
                scope).print() == "9"
      check run(compileSource("(cstr-int-i8 \"abc\" 2)"),
                scope).print() == "1"
      check run(compileSource("(cstr-int-char \"abc\" 2)"),
                scope).print() == "'c'"
      check run(compileSource("(cstr-int-u32 \"abc\" 2)"),
                scope).print() == "10"
      check run(compileSource("(cstr-int-u16 \"abc\" 2)"),
                scope).print() == "11"
      check run(compileSource("(cstr-int-ushort \"abc\" 2)"),
                scope).print() == "12"
      check run(compileSource("(cstr-int-u8 \"abc\" 2)"),
                scope).print() == "13"
      check run(compileSource("(cstr-int-uchar \"abc\" 2)"),
                scope).print() == "99"
      check run(compileSource("(cstr-int-long \"abc\" 5)"),
                scope).print() == "-2"
      check run(compileSource("(cstr-int-ulong \"abc\" 2)"),
                scope).print() == "7"
      check run(compileSource("(cstr-int-i64 \"abc\" 2)"),
                scope).print() == "8"
      check run(compileSource("(cstr-int-u64 \"abc\" 2)"),
                scope).print() == "9"
      check run(compileSource("(cstr-int-diff \"abc\" 5)"),
                scope).print() == "-2"
      check run(compileSource("(cstr-int-float \"abc\" 2)"),
                scope).print() == "5.25"
      check run(compileSource("(cstr-int-double \"abc\" 2)"),
                scope).print() == "5.5"
      check run(compileSource("(cstr-int-equal-len? \"abc\" 3)"),
                scope).print() == "true"
      check run(compileSource("(cstr-int-equal-len? \"abc\" 2)"),
                scope).print() == "false"
      check run(compileSource("(cstr-size-uint \"abc\" 2)"),
                scope).print() == "6"
      check run(compileSource("(cstr-size-i32 \"abc\" 2)"),
                scope).print() == "7"
      check run(compileSource("(cstr-size-i16 \"abc\" 2)"),
                scope).print() == "8"
      check run(compileSource("(cstr-size-short \"abc\" 2)"),
                scope).print() == "9"
      check run(compileSource("(cstr-size-i8 \"abc\" 2)"),
                scope).print() == "1"
      check run(compileSource("(cstr-size-char \"abc\" 2)"),
                scope).print() == "'c'"
      check run(compileSource("(cstr-size-u32 \"abc\" 2)"),
                scope).print() == "10"
      check run(compileSource("(cstr-size-u16 \"abc\" 2)"),
                scope).print() == "11"
      check run(compileSource("(cstr-size-ushort \"abc\" 2)"),
                scope).print() == "12"
      check run(compileSource("(cstr-size-u8 \"abc\" 2)"),
                scope).print() == "13"
      check run(compileSource("(cstr-size-uchar \"abc\" 2)"),
                scope).print() == "99"
      check run(compileSource("(cstr-size-long \"abc\" 5)"),
                scope).print() == "-2"
      check run(compileSource("(cstr-size-ulong \"abc\" 2)"),
                scope).print() == "7"
      check run(compileSource("(cstr-size-i64 \"abc\" 2)"),
                scope).print() == "8"
      check run(compileSource("(cstr-size-u64 \"abc\" 2)"),
                scope).print() == "9"
      check run(compileSource("(cstr-size-diff \"abc\" 5)"),
                scope).print() == "-2"
      check run(compileSource("(cstr-size-float \"abc\" 2)"),
                scope).print() == "5.25"
      check run(compileSource("(cstr-size-double \"abc\" 2)"),
                scope).print() == "5.5"
      check run(compileSource("(cstr-size-equal-len? \"abc\" 3)"),
                scope).print() == "true"
      check run(compileSource("(cstr-size-equal-len? \"abc\" 2)"),
                scope).print() == "false"
      check run(compileSource("(cstr-pair-u64 \"ab\" \"cde\")"),
                scope).print() == "5"
      check run(compileSource("(cstr-pair-i32 \"ab\" \"cde\")"),
                scope).print() == "7"
      check run(compileSource("(cstr-pair-i16 \"ab\" \"cde\")"),
                scope).print() == "8"
      check run(compileSource("(cstr-pair-short \"ab\" \"cde\")"),
                scope).print() == "9"
      check run(compileSource("(cstr-pair-i8 \"ab\" \"cde\")"),
                scope).print() == "-1"
      check run(compileSource("(cstr-pair-char \"ab\" \"cde\")"),
                scope).print() == "'d'"
      check run(compileSource("(cstr-pair-u32 \"ab\" \"cde\")"),
                scope).print() == "10"
      check run(compileSource("(cstr-pair-u16 \"ab\" \"cde\")"),
                scope).print() == "11"
      check run(compileSource("(cstr-pair-ushort \"ab\" \"cde\")"),
                scope).print() == "12"
      check run(compileSource("(cstr-pair-u8 \"ab\" \"cde\")"),
                scope).print() == "13"
      check run(compileSource("(cstr-pair-uchar \"ab\" \"cde\")"),
                scope).print() == "100"
      check run(compileSource("(cstr-pair-diff \"abc\" \"abc\")"),
                scope).print() == "0"
      check run(compileSource("(cstr-pair-diff \"abc\" \"abd\")"),
                scope).print() == "-1"
      check run(compileSource("(cstr-pair-double \"ab\" \"c\")"),
                scope).print() == "3.5"
      check run(compileSource("(cstr-pair-equal? \"abc\" \"abc\")"),
                scope).print() == "true"
      check run(compileSource("(cstr-pair-equal? \"abc\" \"abd\")"),
                scope).print() == "false"
      let copied = run(compileSource("(ptr-copy copy-dst copy-src 3)"), scope)
      check copied.kind == vkCPtr
      check copied.cPtrAddress == cast[pointer](addr copyDst[0])
      check copyDst == [uint8(68), uint8(69), uint8(70)]
      check run(compileSource("(ptr-if-len copy-dst 3)"), scope).print() ==
        "(c_ptr)"
      check run(compileSource("(ptr-if-len copy-dst 0)"), scope).print() ==
        "(c_ptr null)"
      check run(compileSource("(ptr-len copy-dst 3)"), scope).print() == "3"
      check run(compileSource("(ptr-len nil 3)"), scope).print() == "0"
      check run(compileSource("(ptr-len-i32 copy-dst 3)"),
                scope).print() == "8"
      check run(compileSource("(ptr-len-i32 nil 3)"), scope).print() == "-1"
      check run(compileSource("(ptr-len-i16 copy-dst 3)"),
                scope).print() == "9"
      check run(compileSource("(ptr-len-short copy-dst 3)"),
                scope).print() == "10"
      check run(compileSource("(ptr-len-i8 copy-dst 3)"),
                scope).print() == "11"
      check run(compileSource("(ptr-len-char copy-dst 3)"),
                scope).print() == "'D'"
      check run(compileSource("(ptr-len-u64 copy-dst 3)"), scope).print() ==
        "4"
      check run(compileSource("(ptr-len-u32 copy-dst 3)"),
                scope).print() == "12"
      check run(compileSource("(ptr-len-u16 copy-dst 3)"),
                scope).print() == "13"
      check run(compileSource("(ptr-len-ushort copy-dst 3)"),
                scope).print() == "14"
      check run(compileSource("(ptr-len-u8 copy-dst 3)"),
                scope).print() == "15"
      check run(compileSource("(ptr-len-uchar copy-dst 3)"),
                scope).print() == "16"
      check run(compileSource("(ptr-len-uchar nil 3)"), scope).print() == "0"
      check run(compileSource("(ptr-len-diff nil 3)"), scope).print() == "-1"
      check run(compileSource("(ptr-len-diff copy-dst 3)"), scope).print() ==
        "3"
      check run(compileSource("(ptr-len-double copy-dst 3)"), scope).print() ==
        "3.5"
      check run(compileSource("(ptr-has-len? copy-dst 3)"), scope).print() ==
        "true"
      check run(compileSource("(ptr-has-len? copy-dst 0)"), scope).print() ==
        "false"
      check run(compileSource("(ptr-has-len? nil 3)"), scope).print() ==
        "false"
      check run(compileSource("(ptr-int-len copy-dst 2 3)"), scope).print() ==
        "5"
      check run(compileSource("(ptr-int-len nil 2 3)"), scope).print() == "0"
      check run(compileSource("(ptr-int-len-i32 copy-dst 2 3)"),
                scope).print() == "10"
      check run(compileSource("(ptr-int-len-i32 nil 2 3)"),
                scope).print() == "-1"
      check run(compileSource("(ptr-int-len-i16 copy-dst 2 3)"),
                scope).print() == "11"
      check run(compileSource("(ptr-int-len-short copy-dst 2 3)"),
                scope).print() == "12"
      check run(compileSource("(ptr-int-len-i8 copy-dst 2 3)"),
                scope).print() == "13"
      check run(compileSource("(ptr-int-len-char copy-dst 2 3)"),
                scope).print() == "'F'"
      check run(compileSource("(ptr-int-len-u64 copy-dst 2 3)"),
                scope).print() == "6"
      check run(compileSource("(ptr-int-len-u32 copy-dst 2 3)"),
                scope).print() == "14"
      check run(compileSource("(ptr-int-len-u16 copy-dst 2 3)"),
                scope).print() == "15"
      check run(compileSource("(ptr-int-len-ushort copy-dst 2 3)"),
                scope).print() == "16"
      check run(compileSource("(ptr-int-len-u8 copy-dst 2 3)"),
                scope).print() == "17"
      check run(compileSource("(ptr-int-len-uchar copy-dst 2 3)"),
                scope).print() == "18"
      check run(compileSource("(ptr-int-len-uchar nil 2 3)"),
                scope).print() == "0"
      check run(compileSource("(ptr-int-len-diff copy-dst 2 3)"),
                scope).print() == "-1"
      check run(compileSource("(ptr-int-len-double copy-dst 2 3)"),
                scope).print() == "5.5"
      check run(compileSource("(ptr-int-has-len? copy-dst 2 3)"),
                scope).print() == "true"
      check run(compileSource("(ptr-int-has-len? copy-dst 0 3)"),
                scope).print() == "false"
      let identity = run(compileSource("(ptr-identity copy-dst)"), scope)
      check identity.kind == vkCPtr
      check identity.cPtrAddress == cast[pointer](addr copyDst[0])
      check identity.cPtrTargetType.print() == "C/Char"
      check run(compileSource("(ptr-nil? nil)"), scope).print() == "true"
      check run(compileSource("(ptr-nil? copy-dst)"), scope).print() == "false"
      check run(compileSource("(ptr-probe-i32 copy-dst)"),
                scope).print() == "8"
      check run(compileSource("(ptr-probe-i32 nil)"), scope).print() == "-1"
      check run(compileSource("(ptr-probe-i16 copy-dst)"),
                scope).print() == "9"
      check run(compileSource("(ptr-probe-short copy-dst)"),
                scope).print() == "10"
      check run(compileSource("(ptr-probe-i8 copy-dst)"),
                scope).print() == "11"
      check run(compileSource("(ptr-probe-char copy-dst)"),
                scope).print() == "'D'"
      check run(compileSource("(ptr-probe-ulong copy-dst)"),
                scope).print() == "4"
      check run(compileSource("(ptr-probe-ulong nil)"), scope).print() == "0"
      check run(compileSource("(ptr-probe-u32 copy-dst)"),
                scope).print() == "12"
      check run(compileSource("(ptr-probe-u16 copy-dst)"),
                scope).print() == "13"
      check run(compileSource("(ptr-probe-ushort copy-dst)"),
                scope).print() == "14"
      check run(compileSource("(ptr-probe-u8 copy-dst)"),
                scope).print() == "15"
      check run(compileSource("(ptr-probe-uchar copy-dst)"),
                scope).print() == "16"
      check run(compileSource("(ptr-probe-uchar nil)"), scope).print() == "0"
      check run(compileSource("(ptr-probe-i64 copy-dst)"),
                scope).print() == "5"
      check run(compileSource("(ptr-probe-i64 nil)"), scope).print() == "-1"
      check run(compileSource("(ptr-probe-u64 copy-dst)"),
                scope).print() == "6"
      check run(compileSource("(ptr-probe-u64 nil)"), scope).print() == "0"
      check run(compileSource("(ptr-probe-diff copy-dst)"),
                scope).print() == "7"
      check run(compileSource("(ptr-probe-diff nil)"), scope).print() == "-2"
      check run(compileSource("(ptr-same copy-dst copy-dst)"), scope).print() ==
        "1"
      check run(compileSource("(ptr-same copy-dst copy-src)"), scope).print() ==
        "0"
      check run(compileSource("(ptr-same-i32 copy-dst copy-dst)"),
                scope).print() == "8"
      check run(compileSource("(ptr-same-i32 copy-dst copy-src)"),
                scope).print() == "-8"
      check run(compileSource("(ptr-same-i16 copy-dst copy-dst)"),
                scope).print() == "9"
      check run(compileSource("(ptr-same-short copy-dst copy-dst)"),
                scope).print() == "10"
      check run(compileSource("(ptr-same-i8 copy-dst copy-dst)"),
                scope).print() == "11"
      check run(compileSource("(ptr-same-char copy-dst copy-dst)"),
                scope).print() == "'S'"
      check run(compileSource("(ptr-same-char copy-dst copy-src)"),
                scope).print() == "'D'"
      check run(compileSource("(ptr-same-u64 copy-dst copy-dst)"),
                scope).print() == "1"
      check run(compileSource("(ptr-same-u32 copy-dst copy-dst)"),
                scope).print() == "12"
      check run(compileSource("(ptr-same-u16 copy-dst copy-dst)"),
                scope).print() == "13"
      check run(compileSource("(ptr-same-ushort copy-dst copy-dst)"),
                scope).print() == "14"
      check run(compileSource("(ptr-same-u8 copy-dst copy-dst)"),
                scope).print() == "15"
      check run(compileSource("(ptr-same-uchar copy-dst copy-dst)"),
                scope).print() == "16"
      check run(compileSource("(ptr-same-uchar copy-dst copy-src)"),
                scope).print() == "0"
      check run(compileSource("(ptr-same-diff copy-dst copy-src)"),
                scope).print() == "-1"
      check run(compileSource("(ptr-same-double copy-dst copy-dst)"),
                scope).print() == "1.5"
      let picked = run(compileSource("(ptr-pick nil copy-dst)"), scope)
      check picked.kind == vkCPtr
      check picked.cPtrAddress == cast[pointer](addr copyDst[0])
      check picked.cPtrTargetType.print() == "C/Char"
      check run(compileSource("(ptr-ptr-len copy-dst copy-src 3)"),
                scope).print() == "3"
      check run(compileSource("(ptr-ptr-len nil copy-src 3)"), scope).print() ==
        "0"
      check run(compileSource("(ptr-ptr-len-i32 copy-dst copy-src 3)"),
                scope).print() == "8"
      check run(compileSource("(ptr-ptr-len-i32 nil copy-src 3)"),
                scope).print() == "-1"
      check run(compileSource("(ptr-ptr-len-i16 copy-dst copy-src 3)"),
                scope).print() == "9"
      check run(compileSource("(ptr-ptr-len-short copy-dst copy-src 3)"),
                scope).print() == "10"
      check run(compileSource("(ptr-ptr-len-i8 copy-dst copy-src 3)"),
                scope).print() == "11"
      check run(compileSource("(ptr-ptr-len-char copy-dst copy-src 3)"),
                scope).print() == "'D'"
      check run(compileSource("(ptr-ptr-len-u64 copy-dst copy-src 3)"),
                scope).print() == "4"
      check run(compileSource("(ptr-ptr-len-u32 copy-dst copy-src 3)"),
                scope).print() == "12"
      check run(compileSource("(ptr-ptr-len-u16 copy-dst copy-src 3)"),
                scope).print() == "13"
      check run(compileSource("(ptr-ptr-len-ushort copy-dst copy-src 3)"),
                scope).print() == "14"
      check run(compileSource("(ptr-ptr-len-u8 copy-dst copy-src 3)"),
                scope).print() == "15"
      check run(compileSource("(ptr-ptr-len-uchar copy-dst copy-src 3)"),
                scope).print() == "16"
      check run(compileSource("(ptr-ptr-len-uchar nil copy-src 3)"),
                scope).print() == "0"
      check run(compileSource("(ptr-ptr-len-diff copy-dst copy-dst 3)"),
                scope).print() == "3"
      check run(compileSource("(ptr-ptr-len-diff copy-dst copy-src 3)"),
                scope).print() == "-3"
      check run(compileSource("(ptr-ptr-len-double copy-dst copy-dst 3)"),
                scope).print() == "3.5"
      check run(compileSource("(ptr-ptr-has-len? copy-dst copy-src 3)"),
                scope).print() == "true"
      check run(compileSource("(ptr-ptr-has-len? copy-dst copy-src 0)"),
                scope).print() == "false"

  test "union and optional annotations":
    ck "(fn f [x : (| Int Str)] x) (f \"ok\")", "\"ok\""
    ck "(fn f [x : (? Int)] x) (f nil)", "nil"
    ck "(fn f [x : (? Int Str)] x) [(f nil) (f 2) (f \"ok\")]",
       "[nil 2 \"ok\"]"
    expect GeneError:
      discard runStr("(fn f [x : (?)] x) (f nil)")

  test "numeric family and fixed representation annotations":
    ck "(fn f [x : Float] x) (f 1.5)", "1.5"
    ck "(fn f [x : F64] x) (f 1.5)", "1.5"
    ck "(fn f [x : F32] x) (f 1.5)", "1.5"
    ck "(fn f [x : Fixnum] x) (f -140737488355328)", "-140737488355328"
    ck "(fn f [x : Fixnum] x) (f 140737488355327)", "140737488355327"
    expect GeneError:
      discard runStr("(fn f [x : Fixnum] x) (f 140737488355328)")
    ck "(fn f [x : Int] x) (f 140737488355328)", "140737488355328"
    ck "[(== 1 1.0) (!= 1 1.0) (== 0.0 -0.0)]", "[false true true]"

  test "tuple product annotations are positional and exact":
    ck "(fn f [x : (Tuple Int Str)] x/1) (f [1 \"ok\"])", "\"ok\""
    ck "(quote (Tuple Int Str))", "(Tuple Int Str)"
    expect GeneError:
      discard runStr("(fn f [x : (Tuple Int Str)] x) (f [1])")
    expect GeneError:
      discard runStr("(fn f [x : (Tuple Int Str)] x) (f [1 2])")

  test "function annotations describe fixed ordinary signatures":
    ck "(fn use [f : (Fn [Int] Str)] (f 1)) " &
       "(use (fn [x : Int] : Str \"ok\"))", "\"ok\""
    ck "(quote (Fn [Int] Str ^errors []))",
       "(Fn ^errors [] [Int] Str)"
    expect GeneError:
      discard runStr("(fn use [f : (Fn [Int] Str)] f) " &
                     "(use (fn [x : Str] : Str x))")
    expect GeneError:
      discard runStr("(fn use [f : (Fn [Int] Str)] f) " &
                     "(use (fn! [x] x))")
    expect GeneError:
      discard runStr("(fn use [f : (Fn Int Str)] f) (use (fn [x] x))")

  test "unsupported nominal generic aliases and open prop schemas fail clearly":
    expect GeneError:
      discard compileSource("(type (Box t) ^props {^value t})")
    expect GeneError:
      discard compileSource("(type Maybe ^alias (? Int))")
    expect GeneError:
      discard compileSource("(type Bag ^props {} ^rest Int)")
    expect GeneError:
      discard runStr("(enum Option [T] none (some T)) " &
                     "(fn f [x : (Option Int Str)] x) (f Option/none)")
    expect GeneError:
      discard runStr("(type Box ^props {^value Int}) " &
                     "(fn f [x : (Box Int)] x) (f (Box ^value 1))")

  test "callable annotation accepts callables only":
    ck "(fn call-it [f : Callable] (f {^name \"Ada\"})) (call-it /name)", "\"Ada\""
    ck "(fn keep-native [f : NativeFn] f) (keep-native +)", "(native-fn +)"
    ck "(try (fn keep-native [f : NativeFn] f) (keep-native (fn [] nil)) " &
       "catch (TypeError ^expected e) e)", "\"NativeFn\""
    ck "(try (fn keep-fn [f : Fn] f) (keep-fn +) " &
       "catch (TypeError ^expected e) e)", "\"Fn\""
    ck "(fn keep-selector [s : Selector] s) (keep-selector /name)", "(select name)"
    ck "(try (fn keep-selector [s : Selector] s) (keep-selector (quote (x))) " &
       "catch (TypeError ^expected e) e)", "\"Selector\""
    ck "(try (fn keep [f : Callable] f) (keep (quote (not-callable))) " &
       "catch (TypeError ^expected e) e)", "\"Callable\""
