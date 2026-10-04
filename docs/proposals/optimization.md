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
| AOT overflow and effect order | Intermediate overflow, safe failure before invalid control flow, exact effects once, direct-C and dynamic boundary tests, UBSan | In progress; owner approved checked status + out-result C API |
| AOT status documentation | Generated header and source comments agree with the runtime loader | Updated; final audit pending |
| Reproducible controls and baselines | Empty/constant chunks, matched F64 bodies, machine/build provenance, raw samples, checksums, distributions, independent rebuilds | Complete local capture: two fresh-cache builds, 89 matching rows, excluded warmup plus three measured rounds each; saved under benchmarks/baselines |
| Application profiles before P1 | Release harness replay and numeric application samples, ranked sample counts and limitations | Captured real service/patch workload and native Miclone generation; publication/escape dominate service; call/contract and lookup are numeric targets |
| Profile-selected P1 improvements | Before/after application and control workloads; relevant VM/spec/lifetime/thread checks | Pending profiling gate |

P2 representation/cache changes and P3 JIT remain subject to the assessment's
evidence gates. A new borrow contract needs an explicit owner decision;
elapsed time is not approval. Record such decisions
here and keep unrelated work moving while awaiting them.

## Owner decision: direct C errors

The owner selected **checked status + out-result C API** for direct C callers
on 2026-10-03. Implement and document that experimental generated API, migrate
its in-repository callers, and preserve ordinary Gene error semantics through
`aot/load`. This approval does not authorize wrapping intermediate integers,
replaying effects, or treating a late overflow flag as safe control flow.

The integer foundation is `src/gene/native_integer.h`: native-width values
stay unboxed, while overflow promotes to owned arbitrary-precision temporaries.
This preserves intermediate values instead of replaying a function after an
effect. The portable C support also preserves standalone C consumers; it is
checked differentially against Gene's existing integer implementation. It is
not yet wired into emitted functions. Remaining work includes checked function
signatures, sequenced expression/statement lowering, typed-boundary errors with
their actual values, cleanup on every exit, dynamic-entry propagation, ABI
admission/versioning, and migration of the C examples/tests/benchmarks.

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

That capture has now completed and is saved in
`benchmarks/baselines/2026-10-03-controls/`. The new empty-chunk control measures
roughly 109–110 ns per iteration; matched F64 bodies differ by 133–141 ns in
the two builds. This establishes a baseline, not a P1 speedup claim.

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

Application profile results and the attribution method are saved under
`benchmarks/baselines/2026-10-03-applications/`. Native world generation is the
appropriate VM numeric workload; the client mesher's V8 timings must be treated
separately. Publication and escape walks account for approximately 48% and 29%
of the service's main-thread samples. The next P1 investigation is repeated
shared-value graph traversal within one publication, with separate scope/code
visitation and fresh state between publications.

The exact C integer foundation passes the native tests and the same suite with
AddressSanitizer plus UndefinedBehaviorSanitizer. It checks promotion back into
I64, cancellation, aliasing, retained copies, 1000-bit growth, and 81 boundary
operand pairs (including composite results) against Gene's integer operations.
This qualifies the helper only; generated checked functions and their error/
ownership paths still require integration and differential qualification.

Tooling note: List has no destructive `pop` message. The sampling parser uses
linked frame records instead; a general stack API can be considered separately
under the usual library-design review. No language surface was changed for it.
