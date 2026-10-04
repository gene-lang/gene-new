# Performance implementation ledger

This branch implements the reviewed 2026-10-03 optimization assessment
(`tmp/optimization.md`). The assessment's P1/P2 ideas are conditional on
profiles and conformance, not promised speedups. Preserve Gene syntax,
arbitrary-precision arithmetic, evaluation order, scoped dispatch, ownership,
budgets and cancellation.

## Acceptance matrix

| Work | Required evidence | Status |
| --- | --- | --- |
| Portable release default, explicit debug build, version metadata | Build the actual CLI in both modes, inspect `--version`, run CLI checks and the harness replay selection in both modes | Both modes built and report correct optimization/check settings; both replay selections pass 37/37 |
| AOT minimum I64 literal | VM/generated-C parity for signed minimum and an in-range comparison, compiler warnings enabled | Fixed; fresh CLI emission returns 1 for the in-range comparison and compiles with the unsigned-literal warning as an error; full spec pending |
| AOT overflow and effect order | Intermediate overflow, safe failure before invalid control flow, exact effects once, direct-C and dynamic boundary tests, UBSan | In progress; direct-C error contract requested |
| AOT status documentation | Generated header and source comments agree with the runtime loader | Updated; final audit pending |
| Reproducible controls and baselines | Empty/constant chunks, matched F64 bodies, machine/build provenance, raw samples, checksums, distributions, independent rebuilds | Implementation in progress |
| Application profiles before P1 | Release harness replay and numeric application samples, ranked sample counts and limitations | Pending |
| Profile-selected P1 improvements | Before/after application and control workloads; relevant VM/spec/lifetime/thread checks | Pending profiling gate |

P2 representation/cache changes and P3 JIT remain subject to the assessment's
evidence gates. A new borrow contract or direct-C error policy needs an
explicit owner decision; elapsed time is not approval. Record such decisions
here and keep unrelated work moving while awaiting them.

## Verification notes

Source baseline: `91562b1c64dc994930a6b830664305af8a8d2d85`.
Implementation branch: `perf/gene-optimization`.
Scratch builds/results: `tmp/optimization-implementation/`.
The original debug CLI and Claude's completed release CLI were copied there
before changing the default build. Performance runs must not overlap builds.

Default-mode semantic checks of the CLI and benchmark source currently pass
`nim check`; this does not replace actual build/run checks. The initial CLI
release build was launched without `-d:release` to verify the new default.

The new Gene benchmark runner passed a synthetic reporting-protocol smoke
check: one excluded warmup plus three measured samples, stable checksums,
expected medians and stored metadata. It uses existing process, JSON,
filesystem, sorting and timing APIs. Real baseline capture is still pending
the instrumented benchmark build.

The runner also passed paired executable rotation and rejects both a nonzero
child exit and a checksum disagreement between executables. Failed captures
leave their raw logs and do not produce an apparently valid summary.

Checkpoint commits: `39567a6` (release default/build metadata), `bcb68cb`
(signed minimum literal and AOT documentation). The explicit
`-d:geneDebug -d:release` combination is rejected rather than mislabeled.
`nimble tasks` recognizes the debug task. Both CLIs preserve the expected
VM TypeError for an overflowing I64 return. Fresh generated C compiles with
`-Werror=implicitly-unsigned-literal` and returns the correct minimum-literal
comparison result.

The sandboxed harness runs each passed 36/37: the local HTTP timeout fixture
could not listen on localhost. The release rerun with localhost access passed
all 37; this was an environment restriction, not a runtime failure. The debug
rerun also passed all 37 under the same qualification conditions.
