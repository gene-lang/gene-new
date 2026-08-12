# Capability propagation and attenuation

Status: proposal

## 1. Summary

Gene should model authority as an inherited, immutable capability context.

The trusted host creates the root grants. The application entry point selects
the authority the application may receive. Modules, functions, methods,
protocol messages, and individual call sites may select a smaller context.
Nothing below the host boundary can create authority or recover authority that
an ancestor removed.

The surface convention is:

```gene
(fs/WriteDir "*")
```

Here:

- `fs` is the namespace.
- `WriteDir` is a capability type.
- `"*"` is an argument interpreted by `fs/WriteDir`.

Capability types may also define named properties:

```gene
(fs/DoSomething ^prop value)
```

Declarations use a list of capability selectors:

```gene
^capabilities [
  fs/*
  (fs/WriteDir "tmp")
  (device/Compute ^^optional)
]
```

`fs/*` is a projection of the parent's current context. It means “inherit
the filesystem grants my parent has made available,” not “grant every
filesystem capability supported by this runtime.”

This gives application developers control in two especially important places:

1. The entry declaration establishes the application's capability ceiling.
2. A call site can further tighten the context before invoking less-trusted
   code.

The runtime remains the enforcement boundary. Declarations make the policy
visible and compositional; unforgeable grants and native adapters make it
real.

## 2. Design goals

The design should:

- make required authority visible on modules, functions, methods, protocol
  messages, and entry points;
- let the host and application entry point establish explicit ceilings;
- support safe inheritance without repeating every capability name;
- let call sites attenuate authority for a particular call or block;
- support capability-specific positional arguments and named properties;
- distinguish mandatory capabilities from optional enhancements;
- prevent source code from manufacturing or widening authority;
- let standard-library functions declare and enforce their own requirements;
- support scoped resources such as one directory, host, device, or database;
- preserve useful static checks without relying on them for security;
- keep capability-free calls and hot scalar paths inexpensive;
- remain usable in native, embedded, test, and WASM runtimes.

This proposal does not attempt to make ambient host facilities safe after they
have been exposed outside the capability system. Native code, foreign
functions, and standard-library adapters must participate in enforcement.

## 3. Core model

### 3.1 Capability type

A capability type describes one family of authority and owns the rules for
interpreting its arguments and properties.

Examples include:

```gene
fs/WriteDir
fs/WriteFile
fs/ReadFile
net/Connect
clock/Monotonic
device/Compute
```

A capability type is not an ordinary constructible Gene type. Calling a
capability type never mints a grant. It creates an inert *specification* and
resolves that specification only against the inherited context.

For example, `fs/WriteDir` may entail a particular
`fs/WriteFile` operation when the resolved file is safely beneath the
granted directory and the requested write mode is allowed.

### 3.1.1 The `CapabilitySpec` protocol

Capability types are **open**. Any type may become one by implementing an
ordinary Gene protocol:

```gene
(protocol CapabilitySpec
  (message canonicalize [] : CapabilitySpec)
  (message attenuate [requested : CapabilitySpec] : CapabilitySpec?)
  (message describe [] : Str))
```

```gene
(impl CapabilitySpec for WriteDir
  (message canonicalize [] ...)
  (message attenuate [requested] ...)
  (message describe [] ...))
```

Conformance is **explicit**, never structural. A type that happens to define
a method named `attenuate` does not become a capability type. Explicit
conformance means the compiler can validate it, dispatch goes through
qualified protocol messages, and no type acquires capability semantics by
accident.

Only `canonicalize` and `attenuate` are required. `describe` has a default
implementation deriving a string from the canonical specification form.

Deliberately **not** in the protocol:

- **`subsumes`.** A successful `attenuate` already answers "does the
  inherited authority satisfy this request?". Two oracles for one question
  can disagree, and a disagreement between them is a security hole, not a
  bug. Everywhere this document previously said "subsumption" — including
  the protocol-implementation check in §5.5 — the answer now comes from
  `attenuate`.
- **`intersect`.** Same reason: it is `attenuate` under another name.
- **`fs/*` and `^optional`.** These are runtime-level composition over a set
  of specifications, not questions any single specification can answer. They
  stay in the capability system, which keeps the protocol small.

### 3.1.2 Direction and meaning of `attenuate`

The argument order is load-bearing and easy to get backwards:

```text
inherited.attenuate(requested) -> effective | nil
```

- `self` is the **inherited** specification — what the parent context makes
  available.
- `requested` is what the child boundary asks for.
- The result is the **effective** specification, conferring no more authority
  than `self`.
- `nil` means the request is not satisfiable from this inherited
  specification. It is a denial, not an error.

`attenuate` must be **total**: it returns `nil` rather than raising for an
unsatisfiable request. Raising is reserved for a malformed specification and
surfaces as `CapabilityTypeError`.

### 3.1.3 Laws

Implementations must satisfy these. They are checkable by property test and
belong in any capability type's test suite:

```text
canonicalize produces a transitively immutable snapshot:
  the result contains only deeply immutable, non-authority-bearing data

canonicalize is pure, total, deterministic, and idempotent:
  canonicalize(canonicalize(x)) == canonicalize(x)

attenuate never widens:
  attenuate(a, b) is nil, or confers no more authority than a

attenuate is transitive:
  attenuate(attenuate(a, b), c) confers no more than attenuate(a, c)

equivalent specifications canonicalize identically:
  they must be indistinguishable to context keying and fingerprinting

neither message performs I/O, mutates state, captures authority,
or depends on the active capability context
```

**Transitive immutability is a cache-soundness requirement, not value
hygiene.** Context identity, hash-consing, interface fingerprints, transition
caches (§13.2), and provider validation all assume a canonical specification
cannot change after insertion. Freezing the top level is not enough: a
specification retaining a mutable list, object, or closure can be mutated
afterwards, changing the apparent policy while the context ID and capability
epoch stay identical. Every cached transition derived from it is then wrong,
and nothing invalidates them.

So a canonical specification, and any value bound into a deferred selector
constraint (§13.3), must be a **deep immutable snapshot** — or, more simply,
be restricted to a canonical data representation that admits only immutable
scalars, strings, and immutable collections of the same. Mutable or
authority-bearing values are rejected at canonicalization rather than
copied.

### 3.1.4 Resolution flow

```text
1. (fs/WriteDir "tmp") constructs an inert specification. No authority yet.
2. The runtime verifies the type explicitly implements CapabilitySpec.
3. canonicalize validates and freezes it.
4. attenuate proposes a requested narrowing of the inherited specification.
5. The type's *trusted provider* validates that request against the parent's
   sealed grant and mints a new sealed derivative grant, or refuses.
6. The child context holds the derivative grant. The adapter enforces
   against that derivative, not against the host root.
```

Steps 5 and 6 are the crux: user code proposes, trusted code disposes. §3.2.2
explains why the alternative — keeping only the host grant and re-checking it
— fails to preserve `child <= parent`.

### 3.2 Capability grant

A capability grant is an unforgeable runtime value created by trusted host or
runtime code. It contains or references the authority needed to perform an
operation.

### 3.2.1 Specifications are open; grants are sealed

This is the separation that makes an open protocol safe:

| | `CapabilitySpec` | `CapabilityGrant` |
| --- | --- | --- |
| who creates it | anyone | trusted host/runtime only |
| forgeable | yes, freely | no |
| carries authority | **no** | yes |
| extensible by user libraries | yes | no |
| role | describes and narrows | *is* the authority |

Implementing `CapabilitySpec` therefore cannot mint authority, cannot change
which grant a specification is attached to, and cannot reinterpret an `fs`
grant as some other type. Built-in native adapters accept only grants issued
by their own trusted provider.

### 3.2.2 The checked ceiling must advance at every boundary

The laws in §3.1.3 are obligations on implementers, and an open protocol
means some implementation will violate them — by accident or on purpose. The
design must be safe anyway.

**An earlier draft of this section got this wrong**, and the error is worth
recording because it is the natural thing to believe. It argued that keeping
the inherited *host* sealed grant and re-checking it in the adapter bounds a
hostile `attenuate`. That only establishes:

```text
effective authority <= the host's original grant
```

The invariant actually required by §3.5 is `child <= parent`. Those differ,
and the gap is exploitable in one deterministic implementation — no
replacement of a built-in is needed:

```text
1. host sealed grant is  /
2. entry correctly attenuates to  /tmp
3. a later buggy attenuate receives /tmp and returns /
4. adapter checks against the host grant / and permits
```

The child has recovered authority the entry removed. A ceiling that never
advances past the host root is not a ceiling.

**The rule: every attenuation boundary must produce a new sealed derivative
grant, and the adapter checks against the nearest one, not the root.**

The consequence for the open protocol is the important part:

> A user-supplied `attenuate` may *describe* a requested narrowing. It can
> never be the *proof* that the narrowing is sound.

So narrowing is a two-party operation:

```text
user code:          proposes a requested specification via attenuate
trusted provider:   validates the request against the *parent's effective
                    grant*, and mints a new sealed derivative grant
```

The provider for a capability type is trusted code that owns the resource —
the filesystem provider for `fs/*`, the host for its own grants. It is the
only thing that mints, and it validates against the parent's derivative
grant, so each boundary's ceiling is at or below the previous one by
construction rather than by user cooperation.

Given that, a hostile `attenuate` can request anything it likes; the provider
refuses to mint a derivative broader than its input, and:

```text
grant(child) <= grant(parent) <= ... <= grant(host)
```

holds at every level regardless of user code, which is what §3.5 needs.

Two viable alternatives to provider-minted derivatives, if minting proves too
costly: the adapter carries an immutable chain of every ancestor constraint
and checks all of them, or the context stores the parent's effective
specification and a trusted per-type narrowing operation validates the
user-produced specification against it. All three share the same essential
move — the trusted side, not the open protocol, decides whether a narrowing
is legitimate.

This is a load-bearing change to the model, and it must be settled before
runtime representations are chosen, because it decides what a context and a
grant have to contain.

**Advisory capability types are deferred from version 1.** A type with no
sealed grant and no provider — a pure-Gene `app/PublishTopic` enforced only
by library code reading the effective specification — does not fit the model.
A `CapabilityContext` maps a type ID to a *grant* (§3.4), and such a type has
none, so the design would have to say what context entry holds it, who seeds
it into the root context, and how it propagates without letting a freely
constructible specification insert itself as authority. Treating it as
grant-shaped while repeatedly saying it is not a grant leaves resolution and
reflection underspecified even where no security claim is made.

Version 1 therefore requires **every capability type to have a registered
provider** (§3.2.3). The protocol stays open in the sense that matters — a
library may add a capability type — but it adds a type *together with* a
provider, so the trusted surface grows deliberately.

If advisory types are wanted later, the shape is an explicit context-entry
sum type:

```text
ContextEntry = SealedGrant(provider, grant)
             | AdvisoryPolicy(spec)
```

with trusted rules for seeding and inheritance of the advisory arm, and
reflection (§11) reporting which arm a row came from so a reviewer can tell
an enforced contract from a documented one.

A filesystem grant should ultimately be backed by a trusted root handle and a
rights mask, not merely by a source-visible path string. A network grant may
hold an endpoint policy. A compute grant may hold a queue or device handle.

Two grants of the same capability type may coexist. For example, an entry
context may contain separate writable roots for `tmp` and `output`.

### 3.2.3 The capability provider contract

Once narrowing is provider-proved (§3.2.2), the provider — not
`CapabilitySpec` — is the security interface. `CapabilitySpec` is its
*request language*. The provider is trusted code owning a resource, and it
must supply four operations, not the single minting step §3.2.2 describes:

```text
derive(parent_grant, requested_spec) -> child_grant | denial
    Mint a sealed derivative of the SAME type, no broader than
    parent_grant, or refuse.

entail(parent_grant, requested_spec_of_other_type) -> child_grant | denial
    Cross-type derivation: mint a grant of the requested type from a
    grant of a related one. This is what makes an fs/WriteDir grant
    satisfy an fs/WriteFile selector.

meet(grant_a, grant_b) -> grant | empty
    The trusted intersection of two grants. When the two are of related
    but different types, the caller entails both to a common type first;
    a provider is never asked to meet types it does not own.

authorize(grant, operation) -> proof | denial
    Validate a concrete operation against a grant. The final boundary.

subsumes(spec_a, spec_b) -> yes | no | unknown
    NON-AUTHORIZING, static. Does spec_a's authority cover spec_b's, for
    every grant either could resolve against? Mints nothing and touches
    no grant, so the compiler can call it. Three-valued: `unknown` is a
    rejection at an interface boundary, never an assumption of safety.

provenance(grant) -> identity + revocation dependency set
    Stable grant identity, and the set of revocation dependencies this
    grant's validity rests on. Exposes no secrets. Used by fingerprints
    (§5.3), epochs (§13.2), revocation (§13.3), and diagnostics (§11).
```

**Revocation propagates through the whole lineage.** Every boundary mints a
derivative, `entail` mints a grant of a different type, and `meet` mints one
depending on two inputs — so a grant's validity is not a property of that
grant alone. A single self-generation is insufficient: revoking an ancestor
would leave a descendant's own generation unchanged, and a cached proof
against the descendant would still pass. `meet` is worse, since revoking
*either* operand must invalidate the result.

The normative rule:

```text
every derived, entailed, or meet grant carries the revocation
dependencies of all its ancestors, and validating a proof checks the
whole dependency set — not just the grant it names
```

Implementations may realize this as shared lineage tokens, composite
generations, or provider callbacks. §20 may defer the *representation*; it
may not defer this requirement.

**Who owns a cross-type edge.** `entail` is implemented by the provider that
owns the **source** grant, and it may only mint a grant of a type that same
provider owns. `fs/WriteDir -> fs/WriteFile` is legal because one filesystem
provider owns both. A cross-*provider* edge — an `app` grant minting
something the `fs` adapter would accept — is forbidden by default, since it
would let one provider manufacture authority another adapter honours. Where
such an edge is genuinely wanted, the **target** provider must explicitly
register acceptance of the source provider; the source cannot claim it
unilaterally.

**Why `subsumes` is separate from `attenuate`.** §3.1.1 removed `subsumes`
from the open protocol because a second oracle can disagree with `attenuate`.
That reasoning applies to *untrusted* code. Here the provider is the single
authority, so its `subsumes` and its `derive` cannot disagree — they are the
same trusted component. The compiler needs an operation that answers a
question about two *specifications* without a parent grant to mint from,
which `derive` structurally cannot do.

**`meet` is not optional, and identity comparison cannot replace it.** Two
places already require intersecting authority rather than selecting from a
set:

- §6.1 intersects the caller's context with the enclosing module ceiling;
- §6.4.1 intersects a callback's attached context with the invoker's;
- §10.2 intersects a resource's originating grant with the active context.

Two grants may be independently derived from the same root and overlap
without either being an ancestor of the other — `/tmp/a` and `/tmp` derived
along different paths, say. Set intersection by grant identity finds nothing
there and would silently yield an empty context, or worse, pick one. Only the
provider can decide what the overlap actually is, and mint it.

A capability type without a registered provider cannot participate in the
model. This is what makes the protocol open in a useful sense: a library adds
a capability type *together with* a provider, and the trusted surface grows
deliberately rather than by anyone implementing two messages.

This contract must be settled before `CapabilityGrant` and `CapabilityContext`
representations are chosen, since it determines what they must contain.

### 3.3 Capability selector

A capability selector describes authority to be inherited from the current
parent context. It may select a whole namespace, a capability type, or a
capability-specific subset.

```gene
fs/*
fs/WriteDir
(fs/WriteDir)
(fs/WriteDir "*")
(fs/WriteDir "tmp")
(fs/WriteFile filename)
(net/Connect ^host "api.example.com" ^port 443)
```

Selectors do not create grants. Resolution computes a subset or attenuation of
the parent grants.

### 3.4 Capability context

A capability context is an immutable collection of grants available to the
currently executing code.

Conceptually:

```text
CapabilityContext =
  CapabilityTypeId -> zero or more CapabilityGrant
```

The actual representation should use interned IDs and compact immutable
storage. The conceptual multimap matters because a process may hold more than
one scoped grant of the same type.

The active capability context is runtime execution state. It must not be an
ordinary mutable lexical map and must not be writable through dynamic
variables.

### 3.5 Authority is monotonic downward

For every boundary:

```text
child_context <= parent_context
```

`<=` means every child grant is either:

- the same unforgeable grant as one available to the parent; or
- an attenuation proven by the owning capability type to confer no more
  authority.

No module declaration, function declaration, message implementation, macro,
or call-site form can violate this invariant.

Because capability types are open (§3.1.1), "proven by the owning capability
type" needs care: `attenuate` is user-supplied code and may be wrong. The
invariant holds because the *provider*, not the protocol implementation,
mints every derivative grant (§3.2.2):

```text
grant level          enforced by construction — each boundary's sealed
                     derivative is minted by the trusted provider from the
                     parent's derivative, so the checked ceiling advances
                     downward at every step

specification level  an obligation on the implementer (§3.1.3) — a wrong
                     attenuate produces a request the provider refuses, so
                     it can cause denial but not widening
```

The security invariant is the first. The second is what makes declarations
*meaningful* rather than merely safe. Version 1 requires every capability
type to have a provider (§3.2.2), so both levels always exist; a provider-less
advisory type would have only the second, which is why it is deferred.

## 4. Selector syntax

### 4.1 Declaration rows

`^capabilities` accepts three shapes. All three mean the same thing after
normalization — a list of selectors:

```gene
^capabilities *                      # inherit everything available

^capabilities (fs/WriteDir "tmp")    # one selector, no list needed

^capabilities [                      # the general form
  fs/*
  (fs/WriteDir "tmp")
  (device/Compute ^^optional)
]
```

A bare `*` is the whole-context projection: inherit every grant the parent
makes available. It is the natural companion to `fs/*` and carries the same
review consequence as any wildcard (§4.3) — more so, since it spans
namespaces. Static analysis should warn on `*` at a public boundary, and the
entry module should be discouraged from using it, since the entry's whole
job is to choose a ceiling.

This document spells the optional marker `^^optional` throughout. Gene's
`^^flag` sugar means exactly "this property, set to true"; the long form
`^optional true` is the same property, but a security contract should not
present two spellings.

A declaration is a list of selectors:

```gene
(fn generate_report
  [source output]
  ^capabilities [
    (fs/ReadFile source)
    (fs/WriteFile output)
    (device/Compute ^^optional)
  ]
  ...)
```

An exact selector is mandatory by default. If no inherited grant satisfies it,
the boundary fails before the body runs.

The common property `^^optional` marks an exact selector as optional:

```gene
(device/Compute ^^optional)
```

If no inherited grant satisfies an optional selector, it contributes no grant
to the child context. Code may query the selector and receive `nil`.

`^optional` is interpreted by the capability system. All other arguments
and properties are passed to the named capability type.

### 4.2 Bare, empty, and wildcard forms

In a capability-selector position, these forms are equivalent:

```gene
fs/WriteDir
(fs/WriteDir)
(fs/WriteDir "*")
```

They mean “select all currently inherited grants that satisfy the default
`fs/WriteDir` scope.” For `WriteDir`, the default scope is every writable
directory available from the parent context.

This equivalence is capability-type-defined. `"*"` is passed to
`fs/WriteDir`; it is not a universal parser feature. The type declares that
no argument and `"*"` have the same meaning.

Outside a selector position, `fs/WriteDir` evaluates to the capability-type
descriptor. Calling it resolves against the current context; it still cannot
create authority.

### 4.2.1 Selector positions construct specifications automatically

Inside a capability-selector position the capability system applies special
handling, so a declaration reads as data rather than as calls:

- A bare capability type is its own empty application:
  `fs/WriteDir` becomes `(fs/WriteDir)`.
- An applied form `(fs/WriteDir "tmp")` invokes the type's canonical
  constructor (its `ctor`, or the type's declared canonical constructor)
  automatically, producing an inert specification. The author does not write
  a construction call, and the form never evaluates as an ordinary function
  application in this position.
- The resulting value is then passed through `canonicalize` (§3.1.1).

A capability type's canonical constructor *is* program logic, so this does not
by itself make declaration processing safe — it makes it well-defined. What
bounds it is §4.6.1's trust boundary: native compiler-owned constructors for
adapter-backed types. `^optional` is consumed by the capability system before the
type sees its arguments; everything else is the type's own vocabulary.

### 4.3 Namespace projection

```gene
fs/*
```

selects every grant in the parent context whose capability type belongs to the
`fs` namespace.

It has three important properties:

- It may select zero grants without causing a missing-capability error.
- It does not enumerate the runtime's capability catalog.
- It cannot select a grant that the parent context does not contain.

Therefore installing a new filesystem provider or adding a new capability
type to the runtime does not silently give old code new authority. The new
grant must first be admitted by an ancestor, normally the host or entry
policy.

There is still an intentional review consequence: a component using `fs/*`
will inherit a new filesystem grant if an ancestor later adds that grant.
Code requiring a stable, minimal surface should name exact selectors instead.

Namespace wildcard syntax has this projection meaning only in capability
selector positions such as `^capabilities` and `with_capabilities`. Its
meaning in import syntax remains separate.

### 4.4 Arguments and properties

The capability type owns its argument vocabulary:

```gene
(fs/WriteDir "tmp")
(fs/WriteFile filename ^append true)
(net/Connect ^host "api.example.com" ^port 443)
(fs/DoSomething ^prop value)
```

Arguments narrow a parent grant. They cannot broaden it. If an argument names
a directory outside every inherited root, resolution fails.

Properties should describe policy, not implementation accidents. Filesystem
types might support properties such as:

```gene
(fs/WriteFile filename
  ^append false
  ^create true
  ^follow_symlinks false)
```

The type validates unknown, duplicate, and ill-typed properties before
execution.

### 4.5 Parameter-dependent selectors

A function selector may refer to its parameters:

```gene
(fn write_file
  [filename content]
  ^capabilities [(fs/WriteFile filename)]
  ...)
```

This is more precise than:

```gene
^capabilities [fs/WriteFile]
```

The coarse form says the function may write any file allowed by the inherited
filesystem grants. The parameter-dependent form says it may write this
particular file.

Both forms are useful. Standard-library adapters should prefer the precise
form when their arguments make it practical.

Requirement expressions are deliberately restricted. They may contain:

- a capability type;
- literals;
- references to already-bound parameters or `this`;
- type-owned positional arguments and properties.

They may not run arbitrary Gene code, perform I/O, or mutate state. Resolution
must be total except for a structured capability error.

### 4.6 What happens at compile time, and what cannot

The goal is that capability declarations cost nothing at runtime. Full
compile-time *resolution* is not achievable, and it is worth being precise
about why, because the reasons decide the performance design (§13).

**Resolution cannot happen at compile time.** A declaration is static, but
the context it resolves against is a runtime value:

- A function is compiled once and called from many contexts. Its child
  context depends on the caller's, which is not known at compile time.
- `with_capabilities`, task spawn, and host policy all produce contexts that
  exist only while running.
- Separately compiled and dynamically loaded modules (`gene runurl`, plugins)
  are compiled without their eventual caller.
- Scoped and overlay protocol implementations mean the `attenuate` target for
  a user-defined type is not always statically known.
- §4.5's parameter-dependent selectors name runtime values by construction.

**Running `canonicalize` in the compiler is also not free.** It requires the
capability library to be loaded and its implementation available during
compilation, and it executes user code in the compiler. That is acceptable
only under the purity and totality laws (§3.1.3), enforced per §12, and under
a separate compile-time context (§14). Where an implementation is not
available at compile time, canonicalization is deferred to first use and
memoized.

What compile time genuinely delivers is the *static half* of the work, and
then a runtime design that makes the dynamic half nearly free.

There are three distinct stages, and conflating them is what made an earlier
draft claim that `(fs/WriteFile filename)` is canonicalized at compile time.
It cannot be: `filename` has no value then, and emitting its slot index does
not supply one.

**Stage 1 — compile time, for every declaration.** Operates on a *symbolic
selector template*, not a concrete specification:

- parse the row and separate `^optional` from type-owned arguments;
- validate arity, property names, and unknown-type errors against the type;
- reject a type that does not explicitly implement `CapabilitySpec`;
- intern the capability type and namespace to compact IDs;
- canonicalize the *template*, including any fully literal arguments;
- emit a flat descriptor with parameter references as slot indices.

A row with only literal arguments is fully concrete here, and construction
plus `canonicalize` can run at compile time subject to §4.6.1. A row naming a
parameter stays symbolic.

**Stage 2 — runtime binding, only for parameter-dependent rows.** Bind slot
values, run the canonical constructor and `canonicalize` on the now-concrete
arguments, and match against the active context. This is the constructor and
canonicalization work that stage 1 could not do.

**Stage 3 — operation time.** Construct the proof for a deferred constraint
(§13.3), if the operation is actually performed.

By the time a *static* row runs there is no parsing, no property-map
building, no string comparison of type names, and no allocation.

**Interface fingerprints use the stage-1 symbolic template.** A
runtime-dependent specification has no concrete canonical form at compile
time, so a fingerprint must be over the template and its slot references —
not over a pretended concrete value.

### 4.6.1 Compile-time execution needs a real trust boundary

Saying `canonicalize` is "pure and total by protocol law" is a statement of
intent, not an isolation mechanism. A user type's canonical constructor and
protocol methods are ordinary program logic. Totality is undecidable in
general, and a capability-free compile-time context prevents host I/O but not
nontermination, memory exhaustion, mutation of compiler-visible state, or
nondeterminism. A static checker can reject obvious violations; it cannot be
the security argument.

Pick a concrete boundary per capability type:

- **Adapter-backed types**: canonicalization and the canonical constructor
  are **native, compiler-owned** code. No user logic runs in the compiler for
  the types that are actual security boundaries. This is the default and
  covers all built-ins.
- **Provider-supplied custom types**: the provider registers a canonicalizer
  along with the type (§3.2.3). It is trusted by the same act that made the
  provider trusted, so no isolation machinery is needed — but a provider
  that supplies a non-terminating canonicalizer degrades the compiler, so
  registration should require it to be native or to run under instruction and
  memory limits with denial on breach.
- Where a canonicalizer is not available at compile time, defer
  canonicalization to first use and memoize it. Deferral is always sound; it
  costs one resolution.

The canonical constructor is subject to exactly the same restrictions as
`canonicalize` and `attenuate`. §12 previously named only the latter two.

An entirely static row (`fs/*`, `(fs/WriteDir "tmp")`) compiles to a
descriptor naming a *context transformation*. It still has to be applied to
whatever context the caller supplies, but §13.1 makes that a cache hit rather
than a resolution. A parameter-dependent row costs a presence check at entry
and defers the expensive part to the operation (§13.2).

**Built-in types must not pay protocol dispatch.** `CapabilitySpec` is the
*extension* mechanism, not the hot path. Runtime-provided types implement
`canonicalize` and `attenuate` natively, and the runtime calls those
directly; the protocol exists so user libraries can join the system on equal
terms, not so that every filesystem check becomes a dynamic send. A security
boundary should not depend on inline-cache behaviour for its cost profile.

**Compile-time execution is itself capability-relevant.** Running
`canonicalize` at compile time means user code from an imported capability
library executes in the compiler. §14 already requires a separate
compile-time capability context; the purity and totality laws in §3.1.3 are
what keep that execution safe, and they should be enforced rather than
assumed — see §12.

## 5. Where capabilities are declared

### 5.0 Normative defaults

An omitted `^capabilities` row and an explicit empty one are **different**,
and the default differs by boundary. Earlier drafts left this implicit and
contradicted themselves: §5.2 said omission means an empty context, while
§13.1 requires a non-declaring function to touch nothing, which necessarily
means it inherits its caller's context.

| boundary | row omitted | `^capabilities []` |
| --- | --- | --- |
| entry module | **empty context** | empty context |
| imported module | **empty context** | empty context |
| function / method | **caller ∩ defining module ceiling** | empty context |
| protocol message | **caller ∩ defining module ceiling** | empty context |
| `with_capabilities` | n/a — row required | empty context |

The function rule is an intersection, not plain inheritance. Plain
inheritance would break the invariant: a module declaring `^capabilities []`
could export a row-less function, and a broad caller would hand it the broad
context, defeating the module ceiling. A callee is always bounded by its
*defining* module's ceiling (§5.4, §6.1), so omission means:

```text
child = caller_context  ∩  defining_module_ceiling
```

Modules default to empty because a module boundary is a policy decision and
silence there should not grant anything. Functions default to inheritance
because the alternative is unworkable: if omission meant empty, every
ordinary helper call would have to save and clear the context, capability-
bearing code could not call an undeclared helper without losing its
authority, and §13.1's zero-cost property would be impossible.

**Functions are therefore effect-polymorphic on omission**, and one claim
elsewhere in this document must be read accordingly:

> An undeclared function may perform any effect its caller's context permits.
> Required authority is **not** visible in an undeclared function's
> interface.

A declaration on a function is a *narrowing*, not a disclosure. Visibility of
required authority is recovered by static analysis (§12) inferring an
effective requirement transitively, not by the declaration syntax alone. A
public API that wants an enforced, visible contract must declare a row;
tooling should be able to report undeclared effectful functions as such.

`^capabilities []` is the explicit way to drop all authority, and it is
never implied.

**Where the zero-cost promise applies.** §13.1's "touches nothing" claim is
now scoped to calls where the intersection is provably a no-op:

- **Intra-module calls are always free.** The active context inside a module
  is already at or below that module's ceiling, established when the module
  boundary was crossed, so intersecting again changes nothing. This is the
  overwhelming majority of calls.
- **Cross-module calls need the meet**, unless the compiler can prove the
  caller's context is already below the callee module's ceiling — which it
  can whenever both ceilings are static and one is contained in the other.
- When the meet is required, it is keyed on
  `(caller_context_id, callee_module_ceiling_id)` and cached exactly like
  §13.2's transition, so the steady-state cost is a compare and a load rather
  than a provider call.

So the zero-cost claim is precisely: *capability-free code within a module
boundary is byte-identical to today; a cross-module call into a
differently-ceilinged module pays a cached meet.* An unqualified version of
that claim is not compatible with enforcing module ceilings at all.

### 5.1 Runtime root

The embedding host creates the root capability context. This is the only
place application authority originates.

Examples:

- the CLI opens a directory and creates an `fs/WriteDir` grant;
- an embedding application supplies a restricted HTTP client;
- a test harness supplies an in-memory filesystem;
- a WASM host exposes only imported functions allowed by its policy.

Root grants must be created through trusted APIs. Parsing
`(fs/WriteDir ".")` from a command-line policy may be convenient, but the
launcher interprets that data and creates the grant. Evaluating the same form
in untrusted Gene source only resolves inherited authority.

### 5.2 Entry module

The entry module establishes the application-level ceiling:

```gene
(mod app
  ^capabilities [
    (fs/WriteDir "tmp")
    net/*
  ])
```

The entry row is resolved against the host root **by the host, when it
invokes `main`** — not when the module is loaded. Module loading and
initialization run under an empty context (§5.3), so there is no point during
loading at which the entry's ceiling could be materialized, and no authority
for top-level forms or imports to receive.

This is the main policy point controlled by the application developer. It
governs what `main` and everything it calls may do; it does not govern the
loading of the program.

For an entry or imported module, an omitted or explicitly empty
`^capabilities` row means an empty context. There is no implicit inherit-all
behavior at a module boundary. Functions differ — see the defaults table in
§5.0.

### 5.3 Imported modules

**A module row is an immutable selector template, not a context.** It is
never materialized at import time. Loading and initialization run under an
empty capability context, and importing brings in *definitions* without
transferring any authority:

```gene
(mod report
  ^capabilities [fs/*])
```

This says: whenever a function of `report` is called, its ceiling is the
caller's filesystem grants — resolved at that call, against that caller's
already-bounded context (§5.0, §6.1). It does not say the module holds
filesystem authority, and there is no moment at which it does.

That is what makes the singleton sound. Resolving a module's row against
"the context supplied by its importer" would be incoherent once
initialization is empty: there is no importer context at load time, and a
module imported by two differently-authorized callers would have to keep
whichever imported it first. As a template the question does not arise.

Adding capability identity to the module cache key is not merely cache
invalidation — it changes Gene's module instancing model. Today there is one
initialized instance per `<package_identity>::<module_path>`; keying on
context means one source module loaded under two contexts initializes twice.
That must be decided explicitly, because both answers have failure modes:

- **Duplicating** module-level types, protocols, and canonical
  implementations can break dispatch and conformance, since two structurally
  identical types would not be the same type.
- **Sharing** them, while duplicating mutable state, can leak authority
  captured during the broader initialization into the narrower instance.

Sharing types, protocols, and implementations while making mutable state
per-context does not fit this runtime: a module is one initialized scope,
function and message values close over it, and a shared function cannot close
over several per-context state instances without an implicit module-instance
parameter or cloned closures.

**Version 1 takes the simple option: module initialization runs under an
empty capability context.** A module's declared row is *metadata* — the
ceiling applied to its functions when they are called (§5.0) — not a context
its top-level forms execute under.

The alternative — initialize under the declared context, but forbid module
state from retaining authority — is not enforceable. A module can read a
protected file during broad initialization and store the returned **ordinary
string**: no grant retained, and a `Str` carries no origin a store check can
inspect. Catching that needs pervasive information-flow tainting, and the
same hole exists for environment variables and network reads.

Running initialization with an empty context closes the channel at its
source: there is no authority available to leak, so nothing needs to be
tracked. Consequences:

- There is exactly one runtime instance per
  `<package_identity>::<module_path>`, as today, and it is
  context-independent by construction. Gene's module and type identity
  semantics are unchanged, and the module cache key needs no capability
  fingerprint.
- The "which importer's ceiling does the singleton retain?" question
  disappears. It retains none: initialization had none, and each call into
  the module intersects with its declared ceiling at the call boundary.
- Effectful initialization — reading config at load time, connecting a pool —
  becomes an explicit function the application calls under a context it
  chooses. This is a real restriction, and it is the better discipline: the
  authority a module uses becomes visible at a call site instead of implicit
  in load order.
- Enforcement is trivial and needs no analysis: a capability-requiring
  operation attempted during module initialization simply finds an empty
  context and is denied, by the same mechanism that denies it anywhere else.

If effectful initialization is later required, the alternative is per-context
runtime module scopes with stable declaration and type identities across
them — not a store-site check.

If per-context module instances are wanted later, the shape is: share
compiled declaration identities, create per-context runtime module scopes,
and keep nominal type identity stable across them. Then a fingerprint becomes
necessary, and it must include **grant and provider provenance** (§3.2.3), not
only canonical visible selectors — two roots with the same selector shape but
different underlying grants must never share initialized authority-bearing
state.

### 5.4 Functions and methods

A function or method resolves its declaration against the caller's active
context:

```gene
(fn save
  [path content]
  ^capabilities [(fs/WriteFile path)]
  ...)
```

The body receives exactly the selected child context. It does not retain all
of the caller's grants merely because the caller had them.

Closures capture lexical values, not ambient capability authority. At
invocation, their capability declarations resolve against the caller's active
context and any narrower module ceiling.

### 5.5 Protocol messages and implementations

A protocol message can declare the authority callers must be prepared to
supply:

```gene
(protocol Persistable
  (message persist
    [destination]
    ^capabilities [(fs/WriteFile destination)]))
```

An implementation may use the same or narrower authority. It must not demand
authority broader than the public message contract.

Formally, for every valid parent context, an implementation's selected
context must be no broader than the public message's selected context.

For **fully concrete** selectors on an adapter-backed type, the check uses the
**provider's** trusted narrowing relation (§3.2.3), not `attenuate`:

```text
provider.subsumes(message_spec, impl_spec) must return `yes`
```

`subsumes` is the provider's non-authorizing static relation (§3.2.3). An
`provider.derive(message_spec_as_grant, impl_spec)` is not implementable in
its place: a specification is explicitly not a grant, and the compiler has no
parent grant to mint a derivative from. `unknown` is a rejection here, never
an assumption that the implementation is compatible.

Routing this through `message_spec.attenuate(impl_spec)` would be unsound.
§3.2.2 permits a hostile or buggy `attenuate`, and the provider is
authoritative over it, so a lying implementation could make the compiler
accept a capability contract broader than its protocol message. The provider
still refuses to widen at runtime — but callers receive denial where the
public protocol promised success, so substitutability breaks even though
nothing is over-authorized.

Static interface checking must consult the same authority that decides at
runtime. (If provider-less advisory types are added later, they have no such
authority, and tooling must report their compatibility result as unverified
rather than as a checked contract.)

**This does not generalize to parameter-dependent selectors.** "No broader
for every valid parent context" is universally quantified over runtime
arguments, and a single concrete `attenuate` call cannot establish it — the
two specifications may reference different parameter slots entirely. The
check must therefore be a conservative *symbolic* relation:

- accept when message and implementation reference the **identical parameter
  slot** with the implementation's literal arguments statically narrowing the
  message's — where "narrowing" is decided by the provider's relation, not by
  `attenuate`;
- accept when both are fully concrete and the provider check above succeeds;
- **reject everything else**, or require an explicit trusted proof.

Anything outside that subset is rejected rather than assumed sound. Runtime
attenuation still happens, but it cannot retroactively make an unsound public
contract substitutable — by the time it runs, the caller has already been
type-checked against the message.

Scoped and overlay protocol implementations add a second limit: compile-time
and runtime dispatch need not select the same implementation. A statically
checked implementation relationship is only binding if implementation
visibility is frozen into the interface; otherwise the check is advisory and
the runtime boundary is what enforces.

An implementation also may not turn a publicly optional requirement into a
mandatory one. If an implementation needs extra authority, the protocol
contract must expose it or the implementation must arrange a separate,
explicit call under a suitable context.

### 5.6 Call-site attenuation

The special form `with_capabilities` projects a context for one expression
or block:

```gene
(with_capabilities [
    (fs/WriteDir "scratch")
    log/*
  ]
  (plugin/run job))
```

Its selector list resolves against the current context. The body runs with
only the result, and the previous context is restored on every exit path.

This lets a developer tighten authority at the call site even when the called
function declares a broader wildcard:

```gene
(with_capabilities [(fs/WriteDir "exports")]
  (third_party/export data))
```

If the current context has no writable `exports` descendant, the form fails.
It never asks the host for additional authority.

`with_capabilities` is a special form rather than a normal named argument so
that the runtime can establish and restore execution context around argument
evaluation, dispatch, and the callee body with unambiguous semantics.

## 6. Resolution and call semantics

### 6.1 Boundary algorithm

**This is the normative algorithm.** Other sections describe how it is
lowered (§4.6), represented and cached (§13), or illustrated (§7); where any
of them appears to state different semantics, this section governs.

At each call or explicit attenuation boundary:

```text
parent    = active capability context
ceiling   = defining module's row, resolved as a template against parent
available = provider.meet(parent, ceiling)          # §3.2.3

for each selector in the declaration (or, if the row is omitted,
                                      the identity selection):
    candidates = entailment_index[selector.type]     # §8.0
    grant      = provider.derive(available, selector)     # same type
              or provider.entail(available, selector)     # cross type
    if grant is denial and the selector is mandatory:
        fail here, before the body runs
    if grant is denial and the selector is optional:
        contribute nothing

child = immutable context of the minted derivative grants
execute the body under child
```

Three properties this fixes, each established elsewhere and restated here
only because this is where they take effect:

- Every contributed grant is a **provider-minted derivative** (§3.2.2), not
  the parent's grant retained. The checked ceiling advances at every
  boundary.
- Mandatory selectors fail **before the body**, always, in every execution
  profile (§13.3, §13.5).
- Module loading never runs this algorithm, because loading is empty (§5.3).
  A module's row participates only as the `ceiling` template above, resolved
  per call.

Namespace projections contribute every matching available grant. The result
is always at or below `available`.

### 6.2 Mandatory and optional selection

Exact selectors are mandatory unless `^^optional` is present.

```gene
^capabilities [
  (fs/WriteFile output)
  (device/Compute ^^optional)
]
```

The function cannot start without authority for `output`. It can start
without compute acceleration.

Within the body:

```gene
(if (device/Compute ^^optional)
  (accelerated_path)
  (portable_path))
```

Resolving a declared optional selector returns `nil` when absent.

An undeclared selector cannot reach through to the parent. Resolving it fails
even if an ancestor held a matching grant, because it is absent from the
body's active child context.

### 6.3 Multiple matching grants

A broad selector may intentionally produce a set:

```gene
(fs/WriteDir)
```

An operation requiring one concrete proof must resolve unambiguously. If two
grants can map the same source path to different host targets, the runtime
raises `AmbiguousCapability` instead of choosing based on insertion order.

The caller can disambiguate by tightening the context:

```gene
(with_capabilities [(fs/WriteDir "output")]
  (fs/write_file "report.md" text))
```

Capability types may treat multiple matches as equivalent only when they can
prove the resulting authority and target are identical.

### 6.4 Dynamic extent and concurrency

Capability context follows dynamic execution:

- synchronous calls inherit the current selected context;
- a spawned task captures the context active at the spawn point;
- task-local attenuation does not mutate the spawning task;
- callbacks execute with the context deliberately attached by the registering
  API, not whatever context happens to be active later;
- context is restored after returns, errors, cancellation, and non-local
  control flow.

The context must be task-local execution state, not a process-global mutable
variable.

### 6.4.1 Attached contexts must intersect, not replace

A callback registered under a broad context and invoked inside a narrowed one
would, if its attached context simply replaced the invoker's, restore
authority the narrowing removed:

```gene
(var cb (broad/register (fn [] (fs/write_file "/etc/x" data))))
(with_capabilities [(fs/WriteDir "scratch")]
  (cb))              # must not regain the broad grant
```

So invocation uses the **intersection** of the attached context with the
invoker's current context. Replacement is a widening operation and is not
available to source code; only the host may attach a context that is not
bounded by the invoker.

This makes a callback closer to a delegated capability than to a plain
closure, and it interacts with §10.1: if callbacks are values that carry
attached authority, they are authority-bearing values and inherit that
section's restrictions.

Spawned tasks raise the lifetime version of the same question. A task
captures the context active at spawn; if a grant is revoked afterwards, the
captured context must observe the revocation at its next operation-safe
point, not continue on a stale copy. Revocation is therefore a property of
the grant, not of the context that references it.

## 7. Concrete filesystem example

This section follows a program that writes:

```text
<cwd>/tmp/test.md
```

### 7.1 The host grants a ceiling

Suppose the trusted launcher receives a policy equivalent to:

```gene
(fs/WriteDir "<cwd>")
```

The launcher resolves `<cwd>`, opens or securely anchors that directory, and
creates an unforgeable root grant. Gene source does not receive authority from
the string itself.

The host context is now conceptually:

```text
fs/WriteDir(root_handle=<cwd>, rights=[create, truncate, write])
```

### 7.2 The entry module narrows the application

```gene
(mod write_example
  ^capabilities [(fs/WriteDir "tmp")])

(import [write_report] from "./report.gene")

(fn main
  [args]
  ^capabilities [fs/*]
  (write_report "test.md" "# test\n")
  0)
```

At the entry boundary:

1. The parent has write authority rooted at `<cwd>`.
2. `(fs/WriteDir "tmp")` asks `fs/WriteDir` to attenuate that grant to its
   `tmp` descendant.
3. The application context is rooted at `<cwd>/tmp`.
4. The host's broader `<cwd>` grant is no longer visible inside the module.

`main` uses `fs/*`, so it inherits the filesystem grants currently
available from the entry module. It does not regain the original host grant.

If the host already grants only `<cwd>/tmp`, the entry may instead use
`fs/*`, `fs/WriteDir`, `(fs/WriteDir)`, or
`(fs/WriteDir "*")`.

### 7.3 The user's report function declares the exact file

`report.gene` can contain:

```gene
(mod report
  ^capabilities [fs/*])

(fn write_report
  [filename content]
  ^capabilities [(fs/WriteFile filename)]
  (fs/write_file filename content))
```

When called with `"test.md"`, `fs/WriteFile` resolves that relative name
against the inherited `<cwd>/tmp` root and produces an operation proof for:

```text
<cwd>/tmp/test.md
```

The function body receives that narrowed authority. It cannot use the
declaration to write `../secret.md` or an absolute path outside the root.

The coarser declaration the user proposed is also valid:

```gene
(fn write_report
  [filename content]
  ^capabilities [fs/WriteFile]
  (fs/write_file filename content))
```

It means the body may write any file entailed by the currently inherited
filesystem grants. The standard-library operation still checks the actual
`filename`. The parameter-dependent form communicates a tighter contract
and should be preferred where possible.

### 7.4 The standard library declares and checks too

The public standard-library function can be defined conceptually as:

```gene
(fn write_file
  [filename content]
  ^capabilities [(fs/WriteFile filename)]
  (native_write_file
    (fs/WriteFile filename)
    filename
    content))
```

There are two enforcement layers:

1. Function entry resolves `(fs/WriteFile filename)` and fails before the
   body if the active context cannot satisfy it.
2. The native filesystem adapter receives the resolved proof and validates
   every operation against its trusted root and rights.

The first layer gives clear contracts and early diagnostics. The second layer
is the security boundary. A bug in declaration processing must not turn a raw
path string into unrestricted host access.

The implementation need not expose `native_write_file` to normal Gene code.
The runtime may store the pre-resolved proof in a hidden frame slot so the
second `(fs/WriteFile filename)` lookup is allocation-free and cannot select
a different grant.

### 7.5 Secure path resolution

String prefix checks are insufficient. For directory-scoped capabilities, the
filesystem adapter should:

- anchor resolution at a directory handle;
- reject absolute paths when a relative path is required;
- normalize `.` and `..` without permitting escape;
- define symlink policy explicitly;
- use handle-relative operating-system operations where available;
- avoid check-then-open races;
- enforce create, truncate, append, and overwrite rights separately;
- keep diagnostics from leaking host paths outside the visible scope.

The result is authority to operate beneath a root, not permission granted
because a string happens to start with a directory name.

### 7.6 Tightening at the call site

Suppose the entry grants `<cwd>/tmp`, with writable descendants
`exports` and `scratch`. A plugin broadly declares `fs/*`.

The application can restrict one invocation:

```gene
(with_capabilities [(fs/WriteDir "exports")]
  (plugin/write_bundle bundle))
```

The plugin sees only the attenuated `<cwd>/tmp/exports` grant for that call.
Even though its declaration asks to inherit all available filesystem grants,
“available” now means the call-site context.

This is the intended layering:

```text
host:       <cwd>
entry:      <cwd>/tmp
call site:  <cwd>/tmp/exports
callee:     fs/* from the call site
```

Every step preserves or reduces authority.

## 8. Capability-type entailment

Related capability types may form an entailment graph. This is not nominal
subtyping of ordinary values; it is a trusted policy relation.

For example:

```text
fs/WriteDir(root, rights)
  entails fs/WriteFile(relative_path, mode)

only if:
  canonical_target is beneath root
  requested mode is included in rights
  symlink policy is satisfied
```

`fs/WriteFile` may be an operation capability derived from
`fs/WriteDir`, rather than a separate host grant for every possible file.

Capability-type implementations must obey:

- attenuation is transitive;
- attenuation never increases rights;
- equivalent selectors normalize identically;
- matching is deterministic;
- failure does not fall back to ambient host access;
- reflection does not expose secret provider state.

### 8.0 Entailment needs a trusted index, not a linear scan

§3.4 indexes contexts by `CapabilityTypeId`, but the central example asks a
`WriteDir` grant to satisfy a `WriteFile` selector. Looking only under the
requested type ID never finds it. Calling `attenuate` on every inherited
grant would find it, but that makes resolution O(context size), executes
unrelated user-defined code on every check, and contradicts the indexed,
cacheable presence checks §13 depends on.

Discovery must therefore be a **trusted entailment index**, separate from
scope decisions:

```text
index:   requested type ID -> candidate grant type IDs that may satisfy it
answer:  the owning provider's `entail` decides whether a candidate edge
         actually covers this request, and mints the target grant
```

The index is registration-time data owned by providers, not derived by
running user code. It must define:

- how an edge is registered, and by whom;
- conflict resolution when two grant types claim the same requested type;
- cycle rejection, since entailment must be a partial order;
- invalidation, which participates in the capability epoch (§13.2);
- whether a user library may add edges **to adapter-backed types** — the
  default should be no, since an edge into `fs` is a claim about filesystem
  authority and belongs to the filesystem provider.

`attenuate` may *propose* along a candidate edge, but per §3.2.2 it never
decides: the owning provider's `entail` is what accepts an edge and mints the
resulting grant. The index supplies candidates; the provider supplies the
answer.

### 8.1 Built-in and custom capability types

Both are first-class. They differ in who provides them and in whether they
are adapter-backed (§3.2.2), not in how they are declared or resolved.

**Built-in capabilities** are provided by the runtime and standard library —
filesystem access, environment variables, dynamic-library loading, clock,
network. They need **no import**: `fs/WriteDir` is reachable wherever a
selector is legal. Their providers are the runtime itself, so they are real
security boundaries. Their namespaces are reserved; a user library cannot define a
type that collides with `fs/WriteDir` and thereby capture its grants. Type
identity is the interned namespace-qualified ID, not a name match.

**Custom capabilities** are provided by user libraries — Slack access, a
topic publisher, a database pool:

```gene
(app/PublishTopic "events")
(db/Query ^schema "analytics" ^^read_only)
```

They implement `CapabilitySpec` like any other type.

**Identity.** A textual namespace-qualified name is not globally unique
across packages, package versions, module instances, or lexical aliases, so
`db/Query` alone cannot be the identity. A custom capability type's identity
is its **declaration identity** — defining package, version, module, and
declaration — interned to an ID. Namespace projection resolves against the
capability's *defining* namespace identity, not whichever alias spelling
appears at the use site, so aliasing an import cannot capture another
package's grants.

**Compile-time availability.** The claim that importing such a library
"executes no module body" holds for compile-artifact discovery, not for
ordinary runtime import, which initializes a module once. So the compiler
needs the constructor and `CapabilitySpec` implementation without running
module initialization. Per §4.6.1 this is resolved by construction rather
than by assumption: adapter-backed types use native compiler-owned
canonicalizers, and advisory types either use a declarative schema the
compiler evaluates directly or have their canonicalization deferred to first
use. A custom type whose implementation is only available after module
initialization simply takes the deferred path, which is always sound.

A custom type must register a provider (§3.2.3) to participate at all in
version 1; provider-less advisory types are deferred (§3.2.2). Registering a
provider is the act that makes a library's capability type trusted, so it is
a deliberate extension of the trusted surface rather than an implicit
consequence of implementing two messages.

The code that mints root grants and defines native entailment remains
trusted, regardless of who defines the specification type.

## 9. Runtime support versus granted authority

The runtime has a catalog of capability types and providers. The active
context has grants. These are different questions:

```text
Does this runtime understand fs/WriteDir?   support
Does this execution context hold one?       authority
```

Errors should preserve the distinction:

- `UnknownCapabilityType`: the name is not registered;
- `UnsupportedCapability`: the type is known but no provider exists in this
  runtime profile;
- `MissingCapability`: the provider exists but the parent context has no
  satisfying grant;
- `CapabilityScopeError`: grants exist but the requested scope is outside
  them;
- `AmbiguousCapability`: multiple non-equivalent grants satisfy an
  operation;
- `CapabilityTypeError`: arguments or properties are invalid.

`fs/*` consults only the active parent context. It does not turn runtime
support into authority.

## 10. Standard library and native boundary

Every effectful public standard-library operation should declare the least
capability it needs:

```gene
(fn read_file
  [filename]
  ^capabilities [(fs/ReadFile filename)]
  ...)

(fn write_file
  [filename content]
  ^capabilities [(fs/WriteFile filename)]
  ...)

(fn connect
  [host port]
  ^capabilities [(net/Connect ^host host ^port port)]
  ...)
```

Native implementations must accept resolved grants or proofs, not look up
unrestricted process-global facilities.

### 10.1 Proofs and other authority-bearing values

A resolved proof is authority in a value. If ordinary code can obtain, store,
return, capture in a closure, send to another task, or attach to an error
value such a proof, it has exactly the authority-recovery channel the dynamic
context exists to prevent: acquire a broad proof, then use it inside a
narrowed context.

**For version 1, proofs are not first-class.** They are unobservable and
non-escapable: the runtime holds a resolved proof in a hidden frame slot
(§7.4), and no source-level operation yields one as a value. An API of the
shape

```text
fs/write_file_with(proof, filename, content)
```

is **adapter-internal**, not a public escape hatch. Exposing it publicly is a
model change, not a convenience: the central invariant would then have to
track authority in values rather than only in the active context, and the
whole-program verifier (§19) would have to do the same.

### 10.2 Authority-bearing resources

The same channel exists for every authority-bearing *resource* — an open file
handle, a connected client, a device queue. A broad caller opens one, passes
the handle into a narrowed or empty context, and that code operates through
it. This cannot be left as a known limitation: the invariant here is stated
unqualified, and a caveat that large would mean the design is not an
end-to-end boundary.

Rechecking only the handle's *originating* grant is insufficient. It proves
the original grant is still valid; it says nothing about whether the
**current** context authorizes the operation, so the ancestor's attenuation
is still bypassed.

**Version 1 rule: every operation on an authority-bearing resource intersects
the resource's originating grant with the active context, and is authorized
by the meet.**

```text
authorized(op) requires:
  op is within the resource's originating grant, AND
  op is within the active context's grant for that capability type
```

The meet is computed by the trusted provider (§3.2.3), not by comparing grant
identities — two grants independently derived from one root may overlap
without either being an ancestor of the other.

Consequences, all intended:

- A handle passed into an empty context is unusable. That is the correct
  behaviour, not a defect.
- A handle is not a bearer token. Holding it is necessary but never
  sufficient.
- Resources need no escape analysis, no `Send` restriction, and no
  non-escapability rule, because authority is re-derived from the active
  context at each use rather than carried by the value.

The rejected alternative is worth naming: **explicit capability delegation**,
where passing a resource deliberately conveys authority. It is a legitimate
design, and it is what a later version should adopt if delegation is wanted.
But it puts authority *in values*, and then §3.5's invariant, closure and task
capture, `Send` rules, and the agent verifier (§19) must all track authority
through data flow rather than through the active context. That is a different
and much larger model, and choosing it should be deliberate rather than
arrived at by leaving handles unspecified.

The existing guidance that "an error value must not accidentally carry a
forgeable grant" is too weak. An **unforgeable** grant carried across a
boundary is precisely what conveys authority; the requirement is that no
grant or proof escapes into a value at all.

No public standard-library function should silently use unrestricted current
directory, environment, network, clock, random source, process, or device
access after the corresponding capability model exists.

## 11. Reflection and tooling

Reflection should expose canonical selectors:

```gene
(capabilities_of write_report)
# => [(fs/WriteFile filename)]
```

Reflection must expose which provider stands behind a capability type, since
a declaration alone does not say who enforces it:

```gene
(capability_type_info fs/WriteDir)
# => {^provider "host/fs" ^enforced true}

(capability_type_info db/Query)
# => {^provider "acme/db" ^enforced true}
```

A reviewer reading `^capabilities [(db/Query ^schema "analytics")]` needs to
know which trusted component decides that row. If provider-less advisory
types are added later (§3.2.2), reflection must mark them `^enforced false`
so a documented row is never mistaken for a checked one.

Useful tooling includes:

- listing the entry ceiling;
- reporting the provider standing behind each capability type a program
  uses;
- showing which ancestor supplied a grant;
- explaining every attenuation step;
- checking protocol implementation compatibility;
- producing an interface fingerprint from canonical selectors;
- warning when a broad namespace projection is used at a public boundary;
- showing optional capabilities that were unavailable.

Diagnostics should answer:

1. What selector was requested?
2. At which boundary?
3. What relevant grants were available?
4. Which ancestor removed or narrowed the required authority?
5. How can the entry or call site policy be changed deliberately?

Tooling may reveal source-visible scopes but should redact opaque tokens,
credentials, host handles, and inaccessible host paths.

## 12. Static checking

Static checking can reject:

- unknown capability types;
- a selector type that does not explicitly implement `CapabilitySpec`;
- malformed selector arguments and properties;
- duplicate or conflicting selector rows;
- parameter references that are not bound at the boundary;
- an implementation broader than its protocol message (via the provider's
  `subsumes`, §5.5);
- a call whose statically known context cannot satisfy a mandatory selector;
- attempts to use capability constructors as ordinary authority-minting
  values;
- a `canonicalize` or `attenuate` implementation that performs I/O, mutates
  state, or requires capabilities of its own. These run at compile time
  (§4.6), so this is not a style rule: an impure implementation is a
  compile-time sandbox escape.

Static analysis may also warn when:

- an entry uses a broad namespace projection;
- a function declares `fs/WriteFile` but its arguments permit a more precise
  selector;
- an optional selector is never checked;
- a component declares grants it never resolves or passes onward.

Runtime checks remain mandatory because contexts may depend on host policy,
dynamic dispatch, plugins, and runtime values.

## 13. Performance model

Capability checks occur at security-relevant boundaries, but they should not
penalize capability-free code. Since resolution is inherently dynamic (§4.6),
the cost has to be engineered away at runtime rather than assumed away at
compile time. Five techniques, in descending order of payoff.

### 13.1 Capability-free code pays nothing, by absence

The dominant case is code that declares no capabilities at all. For it the
machinery must be *absent from the emitted code*, not present and skipped: no
frame field, no branch, no guard. A "fast path" still costs a predictable
branch on every call, and this repo's call path is already tight enough that
such a branch is measurable.

Two consequences for the implementation:

- The compiler emits a different function prologue for declaring and
  non-declaring functions. A non-declaring function reached by an
  intra-module call is byte-identical to today; a cross-module call whose
  meet is not provably a no-op pays the cached intersection described in
  §5.0.
- The active context lives in a **VM register**, not a per-frame field, and
  is saved and restored only by boundaries that actually change it — the same
  shape as the operand-stack `sp` register work. A call that neither declares
  nor narrows never touches it.

This is the acceptance criterion that matters most: capability-free call
benchmarks must be indistinguishable from the pre-capability build, not
merely "no material regression".

### 13.2 Cache the context transition per call site

This is the largest win for code that *does* declare capabilities.

For a static row, the result of `resolve(declaration, parent_context)`
depends only on the declaration and the parent context. Both are interned, so
the pair is a cache key and the transition is memoizable per call site,
exactly like the existing per-call-site protocol-send cache:

```text
guard:  parent_context_id == cached_parent_id
hit:    child_context_id = cached_child_id     # one compare, one load
miss:   full resolve, then fill the cache
```

Contexts change rarely — only at explicit boundaries — so a given call site
almost always sees the same parent. The steady-state cost of a static
declaration becomes a compare and a load, with the resolve paid once.

The guard must also include a **capability epoch** bumped by anything that
can change resolution (grant revocation, a scoped `CapabilitySpec`
implementation coming into or out of scope), so a stale transition can never
be reused after the policy changes. This mirrors the `implEpoch` guard the
dispatch cache already uses.

Requirements this places on the representation: contexts must be
**hash-consed**, so identity is a pointer compare rather than a structural
walk, and so module-cache fingerprinting (§5.3) and the guard share one
mechanism.

**Threading.** This cache is mutable per-call-site state on a shared chunk,
which is exactly why the existing protocol dispatch cache is compiled out in
the atomic threaded build
(`dispatchCacheEnabled = not (threads and gcAtomicArc)` in `vm.nim`). The
capability transition cache inherits that problem and must state its answer:
per-worker side tables, immutable copy-on-write cells, atomics, or compiled
out in that build like its predecessor. Until that is chosen, the "compare
plus load" figure describes the single-lane implementation only, and the
acceptance criterion must be qualified by build profile.

**Lifetime.** Hash-consed contexts retain sealed grants, which retain host
handles. Interning them in a global table keeps those resources alive for the
process lifetime and grows without bound under repeated dynamic attenuation —
a long-running server that narrows per request would leak a context per
request. Interning must therefore be weak, or scoped to an application
lifetime with explicit reclamation, and grant release must not wait on it.
Context churn and resource release need their own tests.

### 13.3 Defer the proof, never the constraint

`(fs/WriteFile filename)` is the expensive case: it depends on a runtime
value, and doing it properly means path canonicalization, escape rejection,
and symlink policy — real work, not a compare.

The child context holds a **sealed derivative grant minted for the bound
argument** — not the parent grant with a constraint attached beside it. This
is the same rule as every other boundary (§3.2.2, §6.1); a parameter-
dependent selector is only unusual in that its argument is known at the
boundary rather than at compile time.

```text
child context holds:
  fs/WriteFile grant, derived by the provider for exactly `filename`
  (the parent's fs/WriteDir grant is NOT in the child context)
```

Consequences, which are the point of the exact declaration:

- `(fs/write_file other content)` **fails** even when `other` sits beneath
  the parent root, because the child holds authority for one file, not for
  the root. Checking only that the context held *some* `WriteFile`-entailing
  grant would leave the parent's `WriteDir` grant reachable and silently
  convert an exact declaration into broad filesystem authority.
- Nested calls inherit the derivative, so confinement propagates without any
  side-channel bookkeeping.
- The hidden frame slot caches the *resolved proof for the bound value*. It
  is an optimization over a constraint that already exists — not the
  mechanism by which the constraint exists.
- **A carried proof is validated against its grant's whole revocation
  dependency set** (§3.2.3) on every use, not just against the grant it
  names — an ancestor's revocation must invalidate it. The capability epoch
  (§13.2) guards context-transition caches only and does not reach a
  frame-slot proof. Caching a canonicalized *target* is safe; caching an
  authorization *decision* across a revocation is not.

**Validation is not deferred. Only its reuse is.** §§4.1, 6.1 and 15 promise
that an unsatisfied mandatory selector fails before the body runs, and §18
tests it. Moving scope validation to first use would let a body perform
unrelated effects before discovering that its declared path lies outside the
granted root, or return without discovering it at all. A mandatory selector
cannot be an entry precondition in one section and a lazy operation
constraint in another.

The normative rule is **fail before the body** — but policy validation and
filesystem object resolution are different events, and conflating them
reintroduces the check-then-open race §7.5 forbids:

```text
at the boundary:   bind the parameter, canonicalize the selector, and
                   provider.derive / provider.entail the exact sealed
                   child grant. Fail here if policy cannot satisfy it.

at the operation:  provider.authorize produces a race-safe proof against
                   that grant, and performs the operation atomically.
```

A previous draft ran full `authorize` at entry and reused its result at the
operation. That is unsafe. Between the boundary and the write, another
process can replace a path component or the leaf, so a cached path or a
cached authorization decision is exactly the stale check the secure-path
rules exist to prevent. And for a `^create true` selector, eagerly opening
the target to stabilize it would create or truncate the file *before the
function body runs* — not a neutral validation step.

So proof reuse is legal only under a specific condition:

> A proof may be carried from the boundary to the operation **only if it
> holds stable operating-system objects** — an open directory handle, an open
> target handle — and the eventual operation is atomic and handle-relative.
> Otherwise `authorize` runs again at the operation.

What the boundary check guarantees is therefore a **policy** precondition: if
the active context cannot authorize this selector for this argument under any
filesystem state, the function fails before its body. What it does not
guarantee is that the filesystem still looks the same at the write; only a
handle-relative atomic operation gives that, and that is the adapter's job.

The cost, stated plainly: a function declaring a parameter-dependent selector
pays policy validation even on a path that never performs the operation.
Parameter-dependent selectors are opt-in and uncommon, and a security
precondition outranks the saving.

### 13.4 Built-in types bypass the protocol

`CapabilitySpec` is the extension mechanism, not the hot path. Runtime and
standard-library types implement `canonicalize` and `attenuate` natively, and
the runtime calls them directly through the interned type ID. A filesystem
check must not become a dynamic protocol send, and a security boundary must
not depend on inline-cache behaviour for its cost profile. Only user-defined
types dispatch, and they are the ones already off the hot path.

### 13.5 Nothing at a declaration boundary is elidable

A declaration does two different things, and only one is a check:

1. **checks satisfaction** — will the required authority be available? This
   is eager diagnostics, and it is genuinely redundant with the adapter.
2. **constructs the child context** — the body and every nested call run
   under the selected context. This is not a check at all. It is the
   attenuation.

Eliding (2) is a security hole, and the adapter does not catch it. A function
declaring one exact `fs/WriteFile` selector, whose boundary transformation is
skipped, retains the broader parent context. It then performs a *different*
filesystem operation, and that operation's adapter check correctly approves
it against the broader grant it can still see. Nothing at the operation
recovers the enclosing declaration that was never installed.

**The rule: neither is elidable.**

```text
the declaration's context     must be installed in every execution profile
transformation

satisfaction checking         is a normative precondition (§4.1, §6.1, §13.3)
                              and fails before the body in every profile
```

Static rows install their child context from a cached transition (§13.2);
parameter-dependent rows validate once at entry and reuse the proof (§13.3).

A release profile that skipped eager satisfaction checks is not available:
eliding the *transformation* is a security hole (above), and §13.3 makes
eager satisfaction a normative precondition other sections depend on. What
would remain elidable is a compare and a load, which is not worth a second
execution profile or semantic divergence between builds.

So this section is no longer an optimization lever. §§13.1–13.4 carry the
performance argument on their own, and the affordability claim rests on the
transition cache rather than on skipping work.

An adapter check on a real filesystem or network operation is noise next to
the syscall it guards, so the final boundary is affordable regardless. The
adapter layer is never configurable.

### 13.6 Representation

Recommended representation:

- intern each capability type and namespace to compact IDs;
- store immutable contexts in a compact sorted array or persistent structure;
- give the empty context a singleton representation;
- precompile static selector rows into compact descriptors;
- resolve namespace projections by namespace ID rather than string scanning;
- cache safe attenuation results within one boundary;
- store resolved operation proofs in hidden frame slots;
- make capability-free function entry take a predictable fast path;
- avoid heap allocation for successful checks when the selected context and
  proof fit preallocated frame or arena storage.

Parameter-dependent selectors add work only to functions that declare them.
They must not add heap reads to unrelated scalar operations.

Benchmarks should measure:

- capability-free direct calls, against a pre-capability baseline build,
  where the bar is *no measurable difference* (§13.1);
- one exact static selector, warm and cold in the transition cache;
- the transition-cache hit rate under realistic call patterns, since §13.2's
  whole argument rests on it being high;
- one parameter-dependent filesystem selector, separating the entry presence
  check from the deferred proof (§13.3);
- a boundary whose capability epoch is bumped repeatedly, to confirm
  invalidation is not pathological;
- `fs/*` over small and large contexts;
- nested `with_capabilities`;
- module initialization and cache lookup;
- task spawn with context capture;
- a user-defined capability type against a built-in one, to quantify what
  protocol dispatch costs when it is not bypassed (§13.4).

This repo's benchmark noise floor is high enough that a single run cannot
settle a few-percent question. A capability-free regression claim needs
reproduction across batches and a mechanism, not one number.

## 14. Environments, evaluation, and macros

If an `Env` exposes `^capabilities`, its value must be a validated
`CapabilityContext` or a selector list resolved against the creator's
current context. Assigning an arbitrary map or Gene value must not create
grants.

Evaluated code runs under both:

- the target environment's lexical bindings; and
- an explicit capability context no broader than the evaluator's active
  context.

The default should be the intersection of those contexts. An explicit
`with_capabilities` can narrow it further.

Macros and compile-time execution use a separate compile-time capability
context. Runtime grants do not automatically become compiler grants.
Generated code may contain capability declarations, but macro execution
cannot use those declarations to mint compile-time authority.

## 15. Errors, cleanup, and audit

A failed mandatory check occurs before the callee body runs. A native adapter
may still fail later because of revocation, operating-system errors, races, or
resource exhaustion.

Capability scopes must compose with existing cleanup semantics:

- `with_capabilities` restores the previous context on all exits;
- resources acquired under a context are released normally;
- no error value may carry a grant or a resolved proof at all — not merely
  no *forgeable* one, since an unforgeable grant is precisely what conveys
  authority (§10.1);
- revocation, if supported, is checked at an operation-safe point.

Optional audit events may record:

- grant creation by the host;
- entry and call-site attenuation;
- denied selector resolution;
- native operation use.

Audit logging is not itself enforcement and must avoid leaking sensitive
arguments.

## 16. Compatibility and interface evolution

Capability declarations are part of a public callable's interface.

Generally:

- adding a mandatory selector is breaking;
- broadening a selector is security-significant and usually breaking;
- changing optional to mandatory is breaking;
- narrowing an implementation under an unchanged public contract is
  compatible;
- adding a new grant to an entry policy is a deliberate application-policy
  change;
- adding a runtime capability type alone grants nothing;
- a component using `fs/*` may observe a newly added parent filesystem
  grant, so changing the parent policy deserves review.

Canonical selector forms should participate in module and interface
fingerprints where cached compilation or module reuse depends on policy.

## 17. Implementation plan

Gene is pre-release and has no external users, so there is **no migration
path, no deprecation window, and no compatibility shim**. Incompatible code
is deleted and replaced. This is a deliberate simplification: a compatibility
layer that wraps a raw host path is exactly the source-can-mint-authority
pattern §5.1 forbids, and not having to keep one removes the most dangerous
part of the work.

### 17.1 What gets deleted

- The current name-only capability values and every path that passes a raw
  host path as authority. They provide no scoped confinement and cannot be
  made to.
- The explicit-argument spelling of built-in capabilities. Today the runtime
  spells these `$fs/ReadDir` and passes them as ordinary arguments — see the
  `fs/read_text expects (fs/ReadDir, path)` diagnostics in `stdlib.nim`. They
  become ambient descriptors resolved from the active context, so every such
  call site is rewritten rather than bridged.
- `gene run`'s current boot order, which loads and executes the entry module
  and *then* evaluates `--grant` expressions in that module's scope. That is
  authority minted by already-running source, and it is replaced outright
  (§17.2 step 3).

### 17.2 Build order

Ordered by dependency, not by risk, since nothing has to keep working
in between:

1. **The provider contract (§3.2.3)** — `derive`, `entail`, `meet`,
   `authorize`, `subsumes`, `provenance` with lineage revocation. This is the
   trusted security interface and it determines what a grant and a context
   must contain, so nothing below it can be designed first.
2. Interned `CapabilityType`, unforgeable `CapabilityGrant`, immutable
   hash-consed `CapabilityContext`.
3. **Launcher boot**: parse trusted host policy, mint the root context, then
   load the program with module initialization running empty (§5.3), then
   resolve the entry row and invoke `main` under it (§5.2).
4. Row parsing and normalization: the three `^capabilities` shapes,
   `^^optional`, namespace projection, and the selector-position constructor
   rule (§4.2.1).
5. The boundary algorithm (§6.1) at function, method, and protocol-message
   boundaries, including the omitted-row `caller ∩ module ceiling` rule.
6. `with_capabilities`, with exception-safe dynamic extent.
7. The filesystem provider: root-handle confinement, handle-relative atomic
   operations, symlink policy, rights masks (§7.5). This is where the design
   either holds or does not.
8. Standard-library APIs converted to parameter-dependent selectors.
9. The entailment index (§8.0), task propagation, and reflection (§11).
10. Static checking (§12) and the `CapabilitySpec` protocol for
    provider-supplied custom types.

Steps 1–3 are the ones worth getting right before writing much else; 7 is
where most of the real difficulty lives.

## 18. Acceptance criteria

The implementation is ready when tests demonstrate all of the following:

- Source code cannot create a grant by evaluating a capability-type call.
- `fs/*` with no inherited filesystem grants produces an empty projection.
- Registering a new filesystem type does not change `fs/*` without a new
  parent grant.
- An entry module can narrow a host `<cwd>` grant to `<cwd>/tmp`.
- A child using `fs/*` sees only that narrowed entry grant.
- `fs/WriteDir`, `(fs/WriteDir)`, and
  `(fs/WriteDir "*")` normalize equivalently.
- An exact mandatory selector fails before the body runs when absent.
- An optional exact selector resolves to `nil` when absent.
- A parameter-dependent `fs/WriteFile` selector rejects path escape.
- The standard-library filesystem adapter independently enforces its resolved
  root and rights.
- `with_capabilities` can narrow a call and cannot widen it.
- Context restoration works for return, error, cancellation, and non-local
  control flow.
- Multiple non-equivalent matching grants produce
  `AmbiguousCapability`.
- Protocol implementations cannot broaden public capability contracts.
- A capability-requiring operation attempted during module initialization is
  denied, because initialization has an empty context.
- Spawned tasks receive the intended immutable context without global
  contention.
- Capability-free call benchmarks show no material avoidable regression.

Open-protocol criteria (§3.1, §3.2.2):

- A type that does not explicitly implement `CapabilitySpec` is rejected in a
  selector position, even if it defines methods with the right names.
- A user-defined capability type resolves, attenuates, and reflects exactly
  like a built-in one.
- **Intermediate attenuation survives a hostile `attenuate`.** With a host
  grant of `/`, an entry narrowing to `/tmp`, and a nested boundary whose
  `attenuate` returns `/`, the operation is refused. This is the single most
  important test in this document: it is the case an earlier draft got wrong
  by checking only against the host root, and it must exist as a deliberately
  hostile implementation, not only as a property test.
- A boundary's checked ceiling is the nearest sealed derivative grant, not
  the host root.
- A user-supplied `attenuate` cannot cause a derivative grant to be minted
  that its provider would refuse.
- An `attenuate` that raises surfaces as `CapabilityTypeError` and denies the
  boundary; it does not fall through to ambient access.
- `canonicalize` is idempotent, and two equivalent specifications produce
  identical context keys and interface fingerprints.
- A `canonicalize` or `attenuate` that attempts I/O is rejected at compile
  time.
- A user library cannot define a type that captures grants belonging to a
  reserved built-in namespace.
- `^capabilities *`, `^capabilities (fs/WriteDir "tmp")`, and the list form
  normalize to the same descriptors.
- Reflection reports the correct provider for a built-in type and for a
  library-supplied one.
- A capability type with no registered provider is rejected in a selector
  position.
- A static row compiles to a descriptor requiring no runtime parsing or
  allocation; a parameter-dependent row adds cost only to its own boundary.

Performance criteria (§13):

- Capability-free calls are indistinguishable from a pre-capability baseline
  build, reproduced across benchmark batches rather than in one run.
- A repeated static declaration hits the context-transition cache and costs a
  compare plus a load in steady state.
- Bumping the capability epoch invalidates cached transitions, and a stale
  transition is never reused after revocation or a scoped implementation
  change.
- A function declaring a parameter-dependent selector that policy cannot
  satisfy fails **before** the body runs, in every execution profile; the
  race-safe proof is still produced at the operation (§13.3).
- Replacing a path component between the boundary and the operation cannot
  make a write land outside the granted root.
- Built-in capability checks perform no dynamic protocol send.
- Repeated dynamic attenuation in a long-running loop does not grow context
  interning without bound, and releases grants and host handles.

Semantics criteria (§5.0, §6.4.1, §8.0, §10.1, §13.3):

- A function with an omitted row receives `caller ∩ defining module ceiling`;
  one with `^capabilities []` receives an empty context.
- A body declaring `(fs/WriteFile filename)` **cannot** write a different
  path beneath the same parent root. This is the test that distinguishes a
  deferred *proof* from a deferred *constraint*.
- A callback registered under a broad context and invoked inside
  `with_capabilities` cannot perform an operation the narrowing removed.
- A grant revoked after task spawn is observed by the spawned task at its
  next operation-safe point.
- A `WriteDir` grant satisfies a `WriteFile` selector through the registered
  entailment index, without scanning unrelated grants or running unrelated
  user code.
- No source-level operation yields a grant or resolved proof as a value,
  including via error values and closure capture.
- Module initialization runs with an empty context, so a capability-requiring
  operation attempted during it is denied; there is exactly one runtime module
  instance regardless of context, and no capability fingerprint in its key.
- A function declaring `(fs/WriteFile a)` cannot operate on `b`, in every
  execution profile: the declaration transformation is never elided (§13.5).
- An authority-bearing resource opened under a broad context and used inside
  a narrower one is authorized by the meet, so an operation the narrowing
  removed is refused (§10.2).
- A resource passed into an empty context is unusable.
- `provider.meet` finds the overlap of two grants independently derived from
  one root where neither is an ancestor of the other; grant-identity
  comparison alone does not.
- A capability type whose provider is absent cannot be used, and one whose
  provider refuses a derivation yields denial rather than a wider grant.
- A canonical specification containing a mutable collection or closure is
  rejected at canonicalization; mutating a value after insertion cannot
  change an already-cached transition.
- **A grant revoked after a proof is carried denies a second operation in the
  same frame.** So does revoking an *ancestor* of that grant, and revoking
  *either operand* of a `meet` the grant descends from (§3.2.3).
- A broad caller invoking an undeclared function exported by a module whose
  ceiling is `^capabilities []` cannot perform an effect through it (§5.0).
- An intra-module call to an undeclared function performs no context work; a
  cross-module call into a differently-ceilinged module takes the cached
  meet.
- `provider.entail` mints a cross-type grant the target adapter accepts, and
  a provider cannot mint a grant for a type it does not own without the
  target provider's registered acceptance.
- `provider.subsumes` returning `unknown` rejects a protocol implementation
  rather than accepting it.
- Concrete protocol-implementation compatibility is decided by the provider's
  narrowing relation, and a lying `attenuate` cannot make the compiler accept
  a broader implementation.

## 19. Application: Gene as an agent's sole action surface

The machinery in §11 and §12 answers a problem outside this proposal's
original scope: an LLM agent that acts by emitting a Gene program, rather
than a tool call, needs exactly the pre-execution capability enumeration this
document specifies. Moving from tool calls to programs otherwise trades
per-action authorization for per-session authorization, and a capability
bound is what recovers the narrower guarantee.

That direction is developed in `agent-code-as-action.md`. It depends on this
proposal and changes nothing in it; nothing here should be justified by it.

## 20. Deferred questions

The following can be decided during implementation without changing the core
model:

- the exact host CLI and embedding configuration syntax, and externalizing
  capability policy to command-line arguments or a config file. The host
  already interprets such policy and mints grants from it (§5.1); what is
  deferred is the surface syntax, not the model;
- whether revoked grants use epochs, handles, or provider callbacks;
- whether `describe`'s default implementation is derived structurally from
  the canonical form or supplied per namespace;
- whether advisory (non-adapter-backed) capability types should require an
  explicit marker at declaration rather than only being reported by
  reflection;
- which operating systems receive handle-relative filesystem support first;
- whether a broad selector lookup returns a dedicated `CapabilitySet` value
  or only supports iteration and narrowing;
- which selector relationships are statically decidable;
- how capability policy appears in package manifests;
- whether audit hooks are built in or provided by an optional namespace.

These questions do not change the central invariant:

```text
the host grants;
the entry establishes the application ceiling;
modules and callees inherit selected authority;
call sites may tighten it;
nothing below the host can widen it.
```
