import gene/[compiler, printer, vm]
import std/[os, unittest]

template ck(src, expected: string) =
  check run(compileSource(src), newGlobalScope()).print() == expected

template withGeneWorkers(body: untyped) =
  let previousWorkers = getEnv("GENE_WORKERS")
  putEnv("GENE_WORKERS", "2")
  try:
    body
  finally:
    putEnv("GENE_WORKERS", previousWorkers)

suite "threaded scheduler workers":
  test "worker pool runs worker-candidate tasks":
    withGeneWorkers:
      ck "(scope (var x 20) " &
         "  (var a (spawn (+ x 1))) " &
         "  (var b (spawn (+ x 2))) " &
         "  (+ (await a) (await b)))",
         "43"

  test "root channel waits run worker-candidate tasks on workers":
    withGeneWorkers:
      ck "(scope (var ch (channel ^capacity 1)) " &
         "  (var x 40) " &
         "  (spawn (ch ~ Channel/send (+ x 2))) " &
         "  (ch ~ Channel/recv))",
         "42"
