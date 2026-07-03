## WebAssembly host ABI v0 for the Gene VM (docs/wasm.md §A.4).
##
## Text-only, synchronous: source string in; status + rendered result + captured
## print/println output out. No raw `Value` crosses the boundary — results are
## referenced through opaque i32 handles into a guest-side registry that roots
## the strings until `gene_result_free`. Build with the `wasm` nimble task.

import gene/[compiler, printer, types, vm]

type
  GeneResult = ref object
    status: cint          # 0 ok | 1 gene-error | 2 panic | 3 parse/compile error
    text: string          # rendered result value, or the error message
    output: string        # captured print/println output

var results: seq[GeneResult] = @[]   # handle = index + 1 (0 is reserved / OOM)

proc geneEvalSource(src: string): GeneResult =
  new(result)
  let capture = new(string)
  geneWasmCapture = capture
  defer: geneWasmCapture = nil
  let chunk =
    try:
      compileSource(src)
    except CatchableError as e:
      result.status = 3
      result.text = e.msg
      result.output = capture[]
      return
  let scope = newGlobalScope()
  try:
    let value = run(chunk, scope)
    result.status = 0
    result.text = value.print()
  except GenePanic as e:
    result.status = 2
    result.text = e.msg
  except GeneError as e:
    result.status = 1
    result.text = e.msg
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
  results.add geneEvalSource(src)
  cint(results.len)               # handle = index + 1

proc resultAt(handle: cint): GeneResult =
  if handle >= 1 and handle.int <= results.len: results[handle.int - 1]
  else: nil

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
  ## Release the result's rooted strings. The slot is kept (handles stay stable)
  ## but emptied so its memory is reclaimable.
  let r = resultAt(handle)
  if r != nil:
    r.text = ""
    r.output = ""
    results[handle.int - 1] = nil

# Nim's module init (`NimMain`) runs global `let` initializers — including the
# `TRUE`/`FALSE`/`VOID` singletons. It must execute before any export is called,
# or those singletons read as zero (i.e. `nil`). Emscripten runs the generated C
# `_main` at module instantiation when it is exported (INVOKE_RUN, on by
# default), which guarantees NimMain runs before the ABI exports are callable.
proc main() =
  discard
main()
