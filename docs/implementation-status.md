# Implementation status

**Status date:** 2026-08-29

The current VM implements the reader/value/printer pipeline, callable-first
bytecode execution, runtime fexprs and template macros, selectors and streams,
the generic collection operations (design §6.2: `$map`/`$filter`/`$take`/
`$into`/`$each` and their bare sends dispatch on the receiver's type; the
eager `List`/`Map`/`Set` methods answer in their own kind, a user type joins
the generic by declaring the message, and a missing method is the send path's
`MessageError` for every spelling), gradual nominal types,
protocols/derivation with scoped impl visibility
(canonical/scoped/overlay, `import_impl`, transactional reload —
`docs/scoped-impls.md`), structured tasks/channels/actors, module/eval
overlays, explicit capability values, native roots/calls, typed FFI
boundaries, `^repr native_wrapper` types (design §16.6),
serialization, the experimental `gene runurl` URL-module entry
(design §15.9), and the AI-agent support libraries exercised by
`examples/ai_agent`.

The normative implemented surface lives in `docs/spec/` and is checked by
`nimble spec`. Unit and integration coverage runs with `nimble test`; broad
runtime verification uses `nimble verify`.

The front-end transpilation proposal is implemented through its P6 embedded
web-module slice.
`gene/html/render` is the shared node-to-text edge, and `gene/css` supplies
ordered declaration/rule data, nested/media rendering, deterministic scoped
classes, and scoped keyframes. `examples/todo_app/src/main.gene` uses these APIs
instead of local renderers or raw CSS strings. A backend-neutral fixture
manifest and canonical result envelope run
under `nimble transpile_spec`; the fixed bigint/JSON spike runs under
`nimble transpile_perf`. `gene build --target web` analyzes the deliberately
bounded `web` profile into a separate semantic IR and emits readable ES2022,
TypeScript declarations/source, and direct Gene source maps over a closed
acyclic module graph. Exact `Int` uses `bigint`. The profile covers macros,
state/control flow, matching, paths/selectors, structural maps and nodes,
nominal types/enums/protocols, checked errors, streams, portable stdlib calls,
structured tasks/cancellation, static namespaces, and generated DOM bindings.
The eager collection methods of design §6.2 remain VM-only: the profile
compiles the stream-shaped pipeline (`to_stream` then the stream operations)
and rejects an eager receiver at compile time (`docs/web-profile.md`).
Checked JS exports/imports, callbacks, method edges, and an interactive Gene
component exercise the ABI. `derive` deliberately remains VM-only; fexprs,
runtime eval, actors/channels, native FFI, capabilities, scoped impl imports,
threads, and deep persistent freeze/thaw receive explicit profile diagnostics.

A `web_module` block embeds a web-profile source unit inside an ordinary
module, so a complete page — server logic, HTML, CSS, and browser behavior — is
one authored file with no build step, bundler, or hand-written JavaScript.
`gene run examples/todo_app/src/main.gene` serves a page whose delegated click
handler was authored in that same file and enhances existing server-rendered
rows. The block's forms keep their original positions rather than being
reprinted and re-read, so diagnostics and source maps name the lines the author
wrote; it sees the web prelude and its own declarations only, so it cannot
close over a database handle or a request. Compilation happens once per module
version behind the `compile_web_asset` seam, never per request. The owning
`Application` holds the resulting immutable assets and their content-addressed
routes, which every `Server` it starts answers; `$web/script` and
`$web/stylesheet` return finished nodes, and referring to an asset is what
publishes it. Source maps carry only the embedded block, so server source never
enters a browser artifact. `nimble transpile_spec` runs the lifecycle suite.

The experimental `typed_native` C backend (`gene compile --target c`,
`docs/proposals/native-type.md` Part II) lowers native-pointer parameters,
field access, and direct typed calls, and its dynamic boundary is now
connected in both directions: `aot/load` opens a compiled library and binds
its `^native_entry` functions and `ffi/fn` wrappers as ordinary callables, so
Gene code can call compiled machine code and managed wrappers cross the seam
with borrow/transfer/copy ownership. The lowerable subset covers field access,
locals, direct/FFI/protocol calls, arithmetic, comparisons, `if`, `while`, and
block statements.

The boundary enforces the same contracts the interpreter's FFI path does — the
generated wrappers call those converters rather than a parallel set — and ABI
compatibility is verified rather than assumed: a library declares every native
type it transitively depends on with layout and declaration fingerprints, `load`
rejects a mismatch before binding anything, and an incompatible redeclaration
after load makes already-bound callables refuse.

It remains experimental. Direct protocol sends are guarded only within the
compiling module, so a cross-module overlay over an AOT-compiled type is a
known limitation, and there is no `gene build` producing a linked artifact —
that waits on package and dependency support, since what to link against is a
dependency-graph question. `examples/native` drives `cc` from a shell script
meanwhile. Loaded AOT libraries are pinned for the process lifetime, because
their callables and release shims can outlive any individual call.

Package support is shipped through `docs/proposals/package.md` Stage 3: ad-hoc
and regular application packages discovered from the nearest ancestor
`package.gene`, data-only manifests, the application and user stores with
deterministic precedence, two-phase exact-version resolution, `^pkg` imports
with per-package module boundaries, package/module identity as the module-cache
key, and `gene pkg show|locate|graph|install`. Hosted registries, semver
solving, lockfiles, content addressing, publishing, and multiple installed
versions of one name are not.

The application event bus (`docs/events.md` phase 1) is implemented:
`gene/event` supplies the `Event` root, `Bus`, `Subscription`, `PublishResult`,
`Matcher`, `exact`, the `ErrorPolicy` enum, the `EventSink` protocol, and the
recording/null/composite sinks, with nominal `^is` matching over compact type
ids, copy-based deep-freeze on publish, snapshot dispatch, and both error
policies. The runtime instrumentation half — phases 2-4, `runtime/EventStream`
and the `runtime/...` event families, category configuration, emission sites,
and safe-point draining — is **not** implemented. An unfinished producer was
committed to `src/gene/` in 0eb4989 without ever being included or compiled and
has been withdrawn; recover it with
`git show 0eb4989:src/gene/runtime_events.nim` before restarting that work.

Lane ownership (§9.1) *is* enforced: a bus records the lane that created it and
refuses operations from another with `SubscriptionError`. That is not redundant
with the bus not being `Send` — sendability stops a bus being transferred, but
an embedding host thread calling in through `native_api` transfers nothing. The
remaining phase-1 gap is that `EventSink:emit` implements but cannot *declare*
its `^errors [EventPublishError]` row, because natively registered protocols
have no per-message error types.

Deferred work is explicitly non-normative. Major deferred areas include package
registries and lockfiles, static effect rows, full hygienic compile-time
function macros, partial protocol impl composition, static enum exhaustiveness,
arbitrary escaping foreign callbacks/foreign-thread VM entry, JIT, and AOT
beyond the experimental backend described above.

For the AI agent, typed tools, event tracing, persistence, gateway surfaces,
cancellation, and the embedded terminal are shipped. The next packaging slice
is migrating its current built-in capability reads to explicit named `main`
grants now supported by `gene run` and `GeneCall`.
