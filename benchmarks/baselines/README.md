# Performance evidence

Keep provenance and every timed sample with each baseline. State the source
revision, build commands, binary digest, target/toolchain, instrumentation,
process/run ordering and any environment qualifications. Preserve failed or
skipped fixture status in the report; do not report those as completed
measurements.

The Gene runner in `benchmarks/run.gene` produces `metadata.json`, per-process
raw logs and `summary.json`. Pair independently built executables to measure
both run and build variation. Its timings include the work described by each
benchmark, and net Nim allocator retention is distinct from peak RSS.

## What to check in

Check in `README.md`, `metadata.json`, `summary.json`, `report.md`, copied
runner sources, compressed profiles and compressed verification logs. Leave
the per-process `*.stdout.json`, `*.stdout.jsonl` and `*.stderr.txt` captures
in the local output directory: `summary.json` already records every sample,
checksum and process time they contain.

Baselines up to 2026-10-14 were captured with those per-process files. They
were removed on 2026-10-15; where an older README says raw samples sit beside
a summary, the files are in the history before that date
(`git log --diff-filter=D -- 'benchmarks/baselines/*.stderr.txt'`).

Historical directories are evidence, not universal performance thresholds.
Profiles of a representative release application determine which runtime
optimization to attempt next.
