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

## Fexpr evaluation boundaries

Fexprs choose how to interpret syntax at runtime. Template macros expand into
ordinary lexical syntax; binding and control flow follow the resulting code.
The two mechanisms have different evaluation boundaries:

- Each `eval` through `caller_env` uses a fresh evaluation copy. Direct binding
  writes cannot change the original caller scope, and evaluated declarations
  stay local to that evaluation.
- The current VM permits `set` on a copied caller binding, updating only the
  evaluation copy. It does not currently reject the assignment. A subsequent
  `eval` starts from the caller bindings again.
- Mutable values and invoked closures retain their existing effects. A Cell
  can be mutated, and a closure may rebind variables it already captures.
- `eval` carries no enclosing caller function-return or loop targets. `return`
  requires a function within the evaluated syntax; `break` and `continue`
  require a loop within it. An absent local target raises `CompileError` when
  that syntax is compiled by `eval`. Unevaluated syntax does not reach this check.

The fexpr's own body and functions or loops inside evaluated syntax follow
ordinary local control-flow rules. See [the fexpr and macro guide](../language.md#macros-fexprs-and-eval)
and the runnable [fexpr demo](../../examples/fexpr_demo.gene).

## Direct message calls and checked callable signatures

`(P:msg receiver args...)` normalizes to `(receiver .P:msg args...)`.
`(Self:msg receiver args...)` normalizes to `(receiver .msg args...)`.
The receiver runs before qualifier resolution and remaining arguments. This
normalization is mandatory, including before `=>` captures a stage. Concrete
type qualifiers remain invalid, and a direct receiver cannot be supplied by a
leading spread. The reader preserves authored syntax for quotes and Call.site.

Held-message application `(m x)` retains the message's authored dispatch scope;
`(x .%m)` uses the send site's scope. Ordinary held calls remain eager, so their
failure timing need not match a send.

`(Callable [A B] R)` creates a checked invocation view of any ordinary callable:
functions, native callables, messages, selectors, constructor-capable types,
and user values implementing `Callable`. Fexprs are excluded. Bare `Callable`
only tests callability; `Fn` and `(Fn ...)` retain their function-only matching.
A checked view itself is Callable and is neither Fn nor Message. A held send
requires a raw Message. Views are not serializable or automatically Send.

The positional vector is exact unless it ends in `T...`, which checks zero or
more further arguments. `^named {^key T}` is a closed named shape. Explicitly
nil-admitting types permit omission; `Any` remains required. Omitted arguments
stay omitted, so target defaults run per invocation. Supplied runtime Void
remains supplied; literal void props follow the reader's normal removal rule.
The target's own arity and parameter checks still apply after view checks.

Inputs and results cross ordinary typed boundaries using the signature's
authored type/implementation scope. Adaptation may create a distinct view
without changing the target. Reapplying an equivalent contract may reuse a
view; adaptation does not promise identity preservation or function variance.

`^errors [E]` bounds ordinary invocation errors, including target-owned default
evaluation; `^errors []` admits none. `Error` opens the row, so `[E Error]`
permits every ordinary error while retaining E as diagnostic information.
An omitted row leaves errors unchecked at runtime. A rejecting row generates
one `ErrorContractViolation` retaining the original typed error as `cause`.
Generated type failures and contract violations pass through outer rows;
freshly constructed failures are ordinary regardless of their type name.
Panic and cancellation retain their normal behavior. Returned
Streams and Tasks remain values with their own deferred contracts. The callable
error row does not apply to later consumption or execution of those values.

`fn` and `message` declarations marked `^^generator` return a suspended Stream.
The execution kind belongs to the resolved implementation and is preserved by
inheritance and callable views. A Stream result contract also admits ordinary
factories; it does not select generator execution. See the
[generator contract](streams.md).

Error-row compatibility compares resolved semantic coverage: order, duplicates,
Never, redundant subtypes, and named hints alongside Error do not change it.
Other exact callable-signature rules remain in force. The
[error-handling contract](../error-handling.md) specifies checking modes,
retained Error conformance, and implementation status.

Executable coverage: `tests/test_unify_callable.nim` and shared `callable.*`
fixtures in `tests/transpile/fixtures.json`.

## Callable reflection

`($runtime/signature target)` returns an immutable `SignatureDescription` node.
Known argument shapes are available for ordinary Gene functions, checked
`Callable` views, selectors, enum variants, direct ordinary Type construction,
declared FFI callables, and message contracts with available signature metadata.
Ordinary native functions without signature metadata and fexprs remain unknown.
Custom `Callable` values expose the selected `apply_contract` separately;
their outer argument shape remains unknown. A checked view still exposes its
enforced outer contract over an opaque target.

The format-1 description has these fields:

| Field | Meaning |
| --- | --- |
| `category`, `origin`, `completeness`, `shape_known` | Callable category, declared/checked-view provenance, known/partial/unknown metadata, and whether shape binding is supported |
| `positional`, `named`, `rest`, `minimum_positional` | Ordered parameter descriptions, optional rest description, and minimum positional count |
| Parameter `name`, `local`, `required`, `has_default`, `type_known`, `type` | External name/local alias, omission rules, presence of explicit default code, and safely described type |
| `result_known`, `result` | Declared result contract; an unannotated result is unknown, distinct from explicit `Any` |
| `invocation_errors` | `checked`, `known`, and `types`; an unchecked row has unknown types, while a checked empty row has an empty list |
| `deferred` | For a supported `(Stream T E)` or `(Task T E)` result, `known`, `kind`, `value_type`, and `error_type`; otherwise `known` is false |
| `name`, `source`, `doc`, `execution` | Function name, source position, literal `@doc` text, and ordinary/generator execution kind when known |
| `contract_identity`, `contract_version` | Compiler contract identifiers when available; these are descriptive and do not identify a particular closure instance |
| `type_parameters` | Generic parameter names when available; uninstantiated generic annotations remain unknown rather than resolving to same-named outer bindings |
| `resolution`, `protocol`, `declaring_protocol`, `abstract_self` | For messages: requirement versus implementation, qualifier, owning protocol identity, and whether `Self` is abstract |
| `dispatch_scope`, `receiver_included`, `receiver_type` | For messages: authored/query dispatch, the leading receiver slot, and queried nominal receiver type without retaining the receiver value |
| `construction`, `constructor_errors` | Direct `data`, explicit `new`, or unsupported `native` construction; the selected ctor's own error row is separate from the whole `new` operation |
| `apply_contract` | A custom Callable implementation's `(self, Call)` method contract; these are not the outer caller's positional parameters |

### Message requirements and receiver-aware queries

`($runtime/signature P:message)` describes the declaring protocol requirement.
It includes the leading receiver parameter and retains symbolic `Self` in
parameter/result/error annotations with `abstract_self true`. This is a known
abstract contract, not a concrete receiver type or proof of conformance. A
protocol's default generator body does not imply the selected implementation
will be a generator, so requirement `execution` stays unknown.

`($runtime/signature P:message receiver)` resolves the implementation without
executing it. The optional second argument is valid only for Messages; explicit
nil still supplies a receiver. Held messages retain their authored dispatch
scope. A raw protocol declaration supplied by a native caller uses the query's
calling scope. To query ordinary send-site behavior, author a fresh message
value at that site. Resolution uses the existing readiness, nearest-provider,
ambiguity, and retained Error-witness rules; missing/pending implementations
remain errors instead of invented signatures.

`Self:message` has no protocol requirement, so its shape is unknown without a
receiver. With a receiver it describes the selected type-direct message.
Inherited signatures preserve their original declaration-bound `Self`;
querying a Child never substitutes Child for Parent in an inherited contract.
An inherited message's `declaring_protocol` also remains its original owner,
even when `protocol` names a child protocol used as the query qualifier.
Receiver-aware descriptions still include the leading receiver slot for held
message application. They do not bind or retain the queried receiver, and shape
binding does not prove that a later receiver selects the same implementation.

### Data construction and new

`($runtime/signature T)` describes `(T ...)`: inherited closed props become
named parameters, body fields become positional parameters, and a trailing
body rest field becomes the rest parameter. A nil-admitting body field still
requires its positional slot, while an optional prop may be omitted. This
query never runs a ctor. Aliases, enum type values, native wrappers, and types
with native constructor metadata not supported by this API have unknown direct
construction shapes. Enum variants separately expose exact payload slots.

`($runtime/constructor_signature T)` describes `(new T ...)` using the nearest
ctor in T's ancestry. It removes implicit `self` from the public parameters,
preserves the ctor's original parameter contracts and default flags, and
reports T as the result regardless of the ctor body's return annotation.
No ctor means `shape_known false` with `reason no_constructor`; there is no
fallback to direct data construction. A non-Type argument is an error.

The ctor's error row appears in `constructor_errors`. The full invocation row
remains unknown because `new` also validates the completed instance, which can
fail after an otherwise successful ctor with `^errors []`.

### Other callable categories

Selectors expose one positional argument, no named arguments, and unknown
result/error contracts. Describing a selector does not traverse any data or
execute effectful stages. FFI callables expose their existing declared
parameter/result types, with unknown error contracts; addresses, libraries,
release callbacks, and foreign memory are not exported.

A custom `Callable` is resolved in the query's calling scope. Its `apply`
method receives `(self, Call)`, so that method signature cannot be substituted
for the outer call's argument shape. Inspect `apply_contract` for diagnostics
or use a checked view when an enforced outer signature is required. Reflection
never calls the custom implementation.

Checked views do not invent positional parameter names, target defaults,
source information, or target execution kind. Their named parameters use the
existing explicit nil-admission rule for omission. The description does not
claim a checked target was statically proved compatible.

Reflection only reads initialized type bindings and supported type structure;
normal message/type lookup may complete pending declaration metadata.
It never evaluates defaults or arbitrary annotations, imports modules, invokes
getters or protocol methods, or exports frames/captures/native pointers. It
copies annotation structure without meta and retains ordinary nominal type
identities. Dynamic annotations and unsupported type forms have
`type_known false` and `type nil`. Unannotated parameters have the existing
`Any` admission contract. User `@signature`/`@wrapped` metadata cannot replace
the effective contract. Only a literal string `@doc` is copied from declaration
metadata.

`$runtime/bind_shape(description, positional, named)` takes a positional List
and named PropMap. It checks counts, required names, and unexpected names
without evaluating defaults, adapting values, or invoking a target. Unknown
shapes and invalid envelopes raise an ordinary RuntimeError. The result is an
immutable `BoundShape` with shallow snapshots in `positional` and `named`, plus
`omitted_positional` indices and `omitted_named` names. Nested mutable payloads
retain identity; borrowed CallerEnv and construction values cannot escape
through the envelope.

Omitted values are never filled with nil or computed defaults. Supplied nil
stays supplied. Raw Void values already present in positional input remain
supplied. Ordinary Gene maps remove Void-valued entries before this API runs;
a named Void therefore cannot be transported through its PropMap input. Use
ordinary direct named invocation for that case. Reflection does not change
the existing collection or call-envelope semantics.

A description, including a copied or edited description, provides no authority
and is not a reusable type-check proof. Invocation must still go through the
real target's ordinary boundary. Descriptions are fresh snapshots with no
function-name cache; existing descriptions retain their type identities after
replacement. Read a fresh description when registering a replacement callable.

The implementation is shared by the native and wasm VM, subject to each VM's
existing feature admission (for example, native FFI availability). The transpiled web
profile rejects this runtime surface. Coverage lives in
`tests/test_callable_reflection.nim`, with a real tool adapter in the Harness
package's `src/agents/reflection.gene` and `tests/reflection_smoke.gene`.

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

`=>` prepares a per-item invocation once, converts the input with normal
`to_stream`, and returns a new lazy Stream in every position, including the
final stage. It never drains, collects, flattens, or awaits implicitly.

```gene
(rows => save)                              # lazy; no save calls yet
(rows -> $each save)                        # immediate per-row effects; nil
(xs => f c -> $into [])                     # explicit collection
(producer => step -> $take 5 -> $into [])   # bounded demand
```

Fixed callee, message-value, and argument expressions run once in ordinary
component order, before conversion. This includes mutable symbol reads.
Spreads expand once after the fixed expressions have evaluated; their captured
layout and element references do not track later source-container edits.
Omitted callee defaults still run per invocation. A direct guarded item send
prepares its fixed expressions even if all receivers are absent; its guard
suppresses item-time message resolution and invocation. Use an ordinary lambda
when argument evaluation itself must be guarded per item.

`to_stream` preserves a Stream's identity and cursor position. Lists, Sets,
Ranges, and user types with a type-direct conversion are accepted; a Map needs
explicit `-> $to_pairs_stream`, with `[key value]` as one item. Unsupported
scalars and nil are not singleton or empty streams. Conversion must produce a
Stream and must not pull items. Per-item `void` results become `nil`; `nil`,
Lists, Streams, and Tasks remain individual results.

Preparation can fail immediately. Callback/dispatch/boundary failures occur
on demand, are terminal, preserve completed effects, and propagate once.
Explicit consumers and lexical resource scopes govern cleanup. `#(...)`
retains its immutable syntax/call-site marker but executes normally; quote is
the inert spelling. See the lifecycle contract in `docs/spec/streams.md`.

Pipeline syntax is represented by syntax-only `vkPipeline`, associates
left-to-right, and preserves tail position only for the final stage. The
segment before the first delimiter is a single form. Multiple direct slots,
empty stages, syntax-call stages, a multi-form leading segment, and mixing
`->`/`=>` with `;` at one parenthesis depth are errors; `->` and `=>` mix with
each other. `;` remains head-folding reader sugar and has no slot behavior.
See [pipelines in the language guide](../language.md#pipelines-and-generators).

MVP compiler-dispatched heads:

<!-- compiler-head-dispatch:start -->
```text
do if if_yes if_not && || ?? ! let var const set new fn macro quote quasiquote
select path msg ns env eval import import_impl mod match while loop repeat for break
continue yield return try scope supervisor spawn await fail panic type alias enum
protocol impl derive web_module
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
structured cleanup bodies, constructors, namespaces/modules, `new`,
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
