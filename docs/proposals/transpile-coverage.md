# Web-profile conformance coverage ledger

Status: **P0–P5 implemented.** `tests/transpile/fixtures.json` is consumed by
both the VM and Node runners. Eligible programs must produce the same canonical
envelope; exclusions must fail compilation with their recorded reason.
`nimble transpile_spec` also runs adversarial async and DOM component checks.

| Surface | Representative fixture/test |
|---|---|
| nil, void, truthiness, `??`, `&&`, `||` | `absence.*`, `truthiness.*`, `logic.*` |
| exact Int, F64, arithmetic, kind-strict comparisons | `numeric.*`, `scalar.f64` |
| functions, callbacks, checked JS ABI | `function.*`, `tests/transpile/web_interop.gene` |
| lists, mutable state, loops, guards | `list.*`, `control.state_and_loops` |
| destructuring, match, list rest | `pattern.*` |
| static namespaces and closed relative modules | `module.*` |
| local and imported template macros/provenance | `macro.*`, `tests/test_vm.nim`, `tests/test_cli.nim` |
| paths, default/strict selectors, `set`, shallow immutable data | `data.*` |
| structural Map keys, PropMap, Node, Range, Sym | `data.*`, `scalar.symbol` |
| nominal types, body schemas/patterns, ctors, inheritance, direct and protocol super | `type.*`, `protocol.super_chain` |
| enums and pattern payloads | `enum.payload_match` |
| protocols, builtin dispatch, message values | `protocol.*` |
| typed catch/ensure, checked `^errors` | `errors.*` |
| stream pull/skip/close and combinators | `stream.*`, `stdlib.list_map` |
| structured spawn/await/scope | `async.scope_spawn_await`, `tests/transpile_async_runner.nim` |
| portable string/URL/HTML/JSON/node/stream stdlib | `stdlib.*`, `web_advanced.gene` |
| DOM node edge and checked event callback | `tests/transpile_dom_runner.nim` |
| fexprs/eval/actors/FFI/capabilities/import_impl/AtomicCell/freeze/derive/effects | `rejected.*` |

The current manifest contains 57 cases. `tests/transpile_typecheck.mjs` also
strictly checks emitted advanced, namespace, interop, equality, and component
TypeScript plus the generated DOM declarations with TypeScript 5.9.2.
