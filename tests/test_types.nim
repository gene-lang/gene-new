import gene/[compiler, types, vm, printer]
import std/unittest

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

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
