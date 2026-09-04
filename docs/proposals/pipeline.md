# Sequenced value pipelines with `->` and `=>`

> **Status (2026-09-02): Accepted and implemented**
>
> This document specifies the `->` value pipeline and its per-item `=>`
> delimiter. `docs/design.md` defines `;` as head-folding reader sugar with no
> `_` slot behavior. This proposal does not change it.
>
> Pipeline examples use ordinary `gene` fences and are checked by the
> repository documentation contract.

## 1. Decision summary

Gene spells a left-to-right value pipeline with the reserved `->` token:

```gene
(a -> f c)
```

The stage receives the completed value of the preceding segment. With no
explicit slot, that value becomes the first positional argument:

```gene
(a -> f c)          # call shape: (f a c)
```

An exact `_` in the stage overrides the default position:

```gene
(a -> f _ c)        # call shape: (f a c)
(a -> f c _)        # call shape: (f c a)
(a -> f ^k _)       # call shape: (f ^k a)
(a -> _ c)          # call shape: (a c)
```

The comments say **call shape**, not semantic expansion. A pipeline guarantees
that `a` is evaluated first and exactly once. Directly rewriting the first
example to `(f a c)` would be wrong because an ordinary call evaluates its
callee before its arguments.

The pipeline is therefore syntax with compiler-enforced sequencing, not a
reader-only substitution into an ordinary call.

## 2. Motivation

`->` is introduced for value threading. It reads in data-flow order and
complements Gene's callable-first ordinary calls:

```gene
(source
  -> parse options
  -> validate schema
  -> save db _)
```

The intended flow is:

1. evaluate `source`;
2. call `parse` with that value and `options`;
3. call `validate` with the parse result and `schema`;
4. call `save` with `db` and the validation result.

The surface removes temporary names without weakening evaluation-order,
single-evaluation, error, or call semantics.

The explicit sequenced spelling and the pipeline spelling are equivalent:

```gene
# Explicit locals
(var parsed (parse_record source options))
(var checked (validate parsed schema))
(save db checked)

# Pipeline
(source
  -> parse_record options
  -> validate schema
  -> save db _)
```

The pipeline removes only the names. It does not remove either sequencing
edge or turn the source into an ordinary nested call.

## 3. Goals

- Make left-to-right data flow explicit and compact.
- Evaluate every threaded value exactly once.
- Guarantee that a stage's incoming value is complete before its callee or
  other arguments are evaluated.
- Support the common first-positional case without `_`.
- Support an explicit slot in the stage head, a positional argument, or a
  named argument value.
- Preserve ordinary Gene call behavior after the incoming value has been
  established: callee evaluation, named/positional argument order, spreads,
  type checks, checked errors, capabilities, and call-kind checks.
- Preserve the pipeline as source-visible syntax for formatting, diagnostics,
  quoting, and tooling.
- Reuse existing call, send, TCO, and backend machinery. Add only the internal
  syntax value kind needed to preserve stage boundaries, never a nominal
  user-facing `Pipeline` type or a pipeline execution object.

## 4. Non-goals

- Changing `;`, which remains head-folding syntax without placeholder
  substitution.
- Implicitly awaiting tasks.
- Implicitly catching errors or converting them to result values.
- Implicitly skipping `nil` or `void`; use `?.message`, `??`, or an explicit
  conditional.
- **Implicitly mapping a `Stream`.** A `->` stage whose incoming value is a
  stream still receives the stream itself — a `->` stage's meaning never
  depends on the runtime type of the incoming value, at the head of the
  pipeline or between stages. Per-item flow is written, never inferred: either
  the Stream combinators of design §6.2 — `(source -> $map f -> $filter p ->
  $into [])` — or the `=>` delimiter of Section 6.5, which says at the stage
  what an implicit rule would have had to guess.
- A general placeholder/capture language inside nested syntax.
- Duplicating the incoming value at multiple slots.
- Defining a parallel dispatch mechanism. A stage ultimately uses the existing
  ordinary-call or dot-send path.

## 5. Surface grammar

`->` and `=>` separate one pipeline segment from the next inside a node:

```text
pipeline       = "(", initial_form, pipeline_stage,
                 { pipeline_stage }, ")" ;
pipeline_stage = spacing, ( "->" | "=>" ), spacing, stage_segment ;
stage_segment  = form, { form } ;
```

The normative surface is integrated into `docs/design.md`. The required
lexical distinctions are:

- a whole `->` or `=>` atom inside a node is the pipeline delimiter;
- `->name`, `a->b`, `-->`, and `=>name` remain ordinary symbols, so the rule is
  about the atom rather than about spacing;
- only a parenthesized node, `(...)` or `#(...)`, is pipeline-capable; an arrow
  delimiter in a list, map, or outside such a node is a read error;
- a multi-form segment before the first delimiter, an empty stage, and more
  than one direct `_` in a stage are read errors;
- `;` and an arrow delimiter may not occur at the same parenthesis depth in one
  node; nest one form explicitly instead of relying on precedence. `->` and
  `=>` do mix at one depth.

The value ahead of the first delimiter is a single form. A stage segment keeps
the ordinary grouping convention:

- one form is that form;
- several forms form a call-like node.

```text
((a b) -> f c)   # the call (a b) enters the pipeline
(a b -> f c)     # ReadError: wrap the call in its own parentheses
```

Under the ordinary node grammar, `(a b -> f c)` has already read `a` as the
callee and `b` as its argument before the unexpected delimiter arrives. An
implicitly wrapped leading segment would reinterpret that prefix as `(a b)` —
a call the author never parenthesized — in the one position where the reader
has no earlier delimiter to justify the reinterpretation. Clojure-style thread
macros commonly accept that shape, so the rejection is intentional rather than
an assumption that users will not try it.

The reader must accumulate each segment separately rather than reuse one
node-wide property table. Each raw segment owns its own head, props, meta, body,
and source location. Encountering a delimiter flushes that segment, records
which delimiter opened the next one, and resets all five fields before reading
the next stage. This preserves the compiler-visible stage
order and permits the same property name in different stages while retaining
ordinary duplicate detection within one stage:

```gene
(a
  -> f ^k 1
  -> g ^k 2)       # valid: each ^k belongs to a different stage

(a -> f ^k 1 ^k 2) # ReadError: duplicate ^k in the f stage
```

Nested nodes parse recursively, so a delimiter inside a stage argument belongs
to the nested node rather than splitting the outer pipeline.

Stage meta is ordinary stage-owned syntax just like props. It is preserved on
the materialized call site and round-trips through the printer:

```gene
(a -> f @trace span ^mode fast c)
```

`#(...)` accepts the same grammar and retains the immutable source marker:

```gene
#(a -> f c)
```

The marker is not quotation. Executing `#(1 -> + 2)` answers `3`, just as an
immutable ordinary call node still executes. Under quote or quasiquote it
round-trips as `#(1 -> + 2)`, and materialized stage call-site nodes retain the
marker for tooling. Pipeline syntax still has no runtime mutation interface;
`quote`, not `#`, is the spelling that makes it inert.

Therefore:

```text
(a -> f)             # initial value: a
((make x) -> f)      # initial value: (make x)
(make x -> f)        # ReadError: the leading segment is not a single form
```

Pipelines associate left-to-right:

```gene
(a -> f c -> g d)

# call shape:
(g (f a c) d)
```

The call-shape comment does not relax the sequencing contract in Section 7.

## 6. Stage insertion

### 6.1 Default insertion

When a stage has no direct `_` slot, the incoming value becomes its first
positional argument:

```gene
(a -> f)             # f(a)
(a -> f c d)         # f(a, c, d)
(a -> f ^k v c)      # f(^k v, a, c)
(a -> /name)         # (/name a)
```

Properties stay properties. “First positional” refers only to the order of the
stage body; it does not move or reinterpret `^k v`.

### 6.2 Explicit insertion

One exact `_` may replace the default insertion point. It may appear directly
as:

- the stage head;
- a positional argument;
- a property value.

```gene
(a -> _ c)           # call the value a with c
(a -> _)             # call the value a with no arguments
(a -> f _ c)         # f(a, c)
(a -> f c _)         # f(c, a)
(a -> f ^k _)        # f(^k a)
(a -> f ^k _ c)      # f(^k a, c)
```

A property key is never a slot:

```gene
(a -> f ^_ c)        # no explicit slot; call shape: (f ^_ c a)
```

The reader must reject more than one direct slot:

```text
(a -> f _ _)         # ReadError: a pipeline stage accepts at most one `_`
(a -> f ^x _ ^y _)   # same error
```

### 6.3 Nested `_` is not a slot

Slot detection does not descend into nested forms or containers. This prevents
pipeline syntax from capturing wildcards, parameters, templates, or data:

```gene
(a -> map (fn [_] _))       # no direct slot; a is inserted first
(a -> f [x _])              # no direct slot; `_` remains list data/syntax
(a -> f (quote _))          # no direct slot
```

The incoming value can be embedded more deeply with an explicit function.
MVP does not add recursive slot search.

An `_...` spread is not the exact `_` slot and receives no special pipeline
meaning. A future proposal may add a threaded-splice form if a real use case
requires one.

### 6.4 Dot sends

No additional implicit dot-stage rule is needed. A head slot expresses that
the incoming value is the receiver, after which ordinary dot-send
normalization applies:

```gene
(a -> _ .message c)          # call shape: (a .message c)
(a -> _ .Proto:message c)    # call shape: (a .Proto:message c)
(a -> _ .%m c)               # call shape: (a .%m c)
```

This keeps one slot rule instead of teaching `->` a separate message-dispatch
mode.

### 6.5 Per-item stages with `=>`

`=>` marks a stage that runs once per item of the incoming value. Everything in
6.1–6.4 still describes the stage: the item, not the collection, is the first
positional argument by default, one exact direct `_` overrides that, nested `_`
is not a slot, and a head slot makes the item a dot-send receiver.

```gene
(xs => f c)              # per item: (f item c)
(xs => f c _)            # per item: (f c item)
(xs => f ^k _)           # per item: (f ^k item)
(xs => _ .render c)      # per item: (item .render c)
```

Here `=>` means **per item**, never key/value pairing. Maps have an explicit
pair conversion described below.

**A pipeline never accumulates a collection between stages.** What a `=>` stage
does is decided by one question — does the pipeline continue after it?

- **Not final.** The stage maps *lazily*, in the `Stream` tier of design §6.2,
  and hands the next stage a `Stream`. Nothing is materialized, so an unbounded
  producer flows through one item at a time.
- **Final.** The stage has no consumer for its results. It drains its upstream
  for effect, and the pipeline answers `nil`.

The complete shape table is:

| Stage position | Delimiter | When the stage runs | Value passed onward / pipeline answer |
| --- | --- | --- | --- |
| non-final | `->` | eagerly, once | the ordinary call result |
| final | `->` | eagerly, once | the ordinary call result |
| non-final | `=>` | components now; per-item calls lazily when pulled | a `Stream` |
| final | `=>` | components now; per-item calls eagerly while draining | `nil` |

Appending a stage after a final `=>` changes the old stage from an eager drain
to a lazy map. Consequently `(rows => save -> log)` does **not** call `save`
unless `log` consumes the Stream. Use `(rows -> $each save)` when the drain
must remain explicit and position-independent.

```gene
(rows => save)                              # per row, for effect; nil
(xs => f c -> $into [])                     # lazy through f; into collects
(producer => step -> $take 5 -> $into [])   # terminates on an endless producer
```

`=>` therefore adds no dispatch mechanism of its own: a non-final stage is the
`map` a hand-written `($map ($to_stream xs) (fn [item] (f item c)))` would
perform, and a final stage is `each`, both without naming the item.

Laziness is the delimiter's, not the receiver's: a non-final `=>` converts its
incoming value with `to_stream`, which is the identity on a `Stream`. A kind
with no `to_stream` — `Map` — therefore reaches a non-final `=>` only through
an explicit `-> $to_pairs_stream`, while a final `=>` drains it directly
because `each` needs no conversion.

Those two Map paths deliberately inherit the generic collection operations'
different callback shapes. A final `=>`/`each` sees each Map **value**. A
non-final path through `to_pairs_stream` sees `[key value]`, where a PropMap key
is a `Sym` and `entry/1` is the value. Changing `each` to see pairs would be a
stdlib migration, not a pipeline rule.

Collecting stays explicit and therefore retains the standard-library `$`
spelling: a lazy collecting chain ends in `-> $into []`. No pipeline-only
collector alias is introduced.

The two delimiters mix at one parenthesis depth. `;` mixes with neither.

This is the explicit stage-level syntax that Section 4's non-goal reserved.
The rejected feature was a `->` stage that changes meaning when the incoming
value happens to be a stream; `=>` is a different delimiter the author writes,
so a reader never has to know a runtime type to know what a stage does.

Symbols and literals are left in place rather than lifted: a symbol load is
idempotent, and keeping it in place preserves ordinary head dispatch for `+`,
for a statically known function, and for a `.message` descriptor. A spread
stays a spread, with its operand lifted.

Loop-invariant hoisting is the reason `=>` can be a stage at all. It is exactly
the work Section 4 said an *implicit* per-item rule would have to do silently,
and doing it under an explicit delimiter is what makes it a contract rather
than an optimization.

## 7. Evaluation contract

For each stage, Gene performs these steps in order:

1. Evaluate the preceding pipeline expression exactly once.
2. Retain its value in compiler-owned temporary storage that user code cannot
   name, shadow, capture, or mutate.
3. Evaluate the stage callee.
4. Evaluate the stage's named and positional argument expressions according to
   the ordinary call contract. The inserted pipeline slot is a load of the
   already-computed temporary value.
5. Invoke the existing call or send machinery.
6. Use the result as the incoming value of the next stage.

If any step raises, later steps and later stages do not run.

For example, this source:

```gene
((make_a) -> (make_f) (make_c))
```

must evaluate in this order:

```text
make_a → make_f → make_c → invoke selected f
```

It is not semantically equivalent to the naive reader expansion:

```gene
((make_f) (make_a) (make_c))
```

because that ordinary call evaluates `make_f` first.

The named-slot form has the same guarantee:

```gene
((make_a) -> (make_f) ^k _)

# order:
make_a → make_f → load retained a → invoke selected f
```

### 7.1 Per-item stage evaluation

A `=>` stage evaluates its callee and its non-slot arguments **once**, before
iterating. Only the per-item call repeats:

1. evaluate the incoming expression exactly once and retain it;
2. evaluate every separately evaluated stage component — the callee unless the
   head is the slot, each direct property value, and each direct positional
   argument — once, into compiler-owned storage;
3. build the per-item callable over that storage;
4. hand the retained value and callable to `map` over `to_stream` when a later
   stage will consume results, or to `each` when the stage is last.

Component evaluation is eager even if zero items will flow. Here `choose` runs
once, while the per-item call never runs:

```gene
(var out
  ([1 2 3]
    => (choose) _ 10
    -> $take 0
    -> $into []))
```

Stage execution then interleaves per item. For
`xs => a => b -> $into []`, the observable order is
`a(item1), b(item1), a(item2), b(item2)`, not all `a` calls followed by all
`b` calls.

### 7.2 Failure and laziness

The earlier short-circuit guarantee is stage-local for eager `->` work and
item-local for lazy `=>` work. If the third per-item call raises, calls and
effects already completed for items one and two remain visible. The failing
item does not continue through later stages, no later item is pulled, and the
pipeline provides no transaction or rollback.

A lazy pipeline also inherits Stream ownership:

- an adapter owns its upstream until normal exhaustion or explicit close;
- `for` closes the Stream it consumes, and `$into []` consumes it;
- a bounded `take` detaches its still-resumable upstream when the bound is
  reached;
- a returned Stream keeps its per-item callback and captured components alive
  until it is exhausted, closed, or released; and
- merely abandoning an unpulled Stream does not promise deterministic resource
  cleanup. Code using a resource-backed producer must consume it in a closing
  construct or call `close` explicitly.

Closing a Stream releases both its upstream and its per-item callback. The
pipeline does not add a second lifetime policy around that contract.

## 8. Canonical representation

The reader must preserve pipeline structure in a canonical form until a
compiler stage can enforce Section 7. It must not immediately substitute the
left expression into an ordinary call tree.

The accepted representation is a syntax-only `vkPipeline` value containing an
initial expression and ordered `PipelineStage` records. Each stage owns its
head, props, meta, body, direct slot location, and source location. It is not a
magic Gene node and introduces no user-facing `thread`, `stage`, or `Pipeline`
binding.

`vkPipeline` is generally available wherever an expression is accepted, but it
is program syntax rather than a nominal runtime data type. In executable
position the compiler consumes it. Under quote/quasiquote it remains inert
syntax that macros may inspect or emit and `eval` may later compile. It has no
constructor, message surface, serialization contract, `Send` conformance, or
ordinary collection behavior.

The representation also retains whether the parenthesized source used `#(`.
That bit exists for faithful syntax/tooling round-trips and for the immutable
stage call-site marker described in Section 5; it does not make executable
pipeline syntax inert.

The representation must satisfy these constraints:

- it retains stage boundaries, props, meta, positional order, and slot
  location;
- it cannot collide with the internal `~`/`?~` markers used for canonical
  message sends;
- it round-trips through the canonical printer;
- it survives source-location and macro-provenance tracking;
- it cannot be forged accidentally by an unrelated ordinary call;
- it is produced only by the `->` reader surface and cannot be forged by a
  user-authored ordinary node.

Keeping the structure also lets the human formatter preserve `->`. A direct
rewrite to `(f a c)` would be non-injective: the formatter could not know
whether the author wrote a pipeline or an ordinary nested call.

## 9. Compiler seam

Pipeline sequencing belongs behind one compiler interface shared by the VM,
typed-native analysis, and the web backend. Conceptually:

```text
compile_pipeline(initial, stages, expected_type, tail_position)
```

The implementation may use an anonymous local slot or a stack-placement
instruction. The interface must guarantee:

- no user-visible binding;
- no duplicate evaluation;
- compiler-owned storage is frame-bounded inside a function and does not
  remain live in a module, namespace, or REPL scope after the pipeline result
  no longer needs it;
- no extra heap allocation on the runtime hot path when a frame/local slot is
  sufficient;
- ordinary call-site metadata and diagnostics;
- final-stage tail-position propagation;
- no tail marking on intermediate stages;
- the same checked-error, capability, return-adaptation, and implementation
  validation behavior as the corresponding ordinary call or send.

A source-level rewrite to `do` plus a generated `let` illustrates the semantics
but is not the preferred implementation:

```gene
(do
  (let generated_pipeline_value a)
  (f generated_pipeline_value c))
```

That spelling risks exposing or capturing a generated name, adds synthetic
scope artifacts to diagnostics, and can interfere with slot accounting. The
compiler should own the temporary directly.

Concretely, the VM overwrites the top-level pipeline scratch slot after the
final stage. Top-level `=>` components are captured through the generated
callback's own call scope rather than stored in the application-long module
frame. A returned lazy Stream retains that smaller scope because its callback
still needs the values; `Stream/close` releases the callback. Function-local
scratch remains in the ordinary call frame and disappears with that frame; a
returned lazy Stream may intentionally retain the frame through its callback
until the Stream is closed or released.

## 10. Macros, fexprs, and special forms

The MVP targets ordinary eager call and dot-send stages, for `->` and `=>`
alike. Statically known macro,
fexpr, and special-form stage heads are rejected with an actionable diagnostic;
they do not share the ordinary evaluation contract and must not acquire
accidental pipeline semantics. A later proposal may add a narrowly specified
syntax-stage model backed by concrete use cases.

Dynamic callees continue through ordinary runtime call-kind checks. A dynamic
value that turns out to be an `Fexpr` is rejected as it is in an ordinary eager
call.

`yield` and `await` are syntax heads, so `(value -> yield)` and
`(task -> await)` are rejected by the same rule. They may still occur where an
ordinary component expression may occur, and retain their ordinary meaning:

```gene
((await task) -> decode)
(value -> combine (await other_task))
```

The pipeline never inserts an await. A nested `yield` makes its enclosing
function a generator exactly as it would outside a pipeline; its yielded value
and resumed result are governed by the ordinary `yield` contract.

## 11. Tooling and diagnostics

The reader should report:

- missing initial segment;
- missing stage after `->` or `=>`;
- a multi-form segment before the first delimiter;
- more than one direct `_` slot;
- mixed `;` and arrow delimiters at one parenthesis depth;
- invalid standalone `->`/`=>` and delimiters inside lists or maps, explaining
  that arrows are valid only between segments of one parenthesized form;
- a leading send stage such as `(a -> .message)`, pointing at that stage and
  suggesting the head-slot spelling `(a -> _ .message)`.

When a non-final `=>` leaves a `Stream` at a boundary requiring `List`, the
type error suggests the explicit `-> $into []` collector. The ordinary
expected/actual types remain the primary diagnostic.

Diagnostics from a stage call should point at that stage, not at the whole
pipeline. Tail-fallback and call-site records should use the same stage source
location.

The canonical printer and `gene fmt` should emit `->`/`=>` pipelines from the
canonical representation. The formatter should use one stable multiline style:

```gene
(source
  -> parse options
  -> validate schema
  -> save db _)
```

LSP occurrence, completion, hover, and selection ranges should expose each
stage as source syntax while navigation into the expanded/canonical structure
remains possible through the existing source-location table.

## 12. Interaction with existing syntax

### 12.1 Message sends

Message sends remain dot-only:

```gene
(x .message)
x/.message
```

`->` does not perform message resolution. To send inside a pipeline, use the
explicit receiver slot shown in Section 6.4.

### 12.2 Arrows inside symbols

Only a whole `->` or `=>` atom between node segments is a delimiter, so these
remain ordinary symbols:

```gene
->name            # a symbol that begins with an arrow
a->b              # a symbol that contains one
-->               # a longer arrow-like symbol
```

Spaced `~` carries no meaning after this change: `~` sends were removed with
the dot surface, and the pipeline it briefly spelled is now `->`. The reader
rejects it with a message naming both replacements rather than silently reading
it as something else. `~name` stays an ordinary glued symbol and the
`#B16#aa~ bb` byte-literal continuation keeps its byte syntax.

## 13. Performance requirements

- Pipeline execution must add no heap allocation beyond what the corresponding
  calls already require when compiler-local storage is sufficient.
- The incoming value must not be copied merely to preserve ordering.
- A pipeline of ordinary calls should compile to call sequences plus the
  minimum placement/store-load operations needed for sequencing.
- The final stage must retain ordinary tail-call eligibility.
- Reader normalization must remain one pass over pipeline syntax and must not
  add a second source-text pass.
- `nimble perf` must compare pipeline calls with their explicit sequenced
  equivalent, not with the semantically different naive nested call.

## 14. Required tests

### Reader and printer

- default insertion;
- explicit head, positional, and property-value slots;
- a head slot with no arguments calls the incoming value;
- multi-stage left association;
- empty stage and duplicate-slot errors;
- a multi-form segment before the first delimiter is rejected;
- nested `_` is not captured;
- dot-send stage through a head slot;
- stage meta and `#(...)` immutable-marker round-trips;
- `->` and `=>` mixed at one depth, each printing its own delimiter;
- arrow-containing symbols and byte continuations remain unchanged;
- canonical print/read round-trip and formatter idempotence.

### Evaluation order

- incoming expression runs before the stage callee;
- a `=>` stage's callee and non-slot arguments run once, before iterating;
- those components still run when a later `take 0` pulls no items;
- a non-final `=>` stage is lazy, and an unbounded producer terminates when a
  later stage bounds it;
- a final `=>` stage drains its upstream and the pipeline answers `nil`;
- stage callee runs before its other arguments;
- incoming expression runs once with default insertion;
- incoming expression runs once with a property slot;
- a failing incoming expression prevents callee and argument evaluation;
- a failing callee prevents stage argument evaluation;
- later stages do not run after an earlier failure.
- per-item failure preserves effects from completed earlier items and pulls no
  later items;

### Semantics and backends

- positional, named, default, rest, and spread arguments;
- typed parameter and return boundaries;
- a Stream-to-List mismatch suggests `-> $into []`;
- checked errors and capabilities;
- ordinary functions, dynamic callables, and dot sends;
- bytecode, typed-native acceptance/rejection, and web emission;
- final-stage TCO and intermediate-stage non-tail behavior;
- source locations, stack traces, and tail-fallback diagnostics.
- top-level scratch releases the last incoming value, while a returned lazy
  Stream retains and then releases only the callback capture it needs.

## 15. Implementation outcome

1. **Surface contract:** complete in `docs/design.md` and
   `docs/spec/calls.md`; `;` remains independent head-folding sugar.
2. **Reader representation:** complete. The reader emits `vkPipeline`, owns
   props/meta/source locations and a delimiter kind per stage, requires a
   single-form leading segment, and validates direct slots and mixed
   delimiters in one pass.
3. **Compiler sequencing:** complete. VM GIR uses compiler-owned inaccessible
   locals, preserves source-facing call sites, and propagates tail position to
   only the final stage. Inside functions, a `=>` stage adds one frame-bounded
   hidden binding per separately evaluated component. At module/namespace/REPL
   scope, those components pass through the callback's own capture scope and
   the pipeline scratch slot is cleared after evaluation. Both paths reuse the
   ordinary `map` send. The opcode/build table uses executable artifact marker
   GIR v5.
4. **Backends:** complete for the VM and web emitter. The web profile now
   infers an inline callback's parameter and return types when the expected
   type is a known `Callback`, which is what lets a generated `=>` callback
   carry no annotations; a user-written callback with nothing to infer from
   still requires them. Fixed-representation typed-native analysis deliberately
   declines pipeline syntax, retaining the checked dynamic VM fallback rather
   than inventing a second lowering.
5. **Syntax transformation and tooling:** complete for canonical printing,
   `gene fmt`, source indexing, quote/quasiquote, macro expansion, GIR
   round-tripping, and diagnostics. Slot classification is refreshed after
   unquote or macro expansion so generated `_` syntax cannot become stale.
6. **Corpus and gates:** `examples/pipeline.gene` is the runnable example; the
   tracked Gene corpus parses, the executable spec and wasm suite pass, and the
   performance smoke check compares pipeline execution directly with explicit
   sequenced locals. The repository-wide test/verify gate still reports its
   pre-existing general-intelligence timeout and AI-agent state-store failures,
   outside this feature.

No stage changes `;`. A future proposal may compare or unify their internal
implementations after `->` has an independently sound contract.

## 16. Deferred extensions

- The formatter keeps a one-stage pipeline compact when it fits and gives a
  pipeline with two or more stages the stable multiline layout from Section
  11.
- `_...` has no threaded-splice meaning. It requires a separate future use case
  and slot kind.
- `=>` is `map`. A per-item `filter` or `each` delimiter is not proposed: both
  read clearly today as `-> $filter p` and `-> $each f`, and neither carries the
  slot ergonomics that motivate `=>`.
- A final `=>` remains the ergonomic implicit drain. The rejected alternative
  was to make `=>` always return a lazy Stream and require `-> $each f` for
  every effect-only traversal. Revisit this only if real edits repeatedly ship
  the silent-non-execution bug where appending a stage turns an old final drain
  into a lazy map. The mechanical migration is `X => f` to `X -> $each f`;
  there is no third delimiter to preserve.
- Direct `;`/arrow mixing remains rejected. Explicit nesting is the composition
  syntax unless a later proposal demonstrates a clearer rule.
- Quasiquote supports unquote in pipeline components. Direct unquote-splicing
  into a stage body is deferred because a dynamic splice can move the stage's
  direct slot and needs a dedicated reconstruction contract.

None of these extensions reopens `;`; they concern only `->`/`=>` pipelines.

Decided 2026-09-02: streams are **not** implicitly threaded per-item through
pipelines — see the non-goal in Section 4. The per-item spelling that Section 4
required to be explicit stage-level syntax is `=>` (Section 6.5); a `->` stage
still never inspects the incoming value's runtime type.
