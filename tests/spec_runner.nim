## Executable Gene language surface spec.
##
## This file intentionally checks behavior from docs/design.md and
## examples/web_demo.gene at a higher level than unit tests. Run after changes:
##   nimble spec

import gene/[compiler, gir, printer, reader, types, vm]
import std/[sequtils, strutils, unittest]

template check_read(src: string, expected: string) =
  check read(src).print() == expected

template check_eval(src: string, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

suite "spec — reader surface from design":
  test "programs contain multiple top-level forms":
    let forms = readAll("(mod app) (import std/stream [map]) (fn main [] nil)")
    check forms.len == 3
    check forms[0].print() == "(mod app)"
    check forms[1].print() == "(import (path std stream) [map])"
    check forms[2].print() == "(fn main [] nil)"

  test "selector literals and context-neutral paths stay distinct":
    check_read("/user/name", "(select user name)")
    check_read("user/name", "(path user name)")
    check_read("/users/0/name", "(select users 0 name)")
    check_read("users/-1/name", "(path users -1 name)")
    check_read("(import net/http [Request])", "(import (path net http) [Request])")
    check_read("(fn f [^server : Http/Server] nil)",
               "(fn f [^ server : Http/Server] nil)")
    check_read("(~ f a)", "(~ f a)")
    check_read("(x; parse; (or _ default))", "(or ((x) parse) default)")
    check_read("(x ~ parse; (or _ default))", "(or (parse x) default)")

  test "template unquote supports interpolation and dynamic paths":
    check_read("%$\"$${self/price}\"", "(unquote ($ \"$\" (path self price)))")
    check_read("`(td %$\"$${self/price}\")",
               "(quasiquote (td (unquote ($ \"$\" (path self price)))))")
    check_read("`(div %children...)", "(quasiquote (div (unquote (... children))))")

  test "datum comments are spacing, not values":
    check readAll("#_ (discarded) (kept)").len == 1
    check readAll("#_ (discarded) (kept)")[0].print() == "(kept)"
    check_read("(a #_ b c)", "(a c)")
    check_read("(a #_ b)", "(a)")

  test "strings decode Unicode escapes":
    check_read("\"\\u00E9\\u{1F600}\"", "\"é😀\"")

  test "dollar interpolation keeps the canonical call form distinct":
    check_read("$\"hello ${name}\"", "($ \"hello \" name)")
    check_read("($ \"hello \" name)", "($ \"hello \" name)")

  test "malformed syntax is rejected":
    expect ReadError: discard read("(a b")
    expect ReadError: discard read(")")
    expect ReadError: discard read("$\"hello ${name\"")
    expect ReadError: discard read("'ab'")

suite "spec — value spread from design":
  test "spread flattens values in calls and list literals":
    check_eval("(var xs [1 2]) (fn collect [items...] items) (collect xs... 3)",
               "[1 2 3]")
    check_eval("(fn collect [items...] items) (collect [1 2]... 3)",
               "[1 2 3]")
    check_eval("(var xs [2 3]) [1 xs... 4]", "[1 2 3 4]")
    check_eval("[1 [2 3]... 4]", "[1 2 3 4]")
    check_eval("(var n (quote (pair 2 3))) [1 n... 4]", "[1 2 3 4]")

suite "spec — templates from design":
  test "quasiquote unquote builds generated nodes":
    check_eval("(var name \"Ada\") `(div %name)", "(div \"Ada\")")

  test "eval executes generated template nodes":
    check_eval("(var x 40) (eval `(+ %x 2) ^in (env))", "42")

  test "quasiquote unquote-splicing merges generated bodies":
    check_eval("(var body [(quote (p \"a\")) (quote (p \"b\"))]) `(div %body...)",
               "(div (p \"a\") (p \"b\"))")

suite "spec — macros from design":
  test "template macros expand before calls":
    check_eval("(macro when! [cond, body...] " &
               "  `(if %cond (then %body...) (else nil))) " &
               "[(when! true 1) (when! false 2)]",
               "[1 nil]")
    check_eval("(macro when! [cond, body...] " &
               "  `(if %cond (then %body...) (else nil))) " &
               "(when! true (var x 1) (+ x 1))",
               "2")

  test "macro call arguments are syntax nodes":
    check_eval("(var hit 0) " &
               "(macro ignore! [ignored] 7) " &
               "[(ignore! (set hit 1)) hit]",
               "[7 0]")

  test "macro call props bind named syntax parameters":
    check_eval("(macro scaled! [value ^by n] `(+ %value %n)) " &
               "(scaled! ^by 3 7)",
               "10")
    check_eval("(macro scaled! [value ^by amount] `(+ %value %amount)) " &
               "(scaled! ^by 4 9)",
               "13")
    check_eval("(macro tagged! [value ^tag t] `(quote (%t %value))) " &
               "(tagged! ^tag item 7)",
               "(item 7)")
    expect GeneError:
      discard run(compileSource(
        "(macro scaled! [value ^by n] `(+ %value %n)) " &
        "(scaled! 7)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource(
        "(macro scaled! [value ^by n] `(+ %value %n)) " &
        "(scaled! ^other 3 7)"), newGlobalScope())

  test "macro parameters destructure syntax patterns":
    check_eval("(macro second! [[_ value]] `%value) " &
               "(second! [ignored (+ 1 2)])",
               "3")
    check_eval("(macro pick-prop! [{^value v}] `%v) " &
               "(pick-prop! {^value (+ 2 3)})",
               "5")
    check_eval("(macro named-pair! [^entry [k v]] `(+ %k %v)) " &
               "(named-pair! ^entry [2 3])",
               "5")
    expect GeneError:
      discard run(compileSource(
        "(macro second! [[_ value]] `%value) " &
        "(second! [only-one])"), newGlobalScope())

  test "macro typed patterns match syntax values":
    check_eval("(macro eval-node! [(form : Node)] `%form) " &
               "(eval-node! (+ 1 2))",
               "3")
    check_eval("(macro eval-flat! [form : Node] `%form) " &
               "(eval-flat! (+ 2 3))",
               "5")
    check_eval("(macro keep-syms! [(items : (List Sym))] `(quote %items)) " &
               "(keep-syms! [a b])",
               "[a b]")
    check_eval("(macro keep-entry! [^entry item : (List Sym)] `(quote %item)) " &
               "(keep-entry! ^entry [a b])",
               "[a b]")
    expect GeneError:
      discard run(compileSource(
        "(macro eval-node! [(form : Node)] `%form) " &
        "(eval-node! 1)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource(
        "(macro eval-flat! [form : Node] `%form) " &
        "(eval-flat! 1)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource(
        "(macro keep-syms! [(items : (List Sym))] `(quote %items)) " &
        "(keep-syms! [a 1])"), newGlobalScope())

  test "macro parameter defaults bind syntax values":
    check_eval("(macro default-value! [x = 7] `%x) " &
               "[(default-value!) (default-value! 9)]",
               "[7 9]")
    check_eval("(macro second-or-first! [x y = x] `%y) " &
               "[(second-or-first! (+ 1 2)) (second-or-first! 1 4)]",
               "[3 4]")
    check_eval("(macro named-default! [^value v = (+ 2 3)] `%v) " &
               "[(named-default!) (named-default! ^value 8)]",
               "[5 8]")
    check_eval("(macro optional! [x?] `%x) (optional!)", "void")
    expect GeneError:
      discard compileSource("(macro bad! [x = 1 y] `%y)")

  test "template macros expand in default arguments":
    check_eval("(macro seven! [] 7) (fn f [x = (seven!)] x) (f)", "7")

  test "template macros avoid introduced local capture":
    check_eval("(macro local! [x] `(do (var tmp 1) (+ tmp %x))) " &
               "(var tmp 100) [(local! 2) tmp]",
               "[3 100]")

  test "template macros avoid introduced helper capture":
    check_eval("(macro helper! [x] " &
               "  `(do (fn helper [y] (+ y 1)) (helper %x))) " &
               "(fn helper [y] 100) [(helper! 2) (helper 2)]",
               "[3 100]")
    check_eval("(macro recursive! [x] " &
               "  `(do (fn helper [n] " &
               "          (if (= n 0) 0 (helper (- n 1)))) " &
               "       (helper %x))) " &
               "(fn helper [n] 99) [(recursive! 3) (helper 3)]",
               "[0 99]")

suite "spec — typed native compilation prototype from design":
  test "simple typed Int arithmetic can use a native direct op":
    let chunk = compileSource("(fn add [x : Int y : Int] : Int (+ x y))")
    check chunk.functions[0].nativeOp == ncoIntAdd
    check "native=int-add" in chunk.disassemble()
    check_eval("(fn add [x : Int y : Int] : Int (+ x y)) (add 20 22)",
               "42")
    check_eval("(fn add [x : Int y : Int] : Int (+ x y)) " &
               "(try (add \"bad\" 1) catch (TypeError ^where w) w)",
               "\"parameter 'x'\"")
    check_eval("(fn outer [] (add \"bad\" 1)) " &
               "(fn add [x : Int y : Int] : Int (+ x y)) " &
               "(try (outer) catch (TypeError ^trace t) " &
               "  [t/0/name t/0/kind t/1/name t/1/kind])",
               "[\"add\" \"typed-native\" \"outer\" \"bytecode\"]")

  test "fixed representation functions expose an experimental C backend":
    let chunk = compileSource("(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
                              "(fn scale [x : F64 y : F64] : F64 (* x y))")
    check chunk.functions[0].nativeOp == ncoI64Add
    check chunk.functions[1].nativeOp == ncoF64Mul
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneFfiAbiTypeInfo" in c
    check "_Static_assert(sizeof(int64_t) == 8, \"C/Int64 must be 8 bytes\");" in c
    check "static const GeneFfiAbiTypeInfo gene_ffi_abi_types[] = {" in c
    check "{\"C/Int64\", \"int64_t\", sizeof(int64_t), GENE_ALIGNOF(int64_t)}," in c
    check "static const size_t gene_ffi_abi_types_count = 22;" in c
    check "int64_t gene_native_add64(int64_t x, int64_t y)" in c
    check "double gene_native_scale(double x, double y)" in c
    check_eval("(fn add64 [x : I64 y : I64] : I64 (+ x y)) (add64 20 22)",
               "42")

  test "selected typed functions AOT emit direct typed C calls":
    let chunk = compileSource("(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
                              "(fn add64_twice [x : I64 y : I64] : I64 " &
                              "  (add64 (add64 x y) y))")
    check chunk.functions[0].aotExpr.kind != vkNil
    check chunk.functions[1].aotExpr.kind != vkNil
    check chunk.functions[0].aotFrameKind == afkTypedNative
    check not chunk.functions[0].aotFrameCanSuspend
    check "aot=c frame=typed-native" in chunk.disassemble()
    check "typed-module-aot:" in chunk.disassemble()
    check "add64 repr=I64 arity=2 frame=typed-native" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneNativeFrameInfo" in c
    check "typedef struct GeneAotModuleFunction" in c
    check "static const GeneNativeFrameInfo gene_frame_add64 = {\"add64\", GENE_NATIVE_FRAME_TYPED};" in c
    check "(void)&gene_frame_add64;" in c
    check "static const GeneAotModuleFunction gene_aot_module[] = {" in c
    check "{\"add64\", \"gene_native_add64\", \"I64\", 2, &gene_frame_add64}," in c
    check "static const size_t gene_aot_module_count = 2;" in c
    check "int64_t gene_native_add64_twice(int64_t x, int64_t y)" in c
    check "return gene_native_add64(gene_native_add64(x, y), y);" in c
    check_eval("(fn add64 [x : I64 y : I64] : I64 (+ x y)) " &
               "(fn add64_twice [x : I64 y : I64] : I64 " &
               "  (add64 (add64 x y) y)) " &
               "(add64_twice 20 2)",
               "24")

  test "task-frame lowering metadata is emitted for resumable functions":
    let chunk = compileSource("(fn wait [t : (Task Int Never)] : Int (await t)) " &
                              "(fn ints [] : (Stream Int Never) (yield 1))")
    check chunk.functions[0].taskFrameKind == tfkVm
    check chunk.functions[1].taskFrameKind == tfkGenerator
    check "task-frame=vm" in chunk.disassemble()
    check "task-frame=generator" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneTaskFrameInfo" in c
    check "static const GeneTaskFrameInfo gene_task_frames[] = {" in c
    check "{\"wait\", \"vm\", true}," in c
    check "{\"ints\", \"generator\", false}," in c

  test "direct protocol calls record selected impl dependencies":
    let source = "(protocol ToName (message to_name [self] : Str)) " &
                 "(type User ^props {^name Str}) " &
                 "(impl ToName User (message to_name [self] : Str self/name)) " &
                 "(to_name ^protocol ToName ^receiver User (User ^name \"Ada\"))"
    let chunk = compileSource(source)
    check chunk.directProtocolCalls.len == 1
    check chunk.directProtocolCalls[0].messageName == "to_name"
    check chunk.directProtocolCalls[0].protocolExpr.print() == "ToName"
    check chunk.directProtocolCalls[0].receiverExpr.print() == "User"
    check "direct-protocol-calls:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "direct-protocol to_name ToName/User" in c
    check "static const GeneDirectProtocolCall gene_direct_protocol_calls[] = {" in c
    check "{\"to_name\", \"ToName\", \"User\"}," in c
    check "static const size_t gene_direct_protocol_calls_count = 1;" in c
    check_eval(source, "\"Ada\"")
    expect GeneError:
      discard compileSource("(to_name ^protocol ToName x)")

  test "ffi/fn declarations expose generated C wrappers":
    let chunk = compileSource("(ffi/fn strlen " &
                              "  ^library libc ^symbol \"strlen\" " &
                              "  ^abi C ^calling cdecl " &
                              "  [s : C/CStr] : C/Size)")
    check chunk.ffiFns.len == 1
    check chunk.ffiFns[0].name == "strlen"
    check chunk.ffiFns[0].library == "libc"
    check chunk.ffiFns[0].symbol == "strlen"
    check chunk.ffiFns[0].abi == "C"
    check chunk.ffiFns[0].calling == "cdecl"
    check "ffi-fns:" in chunk.disassemble()
    check "calling=cdecl" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "generated FFI adapter wrappers" in c
    check "adapter skeletons" notin c
    check "typedef struct GeneFfiFnInfo" in c
    check "const char *calling;" in c
    check "#define GENE_FFI_CDECL" in c
    check "#define GENE_FFI_STDCALL __stdcall" in c
    check "static const GeneFfiFnInfo gene_ffi_fns[] = {" in c
    check "{\"strlen\", \"libc\", \"strlen\", \"C\", \"cdecl\", " &
      "\"gene_ffi_strlen\", \"\", 1, \"C/Size\"}," in c
    check "static const size_t gene_ffi_fns_count = 1;" in c
    check "extern size_t GENE_FFI_CDECL strlen(const char * s);" in c
    check "GeneStatus gene_ffi_strlen" in c
    check "calling: cdecl" in c
    check "arg 0 s: C/CStr -> const char *" in c
    check "result: C/Size -> GeneValue" in c
    check "GeneStatus status = gene_ffi_check_arity(ctx, call, 1);" in c
    check "status = gene_ffi_arg_cstr(ctx, call, 0, \"s\", &s);" in c
    check "size_t native_result = strlen(s);" in c
    check "return gene_ffi_result_size(ctx, native_result, result);" in c
    check "return GENE_FFI_WRAPPER_UNIMPLEMENTED;" notin c
    let stdcallC =
      compileSource("(ffi/fn WindowProc ^symbol \"WindowProc\" " &
                    "^calling stdcall [x : C/Int] : C/Int)").emitExperimentalC()
    check "extern int GENE_FFI_STDCALL WindowProc(int x);" in stdcallC
    expect GeneError:
      discard compileSource("(ffi/fn bad_calling ^symbol \"bad\" " &
                            "^calling vectorcall [] : C/Void)")
    check_eval("(ffi/fn strlen ^symbol \"strlen\" [s : C/CStr] : C/Size) strlen",
               "(native-fn strlen)")

  test "ffi/fn C wrappers marshal scalar, pointer, slice, and buffer ABI shapes":
    let source =
      "(ffi/fn c_abs ^symbol \"abs\" [x : C/Int] : C/Int) " &
      "(ffi/fn c_strerror ^symbol \"strerror\" [x : C/Int] : C/CStr) " &
      "(ffi/fn c_memchr ^symbol \"memchr\" " &
      "  [p : (C/ConstPtr C/Char) ch : C/Int n : C/Size] " &
      "  : (C/NullablePtr C/Char)) " &
      "(ffi/fn consume_slice ^symbol \"consume_slice\" " &
      "  [s : (C/Slice C/UInt8)] : C/Void) " &
      "(ffi/fn consume_buffer ^symbol \"consume_buffer\" " &
      "  [b : (Buffer C/UInt8)] : C/Void) " &
      "(ffi/fn make_owned ^symbol \"make_owned\" ^release \"destroy_owned\" " &
      "  [] : (C/OwnedPtr C/Char))"
    let c = compileSource(source).emitExperimentalC()
    check "static const size_t gene_ffi_fns_count = 6;" in c
    check "{\"make_owned\", \"\", \"make_owned\", \"C\", " &
      "\"C\", \"gene_ffi_make_owned\", \"destroy_owned\", 0, " &
      "\"(C/OwnedPtr C/Char)\"}," in c
    check "status = gene_ffi_arg_int(ctx, call, 0, \"x\", &x);" in c
    check "int native_result = abs(x);" in c
    check "return gene_ffi_result_int(ctx, native_result, result);" in c
    check "extern const char * GENE_FFI_CDECL strerror(int x);" in c
    check "const char * native_result = strerror(x);" in c
    check "return gene_ffi_result_cstr(ctx, native_result, result);" in c
    check "status = gene_ffi_arg_const_ptr(ctx, call, 0, \"p\", " &
      "\"(C/ConstPtr C/Char)\", &p);" in c
    check "return gene_ffi_result_ptr(ctx, (void *)native_result, " &
      "\"(C/NullablePtr C/Char)\", NULL, result);" in c
    check "extern void GENE_FFI_CDECL consume_slice(const void * s, size_t s_len);" in c
    check "status = gene_ffi_arg_buffer(ctx, call, 0, \"s\", " &
      "\"(C/Slice C/UInt8)\", &s_view);" in c
    check "consume_slice(s_view.data, s_view.len);" in c
    check "extern void GENE_FFI_CDECL consume_buffer(const void * b, size_t b_len);" in c
    check "GeneFfiBufferView b_view;" in c
    check "status = gene_ffi_arg_buffer(ctx, call, 0, \"b\", " &
      "\"(Buffer C/UInt8)\", &b_view);" in c
    check "consume_buffer(b_view.data, b_view.len);" in c
    check "return gene_ffi_result_void(ctx, result);" in c
    check "return gene_ffi_result_ptr(ctx, (void *)native_result, " &
      "\"(C/OwnedPtr C/Char)\", \"destroy_owned\", result);" in c
    check "return GENE_FFI_WRAPPER_UNIMPLEMENTED;" notin c
    expect GeneError:
      discard compileSource("(ffi/fn bad_any ^symbol \"bad\" [x : Any] : C/Int)")
    expect GeneError:
      discard compileSource("(ffi/fn bad_slice_result ^symbol \"bad\" " &
                            "[] : (C/Slice C/UInt8))")
    expect GeneError:
      discard compileSource("(ffi/fn bad_owned ^symbol \"bad\" " &
                            "[] : (C/OwnedPtr C/Char))")

  test "ffi/struct declarations expose C layout metadata manifests":
    let chunk = compileSource("(ffi/struct Timespec " &
                              "  ^size 16 ^align 8 " &
                              "  ^fields [[tv_sec C/Long ^offset 0] " &
                              "           [tv_nsec C/Long ^offset 8]])")
    check chunk.ffiStructs.len == 1
    check chunk.ffiStructs[0].name == "Timespec"
    check chunk.ffiStructs[0].layout == "C"
    check chunk.ffiStructs[0].hasSize
    check chunk.ffiStructs[0].size == 16
    check chunk.ffiStructs[0].hasAlign
    check chunk.ffiStructs[0].align == 8
    check chunk.ffiStructs[0].fields.len == 2
    check chunk.ffiStructs[0].fields[0].name == "tv_sec"
    check chunk.ffiStructs[0].fields[0].typeExpr.print() == "C/Long"
    check chunk.ffiStructs[0].fields[0].hasOffset
    check chunk.ffiStructs[0].fields[0].offset == 0
    check "ffi-structs:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneFfiStructInfo" in c
    check "typedef struct GeneFfiStructFieldInfo" in c
    check "typedef struct Timespec {" in c
    check "long tv_sec;" in c
    check "_Static_assert(sizeof(Timespec) == 16, " &
      "\"ffi/struct Timespec size mismatch\");" in c
    check "_Static_assert(GENE_ALIGNOF(Timespec) == 8, " &
      "\"ffi/struct Timespec align mismatch\");" in c
    check "_Static_assert(offsetof(Timespec, tv_nsec) == 8, " &
      "\"ffi/struct Timespec.tv_nsec offset mismatch\");" in c
    check "static const GeneFfiStructInfo gene_ffi_structs[] = {" in c
    check "{\"Timespec\", \"C\", 16, 8, 2}," in c
    check "{\"Timespec\", \"tv_sec\", \"C/Long\", 0}," in c
    let ptrChunk = compileSource("(ffi/struct HandleBox " &
                                 "  ^fields [[handle (C/Ptr C/Void)]])")
    let ptrC = ptrChunk.emitExperimentalC()
    check "typedef struct HandleBox {" in ptrC
    check "void * handle;" in ptrC
    check_eval("(ffi/struct Timespec ^fields [[tv_sec C/Long]]) Timespec",
               "Timespec")
    expect GeneError:
      discard compileSource("(ffi/struct BadSlice " &
                            "  ^fields [[view (C/Slice C/UInt8)]])")
    expect GeneError:
      discard compileSource("(ffi/struct BadBuffer " &
                            "  ^fields [[buf (Buffer C/UInt8)]])")

  test "ffi/union declarations expose C layout metadata manifests":
    let chunk = compileSource("(ffi/union IntOrDouble " &
                              "  ^size 8 ^align 8 " &
                              "  ^fields [[i C/Int] [d C/Double]])")
    check chunk.ffiUnions.len == 1
    check chunk.ffiUnions[0].name == "IntOrDouble"
    check chunk.ffiUnions[0].layout == "C"
    check chunk.ffiUnions[0].hasSize
    check chunk.ffiUnions[0].size == 8
    check chunk.ffiUnions[0].hasAlign
    check chunk.ffiUnions[0].align == 8
    check chunk.ffiUnions[0].fields.len == 2
    check chunk.ffiUnions[0].fields[0].name == "i"
    check chunk.ffiUnions[0].fields[0].typeExpr.print() == "C/Int"
    check "ffi-unions:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneFfiUnionInfo" in c
    check "typedef struct GeneFfiUnionFieldInfo" in c
    check "typedef union IntOrDouble {" in c
    check "int i;" in c
    check "double d;" in c
    check "_Static_assert(sizeof(IntOrDouble) == 8, " &
      "\"ffi/union IntOrDouble size mismatch\");" in c
    check "_Static_assert(GENE_ALIGNOF(IntOrDouble) == 8, " &
      "\"ffi/union IntOrDouble align mismatch\");" in c
    check "static const GeneFfiUnionInfo gene_ffi_unions[] = {" in c
    check "{\"IntOrDouble\", \"C\", 8, 8, 2}," in c
    check "{\"IntOrDouble\", \"i\", \"C/Int\"}," in c
    check_eval("(ffi/union IntOrDouble ^fields [[i C/Int]]) IntOrDouble",
               "IntOrDouble")
    expect GeneError:
      discard compileSource("(ffi/union Bad ^fields [[i C/Int ^offset 0]])")
    expect GeneError:
      discard compileSource("(ffi/union BadBuffer " &
                            "  ^fields [[buf (Buffer C/UInt8)]])")

  test "callback and dynamic FFI signatures expose metadata manifests":
    let chunk = compileSource(
      "(ffi/callback Comparator " &
      "  [lhs : (C/Ptr C/Void) rhs : (C/Ptr C/Void)] : C/Int) " &
      "(ffi/signature RuntimeCall ^abi C " &
      "  [value : Any] : C/Int)")
    check chunk.ffiSignatures.len == 2
    check chunk.ffiSignatures[0].name == "Comparator"
    check chunk.ffiSignatures[0].kind == fskCallback
    check not chunk.ffiSignatures[0].escaping
    check not chunk.ffiSignatures[0].runtimeConstructible
    check chunk.ffiSignatures[1].name == "RuntimeCall"
    check chunk.ffiSignatures[1].kind == fskDynamic
    check chunk.ffiSignatures[1].runtimeConstructible
    check "ffi-signatures:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "typedef struct GeneFfiSignatureInfo" in c
    check "static const GeneFfiSignatureInfo gene_ffi_signatures[] = {" in c
    check "{\"Comparator\", \"callback\", \"C\", " &
      "\"lhs:(C/Ptr C/Void),rhs:(C/Ptr C/Void)\", \"C/Int\", false, false}," in c
    check "{\"RuntimeCall\", \"dynamic\", \"C\", \"value:Any\", " &
      "\"C/Int\", false, true}," in c

suite "spec — strings from design":
  test "strings expose explicit chars and bytes iteration":
    check_eval("[(chars \"Aé\") (bytes \"Aé\")]",
               "[['A' 'é'] [65 195 169]]")

  test "graphemes expose combining scalar clusters":
    let s = "e\u0301x"
    check_eval("(graphemes \"" & s & "\")", "[\"e\u0301\" \"x\"]")

  test "dollar interpolation calls to-str-style display conversion":
    check_eval("(var name \"Ada\") $\"hello ${name}\"", "\"hello Ada\"")
    check_eval("$\"sum = $(+ 1 2)\"", "\"sum = 3\"")
    check_eval("(type User ^props {^name Str}) " &
               "(impl ToStr User (message to-str [self] : Str self/name)) " &
               "(var user (User ^name \"Ada\")) " &
               "$\"hello ${user}\"",
               "\"hello Ada\"")

suite "spec — equality and identity from design":
  test "same question mark is scalar identity or heap identity":
    check_eval("(var xs [1]) [(= [1] [1]) (same? [1] [1]) (same? xs xs)]",
               "[true false true]")

  test "hash follows equality for hash-stable values":
    check_eval("[(= (hash #[1 2]) (hash (freeze [1 2]))) " &
               " (= (hash (quote #(x @line 1 ^a 2))) " &
               "    (hash (quote #(x @line 99 ^a 2))))]",
               "[true true]")
    check_eval("(try (hash [1 2]) catch {^message m} m)",
               "\"hash expects a hash-stable value\"")
    check_eval("(try (hash #[(cell 1)]) catch {^message m} m)",
               "\"hash expects a hash-stable value\"")

  test "freeze helpers make mutability explicit":
    check_eval("[(freeze-shallow [1 [2]]) " &
               " (freeze [1 {^a [2]}]) " &
               " (thaw (freeze [1 {^a [2]}]))]",
               "[#[1 [2]] #[1 #{^a #[2]}] [1 {^a [2]}]]")
    check_eval("(try (freeze [(cell 1)]) catch {^message m} m)",
               "\"freeze cannot freeze Cell\"")

suite "spec — numeric boundaries from design":
  test "Int has mathematical integer semantics":
    check_eval("[(+ 9223372036854775807 1) " &
               " (* 100000000000000000000 100000000000000000000) " &
               " (< 9223372036854775808 9223372036854775809)]",
               "[9223372036854775808 " &
               "10000000000000000000000000000000000000000 " &
               "true]")

  test "fixed-width integer annotations are range checked":
    check_eval("(fn signed [x : SignedInt] x) " &
               "(fn unsigned [x : UnsignedInt] x) " &
               "[(signed -1) (unsigned 18446744073709551616)]",
               "[-1 18446744073709551616]")
    expect GeneError:
      discard run(compileSource("(fn unsigned [x : UnsignedInt] x) " &
                                "(unsigned -1)"),
                  newGlobalScope())
    check_eval("(fn byte [x : U8] x) [(byte 0) (byte 255)]", "[0 255]")
    expect GeneError:
      discard run(compileSource("(fn byte [x : U8] x) (byte 256)"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(fn small [x : I8] x) (small -129)"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(fn fixed [x : I64] x) " &
                                "(fixed 9223372036854775808)"),
                  newGlobalScope())
    check_eval("(fn single [x : F32] x) (single 3.5)", "3.5")
    check_eval("(try (fn single [x : F32] x) (single 1e39) " &
               "catch (TypeError ^expected e) e)",
               "\"F32\"")
    check_eval("(fn double [x : F64] 1) (double 1e39)", "1")

  test "C ABI scalar annotations are explicit range checked boundaries":
    check_eval("C/Int32", "(c-abi-type Int32)")
    check_eval("(fn int32 [x : C/Int32] x) " &
               "[(int32 -2147483648) (int32 2147483647)]",
               "[-2147483648 2147483647]")
    check_eval("(fn byte [x : C/UInt8] x) [(byte 0) (byte 255)]",
               "[0 255]")
    check_eval("(fn cbool [x : C/Bool] x) (cbool false)", "false")
    check_eval("(fn cstr [x : C/CStr] x) (cstr \"ok\")", "\"ok\"")
    check_eval("(try (fn int32 [x : C/Int32] x) (int32 2147483648) " &
               "catch (TypeError ^expected e) e)",
               "\"C/Int32\"")
    check_eval("(try (fn cstr [x : C/CStr] x) (cstr \"bad\\0str\") " &
               "catch (TypeError ^expected e) e)",
               "\"C/CStr\"")

  test "C pointer annotations are opaque checked boundaries":
    var releases = 0
    proc releasePtr(address: pointer) {.nimcall.} =
      inc releases

    let scope = newGlobalScope()
    scope.define("ptr", newCPtr(cast[pointer](0x1234'u), newSym("C/Char")))
    scope.define("const_ptr",
                 newCConstPtr(cast[pointer](0x2345'u), newSym("C/Char")))
    scope.define("owned",
                 newCOwnedPtr(cast[pointer](0x3456'u), releasePtr,
                              newSym("C/Char")))

    check run(compileSource("((fn [p : (C/Ptr C/Char)] p) ptr)"),
              scope).print() == "(c-ptr)"
    check run(compileSource("((fn [p : (C/ConstPtr C/Char)] p) const_ptr)"),
              scope).print() == "(c-const-ptr)"
    check run(compileSource("((fn [p : (C/NullablePtr C/Char)] true) nil)"),
              scope).print() == "true"
    check run(compileSource("((fn [p : (C/OwnedPtr C/Char)] true) owned)"),
              scope).print() == "true"
    expect GeneError:
      discard run(compileSource("((fn [p : (C/Ptr C/Char)] p) const_ptr)"),
                  scope)
    check run(compileSource("[(C/close owned) (C/closed? owned)]"),
              scope).print() == "[nil true]"
    check releases == 1

  test "C slice annotations are opaque pointer-length boundaries":
    let scope = newGlobalScope()
    scope.define("slice", newCSlice(cast[pointer](0x4567'u), 8,
                                    newSym("C/Char")))
    scope.define("empty", newCSlice(nil, 0, newSym("C/Char")))
    scope.define("other", newCSlice(cast[pointer](0x5678'u), 8,
                                    newSym("C/Int32")))

    check run(compileSource("((fn [s : (C/Slice C/Char)] s) slice)"),
              scope).print() == "(c-slice 8)"
    check run(compileSource("((fn [s : (C/Slice C/Char)] s) empty)"),
              scope).print() == "(c-slice null 0)"
    expect GeneError:
      discard run(compileSource("((fn [s : (C/Slice C/Char)] s) other)"),
                  scope)

  test "Buffer annotations are Gene-owned typed storage":
    check_eval("(var b (buffer C/UInt8 [1 2])) " &
               "[(Buffer/len b) (Buffer/get b 1) " &
               "(Buffer/set! b 0 9) (Buffer/to_list b)]",
               "[2 2 9 [9 2]]")
    check_eval("((fn [b : (Buffer C/UInt8)] true) " &
               "(buffer C/UInt8 [1 2]))",
               "true")
    check_eval("((fn [b : (Buffer Int)] true) (buffer [1 2]))", "true")
    expect GeneError:
      discard run(compileSource("(buffer C/UInt8 [256])"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("((fn [b : (Buffer C/UInt8)] b) " &
                                "(buffer C/Int32 [1]))"),
                  newGlobalScope())

  test "Device buffers are opaque native-compute handles":
    check_eval("(var b (Device/buffer Device/Compute \"mock\" C/Int64 4)) " &
               "[(Device/Buffer/backend b) " &
               " (Device/Buffer/elem-type b) " &
               " (Device/Buffer/len b) " &
               " ((fn [buf : Device/Buffer] (Device/Buffer/len buf)) b) " &
               " ((fn [buf : (Device/Buffer C/Int64)] " &
               "    (Device/Buffer/elem-type buf)) b) " &
               " b]",
               "[\"mock\" C/Int64 4 4 C/Int64 (device-buffer mock C/Int64 4)]")
    expect GeneError:
      discard run(compileSource("(Device/buffer nil \"mock\" C/Int64 1)"),
                  newGlobalScope())
    check_eval("(var b (Device/buffer Device/Compute \"mock\" C/Int64 4)) " &
               "(try ((fn [buf : (Device/Buffer F64)] buf) b) " &
               "catch (TypeError ^expected e) e)",
               "\"(Device/Buffer F64)\"")

  test "FFI runtime loading requires explicit authority":
    check_eval("Ffi/Load", "(ffi-type Load)")
    let scope = newGlobalScope()
    scope.define("native", newFfiLoadCapability())
    check run(compileSource("((fn [cap : Ffi/Load] cap) native)"),
              scope).print() == "(ffi-load)"
    expect GeneError:
      discard run(compileSource("((fn [cap : Ffi/Load] cap) nil)"), scope)
    expect GeneError:
      discard run(compileSource("(ffi/open nil \"libmissing-gene-new\")"),
                  scope)
    expect GeneError:
      discard run(compileSource("(ffi/open native \"libmissing-gene-new\")"),
                  scope)

suite "spec — nominal types from design":
  test "child types preserve inherited field schemas":
    expect GeneError:
      discard run(compileSource("(type Animal ^props {^name Str}) " &
                                "(type Dog ^is Animal ^props {^name Any})"),
                  newGlobalScope())

  test "type body schemas validate positional node body":
    check_eval("(type Note ^props {^text Str}) " &
               "(type Task ^props {^id Int} ^body [Note...]) " &
               "(var t (Task ^id 1 (Note ^text \"a\") (Note ^text \"b\"))) " &
               "[(t ~ /id) ((t ~ /0) ~ /text) ((t ~ /1) ~ /text)]",
               "[1 \"a\" \"b\"]")
    check_eval("(type Pair ^body [Int Str]) " &
               "(try (Pair 1 2) catch (TypeError ^where w) w)",
               "\"body field 1 for Pair\"")

  test "type layout promises are reserved":
    expect GeneError:
      discard compileSource("(type Packed ^sealed true ^props {})")

suite "spec — typed variable boundaries from design":
  test "var annotations check gradual boundaries":
    check_eval("(var result : Int (eval (quote (+ 20 22)) ^in (env))) result",
               "42")
    check_eval("(try (var result : Int (eval (quote \"bad\") ^in (env))) result " &
               "catch (TypeError ^where w) w)",
               "\"var 'result'\"")
  test "set checks typed variable boundaries":
    check_eval("(var result : Int 1) (set result 42) result", "42")
    check_eval("(try (var result : Int 1) (set result \"bad\") result " &
               "catch (TypeError ^where w) w)",
               "\"set 'result'\"")
    check_eval("(try (fn f [x : Int] (set x \"bad\") x) (f 1) " &
               "catch (TypeError ^where w) w)",
               "\"set 'x'\"")
    check_eval("(try (var s : (Stream Int Never) (to_stream [1])) " &
               "     (set s (to_stream [\"bad\"])) " &
               "     (s ~ Stream/next) " &
               "catch (TypeError ^where w) w)",
               "\"Stream/next item\"")

  test "callable runtime values have explicit boundary types":
    check_eval("(fn keep-native [f : NativeFn] f) (keep-native +)",
               "(native-fn +)")
    check_eval("(try (fn keep-fn [f : Fn] f) (keep-fn +) " &
               "catch (TypeError ^expected e) e)",
               "\"Fn\"")
    check_eval("(fn keep-selector [s : Selector] s) (keep-selector /name)",
               "(select name)")
    check_eval("(try (fn keep-selector [s : Selector] s) " &
               "     (keep-selector (quote (name))) " &
               "catch (TypeError ^expected e) e)",
               "\"Selector\"")
    check_eval("(fn keep-callable [f : Callable] f) (keep-callable +)",
               "(native-fn +)")
    check_eval("(type AddN ^props {^n Int}) " &
               "(impl Callable AddN " &
               "  (message apply [self call] (+ self/n (call ~ /0)))) " &
               "(fn invoke [f : Callable] (f 2)) " &
               "(invoke (AddN ^n 3))",
               "5")
    # The Call envelope exposes the source call site (design §3 `^site? Node`).
    check_eval("(type Probe ^props {}) " &
               "(impl Callable Probe (message apply [self call] call/site)) " &
               "(var p (Probe)) (p 1 2)",
               "(p 1 2)")

suite "spec — generic functions from design":
  test "generic function calls infer type parameters locally":
    check_eval("(fn (identity item) [x : item] : item x) " &
               "[(identity 1) (identity \"ok\")]",
               "[1 \"ok\"]")
    check_eval("(fn (get key value) [m : (Map key value)] : value m/a) " &
               "(get {^a 9})",
               "9")
    check_eval("(fn ints [] : (Stream Int Never) (yield 7)) " &
               "(fn (first item err) [s : (Stream item err)] : item " &
               "  (s ~ Stream/next)) " &
               "(first (ints))",
               "7")
    check_eval("(fn (first item) [b : (Buffer item)] : item " &
               "  (Buffer/get b 0)) " &
               "(first (buffer [5 6]))",
               "5")

  test "generic calls can request selective monomorphization metadata":
    let chunk = compileSource("(fn (identity item) [x : item] : item x) " &
                              "(identity ^types [Int] 1)")
    check chunk.monomorphizations.len == 1
    check chunk.monomorphizations[0].functionName == "identity"
    check chunk.monomorphizations[0].typeArgs[0].print() == "Int"
    check "monomorphizations:" in chunk.disassemble()
    let c = chunk.emitExperimentalC()
    check "identity<Int>" in c
    check "static const GeneMonomorphizationSpec gene_monomorphizations[] = {" in c
    check "{\"identity\", \"Int\"}," in c
    check_eval("(fn (identity item) [x : item] : item x) " &
               "(identity ^types [Int] 1)",
               "1")
    expect GeneError:
      discard compileSource("(fn (identity item) [x : item] : item x) " &
                            "(identity ^types Int 1)")

suite "spec — static effects from design":
  test "^effects rows are reserved in MVP":
    expect GeneError:
      discard compileSource("(fn f ^effects [fs] [] 1)")
    expect GeneError:
      discard compileSource("(protocol Run " &
                            "  (message run ^effects [fs] [self]))")
    expect GeneError:
      discard compileSource("(protocol Run (message run [self])) " &
                            "(impl Run Job " &
                            "  (message run ^effects [fs] [self] 1))")

suite "spec — checked errors from design":
  test "Never contributes no errors and rows deduplicate":
    check_eval("(fn quiet ^errors [Never] [] 1) (quiet)", "1")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(fn raise-boom ^errors [Never Boom Boom] [] " &
               "  (fail (Boom ^message \"x\"))) " &
               "(try (raise-boom) catch (Boom ^message m) m)",
               "\"x\"")

suite "spec — pattern destructuring from design":
  test "match and catch bindings are branch-local":
    expect GeneError:
      discard run(compileSource("(match [1 2] (when [a b] (+ a b))) a"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(type Boom ^props {^message Str} ^impl [Error]) " &
                                "(impl Error Boom) " &
                                "(try (fail (Boom ^message \"x\")) " &
                                "catch (Boom ^message m) m) m"),
                  newGlobalScope())
  test "alternation alternatives bind the same names":
    check_eval("(match [2 7] (when (| [1 a] [2 a]) a))", "7")
    expect GeneError:
      discard run(compileSource("(match [1] (when (| [a] [b]) a))"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(match 1 (when (not x) \"no\") (else \"ok\"))"),
                  newGlobalScope())
  test "meta patterns opt into matching meta":
    check_eval("(match (quote (x @line 7 ^name \"Ada\")) " &
               "  (when (@ {^line l} (x ^name n)) [l n]))",
               "[7 \"Ada\"]")
    check_eval("(match (quote (x @line 7 ^name \"Ada\")) " &
               "  (when (x ^name n) n))",
               "\"Ada\"")
  test "typed patterns bind and require the declared type":
    check_eval("(match \"Ada\" (when (s : Str) s) (else \"no\"))",
               "\"Ada\"")
    check_eval("(match 7 (when (s : Str) s) (else \"no\"))",
               "\"no\"")
    check_eval("(try (fn f [x : Int] x) (f \"bad\") " &
               "catch (e : TypeError) e/where)",
               "\"parameter 'x'\"")

suite "spec — protocol derive from design":
  test "protocol-local derive can generate an impl":
    check_eval("(protocol HasLabel " &
               "  (message label [self] : Str) " &
               "  (derive [t : Type, req] " &
               "    `(impl HasLabel %t " &
               "       (message label [self] : Str self/name)))) " &
               "(type MenuItem ^props {^name Str} ^derive [HasLabel]) " &
               "(label (MenuItem ^name \"Soup\"))",
               "\"Soup\"")

  test "protocol-local derive is limited to its own impls":
    expect GeneError:
      discard run(compileSource("(protocol Other) " &
                                "(protocol HasLabel " &
                                "  (derive [t : Type, req] `(impl Other %t))) " &
                                "(type MenuItem ^props {^name Str} " &
                                "  ^derive [HasLabel])"),
                  newGlobalScope())

suite "spec — cells from design":
  test "Cell get, set, swap, and update are explicit mutation":
    check_eval("(var count (cell 0)) " &
               "[(count ~ Cell/get) " &
               " (count ~ Cell/set 10) " &
               " (count ~ Cell/swap 20) " &
               " (count ~ Cell/update (fn [x] (+ x 1))) " &
               " (count ~ Cell/get)]",
               "[0 10 10 21 21]")

suite "spec — atomic cells from design":
  test "AtomicCell load, store, swap, and compare-exchange are explicit mutation":
    check_eval("(var state (atomic-cell 0)) " &
               "[(state ~ AtomicCell/load) " &
               " (state ~ AtomicCell/store 1) " &
               " (state ~ AtomicCell/swap 2) " &
               " (state ~ AtomicCell/compare-exchange 2 3) " &
               " (state ~ AtomicCell/load)]",
               "[0 1 1 true 3]")

suite "spec — mutable containers from design":
  test "persistent and mutating container updates are explicit":
    check_eval("(var xs #[1 2 3]) " &
               "(var xs2 (xs ~ List/assoc 1 20)) " &
               "(var ys [1 2]) " &
               "(ys ~ List/set! 0 9) " &
               "(var m #{^a 1}) " &
               "(var m2 (m ~ Map/assoc \"b\" 2)) " &
               "(var mm {^a 1}) " &
               "(mm ~ Map/put! \"b\" 3) " &
               "(var n (quote (user ^name \"Ada\"))) " &
               "(n ~ Node/set-prop! \"name\" \"Bob\") " &
               "[xs xs2 ys m m2 (mm ~ Map/get \"b\") (n ~ /name)]",
               "[#[1 2 3] #[1 20 3] [9 2] #{^a 1} #{^a 1 ^b 2} 3 \"Bob\"]")

suite "spec — void normalization from design":
  test "void does not persist in prop storage":
    check_eval("[{^a void ^b 1} " &
               " (quote (x ^a void ^b 1)) " &
               " (do (type T ^props {^a? Int}) " &
               "     (var t (T ^a void)) " &
               "     t/a)]",
               "[{^b 1} (x ^b 1) void]")

suite "spec — streams from design":
  test "streams expose pull operations":
    check_eval("(var s (to_stream [1 2])) " &
               "[(s ~ Stream/has_next) " &
               " (s ~ Stream/peek) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/has_next)]",
               "[true 1 1 2 false]")

  test "next on an exhausted stream raises EndOfStream":
    check_eval("(try (var s (to_stream [])) (s ~ Stream/next) " &
               "catch (EndOfStream ^message m) m)",
               "\"end of stream\"")

  test "stream helpers map, filter, take, and materialize":
    check_eval("(var s (take " &
               "  (filter " &
               "    (map (to_stream [1 2 3]) (fn [x] (+ x 1))) " &
               "    (fn [x] (> x 2))) " &
               "  2)) " &
               "[(s ~ Stream/next) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/has_next) " &
               " (do (var pairs (to_pairs_stream {^a 1})) " &
               "     (pairs ~ Stream/next)) " &
               " (into (to_pairs_stream {^a 1}) {})]",
               "[3 4 false [a 1] {^a 1}]")
    check_eval("(var pairs (to_pairs_stream {^a 1})) " &
               "(var pair (pairs ~ Stream/next)) " &
               "(fn key [x : Sym] x) (key pair/0)",
               "a")

  test "stream helpers are lazy":
    check_eval("(var hits (cell 0)) " &
               "(var s (map (to_stream [1 2]) " &
               "            (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
               "[(hits ~ Cell/get) " &
               " (s ~ Stream/next) " &
               " (hits ~ Cell/get)]",
               "[0 1 1]")

  test "yield functions return lazy streams":
    check_eval("(var hits (cell 0)) " &
               "(fn gen [] : (Stream Int Never) " &
               "  (hits ~ Cell/set 1) " &
               "  (yield 10) " &
               "  (hits ~ Cell/set 2) " &
               "  (yield 20)) " &
               "(var s (gen)) " &
               "[(hits ~ Cell/get) " &
               " (s ~ Stream/next) " &
               " (hits ~ Cell/get) " &
               " (s ~ Stream/next) " &
               " (hits ~ Cell/get) " &
               " (s ~ Stream/has_next)]",
               "[0 10 1 20 2 false]")

  test "yield skips void and resumes while loops":
    check_eval("(fn nums [] : (Stream Int Never) " &
               "  (var i 0) " &
               "  (while (< i 3) " &
               "    (yield (if (= i 1) void i)) " &
               "    (set i (+ i 1)))) " &
               "(var s (nums)) " &
               "[(s ~ Stream/next) " &
               " (s ~ Stream/next) " &
               " (s ~ Stream/has_next)]",
               "[0 2 false]")

  test "yield resumes for loops lazily":
    check_eval("(var hits (cell 0)) " &
               "(var source (map (to_stream [1 2 3]) " &
               "  (fn [x] (hits ~ Cell/update (fn [n] (+ n 1))) x))) " &
               "(fn copy [s] : (Stream Int Never) " &
               "  (for x s (yield x))) " &
               "(var out (copy source)) " &
               "[(hits ~ Cell/get) " &
               " (out ~ Stream/next) " &
               " (hits ~ Cell/get) " &
               " (out ~ Stream/next) " &
               " (hits ~ Cell/get)]",
               "[0 1 1 2 2]")

  test "typed stream boundaries check items when pulled":
    check_eval("(try (fn first [s : (Stream Int Never)] (s ~ Stream/next)) " &
               "     (first (to_stream [\"bad\"])) " &
               "catch (TypeError ^where w) w)",
               "\"Stream/next item\"")
    check_eval("(try (fn bad [] : (Stream Int Never) (yield \"bad\")) " &
               "     (var s (bad)) " &
               "     (s ~ Stream/next) " &
               "catch (TypeError ^where w) w)",
               "\"Stream/next item\"")

  test "yield is only valid inside functions":
    expect GeneError:
      discard compileSource("(yield 1)")

  test "selectors map static lookup over stream items":
    check_eval("(var users [{^name \"Ada\"} {^age 37} {^name \"Bob\"}]) " &
               "(var names users/%to_stream/name) " &
               "[(names ~ Stream/next) " &
               " (names ~ Stream/next) " &
               " (names ~ Stream/has_next)]",
               "[\"Ada\" \"Bob\" false]")

  test "selector strict and default options make missing lookup explicit":
    check_eval("(var fallback \"unknown\") " &
               "[((select ^default fallback name) {^age 37}) " &
               " ((select ^default fallback name) {^name nil})]",
               "[\"unknown\" nil]")
    check_eval("(try ((select ^strict true name) {^age 37}) " &
               "catch {^message m} m)",
               "\"selector lookup failed at segment: name\"")
    check_eval("(try ((select ^strict true ^default \"unknown\" name) {^age 37}) " &
               "catch {^message m} m)",
               "\"selector lookup failed at segment: name\"")

  test "list selectors expose fixed members":
    check_eval("(var xs [10 20 30]) " &
               "[(xs ~ /size) (xs ~ /empty?) (xs ~ /first) (xs ~ /last)]",
               "[3 false 10 30]")
    check_eval("(var xs []) [(xs ~ /empty?) (xs ~ /first) (xs ~ /last)]",
               "[true void void]")

  test "complex selector stages adapt stream helpers":
    check_eval("(var users [{^name \"Ada\" ^adult true} " &
               "            {^name \"Tim\" ^adult false} " &
               "            {^name \"Bob\" ^adult true}]) " &
               "(var names ((select %to_stream %(filter /adult) name) users)) " &
               "[(names ~ Stream/next) " &
               " (names ~ Stream/next) " &
               " (names ~ Stream/has_next)]",
               "[\"Ada\" \"Bob\" false]")
    check_eval("(var users [{^name \"Ada\"} {^name \"Bob\"} {^name \"Cy\"}]) " &
               "((select %to_stream %(map /name) %(take 2) %(into [])) users)",
               "[\"Ada\" \"Bob\"]")

  test "selector key wrappers force dynamic key lookup":
    check_eval("(var field \"name\") " &
               "(var get-name (select %(key field))) " &
               "(get-name {^name \"Ada\"})",
               "\"Ada\"")
    check_eval("(var plus +) " &
               "[((select %plus) 4) ((select %(key plus)) 4)]",
               "[4 void]")

  test "declarations is an ordinary stream selector stage":
    check_eval("(ns m (var b 2) (var a 1)) " &
               "(var names m/%declarations/name) " &
               "[(names ~ Stream/next) " &
               " (names ~ Stream/next) " &
               " (names ~ Stream/has_next)]",
               "[\"a\" \"b\" false]")

  test "this-mod exposes the current module declaration stream":
    let scope = newGlobalScope()
    discard bindThisModule(scope, "spec")
    check run(compileSource("(var x 9) " &
                            "(var ds (filter (this-mod ~ Module/declarations) " &
                            "  (fn [d] (= d/name \"x\")))) " &
                            "(var decl (ds ~ Stream/next)) " &
                            "[(/value decl) (this-mod ~ Module/path)]"),
              scope).print() == "[9 nil]"

suite "spec — structured tasks from design":
  test "scope owns spawned tasks and await returns the result":
    check_eval("(scope " &
               "  (var a (spawn (+ 1 2))) " &
               "  (var b (spawn (+ 3 4))) " &
               "  (+ (await a) (await b)))",
               "10")

  test "spawn queues child work and CPU tasks yield at safepoints":
    check_eval("(scope (var out (cell 0)) " &
               "  (var slow (spawn (do " &
               "    (var i 0) " &
               "    (while (< i 5000) (set i (+ i 1))) " &
               "    (out ~ Cell/set 1)))) " &
               "  (var fast (spawn (out ~ Cell/set 2))) " &
               "  (await fast) " &
               "  [(out ~ Cell/get) (await slow) (out ~ Cell/get)])",
               "[2 1 1]")

  test "worker-candidate spawns snapshot Send captures":
    check_eval("(scope (var x 1) " &
               "  (var t (spawn x)) " &
               "  (set x 2) " &
               "  (await t))",
               "1")
    check_eval("(scope (var x 1) " &
               "  (fn read [n] (+ x n)) " &
               "  (var t (spawn (read 2))) " &
               "  (set x 10) " &
               "  (await t))",
               "3")
    check_eval("(scope (var c (cell 0)) " &
               "  (var t (spawn (c ~ Cell/get))) " &
               "  (c ~ Cell/set 2) " &
               "  (await t))",
               "2")
    check_eval("(scope (var x 41) " &
               "  (var t (spawn (fn [] (+ x 1)))) " &
               "  ((await t)))",
               "42")

  test "timer waits suspend only the current task":
    check_eval("(scope (var out (cell 0)) " &
               "  (var slow (spawn (do (sleep 5) (out ~ Cell/set 1)))) " &
               "  (var fast (spawn (out ~ Cell/set 2))) " &
               "  (await fast) " &
               "  [(out ~ Cell/get) (await slow) (out ~ Cell/get)])",
               "[2 1 1]")

  test "scope normal exit waits for live child tasks":
    check_eval("(var out (cell 0)) " &
               "(scope (var ch (channel ^capacity 1)) " &
               "  (spawn (do (ch ~ Channel/recv) (out ~ Cell/set 7))) " &
               "  (spawn (ch ~ Channel/send 1)) " &
               "  nil) " &
               "(out ~ Cell/get)",
               "7")

  test "await propagates recoverable task errors":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(scope " &
               "  (var t (spawn (fail (Boom ^message \"boom\")))) " &
               "  (try (await t) catch (Boom ^message m) m))",
               "\"boom\"")

  test "await propagates task cancellation outside catch":
    expect GeneCancel:
      discard run(compileSource("(scope (var ch (channel ^capacity 1)) " &
                                "  (var t (spawn (ch ~ Channel/recv))) " &
                                "  (t ~ Task/cancel) " &
                                "  (try (await t) catch _ \"caught\"))"),
                  newGlobalScope())

  test "scope error exit cancels pending child tasks":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(var ch (channel ^capacity 1)) " &
               "(var out (cell 0)) " &
               "(try " &
               "  (scope " &
               "    (spawn (do (ch ~ Channel/recv) (out ~ Cell/set 1))) " &
               "    (fail (Boom ^message \"stop\"))) " &
               "  catch (Boom) nil) " &
               "(ch ~ Channel/send 1) " &
               "(scope nil) " &
               "(out ~ Cell/get)",
               "0")

  test "scope error exit waits for child cancellation cleanup":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(var ch (channel ^capacity 1)) " &
               "(var out (cell 0)) " &
               "(try " &
               "  (scope " &
               "    (spawn (try (ch ~ Channel/recv) " &
               "                ensure (out ~ Cell/set 9))) " &
               "    (sleep 1) " &
               "    (fail (Boom ^message \"stop\"))) " &
               "  catch (Boom) nil) " &
               "(out ~ Cell/get)",
               "9")

  test "detached tasks outlive scope ownership":
    check_eval("(var out (cell 0)) " &
               "(scope " &
               "  (var t (spawn (do (sleep 5) (out ~ Cell/set 1)))) " &
               "  (t ~ Task/detach) " &
               "  nil) " &
               "[(out ~ Cell/get) (sleep 10) (out ~ Cell/get)]",
               "[0 nil 1]")

  test "Task annotations accept task handles":
    check_eval("(scope (var t : (Task Int Never) (spawn 1)) t)", "(task)")

  test "Task annotations validate results and errors when awaited":
    check_eval("(scope " &
               "  (fn use [t : (Task Int Never)] (await t)) " &
               "  (use (spawn 5)))",
               "5")
    check_eval("(scope " &
               "  (fn use [t : (Task Int Never)] " &
               "    (try (await t) catch (TypeError ^where w) w)) " &
               "  (use (spawn \"bad\")))",
               "\"await task result\"")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(type Other ^props {^message Str} ^impl [Error]) " &
               "(impl Error Other) " &
               "(scope " &
               "  (fn use [t : (Task Int Boom)] " &
               "    (try (await t) catch (TypeError ^where w) w)) " &
               "  (use (spawn (fail (Other ^message \"bad\")))))",
               "\"await task error\"")

suite "spec — bounded channels from design":
  test "channels send, receive, and close in FIFO order":
    check_eval("(var ch (channel ^capacity 2)) " &
               "(ch ~ Channel/send 1) " &
               "(ch ~ Channel/send 2) " &
               "(ch ~ Channel/close) " &
               "[(ch ~ Channel/recv) " &
               " (ch ~ Channel/recv) " &
               " (try (ch ~ Channel/recv) catch (ChannelClosed ^message m) m)]",
               "[1 2 \"channel is closed\"]")
    check_eval("(scope (var ch (channel ^capacity 1)) " &
               "  (var t (spawn (try (ch ~ Channel/recv) " &
               "                  catch (ChannelClosed ^message m) m))) " &
               "  (spawn (ch ~ Channel/close)) " &
               "  (await t))",
               "\"channel is closed\"")
    check_eval("(scope (var ch (channel ^capacity 1)) " &
               "  (ch ~ Channel/send 1) " &
               "  (var t (spawn (try (ch ~ Channel/send 2) " &
               "                  catch (ChannelClosed ^message m) m))) " &
               "  (spawn (ch ~ Channel/close)) " &
               "  (await t))",
               "\"channel is closed\"")

  test "try-send and try-recv expose non-suspending channel checks":
    check_eval("(var ch (channel ^capacity 1)) " &
               "[(ch ~ Channel/try-send 1) " &
               " (ch ~ Channel/try-send 2) " &
               " (ch ~ Channel/recv) " &
               " (same? (ch ~ Channel/try-recv) void)]",
               "[true false 1 true]")

  test "typed channel boundaries check items before enqueue":
    check_eval("(var ch : (Channel Int) (channel)) " &
               "(try (ch ~ Channel/send \"bad\") catch (TypeError ^where w) w)",
               "\"Channel/send item\"")

  test "channel sends enforce dynamic Send values":
    check_eval("(var ch (channel)) " &
               "(ch ~ Channel/send #[1 #{^a 2}]) " &
               "(ch ~ Channel/recv)",
               "#[1 #{^a 2}]")
    check_eval("(var ch (channel)) " &
               "(var captured #[1 #{^a 2}]) " &
               "(var f (fn [] captured)) " &
               "(ch ~ Channel/send f) " &
               "(var g (ch ~ Channel/recv)) " &
               "(g)",
               "#[1 #{^a 2}]")
    check_eval("(var ch (channel)) " &
               "(var f (fn [x y = x] y)) " &
               "(ch ~ Channel/send f) " &
               "(var g (ch ~ Channel/recv)) " &
               "(g 7)",
               "7")
    check_eval("(var ch (channel)) " &
               "(try (ch ~ Channel/send [1]) catch (TypeError ^expected e) e)",
               "\"Send\"")
    check_eval("(var ch (channel)) " &
               "(try (ch ~ Channel/send #[(cell 1)]) " &
               "catch (TypeError ^where w) w)",
               "\"Channel/send item\"")
    check_eval("(var ch (channel)) " &
               "(var captured (cell 1)) " &
               "(var f (fn [] (captured ~ Cell/get))) " &
               "(try (ch ~ Channel/send f) catch (TypeError ^expected e) e)",
               "\"Send\"")

suite "spec — actors from design":
  test "actor send processes messages sequentially":
    check_eval("(var out (cell 0)) " &
               "(fn handle [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  (var next (+ state msg)) " &
               "  (out ~ Cell/set next) " &
               "  (actor/continue next)) " &
               "(var counter : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(counter ~ actor/send 2) " &
               "(counter ~ actor/send 5) " &
               "(out ~ Cell/get)",
               "7")

  test "actor snapshots expose idle state metadata":
    check_eval("(fn handle [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  (actor/continue (+ state msg))) " &
               "(var counter : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(counter ~ actor/send 2) " &
               "(counter ~ actor/send 5) " &
               "(var snap (counter ~ actor/snapshot)) " &
               "[snap/state snap/mailbox snap/closed snap/processing]",
               "[7 0 false false]")

  test "actor upgrade replaces idle handlers with migration rollback":
    check_eval("(fn add [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  (actor/continue (+ state msg))) " &
               "(fn mul [ctx : (ActorContext Int), state : Int, msg : Int] : (ActorStep Int) " &
               "  (actor/continue (* state msg))) " &
               "(var counter : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 1) ^handle add)) " &
               "(counter ~ actor/send 2) " &
               "(actor/upgrade counter mul ^migrate (fn [state] (+ state 1))) " &
               "(counter ~ actor/send 3) " &
               "(var before (counter ~ actor/snapshot)) " &
               "(var err (try (actor/upgrade counter 99) " &
               "  catch (TypeError ^where w) w)) " &
               "(counter ~ actor/send 2) " &
               "(var after (counter ~ actor/snapshot)) " &
               "[before/state err after/state]",
               "[12 \"actor/upgrade handler\" 24]")

  test "actor stop closes the actor":
    check_eval("(var a : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (actor/stop)))) " &
               "(a ~ actor/send 1) " &
               "(try (a ~ actor/send 2) catch (ActorClosed ^message m) m)",
               "\"actor is closed\"")

  test "actor sends require typed Send messages":
    check_eval("(var a : (ActorRef Int) " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (actor/continue state)))) " &
               "(try (a ~ actor/send \"bad\") catch (TypeError ^where w) w)",
               "\"actor/send message\"")
    check_eval("(var a (actor/spawn ^init (fn [] 0) " &
               "  ^handle (fn [ctx state msg] (actor/continue state)))) " &
               "(try (a ~ actor/send [1]) catch (TypeError ^expected e) e)",
               "\"Send\"")

  test "actor ask uses an explicit one-shot ReplyTo capability":
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send Get) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (match msg " &
               "    (when (Get ^reply reply) " &
               "      (reply ~ ReplyTo/send state) " &
               "      (actor/continue state)))) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 41) ^handle handle)) " &
               "(await (counter ~ actor/ask (fn [reply] (Get ^reply reply))))",
               "41")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send Get) " &
               "(scope " &
               "  (var counter : (ActorRef Get) " &
               "    (actor/spawn ^init (fn [] 41) " &
               "      ^handle (fn [ctx state msg] " &
               "        (match msg " &
               "          (when (Get ^reply reply) " &
               "            (reply ~ ReplyTo/send state) " &
               "            (actor/continue state)))))) " &
               "  (fn (choose result err) [t : (Task result err) fallback : result] " &
               "    fallback) " &
               "  (try (choose (counter ~ actor/ask (fn [reply] (Get ^reply reply))) \"bad\") " &
               "       catch (TypeError ^expected e) e))",
               "\"Int\"")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send Get) " &
               "(var ch (channel ^capacity 1)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var got (ch ~ Channel/recv)) " &
               "  (match msg " &
               "    (when (Get ^reply reply) " &
               "      (reply ~ ReplyTo/send (+ state got)) " &
               "      (actor/continue state)))) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 40) ^handle handle)) " &
               "(var pending (counter ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
               "(ch ~ Channel/send 2) " &
               "(await pending)",
               "42")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send Get) " &
               "(var ch (channel ^capacity 1)) " &
               "(var out (cell 0)) " &
               "(fn handle [ctx : (ActorContext Get), state : Int, msg : Get] : (ActorStep Int) " &
               "  (var (Get ^reply reply) msg) " &
               "  (var got (ch ~ Channel/recv)) " &
               "  (reply ~ ReplyTo/send got) " &
               "  (out ~ Cell/set got) " &
               "  (actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(var pending (actor/ask ^timeout-ms 5 counter (fn [reply] (Get ^reply reply)))) " &
               "(var err (try (await pending) catch (ActorError ^message m) m)) " &
               "(ch ~ Channel/send 7) " &
               "[err (sleep 1) (out ~ Cell/get)]",
               "[\"actor/ask timed out\" nil 7]")
    check_eval("(scope " &
               "  (type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send Get) " &
               "(var saved (cell nil)) " &
               "(var ch (channel ^capacity 1)) " &
               "(fn handle [ctx state msg] " &
               "  (var (Get ^reply reply) msg) " &
               "  (var got (ch ~ Channel/recv)) " &
               "  (try (reply ~ ReplyTo/send got) catch {^message m} m) " &
               "  (actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(var pending (actor/ask ^timeout-ms 5 counter " &
               "  (fn [reply] (saved ~ Cell/set reply) (Get ^reply reply)))) " &
               "(var err (try (await pending) catch (ActorError ^message m) m)) " &
               "(var first-late (try ((saved ~ Cell/get) ~ ReplyTo/send 9) " &
               "                  catch {^message m} m)) " &
               "(var second-late (try ((saved ~ Cell/get) ~ ReplyTo/send 10) " &
               "                   catch {^message m} m)) " &
               "[err first-late second-late])",
               "[\"actor/ask timed out\" nil \"reply has already been sent\"]")
    check_eval("(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send Get) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (match msg " &
               "        (when (Get ^reply reply) " &
               "          (reply ~ ReplyTo/send \"bad\") " &
               "          (actor/continue state)))))) " &
               "(try (await (counter ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
               "catch (TypeError ^where w) w)",
               "\"ReplyTo/send value\"")

  test "scope shutdown cancels pending actor asks":
    expect GeneCancel:
      discard run(compileSource("(type Get ^props {^reply (ReplyTo Int)}) " &
                                "(impl Send Get) " &
                                "(var pending nil) " &
                                "(scope " &
                                "  (var a (actor/spawn ^init (fn [] 41) " &
                                "    ^handle (fn [ctx state msg] " &
                                "      (match msg " &
                                "        (when (Get ^reply reply) " &
                                "          (reply ~ ReplyTo/send state) " &
                                "          (actor/continue state)))))) " &
                                "  (set pending (a ~ actor/ask " &
                                "    (fn [reply] (Get ^reply reply)))) " &
                                "  nil) " &
                                "(await pending)"),
                  newGlobalScope())
    check_eval("(scope " &
               "  (type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send Get) " &
               "(var saved (cell nil)) " &
               "(var ch (channel ^capacity 1)) " &
               "(fn handle [ctx state msg] " &
               "  (var (Get ^reply reply) msg) " &
               "  (var got (ch ~ Channel/recv)) " &
               "  (try (reply ~ ReplyTo/send got) catch {^message m} m) " &
               "  (actor/continue state)) " &
               "(var counter : (ActorRef Get) " &
               "  (actor/spawn ^init (fn [] 0) ^handle handle)) " &
               "(var pending (counter ~ actor/ask " &
               "  (fn [reply] (saved ~ Cell/set reply) (Get ^reply reply)))) " &
               "(pending ~ Task/cancel) " &
               "(var first-late (try ((saved ~ Cell/get) ~ ReplyTo/send 9) " &
               "                  catch {^message m} m)) " &
               "(var second-late (try ((saved ~ Cell/get) ~ ReplyTo/send 10) " &
               "                   catch {^message m} m)) " &
               "[first-late second-late])",
               "[nil \"reply has already been sent\"]")
    expect GeneCancel:
      discard run(compileSource("(type Boom ^props {^message Str} ^impl [Error]) " &
                                "(impl Error Boom) " &
                                "(type Get ^props {^reply (ReplyTo Int)}) " &
                                "(impl Send Get) " &
                                "(supervisor ^strategy stop " &
                                "  (var a (actor/spawn ^mailbox 4 ^init (fn [] 0) " &
                                "    ^handle (fn [ctx state msg] " &
                                "      (fail (Boom ^message \"bad\"))))) " &
                                "  (var first (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
                                "  (var second (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
                                "  (sleep 1) " &
                                "  (await second))"),
                  newGlobalScope())

  test "scope owns spawned actors until scope exit":
    check_eval("(var a (scope " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (actor/continue state))))) " &
               "(a ~ actor/try-send 1)",
               "false")
    check_eval("(scope " &
               "  (var a (scope " &
               "    (actor/spawn ^init (fn [] 0) " &
               "      ^handle (fn [ctx state msg] (actor/continue state))))) " &
               "  (a ~ actor/try-send 1))",
               "false")

  test "supervisor owns actors and restarts after recoverable handler errors":
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(var seen (cell 0)) " &
               "(supervisor ^strategy restart " &
               "  (var a (actor/spawn ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (= msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do " &
               "          (seen ~ Cell/set state) " &
               "          (actor/continue (+ state msg))))))) " &
               "  (a ~ actor/send 1) " &
               "  (a ~ actor/send 5) " &
               "  (seen ~ Cell/get))",
               "10")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(var events (channel ^capacity 4)) " &
               "(var seen (cell 0)) " &
               "(supervisor ^strategy restart ^events events " &
               "  (var a (actor/spawn ^mailbox 4 ^init (fn [] 10) " &
               "    ^handle (fn [ctx state msg] " &
               "      (if (= msg 1) " &
               "        (fail (Boom ^message \"bad\")) " &
               "        (do " &
               "          (seen ~ Cell/set state) " &
               "          (actor/continue (+ state msg))))))) " &
               "  (spawn (a ~ actor/send 1)) " &
               "  (spawn (a ~ actor/send 5)) " &
               "  (sleep 1) " &
               "  (var event (events ~ Channel/recv)) " &
               "  [(seen ~ Cell/get) " &
               "   (match event " &
               "     (when (ActorFailure ^failed-message failed " &
               "                         ^error (Boom ^message m) " &
               "                         ^panic p ^strategy s) " &
               "       [failed m p s]))])",
               "[10 [1 \"bad\" false restart]]")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(var events (channel ^capacity 1)) " &
               "(var dead (channel ^capacity 2)) " &
               "(events ~ Channel/send \"busy\") " &
               "(supervisor ^strategy restart ^events events ^dead-letter dead " &
               "  (var a (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] " &
               "      (fail (Boom ^message \"bad\"))))) " &
               "  (a ~ actor/send 1) " &
               "  (sleep 1) " &
               "  (var event (dead ~ Channel/recv)) " &
               "  (var busy (events ~ Channel/recv)) " &
               "  [busy " &
               "   (match event " &
               "     (when (ActorFailure ^failed-message failed " &
               "                         ^error (Boom ^message m) " &
               "                         ^strategy s) " &
               "       [failed m s]))])",
               "[\"busy\" [1 \"bad\" restart]]")
    check_eval("(var a (supervisor ^strategy stop " &
               "  (actor/spawn ^init (fn [] 0) " &
               "    ^handle (fn [ctx state msg] (actor/continue state))))) " &
               "(a ~ actor/try-send 1)",
               "false")
    check_eval("(type Boom ^props {^message Str} ^impl [Error]) " &
               "(impl Error Boom) " &
               "(type Get ^props {^reply (ReplyTo Int)}) " &
               "(impl Send Get) " &
               "(try " &
               "  (supervisor ^strategy escalate " &
               "    (var a (actor/spawn ^init (fn [] 0) " &
               "      ^handle (fn [ctx state msg] " &
               "        (fail (Boom ^message \"bad\"))))) " &
               "    (var pending (a ~ actor/ask (fn [reply] (Get ^reply reply)))) " &
               "    (sleep 1) " &
               "    \"after\") " &
               "  catch (Boom ^message m) m)",
               "\"bad\"")
    expect GenePanic:
      discard run(compileSource("(type Get ^props {^reply (ReplyTo Int)}) " &
                                "(impl Send Get) " &
                                "(supervisor ^strategy stop " &
                                "  (var a (actor/spawn ^init (fn [] 0) " &
                                "    ^handle (fn [ctx state msg] " &
                                "      (panic \"halt\")))) " &
                                "  (var pending (a ~ actor/ask " &
                                "    (fn [reply] (Get ^reply reply)))) " &
                                "  (sleep 1) " &
                                "  \"after\")"),
                  newGlobalScope())

suite "spec — Env and eval from design":
  test "Env/extend creates a child environment":
    check_eval("(var base (env ^bindings {^x 10})) " &
               "(var child (base ~ Env/extend {^y 20})) " &
               "[(eval (quote x) ^in child) " &
               " (eval (quote y) ^in child) " &
               " (try (eval (quote y) ^in base) catch {^message m} m)]",
               "[10 20 \"undefined symbol: y\"]")

  test "eval sees explicit Env imports before built-ins":
    check_eval("(ns math (var forty-two 42)) " &
               "(var e (env ^imports [math])) " &
               "(eval (quote forty-two) ^in e)",
               "42")

  test "eval sees an optional Env module namespace":
    check_eval("(ns app (var from-module \"ok\")) " &
               "(var e (env ^module app)) " &
               "(eval (quote from-module) ^in e)",
               "\"ok\"")

  test "eval module context does not mutate the source namespace":
    check_eval("(ns app (var x 1)) " &
               "(var e (env ^module app)) " &
               "[(eval (quote (set x 2)) ^in e) (/x app)]",
               "[2 1]")

  test "eval declarations shadow Env bindings without mutating Env":
    check_eval("(var e (env ^bindings {^x 1})) " &
               "[(eval (quote (do (var x 2) x)) ^in e) " &
               " (eval (quote x) ^in e)]",
               "[2 1]")

  test "eval rejects ambient imports inside evaluated code":
    check_eval("(try " &
               "  (eval (quote (import [answer] from \"./envlib\")) ^in (env)) " &
               "catch (CompileError ^message m) m)",
               "\"eval cannot use import; add imports to Env\"")

  test "eval sees explicit Env capability values":
    check_eval("(var e (env ^bindings {^fs \"binding\"} " &
               "           ^capabilities {^fs \"capability\" ^net \"closed\"})) " &
               "[(eval (quote fs) ^in e) (eval (quote net) ^in e)]",
               "[\"binding\" \"closed\"]")

  test "runtime capabilities are opaque library values":
    check_eval("[Fs/ReadDir " &
               " (Capability/name Fs/ReadDir) " &
               " ((fn [cap : Capability] (Capability/name cap)) Fs/WriteDir)]",
               "[(capability Fs/ReadDir) \"Fs/ReadDir\" \"Fs/WriteDir\"]")
    check_eval("(var e (env ^capabilities {^fs Fs/ReadDir})) " &
               "(eval (quote (Capability/name fs)) ^in e)",
               "\"Fs/ReadDir\"")
    check_eval("(var ch (channel)) " &
               "(try (ch ~ Channel/send Fs/ReadDir) " &
               "catch (TypeError ^expected e) e)",
               "\"Send\"")

  test "runtime GC stats expose optimization diagnostics":
    check_eval("(var stats (Runtime/gc-stats)) " &
               "[stats/live-managed stats/rc-stats?]",
               "[0 false]")

  test "eval policy can limit execution steps":
    check_eval("(type EvalPolicy ^props {^max-steps Int " &
               "                         ^allow-ffi? Bool " &
               "                         ^allow-native-compile? Bool}) " &
               "(var p (EvalPolicy ^max-steps 20 " &
               "                   ^allow-ffi false " &
               "                   ^allow-native-compile false)) " &
               "(eval (quote (+ 1 2)) ^in (env ^policy p))",
               "3")
    check_eval("(try (eval (quote (while true nil)) " &
               "           ^in (env ^policy {^max-steps 20})) " &
               "catch {^message m} m)",
               "\"eval max steps exceeded\"")
    expect GeneError:
      discard run(compileSource("(env ^policy {^max-memory-mb 128})"),
                  newGlobalScope())
    expect GeneError:
      discard run(compileSource("(env ^policy {^allow-ffi true})"),
                  newGlobalScope())

suite "spec — parser helpers from design":
  test "read-one feeds eval and read-all returns a stream":
    check_eval("(eval (read-one \"(+ 1 2)\") ^in (env))", "3")
    check_eval("(var s (read-all \"(a) (b 2)\")) " &
               "[(s ~ Stream/next) (s ~ Stream/next) (s ~ Stream/has_next)]",
               "[(a) (b 2) false]")

  test "lex-all exposes a token stream":
    check_eval("(fn first-token [s : (Stream Token Never)] (s ~ Stream/next)) " &
               "(var t (first-token (lex-all \"(+ 1)\"))) " &
               "(var k t/kind) (var x t/lexeme) " &
               "(var l t/line) (var c t/col) [k x l c]",
               "[l-paren \"(\" 1 1]")

suite "spec — modules from design":
  test "explicit mod declarations are top-level and unique":
    check_eval("(mod app) (var x 1) x", "1")
    expect GeneError:
      discard compileSource("(mod)")
    expect GeneError:
      discard compileSource("(mod a) (mod b)")
    expect GeneError:
      discard compileSource("(do (mod nested))")

  test "explicit mod names the current module root":
    let scope = newGlobalScope()
    discard bindThisModule(scope, "implicit")
    check run(compileSource("(mod app) this-mod"), scope).print() == "(mod app)"

  test "duplicate bindings in one namespace are rejected":
    expect GeneError:
      discard run(compileSource("(var x 1) (var x 2)"), newGlobalScope())
    expect GeneError:
      discard run(compileSource("(ns m (var x 1) (var x 2))"),
                  newGlobalScope())
    check_eval("(var x 1) (ns m (var x 2)) [x (/x m)]", "[1 2]")

suite "spec — web demo remains parseable":
  test "web demo parses as a module source unit":
    let forms = readAll(readFile("examples/web_demo.gene"))
    check forms.len == 35
    check forms[0].print().startsWith("(mod @doc ")
    check forms[1].print() == "(import (path net http) [Request Response serve])"
    check forms[^1].print().startsWith("(fn main ")

  test "web demo exercises selector-core examples":
    let rendered = readAll(readFile("examples/web_demo.gene")).mapIt(it.print()).join("\n")
    check "(unquote ($ \"$\" (path self price)))" in rendered
    check "(path routes (unquote to_pairs_stream))" in rendered
    check "(path req params name)" in rendered
