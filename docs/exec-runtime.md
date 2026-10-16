# Native command execution

The public API is documented in [stdlib.md](stdlib.md#files). macOS and Linux
share three small native components below the VM:

| Component | Responsibility |
| --- | --- |
| `process_launch.{nim,c,h}` | Child-only cwd, effective-PATH lookup, argv/env ownership, spawn/fork, descriptors, exit observation, signals and the single final reap. |
| `process_io.nim` | Nonblocking stdin/stdout/stderr transfer, bounded capture, partial writes, final output, timeout and cancellation cleanup. |
| `native_wake.{nim,c,h}` | Leased, coalescing notifications targeted to an owning runtime lane. Also used by native ingress. |

`stdlib.nim` retains argument validation, result maps, Task/channel integration
and terminal policy. `build.nim` and the CLI's parallel build launcher use the
same process handle. Other process users and Windows retain their existing
backends.

## Ownership and notification

An async call snapshots its strings, explicit relative directory and nonempty
environment overlay into owned native buffers. A raw linked queue transfers
that request to one process-monitor thread. The monitor constructs, uses and
destroys its ProcessHandle, ProcessPump and Nim strings on that same thread;
GC-managed objects are never transferred from a scheduler heap to the monitor.

The monitor advances each stream by at most 256 KiB per visit, in chunks up to
64 KiB. It retains partial input and output buffers across readiness waits.
Writable interest exists only while bytes are pending; EOF removes readable
interest. A full destination pipe cannot block another stream, child, deadline
or cancellation. A burst admits at most eight new requests before servicing
existing children again.

Captured execution owns its existing process group. Async inherited-terminal
children use the same monitor, with a separate serialized handoff queue. A
synchronous inherited handoff retains its direct blocking caller and signals
the monitor when it releases the shared terminal lock. Queued handoffs can be
cancelled without acquiring the terminal. File jobs use the existing worker
pool; no native async process occupies one of those workers for its lifetime.

Producers publish native line buffers or completion fields before signalling
the owning lane. Pending scheduler records hold the Gene Values and application
state. Only that lane constructs Gene strings/maps, delivers channel messages,
settles Tasks and releases pending owners. A producer has a separate wake lease
that survives publication of the final completion flag, so it can safely signal
even if the scheduler has already freed the job context.

The wake registry supports multiple applications on one OS lane. A wait pins
the matching endpoints, polls them, drains coalesced bytes, and releases its
snapshot without generating another notification. Native-ingress producers
can signal a weak key under the registry lock; retiring an endpoint cannot
leave a foreign producer holding an unleased descriptor.

The scheduler distinguishes total pending native work from work that requires
polling. Notified work keeps the scheduler alive without forcing a periodic
poll. Global classification transitions wake runtime lanes (including a lane
waiting for the last operation elsewhere), timer waits return to their
outer predicates after notification, and root channel receives use the same
contract. Existing file, TCP, HTTP and terminal adapters retain polling where
needed. Local `$io/pipe` adapters also notify: otherwise their per-chunk
completion poll would remain a throughput limit for exec's binary streams.

## Exit and cleanup

macOS uses a kqueue process event; Linux attempts `pidfd_open`. A failed or
unavailable exit registration falls back to bounded, per-owned-child status
checks while pipe readiness and cancellation remain event driven. The monitor
does not install a process-wide `waitpid(-1)` reaper.

`waitid(..., WNOWAIT)` observes status without releasing the PID. Cancellation
or timeout sends TERM, allows up to one second for the leader, and sends the
final KILL before reaping. Group cleanup includes descendants even if the
leader has already exited. A native registry reader pins its signalling
authority; retirement clears the slot and waits out old readers before the
owner consumes exit status. A reaped/closed handle never signals or consults
its old numeric PID again. Normal successful exit does not kill the group.

The embedding host must leave owned children waitable: launching with SIGCHLD
ignored or `SA_NOCLDWAIT` is rejected. Other components must not reap these
children. A competing global reaper would invalidate PID ownership. The shared
launcher never changes the parent's cwd or environment to prepare a child.

Shutdown registration happens when the native module initializes, before any
async request can race with exit. Shutdown closes launch admission and allows
up to one second for in-flight spawn/registration handoffs before sweeping the
group registry. A late registration sees the closing state and kills its group.
The same handoff applies to the captured-group signal handler.

Absent-PATH lookup follows libc's platform policy: Darwin's `_PATH_DEFPATH`,
and glibc's `CS_PATH` obtained through `confstr`. They are not interchangeable;
even the directory order can differ. See the [Apple launcher source](https://github.com/apple-oss-distributions/Libc/blob/main/sys/posix_spawn.c)
and [glibc lookup source](https://github.com/bminor/glibc/blob/master/posix/execvpe.c).

`posix_spawn` uses child chdir file actions where supported. The fallback
prepares all data before fork, blocks signals across fork, resets caught
handlers in the child, then uses only native async-signal-safe operations
before `execve`. Its error pipe reports launch errors to the parent. Scripts
without a shebang require an explicit interpreter on both platforms.

Two existing distinctions are retained: top-level synchronous capture cleans
up only its child, whereas async/fiber capture owns a group; async timeouts
begin after dequeue and before launch, whereas synchronous timeouts begin
after launch. These are not unified by the monitor refactor.

## Qualification

`nimble execTest` runs the standalone launcher, I/O, wake and public exec suites.
They are separate executables because some double as child fixtures. The normal
test task includes them, and `nimble threadcheck` includes exec under AtomicArc.

Linux test builds with `-d:geneExecTests` accept
`GENE_TEST_EXEC_EXIT_BACKEND=auto|poll`; the value is read once at initialization
and other values fail. Production builds ignore it. `-d:geneExecForceFork`
requires `geneExecTests` and exercises the launch fallback. Lifecycle counters
and controlled registry-reader/spawn probes exist only in test builds.
`geneExecTinyBudget` also requires `geneExecTests`; it forces final-output
draining across fairness yields. Nim-only test controls pause submissions or
inject one enqueue failure to verify snapshot ownership and rollback.

The Gene workload/orchestrator files are `benchmarks/exec_workloads.gene` and
`benchmarks/run_exec.gene`. `exec_clock_host.nim` injects an identical nanosecond
clock into preserved old/new VMs. `exec_reference.c` independently implements
native launch/I/O/wait, and `exec_child.c` supplies deterministic child work.
Build before measuring, rotate executable order, retain raw samples and source
provenance, and report forced fallback and cold startup separately. Native
direct-pipe measurements do not include Gene's additional adapter pipe.
