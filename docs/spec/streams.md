# Generators, Streams, and channels

**Status:** normative and implemented. Executable coverage: stream and bounded
channel suites in `tests/spec_runner.nim` and `tests/test_vm.nim`.

## Generator declarations

`^^generator` declares the execution kind of a `fn` or `message`:

```gene
(fn ^^generator count_to [limit : Int] : (Stream Int Never)
  (var n 0)
  (while (< n limit)
    (yield n)
    (set n (+ n 1))))

((count_to 3) -> $into []) # [0 1 2]
```

The marker is the ordinary sugar for `^generator true`. An absent marker or
literal false declares an ordinary callable; other values are declaration
errors. Names, return annotations, and caller expectations do not select
execution kind. A trailing `*` is optional. Constructors and fexprs cannot be
generators.

Calling a generator evaluates arguments, binds parameters, and evaluates
applicable defaults immediately. It returns a fresh Stream without entering the
body. Each pull resumes that invocation's saved state. Captured outer values
retain normal closure semantics; aliasing a Stream shares its cursor.

Executable `yield` requires a marker on its own enclosing callable. A nested
generator does not make its factory a generator, and quoted yield forms remain
data. Marked generators may omit their result annotation or contain no yield.
Fallthrough and `(return)` end production; `(return void)` is also permitted.
Other explicit return values are invalid. A final body expression is discarded,
including a Stream value; delegation uses `for ... yield`.

Known result annotations that exclude Stream are rejected during compilation.
Dynamic annotations retain normal runtime validation. Ordinary callables can
return existing Streams eagerly. Aliases, checked callable views, compiled
artifacts, and dynamic dispatch preserve the target's declared execution kind.
Replacing a callable selects the new definition; existing cursors keep their
original code and state.

## Generator messages and inheritance

Inherited direct messages, protocol implementations, and protocol default
bodies retain their execution kind and run with the actual receiver:

```gene
(type Numbers ^props {^limit Int}
  (message ^^generator values [] : (Stream Int Never)
    (for n in (count_to self/limit) (yield n))))
(type Child : Numbers ^props {})

(((Child ^limit 3) .values) -> $into []) # [0 1 2]

(type Shifted : Numbers ^props {^offset Int}
  (message ^^generator values [] : (Stream Int Never) ^^override
    (for n in (super .values) (yield (+ n self/offset)))))
```

An inheriting `impl ... ^^override` keeps omitted messages, including their
generator bodies. A replacement declares its own execution kind: using yield
still requires `^^generator`, while an ordinary Stream-returning body may
satisfy the same inherited signature. Generator kind is not an additional
dimension of callable signature equality. The ordinary override and
declaration-bound `Self` rules continue to apply.

## Types, errors, and partial consumption

`(Stream T E)` checks emitted items against T and ordinary producer-owned errors
against E, including cleanup errors raised during explicit close. An undeclared
ordinary failure produces one `ErrorContractViolation`; generated failures,
panic, and cancellation keep their existing classifications. A callable's
invocation `^errors` row covers creation/default evaluation, separately from E.
`peek` and `has_next` may run production and encounter its errors.

Cleanup runs only for scopes the generator entered. Closing before the first
pull does not execute the body. Closing after a yield unwinds active ensures;
any cleanup yields are discarded while unwinding continues. The first cleanup
failure wins. A cleanup failure does not replace an already propagating
producer or consumer failure.

`take` intentionally leaves a separately held upstream resumable after reaching
its limit. Close that original Stream when ownership ends:

```gene
(let stream (count_to 100))
(try
  (stream -> $take 3 -> $into [])
  ensure (stream .close))
```

## Stream and channel operations

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

## Backends and measurement

The VM supports named and anonymous generators, generator messages, and their
ordinary inheritance/dispatch paths. The web profile supports named generators
and generator messages with Stream result annotations, including protocol
defaults and inheritance. It explicitly rejects generator callbacks and async
generators. The VM rejects pulls that require asynchronous suspension; Streams
remain synchronous, with Task/Channel facilities available separately.

Generator definitions are excluded from scalar/native lowering. The generic
call path dispatches on the resolved callable's compiled kind. Any future
specialization must preserve argument/default timing, cursor identity,
lookahead, errors, and cleanup, and guard the callable/code identity it uses.

`benchmarks/bench_pipeline.nim` measures creation, first pull, long iteration,
lookahead, early cleanup, allocations, and retained memory. Run it with
`nim c -r -d:release -d:nimAllocStats -d:geneGeneratorStats --path:src benchmarks/bench_pipeline.nim`.
Allocation totals include scopes and adapters; the optional per-thread
generator counter separately counts continuation creation. Use these
measurements before choosing a new generator lowering.
