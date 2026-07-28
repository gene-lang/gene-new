# Gene → TypeScript: a front-end compilation target

Status: **proposal, not implemented.** Nothing described here exists in the
tree today. Related: `docs/wasm.md` (Target A is implemented and is the
competing answer), `docs/proposals/jit-pipeline.md` (the precedent for
"a decidable subset gets its own backend"), `docs/design.md` §7/§10/§11/§15.

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
`examples/web_demo.gene` and `examples/todo_app.gene` already model T2 —
"HTML is ordinary Gene node data until render time … one `node -> text` edge" —
but each hand-rolls that edge (§3.2), and both fake T1 with a raw `"""…"""`
string. That string is the gap you feel; the missing renderer is the one behind
it.

---

## 1. Recommendation

**Three tiers, shipped in order, each independently useful.**

- **Tier 0 (`gene/css`, `gene/html`)** — CSS and markup as node data with real
  printers. Stdlib only, no compiler backend, no DOM. This removes the raw CSS
  string from `todo_app.gene`, gives component-scoped styles, and replaces two
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
| Semantic fidelity | **Total.** `fn!`, `eval`, actors, FFI, macros, everything | A subset; drift is a permanent risk |
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

### 3.2 Markup is data, but the renderer is not written yet

`(html (body (div ^class "card" …)))` is already legal node data. The renderer
is **not** already solved: `gene/html` supplies only `escape` and `attr_escape`
(`stdlib.nim:8149`), and `todo_app.gene` / `web_demo.gene` each hand-roll their
own node→text edge. A real `html/render` is genuine P0 work — boolean and void
attributes, raw-text elements (`<script>`, `<style>`), per-context escaping,
arbitrary `data-*`/`aria-*`, and deterministic attribute order.

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

- `fn`, `let`/`var`/`set`, `set!` on paths
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
- `Task`, `spawn`, `await`, `scope` — deferred; see §4.8, this is a semantics
  project, not a rename
- `macro`, quasiquote/`%` — expanded at compile time, native lowering. **`derive`
  is not in this bucket today** (§4.3).
- `mod`, `ns`, `import` → ES modules under §4.9's restrictions

**Rejected, with a diagnostic naming the reason:**

| Rejected | Why |
|---|---|
| `fn!` / fexprs / `caller_env` | Needs a live evaluator plus retained argument syntax at every dynamic call site (§3). That is the wasm VM. |
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
to consume it would force the IR to represent *all* of Gene — `fn!`, `eval`,
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
  from the first profile. Whichever wins also has to define caching, dependency
  cycles, and provenance for generated declarations.

```text
read → sugars → quasiquote → macro expansion → declaration collection
                                             → derive (phase TBD, see above)
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
| `List`, nodes, typed instances | Mutation, `void` normalization (prop deleted vs. list slot → `nil`), and closed-schema revalidation on every `set!` |
| `type` → `class` | The class is the easy half; direct `(T …)` vs. `new T` (§7.1.1), required/unknown-field checks, and the in-progress publication marker are runtime |
| `Any` → `unknown` | **TS `unknown` performs no runtime check.** It is a static discipline; Gene's gradual boundary demands emitted validators, including nested generics and protocol conformance |
| `try/catch`, `^errors` | TS cannot express a checked error row; typed catch patterns need runtime tests, and cancellation must not be interceptable by an ordinary `catch` |
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

**No recommendation yet — this is the gating prototype**, because the answer
determines the representation of every value that touches a number. Two things
shape how it must be run:

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
`Str`/`Bool`/`Sym` (numbers pending §4.5); otherwise call `eq(a, b)` from the
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

So §4.2 lists this as deferred, not mapped. P4 owes an operational contract plus
adversarial conformance tests (cancel during `ensure`, cancel a child mid-flight,
`catch` attempting to swallow a cancel) before any of it is called approximate.

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

The profile therefore requires **unconditional top-level imports over a closed
module graph**, and must define initialization order and cycle behavior
explicitly. `(mod x)` → file, `import` → `import`, `ns` → frozen object is the
shape, not yet the contract.

**The stdlib is the scope risk.** `$str/join` has to *be* somewhere. The pure,
portable parts — `str`, `json`, `html`, `url`, `parse`, node anatomy,
`gene/stream` combinators, `map`/`filter`/`into` — become a hand-written TS
package (`@gene/std`) that the emitter imports from, tree-shakeable. Anything
touching fs/net/process is simply not in the profile. Scope this honestly: it is
a real, bounded, boring chunk of work, and it must be conformance-tested against
the Nim implementations (§5).

**Name mangling** must be injective and documented. Gene names are `snake_case`
but permit `?`, `!`, and `-`; JS has reserved words and a narrower identifier
set. A scheme like `empty?` → `empty_$q`, `push!` → `push_$b`, plus a `$`-prefix
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
| `Int`, `F64` | pending §4.5 |
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

**P0 — `gene/css` + a real `html/render`.** Stdlib only, no compiler, no DOM.
Deliverable: `todo_app.gene`'s raw CSS string replaced by `(css …)` with scoped
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

**Never:** `fn!`, `eval`, actors, channels, FFI, capabilities. Those are what
the wasm VM is for, and saying so plainly is what keeps the profile honest.

---

## 9. Alternatives considered

- **GIR → JS.** Rejected: §4.3. Unreadable output defeats the purpose.
- **Ship a Gene interpreter written in TS.** Rejected: a third implementation,
  worse fidelity than wasm and worse performance than transpiled output. Strictly
  dominated by both existing options.
- **Full-fidelity Gene → JS (no profile).** Rejected: requires shipping the
  evaluator for `fn!`/`eval`, a scheduler for actors, and a numeric tower — i.e.
  the VM, in JS, slower than the wasm one that already exists.
- **Emit JS instead of TS.** Rejected: §1. Throws away information the compiler
  already has and gives the rest of the team nothing.
- **wasm Target C (Gene → wasm, `docs/wasm.md`).** Different problem. Produces
  opaque modules with the same devtools and interop deficits as Target A, and
  overlaps the JIT. Not a substitute for readable TS.

---

## 10. Open questions

1. **Where does the `web` profile check live?** `jit-pipeline.md` puts JIT
   eligibility at function-definition time. This one is whole-module and must
   run before emission — probably a distinct pass over the expanded tree, with
   diagnostics that name the rejected form *and* its rejection reason from §4.2.
2. ~~Prop or meta for the profile marker?~~ **Settled: a prop, `^profile web`.**
   The compiler *enforces* it, and §1.4 is explicit — "if the core language
   enforces or consumes it, it is a prop." Still open: whether every exported
   function in such a module must be fully annotated. §4.5 and §4.4 both assume
   a typed-boundary rule that §4.2 does not yet state; write it down.
3. **The numeric representation (§4.5).** The gating prototype. B or C′, decided
   by measurement, before anything else in §4 is designed.
4. **How much of `@gene/std` is actually needed** before a real component is
   writable? Measure against a rewritten `todo_app` front end, not a guess.
5. **Reactivity.** Do not invent a framework — but node-data-as-VDOM (§7.2)
   strongly suggests a small signal/diff layer. Defer past P5, decide with a
   real app in hand.
6. **Is P1's factoring acceptable to the VM's performance envelope?** It touches
   `compiler.nim`'s hot path. Benchmark under `nimble perf` with before/after
   numbers, per `AGENTS.md`.

---

## 11. Summary

- CSS and markup are **data with printers**, not compiler targets. Ship that
  first (`gene/css` + a real `html/render`); it is cheap and it is most of what
  "write CSS in Gene" means. The DOM edge is not part of it.
- For behavior, a **restricted `web` profile compiled to TypeScript** is the
  right shape — not full-fidelity Gene→JS, which is what the already-implemented
  wasm VM does better.
- The profile line is **bounded, tree-shakeable runtime support**, measured and
  published per feature. `fn!`, `eval`, actors, and FFI are out permanently.
- `nil`/`void` → `null`/`undefined` and `??` → `??` really are exact. The rest
  of the "easy" mapping was overstated: maps, mutation, schema validation,
  `Any`, typed errors, streams, and protocol `super` each need a written
  representation contract.
- **Four things gate starting.** The numeric representation (§4.5) — unresolved,
  and it determines every value that touches a number. `derive`'s phase (§4.3) —
  it runs at module execution today, not compile time. The profile's **analysis
  rules** (§4.3) — there is no static checker in `compiler.nim` today, so
  "checked types" is a phase to be designed, not a property to be read off. And
  a data-driven fixture corpus (§5), because `spec_runner.nim` is Nim code two
  runners cannot share.
- **Tier 1 begins as a narrow end-to-end spike, not a compiler migration.** The
  web IR covers eligible forms only and GIR stays where it is; interop is proven
  at P2.5, right after the first emitted function, because direct DOM/npm access
  is the whole reason to prefer this over wasm.
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
