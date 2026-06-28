import gene/[compiler, types, vm, printer]
import std/[dynlib, unittest]

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

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
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"sleep\" [C/UInt] C/UInt) -1)"),
            scope)
        expect GeneError:
          discard run(compileSource(
            "((ffi/bind lib \"sleep\" [C/UInt] C/UInt) 4294967296)"),
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
