# Benchmarks

Build the host in portable release mode with `nimble build`. Check
`bin/gene --version`; `nimble debug` is for debugging, not performance baselines.

## Repeatable core measurements

```sh
nim c -d:release --path:src --hints:off -o:tmp/bench_core benchmarks/bench_core.nim
bin/gene run benchmarks/run.gene tmp/perf-run tmp/bench_core
```

The output directory must be new. The Gene runner records the executable
digest, compiled-in Nim command/options, Git revision/worktree state, platform,
C compiler, raw stdout/stderr and per-row samples. Round zero is excluded;
five measured rounds follow (`GENE_BENCH_SAMPLES=3..100` overrides that count).
`GENE_BENCH_MACHINE` can label the CPU/machine used. Medians, ranges and p95
are in `summary.json`; process wall time is recorded separately from the
benchmark loop time. Checksums, row sets and iteration counts must stay stable.
Generated-C failures now fail the benchmark process instead of printing a
warning and returning success. Missing external C compilers are explicit skips.
Run the distribution regression specs with `bin/gene test benchmarks/runner_spec.gene`.

Pass multiple independently built executables to alternate their execution
order across rounds. Use separate fresh Nim cache directories for independent
rebuilds; repeated runs of one executable do not measure build-to-build noise.
Run benchmarks while no compiler or other assessment workload is active.
Preserve commands and machine metadata when checking selected baselines into
`benchmarks/baselines/`; do not infer an optimization from a single run.

The core controls include an empty chunk, a constant chunk and matched
untyped/F64 function bodies. Per-iteration costs include entering/exiting
`run` and result handling. A four-argument builtin addition is not an empty
chunk and cannot be subtracted as an exact entry-cost estimate.

`retained_nim_bytes_delta` records the allocator's net occupied-memory change,
not peak RSS or proof of a leak. Compile a separate run with `-d:nimAllocStats`
for allocation counts; `allocations=-1` means unavailable. Compare timing with
equally instrumented builds. The dedicated pipeline harness adds demand and
cleanup measurements. Application sampling profiles must rank P1 work before
microbenchmark changes are selected; the harness replay selection and a
Miclone meshing pass are the initial application targets.

For the native service path, `bin/gene run examples/gene-harness/probes/performance.gene
tmp/harness-profile 100` runs real service/turn/patch work against a deterministic
provider and asserts that every patch was applied. Use a new workspace each run.
The existing native numeric workload is
`bin/gene run examples/miclone/probes/run_worldgen.gene --repeat-seconds 10`.
It executes the server's real generation code. Miclone's client mesher runs in
V8; profile `tools/mesh_bench.mjs` separately when considering web-backend work,
and do not attribute its timings to the native VM.

For a reproducible uninstrumented service comparison, build both CLIs first,
then run (from the repository root):

```sh
GENE_BENCH_SAMPLES=3 bin/gene run benchmarks/run_harness.gene tmp/harness-comparison path/to/before-gene path/to/after-gene
```

The runner alternates binary order, excludes one warmup per binary, and uses a
fresh workspace for every 100-turn run. It preserves raw output, executable
hashes, version/build information, source diff, result checksums, service timing
and whole-process timing distributions. Keep builds and profiling out of the
measurement window. The workspaces stay under the output directory for inspection;
only logs and summaries belong in a checked-in baseline.

On macOS, `sample PID 10 1 -mayDie -file REPORT` captures native stacks.
`bin/gene run benchmarks/summarize_sample.gene REPORT` accounts for main-thread
samples without counting recursive frames repeatedly. The categorization uses
recognized ancestors and leaves inlined/unknown work unattributed; inspect the
raw stacks too. Run its accounting regression with
`bin/gene test benchmarks/profile_spec.gene`.

Run the recursive Fibonacci benchmark with:

```bash
benchmarks/scripts/bench_fib       # defaults to fib(28)
benchmarks/scripts/bench_fib 28
benchmarks/scripts/bench_fib_typed 30
benchmarks/scripts/bench_fib_aot_c 30
```

Run the call burst benchmark with:

```bash
benchmarks/scripts/bench_call_burst             # defaults to 10000 x 1000 calls
benchmarks/scripts/bench_call_burst 1000 100
```

The current implementation has a bytecode VM but not the old native compiler
mode, so `GENE_BENCH_MODE` currently supports only `vm`. The benchmark compiles
the Gene source once and times VM execution.

`bench_fib_aot_c` measures the experimental C backend separately. It emits C for
a fixed-representation typed function, compiles that C with the host compiler,
and times the resulting binary. This is useful as an AOT/JIT target signal; it
does not exercise runtime VM dispatch into native code.

On macOS, the AOT scripts use `tools/with_c_sdk` to probe the selected C compiler.
If the default SDK cannot link a trivial program, they select the newest installed
SDK that can. An explicit `SDKROOT` is preserved. This also covers the separate C
link step, which cannot inherit an SDK chosen internally by Nim's `config.nims`.

For that, use `examples/native/bench_fib.sh`, which builds the same function as
a loadable AOT library and calls it from Gene through the `aot/load` boundary.
It reports both halves of the trade: compiled fib runs far ahead of the VM once
the call tree is inside compiled code, while a single boundary crossing costs
more than a plain VM call.

## Fibonacci

The benchmarked Gene program is:

```gene
(var fib (fn [n]
  (if (< n 2)
    n
    (+ (fib (- n 1)) (fib (- n 2))))))
(fib 28)
```

`fib(28)` performs 1028457 naive recursive `fib` calls and returns `317811`.

The default benchmark annotates the recursive function as `Int -> Int`, so
typed call-boundary and recursive dispatch fast paths are visible in perf runs.
Pass `24` for the shorter historical 150049-call sample.

## Call Burst

The call burst benchmark compiles each source unit once, then measures tight
bursts of zero-arg, one-arg, four-arg, typed one-arg `Int -> Int`, and typed
four-arg `Int` function calls inside a `while` loop.
