import gene/[compiler, printer, types, vm]
import std/[tables, unittest]

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

suite "protocols — declarations and dispatch":
  test "protocol declarations bind the protocol; messages are qualified members":
    ck "(protocol ToName (message to_name [self] : Str)) ToName",
       "(protocol ToName)"
    ck "(protocol ToName (message to_name [self] : Str)) ToName/to_name",
       "(message to_name)"
    # Message names are not bound in the enclosing scope (docs/core.md §1).
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(to_name 1)")

  test "built-in Send is a marker protocol":
    ck "Send", "(protocol Send)"

  test "message sends dispatch on the receiver nominal type":
    ck "(protocol ToName (message to_name [self] : Str)) " &
       "(type User ^props {^name Str}) " &
       "(impl ToName for User (message to_name [self] : Str self/name)) " &
       "((User ^name \"Ada\") ~ to_name)",
       "\"Ada\""

  test "qualified message sends work through the protocol value":
    ck "(protocol ToName (message to_name [self] : Str)) " &
       "(type User ^props {^name Str}) " &
       "(impl ToName for User (message to_name [self] : Str self/name)) " &
       "((User ^name \"Ada\") ~ ToName/to_name)",
       "\"Ada\""

  test "user-defined Callable values receive a Call envelope":
    ck "(type AddN ^props {^n Int}) " &
       "(impl Callable for AddN " &
       "  (message apply [self call] (+ self/n (call ~ /0)))) " &
       "((AddN ^n 5) 7)",
       "12"
    ck "(type PickNamed ^props {}) " &
       "(impl Callable for PickNamed " &
       "  (message apply [self call] call/named/name)) " &
       "((PickNamed) ^name \"Ada\")",
       "\"Ada\""

  test "the Call envelope carries the source call site":
    ck "(type Probe ^props {}) " &
       "(impl Callable for Probe (message apply [self call] call/site)) " &
       "(var p (Probe)) (p 7 8)",
       "(p 7 8)"

  test "Callable boundaries accept values with visible impls":
    ck "(type AddN ^props {^n Int}) " &
       "(impl Callable for AddN " &
       "  (message apply [self call] (+ self/n (call ~ /0)))) " &
       "(fn invoke [f : Callable] (f 2)) " &
       "(invoke (AddN ^n 3))",
       "5"

  test "ToStr customizes display conversion":
    ck "(type User ^props {^name Str}) " &
       "(impl ToStr for User (message to_str [self] : Str self/name)) " &
       "(var user (User ^name \"Ada\")) " &
       "[(to_str user) ($ \"hello \" user) $\"hi ${user}\"]",
       "[\"Ada\" \"hello Ada\" \"hi Ada\"]"
    ck "(type Bad ^props {}) " &
       "(impl ToStr for Bad (message to_str [self] 1)) " &
       "(try (to_str (Bad)) catch (TypeError ^where w) w)",
       "\"ToStr/to_str\""

  test "namespace protocol messages find receiver-scope impls":
    ck "(ns model " &
       "  (protocol ToName (message to_name [self] : Str)) " &
       "  (type User ^props {^name Str}) " &
       "  (impl ToName for User (message to_name [self] : Str self/name))) " &
       "((model/User ^name \"Ada\") ~ model/ToName/to_name)",
       "\"Ada\""

  test "parent type impl applies to child receivers":
    ck "(protocol ToName (message to_name [self] : Str)) " &
       "(type Animal ^props {^name Str}) " &
       "(type Dog ^is Animal ^props {^breed Str}) " &
       "(impl ToName for Animal (message to_name [self] : Str self/name)) " &
       "((Dog ^name \"Rex\" ^breed \"Lab\") ~ to_name)",
       "\"Rex\""

  test "overlapping parent and child impls are ambiguous at use":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type Animal ^props {^name Str}) " &
                     "(type Dog ^is Animal ^props {^breed Str}) " &
                     "(impl ToName for Animal (message to_name [self] : Str self/name)) " &
                     "(impl ToName for Dog (message to_name [self] : Str self/breed)) " &
                     "((Dog ^name \"Rex\" ^breed \"Lab\") ~ ToName/to_name)")

  test "type ^impl requirements are checked after forward impls":
    ck "(protocol ToName (message to_name [self] : Str)) " &
       "(type User ^props {^name Str} ^impl [ToName]) " &
       "(impl ToName for User (message to_name [self] : Str self/name)) " &
       "((User ^name \"Ada\") ~ to_name)",
       "\"Ada\""

  test "types can require manual Send impls":
    ck "(type Token ^props {^id Int} ^impl [Send]) " &
       "(impl Send for Token) " &
       "(var t (Token ^id 7)) t/id",
       "7"

  test "missing type ^impl requirements are rejected at scope completion":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str} ^impl [ToName])")
    expect GeneError:
      discard runStr("(type Token ^props {^id Int} ^impl [Send])")

  test "type ^impl entries must resolve to protocols":
    expect GeneError:
      discard runStr("(var NotProtocol 1) " &
                     "(type User ^props {^name Str} ^impl [NotProtocol])")
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str} ^impl ToName)")

  test "type ^derive requests resolve to protocols and are retained":
    let scope = newGlobalScope()
    discard run(compileSource("(protocol Clone (derive [t req] nil)) " &
                              "(protocol ToJson (derive [t req] nil)) " &
                              "(type User ^props {^name Str} " &
                              "  ^derive [Clone (ToJson ^skip [password])])"),
                scope)
    let user = scope.lookup("User")
    check user.typeDerivedProtocols.len == 2
    check user.typeDerivedProtocols[0].protocolName == "Clone"
    check user.typeDerivedProtocols[1].protocolName == "ToJson"
    check user.typeDeriveRequests.len == 2
    check user.typeDeriveRequests[1].kind == vkNode
    check user.typeDeriveRequests[1].props.len == 1

  test "type ^derive entries must resolve to protocols":
    expect GeneError:
      discard runStr("(var NotProtocol 1) " &
                     "(type User ^props {^name Str} ^derive [NotProtocol])")
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str} ^derive ToName)")

  test "type ^derive requires a protocol-local derive form":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str} ^derive [ToName])")

  test "protocol-local derive generates impls for required protocols":
    ck "(protocol HasLabel " &
       "  (message label [self] : Str) " &
       "  (derive [t : Type, req] " &
       "    `(impl HasLabel for %t " &
       "       (message label [self] : Str self/name)))) " &
       "(type User ^props {^name Str} ^impl [HasLabel] ^derive [HasLabel]) " &
       "((User ^name \"Ada\") ~ label)",
       "\"Ada\""

  test "protocol-local derive receives option-carrying requests":
    ck "(protocol HasLabel " &
       "  (message label [self] : Str) " &
       "  (derive [t : Type, req] " &
       "    `(impl HasLabel for %t " &
       "       (message label [self] : Str %req/label)))) " &
       "(type User ^props {^name Str} ^derive [(HasLabel ^label \"generated\")]) " &
       "((User ^name \"Ada\") ~ label)",
       "\"generated\""

  test "deriving a child runs only the child's derive and emits one complete impl":
    ck "(protocol A " &
       "  (message a [self] : Str) " &
       "  (derive [t req] " &
       "    `(impl A for %t (message a [self] : Str \"ancestor\")))) " &
       "(protocol B ^inherit [A] " &
       "  (message b [self] : Str) " &
       "  (derive [t req] " &
       "    `(impl B for %t " &
       "       (message a [self] : Str \"via-child\") " &
       "       (message b [self] : Str \"child\")))) " &
       "(type T ^props {} ^derive [B]) " &
       "(var t (T)) [(t ~ A/a) (t ~ B/b)]",
       "[\"via-child\" \"child\"]"

  test "protocol-local derive may only generate own impl declarations":
    expect GeneError:
      discard runStr("(protocol HasLabel " &
                     "  (derive [t : Type, req] `(var generated 1))) " &
                     "(type User ^props {^name Str} ^derive [HasLabel])")
    expect GeneError:
      discard runStr("(protocol Other) " &
                     "(protocol HasLabel " &
                     "  (derive [t : Type, req] `(impl Other for %t))) " &
                     "(type User ^props {^name Str} ^derive [HasLabel])")

  test "message implementation return annotations are checked":
    ck "(try (protocol ToName (message to_name [self] : Str)) " &
       "(type User ^props {^name Str}) " &
       "(impl ToName for User (message to_name [self] : Str 1)) " &
       "((User ^name \"Ada\") ~ to_name) " &
       "catch (TypeError ^where w) w)",
       "\"return from 'to_name'\""

  test "missing impl is a recoverable runtime error":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str}) " &
                     "((User ^name \"Ada\") ~ ToName/to_name)")

  test "duplicate visible impls are rejected":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str}) " &
                     "(impl ToName for User (message to_name [self] : Str self/name)) " &
                     "(impl ToName for User (message to_name [self] : Str self/name))")

  test "impls must cover exactly the protocol messages":
    expect GeneError:
      discard runStr("(protocol P (message a [self]) (message b [self])) " &
                     "(type T ^props {}) " &
                     "(impl P for T (message a [self] 1))")
    expect GeneError:
      discard runStr("(protocol P (message a [self])) " &
                     "(type T ^props {}) " &
                     "(impl P for T (message a [self] 1) (message b [self] 2))")

  test "protocol defaults fill an explicit impl but do not imply conformance":
    ck "(protocol P " &
       "  (message fallback [self] : Str \"default\") " &
       "  (message chosen [self] : Str \"base\")) " &
       "(type T ^props {}) " &
       "(impl P for T (message chosen [self] : Str \"explicit\")) " &
       "(var t (T)) [(t ~ fallback) (t ~ chosen)]",
       "[\"default\" \"explicit\"]"
    expect GeneError:
      discard runStr("(protocol P (message fallback [self] : Str \"default\")) " &
                     "(type T ^props {} ^impl [P])")
    expect GeneError:
      discard runStr("(protocol P (message fallback [self] : Str \"default\")) " &
                     "(type T ^props {}) ((T) ~ fallback)")

  test "inherited defaults fill one complete child impl":
    ck "(protocol A (message a [self] : Str \"a\")) " &
       "(protocol B ^inherit [A] (message b [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl B for T (message b [self] : Str \"b\")) " &
       "(var t (T)) [(t ~ A/a) (t ~ B/b)]",
       "[\"a\" \"b\"]"

  test "universal conformance must be explicit and fully defaulted":
    ck "(protocol P ^universal true (message value [self] : Int 7)) " &
       "(type T ^props {} ^impl [P]) ((T) ~ P/value)",
       "7"
    expect GeneError:
      discard runStr("(protocol P ^universal true (message value [self] : Int))")
    expect GeneError:
      discard runStr("(protocol P ^universal 1)")

  test "impl signatures must match protocol message signatures":
    expect GeneError:
      discard runStr("(protocol P (message value [self x : Int] : Str)) " &
                     "(type T ^props {}) " &
                     "(impl P for T " &
                     "  (message value [self x : Str] : Str \"x\"))")
    expect GeneError:
      discard runStr("(protocol P (message value [self] : Str)) " &
                     "(type T ^props {}) " &
                     "(impl P for T (message value [self] : Int 1))")

  test "deep recursion through a protocol message uses heap frames":
    # Message dispatch resolves to the receiver's impl at the call site and pushes
    # a heap frame, instead of double-recursing through applyCall. Deep recursion
    # through a method therefore no longer grows the Nim stack.
    ck "(protocol Count (message down [self n])) " &
       "(type Counter ^props {}) " &
       "(impl Count for Counter " &
       "  (message down [self n] " &
       "    (if (== n 0) 0 (+ 1 (self ~ down (- n 1)))))) " &
       "((Counter) ~ down 200000)",
       "200000"

suite "protocols — ^inherit and qualified message identity":
  test "^inherit flattens ancestor messages into the impl requirement":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl B for T " &
       "  (message do_a [self] : Str \"a\") " &
       "  (message do_b [self] : Str \"b\")) " &
       "(var t (T)) " &
       "[(t ~ do_a) (t ~ do_b) (t ~ A/do_a) (t ~ B/do_b)]",
       "[\"a\" \"b\" \"a\" \"b\"]"

  test "^inherit diamond does not duplicate the inherited message":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
       "(protocol C ^inherit [A B] (message do_c [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl C for T " &
       "  (message do_a [self] : Str \"a\") " &
       "  (message do_b [self] : Str \"b\") " &
       "  (message do_c [self] : Str \"c\")) " &
       "(var t (T)) " &
       "[(t ~ do_a) (t ~ do_b) (t ~ do_c) (t ~ C/do_a)]",
       "[\"a\" \"b\" \"c\" \"a\"]"

  test "^inherit with multiple unrelated parents, no diamond":
    ck "(protocol X (message do_x [self] : Str)) " &
       "(protocol Y (message do_y [self] : Str)) " &
       "(protocol Z ^inherit [X Y] (message do_z [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl Z for T " &
       "  (message do_x [self] : Str \"x\") " &
       "  (message do_y [self] : Str \"y\") " &
       "  (message do_z [self] : Str \"z\")) " &
       "(var t (T)) " &
       "[(t ~ do_x) (t ~ do_y) (t ~ do_z)]",
       "[\"x\" \"y\" \"z\"]"

  test "impl missing an inherited message is rejected":
    expect GeneError:
      discard runStr("(protocol A (message do_a [self] : Str)) " &
                     "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
                     "(type T ^props {}) " &
                     "(impl B for T (message do_b [self] : Str \"b\"))")

  test "same-name messages across independent parents coexist":
    # docs/core.md §3.3: X/clash and Y/clash are distinct messages; the impl
    # qualifies them, sends use the qualified spelling, and the bare send of
    # the ambiguous simple name is a use-site error.
    ck "(protocol X (message clash [self] : Str)) " &
       "(protocol Y (message clash [self] : Str)) " &
       "(protocol Z ^inherit [X Y] (message do_z [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl Z for T " &
       "  (message X/clash [self] : Str \"x-behavior\") " &
       "  (message Y/clash [self] : Str \"y-behavior\") " &
       "  (message do_z [self] : Str \"z\")) " &
       "(var t (T)) " &
       "[(t ~ X/clash) (t ~ Y/clash) (t ~ do_z)]",
       "[\"x-behavior\" \"y-behavior\" \"z\"]"
    expect GeneError:
      discard runStr("(protocol X (message clash [self] : Str)) " &
                     "(protocol Y (message clash [self] : Str)) " &
                     "(protocol Z ^inherit [X Y]) " &
                     "(type T ^props {}) " &
                     "(impl Z for T " &
                     "  (message X/clash [self] : Str \"x\") " &
                     "  (message Y/clash [self] : Str \"y\")) " &
                     "((T) ~ clash)")

  test "unqualified impl message names must be unique in the closure":
    expect GeneError:
      discard runStr("(protocol X (message clash [self] : Str)) " &
                     "(protocol Y (message clash [self] : Str)) " &
                     "(protocol Z ^inherit [X Y]) " &
                     "(type T ^props {}) " &
                     "(impl Z for T " &
                     "  (message clash [self] : Str \"which one?\") " &
                     "  (message Y/clash [self] : Str \"y\"))")

  test "redeclaring an inherited simple name creates a distinct message":
    # docs/core.md §3.4: B/do_a does not override A/do_a; both are in B's
    # closure and both must be implemented.
    ck "(protocol A (message do_a [self] : Str)) " &
       "(protocol B ^inherit [A] (message do_a [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl B for T " &
       "  (message A/do_a [self] : Str \"from-A\") " &
       "  (message B/do_a [self] : Str \"from-B\")) " &
       "(var t (T)) " &
       "[(t ~ A/do_a) (t ~ B/do_a)]",
       "[\"from-A\" \"from-B\"]"
    expect GeneError:
      discard runStr("(protocol A (message do_a [self] : Str)) " &
                     "(protocol B ^inherit [A] (message do_a [self] : Str)) " &
                     "(type T ^props {}) " &
                     "(impl B for T (message B/do_a [self] : Str \"only-B\"))")

  test "a child-protocol spelling reaches an unambiguous inherited message":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl B for T " &
       "  (message do_a [self] : Str \"a\") " &
       "  (message do_b [self] : Str \"b\")) " &
       "((T) ~ B/do_a)",
       "\"a\""

  test "^inherit requires already-defined parent protocols":
    expect GeneError:
      discard runStr("(protocol B ^inherit [A] (message do_b [self] : Str)) " &
                     "(protocol A (message do_a [self] : Str))")

  test "impl of a child protocol satisfies a parent-typed ^impl requirement":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
       "(type T ^props {} ^impl [A]) " &
       "(impl B for T " &
       "  (message do_a [self] : Str \"a\") " &
       "  (message do_b [self] : Str \"b\")) " &
       "((T) ~ do_a)",
       "\"a\""

  test "overlapping impls of a protocol and its child are ambiguous at use":
    expect GeneError:
      discard runStr("(protocol A (message do_a [self] : Str)) " &
                     "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
                     "(type T ^props {}) " &
                     "(impl A for T (message do_a [self] : Str \"a-direct\")) " &
                     "(impl B for T " &
                     "  (message do_a [self] : Str \"a-via-b\") " &
                     "  (message do_b [self] : Str \"b\")) " &
                     "((T) ~ A/do_a)")

suite "types — type-direct messages and sends":
  test "type-direct messages are sendable and qualified members":
    ck "(type Box ^props {^val Int} " &
       "  (message get [self] self/val) " &
       "  (message doubled [self] (* self/val 2))) " &
       "(var b (Box ^val 7)) " &
       "[(b ~ get) (b ~ doubled) (Box/get b)]",
       "[7 14 7]"

  test "a receiver message wins over a lexical binding at send sites":
    # docs/core.md §9.1/§9.3: receiver-first; the bare call stays lexical.
    ck "(fn get [x] \"lexical\") " &
       "(type Box ^props {^val Int} (message get [self] self/val)) " &
       "(var b (Box ^val 7)) " &
       "[(b ~ get) (get b)]",
       "[7 \"lexical\"]"

  test "sends fall back to lexical bindings for plain receivers":
    ck "(var xs [1 2 3]) (fn second [l] l/1) (xs ~ second)",
       "2"

  test "implicit-self sends resolve in the receiver's context":
    ck "(type Box ^props {^val Int} (message get [self] self/val)) " &
       "(var self (Box ^val 42)) (~ get)",
       "42"

  test "protocol impls win over shadowing lexical bindings at send sites":
    ck "(protocol P (message pm [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl P for T (message pm [self] : Str \"via-impl\")) " &
       "(fn probe [pm] ((T) ~ pm)) " &
       "(probe (fn [x] \"shadow\"))",
       "\"via-impl\""

  test "child types reach parent type-direct messages via the ^is chain":
    ck "(type Animal ^props {^name Str} " &
       "  (message speak [self] $\"${self/name} makes a sound\")) " &
       "(type Dog ^is Animal ^props {^breed Str}) " &
       "(var d (Dog ^name \"Rex\" ^breed \"Lab\")) " &
       "[(d ~ speak) (Dog/speak d)]",
       "[\"Rex makes a sound\" \"Rex makes a sound\"]"

  test "a child's same-named message shadows the parent's":
    ck "(type Animal ^props {^name Str} " &
       "  (message speak [self] \"generic\")) " &
       "(type Dog ^is Animal ^props {} " &
       "  (message speak [self] \"woof\")) " &
       "(var d (Dog ^name \"Rex\")) " &
       "[(d ~ speak) ((Animal ^name \"Generic\") ~ speak)]",
       "[\"woof\" \"generic\"]"

  test "type-direct overrides preserve the inherited callable signature":
    ck "(type A ^props {} (message value [self x : Int] : Int x)) " &
       "(type B ^is A ^props {} " &
       "  (message value [self x : Int] : Int (+ x 1))) " &
       "((B) ~ value 2)",
       "3"
    expect GeneError:
      discard runStr("(type A ^props {} " &
                     "  (message value [self x : Int] : Int x)) " &
                     "(type B ^is A ^props {} " &
                     "  (message value [self x : Str] : Int 1))")
    expect GeneError:
      discard runStr("(type A ^props {} (message value [self] : Int 1)) " &
                     "(type B ^is A ^props {} " &
                     "  (message value [self] : Str \"x\"))")

  test "type-direct messages do not satisfy ^impl requirements":
    expect GeneError:
      discard runStr("(protocol P (message m [self])) " &
                     "(type T ^props {} ^impl [P] (message m [self] 1))")

  test "type body items must be simple message declarations":
    expect GeneError:
      discard runStr("(type T ^props {} (frob 1))")
    expect GeneError:
      discard runStr("(type T ^props {} " &
                     "  (message m [self] 1) (message m [self] 2))")
    expect GeneError:
      discard runStr("(protocol P (message m [self])) " &
                     "(type T ^props {} (message P/m [self] 1))")

suite "types — inline protocol impls":
  test "inline impls dispatch like standalone impls":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(type T ^props {} " &
       "  (impl A (message do_a [self] : Str \"inline\"))) " &
       "(var t (T)) " &
       "[(t ~ do_a) (t ~ A/do_a)]",
       "[\"inline\" \"inline\"]"

  test "inline marker impls satisfy ^impl requirements":
    ck "(type Token ^props {^id Int} ^impl [Send] (impl Send)) " &
       "(var t (Token ^id 7)) t/id",
       "7"

  test "inline impls must cover the protocol closure":
    expect GeneError:
      discard runStr("(protocol P (message a [self]) (message b [self])) " &
                     "(type T ^props {} (impl P (message a [self] 1)))")

  test "inline impls cover ^inherit ancestor messages":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
       "(type T ^props {} ^impl [A] " &
       "  (impl B " &
       "    (message do_a [self] : Str \"a\") " &
       "    (message do_b [self] : Str \"b\"))) " &
       "(var t (T)) " &
       "[(t ~ do_a) (t ~ do_b)]",
       "[\"a\" \"b\"]"

  test "inline impls qualify same-named closure messages":
    ck "(protocol X (message clash [self] : Str)) " &
       "(protocol Y (message clash [self] : Str)) " &
       "(protocol Z ^inherit [X Y]) " &
       "(type T ^props {} " &
       "  (impl Z " &
       "    (message X/clash [self] : Str \"x\") " &
       "    (message Y/clash [self] : Str \"y\"))) " &
       "(var t (T)) " &
       "[(t ~ X/clash) (t ~ Y/clash)]",
       "[\"x\" \"y\"]"

  test "inline impls coexist with type-direct messages":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(type T ^props {^val Int} " &
       "  (message own [self] self/val) " &
       "  (impl A (message do_a [self] : Str \"via-impl\"))) " &
       "(var t (T ^val 9)) " &
       "[(t ~ own) (t ~ do_a)]",
       "[9 \"via-impl\"]"

  test "inline impls take no receiver":
    expect GeneError:
      discard runStr("(protocol A (message do_a [self] : Str)) " &
                     "(type T ^props {} " &
                     "  (impl A for T (message do_a [self] : Str \"x\")))")

  test "inline plus standalone impls of one protocol are duplicates":
    expect GeneError:
      discard runStr("(protocol A (message do_a [self] : Str)) " &
                     "(type T ^props {} " &
                     "  (impl A (message do_a [self] : Str \"inline\"))) " &
                     "(impl A for T (message do_a [self] : Str \"standalone\"))")

  test "inline impl targets must be protocols":
    expect GeneError:
      discard runStr("(var NotProtocol 1) " &
                     "(type T ^props {} (impl NotProtocol))")

suite "protocols — namespace-qualified declaration paths":
  test "^inherit accepts namespace-qualified parents":
    ck "(ns p (protocol A (message do_a [self] : Str))) " &
       "(protocol B ^inherit [p/A] (message do_b [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl B for T " &
       "  (message do_a [self] : Str \"a\") " &
       "  (message do_b [self] : Str \"b\")) " &
       "(var t (T)) " &
       "[(t ~ do_a) (t ~ do_b) (t ~ p/A/do_a)]",
       "[\"a\" \"b\" \"a\"]"

  test "^impl accepts namespace-qualified protocols":
    ck "(ns p (protocol A (message do_a [self] : Str))) " &
       "(type T ^props {} ^impl [p/A]) " &
       "(impl p/A for T (message do_a [self] : Str \"ok\")) " &
       "((T) ~ do_a)",
       "\"ok\""

  test "impl bodies accept namespace-qualified message owners":
    ck "(ns p " &
       "  (protocol X (message clash [self] : Str)) " &
       "  (protocol Y (message clash [self] : Str))) " &
       "(protocol Z ^inherit [p/X p/Y]) " &
       "(type T ^props {}) " &
       "(impl Z for T " &
       "  (message p/X/clash [self] : Str \"x\") " &
       "  (message p/Y/clash [self] : Str \"y\")) " &
       "(var t (T)) " &
       "[(t ~ p/X/clash) (t ~ p/Y/clash)]",
       "[\"x\" \"y\"]"

  test "^derive accepts namespace-qualified protocols":
    # The derive template names its own protocol; the generated impl runs in
    # the deriving type's scope where the protocol may not be bound, so the
    # validated protocol value is substituted before execution.
    ck "(ns p " &
       "  (protocol HasLabel " &
       "    (message label [self] : Str) " &
       "    (derive [t req] " &
       "      `(impl HasLabel for %t (message label [self] : Str self/name))))) " &
       "(type U ^props {^name Str} ^derive [p/HasLabel]) " &
       "((U ^name \"Ada\") ~ label)",
       "\"Ada\""
