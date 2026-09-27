# Mixed ownership under cancellation — 2026-09-26

This is macOS arm64 ORC evidence, not promotion of the native-app profile.
The compiler is Nim 2.2.4. AtomicArc retirement and native Linux timing remain
separate gates.

## Closure capture regression

The stable-capture optimization copied reference-bearing values into detached
capture scopes. A stable binding to a mutable object can later hold the
closure: object → closure → copied scope → object. That cycle does not retain
the activation Scope, so activation retirement never sees it. The runtime now
copies only immediate, Str, or Sym slot values. Every other captured value
uses the existing capture-by-reference and retirement path.

The new RC regression fails on `2439442`: after 30 calls, Cell, list, map,
node, and combined graph cases retain 37, 64, 65, 66, and 135 managed Values.
The repaired build returns to baseline for all five, plus a shallow-frozen
container holding a Cell and a captured function holding a Cell. A retained
Cell closure stays callable and returns that same Cell.

## Cancellation evidence

The shared `mixed_graph.gene` fixture creates fresh
List → Map → Node → Cell → Function → Scope graphs. Its cancellation child
parks Tasks on a channel, a timer, and a nested Task, then cancels and joins
them. It checks that each ensure block runs once, that a graph retained across
the batches stays callable, and that dropping it returns to the pre-control
managed count. Checkpoints also require empty runnable/waiting Fiber queues,
zero retained I/O bytes, zero cleanup leases, and zero readiness waits.
Queue counts exclude the currently executing Fiber.

The HTTP cancellation child now holds that graph in both request handlers.
This exposed a server defect: `nativeTaskCancel` assigned a terminal outcome
without unwinding the handler Fiber, so aborted uploads skipped ensure.
The server now requests scheduler cancellation and tracks handler/read Tasks
until their cleanup settles. Requested cancellation is an expected cleanup
outcome; failures, panics, and cancellation of close Tasks still fail cleanup.
Focused HTTP regressions check truncated uploads, forced shutdown, and a
deadline-cancelled Gene response reader.

The ten-child lifetime profile returned `probe_pass`. Its instrumented binary
SHA-256 was
`7f464e079911c9c2d37b140158771df7d70af27948bfbaeb04b39fe1bd816162`.
Every per-class count matched its warm baseline at batches of 1, 100, 1,000,
and 10,000, with zero native roots and the required zero Task/I/O counters.

| Child | Warm and final managed Values |
| --- | ---: |
| Eval/failure | 881 |
| Witnesses | 822 |
| Type cancellation | 794 |
| Mixed cancellation | 929 |
| Partial selections | 891 |
| In-process service | 866 |
| HTTP cancellation with mixed graphs | 1,044 |
| Scalar generations | 824 |
| Type/protocol/impl generations | 824 |
| Discarded/failed generations | 826 |

The mixed child ran 33,603 parent and 11,201 nested cleanups. The HTTP child
ran 22,402 handler cleanups. Retained Module, function, and instance controls
passed. Both cancellation children also passed AddressSanitizer with no
reported memory errors through 1,301 iterations each. The sanitizer's leak
detector was disabled; the separate RC counters are the managed-leak oracle.
The deadline-cancelled response-reader regression also passed ASAN with its
Cell/closure identity check and exactly one ensure execution.

Reproduce with:

```sh
rtk nimble leakcheck
rtk proxy python3 tests/profiles/native-app/run.py --probe-blocked --workload lifetime
```

## Service soak

A short release/RC SERVICE check passed at 30 requests/s: p95 5.78 ms,
55 ms maximum heartbeat gap, zero managed-value slope, and completed cleanup.
Its binary SHA-256 was
`cafa3db629f1cba31189be3cd888360a26672dee9915ff2cc01e68660cbacc06`.
The two-hour run remains pending; no multi-hour qualification follows from
this short check.
