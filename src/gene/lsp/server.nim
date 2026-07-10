## Gene language server (docs/lsp.md): JSON-RPC 2.0 over stdio.
##
## Launched by `gene lsp`. Stdout carries ONLY framed protocol messages —
## never echo/println here; diagnostics about the server itself go to stderr
## (enable with GENE_LSP_LOG=1).
##
## Shipped capabilities: full-text document sync, publishDiagnostics (reader
## parse errors), documentSymbol (outline/breadcrumbs), definition, hover,
## and workspace/symbol over an index of the workspace's .gene files.

import std/[json, os, strutils, tables, uri]
import ./analysis

type
  DocState = object
    text: string
    symbols: seq[DocSymbol]     ## last good parse (kept across parse errors)
    defs: seq[FlatDef]

  LspServer = object
    rootPath: string
    docs: Table[string, DocState]        ## uri -> open document
    index: Table[string, seq[FlatDef]]   ## uri -> definitions (all files)
    shutdownRequested: bool

const
  maxIndexedFiles = 2000
  maxIndexedFileBytes = 1_000_000
  skippedDirs = [".git", "node_modules", "nimcache", "bin", ".vscode"]

var logEnabled = false

proc log(msg: string) =
  if logEnabled:
    stderr.writeLine "[gene-lsp] " & msg
    stderr.flushFile()

# ---------------------------------------------------------------------------
# Transport: Content-Length framed JSON over stdio.
# ---------------------------------------------------------------------------

proc readMessage(): JsonNode =
  ## nil on EOF.
  var contentLength = -1
  var line: string
  while true:
    if not stdin.readLine(line):
      return nil
    line = line.strip(chars = {'\r', ' '})
    if line.len == 0:
      break
    let sep = line.find(':')
    if sep > 0 and line[0 ..< sep].strip().toLowerAscii() == "content-length":
      try:
        contentLength = parseInt(line[sep + 1 .. ^1].strip())
      except ValueError:
        return nil
  if contentLength <= 0:
    return nil
  var body = newString(contentLength)
  var got = 0
  while got < contentLength:
    let n = stdin.readBuffer(addr body[got], contentLength - got)
    if n <= 0:
      return nil
    got += n
  try:
    parseJson(body)
  except JsonParsingError:
    log "bad JSON payload: " & body[0 ..< min(body.len, 120)]
    nil

proc writeMessage(msg: JsonNode) =
  let body = $msg
  stdout.write "Content-Length: " & $body.len & "\r\n\r\n" & body
  stdout.flushFile()

proc respond(id: JsonNode, resultNode: JsonNode) =
  writeMessage(%*{"jsonrpc": "2.0", "id": id, "result": resultNode})

proc respondError(id: JsonNode, code: int, message: string) =
  writeMessage(%*{"jsonrpc": "2.0", "id": id,
                  "error": {"code": code, "message": message}})

proc notify(meth: string, params: JsonNode) =
  writeMessage(%*{"jsonrpc": "2.0", "method": meth, "params": params})

# ---------------------------------------------------------------------------
# JSON shaping
# ---------------------------------------------------------------------------

proc toJson(p: LspPos): JsonNode =
  %*{"line": p.line, "character": p.character}

proc toJson(r: LspRange): JsonNode =
  %*{"start": toJson(r.start), "end": toJson(r.endPos)}

proc toJson(s: DocSymbol): JsonNode =
  result = %*{"name": s.name, "kind": s.kind,
              "range": toJson(s.range),
              "selectionRange": toJson(s.selectionRange)}
  if s.detail.len > 0:
    result["detail"] = %s.detail
  if s.children.len > 0:
    var kids = newJArray()
    for c in s.children:
      kids.add toJson(c)
    result["children"] = kids

proc posFromJson(node: JsonNode): LspPos =
  LspPos(line: node["line"].getInt, character: node["character"].getInt)

# ---------------------------------------------------------------------------
# URI <-> path
# ---------------------------------------------------------------------------

proc uriToPath(uriText: string): string =
  if not uriText.startsWith("file://"):
    return ""
  let u = parseUri(uriText)
  decodeUrl(u.path, decodePlus = false)

proc pathToUri(path: string): string =
  var parts: seq[string]
  for part in path.split('/'):
    parts.add encodeUrl(part, usePlus = false)
  "file://" & parts.join("/")

proc canonUri(uriText: string): string =
  ## One canonical spelling per file, so the workspace index and the client's
  ## didOpen uri key the same entry regardless of percent-encoding choices.
  let path = uriToPath(uriText)
  if path.len > 0: pathToUri(path) else: uriText

# ---------------------------------------------------------------------------
# Documents and the workspace index
# ---------------------------------------------------------------------------

proc publishDiagnostics(uri: string, diags: seq[LspDiagnostic]) =
  var arr = newJArray()
  for d in diags:
    arr.add %*{"range": toJson(d.range), "severity": 1,
               "source": "gene", "message": d.message}
  notify("textDocument/publishDiagnostics", %*{"uri": uri, "diagnostics": arr})

proc analyzeDocument(server: var LspServer, uri, text: string) =
  let path = uriToPath(uri)
  let a = analyze(text, if path.len > 0: path else: uri)
  var st = server.docs.getOrDefault(uri)
  st.text = text
  if a.parsed:
    st.symbols = a.symbols
    st.defs = flattenDefs(a.symbols, text)
    server.index[canonUri(uri)] = st.defs
  server.docs[uri] = st
  publishDiagnostics(uri, a.diagnostics)

proc indexFile(server: var LspServer, path: string) =
  try:
    if getFileSize(path) > maxIndexedFileBytes:
      return
    let text = readFile(path)
    let a = analyze(text, path)
    if a.parsed:
      server.index[pathToUri(path)] = flattenDefs(a.symbols, text)
  except CatchableError:
    discard

proc indexWorkspace(server: var LspServer) =
  if server.rootPath.len == 0 or not dirExists(server.rootPath):
    return
  var count = 0
  for path in walkDirRec(server.rootPath, relative = false):
    if count >= maxIndexedFiles:
      log "workspace index capped at " & $maxIndexedFiles & " files"
      break
    if not path.endsWith(".gene"):
      continue
    var skip = false
    for dir in skippedDirs:
      if ("/" & dir & "/") in path:
        skip = true
        break
    if skip:
      continue
    server.indexFile(path)
    inc count
  log "indexed " & $server.index.len & " files under " & server.rootPath

# ---------------------------------------------------------------------------
# Request handlers
# ---------------------------------------------------------------------------

proc handleInitialize(server: var LspServer, id, params: JsonNode) =
  if params.hasKey("rootUri") and params["rootUri"].kind == JString:
    server.rootPath = uriToPath(params["rootUri"].getStr)
  elif params.hasKey("rootPath") and params["rootPath"].kind == JString:
    server.rootPath = params["rootPath"].getStr
  respond(id, %*{
    "capabilities": {
      "textDocumentSync": {"openClose": true, "change": 1},
      "documentSymbolProvider": true,
      "definitionProvider": true,
      "hoverProvider": true,
      "workspaceSymbolProvider": true
    },
    "serverInfo": {"name": "gene-lsp"}
  })

proc handleDocumentSymbol(server: LspServer, id, params: JsonNode) =
  let uri = params["textDocument"]["uri"].getStr
  var arr = newJArray()
  if server.docs.hasKey(uri):
    for s in server.docs[uri].symbols:
      arr.add toJson(s)
  respond(id, arr)

proc lookupWord(server: LspServer, params: JsonNode): string =
  let uri = params["textDocument"]["uri"].getStr
  if not server.docs.hasKey(uri):
    return ""
  let text = server.docs[uri].text
  wordAt(text, lineStarts(text), posFromJson(params["position"]))

proc findDefs(server: LspServer, name: string,
              preferUri = ""): seq[(string, FlatDef)] =
  if name.len == 0:
    return
  if preferUri.len > 0 and server.index.hasKey(preferUri):
    for d in server.index[preferUri]:
      if d.name == name:
        result.add (preferUri, d)
  for uri, defs in server.index:
    if uri == preferUri:
      continue
    for d in defs:
      if d.name == name:
        result.add (uri, d)

proc handleDefinition(server: LspServer, id, params: JsonNode) =
  let uri = params["textDocument"]["uri"].getStr
  let word = server.lookupWord(params)
  var arr = newJArray()
  for (defUri, d) in server.findDefs(word, preferUri = canonUri(uri)):
    arr.add %*{"uri": defUri, "range": toJson(d.selectionRange)}
  respond(id, arr)

proc handleHover(server: LspServer, id, params: JsonNode) =
  let uri = params["textDocument"]["uri"].getStr
  let word = server.lookupWord(params)
  let hits = server.findDefs(word, preferUri = canonUri(uri))
  if hits.len == 0:
    respond(id, newJNull())
    return
  let (defUri, d) = hits[0]
  let path = uriToPath(defUri)
  let location = (if path.len > 0: extractFilename(path) else: defUri) &
                 ":" & $(d.selectionRange.start.line + 1)
  respond(id, %*{
    "contents": {
      "kind": "markdown",
      "value": "```gene\n" & d.signature & "\n```\n_defined in " & location &
               "_"
    }
  })

proc handleWorkspaceSymbol(server: LspServer, id, params: JsonNode) =
  let query = params{"query"}.getStr("").toLowerAscii()
  var arr = newJArray()
  var count = 0
  for uri, defs in server.index:
    for d in defs:
      if query.len > 0 and not d.name.toLowerAscii().contains(query):
        continue
      arr.add %*{
        "name": d.name,
        "kind": d.kind,
        "containerName": d.containerName,
        "location": {"uri": uri, "range": toJson(d.selectionRange)}
      }
      inc count
      if count >= 500:
        respond(id, arr)
        return
  respond(id, arr)

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

proc runLspServer*(): int =
  logEnabled = getEnv("GENE_LSP_LOG", "") in ["1", "true", "yes", "on"]
  log "starting"
  var server = LspServer(docs: initTable[string, DocState](),
                         index: initTable[string, seq[FlatDef]]())
  while true:
    let msg = readMessage()
    if msg == nil:
      log "eof"
      return 0
    let meth = msg{"method"}.getStr("")
    let id = msg{"id"}
    let params = if msg.hasKey("params"): msg["params"] else: newJObject()
    let isRequest = id != nil and not (id.kind == JNull)
    try:
      case meth
      of "initialize":
        server.handleInitialize(id, params)
      of "initialized":
        server.indexWorkspace()
      of "textDocument/didOpen":
        let doc = params["textDocument"]
        server.analyzeDocument(doc["uri"].getStr, doc["text"].getStr)
      of "textDocument/didChange":
        let uri = params["textDocument"]["uri"].getStr
        let changes = params["contentChanges"]
        if changes.len > 0:
          # Full sync (change: 1): the last change carries the whole text.
          server.analyzeDocument(uri, changes[changes.len - 1]["text"].getStr)
      of "textDocument/didClose":
        # The unsaved buffer's definitions must not outlive the buffer:
        # re-index from disk (or drop the entry when the file is gone) and
        # clear the document's diagnostics from the client.
        let uri = params["textDocument"]["uri"].getStr
        server.docs.del(uri)
        let path = uriToPath(uri)
        server.index.del(canonUri(uri))
        if path.len > 0 and fileExists(path):
          server.indexFile(path)
        publishDiagnostics(uri, @[])
      of "textDocument/didSave":
        discard
      of "workspace/didChangeWatchedFiles":
        # Keep the index current for files edited outside open buffers
        # (created/changed/deleted on disk). Open documents win: their
        # buffer text already drives the index via didChange.
        for change in params{"changes"}:
          let uri = change["uri"].getStr
          if server.docs.hasKey(uri):
            continue
          let path = uriToPath(uri)
          server.index.del(canonUri(uri))
          if change{"type"}.getInt(2) in [1, 2] and path.len > 0 and
              fileExists(path):
            server.indexFile(path)
      of "textDocument/documentSymbol":
        server.handleDocumentSymbol(id, params)
      of "textDocument/definition":
        server.handleDefinition(id, params)
      of "textDocument/hover":
        server.handleHover(id, params)
      of "workspace/symbol":
        server.handleWorkspaceSymbol(id, params)
      of "shutdown":
        server.shutdownRequested = true
        respond(id, newJNull())
      of "exit":
        return (if server.shutdownRequested: 0 else: 1)
      else:
        if isRequest:
          respondError(id, -32601, "method not found: " & meth)
        # Unknown notifications ($/setTrace, ...) are ignored.
    except CatchableError as e:
      log "handler error for " & meth & ": " & e.msg
      if isRequest:
        respondError(id, -32603, "internal error: " & e.msg)
