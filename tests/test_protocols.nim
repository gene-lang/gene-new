import gene/[compiler, printer, types, vm]
import std/unittest

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

  test "missing type ^impl requirements are rejected at scope completion":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str} ^impl [ToName])")

  test "type ^impl entries must resolve to protocols":
    expect GeneError:
      discard runStr("(var NotProtocol 1) " &
                     "(type User ^props {^name Str} ^impl [NotProtocol])")
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str} ^impl ToName)")

  test "type ^derive requests resolve to protocols and are retained":
    let scope = newGlobalScope()
    discard run(compileSource("(protocol Clone) (protocol ToJson) " &
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

  test "^derive plumbing does not satisfy manual ^impl requirements yet":
    expect GeneError:
      discard runStr("(protocol ToName (message to_name [self] : Str)) " &
                     "(type User ^props {^name Str} ^impl [ToName] ^derive [ToName])")

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
