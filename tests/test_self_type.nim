## Declaration-bound Self and explicit implementation composition.
import std/[strutils, unittest]
import gene/[compiler, printer, types, vm]

proc selfTypeEval(source: string): string =
  run(compileSource(source), newGlobalScope()).print()

proc selfTypeError(source, expected: string) =
  var failed = false
  try:
    discard selfTypeEval(source)
  except GeneError as error:
    failed = true
    if expected notin error.msg:
      raise newException(GeneError,
        "expected diagnostic containing " & expected & ", got: " & error.msg)
  if not failed:
    raise newException(GeneError, "expected declaration failure containing " & expected)

suite "Self — forward declaration readiness":
  test "a child-before-parent static impl retains the eventual parent binding":
    check selfTypeEval("""
      (protocol P (message accepts [x : Self] : Bool))
      (type Dog ^props {}) (type Pup : Dog ^props {})
      (impl P for Pup ^^override (message accepts [x : Dog] : Bool false))
      (impl P for Dog (message accepts [x : Self] : Bool true))
      ((Pup) .P:accepts (Dog))
    """) == "false"

  test "an intermediate send cannot enter a pending provider or fall back":
    check selfTypeEval("""
      (protocol P (message value [] : Int 99))
      (type Dog ^props {}) (type Pup : Dog ^props {})
      (impl P for Pup ^^override)
      (let early (try ((Pup) .P:value) catch RuntimeError $err/message))
      (impl P for Dog (message value [] : Int 7))
      [(== early "declaration not ready: P for Pup") ((Pup) .P:value)]
    """) == "[true 7]"

  test "unexecuted branches are not forward ancestor targets":
    selfTypeError("""
      (protocol P (message value [] : Int))
      (type Dog ^props {}) (type Pup : Dog ^props {})
      (if false (impl P for Dog (message value [] : Int 1)))
      (impl P for Pup ^^override (message value [] : Int 2))
    """, "ancestor")

  test "prospective duplicate providers never expose an intermediate body":
    let scope = newGlobalScope()
    discard run(compileSource("(var entered 0)"), scope)
    expect GeneError:
      discard run(compileSource("""
        (protocol P (message value [] : Int))
        (type Dog ^props {})
        (impl P for Dog (message value [] : Int (set entered 1) 1))
        ((Dog) .P:value)
        (impl P for Dog (message value [] : Int 2))
      """), scope)
    check run(compileSource("entered"), scope).print() == "0"

  test "unrelated pending providers do not block a ready body":
    check selfTypeEval("""
      (protocol P (message value [] : Int))
      (type A ^props {}) (type B ^props {})
      (impl P for A (message value [] : Int 1))
      (let first ((A) .P:value))
      (impl P for B (message value [] : Int 2))
      [first ((B) .P:value)]
    """) == "[1 2]"

suite "Self — declaration contracts":
  test "inherited Self accepts the complete nominal family":
    check selfTypeEval("""
      (protocol Eq (message eq [other : Self] : Bool))
      (type Dog ^props {^name Str})
      (impl Eq for Dog
        (message eq [other : Self] : Bool (== self/name other/name)))
      (type Pup : Dog ^props {})
      (let dog (Dog ^name "rex")) (let pup (Pup ^name "rex"))
      (fn compare [a : Dog b : Dog] : Bool (a .Eq:eq b))
      [(compare dog dog) (compare dog pup)
       (compare pup dog) (compare pup pup)]
    """) == "[true true true true]"

  test "direct replacements need a flag and the inherited signature":
    let parent = "(type Dog ^props {} (message accepts [x : Self] : Bool true)) "
    selfTypeError(parent & "(type Pup : Dog ^props {} " &
      "(message accepts [x : Dog] : Bool true))", "override")
    selfTypeError(parent & "(type Pup : Dog ^props {} " &
      "(message accepts [x : Self] : Bool ^^override true))", "Self")
    selfTypeError(parent & "(type Pup : Dog ^props {} " &
      "(message accepts [x : Pup] : Bool ^^override true))", "incompatible")
    check selfTypeEval(parent & "(type Pup : Dog ^props {} " &
      "(message accepts [x : Dog] : Bool ^^override false)) " &
      "((Pup) .accepts (Dog))") == "false"

  test "new direct messages cannot assert replacement":
    selfTypeError("(type Dog ^props {} (message fresh [] ^^override 1))", "override")

  test "overriding body-local Self and escaping functions remain child-bound":
    check selfTypeEval("""
      (type Dog ^props {} (message accepts [x : Self] : Bool true))
      (type Pup : Dog ^props {}
        (message accepts [x : Dog] : Bool ^^override
          (let mine : Self self)
          (let check_child (fn [value : Self] : Bool true))
          (try (check_child x) catch TypeError false))
        (message checker [] (fn [value : Self] : Bool true)))
      (let pup (Pup)) (let check_child (pup .checker))
      [(pup .accepts (Dog)) (pup .accepts pup)
       (try (check_child (Dog)) catch TypeError false)]
    """) == "[false true false]"

  test "inherited results and nested boundaries retain Dog":
    check selfTypeEval("""
      (type Dog ^props {}
        (message copy [] : Self (Dog))
        (message optional [x : Self?] : Bool true)
        (message many [xs : (List Self)] : Int ($size xs)))
      (type Pup : Dog ^props {})
      (let p (Pup))
      [(same? ($head (p .copy)) Dog)
       (p .optional (Dog)) (p .optional nil) (p .many [(Dog) p])]
    """) == "[true true true 2]"

  test "aliases cannot hide contextual Self in a replacement signature":
    selfTypeError("""
      (alias Hidden Self)
      (type Dog ^props {} (message accepts [x : Self] : Bool true))
      (type Pup : Dog ^props {}
        (message accepts [x : Hidden] : Bool ^^override true))
    """, "Self")
    check selfTypeEval("""
      (type Dog ^props {} (message accepts [x : Self] : Bool true))
      (alias Parent Dog)
      (type Pup : Dog ^props {}
        (message accepts [x : Parent] : Bool ^^override false))
      ((Pup) .accepts (Dog))
    """) == "false"

suite "Self — complete and inheriting impls":
  test "inheriting omissions reuse ancestor bodies; complete omissions use defaults":
    let declarations = """
      (protocol Eq
        (message eq [other : Self] : Bool)
        (message label [] : Str "default"))
      (type Dog ^props {})
      (impl Eq for Dog
        (message eq [other : Self] : Bool true)
        (message label [] : Str "ancestor"))
      (type Pup : Dog ^props {})
    """
    check selfTypeEval(declarations & """
      (impl Eq for Pup ^^override
        (message eq [other : Dog] : Bool false))
      [((Pup) .Eq:eq (Dog)) ((Pup) .Eq:label)]
    """) == "[false \"ancestor\"]"
    check selfTypeEval(declarations & """
      (impl Eq for Pup
        (message eq [other : Dog] : Bool false))
      [((Pup) .Eq:eq (Dog)) ((Pup) .Eq:label)]
    """) == "[false \"default\"]"

  test "complete impls never borrow missing ancestor bodies":
    selfTypeError("""
      (protocol P (message value [] : Int))
      (type Dog ^props {}) (impl P for Dog (message value [] : Int 1))
      (type Pup : Dog ^props {}) (impl P for Pup)
    """, "missing")

  test "inheriting impls require an actual ancestor provider":
    selfTypeError("""
      (protocol P (message value [] : Int 1))
      (type Dog ^props {}) (impl P for Dog ^^override)
    """, "ancestor")

  test "complete impls do not get a fresh Self when replacing ancestor behavior":
    for mode in ["", "^^override"]:
      selfTypeError("""
        (protocol Eq (message eq [other : Self] : Bool))
        (type Dog ^props {})
        (impl Eq for Dog (message eq [other : Self] : Bool true))
        (type Pup : Dog ^props {})
      """ & "(impl Eq for Pup " & mode &
        " (message eq [other : Self] : Bool false))", "Self")

  test "protocol closure retains per-protocol bindings":
    let declarations = """
      (protocol P (message copy [] : Self))
      (protocol Q ^inherit [P]
        (message special_copy [] : Self (self .P:copy)))
      (type Dog ^props {})
      (impl P for Dog (message copy [] : Self self))
      (type Pup : Dog ^props {})
    """
    check selfTypeEval(declarations & """
      (impl Q for Pup ^^override
        (message P:copy [] : Dog self))
      (same? ($head ((Pup) .Q:special_copy)) Pup)
    """) == "true"
    check selfTypeEval(declarations & """
      (impl Q for Pup ^^override
        (message P:copy [] : Dog (Dog)))
      (try ((Pup) .Q:special_copy) catch TypeError "checked")
    """) == "\"checked\""

  test "shared defaults keep independent conformance environments":
    check selfTypeEval("""
      (protocol P (message accepts [other : Self] : Bool true))
      (type A ^props {}) (type B ^props {})
      (impl P for A) (impl P for B)
      [((A) .P:accepts (A)) ((B) .P:accepts (B))
       (try ((A) .P:accepts (B)) catch TypeError false)]
    """) == "[true true false]"

suite "Self — declaration metadata":
  test "override values are literal booleans at supported declaration sites":
    for flag in ["1", "nil", "(== 1 1)"]:
      selfTypeError("(type A ^props {} (message m [] ^override " & flag & " 1))",
                    "override")
      selfTypeError("(protocol P (message m [])) (type A ^props {}) " &
        "(impl P for A ^override " & flag & " (message m [] 1))", "override")
    selfTypeError("(protocol P (message m [])) (type A ^props {}) " &
      "(impl P for A (message m [] ^^override 1))", "override")

  test "universal abstract Self is rejected but self and Self message values remain legal":
    selfTypeError("(protocol P ^^universal (message copy [] : Self self))", "Self")
    check selfTypeEval("""
      (protocol P ^^universal (message value [] : Int (Self:value self)))
      (type A ^props {} (message value [] : Int 7))
      ((A) .P:value)
    """) == "7"

suite "Self — live overlay dependencies":
  test "a captured inheriting impl refreshes when a nearer ancestor appears":
    check selfTypeEval("""
      (protocol P (message value [] : Int))
      (type Base ^props {}) (type Mid : Base ^props {}) (type Leaf : Mid ^props {})
      (impl P for Base (message value [] : Int 1))
      (fn make_reader []
        (impl P for Leaf ^^override)
        (fn [] ((Leaf) .P:value)))
      (let reader (make_reader))
      (let before (reader))
      (if true (impl P for Mid (message value [] : Int 2)))
      [before (reader)]
    """) == "[1 2]"

  test "a later conflicting ancestor is rejected before the overlay body runs":
    check selfTypeEval("""
      (protocol P (message value [] : Int))
      (type Base ^props {}) (type Leaf : Base ^props {})
      (var entered 0)
      (fn make_reader []
        (impl P for Leaf (message value [] : Int (set entered (+ entered 1)) 7))
        (fn [] ((Leaf) .P:value)))
      (let reader (make_reader))
      (let before (reader))
      (if true (impl P for Base (message value [] : Int 2)))
      [before (try (reader) catch RuntimeError "conflict") entered]
    """) == "[7 \"conflict\" 1]"

suite "Self — checked error contracts":
  test "protocol error rows bind Self and inherited replacements name the original type":
    check selfTypeEval("""
      (type Boom ^props {}) (impl Error for Boom (message message [] : Str ^errors [] ($to_str (quote Boom))))
      (protocol P (message raise [] : Int ^errors [Self]))
      (impl P for Boom (message raise [] : Int ^errors [Self] (fail self)))
      (type Child : Boom ^props {})
      (impl P for Child ^^override (message raise [] : Int ^errors [Boom] (fail self)))
      [(try ((Boom) .P:raise) catch Boom 1)
       (try ((Child) .P:raise) catch Boom 2)]
    """) == "[1 2]"

  test "an error row alias cannot conceal replacement Self":
    selfTypeError("""
      (type Boom ^props {}) (impl Error for Boom (message message [] : Str ^errors [] ($to_str (quote Boom))))
      (alias Hidden Self)
      (protocol P (message raise [] : Int ^errors [Self]))
      (impl P for Boom (message raise [] : Int ^errors [Self] (fail self)))
      (type Child : Boom ^props {})
      (impl P for Child ^^override (message raise [] : Int ^errors [Hidden] (fail self)))
    """, "Self")

  test "universal defaults retain concrete checked error rows":
    check selfTypeEval("""
      (protocol P ^^universal
        (message raise [] : Int ^errors [RuntimeError]
          (fail (RuntimeError ^message "declared"))))
      (try (1 .P:raise) catch RuntimeError $err/message)
    """) == "\"declared\""

suite "Self — forward annotation dependencies":
  test "forward aliases are resolved before direct bodies become callable":
    check selfTypeEval("""
      (type Dog ^props {} (message accepts [x : Later] : Bool true))
      (let early (try (Dog) false catch RuntimeError true))
      (alias Later Self)
      [early ((Dog) .accepts (Dog))]
    """) == "[true true]"

  test "a forward alias cannot hide contextual Self in a direct replacement":
    selfTypeError("""
      (type Dog ^props {} (message accepts [x : Later] : Bool true))
      (type Pup : Dog ^props {} (message accepts [x : Later] : Bool ^^override true))
      (alias Later Self)
    """, "Self")

  test "an impl waits for a forward annotation and closes it once":
    check selfTypeEval("""
      (protocol P (message accepts [x : Later] : Bool))
      (type Dog ^props {})
      (impl P for Dog (message accepts [x : Later] : Bool true))
      (let early (try ((Dog) .P:accepts (Dog)) false catch RuntimeError true))
      (alias Later Self)
      [early ((Dog) .P:accepts (Dog))]
    """) == "[true true]"

  test "direct error rows wait for the receiver's Error conformance":
    check selfTypeEval("""
      (type Boom ^props {} (message raise [] : Int ^errors [Self] (fail self)))
      (impl Error for Boom (message message [] : Str ^errors [] ($to_str (quote Boom))))
      (try ((Boom) .raise) catch Boom 7)
    """) == "7"

suite "Self — shared nested signature comparison":
  test "union normalization includes callable parameter vectors and named maps":
    check selfTypeEval("""
      (type Base ^props {}
        (message accepts [f : (Callable [(| Int Str)] Bool ^named {^x (| Nil Str)})] : Bool true))
      (type Child : Base ^props {}
        (message accepts [f : (Callable [(| Str Int)] Bool ^named {^x (| Str Nil)})] : Bool ^^override false))
      true
    """) == "true"

suite "Self — conformance boundary coherence":
  test "a captured protocol boundary rejects a newly conflicting ancestor":
    check selfTypeEval("""
      (protocol P (message accepts [x : Self] : Bool))
      (type Base ^props {}) (type Leaf : Base ^props {})
      (var entered 0)
      (fn make_checker []
        (impl P for Leaf (message accepts [x : Self] : Bool true))
        (fn [] (let x : P (Leaf)) (set entered (+ entered 1)) true))
      (let checker (make_checker))
      (checker)
      (if true (impl P for Base (message accepts [x : Self] : Bool true)))
      [(try (checker) catch RuntimeError false) entered]
    """) == "[false 1]"

suite "Self — nested error annotations":
  test "an escaping nested function retains its declaring error type":
    check selfTypeEval("""
      (type Boom ^props {}
        (message raiser [] (fn [] : Int ^errors [Self] (fail self))))
      (impl Error for Boom (message message [] : Str ^errors [] ($to_str (quote Boom))))
      (type Child : Boom ^props {})
      (let raise_child ((Child) .raiser))
      (try (raise_child) catch Boom 7)
    """) == "7"

suite "Self — proposal integration cases":
  test "a protocol diamond shares the inherited binding and adds a child binding":
    check selfTypeEval("""
      (protocol P (message copy [] : Self))
      (protocol Left ^inherit [P]) (protocol Right ^inherit [P])
      (protocol Q ^inherit [Left Right] (message fresh [] : Self))
      (type Dog ^props {})
      (impl P for Dog (message copy [] : Self (Dog)))
      (type Pup : Dog ^props {})
      (impl Q for Pup ^^override (message fresh [] : Self self))
      [(same? ($head ((Pup) .Q:copy)) Dog)
       (same? ($head ((Pup) .Q:fresh)) Pup)]
    """) == "[true true]"

  test "grandparent replacements and invariant Cell inputs retain their contract":
    check selfTypeEval("""
      (type Dog ^props {}
        (message accepts [x : (Cell Self)] : Bool true))
      (type Mid : Dog ^props {})
      (type Pup : Mid ^props {}
        (message accepts [x : (Cell Dog)] : Bool ^^override false))
      (var cell : (Cell Dog) ($cell (Dog)))
      ((Pup) .accepts cell)
    """) == "false"

  test "inherited body reuse preserves the original super starting point":
    check selfTypeEval("""
      (protocol P (message label [] : Str))
      (type Base ^props {})
      (impl P for Base (message label [] : Str "base"))
      (type Mid : Base ^props {})
      (impl P for Mid (message label [] : Str (super .P:label)))
      (type Leaf : Mid ^props {}) (impl P for Leaf ^^override)
      ((Leaf) .P:label)
    """) == "\"base\""

  test "an explicit universal ancestor permits body reuse with concrete body Self":
    check selfTypeEval("""
      (protocol P ^^universal (message accepts [other : Any] : Bool false))
      (type Dog ^props {})
      (impl P for Dog (message accepts [other : Any] : Bool
        (let mine : Self other) true))
      (type Pup : Dog ^props {}) (impl P for Pup ^^override)
      [((Pup) .P:accepts (Dog)) (1 .P:accepts nil)]
    """) == "[true false]"

  test "eval preserves forward dependency readiness and local visibility":
    check selfTypeEval("""
      (eval (quote (do
        (protocol P (message value [] : Int))
        (type Base ^props {}) (type Child : Base ^props {})
        (impl P for Child ^^override)
        (let early (try ((Child) .P:value) false catch RuntimeError true))
        (impl P for Base (message value [] : Int 7))
        [early ((Child) .P:value)])) ^in (env))
    """) == "[true 7]"

  test "direct replacements share callable shape and result checks":
    let parent = "(type Base ^props {} (message m [x : Int] : Int x)) "
    for declaration in [
      "(message m [x : Int = 1] : Int ^^override x)",
      "(message m [x : Int xs...] : Int ^^override x)",
      "(message m [^x : Int] : Int ^^override x)",
      "(message m [x : Int] : Str ^^override \"x\")",
      "(message m [x : Int] : Int ^errors [] ^^override x)"
    ]:
      selfTypeError(parent & "(type Child : Base ^props {} " & declaration & ")", "incompatible")

suite "Self — captured task scopes":
  test "a spawned body uses its declaring receiver's Self":
    check selfTypeEval("""
      (type Dog ^props {}
        (message check [] : Bool
          (scope (await (spawn (do (let x : Self (Dog)) true))))))
      (type Pup : Dog ^props {})
      ((Pup) .check)
    """) == "true"

suite "Self — abstract requirement readiness":
  test "concrete requirement error rows validate without an implementation":
    selfTypeError("""
      (type NotError ^props {})
      (protocol P (message value [] ^errors [NotError]))
    """, "Error types")

  test "abstract Self error rows wait for a concrete conformance":
    check selfTypeEval("(protocol P (message value [] ^errors [Self])) true") == "true"

  test "a requirement may refer to a type initialized later in its unit":
    check selfTypeEval("""
      (protocol P (message value [x : Later] : Bool))
      (type Later ^props {})
      true
    """) == "true"
    selfTypeError("(protocol P (message value [x : Missing] : Bool))", "declaration not ready")

suite "Self — native annotation compatibility":
  test "opaque C pointee labels do not require a Gene declaration":
    check selfTypeEval("""
      (type Wrapper ^props {^handle (C/OwnedPtr NativeHandle)})
      true
    """) == "true"

  test "a forward pointer-target alias cannot conceal replacement Self":
    selfTypeError("""
      (type Base ^props {} (message accepts [x : (C/Ptr Later)] : Bool true))
      (type Child : Base ^props {}
        (message accepts [x : (C/Ptr Later)] : Bool ^^override true))
      (alias Later Self)
    """, "Self")
