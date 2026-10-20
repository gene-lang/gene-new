# Task and actor contract

**Status:** normative and implemented. Executable coverage: structured-task,
bounded-channel, and actor suites in `tests/spec_runner.nim` and scheduler/actor
suites in `tests/test_vm.nim`.

- `scope` owns child tasks; normal exit waits, while error/cancellation cancels
  and waits for cleanup. Normal waiting does not consume task results or raise
  their stored failures. Detached tasks are explicit exceptions.
- The VM's first `await` consumes the task result, including a failed result.
  Repeating it through the same handle or an alias raises `RuntimeError`.
- `Task/join` waits without propagating the joined task's outcome. It returns
  `TaskOutcome/ok`, `error`, `panic`, or `cancelled`, does not consume the
  ordinary `await` result, and may be repeated. Cancellation of the joining
  task still propagates normally.
- `Task/done?` is a non-consuming readiness check. It stays true after the
  task's result has been consumed by `await`; it does not wait or inspect the
  outcome.
- Once task cancellation or policy expiry is observed, `return`, `break` and
  `continue` leaving its active cleanup cannot suppress the unwind or resume
  normal work. Recoverable failures leaving cleanup cannot replace that
  terminal reason either. Helpers may return normally, cleanup-local loops
  may break or continue, and local error catches still work. Ordinary errors
  retain their existing cleanup behavior, including suppression by an
  `ensure` return. Explicit stream close still reports producer cleanup errors
  through the Stream's error contract. A cancellation request arriving after
  successful completion does not change the completed outcome.
- Time/memory expiry uses the shared, bounded cleanup allowance described in
  [calls](calls.md#binding-an-invocation). Ordinary task cancellation acquires
  no new timeout by itself. Runtime-mandated owned-child settlement remains
  required when arbitrary Gene cleanup is truncated.
- Cancelling an `os/exec_async`, `exec_stream_async`, or `exec_stdio_async`
  Task requests subprocess termination. Its cancelled outcome is published
  after the direct child is reaped and its adapter-owned pipes/channel are
  closed, so `join` waits for that cleanup. If the child ignores termination,
  the adapter escalates to kill after a one-second grace period. A configured
  execution timeout uses the same bounded termination/reaping path. This
  contract covers the direct child, not arbitrary descendant process trees.
- `spawn ^lane root` enqueues and returns its `Task` before the child body can
  begin. `$runtime/require_root_lane` returns `nil` on that lane and raises the
  typed `RuntimeLaneError` everywhere else.
- Fibers of one lane are time-sliced. A fiber stops running at a suspension
  point (a wait on a task, channel, timer or I/O) or, once its instruction
  slice is spent, at the next function entry, `for` iteration, backward loop
  jump or `continue`. It is not descheduled anywhere else, and a requested
  cancellation is delivered only where it stops. Code that neither calls a
  function written in Gene nor loops is therefore atomic with respect to the
  other fibers of its lane: `(queue/.get .push item)` cannot interleave with
  a `(queue .swap [])` elsewhere. A sequence that calls a Gene function or
  loops between a read and its update has no such guarantee, and neither does
  anything shared with a worker lane, which runs in parallel.
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
