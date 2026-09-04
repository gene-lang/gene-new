# Gene improvements required by Cordis

**Status:** implemented on 2026-09-04. These changes satisfy the prerequisites
for the corresponding Cordis stages in
[`examples/cordis/docs/design.md`](../examples/cordis/docs/design.md); they are
not part of the Cordis package.

The list is intentionally narrow. Contexts, realms, provider selection,
dependency epochs, effects, hooks, composition reconciliation, and candidate
swap remain Cordis behavior. Gene should supply only the lower-level mechanisms
that cannot be implemented correctly as an ordinary package.

## 1. Sandboxed module generations

**Unblocks:** Cordis loader integration and recoverable HMR (stages 7 and 9).

`$runtime/load_sandboxed` currently initializes a sandboxed graph directly in
the application's module cache. The optional isolation key gives the graph a
distinct identity, but there is no handle that can stage, discard, or later
release every module and protocol registration created by that load. Module
top-level execution also happens before `$runtime/configure_module` can attach
its execution policy.

Gene exposes one deep runtime module interface that owns the complete lifetime
of isolated module graphs:

```gene
(var transaction ($runtime/sandbox_transaction))

(var generation
  (transaction .prepare
    {^dir plugin_root
     ^entry entry_path
     ^grants namespaces
     ^shared shared_modules
     ^label loader_entry_id
     ^policy {^max_steps 100000
              ^max_memory_mb 64
              ^timeout_ms 2000}}))

(var plugin_module generation/.module)
(var graph generation/.graph)

transaction/.commit
transaction/.discard
generation/.release
```

`SandboxTransaction` and `SandboxGeneration` are opaque, lane-owned values with
these semantics:

- `SandboxTransaction/prepare` may be called for one or more roots and
  canonicalizes each directory and shared-module allowlist
  with the same containment rules as `load_sandboxed`.
- Preparation mints a fresh opaque generation identity. `label` is diagnostic
  data only; callers neither construct cache identities nor need source digests
  before dependency discovery has run.
- Compilation, macro expansion, and module initialization are bounded by the
  supplied policy. The policy is installed on every generation-owned module
  before any of its runtime code executes and follows escaped functions and
  protocol methods afterwards. Admitted shared modules retain their existing
  host policy.
- Preparation quiesces worker-lane module readers and filters scheduler pumping
  to the candidate generation, so a suspending module initializer cannot expose
  prospective tables to unrelated root-lane work.
- FFI, native/capability type, and embedded web-module declarations are
  rejected during preparation; the eval policy has no flag that enables them.
- The candidate module cache, canonical protocol registrations, scoped impls,
  serde origins, and compile artifacts are prospective. Candidate values see
  their own prospective definitions, but unrelated live application code does
  not.
- `module` returns the candidate entry module so a trusted host can validate
  its declarations and invoke its exported descriptor.
- `graph` returns the immutable snapshot specified below.
- `SandboxTransaction/commit` publishes every prepared graph at one owning-lane
  commit point. It is idempotent and rejects a discarded transaction. A
  validation failure publishes none of them.
- `SandboxTransaction/discard` releases every uncommitted graph and all runtime
  roots they introduced. It is idempotent and rejects a committed transaction.
- `SandboxGeneration/release` removes a committed generation from module-cache
  and registry roots after its owner has quiesced all callers. Existing
  unsanctioned detached values may subsequently fail dispatch; the host is
  responsible for its lifetime contract. Release is idempotent.
- Dropping a handle is not lifecycle. An uncommitted generation must still be
  discarded, and a committed generation must still be released explicitly.
- A preparation failure leaves no prospective or live cache entry reachable.

`load_sandboxed` remains as a compatibility convenience equivalent to a
one-generation transaction followed by commit, but new transactional loaders
should use the transaction interface. `configure_module` remains useful for
trusted, already-loaded modules; it is not the safe way to set the initial
policy of untrusted code.

### 1.1 Immutable graph snapshot

The generation graph supplies exactly the information a reload owner needs,
without adding broad mutable module-cache reflection. Current `Module`
reflection has no import graph or authenticated source/interface digests.

```gene
{^root "sandbox:...::plugins/api"
 ^nodes [
   {^identity "sandbox:...::plugins/api"
    ^owned true
    ^path "/canonical/plugins/api.gene"
    ^source_digest "sha256:..."
    ^compile_interface_digest "sha256:..."
    ^dependencies [
      {^identity "sandbox:...::plugins/http"
       ^phase "runtime"}
    ]}
 ]}
```

Requirements:

- identities and paths are normalized exactly as the module loader uses them;
- source digests describe the bytes actually compiled, not a later reread;
- dependency edges include runtime imports and compile-time macro/derive
  dependencies, with their phase recorded;
- admitted shared dependencies appear as reference nodes with `^owned false`,
  their live identity, path, source digest, and compile-interface digest;
- the compile-interface digest changes whenever reload compatibility or shared
  protocol/type identity can change;
- nodes and edge lists are deeply frozen and deterministically ordered; and
- graph data is available only through the trusted generation handle. A
  sandboxed plugin does not receive the handle or `$runtime` namespace.

Cordis can retain one snapshot per live loader entry, map filesystem changes to
affected entry roots, and include shared-interface fingerprints in
its generation comparisons. A separate public `Module/dependencies` interface
is unnecessary.

### 1.2 Verification

- preparation does not change ordinary module lookup or protocol dispatch;
- candidate functions and protocol values work against their prospective graph;
- a failed preparation or explicit discard restores cache, impl, serde, and
  compile-artifact counts;
- a multi-generation transaction commit publishes every graph or none;
- release removes all generation-owned roots after callers are quiescent;
- repeated prepare/discard and prepare/commit/release cycles retain no stale
  module identities;
- compilation, macro expansion, top-level loops, and later escaped calls all
  obey the supplied step, memory, and time limits; and
- source and interface digests are stable for the same authenticated inputs.

## 2. Task outcome joining

**Unblocks:** deterministic effect cleanup, hook aggregation, and runtime close
(Cordis stages 2, 3, 5, and 10).

`Task/cancel` exists and `await` deliberately propagates cancellation or the
task failure. A lifetime owner additionally needs to wait for a task to finish
without aborting the rest of an aggregate cleanup. Gene exposes one explicit
observation interface:

```gene
(enum TaskOutcome [T E]
  (ok T)
  (error E)
  (panic Str)
  cancelled)

(task .join)  # -> (TaskOutcome T E)
```

`join` suspends until the task and all of its `ensure` cleanup have completed.
It never rethrows the joined task's recoverable error, panic, or cancellation;
it returns one immutable outcome instead. Panic text follows the same bounded,
non-authoritative summary rules as `$runtime/guard_call`. Cancellation of the
*joining task* still propagates normally, so `join` is not a way to make an
owner immortal.

Ordinary callers continue to use `await`. `join` is the explicit supervision
seam for task groups, effect ledgers, and shutdown code that must observe every
child before deciding which aggregate failure to report.

Root-lane `spawn` now normatively guarantees that it enqueues the child and
returns its `Task` before the child body begins. This lets a lane-owned lifetime
ledger record the task before any child-created effect becomes observable.

### 2.1 Verification

- joining successful, failed, panicked, and cancelled tasks returns the matching
  variant;
- joining waits for suspending `ensure` cleanup;
- joining twice returns the same outcome;
- cancelling the joining task propagates cancellation without cancelling an
  otherwise independent joined task; and
- a root-lane child cannot run before the spawning turn records its handle.

## 3. Root-lane assertion

**Unblocks:** construction of lane-owned Cordis runtimes (stage 1).

Gene can request root placement with `spawn ^lane root` and can assert that the
current turn is already on that lane through a narrow runtime operation that
does not expose scheduler or thread identities:

```gene
($runtime/require_root_lane)  # -> Nil or raises RuntimeLaneError
```

Cordis calls this during `new_runtime`. The check is synchronous, carries no
authority, and has the same meaning on native and single-threaded/WASM targets.
It avoids baking thread ids or scheduler implementation details into packages.

### 3.1 Verification

- application entry and `spawn ^lane root` pass;
- a worker-placed task fails with `RuntimeLaneError`; and
- the result is stable across nested function and protocol calls.

## 4. Capability-gated filesystem watching

**Unblocks:** the automatic file-watch HMR adapter in Cordis stage 9. Manual
`Loader/reload` remains implementable without it.

Gene exposes a bounded watcher in `gene/fs`:

```gene
(import $fs [watch FsWatcher FsChange])

(var watcher
  (watch plugin_root ^recursive true ^capacity 256))

(var change watcher/.recv)  # suspends
watcher/.close
```

The interface and authority contract are:

- `watch` requires the existing `fs/ReadDir` capability for the canonical
  watched root. A caller could already poll the same names with `list_dir`, so
  watching does not need a second authority vocabulary. `ReadFile` or a
  write-only grant is insufficient.
- `FsChange` is frozen data with `^kind` (`created`, `modified`, `removed`,
  `renamed`, or `rescan_required`), canonical root-relative `^path` when one
  event is known, and optional `^from` for rename.
- `recv` suspends until one change is available and raises `WatcherClosed` only
  after close and buffered-event drain.
- the queue is bounded. Overflow coalesces to one `rescan_required` change;
  events are never silently dropped while pretending the stream is complete.
- `close` is idempotent, wakes a pending receiver, and releases native watcher
  handles. Cancellation of a pending receive does not leak the watcher.
- symlinks do not enlarge the watched root. Recursive discovery applies the
  same canonical containment rule as other filesystem operations.
- platforms without a native watcher may use a bounded polling adapter with the
  same observable contract.

Debouncing, digest comparison, dependency closure, and reload policy remain in
Cordis. The standard library reports filesystem change; it does not understand
modules or plugins.

### 4.1 Verification

- create, modify, remove, and rename are reported with normalized relative paths;
- recursive watches include new subdirectories without escaping through links;
- overflow emits `rescan_required`;
- close and cancellation release all native resources; and
- a watch outside the granted root is rejected before opening an OS handle.

## 5. Existing facilities reused unchanged

Cordis does not require new language machinery for its domain model. The
following implemented facilities remain the intended foundation:

- bounded `Env` evaluation, `with_capabilities`, and
  `$runtime/guard_call` for the default `PluginInvoker`;
- nominal protocols, scope-sensitive typed boundaries, opaque values, frozen
  data, cells, and ordinary package imports;
- root-lane `spawn`, `Task/cancel`, structured `scope`, timers, bounded
  channels, and actors;
- `$runtime/configure_module` for trusted modules that were already loaded;
- `Store`, `$fs/write_text_atomic`, and `crypto/sha256` for manifests and
  persistence;
- the `log` module for diagnostics; and
- `$runtime/load_sandboxed` as a compatibility path for non-transactional
  loaders.

In particular, Gene does not need Cordis-specific contexts, dependency epochs,
effect scopes, hook modes, provider registries, or composition transactions.
Those mechanisms remain local to the Cordis module.

## 6. Delivered order

1. Added `runtime/require_root_lane` and the root-lane spawn ordering test.
2. Added `Task/join` and `TaskOutcome`.
3. Implemented `SandboxTransaction` preparation/commit/discard plus
   `SandboxGeneration` graph snapshots and release.
4. Added the capability-gated `fs/watch` adapter.
5. Updated `docs/spec/concurrency.md`, `docs/spec/modules.md`, `docs/stdlib.md`,
   the implementation-status inventory, and the Gene language skill references.

The first two unblock the Cordis kernel. Sandboxed generations unblock the
loader and manual HMR. Filesystem watching is last because it is only an input
adapter for an already-testable `Loader/reload` operation.
