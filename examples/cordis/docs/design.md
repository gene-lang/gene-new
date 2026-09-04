# Cordis for Gene — design

**Status:** implementation-ready design. The Gene prerequisites in
[`tmp/gene-improvements.md`](../../../tmp/gene-improvements.md) are implemented;
no Cordis implementation exists under `examples/cordis` yet. Gene runtime facts
were rechecked against the tree on 2026-09-04.

This document adapts the design in `~/tools/cordis` at commit `2ceea23` to
Gene. That checkout is outside this repository, so the citation is provenance
rather than something a reader can verify from a clone. The reference is the
behavior of Cordis's core, loader, include, HMR, timer, and console-logger
packages and their tests—not a line-for-line port of their TypeScript
implementation.

The target is semantic fidelity: spatially scoped services, dependency-driven
plugin activation, deterministic effect ownership, configuration overlays,
isolated realms, hook dispatch, declarative composition, and recoverable hot
reload. The interface deliberately looks like Gene. JavaScript-specific
machinery such as `Proxy`, prototype shadowing, decorators, module
augmentation, promise-like fibers, and callable classes does not cross the
seam.

## 1. Thesis

Cordis is two mechanisms made to cooperate:

- **spatial composition** chooses which service implementation and
  configuration a consumer sees; and
- **temporal composition** keeps a plugin active exactly while its required
  services exist, and owns everything created during that activation.

The Gene module should keep those two mechanisms behind one small interface:

```gene
(import log [new_logger])
(import [InvocationLimits RuntimeOptions default_plugin_invoker new_runtime]
  from "./cordis")

(var base_logger (new_logger "app/cordis"))
(var runtime
  (new_runtime
    (RuntimeOptions
      ^logger base_logger
      ^invoker (default_plugin_invoker)
      ^default_limits
        (InvocationLimits
          ^max_steps 100000 ^max_memory_mb 64 ^timeout_ms 2000))))
(var root runtime/.root)

(var db_instance
  (runtime .install root db_plugin {^path "app.db"}))

db_instance/.await_ready
runtime/.close
```

The names arrive through an ordinary path import. `$name/member` is reserved
for standard-library namespaces — `$x` is sugar for `gene/x`, which is why
`$runtime`, `$os`, and `$event` are spelled that way below — and Cordis is a
package under `examples/`, not a member of the standard library. A consumer in
another package declares a dependency alias and imports through it:
`(import [Runtime] from "." ^pkg "cordis")`.

`Runtime`, its owned `Loader`, `Context`, `PluginInstance`, and the nominal key
and lifetime handles are the public model. The provider index, dependency graph,
transition scheduler, effect ledger, realm interner, binding cache, hook tables,
generation table, and loader reconciliation state are implementation details.
This makes Cordis a deep module: callers learn a small lifecycle, resolution,
and composition interface, while the hard state machines stay local.

## 2. What is preserved, what changes, and what already exists

| Cordis concept | Gene form | Decision |
| --- | --- | --- |
| `Context` prototype chain | immutable `Context` views | Preserve inheritance without mutable prototypes. |
| `ctx.foo` proxy lookup | `(ctx .require foo_key)` | Make dependency access explicit and inspectable. |
| `Fiber` | `PluginInstance` | Avoid collision with Gene runtime fibers/tasks. |
| `ctx.effect()` | nested `EffectScope` ledger | Use one acquisition form and explicit `defer`. |
| `Plugin.inject` | `Requirement` rows | Required services gate activation. |
| `ctx.provide()` | `(activation .provide key value)` | Registration is owned by the active instance. |
| isolate symbols | nominal `RealmId` values | Preserve private and named shared realms. |
| intercept prototype chain | immutable config-overlay rows | Merge root-to-leaf at binding time. |
| service shadow proxies | plain or contextual binding adapters | Preserve definition/use-site semantics explicitly. |
| context accessors, mixins, associations | service-owned façades and protocol messages | Keep convenience out of the kernel. |
| string/symbol events | nominal `HookKey` values | Keep extensibility without global string typing. |
| `emit/parallel/serial/bail/waterfall` | five hook dispatch operations | Preserve their distinct control-flow contracts. |
| loader entry tree | data-only composition tree | Reconcile through a runtime-owned `Loader` façade. |
| Node module-cache surgery | reclaimable sandbox generations | Prepare, commit, discard, and release isolated graphs without mutating live identities in place. |
| Cordis logger/exporters | Gene `log` module | Reuse the runtime's existing structured logging module. |
| timer plugin | effect-owned task/timer adapter | Reuse Gene structured concurrency and cancellation. |

The deletion test for the runtime is strong: removing it would spread realm
resolution, dependency epochs, transition coalescing, cleanup ordering, hook
ownership, and reload rollback across every plugin and loader caller.

### Relationship to `examples/gene-harness`

`examples/gene-harness` is an implemented plugin runtime in this repository,
described in `examples/gene-harness/docs/design.md`. It is the intended first
consumer of this design, not a dependency today: Cordis is still proposed, and
the harness currently owns its own working kernel. Cordis is the general plugin
runtime the harness should later build on; the harness is what that runtime
becomes when its plugins are authored at runtime by a language model, must
survive a crash, and must be recoverable by an operator afterwards.

That split assigns each mechanism exactly once. Cordis owns composition:
services and realms decide which provider a consumer sees, requirements and
dependency epochs decide when a plugin exists, effect scopes own everything an
activation creates, hooks carry control-flow-shaped extension, the loader
reconciles a data-only tree, and candidate swap replaces modules in a running
process. The harness owns durability and the agent: event-sourced plugin state
in segmented streams with projection checkpoints; a composition store whose
desired state is written under revision CAS by more than one process;
content-addressed module blobs closed over their dependency graph, because its
plugin author is a model rather than a repository; per-entry quarantine,
`doctor`, and a recovery nucleus; and the command, tool, prompt, and view
surface an agent talks through. None of that belongs in a plugin runtime, and
none of it is derivable from one.

Four things the harness implements today should move during that later
migration: its seam table becomes services, its ownership ledger becomes effect
scopes, its `pending`/`ready`/`error` fixpoint becomes instances and dependency
epochs, and its sandbox loading becomes the loader. Its non-unique ordered registries —
commands, tools, prompt sections, views — do *not* become services, because a
service address holds one provider by construction and those hold many. They
stay collections in the harness layer and are contributed as effects:

```gene
(activation .effect "tool:search"
  (fn [fx]
    (tools .add row)
    (fx .defer (fn [] (tools .remove row)))))
```

Reverse-order removal, owner attribution, and removal without the contributor's
cooperation then follow from the scope instead of from a second ledger.

Knowing the first consumer before implementing is worth more than the
comparison, and it constrains this design in four places:

- **Plugin-supplied calls need one supervision seam.** Activation, availability
  predicates, schemas, binding adapters, hook handlers, and cleanup are all
  called directly by the runtime. A host whose plugin authors are untrusted has
  to bound every one of them with step, wall-clock, and memory budgets plus
  panic containment. That is a property of *where the runtime calls out*, so the
  runtime calls a host-supplied `PluginInvoker` through one identifiable path
  rather than growing six wrappers. The default adapter uses Gene's bounded
  `Env` and `$runtime/guard_call`; the harness may supply an audited adapter.
  This is adopted as invariant 13 below.
- **Staged commit must generalize beyond reload.** The prospective provider
  index below stages a set of instances, validates them, and publishes at one
  point. The harness needs that same transaction for an ordinary composition
  change, not only for a module swap. It should be an operation the loader
  offers, with hot reload as its first caller rather than its definition.
- **The service-key catalog is populated at runtime.** Keys are admitted from a
  catalog so that data cannot mint identity. A harness may mint a key when a
  model introduces a new single-provider seam that did not exist at boot; its
  multi-row tool registry remains a harness collection, as stated above. The
  rule survives — the host stays the only minter, so repeating a string still
  forges nothing — but the catalog is a live host-owned table, not a startup
  constant.
- **A manifest is a source, not a file.** The harness's desired state is a
  CAS-published store, not a data file on disk. The loader already accepts data
  at its `reconcile` seam, and the verification list requires an in-memory
  composition test, so this costs nothing; it does mean the file adapter must
  never quietly become the loader's only input.

The sequencing runs opposite to the dependency. The harness works today and
this runtime does not exist, so nothing here asks for a rewrite: Cordis is
implemented against the requirements above, and the harness migrates its kernel
onto it afterwards, keeping every durable layer it already has. If that
migration cannot be expressed, the interface in this document is wrong — which
is the most useful thing a first consumer can tell an unimplemented design.

## 3. Required invariants

The implementation is correct only if all of these remain true:

1. A plugin instance is active only when every required service resolves to an
   active, available provider in that instance's context.
2. A service lookup resolves one exact `(service key, realm id)` address. It
   never silently falls back from an isolated realm to a parent realm.
3. Provider-internal dependencies resolve at the provider's definition site;
   caller-sensitive configuration, isolation, and effect ownership come from
   the use site.
4. Every provider, hook, timer, task, child instance, and user cleanup created
   through an activation interface belongs to one effect scope. Raw detached
   work is outside the plugin contract.
5. Disposing an effect is idempotent and cleans nested effects in reverse
   acquisition order.
6. At most one lifecycle transition runs for an instance. A dependency or
   config change during a transition updates the desired epoch; the transition
   loop converges on the newest epoch.
7. An activation failure leaves the instance in `failed`. Dependency churn
   alone does not retry it; explicit `update` or `restart` does.
8. Config validation completes before committed config changes. Invalid config
   neither unloads the old activation nor mutates the instance.
9. A child context may narrow service visibility, namespace access, and Gene
   capabilities. It may not amplify any of them.
10. Plugin code cannot mutate the runtime's provider index, dependency graph,
    realm table, or effect ledger except through the public interface.
11. Runtime shutdown stops accepting work, disposes instances in dependency
    order, waits for cleanup, and releases retained callbacks.
12. Reflection returns immutable snapshots. Observing the runtime cannot become
    a mutation back door.
13. Every call from the runtime into plugin-supplied code — activation,
    availability predicates, schemas, config merge functions, binding adapters,
    hook handlers, and cleanup — passes through one supervision path. A host can
    therefore bound all of them with step, wall-clock, and memory budgets and
    contain a panic as that call's typed failure, without the runtime growing a
    second invocation route that escapes the policy.
14. Replacing or withdrawing a provider prevents its old transitive consumer
    closure from accepting new effects at publication, then quiesces those
    consumers before disposing the old provider. Its scope and module generation
    remain alive while a sanctioned consumer can still hold its plain binding.
15. Every sandboxed module graph is owned by one loader generation. Failed
    candidates are discarded; replaced live generations are released only
    after their instances and transitive service consumers are quiescent.
16. Instance unload closes its external invocation gate, waits for already-
    entered calls to unwind, and only then runs cleanup through a serialized
    teardown permit on the same `PluginInvoker`. Self-disposal requested from
    inside an invocation is queued until that invocation returns.

These invariants are the interface's behavioral content, not incidental
implementation notes.

## 4. Architecture

```text
data-only composition
        |
        v
    Loader façade -----------> Gene sandbox transactions
        |
        v
  Cordis engine <------------ Runtime façade ----------------+
   |        |              |              |                  |
   |        |              |              |                  |
contexts  provider      dependency      transition         hooks
/ realms   index          graph          scheduler          table
   |        |              |              |                  |
   +--------+-------> PluginInstance <----+------------------+
                         |
                         v
                    EffectScope
                         |
          +--------------+--------------+
          |              |              |
       services         tasks         cleanup
```

`Runtime` and its owned `Loader` are the two public façades of one Cordis
module. Ordinary hosts use `Runtime`; composition sources use `Loader`. Both are
backed by one private engine, so context movement and prospective publication
stay implementation details instead of leaking through the `Runtime`
interface. Include-file persistence, a harness composition store, and an HMR
file watcher are adapters at the `Loader/reconcile` or `Loader/reload` seams.
The provider index, prospective index, context mover, generation table, and
transition scheduler are internal seams used by implementation tests; they are
not exposed merely to make tests convenient.

## 5. Public model

The following declarations describe the intended surface. They are design
sketches; the implementation may split private representation types without
changing their behavior.

```gene
(enum InstanceState
  pending loading active failed unloading disposed)

(enum PluginCallKind
  activate availability validate_schema validate_service merge_config
  bind_service hook cleanup)

(enum HookMode emit parallel serial bail waterfall)

(enum ReconcileMode incremental staged)

(protocol Disposable
  (message dispose [] : Nil))

(protocol PluginInvoker
  (message invoke [call] : Any))

(type InvocationLimits
  ^props {^max_steps Int ^max_memory_mb Int ^timeout_ms Int})

(type RuntimeOptions
  ^props {^logger Logger
          ^invoker PluginInvoker
          ^default_limits InvocationLimits})

(type PluginCall
  ^props {^kind PluginCallKind
          ^callable Callable
          ^args (List Any)
          ^instance_uid Int
          ^entry_id Str?
          ^capability_selectors List
          ^limits InvocationLimits})

(type LoaderOptions
  ^props {^plugin_root Str
          ^shared (List Str)
          ^max_namespaces (List Str)
          ^capability_catalog Map
          ^capability_ceiling Any
          ^default_limits InvocationLimits?
          ^reload_policy Any?})

(type ServiceKey
  ^props {^id Str
          ^contract Any
          ^check Callable
          ^config_schema Callable?
          ^merge_config Callable?
          ^bind Callable?})

(type HookKey
  ^props {^id Str ^mode HookMode ^payload_schema Callable?})

(type Requirement
  ^props {^key ServiceKey ^config Any?})

(type PluginSpec
  ^props {^id Str
          ^config_schema Callable?
          ^requires (List Requirement)
          ^provides (List ServiceKey)
          ^reload Str?
          ^activate Callable})
```

The public operations are conceptually:

```text
service_key(id, contract, ^check,
  ^config_schema?, ^merge_config?, ^bind?) -> ServiceKey
hook_key(id, mode, ^payload_schema?) -> HookKey
default_plugin_invoker() -> PluginInvoker
new_runtime(options: RuntimeOptions) -> Runtime

Runtime
  root() -> Context
  admit_service_key(key) -> Nil
  admit_hook_key(key) -> Nil
  install(context, plugin, config) -> PluginInstance
  inject(context, requirements, callback) -> PluginInstance
  loader(loader_options: LoaderOptions) -> Loader
  inspect() -> RuntimeSnapshot
  await_settled() -> Nil
  close() -> Nil

Context
  require(key, head_config?) -> service
  get(key, head_config?) -> service | void
  hook_subject(key) -> HookSubject
  dispatch(hook, payload, dispatch_options?) -> value
  derive(options) -> Context

EffectOwner
  defer(cleanup) -> Disposable
  provide(key, value, availability?) -> ProviderLease
  effect(label, acquire) -> EffectLease
  spawn(label, thunk) -> Task
  on(hook, handler, options?) -> Disposable
  once(hook, handler, options?) -> Disposable
  install(plugin, config) -> PluginInstance

ActivationContext implements Context reads and EffectOwner
EffectScope implements EffectOwner

EffectLease implements Disposable
  value() -> Any

PluginInstance
  state() -> InstanceState
  await_ready() -> PluginInstance
  update(config) -> Nil
  restart() -> Nil
  dispose() -> Nil
  effects() -> (List EffectSnapshot)

ProviderLease implements Disposable
  refresh() -> Bool

Loader
  reconcile(manifest, mode=ReconcileMode/incremental) -> CompositionSnapshot
  reload(changed_paths) -> ReloadSnapshot
  inspect() -> LoaderSnapshot
  await_settled() -> Nil
  dispose() -> Nil
```

`ServiceKey` and `HookKey` are opaque nominal values created only by their
trusted-host constructors and then admitted to a runtime. `Runtime`, `Loader`,
`RealmId`, `Context`, `ActivationContext`, `EffectScope`, `EffectLease`,
`ProviderLease`, and `HookSubject` are opaque runtime-issued values. The
property lists in this document describe logical data and reflection shapes,
not public direct-construction schemas. The host shares only admitted key values
and their protocol modules with plugins. An activation context deliberately
exposes no key-admission operation. Each catalog is unique by both nominal
identity and string id. Re-admitting the same key is idempotent; admitting a
different key under an existing id is an error.

`new_runtime` calls `$runtime/require_root_lane` and rejects construction
anywhere else. `RuntimeOptions/logger` is the base logger described in section
15. `default_limits` are used unless a loader entry or derived host context
narrows them. Limits may be narrowed but never raised above the runtime value.

`PluginInvoker` is a real seam because Cordis ships a default bounded adapter
and the harness supplies an owner-aware audited adapter. The runtime gives it a
shallow-immutable call row containing the `PluginCallKind`, callable, argument
list, instance and entry identities, effective capability selectors, and
effective limits. The invoker calls the callable exactly once and either
returns its value or raises the typed failure for that call. The default adapter
uses a bounded `Env`, an argument-list trampoline, `with_capabilities`, and
`$runtime/guard_call`. No other runtime path invokes plugin-supplied code. The
engine acquires an owner invocation lease before calling the invoker and
releases it in `ensure`; unloading closes the external gate and waits for its
count to reach zero. Cleanup then uses a serialized teardown permit but still
passes through the same invoker. A call that requests its own instance's
disposal queues the transition and returns instead of waiting on itself.

`LoaderOptions` contain the trusted plugin root, admitted shared modules,
maximum namespace set, capability catalog and ceiling, default invocation
limits, and reload policy. They are host values, never manifest data.
`Runtime/loader` returns an owned façade over the runtime's private engine;
context movement and prospective provider indexes are deliberately absent from
the ordinary `Runtime` interface.

`Context/derive` accepts only `^isolate`, `^intercept`, `^capabilities`, and
`^limits`. Live code keys `isolate` and `intercept` by admitted `ServiceKey`
values; the loader resolves serialized service ids before deriving. Capability
selectors and invocation limits can only narrow their parent values. Derivation
cannot change runtime identity, owner instance, declared-key access, or loader
entry identity.

`Disposable` is the one-message lifetime protocol: `dispose` is idempotent and
may await cleanup. `ProviderLease/refresh` re-runs the availability predicate;
when its answer changes, the runtime advances the provider generation and
refreshes affected dependency epochs. A mutable predicate without an explicit
`refresh` call cannot wake pending consumers by magic.

`EffectOwner` is the common ownership interface implemented by the activation
root and every nested effect scope. `effect` returns an `EffectLease` only after
acquisition succeeds. The acquisition callback's ordinary return value is
available through `lease/value`; disposing the lease performs early cleanup.
Ignoring the lease leaves it owned by its parent and therefore still safe.

`get` is the optional lookup. `require` raises a `ServiceUnavailable` error with
the service id, realm, consumer instance, and nearest visible provider state.
Plugin code may access only keys declared in `PluginSpec/requires`; the root
operator context may inspect or resolve any key. This turns Cordis's proxy-time
"cannot get without inject" rule into an ordinary, testable check.

`install` returns a normal handle. It is not promise-like. Code that needs an
active plugin says `(instance .await_ready)`, so merely passing or inspecting a
handle cannot suspend.

`inject` is the anonymous-consumer form. It installs an instance whose
requirements are the supplied rows and whose activation is the callback, so a
host or a test can hold a dependency without authoring a `PluginSpec`. It obeys
every rule an installed plugin obeys, declared-requirement access included.

`await_settled` returns once no instance has a transition task outstanding,
including transitions started by an earlier transition. It is the runtime's
quiescence signal; the composition loader's own `await_settled` is built on it
rather than on a polling loop of its own.

`Context/dispatch` is the only hook-dispatch entry. The `HookKey` selects the
mode, so callers cannot accidentally use `emit` semantics for a waterfall hook.
`dispatch_options/subject` scopes delivery; `dispatch_options/terminal` is
required only for waterfall and rejected for every other mode.

`ActivationContext` also carries the `Context` read operations — `require`,
`get`, `dispatch`, and `derive` — over the instance's own context. Activation
code uses one value both to read services and to own what it creates. The split
in the list above is by role, not two objects handed to a plugin.

A "schema" in `PluginSpec/config_schema`, `ServiceKey/config_schema`, and
`HookKey/payload_schema` is a validation *function*, not a declarative schema
language: Gene ships no such language and this runtime does not invent one. The
function receives the candidate value and either returns the normalized value it
accepts or raises `ConfigValidationError`. `nil` accepts any value unchanged.
Because normalization is the validator's return value, a schema is also the one
place allowed to canonicalize config before it reaches the merge law.

## 6. Services are protocols plus nominal keys

A Gene protocol remains the service interface. `ServiceKey` identifies a slot
in a context and carries the runtime facts needed to validate and bind that
protocol.

```gene
(import [service_key] from "./cordis")

(protocol Clock
  (message now_ms [] : Int))

(fn check_clock [value : Clock] : Clock value)

(var clock_key
  (service_key "clock" Clock ^check check_clock))

(type SystemClock)

(impl Clock for SystemClock
  (message now_ms [] : Int
    ($os/monotonic_ms)))
```

`$os/monotonic_ms` requires the `clock/Monotonic` capability, which makes this
the smallest complete illustration of the loader rule below: a provider's
authority comes from the ceiling its module was loaded under, never from its
manifest entry and never from the fact that it claims a service named `clock`.
The two failure points are both intended. An entry that *requests*
`clock/Monotonic` beyond the host ceiling is rejected at load, before any effect
runs. An entry that requests nothing and calls anyway activates cleanly and
fails at its first `now_ms`, because a capability is checked where it is
exercised. What never happens is the third possibility: the runtime reading a
service id and inferring a grant from it.

The explicit key matters. The same protocol may occupy two independently
isolated slots, and unrelated keys may intentionally use the same contract.
The key id is stable data for manifests and diagnostics; the key value is the
nominal in-process identity. Two modules cannot create equivalent keys merely
by repeating the string.

`service_key` is a trusted-host constructor and is not part of the shared
plugin module. Its required `check` callback is a typed identity function
defined beside the protocol. Gene protocol conformance is scope-sensitive; an
explicit typed gate fixes the checking scope instead of asking the Cordis
implementation to invent dynamic protocol reflection. The `contract` value is
retained for diagnostics and declaration validation, while `check` is the
executable provider and bound-façade gate. A contract module creates the key,
the host admits it to each runtime that should recognize its serialized id, and
sandboxed plugins import the already-created key from that contract module.
This keeps the live catalog runtime-local without cloning protocol or key
identity between plugins.

A service shared by separately sandboxed plugins defines its protocol and key
in an admitted shared contract module. Every provider and consumer imports that
same value. Recompiling the declaration inside each sandbox would create
different protocol and key identities even when their source text matches.
Plugin-private keys are valid, but cannot connect independently loaded plugin
graphs.

Provider registration passes the value through `key/check` before publication,
and binding passes a contextual façade through it again before return. A
duplicate provider for the same service address is an error. A replacement is
a loader transaction, not "last registration wins."

Services are not implemented by dynamically adding and removing Gene protocol
impls. Protocol impl visibility belongs to the receiver's declaration/send
scope and has transactional module coherence rules; Cordis availability
belongs to a runtime context and changes over an instance lifetime. A provider
is therefore a value that already conforms to the service protocol. Cordis
selects that value, while ordinary Gene dispatch selects its protocol impl.
The two mechanisms meet at a clean seam and do not mutate one another.

An activation looks like this:

```gene
(fn activate_clock [ctx config]
  (ctx .provide clock_key (SystemClock)))

(var clock_plugin
  (PluginSpec
    ^id "core/clock"
    ^config_schema nil
    ^requires []
    ^provides [clock_key]
    ^activate activate_clock))
```

Consumers declare before they read:

```gene
(fn activate_reporter [ctx config]
  (var clock (ctx .require clock_key))
  (ctx .effect "report-loop"
    (fn [fx]
      (fx .spawn "report-task" (fn [] (report_loop clock config))))))

(var reporter_plugin
  (PluginSpec
    ^id "app/reporter"
    ^requires [(Requirement ^key clock_key)]
    ^provides []
    ^activate activate_reporter))
```

`provides` is a declaration, not availability. It lets the runtime reserve
addresses, reject duplicate providers before effects run, and diagnose a
pending dependency cycle. Activation must publish each declared key exactly
once before it can become `active`, and may not publish an undeclared key.
Conditional readiness belongs in the provider availability predicate; a truly
optional provider belongs in a separate plugin spec.

A cycle among declared providers is diagnosed, never broken. Every instance in
the cycle stays `pending` with its unmet requirement recorded, `await_ready`
raises `DependenciesUnavailable`, and `inspect` names the address nobody
reached. The alternative — activating one member early so its peer can observe
a half-built provider — would make invariant 1 conditional on load order, which
is the property this whole mechanism exists to remove.

Ordinary service use remains ordinary qualified Gene dispatch:

```gene
(var clock (ctx .require clock_key))
(clock .Clock:now_ms)
```

No Cordis-specific dispatcher sits on the hot path after a plain binding is
resolved.

## 7. Contexts, realms, and resolution

### 7.1 Immutable context views

A `Context` is an immutable view containing:

- a runtime identity;
- a parent view;
- the owner instance whose effect scope receives use-site effects;
- a persistent service-key-to-realm map;
- persistent config-overlay rows;
- the allowed service-key set derived from requirements and provisions; and
- the entry/call-site capability attenuation policy.

The last item is opaque runtime metadata, not a capability grant stored in a
Gene object. A module ceiling is attached before initialization by its
`SandboxGeneration` and follows escaped callables; it is not copied into or
replaced by a Cordis context. Entering plugin code intersects the host context,
that callee's module ceiling, the entry policy, and any call-site
`with_capabilities` selector. Context derivation can only add another
intersection.

Derivation returns a new view and does not mutate the parent:

```gene
(var tenant_a
  (root .derive
    {^isolate [database_key]
     ^intercept {
       ^http {^headers {^x-tenant "a"}}
     }}))
```

Context ancestry is data, not Gene lexical inheritance and not an object
prototype chain. It is therefore safe to snapshot, compare by identity, and
move under loader control.

### 7.2 Service addresses

Every lookup is reduced to:

```text
ServiceAddress = (ServiceKey identity, RealmId identity)
```

The root view maps each key to its default realm. `isolate` replaces the realm
for selected keys:

- `private` creates a fresh realm visible only through descendants of that
  context;
- a named realm label interns one realm within the runtime, allowing separate
  context branches to share it; and
- omission inherits the parent's mapping.

Names in serialized loader config are resolved against the loader's admitted
service-key catalog. Arbitrary data cannot construct a live `RealmId` or
`ServiceKey`.

That catalog is why `isolate` has two spellings for one mechanism. Live code
passes the nominal keys it already holds — `^isolate [database_key]` — while a
manifest holds no values at all and passes service *ids*, which the loader
resolves through the catalog before deriving anything. An id absent from the
catalog is a rejected manifest, not a new realm; the data-only form can select
among admitted keys but can never introduce one.

The catalog is a live host-owned table rather than a startup constant. A host
that mints keys while running — for example, for a newly authored single-provider
seam — extends it through `Runtime/admit_service_key`. Minting stays the host's
alone, so repeating a string still forges nothing; what changes is only that the
set of admitted ids is not fixed when the runtime starts.

If `tenant_a` isolates `database_key`, a database in the root realm is not a
fallback. The tenant's consumer stays pending until a provider exists at the
tenant address. This is the behavior that makes isolation real rather than a
lookup preference.

### 7.3 Resolution algorithm

`require(key, head_config)` performs these steps:

1. Verify that the context belongs to this runtime and is still live.
2. Verify that the calling plugin declared the key. Root/operator access is the
   explicit exception.
3. Read the exact realm mapped for the key and form the service address.
4. Find its provider record and require the owner instance to be `active`.
5. Require the provider record's cached availability to be true. Registration
   and `ProviderLease/refresh` run the predicate; an error is logged and cached
   as unavailable.
6. Merge config overlays from outermost to innermost, then the requirement
   row, then `head_config`. The key's merge function owns the merge law;
   otherwise shallow map replacement is used.
7. Bind the provider at the definition/use-site seam described below.
8. Validate the bound result against the key's protocol and return it.

Availability is cached on the provider record, not polled on every service
call. Registration computes it once; `ProviderLease/refresh` is the explicit
edge that recomputes it and notifies dependants. This keeps ordinary resolved
service calls free of an arbitrary plugin callback.

Provider generation, context generation, and normalized merged config form the
binding-cache key. Provider removal or context invalidation makes cached
bindings unusable. A cached value may never outlive either endpoint.

### 7.4 Definition site and use site

Cordis's hardest behavior is its shadow context: code inside a service resolves
its own dependencies where the service was defined, while caller isolation,
intercepts, and effects come from where the service is used.

Gene should not emulate that with hidden property proxies. A `ServiceKey` has
one of two binding policies:

- **plain** returns the provider value. The provider's closures naturally
  retain their definition activation, and the service has no caller-sensitive
  behavior;
- **contextual** calls the key's binding adapter with the provider value,
  definition context, use context, and merged config. The adapter returns a
  façade implementing the public protocol.

For example, an HTTP client can retain its provider's transport dependency but
apply a caller's headers, timeout overlay, and effect ownership:

```gene
(type BoundHttp
  ^props {^transport Any ^use_context Context ^config Map})

(impl Http for BoundHttp
  (message get [url : Str]
    (request_with
      self/transport self/use_context self/config "GET" url)))

(fn bind_http [provider definition_context use_context config]
  (BoundHttp
    ^transport provider/transport
    ^use_context use_context
    ^config config))
```

The adapter is private to the service module. Callers still see `Http`. A
future `service` macro may generate repetitive façades, but the kernel does not
depend on such a macro.

A contextual bound value carries its use context. Calling it after that
context's owner has been disposed raises `ContextDisposed`. Contexts and bound
services are lane-owned and are not `Send` unless a concrete adapter explicitly
implements `Send` without retaining a mutable context.

A plain binding carries no such marker and needs none: its validity is bounded
by the consumer's own lifecycle. Losing the provider changes the consumer's
dependency epoch, which unloads the consumer before a retained value can
outlive the provider that produced it. That covers exactly the code an effect
scope owns. A value carried into detached work is outside the plugin contract,
and the runtime does not pretend to track it there.

This preserves Cordis's two-site semantics while making the seam visible in
code and testable with two adapters: a plain adapter and a contextual adapter.

## 8. Plugin instances and dependency epochs

One `PluginSpec` may have several installed instances. The descriptor has a
stable id; each instance receives a monotonically increasing runtime uid. A
loader entry id addresses an instance, not a plugin callback identity.

An instance stores:

```text
uid
plugin spec
parent context
activation context
validated config
resolved requirement records
desired dependency epoch
active dependency epoch
state and last error
root effect scope
transition task, if any
loader entry identity, if any
```

The dependency epoch is a stable vector of provider instance uid and provider
generation for every requirement, in descriptor order. Missing or unavailable
providers produce the distinguished `inactive` epoch.

Provider publication, withdrawal, availability change, realm movement, and
context-overlay changes recompute only instances indexed under affected service
keys. There is no scan of every plugin after every registration.

### 8.1 State machine

```text
                  dependencies ready
 pending --------------------------------> loading
    ^                                          |
    |                                          | success
    | dependency lost                          v
 unloading <------------------------------- active
    |  ^                                       |
    |  | desired epoch changed                 | dependency/config change
    +--+---------------------------------------+

 loading -- activation error --> failed
 failed  -- explicit update/restart --> loading or pending
 any non-disposed state -- dispose --> unloading --> disposed
```

The transition loop is serialized per instance:

1. Record a new desired epoch.
2. If a transition is already running, stop; it will observe the new desire.
3. If active on a stale epoch, unload completely.
4. If the desired epoch is `inactive`, settle at `pending`.
5. Snapshot the exact provider records, enter `loading`, and activate.
6. If activation succeeds and the desired epoch is unchanged, publish
   `active`.
7. If the epoch changed during activation, unload what was just acquired and
   loop.
8. If activation fails, clean its partial effect scope, store the error, and
   publish `failed`.

`await_ready` waits until the transition loop is quiescent. It returns only in
`active`; `pending` raises `DependenciesUnavailable`, `failed` rethrows a
`PluginActivationError` with the cause, and `disposed` raises
`InstanceDisposed`.

### 8.2 Update and restart

`update(config)` validates the complete new value first. The `config_update`
waterfall hook may transform or veto it. On acceptance, the instance clears a
stored activation error and requests a restart against the newest dependency
epoch.

`restart()` keeps config but otherwise follows the same path. It is the
operator's explicit retry for a failed instance.

Core update is not rollback. If the new activation fails, the instance is
`failed`, matching Cordis. The loader and HMR adapter add candidate validation
and rollback at the composition level where an old module/config version is
available.

## 9. Effect ownership

An `EffectScope` is an ordered tree, not an untyped bag of cleanup functions.
The acquisition interface is:

```gene
(var server_effect
  (activation .effect "server"
    (fn [fx]
      (var server (open_server config))
      (fx .defer (fn [] server/.close))

      (fx .effect "accept-loop"
        (fn [child]
          (child .spawn "accept-task" (fn [] (accept_loop server)))))
      server)))

(var server server_effect/.value)
```

`acquire` receives a child `EffectScope`. Its ordinary return value is stored on
the returned `EffectLease`; it does not encode cleanup by returning one of
several magic shapes. Cleanup is registered only with `defer`, `provide`, `on`,
`install`, or another `EffectOwner` operation. Disposing the lease early cleans
the child scope and makes `lease/value` raise `EffectDisposed`; ignoring it
leaves the lease attached to its parent. A value already extracted from the
lease is not revocable by magic; resource adapters remain responsible for
rejecting use after their own close, and detached retention is outside the
effect contract.

`spawn` uses `spawn ^lane root`, relying on Gene's guarantee that the spawning
turn receives the `Task` before the child body begins. It registers cancellation
and join with the effect scope before yielding. Cleanup cancels the task and
uses `Task/join` to observe completion without letting one child's cancellation
skip later cleanup. Long-lived plugin work uses this operation.
Ordinary lexical `spawn` keeps ordinary Gene structured-concurrency semantics;
the runtime does not pretend it can discover an explicitly detached task after
the fact.

Rules:

- the child scope is attached to its parent before acquisition starts;
- if acquisition raises or is cancelled, the child is disposed before the
  error continues;
- cleanup runs once in reverse acquisition order;
- nested scopes are disposed as one parent entry;
- async cleanup is awaited;
- cleanup continues after errors and returns one aggregate error preserving
  order;
- automatic instance unload logs cleanup failures and continues to a stable
  lifecycle state;
- explicit `EffectLease/dispose` returns the aggregate failure to its caller;
- new effects are rejected after unloading begins; and
- effect snapshots expose labels and children, never cleanup closures.

Provider registration, hook subscription, timers, and child instances use this
same `EffectOwner` mechanism. There is no parallel table of special cleanup
kinds.

Plugin activation itself runs inside the instance's root scope. A returned
value is ignored; a plugin cannot bypass ownership by returning a disposer that
the runtime may forget to collect.

## 10. Hooks and events

Gene already has a nominal application event bus in `gene/event`. Cordis hooks
have additional control-flow modes and should not overload that module's
`publish` contract. The Cordis engine therefore owns a separate lane-local hook
table behind `Context/dispatch` and the `EffectOwner/on` and `once` operations.

A `HookKey` is a nominal value created and admitted by trusted host code, then
referenced by loaded plugins through shared contract modules.

Like a service key, a `HookKey` is opaque and becomes usable only after
`Runtime/admit_hook_key`. A sandboxed descriptor may reference an admitted key
from a shared contract module; it cannot mint one by repeating the id.

One dispatch operation preserves the five Cordis semantics while taking one
payload value instead of variadic arguments:

```text
EffectOwner/on(hook, handler, prepend=false, global=false) -> Disposable
EffectOwner/once(hook, handler, prepend=false, global=false) -> Disposable
Context/dispatch(hook, payload,
  ^subject HookSubject? = nil,
  ^terminal Callable? = nil) -> value
```

The key's `HookMode` selects the algorithm. `emit` invokes synchronously in
registration order and propagates the first error. `parallel` starts every
handler with `spawn ^lane root`, joins every task, and raises an ordered
aggregate error. The explicit lane preserves support for captured, non-`Send`
local handlers: a root-lane task never migrates to a worker and may therefore
retain them. `serial` awaits handlers in order and stops on the first bailed
result. `bail` is its synchronous form. `waterfall` requires `^terminal`; every
other mode rejects that option. `new_runtime` uses
`$runtime/require_root_lane`, so "the runtime's owning lane" and "the root
lane" are one lane throughout.

A result is bailed when it is not `nil`, `void`, or `false`, matching Cordis's
null/undefined/false rule. `waterfall` gives each handler a single-use `next`
continuation. Calling `next` twice—including after an await or from an outer
frame—raises `ContinuationAlreadyCalled`.

Registration through an activation is effect-owned. `once` marks itself
consumed before calling the handler. Dispatch takes a handler snapshot, so
registration or cancellation during a dispatch affects only the next one.

`subject` replaces Cordis's overloaded `thisArg`. It is an opaque `HookSubject`
created by `(ctx .hook_subject key)` and identifies one admitted service key and
the realm that context maps it to. A scoped handler records its registration
context. Dispatch with a subject includes global handlers and handlers whose
context maps that key to the same realm. Dispatch without a subject includes
all handlers. Filtering is a runtime operation; user payloads cannot supply a
forged subject or filter function. Plugin code may create a subject only for a
declared requirement or provision; root/operator code retains the explicit
all-key exception used by `require`.

Internal hooks use private `HookKey` values rather than reserved
`"internal/"` strings:

- `plugin_changed`
- `instance_status_changed`
- `service_changed`
- `config_update`
- `service_resolve`
- `hook_registered`
- `hook_dispatched`

Only documented extension hooks enter the public hook catalog. Ordinary domain
events remain nominal `$event/Event` values on an application-owned
`event/Bus`.

## 11. Configuration and intercepts

Plugin and service configuration are separate:

- plugin config is validated once per instance before activation; and
- service intercept config is merged each time a service is bound for a use
  context.

A `Requirement` may carry the consumer's base service config. Derived contexts
may add overlays:

```gene
(var api_context
  (root .derive
    {^intercept {
       ^http {^timeout_ms 2000
              ^headers {^x-client "api"}}
     }}))
```

The service key owns both validation and merge. Merge order is deterministic:

```text
outer context overlays
-> inner context overlays
-> requirement config
-> explicit require head config
```

For the default merge, later map fields replace earlier fields. A service may
provide a deeper merge function, but it must be pure, deterministic, and return
a fresh value. Config values are frozen snapshots before entering a plugin or
binding adapter, so callers cannot mutate the instance behind the validator.

The `config_update` waterfall is the one interception point for persistence,
normalization, audit, or veto. A continuation is single-use. Loader persistence
uses a global prepend handler; plugin-local handlers are scoped to the instance.

## 12. Composition loader

`Loader` is a runtime-owned façade over the same private engine as `Runtime`.
It reconciles a desired, data-only tree into installed instances without
exposing provider maps, context movers, prospective indexes, or module
generations to composition sources.

### 12.1 Loader interface

`Runtime/loader(options)` accepts trusted `LoaderOptions` once and returns the
owned loader. An incompatible second call is an error. The two mutation
operations are:

```text
reconcile(manifest, mode=incremental) -> CompositionSnapshot
reload(changed_paths) -> ReloadSnapshot
```

`reconcile` accepts the already-parsed data value, not a filename or source
object. The in-memory harness store and the include-file adapter therefore use
the same interface without a hypothetical `CompositionSource` port.

`incremental` mode validates the complete manifest first, then applies each
entry change through the ordinary instance lifecycle. A newly installed or
updated entry may settle in `failed`; unaffected entries stay live. `staged`
mode prepares candidate activation revisions for every changed entry and its
service-consumer closure against a prospective index, requires all enabled
candidates to become `active`, and publishes the new composition or discards it
whole. Hot reload always uses staged mode internally.

`Loader/inspect` and both result values are immutable snapshots. `dispose`
stops watchers owned by loader adapters, quiesces loader work, and asks the
private engine to remove its entries. The engine first unloads every affected
consumer, including one installed directly through `Runtime`, then disposes the
entry providers and releases their sandbox generations. `Runtime/close` first
stops loader inputs and then disposes loader-owned and directly installed
instances together in global dependency order.

### 12.2 Manifest

The default format is one Gene data value, never evaluated:

```gene
{^format 1
 ^entries [
   {^id "clock"
    ^plugin_id "core/clock"
    ^module "./plugins/clock.gene"
    ^config {}}

   {^id "tenant_a"
    ^group true
    ^children [
      {^id "database"
       ^module "./plugins/sqlite.gene"
       ^config {^path "tenant-a.db"}
       ^isolate {^database true}}

      {^id "api"
       ^module "./plugins/api.gene"
       ^config {^port 8080}
       ^intercept {^http {^headers {^x-tenant "a"}}}}
    ]}
 ]}
```

An entry supports:

```text
id              stable among siblings
plugin_id       optional expected PluginSpec id
module          module path inside the admitted plugin root
config          inert plugin config
disabled        inherited disable flag
group           entry contains children rather than a plugin
children        ordered nested entries
isolate         service id -> true or named realm label
intercept       service id -> config overlay
namespaces      requested external stdlib namespaces
capabilities    requested capability selectors
limits          requested narrowing of step, memory, and timeout limits
```

Unknown fields, duplicate sibling ids, invalid groups, unknown service ids,
malformed selectors, and limits above the loader ceiling are rejected before
reconciliation. Generated ids are allowed only for interactive creation and
are persisted immediately; authored manifests should always specify ids.

`disabled` is inherited. A group itself remains present while its descendants
are disabled or enabled. Moving an entry changes its parent context; the loader
recomputes realms, overlays, and dependency epochs before deciding whether the
plugin must restart.

### 12.3 Module loading and capabilities

The loader resolves every entry beneath the host-supplied plugin root and
prepares it inside a Gene sandbox transaction:

```gene
(var sandbox_tx ($runtime/sandbox_transaction))
(var generation
  (sandbox_tx .prepare
    {^dir dir
     ^entry entry
     ^grants grants
     ^shared shared
     ^label entry/id
     ^policy execution_policy}))
(var plugin_module generation/.module)
```

`dir` is the admitted plugin root, `grants` the namespace subset the entry may
reach, `shared` the admitted shared-module list, and `label` the loader entry id
used in diagnostics. Gene mints a fresh opaque generation identity; callers do
not have to know dependency digests before loading the graph that discovers
them. Every plugin graph, including a first load, therefore has one explicit,
reclaimable owner.

The root, admitted shared modules, maximum namespace set, and capability
ceiling come from trusted host configuration. A manifest may request a subset;
it cannot mint a grant. `prepare` bounds compilation, macro expansion, module
initialization, and later escaped calls with `execution_policy`; untrusted
top-level code never runs before its limits exist. The plugin format still
requires a declaration-only top level, but safety does not depend on its
cooperation. The loader then validates the exported `PluginSpec` and passes it
to the private engine's prospective or live install path.

The restriction follows exported functions and protocol values after load.
Modules outside the root must be in the explicit shared list. A plugin cannot
create a sandbox transaction itself, and the `$runtime` namespace and
generation handles must not be shared with plugins.

The plugin module exports one `plugin` binding. `plugin_id`, when present, must
match `PluginSpec/id`; the entry's own `id` remains the instance address, so one
plugin spec can be installed more than once. Config schema, requirements,
provisions, and every referenced key are validated without activating the
plugin.

Manifest capability selectors are inert data resolved through a host-admitted
capability catalog. Trusted loader code expands only those known rows into
selector forms for the sandbox policy and later `PluginCall` rows; it never
evaluates an arbitrary manifest expression.

The loader retains `generation/graph` for change analysis. A failed staged
composition calls `SandboxTransaction/discard`. A successful commit publishes
all prepared module graphs and Cordis provider/hook records in one non-yielding
owning-lane turn. Replaced committed generations are released only after their
instances and transitive service consumers have unloaded.

### 12.4 Reconciliation

Entries are addressed by colon-separated ancestry such as
`tenant_a:database`. Reconciliation compares desired entries by full id:

- new enabled entry: load, validate, install;
- removed or newly disabled entry: dispose;
- unchanged entry: retain its instance;
- config-only change: `update` the instance;
- context change: the private engine derives and installs the new immutable
  context, then refreshes the instance's dependency epoch;
- module identity change: use the replacement transaction below; and
- group movement: reparent descendants, then reconcile from outermost to
  innermost.

Independent siblings may load in parallel, but state publication is serialized
by the loader. `await_settled` loops until there are no module-load or instance
transition tasks, including work created by an earlier transition.

A staged reconciliation computes the transitive service-consumer closure of
every replaced or withdrawn provider. It prepares replacement activation
revisions and module generations for that complete closure against a
prospective provider index. An unchanged consumer keeps its public
`PluginInstance` handle and uid while its candidate effect scope remains
private. A candidate is an internal `InstanceRevision`, not a second lifecycle
transition on the public handle, so invariant 6 still holds. If preparation
fails, the loader discards candidates and leaves the old composition active.
Commit swaps the candidate revisions, publishes all new records, and prevents
the old closure from accepting new effects in one owning-lane turn. It then
cancels and joins old consumers from leaves to providers before disposing old
providers and releasing their generations. A post-commit cleanup failure
reports `recovery_required`; it cannot roll visibility back. This is stronger
than incremental reconciliation by request; invariant 7 continues to govern
ordinary installs and updates.

### 12.5 Include and persistence

The include adapter reads a data manifest, optionally applies host-supplied
patches, and gives the result to the loader. Patches may override a known entry
or insert children into a known group. A patch that names the expected module
must match it; otherwise it is skipped with a warning.

Writes use Gene's atomic `Store`/filesystem operations under explicit
filesystem capabilities:

```text
serialize complete candidate
-> write temporary sibling
-> flush/close
-> atomic replace
```

Write coalescing is bounded to one pending task. Read-only files can be loaded
but not updated. Paths resolve relative to the including file, never the
process working directory. Dynamic JavaScript-style `!js` expressions are not
ported; interpolated values must use a declared, pure data template language
or explicit host preprocessing.

## 13. Hot reload

Cordis never edits an existing Gene module identity in place. Each candidate
belongs to a fresh, runtime-identified `SandboxGeneration`. Its immutable graph
snapshot records source and shared compile-interface digests; its policy records
namespace and capability ceilings. Generation release, rather than ad-hoc
module-cache deletion, reclaims rejected and replaced graphs.

Reload is a composition transaction:

1. Debounce and coalesce changed paths. The file adapter uses capability-gated
   `$fs/watch`; tests and embedding hosts may call `Loader/reload` directly.
2. Compute affected plugin entry roots from the immutable graph snapshot
   retained with every live sandbox generation.
3. If a changed module belongs to the runtime, loader, or admitted shared
   contract set, request a full process restart.
4. Create one Gene sandbox transaction and prepare all affected module roots as
   new generations.
5. Validate descriptors, schemas, shared protocol identities, requirements,
   and configs without touching live instances.
6. Compute the transitive Cordis service-consumer closure of every provider the
   module candidates replace. Stage replacement activation revisions for that
   complete closure in private contexts backed by a prospective provider index
   layered over unchanged live providers. An unchanged consumer keeps its
   public instance handle and committed module generation while receiving a
   private candidate effect scope.
7. Reconcile candidates to a fixpoint. Every enabled candidate must become
   `active`; a candidate left `pending` is rejected with its missing-service or
   dependency-cycle diagnostic. Candidate providers can satisfy one another
   but remain invisible to the live provider index and live hooks.
8. If any candidate fails, dispose every staged scope, discard the sandbox
   transaction, and retain the old instances and generations.
9. In one non-yielding owning-lane turn, commit the sandbox transaction, publish
   the staged activation revisions, provider/hook records, and changed entry
   handles, prevent the replaced old closure from accepting new effects, and
   make its records unavailable. No plugin-supplied call occurs in this commit
   turn.
10. Cancel and `Task/join` old consumers from leaves to providers. Only after a
    provider's old consumers are quiescent may its scope be disposed. Release
    every old sandbox generation no longer referenced by a live entry.
11. Emit one `hmr_reloaded` hook containing the old and new module digests.

Steps 6–9 require a private prospective provider index. Starting candidates in
the live index would create duplicate providers or briefly restart unrelated
consumers. The index is an internal seam shared by the runtime and loader
façades; it is never handed to a loader caller. Step 9 is the only moment its
records become visible. A cleanup or generation-release failure after that
point reports `recovery_required`; it does not roll visibility back to a mix of
generations.

Staging covers Cordis-visible publication, not arbitrary external effects. A
candidate may still log, read a file, or contact a remote system before commit
within its admitted authority. Plugins whose activation cannot be repeated or
overlapped must declare `stop_start`; `candidate_swap` is not a transaction over
the outside world.

If a plugin owns an irreversible external resource that prevents old and new
instances from overlapping, its `PluginSpec` declares
`^reload "stop_start"`. The loader
then prepares and validates the new module generation but does not activate the
new instance in step 7. If any instance in the affected service-consumer
closure declares `stop_start`, that entire connected closure uses the reduced
mode; mixing overlap and teardown inside one dependency closure would recreate
the half-old graph staging prevents. The loader quiesces the old closure first,
activates replacements afterwards, and cannot promise rollback after teardown.
It reports that reduced guarantee before reloading. The default
`"candidate_swap"` mode is allowed only when every affected instance permits
staged activation.

`nil` and `"candidate_swap"` select the default; `"stop_start"` is the only
other version-1 value. Descriptor validation rejects every other spelling.

HMR preserves loader entry identity and config. It does not serialize live
tasks, sockets, or arbitrary plugin state. A plugin that needs state migration
must expose an explicit snapshot/migrate seam. Candidate-swap failure leaves
the old instance active before commit; failure after a stop/start teardown is
`recovery_required` and carries the prepared generation and old snapshot in its
diagnostic for operator recovery.

## 14. Timers and structured concurrency

The timer package is a normal service adapter, not a second scheduler. It uses
Gene tasks and the activation effect scope:

```text
timeout(callback, delay_ms) -> Disposable
sleep(delay_ms) -> Nil
interval(callback, delay_ms) -> Disposable
ticks(delay_ms) -> Stream Nil
throttle(callback, delay_ms, trailing=true) -> DisposableCallable
debounce(callback, delay_ms) -> DisposableCallable
```

Disposing the owner cancels timers, rejects or cancels pending waits with
`ContextDisposed`, and closes tick streams. Concurrent stream reads are either
serialized by the stream adapter or rejected explicitly; they never allocate
one unowned task per read.

Timer callbacks execute under their captured use context and owner effect
scope. A callback cannot create effects after that owner begins unloading.
Intervals use bounded delivery: a slow consumer coalesces ticks rather than
growing an unbounded queue.

## 15. Logging

Cordis's logger service should map onto Gene's existing `log` module rather than
fork its routing, redaction, sink, failure, and concurrency contracts.

The embedding host supplies the runtime's base logger through
`RuntimeOptions/logger`. Each plugin call row and diagnostic receives a child
enriched with stable fields:

```gene
(var logger
  ((base_logger .child "cordis") .with
    {^plugin plugin/id
     ^instance instance/uid
     ^entry instance/entry_id}))
```

Service binding may derive a child logger or add a service payload field.
Thresholds and sink routes remain properties of the host-installed logging
configuration; a Cordis intercept cannot rewrite them. Plugin data cannot add
file sinks or otherwise grant output authority.

Logging identity does not come from the package name. A standalone application
may supply `app/cordis`; an extension host may supply a permitted
`extension/...` logger. Runtime, loader, and HMR derive child names from that
handle instead of claiming `gene/*` or `genex/*`. The in-memory diagnostic
history is bounded. Sink failures retain Gene logging's non-recursive emergency
path and never re-enter Cordis hooks.

The console renderer, colors, timestamps, and target-specific formatting stay
logging adapters. None belong in the Cordis kernel.

## 16. Concurrency and lane ownership

Version 1 is lane-owned:

- `new_runtime` calls `$runtime/require_root_lane` before allocating state;
- provider and hook tables mutate on the runtime's owning Gene lane;
- lifecycle transitions are structured child tasks of the runtime scope;
- each instance has at most one transition task;
- service resolution is synchronous on the owning lane;
- hook dispatch stays on that lane unless `parallel` explicitly creates child
  tasks; and
- closing the runtime cancels and `Task/join`s its complete task tree.

`Runtime`, `Context`, `ActivationContext`, `PluginInstance`, plain mutable
services, effect scopes, and hook subscriptions do not implement `Send`.
Cross-lane access uses an actor adapter with a typed, bounded mailbox. Services
that are intrinsically sendable may expose a separate sendable handle such as
an `ActorRef`; the runtime does not infer safety from immutability alone.

This keeps mutation lock-free in the common case and aligns with Gene's local
event bus. A future multi-lane provider index would require measured need,
immutable snapshots, epoch publication, and a reclamation protocol; adding a
mutex around the current design is not sufficient.

## 17. Introspection and diagnostics

`Runtime/inspect` returns one frozen snapshot:

```gene
{^instances [
   {^uid 7 ^plugin "app/reporter" ^state "pending"
    ^entry "tenant_a:reporter"
    ^requirements [
      {^service "database" ^realm "private:12"
       ^provider void ^status "missing"}
    ]
    ^effects []}
 ]
 ^services [
   {^service "clock" ^realm "default"
    ^provider 3 ^generation 1 ^active true}
 ]
 ^realms [...]
 ^hooks [...]
 ^transitions [...]}
```

Snapshots expose ids, states, labels, generations, and error summaries. They
do not expose cleanup closures, capability grants, mutable config objects,
provider internals, or hook callbacks.

The following errors are distinct because their remedies differ:

- `UndeclaredRequirement`
- `ServiceUnavailable`
- `DuplicateProvider`
- `ServiceContractError`
- `ConfigValidationError`
- `PluginActivationError`
- `PluginCleanupError`
- `DependenciesUnavailable`
- `InstanceDisposed`
- `ContextDisposed`
- `EffectDisposed`
- `ContinuationAlreadyCalled`
- `HookDispatchError`
- `CompositionError`
- `ReloadRejected`
- `RecoveryRequired`

An invoker failure is translated at the calling interface: activation becomes
`PluginActivationError`, schemas and merges become `ConfigValidationError`,
service checking/binding becomes `ServiceContractError`, handlers become
`HookDispatchError`, cleanup becomes `PluginCleanupError`, and availability is
cached false with the cause in diagnostics. The invoker's structured cause is
retained. Gene-level sandbox transaction failures become `CompositionError`
during reconciliation or `ReloadRejected` before an HMR commit; a failure after
commit becomes `RecoveryRequired`.

Every lifecycle error includes plugin id, instance uid, loader entry id when
present, and the outer activation stack. Causes remain structured; formatting
does not destroy them.

## 18. Proposed filesystem layout

```text
examples/cordis/
  package.gene
  docs/
    design.md
  src/
    cordis.gene             public exports
    model.gene              public value types and errors
    runtime.gene            context, providers, dependencies, transitions
    invocation.gene         default PluginInvoker adapter
    effects.gene            EffectScope implementation
    hooks.gene              HookKey and dispatch modes
    loader.gene             Loader façade, composition tree, reconciliation
    include.gene            data-file adapter and atomic persistence
    hmr.gene                dependency analysis and candidate swap
    timer.gene              task/timer service adapter
    plugin_api.gene         stable sandbox/shared plugin contract
    main.gene               runnable demonstration
  plugins/
    clock.gene
    database.gene
    reporter.gene
  tests/
    lifecycle.gene
    isolation.gene
    services.gene
    effects.gene
    hooks.gene
    loader.gene
    hmr.gene
```

`package.gene` names the package `genex/cordis`. That is the package's registry
identity, not a standard-library namespace: nothing here becomes reachable as
`$cordis`, and a dependent package picks its own alias for `^pkg` imports.

The files under `src/` are implementation partitions of one Cordis module, not
independently supported interfaces. `cordis.gene` exports the host-facing
`Runtime`, `Loader`, values, protocols, constructors, and default invoker. Only
`plugin_api.gene` and specifically admitted service or hook contract modules
are shared with sandboxed plugins. Key constructors, admission operations,
loader, include, HMR, filesystem, runtime sandbox controls, generation handles,
and host capability objects are never shared.

## 19. Verification

Tests use the public interface. They do not reach into provider maps or force
private state transitions.

### Core lifecycle

- specs activate whether or not their activation returns a value, and a
  returned value never registers cleanup;
- invalid descriptors and configs fail before effects are visible;
- missing requirements keep an instance pending;
- provider arrival activates all matching consumers;
- provider withdrawal unloads exactly the affected consumers;
- dependency replacement changes the epoch and restarts once;
- changes during load/unload coalesce to the newest epoch;
- activation failure cleans partial effects and stays failed;
- dependency churn does not retry a failed instance;
- update/restart recovers a failed instance;
- dropped update results do not become unobserved task failures;
- every plugin-supplied call kind passes through the configured `PluginInvoker`
  exactly once with narrowed limits and capabilities;
- unload rejects new external invocations, waits for in-flight calls, runs
  cleanup through the invoker, and self-disposal from a hook does not deadlock;
- construction away from the root lane is rejected; and
- runtime close reaches `disposed` for every instance.

### Services and spatial composition

- undeclared access is rejected;
- root operator access is explicit and works;
- private realms do not see root providers;
- two contexts sharing a named realm see one provider;
- moving providers and consumers between groups refreshes only relevant
  instances;
- definition-site dependencies do not leak caller-only services;
- contextual bindings receive use-site intercepts and effect ownership;
- cached bindings invalidate on provider/context generation changes;
- duplicate providers are rejected deterministically;
- availability predicate errors are contained and diagnosed;
- changing availability has no effect until `ProviderLease/refresh`, which
  advances exactly the affected epochs; and
- forged service keys, hook keys, realms, subjects, contexts, and leases are
  rejected by nominal runtime identity.

### Effects and hooks

- nested cleanup is reverse ordered and idempotent;
- acquisition failure cleans only the partial subtree;
- an `EffectLease` exposes the acquisition value and early disposal makes later
  `lease/value` access fail;
- cleanup continues after several errors and preserves their order;
- cancelled and failed task joins do not skip later cleanup;
- provider, hook, timer, and child-instance cleanup use the same ledger;
- all five dispatch modes preserve ordering and error behavior;
- `Context/dispatch` selects behavior from the key and rejects an invalid
  waterfall terminal combination;
- `parallel` waits for every handler before raising;
- `once` is consumed before reentrant dispatch;
- dispatch snapshots tolerate add/remove during callbacks;
- scoped hook filtering follows realms; and
- waterfall continuations reject every second call, including delayed calls.

### Loader and HMR

- incremental reconciliation may leave only the changed entry failed, while
  staged reconciliation publishes every candidate or none;
- nested disable/enable and group moves reconcile correctly;
- config persistence is atomic and path-relative;
- patches cannot silently target the wrong module;
- manifests cannot enlarge namespace or capability ceilings;
- loader entry ids remain distinct from optional expected plugin ids;
- sandbox restrictions follow escaped callbacks;
- sandbox compilation, macros, and top-level execution are bounded before they
  begin;
- changed dependencies reload every affected plugin root;
- shared/runtime changes request full restart;
- candidate import or activation failure leaves old instances working;
- successful swap does not expose duplicate providers;
- replacement includes the transitive service-consumer closure, and old
  providers remain alive until those consumers have joined;
- candidate staging documents external effects and rejects an unsupported
  reload mode;
- old cleanup failure reports `recovery_required`;
- discarded and replaced sandbox generations release all cache and registry
  roots;
- watcher overflow requests a rescan rather than silently losing changes; and
- repeated rapid reloads leave no stale hooks, effects, tasks, or module
  identities reachable.

At least one test service must have both plain and contextual adapters. At least
one loader test uses an in-memory composition adapter and one uses a real
temporary filesystem, so the loader seam is justified rather than hypothetical.

## 20. Implementation order

0. Use the implemented `$runtime/require_root_lane` and `Task/join` primitives
   from `tmp/gene-improvements.md`.
1. Implement `RuntimeOptions`, the default `PluginInvoker`, service keys,
   immutable contexts, realm resolution, and read-only snapshots.
2. Add effect scopes and a manually driven plugin state machine.
3. Add the dependency reverse index, epochs, and transition coalescing.
4. Add plain and contextual service binding plus intercept merge.
5. Add hook keys and all dispatch modes.
6. Add the data-only `Loader` façade, both reconciliation modes, and nested
   group reconciliation.
7. Integrate Gene's bounded sandbox generation prepare/commit/discard/release
   interface and add the shared plugin contract.
8. Add atomic include persistence and patches.
9. Add candidate-swap HMR, explicit stop/start fallback, and the implemented
   `$fs/watch` adapter.
10. Add timer and actor adapters, then the runnable example.

Each stage adds executable interface tests before the next stage. HMR is last
because it relies on every earlier lifetime and visibility guarantee; it must
not define those guarantees accidentally.

Stages 1 through 7 have an acceptance test better than any of their own: the
harness kernel described in section 2 must be expressible on them, with its
seam table as services, its ledger as effect scopes, its lifecycle as instances
and epochs, and its loading as the loader. Attempting that migration against an
implemented consumer is how the interface gets falsified early, and it is
cheaper than discovering the same gap from a second example written to fit.

## 21. Deliberate non-goals

- No transparent `ctx.foo` property injection.
- No JavaScript decorators, callable classes, or prototype mixins.
- No generic context accessor or associated-property subsystem; a service
  module exposes a protocol or a private binding façade.
- No overloading garbage collection as plugin or subscription cleanup.
- No global mutable context or process-wide singleton registry.
- No automatic capability grant from a manifest, service, or plugin id.
- No hidden cross-lane locking or unbounded hook/timer queues.
- No arbitrary expression evaluation in configuration files.
- No individual mutation of Gene's live application module cache; only
  generation transaction commit and lifecycle release.
- No claim that HMR preserves sockets, tasks, or arbitrary in-memory state.
- No second logging stack.
- No public exposure of the kernel's internal seams for mocks.

The result is recognizably Cordis: contexts control where services resolve,
instances control when plugins exist, and effects make teardown a property of
the runtime rather than plugin discipline. It is also recognizably Gene:
protocols remain the service contracts, modules and capabilities remain real
security seams, structured concurrency owns work, nominal values replace
stringly typed identity where possible, and lifecycle behavior is explicit at
the call site.
