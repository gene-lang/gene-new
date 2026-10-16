# Exec qualification budgets

Lock these budgets before the paired qualification runs. They apply separately
on macOS ARM64 and native Linux ARM64, using matched same-host release builds.
The amd64 Rosetta runner is excluded after its libc spawn-error probe failed.

Sequencing deviation: the original control binary/source were preserved before
the refactor, but numerical budgets were not recorded before implementation.
These budgets are being fixed after prototype functional/smoke runs and before
paired qualification. Do not present them as pre-implementation measurements.

- Captured/async no-output rows: median at least 2.5x faster than original;
  median at most matched native + 1 ms, p95 at most native p95 + 2 ms.
- Synchronous inherited stdio: no repeatable median regression exceeding the
  greater of 15% or 0.2 ms versus control across three rotated rounds.
- First streamed line: median at most native + 1 ms, p95 at most native + 2 ms.
- 1 MiB capture, separately and simultaneously on stdout/stderr: at least 2x
  control throughput and at least 50% of direct native throughput.
- Binary adapter stdin/stdout: at least 2x control throughput and at least 20%
  of native direct-pipe throughput (which omits Gene's additional adapter pipe).
- 64 active captured children must permit a short child and small file read
  within 2 s while the long children are held on a deterministic release gate.
  One monitor thread; active peak at least 64; no captured exec worker occupancy.
- A 180 ms exec-only scheduler wait performs fewer than 12 native lane waits;
  pending counters return to zero. Native silent-child pumps have no periodic
  timeout when exit notification is available. Forced Linux poll is reported
  separately and is not an event-driven latency result.
- Idle CPU, cold startup, worker-lane behavior, slow-consumer fairness and
  optional environment cost are measured/reported, not hidden in warm medians.

Investigate failures, retain failed captures, and change code or explicitly
report unmet budgets; do not silently loosen a threshold after qualification.
