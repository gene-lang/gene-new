import gene/[compiler, printer, types, vm]
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

  test "root execution lease runs worker-candidate tasks before blocking waits":
    withGeneWorkers:
      let task = run(compileSource(
        "(var t (spawn 42)) " &
        "(var i 0) " &
        "(while (< i 200000) (set i (+ i 1))) " &
        "t"), newGlobalScope())
      check task.kind == vkTask
      check task.taskDone

  test "root function calls lease workers for worker-candidate tasks":
    withGeneWorkers:
      let fn = run(compileSource(
        "(fn [] " &
        "  (var t (spawn 42)) " &
        "  (var i 0) " &
        "  (while (< i 200000) (set i (+ i 1))) " &
        "  t)"), newGlobalScope())
      check fn.kind == vkFunction
      let task = fn.call()
      check task.kind == vkTask
      check task.taskDone

  test "generator pulls lease workers for worker-candidate tasks":
    withGeneWorkers:
      let task = run(compileSource(
        "(fn gen [] " &
        "  (var t (spawn 42)) " &
        "  (var i 0) " &
        "  (while (< i 200000) (set i (+ i 1))) " &
        "  (yield t)) " &
        "(var s (gen)) " &
        "(s ~ Stream/next)"), newGlobalScope())
      check task.kind == vkTask
      check task.taskDone

  test "worker pool wakes sleeping worker-candidate tasks while root runs":
    withGeneWorkers:
      let task = run(compileSource(
        "(var t (spawn (do (sleep 1) 42))) " &
        "(var i 0) " &
        "(while (< i 800000) (set i (+ i 1))) " &
        "t"), newGlobalScope())
      check task.kind == vkTask
      check task.taskDone
