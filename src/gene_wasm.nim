## WebAssembly host ABI v0 for the Gene VM (docs/workflows.md §A.4).
##
## Text-only, synchronous: source string in; status + rendered result + captured
## print/println output out. No raw `Value` crosses the boundary — results are
## referenced through opaque i32 handles into a guest-side registry that roots
## the strings until `gene_result_free`. Build with the `wasm` nimble task.

import gene/[compiler, printer, types, vm]
import std/tables

type
  GeneResult = ref object
    status: cint          # 0 ok | 1 gene-error | 2 panic | 3 parse/compile error
    text: string          # rendered result value, or the error message
    output: string        # captured print/println output

var results: Table[cint, GeneResult]
var nextResultHandle: cint = 0 # never recycle an identity; stale handles stay stale

proc geneEvalSource(src: string): GeneResult =
  # Install the host log writer on first eval, not at module-init (see
  # ensureGeneWasmLogWriter). The logging registry itself initializes lazily
  # via ensureRegistry and carries the documented default limits; do NOT
  # installLoggingConfig here, since replacing a registry closes the previous
  # one's sinks and rebinds runtime loggers through globals that are not
  # safely reachable from the first eval under Emscripten.
  ensureGeneWasmLogWriter()
  new(result)
  let capture = new(string)
  geneWasmCapture = capture
  defer: geneWasmCapture = nil
  var chunk =
    try:
      compileSource(src)
    except CatchableError as e:
      result.status = 3
      result.text = e.msg
      result.output = capture[]
      return
  # Constructing the scope builds the Application on first eval. It has to be
  # inside a handler: an escaping failure here would leave `gene_eval` with no
  # handle to return, so the host would see a bare 0 ("rejected input") and no
  # message at all for what is really a host-environment error.
  let scope =
    try:
      newGlobalScope()
    except CatchableError as e:
      result.status = 1
      result.text = e.msg
      result.output = capture[]
      return
  # A host input is an isolated eval unit, not a loaded application module.
  # Registering its providers in the application's base indexes would pin
  # every completed root despite no Value ever crossing the host boundary.
  scope.implOverlayRoot = true
  scope.moduleRoot = false
  scope.moduleStatic = false
  defer:
    # Constants/closed annotations in executable code are outside owners in
    # trial deletion. The host has rendered everything before relinquishing it.
    chunk = nil
    retireWasmEvaluationScope(scope)
  try:
    let value = run(chunk, scope)
    result.status = 0
    result.text = value.print()
  except GenePanic as e:
    result.status = 2
    result.text = e.msg
  except GeneError as e:
    result.status = 1
    result.text = errorDiagnosticMessage(e, scope)
  except CatchableError as e:
    result.status = 1
    result.text = e.msg
  result.output = capture[]

# --- exported ABI ----------------------------------------------------------

proc geneAlloc(len: cint): pointer {.exportc: "gene_alloc".} =
  ## A guest buffer the host fills with UTF-8 source bytes. Host frees via
  ## gene_free after gene_eval has copied the bytes.
  if len <= 0: return nil
  result = alloc(len)

proc geneFree(p: pointer) {.exportc: "gene_free".} =
  if p != nil: dealloc(p)

proc geneEval(srcPtr: pointer, srcLen: cint): cint {.exportc: "gene_eval".} =
  ## Evaluate one source unit; returns a result handle (>=1), 0 on bad input.
  if srcLen < 0 or (srcLen > 0 and srcPtr == nil): return 0
  var src = newString(srcLen)
  if srcLen > 0: copyMem(addr src[0], srcPtr, srcLen)
  if nextResultHandle == high(cint): return 0
  let evaluated = geneEvalSource(src)
  inc nextResultHandle
  results[nextResultHandle] = evaluated
  nextResultHandle

proc resultAt(handle: cint): GeneResult =
  results.getOrDefault(handle)

proc geneResultStatus(handle: cint): cint {.exportc: "gene_result_status".} =
  let r = resultAt(handle)
  if r == nil: -1 else: r.status

proc geneResultTextPtr(handle: cint): pointer {.exportc: "gene_result_text_ptr".} =
  let r = resultAt(handle)
  if r == nil or r.text.len == 0: nil else: addr r.text[0]

proc geneResultTextLen(handle: cint): cint {.exportc: "gene_result_text_len".} =
  let r = resultAt(handle)
  if r == nil: 0 else: cint(r.text.len)

proc geneResultOutPtr(handle: cint): pointer {.exportc: "gene_result_out_ptr".} =
  let r = resultAt(handle)
  if r == nil or r.output.len == 0: nil else: addr r.output[0]

proc geneResultOutLen(handle: cint): cint {.exportc: "gene_result_out_len".} =
  let r = resultAt(handle)
  if r == nil: 0 else: cint(r.output.len)

proc geneResultFree(handle: cint) {.exportc: "gene_result_free".} =
  ## Release the result and its strings. Identity is monotonic while registry
  ## storage follows only live handles, so long-running hosts stay bounded.
  results.del(handle)

when defined(geneRcStats):
  proc geneTestHeapBytes(): cint {.exportc: "gene_test_heap_bytes".} =
    GC_fullCollect()
    cint(getOccupiedMem())

  proc geneTestResultHandles(): cint {.exportc: "gene_test_result_handles".} =
    cint(results.len)

  proc geneTestScopeRetirement(): cint {.exportc: "gene_test_scope_retirement".} =
    cint(generationRetirementAvailable())

# Nim's module init (`NimMain`) runs global `let` initializers — including the
# `TRUE`/`FALSE`/`VOID` singletons. It must execute before any export is called,
# or those singletons read as zero (i.e. `nil`). Emscripten invokes the C
# `_main` shim below at module instantiation. Compile with --noMain:
# ordinary executable startup destroys Nim globals on return, while this VM
# must remain usable through the ABI until the host releases the wasm module.
when not compileOption("noMain"):
  {.error: "gene_wasm requires --noMain; use the nimble wasm task".}

{.emit: """
void NimMain(void);
int cmdCount;
char **cmdLine;
char **gEnv;
int main(int argc, char **argv) {
  cmdCount = argc;
  cmdLine = argv;
  NimMain();
  return 0;
}
""".}
