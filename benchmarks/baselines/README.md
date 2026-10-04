# Performance evidence

Keep raw samples and provenance with each baseline. State the source revision,
build commands, binary digest, target/toolchain, instrumentation, process/run
ordering and any environment qualifications. Preserve failed or skipped
fixture status in the report; do not report those as completed measurements.

The Gene runner in `benchmarks/run.gene` produces `metadata.json`, per-process
raw logs and `summary.json`. Pair independently built executables to measure
both run and build variation. Its timings include the work described by each
benchmark, and net Nim allocator retention is distinct from peak RSS.

Historical directories are evidence, not universal performance thresholds.
Profiles of a representative release application determine which runtime
optimization to attempt next.
