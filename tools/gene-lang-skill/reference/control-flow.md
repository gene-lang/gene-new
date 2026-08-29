# Control flow, errors, streams, tasks

Normative contract: `docs/spec/calls.md`, `docs/spec/streams.md`,
`docs/spec/concurrency.md`. Style contract: `docs/style.md` §"Conditional forms".
Everything below is probed.

## Conditionals

Compact `if` for expression-sized branches. Both results at the same indent,
condition alone on the opening line:

```gene
(if (< value low)
  low
  value)
```

One-sided conditions omit the else arm — `(if cond value)` yields `nil` on the
false path already. Guards with a body use `if_yes` / `if_not`, whose tails are
implicit sequences:

```gene
(if_yes user/active
  (events ~ push "activated")
  (events ~ push "queued"))

(if_not cached
  (var value (load))
  (save value)
  value)
```

Full clauses only when every branch does real work. Prefer `elif` over an `else`
whose sole expression is another `if` — it keeps dispatch chains at one indent:

```gene
(if ready
  (then
    (record "start")
    "started")
  (elif retryable
    (record "retry")
    "retrying")
  (else
    (record "skip")
    "skipped"))
```

`&&`, `||`, `!`, and `??` (absent-default) round out the boolean surface.

## Match

`match` may keep an explicit `(else nil)` — unlike `if`, a missing `else` is not
a nil default. Patterns destructure lists, maps, typed values, and enum payloads:

```gene
(match status
  (when Status/pending "pending")
  (when (Status/failed message) $"failed: ${message}")
  (else nil))

(match value
  (when [a b] (+ a b))
  (when {^a a} a)
  (when (User ^name n) n)
  (else nil))
```

## Loops

```gene
(for value in values …)          # over a list, stream, or range
(for [k v] in a_map …)           # map iteration yields pairs
(repeat index in count …)        # indexed
(while (> current 0) …)
(loop … (break))                 # unbounded
```

**`break` and `continue` take no arguments.** Carry a result out in a binding
instead. Early `return`, `break`, and `continue` are preferred where they remove
deep nesting.

## Checked errors

```gene
(try
  (checked_value (load))
catch ExampleError
  $"error: ${$ex/message}"
catch Any
  "unknown error"
ensure
  (close))
```

What follows `catch` is a type. The catch body reads the whole error through
`$ex`; use `catch Any` as the explicit catch-all. `fail` raises a recoverable
typed error; `panic` does not. Clause heads align
under `try` and their bodies indent once. See `reference/declarations.md` for
declaring an error type and a function's `^errors` row.

## Streams

Lazy pull cursors. `to_stream` opens, `into` closes:

```gene
(users
  ~ to_stream
  ; ~ filter (fn [u] u/active)
  ; ~ map (fn [u] u/name)
  ; ~ into [])
```

The same operations exist as functions taking the stream first —
`($map stream f)`, `($filter stream pred)`, `($take stream n)`,
`($into stream [])`. `each` lives only under the namespace:
`($stream/each stream f)`.

Message surface: `has_next` `peek` `next` `try_next` `close` `map` `filter`
`take` `into` `each` `to_pairs_stream`.

`peek`/`next` raise `EndOfStream` at exhaustion; `try_next` returns a tagged
result instead — `TryNext/exhausted`, `#(TryNext/value item)`, or
`#(TryNext/error err)`. `void` items are skipped. The first producer error is
terminal and propagates once.

A generator is a `fn` whose name ends in `*`:

```gene
(fn indexed_pairs* [items]
  (repeat index in items/~size
    (yield [index items/%index])))
```

Closing a suspended generator unwinds its `ensure` blocks once, in LIFO order.
Close is idempotent.

## Tasks

`scope` owns its child tasks: normal exit waits for them, error or cancellation
cancels and waits for cleanup.

```gene
(scope
  (var left_task (spawn (left)))
  (var right_task (spawn (right)))
  [(await left_task) (await right_task)])
```

`(spawn ^lane root …)` keeps thread-affine work off the worker lane. `Task`
messages: `cancel`, `detach`.

## Channels

Bounded FIFO queues — capacity is a **named** argument:

```gene
(var ch ($channel ^capacity 2))
(ch ~ send 1)
(ch ~ recv)
(ch ~ try_recv)     # TryRecv/empty or #(TryRecv/value payload)
(ch ~ close)
```

Close rejects future sends and lets buffered items drain before `ChannelClosed`.

## Actors

`Actor` is the type (operations with a receiver); `$actor` is the function
namespace (operations without one).

```gene
(fn handle [ctx, state, msg]
  ($actor/continue (+ state msg)))

(var a ($actor/spawn ^init (fn [] 0) ^handle handle))
(a ~ send 4)
((a ~ snapshot) ~ /state)     # 4
```

Messages process sequentially. `ask`/reply uses a one-shot `ReplyTo`, and
timeout or cancellation ignores late replies safely. Channel and actor sends
enforce `Send` on the payload.

> Concurrency is experimental: cooperative scheduling by default, with an
> optional bounded worker lane in `--mm:atomicArc --threads:on` builds.
