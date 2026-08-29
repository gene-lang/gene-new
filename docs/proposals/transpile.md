# Gene → TypeScript: a front-end compilation target

Status: **implemented through P5.** Tier 0 printers, the bigint decision,
shared macro expansion/provenance, the web semantic IR, readable TS/ESM and
declaration artifacts, checked interop, the P3 language/data/runtime breadth,
structured async/cancellation, the generated DOM subset, and an interactive
Gene component are in the tree. The shared conformance manifest has 57 VM/web
cases plus adversarial cancellation and DOM runners. Deliberate exclusions in
§4.2 remain exclusions, not unfinished fallbacks.
Related: `docs/wasm.md` (Target A is
implemented and is the competing answer), `docs/proposals/jit-pipeline.md`
(the precedent for "a decidable subset gets its own backend"),
`docs/design.md` §7/§10/§11/§15.

---

## 0. What is being asked

> Write CSS and JS in Gene when writing a web front end.

That sentence contains three separable problems with wildly different costs.
Conflating them is the main way this project fails, so name them first.

| | Problem | What it needs | Cost |
|---|---|---|---|
| **T1** | Produce **CSS** from Gene | A data DSL and a printer | Small. No compiler work. |
| **T2** | Produce **markup** from Gene | The data model exists; a real renderer does not | Moderate |
| **T3** | Run **behavior** written in Gene in the browser | Either a Gene runtime in the page, or a Gene→JS compiler | Large |

T1 and T2 are stdlib features. Only T3 is a compiler backend. The existing
`examples/todo_app/src/main.gene` already models T2 —
"HTML is ordinary Gene node data until render time … one `node -> text` edge" —
but each hand-rolls that edge (§3.2), and both fake T1 with a raw `"""…"""`
string. That string is the gap you feel; the missing renderer is the one behind
it.

---

## 1. Recommendation

**Three tiers, shipped in order, each independently useful.**

- **Tier 0 (`gene/css`, `gene/html`)** — CSS and markup as node data with real
  printers. Stdlib only, no compiler backend, no DOM. This removes the raw CSS
  string from `todo_app`, gives component-scoped styles, and replaces two
  hand-rolled HTML renderers with one. Do this first regardless of Tier 1.
- **Tier 1 (`gene build --target web`)** — a **`web` profile**: a statically
  decidable subset of Gene compiled to readable **TypeScript**, gated by a
  conformance suite run against the VM. This is the real work, and §4 is honest
  that its first slice is much smaller than its eventual surface.
- **Tier 2 (interop)** — declared JS externs, `.d.ts` emission, DOM, and the
  node→DOM edge. Listed third, but its **ABI is proven early** (§8 P2.5):
  interop is why this backend beats wasm, so it cannot wait for the subset to
  grow. Only breadth is deferred.

**Target TypeScript, not JavaScript.** Gene's annotation surface (§7) has a
near-1:1 TS image, TS is what the rest of a front-end team reads, and the
emitted `.d.ts` is how non-Gene code consumes Gene modules. Emitting JS throws
away information the compiler already has for free.

**Do not build a general Gene→JS compiler.** Full fidelity in JS is a second
implementation of Gene, and §2 explains why the wasm VM already occupies that
slot better.

---

## 2. Why not just ship the wasm VM?

`docs/wasm.md` Target A is **implemented**: `nimble wasm` produces
`web/gene.js` + `web/gene.wasm` and a browser playground. Any transpiler
proposal has to justify itself against a working alternative.

| | wasm VM in the page | transpile to TS |
|---|---|---|
| Semantic fidelity | **Total.** explicit fexprs, `eval`, actors, FFI, macros, everything | A subset; drift is a permanent risk |
| Payload | `web/gene.wasm` is **~4.1 MB** today, flat regardless of program size | Proportional to your code + a small runtime |
| Tree-shaking / code splitting | None | Ordinary bundler behavior |
| DOM access | Every call crosses the JS↔wasm boundary | Direct |
| Devtools | Gene values are opaque bytes; no breakpoints in Gene | Real stack frames, real source maps |
| npm interop | Hand-written bridges | Ordinary imports |
| Types for JS consumers | None | `.d.ts` |
| Startup | Fetch + instantiate 4 MB, then compile Gene source | Parse a normal JS bundle |

**They are complementary, not competing.** The rule of thumb:

- The page **is** the Gene program (playground, editor, canvas app, notebook,
  something already using actors/`eval`): **ship the wasm VM.** Fidelity wins,
  and 4 MB amortizes over a long session.
- The Gene code is **part of** an existing web app (a form, a component, shared
  validation/domain logic reused from the server): **transpile.** 4 MB for a
  widget is a non-starter, and you need devtools and npm.

The second case is what "write a web front end in Gene" usually means, and it is
the one nothing in the tree serves today.

---

## 3. Tier 0 — CSS and markup are *data*, not codegen

This is the cheapest and highest-value piece, and it needs no backend at all.

### 3.1 Why CSS must not be a transpile target

CSS has no control flow. There is nothing to compile. The computation that
*produces* CSS is ordinary Gene running at build time — which is exactly the
design's own idiom for HTML. Making CSS a compiler feature would be a category
error: it is a printer over node data.

**Declarations must be ordered body nodes, not props.** A `PropMap` silently
loses duplicate declarations (`^display` twice, the standard fallback idiom) and
cannot interleave declarations with nested rules — and CSS is order-sensitive in
both cases. It also cannot spell custom properties (`--brand-color`) or vendor
prefixes without a lossy underscore rewrite. So:

```gene
(import $css [css rule decl media render])

(let card_styles
  (css
    (rule ".card"
      (decl padding       "20px 24px")   # sugar: snake_case → wire name
      (decl border_radius "14px")
      (decl "--brand"     "#18181b")     # string = raw wire name, no rewrite
      (rule "&:hover" (decl background "#fafafa")))
    (media "(max-width: 600px)"
      (rule ".card" (decl padding "12px")))))

(render card_styles)
```

- A bare symbol argument is sugar rewritten `snake_case` → `kebab-case`, the
  same split as `content-type` in `gene/net/http`: the Gene name is
  `border_radius`, the wire name is `border-radius`. A **string** argument is a
  raw wire name passed through untouched, which covers `--custom`, `-webkit-*`,
  and anything future.
- Selectors stay strings — `.card` and `&:hover` are CSS syntax, not Gene
  symbols. Nesting is structural, so the tree stays ordinary node data and
  `$props`/`$body`/quasiquote/`map` all work on it unchanged.
- Because it is data, **values are computed in Gene**: tokens are bindings, a
  theme is a map, a variant is a function returning rules.
- **Scoped class names** need a defined canonical serialization to hash: which
  fields participate, that source meta is excluded, how collisions are handled,
  and how the generated name is substituted into selectors and `@keyframes`
  names. Underspecified hashing is how scoped-CSS systems break.

### 3.2 Markup is data; the shared renderer is implemented

`(html (body (div ^class "card" …)))` is ordinary node data. `gene/html/render`
now owns the node→text edge, including boolean/void attributes, raw-text
elements, contextual escaping, arbitrary `data-*`/`aria-*`, and deterministic
attribute order. The examples use it instead of hand-rolled renderers.

**The DOM edge is not P0 and not "pure stdlib."** The native runtime has no DOM;
node→DOM requires either the wasm JS bridge or the Tier 1 interop layer, which
first exists at P2.5. See §7.2 for why it is still the most interesting edge.

### 3.3 What Tier 0 does *not* give you

Event handlers. `^onclick` has to hold *behavior*, and behavior in the browser
is T3. Tier 0 gets you server-rendered pages with generated CSS — genuinely
useful, and honestly the whole story for a `todo_app`-shaped app — but the
moment you want a click handler written in Gene, you are in Tier 1.

---

## 4. Tier 1 — the `web` profile

### 4.1 The governing principle

> **A form is in the profile if its support is bounded and tree-shakeable.**

"No runtime residue" was the wrong line: the accepted list below already needs a
`GeneNode` class, structural `eq`, protocol identity, gradual-boundary
validators, and stream adapters. Those are semantics, not conveniences. So
every accepted feature must be classified as **native lowering** (compiles to
plain TS, zero import), **runtime helper** (pulls a named, measured, individually
tree-shakeable export from `@gene/rt`), or **rejected**. A feature with no
bounded helper is rejected. `jit-pipeline.md` establishes the pattern: an
eligibility predicate, checked at a known point, routing a subset elsewhere.

### 4.2 Eligibility

This list is the **destination**, not the first slice. §8 starts far smaller;
a feature joins only when its representation contract and conformance cases are
written. Marked *(H)* where it costs a runtime helper.

**In the profile:**

- `fn`, `let`/`var`/`set`, `set` on paths
- `do`, `if`, `if_yes`, `if_not`, `&&`, `||`, `!`, `??`
- `while`, `loop`, `repeat`, `for`, `break`, `continue`, `return`
- `match` and destructuring (§8) — decision tree, native lowering
- `try`/`catch`/`ensure`, `fail` *(H)* — typed errors and `^errors` rows have no
  TS expression; the row is checked at compile time and erased
- `type` → class; `enum` → discriminated union; `protocol`/`impl` → §4.7 *(H)*
- `ctor`/`new`, direct `(T …)` construction, `super` *(H)* — closed-schema
  validation, `void` normalization, and the `(T …)`-vs-`new` split are runtime
  behavior, not a class declaration
- scalars `Nil`, `Void`, `Bool`, `Str`, `Sym`, plus `List`; `Int`/`F64` gated on
  §4.5; `Map`, `PropMap`, `Node`, `Range` *(H)*
- `#[]`/`#{}`/`#()` shallow-immutable literals → `Object.freeze`
- selectors and slash paths **that resolve statically**
- `Stream`, `yield` *(H)* — a JS generator is the substrate, not the contract
  (§4.4)
- `Task`, `spawn`, `await`, `scope` *(H)* — structured ownership and
  non-catchable cancellation under §4.8
- `macro`, quasiquote/`%` — expanded at compile time, native lowering.
  **Decision: `derive` remains VM module-initialization behavior and is rejected
  by the web profile** (§4.3).
- `mod`, `ns`, `import` → ES modules under §4.9's restrictions

**Rejected, with a diagnostic naming the reason:**

| Rejected | Why |
|---|---|
| explicit fexprs / `caller_env` | Needs a live evaluator plus retained argument syntax at every trailing-`!` call site (§3). That is the wasm VM. |
| `eval node ^in env` | Needs the whole front end in the page. |
| Actors, `Channel`, `supervisor`, `ActorRef` | Bounded mailboxes with backpressure and an M:N scheduler need a scheduler; JS has one event loop and no preemption. |
| FFI, `C/*`, `^repr native_wrapper`, `$ffi/Load` | No dlopen. |
| Capability values, `$fs`, `$net`, process/env | Not the browser's authority model. |
| `import_impl` and overlay-scoped impls | Impl visibility becomes a *runtime* resolution (`docs/scoped-impls.md`); the profile needs impl sets fixed at compile time. |
| `AtomicCell`, threads | Single-threaded target. |
| Deep `$freeze`/`$thaw` with structural sharing | Ships a persistent-data-structure library; revisit later. |
| Bignum promotion | See §4.5. |

The rejection list is not a list of regrets. It is the definition of the
profile, and every entry on it is exactly the reason the wasm VM exists.

### 4.3 Where the backend hooks in

Three candidate inputs, and the choice is not close:

1. **GIR bytecode.** *Rejected.* GIR is a stack machine (`opPushConst`,
   `opLoadLocal`, …). Lowering it to JS yields either an explicit operand-stack
   simulation or a reconstructed expression tree — the first is unreadable and
   slow, the second means you threw away the tree and rebuilt it. Readable
   output is the entire point (§4.10).
2. **Raw reader output.** *Rejected.* Macros unexpanded, declarations
   uncollected, nothing resolved. The backend would reimplement the front end.
3. **A semantic IR** carrying binding identities, checked types, lvalue
   category, control-flow shape, visible impl sets, declaration descriptors, and
   source + expansion provenance. **Recommended.**

A "resolved node tree" is too weak a contract — an emitter needs all of the
above, and it cannot be the *only* artifact either: `gene fmt` and the LSP must
keep the **unexpanded** source tree. So P1 produces an IR *alongside* the
original and expanded trees, and must specify their ownership and lifetime.

**The IR is web-only, and GIR is not migrated onto it.** Requiring GIR emission
to consume it would force the IR to represent *all* of Gene — fexprs, `eval`,
actors, scoped impls, dynamic modules — before the first tiny P2 function ships.
That is a whole-compiler replacement, and it puts `compiler.nim`'s hot path at
risk before the product hypothesis has been tested. Instead: factor only the
genuinely shared pieces (macro expansion, source and expansion provenance),
leave the existing GIR path intact, and build the semantic IR for **eligible
forms only**, rejecting anything it cannot represent. Unifying GIR behind it is
a later option earned by evidence, not a precondition.

**The IR also implies an analysis phase that does not exist.** "Checked types"
is not free here: `gir.nim:227` stores `paramTypes` as retained *type
expressions*, and enforcement — plus generic inference and `Any` adaptation at
call boundaries — happens at runtime in `vm.nim`. `compiler.nim` has no static
checker. Annotated parameters and returns do **not** hand the emitter a checked
type for every local, call, branch, or numeric operation. So the profile's
analysis rules are their own named deliverable: what is inferred, what must be
annotated, how control-flow joins work, and when the compiler emits a runtime
check versus rejects the program outright. Otherwise P1 quietly contains a type
checker of undefined scope and diagnostics.

Two things do not exist today:

- **Macro expansion is fused into GIR emission.** `compileMacroCall`
  (`src/gene/compiler.nim:2119`) expands and immediately calls `compileExpr`.
- **`derive` is not a compile-time phase at all.** Despite §11.4's framing, the
  implementation compiles derive bodies to `FunctionProto`s
  (`compiler.nim:6360`) and the VM invokes them while *defining the type during
  module execution* (`vm.nim:11118`). That is a different phase from template
  expansion, and P1 must pick one: move derivation into a capability-free
  compile-time evaluator, emit it as module-initialization TS, or exclude it
  from the first profile. **P1 chose exclusion:** moving it would require a
  capability-free evaluator, caching, dependency-cycle, and provenance
  contract that the bounded browser profile does not otherwise need.

```text
read → sugars → quasiquote → macro expansion → declaration collection
                                             → derive (VM only; web rejects)
                                             → name/impl resolution + typing
                                             ↓
                                    semantic IR  (+ original & expanded trees)
                                    ├── GIR emission (existing)
                                    └── TS emission (new)
```

This refactor has independent value for the LSP (`src/gene/lsp/`) and for
diagnostics — but **not** for the JIT: `jit-pipeline.md` takes GIR → HIR, so
claiming P1 as JIT groundwork would require changing that plan too. Do not
count it.

`src/gene/fmt.nim` is a printing reference, not a semantic-lowering precedent.

### 4.4 The semantic mapping

The surprise is how favorable this is. Gene's two-absence model was designed
independently of JS and lands on JS's two-absence model exactly.

| Gene | TypeScript | Residue |
|---|---|---|
| `nil` | `null` | none |
| `void` | `undefined` | none |
| `($absent? x)` | `x == null` | none |
| `(?? a b)` | `a ?? b` | **none — exact match.** JS `??` fires on `null` *and* `undefined`, which is precisely `absent?` |
| storing `void` deletes a prop | `delete` / omit | small lowering |
| `Str` (immutable) | `string` | none |
| `Bool` | `boolean` | none |
| `List` | `T[]` | none |
| `PropMap` `{^a 1}` | object literal | none |
| `(Map K V)` | `Map<K, V>` | none |
| `#[…]`, `#{…}` | `Object.freeze([…])` | none (shallow freeze *is* `Object.freeze`) |
| `match` | decision tree of `if`/`switch` | none |
| selector literal `/a/b` | closure | none |
| `x/a/b` static path | `x.a.b` | none |
| `(x ~ m a)` static receiver | `x.m(a)` | none |
| `same?` | `===` | none |
| `^is` | `extends` | none |
| `enum` | const singletons + discriminated union | small |
| node `(h ^p v x)` | a `GeneNode` class | helper |
| `(x ~ %m a)` dynamic receiver | `send(x, m, a)` | helper |

**Everything below was mismarked "none"/"small" in an earlier draft.** Each is a
genuine representation decision that owes a written contract before it enters
the profile:

| Gene | The gap |
|---|---|
| `(Map K V)` → `Map<K,V>` | Gene keys hash **structurally**; JS `Map` uses SameValueZero, so `{^a 1}` twice is two distinct keys. Needs a keyed wrapper or a hash-consing layer. |
| `List`, nodes, typed instances | Mutation, `void` normalization (prop deleted vs. list slot → `nil`), and closed-schema revalidation on every `set` |
| `type` → `class` | The class is the easy half; direct `(T …)` vs. `new T` (§7.1.1), required/unknown-field checks, and the in-progress publication marker are runtime |
| `Any` → `unknown` | **TS `unknown` performs no runtime check.** It is a static discipline; Gene's gradual boundary demands emitted validators, including nested generics and protocol conformance |
| `try/catch`, `^errors` | TS cannot express a checked error row; catch types need runtime tests, `$ex` needs a branch-local binding, and cancellation must not be interceptable by an ordinary `catch`. Runtime diagnostics also need the same nominal `RuntimeError` identity across the VM and web representations. |
| `Stream`, `yield` | A generator is not the contract: `peek`, `has_next` vs. `EndOfStream`, terminal producer errors, `yield void` skipping, idempotent `close`, upstream-close, `ensure` unwinding |
| `Task`/`spawn`/`scope` | §4.8 — deferred |

### 4.5 Hazard 1 — the numeric model

§7.4: `Int` is arbitrary-precision with a checked-I64 fast path; `Fixnum` is
±140737488355327 (2⁴⁷−1); **numeric equality is kind-strict, so `(== 1 1.0)` is
false**; and **silent wraparound is forbidden**.

JS has one `number`. Three options:

- **A. `Int` → `number`.** Fast and natural. Breaks all three rules: `(== 1 1.0)`
  becomes true, `($head 1)` can no longer distinguish `Int` from `F64`, and
  arithmetic past 2⁵³ silently loses precision — the exact failure mode §7.4
  forbids.
- **B. `Int` → `bigint`, `F64` → `number`.** Exact. Costs: bigint arithmetic is
  an order of magnitude slower, bigint doesn't survive `JSON.stringify`, mixing
  bigint and number throws `TypeError`, and every DOM/npm boundary needs a
  coercion. Poisons the whole surface.
- **C. `number` with static `Int`/`F64` tracking.** Tempting, and it was this
  doc's first recommendation. **It does not work as stated.** Static annotations
  cannot recover a runtime kind: the moment a number flows through `Any`, a
  union, a generic container, JSON, an unannotated function, or an npm boundary,
  `Int` and `F64` are the same JS value, and kind-strict `==`, `$head`, hashing,
  and `Map` lookup are all wrong. Nor may the range check be stripped in
  production — stripping it *is* the silent precision loss §7.4 forbids.
- **C′. A statically proven numeric profile.** C's idea, honestly scoped:
  `number` representation, but the profile **rejects any operation where kind or
  range can escape proof** — no numbers through `Any`, no numeric map keys
  without a proven kind, no unannotated numeric boundary. Small, sound, and
  possibly too small to be useful.

**Decision implemented: B (`Int` → `bigint`, `F64` → `number`).** The gating
prototype measured the JSON and arithmetic costs and found C′ too restrictive
for even the exact-integer seed fixture. The reproducible results are published
in `transpile-numbers.md`. Two things shaped the experiment:

- **JSON is part of the decision, not a detail.** `JSON.parse` returns
  `number`, erasing integer lexical kind and precision; `JSON.stringify`
  *throws* on `bigint`. Since data exchange is most of what front-end code does,
  B's cost is paid on every request boundary, and C′'s rejections land hardest
  exactly where parsed data flows. Benchmark both against a real payload.
- **C′ cannot be evaluated ahead of the emitter.** B can be hand-benchmarked,
  but C′ *is* an analysis — its viability is the question of how much real code
  survives its rejection rules, which cannot be answered before those rules and
  the analysis in §4.3 exist. Sequence accordingly: B's numbers first, C′'s
  verdict alongside the first emitter slice.

Representation is not the whole numeric model. The operator names are Gene's, not
JavaScript's: `//` is the truncated **remainder** (`%` is the unquote prefix and
`mod` names the module form), and a zero divisor is a catchable Gene error in the
VM for both numeric types — so neither `Infinity` nor a JS `RangeError` is a
faithful lowering. `tests/transpile/fixtures.json` covers `/` and `//` and the
zero divisor over `Int` and `F64`.

### 4.6 Hazard 2 — truthiness, `==`, and short-circuit operators

Gene: only `false`, `nil`, `void` are falsy. **`0`, `""`, and `NaN` are truthy.**
JS disagrees on all three. So `(if c …)` cannot compile to `c ? … : …`.

```js
// (if c a b)  →  no function call, inline
((c) !== false && (c) != null) ? a : b
```

`!= null` catches `null` and `undefined` in one comparison. `!` is the same
test negated.

`&&` and `||` are worse, because JS's own operators disagree on the same three
values *and* they short-circuit, so you cannot evaluate both sides. In statement
position, lower to a temp:

```js
let $t = a; if ($t !== false && $t != null) { $t = b; }
```

In expression position, either hoist the statement form (preferred — the emitter
should be statement-oriented anyway, see §4.10) or fall back to a shim taking a
thunk. Do not emit IIFEs; they defeat readability and inlining.

`==` is structural and meta-blind. Emit `===` when both operands are statically
`Str`/`Bool`/`Sym` and same-kind `Int`/`F64`; otherwise call `eq(a, b)` from the
runtime.

### 4.7 Hazard 3 — protocols and dispatch

`~` is dispatch and only dispatch (§3). Bare = type-direct, qualified `P:m` =
protocol. Both walk the `^is` chain, and impls have visibility scopes.

In the profile, drop overlay/scoped impls and the picture collapses to something
JS does natively:

- **Type-direct messages** → prototype methods. `(x ~ m a)` → `x.m(a)`.
  `^is` → `extends`. `(super ~ m)` → `super.m()`. Free.
- **Protocol impls** → methods installed under a **unique symbol** per protocol
  message, so `P:m` and `Q:m` coexist on one class without collision:
  `x[P$m](a)`. `(impl P for T …)` is `Object.defineProperty` on `T.prototype`
  at module load. This does **not** make `super ~ P:m` free: `super` resolves
  from the *enclosing type's* parent, not the receiver's, and an externally
  installed function has no `[[HomeObject]]`, so JS `super` is unavailable
  inside it. Protocol `super` needs an explicit chain walk from a recorded
  parent — a runtime helper. Message identity and `^is` inheritance of impls
  need the same table. `Self`-typed parameters (§10) need emitted boundary
  checks, not a TS type.
- **`(impl P for List)`, `for Str`, `for Nil`** — cannot patch builtin
  prototypes safely. Route these through a per-protocol lookup table keyed by a
  runtime kind tag; the emitter knows statically which impls target builtins, so
  only those pay.
- **Message values** (`P:msg`, `Self:msg` in value position) → a closure
  `(recv, ...args) => recv[P$m](...args)`. Matches the documented
  `(receiver, ...send args)` callable shape exactly, so `(map xs P:show)` works.
- **`?~`** → `x == null ? x : x.m(a)` with `x` hoisted to a temp. Note this is
  *not* `x?.m(a)`: JS optional chaining yields `undefined` for a `null`
  receiver, but Gene's `?~` yields the receiver unchanged — `nil` stays `nil`.
  Hoist and test.

`MessageError` and `CallKindError` mostly become compile-time errors in the
profile, which is a strict improvement.

### 4.8 Hazard 4 — concurrency

`Task` → `Promise`, `spawn` → an async call, `await` → `await` is idiomatic and
also **not the interesting part**. Calling this a Promise rename would be wrong:

- `scope` must **wait for child cleanup on every exit path**, not just the happy
  one; `Promise.all` does not do this.
- Cancellation is a **non-`Error` control signal** that an ordinary `catch` must
  not intercept. JS rejections are catchable by anything.
- `ensure` always runs. `finally` interacts badly with a rejected-and-swallowed
  cancellation.
- Gene observes cancellation at **suspension points and safepoints**;
  `AbortController` only *transports* a request and cannot interrupt a running
  JS task.

The implemented P4 contract is normative in `docs/web-profile.md`: a scope waits
for children on success, cancels and settles them on failure, `await` checks
cancellation around suspension, cancellation is a non-`Error` control value
that emitted catches rethrow, and `ensure` still runs. The adversarial runner
cancels a child before suspension, attempts to swallow it with `catch Any`, and
checks that `ensure` ran exactly once.

Two consequences of the emission model, both learned the hard way:

- **Asyncness is a call-graph property.** `await` appears at a *call site*
  because the callee is async, so the caller must be async too. It is carried
  across module boundaries with the signature; only top-level functions can carry
  it, so async in a method, constructor, generator, or callback value is
  rejected. Resolve it by recording call edges during the single analysis pass
  and running one reverse-edge worklist over them — iterating analysis until the
  flags converge costs one full pass per link in the longest caller chain.
- **The cancellation test must be a symbol brand.** `GeneCancellation` is emitted
  per module, so `instanceof` is false across a module boundary and the class may
  be absent from a module that only catches — but a structural `kind` string is
  no better, because a nominal Gene type can declare its own `^kind Str` field
  and would become uncatchable. The rethrow guard tests a
  `Symbol.for("gene.cancellation")` brand, which no Gene field name can produce.
  `GeneNode` needs the same treatment for the same reason: every emitted runtime
  class is per-module, so `instanceof` is the wrong tool for any identity that a
  value carries across an import.

Actors are rejected outright: a bounded mailbox with backpressure and sequential
handlers is a scheduler, and shipping a scheduler to the browser is shipping the
VM.

### 4.9 Modules and names

One Gene module → one ES module — **but not automatically.** Gene permits
selected imports in runtime positions, executes top-level forms in order,
detects runtime initialization cycles, exposes namespaces as reflectable values,
and distinguishes `let` from live `var` members. Static ESM imports are hoisted,
and ESM cycles expose partially initialized live bindings under quite different
rules.

The profile therefore requires **unconditional top-level imports over a closed,
acyclic module graph**. `(mod x)` → file, `import` → `import`, and static `ns`
→ frozen object is the implemented contract; executable namespace initializers
and namespace reflection remain outside it.

**The stdlib is the scope risk.** `$str/join` has to *be* somewhere. The
implemented backend emits only the portable helper families a module proves it
uses — string, JSON, HTML, URL, node anatomy, and `gene/stream`
`map`/`filter`/`into` — rather than imposing a package import. Anything touching
fs/net/process is not in the profile and crosses an explicit JS extern. The
portable operations are conformance-tested against the Nim implementations
(§5), and their isolated costs are published under §4.11.

**Name mangling** must be injective and documented. Gene names are `snake_case`
but permit `?`, `!`, and `-`; JS has reserved words and a narrower identifier
set. A scheme like `empty?` → `empty_$q`, `push` → `push_$b`, plus a `$`-prefix
escape for reserved words, is fine — pick one, write it down, and make it
reversible so source maps and stack traces can undo it.

`$x` desugars to `gene/x` (§15.6) and is resolved at compile time, so the `$`
sigil never reaches the output.

### 4.10 Output shape and the artifact contract

**The shipped product is runnable ESM + `.d.ts`**, not `.ts` source — TypeScript
is not executable, and a command that emits only `.ts` pushes an unstated
toolchain dependency onto the user. So the contract must name: the JS target
(`es2022`), the minimum TS version, whether `.ts` is also emitted as an opt-in,
how declarations are packaged, and the source-map chain (`.gene` → `.ts` → `.js`
must compose end to end). Name the command for what it produces — `gene build
--target web` reads better than `gene js`.

Non-negotiable requirements, because violating them means you built a worse
wasm:

- **One Gene module → one readable output module.** A front-end developer must
  be able to open it, read it, and set a breakpoint.
- **Preserve names** wherever legal (after mangling).
- **Statement-oriented emitter.** Gene is expression-oriented; a naive
  expression-to-expression translation produces IIFE soup. Lower to statements
  with temps, and use expressions only where they read naturally.
- **Source maps back to `.gene`**, so devtools shows Gene.
- **No compiled-output-in-a-string tricks**, no `eval`, no `with`, no
  `Function` constructor — those break CSP and are the failure mode this whole
  tier exists to avoid.

### 4.11 The runtime budget

`@gene/rt` is the shim shipped to the browser, and its size is the whole
difference from the 4 MB wasm alternative — so it must be a **reproducible
measured artifact**, not an aspiration:

- Fixed tool and pinned version (e.g. `esbuild --minify`), reporting **both**
  minified and gzipped bytes.
- A **core baseline** (what any non-trivial module pulls in: `GeneNode`, `eq`,
  truthiness, `send`) *plus* **per-feature costs** measured by building a fixture
  that uses exactly one feature — protocols, streams, maps, schema validation,
  cancellation — so each entry in §4.2's *(H)* list has a price next to it.
- A feature whose helper cannot be tree-shaken away when unused is a design bug,
  not a size overrun.

Publish the table; let it gate whether a feature earns its place, the way
`nimble perf` gates allocation.

### 4.12 Embedded web modules — one authored source file

§4.10 describes one delivery mode: `gene build --target web` writes files, and
something else serves them. This is the second, and the product it is designing
for is specific enough to state as a goal, because everything below follows from
it:

> A complete web page is authored in **one Gene source file** — server logic,
> HTML, CSS, and browser behavior. `gene run app.gene` serves it with no second
> source file, no build command, no bundler, and no hand-written JavaScript.

The constraint is on **authoring**, not on the wire. Compiler-generated
dependencies may be served separately from reserved routes (below); what may not
appear is a second file a human has to write, name, or keep in sync. Drawing the
line there rather than at "everything is inline" costs nothing the author can
see and buys browser caching, a smaller per-response payload, and an escape from
the document-relative import problem — while still refusing the hand-written
host shim that would quietly make this a two-file product again.

`examples/todo_app` is the driving case: a complete server-rendered app whose
every interaction is a form POST and a redirect. Adding one Gene-authored click
handler that changes an existing server-rendered todo row is the smallest change
that exercises the whole path.

**A client file compiled by path is not that product.** Naming
`"src/client.gene"` from the server keeps two files, and makes the
server/client relationship a string that no tool can rename, navigate, or check
until the moment it executes. The unit of authoring has to be a form in the
containing module:

```gene
(mod todo_app)

(web_module todo_client
  (fn on_click [event : Any] : Void
    (set event/target/text_content "…")
    void)

  (fn main [root : Any] : Void
    (root ~ add_event_listener "click" on_click)))
```

`web_module` builds a **synthetic `^profile web` source unit** with a stable
identity — `app.gene#todo_client` — whose forms keep their original `SourceLoc`
and macro provenance. It must not print the forms to text and re-read them;
diagnostics, source maps, and the conformance gate all depend on the block's
positions being the ones the author wrote.

**One file is not one lexical environment.** The embedded block sees the web
prelude and its own declarations — nothing else. It cannot close over the
server's database handle, the current request, a capability value, a mutable
global, or any enclosing binding. That restriction is what keeps the block
compilable at all (the profile has no image for those values) and what stops
"locality" from silently becoming "capture." Sharing types or macros across the
boundary is a later, explicit compile-time mechanism, never an accident of
nesting.

#### The author-facing interface

The author sees exactly two things: the embedded declaration, and one operation
that places it in a page.

```gene
(web_module todo_client
  ...)

(fn page [] : Str
  (render
    `(html
       (body
         (main ^id "todo_root" ...)
         %($web/script todo_client ^mount "todo_root")))))
```

The spelling is open; the semantics are not:

- `web_module` binds an **opaque, immutable web-asset value**. Its body is never
  executed by the server VM, and the binding carries no JS text the author can
  reach.
- `$web/script` returns the **complete script node**. Application code never
  handles JavaScript, source maps, hashes, or dependency URLs.
- Referring to the asset is what **installs its routes** on the owning
  `Application` (below), at module-load time rather than at render time. The
  author never receives a route table and cannot forget to mount one.
- The mount id and the entry contract are **validated here**, at the composition
  site. Any placement-specific bootstrap this generates is itself
  content-addressed.
- Specify whether `web_module` is top-level only, whether its binding may be
  exported and imported, and how duplicate asset names are diagnosed.

**CSP metadata needs a data path, and a `Str` has none.** `page` returns a
string, which cannot carry headers. With external scripts as the default (below)
script CSP largely disappears — but the inline `<style>` remains, so either the
composition operation integrates with a response/page value that preserves
required headers, or the interface explicitly hands back the nonce/hash. Saying
"the serve adapter produces CSP metadata" does not get it onto
`Response.headers`; name the mechanism.

#### The seam

A runtime `compile_module(path) -> Str` is the wrong interface. It hands
ordinary request-handling code the compiler and the filesystem, then erases the
result to a string, so every caller has to re-derive when to compile, where
imports resolve, whether to cache, JS versus TS, how to fix the source map, how
to append the entry call, and how to place the bytes in HTML without breaking
the document. One seam owns all of it:

```text
compile_web_asset(source_unit, synthetic_identity) -> WebAsset
```

`WebAsset` keeps the JS, its source map, entry metadata, dependency facts, and
content/CSP hashes private. Two adapters sit on it:

- the **file adapter** writes `.mjs`/`.ts`/`.d.ts`/maps for
  `gene build --target web` — today's behavior, unchanged;
- the **serve adapter** produces the script node, the generated routes to
  publish, and the CSP metadata the response needs.

The containing module compiles its embedded assets **once per module version**,
content-addressed. `gene run --watch` and the module reloader may rebuild in
dev; request handling never invokes the compiler, and a built or AOT artifact
carries the already-emitted bytes. This is what dissolves the "runtime call
versus compile-time macro" question — it was never an authoring choice, only a
storage strategy behind one interface.

#### The entry is an external module by default

Since the goal constrains authoring rather than the wire, the default
composition emits a `src` reference, not a script body:

```html
<script type="module" src="/__gene/todo_client-<hash>.js"></script>
```

Inlining buys **no authoring property** — the author still edits one file and
runs one command either way — while dragging four costs onto P6's critical
path: inline-script nonce/hash plumbing, the HTML script-tokenizer escaping
mode, a base64 source map in every page response, and repeated entry bytes where
a content-addressed URL would have been cached. The external module is still
readable in devtools and still maps back to the embedded Gene block;
`script-src 'self'` admits it with no nonce.

Inline emission stays a **supported adapter** for deployments that measure a
reason to prefer it — the handler appearing in view-source is a real teaching
and debugging property, just not one worth blocking the MVP on. The raw-text
hardening below is still worth fixing in `html/render`, but it stops being a
prerequisite.

**Entries stay self-contained.** Each emitted entry keeps its own tree-shaken
prelude, exactly as modules do today. A shared runtime assembled from the union
of an application's modules would need a **link stage that does not exist**:
`compile_web_asset` cannot know the union at per-module compile time, the
runtime's hash appears in every entry's import specifier, and that changes every
entry's bytes and therefore every entry's hash — so a discovered or reloaded
module can invalidate the whole table. With one content-addressed external
entry the browser already caches the prelude, which was the only thing sharing
would have bought. Revisit when a real application has two entries and
measurement shows the duplication matters; the shape it would take is a named
`link_web_deployment(assets, asset_base) -> WebDeployment` owning the feature
union, dependency order, URL rewriting, and hashes, with `compile_web_asset`
demoted to returning *relocatable* content plus runtime requirements.

#### Generated routes

**The `Application` owns generated assets.** Not the `Server`, and not the
process. This has to be one concrete lifecycle, because it decides where the
deployment table and the asset base live — and the evidence points one way:
`web_module` is compiled while *loading* a module, which happens under an
`Application` (it is the runtime's module-loading context, holding
`moduleCache`/`moduleLoading`), and `$web/script` takes no `Server` argument.
So:

- compilation stores immutable `WebAsset` values on the `Application`;
- `$web/script` derives URLs from that application's configured `asset_base`;
- every `Server` that application starts answers the same application-owned
  deployment table before dispatching to its handler;
- separate `Application` values stay isolated.

This also keeps route installation out of request-time rendering: referring to
an asset marks it reachable during module loading, and rendering a page only
emits an already-finalized script node. Should assets ever need to vary per
`Server`, the author-facing interface would have to take server or request
context in order to pick a base and a table — a substantially wider surface with
no driving case in P6.

Modules are published under that application's asset base, with `/__gene/` only
the default:

```
<base>/todo_client-<hash>.js       a page entry
<base>/todo_client-<hash>.js.map   its map, subject to the policy below
```

- **The base is configurable, not a process root.** A Gene app mounted behind a
  reverse proxy at `/todo/` never sees a request for `/__gene/…`. Hard-coding
  the root breaks that deployment.
- **Generated siblings import each other relatively**, so relocating under a
  configured prefix is natural and needs no absolute root.
- **Old generations must outlive their HTML.** A browser can receive a page
  naming generation *N* immediately before the server publishes *N+1*. Replacing
  the table eagerly is a race; state the retention policy (a bounded number of
  generations, or until process exit) and test two interleaved ones.
- **Response contract:** GET and HEAD, correct `Content-Type`,
  `X-Content-Type-Options: nosniff`, immutable caching justified by the content
  hash, and an explicit answer for whether production exposes `.map` routes.

**Hashing must not be self-referential.** If the JavaScript ends with
`//# sourceMappingURL=todo_client-<hash>.js.map` — as the current file emitter's
appended URL would — then hashing "the emitted bytes" hashes a name derived from
those bytes. Fix the order explicitly:

1. build the client-only map, with no content-addressed JS name in its `file`
   field;
2. hash the map; that fixes the map URL;
3. append the map URL to the JavaScript;
4. hash the final JavaScript; that fixes the script URL.

Or carry the relation in a `SourceMap` response header so it never mutates the
hashed script. Either way, hashes inside import specifiers force
dependency-first linking, and map routes follow the disclosure policy below.

#### The entry and mount contract

The serve adapter owns a **checked** entry, not an appended string. A first cut:

```text
main : <mount value> -> Void
```

The composition site supplies a mount id; compiler-owned bootstrap resolves that
element and passes it in. That keeps the mount convention in one place, lets the
compiler diagnose a missing or mis-typed entry, and means `querySelector` never
has to be exposed merely to start the program.

**The DOM operation this needs does not exist yet.** The generated allowlist
produces only the TypeScript declaration in `web/gene_dom.generated.d.ts`; the
analyzer registers no Gene-facing event registration, so both spellings fail
today:

```
(root ~ add_event_listener "click" on_click)
  ->  web type Any has no message add_event_listener
($dom/add_event_listener root "click" on_click)
  ->  portable web stdlib does not provide dom/add_event_listener
```

So P6 must land a real Gene-facing operation with the checked callback adapter
and receiver semantics the DOM ABI already promises — or the entry contract must
express the event and handler itself, rather than pretending `main` performs a
call it cannot make. This is the item that decides whether progressive
enhancement is reachable at all; it is not a typing detail.

Resolve the mount type at the same time. `Any` is a workable narrow slice, but
its generated validator is literally `return value;` — no structural check — so
it must not be described as validating the mount. A checked `main` needs the
smallest honest host type (`EventTarget`, or an opaque mount type) validating
the operations the entry is allowed to perform.

Still to specify: whether exactly one `main` is required; whether an async
`main` is admitted and how a rejected `Task` surfaces rather than vanishing into
an unhandled rejection; how a missing or duplicate mount is reported; and
whether the contract enhances existing markup, replaces the mount's children, or
leaves that to `main`.

The acceptance example must exercise the chosen answer by **changing an existing
server-rendered todo element**. Rendering an unrelated fresh subtree does not
demonstrate progressive enhancement.

#### Inline delivery, when it is chosen

Two claims about inlining need stating more carefully than "it already works",
since the inline adapter remains supported and the inline `<style>` is on the
default path regardless.

**CSP is not satisfied by the absence of `eval`.** The profile forbidding
`eval`/`with`/`Function` (§4.10) answers `unsafe-eval` only. An ordinary
`script-src` still blocks an inline `<script>` without a matching nonce or hash,
and `style-src` blocks the inline `<style>` the todo app *already* emits. With
external entries the script half largely disappears; the style half does not,
until static styles move to a generated `.css` route too.

**Raw-text escaping is necessary but not sufficient.** `html/render` does emit
`script`/`style` bodies as raw text and rewrites a case-insensitive `</script`
to `<\/script` — verified. But the HTML script-data tokenizer also has escaped
and double-escaped states entered by `<!--` and `<script`, and those pass
through untouched:

```
(script ^type "module" "var payload = \"<!--<script>\";")
  ->  <script type="module">var payload = "<!--<script>";</script>
```

In double-escaped state a following `</script>` returns the tokenizer to escaped
state instead of closing the element, so the renderer's own closing tag can be
consumed and the markup after it swallowed. The fix belongs in the **emitter**,
which controls every literal it writes: an HTML-embeddable mode encodes `<`
inside JS string literals and sanitizes generated comments. Do not regex
finished JavaScript — a blind replacement cannot tell an operator from a string.
The regression is a real HTML-parser test: `<!--`, `<script`, and `</script>`
together in Gene strings, followed by markup that must remain a sibling of the
script.

#### Source maps must not ship the server

§4.10 requires devtools to show `.gene`. That is a disclosure hazard the file
mode never had: `emitSourceMap` currently sets `sourcesContent` to
`readFile(module.sourcePath)`, and once the web module lives *inside*
`app.gene`, that is the whole server file — SQL, routes, comments — reaching
every browser.

The synthetic source unit needs an explicit policy:

- browser `sourcesContent` carries **only** the embedded block (with blank-line
  padding if host line numbers are worth preserving);
- server-only source never enters a browser artifact, by construction rather
  than by redaction after the fact;
- production may omit `sourcesContent`, or the map route entirely, while dev
  publishes the redacted one;
- the synthetic identity stays stable enough to serve as a devtools name and a
  cache key.

Test both mapping accuracy *and* the absence of a distinctive server-only string
in everything the browser can fetch.

#### Imports resolve to generated routes, never to authored files

A relative ESM `import` inside an *inline* module resolves against the document
URL, which is why an inlined multi-module client cannot work as-is. External
entries do not have that problem: a generated module importing a generated
sibling uses an ordinary relative specifier that resolves against the asset
base, wherever that base is mounted.

What stays rejected inside `web_module` is narrower but firmer:

- **`js/fn ^from` pointing at an author-written file.** Generated routes serve
  compiler output only. A hand-written host shim is a second authored file
  wearing a URL, and admitting it is how the one-file property dies quietly.
- **Bare specifiers**, which have no meaning the server can guarantee.
  Compile-time macro imports, which disappear before emission, are a different
  thing and remain admissible.

Browser facilities therefore arrive as compiler-owned typed intrinsics — the
shape the DOM support already uses. If `fetch` is admitted later it gets an
explicit typed contract and a measured helper cost against §4.11's table.

The **file** mode (§4.10) is unaffected: there the module graph really is files
on disk, and a bundler is a reasonable thing to point at them.

#### Acceptance

P6 is complete when `examples/todo_app/src/main.gene` is still the **only
authored source file**, and contains the server routes and store, the CSS data
and its `<style>`, the server-rendered HTML, an embedded `web_module` with a
checked `main`, a visible `$web/script`-style composition operation, and
compiler-owned mounting onto existing server markup.

`gene run examples/todo_app/src/main.gene` must perform **no web file writes and
no per-request compilation**. The tests that matter exercise the interfaces and
the lifecycle, not the internals:

- the entry and its dependencies load from the **configured asset base under a
  subpath deployment**, not just from the root default;
- two `Application` values cannot read each other's generated routes, and two
  `Server` values started by the *same* application both serve its table;
- an HTML response from generation *N* can still fetch its *N* URLs while *N+1*
  is being published;
- the real Gene DOM registration operation **changes an existing SSR row**;
- script and map hashes are reproducible and non-self-referential, and maps
  expose only the embedded block;
- the page loads under the documented CSP, covering **both** `script-src` and
  `style-src` for whichever delivery modes it selects;
- async entry errors stay visible rather than becoming unhandled rejections;
- and, if the inline adapter is exercised, hostile raw-text strings cannot
  consume following markup.

A compiler test proves that server-value capture, a bare or authored-file
import, a bad entry signature, and a missing mount contract each fail with a
location *inside the embedded block*.

---

## 5. The drift problem, and the gate that manages it

**This is the single biggest long-term cost, and it must be designed for on day
one, not retrofitted.** A second backend is a second implementation of Gene's
semantics. Every one of §4.5–§4.8 is a place where the two can silently
disagree, and silent disagreement between "it works on the server" and "it works
in the browser" is the worst bug class a language can ship.

The repo has the right instrument in spirit — `AGENTS.md`: *"`nimble spec` is
the executable language-surface contract"* — but **not in a usable form.**
`tests/spec_runner.nim` is Nim code: `check_eval(src, expected)` templates with
embedded source, `.print()` string comparisons, and exception assertions. Two
runners cannot consume that.

So the harness has a prerequisite of its own:

1. **Extract shared fixtures + a manifest** — **incrementally.** Each case
   records source, expected value, expected error, expected stdout, and profile
   eligibility, as data readable by both runners. Converting the whole Nim suite
   is *not* a precondition for P2: start with every form the tiny profile admits
   plus its explicit rejection cases, and migrate more as features enter. Keep a
   **coverage ledger** so "incremental" cannot decay into silent omission. The
   full eligible corpus stays the destination.
2. **Define a canonical result envelope**, so typed errors, `nil` vs. `void`,
   symbols, maps, nodes, identity, async cleanup, and diagnostics compare
   without depending on two printers happening to agree.
3. **Pin the Node and TypeScript toolchain** in CI; an unpinned toolchain makes
   a diff meaningless.
4. **An exclusion means "the TS compiler rejects this case, with this reason."**
   It is never permission for an *accepted* program to produce a different
   result. There is no third state and no silent skipping.
5. New language features state their profile status when they land, the same way
   `docs/design.md` must be updated.
6. A `nimble transpile_spec` task, wired into `nimble verify`.
7. **A performance gate, not just a size gate.** Semantic agreement and bundle
   bytes are necessary and insufficient in this repository. Record, for fixed
   fixtures: compile time, Node runtime, allocations where measurable, and
   bundle size — and treat regressions the way `AGENTS.md` treats `nimble perf`
   output, with before/after numbers and a stated reason. The B-vs-C′ decision
   (§4.5) is partly a performance question and needs these numbers to settle.

Step 1 alone has independent value: a data-driven spec corpus is a better
contract than Nim test code regardless of whether Tier 1 ever ships.

Without this gate, do not start Tier 1. With it, drift is a build failure
instead of a support ticket.

---

## 6. Interop — and why it must be proven early

Direct DOM and npm access is the **main reason to prefer this backend over
wasm**, so deferring all of it behind a growing language subset tests the wrong
hypothesis first. Interop moves up: an **ABI spike immediately after the minimal
pure emitter** — one imported JS function, one exported Gene function with a
checked wrapper, one callback or DOM event — and the JS ABI gets defined there,
before the subset expands.

**A declaration is not an ABI.** Declaring `foo(x: string): number` says nothing
about JS object identity, method receivers and `this`, callbacks, promises,
exceptions crossing the boundary, overloads, or optional fields — nor about how
Gene's `Int`, `nil`/`void`, lists, maps, and typed instances convert in each
direction. That table is the deliverable. §16's FFI declaration vocabulary is
the right shape to reuse — a `js` ABI alongside the C one — but only the
vocabulary; the semantics are new.

**Calling Gene from JS is not free either.** An earlier draft said it was, which
contradicts §7.4: **`.d.ts` is erased.** A JS caller can pass anything to an
exported typed Gene function, so the export needs a validating wrapper and
possibly a representation adapter — the same gradual boundary Gene enforces
everywhere else, just facing outward.

**The DOM**: declare, don't wrap — but treat `lib.dom.d.ts` as input to a
**supported subset** of a binding generator, not as a promise to translate the
whole TypeScript type system. Conditional types, mapped types, and overload sets
have no Gene image; the generator must reject what it cannot model and say so.

**Bundlers**: emit plain ESM and let esbuild/vite/rollup do their jobs. Do not
build a bundler.

---

## 7. What this buys you that TypeScript alone does not

If the answer is only "you get to use parens," it is not worth the conformance
burden. It is not only that.

### 7.1 Macros run at build time, at zero runtime cost

`macro` (§11.2) is a compile-time template expander, so in a transpiled build it
expands **before emission** and costs the browser nothing. That is real
compile-time metaprogramming — a JSON codec, a form validator, a router table, a
typed API client from a schema — landing as plain readable TS. TypeScript has
nothing equivalent: decorators are runtime, and codegen tools are a separate
build step in a separate language.

`derive` *should* belong here too, and §11.4 describes it that way, but today it
runs during module execution (§4.3). Whether this benefit extends to `derive` is
exactly the P1 decision.

### 7.2 Markup as data, so the template *is* the AST

`` `(div ^class "card" (span %title)) `` is already node data, and the compiler
already sees it as a tree. That means templates compile **statically** to VDOM
constructor calls with no runtime template parsing — JSX's benefit without JSX's
separate grammar, because homoiconicity gave it to you for free. And the same
tree is inspectable, transformable, and testable as data before it renders,
which JSX is not.

### 7.3 One language across the boundary

Types, validation, and domain logic written once. §7's nominal types, `enum`s,
and protocols give a shared vocabulary that server and client both compile
from — with the server keeping full fidelity on the VM and the client getting
the profile subset. The type declarations themselves are 100% in the profile.

### 7.4 Gradual types map to TS almost exactly

| Gene | TS |
|---|---|
| `Int`, `F64` | `bigint`, `number` |
| `Str` | `string` |
| `Bool` | `boolean` |
| `T?`, `(? T)` | `T \| null` |
| `(\| A B)` | `A \| B` |
| `(List T)` | `T[]` |
| `(Map K V)` | `Map<K, V>` |
| `Never` | `never` |
| `Any` | **`unknown`**, not `any` |
| `type` | `class` |
| `protocol` | `interface` |
| `enum` | discriminated union |
| generics `[T]` | `<T>` |

`Any` → `unknown` is deliberate: TS forces a narrowing before an `unknown` can
be used, which *rhymes* with §7.2's rule that *"`Any` can flow into typed code
only through a runtime typed-boundary check."* But the resemblance is static
only — **TS erases, so `unknown` performs no check at runtime.** Gene's boundary
must still emit real validators, including for nested generics and protocol
conformance. `unknown` buys a good editing experience, not the semantics.

---

## 8. Staging

Each phase ships something usable and is independently abandonable.

**Implementation note (2026-07-30): P0, P0.5, P1, P2, P2.5, P3, P4, P5, and P6
below are complete.** The descriptions remain as the historical delivery gates.

**P0 — `gene/css` + a real `html/render`.** Stdlib only, no compiler, no DOM.
Deliverable: `todo_app`'s raw CSS string replaced by `(css …)` with scoped
class generation, and the two examples' hand-rolled renderers replaced by one
`html/render` with a written escaping/attribute contract.
*Independently valuable even if Tier 1 never happens.*

**P0.5 — B's numbers (§4.5) and the seed fixture corpus (§5).** Benchmark
`bigint` against a real JSON payload; convert only the fixtures the tiny profile
needs. Neither emits a line of TS.

**P1 — narrow factoring.** Extract *only* the genuinely shared front-end pieces
— macro expansion, source and expansion provenance — and decide `derive`'s
phase (§4.3). Build the semantic IR **for eligible forms only**; leave GIR
emission untouched. Write the profile's analysis rules (§4.3) as a named
document before implementing them. Deliverable: no VM behavior change, no
`nimble perf` regression, and an IR that rejects everything outside the tiny
profile.

**P2 — first vertical slice, deliberately tiny.** Fully annotated **synchronous
pure functions** over `Bool`, `Str`, `List`, and one numeric representation.
Unconditional top-level imports over a closed module graph. **No** `Any`,
reflection, protocols, typed nodes, maps, streams, or errors. Source maps and
the shared-fixture harness land here, with the first emitted line. Publish the
§4.11 size table and the §5 performance baseline. C′'s verdict lands here too —
it cannot be judged earlier (§4.5).

**P2.5 — the interop ABI spike (§6).** One imported JS function, one exported
Gene function with a checked wrapper, one callback or DOM event. **Before** the
subset grows, because interop is the product's justification and a declaration
is not an ABI. Deliverable: the conversion table for `Int`, `nil`/`void`, lists,
maps, typed values, callbacks, promises, and exceptions in both directions.

**P3+ — one feature at a time,** each admitted only when its representation
contract (§4.4) and conformance cases exist: maps and structural equality;
typed errors; types/enums/protocols and `.d.ts`; `Any` boundary validators;
streams. Order by what a real component and the measured cost demand, not by
this list.

**P4 — async.** Only after §4.8's operational contract is written and its
adversarial tests exist.

**P5 — DOM breadth.** A generated binding over a *supported subset* of
`lib.dom.d.ts`, plus the node→DOM edge. Deliverable: an interactive component
with Gene event handlers.

**P6 — embedded web modules (§4.12).** The `web_module` form and its synthetic
source unit, the `$web/script` composition operation, the `compile_web_asset`
seam with its file and serve adapters, the `Application`-owned generated-route
table and its `gene/net/http` integration, a **Gene-facing DOM event
registration**
(which does not exist today), the checked entry/mount contract, non-circular
content hashing, and a redacted client-only source map. Deliverable:
`gene run examples/todo_app/src/main.gene` serves a page whose click handler was
authored in the same file and changes an existing server-rendered row — one
command, one authored source file, no build step, no bundler. Entries are
external and content-addressed by default; inline delivery, the script-tokenizer
escaping mode, and script CSP plumbing are a **later adapter**, not MVP scope.
This is the first phase whose deliverable is an *application* rather than a
compiler capability, which is why it is the one that finds what the fixtures
cannot: the missing DOM operation, the scoping rule, the disclosure hazard in
`sourcesContent`, and the hash-ordering circularity are all things no
single-feature fixture would have surfaced.

**P6 is implemented.** `gene run examples/todo_app/src/main.gene` serves the
one-file app; `tests/transpile_embed_runner.nim` is the lifecycle suite. What
building it settled, beyond the plan:

- **The entry parameter is `EventTarget`** (open question 8), a new profile
  type whose validator structurally checks `addEventListener` rather than
  being `return value;`. `Any` was rejected precisely because describing it as
  "validating the mount" would have been false.
- **`$dom/add_event_listener` / `remove_event_listener`** are compiler-owned
  typed intrinsics: the target is checked, the handler is a checked
  `Callback [Any] Void`, and the listener is passed through unwrapped so
  removal can still find it by identity.
- **Progressive enhancement needed no allowlist growth** (open question 9).
  Reading and traversing existing markup went through the profile's existing
  `Any` path accessor, which already camel-maps `parent_element` and
  `class_name`. Delegation from the mount root covered the todo case exactly
  as predicted.
- **Redaction is positional, not textual.** The block's own characters are
  kept and everything before them is replaced by spaces and newlines, so line
  *and* column stay exact with no padding fixups, and no host byte can reach a
  browser by construction.
- **A gap the phase exposed:** web diagnostics about a bare symbol, string, or
  number had no position at all, because only containers carry `SourceLoc`.
  The analyzer now falls back to the nearest enclosing form it descended
  through, which is what makes "server-value capture fails *inside* the block"
  a checkable claim rather than a hopeful one.
- **`$web/stylesheet`** answers the CSP question §4.12 left open by naming a
  mechanism: static styles become a generated `.css` route, so the page loads
  under a plain `script-src 'self'; style-src 'self'` and nothing has to travel
  on a `Str` return type.

**Never:** fexprs, `eval`, actors, channels, FFI, capabilities. Those are what
the wasm VM is for, and saying so plainly is what keeps the profile honest.

---

## 9. Alternatives considered

- **GIR → JS.** Rejected: §4.3. Unreadable output defeats the purpose.
- **Ship a Gene interpreter written in TS.** Rejected: a third implementation,
  worse fidelity than wasm and worse performance than transpiled output. Strictly
  dominated by both existing options.
- **Full-fidelity Gene → JS (no profile).** Rejected: requires shipping the
  evaluator for fexprs/`eval`, a scheduler for actors, and a numeric tower — i.e.
  the VM, in JS, slower than the wasm one that already exists.
- **Emit JS instead of TS.** Rejected: §1. Throws away information the compiler
  already has and gives the rest of the team nothing.
- **wasm Target C (Gene → wasm, `docs/wasm.md`).** Different problem. Produces
  opaque modules with the same devtools and interop deficits as Target A, and
  overlaps the JIT. Not a substitute for readable TS.

---

## 10. Open questions

1. ~~**Where does the `web` profile check live?**~~ **Settled:** a distinct
   whole-module analysis over the shared expanded tree, before emission.
   `jit-pipeline.md` puts JIT
   eligibility at function-definition time. This one is whole-module and must
   run before emission — probably a distinct pass over the expanded tree, with
   diagnostics that name the rejected form *and* its rejection reason from §4.2.
2. ~~Prop or meta for the profile marker?~~ **Settled: a prop, `^profile web`.**
   The compiler *enforces* it, and §1.4 is explicit — "if the core language
   enforces or consumes it, it is a prop." Every exported function has fully
   annotated positional parameters and return type, and the compiler emits
   checked wrappers at the JS boundary.
3. ~~**The numeric representation (§4.5).**~~ **Settled: B.** `Int` is
   `bigint`; the fixed benchmark and JSON cost are published in
   `transpile-numbers.md`.
4. ~~**How much of `@gene/std` is actually needed** before a real component is
   writable?~~ **Settled for P5:** the emitted, tree-shaken portable subset is
   string/URL/HTML/JSON helpers, node anatomy, size, and stream
   conversion/combinators. `examples/web_component.gene` exercises the actual
   component boundary; host-authority APIs remain explicit JS externs.
5. **Reactivity.** Do not invent a framework — but node-data-as-VDOM (§7.2)
   strongly suggests a small signal/diff layer. Defer past P5, decide with a
   real app in hand. §4.12's todo app is that app; decide after it works, not
   before.
6. ~~**Is P1's factoring acceptable to the VM's performance envelope?**~~
   **Settled by the repository performance gates:** GIR is unchanged and the
   shared expansion artifact is invoked by the web path; `nimble perf` remains
   the VM guard.
7. ~~**Which embedding mode becomes the default (§4.12)?**~~ **Dissolved, not
   answered.** Runtime-call versus compile-time macro was never an authoring
   choice. One seam — `compile_web_asset` — with a file adapter and an inline
   adapter; `gene run` and a built artifact differ only in *when* the bytes are
   produced and *where* they are stored. Application authors see neither.
8. **What is the embedded entry's parameter type (§4.12)?** The profile has no
   DOM element type, so `main` takes `Any` — and every mount then pays a
   boundary validator — or the DOM subset grows a nominal type. Bootstrap itself
   no longer needs `querySelector`, and one delegated `add_event_listener` on
   the mount root already reaches server-rendered rows, so this is now a typing
   question rather than a capability one.
9. **How much DOM does progressive enhancement actually need?** Delegation
   covers the todo case. The moment an app wants to read or traverse existing
   markup, the allowlist has to grow under §6's rules — and that is the point
   where "enhance the server's HTML" stops being cheap. Decide with the second
   app, not this one.
10. **When, if ever, does a shared runtime replace self-contained entries
    (§4.12)?** Deferred out of P6: one content-addressed external entry is
    already browser-cached, so sharing buys nothing until an application has two
    of them, and it would require a link stage that per-module compilation
    cannot provide. Revisit with measurements from a two-entry app; the answer
    decides whether `compile_web_asset` keeps returning final JS or is demoted
    to relocatable content plus runtime requirements.

---

## 11. Summary

- CSS and markup are **data with printers**, not compiler targets. Ship that
  first (`gene/css` + a real `html/render`); it is cheap and it is most of what
  "write CSS in Gene" means. The DOM edge is not part of it.
- For behavior, a **restricted `web` profile compiled to TypeScript** is the
  right shape — not full-fidelity Gene→JS, which is what the already-implemented
  wasm VM does better.
- The profile line is **bounded, tree-shakeable runtime support**, measured and
  published per feature. Fexprs, `eval`, actors, and FFI are out permanently.
- `nil`/`void` → `null`/`undefined` and `??` → `??` really are exact. The rest
  of the "easy" mapping was overstated: maps, mutation, schema validation,
  `Any`, typed errors, streams, and protocol `super` each need a written
  representation contract.
- **The four original gates are settled.** Numeric option B uses `bigint`;
  `derive` stays VM-only; `docs/web-profile.md` defines the web analysis and
  runtime-check rules; and the data-driven manifest is executed by both
  backends.
- **Tier 1 remains a separate bounded backend, not a compiler migration.** The
  web IR covers eligible forms only and GIR stays where it is. Interop was
  proven at P2.5 and the subset subsequently grew through structured async and
  the DOM component slice.
- The dominant long-term cost is **semantic drift**; the mitigation is a
  conformance harness — semantic, size, *and* performance — wired into
  `nimble verify`, landing with the first emitted line. Without it, do not start.

---

## 12. Third review (Codex, 2026-07-28)

**Verdict: approved as an implementation proposal.** I found no remaining
architectural blocker worth adding to the document.

The important boundaries are now in the plan rather than left implicit:

- P0 is independently useful and does not pretend a DOM exists in the native
  runtime.
- Tier 1 starts with a web-only IR and leaves the working GIR pipeline alone.
- Static analysis is named as new compiler work instead of being hidden behind
  “fully annotated.”
- Numeric representation is an explicit measured decision, including JSON and
  boundary costs.
- The conformance corpus grows with the admitted profile and has semantic,
  size, and performance gates.
- JS interop is proven immediately after the minimal emitter, before effort is
  spent broadening a backend whose main advantage is interop.

The unresolved items — numeric B versus C′, `derive` phase, exact analysis
rules, and module-cycle behavior — are legitimate design decisions with named
experiments or rejection gates. They no longer undermine the architecture.

Proceed with P0 and the P0.5 measurements. For Tier 1, treat P2.5 as the
go/no-go checkpoint: the project should not expand the language subset until
the minimal compiler demonstrates a sound, usable JS boundary.
