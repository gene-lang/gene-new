# Stream and channel contract

**Status:** normative and implemented. Executable coverage: stream and bounded
channel suites in `tests/spec_runner.nim` and `tests/test_vm.nim`.

- Streams are lazy pull cursors. `has_next` is false at exhaustion;
  `peek`/`next` raise typed `EndOfStream`.
- `void` items are skipped. Generator `return` terminates without yielding a
  return value; natural fallthrough is equivalent.
- The first producer error is terminal, closes owned upstream resources once,
  and propagates once. Later pulls observe exhaustion.
- Closing a suspended generator unwinds `ensure` blocks once in LIFO order.
  Close is idempotent and preserves the first cleanup error.
- A naturally exhausted `take` detaches from its upstream so normal loop
  cleanup leaves that upstream resumable. Early close/break/error closes it.
- `try_next` returns `TryNext/exhausted`, `#(TryNext/value item)`, or
  `#(TryNext/error err)` — a tagged result that distinguishes end-of-stream,
  pulled item, and producer error without raising.
- Channels are bounded FIFO queues. Close rejects future sends and permits
  buffered draining before `ChannelClosed`.
- `try_recv` returns `TryRecv/empty` or `#(TryRecv/value payload)`, preserving
  empty, `void`, `nil`, and ordinary payloads as distinct states.
