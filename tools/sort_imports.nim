## Sort the selectors inside Gene import forms.
##
## Canonical order is capitalised selectors first, then the rest, alphabetically
## within each group, so `(import A B a b)` rather than a mixed list. Grouped
## selectors (`a/[B c]`) sort recursively.
##
## Only imports whose selectors are actually out of order are rewritten, so the
## tool does not reflow unrelated imports. A rewritten import is rendered with
## the formatter's canonical import layout. Quoted imports and imports with
## interior comments are left alone: sorting a quoted import would change data,
## and re-rendering would drop its comments.
##
## Usage:
##   sort_imports [--check] <file-or-directory>...
##
## `--check` reports every import that needs sorting and exits 1 without
## writing. With no `--check`, changed files are rewritten in place.

import std/[algorithm, os, osproc, strutils]
import gene/[clause_syntax, reader, types]
import tools/[fmt, source_index]

type Edit = object
  start, stop: int
  line: int
  text: string

proc lineOf(source: string, offset: int): int =
  result = 1
  for i in 0 ..< min(offset, source.len):
    if source[i] == '\n':
      inc result

proc columnAt(source: string, offset: int): int =
  var start = offset
  while start > 0 and source[start - 1] != '\n':
    dec start
  offset - start

proc containsComment(doc: SourceDocument, syntax: SyntaxRef): bool =
  if syntax.kind == skComment:
    return true
  for row in doc.children(syntax):
    if containsComment(doc, row.syntax):
      return true

proc collect(doc: SourceDocument, source, path: string, syntax: SyntaxRef,
             edits: var seq[Edit], skipped: var seq[string]) =
  if syntax.kind in {skComment, skQuasiquote}:
    return
  if syntax.kind == skNode:
    let rows = doc.children(syntax)
    var head = ""
    if rows.len > 0 and rows[0].label == "head":
      head = source[rows[0].syntax.span.startByte ..< rows[0].syntax.span.endByte]
    if head in ["quote", "quasiquote"]:
      return
    if head == "import":
      let start = syntax.span.startByte
      let stop = syntax.span.endByte
      let line = lineOf(source, start)
      if containsComment(doc, syntax):
        skipped.add path & ":" & $line & ": import has an interior comment"
        return
      let text = source[start ..< stop]
      var unit: SourceUnit
      try:
        unit = readAllWithLocs(text, path)
      except CatchableError as error:
        skipped.add path & ":" & $line & ": " & error.msg
        return
      if unit.forms.len != 1:
        skipped.add path & ":" & $line & ": expected one import form"
        return
      let value = unit.forms[0]
      if value.kind != vkNode or not value.head.isSymbolNamed("import"):
        return
      let indent = columnAt(source, start)
      let plain = formatForm(value, indent)
      let ordered = formatImportForm(value, indent)
      if plain != ordered:
        edits.add Edit(start: start, stop: stop, line: line, text: ordered)
      return
  for row in doc.children(syntax):
    collect(doc, source, path, row.syntax, edits, skipped)

proc process(path: string, check: bool, changed: var int, editsNeeded: var int,
             skipped: var seq[string]) =
  let source = readFile(path)
  let doc = indexSource(source, path)
  var edits: seq[Edit]
  for syntax in doc.topLevel:
    collect(doc, source, path, syntax, edits, skipped)
  if edits.len == 0:
    return
  editsNeeded += edits.len
  if check:
    for edit in edits:
      echo path & ":" & $edit.line & ": import selectors are not sorted"
    return
  edits.sort(proc(a, b: Edit): int = cmp(b.start, a.start))
  var text = source
  for edit in edits:
    text = text[0 ..< edit.start] & edit.text & text[edit.stop .. ^1]
  writeFile(path, text)
  inc changed

proc addWalked(path: string, files: var seq[string]) =
  for kind, child in walkDir(path):
    case kind
    of pcDir:
      if splitFile(child).name notin [".claude", ".git", "archive",
                                     "build", "generated", "node_modules", "tmp"]:
        addWalked(child, files)
    of pcFile:
      if child.endsWith(".gene"):
        files.add child
    else: discard

proc addFiles(path: string, files: var seq[string], missing: var seq[string],
             skipped: var seq[string]) =
  if dirExists(path):
    ## Prefer Git's view of a directory so generated and ignored sources are not
    ## rewritten; fall back to a recursive walk outside a repository.
    let listing = execCmdEx("git ls-files -z -- " & quoteShell(path))
    if listing.exitCode == 0:
      for entry in listing.output.split('\0'):
        if entry.endsWith(".gene"):
          files.add entry
    else:
      addWalked(path, files)
  elif fileExists(path):
    if path.endsWith(".gene"):
      files.add path
    else:
      skipped.add path & ": not a Gene source"
  else:
    missing.add path

when isMainModule:
  var check = false
  var paths: seq[string]
  for arg in commandLineParams():
    if arg == "--check":
      check = true
    elif arg in ["-h", "--help"]:
      echo "usage: sort_imports [--check] <file-or-directory>..."
      quit 0
    else:
      paths.add arg
  if paths.len == 0:
    echo "usage: sort_imports [--check] <file-or-directory>..."
    quit 2

  var files, missing, skipped: seq[string]
  for path in paths:
    addFiles(path, files, missing, skipped)
  for path in missing:
    echo "not found: ", path
  files.sort()
  var unique: seq[string]
  for file in files:
    if unique.len == 0 or unique[^1] != file:
      unique.add file
  files = unique
  var changed = 0
  var editsNeeded = 0
  for file in files:
    process(file, check, changed, editsNeeded, skipped)
  for message in skipped:
    echo "skipped: ", message
  if check:
    if editsNeeded > 0:
      quit 1
  else:
    echo "sorted ", editsNeeded, " import(s) in ", changed, " file(s)"
