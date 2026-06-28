import gene/[compiler, printer, vm]
import std/[os, unittest]

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

suite "threaded scheduler workers":
  test "worker pool runs worker-candidate tasks":
    let previousWorkers = getEnv("GENE_WORKERS")
    putEnv("GENE_WORKERS", "2")
    try:
      ck "(scope (var x 20) " &
         "  (var a (spawn (+ x 1))) " &
         "  (var b (spawn (+ x 2))) " &
         "  (+ (await a) (await b)))",
         "43"
    finally:
      putEnv("GENE_WORKERS", previousWorkers)
