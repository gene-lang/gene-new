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

### 1.1 Five decisions that shape everything else

Each changes what ordinary code looks like, so disagreeing with any means
disagreeing with most of the detail that follows.

**0. Declaration requirements are a mode, and open is the default.** A
program that attenuates nothing writes no capability code at all. Modes nest
(`open -> strict -> open`), and mode governs *declarations only* — an open
region inside a strict one inherits the narrowed context and cannot exceed it,
so going open never widens authority. Every rule below describes *strict*
mode. §5.0.

**1. In strict mode, a public declaration is a contract, not an optional
narrowing.** An exported function or protocol message must carry a
`^capabilities` row; `^capabilities *` says "whatever my caller has". Private
helpers may omit and inherit. Otherwise a module granted `fs/*` gives every
undeclared exported helper ambient filesystem authority, and §2's visibility
goal is false for the declarations other code depends on. §5.0.

**2. Version 1 capability types are provider-backed, without exception.** Any
library may *define* a capability type, but it is usable only once the host
admits a provider for it. A pure-Gene `app/PublishTopic` with no provider does
not work in version 1. §3.1.1, §3.2.3.

**3. Authority lives in the context, never in values.** Possessing a file
handle or connected client conveys no permission; every operation intersects
the resource's originating grant with the *active* context. **This is not an
object-capability model** — passing a handle delegates nothing, and one passed
into an empty context is unusable. Explicit delegation is rejected
deliberately, not by omission. §10.2.

**4. A capability-type call always constructs an inert specification.** It
never resolves or authorizes by virtue of where it appears. `^capabilities`
and `with_capabilities` resolve specifications; presence is tested with
`(capability_available? spec)`; adapters receive grants through runtime state
no expression can name. §4.2.1, §6.2.

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

Capability types are **open in vocabulary, closed in enforcement**. Any type
may *describe* a kind of authority by implementing an ordinary Gene protocol,
but describing one is not enough to use it: a capability type is only valid in
a selector position once the host has admitted a provider for it (§3.2.3,
§3.2.4). Defining the type is ordinary library code; making it mean something
extends the trusted base and is the host's decision.

The practical consequence is worth stating plainly, because the word "open"
otherwise promises more than the provider model delivers: **an ordinary
library cannot introduce a working capability type on its own.** A library may
ship `app/PublishTopic` and its `CapabilitySpec` implementation, but until a
provider for it is admitted, a selector naming it is rejected (§18). Version 1
is scoped to host-backed capability types; §3.2.2 records the two candidate
routes out of that restriction and why neither is in version 1.

```gene
(protocol CapabilitySpec
  (message canonicalize [] : CapabilitySpec)
  (message describe [] : Str))
```

```gene
(type WriteArea
  ^capability "app/WriteArea"
  ^body [Str]
  (impl CapabilitySpec
    (message canonicalize []
      ^capabilities []
      ($freeze (WriteArea ($str/lower self/0))))))
```

`^capability` contains only the provider-facing qualified name. Declaration
identity and the schema hash are verification metadata, so library authors do
not repeat either in source: the linker derives identity from the defining
package, module, and type declaration, while the compiler hashes the declared
`^props` and `^body` schema. Both must match the descriptor admitted by the
host before this facade can link. The admitted descriptor should come from an
authenticated compile artifact; it is not an arbitrary declaration made by
module initialization.

The host-facing setup seam is deliberately before Gene execution. An embedding
host creates the application with a configuration callback, admits each
provider and its descriptors there, and returns the root grants. Registry
freeze happens immediately after that callback and before entry or imported
module code runs. Gene has no corresponding admission operation.

Conformance is **explicit**, never structural. A type that happens to define
a method with a matching name does not become a capability type. Explicit
conformance means the compiler can validate it, dispatch goes through
qualified protocol messages, and no type acquires capability semantics by
accident.

Only `canonicalize` is required. `describe` defaults to a string derived from
the canonical form.

**The protocol is purely descriptive. It decides nothing about authority.**
That is the logical end of the principle this design started from — user
types must not be trusted grants. A specification is a *request written in a
type's own vocabulary*; every question about whether a request is satisfiable,
and every act of minting authority, belongs to the trusted provider (§3.2.3).

Deliberately **not** in the protocol:

- **`attenuate`.** An earlier design had the specification propose a
  narrowing for the provider to validate. Since the provider must
  independently prove the result anyway, the proposal step changes no outcome
  while adding an untrusted call to the normative path — and a context holds
  *grants*, not inherited specifications, so there was no well-defined
  receiver for it. Narrowing is `provider.resolve` (§6.1).
- **`subsumes`, `intersect`.** Both are provider operations (§3.2.3). Two
  oracles for one question can disagree, and a disagreement between an
  untrusted and a trusted one is a security hole.
- **`fs/*` and `^optional`.** Runtime composition over sets of grants (§6.1),
  not questions a single specification can answer.

This keeps exactly one narrowing oracle, and it is the trusted one.

### 3.1.3 Laws

Implementations must satisfy these. They are checkable by property test and
belong in any capability type's test suite:

```text
canonicalize produces a transitively immutable snapshot:
  the result contains only deeply immutable, non-authority-bearing data

canonicalize is pure, total, deterministic, and idempotent:
  canonicalize(canonicalize(x)) == canonicalize(x)

equivalent specifications canonicalize identically:
  they must be indistinguishable to context keying and fingerprinting

canonicalize performs no I/O, mutates no state, captures no authority,
and does not depend on the active capability context
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
4. The runtime finds candidate parent grants (§6.1) and asks the type's
   *trusted provider* to derive from them.
5. The provider validates the request against the parent's sealed grant and
   mints a new sealed derivative grant, or refuses.
6. The child context holds the derivative grant. Operations are enforced
   against that derivative, not against the host root.
```

Steps 4-6 are the crux: user code describes, trusted code decides. §3.2.2
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

Keeping the inherited *host* grant and re-checking it at the operation only
establishes `effective authority <= the host's original grant`. §3.5 requires
`child <= parent`. Those differ, and the gap is exploitable with no
replacement of a built-in:

```text
1. host sealed grant is  /
2. entry correctly narrows to    /tmp
3. a later boundary derives from the HOST grant rather than from /tmp
4. adapter checks against the host grant / and permits
```

The child has recovered authority the entry removed. A ceiling that never
advances past the host root is not a ceiling.

**The rule: every attenuation boundary must produce a new sealed derivative
grant, and the adapter checks against the nearest one, not the root.**

The consequence for the open protocol is the important part:

> A `CapabilitySpec` *describes* a requested narrowing. It is never the
> *proof* that the narrowing is sound.

So narrowing is a two-party operation: user code describes a request in the
type's own vocabulary, and the trusted provider validates it against the
*parent's* grant and mints a new sealed derivative or refuses. The provider
owns the resource — the filesystem provider for `fs/*`, the host for its own
grants — and is the only thing that mints, so each boundary's ceiling is at or
below the previous one by construction rather than by user cooperation.
Source code can request anything it likes, and:

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

There are two candidate routes out of this restriction. Neither is in version
1; both are recorded so the choice is made deliberately rather than by
default, and so §3.1.1's "open" is not read as a promise.

**Route A — a generic provider for application-defined nominal policies.** One
trusted, host-admitted provider that owns every capability type in an
application-reserved namespace and implements matching generically: nominal
type identity plus a declarative comparison over the specification's canonical
arguments (exact match, or a rule the runtime defines rather than the library
does). A library then gets `app/PublishTopic` with no bespoke host code, and
the grant stays sealed and enforced, because the *provider* is still trusted
code the host admitted — the library only supplies descriptions for it to
compare. This is the stronger of the two: it keeps every claim in the document
true, and it is what an application should want.

The cost is that the generic provider must define matching for types it knows
nothing about. `intersect` and `subsumes` over arbitrary nominal specs can
only be
structural, so `(app/PublishTopic "a/*")` cannot subsume
`(app/PublishTopic "a/b")` unless the runtime defines the glob rule itself —
which means the runtime, not the library, owns the semantics of every generic
capability type. That is a real design commitment and is why it is not
version 1.

**Route B — an explicit advisory arm**, for contracts that document rather
than enforce:

```text
ContextEntry = SealedGrant(provider, grant)
             | AdvisoryPolicy(spec)
```

with trusted rules for seeding and inheritance of the advisory arm, and
reflection (§11) reporting which arm a row came from so a reviewer can tell
an enforced contract from a documented one. This is weaker and more dangerous
than it looks: an advisory row is indistinguishable from an enforced one at a
glance, which is exactly the confusion the sealed-grant boundary exists to
prevent. If it is ever added, reflection reporting the arm is not optional.

A filesystem grant should ultimately be backed by a trusted root handle and a
rights mask, not merely by a source-visible path string. A network grant may
hold an endpoint policy. A compute grant may hold a queue or device handle.

Two grants of the same capability type may coexist. For example, an entry
context may contain separate writable roots for `tmp` and `output`.

### 3.2.3 The capability provider contract

Once narrowing is provider-proved (§3.2.2), the provider — not
`CapabilitySpec` — is the security interface. `CapabilitySpec` is its
*request language*. The provider is trusted code owning a resource.

The seam has **two halves**, and separating them is what keeps it small. The
provider proper is a *grant authority*: it mints, intersects, and vouches for
grants. It performs no effects. Effects belong to **provider-owned adapters**,
which are ordinary typed native functions.

```text
CapabilityProvider — REQUIRED, all three

resolve(parent_grant, requested_spec) -> child_grant | denial
    Mint a sealed grant no broader than parent_grant, or refuse.
    Covers same-type narrowing and cross-type derivation in one
    operation: an fs/WriteDir grant satisfying an fs/WriteFile selector
    is the same question as an fs/WriteDir grant satisfying a narrower
    fs/WriteDir selector, and splitting it into derive/entail forced
    every provider to implement two paths that must agree with each
    other. The requested spec's type may differ from the parent's; it
    must be a type this same provider owns (see "who owns a cross-type
    edge" below).

intersect(left_grants, right_grants) -> grant set
    The trusted intersection of two SETS of grants this provider owns.
    Set-valued and provider-scoped rather than a per-type pairwise meet,
    because related types intersect: WriteDir "/tmp" and WriteFile
    "/tmp/a" overlap, and a per-type meet never compares them. May
    return zero, one, or several grants, of any types this provider
    owns. The runtime groups a context's grants by provider and calls
    this once per provider (§6.1).

validity(grant) -> identity + revocation dependency set
    Stable grant identity, and the set of revocation dependencies this
    grant's validity rests on. Exposes no secrets. Used by fingerprints
    (§5.3), epochs (§13.2), revocation (§13.3), and diagnostics (§11).

CapabilityProvider — OPTIONAL

subsumes(spec_a, spec_b) -> yes | no | unknown
    NON-AUTHORIZING, static. Does spec_a's authority cover spec_b's, for
    every grant either could resolve against? Mints nothing and touches
    no grant, so the compiler can call it. Three-valued, and a provider
    that does not implement it is treated as answering `unknown`
    everywhere — which is a rejection at an interface boundary, never an
    assumption of safety. Genuinely optional: §5.5 accepts exact
    canonical equality without it, so subsumes is needed only to prove a
    non-identical narrowing.

PROVIDER-OWNED ADAPTERS — typed, one per operation

read_file(grant, ...)     write_file(grant, ...)
connect(grant, ...)       publish(grant, ...)      ...

    Each adapter is registered by, and belongs to, exactly one provider.
    Each one MUST atomically validate against a grant its own provider
    issued and perform the operation in the same call, handle-relative,
    so nothing can be swapped between the check and the use.

    An adapter exports no proof: there is no value representing "this
    operation was authorized", so nothing can be captured, stored,
    returned, or replayed.
```

**Why effects are adapters rather than one `perform`.** A single
`perform(grant, operation)` forces every effect through a dynamically typed
envelope, losing static types at the boundary that most needs them, and a
provider without it cannot exercise its capability at all — so it was never
really optional. Splitting keeps the atomicity rule, restated as an obligation
on every adapter, and adapters are provider-*owned*, so the responsible
component is still named. `write_file(grant, path, bytes)` is now an ordinary
typed function rather than `perform(grant, {op: :write_file, ...})`.

`resolve`, `intersect`, and `validity` are all required, with no minimal
subset: a provider that cannot mint cannot participate, one that cannot
intersect breaks §6.1 and §10.2, and one that cannot answer `validity` cannot
participate in revocation — which is not optional.

### 3.2.3.1 Provider algebra: the laws a provider must satisfy

Deduplication (§6.1), ambiguity detection (§6.3), fingerprints (§5.3), and
transition caching (§13.2) all assume contexts behave like sets and compare
stably. None of that follows from the signatures — a provider free to mint a
fresh grant per call makes all of it provider-dependent and caching unsound.
These are conformance requirements, testable per provider:

```text
semantic key      Every grant has a stable key derived from its authority
                  and lineage — never an allocation identity. Two grants
                  with equal authority and equal lineage have equal keys
                  within one application run and provider epoch. Stability
                  ACROSS runs is not required: host handles and root
                  lineage have no meaningful cross-run identity, and every
                  cache in this document is per-run. The key used for
                  authority equality is a collision-free canonical identity;
                  a fixed-width hash may only be a lookup or sort hint.

resolve           Deterministic by semantic key: resolve(g, s) called twice
                  yields grants with the same key. Idempotent on an
                  already-satisfying grant.

intersect         Commutative and associative up to semantic key, and
                  idempotent: intersect(G, G) == G. Output is normalized —
                  no grant in the result is subsumed by another in the
                  result, and no duplicates by key.

both              Reject a revoked or malformed input rather than minting
                  from it. Never widen: every output is bounded by every
                  input it derives from.
```

Determinism is up to semantic key, not object identity, so a provider may
allocate freely while the runtime hash-conses on the key. Commutativity and
associativity are what let §6.1 intersect per provider in any order. The
runtime cannot detect a violation in general, so conformance is a condition of
admission (§3.2.4).

**Revocation propagates through the whole lineage.** A grant's validity is not
a property of that grant alone: revoking an ancestor must invalidate a
derivative, and revoking *either* operand must invalidate an `intersect`
result. A self-generation per grant is insufficient for both.

The normative rule:

```text
every resolved or intersected grant carries the revocation
dependencies of all its ancestors, and every adapter checks the whole
dependency set — not just the grant it names
```

Implementations may realize this as shared lineage tokens, composite
generations, or provider callbacks. §19 may defer the *representation*; it
may not defer this requirement.

**Who owns a cross-type edge.** A cross-type `resolve` is implemented by the
provider that owns the **source** grant, and it may only mint a grant of a
type that same provider owns. `fs/WriteDir -> fs/WriteFile` is legal because
one filesystem provider owns both. A cross-*provider* edge — an `app` grant
minting something the `fs` adapter would accept — is forbidden in version 1,
without an acceptance exception. A future bridge must be an explicit target-
provider operation with both revocation lineages (§3.2.4); it is not an
entailment edge and is outside this version.

**Why `subsumes` belongs to the provider even though it is optional.** The
compiler needs to answer a question about two *specifications*, with no parent
grant to mint from, which `resolve` structurally cannot do. Putting it
anywhere but the provider would create a second oracle for a question
`resolve` also answers, and the two could disagree — a disagreement between an
untrusted oracle and a trusted one is a security hole. Optional means a
provider may decline to answer (`unknown` everywhere, §3.2.3), not that
someone else may answer instead.

**`intersect` is not optional, and identity comparison cannot replace it.**
Three places already require intersecting authority rather than selecting from
a set:

- §6.1 intersects the caller's context with a callee module's ceiling on a
  module crossing, via `intersect_contexts`;
- §6.4.1 intersects a callback's attached context with the invoker's;
- §10.2 intersects a resource's originating grant with the active context.

Two grants may be independently derived from the same root and overlap
without either being an ancestor of the other — `/tmp/a` and `/tmp` derived
along different paths, say. Set intersection by grant identity finds nothing
there and would silently yield an empty context, or worse, pick one. Only the
provider can decide what the overlap actually is, and mint it.

### 3.2.4 Provider admission

A provider mints sealed grants, defines narrowing, and is the final operation
boundary. Admitting one therefore **extends the trusted base**, and ordinary
library initialization must not be able to do it — a library that could
register a provider could mint its own authority, and the sealed-grant
boundary would be circular.

```text
who admits      the host, explicitly, over native or otherwise
                authenticated implementations. Never Gene source, never
                an import, never module initialization.

ownership       exactly one provider per capability type, exclusively.
                A type's provider cannot be replaced or shadowed.

lifetime        the registry is populated during host boot and frozen
                before any program code runs. No admission, replacement,
                or unloading afterwards.

edges           entailment edges (§8.0) are registered with the provider
                that owns both endpoint types, and are frozen with it.
```

**Version 1 forbids cross-provider entailment edges.** An earlier sketch let
a target provider "accept" an edge from a source provider, but never said
which provider mints the target grant or how both revocation lineages are
preserved — and a source provider asserting an edge into another's types is
precisely the circularity above. If such edges are needed later, the shape is
an explicit **bridge** operation on the *target* provider that consumes a
source grant, mints its own grant, and records both providers' revocation
dependencies. Source-provider assertion alone must never suffice.

A capability type without an admitted provider cannot participate in the
model at all. This is the honest scope of "open": a library supplies a
capability *vocabulary* freely (§3.1.1), and supplies enforcement only if the
host admits it.

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
type" means the *provider*, which mints every derivative grant (§3.2.2):

```text
grant level          enforced by construction — each boundary's sealed
                     derivative is minted by the trusted provider from the
                     parent's derivative, so the checked ceiling advances
                     downward at every step

specification level  an obligation on the implementer (§3.1.3) — a wrong
                     canonical form yields a request the provider refuses,
                     so it can cause denial but not widening
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
to the child context, and the boundary still succeeds. Code tests for it with
`(capability_available? (device/Compute))` (§6.2).

`^^optional` is meaningful **only in a declaration row**, where it answers
"may this boundary proceed without the grant?". It has no meaning in an
expression: a capability-type call constructs an inert specification wherever
it appears (§4.2), so `(device/Compute ^^optional)` outside a row is a
specification carrying a property the capability system will reject rather
than a disguised presence check.

`^^optional` is interpreted by the capability system. All other arguments
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

**A capability-type call always constructs an inert specification**, wherever
it appears. `(fs/WriteDir "tmp")` does not resolve, check, or authorize
anything; it describes something. Only two forms resolve a specification
against the active context — `^capabilities` and `with_capabilities` — and
only `(capability_available? spec)` tests presence (§6.2).

One expression previously meant three things by position — constructing a
specification, resolving authority, and presence-checking inside `if`. Since
grants are deliberately not expressible as values (§10.2), "resolving" in
expression position had no value to produce anyway. Adapters receive grants
through runtime state no expression can name (§10.1); nothing an author writes
evaluates to a grant.

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
- §4.5's parameter-dependent selectors name runtime values by construction.

**`CapabilitySpec` is exempt from scoped dispatch.** A capability type has
exactly one `CapabilitySpec` implementation. Scoped and overlay
implementations do not apply to it.

Ordinary protocols stay scoped; this one cannot be, because provider ownership
is already global and frozen while dispatch is not. If `canonicalize` were
scope-dependent, the same nominal declaration would describe different
requests depending on where it was dispatched — so a canonical key would not
be canonical, and fingerprints (§5.3) and transition caches (§13.2) would key
on a value that varies by caller. It would also let an overlay change what a
security declaration *means* without changing its text.

#### 4.6.0 Four bootstrap phases

"Frozen when its provider is admitted" and "available only after its module
loads" are both true, and are different events:

```text
1. host boot     admit providers; freeze provider and TYPE OWNERSHIP.
                 A type is identified here by the declaration identity from
                 its authenticated compile artifact, provider identity,
                 canonical display name, and schema hash. No Gene code has
                 run. Nothing can be replaced later.

2. link          install the one canonical CapabilitySpec implementation
                 for each Gene facade, taken from declaration METADATA, and
                 verify that its qualified name and schema hash match the
                 already-admitted descriptor. The implementation is bound,
                 not executed; a facade cannot claim an unowned name.

3. module init   follows §5.3: a pass-through/open module inherits the
                 enclosing initialization context, while any narrowing row
                 initializes empty. A capability type's module may initialize
                 here; this does not re-open ownership, frozen at phase 1.

4. first use     the canonicalizer may finally EXECUTE, and its result is
                 memoized (§4.6.1).
```

Ownership freezes at phase 1 as a host descriptor; binding a Gene `Type`
facade happens at phase 2 from metadata; execution defers to phase 4. The
distinction removes the apparent cycle between “the registry freezes before
Gene code” and “a library defines the type.” A Gene-defined facade is
therefore supported with no phase at which running code can install, replace,
or seize a provider (§3.2.4), and the `canonicalize` target is statically
known from phase 2 onward.

**The compiler never runs a Gene-defined `canonicalize`.** Built-in providers
may expose a native, compiler-owned schema and canonicalizer; these are part of
the trusted toolchain, not library code. For a library-defined type the
compiler verifies that the facade's derived schema hash matches the
provider-admitted descriptor and emits a symbolic template. Exact constructor-
shape validation happens when that template first binds to the linked facade.
Its Gene implementation then runs and the canonical result is memoized
(§4.6.1).

What compile time genuinely delivers is the *static half* of the work, and
then a runtime design that makes the dynamic half nearly free.

There are three distinct stages, and conflating them is what made an earlier
draft claim that `(fs/WriteFile filename)` is canonicalized at compile time.
It cannot be: `filename` has no value then, and emitting its slot index does
not supply one.

**Stage 1 — compile time, for every declaration.** Operates on a *symbolic
selector template*, not a concrete specification:

- parse the row and separate `^optional` from type-owned arguments;
- validate built-in arity/property rules and reject names absent from the
  admitted catalog; for a custom facade, verify its declaration schema hash
  and retain its arguments for typed construction at first binding;
- reject a type that does not explicitly implement `CapabilitySpec`;
- intern the capability type and namespace to compact IDs;
- canonicalize the *template* with a native compiler-owned canonicalizer when
  the admitted type provides one; otherwise preserve its literal arguments in
  normalized descriptor form without executing library code;
- emit a flat descriptor with parameter references as slot indices.

A built-in row with only literal arguments is fully concrete here. A custom
row, or any row naming a parameter, retains a symbolic descriptor for runtime
binding. No purity claim is used as permission to execute user code in the
compiler.

**Stage 2 — runtime binding, for parameter-dependent or custom rows.** Bind
slot values, validate custom arguments through the linked facade's closed type
schema, run `canonicalize` on the now-concrete specification, and match against
the active context. This is the constructor and canonicalization work that
stage 1 could not safely do.

**Stage 3 — operation time.** A provider-owned adapter validates against the
child grant and executes atomically (§3.2.3, §13.3).

By the time a static *built-in* row runs there is no parsing, property-map
building, string comparison of type names, or allocation. A static custom row
pays its deferred first-use construction once and then uses the memoized
canonical form.

**Interface fingerprints use the stage-1 symbolic template.** A
runtime-dependent specification has no concrete canonical form at compile
time, so a fingerprint must be over the template and its slot references —
not over a pretended concrete value.

### 4.6.1 No user code runs in the compiler

Purity laws and an empty compile-time capability context do not isolate
arbitrary Gene code: totality is undecidable, and an empty context prevents
host I/O but not nontermination, memory exhaustion, mutation of
compiler-visible state, or nondeterminism. Static analysis can reject obvious
violations; it cannot be the security argument, and an earlier draft leaned
on it in three places.

**Version 1 takes the only boundary it can actually enforce: the compiler
executes no user-supplied capability code.**

```text
host-provided types      canonicalizers are native, compiler-owned. Rows
                         are fully processed at compile time (stage 1).

library-provided types   canonicalization is DEFERRED to first use at
                         runtime, and memoized. The compiler validates
                         the row's shape against the registered type but
                         never runs the type's own code.
```

This costs a first-use resolution for custom capability rows and nothing for
built-ins, which are the common case. In exchange, compiling an untrusted
package cannot execute that package's logic inside the compiler — a property
worth more than the saved resolution, and one no amount of static checking
would have delivered.

It also removes an inconsistency §8.1 raised: a custom implementation only
available after module initialization is no longer a special case, because
*every* custom implementation takes the deferred path.

## 5. Where capabilities are declared

### 5.0 Open and strict mode

**A program that does not attenuate anything writes no capability code at
all.** Scripts, tests, internal tools, anything early in development — the
rules below must not tax them. So declaration *requirements* are a mode, set
per module and defaulting to the package and then the application:

```gene
^capabilities_mode strict     # or open; default open
```

**Mode governs declarations, never authority.** This is the whole rule, and
everything else follows from it:

```text
mode      decides whether a missing ^capabilities row is an error
          or an inheritance

context   always inherits from the parent and only ever narrows,
          in both modes, at every boundary (§3.5)
```

**Open mode (default).** Nothing is required and nothing is implied:

| boundary | row omitted, open mode |
| --- | --- |
| entry module | **inherits the host root** |
| imported module ceiling | **inherits the application context once** |
| any function / method / message | **inherits the caller's context** |

An imported module's effective context on a call is still
`caller ∩ module ceiling` (§5.2.1). Materializing the open ceiling against the
application context, rather than whichever importer happened to load it first,
keeps one module instance deterministic while preserving caller attenuation.
During load, the same pass-through convention preserves top-level behavior:
an open entry starts under the host root and open imports inherit that
initialization context. §5.3 gives the strict/narrowed rule and its caveat.

Rows are still honoured where written, so `with_capabilities` and a narrowing
declaration work normally — they are simply not required. An open-mode
application behaves exactly like a pre-capability Gene program, and reflection
(§11) reports it as unenforced so nothing reads an absent row as a checked
contract.

**Strict mode.** Declarations become contracts, and omission means what §2's
visibility goal requires:

| boundary | row omitted | `^capabilities []` |
| --- | --- | --- |
| entry module | **empty context** | empty context |
| imported module | **empty context** | empty context |
| **exported** function / method | **compile error** — row required | empty context |
| **private** function / method | **caller ∩ defining module ceiling** | empty context |
| protocol message | **compile error** — row required | empty context |
| `with_capabilities` | n/a — row required | empty context |

#### 5.0.1 Hybrid: modes may alternate

Modes nest freely along an import chain — `open -> strict -> open -> strict`
is well defined, and each module's mode governs only its own declarations.

**An `open` region inside a `strict` one is not an escape hatch.** It means
"this code does not specify capabilities", so it inherits — and inheriting is
exactly what bounds it. It receives the strict parent's already-narrowed
context, never the host root, and cannot perform anything the inherited
context does not permit.

```text
app          open     inherits host root:            fs/*, net/*
  sandbox    strict   ^capabilities [(fs/WriteDir "tmp")]  =>  tmp only
    helper   open     no rows; inherits                    =>  tmp only
      inner  strict   ^capabilities [(fs/ReadDir "tmp")]   =>  tmp read only
```

`helper` writes no capability code and gets no authority back: it can use
`tmp`, because that is what `sandbox` left, and nothing else. Going open never
widens — §3.5's monotonic attenuation holds across every mode change, because
mode is not consulted when composing contexts.

What alternation buys is that adopting strictness is *incremental*. A team can
make one sensitive subtree strict without annotating the program around it,
and an audited strict library can call an unannotated helper without that
helper becoming a hole.

**Dependencies need not be annotated to be safe.** A strict module may import
an open library; its undeclared exports behave as `^capabilities *`, bounded
by its module ceiling and the importing context (§6.1). What is lost is
*visibility*, not safety — the enforcing mechanism is the ceiling, not the
annotation. A lint reports unannotated dependencies, so an application that
wants them fully declared can require it as policy.

Everything below describes strict mode, where someone relies on the
declarations. In open mode it is all optional.

#### 5.0.2 Mode is erased before runtime

**Mode is package-owned, and the compiler normalizes it away.** An application
cannot change a dependency's mode: a package compiled once must not mean two
things. Every omission is rewritten to an explicit descriptor at compile or
link time:

```text
open    callable omission   ->  *
open    module omission     ->  app_context  (the application ceiling)
strict  public omission     ->  compile / link error
strict  module omission     ->  []
        private omission    ->  inherited context
```

After this pass **the runtime knows nothing about `capabilities_mode`** — only
normalized descriptors. So there is no mode check on any hot path and no way
for mode to affect resolution, which is the mechanical reason §5.0's "mode
governs declarations, never authority" holds rather than being merely
asserted. It also settles mixed-mode protocol implementations (§5.5): an
omitted open-mode implementation row normalizes to `*` and is compared as `*`.

An application wanting annotated dependencies states it as a **link-time
validation policy**, `^require_strict_dependencies`, which checks interface
metadata and fails the link rather than recompiling a dependency under a mode
its author did not choose.

**A public declaration is a contract.** An exported function, method, or
protocol message must carry a `^capabilities` row; omitting one is a compile
error. Inheritance-on-omission is not survivable at a public boundary: it
means a module granted `fs/*` hands every undeclared exported helper ambient
filesystem authority, and it makes §2's goal — required authority visible on
public declarations — false for exactly the declarations other code depends
on.

`^capabilities *` is the explicit pass-through: "whatever my caller has,
bounded by my module's ceiling". An author who wants an effect-polymorphic
public helper says so in one token, and a reviewer sees it.

```gene
(fn ^export copy_tree [src, dst]
  ^capabilities *          # explicit: I use whatever my caller has
  ...)

(fn ^export read_config [path]
  ^capabilities [(fs/ReadFile path)]   # enforced, visible contract
  ...)
```

**Private helpers still inherit**, which keeps the rule affordable: a row on
every internal function would destroy §13.1's zero-cost property, since every
helper call would have to save and clear the context. Inheritance is an
intersection — `child = caller_context ∩ defining_module_ceiling` (§5.4, §6.1)
— because plain inheritance would let a module declaring `^capabilities []`
contain a row-less function that a broad caller hands the broad context.

For private helpers, static analysis (§12) infers an effective requirement
transitively and tooling should be able to report it. That inference is now
doing the job it is suited to — describing internal code — rather than
substituting for a missing public contract.

Modules default to empty because a module boundary is a policy decision and
silence there should not grant anything.

`^capabilities []` is the explicit way to drop all authority, and it is
never implied.

**Cost of the rule.** It is a source-compatibility break for any exported
function that would have omitted the row, and the migration is mechanical:
add `^capabilities *` to preserve existing behaviour exactly, then tighten
where a real contract is wanted. §16 treats adding a row to a published
function as a narrowing, so the tightening step is the breaking one and is
visible as such.

**Where the zero-cost promise applies.** §13.1's "touches nothing" claim is
scoped by the module-crossing rule (§6.1):

- **Intra-module calls do no context work at all.** The module row is applied
  when execution *crosses into* the module, not on every call within it, so an
  intra-module call has no ceiling to apply and nothing to intersect. This is
  the overwhelming majority of calls.

  This is a correctness rule before it is a performance one. Relative
  selectors are not idempotent: re-applying `(fs/WriteDir "tmp")` to a context
  already scoped to `<cwd>/tmp` yields `<cwd>/tmp/tmp`, so a design that
  re-resolved the row per call would be wrong as well as slow (§6.1).

- **Cross-module calls apply the callee module's row**, unless the compiler
  can prove the result equals the caller's context — which it can whenever
  both ceilings are static and the caller's is contained in the callee's.
- When the crossing is required, it is keyed on
  `(caller_context_id, callee_ceiling_id)` — the module ceiling already folded
  with any import ceiling (§5.3.1, §6.1) — and cached exactly like §13.2's
  transition, so the steady-state cost is a compare and a load rather than a
  provider call.
- **A declared row is applied at every call**, intra-module or not — that is
  what a declaration means. `^capabilities []` on an exported function
  installs and restores an empty context even for a capability-free body, so
  it is not free (§13.1, §18).

So the zero-cost claim is precisely: *a private capability-free call within a
module is byte-identical to today; crossing into a differently-ceilinged
module pays a cached transition; a declared row always costs its own
boundary.* An unqualified version of that claim is not compatible with
enforcing module ceilings at all.

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

The version-1 CLI uses host-only options before the entry path:

```text
gene run --allow_read_dir config --allow_write_dir output app.gene -- args...
gene run --allow_read_write_dir workspace app.gene
```

These options accept directory paths, validate them, and mint provider grants
directly. They do not evaluate Gene expressions or pass named arguments to
`main`. Once the entry path has been consumed, identical strings are ordinary
program arguments. Richer policy files and the embedding API syntax remain
separate host-surface decisions.

**With no such option the default filesystem root is the launch directory**,
and the nominal host capabilities (§8.1) are granted whole. `--allow_*` adds
directories to that root; it does not replace it.

This is narrower than "everything the process could do", and deliberately so.
§17 gives up compatibility with pre-capability builds outright — there are no
external users and no migration shim — so nothing is owed to a program that
read `/etc` by ambient authority, and a launcher that hands out the whole
filesystem leaves an entry row nothing worth narrowing. §18's "runs with the
host's full authority" means *whatever the host granted*, which is this; it
does not mean unrestricted.

The cost is that a program reading outside its launch directory — a temp file,
`$HOME` — must be given that directory explicitly, by `--allow_*` or by an
embedding host. That is the intended friction.

### 5.2 Entry module

In strict mode the entry module establishes the application-level ceiling.
(In open mode there is no entry row and the entry inherits the host root,
§5.0.)

```gene
(mod app
  ^capabilities [
    (fs/WriteDir "tmp")
    net/*
  ])
```

This is the main policy point controlled by the application developer. It
governs what `main` and everything it calls may do; it does not govern the
loading of the program.

#### 5.2.1 Ceiling lifecycle (normative)

Ceilings are resolved **once**, in one phase, after loading and before `main`.
This section governs; §5.3 and §6.1 describe consequences of it.

```text
1. host boot        host_root = grants the host mints (§5.1)

2. load             no row is materialized yet. A pass-through/open entry
                    initializes under host_root, and pass-through imports
                    inherit that initialization context. A module with any
                    narrowing row initializes under EMPTY, as does a module
                    that ANY import bounds with a ceiling (§5.3.1) — the
                    module is a singleton, so the narrower answer is the
                    only one that cannot leak. Consequently a strict or
                    narrowed entry also causes its pass-through import
                    subtree to initialize empty. Imports transfer no
                    authority beyond this inherited initialization context.

3. materialize      app_context = resolve_row(entry_row, host_root)
                                  host_root, if the entry row is omitted
                                             in open mode
                                  empty,     if omitted in strict mode

                    entry.module_ceiling = app_context

                    module_ceiling(M) =
                        resolve_row(M.row, app_context)  when M declares one
                        app_context                      omitted, open mode
                        empty                            omitted, strict mode

                    import_ceiling(I, M) =
                        resolve_row(I's import row for M, app_context)
                                                         when I declares one
                        unbounded                        otherwise   (§5.3.1)

4. run              main executes under app_context. Every boundary computes
                    intersect(parent, callee_ceiling(caller_module,
                                                     callee_module)) (§6.1).
```

A module loaded lazily after step 3 materializes its ceiling against the
stored `app_context`, so it gets the same ceiling it would have had at step 3.
`app_context` is fixed for the life of the program. A lazy pass-through
module also initializes under that fixed context, rather than under whichever
narrowed caller happened to trigger the singleton load first.

Two consequences worth stating, because earlier drafts contradicted themselves
on both:

- **Nothing is resolved per call.** Step 3 happens once; a call only
  intersects an already-materialized ceiling with its caller's context.
- **Nothing is resolved during load.** At step 2 there is no `app_context` to
  resolve against, which is exactly why materialization is its own phase
  rather than part of loading.

Relative selectors depend on this: `(fs/WriteDir "tmp")` resolves against
`app_context` once, so what "tmp" is relative *to* is a single well-defined
context rather than whatever happened to be active.

### 5.3 Imported modules

**A module row is an immutable selector template, not a context.** It is
never materialized at import time. Loading and initialization run under an
empty capability context, and importing brings in *definitions* without
transferring any authority:

```gene
(mod report
  ^capabilities [fs/*])
```

This is a *ceiling*, materialized once against `app_context` in §5.2.1's step
3 and fixed thereafter. It bounds what any call into `report` may receive; it
does not say the module holds that authority, and there is no moment at which
it does — what a call actually gets is `intersect(caller_context, ceiling)`.

That is what makes the singleton sound. Resolving a module's row against "the
context supplied by its importer" would be incoherent: there is no importer
context at load time, and a module imported by two differently-authorized
callers would have to keep whichever imported it first. An absolute ceiling
plus a per-call intersection answers both without instancing the module.

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

**Version 1 makes initialization follow the declaration mode.** A
pass-through row (including an omitted row in open mode) preserves Gene's
existing top-level behavior and inherits the enclosing initialization
context. Any narrowing row — including an omitted row in strict mode and
`^capabilities []` — initializes under an empty context. Once the application
context exists, a lazily loaded pass-through module initializes against that
fixed application context, not a first caller's transient narrowing.

This distinction is intentional. Default-open mode promises compatibility,
not confinement: an open module may read protected data at initialization and
retain the returned **ordinary string**. A later call-site attenuation cannot
retroactively erase information already captured. Catching that would require
pervasive information-flow tainting. An application that treats capabilities
as a security boundary therefore uses a strict or narrowed entry; its
initialization context is empty, and pass-through imports can inherit only
empty during the load phase.

Consequences:

- There is exactly one runtime instance per
  `<package_identity>::<module_path>`, as today. Gene's module and type
  identity semantics are unchanged, and the module cache key needs no
  capability fingerprint — including with import-site ceilings (§5.3.1),
  which separate importers by per-call intersection rather than by instancing.
- In an open application, initialization intentionally has legacy ambient
  behavior. The application has not asked the declaration system to confine
  it; native adapters still require grants from the host root.
- In a strict or narrowed application, effectful initialization becomes an
  explicit function called after materialization under a context the
  application chooses. The authority is visible at a call boundary instead
  of implicit in load order.
- A capability-requiring operation attempted while a narrowing module
  initializes finds an empty context and is denied by the ordinary mechanism.
- A lazy open module uses the fixed application context, so first-caller order
  does not choose the singleton's initialization authority.

If per-context module instances are wanted later, the shape is: share
compiled declaration identities, create per-context runtime module scopes,
and keep nominal type identity stable across them. Then a fingerprint becomes
necessary, and it must include **grant and provider identity** (`validity`,
§3.2.3), not
only canonical visible selectors — two roots with the same selector shape but
different underlying grants must never share initialized authority-bearing
state.

#### 5.3.1 Import-site ceilings

The row above is authored by the dependency. An importer that wants to bound a
dependency it does not control has, so far, only `with_capabilities` at each
call site (§5.6) — which is per-call, easy to forget, and useless for anything
the dependency does at load time. So an import may declare its own ceiling:

```gene
(import * : plugin from "./plugin"
  ^capabilities [(fs/WriteDir "tmp")])
```

This is the caller-side counterpart of §5.3's module row: one declaration, at
the importer, per dependency. It composes by intersection like every other
boundary, so a call from importer `I` into module `M` receives

```text
caller_context ∩ module_ceiling(M) ∩ import_ceiling(I, M)
```

and §3.5's monotonic-downward invariant holds by construction — an import
ceiling can only remove authority, never restore it, and it cannot exceed what
`M`'s own row already allows.

Like a module ceiling, an import ceiling is **materialized once against
`app_context`** (§6.1), not against the importer's transient context at the
moment of a call. It is therefore immutable, and the two ceilings fold into a
single precomputed bound per `(importer, module)` pair — a static property of
the call site — so §13.2's per-call-site transition cache is keyed and reused
exactly as before, with no extra runtime composition.

**It does not key the module cache.** There is still exactly one instance per
`<package_identity>::<module_path>`, and §5.3's argument against capability
fingerprints is untouched: differently-authorized importers are separated by
per-call intersection, not by instancing.

**A module imported with any import ceiling initializes under an empty
context.** This is the rule that makes the ceiling real rather than decorative.
§5.3 is explicit that an open module's initialization inherits the enclosing
context and may capture protected data as ordinary values, which no later
call-site attenuation can retract:

> A later call-site attenuation cannot retroactively erase information already
> captured. Catching that would require pervasive information-flow tainting.

An importer that bounds a dependency is asking for confinement, so load time
cannot be exempt from it. This is not a new initialization mode — it is §5.3's
existing "any narrowing row initializes under an empty context" rule, extended
to narrowing declared by the importer rather than by the module.

The quantifier is deliberately conservative: because the module is a singleton,
**any** import declaring a ceiling forces empty-context initialization for
every importer, including those that declared none. Taking the narrower option
is the only answer that cannot leak — the alternative would let an unbounded
importer decide whether a bounded importer's confinement holds.

**The implemented guarantee is order-dependent in one case, and it is worth
stating exactly.** The bound is recorded when the bounding `import` executes,
which is before that dependency loads, so the dependency initializes empty. But
if some *other* importer already loaded the same module earlier in the program
with no ceiling, that initialization has already run: the singleton exists, and
nothing can retract what its top level captured. Calls are still confined —
every boundary intersects the import ceiling regardless of load order — so this
is an initialization-capture residual, not an authority leak.

Closing it needs a pre-pass that walks the entry's static import graph and
collects every ceiling before any module initializes. Import specifications are
static and unconditional, so the pass is possible; it is deferred rather than
impossible. Until then, a program that cares should bound a dependency at every
import of it, which a lint can check.

A dependency whose initialization genuinely needs authority exposes it as an
explicit setup function the importer calls under a context it chooses, which is
what §5.3 already prescribes for strict and narrowed applications.

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
invocation, their declarations resolve against the caller's active context
intersected with their defining module's ceiling (§6.1).

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
**provider's** trusted `subsumes` relation (§3.2.3):

```text
provider.subsumes(message_spec, impl_spec) must return `yes`
```

`resolve` cannot substitute for it: a specification is not a grant, and the
compiler has no parent grant to mint from. `unknown` — including from a
provider that omits `subsumes` — rejects rather than assumes compatibility.

Routing this through untrusted specification code would be unsound: a lying
implementation could make the compiler accept a contract broader than its
message. The provider still refuses to widen at runtime, but callers then
receive denial where the public protocol promised success, so substitutability
breaks even though nothing is over-authorized. Static interface checking must
consult the same authority that decides at runtime.

**This does not generalize to parameter-dependent selectors.** "No broader
for every valid parent context" is universally quantified over runtime
arguments, and a single concrete `subsumes` call cannot establish it — the
two specifications may reference different parameter slots entirely. The
check must therefore be a conservative *symbolic* relation:

- accept when message and implementation reference the **same external
  boundary slot** with the implementation's literal arguments statically
  narrowing the message's — where "narrowing" is decided by the provider's
  relation, not by `subsumes`;
- accept when both are fully concrete and the provider check above succeeds;
- **reject everything else**, or require an explicit trusted proof.

Anything outside that subset is rejected rather than assumed sound. Runtime
attenuation still happens, but it cannot retroactively make an unsound public
contract substitutable — by the time it runs, the caller has already been
type-checked against the message.

“Same slot” is independent of a local parameter spelling. Positional slots are
identified by index; named slots by their external call key; rest parameters
by their declared positional or named-rest role; `this` has its own fixed
slot. Thus an implementation may rename `destination` to `path` and still
match a protocol message's first positional parameter. Conversely, two local
variables with the same spelling do not match when they occupy different
external slots. Optionality is compared selector-by-selector after this
mapping: a publicly optional selector may remain optional or be omitted, but
may not become mandatory.

Scoped and overlay protocol implementations add a second limit: compile-time
and runtime dispatch need not select the same implementation, so a static
check against the statically visible implementation does not cover the one
that actually runs.

**That gap is closed by validating every implementation when it is registered
or activated, not by calling the static check advisory.** Runtime attenuation
prevents *excess authority* — a scoped implementation cannot exceed its
context. It does not preserve the *protocol contract*: a caller satisfying the
public message row can still get `MissingCapability` because the
implementation selected at runtime secretly requires more, and the public row
promised that call would work.

So registration is a checkpoint:

```text
registering or activating an implementation of a protocol message
  requires: implementation_row is no broader than message_row
  rejected at registration, not at the call that later fails
```

This is affordable because the common case needs no provider reasoning:

- **Exact canonical equality is always accepted.** An implementation whose row
  canonicalizes identically to the message's is compatible by inspection —
  no `subsumes` call, no provider involvement.
- **`subsumes` is needed only to prove a non-identical narrowing**, and a
  provider that does not implement it answers `unknown`, which rejects that
  implementation rather than admitting it.

This is what makes `subsumes` genuinely optional (§3.2.3) rather than
nominally so: without it, a provider still supports every implementation that
restates its message's row, and only loses the ability to register a
strictly-narrower one.

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

**The runtime owns composition; the provider owns grant semantics.** A context
is a multimap holding zero or more grants per type (§3.4). Composition is the
runtime's job, but it cannot be done type-by-type, because the design relies
on related types (§8.0) — a context holding `fs/WriteDir "/tmp"` and one
holding `fs/WriteFile "/tmp/a"` have a real intersection that no type-keyed
comparison finds. Grants are therefore grouped by **owning provider**, not by
capability type, and the provider returns a set:

```text
intersect_contexts(a, b) -> context
    Group both inputs' grants by owning provider. For each provider
    present in BOTH groupings, call

        provider.intersect(left_grants, right_grants) -> grant set

    which may return zero, one, or several grants, of any types that
    provider owns — including a type present in neither input, when the
    overlap of two related types is a third. Deduplicate by canonical
    identity. A provider present in only one input contributes nothing.

resolve_selector(context, selector) -> grant set | denial
    candidates = [selector.type] ++ entailment_index[selector.type]   §8.0
    for each candidate type, in registration order, and each grant of
    that type in the context, in canonical order:
        provider.resolve  (one operation; the candidate type may differ
                          from the selector type, §3.2.3)
    Collect every successful mint, deduplicated by canonical identity.

resolve_row(row, context) -> context
    Apply every selector in `row` against `context`, yielding the minted
    grants. The result is bounded by `context` by construction. Note this
    does NOT make the boundary's intersection redundant: a module ceiling
    is materialized against app_context, not against the caller, so it
    must still be intersected with the caller's context (below).
```

**A module ceiling is materialized once, against `app_context`** (§5.2.1 step
3) — never against a caller's context, and never during load:

```text
module_ceiling(M) = resolve_row(M.row, app_context)
```

An import ceiling (§5.3.1) is materialized the same way and folded into the
same bound. Both are static properties of the call site, so the pair is
precomputed once per `(importer, module)`:

```text
import_ceiling(I, M)  = resolve_row(I.import_row_for(M), app_context)
callee_ceiling(I, M)  = intersect_contexts(module_ceiling(M),
                                           import_ceiling(I, M))
```

An absent import row contributes no bound, leaving `callee_ceiling` equal to
`module_ceiling(M)`.

Both are immutable and cached for the life of the program. Then at each call or
explicit attenuation boundary:

```text
parent    = active capability context
available = intersect_contexts(parent, callee_ceiling(caller_module,
                                                     callee_module))

for each selector in the declaration (or, for a private helper with no
                                      row, the identity selection):
    grants = resolve_selector(available, selector)
    if grants is empty and the selector is mandatory:
        fail here, before the body runs
    if grants is empty and the selector is optional:
        contribute nothing
    otherwise contribute every grant in the set

child = immutable context of the minted derivative grants
execute the body under child
```

**Why the ceiling is absolute rather than caller-relative.** Selectors are not
idempotent, so a ceiling re-derived from whatever context is active compounds.
With `(fs/WriteDir "tmp")` on module `A` and root `/`, resolving A's row per
crossing gives `/tmp` on entry, then `/tmp/tmp` on re-entry from `B` — and
`A -> B -> A` is ordinary: a callback, mutual recursion, or a cyclic import
all produce it. Resolving once against the root makes the ceiling idempotent
under any call order, depth, or re-entry.

The intersection with `parent` is load-bearing, not redundant: `module_ceiling`
is not derived from `parent`, so it is what stops a module regaining authority
its caller dropped.

**Intra-module calls remain free**, now as a provable optimization rather than
a rule. Inside `M` the active context was established by a crossing into `M` —
hence at or below `module_ceiling(M)` — and only narrows (§3.5), so the
intersection is a no-op and is skipped.

Consequently a module row's `fs/*` means "the filesystem authority the
*application* holds", not "what my caller holds". Caller-relative attenuation
is already supplied by intersecting with `parent`; making the ceiling
caller-relative too was double-counting, and was the source of the
compounding.

**Set-valued by design, ambiguity reported late.** A selector may legitimately
resolve to several grants — §6.3's two writable roots — so `resolve_selector`
returns a set and a boundary never fails merely because it found more than
one. `AmbiguousCapability` is raised at the *operation*, when one concrete
grant must be chosen and two non-equivalent candidates could serve it (§6.3),
not during resolution.

**Determinism.** Candidate types are visited in registration order and grants
in canonical identity order, so resolution does not depend on insertion order
or hash iteration. Two contexts that are equal as sets produce equal results,
which is what makes the transition cache in §13.2 sound.

Three properties this fixes, each established elsewhere and restated here
only because this is where they take effect:

- Every contributed grant is a **provider-minted derivative** (§3.2.2), not
  the parent's grant retained. The checked ceiling advances at every
  boundary.
- Mandatory selectors fail **before the body**, always, in every execution
  profile (§13.3, §13.5).
- Module loading never runs this algorithm, because loading is empty (§5.3).
  A module's row is materialized once in §5.2.1 step 3; a boundary only
  intersects the resulting ceiling.

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

Within the body, presence is tested explicitly:

```gene
(if (capability_available? (device/Compute))
  (accelerated_path)
  (portable_path))
```

**`capability_available?` is a lookup, not a resolution.** It answers only
about selectors the enclosing declaration already evaluated at its boundary:

```text
capability_available?(spec) =
    spec canonicalizes to a selector in THIS boundary's declaration,
    and that selector contributed at least one grant to the active context
```

`true` or `false`. It mints nothing, calls no provider, and performs no
entailment discovery.

That restriction is the point. Cross-type satisfaction is discovered by
`resolve` (§6.1), which *mints* — so a general presence test would either mint
a grant it discards, or need a second pure query path whose answers must agree
with `resolve`'s forever. Two oracles for one question is the failure mode
§3.2.3 already rejects.

The useful case needs none of it: an optional selector was declared, so it was
already resolved at the boundary and the question is whether it produced
anything. Asking about an undeclared capability is `false`, not an error, and
never reaches the parent; *using* one still fails at the boundary (§6.1).
General "could I obtain X?" queries would need a separate pure provider
operation with a stated consistency guarantee, and are not in version 1.

`^^optional` appears only in declaration rows, never in this expression: it
says whether a boundary may start without a grant, which is meaningless once
the boundary has already started.

### 6.3 Multiple matching grants

A broad selector may intentionally produce a set:

```gene
(fs/WriteDir)
```

An operation requiring one concrete grant must resolve unambiguously. If two
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
2. `(fs/WriteDir "tmp")` asks the filesystem provider to derive a grant for
   the `tmp` descendant of that root.
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
against the inherited `<cwd>/tmp` root and derives a grant for:

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
2. The filesystem provider's adapters validate every operation against the
   derived grant's trusted root and rights, and execute it atomically.

The first layer gives clear contracts and early diagnostics. The second layer
is the security boundary. A bug in declaration processing must not turn a raw
path string into unrestricted host access.

The implementation need not expose `native_write_file` to normal Gene code.
The runtime may store the derived grant in a hidden frame slot so the second
`(fs/WriteFile filename)` lookup is allocation-free and cannot select a
different grant.

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
requested type ID never finds it. Asking every inherited grant's provider
would find it, but that makes resolution O(context size) and contradicts the
indexed, cacheable checks §13 depends on.

Discovery must therefore be a **trusted entailment index**, separate from
scope decisions:

```text
index:   requested type ID -> candidate grant type IDs that may satisfy it
answer:  the owning provider's `resolve` decides whether a candidate edge
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

The index supplies candidates; the owning provider's `resolve` accepts an edge
and mints the resulting grant. Discovery and decision stay separate.

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
ordinary runtime import, which initializes a module once. The compiler
therefore consumes only the admitted descriptor and declarative row schema.
It does not need to execute, or even load executable code for, the Gene
`CapabilitySpec` implementation. Adapter-backed built-ins may additionally
provide native compiler-owned canonicalizers. A custom implementation binds
at link time and canonicalizes at first runtime use (§4.6.1).

A custom type must have a provider admitted by the host (§3.2.3) to
participate at all in version 1; provider-less advisory types are deferred
(§3.2.2). A package may ship a provider implementation and authenticated
descriptor, but importing that package does not admit it. Host admission is
the act that makes the library's capability type trusted, so it is a
deliberate extension of the trusted surface rather than an implicit
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

Native implementations must go through a provider-owned adapter with a
resolved grant, not look up unrestricted process-global facilities.

The apparent `grant` parameter in §3.2.3 is a host-interface parameter, not a
Gene argument. A fused native builtin obtains the active child context from
the VM, resolves the exact operation grant into a private non-`Value` slot,
and immediately calls its provider-owned adapter. If the native ABI represents
that slot explicitly, its type is opaque and cannot be boxed, reflected,
captured, or supplied by Gene code. Validation and effect remain one native
operation; there is no public `native_write_file(grant, ...)` surface.

### 10.1 Proofs and other authority-bearing values

An authorization decision held in a value would be authority in a value: if
code could obtain, store, return, capture in a closure, send to another task,
or attach to an error one, it would have exactly the authority-recovery
channel the dynamic context exists to prevent.

**There is no such value.** §3.2.3's adapters validate and execute in one call
and export nothing, so no proof exists to escape. This is why the operation
boundary is `write_file(grant, ...) -> result` rather than
`authorize(grant, operation) -> proof`: the second interface would require a
sealed proof-consumption protocol binding provider identity, exact operation,
stable handles, and revocation lineage, and would still leave the question of
who may consume a proof and whether it is one-shot.

An API of the shape `fs/write_file_with(proof, ...)` therefore does not
exist. Adding one is a model change, not a convenience: the central invariant
would have to track authority in values rather than only in the active
context, and any pre-execution verifier would have to do the same.

### 10.2 Authority-bearing resources

The same channel exists for every authority-bearing *resource* — an open file
handle, a connected client, a device queue. A broad caller opens one, passes
it into a narrowed or empty context, and that code operates through it.
Rechecking only the handle's *originating* grant proves the original grant is
still valid but says nothing about whether the **current** context authorizes
the operation, so the ancestor's attenuation is still bypassed.

**Version 1 rule: every operation on an authority-bearing resource intersects
the resource's originating grant with the active context, and is authorized
by the meet** (decision 3 of §1.1).

Name it plainly: **this is contextual authority, not an object-capability
model.** In ocap, possessing a reference *is* the permission and passing it
delegates. Here possession is necessary and never sufficient. Readers arriving
with ocap expectations — reasonable, given "capability" — will otherwise
mis-predict every I/O interface in the standard library.

```text
authorized(op) requires:
  op is within the resource's originating grant, AND
  op is within the active context's grant for that capability type
```

The meet is computed by `intersect_contexts` (§6.1) over the trusted
per-provider `intersect` (§3.2.3), not by comparing grant identities — two
grants independently derived from one root may overlap without either being an
ancestor of the other, and two grants of *related* types may overlap without
sharing a type at all.

Consequences, all intended:

- A handle passed into an empty context is unusable. That is the correct
  behaviour, not a defect.
- A handle is not a bearer token. Holding it is necessary but never
  sufficient.
- Resources need no escape analysis, no `Send` restriction, and no
  non-escapability rule, because authority is re-derived from the active
  context at each use rather than carried by the value.

The runtime still has to remember the resource's creation-time ceiling. That
metadata is **runtime-internal origin state**, not a Gene field and not a
`CapabilityGrant` value. A native resource node contains a hidden, monotonic,
never-reused identity; a runtime table maps that identity to the owning
application and immutable origin context. Every resource adapter loads the
entry, intersects it with the active context, and performs the operation
atomically.

The table deliberately does **not** retain the resource value, which would
make the entry and resource keep one another alive. Explicit close atomically
takes the hidden identity and removes its entry; final release of a resource
node does the same through a runtime cleanup hook. Because identities are not
addresses and are never reused, recycling a node or boxed-bit pattern cannot
inherit another resource's authority. Reflection, serialization, equality,
copying, property access, and ordinary message sends cannot reveal or
reproduce this metadata.

Two alternatives are rejected. **Explicit delegation** — possession of a
sealed resource conveys its restricted authority — is the ocap answer and is
legitimate; it is what a later version should adopt if delegation is wanted.
But it puts authority in values, and then §3.5's invariant, closure and task
capture, `Send` rules, and any pre-execution verifier must all track
authority through data flow. **Two resource classes**, context-bound and delegable, is
worse than either: its failure mode is a delegable handle where a
context-bound one was assumed, which is the confusion the design exists to
prevent, now with two spellings.

Note also that "an error value must not accidentally carry a forgeable grant"
is too weak — an *unforgeable* grant crossing a boundary is precisely what
conveys authority. No grant or proof escapes into a value at all.

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
- a capability type with no admitted provider, in a selector position
  (§3.1.1);
- a selector type that does not explicitly implement `CapabilitySpec`;
- malformed selector arguments and properties;
- duplicate or conflicting selector rows;
- parameter references that are not bound at the boundary;
- **in strict mode, an exported function, method, or protocol message with
  no `^capabilities` row** (§5.0) — the public-contract rule, and the one
  static check the visibility goal rests on. Not a check in open mode;
- `^^optional` outside a declaration row (§4.2.1, §6.2);
- an implementation broader than its protocol message (via the provider's
  `subsumes`, §5.5), including when `subsumes` answers `unknown`;
- a call whose statically known context cannot satisfy a mandatory selector;
- attempts to use capability constructors as ordinary authority-minting
  values;
- a `canonicalize` implementation that performs I/O, mutates state, or
  requires capabilities of its own. This is a correctness check on a
  registered type, not a sandbox: §4.6.1 keeps user canonicalizers out of the
  compiler entirely, so static rejection here is defence in depth rather than
  the security argument.

Static analysis may also warn when:

- an entry uses a broad namespace projection;
- an exported function declares `^capabilities *`, which is legal and explicit
  but is the pass-through, not a contract;
- a function declares `fs/WriteFile` but its arguments permit a more precise
  selector;
- an optional selector is never tested with `capability_available?`;
- a component declares grants it never resolves or passes onward;
- a **private** helper's inferred effective requirement exceeds what its
  module's exported surface declares — the inference that used to substitute
  for public declarations now checks them instead.

Runtime checks remain mandatory because contexts may depend on host policy,
dynamic dispatch, plugins, and runtime values.

## 13. Performance model

Capability checks occur at security-relevant boundaries, but they should not
penalize capability-free code. Since resolution is inherently dynamic (§4.6),
the cost has to be engineered away at runtime rather than assumed away at
compile time. Five techniques, in descending order of payoff.

### 13.1 Private capability-free code pays nothing, by absence

The dominant case is a private helper that declares no capabilities. For it
the machinery must be *absent from the emitted code*, not present and skipped:
no frame field, no branch, no guard. A "fast path" still costs a predictable
branch on every call, and this repo's call path is already tight enough that
such a branch is measurable.

Since §5.0 requires a row on every *exported* declaration, "non-declaring"
means "private helper" — which is what the dominant case was in practice
anyway.

**The zero-cost claim is scoped to that case, and cannot be broader.** A pure
exported function declaring `^capabilities []` must install and restore an
empty context when a capability-bearing caller invokes it, since the whole
point of `[]` is that the callee does not see the caller's authority. That is
not byte-identical to a pre-capability build, and no amount of caching makes
it so — only proof-based elimination would, by showing the caller's context is
already empty. §18 therefore states three separate performance tiers rather
than one claim: private intra-module calls (no measurable overhead),
cross-module public calls (bounded cached cost), and capability-declaring
calls (measured cold and warm).

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

The guard must also include a **capability epoch** bumped by anything that can
change resolution, notably grant or ancestor revocation, so a stale transition
can never be reused after policy changes. `CapabilitySpec` implementations are
canonical, application-global, and never scoped (§4.6), so ordinary dispatch
scope changes do not participate in this epoch.

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
- **Nothing carries an authorization decision.** An adapter (§3.2.3) checks
  the grant's whole revocation dependency set at each call, so an ancestor's
  revocation takes effect immediately. Caching a canonicalized *target* is
  safe; there is no cached decision to go stale.

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
                   provider.resolve the exact sealed child grant.
                   Fail here if policy cannot satisfy it.

at the operation:  a provider-owned adapter validates against that grant and
                   performs the operation atomically, handle-relative.
```

Running validation at the boundary and *reusing its result* at the operation
would be unsafe: between the two, another process can replace a path
component or the leaf, so a carried decision is exactly the stale check the
secure-path rules exist to prevent. And for a `^create true` selector,
eagerly opening the target to stabilize it would create or truncate the file
*before the function body runs* — not a neutral validation step.

Hence the split. The boundary check is a **policy** precondition: if the
active context cannot satisfy this selector for this argument under any
filesystem state, the function fails before its body. Whether the filesystem
still looks the same at the write is guaranteed only by the adapter being
atomic and handle-relative, which is why authorization and execution are one
operation and not two.

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

Capability declarations are part of a public callable's interface — and since
§5.0 requires one on every exported callable, every public callable now has an
interface to evolve, rather than an absence to reinterpret later.

Generally:

- replacing `^capabilities *` with any narrower row is breaking. This is the
  migration path §5.0 describes: `*` preserves prior behaviour exactly, and
  the later tightening is the change callers can observe;
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

1. **The provider contract (§3.2.3)** — `resolve`, `intersect`, `validity`
   with lineage revocation, optional `subsumes`, and the provider-owned
   adapter rule. This is the trusted security interface and it determines
   what a grant and a context must contain, so nothing below it can be
   designed first.
2. Interned `CapabilityType`, unforgeable `CapabilityGrant`, immutable
   hash-consed `CapabilityContext`.
3. **Launcher boot**: parse trusted host policy, mint the root context, load
   the program using §5.3's pass-through-or-empty initialization rule, then
   resolve the entry row and invoke `main` under it (§5.2).
4. Row parsing and normalization: the three `^capabilities` shapes,
   `^^optional`, namespace projection, and the selector-position constructor
   rule (§4.2.1), plus `^capabilities` on `import` (§5.3.1). The import row is
   parsed raw and lowered in `compileImport`, because `parseImportSpec` also
   runs during dependency-graph analysis where no compiler exists to lower a
   selector.
5. The boundary algorithm (§6.1) at function, method, and protocol-message
   boundaries, including the private-helper `caller ∩ module ceiling` rule
   and the exported-declaration requirement (§5.0).
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
- An optional exact selector contributes no grant when absent, and the
  boundary still starts.
- `(capability_available? spec)` answers `false` for an absent optional
  selector and for an undeclared one, mints nothing, and never reaches the
  parent context.
- `^^optional` in an expression position is rejected, not treated as a
  presence check.
- A parameter-dependent `fs/WriteFile` selector rejects path escape.
- The standard-library filesystem adapter independently enforces its resolved
  root and rights.
- `with_capabilities` can narrow a call and cannot widen it.
- **An import-site ceiling bounds a dependency the importer does not control**
  (§5.3.1): calls into it receive
  `caller ∩ module_ceiling ∩ import_ceiling`, an import ceiling cannot restore
  authority the module row or the caller dropped, and the module still has
  exactly one runtime instance shared by bounded and unbounded importers.
- **A module bounded by an import ceiling initializes under an empty context**,
  so a dependency cannot capture protected data at load time and retain it as
  ordinary values past the bound. The order-dependent residual in §5.3.1 — a
  module already initialized by an earlier unbounded importer — is a known
  deferral, not a passing case.
- **`^require_strict_dependencies` fails the link** when any dependency was
  compiled in open mode, names every offender, and does not recompile the
  dependency under a mode its author did not choose (§5.0.2).
- Context restoration works for return, error, cancellation, and non-local
  control flow.
- Multiple non-equivalent matching grants produce
  `AmbiguousCapability`.
- Protocol implementations cannot broaden public capability contracts.
- **An open-mode application with no `^capabilities` anywhere — no entry row,
  no module rows, no function rows — compiles and runs with whatever the host
  granted**, and declaration processing changes nothing about its behaviour.
  "Full authority" here means the host root (§5.1), which for `gene run`
  defaults to the launch directory — not the whole filesystem. A program
  reaching outside it is denied until `--allow_*` or an embedding host says
  otherwise, and that denial is the design working.
- **Ceilings materialize once, between load and `main`** (§5.2.1): no row is
  resolved during module loading, and none is resolved per call. A module
  loaded lazily after that phase gets the same ceiling it would have had.
- After the normalization pass (§5.0.2) no runtime structure records
  `capabilities_mode`; a precompiled package behaves identically in an open
  and a strict application, and `^require_strict_dependencies` fails at link
  rather than recompiling the dependency.
- A Gene-defined capability type works end to end across the four bootstrap
  phases (§4.6.0), and no phase permits installing or replacing a provider
  after host boot.
- Switching a module to strict mode is the only thing that turns its missing
  rows into errors; reflection reports it as unenforced until then.
- **An open module nested inside a strict one gains no authority**: it
  inherits the strict parent's narrowed context and is denied anything outside
  it. `open -> strict -> open -> strict` attenuates monotonically at every
  step.
- A strict module importing an open library runs: the library's undeclared
  exports behave as `^capabilities *`, still bounded by its module ceiling and
  the importing context.
- In strict mode, an exported function, method, or protocol message with no
  `^capabilities` row is a compile error; the same declaration marked private
  compiles and inherits `caller ∩ module ceiling`. So a module granted `fs/*`
  cannot hand an undeclared exported helper ambient authority.
- `^capabilities *` on an exported function is the pass-through, so the
  migration is mechanical.
- A pass-through module in an open application can retain legacy top-level
  behavior. A module with a narrowing row initializes empty, and an open
  import below a narrowed entry can inherit only that empty initialization
  context.
- Spawned tasks receive the intended immutable context without global
  contention.
- Capability-free call benchmarks show no material avoidable regression.

Open-protocol criteria (§3.1, §3.2.2):

- A type that does not explicitly implement `CapabilitySpec` is rejected in a
  selector position, even if it defines methods with the right names.
- A capability type whose provider the host did not admit is rejected in a
  selector position; Gene source cannot admit one, and the registry is frozen
  before program code runs.
- A cross-provider entailment edge is rejected in version 1.
- **Provider algebra (§3.2.3.1)**: `resolve` is deterministic by semantic key;
  `intersect` is commutative, associative, idempotent, and normalized; equal
  authority plus equal lineage gives equal keys within a run and epoch; both
  reject revoked inputs. Equal contexts therefore give equal results regardless of
  insertion order, and `AmbiguousCapability` is raised at the operation rather
  than during resolution. A provider violating any law fails the conformance
  suite admission (§3.2.4) requires.
- A user-defined capability type resolves and reflects exactly like a built-in
  one, and reflection reports the correct provider for both.
- **Intermediate narrowing is preserved.** With a host grant of `/` and an
  entry narrowing to `/tmp`, no nested boundary can obtain authority above
  `/tmp`, and a derivation attempted against the host root rather than the
  parent derivative is refused. A boundary's checked ceiling is the nearest
  sealed derivative, not the host root. This is the single most important test
  in this document.
- A `CapabilitySpec` implementation cannot cause a grant to be minted that its
  provider would refuse; it has no path to authority at all.
- `canonicalize` is idempotent; equivalent specifications produce identical
  context keys and fingerprints; one that raises surfaces as
  `CapabilityTypeError` and denies the boundary rather than falling through to
  ambient access.
- A library-provided `canonicalize` never runs during compilation — it runs at
  first use, is memoized, and is denied there if it attempts I/O.
- A user library cannot define a type that captures grants belonging to a
  reserved built-in namespace.
- `^capabilities *`, `^capabilities (fs/WriteDir "tmp")`, and the list form
  normalize to the same descriptors.
- A static built-in row compiles to a descriptor requiring no runtime parsing
  or allocation. A static custom row pays construction and canonicalization
  once at first use, then reuses the memoized canonical form. A
  parameter-dependent row adds cost only to its own boundary.

Performance criteria (§13):

Three tiers, because one unqualified claim was not achievable. A pure exported
function declaring `^capabilities []` must install and restore an empty
context when a capability-bearing caller invokes it; that cannot be
byte-identical to a pre-capability build without proof-based elimination, and
§5.0 now requires a row on every exported callable. State the tiers
separately so a regression in one is visible rather than averaged away:

- **Private intra-module capability-free calls: no measurable overhead**,
  reproduced across benchmark batches rather than in one run. This is the
  overwhelming majority of calls and the byte-identical claim applies here
  and only here.
- **Cross-module public calls: bounded, cached boundary cost.** A published
  per-call ceiling, met by the `(caller_context_id, callee_ceiling_id)` cache
  (§5.0), not by an unqualified "no overhead" claim. An import-site ceiling
  (§5.3.1) folds into the same key and must not add a second lookup.
- **Capability-declaring calls: measured cold and warm resolution costs**,
  reported separately. Cold pays canonicalization and provider resolution;
  warm pays the cached transition.
- A repeated static declaration hits the context-transition cache and costs a
  compare plus a load in steady state.
- Bumping the capability epoch invalidates cached transitions, and a stale
  transition is never reused after revocation. `CapabilitySpec` has one
  application-global implementation, so scoped dispatch cannot change a
  selector's meaning.
- A function declaring a parameter-dependent selector that policy cannot
  satisfy fails **before** the body runs, in every execution profile; the
  race-safe proof is still produced at the operation (§13.3).
- Replacing a path component between the boundary and the operation cannot
  make a write land outside the granted root.
- Built-in capability checks perform no dynamic protocol send.
- Repeated dynamic attenuation in a long-running loop does not grow context
  interning without bound, and releases grants and host handles.

Semantics criteria (§5.0, §6.4.1, §8.0, §10.1, §13.3):

- A *private* function with an omitted row receives
  `caller ∩ defining module ceiling`; one with `^capabilities []` receives an
  empty context; an *exported* one with no row does not compile (§5.0).
- **A module ceiling is materialized once, against `app_context`** (§5.2.1).
  A module declaring `(fs/WriteDir "tmp")` under an `app_context` of `/`
  yields `/tmp`; an intra-module call, and re-entry via `A -> B -> A`, both
  still see `/tmp` and never `/tmp/tmp` (§6.1).
- The same module entered from two differently-scoped callers has one ceiling
  and two different effective contexts, each `caller ∩ ceiling`.
- **Cross-type intersection survives.** A context holding `fs/WriteDir "/tmp"`
  intersected with one holding `fs/WriteFile "/tmp/a"` yields a usable grant
  for `/tmp/a`, not the empty context a type-keyed comparison would produce
  (§6.1, §3.2.3).
- A scoped or overlay implementation whose row exceeds its protocol message's
  is rejected **at registration or activation**, not at a later call that
  fails with MissingCapability (§5.5).
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
- No source-level operation yields a grant, proof, or authorization decision
  as a value — including via error values and closure capture. Adapters
  validate and execute in one call (§3.2.3), so there is nothing to capture,
  store, or replay.
- A narrowing module's initialization runs with an empty context, so a
  capability-requiring operation attempted there is denied. A pass-through
  module preserves open-mode initialization compatibility. There is exactly
  one runtime module instance regardless of context and no capability
  fingerprint in its key; lazy pass-through initialization uses the fixed
  application context rather than a first caller's transient context.
- A function declaring `(fs/WriteFile a)` cannot operate on `b`, in every
  execution profile: the declaration transformation is never elided (§13.5).
- An authority-bearing resource opened under a broad context and used inside
  a narrower one is authorized by the meet, so an operation the narrowing
  removed is refused (§10.2).
- A resource passed into an empty context is unusable.
- `provider.intersect` finds the overlap of two grants independently derived
  from one root where neither is an ancestor of the other; grant-identity
  comparison alone does not.
- A canonical specification containing a mutable collection or closure is
  rejected at canonicalization; mutating a value after insertion cannot
  change an already-cached transition.
- **A grant revoked after a proof is carried denies a second operation in the
  same frame.** So does revoking an *ancestor* of that grant, and revoking
  *either operand* of an `intersect` the grant descends from (§3.2.3).
- A broad caller invoking a `^capabilities *` function exported by a module
  whose ceiling is `^capabilities []` cannot perform an effect through it:
  the pass-through is still bounded by the defining module's ceiling (§5.0).
- An intra-module call to a private undeclared function performs no context
  work; a cross-module call into a differently-ceilinged module takes the
  cached meet.
- A cross-type `provider.resolve` mints a grant the target adapter accepts
  only when both types belong to that provider. Any cross-provider
  entailment is rejected in version 1.
- A provider implementing `resolve`, `intersect`, and `validity` but not
  `subsumes` is conforming: `subsumes` reads as `unknown`, which rejects at
  interface boundaries rather than admitting anything, and §5.5 still accepts
  exact canonical equality without it.
- `provider.intersect` returns a grant of a type present in NEITHER input
  when that is the true overlap of two related types, and the runtime keeps
  it.
- `provider.subsumes` returning `unknown` rejects a protocol implementation
  rather than accepting it.
- Concrete protocol-implementation compatibility is decided by the provider's
  `subsumes` relation, so untrusted specification code cannot make the
  compiler accept a broader implementation.

## 19. Deferred questions

Four questions that were previously here, or scattered as unresolved tensions,
have been **settled** and moved to §1.1: whether a public declaration is a
contract (§5.0), whether version 1 capability types must be provider-backed
(§3.1.1), whether resource possession delegates authority (§10.2), and what a
capability-type call means in expression position (§4.2, §6.2). They are
listed there because each one changes what ordinary code looks like, and
deferring them would have left the compiler, protocol-substitution, caching,
and revocation detail resting on unmade decisions.

The following can be decided during implementation without changing the core
model:

- richer host policy-file syntax and the final embedding configuration API.
  The minimal CLI directory options are fixed in §5.1; arbitrary capability
  schemas and external policy documents remain deferred;
- whether revoked grants use epochs, handles, or provider callbacks;
- whether `describe`'s default implementation is derived structurally from
  the canonical form or supplied per namespace;
- which route out of the version-1 host-backed restriction to take, if either:
  a generic provider for application-defined nominal policies, or an explicit
  advisory arm (§3.2.2 records both and why neither is version 1). This is
  deferred as *which*, not *whether* — version 1 is host-backed regardless;
- if the advisory route is taken, whether advisory types require an explicit
  marker at declaration rather than only being reported by reflection;
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
