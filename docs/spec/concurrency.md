# Task and actor contract

**Status:** normative and implemented. Executable coverage: structured-task,
bounded-channel, and actor suites in `tests/spec_runner.nim` and scheduler/actor
suites in `tests/test_vm.nim`.

- `scope` owns child tasks; normal exit waits, while error/cancellation cancels
  and waits for cleanup. Detached tasks are explicit exceptions.
- Worker publication requires Send-safe captured snapshots. Runtime worker
  lanes may not allocate or release shared Gene heap objects unsafely.
- Channel and actor sends enforce `Send` independently of nominal message type.
- Actor `^type` is authoritative. Otherwise a statically typed handler message
  parameter is inferred; if unavailable, the resolved type is `Any`.
- Actors process messages sequentially. Ask/reply uses one-shot `ReplyTo` and
  timeout/cancellation ignores late replies safely.
- Supervisor failure delivery uses bounded FIFO retry state, bounded task
  publication, observable overflow/drop counters, and independent event and
  dead-letter channels. Original actor failure does not depend on notification
  delivery succeeding.
