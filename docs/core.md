# Gene — Core Type & Protocol Model

**Status:** consolidated design, ready for implementation planning.
**Scope:** protocols, messages, dispatch, protocol-local derivation, the two
inheritance axes (type `^is` and protocol `^inherit`), type-direct messages,
message resolution / `~` semantics, and dispatch on scalar/singleton
receivers (including `Nil`). Extends `docs/design.md §10`. Formerly
`docs/protocol-design.md`, which replaced `docs/proposals/inheritance.md`.

The base protocol/message/derive model (no inheritance) is implemented and
stable — see `docs/design.md §10` for the unchanged core. This document adds
protocol inheritance, type-direct messages, and receiver-directed message
resolution as one design, so they are reviewed and built together instead of
as follow-on patches.

---

## 1. Base model (recap)

```gene
(protocol ToHtml
  (message to_html [self : Self] : Node))

(impl ToHtml MenuItem
  (message to_html [self] : Node
    `(tr (td %self/name))))
```

- Message dispatch is on the receiver's runtime type, not literal node head
  identity — this already holds for scalars (`docs/design.md §1.1`) and
  extends unchanged to inheritance and `Nil` below.
- Messages are ordinary callable values (`(item ~ to_html)`).
- `^impl [P]` on a type requires a visible `impl P T` covering `P`'s full
  message set.
- `^derive [P]` triggers `P`'s protocol-local `derive` form, generating an
  `impl` in a compiler-owned overlay.
- Coherence is based on visible implementations, not ownership: zero visible
  impls for a `(protocol, type)` pair is a missing-implementation error;
  multiple applicable visible impls is an ambiguity error; import order never
  resolves ambiguity.

Everything below assumes this base is in place.

---

## 2. Type inheritance and protocol impls

Gene has two independent inheritance axes, and both are needed:

```text
^is        single-parent type inheritance   — inherits data shape + concrete behavior
^inherit   multi-parent protocol inheritance — composes contracts, independent of type shape
```

| | `type Dog ^is Animal` | `protocol Ord ^inherit [Comparable]` |
|---|---|---|
| composes | props/body, type-direct messages, protocol impls | behavioral contracts |
| parents | exactly one (`docs/design.md §7.3`) | any number, left-to-right |
| requires shared data shape? | yes, by construction | no — sharing behavior across *unrelated* data shapes is the reason protocols exist (`docs/design.md §0`) |

### 2.1 Implemented rule: protocol impl lookup walks the `^is` chain

```gene
(type Animal ^props {^name Str})
(impl Comparable Animal (message compare [self other] ...))

(type Dog ^is Animal ^props {^breed Str})

(d ~ compare)  # resolves through impl Comparable Animal — no impl Comparable Dog needed
```

This was already implemented and tested before protocol inheritance existed
(`resolveProtocolMessage`/`hasVisibleImpl` in `src/gene/vm.nim` already walk
`T`'s `^is` chain via `isSubtypeOf`) — it closes the gap this section
originally set out to close, and turned out not to be a gap.

**Correction from an earlier draft of this document: overlap is an ambiguity
error, not most-specific-wins.** If both `impl Comparable Animal` and `impl
Comparable Dog` are visible, dispatching `compare` on a `Dog` raises an
ambiguity error rather than silently preferring `Dog`'s impl (see
`tests/test_protocols.nim`, "overlapping parent and child impls are ambiguous
at use"). An earlier draft of this section recommended most-specific-wins by
analogy to ordinary single-inheritance field shadowing; the shipped behavior
instead extends this codebase's existing rule that ambiguity is always a
compile/use-site error, never silently resolved (`docs/design.md §10`), and
that rule turned out to already cover the `^is` axis. Protocol inheritance
(§3) reuses the exact same match-and-count logic, so overlapping impls of a
protocol and one of its `^inherit` ancestors are ambiguous at use for the
same reason (§3.5).

### 2.2 Why `^inherit` still needs to exist

`^is` is single-inheritance and ties composition to data shape. Protocols
exist precisely so unrelated types can share a contract:

```gene
(protocol Container (message put [self : Self, x : item] : Self) (message get [self : Self] : item))
(protocol SortedContainer ^inherit [Container] (message min [self : Self] : item) (message max [self : Self] : item))

(type SortedArray ...)     # array-backed
(type SortedSkipList ...)  # node-backed — no shared ^is ancestor with SortedArray
```

`(fn f [x : Container] ...)` must accept both, with zero shared type
hierarchy. `SortedContainer <: Container` is a fact about the *contract*;
`^is` cannot express it without forcing incidental data-shape sharing between
otherwise-unrelated types.

The two axes compose without conflict: a receiver's full behavior set is
`{type-direct messages, walking ^is} ∪ {protocol impls, walking ^is per §2.1,
closure-flattened via ^inherit per §3}`.

---

## 3. Protocol inheritance

### 3.1 Syntax

```gene
(protocol B ^inherit [A]
  (message do_b [self : Self] : Any))

(protocol C ^inherit [A B]
  (message do_c [self : Self] : Any))
```

`^inherit` is a prop key inside `protocol`, taking a list of parent protocol
values. Order is left-to-right and matters only for the `^derive` option
placement in §6, not for message resolution.

### 3.2 Transitive closure and message ownership

A message is identified by its **defining protocol**, not by name alone. When
`C ^inherit [A B]`, `C`'s flattened message set is the union of `A`, `B`, and
`C`'s own messages. In a diamond (`C ^inherit [A B]`, `B ^inherit [A]`), `A`'s
messages appear once — reachability through two paths does not duplicate them.

`impl C T` must provide (directly, or via §3.6/§5) every message in `C`'s
transitive closure. Missing one is a compile error: `"impl C T is missing
message A/do_a"`.

### 3.3 Name conflicts across independent parents

```gene
(protocol X (message clash [self : Self] : Any))
(protocol Y (message clash [self : Self] : Any))
(protocol Z ^inherit [X Y] (message do_z [self : Self] : Any))  # ERROR
```

**Implemented as a compile-time error at `Z`'s definition, not a use-site
ambiguity error.** An earlier draft of this section recommended letting `Z`
define successfully and only rejecting an unqualified `(clash t)` at the use
site. That was not implementable without a bigger representational change:
`ProtocolData.messages` is a `name → message value` table (flattened eagerly
at protocol-construction time, mirroring how `newType` eagerly merges `^is`
fields), so two distinct messages can't occupy the same name slot at all —
there is no "both exist, pick one at the use site" state to be ambiguous
about. Diamond re-inheritance is not a conflict (`X`'s message reached
through two parents is the *same* value, checked by identity, not by name),
but two different parents contributing two different messages under the same
name is rejected when `Z` is defined. Reaching name-keyed messages through
qualified access (`X/clash`) still works normally; only `Z`'s own combined
table is affected.

### 3.4 No re-declaration of an inherited name

A child protocol may not redeclare a message name owned by an ancestor:

```gene
(protocol B ^inherit [A]
  (message do_a [self : Self] : Any)  # ERROR: conflicts with inherited A/do_a
  ...)
```

If different behavior is needed, define a differently-named message. This
keeps message ownership unambiguous and avoids override/MRO complexity.

### 3.5 Subtyping is structural from the impl

```gene
(fn print-a [x : A] (println (x ~ A/do_a)))
(print-a t)   # t : T, and T implements C, which inherits A
```

Writing `impl C T` is the only declaration needed; it implies `T` satisfies
every ancestor of `C` (here, `A`). No separate `^impl [A]` annotation is
required — the subtype relationship is derived automatically from the impl
graph. `^impl [C]` on a type declaration remains a compiler-checked
requirement that an `impl C T` exists, but is not itself the source of truth
for what `T` implements; a lone `^impl [C]` and an `impl C T` elsewhere both
register `T → {A, B, C}` in the same way. This composes with the `^is`-walk
rule in §2.1: `T`'s ancestors' impls contribute to the same registration.

### 3.6 Reusing a separately visible ancestor impl

```gene
(impl A T (message do_a [self] "from A impl"))
(impl B T (message do_b [self] ...))  # omits do_a
```

If `impl A T` is already visible when `impl B T` is compiled, `impl B T` may
omit messages already satisfied by that visible ancestor impl. The compiler
checks that `{messages in impl B T body} ∪ {messages satisfied by in-scope
ancestor impls}` covers `B`'s full transitive closure; otherwise it is a
missing-message error.

Two separately visible impls providing the *same* `(protocol, type)` pair
(e.g. both `impl A T` and `impl B T` defining `A/do_a`) is an ordinary
duplicate-impl ambiguity error at the use site of `A/do_a` on `T` — the
existing coherence rule applies unchanged, it does not get a new rule for
inheritance.

This is the highest-risk piece of the design (see §11) because it requires
the compiler to merge completeness evidence across separate impl
declarations rather than checking one impl body in isolation.

### 3.7 Circular inheritance

```gene
(protocol A ^inherit [B] ...)
(protocol B ^inherit [A] ...)
```

Compile error at definition time. Forward-declared protocols are not
supported in MVP; a protocol body may only refer to already-defined
protocols.

### 3.8 Generic protocols

```gene
(protocol (Container item)
  (message put [self : Self, x : item] : Self)
  (message get [self : Self] : item))

(protocol (SortedContainer item)
  ^inherit [(Container item)]
  (message min [self : Self] : item)
  (message max [self : Self] : item))
```

MVP requires an **exact type-parameter match** — `^inherit [(Container
item)]` reuses the same parameter. Specializing a parent
(`^inherit [(Container Int)]` while the child stays generic) is deferred; see
open questions.

---

## 4. Dispatch table design

With inheritance, looking up `B/do_b` on `T` must consider `impl C T` where
`C`'s closure includes `B`, not only a direct `impl B T` — and, per §2.1,
must also consider impls visible on `T`'s `^is` ancestors.

**Message-name flattening is eager, at protocol-construction time.** `C`'s
`messageNames → message value` table is computed once when `C` is
constructed (merging each parent's already-flattened table, deduped by value
identity — see §3.2/§3.3), so `impl C T`'s completeness check and every
downstream lookup by name already sees the full transitive closure with zero
per-call cost. This part matches the original "flatten eagerly" intent.

**Protocol-ancestor matching at dispatch time walks the parent chain, and
this is a deliberate deviation from an earlier draft of this section**, which
called for registering one dispatch entry per `(protocol, type)` pair up
front and rejected chain-walking as unacceptable for a performance-sensitive
VM. In practice: `resolveProtocolMessage`/`hasVisibleImpl` in `src/gene/vm.nim`
already walked `T`'s `^is` chain at dispatch time for type inheritance before
this document existed, so a from-scratch "flatten every ancestor pair at
registration" scheme for protocols would have been the odd one out rather
than consistent with the codebase. `impl C T` is registered once, under `C`
only; checking whether it also satisfies an ancestor protocol `A` walks `C`'s
(typically shallow) `^inherit` chain via `protocolIsOrInherits` at the match
site. Measured on `vm.protocol_message.compiled_chunk`
(`benchmarks/bench_core.nim`), this cost ~1394365 ops/s before this change
and ~1389748 ops/s after (~0.3%, within run-to-run noise) — not a measurable
regression in practice, so the theoretical O(depth) walk was not worth a
larger registration-time restructuring for this MVP slice.

```text
impl C T registered once, under protocol C
lookup(A, T)  → same(C, A)? no  → walk C.parents → same(B, A)? no → walk further → found
lookup(C, T)  → same(C, C)? yes → done
```

Duplicate-registration conflicts (§3.6) are still caught at registration
time, unchanged.

---

## 5. Default message bodies

```gene
(protocol B ^inherit [A]
  (message do_b [self : Self] : Any
    (do_a self)))  # default body, calls an inherited message
```

A message may carry a default implementation in its own protocol body. If
`impl B T` doesn't provide `do_b`, the default is used.

**Design call: implement defaults as a dispatch-table fallback, not as
derive-style codegen.** A default body is generic over `Self` — it never
needs a per-type copy or knowledge of `T`'s shape. At the same registration
step described in §4, if `impl B T` doesn't explicitly provide a defaulted
message, register that `(protocol, type)` dispatch entry pointing at the
**one shared default closure** rather than synthesizing a per-type `impl`
node in the overlay.

This deliberately keeps defaults independent of `^derive` (§6): derive is a
macro that inspects the `Type` value to generate type-specific code (field
names, `^opt`/`^skip` options); a default never needs that, so routing it
through the derive/overlay machinery would pay per-type codegen cost for a
mechanism that is supposed to be free.

Ancestor defaults are visible to descendants. Since re-declaration of an
inherited message name is disallowed (§3.4), a default can only be
overridden by a descendant protocol defining a genuinely new message name, so
no default-resolution conflict can arise.

**Fully-defaulted protocols need no impl at all.** If every message in a
protocol's transitive closure has a default, the base coherence rule in §1
("zero visible impls is a missing-implementation error") gets one exception:
zero visible impls is fine for that protocol, for any type — the defaults
serve as the effective impl. `Node` (`docs/design.md §1.2-1.3`, "every value
implements Node") is the existing example this generalizes. See §9.2.

---

## 6. Derive across inheritance

```gene
(protocol A
  (message do_a [self : Self] : Any)
  (derive [t req]
    `(impl A %t (message do_a [self] (to-str self/name)))))

(protocol B ^inherit [A]
  (message do_b [self : Self] : Any)
  (derive [t req]
    `(impl B %t (message do_b [self] (to-str self/value)))))

(type T ^props {^name Str ^value Int} ^derive [B])
```

`^derive [B]` runs **all of `B`'s ancestor derives first, in topological
order, then `B`'s own derive** — equivalent to writing `^derive [A B]`. A
type author writing `^derive [B]` means "give me everything `B` provides";
requiring them to also list every ancestor would defeat the point of
inheritance.

`B`'s derive form cannot call `A`'s derive directly, but can assume `A`'s
impl is already present by the time it runs — each derive form stays focused
on its own messages.

Per-ancestor options are passed by listing the ancestor explicitly:

```gene
(type User ^derive [(A ^opt1 "x") (B ^opt2 "y")])
```

Explicit listing always overrides automatic transitive expansion; `A`'s
derive still runs first because it is a topological ancestor, regardless of
list order.

**Derive vs. default, restated:** default (§5) is a zero-codegen dispatch
fallback for messages that don't need per-type knowledge; derive is opt-in,
per-type macro codegen for messages that do. Keep the two mechanisms and
their compiler passes separate (see open question OQ-E).

---

## 7. Overriding an inherited message

Disallowed — see §3.4. There is no override/MRO mechanism for protocol
inheritance. Wanting different per-type behavior for the "same" concept
means either a manual `impl` (no default is used once the impl provides the
message) or a genuinely new message name. (Type inheritance has its own,
different override rule — most-specific `^is` ancestor wins — per §2.1 and
§8.)

---

## 8. Type-direct messages

A `type` declaration may carry its own callable methods without a separate
protocol + impl pair:

```gene
(type Box ^props {^val Int}
  (message get [self] self/val)
  (message doubled [self] (* self/val 2)))

(var b (Box ^val 7))
(b ~ get)         # => 7   (message send, §9)
(Box/get b)       # => 7   (explicit qualified form)
(b ~ doubled)     # => 14
```

### Motivation

The three-form ceremony (`protocol` + `type` + `impl`) is right when behavior
is shared across types or exposed as a public contract. For purely private,
single-type behavior it is boilerplate. Type-direct messages group behavior
at the declaration site without polluting the module with a single-use
protocol.

### Namespacing, not lexical binding

An earlier draft of this design bound `get` bare in the enclosing module
scope, exactly like a standalone `fn`. That doesn't scale: two types in the
same module both defining a message with the same name (say, `Dog/speak` and
`Cat/speak`) would collide as duplicate bindings of the same bare name.
**Type-direct messages are namespaced under their declaring type instead** —
`Box/get` is a qualified name resolved exactly like `Stream/next` or
`Color/red` (`docs/design.md §2.1`), never a bare binding in the enclosing
scope. This is what lets unrelated types define same-named messages without
collision, and it's why `~` needs the resolution rule in §9.

### Dispatch

`(type X (message do_a [self] …))` binds `do_a` as a qualified member of `X`
— `X/do_a` — not a plain function in the enclosing scope. `(x ~ do_a)`
reaches it through `~`'s message-send resolution (§9); `(X/do_a x)` reaches
it directly through ordinary qualified-name resolution, unchanged from how
any other qualified member works.

Type-direct messages are **not** protocol messages: they are not
`vkProtocolMessage` values, cannot appear in `^impl` checks, and are invisible
to impl-based dispatch lookups. A type declaring `^impl [Renderable]` and
also carrying a type-direct `render` message still needs an explicit `(impl
Renderable T …)`; the type-direct message does not satisfy the protocol
requirement. This keeps the two systems orthogonal: protocols are public
contracts, type messages are private convenience.

### Inheritance interaction

- Child types see parent type-direct messages by walking the type's `^is`
  chain (§2), not by lexical binding: looking up `speak` on a `Dog` checks
  `Dog`'s own message table, then `Animal`'s — most-derived wins.
  `(Dog/speak d)` and `(d ~ speak)` both reach `Animal/speak` if `Dog`
  doesn't define its own.
- A child's same-named message shadows the parent's during that same walk —
  first match wins. No MRO, no virtual dispatch, no error.
- Type-direct messages do not auto-create a protocol. If a caller needs a
  protocol for typed boundaries or multi-type dispatch, they write an
  explicit `protocol` + `impl`.

### Error forms

- A type body item that is not a `(message …)` form is a compile-time error.
- A `(message …)` form missing a name or parameter vector is a compile-time
  error (same validation as `impl` message forms).
- Duplicate message names in the same type body are a compile-time error.

### Implementation sketch

1. In `compileType`, scan `body[1:]` for `(message …)` forms.
2. For each, emit `opMakeFn` (reusing `buildFunctionProto`) and register it
   in the type's own message table — `TypeData`/`TypeProto` gains a
   name→function member table — rather than binding it in the enclosing
   scope.
3. Qualified-name resolution (`docs/design.md §2.1`, already handling
   `Stream/next`-style lookups) is extended to also check this per-type
   message table.
4. `~`'s fallback path (§9) walks the `^is` chain against this same table.

This does touch `TypeData`/`TypeProto`, unlike the original sketch, which
assumed a plain enclosing-scope binding was sufficient — that assumption is
what created the cross-type collision problem in the first place.

---

## 9. Message resolution and `~`

Three sources can provide behavior for a receiver: protocol messages (§1,
§4), type-direct messages (§8), and fully-defaulted protocols (§5). `~` is
the entry point for reaching all of them by unqualified name, and needs a
resolution rule precise enough to keep existing non-message uses of `~`
working unchanged.

### 9.1 The two forms

```gene
(x ~ name ...)     # unqualified — message send, resolved in the context of x
(x ~ X/name ...)   # qualified — X resolved as an ordinary/built-in name, then applied
```

The **qualified** form is unchanged from the base design (`docs/design.md
§3`): `X/name` resolves via ordinary qualified-name rules, then `x` is
prepended. `X` must already be a built-in or a name resolved in the current
lexical scope — no receiver-based resolution is involved.

The **unqualified** form gets a two-tier fallback:

1. **Lexical first.** Resolve `name` as an ordinary bound name, exactly as
   today. This covers both non-message uses of `~` (`(xs ~ filter p)`,
   `(xs ~ map f)` — `filter`/`map` are plain functions, not messages) and
   protocol messages already reachable by their existing lexical binding
   (`(item ~ to_html)`). If found, use it — **this preserves every existing
   use of `~` unchanged.**
2. **Type-direct fallback.** If `name` is not bound lexically at all, look it
   up in the receiver's runtime type's message table (§8), walking the `^is`
   chain. This is the new path, and exists specifically to reach type-direct
   messages, which are deliberately *not* bound bare in lexical scope (§8).
3. Neither resolves → compile-time missing-message error.

If `x`'s static type is known, step 2 resolves at compile time to a direct
call — zero overhead, same cost as the qualified form. If `x : Any`, it's one
dynamic table lookup keyed by `(runtime-type, name)`, walking `^is` at
runtime; an inline cache at the call site is the expected optimization once
this is on a hot path.

### 9.2 Universal / fully-defaulted protocols

A protocol whose entire message closure has default bodies (§5) needs no
impl at all, for any type — `Node` is the existing example: every value
already satisfies it structurally. No new tier is needed at the `~`
resolution level for this: it lives entirely inside ordinary protocol
dispatch (tier 1 above). When no impl is found for a type, dispatch falls
through to the default instead of raising a missing-impl error, only when
the protocol's whole closure is defaulted.

### 9.3 Open question — silent shadowing

If an unrelated lexical binding happens to share a name with a type-direct
message (some plain function `speak` in scope, and `Dog` also has a
type-direct `speak`), tier 1 wins silently under the rule above — no
ambiguity error is raised. See OQ-F.

---

## 10. Nil and scalar receiver types

`Nil` uses the **regular impl approach — no special dispatch carve-out.**

**Design intent, not yet implemented.** Checked empirically against the
current implementation (see §11): `Nil` is not currently a resolvable
`vkType` value (built-in type names like `Nil`/`Bool`/`Int` exist only as
strings inside the gradual type-boundary checker), and protocol dispatch
currently requires a `vkNode` receiver with a `vkType` head, which a bare
scalar like `nil` doesn't have. The design below is still the right target;
it's just a separate, larger piece of work than protocol inheritance.

`Nil` is already an ordinary nominal type under `Any` in the MVP hierarchy
(`docs/design.md §7.2`, settled at `§21`). Message dispatch is defined on the
receiver's *runtime type*, and scalar-like values already dispatch this way
rather than by literal node head (`docs/design.md §1.1`: "scalars expose
type information through the runtime even though their node head is the
scalar itself"). So:

```gene
(impl ToHtml Nil
  (message to_html [self] : Node
    `(span "—")))
```

works exactly like implementing any other concrete type, and plugs into the
same flattened dispatch table (§4) as everything else. Inheritance,
defaults, and derive all apply to `Nil` with no special case, since none of
those mechanisms inspect anything but the receiver's runtime type and the
protocol's message set.

**Optional types need no union-impl mechanism.** For `(opt T) = (| T Nil)`,
dispatch happens on the concrete runtime value at the call site: if the
value is `nil`, `impl P Nil` runs; if it is a `T`, `impl P T` runs. No
separate `impl P (| T Nil)` form is needed or should be added — a union is
not itself a nominal dispatch target.

---

## 11. MVP scope and implementation order

Base protocols (`docs/design.md §10`, no inheritance) are already
implemented and stable, and sit at implementation-order item 13; base
`^derive` plumbing is item 9 of the readiness checklist. Protocol-local
`derive` more broadly is sequenced at implementation-order item 16
(`docs/design.md §19`). The work below builds on both.

**Implemented (`protocol-inheritance` branch):**

- §2 — turned out to already be implemented (see the §2.1 correction); no
  change needed.
- §3.1–§3.2, §3.4, §3.7 (protocol-inheritance syntax, transitive closure with
  diamond dedup, no-redeclaration-of-inherited-name, circular-inheritance
  rejection — the last one falls out for free from top-to-bottom evaluation
  order, since a protocol can only reference an already-defined parent)
- §3.3, implemented as a protocol-definition-time conflict error rather than
  a use-site ambiguity error (see the §3.3 correction — a name-keyed message
  table can't represent "two distinct messages, same name" at all)
- §3.5 (structural subtyping — `impl C T` satisfies every `^inherit` ancestor
  of `C` for boundary checks and dispatch, via `protocolIsOrInherits`)
- §4 (message-name flattening at protocol-construction time; protocol-ancestor
  dispatch matching via a parent-chain walk rather than per-ancestor
  registration — see the §4 correction)
- Tests: `tests/test_protocols.nim`

**Not yet implemented / out of scope for this slice:**

- §3.6 partial impl composition (OQ-A)
- §3.8 generic protocols — no generic-protocol machinery exists in the base
  system at all yet (`protocol` declarations take a simple symbol name, not
  a type-parameter list), so this is blocked on a larger generics feature,
  not just on inheritance (OQ-C)
- §5 default message bodies (OQ-B) — and, since it depends on defaults,
  §9.2 universal/fully-defaulted protocols defers with it
- §6 transitive `^derive` — `ProtocolProto`/`applyProtocolDerive` don't yet
  resolve or run ancestor derive forms before a child's own; `^derive [B]`
  today only runs `B`'s own derive form
- §7, §8 — type-direct messages (`(type T (message ...) ...)`) don't exist
  in the compiler yet; `compileType` has no message-scanning step
- §9 — `~`'s resolution is unchanged from the base design (pure lexical,
  per `docs/design.md §3`); the two-tier fallback has no receiver-type
  message table to fall back to until §8 exists
- §10 — checked empirically (`./bin/gene eval '(protocol P (message m [self] : Str "x")) (impl P Nil (message m [self] : Str "n")) (m nil)'`) and it does **not** work yet: `Nil`/`Bool`/`Int`/etc. are recognized only as special-case strings inside the gradual type-boundary checker (`matchesBuiltinType` in `src/gene/vm.nim`), not as bound `vkType` values, so `Nil` isn't a resolvable symbol in impl-receiver position at all — "undefined symbol: Nil". Separately, protocol dispatch (`receiverType` in `src/gene/vm.nim`) currently requires a `vkNode` value with a `vkType` head; a bare scalar like the `nil` literal (`vkNil`) has no such head, so it couldn't dispatch through a protocol message even if `Nil` resolved to a type value. This is a larger, pre-existing gap in scalar/singleton dispatch, not specific to inheritance — out of scope for this slice, correcting an earlier claim in this document that it "already works."

---

## 12. Open questions

| # | Question | Recommendation |
|---|---|---|
| OQ-A | Is partial impl composition (§3.6 — `impl B T` omitting messages covered by a separately visible `impl A T`) worth its coherence-checker complexity for the first slice? | Defer. Require `impl B T` to restate its full transitive closure in the first cut; revisit once dispatch-table flattening (§4) is proven in production. This is the single highest-risk item in the design, and it's separable from everything else. |
| OQ-B | Should default message bodies (§5), and the fully-defaulted-protocol relaxation they enable (§9.2), ship in the same slice as base inheritance? | No. Ship after §4 is stable. Coupling a second new completeness-checking path (defaults) to the first one (inheritance flattening) makes it harder to isolate bugs in either. Once added, implement as a dispatch-fallback (§5), not via the derive/overlay path. |
| OQ-C | Generic protocol inheritance (§3.8): exact type-parameter match only, or allow specialization (`^inherit [(Container Int)]` under a still-generic child)? | Exact match only for MVP. Specialization introduces associated-type-like complexity that doesn't have a clear need yet; revisit if a concrete use case appears. |
| OQ-D | Should the compiler warn or error on a redundant `^impl [A B]` when `B`'s closure already implies `A`? | Warn, not error. Redundant but harmless; a lint ("`A` is already implied by `B`") is enough. |
| OQ-E | Defaults (§5) and derive (§6) both feed the impl-completeness checker at compile time. Should they be one compiler pass or two? | Keep them as two separate, ordered passes: resolve default-fallback dispatch entries as a dispatch-table concern (§4/§5), and run derive expansion as a separate codegen concern, with completeness-checking happening only after both have run. A single merged pass makes it harder to tell whether a missing-message error came from a broken default or a broken derive. |
| OQ-F | Should `~`'s tier-1 lexical match (§9.1) silently shadow a same-named type-direct message on the receiver's type, or is that an ambiguity error? | Silent shadow, for now. This preserves `~`'s existing behavior exactly and keeps step 1 a zero-cost, zero-new-rule lookup. The collision is narrow (an unrelated top-level binding must accidentally share a name with a type-direct message on the *specific* receiver type in use) — revisit only if it causes real confusion in practice. |

---

## Complexity assessment

- **Dispatch table flattening (§4)** touches the core impl-lookup mechanism
  all dispatch depends on. Must preserve the existing O(1) dispatch
  guarantee — this is the piece to get right first.
- **Type-direct message namespacing and `~`'s two-tier resolution (§8-§9)**
  add a new per-type message table and touch qualified-name resolution. Tier
  1 (lexical-first) is the guard that must not regress: every existing
  non-message use of `~` (pipeline-style flips) has to keep resolving
  exactly as before.
- **Transitive derive expansion (§6)** interacts with the macro system;
  ancestor derives must run before descendant derives, which means
  inheritance depth must be known at derive-expansion time.
- **Partial impl composition (§3.6 / OQ-A)** is the most dangerous deferred
  feature: it requires merging completeness evidence across separate impls,
  a new kind of coherence check not present in the base (no-inheritance)
  system.
