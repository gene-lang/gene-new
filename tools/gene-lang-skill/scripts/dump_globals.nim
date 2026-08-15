## Dump every binding reachable from the Gene global scope, qualified, with its
## value kind. Source of truth for `reference/stdlib.md` — regenerate that table
## from this output after stdlib changes rather than editing it by hand.
##
##   nim c --path:src -o:/tmp/dump_globals tools/gene-lang-skill/scripts/dump_globals.nim
##   /tmp/dump_globals
##
## Built-ins live in the *parent* of a module root, so the walk starts at
## `builtinsScope()` and follows the parent chain. Mirrors the global walk in
## `tests/spec_runner.nim`, suite "naming convention".
import gene/[types, vm]
import std/[algorithm, sequtils, sets, strutils, tables]

var names: seq[string]
var seen: HashSet[uint64]
var roots: seq[(string, Scope)]
var s = builtinsScope()
while s != nil:
  roots.add(("", s))
  s = s.parent

var stack = roots
while stack.len > 0:
  let (prefix, scope) = stack.pop()
  if scope == nil:
    continue
  scope.materializeMirroredVars()
  for name, v in scope.vars:
    let qual = if prefix.len > 0: prefix & "/" & name else: name
    names.add qual & "\t" & $v.kind
    if v.kind == vkNamespace and not seen.containsOrIncl(v.bits):
      stack.add((qual, v.nsScope))
    elif v.kind == vkProtocol and not seen.containsOrIncl(v.bits):
      for msgName, _ in v.protocolMessages:
        names.add qual & ":" & msgName & "\tprotocolMessage"

sort(names)
for n in deduplicate(names):
  echo n
