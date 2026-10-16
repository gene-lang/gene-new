# Native exec milestone evidence

Both platforms pass all 44 frozen performance gates. The detailed stage report
and verification matrix are in [exec-milestone.md](../../../docs/reports/exec-milestone.md).

## Captures

| Files | Meaning |
| --- | --- |
| `macos-summary.json`, `macos-gates.json`, `macos-metadata.json` | Final paired macOS ARM64 matrix. |
| `linux-arm64-summary.json`, `linux-arm64-gates.json`, `linux-arm64-metadata.json` | Final native Linux ARM64 matrix. |
| `macos-extra.json`, `linux-arm64-extra.json` | Optional settings, whole idle-workload CPU, Bash external batches and cold CLI. |
| `*-options-paired.json` | 200 rotated, paired samples each for default/dir/env launch. |
| `*-concurrency-*.json` | Three trials of file/short-command responsiveness with 32/64 long children, plus a slow binary consumer. |
| `profile-*-final.sample.txt.gz` | Final macOS profiles; main-thread and idle-worker samples must be interpreted separately. |
| `macos-v1-*`, `profile-*-v1.sample.txt.gz` | Retained first capture, whose stdin throughput missed its gate. |
| `verification-logs.tar.xz` | Test/build logs, including failures and their resolution. |

The summaries retain every timed sample. Per-process stdout/stderr captures
remain under `tmp/exec-milestone/mac-qual-v2`, `mac-extra-v2`, and
`linux-arm64/{qual-final,extra-final2}`. They are not duplicated here. The v1
capture remains under `mac-qual-v1`/`mac-extra-v1`.

## Provenance and reproduction

The base revision is `78e1ee21`. The original working tree already contained
compiler/GIR lifetime fixes and other owner edits. Qualification ran before the
implementation was committed. Source snapshots therefore identify the measured
code more precisely than the base revision alone; unrelated edits were preserved.

`source-snapshots.tar.xz` contains `control-tree`, `m1a-tree` and `final-tree`
source/configuration snapshots. The archived final tree is the first measured
candidate. Apply `final-bytes-copy.patch` to that tree to reproduce the final
candidate. Current source digests and build/binary metadata accompany the report.
Supply each snapshot's `vendor` directory from the base checkout (a symlink is
sufficient). `sources/` contains the exact benchmark programs.

All performance hosts use Nim 2.2.12, ORC, `-d:release` and speed optimization.
The common instrumentation host is built once against each selected source:

```sh
nim c -d:release --path:SNAPSHOT/src --nimcache:CACHE \
  -o:HOST benchmarks/exec_clock_host.nim
cc -O2 -Wall -Wextra benchmarks/exec_child.c -o CHILD
cc -O2 -Wall -Wextra benchmarks/exec_reference.c -o NATIVE
```

On this Mac, C helper builds also use
`-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
Native CLI builds use `nim c -d:release --path:src --nimcache:CACHE -o:CLI src/gene.nim`.
Exact commands/platform qualifications are recorded in `provenance.json` and
the compressed build logs. Binary hashes are in each matrix's metadata/summary.

Run from the repository root with all compilation and validation stopped:

```sh
FINAL_CLI run benchmarks/run_exec.gene OUT CHILD NATIVE CONTROL_HOST M1A_HOST FINAL_HOST
FINAL_CLI run benchmarks/check_exec.gene OUT/summary.json OUT/gates.json
FINAL_HOST benchmarks/run_exec_extra.gene EXTRA_CONFIG_JSON 1 all
FINAL_HOST benchmarks/exec_options.gene CHILD 200 all
HOST benchmarks/exec_concurrency.gene CHILD 1 all
```

Output directories must be new. Extra configuration names the output directory,
child/workload paths, three named hosts and the control/final CLIs. Set `profile`
to true only where Apple's `sample` is available. The native reference stores
captured output; the pipe-output reference only consumes bytes, and does not
include Gene's additional adapter pipe.

## Qualifications and limitations

- The macOS host is an Apple M4 Pro, 14 CPUs, 48 GiB RAM, macOS 27.0.1. Native
  Linux runs in an isolated Colima VZ ARM64 VM with 4 CPUs and 8 GiB RAM and
  Ubuntu 24.04 userspace. These are machine-specific measurements.
- The first amd64/Rosetta runner misreported libc spawn errors. Its probe is
  retained, and its results are excluded from qualification. The native ARM64
  runner passed the compatibility checks.
- Linux source was transferred as an archive without `.git`; its metadata
  records that fact and an explicit source revision, rather than inventing a
  container commit. The source snapshots remain authoritative.
- Linux's GNU `time` package was added after an initial extra capture failed
  because the utility was absent. One parallel Linux release compilation hit
  the VM memory limit; its isolated retry succeeded.
- Numerical budgets were frozen after prototype smoke runs, before paired
  qualification, not before implementation. See `budgets.md`.
- Two broad-suite checks reference qualification scripts absent from the
  checkout and HEAD. They remain failures and are not counted as passes.
- macOS ASan uses `detect_leaks=0` because this runtime does not support leak
  detection. Linux native sanitizer/leak checks and the separate RC suite pass.
- Windows, an interactive Gene shell, submission-based timeout semantics, and
  uniform top-level/async descendant cleanup are outside this qualification.

The local runtime uses the `gene-exec` Colima profile and the explicit socket
`~/.colima/gene-exec/docker.sock`; the existing Docker default context was not
changed. Task-local runtime binaries are under `tmp/exec-milestone/runtime/bin`.
The completed qualification containers are stopped, with their files retained;
`docker start gene-exec-arm64` reopens the native runner using that socket.
