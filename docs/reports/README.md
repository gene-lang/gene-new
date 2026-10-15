# Work reports

Each report records a completed piece of work: what changed, how it was
measured or verified, and what was left open. Reports describe the code when
they were written; the guides and [specification](../spec/README.md) describe
current behavior. Open designs live in [proposals](../proposals/README.md).

| Report | Work | Evidence |
| --- | --- | --- |
| [Performance implementation ledger](optimization.md) | Portable release default, checked native lowering, reproducible measurement (2026-10-04). | `benchmarks/baselines/2026-10-03-*`, `2026-10-04-publication` |
| [Optimization review follow-up](optimization-review.md) | Disposition of the review of that work. | |
| [General-purpose runtime optimization](general-runtime-optimization.md) | Lower ordinary application overhead (2026-10-10 and 2026-10-11). | `benchmarks/baselines/2026-10-1[01]-general-runtime` |
| [Pooled call-scope metadata](scope-pool-reset-investigation.md) | Investigation and fix of a finding from that work. | `tests/fixtures/scope_pool_metadata_probe.nim` |
| [Typed boundaries and stdlib dispatch](types-stdlib-optimization.md) | Cheaper type-contract checks and standard-library calls (2026-10-14). | `benchmarks/baselines/2026-10-14-types-stdlib` |
| [Harness computer use and media](harness-computer-media.md) | Computer use, screenshots and uploads in the Harness, with its [verification record](harness-computer-media-verification.md). | |
