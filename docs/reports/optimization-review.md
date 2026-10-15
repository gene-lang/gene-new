# Optimization review follow-up

Review: Claude, 2026-10-04, against `ee04297` on `perf/gene-optimization`.
This records the disposition of the review independently of temporary files.

## Changes made

| Comment | Disposition |
| --- | --- |
| 1. NaN comparison divergence | Removed the native ordering guard. `<`, `<=`, `>`, `>=` and `==` now agree with the VM for NaNs on either side, infinities, and finite values. Default collection ordering remains separate. Added VM/loaded-native differential tests and standalone sanitizer checks. |
| 2. Deep native recursion crashes | Added a per-thread, per-generated-module depth guard, default 256 active calls. It returns a checked RuntimeError, leaves the result untouched, unwinds all temporaries, and permits later calls. Tested depth 100,000 against VM success/native checked failure and repeated recovery. `GENE_AOT_MAX_CALL_DEPTH` configures a qualified C build's limit. It does not guard arbitrary foreign C recursion or huge individual frames. |
| 3. Slow test CLI builds | The eight Python harnesses, Nim CLI tests and HTTP-server tests explicitly build with `-d:geneDebug`. Companion CLI tools do too. A small fixture with the real `gene` project name and build-info module tests the default release policy without optimizing the VM for that assertion. The actual release CLI is rebuilt separately. |
| 4. Noisy speedup estimate | Replaced the estimate with the reviewer's quiet result: about 1.6× (1.64× at 100 turns, 1.57× at 40). Kept the older raw measurements, labeled as noise-dominated and superseded. Reviewer measurements are explicitly attributed, not presented as a new assistant capture. |
| 5. Equality spelling | Both scalar and typed-native eligibility use the existing Gene `==` operator. Removed special treatment of `=` and migrated the native examples/spec fixtures. This repairs backend parity; it adds no Gene syntax. |
| 6. Stale executable and inaccessible header | Rebuilt `bin/gene` as portable release. Added `gene compile --c-header` to export the self-contained C support header from an installed compiler. The SQLite driver now consumes this generated header. |
| 6. Missing assessment reference | Made the implementation ledger self-contained instead of depending on an ignored temporary assessment. |
| 6. Heavy evidence | Removed 38 empty or aborted-capture artifacts. Retained successful raw samples, metadata, profiles and compressed qualification logs for reproducibility. |
| 7. Core benchmark SDK selection | Routed generated-C compilation through `tools/with_c_sdk` on macOS, retaining failure propagation. The chosen SDK is preserved in the benchmark's stderr log. Explicit `SDKROOT` still wins. |
| 8. Statement FFI props disappear | Reject props/metadata at statement admission and in shared FFI argument admission, matching expression-position behavior. No property is silently discarded. |
| 8. Integers wider than I64 crash compilation | Guarded literal-representation inference and emit exact, compiler-generated base-1e9 limbs. Wide constants can participate in comparisons/arithmetic; a narrow typed result raises TypeError with the exact value. Tested positive/negative wide literals and cancellation. |
| 8. Non-finite float literals emit invalid C | Emit `NAN`, `INFINITY` and `(-INFINITY)` and compare VM/native results. |
| 8. Absolute diagnostic source paths | Native frames retain virtual/relative source labels; absolute compiler paths become filenames. Equal scalar sources in two different checkout paths now emit identical C. Existing semantic ABI identities were not changed. |
| 8. Null field stores | Check string and non-null pointer stores before mutation. Also reject invalid null foreign results at the FFI boundary using the runtime's error messages. Added unchanged-destination/result tests. |
| 8. Rewrite leftovers | Removed the unused null-trap exports/declarations and `AotCFunction.optionalNilTail`. The live function-prototype optional-tail metadata is retained. Fixed unused acquisition-error labels on zero-argument native entries, exposed by warning-as-error tests. |

## Ownership limitation left open

The review's failure-before-consumption case is real. A scratch fixture counted
native allocations while calling these shapes with `x = INT64_MAX`:

```gene
(fn transfer_fail ^native_entry {^p transfer} [p : Point x : I64] : I64 (+ x 1))
(fn copy_fail ^native_entry {^p copy} [p : Point x : I64] : I64 (+ x 1))
```

After the transfer failure, one allocation remained live and its Gene wrapper
was closed. After the copy failure, the original remained usable and the copied
allocation remained live. Closing the original left two unconsumed allocations;
the fixture then explicitly released them.

Unconditional post-call restore/free is unsafe: the existing release-then-fail
test verifies that the callee may already have freed the pointer. Arbitrary FFI
calls may retain it or transfer ownership elsewhere, so matching a release
symbol alone cannot prove safety. A complete fix needs ownership effects and
cleanup paths represented in native lowering, including aliases and callbacks.
That contract was not invented in this review fix. The native API guide now
documents the limitation and recommends borrowing with owner-managed cleanup
around fallible kernels. Acquisition failures before native entry still roll
back; generated integer temporaries still clean up on every checked exit.

The suggested unchecked integer fast body with retry is also deferred. A valid
implementation must bail out at each overflowing operation before using the
value for control flow or memory access, and must prove replay has no observable
effects. It is a separate performance feature, not a safe local review cleanup.

## Qualification

- 834 executable specs passed with emitted standalone C under ASan and UBSan.
- 1,635 Nim-suite tests passed, including the debug CLI and release-policy checks.
- Exact-integer differential tests passed with sanitizers in builtin-overflow
  and portable-overflow modes.
- The rebuilt core benchmark completed all 89 measurements with `SDKROOT`
  unset; every checksum and work count matches the previous capture. Its stderr
  records automatic selection of the compatible SDK. Six benchmark-tool specs
  and the SQLite C/Gene workflow also passed using the rebuilt release CLI.
- All eight changed Python harnesses passed: six genex harnesses (one test each),
  owned HTTP client (41 tests, one existing skip), and registry service (8 tests).
  Each harness completed in roughly 38–61 seconds in this run, including its
  fresh debug build and fixtures; these are not isolated compiler timings.

Three subsequent `examples/native/bench_fib.sh` runs used the rebuilt release/ORC
CLI with checks enabled, Apple clang 21 at `-O2`, and automatic SDK selection.
No assessment build/profile overlapped these timings. All results were 317811.

| Run | VM fib(28) × 20 (ms) | Checked native (ms) | 200k boundary iterations (ms) | 200k VM-call iterations (ms) |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1232 | 115 | 71 | 22 |
| 2 | 1238 | 112 | 73 | 21 |
| 3 | 1256 | 122 | 74 | 23 |

The ratio of medians is 10.8×. These measurements include the recursion guard;
the earlier 11.8× capture did not. Identity-loop medians include the surrounding
Gene loop and must not be treated as isolated adapter instruction timings.

Scratch logs and the ownership probe are in `tmp/optimization-review/`. They are
not required to understand this record and are not added as another full evidence
archive. Earlier successful raw performance evidence stays under
`benchmarks/baselines/2026-10-04-publication/`.
