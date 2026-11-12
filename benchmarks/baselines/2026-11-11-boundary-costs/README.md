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
- `profiles/`: `sample` call graphs (3 s each) of the five kernels beside
  them, on the branch binary at `51e3fbe8`, and `self_and_callers.py`, which
  prints each leaf's self time and callers. Report section 9.
- `kernels-final/`: `run_kernels.gene` again at `98f8e870`, after the
  interpreter-core commits.
