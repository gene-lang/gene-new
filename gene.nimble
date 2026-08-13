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
bin           = @["gene", "gene_fmt", "gene_lsp", "gene_viewer"]
namedBin["gene_fmt"] = "gene-fmt"
namedBin["gene_lsp"] = "gene-lsp"
namedBin["gene_viewer"] = "gene-viewer"

# Dependencies

requires "nim >= 2.0.0"

task speedy, "Optimized build for maximum performance":
  exec "mkdir -p bin"
  exec "nim c -d:release --mm:orc --opt:speed --passC:\"-march=native -O3\" -o:bin/gene src/gene.nim"

task wasm, "Build the wasm host-ABI module (docs/wasm.md §A.4) via Emscripten":
  ## Requires the Emscripten SDK (`emcc` on PATH). Produces web/gene.js +
  ## web/gene.wasm exporting the text-only eval ABI, ready for the browser
  ## playground (web/index.html) and the node harness (tests/test_wasm.mjs).
  ## `_main` MUST be exported so Emscripten runs NimMain (global `let` init)
  ## before the exports are callable — without it TRUE/FALSE/VOID read as nil.
  exec "mkdir -p web"
  exec "nim c --os:linux --cpu:wasm32 -d:emscripten -d:geneWasm --mm:orc " &
       "-d:release --threads:off --cc:clang --clang.exe:emcc " &
       "--clang.linkerexe:emcc --path:src --hints:off " &
       "--passL:\"-s EXPORTED_FUNCTIONS=['_main','_gene_alloc'," &
       "'_gene_free','_gene_eval','_gene_result_status','_gene_result_text_ptr'," &
       "'_gene_result_text_len','_gene_result_out_ptr','_gene_result_out_len'," &
       "'_gene_result_free','_malloc','_free']\" " &
       "--passL:\"-s EXPORTED_RUNTIME_METHODS=['HEAPU8']\" " &
       "--passL:\"-s ALLOW_MEMORY_GROWTH=1\" " &
       "--passL:\"-s MODULARIZE=1 -s EXPORT_NAME=GeneModule\" " &
       "-o:web/gene.js src/gene_wasm.nim"
  exec "node tests/test_wasm.mjs"

task native_example, "Build and run the typed_native SQLite example":
  ## Compiles examples/native/sqlite_rows.gene to C with the experimental
  ## typed_native backend, links it with a small C shim and driver against
  ## libsqlite3, and runs the result. Requires a C compiler and SQLite headers;
  ## needs bin/gene, so run `nimble build` first.
  exec "examples/native/build.sh"

task tools, "Build gene-fmt, gene-lsp, and gene-viewer":
  ## `gene fmt|lsp|view` exec these, resolved next to the running `gene` binary
  ## and then on PATH. Without them those three subcommands report a clear
  ## error naming both places they looked.
  exec "mkdir -p bin"
  exec "nim c --path:src --hints:off -o:bin/gene-fmt src/gene_fmt.nim"
  exec "nim c --path:src --hints:off -o:bin/gene-lsp src/gene_lsp.nim"
  exec "nim c --path:src --hints:off -o:bin/gene-viewer src/gene_viewer.nim"

task test, "Run the test suite":
  exec "nim c -r --path:src --hints:off tests/test_all.nim"
  exec "node tests/test_wasm.mjs"

task spec, "Run executable language surface specs":
  exec "nim c -r --path:src --hints:off tests/spec_runner.nim"

task transpile_spec, "Run shared VM/web-profile conformance fixtures":
  exec "node tools/check_host_bindings.mjs"
  exec "nim c -r --path:src --hints:off tests/transpile_fixture_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_web_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_async_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_dom_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_embed_runner.nim"

task transpile_typecheck, "Type-check emitted web artifacts with pinned TypeScript":
  exec "npm run transpile:typecheck"

task host_bindings, "Check the web profile's host surface against lib.dom.d.ts":
  ## The compiler is the source of truth for what Gene can call; TypeScript is
  ## the oracle that says whether those calls exist. Run by `test`, so drift
  ## fails the build instead of producing a document nobody reads.
  exec "node tools/check_host_bindings.mjs"

task transpile_perf, "Measure web-profile numeric, compile, runtime, and size baselines":
  exec "mkdir -p bin"
  exec "nim c -d:release --path:src --hints:off -o:bin/gene src/gene.nim"
  exec "node benchmarks/transpile_numbers.mjs"
  exec "node benchmarks/transpile_web.mjs"

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
  exec "nim c -r --path:src --hints:off tests/transpile_fixture_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_web_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_async_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_dom_runner.nim"
  exec "nim c -r --path:src --hints:off tests/transpile_embed_runner.nim"
  exec "mkdir -p bin"
  exec "nim c -d:release --path:src --hints:off -o:bin/gene src/gene.nim"
  exec "node benchmarks/transpile_numbers.mjs"
  exec "node benchmarks/transpile_web.mjs"
  exec "nim c -r -d:release --path:src --hints:off benchmarks/bench_core.nim"
  exec "nim c -r -d:geneRcStats --path:src --hints:off tests/test_rc.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_values.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_vm.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_native_api_threads.nim"
  exec "nim c -r --mm:atomicArc --threads:on --path:src --hints:off tests/test_thread_workers.nim"
  exec "nim c -r --mm:atomicArc --threads:on -d:geneRcStats --path:src --hints:off tests/test_rc.nim"
