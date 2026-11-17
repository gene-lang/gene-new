## The runtime's message-only failures are a reviewed list.
##
## A `raise newException(GeneError, "...")` in the runtime reaches a Gene
## handler as a RuntimeError value carrying only its message. Every such site
## has been reviewed: it reports a defect (a mistake in the calling program or
## in the runtime), not a failure a correct program can meet. Failures a correct
## program can meet use a built-in Error type instead (`raiseBuiltinError`,
## `raiseOsError`, ...). The compiler's diagnostics are listed too; at runtime
## they reach a loader through `eval` or a module import, which report them as
## `CompileError`.
##
## This test keeps the list exact. A new message-only raise fails it until the
## raise is either given an Error type or added to
## tests/fixtures/message_only_raises.txt after deciding it is a defect. A
## removed raise fails it until its line is removed. Set
## GENE_UPDATE_RAISE_LIST=1 to rewrite the list from the sources.
import std/[algorithm, os, strutils, tables, unittest]

const listPath = "tests/fixtures/message_only_raises.txt"
const marker = "raise newException(GeneError,"

proc runtimeSources(): seq[string] =
  for pattern in ["src/*.nim", "src/gene/*.nim", "src/gene/ext/*.nim",
                  "src/gene/ext/term/*.nim"]:
    for path in walkFiles(pattern):
      result.add path.replace('\\', '/')
  result.sort()

proc messageKey(text: string, start: int): string =
  ## The raise's first string literal, or the start of its message expression.
  var i = start
  while i < text.len and text[i] in Whitespace: inc i
  if i < text.len and text[i] == '"':
    inc i
    while i < text.len and text[i] != '"':
      if text[i] == '\\' and i + 1 < text.len:
        result.add text[i]
        inc i
      result.add text[i]
      inc i
  else:
    var j = i
    while j < text.len and text[j] notin {'\n', '\r'}: inc j
    result = "<expr " & text[i ..< j].strip()[0 ..< min(60, j - i)].strip() & ">"

proc currentRaises(): seq[string] =
  for path in runtimeSources():
    let text = readFile(path)
    var at = text.find(marker)
    while at >= 0:
      result.add path & "\t" & messageKey(text, at + marker.len)
      at = text.find(marker, at + marker.len)
  result.sort()

proc listedRaises(): seq[string] =
  for line in readFile(listPath).splitLines():
    if line.len == 0 or line.startsWith("#"): continue
    result.add line
  result.sort()

proc writeList(raises: seq[string]) =
  var counts = initOrderedTable[string, int]()
  for entry in raises:
    let file = entry.split('\t', 1)[0]
    counts.mgetOrPut(file, 0) += 1
  var text = "# Reviewed message-only runtime failures: tests/test_message_only_raises.nim.\n" &
    "# Each line is file<TAB>message. Every entry is a defect, not a failure a\n" &
    "# correct program can meet; compiler entries surface as CompileError.\n#\n"
  for file, count in counts: text.add "# " & $count & "\t" & file & "\n"
  text.add "#\n"
  for entry in raises: text.add entry & "\n"
  writeFile(listPath, text)

suite "message-only runtime failures":
  test "every message-only raise is on the reviewed list":
    let current = currentRaises()
    if getEnv("GENE_UPDATE_RAISE_LIST") == "1":
      writeList(current)
    let listed = listedRaises()
    var remaining = initCountTable[string]()
    for entry in listed: remaining.inc entry
    var unlisted: seq[string]
    for entry in current:
      if remaining[entry] > 0: remaining.inc(entry, -1)
      else: unlisted.add entry
    var stale: seq[string]
    for entry, count in remaining:
      for _ in 0 ..< count: stale.add entry
    if unlisted.len > 0:
      checkpoint "message-only raises not on the reviewed list; give each an " &
        "Error type or list it as a defect:\n  " & unlisted.join("\n  ")
    if stale.len > 0:
      checkpoint "listed raises no longer in the sources; remove them:\n  " &
        stale.join("\n  ")
    check unlisted.len == 0
    check stale.len == 0
