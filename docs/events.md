# Events, pub/sub, and optional runtime instrumentation

Status: proposal

## 1. Recommendation

Gene should provide:

1. a general-purpose `event` library for application pub/sub; and
2. an optional runtime event producer controlled by runtime configuration.

These are related features, but they are not the same module.

Application code should be able to create an event bus, define event types,
subscribe handlers, publish values, and cancel subscriptions without involving
the VM:

```gene
(import gene/event [Bus])

(type UserCreated
  ^is $event/Event
  ^props {^user_id Str})

(var bus
  (Bus))

(var subscription
  (bus .subscribe UserCreated on_user_created))

(bus .publish
  (UserCreated ^user_id "u_123"))

(subscription .cancel)
```

(This first example deliberately shows both spellings side by side: `Bus` via
an explicit import for the name used repeatedly, `$event/Event` inline for a
name used once. Later examples generally pick whichever fits their code, not
both at once.)

Separately, a runtime may produce structured events for tooling,
observability, testing, profiling, and diagnostics:

```gene
(var bus
  ($event/Bus ^error_policy $event/collect))

(bus .subscribe
  $runtime/task/Completed
  on_task_completed)

(runtime_events .attach bus)
```

`runtime_events` in this example is a host-created
`$runtime/EventStream`. It is explicit runtime state supplied to the entry
program or embedding host, not a process-global bus available to every module.

Both `event` and `runtime` are ordinary lowercase stdlib namespaces, not
bare capability namespaces (`bareCapabilityNamespaces` in
`src/gene/compiler.nim` lists only `fs`). Per `staysBare`, a lowercase
namespace name is not kept bare when the standard library moves under `gene`
— it is reached as `gene/event`, `gene/runtime`, or the `$` sugar
`$event`/`$runtime`, exactly like `math` or `str`. Every `gene` code sample in
this document uses either an explicit `(import gene/event [...])` /
`(import gene/runtime [...])` for names it uses repeatedly, or the `$` sugar
inline; there is no bare `event/...` or bare `runtime/...` spelling in code.

Prose, by contrast, keeps writing `event/Bus`, `runtime/EventStream`, and
similar dotted paths throughout this document. Read those as **the logical
qualified name** — "the member `Bus` of the `event` namespace" — not as
literal executable syntax; the equivalent code is `$event/Bus` or
`(import gene/event [Bus]) ... Bus`. This is the same convention design docs
use elsewhere to talk about a stdlib member by its full path without
namespace-sugar noise. A few places make the declaration-shorthand version of
this explicit, marked "conceptually" or "illustrative" (§7.2, §11.1, §11.2,
§12.2, §13, §19): a `(type event/PublishResult ...)` or
`(type runtime/EventsDropped ...)` block shows a type's logical dotted path
as its declaration head for readability, not a literal `(type ...)` form —
the real declaration nests the type inside `(ns event ...)` / `(ns runtime
...)`, matching the executable `(ns order ...)` pattern in §6.2.

Runtime event production is off by default:

```text
gene run app.gene --runtime_events=module,task
```

The exact CLI spelling may be finalized with implementation, but
`runtime_events` is the canonical option name. A Boolean form is useful
sugar:

```text
false  -> no runtime events
true   -> the default low-volume event categories
```

Internally, configuration should always be a category mask rather than one
Boolean. High-frequency events such as calls, instructions, and allocations
must require explicit selection.

The central performance rule is:

> When a runtime event category is disabled, its emission site performs at
> most one predictable category check and performs no allocation, timestamp
> lookup, payload conversion, or subscriber dispatch.

The central safety rule is:

> The VM never invokes arbitrary Gene handlers directly from an event emission
> site.

The runtime writes compact native records into a bounded stream. An adapter
materializes Gene values and dispatches them only at safe points.

## 2. Goals

The event library should:

- make application event types ordinary Gene types;
- support exact, ancestor, and recursive family matching without string
  comparisons or subscriber scans;
- provide a small, predictable publish/subscribe interface;
- preserve deterministic subscriber ordering within one bus;
- make subscription lifetime explicit;
- define nested publication and handler-error behavior;
- avoid a global bus and a global topic namespace;
- support alternate sinks such as a bus, recorder, logger, or composite;
- work without runtime instrumentation being enabled;
- require no new runtime dependency.

Runtime instrumentation should:

- be disabled by default;
- be selectable by category;
- have near-zero disabled-path overhead;
- avoid allocating Gene values in VM hot paths;
- avoid reentrant Gene execution from VM internals;
- use bounded memory and explicit overflow behavior;
- avoid retaining arbitrary runtime object graphs;
- provide useful ordering and correlation identifiers;
- redact sensitive information by default;
- support native, embedded, test, and WASM profiles;
- expose a stable, versioned event interface to tools.

This proposal does not make event delivery a reliable audit log, a durable
message broker, or an actor mailbox replacement.

## 3. Non-goals

Version 1 does not provide:

- durable storage;
- delivery across processes or machines;
- exactly-once delivery;
- transactional publication with a database;
- arbitrary predicate execution in subscription indexes;
- global total ordering across runtime worker lanes;
- lossless delivery from VM hot paths;
- implicit access to a runtime event stream from every module;
- dynamic mutation of runtime instrumentation sites;
- cross-cutting event categories;
- a replacement for structured concurrency, actors, channels, or streams.

Matching is nominal and `^is` is single-inheritance, so an event belongs to
exactly one family. Orthogonal categories — "security-relevant", "retryable",
"user-initiated" — cannot be a second axis a subscription selects on. A handler
that wants one filters after delivery (§6.3). Runtime events are a closed set
designed around this; application hierarchies should stay shallow rather than
encode a second taxonomy by forking the tree.

Libraries may build durable or distributed systems on top of explicit
adapters later. Those semantics should not be implied by the word “event.”

## 4. Two distinct modules

### 4.1 Application event bus

`event/Bus` is a normal Gene value. It owns subscriptions and dispatches
events published by application code.

```gene
(var bus
  ($event/Bus))
```

Creating a bus does not enable runtime instrumentation.

### 4.2 Runtime event stream

`runtime/EventStream` is created by the host when runtime event production
is enabled. It owns or reads bounded native event queues.

It may feed any value implementing `EventSink`, normally through an adapter
that converts native records into frozen Gene event values.

```gene
(runtime_events .attach bus)
```

Creating or using an application bus does not imply that a runtime stream
exists. Enabling a runtime stream does not force application code to use
`event/Bus`; a host may instead attach a native profiler, test recorder, or
diagnostic writer.

This separation keeps the event library useful on its own and keeps runtime
instrumentation policy out of normal application publication.

## 5. The sink seam

Gene-level event consumers share one small protocol:

```gene
(protocol EventSink
  (message emit
    [event]
    : Nil
    ^errors [EventPublishError]))
```

`emit` declares `^errors [EventPublishError]` rather than leaving it dynamic
(design: "Missing `^errors` means dynamic/unchecked errors"). §7.2 and §12.3
make `EventPublishError` the entire mechanism by which an attached
`event/collect` bus cannot silently swallow observer failures — the adapter's
draining loop (§12.3) depends on catching exactly that raise. Leaving `emit`
unchecked would make the one deterministic, documented raise the interface
exists to guarantee into an unchecked contract, undercutting the "cannot be
misconfigured into silence" claim in §7.2.

`event/Bus` implements `EventSink`. Other useful implementations include:

- `event/RecordingSink` for tests;
- `event/NullSink`;
- `event/CompositeSink`;
- a structured logging sink;
- a tracing exporter;
- a bridge to an actor or channel.

The protocol deliberately has one message. Filtering, buffering, retries,
fan-out, serialization, and error policy belong behind sink implementations
instead of expanding the common interface.

Calling the protocol directly uses normal qualified message dispatch:

```gene
(sink .EventSink:emit event)
```

The native VM does not invoke this protocol at emission sites. It writes
native records to `runtime/EventStream`; a Gene-facing adapter invokes
`EventSink:emit` later at a safe point.

## 6. Application event identity

### 6.1 Events are nominal typed values

Every publishable event is an instance of `event/Event` or one of its
`^is` descendants:

```gene
(type OrderPlaced
  ^is $event/Event
  ^props {
    ^order_id Str
    ^total F64
  })

(bus .subscribe
  OrderPlaced
  handle_order)

(bus .publish
  (OrderPlaced
    ^order_id "o_123"
    ^total 19.95))
```

An event needs no separate topic string, tag field, or protocol
implementation. Its concrete nominal type is its identity and its `^is`
ancestry is its matching hierarchy.

Requiring `event/Event` gives the bus one inexpensive recognition rule and
prevents arbitrary scalars or unrelated typed data from becoming events by
accident. A value that is not an `event/Event` descendant fails `publish` with
`EventTypeError` before any freeze or dispatch — forgetting `^is event/Event`
is a normal typed value, so the rejection must name that cause rather than
surface as a missing-metadata internal error. Event payloads remain ordinary Gene typed nodes and use ordinary
field validation.

Because `^is` is single-inheritance, this also means a pre-existing domain
type cannot itself be published: an `Order` cannot become an event by adding
`^is event/Event` if it already has a domain `^is` parent, and every example
in this document declares a dedicated event type (`OrderPlaced`, not `Order`)
for exactly this reason. Events are snapshots of a domain occurrence, not the
domain entities themselves, and that separation is enforced by the type
system rather than being a style preference.

Using types provides:

- declaration identity instead of collision-prone strings;
- schema and property validation;
- a single matching hierarchy;
- natural reflection;
- useful diagnostics;
- no separate topic registry or per-event topic allocation.

Ad hoc string and symbol topics are deferred. They can be added later through
an explicit adapter without changing typed event publication.

### 6.2 Event families

Events are layered with Gene namespaces and nominal base types:

```text
event/Event
  runtime/Event
    runtime/module/Event
      runtime/module/Loaded
      runtime/module/Failed
    runtime/task/Event
      runtime/task/Spawned
      runtime/task/Completed
      runtime/task/Failed
```

**Each event-family namespace declares its family base type as `Event`.** This
is the only naming convention the design needs:

```gene
$event/Event
$runtime/Event
$runtime/module/Event
$runtime/task/Event
```

These are ordinary first-class type values. `runtime/task/Event` is a normal
qualified name resolving to a type declaration; the bus does not parse the
path or run a glob matcher.

For example, a family is declared as:

```gene
(ns order
  (type Event
    ^is $event/Event
    ^props {^request_id Str?})

  (type Placed
    ^is Event
    ^props {
      ^order_id Str
      ^total F64
    }))
```

`order/Placed` inherits from `order/Event`, and subscribing to `order/Event`
matches the whole family.

There is **no wildcard selector spelling**. An earlier draft reserved a `*`
member in each family namespace so `runtime/task/*` would resolve to
`runtime/task/Event`. That is dropped, because it was a second spelling for a
name the design already fixes, and it cost three things for no dispatch
benefit:

1. **`X/*` already means other things.** `(import order/* from "./m")` is the
   import wildcard (design §15.6), and it is recognized from exactly the reader
   output `order/*` produces — a `path` node whose last segment is the symbol
   `*`. The reader emits a deliberately *context-neutral* path node (design
   §2.1), so an expression-vs-import distinction for one segment spelling would
   put context-sensitivity back where the reader keeps it out. Separately,
   `docs/proposals/capabilities.md` §1 defines `fs/*` as a projection of the
   parent's current context — "inherit the filesystem grants my parent has made
   available," explicitly *not* "everything under `fs`" — which is close to the
   opposite of what a family wildcard would mean here.
2. **A namespace declaring `*` loses `*`.** `*` is the multiplication builtin
   and a native fast-path callee. A member named `*` shadows it for bare uses
   inside that namespace's own body, turning `(* a b)` into a runtime
   "not callable" error with no compile-time warning — in precisely the
   namespaces that define events.
3. **It is not a name.** Every registered, user-facing Gene name is
   `snake_case` (or `PascalCase` for types). `*` is an operator lexeme.

`Event` is exactly as uniform and as enforceable a convention as `*` would
have been, and it is the name this document already uses in every hierarchy
diagram and type declaration.

Subscribing to a family base type always includes that type and all of its
descendants. There is no separate single-level selector: event hierarchies are
expected to be shallow, and adding a second recursion depth would grow the
interface without improving dispatch. `event.*` and other dot-separated topic
spellings are not supported either; `/` is the only hierarchy separator, and
nominal `^is` ancestry is the only hierarchy.

### 6.3 Matching semantics

Subscribing to a type matches values of that type and its `^is`
descendants:

```gene
(bus .subscribe
  $runtime/task/Event
  record_task_event)

(bus .subscribe
  $runtime/task/Completed
  record_completed_task)
```

The first subscription matches every task event, because every task event
descends from `runtime/task/Event`. The second matches
`runtime/task/Completed` and any deliberate descendants of that concrete
event type.

An exact-type selector excludes descendants:

```gene
(bus .subscribe
  ($event/exact $runtime/task/Completed)
  record_exact_completed_task)
```

The root type subscribes to everything, so no separate `event/any` selector is
needed:

```gene
(bus .subscribe
  $event/Event
  record_everything)
```

A union selects several unrelated families at once:

```gene
(bus .subscribe
  (| UserCreated UserUpdated)
  on_user_change)
```

That is the entire selector grammar:

| Selector | Matches |
| --- | --- |
| `T` (any `event/Event` descendant type) | `T` and its `^is` descendants |
| `(event/exact T)` | `T` only |
| `(\| A B ...)` | the union of what each alternative matches |

`event/exact` returns an opaque `event/Matcher`. It is deliberately not called
`Selector`: `Selector` is already a registered type for reader selector
literals, and `capabilities.md` uses "capability selector" for a third thing.
"Selector" stays a prose term here; the value type is `Matcher`.

The union row is not a new spelling invented for the bus. `(| A B)` is the type
expression the language already takes in every annotation position, so a
selector and the handler signature that receives it name one thing. Each
alternative must itself be an `event/Event` descendant; `(| OrderPlaced Str)`
raises rather than matching the half that makes sense. An `alias` naming a
union selects identically, and unions flatten, so `(| (| A B) C)` is `(| A B C)`.

**A union is one subscription, not several.** An event matching two
alternatives invokes the handler once, and cancelling removes it from every
family it was registered under. This is the one case the two-subscription
workaround gets wrong rather than merely writes at length: subscribing `A` and
`B` separately is two subscriptions by the rule below, and a value that is both
would invoke the handler twice.

`subscribe` takes a `Type`, a union of them, or an `event/Matcher`, and raises
`EventTypeError` for anything else, including a `Type` that is not an
`event/Event` descendant.

Every subscription is independent. If the same handler is separately
subscribed to both `runtime/Event` and `runtime/task/Event`, a task event
invokes it twice in the corresponding subscription positions. The bus does not
silently deduplicate distinct subscriptions.

Version 1 does not execute arbitrary predicates to decide subscription
matching. A handler may filter after receiving an event, or a later adapter
may provide indexed domain-specific selectors.

### 6.4 Compact matching metadata

Each event type receives an application-local compact `event_type_id` and
an immutable flattened list of matching ancestor IDs:

```text
runtime/task/Completed:
  event_type_id = 42
  match_ids = [
    42, # runtime/task/Completed
    17, # runtime/task/Event
     4, # runtime/Event
     1  # event/Event
  ]
```

IDs identify type declarations, not names. Two modules declaring types with
the same printed path receive different IDs.

IDs and `match_ids` are assigned **eagerly, when the type is finalized** — not
lazily on first publication. Eager assignment keeps ID allocation a
declaration-phase property of the application's type table, so no lane bumps a
shared counter at first publish and §9's concurrency model has no race to
describe. Gene's single immutable `^is` parent makes the list stable. It should
be stored in type metadata, not on each event instance.

This requires no new `ValueKind` and no topic field in the event payload. A
typed node already points to its concrete `Type`; the optional event metadata
lives on that type. Compact IDs are application-local implementation details
and are never serialized as type identity.

ID assignment is an application-wide, runtime-internal table keyed by type
declaration. That is not the "global registration" §2 rules out: there is no
global bus, no process-wide topic namespace, and nothing a module can register
into, collide in, or observe. Event types are declared exactly like any other
type, and the table is derived from those declarations rather than populated by
them. The application owns the counter.

A bus maintains ordered subscription buckets:

```text
descendant_subscribers[event_type_id]
exact_subscribers[event_type_id]
```

Compact IDs are assigned per application, but buckets are owned per bus, so
these are sparse maps rather than arrays indexed by the application's type
counter. A bus with three subscriptions must not allocate storage proportional
to the number of event types the whole application declares. A bus that grows
large enough for the indirection to matter may remap to a dense bus-local
index; that is an implementation choice, not part of the interface.

For a concrete event type, the bus resolves:

1. the descendant bucket for every ID in `match_ids`;
2. the exact bucket for the concrete `event_type_id`;
3. one merged list ordered by the subscription sequence number.

The merged list is cached per concrete event type, and each cached entry
records the bus subscription generation it was built at. Subscribe and cancel
increment the generation. A publication whose cached entry carries a stale
generation rebuilds that one entry and re-stamps it; entries for types that are
never published again are never rebuilt.

A single bus-wide counter therefore invalidates every cached entry, and only
laziness keeps that cheap. An implementation that measures thrash — subscribing
repeatedly while publishing a hot type whose matches never change — may bump
only the generations of the types whose buckets a subscription actually
touches. The observable semantics are identical.

A publication in progress uses the snapshot it resolved at entry (§7.5); a
generation bump during dispatch never mutates the list currently executing.
This holds because a stale-entry rebuild (above) replaces the cached entry
with a newly built list rather than mutating the existing one in place — the
cache is copy-on-write. A publication that already read the old entry keeps
running against that unchanged list even if a concurrent subscribe or cancel
rebuilds the cache slot underneath it.

The common cached publication path is therefore:

```text
read the event's concrete type
read its compact event_type_id
read the bus's cached ordered match list
invoke only the matching subscriptions
```

It performs no path parsing, string-prefix comparison, type-name lookup,
predicate execution, or scan of unrelated subscriptions. Uncached resolution
uses an ordered merge and is `O(h + m log h)`, where `h` is nominal
ancestry depth and `m` is the number of matching subscriptions. Cached
dispatch is `O(m)`. Because event hierarchies are shallow, the merge can use
fixed small scratch storage rather than allocate.

### 6.5 Immutability

An event is a snapshot, not a shared mutable command.

`publish` deep-freezes the event before invoking any handler, using the same
deep `freeze` the language already provides (`docs/spec/types.md`
§"Deep `freeze` rejects a wrapper..."). If the value cannot be frozen,
publication fails before dispatch begins. A value already known to be frozen
takes the fast path described below.

**The freeze is copy-based, matching the implemented `freeze`, not in
place.** `freeze` (`biFreeze`/`freezeValue` in `src/gene/vm.nim`) builds a new
immutable `List`/`Map`/`Node` rather than mutating the input, and `thaw`
proves the original untouched: `($thaw ($freeze [1 {^a [2]}]))` round-trips to
the original mutable `[1 {^a [2]}]` (`tests/spec_runner.nim`,
"freeze helpers make mutability explicit"; `tests/test_vm.nim`,
"freeze and thaw convert container mutability explicitly"). An in-place deep freeze — one that mutates the
existing node and every reachable child to immutable — is a different,
unimplemented primitive, and it would have a sharp edge this proposal does not
want: freezing in place freezes every other alias of the value and of any
shared nested child, not just the publisher's reference, so a `List` shared
between the event payload and an unrelated variable would make that unrelated
variable's list silently immutable. `publish` does not do that. Instead:

```gene
(var e (OrderPlaced ^order_id "o_1" ^total 19.95))
(bus .publish e)
(set e/order_id "o_2")   # succeeds: e is unchanged, publish froze a copy
```

The value every subscriber receives is the frozen copy, not `e`. Code wanting
a mutable working value can keep mutating it after `publish` returns; nothing
it does afterward is observable through the event already delivered.

Deep-freezing a freshly constructed event is `O(payload)`, and events are
normally constructed at the publish site, so this traversal — not dispatch — is
the dominant cost of publishing a small event to few handlers. §17.3's
"proportional to matched handlers" requirement covers dispatch bookkeeping, not
the freeze. This copy cost is real and is the reason an implementation should
let an event be *constructed* already frozen (a construction-site flag, or
frozen literal props) so the common path skips both the traversal and the
allocation, rather than re-deriving that the value is immutable on every
publish. Constructing frozen is the only way to avoid the copy; there is no
in-place option to fall back on.

Both fast paths need an `O(1)` "already frozen?" answer for an arbitrary node.
The existing `immutable: bool` field on `GeneList`, `GeneMap`, and `GeneNode`
headers (`src/gene/types.nim`) is not that answer by itself: `freeze_shallow`
(`biFreezeShallow`) sets it directly on a node whose children are untouched,
so a top-level `immutable = true` node can still hold a mutable `Cell` or
`List` reachable through it. The O(1) fast path in §17.3 ("freeze an
already-frozen event without traversing it again") is therefore only sound
when "already frozen" means *constructed deep-frozen* — every reachable value
immutable from the moment the event was built.

Distinguishing that requires a **second, distinct header bit** — a
`deep_frozen: bool` alongside the existing `immutable: bool`, not a
repurposing of it. Two producers are allowed to set it: deep `freeze`
(`freezeValue`) sets it on every node it builds, because each child was
itself produced by a recursive `freezeValue` call and so is already
`deep_frozen`, which makes the composed invariant hold by construction; and
the event-construction-time "already frozen" path (the flag/frozen-literal-props
option above) must go through the same recursive guarantee — assembling props
only from values that are themselves already `deep_frozen`, or delegating to
`freezeValue` internally — before it may set the bit on the node it produces.
`freeze_shallow` must never set `deep_frozen`, only `immutable`, which keeps
the two bits meaning different things: `immutable` says "this container's own
head/props/body cannot change," `deep_frozen` says "nothing reachable from
here can change." `publish`'s O(1) check reads `deep_frozen`, not `immutable`;
a value whose immutability was only ever established shallowly still takes
the full deep-freeze traversal.

Freezing ensures:

- every subscriber sees the same event value;
- one handler cannot modify what later handlers observe;
- a queued or cross-lane adapter can validate `Send` independently;
- retaining an event does not retain mutable publication state accidentally.

The bus does not freeze values reachable only through opaque native resources.
Such values fail the ordinary freeze validation unless their type explicitly
supports safe frozen identity.

## 7. Event bus interface

`event` is a new stdlib root, registered under `gene/event` like every other
lowercase stdlib namespace (`math`, `str`, `stream`, `log`, ...). Case is the
rule the compiler already enforces (`staysBare` in `src/gene/compiler.nim`):
an uppercase name is a type and stays bare so annotations keep resolving
structurally, but a lowercase name is a namespace and is reached as
`gene/event`/`$event`, not bare. The only bare capability namespace is `fs`
(`bareCapabilityNamespaces`); `event` is not on that list, and this proposal
does not ask for it to be added. So `$event/Bus` and
`(import gene/event [Bus])` both work; bare `event/Bus` does not. `runtime`
follows the same rule (§13, §15) — it is reached as `gene/runtime`/`$runtime`,
the same posture `$runtime/load_sandboxed` already relies on. Its members:

| Member | Kind |
| --- | --- |
| `Event` | root event type (§6.1) |
| `Bus`, `Subscription`, `PublishResult`, `Matcher` | types |
| `exact` | function, `Type -> Matcher` |
| `ErrorPolicy` | enum: `raise_after`, `collect` (§8) |
| `RecordingSink`, `NullSink`, `CompositeSink` | `EventSink` implementations (§5) |

### 7.1 Subscribe

```gene
(bus .subscribe
  event_selector
  handler)
```

The handler receives one event:

```gene
(fn on_user_created
  [event : UserCreated]
  ...)
```

`subscribe` returns an opaque `event/Subscription`.

**`subscribe` validates the handler against the selector.** The handler must
take one parameter, and its declared parameter type must accept every value the
selector can match — that is, the selector's type must be the parameter type or
an `^is` descendant of it. Otherwise `subscribe` raises `EventTypeError`.

Without this check, a narrowly annotated handler on a family selector is
accepted and then fails once per non-matching event, at dispatch time:

```gene
(bus .subscribe
  $runtime/task/Event
  record_completed)          # [event : $runtime/task/Completed]
```

Under the default error policy that surfaces as an `EventPublishError` raised
at the *publisher*, which did nothing wrong, and only for the subset of task
events that happen to occur. Both types are in hand at subscribe, so the check
is cheap and converts a recurring runtime failure into one declaration-site
error.

An unannotated handler parameter accepts any event and always passes.

Optional properties:

```gene
(bus .subscribe
  UserCreated
  on_user_created
  ^once true)
```

`^once true` removes the subscription after its first attempted delivery,
whether the handler returns or raises. This prevents an erroring one-shot
handler from being invoked indefinitely.

Subscriber priority is deferred. Version 1 dispatches in successful
subscription order.

### 7.2 Publish

```gene
(bus .publish event)
```

`publish`:

1. validates and freezes the event;
2. snapshots the matching subscriptions;
3. invokes them in subscription order;
4. records deliveries and handler failures;
5. applies the bus's error policy;
6. returns `event/PublishResult`, or raises per §8.

Conceptually:

```gene
(type event/PublishResult
  ^props {
    ^matched Int
    ^delivered Int
    ^failed Int
    ^errors (List Error)
  })
```

`PublishResult` is the return type under both error policies. The policy
governs only whether a publication with failures *raises* instead of returning
(§8).

The bus implements `EventSink:emit` by publishing the event and **reporting a
nonzero `failed` count as a sink failure**, regardless of the bus's own error
policy.

This matters when a bus is attached to a runtime stream (§13). Under
`event/raise_after` the failures already leave the bus as an
`EventPublishError`, which the adapter records (§12.3). Under `event/collect`
the bus returns them in `PublishResult` instead — and if `emit` discarded that
result, handler failures inside an attached observation bus would be invisible:
the adapter would see a successful sink call, `sink_failures` in §19 would stay
zero, and there is no other channel through which the failure could surface.
`emit` therefore raises `EventPublishError` carrying the collected failures
when `failed` is nonzero. `collect` still does what it is for — it keeps one bad
handler from aborting the others and keeps the failure away from the *publisher*
— but it does not silently swallow failures at the sink boundary.

### 7.3 Cancel

```gene
(subscription .cancel)
```

Cancellation is idempotent. It returns whether the subscription changed from
active to cancelled.

A subscription keeps its handler reachable until cancellation or bus close.
Garbage collection of the `Subscription` wrapper does not implicitly cancel it;
relying on nondeterministic collection for observable behavior would make event
delivery unpredictable.

### 7.4 Close

```gene
(bus .close)
```

`close` cancels every subscription, releases the handler references, and is
idempotent. Afterwards `subscribe` and `publish` raise `EventBusClosedError`;
`cancel` on an already-cancelled subscription stays a no-op.

A close during publication does not invalidate the snapshot currently
executing (§7.5) — the in-flight publication runs to completion, and only the
next one raises. Without an explicit close there is no way to release a bus's
handlers deterministically, since §7.3 rules out collection-driven
cancellation.

### 7.5 Subscription mutation during publication

Publication uses a subscription snapshot:

- a subscription added during publication starts with the next event;
- a cancellation during publication takes effect for the next event;
- a one-shot subscription is marked consumed before its handler runs;
- closing the bus prevents future publication but does not invalidate the
  snapshot currently executing (§7.4).

These rules keep dispatch independent of collection mutation.

### 7.6 Nested publication

Synchronous nested publication is allowed and is depth-first:

```text
handler A receives event 1
  handler A publishes event 2
    all event 2 handlers run
  handler A resumes
remaining event 1 handlers run
```

The bus enforces a configurable nesting limit with a conservative default.
Exceeding it raises `EventRecursionError` before dispatching the nested
event.

Queued delivery is a separate adapter and may choose FIFO breadth-first
semantics. Its interface must say so explicitly.

## 8. Handler errors

A subscriber error must not silently prevent unrelated subscribers from
running. The bus catches handler errors, continues through the publication
snapshot, and applies one of these policies afterward:

```gene
$event/raise_after
$event/collect
```

`event/raise_after` is the default:

- all matching handlers are attempted;
- if any fail, the bus raises one `EventPublishError` containing the ordered
  failures;
- otherwise `PublishResult` is returned.

`event/collect` always returns `PublishResult` from `publish` and leaves error
handling to the publisher:

```gene
(var bus
  ($event/Bus
    ^error_policy $event/collect))
```

The policy governs `publish` only. `EventSink:emit` reports a nonzero `failed`
count under either policy (§7.2), so choosing `collect` for an attached
observation bus does not hide handler failures from the runtime stream's
statistics.

Runtime instrumentation uses collect-and-report behavior. An observer failure
must not replace the application error, module result, task result, or VM
control flow that caused the event.

A configurable error sink may be added after its recursion rules are
specified. It is not required for version 1.

## 9. Concurrency model

### 9.1 Local bus

The version 1 `event/Bus` is lane-owned and synchronous.

- subscribe, cancel, and publish occur on the owning lane;
- handlers run on that lane;
- the bus itself does not introduce tasks;
- no global lock is required.

Attempting to use a lane-owned bus directly from another lane is a normal
task-boundary error.

### 9.2 Cross-lane delivery

Cross-lane publication uses an adapter backed by an actor or bounded channel.
The adapter validates that the frozen event satisfies `Send`, transfers the
snapshot, and publishes it on the destination bus's lane.

This keeps cross-lane scheduling and backpressure explicit instead of putting
hidden locking and cloning into every local publication.

### 9.3 Ordering

One local bus guarantees:

- subscription-order delivery for one event;
- caller-order publication within one lane;
- the nested-publication rule in §7.6.

It does not promise a total order for events concurrently submitted through
different cross-lane adapters. An adapter needing a total order must provide
one and pay its synchronization cost explicitly.

## 10. Runtime event configuration

### 10.1 Configuration forms

Conceptually, runtime creation accepts:

```gene
(RuntimeConfig
  ^runtime_events false)
```

```gene
(RuntimeConfig
  ^runtime_events true)
```

```gene
(RuntimeConfig
  ^runtime_events [
    lifecycle
    module
    task
    actor
  ])
```

The normalized representation is:

```text
RuntimeEventConfig {
  category_mask
  category_options
  buffer_capacity
  include_timestamps
  overflow_policy
}
```

`false` normalizes to an empty category mask. `true` normalizes to the
documented default category set, not to every category.

`all` explicitly enables all compiled instrumentation:

```gene
^runtime_events all
```

It should warn outside tests and diagnostic tooling because it may include
high-frequency events.

### 10.2 Categories

Recommended initial categories:

| Category | Examples | Expected volume |
| --- | --- | --- |
| `lifecycle` | runtime started, stopping, stopped | very low |
| `module` | module load started, loaded, failed | low |
| `task` | spawned, completed, failed, cancelled | medium |
| `actor` | actor spawned, stopped, mailbox overflow | medium |
| `capability` | reserved; shapes not yet defined | low to medium |
| `gc` | collection started, completed, heap summary | low |
| `call` | function/message call and return | high |
| `allocation` | heap allocation samples | very high |
| `instruction` | VM instruction execution | extreme |

The category symbols `module` and `task` are configuration selectors, not
namespace references — `^runtime_events [module task]` does not name
`gene/runtime/module` or `gene/runtime/task`. For these two categories they
happen to print the same as the family namespaces §11.2 concretely defines
for them (`runtime/module/Loaded`, `runtime/task/Completed`), which is
intentional — enabling the `module` category is what makes `runtime/module/*`
events exist to subscribe to — but can read as a collision at a glance. No
resolution ambiguity exists — one is a bare config symbol in a category list,
the other is a qualified type path — but a reader skimming
`^runtime_events [module task]` next to `runtime/module/Loaded` should read
the pairing as "this category populates that family," not as two spellings of
the same name.

This one-category-to-one-family pattern is confirmed only for `module` and
`task`, the two categories §11.2 defines event types for. It is the expected
shape for the rest — `lifecycle`, `actor`, `gc`, `call`, `allocation`, and
`instruction` should each get their own `runtime/lifecycle/Event`,
`runtime/actor/Event`, and so on, as direct children of `runtime/Event` — but
this proposal does not name those family base types or their concrete event
types. §11.2's diagram and declarations should grow the remaining families
before Phase 2 instruments those categories; until then, treat "the category
you enable is the family you receive" as the design intent, not something
already specified for every row in the table above.

The `capability` category is reserved but **not implementable yet**.
`docs/proposals/capabilities.md` §15 lists four audit event *kinds* — grant
creation, entry and call-site attenuation, denied selector resolution, native
operation use — but defines no concrete event shapes, and its §19 still defers
whether audit hooks are built in at all. Until that proposal defines
`runtime/capability/Denied` and its siblings, this one has nothing to
transport. It stays out of the default set, and capabilities.md owns the shapes
when they land.

The default `true` set should be:

```gene
[
  lifecycle
  module
  task
  actor
  gc
]
```

`capability` joins it once its event shapes exist. `call`, `allocation`, and
`instruction` require explicit selection.

Category-specific options use ordinary named properties:

```gene
^runtime_events [
  module
  task
  (call ^sample_rate 0.01)
  (allocation ^sample_rate 0.001)
]
```

Sampling must be performed before payload construction.

### 10.3 Fixed for one runtime

Version 1 fixes the category configuration when the runtime is created.

This provides:

- predictable overhead;
- simple queue provisioning;
- no races while changing instrumentation;
- reproducible tests;
- an opportunity for native profiles to omit unused trace points.

Dynamic enable and disable may be added later at scheduler safe points. It
must not be simulated by registering and unregistering subscribers while the
runtime continues producing every category.

## 11. Runtime event records

### 11.1 Native emission record

The runtime hot path writes a compact native record, conceptually:

```text
RuntimeEventRecord {
  kind
  producer_id
  sequence
  flags
  field_a
  field_b
  field_c
}
```

This layout is illustrative, not an ABI commitment.

Emission must not:

- allocate a Gene `Value`;
- allocate a string;
- retain an arbitrary object graph;
- dispatch a protocol message;
- execute a subscriber;
- acquire a process-global contended lock;
- read a clock when timestamps are disabled.

Names and source locations should use stable interned IDs. The consumer may
resolve those IDs while materializing the public event.

### 11.2 Public runtime event values

Materialized runtime events are frozen typed values under the `runtime`
namespace.

A common base type provides correlation fields. Declaration heads below are
written as dotted paths for readability, the same illustrative shorthand
§11.1 uses for the native record layout; the real declaration nests each
type inside `(ns runtime ...)` and `(ns runtime (ns module ...))` /
`(ns runtime (ns task ...))`, matching the `(ns order ...)` pattern in §6.2:

```gene
(type runtime/Event
  ^is $event/Event
  ^props {
    ^producer_id Int
    ^sequence Int
    ^time_ns Int?
    ^task_id Int?
  })
```

Each runtime category defines a family base type and its specific events
extend that base:

```gene
(type runtime/module/Event
  ^is $runtime/Event)

(type runtime/module/Loaded
  ^is $runtime/module/Event
  ^props {
    ^module_id Int
    ^module_name Str
    ^duration_ns Int?
  })

(type runtime/task/Event
  ^is $runtime/Event)

(type runtime/task/Completed
  ^is $runtime/task/Event
  ^props {
    ^completed_task_id Int
    ^duration_ns Int?
  })
```

These family base types are what a subscriber names to observe a whole
category: `runtime/Event` for everything, `runtime/module/Event` or
`runtime/task/Event` for one family. The nominal `^is` chain is the only
hierarchy; there is no parallel topic hierarchy to keep in sync with it.

`^producer_id` and `^task_id` on `runtime/Event` identify the *observing
context* — which producer emitted the record and, if it happened inside a
task, which task that was. They are not the subject of the event. A concrete
event's own subject gets its own field, disambiguated by name, as
`runtime/task/Completed` does with `^completed_task_id`: for a task-lifecycle
event the inherited `^task_id` and the concrete `^completed_task_id` may
coincide, but they need not — a module-load event's `^task_id` identifies the
task that triggered the load, while a future cross-task event (one task
observing another's completion, say) would have a `^task_id` distinct from
whatever subject field names the task it is about. Concrete event types should
follow the same pattern: give the subject its own specifically-named field
rather than overloading the inherited correlation fields to mean two things.

Field names and meanings are a versioned interface. New optional fields may
be compatible. Renaming fields, changing units, changing identity semantics,
or changing when an event is emitted requires normal compatibility review.

### 11.3 Identity instead of retained values

Runtime events should normally carry stable IDs and summaries:

```text
task_id
actor_id
module_id
function_id
type_id
source_span_id
```

They should not retain arbitrary `Value` references merely to make a
debugger convenient. Retaining live values can:

- extend object lifetimes;
- turn a bounded queue into unbounded retained memory;
- cross lane ownership incorrectly;
- expose secrets;
- perturb garbage collection enough to invalidate profiling.

A debugger requiring live value inspection should use a separate paused-VM
inspection interface.

## 12. Runtime stream and adapter

### 12.1 Bounded buffering

Each producer writes to a bounded queue owned by
`runtime/EventStream`. A multi-lane runtime should prefer per-producer
queues so emission does not contend on one global lock.

The stream preserves order within each producer:

```text
(producer_id, sequence)
```

It does not manufacture a global total order. Optional timestamps can help
tools merge streams, but equal or coarse timestamps do not define causality.

Task parent IDs, message IDs, and explicit correlation IDs should express
causal relationships directly.

### 12.2 Overflow

Runtime event emission must not block application execution by default.

**The overflow policy is drop-oldest.** When a queue is full:

1. the oldest unconsumed record is overwritten by the new one;
2. a per-category dropped counter is incremented;
3. the consumer later materializes one `runtime/EventsDropped` summary.

Drop-oldest is chosen deliberately over dropping the incoming record. A queue
overflows exactly when the runtime is producing faster than the consumer
drains, which is the situation around a stall, a cascade of failures, or a
crash — and in that situation the records adjacent to the failure are the ones
worth keeping. Dropping the newest record preserves whatever happened to be in
the buffer first, which for the diagnostic uses in §1 is the least useful
window. This also matches the ring buffers §20 recommends for native profiles,
so one policy holds across profiles.

`runtime/EventsDropped` must carry enough information to locate the gap, not
only its size:

```gene
(type runtime/EventsDropped
  ^is $runtime/Event
  ^props {
    ^dropped_producer_id Int
    ^dropped_count Int
    ^first_dropped_sequence Int
    ^last_dropped_sequence Int
  })
```

The inherited `^producer_id` and `^sequence` describe the summary itself, which
the consumer synthesizes; `^dropped_producer_id` and the dropped sequence span
describe the queue that lost records. They are deliberately separate fields.

Because per-producer sequence numbers are assigned at emission and never
reused (§12.1), a consumer that sees a sequence discontinuity can align it with
the summary and know precisely which span it did not observe. A bare count
would leave a tool unable to distinguish "lost the startup burst" from "lost
the records immediately before the failure."

The summary is synthesized by the consumer and is not inserted recursively
through the full queue.

Configuration should expose buffer capacity. A lossless mode is not part of
version 1. Tests needing complete traces must provision sufficient capacity
and fail if the dropped count is nonzero.

Audit trails requiring guaranteed delivery need a different module with
explicit blocking, persistence, and failure semantics.

### 12.3 Safe-point draining

The runtime adapter drains records only where Gene execution is safe, such
as:

- scheduler turns;
- task yields;
- after module activation commits;
- before returning control to an embedding host;
- orderly runtime shutdown;
- an explicit test or host flush.

It must not invoke Gene while:

- the allocator or collector is in an unsafe phase;
- a dispatch or module registry is partially mutated;
- a native frame forbids reentry;
- a capability provider holds an internal lock;
- an error object is only partially constructed.

The safe-point adapter:

1. reads native records;
2. resolves interned IDs;
3. creates and freezes the public event value;
4. emits it to the attached `EventSink`;
5. catches anything `emit` raises, increments `sink_failures` (§19), and
   continues draining — without changing the observed operation's result.

Step 5 is why `EventSink:emit` must surface handler failures rather than
absorb them (§7.2). A sink that returns normally is indistinguishable from a
sink that worked, so a bus configured with `event/collect` would otherwise
report perfect health while every handler failed. `stats` is the only channel
through which a program learns that its observers are broken.

### 12.4 Observer recursion

Runtime instrumentation is suppressed while the Gene-facing adapter invokes
runtime-event observers.

Without suppression, observing a call would make another call, which would
produce another event and recurse indefinitely.

Observer work may later be traced under an explicit
`trace_observers` diagnostic option with a hard recursion bound. It is
disabled by default.

Application publication through `event/Bus` is not suppressed; the
suppression applies only to runtime instrumentation generated by observer
dispatch.

## 13. Supplying the runtime stream

`Application` is not ambient in Gene, and the runtime event stream should
follow that rule.

An embedding host may:

- attach a native sink when creating the runtime;
- retain the stream for an external tool;
- pass the stream explicitly to the entry function;
- omit the stream entirely when events are disabled.

A conceptual entry function is:

```gene
(fn main
  [
    args : (List Str)
    ^runtime_events : $runtime/EventStream?
  ]
  (if runtime_events
    (runtime_events .attach app_event_bus))
  ...)
```

The concrete CLI-to-`main` injection rule should align with Gene's existing
explicit named entry grants. It must not search a global namespace to satisfy
`runtime_events`.

When a Gene sink attaches after startup, it may request buffered bootstrap
events if they remain in the bounded stream:

```gene
(runtime_events .attach
  app_event_bus
  ^replay_buffer true)
```

`^replay_buffer false` starts with the next record. The default should be
`true` for a newly attached sole consumer so module-startup diagnostics are
not needlessly lost.

**Replay is best-effort and bounded by `buffer_capacity`.** Nothing drains the
queue before a sink attaches, so a startup that produces more records than the
buffer holds overflows it, and per §12.2 the oldest records — the earliest
bootstrap events — are the first ones lost. The default cannot promise a
complete prefix; it promises only whatever the bounded queue still holds.

`attach` therefore reports what replay actually delivered, so a caller that
needs a complete prefix can tell:

```gene
(var replayed
  (runtime_events .attach recorder ^replay_buffer true))

(expect replayed/dropped_before_attach 0)
```

`attach` returns a `runtime/AttachResult`:

```gene
(type runtime/AttachResult
  ^props {
    ^replayed_count Int
    ^dropped_before_attach Int
    ^first_replayed_sequence Int?
  })
```

A test asserting on startup events (§14.4) must check
`dropped_before_attach` rather than assume the buffer held. Provisioning
capacity for the startup burst is the program's responsibility.

A stream accepts one effective sink in version 1. Fan-out belongs in
`event/CompositeSink`. Replacing an attached sink is an explicit detach and
attach operation performed at a safe point.

## 14. Concrete examples

### 14.1 User-defined application events

```gene
(import gene/event [Bus])

(type PaymentReceived
  ^is $event/Event
  ^props {
    ^payment_id Str
    ^amount F64
  })

(fn update_balance
  [event : PaymentReceived]
  ...)

(fn record_payment
  [event : PaymentReceived]
  ...)

(var bus
  (Bus))

(bus .subscribe
  PaymentReceived
  update_balance)

(bus .subscribe
  PaymentReceived
  record_payment)

(bus .publish
  (PaymentReceived
    ^payment_id "p_123"
    ^amount 50.00))
```

Both handlers receive the same frozen event in subscription order.

### 14.2 One-shot event

```gene
(type ApplicationReady
  ^is $event/Event)

(bus .subscribe
  ApplicationReady
  warm_cache
  ^once true)
```

The subscription is consumed before `warm_cache` runs, so nested publication
of `ApplicationReady` does not invoke it twice.

### 14.3 Runtime task observation

The runtime starts with:

```gene
^runtime_events [task]
```

The entry program receives `runtime_events` explicitly:

```gene
(var observations
  ($event/Bus
    ^error_policy $event/collect))

(observations .subscribe
  $runtime/task/Completed
  record_task_duration)

(runtime_events .attach observations)
```

The `^error_policy` here governs direct `publish` calls on `observations`, not
the attached path. At the sink boundary the two policies behave identically:
`EventSink:emit` reports handler failures under both (§7.2), and the adapter
counts them and keeps draining under both (§12.3). So a broken
`record_task_duration` shows up in the stream's `sink_failures` count either
way, and attaching a bus cannot be misconfigured into silence.

The VM records task completions in native queues. At a scheduler safe point,
the adapter materializes `runtime/task/Completed` values and publishes them
to `observations`.

### 14.4 Test recorder

```gene
(var recorder
  ($event/RecordingSink))

(var replayed
  (runtime_events .attach recorder))

(run_scenario)
(runtime_events .flush)

(var stats
  (runtime_events .stats))

(expect replayed/dropped_before_attach 0)
(expect stats/dropped 0)

(expect
  (recorder .events)
  ^contains_type $runtime/module/Loaded)
```

`flush` drains records already emitted. It does not wait for unrelated
tasks to finish.

A test asserting on a complete trace must check both dropped counts, per §12.2
and §13. Without them the assertion is conditional on buffer capacity: a
scenario that overflows the queue silently loses the oldest records, and
`^contains_type` failing would look like a runtime bug rather than an
under-provisioned buffer.

### 14.5 Multiple consumers

```gene
(var sink
  ($event/CompositeSink [
    metrics_bus
    trace_recorder
  ]))

(runtime_events .attach sink)
```

The composite owns fan-out order and error handling. The runtime stream still
knows about only one sink.

## 15. Privacy and authority

Runtime events can reveal sensitive structure even when they do not contain
raw values:

- module names and source locations;
- task and actor topology;
- capability-denial targets;
- timing information;
- function and type identities;
- failure summaries.

Therefore:

- runtime events are disabled by default;
- the host chooses whether to create and expose the stream;
- ordinary modules receive no ambient stream;
- entry code decides whether to pass the stream or derived events onward;
- host paths, source text, arguments, environment values, and credentials are
  excluded by default;
- optional detailed fields require explicit configuration and redaction rules.

This feature is separate from the capability proposal. A future runtime may
represent access to `runtime/EventStream` as a capability grant, but the
event library must not depend on that mechanism. Explicit possession of the
stream value is sufficient for the initial interface.

**Sandboxed modules cannot name the runtime event surface, and that is
intended.** `runtime` is already in `sandboxableNamespaces` and is not granted
by default, so a sandboxed module sees no `runtime` namespace at all — it
cannot resolve `$runtime/EventStream`, `$runtime/task/Completed`, or any other
`gene/runtime/...` type. The refusal is a missing namespace rather than a
check, which is the same posture `$runtime/load_sandboxed` (design §D5)
already relies on.

This means a runtime event value must not be handed to a sandboxed module as a
`runtime/...`-typed value it is expected to match on. A host that wants a
sandboxed module to observe events passes it an `event/Bus` and publishes
host-defined application event types onto it, translating from runtime events
outside the sandbox. That keeps the translation — and the redaction decisions
above — on the host's side of the boundary.

Unsandboxed modules are unaffected: they receive the full stdlib, so
`runtime/...` types resolve normally and §13's explicit-possession rule is the
only thing gating the stream.

Capability audit events also remain ordinary runtime event records. They do
not replace capability enforcement and do not need to be enabled for
enforcement to work.

## 16. Determinism

Application bus delivery is deterministic when publication and subscription
occur on one lane.

Runtime instrumentation can affect:

- execution time;
- scheduling opportunities at drain points;
- memory pressure when enabled;
- observer-visible timestamps.

It must not affect:

- the return value of the instrumented operation;
- which application error propagates;
- capability decisions;
- dispatch selection;
- module publication;
- task cancellation semantics.

Deterministic test mode should support:

- timestamps disabled or supplied by a deterministic clock;
- fixed producer IDs;
- fixed queue capacities;
- explicit flush points;
- dropped-event assertions;
- sampling driven by a seeded deterministic generator.

Runtime observers are user code and may themselves mutate application state if
the entry program gives them access. The runtime guarantees that observer
return values and failures do not control the instrumented VM operation; it
cannot promise semantic non-interference for arbitrary observer side effects.

## 17. Performance requirements

Performance is part of the interface.

### 17.1 Disabled path

For a disabled category:

- no `Value` construction;
- no heap allocation;
- no timestamp read;
- no string formatting;
- no queue access;
- no reference-count change;
- no global lock;
- at most one predictable mask check.

The fully disabled mask should be stored where the VM can read it without a
heap traversal on each hot event site.

### 17.2 Enabled path

For an enabled category:

- use fixed-size native records when possible;
- use interned numeric identities;
- reserve queue memory at runtime creation;
- prefer per-producer queues;
- sample before materializing optional data;
- aggregate repetitive counters rather than emitting one record when event
  identity is unnecessary;
- defer Gene allocation and formatting to the consumer.

High-frequency instrumentation needs isolated benchmarks. An acceptable
overhead for module events says nothing about call or instruction tracing.

### 17.3 Application bus

`event/Bus` should:

- assign event types compact application-local IDs;
- store descendant and exact subscription buckets by compact ID;
- store each event type's immutable flattened event ancestry in type metadata;
- cache the globally ordered matching subscription list per concrete event
  type, stamped with the bus generation it was built at;
- rebuild a stale cache entry lazily, on the next publication of that type;
- avoid copying handler lists when no mutation occurred;
- avoid parsing names, comparing path strings, or scanning unrelated
  subscriptions during publication;
- freeze an already-frozen event without traversing it again — where
  "already frozen" means constructed deep-frozen (§6.5), not merely bearing a
  `freeze_shallow`-set top-level `immutable` bit — and allow an event to be
  constructed already frozen;
- keep publish *bookkeeping* proportional to matched handlers.

The last point is about dispatch only. Deep-freezing a freshly constructed
event is `O(payload)` and dominates the cost of publishing a small event to few
subscribers (§6.5); benchmarks should report freeze and dispatch separately so
a payload-size regression is not read as a dispatch regression.

## 18. Error types

Recommended application event errors:

- `EventTypeError`: invalid event or selector, or a handler whose declared
  parameter type cannot accept everything its selector matches (§7.1);
- `EventFrozenError`: event cannot be safely frozen;
- `EventPublishError`: one or more handlers failed — raised by `publish` under
  `event/raise_after`, and by `EventSink:emit` under either policy (§7.2);
- `EventRecursionError`: nested publication exceeded the bus limit;
- `SubscriptionError`: invalid bus/subscription ownership operation;
- `EventBusClosedError`: subscribe or publish after close.

Recommended runtime stream errors:

- `RuntimeEventsDisabled`: an operation requires a stream that was not
  configured;
- `RuntimeEventConfigError`: unknown category or invalid option;
- `RuntimeEventAttachError`: conflicting sink attachment;
- `RuntimeEventFlushError`: safe draining could not complete.

There is no `RuntimeEventSinkError`: per §12.3, a sink failure during draining
is caught, counted in `sink_failures` (§19), and draining continues — it is
never raised to anything. Introducing an error type with no raise site would
be dead interface surface; a future version that adds one (for example,
validating a sink at `attach` time before any record is delivered, distinct
from a failure encountered while draining) should name the specific trigger
when it lands.

Sink failures should be inspectable through stream statistics or the host
diagnostic hook. They must not replace the application operation that emitted
the observed record.

## 19. Stream statistics

The runtime stream should expose a cheap immutable snapshot:

```gene
(runtime_events .stats)
```

Conceptually:

```gene
(type runtime/EventStats
  ^props {
    ^produced Int
    ^delivered Int
    ^dropped Int
    ^sink_failures Int
    ^queued Int
  })
```

Per-category counts may be included behind a named option if constructing the
full map is nontrivial.

Statistics are diagnostic and may race with active producers. They need not
be one globally atomic snapshot, but each field must be memory-safe and
monotonic where documented.

## 20. WASM, native, and embedding profiles

The same public event types and category names should work across profiles.

Native runtimes may use:

- per-thread ring buffers, overwriting oldest per §12.2;
- monotonic native clocks;
- background native consumers for host-only sinks.

WASM runtimes may use:

- one bounded linear-memory queue, also overwriting oldest;
- host callbacks scheduled outside unsafe VM frames;
- browser performance timestamps when explicitly enabled;
- a host adapter that forwards records to developer tools.

The per-thread ring buffers, monotonic native clocks, and background native
consumers listed above are host-only subsystems and must carry the
`when not defined(geneWasm)` gate the rest of the runtime uses — WASM still
needs producers and a queue of its own, just the linear-memory ones described
above, not these. Ungated host-only code has regressed the wasm payload
before, and `nimble test` does not catch it — only `nimble wasm` rebuilds.

An embedding host may supply a native sink without materializing Gene values.
The native sink interface is internal and receives versioned
`RuntimeEventRecord` data, not arbitrary pointers into the Gene heap.

Native and Gene sinks should be testable against the same logical event
catalog even when their physical representations differ.

## 21. Relationship to logging, tracing, actors, and channels

### 21.1 Logging

Logs are authored diagnostic records. Runtime events are structured facts
about runtime transitions.

A logging sink may render events, but the runtime should not convert every
event into a log string at emission time.

### 21.2 Tracing

Tracing needs span relationships, sampling, timestamps, and exporters. It can
be built as a runtime-event consumer plus application-defined span events.

If tracing later requires context propagation in every call, that is a
separate design decision. It should not be smuggled into the basic event bus.

### 21.3 Actors and channels

Actors and channels define concurrency, ownership, buffering, and
backpressure. A local event bus defines in-lane fan-out.

Cross-lane event delivery should use an actor or channel adapter instead of
duplicating their scheduler semantics inside `event/Bus`.

### 21.4 Audit

An audit log may require lossless writes, durability, access controls,
signatures, and failure propagation. The best-effort runtime stream does not
provide those guarantees.

Audit can consume selected events only when losing them is acceptable.
Security-critical audit requires a dedicated module.

## 22. Implementation plan

### Phase 1: application bus

1. Add typed `event/Bus`, `event/Subscription`, and
   `event/PublishResult`.
2. Add `EventSink` and make `Bus` implement it.
3. Add the `event/Event` root and the event-family base types.
4. Add compact event type IDs, flattened matching ancestry, descendant
   buckets, exact buckets, and generation-stamped resolved-list caches.
5. Implement type and `event/exact` selectors, and subscribe-time
   handler/selector compatibility checking.
6. Add deep-freeze validation, snapshot dispatch, cancellation, close, and
   one-shot subscriptions.
7. Add `raise_after` and `collect` policies.
8. Add recording, null, and composite sinks.
9. Add local-bus performance benchmarks.

### Phase 2: native runtime stream

1. Add immutable `RuntimeEventConfig` and category masks.
2. Add a bounded single-producer stream for the current VM.
3. Instrument low-volume lifecycle, module, and task events.
4. Add stable IDs and per-producer sequence numbers.
5. Add safe-point draining and overflow summaries.
6. Add a native recording sink for tests.
7. Verify the disabled path with allocation and performance checks.

### Phase 3: Gene adapter

1. Define frozen `runtime/Event` types.
2. Materialize native records at safe points.
3. Attach one `EventSink` with optional buffered replay.
4. Add observer-instrumentation suppression.
5. Expose flush and statistics.
6. Define explicit entry or embedding injection.

### Phase 4: high-frequency and multi-lane events

1. Add sampling configuration.
2. Add call and allocation events with isolated benchmarks.
3. Use per-producer queues for multiple lanes.
4. Add correlation fields for task, actor, and message flows.
5. Add host tooling adapters.
6. Consider instruction events only after proving bounded diagnostic value.

## 23. Acceptance criteria

The application library is ready when:

- only instances of `event/Event` descendants can be published;
- a user-defined typed event can be subscribed and published;
- `event/Event`, `runtime/Event`, and a nested family base such as
  `runtime/task/Event` recursively match their nominal descendants;
- no wildcard selector spelling exists: `event/*` and `event.*` are not
  accepted as a second hierarchy spelling, and `X/*` keeps only its existing
  import-wildcard and capability-projection meanings;
- a concrete type selector matches the type and its descendants;
- `event/exact` excludes descendants;
- a union selector matches every alternative, stays one subscription (so an
  event matching two alternatives invokes the handler once), and cancels out of
  every family it was registered under;
- event matching uses declaration identity rather than printed names;
- the common cached match path scans no unrelated subscriptions and compares
  no path strings;
- matching preserves global subscription order across exact and family
  buckets;
- separate overlapping subscriptions invoke the handler separately;
- `subscribe` rejects a handler whose declared parameter type cannot accept
  everything its selector matches;
- all handlers receive the same frozen value, distinct from the publisher's
  own (still-mutable, unless constructed frozen) reference (§6.5);
- subscription order is deterministic;
- subscription mutation affects the next publication only;
- cancellation is explicit and idempotent;
- `close` is idempotent, releases handlers, and makes later `subscribe` and
  `publish` raise `EventBusClosedError`;
- one-shot subscriptions are consumed before handler invocation;
- nested publication follows documented depth-first ordering;
- handler failures do not prevent later handlers from running;
- both error policies produce the documented result, and `EventSink:emit`
  reports handler failures under both;
- lane ownership is enforced;
- application event publication works with runtime instrumentation disabled.

Runtime instrumentation is ready when:

- `runtime_events=false` produces no records;
- `runtime_events=true` enables only the default categories;
- explicit categories and sampling normalize correctly;
- disabled event sites allocate nothing and avoid clocks and queue writes;
- enabled event sites write compact native records;
- no Gene handler runs directly from a VM emission site;
- records materialize only at safe points;
- observer dispatch does not recursively instrument itself;
- queue overflow never blocks, overwrites oldest, and produces a dropped-event
  summary carrying the dropped sequence span;
- per-producer ordering is preserved;
- `attach` reports how much of the replay buffer was already lost;
- arbitrary Gene values are not retained by native records;
- sensitive fields are absent or redacted by default;
- sink failures are counted in `stats` and do not replace application results
  or errors, including when the attached bus uses `event/collect`;
- shutdown and explicit flush drain already-produced records;
- native and WASM profiles expose compatible logical event types;
- benchmarks quantify disabled, low-volume, and high-volume overhead
  separately.

## 24. Deferred questions

Implementation may defer:

- ad hoc named topics;
- subscriber priorities;
- weak subscriptions;
- dynamic category reconfiguration;
- lossless diagnostic mode;
- a cross-lane bus adapter in the standard library;
- live debugger value inspection;
- trace-context propagation;
- event catalog schema export;
- persistent event recording;
- distributed event adapters;
- capability-gated runtime stream access;
- detailed host CLI syntax;
- whether one runtime stream may attach more than one sink directly.

These questions do not change the core architecture:

```text
application publication
  -> event/Bus
  -> synchronous user-space dispatch

runtime transition
  -> enabled-category check
  -> compact bounded native record
  -> safe-point adapter
  -> EventSink
  -> optional event/Bus or another consumer
```
