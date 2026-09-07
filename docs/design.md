# Gene language design

Gene is a general-purpose, gradually typed language built around one node
model. Its syntax draws on Lisp, Clojure, XML/HTML, and Ruby/Smalltalk. The
implementation targets ordinary scripts, services, data processing, native
integration, and browser applications.

This document explains the main design choices. The [implemented
specification](spec/README.md) defines the contract; the [documentation
index](README.md) points to guides, implementation references, and future work.
Detailed numbered chapters live in the [language reference](reference/README.md).

## One value model

Every value has `head`, `props`, `body`, and `meta` projections. The same node
representation serves as data, syntax, a pattern, or a selector plan. Reader
sugar keeps common forms short without introducing a second data model.

A value's anatomy and its type are distinct. `Any` admits every value; `Node`
is a concrete type for node data. Types, protocols, and values retain nominal
identity where the contract requires it.

See [values and reader syntax](reference/syntax.md) and the
[reader contract](spec/reader.md).

## Source reveals evaluation

Ordinary calls evaluate their arguments eagerly. Dot sends dispatch messages
against the receiver; protocol-qualified sends identify a protocol contract.
They do not fall back to an arbitrary lexical function.

Fexprs use named `fn name!` declarations and explicit `name!` call sites. They
interpret syntax at runtime with borrowed access to caller bindings. Template
macros expand into ordinary lexical code before checking and execution. Their
binding and control-flow boundaries differ.

`->` sequences whole-value pipeline stages; `=>` maps a prepared stage lazily
over items. These are separate from `;`, which is reader head-folding sugar.

See [calls](spec/calls.md), [fexprs and macros](macro-design.md),
[pipelines](pipelines.md), and [proper tail calls](tail-calls.md).

## Types preserve contracts

Nominal types combine a schema, one nominal parent, and direct messages.
Protocols add behavior across unrelated types. Inheritance preserves the
contract callers already depend on; runtime dispatch selects the body.

`Self` binds to a declaration or protocol conformance. It does not narrow an
inherited signature to the receiver's runtime subtype. Explicit override
intent and shared signature comparison make replacements reviewable.

Gradual boundaries check values moving from dynamic code into annotated code.
Direct type construction creates checked data; `new` invokes constructor
logic with a pre-created receiver.

See [types](spec/types.md), [protocols](spec/protocols.md), [Self](self-type.md),
and [scoped implementations](scoped-impls.md).

## Absence and state are explicit

`nil` is a stored absence value. `void` means missing or no result, with
normalization defined at each boundary. `T?` means `T | Nil`; fixed parameters
with that annotation default to nil when omitted. Missing fields still read
as void.

`map` converts callback void to nil; `filter_map` drops only void. Lists and
streams preserve one result per input under map; sets retain deduplication.

Mutable collections, shallow immutable literals, Cells, and AtomicCells have
separate contracts. Immutability alone does not establish sendability.

See [nil and void](spec/nil-void.md), [state](reference/state.md), and
[streams](spec/streams.md).

## Concurrency has owners

Tasks, channels, actors, and streams have explicit lifetime and cleanup rules.
A scope owns its tasks. A consuming stream operation owns its upstream cleanup.
Errors, cancellation, and normal completion preserve those obligations.

The default runtime schedules cooperative fibers. An experimental bounded
worker lane supports eligible tasks and actor turns. Production M:N scheduling
and unrestricted foreign callbacks remain separate work.

See [concurrency](spec/concurrency.md), [concurrency rationale](reference/concurrency.md),
and the [scheduler spike](mn-scheduler-spike.md).

## Authority is separate from visibility

An Env supplies bindings; namespace exposure controls directly nameable APIs;
a capability context authorizes external operations. Resource handles identify
resources and retain origin restrictions. Execution policies impose limits.

A retained context is a ceiling. Evaluation and invocation intersect it with
the current context, so a broader saved Env or callback cannot restore removed
permissions. Ordinary CLI defaults are intended for trusted scripts; an Env
or namespace filter alone is not a complete sandbox.

See the [authority contract](spec/authority.md), [capability reference](capabilities.md),
and [module lifecycle](spec/modules.md).

## Packages and backends share semantics

Packages own source identity and dependency graphs. Modules own runtime
initialization and namespaces. Compile artifacts, package resolution, and
runtime loading are separate stages, so discovering a macro need not execute
its dependency's top level.

The VM is the general execution path. The web backend supports a checked,
explicit subset and rejects unsupported forms. Typed-native compilation uses
explicit representations and ownership adapters; it remains experimental.
Backends must preserve the contracts of the subset they accept.

See [packages](packages.md), [package builds](package-builds.md),
[web compilation](web-compilation.md), [web profile](web-profile.md),
[native types](native-types.md), and [wasm](wasm.md).

## Implementation discipline

The implemented contract lives in focused specification files and executable
specs. Feature references explain rationale, implementation seams, and known
limits. Dated measurements are [reports](reports/README.md), not timeless
performance claims. The [implementation status](implementation-status.md)
separates shipped behavior from remaining work.

New designs belong in [proposals](proposals/README.md). Once a feature ships,
its reference belongs beside the implemented feature docs, with deferred
extensions identified explicitly. Retired designs and obsolete rollout plans
belong in the [archive](archive/README.md).

The [reference index](reference/README.md) preserves the old chapter numbers
used by source comments. The original implementation checklist and settled
notes are [historical material](archive/initial-implementation-plan.md).
