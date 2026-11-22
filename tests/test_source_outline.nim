## Outline parity between the structural index and the language server.
##
## The browser editor shows an outline before a buffer parses, so it cannot use
## the LSP analyzer. It derives declarations from indexed tokens instead — and
## these tests are what keep that second implementation honest: for every
## fixture the strict reader accepts, the ordered names, kinds, and exact byte
## spans must be the ones `tools/lsp/analysis` reports.

import std/[os, strutils, unittest]
import tools/[source_index, source_outline, source_positions]
import tools/lsp/analysis

const fixtureSource = """
(mod sample @doc "demo")

(var greeting "hello")

(fn greet [name : Str] : Str
  $"${greeting}, ${name}")

(fn ^^generator naturals [] 1)

(macro unless [condition body] `(if %condition nil else %body))

(type Task
  ^props {^id Int}
  (message label [self] "task")
  (ctor [id : Int] (self .put `id id)))

(enum Color red green (rgb Int))

(protocol ToText
  (message to-text [] : Str))

(impl ToText for Task
  (message to-text [self] "task"))

(message standalone [self] self)

(ctor [id] id)

(ns util
  (fn helper [x] x))

(mod other)

(log "not a declaration")
(+ 1 2)
(server ^host "127.0.0.1")
"""

const wrapSource = """
#@ ns stats
#@fn wrapped [x] x
(fn #_ `old actual [x] x)
(ns util
  #@type Person
  #@protocol
    Named)
"""

proc offsets(src: string, lsp: LspRange): tuple[startByte, endByte: int] =
  let starts = lineStarts(src)
  (startByte: lspPosToOffset(src, starts, lsp.start),
   endByte: lspPosToOffset(src, starts, lsp.endPos))

proc checkParity(src: string, label: string) =
  let doc = indexSource(src)
  let analysis = analyze(src)
  check analysis.parsed
  let rows = doc.outline
  check rows.len == analysis.symbols.len
  for i in 0 ..< min(rows.len, analysis.symbols.len):
    let expected = analysis.symbols[i]
    let actual = rows[i]
    check actual.name == expected.name
    check actual.kind == expected.kind
    let form = offsets(src, expected.range)
    check actual.span.startByte == form.startByte
    check actual.span.endByte == form.endByte
    let nameRange = offsets(src, expected.selectionRange)
    check actual.nameSpan.startByte == nameRange.startByte
    check actual.nameSpan.endByte == nameRange.endByte
    if actual.name != expected.name or actual.kind != expected.kind or
        actual.span.startByte != form.startByte:
      checkpoint label & " declaration " & $i & ": outline " & actual.name &
        " kind " & $actual.kind & " @ " & $actual.span.startByte &
        ", lsp " & expected.name & " kind " & $expected.kind & " @ " &
        $form.startByte

suite "source outline — LSP declaration parity":
  test "every supported declaration kind matches the language server":
    checkParity(fixtureSource, "fixture")

  test "wrapping prefixes, properties, and nested declarations match":
    checkParity(wrapSource, "wrapped")

  test "a non-declaration buffer has no outline rows":
    for src in ["(+ 1 2)", "[a b c]", "{^a 1}", "(log \"x\")", "# comment\n",
                "(server ^host \"127.0.0.1\" ^port 8080)"]:
      check indexSource(src).outline.len == 0
      check analyze(src).symbols.len == 0

  test "outline names use the raw token spelling":
    let doc = indexSource("(fn π/δ [x] x)\n(var a-b \"c\")")
    let rows = doc.outline
    check rows.len == 2
    check rows[0].name == "π/δ"
    check rows[1].name == "a-b"

  test "unclosed declarations keep their indexed name and span":
    let src = "(fn first [x]\n  (fn second [y] y)"
    let doc = indexSource(src)
    check doc.diagnostics.len == 1
    let rows = doc.outline
    check rows.len == 1
    check rows[0].name == "first"
    check not rows[0].closed
    check src[rows[0].nameSpan.startByte ..< rows[0].nameSpan.endByte] ==
      "first"

  test "macro, generator, and constructor details":
    let doc = indexSource(
      "(macro m [x] x)\n(fn ^^generator g [] 1)\n(ctor [x] x)")
    let rows = doc.outline
    check rows.len == 3
    check rows[0].detail == "macro"
    check rows[1].detail == "generator"
    check rows[2].name == "ctor"
    check rows[2].kind == skConstructor

suite "source outline — repository fixtures":
  test "the editor demo fixtures agree with the language server":
    let fixtures = parentDir(currentSourcePath()) / ".." /
      "examples/gene-harness/examples/gene-editor/fixtures"
    if dirExists(fixtures):
      var checked = 0
      for kind, path in walkDir(fixtures):
        if kind != pcFile or not path.endsWith(".gene"):
          continue
        if path.endsWith("mixed_endings.gene"):
          continue
        let src = readFile(path)
        let analysis = analyze(src)
        if not analysis.parsed:
          continue
        inc checked
        checkParity(src, path)
      check checked >= 3
