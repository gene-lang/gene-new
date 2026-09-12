# Cordis for Gene

Cordis is a Gene-native plugin runtime for spatially scoped services,
dependency-driven activation, deterministic effect ownership, hooks,
data-only composition, and recoverable hot reload.

The supported library entry is `src/cordis.gene`. Sandboxed plugins import only
`src/plugin_api.gene` plus explicitly shared service-contract modules.

```gene
(import [RuntimeOptions LoaderOptions invocation_limits
         default_plugin_invoker new_runtime]
  ^from "./src/cordis")

(var runtime
  (new_runtime
    (RuntimeOptions ^logger logger ^invoker (default_plugin_invoker)
                    ^default_limits (invocation_limits))))
(var loader
  (runtime .loader
    (LoaderOptions ^plugin_root "plugins" ^shared ["src/plugin_api.gene"]
      ^max_namespaces [] ^capability_catalog #{} ^capability_ceiling nil
      ^default_limits nil ^reload_policy nil)))
```

See `docs/design.md` for the behavioral contract and `src/main.gene` for a
runnable sandboxed clock/reporter composition.

Optional adapters are separate imports: `include.gene` for data-file loading
and atomic persistence, `hmr.gene` for bounded filesystem watching,
`timer.gene` for effect-owned timers and tick streams, and `actor.gene` for a
typed bounded cross-lane service handle.

From this directory:

```sh
../../bin/gene test
../../bin/gene run cordis_demo
../../bin/gene run probes/hmr.gene
```

The HMR probe runs as an ad-hoc file because it deliberately rewrites and then
restores a plugin fixture; the package test target remains read-only.

`gene test` executes 15 named scenarios and fails on an empty selection.

`LoaderWatcher.inspect` reports `active`, successful `reloads`, `failures`, and
the last error message. A rejected save leaves the previous provider live and
the watcher continues receiving subsequent saves.

Host adapters can call `invoke_effect_owner(owner, PluginCallKind/operation,
callable, args)` through the supported facade. It checks admission, acquires an
engine invocation lease, and applies the owner's execution policy. Retain an
exact `EffectScope` for callbacks belonging to an activation revision. The
lease covers that invocation; a returned stream or task still needs an owned
consumer/effect until its deferred work finishes.

For trusted host compositions, `Loader.reconcile_plugins(manifest, plugins)`
stages already loaded `PluginSpec` values keyed by manifest entry ID. Entries
without a host admission still use sandbox module loading. These admissions
stay outside the data-only manifest and are retained for reload; a subsequent
host reconciliation supplies the complete admission map.

Its optional `^policies` map admits per-entry host policy: `selectors` holds
capability specifications, and `inherit` defaults to false. Inheritance is
allowed only for explicitly admitted host plugins and cannot bypass a configured
loader ceiling. Source-loaded plugins always receive an explicit restricted
context. These policy values are host inputs, separate from the data manifest.

`LoaderOptions.descriptor_factory`, when supplied, receives the prepared
module, normalized entry, and generation graph, and returns a `PluginSpec`.
Harness uses this to verify source digests and run its existing bounded,
capability-empty `init(DescriptorContext)` contract. It seals the module's
entry capability ceiling before activation. Stored generated modules keep
their existing exports and imports.

`LoaderOptions.publication` optionally accepts a `PublicationParticipant`.
Cordis calls `prepare` before candidate activation, `publish(ticket)` while
replacing live indexes and before notifications or old cleanup, and
`abort(ticket)` after cleaning a rejected candidate. The participant is trusted
host code: publication must only swap prepared in-memory state, without I/O,
yielding, plugin callbacks, or failure. Participants require staged
reconciliation and cannot use stop/start reload.

`LoaderOptions.allow_pending` lets a host publish a composition whose missing
dependencies leave plugins pending. Failed activations still reject the
candidate. The default continues to require every desired plugin active.
Owned children deliberately disposed during staging are no longer desired
effects and do not prevent publication. Loader ownership includes descendants,
so their providers cannot leak from a retired generation into its candidate.
Lifecycle transitions run on the runtime's host executor. A notification from
restricted plugin code therefore cannot impose its ambient permissions or
deadline on host transition bookkeeping; `PluginInvoker` still applies each
plugin's own context and limits to its callbacks.
