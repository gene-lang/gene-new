# Stream and channel contract

**Status:** normative and implemented. Executable coverage: stream and bounded
channel suites in `tests/spec_runner.nim` and `tests/test_vm.nim`.

- Streams are lazy pull cursors. `has_next` is false at exhaustion;
  `peek`/`next` raise typed `EndOfStream`.
- Raw `void` emissions are skipped. `map` converts callback void results to nil
  before emission; `filter_map` explicitly drops them. Generator `return`
  terminates without yielding a return value; natural fallthrough is equivalent.
- The first producer error is terminal, closes owned upstream resources once,
  and propagates once. Later pulls observe exhaustion.
- Closing a suspended generator unwinds `ensure` blocks once in LIFO order.
  Close is idempotent and preserves the first cleanup error.
- A naturally exhausted `take` detaches from its upstream so normal loop
  cleanup leaves that upstream resumable. Early close/break/error closes it.
  Bounds are nonnegative Ints. A zero bound detaches during construction,
  without pulling; closing it before its first pull leaves upstream resumable.
- Mapping adapters acquire their upstream at construction. Close releases
  captured callbacks/arguments and closes an attached upstream even before
  the first pull. Lookahead caches one result without repeating callbacks;
  reentrant pulls are rejected. Map normalizes callback void to nil;
  filter_map and raw generator emissions skip void.
- Stream `each` and `into` close their immediate consumed cursor on success,
  callback/boundary failure, or cancellation. A cleanup error does not replace
  an already propagating producer or consumer error.
- Normal `to_stream` preserves Stream cursor identity, adapts List/Set/Range,
  and dispatches to a user type's type-direct conversion message. A conversion
  returns a Stream without pulling. Maps require explicit `to_pairs_stream`;
  scalar/nil inputs are not implicitly singleton/empty Streams.
- `try_next` returns `TryNext/exhausted`, `#(TryNext/value item)`, or
  `#(TryNext/error err)` — a tagged result that distinguishes end-of-stream,
  pulled item, and producer error without raising.
- Channels are bounded FIFO queues. Close rejects future sends and permits
  buffered draining before `ChannelClosed`.
- `try_recv` returns `TryRecv/empty` or `#(TryRecv/value payload)`, preserving
  empty, `void`, `nil`, and ordinary payloads as distinct states.
