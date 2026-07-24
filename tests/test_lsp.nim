## Tests for the Gene language server (docs/lsp.md):
## unit tests over gene/lsp/analysis plus one JSON-RPC stdio e2e against the
## built CLI (`gene lsp`). Included by test_all.nim after test_cli, so the
## e2e reuses its buildGeneCli/geneExe helpers.

import std/[json, os, osproc, streams, strutils, unittest]
import gene/lsp/analysis

const lspSample = """
(mod sample @doc "demo")

(var greeting "hello")

(fn greet [name : Str] : Str
  $"${greeting}, ${name}")

(type Task
  ^props {^id Int ^title Str}
  (message label [self] self/title)
  (ctor [id : Int]
    (self ~ set_prop! `id id)))

(enum Color red green (rgb Int))

(protocol ToText
  (message to-text [self : Self] : Str))

(impl ToText for Task
  (message to-text [self] (greet self/title)))

(ns util
  (fn helper [x] x))
"""

proc findSym(syms: seq[DocSymbol], name: string): DocSymbol =
  for s in syms:
    if s.name == name:
      return s
  checkpoint "symbol not found: " & name
  check false

suite "lsp — analysis":
  test "document symbols cover declaration forms with nesting":
    let a = analyze(lspSample)
    check a.parsed
    check a.diagnostics.len == 0
    var names: seq[string]
    for s in a.symbols:
      names.add s.name
    check names == @["sample", "greeting", "greet", "Task", "Color",
                     "ToText", "impl ToText for Task", "util"]
    let task = findSym(a.symbols, "Task")
    check task.kind == skClass
    check task.children.len == 2
    check task.children[0].name == "label"
    check task.children[0].kind == skMethod
    check task.children[1].name == "ctor"
    check task.children[1].kind == skConstructor
    let color = findSym(a.symbols, "Color")
    check color.kind == skEnum
    var variants: seq[string]
    for v in color.children:
      variants.add v.name
    check variants == @["red", "green", "rgb"]
    let impl = findSym(a.symbols, "impl ToText for Task")
    check impl.children.len == 1
    check impl.children[0].name == "to-text"
    let util = findSym(a.symbols, "util")
    check util.kind == skNamespace
    check util.children.len == 1
    check util.children[0].name == "helper"

  test "selection range points at the declared name":
    let a = analyze(lspSample)
    let greet = findSym(a.symbols, "greet")
    # `(fn greet ...` on line index 4: name starts after "(fn ".
    check greet.selectionRange.start.line == 4
    check greet.selectionRange.start.character == 4
    check greet.range.start.line == 4
    check greet.range.endPos.line >= 5

  test "parse errors become positioned diagnostics":
    let a = analyze("(var ok 1)\n(fn broken [x\n")
    check not a.parsed
    check a.diagnostics.len == 1
    check "unclosed" in a.diagnostics[0].message
    check "opened at <lsp>:2:12; expected ']'" in a.diagnostics[0].message
    check a.diagnostics[0].range.start.line >= 1

  test "mismatched delimiter diagnostics identify the nested opener":
    let a = analyze("(fn broken [x\n  (work x])")
    check not a.parsed
    check a.diagnostics.len == 1
    check "unexpected closing delimiter ']'" in a.diagnostics[0].message
    check "while reading '(' opened at <lsp>:2:3; expected ')'" in
      a.diagnostics[0].message
    check a.diagnostics[0].range.start.line == 1

  test "utf16 conversion handles multi-byte runes":
    let line = "(var π 3)"   # pi is 2 bytes in utf-8, 1 utf-16 unit
    let piByteCol = line.find("π")
    check byteColToUtf16(line, piByteCol) == 5
    check utf16ColToByte(line, 5) == piByteCol
    # After pi: byte col jumps 2, utf16 col jumps 1.
    check byteColToUtf16(line, piByteCol + 2) == 6

  test "matchingCloseOffset ignores parens in strings and comments":
    let src = "(fn f [] # comment with ) paren\n  \"str with ) too\" 1)\n(var x 2)"
    let closing = matchingCloseOffset(src, 0)
    check src[closing - 1] == ')'
    check src[closing ..< src.len].strip().startsWith("(var")

  test "wordAt extracts symbols, path segments, and strips sigils":
    let src = "(greet self/title ^prop)"
    let starts = lineStarts(src)
    check wordAt(src, starts, LspPos(line: 0, character: 2)) == "greet"
    check wordAt(src, starts, LspPos(line: 0, character: 8)) == "self"
    check wordAt(src, starts, LspPos(line: 0, character: 14)) == "title"
    check wordAt(src, starts, LspPos(line: 0, character: 20)) == "prop"

  test "wordAt resolves every segment of a three-part slash path":
    # Review finding: slicing with stale offsets was an out-of-bounds Defect
    # on the middle segment of a/b/c — a server-killing crash.
    let src = "(x alpha/beta/gamma)"
    let starts = lineStarts(src)
    check wordAt(src, starts, LspPos(line: 0, character: 4)) == "alpha"
    check wordAt(src, starts, LspPos(line: 0, character: 10)) == "beta"
    check wordAt(src, starts, LspPos(line: 0, character: 15)) == "gamma"
    check wordAt(src, starts, LspPos(line: 0, character: 18)) == "gamma"
    # Cursor exactly on a slash (offset 8) yields the preceding segment.
    check wordAt(src, starts, LspPos(line: 0, character: 8)) == "alpha"

  test "bytes literals do not read as comments in the raw scanner":
    # 0#base64's # must not start a line comment; otherwise the closing
    # paren is swallowed and the form's range leaks into the next form.
    let src = "(var blob 0#SGVsbG8=)\n(var after 1)"
    let a = analyze(src)
    check a.parsed
    check a.symbols.len == 2
    check a.symbols[0].name == "blob"
    check a.symbols[0].range.endPos.line == 0
    check a.symbols[1].name == "after"
    let closing = matchingCloseOffset(src, 0)
    check src[closing - 1] == ')'
    check closing < src.find("(var after")

  test "triple regex and interpolation atoms preserve raw form ranges":
    let src = "(var pattern #\"\"\"[)#]+\"\"\"im)\n" &
              "(var text $\"\"\"value ${name} ) #\"\"\")\n" &
              "(var after 1)"
    let a = analyze(src)
    check a.parsed
    check a.symbols.len == 3
    check a.symbols[0].range.endPos.line == 0
    check a.symbols[1].range.endPos.line == 1
    check a.symbols[2].name == "after"

  test "char literals with delimiters do not break form ranges":
    let src = "(var close ')')\n(var open '(')\n(var after 2)"
    let a = analyze(src)
    check a.parsed
    check a.symbols.len == 3
    check a.symbols[0].range.endPos.line == 0
    check a.symbols[1].range.endPos.line == 1

  test "datum comments are spacing when locating declared names":
    # (fn #_ old actual [x] x): the parser declares `actual`; the name
    # selection must also skip the #_ marker AND its datum.
    let src = "(fn #_ old actual [x] x)"
    let a = analyze(src)
    check a.parsed
    check a.symbols.len == 1
    check a.symbols[0].name == "actual"
    check a.symbols[0].selectionRange.start.character == src.find("actual")
    # Stacked datum comments discard stacked datums.
    let src2 = "(fn #_ #_ a b real [x] x)"
    let a2 = analyze(src2)
    check a2.symbols.len == 1
    check a2.symbols[0].name == "real"
    check a2.symbols[0].selectionRange.start.character == src2.find("real")
    # A prefixed datum (`old) is ONE datum: the quasiquote prefix must not
    # be discarded alone, leaving `old` selected as the name.
    let src3 = "(fn #_ `old actual [x] x)"
    let a3 = analyze(src3)
    check a3.symbols.len == 1
    check a3.symbols[0].name == "actual"
    check a3.symbols[0].selectionRange.start.character == src3.find("actual")
    # Prefixed bracketed datum: #_ `(a b) discards the whole form.
    let src4 = "(fn #_ `(a b) real2 [x] x)"
    let a4 = analyze(src4)
    check a4.symbols.len == 1
    check a4.symbols[0].name == "real2"
    check a4.symbols[0].selectionRange.start.character == src4.find("real2")

  test "flattenDefs carries container names and signatures":
    let a = analyze(lspSample)
    let defs = flattenDefs(a.symbols, lspSample)
    var labelDef: FlatDef
    for d in defs:
      if d.name == "label":
        labelDef = d
    check labelDef.containerName == "Task"
    check "(message label" in labelDef.signature

suite "lsp — stdio e2e":
  test "gene lsp answers initialize, diagnostics, symbols, and definition":
    buildGeneCli()
    let dir = getTempDir() / "gene_lsp_e2e"
    createDir(dir)
    let samplePath = dir / "sample.gene"
    writeFile(samplePath, lspSample)
    let uri = "file://" & samplePath

    let p = startProcess(geneExe, args = ["lsp"], options = {poUsePath})
    defer:
      if p.running:
        p.terminate()
      p.close()
    let stdinS = p.inputStream
    let stdoutS = p.outputStream

    proc send(msg: JsonNode) =
      let body = $msg
      stdinS.write "Content-Length: " & $body.len & "\r\n\r\n" & body
      stdinS.flush()

    proc recv(): JsonNode =
      var contentLength = -1
      var line: string
      while stdoutS.readLine(line):
        line = line.strip(chars = {'\r', ' '})
        if line.len == 0:
          break
        if line.toLowerAscii().startsWith("content-length:"):
          contentLength = parseInt(line.split(':')[1].strip())
      if contentLength <= 0:
        return nil
      parseJson(stdoutS.readStr(contentLength))

    send(%*{"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"rootUri": "file://" & dir}})
    let init = recv()
    check init["result"]["capabilities"]["documentSymbolProvider"].getBool
    check init["result"]["capabilities"]["definitionProvider"].getBool
    send(%*{"jsonrpc": "2.0", "method": "initialized", "params": {}})

    # Open a broken document: expect one positioned diagnostic.
    send(%*{"jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {"uri": uri, "languageId": "gene",
                                        "version": 1,
                                        "text": "(fn broken [x"}}})
    let diag1 = recv()
    check diag1["method"].getStr == "textDocument/publishDiagnostics"
    check diag1["params"]["diagnostics"].len == 1

    # Full-sync change to the good text: diagnostics clear.
    send(%*{"jsonrpc": "2.0", "method": "textDocument/didChange",
            "params": {"textDocument": {"uri": uri, "version": 2},
                       "contentChanges": [{"text": lspSample}]}})
    let diag2 = recv()
    check diag2["params"]["diagnostics"].len == 0

    send(%*{"jsonrpc": "2.0", "id": 2, "method": "textDocument/documentSymbol",
            "params": {"textDocument": {"uri": uri}}})
    let syms = recv()["result"]
    var names: seq[string]
    for s in syms:
      names.add s["name"].getStr
    check "greet" in names
    check "Task" in names

    # Definition of `greet` at its call site inside the impl body.
    var defLine = -1
    var defChar = -1
    let lines = lspSample.split('\n')
    for i, l in lines:
      let idx = l.find("(greet self/title)")
      if idx >= 0:
        defLine = i
        defChar = idx + 3
        break
    check defLine >= 0
    send(%*{"jsonrpc": "2.0", "id": 3, "method": "textDocument/definition",
            "params": {"textDocument": {"uri": uri},
                       "position": {"line": defLine, "character": defChar}}})
    let defs = recv()["result"]
    check defs.len == 1
    check defs[0]["range"]["start"]["line"].getInt == 4

    send(%*{"jsonrpc": "2.0", "id": 4, "method": "textDocument/hover",
            "params": {"textDocument": {"uri": uri},
                       "position": {"line": defLine, "character": defChar}}})
    let hover = recv()["result"]
    check "(fn greet" in hover["contents"]["value"].getStr

    # Watched-file events keep the index current for closed files.
    let extraPath = dir / "extra.gene"
    writeFile(extraPath, "(fn watched-helper [x] x)\n")
    let extraUri = "file://" & extraPath
    send(%*{"jsonrpc": "2.0", "method": "workspace/didChangeWatchedFiles",
            "params": {"changes": [{"uri": extraUri, "type": 1}]}})
    send(%*{"jsonrpc": "2.0", "id": 5, "method": "workspace/symbol",
            "params": {"query": "watched-helper"}})
    check recv()["result"].len == 1
    removeFile(extraPath)
    send(%*{"jsonrpc": "2.0", "method": "workspace/didChangeWatchedFiles",
            "params": {"changes": [{"uri": extraUri, "type": 3}]}})
    send(%*{"jsonrpc": "2.0", "id": 6, "method": "workspace/symbol",
            "params": {"query": "watched-helper"}})
    check recv()["result"].len == 0

    # didClose clears diagnostics and re-indexes from disk, so unsaved
    # buffer definitions do not outlive the buffer.
    send(%*{"jsonrpc": "2.0", "method": "textDocument/didChange",
            "params": {"textDocument": {"uri": uri, "version": 3},
                       "contentChanges": [{"text": "(fn only-in-buffer [] 1)"}]}})
    discard recv()   # diagnostics for the buffer text
    send(%*{"jsonrpc": "2.0", "method": "textDocument/didClose",
            "params": {"textDocument": {"uri": uri}}})
    let closeDiag = recv()
    check closeDiag["method"].getStr == "textDocument/publishDiagnostics"
    check closeDiag["params"]["diagnostics"].len == 0
    send(%*{"jsonrpc": "2.0", "id": 7, "method": "workspace/symbol",
            "params": {"query": "only-in-buffer"}})
    check recv()["result"].len == 0
    send(%*{"jsonrpc": "2.0", "id": 8, "method": "workspace/symbol",
            "params": {"query": "greet"}})
    # The on-disk sample still indexes (greet + greeting).
    check recv()["result"].len == 2

    send(%*{"jsonrpc": "2.0", "id": 9, "method": "shutdown", "params": {}})
    discard recv()
    send(%*{"jsonrpc": "2.0", "method": "exit"})
    check p.waitForExit() == 0
