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

Top-level exported functions annotate every parameter and return. Their public
JS functions validate both directions around an internal implementation.
Namespace functions receive the same checks at their exported object edge.
Names are mangled injectively: `$` → `$$`, `?` → `$q`, `!` →
`$b`, `-` → `$h`, other bytes → `$xHH`, with prefixes for leading digits and
reserved JS words. `eval` and `arguments` take the reserved-word prefix too:
they are not keywords, but ES modules are always strict and strict mode forbids
binding either name.

**Module functions take named parameters**, spelled `^name : T` as on the VM,
with `^name local : T` to bind under a different name and `^name : T?` to make
one optional (omitting it binds nil). They lower to ordinary positional
JavaScript slots in declaration order: the profile always knows the callee
statically, so a call's props are placed into their slots at analysis time.
That keeps the lowering allocation-free — an options object per call is a cost
the hot paths refuse — and it means a JS caller sees the declared order and can
call the same export positionally.

Four things follow from the lowering, and each is a diagnostic rather than a
surprise:

- Named parameters are for **module functions**. A `message`, a `ctor`, a
  `js/fn` extern, and an inline callback take positional parameters, since a
  `(Fn [A ...] R)` type has nowhere to put a name.
- A positional parameter may not follow a named one. The VM admits either
  order; here a positional argument's slot is its position among the positional
  parameters, and interleaving would make that ordering something a reader
  reconstructs rather than reads.
- A function declaring a named parameter **cannot be used as a value**: through
  an `(Fn [A ...] R)` it would be invoked positionally, which is the call the VM
  refuses with `expects 0..0 argument(s)`.
- Defaults are not admitted, on named or positional parameters. `: T?` is the
  spelling for optional.

**Every call now accounts for every prop.** Props on a call used to be dropped
silently — `(add 1.0 2.0 ^oops 9.0)` compiled and threw `^oops` away, while the
VM raised `got unexpected named argument` for the same source. That was a
divergence no fixture could see, because the profile produced working code.
Nine cases in `tests/transpile/fixtures.json` hold the contract, four of them
asserting that both backends refuse the same source.

Every declaration form admits a closed property set — `mod ^profile`,
`type ^is`/`^props`/`^body`, `js/fn ^from`/`^import`, `^errors` on callables —
and rejects anything else with a source-located reason. That is what makes the
`derive` and `^repr native_wrapper` exclusions real: Gene spells both as
properties on the type (`^derive [P]`, `^repr native_wrapper`), so a guard on
the standalone `(derive …)` form alone would never fire.

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

The numeric operator set is the closed set of design §7.4. `/` on two `Int`s is
integer division truncating toward zero (`bigint` division already is); on two
`F64`s it is ordinary floating-point division. `//` is the truncated
**remainder** for both types and lowers to JS `%`. `%` is the unquote prefix and
never denotes arithmetic. A zero divisor raises the VM's own catchable
`(RuntimeError ^message "division by zero")` for both numeric types, so `F64` division
does not yield `Infinity` and `Int` division does not surface a JS `RangeError`.
Because it really is the VM's value, `catch Error` matches it.

**Indexing follows the VM's rule, not JavaScript's.** A negative index counts
from the end (design §1/§2, `users/-1/name`) and an out-of-range *write* raises;
an out-of-range *read* yields `void`. This holds for list path segments, dynamic
`%` segments, path `set`, and `Buffer`'s `get`/`set` alike, and it mirrors
`readIndex`/`updateIndex` in `vm.nim` including the error text. JS agrees with
none of it — `a[-1]` reads `undefined` and writes an expando the array never
sees, and a store past the end is silently dropped on a typed array — so reads
lower through a `$gene_at` helper and writes through `$gene_index`, which is
what keeps `xs/-1` and `(b .set -1 v)` from meaning two different things by
backend. `tests/transpile/fixtures.json` carries the agreement as `index.*`.

This is not free: it costs roughly 22% on a buffer-indexing hot loop
(`examples/miclone`'s meshing benchmark, 0.249 → 0.305 ms/chunk). A list segment
whose index is a non-negative literal still emits a bare `a[i]`, since neither
half of the rule can apply to it; `Buffer` access always goes through the
helpers, because its index is a runtime value at every call site that matters.

Supported control/data forms include mutable and immutable locals, `set` and
path `set`, compact and clause `if`, guards, short-circuit operators, all core
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

A function type is spelled **`(Fn [A ...] R)`**, which is the VM's spelling, and
it is the only one. The profile used to accept `(Callback [A ...] R)` as a
synonym and no longer does: the VM has no `Callback`, and rather than saying so
at the declaration it took the annotation and raised `unsupported type
annotation` at the first call that passed a function through one. A spelling
that compiles on one backend and fails late on the other is the divergence class
this profile exists to close, so `Callback` is now a source-located refusal
naming `Fn`. It has to be an explicit refusal because the nominal-type
fallthrough would otherwise read `(Callback [A] R)` as a nominal type *named*
`Callback` and emit working code for it.

`fail` accepts only values whose declared type implements `Error`. Catch types,
the branch-local `$ex` binding, and `ensure` lower to runtime type tests plus
`catch`/`finally`. `^errors` rows are validated
at compile time and erased; duplicate, non-error, and malformed rows are
rejected. `^effects` remains reserved and is rejected.

A match pattern whose head is a plain symbol remains one form over the class and
Gene-node representations. Catch headers are different: they contain a type,
never a pattern. Runtime diagnostics use the portable `RuntimeError` identity;
`catch Error` tests protocol conformance, `catch Any` is the catch-all, and the
body reads the caught value through `$ex`.

Node identity is a `Symbol.for("gene.node")` brand rather than
`instanceof GeneNode`, which is per-module and so false for any node that crossed
an import — that staleness also silently read an imported node's prop as
`undefined` through `$gene_get`.

Generators are wrapped as `GeneStream`: `peek`, `has_next`, `next`, terminal
errors, `yield void` skipping, idempotent `close`, iterator cleanup, and
upstream-close through `map`/`filter`/`into` are preserved.

## Async operational contract

`scope` owns every child created by `spawn`. Normal scope exit waits for live
children. Exceptional exit requests cancellation, waits for all children to
settle, then rethrows. `await` checks cancellation before and after suspension.
`finally` still runs exactly once. JavaScript cannot preempt running code, so
cancellation is observed at generated suspension points; actors and channels
remain VM-only because their semantics require the scheduler.

Asyncness is a property of the **call graph**, not of one body. A function is
async if it uses `scope`/`await` or calls an async function, and it is carried
across module boundaries with the imported signature — otherwise a caller's
`await` would land inside a plain `function` and the module would not parse.
Bodies are analyzed once, recording call edges; asyncness is then settled by a
single reverse-edge worklist pass, so the cost is linear in functions plus call
sites even though call graphs are recursive. Only top-level functions carry the
flag, so a type message, a constructor, a protocol message, a generator, and a
callback value are each rejected with a source-located reason rather than
emitting an `await` with nowhere to hang it.

Cancellation is represented by `GeneCancellation`, deliberately not an `Error`;
emitted ordinary catches rethrow it before testing Gene catch types. The test
is a `Symbol.for("gene.cancellation")` brand rather than `instanceof` or a `kind`
string. `instanceof` is wrong because the class is emitted per module, so
identity does not survive a module boundary and a module holding only a Gene
catch never emits the class. A string field is wrong because a nominal Gene type
may declare its own `^kind Str`, which would make
`(fail (T ^kind "gene_cancellation"))` uncatchable; a registry symbol cannot
collide with any Gene field name.

`tests/transpile_async_runner.nim` adversarially checks that a cancelled child
cannot be swallowed by `catch Any` and that `ensure` runs once, in both a
single-module and a two-module shape, and that a Gene error carrying
`^kind "gene_cancellation"` is still catchable.

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

### Generic collection operations (design §6.2)

The VM treats `map`, `filter`, `take`, `into`, and `each` as generic functions
whose eager `List`/`Map` methods answer in the receiver's own kind (design
§6.2). The profile keeps its stream-shaped surface: `map`/`filter`/`into`
accept a `Stream` receiver, `to_stream` converts a `List` into one, and
`take`/`each` are not portable builtins. An eager receiver reaching these
operations is a compile-time rejection naming the missing message — never a
lowering that only looks equivalent. The portable pipeline is therefore the
§2.6 spelling, `(xs .to_stream; .map f; .filter p; .into [])`, which both
backends run. Closing the gap means giving the profile eager `List` lowers
with their representations decided first — bigint-to-number conversion for a
`take` count, `undefined`-to-`null` for a void map result, truthiness for a
`filter` predicate — and each decision pinned by a conformance fixture.

## Deliberate exclusions

The compiler gives dedicated diagnostics for explicit fexprs/`caller_env`, runtime
`eval`, `derive` (which remains VM module-initialization behavior, and is
rejected as the `^derive` property as well as the standalone form), actors,
channels and supervisors, native FFI, `^repr native_wrapper`/`^native`,
capability values, `import_impl`, `AtomicCell`/threads, and deep freeze/thaw.
These features require an evaluator, scheduler, native loader, authority model,
dynamic impl visibility, or persistent-data-structure runtime; full fidelity
belongs to the wasm VM.
