# Checked AOT and publication qualification

This capture follows `69fc074` (publication traversal) and `60768a8` (harness
runner qualification). The implementation ledger is
[`docs/proposals/optimization.md`](../../../docs/proposals/optimization.md).
Host: macOS arm64, Nim 2.2.4, Apple clang 21, ORC, portable release with bounds
and overflow checks. No assessment build or profile overlapped the timings.
This is a shared workstation; substantial background OS activity was observed.

## Real service workload

**Use about 1.6× as the improvement estimate.** Claude's independent quiet
rerun in the October 4 review reported 32.7/32.9 s before and 19.8/20.3 s after
for 100 turns, with 19.8 s from the independent optimized rebuild. Checksums
were 15100. The 40-turn comparison was 7.42/7.46 s versus 4.71/4.75 s with
checksum 3280. Ratios of the two-run medians are 1.64× and 1.57× respectively.
These are reviewer-reported observations; the raw files below are the earlier
noisy capture and must not be presented as the quiet rerun's evidence.

`harness/` contains one excluded warmup and three measured runs per binary,
rotating their order each round. Each process creates a fresh workspace and
performs 100 real service/turn/patch operations. Every run checked all 100 output
files and produced record checksum **15100**. The workspace trees remain in
`tmp/optimization-implementation/harness-comparison-final/workspaces/` rather
than in this baseline.

| Binary | Service samples (ms) | Median (ms) | Range (ms) | Whole-process median (ms) |
| --- | --- | ---: | --- | ---: |
| Pre-publication checked-AOT CLI (`gene-optimized`) | 41579, 90409, 86292 | 86292 | 41579–90409 | 87139 |
| Publication CLI, fresh cache (`gene-publication`) | 24443, 30387, 21207 | 24443 | 21207–30387 | 25226 |
| Publication CLI, independent CLI-test build (`gene-publication-rebuild`) | 23916, 24594, 68274 | 24594 | 23916–68274 | 25201 |

This table is retained for audit, not as the headline performance estimate.
The ranges are wide and overlap; warmup times were 37176/24765/24517 ms.
The apparent 3.5× ratio is noise-dominated and is superseded by the quiet result
above. Neither capture establishes a universal application gain.

The two optimized CLIs came from separate caches/compilations. The second is
the actual release executable built by `tests/test_cli.nim`, copied after its
tests completed. Both use the same runtime changes; executable SHA-256 values
and build/version strings are in `harness/summary.json`. `vm-build-inputs.json`
records hashes of the retained generated VM C inputs, including the pre-change
snapshot. The pre-change binary was built during checked-AOT integration,
before any publication changes; this workload does not invoke AOT functions.

Reproduction, after building each CLI and with an isolated package store:

```sh
GENE_BENCH_SAMPLES=3 path/to/after-gene run benchmarks/run_harness.gene tmp/new-harness-capture path/to/before-gene path/to/after-gene path/to/independently-rebuilt-after-gene
```

Empty stderr files and the earlier aborted capture were removed during review
cleanup. Successful raw samples, metadata, summaries and compressed profiles/
qualification logs remain. The runner has regression tests for warmup exclusion,
measured-round recording and checksum rejection.

## Core controls and AOT cost

`core/` contains 89 matching measurement rows for both binaries, with one
excluded warmup and three measured rounds in alternating order. All checksums
and work counts match. The pre-change core binary is the instrumented baseline
already captured on October 3; the new binary includes checked AOT and the
publication change. Medians, in nanoseconds per iteration:

| Control | Before | After |
| --- | ---: | ---: |
| Empty chunk | 110.96 | 108.96 |
| Constant chunk | 138.90 | 135.13 |
| Matched untyped F64 call | 314.37 | 302.22 |
| Typed F64 call | 453.62 | 442.77 |
| Seven-argument F64 call | 910.43 | 849.31 |
| Disabled Gene logging | 1555.21 | 1569.35 |
| Generated C field getter | 0.875 | 0.806 |

The largest higher median among the 89 rows is 9.6% (structural-node equality);
type-direct sends are 6.9% higher. These small changes are not isolated gains or
regressions: this comparison has one core build per revision, known historical
build variance, and a shared host. The optimized whole-process samples were
34.6/34.8/59.2 seconds; the baseline samples were 35.1–35.4 seconds. Small or
sub-nanosecond differences need independent rebuild confirmation. This work
does not claim to resolve the send or typed-F64 cost identified in the review.

`aot/` holds three fresh runs of `examples/native/bench_fib.sh` with the checked
ABI v2. For 20 calls to fib(28), VM times were 1207/1227/1219 ms and native times
99/103/105 ms: a ratio of medians of 11.8×, with result 317811 on both paths.
For 200,000 identity-loop iterations, native boundary totals were 72/76/74 ms
and VM totals 25/23/22 ms. These include the surrounding Gene loop. The old
unchecked ABI's 117× Fibonacci result is not a current-backend claim. Exact
intermediates and error propagation have a measurable cost; larger native
kernels still amortize the boundary.

## Follow-up profile

After all timing runs, the optimized CLI ran the same 100-turn workload with a
separate ten-second `sample` capture at a requested 1 ms interval, starting one
second after launch. `profile/` stores the compressed raw report, its hash,
the Gene summary, and workload/sampler logs. All **7,091 main-thread samples**
are accounted for; idle worker threads are excluded, as in the earlier capture.

| Attributed bucket | Before (7,219 samples) | After (7,091 samples) |
| --- | ---: | ---: |
| Publication / shared-graph marking | 47.83% | 16.89% |
| Scope escape / retention | 29.03% | 44.80% |
| Call binding / contracts | 0.33% | 0.54% |
| Lookup | 0.61% | 1.51% |
| Reference counting outside those buckets | 1.11% | 1.73% |
| Allocation/copy outside those buckets | 1.69% | 2.85% |
| Unattributed, including waits and inlined work | 19.39% | 31.67% |

This supports the intended reduction in publication work. It does not mean
escape checks became intrinsically slower: these are shares of different
captures, not absolute subsystem timers. Scope escape is the next service-side
investigation. The profiled workload completed all patches with checksum 15100
in 21599 ms; do not mix that instrumented duration into the timing distributions.

## Correctness qualification

Compressed logs under `verification/` preserve the results:

- 829 specs passed, including emitted C built with ASan and UBSan.
- Exact C integer differential tests passed with sanitizers, using both compiler
  overflow builtins and the portable fallback.
- 86 ORC reference-count/scope tests and 49 AtomicArc worker tests passed.
- Managed-root tests passed: 5 ORC, 41 AtomicArc, plus 2 normal-mode retirement
  gate tests. Publication tests retain hidden scope edges and revisit newly
  attached children on the next publication.
- The broad suite ran 1,633 cases: 1,627 passed and six old C-output expectations
  failed. After migrating those expectations, all 118 module/C-target CLI checks
  passed in the rebuilt broad-suite executable. The separate module run passed
  all 115 cases. The initial broad-suite log is retained, including its failures.
- Final debug and release CLIs each passed the 37-spec harness replay selection.
- Six benchmark-tool specs passed. The SQLite example passed both its standalone
  C driver and its loaded Gene calls.

The new C ABI is version 2 and requires rebuilding old AOT libraries. The checks
qualify this macOS arm64 environment; they are not a Linux or wasm qualification.
