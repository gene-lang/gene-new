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

proc ffiTestUShortInc(x: cushort): cushort {.cdecl.} =
  x + cushort(1)

proc ffiTestI8Abs(x: int8): int8 {.cdecl.} =
  if x < 0'i8: -x else: x

proc ffiTestU8Inc(x: uint8): uint8 {.cdecl.} =
  x + 1'u8

proc ffiTestCharNext(x: cchar): cchar {.cdecl.} =
  cchar(ord(x) + 1)

proc ffiTestUCharInc(x: uint8): uint8 {.cdecl.} =
  x + 1'u8

proc ffiTestBoolNot(x: bool): bool {.cdecl.} =
  not x

proc ffiTestU64Inc(x: uint64): uint64 {.cdecl.} =
  x + 1'u64

proc ffiTestULongInc(x: culong): culong {.cdecl.} =
  x + culong(1)

proc ffiTestPtrDiffAbs(x: int): int {.cdecl.} =
  if x < 0: -x else: x

proc ffiTestSizeInc(x: csize_t): csize_t {.cdecl.} =
  x + csize_t(1)

proc ffiTestSizeAddUInt(a, b: csize_t): cuint {.cdecl.} =
  cuint(a + b + csize_t(1))

proc ffiTestSizeDiffLong(a, b: csize_t): clong {.cdecl.} =
  clong(a) - clong(b)

proc ffiTestSizeAddULong(a, b: csize_t): culong {.cdecl.} =
  culong(a + b + csize_t(2))

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

proc ffiTestIntAdd(a, b: cint): cint {.cdecl.} =
  a + b

proc ffiTestIntAddUInt(a, b: cint): cuint {.cdecl.} =
  cuint(a + b + 1)

proc ffiTestIntDiffLong(a, b: cint): clong {.cdecl.} =
  clong(a - b)

proc ffiTestIntAddULong(a, b: cint): culong {.cdecl.} =
  culong(a + b + 2)

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

proc ffiTestDoubleAdd(a, b: cdouble): cdouble {.cdecl.} =
  a + b

proc ffiTestDoubleScale(a: cdouble, factor: cint): cdouble {.cdecl.} =
  a * cdouble(factor)

proc ffiTestIntOffset(a: cint, b: cdouble): cdouble {.cdecl.} =
  cdouble(a) + b

proc ffiTestFloatAdd(a, b: cfloat): cfloat {.cdecl.} =
  a + b

proc ffiTestFloatScale(a: cfloat, factor: cint): cfloat {.cdecl.} =
  a * cfloat(factor)

proc ffiTestIntFloatOffset(a: cint, b: cfloat): cfloat {.cdecl.} =
  cfloat(a) + b

proc ffiTestSliceLen(data: pointer, len: csize_t): csize_t {.cdecl.} =
  len

proc ffiTestSliceFirstByte(data: pointer, len: csize_t): cint {.cdecl.} =
  if data == nil or len == 0:
    -1
  else:
    cint(cast[ptr uint8](data)[])

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

proc ffiTestCStrIntUInt(s: cstring, x: cint): cuint {.cdecl.} =
  cuint(($s).len + int(x) + 1)

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

proc ffiTestPtrLenU64(p: pointer, len: csize_t): uint64 {.cdecl.} =
  if p == nil: 0'u64 else: uint64(len) + 1'u64

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

proc ffiTestPtrSame(a, b: pointer): cint {.cdecl.} =
  if a == b: 1 else: 0

proc ffiTestPtrSameU64(a, b: pointer): uint64 {.cdecl.} =
  if a == b: 1'u64 else: 0'u64

proc ffiTestPtrSameDiff(a, b: pointer): TestCPtrDiff {.cdecl.} =
  if a == b: TestCPtrDiff(1) else: TestCPtrDiff(-1)

proc ffiTestPtrSameDouble(a, b: pointer): cdouble {.cdecl.} =
  if a == b: 1.5 else: -1.5

proc ffiTestPtrPick(a, b: pointer): pointer {.cdecl.} =
  if a != nil: a else: b

proc ffiTestPtrPtrLen(a, b: pointer, len: csize_t): csize_t {.cdecl.} =
  if a == nil or b == nil: 0 else: len

proc ffiTestPtrPtrLenU64(a, b: pointer, len: csize_t): uint64 {.cdecl.} =
  if a == nil or b == nil: 0'u64 else: uint64(len) + 1'u64

proc ffiTestPtrPtrLenDiff(a, b: pointer, len: csize_t): TestCPtrDiff {.cdecl.} =
  if a == b: TestCPtrDiff(len) else: -TestCPtrDiff(len)

proc ffiTestPtrPtrLenDouble(a, b: pointer, len: csize_t): cdouble {.cdecl.} =
  if a == b: cdouble(len) + 0.5 else: cdouble(len) + 1.5

proc ffiTestPtrPtrHasLen(a, b: pointer, len: csize_t): bool {.cdecl.} =
  a != nil and b != nil and len > 0

proc ffiTestPtrIntLen(p: pointer, x: cint, len: csize_t): csize_t {.cdecl.} =
  if p == nil or x < 0: 0 else: csize_t(x) + len

proc ffiTestPtrIntLenU64(p: pointer, x: cint, len: csize_t): uint64 {.cdecl.} =
  if p == nil or x < 0: 0'u64 else: uint64(x) + uint64(len) + 1'u64

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
    ck "(type Task ^props {^id Int}) (= (head (Task ^id 1)) Task)", "true"
  test "distinct types are not equal":
    ck "(type A ^props {^x Int}) (type B ^props {^x Int}) (= A B)", "false"
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
    ck "(type Task ^props {^id Int ^done? Bool}) (var t (Task ^id 1)) t/id", "1"
  test "void fields normalize as omitted at construction":
    ck "(type Task ^props {^id Int ^done? Bool}) " &
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
       "(impl Error Boom) " &
       "(type Other ^props {^message Str} ^impl [Error]) " &
       "(impl Error Other) " &
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
    ck "(fn size [xs : (List Int)] xs/size) (size [1 2 3])", "3"
    ck "(try (fn size [xs : (List Int)] xs/size) (size [1 \"bad\"]) " &
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
    ck "C/Int32", "(c-abi-type Int32)"
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
              scope).print() == "(c-ptr)"
    check run(compileSource("((fn [p : (C/ConstPtr C/Char)] p) constp)"),
              scope).print() == "(c-const-ptr)"
    check run(compileSource("((fn [p : (C/ConstPtr C/Char)] p) p)"),
              scope).print() == "(c-ptr)"
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
       "(Buffer/to_list b) (Buffer/elem-type b)]",
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
    ck "Ffi/Load", "(ffi-type Load)"

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
      let handle = cast[LibHandle](lib.ffiLibraryHandle)
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
                  scope).print() == "(c-const-ptr null)"
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
                      scope).print() == "(c-const-ptr null)"
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
                  scope).print() == "(c-const-ptr)"
        check run(compileSource("((ffi/bind lib \"strchr\" [C/CStr C/Int] " &
                                "  (quote (C/NullableConstPtr C/Char))) " &
                                " \"abc\" 120)"),
                  scope).print() == "(c-const-ptr null)"
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
      scope.define("ushort-inc",
                   newFfiCallable("ffiTestUShortInc", "ffiTestUShortInc",
                                  cast[pointer](ffiTestUShortInc), lib,
                                  @[newSym("C/UShort")], newSym("C/UShort")))
      scope.define("i8-abs",
                   newFfiCallable("ffiTestI8Abs", "ffiTestI8Abs",
                                  cast[pointer](ffiTestI8Abs), lib,
                                  @[newSym("C/Int8")], newSym("C/Int8")))
      scope.define("u8-inc",
                   newFfiCallable("ffiTestU8Inc", "ffiTestU8Inc",
                                  cast[pointer](ffiTestU8Inc), lib,
                                  @[newSym("C/UInt8")], newSym("C/UInt8")))
      scope.define("char-next",
                   newFfiCallable("ffiTestCharNext", "ffiTestCharNext",
                                  cast[pointer](ffiTestCharNext), lib,
                                  @[newSym("C/Char")], newSym("C/Char")))
      scope.define("uchar-inc",
                   newFfiCallable("ffiTestUCharInc", "ffiTestUCharInc",
                                  cast[pointer](ffiTestUCharInc), lib,
                                  @[newSym("C/UChar")], newSym("C/UChar")))
      scope.define("bool-not",
                   newFfiCallable("ffiTestBoolNot", "ffiTestBoolNot",
                                  cast[pointer](ffiTestBoolNot), lib,
                                  @[newSym("C/Bool")], newSym("C/Bool")))
      scope.define("u64-inc",
                   newFfiCallable("ffiTestU64Inc", "ffiTestU64Inc",
                                  cast[pointer](ffiTestU64Inc), lib,
                                  @[newSym("C/UInt64")], newSym("C/UInt64")))
      scope.define("ulong-inc",
                   newFfiCallable("ffiTestULongInc", "ffiTestULongInc",
                                  cast[pointer](ffiTestULongInc), lib,
                                  @[newSym("C/ULong")], newSym("C/ULong")))
      scope.define("ptrdiff-abs",
                   newFfiCallable("ffiTestPtrDiffAbs", "ffiTestPtrDiffAbs",
                                  cast[pointer](ffiTestPtrDiffAbs), lib,
                                  @[newSym("C/PtrDiff")],
                                  newSym("C/PtrDiff")))
      scope.define("size-inc",
                   newFfiCallable("ffiTestSizeInc", "ffiTestSizeInc",
                                  cast[pointer](ffiTestSizeInc), lib,
                                  @[newSym("C/Size")], newSym("C/Size")))
      scope.define("size-add-uint",
                   newFfiCallable("ffiTestSizeAddUInt",
                                  "ffiTestSizeAddUInt",
                                  cast[pointer](ffiTestSizeAddUInt), lib,
                                  @[newSym("C/Size"), newSym("C/Size")],
                                  newSym("C/UInt")))
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
      scope.define("int-add",
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
      scope.define("double-add",
                   newFfiCallable("ffiTestDoubleAdd", "ffiTestDoubleAdd",
                                  cast[pointer](ffiTestDoubleAdd), lib,
                                  @[newSym("C/Double"), newSym("C/Double")],
                                  newSym("C/Double")))
      scope.define("double-scale",
                   newFfiCallable("ffiTestDoubleScale", "ffiTestDoubleScale",
                                  cast[pointer](ffiTestDoubleScale), lib,
                                  @[newSym("C/Double"), newSym("C/Int")],
                                  newSym("C/Double")))
      scope.define("int-offset",
                   newFfiCallable("ffiTestIntOffset", "ffiTestIntOffset",
                                  cast[pointer](ffiTestIntOffset), lib,
                                  @[newSym("C/Int"), newSym("C/Double")],
                                  newSym("C/Double")))
      scope.define("float-add",
                   newFfiCallable("ffiTestFloatAdd", "ffiTestFloatAdd",
                                  cast[pointer](ffiTestFloatAdd), lib,
                                  @[newSym("C/Float"), newSym("C/Float")],
                                  newSym("C/Float")))
      scope.define("float-scale",
                   newFfiCallable("ffiTestFloatScale", "ffiTestFloatScale",
                                  cast[pointer](ffiTestFloatScale), lib,
                                  @[newSym("C/Float"), newSym("C/Int")],
                                  newSym("C/Float")))
      scope.define("int-float-offset",
                   newFfiCallable("ffiTestIntFloatOffset",
                                  "ffiTestIntFloatOffset",
                                  cast[pointer](ffiTestIntFloatOffset), lib,
                                  @[newSym("C/Int"), newSym("C/Float")],
                                  newSym("C/Float")))
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
      scope.define("cstr-int-uint",
                   newFfiCallable("ffiTestCStrIntUInt",
                                  "ffiTestCStrIntUInt",
                                  cast[pointer](ffiTestCStrIntUInt), lib,
                                  @[newSym("C/CStr"), newSym("C/Int")],
                                  newSym("C/UInt")))
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
      scope.define("ptr-len-u64",
                   newFfiCallable("ffiTestPtrLenU64", "ffiTestPtrLenU64",
                                  cast[pointer](ffiTestPtrLenU64), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Size")],
                                  newSym("C/UInt64")))
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
      scope.define("ptr-int-len-u64",
                   newFfiCallable("ffiTestPtrIntLenU64",
                                  "ffiTestPtrIntLenU64",
                                  cast[pointer](ffiTestPtrIntLenU64), lib,
                                  @[newNode(newSym("C/NullablePtr"),
                                            body = @[newSym("C/Char")]),
                                    newSym("C/Int"),
                                    newSym("C/Size")],
                                  newSym("C/UInt64")))
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
      scope.define("ptr-same",
                   newFfiCallable("ffiTestPtrSame",
                                  "ffiTestPtrSame",
                                  cast[pointer](ffiTestPtrSame), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/Int")))
      scope.define("ptr-same-u64",
                   newFfiCallable("ffiTestPtrSameU64",
                                  "ffiTestPtrSameU64",
                                  cast[pointer](ffiTestPtrSameU64), lib,
                                  @[newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")]),
                                    newNode(newSym("C/ConstPtr"),
                                            body = @[newSym("C/Char")])],
                                  newSym("C/UInt64")))
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
      check run(compileSource("(ushort-inc 41)"), scope).print() == "42"
      expect GeneError:
        discard run(compileSource("(ushort-inc -1)"), scope)
      expect GeneError:
        discard run(compileSource("(ushort-inc 65536)"), scope)
      check run(compileSource("(i8-abs -9)"), scope).print() == "9"
      expect GeneError:
        discard run(compileSource("(i8-abs 128)"), scope)
      check run(compileSource("(u8-inc 41)"), scope).print() == "42"
      expect GeneError:
        discard run(compileSource("(u8-inc -1)"), scope)
      expect GeneError:
        discard run(compileSource("(u8-inc 256)"), scope)
      check run(compileSource("(char-next 'A')"), scope).print() == "'B'"
      expect GeneError:
        discard run(compileSource("(char-next 128)"), scope)
      check run(compileSource("(uchar-inc 41)"), scope).print() == "42"
      check run(compileSource("(uchar-inc 'A')"), scope).print() == "66"
      expect GeneError:
        discard run(compileSource("(uchar-inc -1)"), scope)
      expect GeneError:
        discard run(compileSource("(uchar-inc 256)"), scope)
      check run(compileSource("(bool-not true)"), scope).print() == "false"
      check run(compileSource("(bool-not false)"), scope).print() == "true"
      expect GeneError:
        discard run(compileSource("(bool-not 1)"), scope)
      check run(compileSource("(u64-inc 41)"), scope).print() == "42"
      check run(compileSource("(u64-inc 9223372036854775808)"),
                scope).print() == "9223372036854775809"
      expect GeneError:
        discard run(compileSource("(u64-inc -1)"), scope)
      expect GeneError:
        discard run(compileSource("(u64-inc 18446744073709551616)"), scope)
      check run(compileSource("(ulong-inc 41)"), scope).print() == "42"
      when sizeof(culong) == 8:
        check run(compileSource("(ulong-inc 9223372036854775808)"),
                  scope).print() == "9223372036854775809"
      expect GeneError:
        discard run(compileSource("(ulong-inc -1)"), scope)
      check run(compileSource("(ptrdiff-abs -9)"), scope).print() == "9"
      expect GeneError:
        discard run(compileSource("(ptrdiff-abs 9223372036854775808)"),
                    scope)
      check run(compileSource("(size-inc 41)"), scope).print() == "42"
      check run(compileSource("(size-add-uint 20 22)"), scope).print() == "43"
      check run(compileSource("(size-diff-long 20 22)"), scope).print() == "-2"
      check run(compileSource("(size-add-ulong 20 22)"), scope).print() == "44"
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
      check run(compileSource("(int-add 20 22)"), scope).print() == "42"
      check run(compileSource("(int-add-uint 20 22)"), scope).print() == "43"
      check run(compileSource("(int-diff-long 20 22)"), scope).print() == "-2"
      check run(compileSource("(int-add-ulong 20 22)"), scope).print() == "44"
      check run(compileSource("(int-add-i64 20 22)"), scope).print() == "45"
      check run(compileSource("(int-add-u64 20 22)"), scope).print() == "46"
      check run(compileSource("(int-diff-ptrdiff 20 22)"),
                scope).print() == "-2"
      check run(compileSource("(int-add-float 20 22)"),
                scope).print() == "42.25"
      check run(compileSource("(int-add-double 20 22)"),
                scope).print() == "42.5"
      expect GeneError:
        discard run(compileSource("(int-add 1 2147483648)"), scope)
      check run(compileSource("(double-add 1.25 2.5)"), scope).print() == "3.75"
      expect GeneError:
        discard run(compileSource("(double-add 1 2.5)"), scope)
      check run(compileSource("(double-scale 1.5 3)"), scope).print() == "4.5"
      expect GeneError:
        discard run(compileSource("(double-scale 1.5 3.0)"), scope)
      check run(compileSource("(int-offset 4 0.5)"), scope).print() == "4.5"
      expect GeneError:
        discard run(compileSource("(int-offset 4.0 0.5)"), scope)
      check run(compileSource("(float-add 1.25 2.5)"), scope).print() == "3.75"
      expect GeneError:
        discard run(compileSource("(float-add 1 2.5)"), scope)
      check run(compileSource("(float-scale 1.5 3)"), scope).print() == "4.5"
      expect GeneError:
        discard run(compileSource("(float-scale 1.5 3.0)"), scope)
      check run(compileSource("(int-float-offset 4 0.5)"), scope).print() == "4.5"
      expect GeneError:
        discard run(compileSource("(int-float-offset 4.0 0.5)"), scope)
      check run(compileSource("(slice-len byte-slice)"), scope).print() == "3"
      check run(compileSource("(slice-first-byte byte-slice)"),
                scope).print() == "65"
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
        "(c-const-ptr)"
      check run(compileSource("(cstr-ptr-if-len \"abc\" 0)"), scope).print() ==
        "(c-const-ptr null)"
      check run(compileSource("(cstr-int-uint \"abc\" 2)"),
                scope).print() == "6"
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
        "(c-ptr)"
      check run(compileSource("(ptr-if-len copy-dst 0)"), scope).print() ==
        "(c-ptr null)"
      check run(compileSource("(ptr-len copy-dst 3)"), scope).print() == "3"
      check run(compileSource("(ptr-len nil 3)"), scope).print() == "0"
      check run(compileSource("(ptr-len-u64 copy-dst 3)"), scope).print() ==
        "4"
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
      check run(compileSource("(ptr-int-len-u64 copy-dst 2 3)"),
                scope).print() == "6"
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
      check run(compileSource("(ptr-same copy-dst copy-dst)"), scope).print() ==
        "1"
      check run(compileSource("(ptr-same copy-dst copy-src)"), scope).print() ==
        "0"
      check run(compileSource("(ptr-same-u64 copy-dst copy-dst)"),
                scope).print() == "1"
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
      check run(compileSource("(ptr-ptr-len-u64 copy-dst copy-src 3)"),
                scope).print() == "4"
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
    ck "(fn f [x : (opt Int)] x) (f nil)", "nil"

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
