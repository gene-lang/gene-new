# Protocols, messages, and derivation

**Status:** detailed design reference and rationale. The implemented contracts
are [protocols](../spec/protocols.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 10. Protocols, messages, and derivation

```gene
(protocol ToHtml
  (message to_html [] : Node))

(impl ToHtml for MenuItem
  (message to_html [] : Node
    `(tr (td %self/name))))
```

**`self` is implicit in a message body and does not appear in the parameter
vector** — the parameter vector describes only the send arguments, and the
compiler binds `self` to the receiver (as it does for `ctor`, §7.1.1). A
message that takes an argument declares just that argument:

```gene
(message add [n] : Int (+ self/n n))   # self implicit; n is the send argument
```

`self` is an immutable, compiler-owned binding (§12.1): `(set self …)` and
declaring another `self` are compile errors, and it cannot be shadowed, so
`(.m)` always denotes the receiver.

**Parent delegation uses `super` as a receiver.** Inside a type message body,
`(super .m args…)` invokes the implementation of `m` **above the enclosing
type** on the nominal parent chain, called with `self`:

```gene runnable
(type Animal ^props {} (message speak [] : Str "…"))
(type Dog : Animal ^props {}
  (message speak [] : Str ^^override ($ "woof; " (super .speak))))
```

`super` resolves from the *enclosing type's* parent, not the receiver's runtime
type, so declarations `A`, `B : A`, and `C : B` make each `super` step exactly
one level relative to the
body it appears in. The parent identity is fixed when the type is created and
recorded on the message body itself, so `super` resolves **no user-visible
name** — a local binding that happens to share the parent's or the enclosing
type's spelling cannot redirect the delegation. A closure written inside a
message body may use `super`, and it delegates from the same parent. `super` is
reserved and cannot be bound. Using it outside a type message body with a
parent is a compile error.

`super` delegates a **protocol** message the same way. `(super .P:m)` resolves
`P`'s impl from above the enclosing type; the qualifier names the message and
the parent selects the impl, which is the ordinary "qualifier constrains, never
selects" rule with the parent standing in for the receiver's runtime type:

```gene runnable
(protocol Speaks (message speak [] : Str))
(type Animal ^props {})
(impl Speaks for Animal (message speak [] : Str "…"))
(type Dog : Animal ^props {})
(impl Speaks for Dog
  (message speak [] : Str ($ "woof; " (super .Speaks:speak))))

((Dog) .Speaks:speak)   # "woof; …"
```

This needed no new precedence rule: resolution already keeps only providers at
the nearest applicable receiver depth (`docs/scoped-impls.md` §3.3), so starting
the walk at the parent *is* "continue from above the enclosing type". A level
that implements nothing is skipped rather than being an error, and nothing above
at all is a recoverable `MessageError`. The same works in an inline impl, whose
receiver is the enclosing type, and in a standalone `(impl P for T …)`, which
names its receiver. `(super .Self:m)` names no qualifier and so is exactly the
bare super send.

One form stays unsupported: the dynamic `(super .%m)`. `super`'s target is
fixed statically, and an expression yielding a message value cannot be checked
against the parent at compile time, so it is diagnosed rather than silently
mis-dispatched.

**Static impl selection is `super` only.** `T/m` is not a callable path:
`(Dog/bark p)` used to run `Dog`'s body even when `p` was a `Pup` overriding it,
and `(map xs Dog/bark)` did that per element. Both are now errors that name the
replacement — a send `(x .bark)`, or the value spelling `Self:bark`, which
dispatches. Enum variants (`Direction/east`) are unaffected: they are not
messages. Impls were already never exposed as members.

`Self` in a type annotation is **declaration-bound**. A new method on `Dog`
uses `Self = Dog`, including parameter, return, and nested type positions.
A protocol has a separate abstract `Self` for each protocol identity; introducing
a conformance binds it, and nominal inheritance preserves that binding.
Requirements and defaults inherited through another protocol retain their own
declaring protocol's binding. Runtime receiver dispatch still selects the body:

```gene runnable
(protocol Eq (message eq [other : Self] : Bool))
(type Dog ^props {^name Str})
(type Pup : Dog ^props {})
(impl Eq for Dog (message eq [other : Self] : Bool (== self/name other/name)))

(var dog (Dog ^name "rex"))
(var pup (Pup ^name "rex"))

(dog .Eq:eq pup)   # true — the contract accepts Dog and its descendants
(pup .Eq:eq dog)   # true — the inherited contract still accepts Dog
```

An inherited result `: Self` declared on `Dog` promises `Dog`, even when its
body returns the actual `Pup` receiver. It does not promise preservation of every
future subtype. `Self` denotes ordinary nominal admission, not exact runtime
type identity. Outside a receiver-bearing declaration or protocol-template
context, it is invalid. `Self:msg` remains separate type-direct message syntax;
it is never substituted with a concrete type name.

Type-direct replacements require `^^override` on the message. For protocol
implementations, `^^override` belongs on the impl and means “inherit ancestor
bodies, replacing the supplied messages.” Omitted messages prefer inherited
bodies over protocol defaults. A complete impl without the flag supplies its
closure from local bodies and protocol defaults, without borrowing ancestor
bodies. Both modes preserve inherited conformance bindings and exact callable
signatures. Newly supplied replacement signatures name inherited types explicitly
and cannot use contextual `Self`; body-local annotations may still use the new
receiver declaration's `Self`.

```gene
(impl Eq for Pup ^^override
  (message eq [other : Dog] : Bool
    (== self/name other/name)))
```

The flag must be a literal boolean; `^^override` is sugar for `^override true`.
False means the same as omission. An inheriting impl requires an applicable
ancestor message provider. Flags on individual protocol messages, enclosing
types, or protocol declarations are errors. Universal protocol requirements and
defaults cannot depend on abstract `Self` in the MVP because their fallback has
no introducing receiver binding. See `docs/self-type.md` for the full
assembly, readiness, and migration rules.

The legacy form that names the receiver explicitly as the first parameter
(`[self …]`) is still accepted during migration, but `self` may not be rebound
anywhere inside a message or `ctor` body — nested functions and pattern bindings
included. On a new message, `[self : Self]` has the same callable shape as
`[self]`. Its source annotation is retained for validation: the `Self` spelling
is forbidden in a newly supplied replacement signature, including this legacy
receiver position.

Message dispatch is on the first argument's head/type. Messages are ordinary callable values, but their names are **not** bound in the enclosing lexical scope — a message is reached with a send, or as a qualified member of its protocol (`docs/core.md §1/§9`):

```gene
(item .to_html)          # send: to_html resolves in item's context
(item .ToHtml:to_html)   # qualified send: always unambiguous
(var render ToHtml:to_html)
(render item)             # a held message value applies to its first argument
```

The direct head spelling `(ToHtml:to_html item)` is the qualified send
`(item .ToHtml:to_html)`. `ToHtml` identifies a protocol message; the receiver's
runtime type and visible implementations determine dispatch. Concrete types
remain invalid qualifiers; explicit parent delegation uses `super`.

A type can require manual implementations:

```gene
(type MenuItem
  ^props {^name Str ^price Int}
  ^impl [ToHtml])
```

The compiler checks that an `impl ToHtml for MenuItem` exists.

An implementation may also be written inline in the type body, with the
receiver implied (`docs/core.md §8`):

```gene
(type MenuItem
  ^props {^name Str ^price Int}
  (impl ToHtml
    (message to_html [self] : Node
      `(tr (td %self/name)))))
```

A type can request generated implementations:

```gene
(type MenuItem
  ^props {^name Str ^price Int}
  ^derive [Clone ToJson HasLabel])
```

For each item in `^derive`, the compiler resolves the protocol and invokes that protocol's `derive` form.

Derive items may carry options:

```gene
(type User
  ^props {^name Str ^password Str}
  ^derive [(ToJson ^skip [password])])
```

Protocol-local derive:

```gene
(protocol HasLabel
  (message label [] : Str)

  (derive [t : Type, req]
    `(impl HasLabel for %t
       (message label [self] : Str
         ($to_str self/name)))))
```

`derive` is a protocol-local compile-time special form. It receives the target `Type` value and the request node. It returns one or more declarations, usually an `impl`.

Generated declarations are placed in a compiler-owned overlay. Source modules are not mutated. Generated nodes receive provenance meta such as `@derived_by`, `@derived_for`, and `@derived_from`.

Any module may declare an implementation for any protocol and receiver type,
but **where the impl is written decides who can see it**
(`docs/scoped-impls.md` is the full design). There are three impl classes:

- **Canonical** — a static top-level impl in the protocol's or the receiver
  type's home module, including inline impls and successful top-level
  `^derive` results (they live with the receiver). While a module runs, its
  impls are staged in its module scope; at successful completion the batch is
  conflict-checked and published atomically to the shared application
  registry, becoming visible in every loaded module. A failed or conflicting
  module publishes none of its staged impls.
- **Scoped** — a static top-level impl outside both homes. It is visible only
  in its defining module. `^export true` makes it importable, and
  `(import_impl P for T from "path")` copies exactly that pair into the
  importing module's base scope; there is no aliasing, renaming, or
  re-export. Canonical impls cannot be exported.
- **Overlay** — an impl with computed operands, under control flow, inside a
  callable, or in an eval/REPL unit. It is visible only in its capturing
  lexical scope and is never exportable or canonical. A top-level impl with a
  computed protocol or receiver operand draws a compiler diagnostic naming
  the non-static operand, because the form silently loses cross-module
  visibility.

Impls are not value bindings — they cannot be renamed or selectively imported
through `[name]` lists. Coherence is checked where impls become visible: at
most one impl may be active for a `(protocol, receiver)` pair within one
visibility scope; identical re-registration through another module path is
idempotent; and an impl of a child protocol conflicts with an impl of its
ancestor at the same receiver because it supplies the inherited message
identities. A pair with no visible impl is a missing-implementation error at
the use site. Generated implementations follow the same rules, and MVP
rejects overlapping generic implementations that could both apply to the same
concrete receiver type.

A protocol message is always sent qualified — `(x .P:m)` — so the send names one
message identity and no compile-time candidate set is involved. Impl selection
happens at dispatch time and is filtered to impls applicable in the send's own
module: a library send cannot see a scoped impl imported only by its caller.
Within that identity, the nearest applicable receiver on the parent chain wins.
Unqualified sends never reach a protocol impl (§3), so they cannot be ambiguous
across protocols.

`eval` and Env-backed REPL impls stay in their eval overlay and are never
promoted to the application registry implicitly; there is no public
global-promotion operation in the MVP. Each successful application-level
activation advances an impl-registry epoch; native/direct protocol-call
optimization must guard that epoch (and deopt/re-resolve on mismatch) before
it may cache an impl address across activation.

**Dispatch cost and the call-site cache.** A qualified send costs more than a
plain call, and this cost is budgeted, not incidental: it walks the send scope's
parent chain, scanning each scope's impls for the nearest applicable receiver on
the parent chain. The sanctioned optimization is a **per-call-site inline cache**
keyed by `(receiver runtime type, message identity, activation epoch)`: a hit
returns the cached callee after a guard comparison; any key mismatch — a new
receiver type or a bumped impl epoch — re-resolves and refills. The cache is side storage indexed by call site, never
a field widening the instruction stream (that layout is bench-protected). Until
that lands, static-typed receivers and qualified sends resolve with less work,
so hot paths that must minimize dispatch cost should type their receivers.
`docs/core.md §9.1` states the same expectation for the receiver-first tier.

MVP restrictions:

- protocol-local `derive` may generate `impl` declarations for any resolvable
  protocol, but only targeting the deriving type;
- deriving outside the type's defining module is not allowed;
- a manual impl and generated impl for the same `(protocol, type)` pair is an error;
- generated impls are type-checked normally.

Protocol inheritance (`^inherit`), type-direct messages, type/protocol
inheritance interaction, and dot-send resolution semantics are designed as
an extension of this section in `docs/core.md`.

### 10.1 Implementation visibility and imports

The exact rule for when an impl is visible for dispatch and coherence lookup
(`docs/scoped-impls.md` §4 is the full design):

```text
canonical   home-module impl: activates atomically when its defining
            module finishes loading, then visible in every module.
scoped      static top-level impl outside both homes: visible in its
            defining module; `^export true` plus an explicit
            `(import_impl P for T from "path")` copies exactly that
            pair into the importer's base scope.
overlay     computed/conditional/local/eval impls: visible only in the
            capturing lexical scope.
A module's base scope = all canonical impls from loaded modules,
plus its own scoped impls, plus explicitly imported scoped impls;
active lexical overlays join that pool. Layers decide membership,
never precedence.
At most one impl per `(protocol, receiver)` pair may be visible in
any one scope; a conflicting registration fails at assembly or
activation without publishing its batch. Identical re-registration
through another module path is idempotent, never a conflict.
A pair with no visible impl is a missing-implementation error at
the use site.
Impls are not value bindings: no renaming, no selective import
through `[name]` lists, no re-export. Ordinary imports never import
scoped impls; only `import_impl` does. Loading a module is what
activates its canonical impls.
```

Dispatch uses the module containing the send, not the caller's module —
behavior that must cross a module boundary belongs in a canonical impl;
otherwise pass the produced value or an explicit callback. Conformance
checks (`x : P` typed boundaries, protocol-typed props, `(List P)`
elements) use the declaration scope's visibility, so protocol-typed data
crossing modules normally needs canonical conformance. Reload rebuilds the
canonical registry and importer state transactionally
(`docs/scoped-impls.md` §6). This model subsumes the earlier ideas of an
orphan rule and impl-import controls; future versions may still add
`^private`, explicit export lists, and package-private visibility.

---

### 10.2 Delegation

Delegation is composition-based behavior reuse: an outer value implements a protocol by forwarding one or more messages to an inner value selected by a path.

Manual delegation is just an ordinary `impl`:

```gene
(type LoggedDb
  ^props {^inner Db ^log Logger})

(impl Query for LoggedDb
  (message query [self sql]
    (self/log .Logger:info $"query: ${sql}")
    (self/inner .query sql)))
```

This is preferred over broad inheritance for wrappers, adapters, caches, logging, authorization, and resource decorators. Inheritance answers “is a”; delegation answers “has a value that does this behavior.”

Delegation should remain explicit. Gene should not use dynamic “method missing” forwarding as a core feature because it hides which protocols a type implements and makes type checking, docs, native compilation, and coherence harder.

A derive helper may generate forwarding impls:

```gene
(type BufferedReader
  ^props {^source Reader ^buffer Buffer}
  ^derive [(Delegate ^protocol Reader ^to /source)])
```

Such a helper expands to a normal `impl Reader BufferedReader` whose messages forward to `self/source`. This keeps delegation homoiconic, selector-based, and compatible with the existing protocol/derive system. Delegation is not an MVP special form, but cross-protocol derive (§11.4) now supports writing a `Delegate`-style helper as an ordinary library protocol: its `derive` returns an `impl` of the delegated protocol targeting the deriving type.
