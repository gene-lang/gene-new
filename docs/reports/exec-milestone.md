# Exec milestone 1

Status: implemented and qualified on macOS ARM64 and native Linux ARM64,
2026-10-15. All 44 performance gates pass on each platform.

The milestone adds child-only `^dir` and owned `^env` settings to all six exec
variants, shares their POSIX launch/lookup/status implementation, removes fixed
subprocess I/O sleeps, and moves async process lifetimes to one native monitor.
The API remains the existing `$os/exec*` family. See [the public contract](../stdlib.md#files)
and [runtime ownership design](../exec-runtime.md).

## Delivery stages

Separate stage reports are available for [M1a](exec-m1a.md) and [M1b](exec-m1b.md).

The original source/binary were preserved before implementation. A separate
launcher snapshot records the directory-isolation and environment work. M1a
keeps the worker-per-child architecture but uses readiness-driven pumping and
lane notifications. M1b uses one monitor for captured and inherited async
children, serializes terminal handoffs, batches native line publication, and
notifies local pipe-adapter completions. File/TCP/HTTP completion migration is
outside this milestone.

Shared correctness fixes are applied to both measured M1a and final snapshots:
non-consuming exit observation, signalling/registry retirement before reap,
shutdown registration handoff, literal filesystem path components, and wake
registration/lifetime races. M1a retains its worker limit and legacy pipe-adapter
completion polling so those architectural costs remain visible.

## Compatibility decisions

- The owner approved requiring a shebang or explicit interpreter on both
  platforms. Old macOS implicit `/bin/sh` fallback is removed.
- Synchronous top-level capture retains child-only cleanup; async/fiber capture
  owns a process group. Normal completion does not kill background descendants.
- Async timeout time starts after dequeue, before launch; synchronous timeout
  time starts after launch. Queue time remains excluded. Cleanup can take an
  additional one-second TERM grace period.
- A child already observed as exited retains its status and final output;
  forwarding to a still-blocked output destination remains subject to timeout.
- `^cwd` is not added. PATH strings prepend; `nil` removes; empty prefixes do
  not introduce an empty search component. Explicit shell commands still use
  the selected shell's quoting, expansion and pipeline-status semantics.

## Qualification method

The workload and orchestration are Gene programs in `benchmarks/`. An identical
Nim embedding host supplies a nanosecond clock to old and new VMs. A separate C
reference uses native spawn, matched argv/environment/stdio/group policy,
capture buffers and waiting. Binary pipe output is consumed without capture;
its direct native reference omits Gene's extra adapter pipe and value boundary.

Warm comparisons rotate native/control/M1a/final executable order across three
rounds and retain individual samples. Cold CLI, environment/directory options,
idle CPU, external Bash batches and profiles are separate captures. Bash runs
the external fixture, not a builtin `true`. No timed qualification overlaps
this task's compilation or test runs.

Sequencing deviation: the original control was preserved before coding, but
numerical budgets were fixed after prototype smoke runs, before paired
qualification. They must not be described as pre-implementation measurements.
The frozen gates are implemented in `benchmarks/check_exec.gene`; failed
captures and gate results are retained rather than silently adjusting limits.

The first macOS capture passed every gate except stdin-pipe throughput: its
8.84 ms median for 1 MiB was 18.4% of direct native throughput, below the fixed
20% minimum. Sampling the repeated stdin workload attributed 1,036 of 1,177
main-thread samples (88%) to `$binary/slice`, primarily Nim's per-character
string-slice loop. This is independent of process spawning.

The final follow-up replaces that loop with a bulk memory copy into an owned
Bytes result and makes range validation overflow-safe. It preserves the public
slice/write APIs, ownership, and write chunk sizes. The failed first capture and
its profiles remain evidence; subsequent measurements must pass the same gates.

## Platforms and runner findings

The host is an Apple M4 Pro with 14 CPUs and 48 GiB RAM. Nim is 2.2.12; release
measurements use ORC and speed optimization. This Mac's default SDK contains
stubs its installed linker cannot read, so native C validation uses the
installed macOS 26.5 SDK explicitly.

The installed local Colima runner supplies native ARM64 Linux (Ubuntu 24.04
userspace). Docker's existing default context was preserved. The initial amd64
Rosetta runner failed launch-error compatibility: a standalone libc probe
returned successful `posix_spawn` followed by exit 127 for an invalid cwd and
an unexecutable file. Native ARM64 Linux reports those launch errors correctly.
Rosetta results are not used for Linux performance qualification.

Windows keeps its existing process backend and is not performance-qualified
here. No claim of Windows runtime test coverage is made.

## Verification record

Focused coverage includes all six APIs at root and in tasks; environment/PATH
ownership and validation; directory isolation during overlapping launches;
literal symlink and dot components; scripts; exit-before-registration; separate
and truncated output; stdin EOF; blocked consumers; timers; idle task/channel
wait counts; queued handoff cancellation; 64 live children plus short exec/file
work; shutdown during registration; and controlled stale signalling authority.

The broader run has two unrelated missing-script failures:
`tools/qualify_inference_depth.py` and `tools/qualify_episode_depth.py` are absent
from the checkout and HEAD. The initial three native-build failures were caused
by the default SDK and passed after selecting SDK 26.5. These failures remain
in the evidence; the missing checks are not counted as passing.

## M1a and M1b results

These are medians in milliseconds for matched whole operations from a running
program, not isolated VM overhead. Each short row has 120 samples; bulk and
concurrency rows have 9, first-line rows 15. Percentiles and every sample are in
the [evidence directory](../../benchmarks/baselines/2026-10-15-exec/README.md).

### macOS ARM64

| Operation | Original | M1a | Final M1b | Native reference |
| --- | ---: | ---: | ---: | ---: |
| Capture, root | 6.217 | 1.162 | 1.166 | 1.147 |
| Capture, root task | 7.572 | 1.277 | 1.088 | 1.070 |
| Async capture | 7.566 | 1.324 | 1.030 | 0.973 |
| Inherited stdio, synchronous | 1.030 | 1.029 | 1.020 | 1.019 |
| First streamed line | 8.859 | 4.091 | 4.481 | 4.134 |
| Capture 1 MiB stdout | 19.775 | 1.392 | 1.286 | 1.233 |
| Capture 1 MiB each stdout/stderr | 64.565 | 1.929 | 2.221 | 1.312 |
| Pipe 1 MiB into stdin | 1671.763 | 35.879 | 3.339 | 2.118 |
| Read 1 MiB through stdout pipe | 50.125 | 23.762 | 3.084 | 1.874 |
| 64 concurrent 20 ms children | 77.335 | 66.550 | 42.174 | 40.850 |

### Native Linux ARM64

| Operation | Original | M1a | Final M1b | Native reference |
| --- | ---: | ---: | ---: | ---: |
| Capture, root | 5.789 | 0.458 | 0.357 | 0.245 |
| Capture, root task | 6.265 | 0.469 | 0.363 | 0.237 |
| Async capture | 6.345 | 0.447 | 0.378 | 0.251 |
| Inherited stdio, synchronous | 0.337 | 0.318 | 0.308 | 0.230 |
| First streamed line | 7.092 | 0.708 | 1.080 | 1.122 |
| Capture 1 MiB stdout | 11.960 | 0.918 | 0.805 | 0.661 |
| Capture 1 MiB each stdout/stderr | 60.709 | 1.780 | 1.463 | 1.160 |
| Pipe 1 MiB into stdin | 1539.444 | 38.607 | 2.319 | 0.911 |
| Read 1 MiB through stdout pipe | 45.034 | 25.160 | 2.101 | 0.644 |
| 64 concurrent 20 ms children | 52.227 | 46.304 | 36.710 | 33.821 |

M1a removes the fixed monitoring/delivery gap, but still holds workers for live
children and pays polling for pipe-adapter completions. Final M1b removes those
costs. Root captured latency improves 5.3x on macOS and 16.2x on Linux; async
capture improves 7.3x and 16.8x. Final synchronous inherited stdio has no repeatable
regression. The difference from native root-capture medians is about 19 µs on
macOS and 112 µs on Linux; this subtraction is not a separately isolated cost.

First-line absolute times include OS scheduling and idle transitions. The
matched native row is also several milliseconds on macOS. Notification and
idle-wait tests independently rule out periodic exec-only scheduler polling.

## Concurrency, optional settings and startup

Three supplemental trials submit 32 or 64 children sleeping 600 ms, then a short
child and a small file read. With 64 live children, median file latency falls
from 1239 ms to 3.09 ms on macOS and 1219 ms to 1.60 ms on Linux. Short-child latency
falls from 1252 ms to 36.0 ms and 1225 ms to 42.0 ms, respectively. M1a retains the
queue delay. The final monitor test records one monitor and at least 64 active
children. No native async process holds an exec worker for its lifetime.

A deliberately slow binary consumer receives all 1 MiB while unrelated short
commands progress: final short-command medians are 3.02 ms on macOS and 1.30 ms on
Linux. Cancellation, timeout and closed-consumer tests cover the corresponding
failure paths.

The idle workload includes warmup, 128 total child launches, and their CPU time;
it is not a measurement of a completely quiescent VM. Original/M1a/final wall
times are 8.15/8.10/4.05 seconds on macOS and 8.11/8.07/4.09 on Linux. CPU totals
(user+system) fall from 1.14 to 0.23 seconds on macOS and 0.90 to 0.11 on Linux.
The reduced wall time also reflects removing the 32-worker cap.

Paired, rotated launch-option measurements use 200 samples per setting. Median
paired differences for `^dir "."` and a small `^env` map are 9.4/34.0 µs on
macOS and -1.9/2.9 µs on Linux; the negative directory estimate is measurement
noise. These optional costs are separate from the default execution rows.

Cold CLI `eval nil` medians are 4.45→4.49 ms on macOS and 6.31→6.48 ms on Linux.
Cold-start optimization remains deferred. Bash's repeated external-command
batch comparison is recorded separately; it includes amortized shell startup
and is not a per-command latency distribution.

After the owned-byte-copy fix, the 6-second stdin profile completes 354 batches
of 16 MiB instead of 58. Byte slicing falls from 88% to about 14% of main-thread
samples. Remaining costs include I/O buffer copies/zeroing, protocol dispatch,
and scheduling; the report does not attribute those costs to spawning.

## Completed verification

| Coverage | Result |
| --- | --- |
| Public exec contract | 20 cases pass on macOS ORC/AtomicArc/ASan and native Linux; forced Linux poll also passes. |
| Native launcher | 16 cases pass, including fork fallback, cwd isolation, path precedence, script policy, shutdown and registry retirement. |
| Native process I/O | 10 cases pass with a tiny fairness budget; ASan/UBSan checks pass on macOS and Linux. |
| Lane notifications | 7 cases pass, including registration during a pinned wait and retirement; Linux sanitizer/leak checks pass. |
| Existing broad suite | 1718 pass; 2 missing-script failures described above. |
| Language specifications | 892 pass. |
| AtomicArc VM/worker/native-thread/I/O suites | 427/50/18/31 pass. |
| ORC lifetime suite | 90 pass. |
| Byte-copy follow-up | 15 data tests pass under ORC and ASan/UBSan; 31 AtomicArc I/O tests pass. |
| Harness persistent shell | 4 pass on each platform. |
| Linux build/selected CLI build suites | 10/3 pass, including both migrated callers. |
| Performance budgets | 44/44 pass on each platform; failed macOS v1 remains recorded. |

Apple's sanitizer runtime does not support leak detection, so macOS sanitizer
runs use `detect_leaks=0`; separate lifetime tests and Linux native leak checks
provide the additional evidence. Test builds reject invalid exit selectors;
the production Linux release ignores them. The fallback is functionally
qualified but retains bounded exit polling and is not included in event-driven
latency claims.

All nine acceptance items in the proposal are addressed: reproducible stage
reports; event-driven native waits/delivery; fixed numerical gates; progress
above 32 children; lifecycle/platform qualification; existing runtime/Harness
checks; separate M1a/M1b evidence; all-six-variant env/dir support; and directory,
lookup and build-caller isolation. The unapproved cleanup-context and timeout-
origin changes remain separate follow-ups. See the evidence README for exact
build commands, source snapshots, binary hashes and retained limitations.
