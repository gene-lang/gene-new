# Package

version       = "0.1.0"
author        = "G. Cao"
description    = "Gene — a homoiconic general purpose language"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["gene"]

# Dependencies

requires "nim >= 2.0.0"

task test, "Run the test suite":
  exec "nim c -r --path:src --hints:off tests/test_all.nim"

task spec, "Run executable language surface specs":
  exec "nim c -r --path:src --hints:off tests/spec_runner.nim"

task perf, "Run release-mode core benchmarks":
  exec "nim c -r -d:release --path:src --hints:off benchmarks/bench_core.nim"

task leakcheck, "Run refcount/scope leak tracking tests":
  exec "nim c -r -d:geneRcStats --path:src --hints:off tests/test_rc.nim"

task threadcheck, "Run threaded atomicArc smoke checks":
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_values.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_vm.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_native_api_threads.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_thread_workers.nim"
  exec "nim c -r --mm:atomicArc --threads:on -d:geneRcStats --path:src --hints:off tests/test_rc.nim"

task verify, "Run tests, executable specs, and benchmarks":
  exec "nim c -r --path:src --hints:off tests/test_all.nim"
  exec "nim c -r --path:src --hints:off tests/spec_runner.nim"
  exec "nim c -r -d:release --path:src --hints:off benchmarks/bench_core.nim"
  exec "nim c -r -d:geneRcStats --path:src --hints:off tests/test_rc.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_values.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_vm.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_native_api_threads.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_thread_workers.nim"
  exec "nim c -r --mm:atomicArc --threads:on -d:geneRcStats --path:src --hints:off tests/test_rc.nim"
