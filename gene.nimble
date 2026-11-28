# Package

version       = "0.1.0"
author        = "G. Cao"
description    = "Gene — a homoiconic general purpose language"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"

# The formatter, language server, and structural viewer are tools, not runtime.
# Building them separately is what keeps fmt.nim, the LSP analyzer, the
# structural index, and the viewer out of every Gene process; `gene fmt|lsp|view`
# exec the sibling binary. namedBin maps the Nim module name (no hyphens
# allowed) to the hyphenated executable the CLI looks for.
bin           = @["gene", "gene_fmt", "gene_lsp", "gene_viewer", "gene_registry", "gene_doc"]
namedBin["gene_fmt"] = "gene-fmt"
namedBin["gene_lsp"] = "gene-lsp"
namedBin["gene_viewer"] = "gene-viewer"
namedBin["gene_registry"] = "gene-registry"
namedBin["gene_doc"] = "gene-doc"

# Dependencies

requires "nim >= 2.4.2"

task debug, "Build the instrumented CLI and companion tools":
  exec "nimble build --undef:release -d:geneDebug"

task debug_ic, "Build the instrumented CLI incrementally":
  mkDir "bin"
  exec "nim c --ic:on -d:geneDebug --path:src -o:bin/gene src/gene.nim"

task speedy, "Optimized build for maximum performance":
  exec "mkdir -p bin"
  exec "nim c -d:release --mm:orc --opt:speed --passC:\"-march=native -O3\" -o:bin/gene src/gene.nim"

task speedy_pgo, "speedy, profile-guided: instrument, train (tools/pgo), rebuild":
  ## Needs clang and llvm-profdata (on macOS, the Xcode command line
  ## tools). The instrumented binary, raw counters and merged profile stay in
  ## build/pgo.
  let pgo = thisDir() & "/build/pgo"
  let profile = pgo & "/gene.profdata"
  let flags = "-d:release --mm:orc --opt:speed"
  let profdata = when defined(macosx): "xcrun llvm-profdata" else: "llvm-profdata"
  exec "mkdir -p bin " & pgo
  exec "nim c " & flags &
       " --passC:\"-march=native -O3 -fprofile-instr-generate\"" &
       " --passL:\"-fprofile-instr-generate\" --nimcache:" & pgo &
       "/nimcache-instrumented -o:" & pgo & "/gene-instrumented src/gene.nim"
  exec "rm -rf " & pgo & "/profile"
  exec "sh tools/pgo/train.sh " & pgo & "/gene-instrumented " & pgo & "/profile"
  exec profdata & " merge -o " & profile & " " & pgo & "/profile"
  exec "nim c " & flags &
       " --passC:\"-march=native -O3 -fprofile-instr-use=" & profile & "\"" &
       " -o:bin/gene src/gene.nim"

task wasm, "Build the wasm host-ABI module (archive/docs/workflows.md §A.4) via Emscripten":
  ## Requires the Emscripten SDK (`emcc` on PATH). Produces web/gene.js +
  ## web/gene.wasm exporting the text-only eval ABI, ready for the browser
  ## playground (web/index.html) and the node harness (tests/test_wasm.mjs).
  ## The hosted main shim initializes Nim without executable-mode cleanup.
  ## --noMain also keeps Nim from destroying globals when startup returns.
  exec "mkdir -p web"
  exec "nim c --os:linux --cpu:wasm32 -d:emscripten -d:geneWasm --mm:orc " &
       "-d:release --threads:off --noMain --cc:clang --clang.exe:emcc " &
       "--clang.linkerexe:emcc --path:src --hints:off " &
       "--passL:\"-s EXPORTED_FUNCTIONS=['_main','_gene_alloc'," &
       "'_gene_free','_gene_eval','_gene_result_status','_gene_result_text_ptr'," &
       "'_gene_result_text_len','_gene_result_out_ptr','_gene_result_out_len'," &
       "'_gene_result_free','_malloc','_free']\" " &
       "--passL:\"-s EXPORTED_RUNTIME_METHODS=['HEAPU8']\" " &
       "--passL:\"-s ALLOW_MEMORY_GROWTH=1\" " &
       "--passL:\"-s STACK_SIZE=8388608\" " &
       "--passL:\"-s STACK_OVERFLOW_CHECK=2\" " &
       "--passL:\"-s MODULARIZE=1 -s EXPORT_NAME=GeneModule\" " &
       "-o:web/gene.js src/gene_wasm.nim"
  exec "node tests/test_wasm.mjs"

task native_example, "Build and run the typed_native SQLite example":
  ## Compiles examples/native/sqlite_rows.gene to C with the experimental
  ## typed_native backend, links it with a small C shim and driver against
  ## libsqlite3, and runs the result. Requires a C compiler and SQLite headers;
  ## needs bin/gene, so run `nimble build` first.
  exec "examples/native/build.sh"

task genex, "Build the genex SDL2 and WebSocket libraries":
  ## Requires bin/gene, Python 3, a C compiler, pkg-config, SDL2/SDL2_ttf,
  ## and libcurl with WebSocket support. See src/genex/README.md.
  exec "python3 src/genex/tools/build.py"

task tools, "Build gene-fmt, gene-lsp, gene-viewer, and gene-doc":
  ## `gene fmt|lsp|view|doc build` exec these, resolved next to the running
  ## `gene` binary and then on PATH. Without them those subcommands report a
  ## clear error naming both places they looked.
  exec "mkdir -p bin"
  exec "nim c --path:src --hints:off -o:bin/gene-fmt src/gene_fmt.nim"
  exec "nim c --path:src --hints:off -o:bin/gene-lsp src/gene_lsp.nim"
  exec "nim c --path:src --hints:off -o:bin/gene-viewer src/gene_viewer.nim"
  exec "nim c --path:src --hints:off -o:bin/gene-doc src/gene_doc.nim"

task migrate, "Build the flat-clause source migration tool":
  exec "nim c --path:src --hints:off -o:bin/migrate_flat_syntax tools/migrate_flat_syntax.nim"

task sort_imports, "Build the import-selector sorting tool":
  exec "nim c --path:src --hints:off -o:bin/sort_imports tools/sort_imports.nim"

task test, "Run the test suite":
  exec "nim c -r -d:geneScopeReuseTests -d:geneInertStampTests -d:geneFastLoopTests --path:src --hints:off tests/test_all.nim"
  exec "nim c -r -d:genePollWindowTests --path:src --hints:off tests/test_poll_window.nim"
  exec "nim c -r --path:src --hints:off tests/test_migrate_flat_syntax.nim"
  exec "nim c -r --path:src --hints:off tests/test_native_integer.nim"
  exec "nim c -r --path:src --hints:off tests/test_native_managed_abi.nim"
  exec "nim c -r --path:src --hints:off tests/test_native_callback_abi.nim"
  exec "nim c -r --path:src --hints:off tests/test_native_async_abi.nim"
  exec "nim c -r --path:src --hints:off tests/test_release_crypto.nim"
  exec "nim c -r --path:src --hints:off tests/test_digest.nim"
  exec "nim c -r --path:src --hints:off tests/test_keyindex.nim"
  exec "nim c -r -d:geneStoreFaultTests --path:src --hints:off tests/test_store_faults.nim"
  exec "nim c -r --path:src --hints:off tests/test_package_release.nim"
  exec "python3 tests/test_registry_https.py"
  exec "python3 tests/test_registry_service.py"
  exec "nim c -r --path:src --hints:off tests/test_tzif.nim"
  exec "nim c -r --path:src --hints:off tests/test_value_backend_boundaries.nim"
  exec "python3 tests/test_owned_http_client.py"
  exec "python3 tests/test_genex_package.py"
  exec "python3 tests/test_genex_toolchain.py"
  exec "python3 tests/test_genex_libuv_timer.py"
  exec "python3 tests/test_genex_native_module.py"
  exec "python3 tests/test_genex_tzdb.py"
  exec "python3 tests/test_archive_codec.py"
  exec "python3 tests/test_genex_archive_package.py"
  exec "python3 tests/test_archive_zip.py"
  exec "python3 tests/test_tls_adapter.py"
  exec "python3 tests/test_genex_tls_package.py"
  exec "node tests/test_wasm.mjs"
  when defined(posix): exec "nimble execTest"

task spec, "Run executable language surface specs":
  exec "nim c -r --path:src --hints:off tests/spec_runner.nim"

task execTest, "Run native process launch, I/O, notification and exec regressions":
  when defined(posix):
    exec "nim c -r -d:geneExecTests --path:src --hints:off tests/test_process_launch.nim"
    exec "nim c -r --path:src --hints:off tests/test_detached_process.nim"
    exec "nim c -r -d:geneExecTests --path:src --hints:off tests/test_process_io.nim"
    exec "nim c -r -d:geneExecTests --path:src --hints:off tests/test_native_wake.nim"
    exec "nim c -r -d:geneExecTests --path:src --hints:off tests/test_exec.nim"
  else:
    echo "Native process qualification requires macOS or Linux"

task contracts, "Qualify scheduler, synchronization and frozen graph contracts":
  exec "nim c -d:geneSchedulerTests -d:geneGraphProofTests --path:src --hints:off -o:bin/gene-contracts src/gene.nim"
  exec "nim c -r --path:src --hints:off tests/test_frozen_graph_proofs.nim"
  exec "bin/gene-contracts run tools/verify_scheduler.gene bin/gene-contracts auto --gates --proofs"

task transpile_spec, "Run shared VM/web-profile conformance fixtures":
  exec "node tools/check_host_bindings.mjs"
  exec "nim c -r --path:src --hints:off tests/transpile_fixture_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_web_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_async_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_dom_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_files_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_embed_runner.nim"

task transpile_typecheck, "Type-check emitted web artifacts with pinned TypeScript":
  exec "npm run transpile:typecheck"

task host_bindings, "Check the web profile's host surface against lib.dom.d.ts":
  ## The compiler is the source of truth for what Gene can call; TypeScript is
  ## the oracle that says whether those calls exist. Run by `test`, so drift
  ## fails the build instead of producing a document nobody reads.
  exec "node tools/check_host_bindings.mjs"

task transpile_perf, "Measure web-profile numeric, compile, runtime, and size baselines":
  if getEnv("GENE_EXE").len == 0:
    mkDir "build/transpile-perf"
    let host = "build/transpile-perf/gene"
    exec "nim c --ic:on -d:release --path:src --hints:off " &
         "--nimcache:build/nimcache/transpile-perf -o:" & host & " src/gene.nim"
    putEnv("GENE_EXE", host)
  exec "node benchmarks/transpile_numbers.mjs"
  exec "node benchmarks/transpile_web.mjs"

task perf, "Run release-mode core benchmarks":
  exec "nim c --ic:on -r -d:release --path:src --hints:off " &
       "--nimcache:build/nimcache/bench-core benchmarks/bench_core.nim"

task leakcheck, "Run refcount/scope leak tracking tests":
  exec "nim c -r -d:geneRcStats --path:src --hints:off tests/test_rc.nim"
  exec "nim c -r -d:geneRcStats --path:src --hints:off tests/test_native_api.nim"
  exec "nim c -r -d:geneRcStats --path:src --hints:off tests/test_native_managed_orc.nim"
  exec "nim c -r -d:geneRcStats --path:src --hints:off tests/test_native_callback_abi.nim"

task threadcheck, "Run threaded atomicArc smoke checks":
  when defined(posix):
    exec "nim c -r --mm:atomicArc --threads:on -d:geneExecTests --path:src --hints:off tests/test_exec.nim"
  exec "nim c -r --mm:atomicArc --threads:on -d:geneRcStats --path:src --hints:off tests/test_atomic_generation_retirement.nim"
  exec "nim c -r --mm:atomicArc --threads:on -d:geneRcStats --path:src --hints:off tests/test_native_managed_disabled.nim"
  exec "nim c -r --mm:atomicArc --threads:on -d:geneRcStats -d:geneAtomicGenerationRetirementProbe --path:src --hints:off tests/test_native_managed.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_native_managed_abi.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_native_callback_abi.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_native_async_abi.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_io_lifecycle.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_io_scope.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_io_file.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_io_tcp.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_csv_stream.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_values.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_vm.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_native_api_threads.nim"
  exec "python3 tests/test_owned_http_client.py --atomic-arc"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_thread_workers.nim"
  exec "nim c -r --mm:atomicArc --threads:on -d:geneRcStats --path:src --hints:off tests/test_rc.nim"

task verify, "Run tests, executable specs, and benchmarks":
  exec "nim c -r -d:geneScopeReuseTests -d:geneInertStampTests -d:geneFastLoopTests --path:src --hints:off tests/test_all.nim"
  when defined(posix): exec "nimble execTest"
  exec "nim c -r --path:src --hints:off tests/spec_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_fixture_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_web_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_async_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_dom_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_files_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_embed_runner.nim"
  exec "nimble transpile_perf"
  exec "nimble perf"
  exec "nim c -r -d:geneRcStats --path:src --hints:off tests/test_rc.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_values.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_vm.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_native_api_threads.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_thread_workers.nim"
  exec "nim c -r --mm:atomicArc --threads:on -d:geneRcStats --path:src --hints:off tests/test_rc.nim"
