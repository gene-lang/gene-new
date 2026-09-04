# Cordis for Gene

Cordis is a Gene-native plugin runtime for spatially scoped services,
dependency-driven activation, deterministic effect ownership, hooks,
data-only composition, and recoverable hot reload.

The supported library entry is `src/cordis.gene`. Sandboxed plugins import only
`src/plugin_api.gene` plus explicitly shared service-contract modules.

```gene
(import [RuntimeOptions LoaderOptions invocation_limits
         default_plugin_invoker new_runtime]
  from "./src/cordis")

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
