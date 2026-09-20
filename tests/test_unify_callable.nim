import std/[os, strutils, tables, tempfiles, unittest]
import gene/[compiler, gir, gir_codec, printer, types, vm]

template unifyCallableCheck(source, expected: string) =
  check run(compileSource(source), newGlobalScope()).print() == expected

suite "unified callable — direct message syntax":
  test "prefix protocol and Self calls share dot dispatch":
    unifyCallableCheck """
      (protocol Named (message name [] : Str))
      (type Box ^props {^label Str}
        (message label [] self/label)
        (impl Named (message name [] : Str self/label)))
      (let box (Box ^label "box"))
      [(Named:name box) (box .Named:name)
       (Self:label box) (box .Self:label) (box .label)]
    """, "[\"box\" \"box\" \"box\" \"box\" \"box\"]"

  test "the receiver runs before the qualifier is read":
    unifyCallableCheck """
      (protocol A (message label [] : Str))
      (protocol B (message label [] : Str))
      (type Box ^props {})
      (impl A for Box (message label [] : Str "a"))
      (impl B for Box (message label [] : Str "b"))
      (var selected A)
      (fn make [] (set selected B) (Box))
      (selected:label (make))
    """, "\"b\""

  test "direct rejection precedes arguments while held calls stay eager":
    unifyCallableCheck """
      (protocol Paint (message paint [color] : Str))
      (let log [])
      (fn note [x] (log .push x) x)
      (try (Paint:paint (note 1) (note 2)) catch MessageError nil)
      (let held Paint:paint)
      (try (held (note 3) (note 4)) catch MessageError nil)
      log
    """, "[1 3 4]"

  test "prefix stages normalize before per-item preparation":
    unifyCallableCheck """
      (type Box ^props {^n Int} (message plus [x] (+ self/n x)))
      (let box (Box ^n 10))
      [(box -> Self:plus 1)
       ([1 2] => Self:plus box _ -> $into [])
       ([(Box ^n 2) (Box ^n 3)] => Self:plus 1 -> $into [])]
    """, "[11 [11 12] [3 4]]"
    unifyCallableCheck """
      (type Invalid ^props {})
      (let qualifier Invalid)
      (let effects [])
      (fn setup [] (effects .push "setup") 1)
      (let pending ([] => qualifier:missing (setup)))
      (pending .close)
      effects
    """, "[\"setup\"]"

  test "prefix sends retain spreads, named arguments, and explicit receivers":
    unifyCallableCheck """
      (type Box ^props {}
        (message collect [^tag, xs...] [tag xs]))
      (Self:collect (Box) ^tag "t" [1 2]...)
    """, "[\"t\" [1 2]]"
    for source in ["(Self:missing)", "(Self:missing [1]...)"]:
      expect GeneError: discard compileSource(source)

  test "concrete qualifiers remain invalid and super stays explicit":
    unifyCallableCheck """
      (type Base ^props {} (message value [] 1))
      (type Child : Base
        (message value [] ^^override (+ 1 (Self:value super))))
      [(Self:value (Child))
       (try (Base:value (Child)) false catch CallKindError true)]
    """, "[2 true]"

  test "held messages retain authored scope while held sends use their site":
    unifyCallableCheck """
      (protocol Label (message label [] : Int))
      (type Box ^props {})
      (fn capture []
        (impl Label for Box (message label [] : Int 1))
        Label:label)
      (let held (capture))
      (fn use []
        (impl Label for Box (message label [] : Int 2))
        [(held (Box)) ((Box) .%held) (Label:label (Box))])
      (use)
    """, "[1 2 2]"

suite "unified callable — checked signatures":
  test "functions and native functions receive checked callable views":
    unifyCallableCheck """
      (let original (fn [x] (+ x 1)))
      (let checked : (Callable [Int] Int) original)
      (let add : (Callable [Int Int] Int) +)
      (fn function_only [f : Fn] true)
      [(checked 2) (add 3 4) (function_only original)
       (try (function_only checked) false catch TypeError true)]
    """, "[3 7 true true]"

  test "arguments and results are checked around the target invocation":
    unifyCallableCheck """
      (let effects [])
      (let checked : (Callable [Int] Int)
        (fn [x] (effects .push x) "bad"))
      [(try (checked "bad") catch TypeError $err/where)
       (try (checked 1) catch TypeError $err/where)
       effects]
    """, "[\"Callable argument 0\" \"Callable result\" [1]]"

  test "a protocol message contract is checked on each receiver":
    unifyCallableCheck """
      (protocol Show (message show [] : Any))
      (type Good ^props {} (impl Show (message show [] : Any "ok")))
      (type Bad ^props {} (impl Show (message show [] : Any 7)))
      (let show : (Callable [Any] Str) Show:show)
      [(show (Good)) (try (show (Bad)) false catch TypeError true)]
    """, "[\"ok\" true]"

  test "selectors, constructors, and user Callable values participate":
    unifyCallableCheck """
      (type Box ^props {^n Int})
      (let construct : (Callable [] Box ^named {^n Int}) Box)
      (let get_n : (Callable [Box] Int) /n)
      (type Add ^props {^n Int}
        (impl Callable (message apply [call] (+ self/n call/0))))
      (let add : (Callable [Int] Int) (Add ^n 4))
      [(get_n (construct ^n 3)) (add 5)]
    """, "[3 9]"

  test "closed named arguments, optional names, and rest arguments are enforced":
    unifyCallableCheck """
      (fn collect [^tag, xs...] [tag xs])
      (let checked : (Callable [Int Int...] List ^named {^tag Str}) collect)
      [(checked 1 [2 3]... ^tag "t")
       (try (checked 1) false catch TypeError true)
       (try (checked 1 ^tag "t" ^extra 2) false catch TypeError true)
       (try (checked 1 "bad" ^tag "t") false catch TypeError true)]
    """, "[[\"t\" [1 2 3]] true true true]"

  test "omitted defaults run per call and Any named parameters remain required":
    unifyCallableCheck """
      (let count ($cell 0))
      (fn next [] (count .update (fn [n] (+ n 1))) (count .get))
      (fn target [x ^n : Int = (next)] (+ x n))
      (let checked : (Callable [Int] Int ^named {^n Int?}) target)
      (let required : (Callable [Int] Int ^named {^n Any}) target)
      [(count .get) (checked 10) (checked 10)
       (try (required 10) false catch TypeError true)]
    """, "[0 11 12 true]"

  test "explicit Void named values are preserved":
    unifyCallableCheck """
      (fn target [^value : Void] true)
      (let checked : (Callable [] Bool ^named {^value Void}) target)
      (checked ^value (do void))
    """, "true"

  test "declared errors are bounded while boundary errors remain TypeErrors":
    unifyCallableCheck """
      (type Boom ^props {^n Int} ^impl [Error])
      (impl Error for Boom (message message [] : Str ^errors [] ($to_str (quote Boom))))
      (fn fail_it [x] (fail (Boom ^n x)))
      (let allowed : (Callable [Int] Int ^errors [Boom]) fail_it)
      (let denied : (Callable [Int] Int ^errors []) fail_it)
      [(try (allowed 7) catch Boom $err/n)
       (try (denied 1) false catch Any true)
       (try (denied "bad") false catch TypeError true)]
    """, "[7 true true]"

  test "Fexpr values are excluded without changing nominal Fn matching":
    unifyCallableCheck """
      (fn syntax! [x] x)
      (try (let checked : (Callable [Int] Int) syntax!) false
       catch TypeError true)
    """, "true"

  test "a checked message view is invocation-only":
    unifyCallableCheck """
      (type Box ^props {} (message value [] 7))
      (let checked : (Callable [Box] Int) Self:value)
      [(checked (Box))
       (try ((Box) .%checked) false catch CallKindError true)]
    """, "[7 true]"

  test "admission does not bypass the target's own arity":
    unifyCallableCheck """
      (let checked : (Callable [Int] Int) (fn [x y] (+ x y)))
      (try (checked 1) false catch RuntimeError true)
    """, "true"

  test "signature types keep their authored implementation scope":
    unifyCallableCheck """
      (protocol P (message value [] : Int))
      (type Box ^props {})
      (fn make []
        (impl P for Box (message value [] : Int 7))
        (let checked : (Callable [P] Int) (fn [x] 1))
        checked)
      (let checked (make))
      (checked (Box))
    """, "1"

  test "malformed signatures are rejected at their boundary":
    for signature in ["(Callable Int Int)", "(Callable [Int... Int] Int)",
      "(Callable [Int] Int ^named [])", "(Callable [Int] Int ^extra 1)",
      "(Callable [Int] Int ^errors [Int])"]:
      expect GeneError:
        discard run(compileSource("(let f : " & signature & " (fn [x] x))"),
          newGlobalScope())

  test "views survive returned factories and nested collection boundaries":
    unifyCallableCheck """
      (fn make [n] : (Callable [Int] Int) (fn [x] (+ x n)))
      (let checked (make 3))
      (let callbacks : (List (Callable [Int] Int)) [(fn [x] "bad")])
      [(checked 4) (try (callbacks/0 1) false catch TypeError true)]
    """, "[7 true]"

  test "view calls preserve the original observable Call site":
    unifyCallableCheck """
      (type Probe ^props {}
        (impl Callable (message apply [call] call/site)))
      (let checked : (Callable [Int] Node) (Probe))
      (checked 7)
    """, "(checked 7)"

  test "view calls suspend without repeating the target":
    unifyCallableCheck """
      (scope
        (let events [])
        (let checked : (Callable [Int] Int)
          (fn [x] (events .push x) ($sleep 1) (+ x 1)))
        (let task (spawn ^lane root (checked 2)))
        [(await task) events])
    """, "[3 [2]]"

  test "checked error rows preserve panic and cancellation control":
    unifyCallableCheck """
      (scope
        (let events [])
        (let crash : (Callable [] Int ^errors []) (fn [] (panic "crash")))
        (let wait : (Callable [] Int ^errors [])
          (fn []
            (try (events .push "start") ($sleep 10000) 1
             ensure (events .push "cleanup"))))
        (let panicked (spawn ^lane root (crash)))
        (let waiting (spawn ^lane root (wait)))
        (let cancel (spawn ^lane root (do ($sleep 1) (waiting .cancel))))
        (cancel .join)
        [(match (panicked .join) (when (TaskOutcome/panic message) true) (else false))
         (match (waiting .join) (when TaskOutcome/cancelled true) (else false))
         events])
    """, "[true true [\"start\" \"cleanup\"]]"

  test "prefix and Callable signatures survive GIR round trips":
    let chunk = compileSource("""
      (type Box ^props {} (message value [] 7))
      (let checked : (Callable [Box] Int) Self:value)
      [(Self:value (Box)) (checked (Box))]
    """)
    let artifact = ExecutableGir(entryIdentity: "test/unify-callable",
      modules: @[CompiledModule(identity: "test/unify-callable", chunk: chunk,
        macroExports: initTable[string, MacroDef](), syntaxFnExports: @[],
        compileInterface: CompileNamespaceInterface(
          entries: initTable[string, CompileInterfaceEntry]()))])
    let decoded = decodeExecutableGir(encodeExecutableGir(artifact))
    check run(decoded.modules[0].chunk, newGlobalScope()).print() == "[7 7]"

