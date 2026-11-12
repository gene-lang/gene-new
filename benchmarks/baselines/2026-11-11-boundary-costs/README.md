# Boundary costs, 2026-11-11

Evidence for [the report](../../../docs/reports/boundary-costs.md). "Before"
and "baseline" are a release build of `37bd3631`; "after" and "gene" are a
release build of branch `perf/python-gap`.

- `boundaries.tsv`: five alternating rounds of `benchmarks/boundaries.gene`.
  Columns are round, binary, kernel, iterations of the batch kept,
  milliseconds, and nanoseconds per iteration. `provenance.txt` has the
  versions, hashes and load.
- `kernels/`: `benchmarks/run_kernels.gene` with the baseline binary, five
  rounds after one warmup.
- `general/`: `benchmarks/run_general.gene` at 5,000 items with the baseline
  binary.
