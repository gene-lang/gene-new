## Diagnostic for docs/proposals/scope-pool-reset-investigation.md.
## Prints observations rather than asserting a known, unfixed defect.
## Run from the repository root with --path:src and a writable GENE_USER_PACKAGES.
import gene/[compiler, types, vm]
import std/tables

var observations: seq[tuple[address: pointer,
  generation, parentGeneration: uint64, refsMatch: bool]]

proc inspectScope(args: openArray[Value], call: ptr NativeCall): Value {.nimcall.} =
  let scope {.cursor.} = call[].dispatchScope
  # Observe without retaining: retaining the scope would change its lifetime.
  observations.add (cast[pointer](scope), scope.sandboxGenerationId,
    scope.parent.sandboxGenerationId, scope.moduleRefs == scope.parent.moduleRefs)
  NIL

proc probe(source: string) =
  let chunk = compileSource(source)
  doAssert chunk.functions[0].poolCallScope
  echo "simple=", chunk.functions[0].simpleCall,
    " pooled=", chunk.functions[0].poolCallScope,
    " mutates parameter=", chunk.functions[0].positionalParamsMaySet
  observations.setLen(0)
  for generation in [101'u64, 202'u64]:
    let root = newGlobalScope()
    root.sandboxGenerationId = generation
    root.moduleRefs = ModuleRefTable(entries: initTable[string, ModuleRefEntry]())
    root.define("inspect_scope", newNativeCallFn("inspect_scope", inspectScope))
    discard run(chunk, root)
  for observation in observations:
    echo "address=", cast[uint](observation.address),
      " generation=", observation.generation,
      " parent=", observation.parentGeneration,
      " refsMatch=", observation.refsMatch

probe("(fn inspect [x] (inspect_scope) x) (inspect 1)")
probe("(fn inspect [x] (set x (+ x 1)) (inspect_scope) x) (inspect 1)")
