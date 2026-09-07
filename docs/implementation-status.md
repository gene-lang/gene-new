# Implementation status

**Updated:** 2026-09-07. This is a navigation summary of the current tree;
[focused specs](spec/README.md) define the implemented contract. Dated benchmark
and verification results live in [reports](reports/README.md).

## Implemented surfaces

| Area | Current support | Details |
| --- | --- | --- |
| Values and syntax | Node projections, reader/printer, mutable and shallow immutable collections, selectors, and sequenced pipelines | [Reader](spec/reader.md), [pipelines](pipelines.md) |
| Calls and control | Eager calls, messages, checked Callable views, template macros, named fexprs, and tail-elidable call chains | [Calls](spec/calls.md), [macros/fexprs](macro-design.md), [tail calls](tail-calls.md) |
| Types and protocols | Nominal schemas, constructors, inheritance, gradual checks, declaration-bound Self, explicit overrides, and scoped implementation visibility | [Types](spec/types.md), [Self](self-type.md), [scoped impls](scoped-impls.md) |
| Absence and collections | Nil-admitting fixed parameters default to nil; map normalizes void; filter_map drops void; missing field lookup remains distinct | [Nil/void](spec/nil-void.md) |
| Authority and eval | Provider-backed contexts, attenuation, module/import ceilings, Env-parent intersections, retained eval closures, and execution limits | [Authority contract](spec/authority.md), [provider reference](capabilities.md) |
| Packages | Format-1 workspaces/manifests, deterministic dependency solving, lockfiles, multiple versions, git/path/local-registry sources, immutable stores, vendoring, and cache GC | [Packages](packages.md), `tests/test_package.nim` |
| Package builds | System-library discovery, pure-Gene target graphs, source snapshots, deterministic derivations, artifact reuse, and parallel library builds | [Builds](package-builds.md), `tests/test_build.nim` |
| Concurrency | Cooperative fibers, scoped tasks, channels, actors, cancellation, timers, and an experimental bounded worker lane | [Concurrency](spec/concurrency.md) |
| Services and persistence | HTTP event loop, routing, actor-pool dispatch, WebSockets, HTTP client, logging, serialization, stores, and filesystem watching | [Stdlib](stdlib.md), [HTTP server](http-server.md), [persistence](persistence.md) |
| Application events | Event/Bus/Subscription, nominal matching, publication policies, and recording/composite sinks with lane ownership | [Events](events.md) |
| Web backend | Checked web subset through P6: TS/ESM/declarations/source maps, interop, macros, types/protocols, collections, streams, async cancellation, DOM, and embedded web_module lifecycle | [Web profile](web-profile.md), [compilation](web-compilation.md) |
| Native interop | Rooted native API, typed FFI, managed wrappers, and experimental typed-native C lowering with dynamic entry/ownership adapters | [Native types](native-types.md), [native examples](../examples/native/README.md) |
| Tools | Formatter, LSP, structural viewer, module documentation, package commands, and wasm-hosted VM | [Documentation index](README.md) |

The web profile supports eager map/filter_map/filter for Lists, PropMaps, and
Maps, plus lazy Streams. Unsupported constructs are rejected explicitly;
full VM behavior does not silently fall back to generated JavaScript.

The typed-native backend remains experimental. Pure-Gene package builds do not
imply native recipe/link support. Direct protocol-send overlay guards are
module-local; cross-module overlays over AOT-compiled types remain a known
limitation. Loaded AOT libraries remain pinned for process lifetime.

## Applications exercising the runtime

- [Cordis](../examples/cordis/README.md) uses nominal service/hook keys, exact
  realms, lifecycle transactions, policy-bound calls, sandbox generations,
  persistence, filesystem watching, and HMR.
- [Miclone](../examples/miclone/README.md) exercises packed buffers, shared VM/web
  contracts, protocol dispatch, numerical code, and a browser client.
- [Todo app](../examples/todo_app/src/main.gene) combines routing, SQLite, HTML,
  CSS, and embedded browser code in one authored source file.

[Application foundations](reports/application-foundations.md) records the
cross-application changes and their measured validation.

## Known limits and deferred work

- **Eval-defined types:** evaluating a nominal type with methods and invoking
  an instance method can hang; the authority review reproduced this on the
  unchanged runtime. Current eval-retention coverage uses functions/generators.
- **Retention and concurrency:** some mixed scope/closure cycles remain outside
  the runtime's collection support. AtomicArc does not provide ORC cycle
  collection. See the dated [retention findings](reports/application-foundations.md).
  Production M:N lifecycle/load balancing remains future work.
- **Package distribution:** hosted registry transport, publication/signing,
  native/resource build recipes, mixed images, and full application installation
  remain future work. Lockfiles, local registry sources, and multiple installed
  source versions are already implemented.
- **Runtime event instrumentation:** events phases 2–4 are not implemented.
  The withdrawn producer can be recovered from commit `0eb4989` if that work
  resumes. The phase-1 native EventSink error-row declaration gap remains.
- **Language and backends:** static effect checking, full hygienic compile-time
  function macros, static enum exhaustiveness, unrestricted foreign callbacks,
  JIT, and broader AOT support remain deferred. Existing controlled impl-level
  inheritance is implemented; it is not arbitrary partial impl composition.

See [proposals](proposals/README.md) for future designs. Reference documents
outside that directory identify deferred extensions in their own status text.
This summary does not promote historical acceptance criteria into sandbox,
performance, or production-readiness guarantees.
