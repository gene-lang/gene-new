# Selectors, collections, and streams

**Status:** detailed design reference and rationale. The implemented contracts
are [calls](../spec/calls.md), [streams](../spec/streams.md), [nil-void](../spec/nil-void.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 5. Selectors

Selectors are the general navigation/transformation abstraction.

```gene
/user/name          # selector literal
user/name           # apply selector to lexical user
(select user name)  # explicit selector construction
```

Inside selector context, bare names are static segments. They are not resolved from lexical scope.

```gene
(select user name) # static path: user -> name
```

Use `%` to insert lexical values or stages:

```gene
(select user %field)
(select users %to_stream %($filter /adult) name)
```

Rules:

```gene
user       # static segment named user
0          # static index segment
-1         # negative index segment
%field     # evaluated lexical value used as dynamic key/index/stage
%(expr)    # evaluated expression used as dynamic key/index/stage; long form only
```

Short slash syntax permits only simple static segments, numeric indices, and `%name`:

```gene
/users/0/name
/users/%i/name
```

Access paths also permit `.message` send segments. A send segment applies the
message to the value produced by the previous path segment:

```gene
users/.size        # (users .size)
users/%i/.to_html  # ((users/%i) .to_html)
```

A path send is introduced by `/.` (or `/?.` for an absence guard). It is a
zero-argument send applied to the value produced by the preceding segment:

```gene
(xs .size)    # ordinary send
xs/.size      # the same zero-argument send in a path
```

Complex selector stages must use long form:

```gene
(select users %to_stream %($filter /adult) name)
```

not:

```text
/users/%($filter /adult)/name # invalid short syntax
```

That spelling is a read error, not merely discouraged: `%(` ends the symbol
lexeme, so a bare `%` segment would otherwise produce an unquoted empty
symbol *and* silently swallow the following form. `(!= xs/%(- i 1) "\n")`
would read as a three-argument `!=` whose second argument is the index
expression — a wrong program that raises nothing.

`%props`, `%body`, `%meta`, `%declarations`, `%to_stream`, and `%to_pairs_stream`
are not magic selector tokens. They are ordinary functions used as stages — the
collection operations among them are generic functions (§6.2) — and the
`%` escape resolves them the way any name resolves: a standard-library stage is
reached as `%$props`, a stage you defined yourself as `%my_stage`.

```gene
x/props                    # static field/key named props
x/%$props                  # use the standard-library props function as a stage
x/%$props/%$to_pairs_stream
module/%$declarations
users/%$to_stream/name
users/%my_stage            # a stage from the enclosing scope
```

A selector captures evaluated `%` stages like a closure captures lexical bindings.

Static lookup:

- on `Node`: read prop/body/index-like member according to segment type;
- on `PropMap`/`Map`: read key;
- on `List`: integer segment indexes the list. Computed list behavior such as
  `size`, `empty?`, `first`, and `last` is reached with sends, including path
  send segments like `xs/.size`, not selector property lookup;
- on namespace/module values: read exported binding/member;
- missing lookup returns `void`.

Selectors do not automatically project over `List` elements. Use `%to_stream` or an explicit stream/list mapping stage for element projection:

```gene
users/%$to_stream/name # stream of names, skipping void results
users/name            # list member/key lookup; not element projection
```

If a selector stage receives a `Stream`, static lookup is mapped over each yielded item. `void` results are skipped.

If an evaluated `%` segment is callable, it is used as a stage. If it is not callable, it is treated as a dynamic key/index. This means a callable value cannot be used as a dynamic key through bare `%x`. Use explicit map access or an explicit key wrapper if that case is needed:

```gene
(m .get x)            # unambiguous dynamic key lookup
(select m %($key x))    # optional library wrapper: force key/index use
```

Static symbol/string/index segments and explicit `key` wrappers are pure
selector data. Callable stages, call-stage nodes, and `~message` path segments
are executable/effectful. Effectful selectors are not serializable and must not
be admitted to pure selector caches. Functional update APIs such as `$assoc_in`
and `$update_in` accept only pure scalar/key segments and reject executable
stages before invoking them.

Selector chains propagate `void`:

```gene
user/missing/name # => void
```

`nil` is different: if a key exists and stores `nil`, selector access returns `nil`.

Long-form selectors may opt into explicit missing-value handling:

```gene
((select ^default "unknown" user name) data) # returns default if any segment is missing
((select ^strict true user name) data)       # raises SelectorMissing
```

`^default` is evaluated when the selector is constructed and is returned only
for missing/`void` lookup. Present `nil` is still returned as `nil`. `^strict
true` takes precedence over `^default`.

`SelectorMissing` is a typed `MatchError` carrying the failed `^segment` and a
human-readable `^message`.

---

## 6. Streams, generators, and parser streams

A stream is a stateful, pull-based, lazy cursor.

```gene
(Stream item err)
```

`item` is the yielded item type. `err` is the recoverable error type that may occur while producing items.

```gene
(Stream User Never)       # user stream that cannot fail except end-of-stream
(Stream Node ParseError)  # parser stream producing nodes and parse errors
```

`EndOfStream` is not an item. It is a standard read error from `peek`/`next`.
`has_next` returns `false` at exhaustion; it may raise the stream's producer
error `err`, but it does not raise `EndOfStream`.

```gene
(protocol (Stream item err)
  (message has_next [] : Bool
    ^errors [err])

  (message peek [] : item
    ^errors [EndOfStream err])

  (message next [] : item
    ^errors [EndOfStream err])

  (message close [] : Nil
    ^errors [err]))
```

`Never` contributes no errors. Error rows flatten and deduplicate.

`try_next` (on `Stream`) is a non-raising pull alternative: it returns a tagged
`TryNext` result that distinguishes exhausted, value, and producer error
without throwing. The `TryNext` enum follows the `TryRecv` pattern:

```gene
(enum TryNext [T E] exhausted (value T) (error E))
```

```gene
(match (s .try_next)
  (when TryNext/exhausted void)
  (when (TryNext/value v) v)
  (when (TryNext/error e) (raise e)))
```

A function containing `yield` is a generator and returns a `Stream`.

```gene
(fn users* [users : (List User)] : (Stream User Never)
  (var i 0)
  (while (< i users/.size)
    (yield users/%i)
    (set i (+ i 1))))
```

Rules:

- each yielded value must type-check as the stream item type;
- yielding `void` skips the item (an iteration produces no value; this is
  not a way to leave the generator — see "Generator semantics" below);
- falling off the end closes the stream;
- no public `EOS` value is yielded;
- `peek` may buffer one item;
- `close` is idempotent, drops buffered state, stops future pulls, and closes
  the upstream stream if one exists.

### 6.1 Generator semantics

Generators are **one-way yield-only** in MVP: a generator function yields
items outward via `yield` and never receives values back. There is no
generator-side counterpart that suspends on input. A function that
needs a producer/consumer pair between two coroutines uses a callback,
channel, or future — not symmetric yield.

```gene
(fn prefix [s : (Stream T Never), n : Int] : (Stream T Never)
  (var taken 0)
  ($take s n))                   ; → (Stream T Never), pulls from s lazily

(fn pump [s : (Stream T Never), out : (Channel T)]
  (for x in s                    ; one-way: pull out of s
    (out .send x)))
```

`yield void` and an empty `return` are distinct:

- `(yield <value>)` — emits the value as the next item. If the value is
  `void`, this iteration produces no item; execution continues at the
  next `yield` (or the end of the function).
- `(return)` or `(return void)` — leaves the generator immediately without
  producing an item. A non-`void` generator return value is a compile-time
  error in the MVP because `(Stream T E)` has no out-of-band result channel.
  Ordinary functions may use `(return value)` to leave the nearest function;
  structured cleanup (`for` close and pending `ensure` blocks) still runs.
- `(yield)` with no value is a compile-time error — the generator item
  type requires a value.

`close` semantics:

- `Stream/close` is idempotent. The first call drops buffered state,
  discards generator frames, marks the stream closed, and propagates
  the close to its upstream source (if any). Subsequent calls are
  no-ops.
- A bounded helper like `take` detaches from its upstream as soon as it emits
  its requested count. Its later local close (including `for` cleanup after
  normal exhaustion) does not close upstream, so a second consumer can resume
  pulling. Explicit close, loop `break`, producer error, or cancellation before
  the count is reached still closes upstream exactly once. A zero bound
  detaches during construction; closing it before a pull leaves upstream open.
- `filter`, `map`, and other stream combinators all close their upstream
  source when closed (directly or transitively) — see `Stream/close`
  in the protocol above.
- Generator streams retain their full VM continuation. `close` cancels and
  unwinds that continuation, running pending `ensure` blocks once in LIFO
  order, including cleanup reached through saved helper/loop frames. Cleanup
  continues after a cleanup error; the first cleanup error is reported and
  later cleanup failures are suppressed when no structured suppressed-error
  representation is available.

Pull-side error model (`Stream T E`):

- `has_next` may raise `E` (the producer error type), but **never**
  raises `EndOfStream`. At exhaustion `has_next` returns `false`. A
  consumer that wants to detect a producer error against an exhausted
  stream pulls `next` once more and matches on `EndOfStream` vs `E`.
- `peek` and `next` may raise either `EndOfStream` (signalling
  exhaustion — present if buffered or produced by the upstream `E`
  column) or `E`. After `peek`/`next` raises `EndOfStream`, `has_next`
  returns `false` for any subsequent read.
- A consumer that catches `E` and asks "is there more?" gets `false`
  once the producer has finished or signalled exhaustion.
- A producer error is terminal. The failing producer expression runs once, the
  stream closes its owned upstream resources, and the first pull propagates
  `E`. Later `has_next` returns `false`; later `peek`/`next` raise
  `EndOfStream` rather than replaying the producer or its original error.

These rules combine into a simple consumer idiom:

```gene
(while true
  (match (try_ok (s .next))
    (when (Ok v)   (yield_handler v))
    (when (Err e)  (if (== e (EndOfStream)) (break) (handle e)))))
```

### 6.2 Generic collection operations

`to_stream`, `to_pairs_stream`, `map`, `filter`, `take`, `into`, and `each` are
**generic functions**: one exported name per operation, reached as `$map` and
friends through the `gene` root and selected from `gene/stream` (§15.6),
dispatching on the runtime type of its receiver (its first argument). The
mechanism is the message system, not a second dispatch layer: the operation's
name is one message identity shared by every type that serves it, the type's
type-direct message is the method, and the exported function is that message
identity in value position — the same dispatch a `Self:map` value performs
(§3):

```gene
(xs .map f)     # bare send: resolves map in xs's message table
($map xs f)      # the exported function: applies to its first argument
(var m Self:map) # the message value; (m xs f) dispatches identically
```

The dispatch is the ordinary receiver-first rule (§3), so there is no lexical
fallback: a type without the method raises `MessageError`, and a user type
joins the generic by declaring the message — after which `$map` dispatches to
it like any other receiver. The function spelling is an ordinary callable; it
is the `Self:map` message-value spelling that is `Callable` rather than `Fn`
(§3). A direct head application `(Self:map xs f)` is the send `(xs .map f)`.
This kind of generic function is
receiver-dispatched; the type-parameterized functions of §7.4, whose type
parameters are inferred at call sites, are a different mechanism.

The `Stream` methods keep the lazy contract of §6 and the close/detach rules
of §6.1:

```text
map              : (Stream A E, Fn [A] B) -> (Stream N(B) E)
filter_map       : (Stream A E, Fn [A] B) -> (Stream (B without Void) E)
filter           : (Stream A E, Fn [A] Bool) -> (Stream A E)
take             : (Stream A E, Int) -> (Stream A E)
into             : (Stream A E, target) -> target
```

The eager kinds answer in their own kind:

| call       | List        | Map                        | Set | Stream       |
| ---------- | ----------- | -------------------------- | --- | ------------ |
| `map f`    | List, eager | Map over values, keys kept | Set | Stream, lazy |
| `filter_map f` | List, eager | Map over values, surviving keys kept | Set | Stream, lazy |
| `filter p` | List, eager | Map over values, surviving keys kept | Set | Stream, lazy |
| `take n`   | List        | —                          | —   | Stream       |

`to_stream` converts an eager kind to the lazy tier — `List`, `Set`, and
`Range` yield item streams (§8.1) — and is the identity on a `Stream`, so a
caller normalizing an unknown receiver into that tier need not first ask
whether it is already there. `to_pairs_stream` turns a `Map` into a stream of
`[K V]` pairs; a `Map` has no `to_stream`, because there is no item order to
invent for one. `into` collects an iterable receiver into the target
kind named by its argument: `($into s [])` builds a `List`, `($into s {})`
builds a `PropMap` from `[K V]` pairs. `each f` runs `f` on every item and
returns `nil`. Stream `each` and `into` close their immediate source on
success or failure, preserving a primary failure if cleanup also fails.
`map` applies `N(void) = nil` and `N(v) = v` to every callback result. Lists
and streams preserve one output per input, maps preserve their keys, and sets
retain their ordinary deduplication. In the signature above, `N(B)` replaces
Void with Nil in the output element type. Output boundaries still check the
normalized value: a `(List Int)` cannot contain the resulting nil.

`filter_map` drops only void results, retaining nil, false, zero, and empty
strings. Raw map/prop writes of void still remove entries (§1.6); mapping has
already normalized its result before storage. A map's collection callback sees
the value; pair-wise work goes through `to_pairs_stream` or `for`.

For a finite sequence and a pure, total callback, eager mapping and fully
collecting lazy mapping produce equal data, including when the callback returns
void. Fusion must preserve intermediate normalization:
`map(map(xs, f), g) = map(xs, x => g(N(f(x))))` (mathematical notation).
Evaluation timing, side effects, partial consumption, and errors still follow
the eager or lazy evaluation contract. See `docs/spec/nil-void.md`.

The reader/parser pipeline should be stream-shaped:

```text
(Stream Char E)
→ (Stream Token LexError)
→ (Stream Node ParseError)
```

Whitespace, comments, and discarded forms can produce void. Parser producers
can omit these with `yield void`, or a transformation can use `filter_map`.
Ordinary `map` retains them as nil.

---
