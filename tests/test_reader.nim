import gene/reader
import gene/printer
import gene/types
import std/[strutils, unittest]

template check_read(src: string, expected: string) =
  check read(src).print() == expected

suite "reader — atoms and containers":
  test "node":               check_read("(a b c)",   "(a b c)")
  test "list":               check_read("[1 2 3]",   "[1 2 3]")
  test "map":                check_read("{^name \"Alice\" ^age 30}", "{^name \"Alice\" ^age 30}")
  test "immutable node":     check_read("#(h ^p v b)", "#(h ^p v b)")
  test "immutable list":     check_read("#[1 2 3]",  "#[1 2 3]")
  test "immutable map":      check_read("#{^a 1}",   "#{^a 1}")
  test "integer":            check_read("42",         "42")
  test "big integer":        check_read("9223372036854775808", "9223372036854775808")
  test "hex integer":
    check_read("0x0", "0")
    check_read("0x1f", "31")
    check_read("0x4869", "18537")
    check_read("0xDEADbeef", "3735928559")
    check_read("0x7fffffffffffffff", "9223372036854775807")
    check_read("0x10000000000000000", "18446744073709551616")
    check read("0x4869").kind == vkInt
    check read("0x4869").intToString == "18537"
  test "a hex literal is classified from the whole atom":
    # A hex run followed by a symbol char is one atom, exactly as `1-2` and
    # `12abc` already are. Splitting it would silently change call arity:
    # `(f 0x1fg)` would pass two arguments instead of failing.
    check_read("0x1f-3a", "0x1f-3a")
    check_read("0x1fg", "0x1fg")
    check_read("-0x1f", "-31")
    check_read("0x1f", "31")
    # `0x` not followed by a hex digit stays a symbol.
    check_read("0x", "0x")
    check_read("0xg", "0xg")
  test "float":              check_read("3.14",       "3.14")
  test "bool true":          check_read("true",       "true")
  test "bool false":         check_read("false",      "false")
  test "nil":                check_read("nil",        "nil")
  test "string":             check_read("\"hello\"",  "\"hello\"")
  test "string escapes":
    check_read("\"line\\n\\\"slash\\\\\"", "\"line\\n\\\"slash\\\\\"")
    check_read("\"\\u00E9\\u{1F600}\"", "\"é😀\"")
  test "triple-quoted string":
    check_read("\"\"\"say \"hi\" now\"\"\"", "\"say \\\"hi\\\" now\"")
    check_read("\"\"\"hello \"Gene\\\"\"\"\"", "\"hello \\\"Gene\\\"\"")
  test "bytes":
    check_read("#B#01000001", "#B16#41")
    check_read("#B16#4869", "#B16#4869")
    check_read("#B64#SGk=", "#B16#4869")
    check_read("#B#01001000~ 01101001", "#B16#4869")
    check_read("#B16#48~\n 69", "#B16#4869")
    check_read("#B64#SGVs~ bG8=", "#B16#48656c6c6f")
    check read("#B16#4869").kind == vkBytes
  test "regex":
    check_read("#\"\\d+\"im", "#\"\\d+\"im")
    let quoted = read("#\"hello\\\"Gene\"")
    check quoted.kind == vkRegex
    check quoted.regexPattern == "hello\\\"Gene"
    check_read("#\"\"\"^\\s*(\\w+)\\s*$\"\"\"", "#\"^\\s*(\\w+)\\s*$\"")
  test "general map":
    check_read("{{\"a\" : 1 2 : \"b\"}}", "{{\"a\" : 1 2 : \"b\"}}")

suite "reader — char literals":
  test "ASCII char":
    let v = read("'a'")
    check v.kind == vkChar
    check int32(v.charVal) == int32(ord('a'))
    check v.print() == "'a'"

  test "escaped chars":
    check int32(read("'\\n'").charVal) == int32(ord('\n'))
    check read("'\\n'").print() == "'\\n'"
    check int32(read("'\\\\'").charVal) == int32(ord('\\'))
    check read("'\\\\'").print() == "'\\\\'"
    check int32(read("'\\''").charVal) == int32(ord('\''))
    check read("'\\''").print() == "'\\''"

  test "UTF-8 scalar char":
    let v = read("'é'")
    check v.kind == vkChar
    check int32(v.charVal) == 0x00e9
    check v.print() == "'é'"

  test "Unicode escape char":
    check int32(read("'\\u00E9'").charVal) == 0x00e9
    check read("'\\u00E9'").print() == "'é'"
    check int32(read("'\\U0001F600'").charVal) == 0x1f600
    check read("'\\u{1F600}'").print() == "'😀'"

suite "reader — sugars":
  test "pipe folding":       check_read("(a; b; c)",    "(((a) b) c)")
  test "pipe slot form":
    check_read("(x; $parse; (or _ default))", "(or ((x) (path gene parse)) default)")
    check_read("(x; f _ y)", "(f (x) y)")
  test "pipe with message sends":
    # Sends are preserved as read; the compiler resolves them receiver-first
    # (docs/core.md §9), so the reader no longer erases `~`.
    check_read("(xs ~ filter; ~ map f; ~ take 10)",
               "(((xs ~ filter) ~ map f) ~ take 10)")
  test "message send round-trips": check_read("(x ~ f a b)", "(x ~ f a b)")
  test "flipped standalone": check_read("(~ f a b)",   "(~ f a b)")
  test "spread":             check_read("x...",         "(... x)")
  test "prop and meta flags consume no values":
    check_read("(x ^^ready false @@generated nil)",
               "(x @@generated ^^ready false nil)")
    check_read("{^^ready ^value false}", "{^^ready ^value false}")
  test "bare at can be a node head":
    check_read("(@ {^line l} (x ^name n))", "(@ {^line l} (x ^name n))")
    check_read("(x @line 7)", "(x @line 7)")
  test "string interpolation":
    check_read("$\"hello ${name}\"", "($ \"hello \" name)")
    check_read("$\"\"\"hello \"${name}\\\"\"\"\"", "($ \"hello \\\"\" name \"\\\"\")")
    check_read("($ \"hello \" name)", "($ \"hello \" name)")
  test "interpolation delimiters honor nested lexical forms":
    check_read("$\"$(do \\\"x)\\\")\"", "($ (do \"x)\"))")
    check_read("$\"$(match #\\\"[)]\\\" value)\"", "($ (match #\"[)]\" value))")
    check_read("$\"$(do # ignored )\\n x)\"", "($ (do x))")
    check_read("$\"${{^label \\\"}\\\"}}\"", "($ {^label \"}\"})")
    check_read("$\"$(do ')' x)\"", "($ (do ')' x))")
    check_read("$\"${{{\\\"key\\\" : \\\"}\\\"}}}\"", "($ {{\"key\" : \"}\"}})")
    check_read("$\"\"\"$(do \"x)\")\"\"\"", "($ (do \"x)\"))")
  test "interpolation respects max_depth":
    expect ReadError:
      discard read("$\"$((x))\"", options = ReadOptions(maxDepth: 1))

suite "reader — paths":
  test "absolute path":      check_read("/user/name",   "(select user name)")
  test "numeric selector segment": check_read("/users/0/name", "(select users 0 name)")
  test "relative path":      check_read("user/name",    "(path user name)")
  test "negative path segment": check_read("users/-1/name", "(path users -1 name)")
  test "path with unquote":  check_read("user/%field",  "(path user (unquote field))")
  test "qualified import path stays neutral":
    check_read("(import $net/http)", "(import (path gene net http))")
  test "a bare '%' path segment is rejected, not silently mis-parsed":
    # `xs/%(- i 1)` used to lex as the symbol `xs/%` plus a *separate*
    # `(- i 1)` form, quietly giving the enclosing call an extra argument.
    expect ReadError: discard read("xs/%")
    expect ReadError: discard read("(!= xs/%(- i 1) \"\\n\")")
    expect ReadError: discard read("$str/%")
    check_read("xs/%i", "(path xs (unquote i))")  # a named stage still reads
  test "send segment": check_read("xs/~size", "(path xs ~size)")
  test "send segment after an unquote stage":
    check_read("users/%i/~to_html", "(path users (unquote i) ~to_html)")

suite "reader — glued '~' is a symbol, spaced '~' is the send operator":
  # The printer has no symbol-escaping syntax, so a `~name` symbol produced by
  # path desugaring must reread as itself; otherwise printing and rereading
  # changes the form (design §2.1 send segments).
  test "glued tilde reads as one symbol":
    check_read("(a ~b)", "(a ~b)")
    check_read("(path xs ~size)", "(path xs ~size)")
  test "spaced tilde still reads as the send operator":
    check_read("(a ~ b)", "(a ~ b)")
    check_read("(~ name)", "(~ name)")
  test "tilde before a delimiter stays a bare symbol":
    check_read("(a ~)", "(a ~)")
    check_read("[~ 1]", "[~ 1]")
  test "a glued-tilde symbol survives print and reread":
    for src in ["xs/~size", "(a ~b)", "users/%i/~to_html", "(a ~ b)"]:
      let once = read(src).print()
      check read(once).print() == once

suite "reader — unquote":
  test "unquote symbol":     check_read("%name",         "(unquote name)")
  test "unquote form":       check_read("%(label self)", "(unquote (label self))")
  test "unquote path":       check_read("%self/tag",     "(unquote (path self tag))")
  test "unquote interpolated string":
    check_read("%$\"a ${x}\"", "(unquote ($ \"a \" x))")
  test "unquote interpolated string with literal dollar":
    check_read("%$\"$${self/price}\"", "(unquote ($ \"$\" (path self price)))")

suite "reader — comments":
  test "datum comment":      check_read("(a #_ b c)",            "(a c)")
  test "block comment":      check_read("#< block ># (a b)",     "(a b)")
  test "shebang":            check_read("#!/usr/bin/env gene\n(a b)", "(a b)")
  test "comment requires whitespace or bang after '#'":
    check_read("# comment\n(a b)", "(a b)")
    check_read("#\tcomment\n(a b)", "(a b)")
    check_read("(a b) #", "(a b)")       # bare trailing '#' at EOF
    check_read("(a b) #\n", "(a b)")     # bare '#' at end of line
    check_read("#!anywhere\n(a b)", "(a b)")
  test "glued datum comment discards the next form":
    check_read("(a #_b c)", "(a c)")

suite "reader — reserved '#' forms are rejected":
  test "hash-glued word is a read error, not a comment":
    expect ReadError: discard read("#a")
    expect ReadError: discard read("#A 1")
    expect ReadError: discard read("#1")
    expect ReadError: discard read("#comment without space")
  test "hash punctuation forms are reserved":
    expect ReadError: discard read("##")
    expect ReadError: discard read("#-reserved")
    expect ReadError: discard read("#=")
    expect ReadError: discard read("#'x'")
  test "reserved '#' error is located and actionable":
    try:
      discard read("(a\n  #tag)", "sample.gene")
      check false
    except ReadError as e:
      check e.line == 2
      check e.col == 3
      check "#tag" in e.msg
      check "reserved" in e.msg
  test "accepted '#' forms still read":
    check read("#[1 2]").print() == "#[1 2]"
    check read("#{^a 1}").print() == "#{^a 1}"
    check read("#(h 1)").print() == "#(h 1)"
    check read("#\"\\d+\"").print() == "#\"\\d+\""
    check read("#B64#SGk=").print() == "#B16#4869"  # bytes print canonically

suite "reader — module references":
  test "reference forms are single prefix values and print canonically":
    check_read("#Ref shared [1 2]", "#Ref shared [1 2]")
    check_read("#Deref shared", "#Deref shared")
    check_read("[#Ref shared [1 2] #Deref shared]",
               "[#Ref shared [1 2] #Deref shared]")

  test "reference names are literal simple snake_case symbols":
    for source in ["#Ref CamelCase 1", "#Ref kebab-case 1",
                   "#Ref path/name 1", "#Ref 12 1",
                   "#Deref CamelCase", "#Deref path/name"]:
      expect ReadError:
        discard read(source)

  test "reference forms require their fixed operands":
    expect ReadIncompleteError:
      discard read("#Ref shared")
    expect ReadIncompleteError:
      discard read("#Deref")

  test "longer hash words remain reserved":
    expect ReadError:
      discard read("#Reference shared 1")
    expect ReadError:
      discard read("#Dereference shared")

suite "reader — datum comments are spacing":
  test "discards next top-level form":
    check readAll("#_ (a) (b)").len == 1
    check readAll("#_ (a) (b)")[0].print() == "(b)"
  test "datum comment then EOF leaves no form":
    check readAll("#_ (a)").len == 0
  test "stacked datum comments discard two forms":
    let forms = readAll("#_ #_ a b c")
    check forms.len == 1
    check forms[0].print() == "c"
  test "datum comment mid-node is spacing":
    check_read("(a #_ b)", "(a)")
  test "datum comment before closing produces no synthetic value":
    check_read("(a b #_ c)", "(a b)")

suite "reader — vectors (flat token stream)":
  test "vector preserves tokens":
    check_read("[req : Request, ^color : \"red\"]",
               "[req : Request , ^ color : \"red\"]")

suite "readAll — multi-form programs":
  test "two forms":
    let forms = readAll("(a b) (c d)")
    check forms.len == 2
    check forms[0].print() == "(a b)"
    check forms[1].print() == "(c d)"
  test "three forms":
    let forms = readAll("1 2 3")
    check forms.len == 3
  test "empty source":
    check readAll("").len == 0
  test "with comments between forms":
    let forms = readAll("(a b) # comment\n(c d)")
    check forms.len == 2

suite "reader — malformed input is rejected":
  test "unclosed node":      expect ReadError: discard read("(a b")
  test "unclosed vector":    expect ReadError: discard read("[1 2")
  test "unclosed map":       expect ReadError: discard read("{^a 1")
  test "incomplete input uses specific read error":
    expect ReadIncompleteError: discard read("(a b")
    expect ReadIncompleteError: discard read("[1 2")
    expect ReadIncompleteError: discard read("{^a 1")
    expect ReadIncompleteError: discard read("\"unterminated")
    expect ReadIncompleteError: discard read("#_")
  test "read errors carry source location":
    try:
      discard read("(a\n", "sample.gene")
      check false
    except ReadIncompleteError as e:
      check e.sourceName == "sample.gene"
      check e.line == 2
      check e.col == 1
  test "unclosed forms carry structured opening context":
    try:
      discard read("(outer\n  [inner", "nested.gene")
      check false
    except ReadIncompleteError as e:
      check e.contextFrames.len == 2
      check e.contextFrames[0].opener == "("
      check e.contextFrames[0].expectedCloser == ")"
      check e.contextFrames[0].line == 1
      check e.contextFrames[0].col == 1
      check e.contextFrames[1].opener == "["
      check e.contextFrames[1].expectedCloser == "]"
      check e.contextFrames[1].line == 2
      check e.contextFrames[1].col == 3
      check "while reading '[' opened at nested.gene:2:3; expected ']'" in e.msg
      check "while reading '(' opened at nested.gene:1:1; expected ')'" in e.msg
  test "mismatched delimiters report the active opener":
    try:
      discard read("(outer\n  [inner)", "mismatch.gene")
      check false
    except ReadError as e:
      check e.line == 2
      check e.col == 9
      check e.contextFrames.len == 2
      check e.contextFrames[^1].opener == "["
      check "unexpected closing delimiter ')'" in e.msg
      check "opened at mismatch.gene:2:3; expected ']'" in e.msg
  test "structured context supports nesting beyond the inline fast path":
    try:
      discard read(repeat('(', 20), "deep.gene")
      check false
    except ReadIncompleteError as e:
      check e.contextFrames.len == 20
      check e.contextFrames[0].col == 1
      check e.contextFrames[^1].col == 20
  test "top-level closing delimiter has no invented opening context":
    try:
      discard readAll("(valid)\n]", "stray.gene")
      check false
    except ReadError as e:
      check e.line == 2
      check e.col == 1
      check e.contextFrames.len == 0
      check "while reading" notin e.msg
  test "unterminated block comment":
    expect ReadError: discard read("#< open")
  test "datum comment at EOF":
    expect ReadError: discard read("#_")
  test "datum comment with no datum in node":
    expect ReadError: discard read("(a #_)")
  test "unterminated string":
    expect ReadError: discard read("\"unterminated")
  test "unterminated triple-quoted string":
    expect ReadError: discard read("\"\"\"abc")
  test "unterminated regex literal":
    expect ReadError: discard read("#\"\\d+")
  test "invalid regex flag":
    expect ReadError: discard read("#\"\\d+\"q")
  test "unterminated interpolation":
    expect ReadError: discard read("$\"hello ${name\"")
  test "char literal with extra chars":
    expect ReadError: discard read("'ab'")
  test "empty char literal":
    expect ReadError: discard read("''")
  test "unterminated char literal":
    expect ReadError: discard read("'a")
  test "char literal with multiple Unicode scalars":
    expect ReadError: discard read("'é'")
  test "invalid Unicode char escape":
    expect ReadError: discard read("'\\uD800'")
    expect ReadError: discard read("'\\U00110000'")
  test "invalid string escape":
    expect ReadError: discard read("\"\\q\"")
    expect ReadError: discard read("\"\\uD800\"")
    expect ReadError: discard read("\"\\u{110000}\"")
  test "ordinary props and meta props require values":
    for source in ["(x ^name)", "(x ^name ^age 1)", "(x @doc)",
                   "(x @doc @@generated)", "{^name}", "#{^name}",
                   "{^name, ^age 1}"]:
      expect ReadError:
        discard read(source)
  test "prop maps require explicit property keys":
    expect ReadError:
      discard read("{name \"Ada\"}")
  test "missing prop values report the key location":
    try:
      discard read("(x\n  ^name)", "props.gene")
      check false
    except ReadError as e:
      check e.sourceName == "props.gene"
      check e.line == 2
      check e.col == 4
      check "requires a value" in e.msg
  test "stray closing paren":
    expect ReadError: discard read(")")
  test "stray closing bracket":
    expect ReadError: discard read("]")
  test "stray closing brace":
    expect ReadError: discard read("}")
