# AsyncReader admission and upload borrowing — 2026-09-26

This records experimental macOS arm64 evidence. It does not promote the
native-app profile or qualify native Linux or AtomicArc generation retirement.

The scheduler owns one pending protocol-read admission per receiver and the
owned Client's exclusive upload borrow. Every dispatch of the canonical
`gene/io` `AsyncReader:read` uses this admission, including Gene implementations,
held messages, dynamic sends, pipelines, and inherited protocols. A pending
read refuses upload admission; an upload refuses caller reads with `IoBusy`.
No new Gene syntax or protocol methods are required. Read implementations
return their Task at admission and perform asynchronous work inside it.

Native adapters still enforce their physical lifecycle and shared-handle
exclusion. The protocol guard identifies the Gene receiver; custom convenience
APIs and distinct values aliasing a backend must enforce that backend's policy.
Server request bodies already use lifecycle-backed pipe readers.

Client cancellation requests scheduler cancellation of a Gene read Task and
retains the borrow and cleanup lease until its ensure/child cleanup settles
and the transport retires. Admission failure releases acquired borrows.
Completed reader/Task pins retire on the root lane, outside the scheduler lock;
worker publication supports AtomicArc. `gc_stats/io_read_guards` exposes live
records, and cancellation-profile checkpoints require it to be zero.

Coverage exposed three adjacent defects: bound protocol messages were published
using declaration-only fields; a running root Task could cancel itself into a
terminal outcome before cleanup; and `super` lost its nominal parent in task
and control-flow sub-bodies. These are repaired, with focused regressions.
Parent reads continue the existing admission rather than opening a second one.
The spec regression exercises two independently instantiated parent types.

Reproduce with:

```sh
rtk nimble test
rtk nimble spec
rtk nimble leakcheck
rtk nimble threadcheck
rtk proxy python3 tests/test_owned_http_client.py --asan -k custom_reader
rtk proxy python3 tests/profiles/native-app/run.py --gene tmp/gene-read-borrow-profile --probe-blocked --report tmp/read-borrow-profile.json
```

## Verification

The owned-Client suite passes all 41 cases under AtomicArc and 40 under ORC
(the worker-pool case is skipped). All five applicable custom-reader cases
pass ASAN. The custom-reader RC test returns to baseline with zero guards.
All four final gates pass: `nimble test`, `nimble spec`, `nimble leakcheck`,
and `nimble threadcheck`. The broad gate includes 39 wasm ABI cases against
the existing tracked artifact; it does not rebuild or qualify new wasm code.

The full profile reports SCRIPT `pass` and CLI, SERVICE, DATA, and LIFETIME
`probe_pass`. The release/RC binary SHA-256 is
`8cb5e0164e844f94e84f248e11e3fd6fe8d5b9512b9c392c3262f7365020b9ed`.
SERVICE served 1,800 load requests at 30/s, p95 5.69 ms and p99 9.10 ms,
with a 54 ms maximum heartbeat gap, managed growth 0 (995 early/late
minimum), and graceful shutdown with zero cleanup Tasks, leases, resources,
and retained I/O bytes.

The separately built lifetime binary SHA-256 is
`af0cdfcd7494c7b9e6c762f56ebefd1ddaa283245f55d97a4d6eadb83c840088`.
The ten children retain their warm per-class counts through batches of
1, 100, 1,000, and 10,000. Baselines are 881/822/794/931/891/866/1046/824/824/826
(eval, witnesses, Type cancellation, mixed cancellation, selection, service,
HTTP cancellation, scalar generations, rich generations, failed generations).
Both mixed and HTTP cancellation report zero read guards at every checkpoint,
along with their existing zero queue, byte, lease, and readiness checks.
Retained Module/function/instance controls pass. Report:
`tmp/read-borrow-profile.json`, recorded against parent revision `b7057b1`
with the continuation worktree marked dirty.

The prior cancellation-repaired binary's two-hour soak is independent and
still running; see [the cancellation audit](native-app-2026-09-26-cancellation.md).
The earlier baseline's passing two-hour result does not qualify this new build.
