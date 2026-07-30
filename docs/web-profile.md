# Gene `web` profile

Status: **implemented through the P5 component/DOM slice.** This is the
normative analysis and artifact contract for `gene build --target web`.
Anything not admitted here is rejected before emission with a source-located
reason.

## Module and artifact contract

A web module starts with `(mod name ^profile web)`. One source module emits
readable ES2022 `.mjs`, TypeScript 5.9.2 `.ts`, `.d.ts`, and direct `.gene`
source maps for both code artifacts. The root lockfile pins TypeScript and
`.node-version` pins CI Node. Emitted code never uses `eval`, `with`, or the
`Function` constructor.

Imports are unconditional top-level selected imports over a closed, acyclic
relative graph. Runtime functions, type/enum/protocol declarations, and
compile-time macros may cross that graph; macro imports disappear from ESM.
Static `ns` declarations containing
annotated functions lower to frozen exported objects, including nested
namespaces. Namespace reflection and executable namespace initializers remain
outside this static module image.

Top-level exported functions annotate every positional parameter and return.
Their public JS functions validate both directions around an internal
implementation. Namespace functions receive the same checks at their exported
object edge. Names are mangled injectively: `$` → `$$`, `?` → `$q`, `!` →
`$b`, `-` → `$h`, other bytes → `$xHH`, with prefixes for leading digits and
reserved JS words.

## Analysis and values

The web-only semantic IR is built from the shared expanded-source artifact. It
retains source and macro-call provenance, owns copied semantic descriptors, and
does not modify or replace GIR. The VM continues through its existing compiler
path.

The implemented types are `Nil`, `Void`, `Bool`, `Str`, `Sym`, exact `Int`
(`bigint`), `F64` (`number`), `Any` (`unknown` plus runtime checks), `Never`,
optional and union types, `List`, `PropMap`, structurally keyed `Map`, `Node`,
`Range`, callbacks, nominal types/enums, `Stream`, and `Task`. Nested boundary
validators are generated only for types used by the module. There is no
implicit `number`/`bigint`, `null`/`undefined`, object/map, or Promise/Task
coercion.

Analysis is bidirectional. Annotations seed bindings and expected types;
literals, locals, calls, paths, branches, patterns, and operators propagate
types. Calls check arity and arguments. Branches form explicit unions. Numeric
operators require identical `Int` or identical `F64` operands. `==` is
kind-strict and structural where Gene requires it; `same?` is identity. `Any`
entering a typed position creates a runtime check.

Supported control/data forms include mutable and immutable locals, `set` and
path `set!`, compact and clause `if`, guards, short-circuit operators, all core
loops and exits, destructuring and `match` (including list rest patterns),
static/dynamic path stages, selector closures with captured defaults and strict
missing-stage errors, quote/quasiquote, and shallow immutable list, prop-map,
and node literals. Immutable Gene `Map` uses a structural-key wrapper and
cannot be mutated.

## Types, errors, protocols, and streams

Nominal types emit classes with inherited property and ordered-body schemas,
inherited constructors, direct closed-schema construction, required/unknown
field and body-shape rejection, `void` normalization, revalidation after path
mutation, typed body patterns, and checked method boundaries.
Type-direct `super` becomes JS `super`. Enums emit frozen tagged values and
discriminated unions.

Protocols use unique symbols. User-type impls install symbol methods;
`Nil`/`Str`/`List` impls use generated side functions instead of patching
builtin prototypes. Qualified sends, protocol message values, `Self`
parameters, and protocol `super` (a statically selected parent-chain call) are
implemented. Scoped/overlay impl visibility is not.

`fail` accepts only values whose declared type implements `Error`. Typed catch
patterns and `ensure` lower to `catch`/`finally`. `^errors` rows are validated
at compile time and erased; duplicate, non-error, and malformed rows are
rejected. `^effects` remains reserved and is rejected.

Generators are wrapped as `GeneStream`: `peek`, `has_next`, `next`, terminal
errors, `yield void` skipping, idempotent `close`, iterator cleanup, and
upstream-close through `map`/`filter`/`into` are preserved.

## Async operational contract

`scope` owns every child created by `spawn`. Normal scope exit waits for live
children. Exceptional exit requests cancellation, waits for all children to
settle, then rethrows. `await` checks cancellation before and after suspension.
Cancellation is represented by `GeneCancellation`, deliberately not an
`Error`; emitted ordinary catches rethrow it before testing Gene catch
patterns. `finally` still runs exactly once. JavaScript cannot preempt running
code, so cancellation is observed at generated suspension points; actors and
channels remain VM-only because their semantics require the scheduler.

`tests/transpile_async_runner.nim` adversarially checks that a cancelled child
cannot be swallowed by `catch _` and that `ensure` runs once.

## Portable standard library and DOM

The emitter provides tree-shaken portable operations for string
join/split/trim/lower/predicates, URL component encoding, HTML escaping,
lossless-`Int` JSON parse/stringify, size, node anatomy, stream conversion, and
`map`/`filter`/`into`. Filesystem, network, process, environment, and capability
APIs must cross an explicitly declared JS boundary.

`tools/generate_dom_bindings.mjs` reads the pinned TypeScript `lib.dom.d.ts`,
accepts an explicit allowlist, and fails on unsupported shapes. It generates
`web/gene_dom_bindings.json` and `web/gene_dom.generated.d.ts`. `dom/render`
turns Gene node data into real DOM nodes, including attributes, body children,
and `on_*` event listeners. `examples/web_component.gene` and
`tests/transpile_dom_runner.nim` exercise a checked Gene event handler against a
DOM-shaped host.

## Deliberate exclusions

The compiler gives dedicated diagnostics for `fn!`/`caller_env`, runtime
`eval`, `derive` (which remains VM module-initialization behavior), actors,
channels and supervisors, native FFI, capability values, `import_impl`,
`AtomicCell`/threads, and deep freeze/thaw. These features require an evaluator,
scheduler, native loader, authority model, dynamic impl visibility, or
persistent-data-structure runtime; full fidelity belongs to the wasm VM.
