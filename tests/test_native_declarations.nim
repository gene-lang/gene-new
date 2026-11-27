## Design check 6 for every native declaration file.
##
## `src/gene/lib/**/*.doc.gene` declares natives and type messages, which have
## no source of their own. The documentation builder reads those files, and
## this test checks what it produced against the running VM:
## - each `@for` names a registered native, or a message its type or protocol
##   lists;
## - each declaration has a real `@doc`;
## - each `^errors` name is a type;
## - every positional count the declaration allows is accepted, and one more
##   is refused (a rest parameter has no upper bound);
## - each declared named parameter is one the native accepts.
##
## Natives carry no arity metadata, so a call is probed with one sample value
## per parameter, chosen from the parameter's declared type. A call refused
## for its argument count fails with the native's own count message, or with
## the message the over-long call gets. A protocol requirement reports no
## shape, so only its existence is checked.
import std/[os, strutils, tables, unittest]
import gene/[compiler, types, vm]
import tools/declaration_heads
import tools/docs/builder as docBuilder
from tools/docs/model import DocEntry, DocParam, ModuleDoc

proc nativeDeclRepoRoot(): string =
  normalizedPath(parentDir(currentSourcePath()) / "..")

let nativeDeclScratch = getTempDir() / "gene_native_decl_check"
let nativeDeclScope = newGlobalScope()

# A valid call to these has an effect a test must not have: it reads standard
# input or writes to standard output. They are checked for everything except
# calls inside their declared range.
const nativeDeclNoInRangeCall = ["gene/os/read_line", "gene/println"]

# A receiver for each type whose messages are declared.
let nativeDeclReceivers = {
  "List": "[1 2 3]",
  "Map": "{^a 1 ^b 2}",
  "Node": "`(f ^a 1 x y)",
  "Stream": "($to_stream [1 2 3])",
}.toTable

proc nativeDeclTry(source: string): tuple[ok: bool, message: string] =
  try:
    discard run(compileSource(source), nativeDeclScope)
    result = (true, "")
  except CatchableError as error:
    let lines = error.msg.splitLines()
    result = (false, if lines.len > 0: lines[0] else: "")

proc nativeDeclSample(typ: string): string =
  ## A value of the declared type. A path under a directory that does not
  ## exist keeps file and process natives from touching anything real.
  case typ
  of "Str", "Str?": "\"" & (nativeDeclScratch / "missing" / "x") & "\""
  of "Int", "Int?": "1"
  of "Bool": "true"
  of "List": "[]"
  of "(List Str)": "[\"a\"]"
  of "Map": "{}"
  of "Callable": "(fn [args...] nil)"
  else: "nil"

proc nativeDeclRequiredCount(entry: DocEntry): int =
  for param in entry.positional:
    if param.required: inc result

proc nativeDeclHasRest(entry: DocEntry): bool =
  entry.rest.name.len > 0 or entry.rest.typ.len > 0

proc nativeDeclArgs(entry: DocEntry, count: int, extraNamed = ""): string =
  for i in 0 ..< count:
    let typ = if i < entry.positional.len: entry.positional[i].typ
              elif nativeDeclHasRest(entry): entry.rest.typ
              else: ""
    result.add " " & nativeDeclSample(typ)
  for param in entry.named:
    if param.required:
      result.add " ^" & param.name & " " & nativeDeclSample(param.typ)
  result.add extraNamed

proc nativeDeclOwner(forName: string): tuple[owner, message: string] =
  ## `gene/List/push` is `List` and `push`.
  let tail = forName["gene/".len .. ^1]
  let slash = tail.rfind('/')
  (tail[0 ..< slash], tail[slash + 1 .. ^1])

proc nativeDeclCall(entry: DocEntry, count: int, extraNamed = ""): string =
  let args = nativeDeclArgs(entry, count, extraNamed)
  if entry.kind == dkMessage:
    let (owner, message) = nativeDeclOwner(entry.forName)
    "((fn [] (var receiver " & nativeDeclReceivers.getOrDefault(owner, "nil") &
      ") (receiver ." & message & args & ")))"
  else:
    "(" & entry.forName & args & ")"

proc nativeDeclCountRefusal(message: string): bool =
  ## A native's own argument-count message: `expects 1 argument, got 0`,
  ## `expects 1 or 2 arguments, got 3`, `expects no positional arguments`,
  ## `takes no arguments`. A type refusal that names an argument
  ## (`argument 1 expects a Str`) is not one.
  for marker in [" argument, got ", " arguments, got ", "no positional arguments",
                 "takes no arguments"]:
    if marker in message: return true
  false

proc nativeDeclStem(message: string): string =
  ## A count message without its count, so `got 3` and `got 4` compare equal.
  let at = message.find(", got ")
  if at >= 0: message[0 ..< at] else: message

proc nativeDeclNamedRefusal(message, name: string): bool =
  ("does not accept named arguments" in message) or
    (name in message and ("unexpected" in message or "unknown" in message))

proc nativeDeclEntries(): seq[tuple[module: ModuleDoc, entry: DocEntry]] =
  let build = docBuilder.buildPackage(nativeDeclRepoRoot(),
    nativeDeclRepoRoot() / "src/gene/lib")
  for doc in build.modules:
    if not doc.source.endsWith(".doc.gene"): continue
    for entry in doc.entries:
      if entry.forName.len > 0 and entry.kind in {dkFn, dkMessage}:
        result.add (doc, entry)

let nativeDeclBuild = docBuilder.buildPackage(nativeDeclRepoRoot(),
  nativeDeclRepoRoot() / "src/gene/lib")
let nativeDeclAll = nativeDeclEntries()

suite "native declarations":
  test "every declaration file builds without diagnostics":
    for doc in nativeDeclBuild.modules:
      for diagnostic in doc.diagnostics:
        checkpoint doc.source & ": " & diagnostic.message
      check doc.diagnostics.len == 0
    check nativeDeclAll.len > 100

  test "every @for names a registered native or a listed message":
    for (doc, entry) in nativeDeclAll:
      if entry.kind == dkMessage:
        let requirement = ':' in entry.forName
        let tail = entry.forName["gene/".len .. ^1]
        let cut = if requirement: tail.rfind(':') else: tail.rfind('/')
        let owner = "gene/" & tail[0 ..< cut]
        let message = tail[cut + 1 .. ^1]
        let probe = "($size ($filter ($runtime/messages_of_type " & owner &
          ") (fn [m] (== m/name \"" & message & "\"))))"
        let listed = run(compileSource(probe), nativeDeclScope)
        if listed.kind != vkInt or listed.intVal != 1:
          checkpoint doc.source & ": " & entry.forName & " is not a message of " & owner
          check false
      else:
        let found = nativeDeclTry(entry.forName)
        if not found.ok:
          checkpoint doc.source & ": " & entry.forName & ": " & found.message
        check found.ok

  test "every declaration has a @doc and names only types in ^errors":
    for (doc, entry) in nativeDeclAll:
      if entry.doc.strip().len == 0:
        checkpoint doc.source & ": " & entry.forName & " has no @doc"
        check false
      for name in entry.errors:
        let value = try: run(compileSource(name), nativeDeclScope)
                    except CatchableError: NIL
        if value.kind != vkType:
          checkpoint doc.source & ": " & entry.forName & " ^errors names " &
            name & ", which is not a type"
          check false

  test "every declared positional count is accepted, and one more is refused":
    createDir(nativeDeclScratch)
    for (doc, entry) in nativeDeclAll:
      if ':' in entry.forName: continue
      let label = doc.source & ": " & entry.forName
      let low = nativeDeclRequiredCount(entry)
      let high = entry.positional.len
      var over = (ok: true, message: "")
      if not nativeDeclHasRest(entry):
        # One argument too many must be refused for its count: with the
        # native's count message, or with the message two too many get. A
        # different failure means the native took the extra argument and then
        # failed on its value.
        over = nativeDeclTry(nativeDeclCall(entry, high + 1))
        let further = nativeDeclTry(nativeDeclCall(entry, high + 2))
        let countRefused = not over.ok and
          (nativeDeclCountRefusal(over.message) or
           (not further.ok and nativeDeclStem(over.message) ==
             nativeDeclStem(further.message)))
        if not countRefused:
          checkpoint label & " takes " & $(high + 1) &
            " arguments; the declaration allows at most " & $high & ": " &
            (if over.ok: "accepted" else: over.message)
        check countRefused
      if entry.forName in nativeDeclNoInRangeCall: continue
      let top = if nativeDeclHasRest(entry): high + 1 else: high
      for count in low .. top:
        let call = nativeDeclCall(entry, count)
        let outcome = nativeDeclTry(call)
        if outcome.ok: continue
        let refused = nativeDeclCountRefusal(outcome.message) or
          (not over.ok and nativeDeclStem(outcome.message) ==
            nativeDeclStem(over.message))
        if refused:
          checkpoint label & " refuses " & $count & " arguments: " & call &
            " -> " & outcome.message
        check not refused
    removeDir(nativeDeclScratch)

  test "every declared named parameter is accepted":
    createDir(nativeDeclScratch)
    for (doc, entry) in nativeDeclAll:
      for param in entry.named:
        if param.required: continue
        let extra = " ^" & param.name & " " & nativeDeclSample(param.typ)
        let call = nativeDeclCall(entry, nativeDeclRequiredCount(entry), extra)
        let outcome = nativeDeclTry(call)
        if not outcome.ok and nativeDeclNamedRefusal(outcome.message, param.name):
          checkpoint doc.source & ": " & entry.forName & " refuses ^" &
            param.name & ": " & outcome.message
          check false
    removeDir(nativeDeclScratch)
