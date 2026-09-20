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
    expect WebProfileError:
      discard analyzeWebModule("(mod reflection ^profile web) " &
        "(type T ^props {}) ($runtime/constructor_signature T)", "reflection.gene")

suite "language callable reflection":
  test "protocol requirements retain abstract Self without selecting a default body":
    reflectionCheck """
      (alias MaybeInt Int?)
      (protocol P
        (message copy [other : Self, ^limit count : MaybeInt] : Self ^errors [] self))
      (let s ($runtime/signature P:copy))
      (let b ($runtime/bind_shape s [nil nil] {}))
      [s/category s/origin s/resolution s/abstract_self s/execution
       s/receiver_included s/positional/1/type s/result
       s/named/0/name s/named/0/local s/named/0/required b/omitted_named]
    """, "[message requirement requirement true unknown true Self Self \"limit\" \"count\" false #[\"limit\"]]"

  test "receiver-aware protocol reflection preserves inherited Self and runs no code":
    reflectionCheck """
      (var called 0)
      (protocol P (message copy [other : Self] : Self ^errors []))
      (type Parent ^props {})
      (impl P for Parent (message copy [other : Self] : Self ^errors []
        (set called 1) other))
      (type Child : Parent ^props {})
      (let s ($runtime/signature P:copy (Child)))
      [called s/resolution s/abstract_self s/dispatch_scope s/minimum_positional
       (same? s/positional/1/type Parent) (same? s/result Parent)
       (same? s/receiver_type Child)]
    """, "[0 implementation false authored 2 true true true]"

  test "type-direct messages require a receiver and retain declaration-bound types":
    reflectionCheck """
      (type Parent ^props {}
        (message accept [other : Self] : Self other))
      (type Child : Parent ^props {})
      (let abstract ($runtime/signature Self:accept))
      (let concrete ($runtime/signature Self:accept (Child)))
      [abstract/shape_known concrete/category concrete/minimum_positional
       (same? concrete/positional/1/type Parent) (same? concrete/result Parent)]
    """, "[false message 2 true true]"

  test "held message queries use authored impl scope rather than the helper's scope":
    reflectionCheck """
      (protocol Values (message values [] : (Stream Int Never)))
      (type Box ^props {})
      (fn capture []
        (impl Values for Box
          (message ^^generator values [] : (Stream Int Never) (yield 1)))
        Values:values)
      (let held (capture))
      (fn inspect [message]
        (impl Values for Box
          (message values [] : (Stream Int Never) ($to_stream [2])))
        (let a ($runtime/signature message (Box)))
        (let b ($runtime/signature Values:values (Box)))
        [a/execution b/execution])
      (inspect held)
    """, "[generator ordinary]"

  test "missing and pending implementations do not fabricate a signature":
    reflectionCheck """
      (protocol P (message value [] : Int 99))
      (type Missing ^props {})
      (type Parent ^props {})
      (type Child : Parent ^props {})
      (let missing (try ($runtime/signature P:value (Missing)) false catch MessageError true))
      (impl P for Child ^^override)
      (let pending (try ($runtime/signature P:value (Child)) false catch RuntimeError true))
      (impl P for Parent (message value [] : Int 7))
      (let ready ($runtime/signature P:value (Child)))
      [missing pending ready/shape_known ready/result]
    """, "[true true true Int]"

  test "inherited protocol names preserve identity and ambiguity":
    reflectionCheck """
      (protocol A (message value [n : Int] : Int))
      (protocol B (message value [n : Int] : Int))
      (protocol Both ^inherit [A B])
      (protocol One ^inherit [A])
      (let a ($runtime/signature One:value))
      [a/positional/1/type (same? a/protocol One) (same? a/declaring_protocol A)
       (try ($runtime/signature Both:value) false catch Error true)]
    """, "[Int true true true]"

  test "explicit receiver nil is not mistaken for an omitted receiver":
    reflectionCheck """
      [(try ($runtime/signature Self:no_such_message nil) false catch MessageError true)
       (try ($runtime/signature + nil) false catch Error true)
       (try ($runtime/signature + ^unexpected true) false catch Error true)]
    """, "[true true true]"

  test "direct type signatures describe inherited closed props and body schemas":
    reflectionCheck """
      (var constructed 0)
      (type Parent ^props {^name Str ^tag Str?} ^body [Int]
        (ctor [] (set constructed 1)))
      (type Child : Parent ^props {^active Bool} ^body [Str...])
      (let s ($runtime/signature Child))
      (let b ($runtime/bind_shape s [1 "two"] {^name "n" ^active true}))
      (let args b/positional) (let named b/named)
      (let value (Child args ... named ...))
      [constructed s/category s/construction s/minimum_positional s/rest/type
       s/named/1/required value/name value/tag value/0 value/1
       (same? s/result Child)]
    """, "[0 type data 1 Str false \"n\" void 1 \"two\" true]"

  test "nil-admitting body fields still require a positional item":
    reflectionCheck """
      (type Item ^body [Int?])
      (let s ($runtime/signature Item))
      [s/minimum_positional
       (try ($runtime/bind_shape s [] {}) false catch Error true)
       (try (Item) false catch Error true)]
    """, "[1 true true]"

  test "new signatures omit implicit self and keep inherited ctor parameter contracts":
    reflectionCheck """
      (var called 0)
      (type Parent ^props {^n Int}
        (ctor [other : Self, ^offset : Int = 1] ^errors []
          (set called (+ called 1))
          (self .set_prop `n (+ other/n offset))))
      (type Child : Parent ^props {})
      (let s ($runtime/constructor_signature Child))
      (let before called)
      (let b ($runtime/bind_shape s [(Parent ^n 4)] {}))
      (let args b/positional) (let named b/named)
      (let value (new Child args ... named ...))
      [before called s/category s/construction s/minimum_positional
       s/positional/0/name (same? s/positional/0/type Parent)
       (same? s/result Child) value/n (same? ($head value) Child)]
    """, "[0 1 constructor new 1 \"other\" true true 5 true]"

  test "ctor defaults are not evaluated and post-construction failures remain possible":
    reflectionCheck """
      (var defaults 0)
      (fn next [] (set defaults (+ defaults 1)) defaults)
      (type Bad ^props {^n Int}
        (ctor [value : Int = (next)] ^errors [] nil))
      (let s ($runtime/constructor_signature Bad))
      (let b ($runtime/bind_shape s [] {}))
      [defaults s/positional/0/has_default s/constructor_errors/checked
       s/constructor_errors/types s/invocation_errors/known
       (try (new Bad) false catch RuntimeError true) defaults]
    """, "[0 true true #[] false true 1]"

  test "aliases, enums, native wrappers and absent ctors have honest availability":
    reflectionCheck """
      (type Plain ^props {})
      (alias Alias Plain)
      (enum Choice A B)
      (type Handle ^repr native_wrapper ^props {})
      (let data ($runtime/signature Plain))
      (let ctor ($runtime/constructor_signature Plain))
      (let alias ($runtime/signature Alias))
      (let enum_sig ($runtime/signature Choice))
      (let handle ($runtime/signature Handle))
      [data/shape_known ctor/shape_known ctor/reason alias/shape_known
       enum_sig/shape_known handle/shape_known]
    """, "[true false no_constructor false false false]"

  test "selectors expose a unary shape without traversing a receiver":
    reflectionCheck """
      (let s ($runtime/signature /name))
      (let b ($runtime/bind_shape s [{^name "Ada"}] {}))
      (let args b/positional)
      [s/category s/minimum_positional s/result_known (/name args ...)
       (try ($runtime/bind_shape s args {^extra 1}) false catch Error true)]
    """, "[selector 1 false \"Ada\" true]"

  test "enum variants expose exact payload slots without constructing values":
    reflectionCheck """
      (enum Choice (Some Int Str?) None)
      (let s ($runtime/signature Choice/Some))
      (let none ($runtime/signature Choice/None))
      [s/category s/minimum_positional s/positional/0/type none/minimum_positional
       (same? s/result Choice)
       (try ($runtime/bind_shape s [1] {}) false catch Error true)]
    """, "[enum_variant 2 Int 0 true true]"

  test "custom Callable describes apply separately without inventing outer parameters":
    reflectionCheck """
      (var called 0)
      (type Custom ^props {})
      (impl Callable for Custom
        (message apply [call] : Str (set called 1) "ok"))
      (let s ($runtime/signature (Custom)))
      [called s/category s/shape_known s/apply_contract/positional/1/name
       s/apply_contract/result
       (try ($runtime/bind_shape s [] {}) false catch Error true)]
    """, "[0 custom false \"call\" Str true]"

  test "existing FFI metadata is readable without entering native code or exposing pointers":
    let scope = newGlobalScope()
    scope.define("foreign", newFfiCallable("fixture", "fixture_symbol", cast[pointer](1),
      NIL, @[newSym("C/Int32")], newSym("C/Int32")))
    check run(compileSource("""
      (let s ($runtime/signature foreign))
      [s/category s/origin s/shape_known s/minimum_positional s/name
       s/address s/library s/invocation_errors/known]
    """), scope).print() == "[native native_declared true 1 \"fixture\" void void false]"

  test "generic parameters cannot resolve to a same-named outer type":
    reflectionCheck """
      (type T ^props {})
      (fn (identity T) [values : (List T)] : T values/0)
      (enum Option [T] (Some T))
      (let f ($runtime/signature identity))
      (let v ($runtime/signature Option/Some))
      [f/type_parameters f/positional/0/type_known f/result_known
       v/positional/0/type_known]
    """, "[#[\"T\"] false false false]"

  test "protocol error requirements retain their declared row before conformance":
    reflectionCheck """
      (type Failure ^props {^message Str} ^impl [Error])
      (impl Error for Failure)
      (protocol P (message work [] : Int ^errors [Failure]))
      (let s ($runtime/signature P:work))
      [s/invocation_errors/checked s/invocation_errors/known
       (same? s/invocation_errors/types/0 Failure)]
    """, "[true true true]"

  test "raw protocol declarations use the query scope for receiver resolution":
    let scope = newGlobalScope()
    discard run(compileSource("""
      (protocol P (message work [] : Int))
      (type Item ^props {})
      (impl P for Item (message work [] : Int 9))
    """, useLocalSlots = false), scope)
    let protocol = run(compileSource("P", useLocalSlots = false), scope)
    scope.define("raw_message", protocol.protocolMessages["work"])
    check run(compileSource("""
      (let s ($runtime/signature raw_message (Item)))
      [s/resolution s/dispatch_scope s/result s/receiver_included]
    """, useLocalSlots = false), scope).print() == "[implementation query Int true]"

  test "retained Error formatter reflection preserves its originating contract without formatting":
    reflectionCheck """
      (var formatted 0)
      (type Failure ^props {})
      (fn raise_local []
        (impl Error for Failure
          (message message [] : Str ^errors [] (set formatted 1) "failed"))
        (fail (Failure)))
      (let err (try (raise_local) catch Error $err))
      (let s ($runtime/signature Error:message err))
      [formatted s/result s/resolution]
    """, "[0 Str implementation]"
