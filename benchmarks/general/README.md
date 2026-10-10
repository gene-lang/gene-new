# General-purpose Gene / Python comparison

This suite measures common scripting and application work using equivalent
algorithms and deterministic data. The implementations use each language's
standard library; no Cordis, Harness, external model, third-party Python
package, network service, or native extension needs to be built separately.
The runner and correctness tests are Gene. Python is the comparison subject.

## Run

From the repository root, with a release Gene binary:

```sh
bin/gene --version
bin/gene run benchmarks/run_general.gene tmp/general-comparison bin/gene "$(command -v python3)"
```

The output directory must be new. Executable arguments are file paths, not
shell command strings; the runner does not invoke a shell. The shell lookup
above only supplies the installed Python path. To use explicit paths:

```sh
bin/gene run benchmarks/run_general.gene tmp/general-large /path/to/gene /path/to/python3 20000
```

| Parameter | Default | Range / meaning |
| --- | --- | --- |
| Final positional `SIZE` | 5000 | 1–1,000,000 input items per workload batch |
| `GENE_BENCH_SAMPLES` | 5 | 3–100 measured fresh processes per language |
| `GENE_BENCH_TARGET_MS` | 100 | 50–10,000 ms calibration target per workload |
| `GENE_BENCH_MACHINE` | empty | Optional machine label recorded in metadata |

Large sizes may need substantial memory: each process builds all four input
collections before timing. A worker has a ten-minute deadline. Gene's existing
`GENE_USER_PACKAGES` override can place package bookkeeping in a writable,
isolated directory when running inside a filesystem sandbox.

Run the tests with Python on PATH, or set `GENE_BENCH_PYTHON` to its executable:

```sh
bin/gene test benchmarks/general_spec.gene
```

Run either counterpart directly to inspect results. A zero target requests one
untimed correctness evaluation of every workload:

```sh
bin/gene run benchmarks/general/workloads.gene 257 0
python3 benchmarks/general/workloads.py 257 0
```

## Workload contract

For item index `i`, the numeric value is `(37*i + 11) mod 1009`. Both versions
construct the same ordered records, ASCII log lines, and account events. Values
stay within exact integer ranges for the supported sizes. Inputs are read-only
during a workload; each call creates fresh output containers.

| Workload | Timed work | Verified result |
| --- | --- | --- |
| `integer_loop` | Sequential multiply/add/modulo recurrence and accumulation | Final state and total |
| `closure_dispatch` | Create eight captured closures; select and invoke one per item | Sum of returned values |
| `records` | Filter active records, group totals in a map, stable sort by amount | Selected count, ordered-ID rolling checksum, all 32 group totals |
| `text_index` | Trim, ASCII lowercase, split, count words, sort the index | Token count and complete sorted word/count entries |
| `json_roundtrip` | Compact JSON encode, decode, and sum decoded amounts | Record count, amount total, UTF-8 encoded byte count |
| `event_replay` | Ordered credit/debit/reset updates to 64 keyed account records | Every account's balance and revision in key order |

Record groups use string keys in both implementations. Python uses explicit
loops corresponding to Gene's loops, and both call their standard-library sort
and JSON implementations. The text fixture is ASCII because Gene's lowercase
operation is ASCII-only. JSON contains only strings, booleans, and integers;
both encoders use compact separators. No floating-point or Unicode behavior is
implicitly treated as equivalent.

Before timing, the runner compares all results at sizes **1, 17, 257, 2048**.
These exercise filtering, all event branches, wrapped groups/accounts, and
duplicate sort keys. Tests also check independently hand-computed single-item,
stable-sort, and event-order cases. Every timed process must match its warmup
results and the other language's results. Missing/duplicate workloads, changed
input size, invalid timing, process errors, timeouts, and truncated output fail
the run; no summary is published for an incomplete comparison.

## Timing method

1. Alternate which language runs first in each round. Run one excluded warmup
   process per language, followed by the requested measured processes.
2. In every process, construct inputs outside kernel timing. For each workload,
   double repetitions until a calibration batch reaches the target duration.
3. Exclude calibration and time a new batch with that repetition count. Retain
   the last result and compare it with calibration outside the measured region.
4. Normalize duration by repetitions to obtain **milliseconds per complete
   SIZE-item batch**. Repetition counts can differ between languages and runs;
   both perform the same work per batch. Raw counts and durations are retained.

The Gene clock has millisecond resolution. Python uses `perf_counter_ns`,
converted to milliseconds. Batching reduces Gene timer quantization; raising
the target improves resolution at the cost of longer runs. The target is a
calibration threshold, not a guarantee that the later measured batch takes
exactly that long. A zero measured duration is rejected.

Timing includes loops, function calls, allocation, and ordinary automatic
memory management during the batch. It excludes imports, input construction,
calibration, result verification, JSON report emission, and process teardown.
Neither counterpart disables its normal memory management. Each kernel runs
on one thread; the suite does not measure worker scaling or async scheduling.

`summary.json` includes ordered samples, median, minimum, maximum, and
nearest-rank p95 for each workload. With the default five samples, p95 is just
the maximum sample, not a well-estimated latency tail. The report's ratio is
**Gene median / Python median**: greater than one means Gene took longer.
There is no aggregate language score; these workloads are not weighted to
represent a particular application.

Whole-process wall times are reported separately and include startup, fixtures,
calibration, measured batches, and output. Since calibration chooses different
repetition counts, those wall times are not a startup benchmark or an equal-work
language-speed comparison.

## Evidence and limits

The output includes raw stdout/stderr for verification and every timed round,
runtime versions and executable hashes, workload source hashes, source copies,
Git revision/status/diff, OS/architecture, machine label, and timing parameters.
Executable and workload hashes are checked again before publishing the summary.
Untracked benchmark source is preserved even when absent from `git diff`.

Use an idle machine, run no compiler/profile concurrently, inspect sample
spread, and compare multiple sizes. Repeated samples from one Gene executable
do not establish build-to-build stability. Run a separately rebuilt release
binary before attributing small differences to a runtime optimization.

This suite compares the installed implementations, including native
standard-library routines used by Python and Gene. It does not establish
Harness end-to-end latency, durable filesystem performance, HTTP throughput,
long-running memory stability, hostile-code isolation, or production readiness.
Use the application probes and lifetime/service qualification for those claims.
