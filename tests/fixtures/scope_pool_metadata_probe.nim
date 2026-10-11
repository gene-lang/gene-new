## Diagnostic for docs/proposals/scope-pool-reset-investigation.md.
## Reports observations and asserts that both pool acquisition paths reset metadata.
## Run from the repository root with --path:src and a writable GENE_USER_PACKAGES.
import gene/[compiler, types, vm]
import std/tables

var observations: seq[tuple[address: pointer,
  generation, parentGeneration: uint64, refsMatch, simple: bool]]

proc inspectScope(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope {.cursor.} = call[].dispatchScope
  # Observe without retaining: retaining the scope would change its lifetime.
  observations.add (cast[pointer](scope), scope.sandboxGenerationId,
    scope.parent.sandboxGenerationId, scope.moduleRefs == scope.parent.moduleRefs,
    scope.simpleCallScope)
  NIL

proc probe(source: string, simple: bool) =
  let chunk = compileSource(source)
  doAssert chunk.functions[0].poolCallScope
  doAssert chunk.functions[0].simpleCall == simple
  echo "simple=", simple, " pooled=", chunk.functions[0].poolCallScope
  observations.setLen(0)
  for generation in [101'u64, 202'u64, 0'u64]:
    let root = newGlobalScope()
    root.sandboxGenerationId = generation
    if generation != 0:
      root.moduleRefs = ModuleRefTable(entries: initTable[string, ModuleRefEntry]())
    else:
      root.moduleRefs = nil
    root.define("inspect_scope", newNativeCallFn("inspect_scope", inspectScope))
    discard run(chunk, root)
  for observation in observations:
    echo "address=", cast[uint](observation.address),
      " generation=", observation.generation,
      " parent=", observation.parentGeneration,
      " refsMatch=", observation.refsMatch
    doAssert observation.address == observations[0].address
    doAssert observation.generation == observation.parentGeneration
    doAssert observation.refsMatch
    doAssert observation.simple == simple

probe("(fn inspect [x] (inspect_scope) x) (inspect 1)", simple = true)
probe("(fn inspect [x : Int] (inspect_scope) x) (inspect 1)", simple = false)
