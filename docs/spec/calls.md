# Calls, selectors, control, and eval contract

**Status:** normative and implemented. Executable coverage:
`tests/spec_runner.nim`, suites “explicit fexprs”, “selectors”, “pattern
destructuring”, “checked errors”, “Env and eval”, and “absence-guarded
sends”, plus “proper tail calls”. Frame-space assertions live in
`tests/test_vm.nim` because they inspect VM instrumentation rather than only
surface values.

Ordinary calls are callable-first and always eager: `(foo a)` evaluates `foo`
and `a` before calling. A bare lexical head ending in `!` is the distinct,
statically resolved fexpr form: `(foo! a)` preserves `a` as syntax and supplies
the fexpr a borrowed `CallerEnv`. Define one with `(fn foo! [syntax...] ...)`;
the removed `fn!` form is invalid. Aliases, expression heads, and higher-order
ordinary calls cannot invoke a held `Fexpr`. Durable caller authority requires
an explicit named `snapshot` on `CallerEnv`. Message sends dispatch only: bare
names reach type-direct messages, `P:msg` reaches protocol impls, and dynamic
callees must be message values. Invalid callees are rejected before send
arguments run; message names may not end in `!`, and there is no lexical
callable fallback.

Call and `new` spreads merge the operand's anatomy: List elements become
positionals, PropMap entries become named arguments, and a node contributes
both props and body while dropping its head. A spliced prop replaces an
earlier named value with the same key. Use `$body` explicitly when only a
node's positional contents are wanted. Named properties must not disappear
merely because a call uses a spread.

## Binding an invocation

`runtime/bind_call` returns an ordinary zero-argument function that invokes an
existing callable with a bound argument shape:

```gene
(var invoke
  ($runtime/bind_call handler [context payload]
    ^policy {^max_steps 100000 ^max_memory_mb 64 ^timeout_ms 2000}))
(invoke)
```

`^named` optionally supplies a PropMap of named arguments. The positional list
and named map are shallow snapshots: later edits to their shape do not alter
the invocation, while nested mutable values retain identity. The calling
lexical environment supplies scoped implementation visibility, as for a
closure. Fexprs, borrowed `CallerEnv` authority, and in-progress construction
values cannot become durable bound calls.

The binder does not execute the target or start a task. Invocation uses normal
bytecode calls, preserving suspension, error types and fields, panic behavior,
and cancellation cleanup. A caller can spawn the resulting function and inspect
`TaskOutcome` through `join`, without compiling a Gene wrapper via `eval`.

Each invocation receives fresh step, memory, and elapsed-time limits. Time
starts when execution enters the binding. Nested calls consume the caller's
budget as well as any narrower bound/module budget; scope-free and tail calls
must not drop those limits or leave a depleted budget on a lexical scope.
Enforcement uses the VM's existing dispatch and safe-point checks, including
its sampled memory/time checks. This operation does not isolate native code.
The policy accepts the three budget fields above; sandbox loading remains the
boundary for feature-admission flags such as `allow_ffi`.

`^capabilities` optionally supplies an inert selector list, using the same
selector vocabulary as `with_capabilities`. It resolves at binding time in the
creating scope and can only select from that scope's active context. Omitting
it retains that context as a ceiling; `[]` selects no authority. Each later
invocation intersects that captured ceiling with its actual caller's context,
so moving a bound function cannot recover removed authority.

```gene
($runtime/bind_call read_config []
  ^capabilities (quote [(fs/ReadFile filename)])
  ^policy {^max_steps 10000})
```

The `filename` reference is resolved while binding. No declaration is added
to a source module. The runtime compiles its private trampoline once per
application and gives each binding separate mutable dispatch caches.

Current retention limitation: the runtime does not collect every mixed
scope/closure cycle. Keeping a bound call in the scope it captures can form
such a cycle, as can storing a returned ordinary closure in an ancestor scope.
An adapter that keeps a local binding should clear it in `ensure` once the
invocation or supervising task has settled. Cordis does this after `Task/join`.
Temporary bindings and explicitly released bindings reclaim their captures;
this API does not add a general closure-cycle collector.

## Pipelines and core forms

`->` forms a sequenced value pipeline. The incoming expression is evaluated
first and exactly once; each stage then evaluates its callee and ordinary
arguments before invoking the existing call/send machinery. With no direct `_`,
the value is the first positional argument. One direct `_` may instead occupy
the stage head, a positional argument, or a property value:

```gene
(a -> f c)       # call shape (f a c), with a evaluated before f
(a -> f c _)     # call shape (f c a)
(a -> f ^k _)    # call shape (f ^k a)
(a -> _ .m c)    # call shape (a .m c)
(a -> _)         # call the incoming callable with no arguments
```

`=>` is the per-item delimiter: its stage runs once per item of the incoming
value, and its callee and other arguments are evaluated once before iterating.
A pipeline never accumulates a collection between stages. A `=>` stage with a
later stage maps lazily in the `Stream` tier (§6.2), so an unbounded producer
flows through it; a **final** `=>` has no consumer, drains its upstream for
effect, and the pipeline answers `nil`.

```gene
(rows => save)                              # per row, for effect; nil
(xs => f c -> $into [])                     # lazy through f; into collects
(producer => step -> $take 5 -> $into [])   # terminates on an endless producer
```

A non-final `=>` converts its incoming value with `to_stream`, which is the
identity on a `Stream`. A `Map` has no `to_stream`, so it reaches a non-final
`=>` only through `-> $to_pairs_stream`; a final `=>` drains it directly.

Stage position is semantically significant: appending a stage after a final
`=>` changes that old stage from an eager drain into a lazy map. Its components
still evaluate before any item is pulled. Per-item failure preserves completed
earlier effects, and resource-backed Streams require consumption or explicit
close. `#(...)` retains the immutable syntax/call-site marker but executes like
the ordinary pipeline form; quote is the inert spelling.

Pipeline syntax is represented by syntax-only `vkPipeline`, associates
left-to-right, and preserves tail position only for the final stage. The
segment before the first delimiter is a single form. Multiple direct slots,
empty stages, syntax-call stages, a multi-form leading segment, and mixing
`->`/`=>` with `;` at one parenthesis depth are errors; `->` and `=>` mix with
each other. `;` remains head-folding reader sugar and has no slot behavior.
See `docs/design.md §2.7` and `docs/proposals/pipeline.md`.

MVP compiler-dispatched heads:

<!-- compiler-head-dispatch:start -->
```text
do if if_yes if_not && || ?? ! let var const set new fn macro quote quasiquote
select path msg ns env eval import import_impl mod match while loop repeat for break
continue yield return try scope supervisor spawn await fail panic type alias enum
protocol impl derive with_capabilities web_module
```
<!-- compiler-head-dispatch:end -->

`?.message` is the absence-guarded send. It is `.message` with one additional
rule, applied to the receiver only:

- the receiver is evaluated exactly once; if it is **absent** (`nil` or `void`)
  the send yields that receiver unchanged and no message is resolved, no
  argument or named-argument form is evaluated, and no impl runs;
- a present receiver takes the ordinary dot-send path in full, so an unresolvable
  message is still a `MessageError` — guarding never suppresses a misspelled
  name;
- guarding is decided before message resolution, so `(nil ?.anything)` is
  `nil` regardless of the name;
- it does not alter an ordinary dot send. `Nil` remains an ordinary nominal type with no
  dispatch carve-out, `(nil .msg)` is still an error, and where
  `(impl P for Nil …)` exists `(nil .P:m)` runs it while `(nil ?.P:m)`
  short-circuits before lookup;
- every dot descriptor is accepted — bare `.m`, qualified `.P:m`/`.Self:m`,
  held `.%m`, and computed `.%(expr)` — together with named arguments and spreads;
- leading `(?.m …)` is the guarded self-send, observable where lexical `self`
  is absent, as in an `impl P for Nil` body;
- `super` is never absent, so `super ?.m` is rejected. Selectors are ordinary
  callables (`(/name x)`), not message descriptors; use `??` for an
  absent-valued projection.

Clause/declaration heads (`then`, `elif`, `else`, `when`, `catch`, `ensure`,
`ctor`, and `message`) are meaningful only inside their owner. `new` is a core
form that invokes the nearest constructor in a type's ancestry.

## Tail-call contract

The last expression of a function or message body is a tail position. The
position propagates to selected `if` branches, `if_yes`/`if_not` bodies,
`match` arms, `do`, the last `&&`/`||`/`??` operand, and an explicit `return`
value. It does not propagate into arguments, conditions, initializers, loops,
structured cleanup/authority bodies, constructors, namespaces/modules, `new`,
or fexpr calls.

A bytecode call in tail position replaces its current activation when that
activation has no remaining return adaptation, checked-error policy,
implementation validation, cleanup/restoration, or retained caller scope.
Retention includes weak scope-owned closures passed as arguments: the caller
activation remains when elision would otherwise invalidate their capture.
This covers direct and higher-order functions, sends, held protocol messages,
and user values whose `Callable/apply` implementation is Gene bytecode. Nested
tail-position match arms are transparent expression frames and do not add one
frame per recursive iteration.

If observable continuation work remains, the call keeps the activation and
behaves exactly like an ordinary call. Exact compiler-proven scalar/unit
returns may remove a redundant return policy; unknown or adapting results do
not. Stack traces retain a bounded recent tail history and an elision count.
`gene run --report_tail_fallbacks` exposes once-per-site fallback reasons for
development diagnostics.

Expression paths resolve their base lexically and select later segments;
declaration/import/type contexts resolve qualified names statically. Static
scalar/key selector segments are pure. Callable, call-stage, and send segments
are executable: they are non-serializable and invalid for `assoc_in` and
`update_in`. Strict missing lookup raises `SelectorMissing` with `^segment`.
