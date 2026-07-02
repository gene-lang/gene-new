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
- Messages are ordinary callable values. The qualified spelling
  (`(item ~ ToHtml/to_html)`) is always unambiguous; bare `(item ~ to_html)`
  is only shorthand when receiver-context lookup finds a unique applicable
  message with that simple name (§9).
- **Message names are not bound in the enclosing lexical scope.** Declaring
  `(protocol ToName (message to_name ...))` binds `ToName` only; `to_name`
  is reachable as `ToName/to_name` (qualified member access, like
  `Stream/next`) and through sends (`(x ~ to_name)`), never as a bare
  lexical binding. Bare calls `(to_name x)` are therefore undefined-symbol
  errors — use a send or the qualified spelling. This is a deliberate
  revision (earlier drafts and the pre-revision implementation bound each
  message name in scope); scope binding can be reintroduced later as an
  additive feature if it proves worth having, but starting without it keeps
  `(f x)` = lexically-resolved function call and `(x ~ m)` = message send as
  two cleanly separate operations, and removes the duplicate-binding
  collision that same-named messages across protocols would otherwise cause
  in a shared scope.
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

### 3.2 Transitive closure and qualified message ownership

A protocol message is identified by its **defining protocol plus local
message name**, not by simple name alone. `A/do_x` and `B/do_x` are distinct
messages even though both have the local name `do_x`.

When `C ^inherit [A B]`, `C`'s message closure is the union of `A`, `B`, and
`C`'s own messages, keyed by qualified identity. In a diamond (`C ^inherit
[A B]`, `B ^inherit [A]`), `A`'s messages appear once — reachability through
two paths does not duplicate them.

`impl C T` must provide (directly, or via §3.6/§5) every message in `C`'s
transitive closure. Missing one is a compile error: `"impl C T is missing
message A/do_a"`.

### 3.3 Same-name messages across independent parents

```gene
(protocol X (message clash [self : Self] : Any))
(protocol Y (message clash [self : Self] : Any))
(protocol Z ^inherit [X Y] (message do_z [self : Self] : Any))  # OK
```

Same-name messages across unrelated protocols are expected and supported.
This is required for real protocol composition: two independently-authored
contracts can both have `open`, `close`, `read`, `write`, `len`, `name`,
`compare`, or `do_x` without being semantically the same operation.

The collision is resolved by qualified message identity:

```gene
(type T ^derive [Z] ...)

(t ~ X/clash ...)
(t ~ Y/clash ...)
```

Bare `(t ~ clash ...)` is not a protocol conflict resolver. If `T` has no
type-direct `clash` message and more than one visible protocol message named
`clash` applies, the unqualified send is ambiguous and must be written with
`X/clash` or `Y/clash`. If exactly one protocol message named `clash`
applies, the bare send resolves to it — this exactly-one rule is normative
(OQ-H), not implementation-defined. The qualified form is always available
and always unambiguous.

Because message names are never bound in the enclosing scope (§1), declaring
`X` and `Y` with the same message name in one module is not a binding
collision either — there is nothing at module scope to collide.

### 3.4 Re-declaring an inherited simple name

A child protocol may declare its own message with the same simple name as an
ancestor. It creates a new qualified message owned by the child protocol:

```gene
(protocol B ^inherit [A]
  (message do_a [self : Self] : Any))  # B/do_a, distinct from A/do_a
```

`B/do_a` does not override `A/do_a`; both messages are in `B`'s closure and
both must be implemented unless one is satisfied by a default or separate
ancestor impl. There is still no override/MRO mechanism for protocol
inheritance. If a default body or implementation needs one of the operations,
it should call the qualified message (`A/do_a` or `B/do_a`) rather than rely
on the simple name.

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
(impl B T (message do_b [self] ...))  # omits A/do_a
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

### 3.6.1 Implementing same-named messages

When a protocol closure contains more than one message with the same simple
name, an `impl` body must qualify those message definitions:

```gene
(protocol A (message do_x [self : Self] : Str))
(protocol B (message do_x [self : Self] : Str))
(protocol C ^inherit [A B])

(impl C T
  (message A/do_x [self] "A behavior")
  (message B/do_x [self] "B behavior"))
```

For a message name that is unique in the target protocol's closure,
`(message do_y ...)` is shorthand for that one qualified message. If the
simple name is ambiguous, using it in an `impl` body is a compile-time error
with a diagnostic listing the candidate qualified messages.

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

**Message closure flattening is eager, at protocol-construction time.** `C`'s
qualified message set is computed once when `C` is constructed (merging each
parent's already-flattened closure, deduped by qualified identity — see
§3.2/§3.3), so `impl C T`'s completeness check and every downstream lookup
by qualified message already sees the full transitive closure with zero
per-call cost.

Simple names are a secondary index, not the dispatch key. A protocol can have
more than one closure message whose local name is `do_x`; the key used by
completeness checking and dispatch is the message value / qualified identity
(`A/do_x`, `B/do_x`). The simple-name index is useful for diagnostics and for
the unique-name shorthand in impl bodies and unqualified sends, but it must
be able to represent "ambiguous: qualify this name" rather than storing only
one message.

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
    (A/do_a self)))  # default body, calls an inherited message
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

Ancestor defaults are visible to descendants. A descendant protocol declaring
the same simple name creates a distinct qualified message (§3.4); it does
not override or replace the ancestor default. If a protocol closure contains
both `A/do_x` and `B/do_x`, each message independently either has an explicit
impl body, a default body, or a missing-message error.

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

## 7. No protocol-message overriding

Protocol inheritance has no override/MRO mechanism. Reusing an inherited
simple name creates another qualified message, not an override:

```gene
(protocol A (message render [self : Self] : Node))
(protocol B ^inherit [A]
  (message render [self : Self] : Str))  # B/render, not an override of A/render
```

An implementation of `B` must account for both `A/render` and `B/render`.
Callers choose with `(x ~ A/render)` or `(x ~ B/render)`. Type inheritance
has its own different rule for type-direct messages — most-derived `^is`
ancestor wins — per §2.1 and §8.

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

### Inline protocol impls

A type body may also carry `impl` blocks with the receiver implied — the
enclosing type:

```gene
(protocol A (message do_a [self : Self] : Any))

(type T ^props {...}
  (impl A
    (message do_a [self] ...)))
```

This is pure placement sugar: it is semantically identical to writing
`(impl A T (message do_a [self] ...))` immediately after the type
declaration, in the same scope. Everything about standalone impls carries
over unchanged:

- the impl must cover the protocol's full transitive closure (§3.2), with
  the same qualified-name rules for same-named closure messages (§3.6.1);
- it registers as an ordinary visible impl — an inline `impl A` plus a
  separate `impl A T` elsewhere is the usual duplicate-impl error, and an
  inline impl plus a `^derive`-generated impl for the same protocol
  conflicts the same way a manual one does;
- it satisfies a `^impl [A]` requirement on the same type (listing both is
  redundant but harmless, per OQ-D);
- a marker protocol needs no messages: `(impl Send)` inline works.

Unlike type-direct messages, inline impls **are** the protocol system —
`(t ~ do_a)` and `(t ~ A/do_a)` dispatch through them exactly as through a
standalone impl. The two body-item kinds compose freely in one type body:
`(message …)` items are private receiver-owned behavior, `(impl P …)` items
are public contract implementations, grouped at the declaration site.

Writing a receiver inside an inline impl is an error (`(impl A T …)` inside
`(type T …)` — the receiver is always the enclosing type).

### Error forms

- A type body item that is not a `(message …)` or `(impl …)` form is a
  compile-time error.
- A `(message …)` form missing a name or parameter vector is a compile-time
  error (same validation as `impl` message forms).
- Duplicate message names in the same type body are a compile-time error.
- An inline `(impl …)` form naming a receiver is a compile-time error.

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

`~` is Gene's message-send operator. Three sources can provide behavior for
a receiver: protocol messages (§1, §4), type-direct messages (§8), and
fully-defaulted protocols (§5). `~` reaches all of them by unqualified name,
resolved **in the receiver's context** — this is what distinguishes a send
from an ordinary call. A bare call `(f x)` resolves `f` lexically, like any
call head; a send `(x ~ f)` resolves `f` against `x` first.

### 9.1 The three forms

```gene
(x ~ name ...)     # message send: name resolved in the context of x
(~ name ...)       # message send to self: (self ~ name ...)
(x ~ X/name ...)   # qualified: X/name resolved lexically, then applied to x
```

The **qualified** form is unchanged from the base design (`docs/design.md
§3`): `X/name` resolves via ordinary qualified-name rules — `X` must be a
built-in or a name resolved in the current lexical scope — then `x` is
prepended. No receiver-based resolution is involved.

The **implicit-self** form desugars to a send to the lexical `self` binding,
mirroring the leading flipped call in `docs/design.md §3`: `(~ f a)` means
`(self ~ f a)`, and it is a compile-time error when no `self` is in scope.
Resolution is identical to the explicit form, with `self` as the receiver.

The **unqualified send** resolves `name` receiver-first:

1. **Receiver context.** Look `name` up in the receiver's runtime type's
   context: type-direct messages (§8), walking the `^is` chain, then
   protocol messages provided by impls visible for the receiver's type
   (including via `^inherit`, §3.5/§4). A type-direct message with that name
   wins over protocol-message candidates because it is receiver-owned
   behavior. A protocol simple-name match is usable only when exactly one
   qualified protocol message with that simple name applies; if `A/do_x` and
   `B/do_x` both apply, bare `(x ~ do_x ...)` is ambiguous and the caller must
   write `(x ~ A/do_x ...)` or `(x ~ B/do_x ...)`. Ambiguity among multiple
   visible impls for the same qualified protocol message remains the usual
   use-site error.
2. **Lexical fallback.** If the receiver's context has no `name`, resolve it
   as an ordinary lexical binding — `(xs ~ filter p)` keeps working today
   because `filter` is a plain function and `List` defines no `filter`
   message. Note the fallback can only ever produce plain values: protocol
   message names are not bound in lexical scope (§1), so a message never
   arrives via this tier.
3. Neither resolves → missing-message error (at compile time when the
   receiver's static type is known; otherwise at the send).

**This flips the tier order from an earlier draft of this section**, which
resolved lexically first and used the receiver's context only as a fallback.
Lexical-first kept `~` essentially flipped-call sugar with a patch on top —
under it, `(x ~ f a)` resolved `f` exactly like an ordinary call head
whenever `f` was bound at all, which contradicts the intent that a send
resolves the name *differently*, in the receiver's context. Receiver-first
makes the operator mean one thing: ask the receiver first, fall back to the
surrounding scope.

Consequences accepted with receiver-first:

- When a name exists in both places, the receiver's message wins silently
  (§9.3/OQ-F, now inverted relative to the earlier draft). That is the
  message-send semantics working as intended, but it also means *adding* a
  message to a type can re-route existing `~` call sites on that type. A
  lint ("send resolves to `T/name`, shadowing lexical `name`") is the
  mitigation, not an error.
- If `x`'s static type is known, resolution happens at compile time — zero
  runtime overhead, same as the qualified form. If `x : Any`, tier 1 costs
  one dynamic lookup keyed by `(runtime-type, name)` before any lexical
  fallback; an inline cache at the call site is the expected optimization.
- Protocol messages reached through their qualified lexical binding and
  through the receiver's context agree whenever both apply, so `(item ~
  ToHtml/to_html)` behaves identically under either tier order. Bare `(item ~
  to_html)` is only a convenience when the receiver context has exactly one
  matching protocol message or a type-direct message.

`docs/design.md §3` still describes `~` as pure flipped-call sugar
(`(x ~ f a) => (f x a)`); that reading remains correct for the qualified
form and for tier-2 fallback, but this section supersedes it for unqualified
sends.

### 9.2 Universal / fully-defaulted protocols

A protocol whose entire message closure has default bodies (§5) needs no
impl at all, for any type — `Node` is the existing example: every value
already satisfies it structurally. No new tier is needed at the `~`
resolution level for this: it lives entirely inside ordinary protocol
dispatch (tier 1 above). When no impl is found for a type, dispatch falls
through to the default instead of raising a missing-impl error, only when
the protocol's whole closure is defaulted.

### 9.3 Shadowing between the two tiers

With receiver-first resolution, a message on the receiver's type silently
wins over a same-named lexical binding at send sites — the reverse of the
earlier lexical-first draft. `(d ~ speak)` calls `Dog`'s `speak` message even
when a plain function `speak` is in scope; the lexical `speak` remains
reachable as an ordinary bare call, `(speak d)`. See OQ-F.

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

- §1 — message names are no longer bound in the enclosing scope (OQ-I);
  bare calls like `(to_name x)` were migrated to sends/qualified calls in
  tests, examples, and benchmarks
- §2 — turned out to already be implemented (see the §2.1 correction); no
  change needed
- §3.1–§3.5, §3.6.1, §3.7 — the qualified-message-identity model:
  `ProtocolData` stores an identity-deduped transitive closure;
  `ProtocolImpl` entries are keyed by message value, not name; impl bodies
  accept `(message A/do_x ...)` qualification with unique-simple-name
  shorthand; same-name messages across parents coexist; redeclaring an
  inherited simple name creates a distinct message; circular inheritance is
  impossible by evaluation order
- §3.5 structural subtyping via `protocolIsOrInherits` for boundary/`^impl`
  checks; dispatch itself matches impl entries by message identity, which
  covers `^inherit` descendants without a protocol-level walk
- §4 — closure flattening at protocol-construction time; qualified access
  through a child protocol (`C/do_a` for an inherited unambiguous name)
  resolves through the closure; ambiguous spellings error with the candidate
  list
- §7, §8 — type-direct messages: `compileType` scans `(message ...)` body
  forms into a per-type table (`TypeData.messages`), reached via qualified
  access (`Box/get`) and sends, walking `^is` with most-derived-wins
- §8 inline protocol impls — `(impl P (message ...) ...)` in a type body
  registers as an ordinary visible impl with the enclosing type as receiver,
  identical to a standalone `(impl P T ...)` after the declaration (same
  closure coverage, qualification, duplicate, and `^impl`-satisfaction
  rules; `(impl Send)` works for markers)
- §9.1 — receiver-first sends: the reader preserves `(x ~ f a)` nodes
  (round-trips exactly); `opResolveMessage` resolves tier 1 (type-direct
  walking `^is`, then visible protocol impl entries by simple name with the
  exactly-one rule) and falls back to the lexical binding; `(~ f a)` sends
  to lexical `self`; qualified sends and the `^protocol`/`^receiver`
  direct-call metadata path go through protocol member access
- Tests: `tests/test_protocols.nim`, plus migrated cases in
  `tests/test_modules.nim`, `tests/test_errors.nim`, `tests/test_vm.nim`,
  `tests/test_reader.nim`, `tests/test_rc.nim`, `tests/spec_runner.nim`

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
- §9.1's compile-time resolution for statically-known receiver types, the
  shadowing lint (OQ-F), and inline caches for dynamic sends — all sends
  currently resolve dynamically at the call site
- §10 — checked empirically (`./bin/gene eval '(protocol P (message m [self] : Str "x")) (impl P Nil (message m [self] : Str "n")) (m nil)'`) and it does **not** work yet: `Nil`/`Bool`/`Int`/etc. are recognized only as special-case strings inside the gradual type-boundary checker (`matchesBuiltinType` in `src/gene/vm.nim`), not as bound `vkType` values, so `Nil` isn't a resolvable symbol in impl-receiver position at all — "undefined symbol: Nil". Separately, protocol dispatch (`receiverType` in `src/gene/vm.nim`) currently requires a `vkNode` value with a `vkType` head; a bare scalar like the `nil` literal (`vkNil`) has no such head, so it couldn't dispatch through a protocol message even if `Nil` resolved to a type value. This is a larger, pre-existing gap in scalar/singleton dispatch, not specific to inheritance — out of scope for this slice.

---

## 12. Open questions

| # | Question | Recommendation |
|---|---|---|
| OQ-A | Is partial impl composition (§3.6 — `impl B T` omitting messages covered by a separately visible `impl A T`) worth its coherence-checker complexity for the first slice? | Defer. Require `impl B T` to restate its full transitive closure in the first cut; revisit once dispatch-table flattening (§4) is proven in production. This is the single highest-risk item in the design, and it's separable from everything else. |
| OQ-B | Should default message bodies (§5), and the fully-defaulted-protocol relaxation they enable (§9.2), ship in the same slice as base inheritance? | No. Ship after §4 is stable. Coupling a second new completeness-checking path (defaults) to the first one (inheritance flattening) makes it harder to isolate bugs in either. Once added, implement as a dispatch-fallback (§5), not via the derive/overlay path. |
| OQ-C | Generic protocol inheritance (§3.8): exact type-parameter match only, or allow specialization (`^inherit [(Container Int)]` under a still-generic child)? | Exact match only for MVP. Specialization introduces associated-type-like complexity that doesn't have a clear need yet; revisit if a concrete use case appears. |
| OQ-D | Should the compiler warn or error on a redundant `^impl [A B]` when `B`'s closure already implies `A`? | Warn, not error. Redundant but harmless; a lint ("`A` is already implied by `B`") is enough. |
| OQ-E | Defaults (§5) and derive (§6) both feed the impl-completeness checker at compile time. Should they be one compiler pass or two? | Keep them as two separate, ordered passes: resolve default-fallback dispatch entries as a dispatch-table concern (§4/§5), and run derive expansion as a separate codegen concern, with completeness-checking happening only after both have run. A single merged pass makes it harder to tell whether a missing-message error came from a broken default or a broken derive. |
| OQ-F | Under receiver-first resolution (§9.1), a type message silently shadows a same-named lexical binding at `~` send sites. Error, lint, or silence? | Lint, not error. The shadow is the intended semantics — a send asks the receiver first — but a diagnostic ("send resolves to `T/name`, shadowing lexical `name`") catches the migration hazard where adding a message to a type silently re-routes existing sends. Bare calls `(name x)` are unaffected; they stay purely lexical. |
| OQ-G | Should the lexical fallback (§9.1 tier 2) exist at all, or should `~` be receiver-only? | Keep the fallback for MVP. Dropping it breaks the entire pipeline idiom (`(xs ~ filter p; ~ map f)` — `filter`/`map` are plain stdlib functions today), which the main design doc and `examples/web_demo.gene` lean on heavily. Revisit once std stream/list operations become protocol messages on their receiver types; at that point receiver-only would make `~` purely a send, and the fallback could be deprecated with a lint. |
| OQ-H | Should bare `(x ~ name)` ever resolve a protocol message, or only type-direct messages plus lexical fallback? | **Settled — normative in §3.3/§9.1.** Resolves iff exactly one applicable protocol message has that simple name; ambiguity requires qualification. |
| OQ-I | Should protocol declarations also bind message simple names in the enclosing scope (enabling bare calls like `(to_name x)`)? | **Settled — no, for now.** Messages are reachable via qualified access and sends only (§1). Scope binding can be added later as an additive feature; adding it would require an ambiguity-marker binding design for same-named messages across protocols in one scope. |

---

## Complexity assessment

- **Qualified message identity (§3-§4)** touches the core protocol storage
  and impl-lookup mechanism all protocol dispatch depends on. The central
  invariant is that completeness and dispatch are keyed by message identity
  (`Protocol/name`), while simple names are only a possibly-ambiguous index
  for diagnostics and shorthand. This is the piece to get right first.
- **Type-direct message namespacing and `~`'s receiver-first resolution
  (§8-§9)** add a new per-type message table and change what unqualified `~`
  heads mean. The guard that must not regress: existing pipeline sends
  (`(xs ~ filter p)`) must keep resolving through the lexical fallback until
  receiver types actually define those messages, and bare calls `(f x)` must
  remain purely lexical.
- **Transitive derive expansion (§6)** interacts with the macro system;
  ancestor derives must run before descendant derives, which means
  inheritance depth must be known at derive-expansion time.
- **Partial impl composition (§3.6 / OQ-A)** is the most dangerous deferred
  feature: it requires merging completeness evidence across separate impls,
  a new kind of coherence check not present in the base (no-inheritance)
  system.
