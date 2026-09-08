import std/[strutils, tables, unittest]
import gene/[reader, printer, compiler, types, vm]
import tools/fmt

proc wrapCanonical(source: string): string =
  for form in readAll(source):
    if result.len > 0: result.add "\n"
    result.add form.print()

proc wrapEval(source: string): string =
  run(compileSource(source), newGlobalScope()).print()

suite "reader — #@ wrapping prefix":
  test "two complete forms become an ordinary node":
    for pair in [
      ("#@$println x", "($println x)"),
      ("#@ (x) y", "((x) y)"),
      ("#@f x y", "(f x) y"),
      ("#@f #@g x", "(f (g x))"),
      ("#@ #@f g x", "((f g) x)"),
      ("#@\n f,\n (+ 1 2)\n next", "(f (+ 1 2)) next"),
      ("#@ obj .get", "(obj .get)")
    ]:
      checkpoint pair[0]
      check wrapCanonical(pair[0]) == wrapCanonical(pair[1])

  test "expression positions have the same boundary and path parsing":
    for pair in [
      ("[1 #@f a/b 3]", "[1 (f a/b) 3]"),
      ("#[#@f x y]", "#[(f x) y]"),
      ("(#@factory config item)", "((factory config) item)"),
      ("{^value #@f x ^other y}", "{^value (f x) ^other y}"),
      ("{{#@f x : #@g y}}", "{{(f x) : (g y)}}"),
      ("(record @tag #@f x ^value #@g y #@h z tail)",
       "(record @tag (f x) ^value (g y) (h z) tail)"),
      ("(fn f [x = #@g y] x)", "(fn f [x = (g y)] x)"),
      ("(#@f x -> g)", "((f x) -> g)"),
      ("(source -> f #@g x)", "(source -> f (g x))")
    ]:
      checkpoint pair[0]
      check wrapCanonical(pair[0]) == wrapCanonical(pair[1])

  test "quotes templates interpolation and datum comments compose":
    for pair in [
      ("(quote #@f x)", "(quote (f x))"),
      ("`#@f %x", "`(f %x)"),
      ("`(value %#@f x)", "`(value %(f x))"),
      ("$\"value=${#@f x}\"", "$\"value=${(f x)}\""),
      ("#_ #@f x y", "y"),
      ("#@ #_ ignored f #_ discarded x y", "(f x) y"),
      ("#@f #_ #_ a b x", "(f x)"),
      ("#@f # comment\n x", "(f x)"),
      ("#@f #< comment ># x", "(f x)")
    ]:
      checkpoint pair[0]
      check wrapCanonical(pair[0]) == wrapCanonical(pair[1])
    check read("\"#@ f x\"").strVal == "#@ f x"
    check readAll("# @f x\n7").len == 1

  test "missing operands and enclosing delimiters are reader errors":
    for source in ["#@", "#@ f", "#@ f #_ x", "(#@ f"]:
      expect ReadIncompleteError: discard readAll(source)
    for source in ["(#@ f)", "[#@ f]", "{^value #@ f}",
                   "#@ f ^name 1", "#@ f @name 1", "#@ f -> g",
                   "#@ f ; g", "#@ f : x"]:
      expect ReadError: discard readAll(source)
    expect ReadError:
      discard readAll("#@f #@g #@h x", options = ReadOptions(maxDepth: 1))

  test "source provenance stays outside the runtime node":
    let unit = readAllWithLocs("[0\n  #@ f (g x)]", "wrapper.gene")
    let wrapped = unit.forms[0].listItems[1]
    check wrapped.kind == vkNode
    check wrapped.props.len == 0
    check wrapped.meta.len == 0
    check unit.locs[wrapped.bits].line == 2
    check unit.locs[wrapped.bits].col == 3
    check unit.locs[wrapped.body[0].bits].col == 8
    check unit.wraps.hasKey(wrapped.bits)
    check "#@" notin wrapped.print()

suite "execution — #@ is an ordinary call":
  test "computed head and argument execute once in ordinary order":
    check wrapEval("""
      (var order [])
      (fn choose []
        (order .push "head")
        (fn [x] (order .push "body") (+ x 1)))
      (fn argument [] (order .push "argument") 40)
      [#@ (choose) (argument) order]
    """) == "[41 [\"head\" \"argument\" \"body\"]]"

  test "results type checks special forms and defaults are unchanged":
    check wrapEval("""
      (fn twice [x : Int] : Int (* x 2))
      (fn identity [x] x)
      (fn defaulted [x : Int = #@twice 3] x)
      [(+ 1 #@twice 20) (defaulted)
       (try #@twice "bad" catch TypeError "rejected")
       #@identity nil #@identity void
       #@quote (unbound syntax)]
    """) == "[41 6 \"rejected\" nil void (unbound syntax)]"
    check wrapEval("(fn quote_it! [x] x) #@quote_it! (+ 1 2)") == "(+ 1 2)"

suite "formatting — preserve authored #@":
  test "formatting preserves spelling while normalizing spacing and layout":
    check formatSource("#@$println    x") == "#@ $println x\n"
    check formatSource("(fn f [x] #@tap (+ x 1))") ==
      "(fn f [x]\n  #@ tap (+ x 1))\n"
    check formatSource("#@f x y") == "#@ f x y\n"

  test "all expression positions round-trip and format idempotently":
    let longString = "\"" & repeat("long ", 30) & "\""
    for source in [
      "#@ (x) y", "#@f #@g x", "#@ #@f g x", "(#@factory config item)",
      "[1 #@f a/b 3]", "{^value #@f x ^tail y}",
      "{{#@f x : #@g y}}", "(record @tag #@f x)",
      "`(value %#@f x)", "$\"value=${#@f x}\"",
      "#@ obj .get", "(#@f x -> g)", "(source -> f #@g x)",
      "#@f # comment\n x\nnext", "#@ #_ skipped f x\nnext",
      "#_ #@discarded x\n#@f y\nnext", "#@f #Ref item [1 2]\nnext",
      "#@f " & longString, "#@f (g " & longString & ")",
      "(let x #@f \"line one\nline two\")"
    ]:
      checkpoint source
      let formatted = formatSource(source)
      check "#@" in formatted
      check wrapCanonical(formatted) == wrapCanonical(source)
      check formatSource(formatted) == formatted
