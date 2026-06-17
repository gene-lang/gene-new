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
