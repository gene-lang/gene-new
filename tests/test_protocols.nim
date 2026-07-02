import gene/[compiler, printer, types, vm]
import std/[tables, unittest]

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template runStr(src: string): Value =
  run(compileSource(src), newGlobalScope())

suite "protocols — declarations and dispatch":
  test "protocol declarations bind protocol and message values":
    ck "(protocol ToName (message to_name [self] : Str)) ToName",
       "(protocol ToName)"
    ck "(protocol ToName (message to_name [self] : Str)) to_name",
       "(message to_name)"

  test "built-in Send is a marker protocol":
    ck "Send", "(protocol Send)"

  test "impl message dispatches on the receiver nominal type":
    ck "(protocol ToName (message to_name [self] : Str)) " &
       "(type User ^props {^name Str}) " &
       "(impl ToName User (message to_name [self] : Str self/name)) " &
       "(to_name (User ^name \"Ada\"))",
       "\"Ada\""

  test "message values work with flipped receiver calls":
    ck "(protocol ToName (message to_name [self] : Str)) " &
       "(type User ^props {^name Str}) " &
       "(impl ToName User (message to_name [self] : Str self/name)) " &
       "((User ^name \"Ada\") ~ to_name)",
       "\"Ada\""

  test "user-defined Callable values receive a Call envelope":
    ck "(type AddN ^props {^n Int}) " &
       "(impl Callable AddN " &
       "  (message apply [self call] (+ self/n (call ~ /0)))) " &
       "((AddN ^n 5) 7)",
       "12"
    ck "(type PickNamed ^props {}) " &
       "(impl Callable PickNamed " &
       "  (message apply [self call] call/named/name)) " &
       "((PickNamed) ^name \"Ada\")",
       "\"Ada\""

  test "the Call envelope carries the source call site":
    ck "(type Probe ^props {}) " &
       "(impl Callable Probe (message apply [self call] call/site)) " &
       "(var p (Probe)) (p 7 8)",
       "(p 7 8)"

  test "Callable boundaries accept values with visible impls":
    ck "(type AddN ^props {^n Int}) " &
       "(impl Callable AddN " &
       "  (message apply [self call] (+ self/n (call ~ /0)))) " &
       "(fn invoke [f : Callable] (f 2)) " &
       "(invoke (AddN ^n 3))",
       "5"

  test "ToStr customizes display conversion":
    ck "(type User ^props {^name Str}) " &
       "(impl ToStr User (message to-str [self] : Str self/name)) " &
       "(var user (User ^name \"Ada\")) " &
       "[(to-str user) ($ \"hello \" user) $\"hi ${user}\"]",
       "[\"Ada\" \"hello Ada\" \"hi Ada\"]"
    ck "(type Bad ^props {}) " &
       "(impl ToStr Bad (message to-str [self] 1)) " &
       "(try (to-str (Bad)) catch (TypeError ^where w) w)",
       "\"ToStr/to-str\""

  test "namespace protocol messages find receiver-scope impls":
    ck "(ns model " &
       "  (protocol ToName (message to_name [self] : Str)) " &
       "  (type User ^props {^name Str}) " &
       "  (impl ToName User (message to_name [self] : Str self/name))) " &
       "(model/to_name (model/User ^name \"Ada\"))",
       "\"Ada\""

  test "parent type impl applies to child receivers":
    ck "(protocol ToName (message to_name [self] : Str)) " &
       "(type Animal ^props {^name Str}) " &
       "(type Dog ^is Animal ^props {^breed Str}) " &
       "(impl ToName Animal (message to_name [self] : Str self/name)) " &
       "(to_name (Dog ^name \"Rex\" ^breed \"Lab\"))",
       "\"Rex\""

  test "overlapping parent and child impls are ambiguous at use":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type Animal ^props {^name Str}) " &
                     "(type Dog ^is Animal ^props {^breed Str}) " &
                     "(impl ToName Animal (message to_name [self] : Str self/name)) " &
                     "(impl ToName Dog (message to_name [self] : Str self/breed)) " &
                     "(to_name (Dog ^name \"Rex\" ^breed \"Lab\"))")

  test "type ^impl requirements are checked after forward impls":
    ck "(protocol ToName (message to_name [self] : Str)) " &
       "(type User ^props {^name Str} ^impl [ToName]) " &
       "(impl ToName User (message to_name [self] : Str self/name)) " &
       "(to_name (User ^name \"Ada\"))",
       "\"Ada\""

  test "types can require manual Send impls":
    ck "(type Token ^props {^id Int} ^impl [Send]) " &
       "(impl Send Token) " &
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
       "    `(impl HasLabel %t " &
       "       (message label [self] : Str self/name)))) " &
       "(type User ^props {^name Str} ^impl [HasLabel] ^derive [HasLabel]) " &
       "(label (User ^name \"Ada\"))",
       "\"Ada\""

  test "protocol-local derive receives option-carrying requests":
    ck "(protocol HasLabel " &
       "  (message label [self] : Str) " &
       "  (derive [t : Type, req] " &
       "    `(impl HasLabel %t " &
       "       (message label [self] : Str %req/label)))) " &
       "(type User ^props {^name Str} ^derive [(HasLabel ^label \"generated\")]) " &
       "(label (User ^name \"Ada\"))",
       "\"generated\""

  test "protocol-local derive may only generate own impl declarations":
    expect GeneError:
      discard runStr("(protocol HasLabel " &
                     "  (derive [t : Type, req] `(var generated 1))) " &
                     "(type User ^props {^name Str} ^derive [HasLabel])")
    expect GeneError:
      discard runStr("(protocol Other) " &
                     "(protocol HasLabel " &
                     "  (derive [t : Type, req] `(impl Other %t))) " &
                     "(type User ^props {^name Str} ^derive [HasLabel])")

  test "message implementation return annotations are checked":
    ck "(try (protocol ToName (message to_name [self] : Str)) " &
       "(type User ^props {^name Str}) " &
       "(impl ToName User (message to_name [self] : Str 1)) " &
       "(to_name (User ^name \"Ada\")) " &
       "catch (TypeError ^where w) w)",
       "\"return from 'to_name'\""

  test "missing impl is a recoverable runtime error":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str}) " &
                     "(to_name (User ^name \"Ada\"))")

  test "duplicate visible impls are rejected":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str}) " &
                     "(impl ToName User (message to_name [self] : Str self/name)) " &
                     "(impl ToName User (message to_name [self] : Str self/name))")

  test "impls must cover exactly the protocol messages":
    expect GeneError:
      discard runStr("(protocol P (message a [self]) (message b [self])) " &
                     "(type T ^props {}) " &
                     "(impl P T (message a [self] 1))")
    expect GeneError:
      discard runStr("(protocol P (message a [self])) " &
                     "(type T ^props {}) " &
                     "(impl P T (message a [self] 1) (message b [self] 2))")

  test "^inherit flattens ancestor messages into the impl requirement":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl B T " &
       "  (message do_a [self] : Str \"a\") " &
       "  (message do_b [self] : Str \"b\")) " &
       "[(do_a (T)) (do_b (T)) ((T) ~ A/do_a) ((T) ~ B/do_b)]",
       "[\"a\" \"b\" \"a\" \"b\"]"

  test "^inherit diamond does not duplicate the inherited message":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
       "(protocol C ^inherit [A B] (message do_c [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl C T " &
       "  (message do_a [self] : Str \"a\") " &
       "  (message do_b [self] : Str \"b\") " &
       "  (message do_c [self] : Str \"c\")) " &
       "[(do_a (T)) (do_b (T)) (do_c (T))]",
       "[\"a\" \"b\" \"c\"]"

  test "^inherit with multiple unrelated parents, no diamond":
    ck "(protocol X (message do_x [self] : Str)) " &
       "(protocol Y (message do_y [self] : Str)) " &
       "(protocol Z ^inherit [X Y] (message do_z [self] : Str)) " &
       "(type T ^props {}) " &
       "(impl Z T " &
       "  (message do_x [self] : Str \"x\") " &
       "  (message do_y [self] : Str \"y\") " &
       "  (message do_z [self] : Str \"z\")) " &
       "[(do_x (T)) (do_y (T)) (do_z (T))]",
       "[\"x\" \"y\" \"z\"]"

  test "impl missing an inherited message is rejected":
    expect GeneError:
      discard runStr("(protocol A (message do_a [self] : Str)) " &
                     "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
                     "(type T ^props {}) " &
                     "(impl B T (message do_b [self] : Str \"b\"))")

  test "child protocol cannot redeclare an inherited message name":
    expect GeneError:
      discard runStr("(protocol A (message do_a [self] : Str)) " &
                     "(protocol B ^inherit [A] (message do_a [self] : Str))")

  test "independent parents with a colliding message name conflict at definition":
    expect GeneError:
      discard runStr("(protocol X (message clash [self] : Str)) " &
                     "(protocol Y (message clash [self] : Str)) " &
                     "(protocol Z ^inherit [X Y] (message do_z [self] : Str))")

  test "^inherit requires already-defined parent protocols":
    expect GeneError:
      discard runStr("(protocol B ^inherit [A] (message do_b [self] : Str)) " &
                     "(protocol A (message do_a [self] : Str))")

  test "impl of a child protocol satisfies a parent-typed ^impl requirement":
    ck "(protocol A (message do_a [self] : Str)) " &
       "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
       "(type T ^props {} ^impl [A]) " &
       "(impl B T " &
       "  (message do_a [self] : Str \"a\") " &
       "  (message do_b [self] : Str \"b\")) " &
       "(do_a (T))",
       "\"a\""

  test "overlapping impls of a protocol and its child are ambiguous at use":
    expect GeneError:
      discard runStr("(protocol A (message do_a [self] : Str)) " &
                     "(protocol B ^inherit [A] (message do_b [self] : Str)) " &
                     "(type T ^props {}) " &
                     "(impl A T (message do_a [self] : Str \"a-direct\")) " &
                     "(impl B T " &
                     "  (message do_a [self] : Str \"a-via-b\") " &
                     "  (message do_b [self] : Str \"b\")) " &
                     "(do_a (T))")

  test "deep recursion through a protocol message uses heap frames":
    # Message dispatch resolves to the receiver's impl at the call site and pushes
    # a heap frame, instead of double-recursing through applyCall. Deep recursion
    # through a method therefore no longer grows the Nim stack.
    ck "(protocol Count (message down [self n])) " &
       "(type Counter ^props {}) " &
       "(impl Count Counter " &
       "  (message down [self n] (if (= n 0) 0 (+ 1 (down self (- n 1)))))) " &
       "(down (Counter) 200000)",
       "200000"
