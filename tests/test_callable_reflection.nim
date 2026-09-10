import std/[unittest, tables]
import gene/[compiler, gir, gir_codec, printer, types, vm, web]

template reflectionCheck(source, expected: string) =
  check run(compileSource(source), newGlobalScope()).print() == expected

suite "callable reflection":
  test "ordinary declarations expose shape, aliases, rest and safe types":
    reflectionCheck """
      (fn search [query : Str, ^limit count : Int = 10, tags... : Str] : Str
        ^errors [] @doc "Search documents." query)
      (let s ($runtime/signature search))
      [s/category s/origin s/shape_known s/completeness s/doc
       s/positional/0/name s/positional/0/type
       s/named/0/name s/named/0/local s/named/0/required s/named/0/has_default
       s/rest/name s/rest/type s/result s/invocation_errors/checked]
    """, "[function declared true known \"Search documents.\" \"query\" Str \"limit\" \"count\" false true \"tags\" Str Str true]"

  test "inspection and shape binding never evaluate defaults or target code":
    reflectionCheck """
      (var count 0)
      (fn next [] (set count (+ count 1)) count)
      (fn target [x : Int = (next), ^n : Int = (next)] : Int (+ x n))
      (let s ($runtime/signature target))
      (let bound ($runtime/bind_shape s [] {}))
      (let before count)
      (let a (target bound/positional ... bound/named ...))
      (let b (target bound/positional ... bound/named ...))
      [before a b count bound/omitted_positional bound/omitted_named]
    """, "[0 3 7 4 #[0] #[\"n\"]]"

  test "nil-admitting parameters and explicit defaults remain distinct":
    reflectionCheck """
      (alias OptionalInt Int?)
      (fn target [x : OptionalInt, ^value : Str?] [x value])
      (let s ($runtime/signature target))
      (let b ($runtime/bind_shape s [] {}))
      [s/positional/0/required s/positional/0/has_default
       s/named/0/required s/named/0/has_default
       (target b/positional ... b/named ...)]
    """, "[false false false false [nil nil]]"

  test "nil stays supplied while ordinary maps remove Void entries":
    reflectionCheck """
      (fn target [^value : Any] value)
      (let s ($runtime/signature target))
      (let n ($runtime/bind_shape s [] {^value nil}))
      (let named n/named)
      [(target named ...)
       n/omitted_named
       (try ($runtime/bind_shape s [] {^value (do void)}) false catch Any true)
       (try ($runtime/bind_shape s [] {}) false catch Any true)]
    """, "[nil #[] true true]"

  test "a supplied raw positional Void remains supplied through binding and invocation":
    let scope = newGlobalScope()
    scope.define("raw_args", newNativeFn("raw_args", proc(args: openArray[Value]): Value =
      newList(@[VOID])))
    check run(compileSource("""
      (fn target [x : Void] true)
      (let b ($runtime/bind_shape ($runtime/signature target) (raw_args) {}))
      (let args b/positional)
      [b/omitted_positional (target args ...)]
    """), scope).print() == "[#[] true]"

  test "bound envelopes snapshot shape and preserve nested identity":
    reflectionCheck """
      (fn target [x, ^y] [x y])
      (let nested ($cell 1))
      (let args [nested])
      (let named {^y nested})
      (let b ($runtime/bind_shape ($runtime/signature target) args named))
      (args .push 9)
      (named .put "extra" 10)
      (nested .set 2)
      [(same? b/positional/0 nested) (same? b/named/y nested)
       (b/positional/0 .get) b/positional/.size (== b/named/extra void)
       (try (b/positional .push 1) false catch Any true)]
    """, "[true true 2 1 true true]"

  test "shape validation rejects missing, extra and malformed inputs":
    reflectionCheck """
      (fn target [x, ^label] x)
      (let s ($runtime/signature target))
      [(try ($runtime/bind_shape s [] {^label "a"}) false catch Any true)
       (try ($runtime/bind_shape s [1 2] {^label "a"}) false catch Any true)
       (try ($runtime/bind_shape s [1] {}) false catch Any true)
       (try ($runtime/bind_shape s [1] {^label "a" ^extra 0}) false catch Any true)
       (try ($runtime/bind_shape {} [] {}) false catch Any true)
       (try ($runtime/bind_shape s nil {}) false catch Any true)]
    """, "[true true true true true true]"

  test "shape checking is separate from runtime type admission":
    reflectionCheck """
      (fn target [x : Int] : Int x)
      (let b ($runtime/bind_shape ($runtime/signature target) ["wrong"] {}))
      (let args b/positional)
      [b/positional
       (try (target args ...) false catch TypeError true)]
    """, "[#[\"wrong\"] true]"

  test "checked views describe their outer contract over opaque targets":
    reflectionCheck """
      (let checked : (Callable [Int Int...] Int ^named {^label Str?} ^errors []) +)
      (let s ($runtime/signature checked))
      (let b ($runtime/bind_shape s [1 2 3] {}))
      (let args b/positional)
      [s/category s/origin s/positional/0/name s/rest/type s/named/0/required
       s/invocation_errors/checked (checked args ...)
       (try ($runtime/bind_shape s [] {}) false catch Any true)]
    """, "[checked_view checked_view nil Int false true 6 true]"

  test "a checked optional named parameter preserves target default timing":
    reflectionCheck """
      (var calls 0)
      (fn next [] (set calls (+ calls 1)) calls)
      (fn target [^n : Int = (next)] : Int n)
      (let checked : (Callable [] Int ^named {^n Int?}) target)
      (let s ($runtime/signature checked))
      (let b ($runtime/bind_shape s [] {}))
      (let named b/named)
      [calls s/named/0/has_default (checked named ...) (checked named ...) calls]
    """, "[0 false 1 2 2]"

  test "unknown contracts do not become Any or empty error rows":
    reflectionCheck """
      (fn unknown [x] x)
      (fn declared [x] : Any ^errors [] x)
      (let a ($runtime/signature unknown))
      (let b ($runtime/signature declared))
      [a/shape_known a/result_known a/result a/invocation_errors/known
       a/invocation_errors/types b/result_known b/result b/invocation_errors/types]
    """, "[true false nil false nil true Any #[]]"

  test "unsupported targets and effectful annotations never execute":
    reflectionCheck """
      (var calls 0)
      (fn annotation [] (set calls (+ calls 1)) Int)
      (fn target [x : (annotation)] x)
      (fn syntax! [x] x)
      (let s ($runtime/signature target))
      (let syntax_sig ($runtime/signature syntax!))
      (let native_sig ($runtime/signature +))
      [calls s/positional/0/type_known s/positional/0/type
       syntax_sig/shape_known native_sig/shape_known
       (try ($runtime/bind_shape ($runtime/signature +) [] {}) false catch Any true)]
    """, "[0 false nil false false true]"

  test "descriptions are immutable and ignore forged signature metadata":
    reflectionCheck """
      (fn target [x : Str] : Str @signature "fake" x)
      (let s ($runtime/signature target))
      [s/positional/0/type s/signature s/target s/environment
       (try (s/positional/0 .put "name" "changed") false catch Any true)
       (try (s/positional .push nil) false catch Any true)]
    """, "[Str void void void true true]"

  test "generator invocation and producer contracts stay separate":
    reflectionCheck """
      (var entered 0)
      (fn ^^generator items [] : (Stream Int RuntimeError) ^errors []
        (set entered (+ entered 1)) (yield 1))
      (let s ($runtime/signature items))
      [entered s/execution s/invocation_errors/types
       s/deferred/known s/deferred/kind s/deferred/value_type]
    """, "[0 generator #[] true stream Int]"

  test "same-named replacement cannot reuse an earlier signature":
    reflectionCheck """
      (fn first [] (fn same_name [x : Int] : Int x))
      (fn second [] (fn same_name [x : Str, ^label : Str] : Str x))
      (var f (first))
      (let old f)
      (let a ($runtime/signature f))
      (set f (second))
      (let b ($runtime/signature f))
      [a/positional/0/type b/positional/0/type a/named/.size b/named/.size
       (old 7) (f "new" ^label "l")]
    """, "[Int Str 0 1 7 \"new\"]"

  test "compiled artifact round trips preserve reflection metadata":
    let source = """
      (fn target [x : Int, ^n : Int = 4] : Int ^errors [] (+ x n))
      (let s ($runtime/signature target))
      [s/positional/0/type s/named/0/has_default s/result]
    """
    let chunk = compileSource(source)
    let artifact = ExecutableGir(entryIdentity: "test/reflection",
      modules: @[CompiledModule(identity: "test/reflection", chunk: chunk,
        macroExports: initTable[string, MacroDef](), syntaxFnExports: @[],
        compileInterface: CompileNamespaceInterface(
          entries: initTable[string, CompileInterfaceEntry]()))])
    let decoded = decodeExecutableGir(encodeExecutableGir(artifact))
    check run(decoded.modules[0].chunk, newGlobalScope()).print() == "[Int true Int]"

  test "nominal identities survive escaping and same-name declarations stay distinct":
    reflectionCheck """
      (fn make []
        (type Item ^props {^n Int})
        (fn identity [x : Item] : Item x)
        ($runtime/signature identity))
      (let a (make))
      (let b (make))
      (let first a/positional/0/type)
      (let second b/positional/0/type)
      [(same? first a/result) (same? first second) (first ^n 1)]
    """, "[true false ((type Item) ^n 1)]"

  test "a wrapper's own shape is not replaced by target metadata":
    reflectionCheck """
      (fn target [x : Int] : Int x)
      (fn wrapper [x : Str, ^label : Str] : Str @wrapped target x)
      (let s ($runtime/signature wrapper))
      [s/positional/0/type s/named/0/name s/result s/wrapped]
    """, "[Str \"label\" Str void]"

  test "a forged description cannot weaken actual callable checks":
    reflectionCheck """
      (fn target [x : Int] : Int x)
      (let loose ($runtime/signature (fn [x] x)))
      (let b ($runtime/bind_shape loose ["bad"] {}))
      (let args b/positional)
      (try (target args ...) false catch TypeError true)
    """, "true"

  test "web compilation explicitly rejects the unsupported runtime surface":
    expect WebProfileError:
      discard analyzeWebModule("(mod reflection ^profile web) " &
        "(fn f [x : Int] : Int x) ($runtime/signature f)", "reflection.gene")
