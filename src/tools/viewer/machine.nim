## Bounded machine-readable analysis of one buffer, for browser editors.
##
## The full-screen viewer owns a terminal. A browser cannot, so the same
## reader-backed index is exposed here as one JSON request over stdin or a
## text file. `analyze` answers with the ordered declaration outline, the
## structure tree, the diagnostics, and the children of the form enclosing the
## caret; `format` answers with the existing formatter's output.
##
## Every range is emitted twice: half-open UTF-8 byte offsets (the contract for
## tooling) and the equivalent UTF-16 code-unit offsets, which is what a
## browser textarea's `selectionStart` speaks. Both are computed against the
## exact text in this request and the line endings it contains, so a caller
## never has to re-derive a column from a different copy of the buffer.
##
## Responses are bounded by row, child, depth, and input-size limits. A partial
## buffer still gets an outline and a tree; only a lexical failure (an
## unterminated string or comment) reports `ok: false`, which is the signal an
## editor uses to keep its last good view visible as stale.

import std/[json, os, strutils, unicode]
import ../../gene/reader
import ../declaration_kinds
import ../fmt
import ../source_index
import ../source_outline
import ../source_positions

const
  machineProtocol* = 1
  machineDefaultMaxBytes* = 2 * 1024 * 1024
  machineDefaultRowLimit* = 400
  machineDefaultChildLimit* = 80
  machineDefaultDepthLimit* = 12

type
  MachineMode* = enum
    mmAnalyze, mmFormat

  MachineOptions* = object
    mode*: MachineMode
    name*: string
    version*: int
    textFile*: string
    hasSelection*: bool
    selectStart*, selectEnd*: int    ## UTF-8 bytes, half-open.
    selectUtf16*, selectUtf16Start*, selectUtf16End*: int
    maxBytes*, rowLimit*, childLimit*, depthLimit*: int

  Utf16Table* = object
    lineStarts: seq[int]
    utf16Starts: seq[int]

  RowBudget = object
    used*: int
    ids*: int
    truncated*: bool
    rowLimit*, childLimit*, depthLimit*: int

proc resolveSelection*(text: string, options: var MachineOptions)

proc modeName(mode: MachineMode): string =
  case mode
  of mmAnalyze: "analyze"
  of mmFormat: "format"

# ---------------------------------------------------------------------------
# Offsets: UTF-8 bytes and UTF-16 code units against this exact text.
# ---------------------------------------------------------------------------

proc utf16Units(src: string, start, size: int): int =
  if size <= 1:
    return 1
  var codepoint = 0
  case size
  of 2:
    codepoint = (ord(src[start]) and 0x1F) shl 6 or
      (ord(src[start + 1]) and 0x3F)
  of 3:
    codepoint = (ord(src[start]) and 0x0F) shl 12 or
      (ord(src[start + 1]) and 0x3F) shl 6 or (ord(src[start + 2]) and 0x3F)
  of 4:
    codepoint = (ord(src[start]) and 0x07) shl 18 or
      (ord(src[start + 1]) and 0x3F) shl 12 or
      (ord(src[start + 2]) and 0x3F) shl 6 or (ord(src[start + 3]) and 0x3F)
  else:
    return 1
  if codepoint > 0xFFFF: 2 else: 1

proc runeSize(src: string, start: int): int =
  if start >= src.len or ord(src[start]) < 0x80:
    return 1
  result = 1
  while start + result < src.len and
      (ord(src[start + result]) and 0xC0) == 0x80:
    inc result

proc buildUtf16Table*(src: string): Utf16Table =
  ## Absolute UTF-16 offset of every line start. Walking runes is what makes a
  ## supplementary code point count as two units, exactly as JavaScript and
  ## LSP count them.
  result.lineStarts = @[0]
  result.utf16Starts = @[0]
  var units = 0
  var i = 0
  while i < src.len:
    let size = runeSize(src, i)
    if src[i] == '\n':
      inc units
      result.lineStarts.add i + 1
      result.utf16Starts.add units
    else:
      units += utf16Units(src, i, size)
    i += size

proc lineText(src: string, lineStarts: seq[int], line0: int): string =
  if line0 < 0 or line0 >= lineStarts.len:
    return ""
  let first = lineStarts[line0]
  let last = if line0 + 1 < lineStarts.len: lineStarts[line0 + 1] else: src.len
  src[first ..< last]

proc utf16At*(src: string, table: Utf16Table, offset: int): int =
  ## UTF-16 code-unit offset of a UTF-8 byte offset in the same text.
  let bounded = min(max(offset, 0), src.len)
  var line0 = 0
  for i in countdown(table.lineStarts.high, 0):
    if table.lineStarts[i] <= bounded:
      line0 = i
      break
  let column = bounded - table.lineStarts[line0]
  table.utf16Starts[line0] +
    byteColToUtf16(lineText(src, table.lineStarts, line0), column)

proc byteAt*(src: string, table: Utf16Table, offset: int): int =
  ## UTF-8 byte offset of a UTF-16 code-unit offset in the same text.
  let bounded = max(offset, 0)
  var line0 = 0
  for i in countdown(table.utf16Starts.high, 0):
    if table.utf16Starts[i] <= bounded:
      line0 = i
      break
  let column = bounded - table.utf16Starts[line0]
  table.lineStarts[line0] +
    utf16ColToByte(lineText(src, table.lineStarts, line0), column)

proc addSpan(target: JsonNode, src: string, table: Utf16Table,
             span: ByteSpan): JsonNode =
  target["startByte"] = %span.startByte
  target["endByte"] = %span.endByte
  target["startUtf16"] = %utf16At(src, table, span.startByte)
  target["endUtf16"] = %utf16At(src, table, span.endByte)
  target

proc syntaxKindName(kind: SyntaxKind): string =
  case kind
  of skAtom: "atom"
  of skNode: "node"
  of skList: "list"
  of skPropMap: "prop_map"
  of skGeneralMap: "map"
  of skQuasiquote: "quasiquote"
  of skUnquote: "unquote"
  of skInterpolation: "interpolation"
  of skComment: "comment"
  of skSequence: "sequence"
  of skError: "error"

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

proc diagnosticJson(src: string, table: Utf16Table, starts: seq[int],
                    message: string, line, col: int): JsonNode =
  var start = byteOffset(starts, line, col)
  start = min(max(start, 0), src.len)
  let finish = min(start + 1, src.len)
  result = newJObject()
  result["message"] = %message
  result["line"] = %line
  result["col"] = %col
  discard addSpan(result, src, table,
                  ByteSpan(startByte: start, endByte: finish))

proc hasDiagnostic(diagnostics: JsonNode, line, col: int): bool =
  for item in diagnostics:
    if item["line"].getInt == line and item["col"].getInt == col:
      return true

# ---------------------------------------------------------------------------
# Tree rows
# ---------------------------------------------------------------------------

proc joinPath(parent: seq[SourcePathSegment],
              row: seq[SourcePathSegment]): seq[SourcePathSegment] =
  result = parent
  for segment in row:
    result.add segment

proc rowJson(doc: SourceDocument, table: Utf16Table, row: SourceRow,
             fullPath: seq[SourcePathSegment], depth: int,
             budget: var RowBudget): JsonNode =
  result = newJObject()
  result["id"] = %budget.ids
  inc budget.ids
  result["label"] = %row.label
  result["summary"] = %row.summary
  let shownPath = pathText(fullPath)
  result["path"] = %shownPath
  result["kind"] = %syntaxKindName(row.syntax.kind)
  discard addSpan(result, doc.source, table, row.syntax.span)
  result["closed"] = %row.syntax.closed
  result["immutable"] = %row.syntax.immutable
  result["more"] = %0
  result["truncated"] = %false
  result["children"] = newJArray()

  if not isContainer(row.syntax) or depth >= budget.depthLimit:
    return
  let total = doc.childCount(row.syntax)
  if total == 0:
    return
  let remaining = budget.rowLimit - budget.used
  if remaining <= 0:
    budget.truncated = true
    result["more"] = %total
    result["truncated"] = %true
    return
  let take = min(min(total, budget.childLimit), remaining)
  for child in doc.childPage(row.syntax, 0, take):
    budget.used += 1
    result["children"].add(rowJson(doc, table, child, joinPath(fullPath,
      child.path), depth + 1, budget))
  if take < total:
    budget.truncated = true
    result["more"] = %(total - take)
    result["truncated"] = %true

proc containerJson(doc: SourceDocument, table: Utf16Table,
                   syntax: SyntaxRef, label, path: string,
                   budget: var RowBudget): JsonNode =
  result = newJObject()
  result["label"] = %label
  result["path"] = %path
  result["kind"] = %syntaxKindName(syntax.kind)
  discard addSpan(result, doc.source, table, syntax.span)
  result["closed"] = %syntax.closed
  result["more"] = %0
  result["truncated"] = %false
  result["children"] = newJArray()
  let total = doc.childCount(syntax)
  if total == 0:
    return
  let remaining = budget.rowLimit - budget.used
  if remaining <= 0:
    budget.truncated = true
    result["more"] = %total
    result["truncated"] = %true
    return
  let take = min(min(total, budget.childLimit), remaining)
  for child in doc.childPage(syntax, 0, take):
    budget.used += 1
    result["children"].add(rowJson(doc, table, child, child.path, 1, budget))
  if take < total:
    budget.truncated = true
    result["more"] = %(total - take)
    result["truncated"] = %true

# ---------------------------------------------------------------------------
# Selection: the innermost enclosing container.
# ---------------------------------------------------------------------------

proc contains(span: ByteSpan, startByte, endByte: int): bool =
  startByte >= span.startByte and startByte <= span.endByte and
    endByte >= startByte and endByte <= span.endByte

type Enclosing = object
  found: bool
  syntax: SyntaxRef
  path: seq[SourcePathSegment]

proc innermost(doc: SourceDocument, syntax: SyntaxRef,
               startByte, endByte: int, depth: int, visited: var int,
               path: seq[SourcePathSegment]): Enclosing =
  ## Depth-first search for the deepest container holding the selection. The
  ## bounds keep one caret move from turning a pathological buffer into an
  ## unbounded walk.
  ##
  ## A single-form buffer's root is the form itself, so it has to be a
  ## candidate before its children are searched; only the synthetic sequence
  ## root is never selectable.
  if depth > 64 or visited > 4000:
    return
  inc visited
  var best: Enclosing
  if syntax.kind != skSequence and contains(syntax.span, startByte, endByte):
    best = Enclosing(found: true, syntax: syntax, path: path)
  for child in doc.children(syntax):
    if not isContainer(child.syntax):
      continue
    if not contains(child.syntax.span, startByte, endByte):
      continue
    let childPath = joinPath(path, child.path)
    let deeper = doc.innermost(child.syntax, startByte, endByte, depth + 1,
                               visited, childPath)
    if deeper.found:
      return deeper
    return best
  best

proc selectionJson(doc: SourceDocument, table: Utf16Table, options: MachineOptions,
                   budget: var RowBudget): JsonNode =
  result = newJObject()
  result["found"] = %false
  let startByte = min(max(options.selectStart, 0), doc.source.len)
  let endByte = min(max(options.selectEnd, startByte), doc.source.len)
  var visited = 0
  let match = doc.innermost(doc.root, startByte, endByte, 0, visited, @[])
  if not match.found:
    return
  result["found"] = %true
  result["kind"] = %syntaxKindName(match.syntax.kind)
  result["path"] = %pathText(match.path)
  discard addSpan(result, doc.source, table, match.syntax.span)
  result["more"] = %0
  result["children"] = newJArray()
  let total = doc.childCount(match.syntax)
  let take = min(min(total, budget.childLimit), max(budget.rowLimit, 0))
  for child in doc.childPage(match.syntax, 0, take):
    budget.used += 1
    result["children"].add(rowJson(doc, table, child, child.path, 1, budget))
  if take < total:
    result["more"] = %(total - take)
    budget.truncated = true

# ---------------------------------------------------------------------------
# Analyze / format
# ---------------------------------------------------------------------------

proc baseResponse(options: MachineOptions): JsonNode =
  result = newJObject()
  result["protocol"] = %machineProtocol
  result["mode"] = %modeName(options.mode)
  result["name"] = %options.name
  result["version"] = %options.version

proc analyzeResponse*(text: string, options: MachineOptions): JsonNode =
  result = baseResponse(options)
  let table = buildUtf16Table(text)
  var options = options
  resolveSelection(text, options)
  result["ok"] = %true
  result["parsed"] = %false
  result["partial"] = %true
  result["outline"] = newJArray()
  result["diagnostics"] = newJArray()
  result["selected"] = newJObject()
  result["selected"]["found"] = %false

  var lexError = ""
  var lexLine = 0
  var lexCol = 0
  try:
    discard lexAllSpanned(text, includeEof = false, sourceName = options.name,
                          includeTrivia = true)
  except ReadError as error:
    lexError = error.msg
    lexLine = error.line
    lexCol = error.col

  if lexError.len > 0:
    # The index cannot be built, so there is no usable outline for this text.
    # That is the stale-view signal, not a partial result.
    result["ok"] = %false
    result["partial"] = %false
    result["diagnostics"].add(
      diagnosticJson(text, table, lineStarts(text), lexError, lexLine, lexCol))
    return

  let doc = indexSource(text, options.name)
  let diagnostics = result["diagnostics"]
  var parsed = false
  var parseError = ""
  var parseLine = 0
  var parseCol = 0
  try:
    discard readAllWithLocs(text, options.name)
    parsed = true
  except ReadError as error:
    parseError = error.msg
    parseLine = error.line
    parseCol = error.col
  if not parsed and parseError.len > 0:
    diagnostics.add(diagnosticJson(text, table, doc.lineStarts, parseError,
                                   parseLine, parseCol))
  for diagnostic in doc.diagnostics:
    if hasDiagnostic(diagnostics, diagnostic.line, diagnostic.col):
      continue
    diagnostics.add(diagnosticJson(text, table, doc.lineStarts,
                                   diagnostic.message, diagnostic.line,
                                   diagnostic.col))

  result["parsed"] = %parsed
  result["partial"] = %(not parsed or doc.diagnostics.len > 0)

  for row in doc.outline:
    var item = newJObject()
    item["name"] = %row.name
    item["head"] = %row.head
    item["kind"] = %row.kind
    item["kindName"] = %declarationKindName(row.kind)
    item["detail"] = %row.detail
    item["closed"] = %row.closed
    discard addSpan(item, text, table, row.span)
    item["nameStartByte"] = %row.nameSpan.startByte
    item["nameEndByte"] = %row.nameSpan.endByte
    item["nameStartUtf16"] = %utf16At(text, table, row.nameSpan.startByte)
    item["nameEndUtf16"] = %utf16At(text, table, row.nameSpan.endByte)
    result["outline"].add(item)

  var budget = RowBudget(rowLimit: options.rowLimit,
                         childLimit: options.childLimit,
                         depthLimit: options.depthLimit)
  result["tree"] = containerJson(doc, table, doc.root, "root", "/", budget)
  var selectedBudget = RowBudget(rowLimit: options.rowLimit,
                                 childLimit: options.childLimit,
                                 depthLimit: options.depthLimit)
  if options.hasSelection:
    result["selected"] = selectionJson(doc, table, options, selectedBudget)
  result["limits"] = newJObject()
  result["limits"]["rows"] = %options.rowLimit
  result["limits"]["children"] = %options.childLimit
  result["limits"]["depth"] = %options.depthLimit
  result["limits"]["truncated"] = %(budget.truncated or
                                    selectedBudget.truncated)

proc formatResponse*(text: string, options: MachineOptions): JsonNode =
  result = baseResponse(options)
  result["diagnostics"] = newJArray()
  try:
    let formatted = formatSource(text, options.name)
    result["ok"] = %true
    result["text"] = %formatted
    result["changed"] = %(formatted != text)
  except ReadError as error:
    result["ok"] = %false
    let table = buildUtf16Table(text)
    result["diagnostics"].add(diagnosticJson(text, table, lineStarts(text),
                                              error.msg, error.line, error.col))

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

const machineUsage* = """Usage: gene-viewer --machine analyze [options]
       gene-viewer --machine format [options]

Reads Gene source from stdin unless --text-file names one, and writes one JSON
object to stdout. Options:
  --name NAME              diagnostic source name (default "<draft>")
  --version N              caller version echoed in the response
  --text-file PATH         read the buffer from PATH ("-" means stdin)
  --select-start N         UTF-8 byte offset of the selection start
  --select-end N           UTF-8 byte offset of the selection end
  --select-utf16 N         caret position as a UTF-16 code-unit offset
  --select-utf16-start N   selection start as a UTF-16 code-unit offset
  --select-utf16-end N     selection end as a UTF-16 code-unit offset
  --row-limit N            total tree rows (default 400)
  --child-limit N          rows per container (default 80)
  --depth-limit N          maximum expanded depth (default 12)
  --max-bytes N            input size cap (default 2 MiB)
"""

proc parseIntOption(name, value: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, name & " expects an integer")

proc parseMachineCli*(args: openArray[string]): MachineOptions =
  result = MachineOptions(mode: mmAnalyze, name: "<draft>", version: 0,
                          selectUtf16: -1, selectUtf16Start: -1,
                          selectUtf16End: -1, rowLimit: machineDefaultRowLimit,
                          childLimit: machineDefaultChildLimit,
                          depthLimit: machineDefaultDepthLimit,
                          maxBytes: machineDefaultMaxBytes)
  var i = 0
  if i >= args.len:
    raise newException(ValueError,
      "--machine expects a mode: analyze or format")
  case args[i]
  of "analyze": result.mode = mmAnalyze
  of "format": result.mode = mmFormat
  else:
    raise newException(ValueError, "unknown machine mode: " & args[i])
  inc i
  while i < args.len:
    let arg = args[i]
    if arg in ["--help", "-h"]:
      raise newException(ValueError, machineUsage)
    var name = arg
    var value = ""
    if arg.contains('='):
      let at = arg.find('=')
      name = arg[0 ..< at]
      value = arg[at + 1 .. ^1]
    elif i + 1 < args.len:
      value = args[i + 1]
      inc i
    case name
    of "--name":
      result.name = value
    of "--version":
      result.version = parseIntOption(name, value)
    of "--text-file":
      if value.len == 0:
        raise newException(ValueError, "--text-file expects a path")
      result.textFile = value
    of "--select-start":
      result.selectStart = parseIntOption(name, value)
      result.hasSelection = true
    of "--select-end":
      result.selectEnd = parseIntOption(name, value)
      result.hasSelection = true
    of "--select-utf16":
      result.selectUtf16 = parseIntOption(name, value)
      result.hasSelection = true
    of "--select-utf16-start":
      result.selectUtf16Start = parseIntOption(name, value)
      result.hasSelection = true
    of "--select-utf16-end":
      result.selectUtf16End = parseIntOption(name, value)
      result.hasSelection = true
    of "--row-limit":
      result.rowLimit = max(parseIntOption(name, value), 0)
    of "--child-limit":
      result.childLimit = max(parseIntOption(name, value), 0)
    of "--depth-limit":
      result.depthLimit = max(parseIntOption(name, value), 0)
    of "--max-bytes":
      result.maxBytes = max(parseIntOption(name, value), 1)
    else:
      raise newException(ValueError, "unknown --machine option: " & arg)
    inc i

proc readInput(options: MachineOptions): string =
  if options.textFile.len > 0 and options.textFile != "-":
    if not fileExists(options.textFile):
      raise newException(ValueError, "text file not found: " & options.textFile)
    result = readFile(options.textFile)
  else:
    result = stdin.readAll()
  if result.len > options.maxBytes:
    raise newException(ValueError, "input exceeds " & $options.maxBytes &
      " bytes")

proc resolveSelection*(text: string, options: var MachineOptions) =
  if options.selectUtf16Start >= 0:
    let table = buildUtf16Table(text)
    options.selectStart = byteAt(text, table, options.selectUtf16Start)
    options.selectEnd = if options.selectUtf16End >= 0:
      byteAt(text, table, options.selectUtf16End) else: options.selectStart
    options.hasSelection = true
  elif options.selectUtf16 >= 0:
    let table = buildUtf16Table(text)
    let at = byteAt(text, table, options.selectUtf16)
    options.selectStart = at
    options.selectEnd = at
    options.hasSelection = true
  if options.selectEnd < options.selectStart:
    options.selectEnd = options.selectStart

proc runMachine*(args: openArray[string]): int =
  for arg in args:
    if arg in ["--help", "-h"]:
      stdout.writeLine(machineUsage)
      return 0
  var options: MachineOptions
  try:
    options = parseMachineCli(args)
  except ValueError as error:
    stderr.writeLine("Error: " & error.msg)
    return 2
  var text: string
  try:
    text = readInput(options)
  except ValueError as error:
    stderr.writeLine("Error: " & error.msg)
    return 2
  except IOError as error:
    stderr.writeLine("Error: " & error.msg)
    return 2
  if validateUtf8(text) >= 0:
    let response = baseResponse(options)
    response["ok"] = %false
    response["invalid_utf8"] = %true
    stdout.writeLine($response)
    return 0
  let response = case options.mode
    of mmAnalyze: analyzeResponse(text, options)
    of mmFormat: formatResponse(text, options)
  stdout.writeLine($response)
  0
