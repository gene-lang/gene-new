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

**The important exception.** A user-defined capability type with **no
underlying sealed grant and no trusted adapter** — a pure-Gene
`app/PublishTopic` enforced only by library code that reads the effective
specification — has no second layer. There the specification *is* the
enforcement, and a buggy `attenuate` is a real hole.

Two consequences:

- Such types are honest policy *documentation* and useful composition, but
  they are not a security boundary against code that can call the underlying
  library directly.
- A capability type that wants to be a real boundary must be backed by a
  host-issued grant and an adapter that validates against it. The runtime
  should be able to report which capability types are adapter-backed, so a
  reviewer can tell load-bearing types from advisory ones.

This distinction should appear in reflection (§11) rather than living only in
readers' heads.

A filesystem grant should ultimately be backed by a trusted root handle and a
rights mask, not merely by a source-visible path string. A network grant may
hold an endpoint policy. A compute grant may hold a queue or device handle.

Two grants of the same capability type may coexist. For example, an entry
context may contain separate writable roots for `tmp` and `output`.

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
*meaningful* rather than merely safe. For an advisory capability type with no
provider and no sealed grant behind it, only the second exists — which is why
§3.2.2 and §11 insist that distinction be visible.

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
adapter-backed types, and a restricted schema or isolated execution for
advisory ones. `^optional` is consumed by the capability system before the
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
- **Advisory types** (§3.2.2): either restrict them to a declarative
  specification schema the compiler evaluates itself, or run their
  constructor and `canonicalize` under isolated execution — frozen inputs,
  deterministic APIs only, instruction and memory limits, denial on breach.
- Where neither is available at compile time, defer canonicalization to first
  use and memoize it. Deferral is always sound; it costs one resolution.

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
| function / method | **inherit unchanged** | empty context |
| protocol message | **inherit unchanged** | empty context |
| `with_capabilities` | n/a — row required | empty context |

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

The entry selector list is resolved against the host root. The resulting
context, not the complete host context, is inherited by the entry module's
body and imports.

This is the main policy point controlled by the application developer.

For an entry or imported module, an omitted or explicitly empty
`^capabilities` row means an empty context. There is no implicit inherit-all
behavior at a module boundary. Functions differ — see the defaults table in
§5.0.

### 5.3 Imported modules

An imported module resolves its own declaration against the context made
available by its importer:

```gene
(mod report
  ^capabilities [fs/*])
```

This passes through only the importer's filesystem grants. If the importer
removed network access, the imported module cannot recover it.

Module initialization executes under the module's selected context. A module
initialized with broad authority must not be reused accidentally in a
narrower context.

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

The workable split is: types, protocols, and implementations are shared and
context-independent; module-level *mutable state and any authority-bearing
value captured at initialization* are per-context. A module whose
initialization captures no authority needs only one instance, which should be
the common case and should be detectable statically.

The fingerprint must include **grant and provider provenance**, not only the
canonical visible selectors. Two roots with the same selector shape but
different underlying grants must not share initialized authority-bearing
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

For **fully concrete** selectors this check routes through `attenuate`, not
through a separate subsumption oracle (§3.1.1):

```text
message_spec.attenuate(impl_spec) must succeed and yield impl_spec
```

If it returns `nil`, the implementation demands authority the public contract
does not promise. If it returns something narrower than `impl_spec`, the
implementation's declaration is broader than the contract can supply. Both
are rejections, and using one operation for the runtime narrowing and the
concrete contract check means the two cannot disagree.

**This does not generalize to parameter-dependent selectors.** "No broader
for every valid parent context" is universally quantified over runtime
arguments, and a single concrete `attenuate` call cannot establish it — the
two specifications may reference different parameter slots entirely. The
check must therefore be a conservative *symbolic* relation:

- accept when message and implementation reference the **identical parameter
  slot** with the implementation's literal arguments statically narrowing the
  message's;
- accept when both are fully concrete and `attenuate` succeeds as above;
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

At each module, call, or explicit attenuation boundary:

```text
parent = active capability context
ceiling = enclosing module or entry ceiling
available = intersection(parent, ceiling)
selected = resolve(declaration selectors, available)

if a mandatory exact selector is unsatisfied:
  fail before executing the body

child = immutable context containing selected grants
execute under child
```

Namespace projections contribute every matching available grant. Exact
selectors contribute matching grants or attenuated derivatives.

The result is always a subset of or attenuation of `available`.

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
answer:  attenuate decides whether a candidate edge's scope actually covers
         this request
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

`attenuate` decides scope along a candidate edge. It is not the
candidate-discovery mechanism.

### 8.1 Built-in and custom capability types

Both are first-class. They differ in who provides them and in whether they
are adapter-backed (§3.2.2), not in how they are declared or resolved.

**Built-in capabilities** are provided by the runtime and standard library —
filesystem access, environment variables, dynamic-library loading, clock,
network. They need **no import**: `fs/WriteDir` is reachable wherever a
selector is legal. They are adapter-backed, so they are real security
boundaries. Their namespaces are reserved; a user library cannot define a
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

A custom type is a *security* boundary only if it is adapter-backed by a
host-issued grant. Otherwise it is advisory — see §3.2.2, which is the more
important half of this distinction and should be read alongside it.

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

The same question applies to every authority-bearing *resource* — an open
file handle, a connected client, a device queue — acquired under a broad
context and used under a narrow one. Version 1 does not solve this in
general; it must at minimum be stated as a known limitation, and adapters
should prefer designs where a handle re-checks its originating grant at each
operation rather than trusting its own existence.

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

Reflection must also distinguish load-bearing capability types from advisory
ones (§3.2.2), since the two look identical in a declaration:

```gene
(capability_type_info fs/WriteDir)
# => {^adapter_backed true  ^provider "host/fs"}

(capability_type_info app/PublishTopic)
# => {^adapter_backed false ^provider nil}
```

A reviewer reading `^capabilities [(app/PublishTopic "events")]` cannot
otherwise tell whether that row is enforced by a trusted adapter or merely
documented by a library. Tooling should mark advisory rows explicitly.

Useful tooling includes:

- listing the entry ceiling;
- reporting which capability types in a program are advisory rather than
  adapter-backed;
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
- an implementation broader than its protocol message (via `attenuate`, §5.5);
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
  non-declaring functions. Non-declaring functions are byte-identical to
  today.
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

What may be deferred is the **proof**, never the **constraint**. An earlier
draft of this section proposed checking only that the context held *some*
grant able to entail `fs/WriteFile`, and deferring everything else. That is
wrong, and badly so: it converts an exact declaration into broad filesystem
authority. A body declaring `(fs/WriteFile filename)` would still hold the
parent's `WriteDir` grant and could write any other path beneath it, which
defeats §4.5, §6.1 and §7.3 rather than merely weakening diagnostics.

The child context must carry an **immutable deferred constraint bound to the
parameter**, established at entry:

```text
child context holds:
  the parent grant, wrapped by a deferred constraint
  { type: fs/WriteFile, template: <symbolic selector>, bindings: [slot 0] }
```

Properties this must have:

- Every operation performed in the body, and in every nested call that
  inherits this context, resolves through the constraint. It is part of the
  context, not a memo on the side.
- `(fs/write_file other content)` **fails** even when `other` is beneath the
  parent root, because the constraint names `filename`, not the root.
- The hidden frame slot caches the *resolved proof for the bound value*. It
  is an optimization over a constraint that already exists — not the
  mechanism by which the constraint exists.

What is genuinely saved is the expensive half: path canonicalization, escape
rejection, and symlink policy run once at first use rather than at entry, and
not at all if the body returns without performing the operation. Establishing
the constraint itself is cheap — binding a slot into an interned template.

The residual cost is a narrower fail-fast guarantee for *scope* errors: a
path escape surfaces at first use rather than at entry. Absence of any
satisfying grant can still be detected at entry and should be, since that
check is context-id-cacheable per §13.2.

### 13.4 Built-in types bypass the protocol

`CapabilitySpec` is the extension mechanism, not the hot path. Runtime and
standard-library types implement `canonicalize` and `attenuate` natively, and
the runtime calls them directly through the interned type ID. A filesystem
check must not become a dynamic protocol send, and a security boundary must
not depend on inline-cache behaviour for its cost profile. Only user-defined
types dispatch, and they are the ones already off the hot path.

### 13.5 Entry checks are elidable; adapter checks are not

The strongest lever, if the above is still not enough.

§7.4 establishes two enforcement layers, and they have different jobs: the
function-entry check gives clear contracts and early diagnostics, while the
**native adapter is the security boundary**. That layering means entry checks
can be reduced or elided in a release profile without weakening security —
the adapter still refuses the operation against the sealed grant.

If this is done it must be explicit and audited, because two properties are
lost: effects that occur before a denial are no longer prevented (a function
may do half its work before the adapter refuses), and the diagnostic quality
drops sharply. The recommendation is to keep entry checks on by default,
treat elision as a measured optimization for a proven-hot boundary, and never
allow the adapter layer to be configurable at all.

An adapter check on a real filesystem or network operation is noise next to
the syscall it guards, so the security boundary is affordable regardless of
what happens to the diagnostic layer.

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
- an error value must not accidentally carry a forgeable grant;
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

## 17. Migration from the current runtime

The current filesystem capability representation is useful as a starting
point but name-only capability data and raw host paths do not provide scoped
confinement.

Two migration facts that are easy to miss:

**This is a source-level API change, not only a representation change.** The
runtime today spells built-in capabilities `$fs/ReadDir` — see the
`fs/read_text expects (fs/ReadDir, path)` diagnostics in `stdlib.nim` — and
passes them as explicit arguments. This proposal makes `fs/ReadDir` an
ambient descriptor resolved from the active context. Existing call sites
change, so the migration needs a deprecation path and a mechanical rewrite,
not just an internal swap.

**The launcher boot order must change.** `gene run` currently loads and
executes the entry module and *then* evaluates `--grant` expressions in that
module's scope. That cannot remain the authority-origin path: the entry
ceiling has to exist before the entry module's top-level imports and forms
run, or module initialization happens with undefined authority. Step 4 below
therefore requires reordering boot to: parse trusted host policy, mint the
root context, *then* load the entry module under its declared ceiling.
Evaluating grant expressions from an already-running entry scope is exactly
the source-can-mint-authority pattern §5.1 forbids.

Migration should proceed in layers:

1. Introduce interned `CapabilityType`, immutable
   `CapabilityContext`, and unforgeable `CapabilityGrant` runtime values.
2. Parse and normalize list-form `^capabilities` rows.
3. Implement exact selectors, `^^optional`, and namespace projections.
4. Establish host-root and entry-module ceilings.
5. Apply function, method, and protocol-message boundary checks.
6. Add `with_capabilities` with exception-safe dynamic extent.
7. Convert filesystem adapters to root-handle-based confinement.
8. Convert standard-library APIs to parameter-dependent selectors.
9. Add task propagation, reflection, and module-cache fingerprints.
10. Add static protocol and selector validation.

During migration, any compatibility path that wraps a raw path must remain
trusted-host-only. It must not be exposed as a source-level capability
constructor.

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
- Module caching cannot reuse a broadly initialized instance in a narrower
  incompatible context.
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
- Reflection reports `adapter_backed` correctly for a built-in and for a
  pure-Gene capability type.
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
- A function declaring a parameter-dependent selector that returns before
  performing the operation does not compute an operation proof.
- Built-in capability checks perform no dynamic protocol send.
- Repeated dynamic attenuation in a long-running loop does not grow context
  interning without bound, and releases grants and host handles.

Semantics criteria (§5.0, §6.4.1, §8.0, §10.1, §13.3):

- A function with an omitted row inherits its caller's context unchanged; one
  with `^capabilities []` receives an empty context.
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
- A module whose initialization captures no authority is instantiated once
  across differing contexts; one that does capture authority is not shared.

## 19. Application: Gene as an agent's sole action surface

Added 2026-08-11. This section records a direction, not a committed design;
it changes no part of the model above. It exists because the machinery in
§11 and §12 turns out to answer a problem outside this proposal's original
scope, and that changes what this work is worth.

### The idea

An LLM agent today acts through *tool calls*: a name and typed arguments,
matched against a schema. The proposal here is to delete that surface
entirely and give the agent one way to act — **emit a Gene program, executed
by the interpreter under an explicit capability grant.**

The immediate win is composition. A tool call is a single invocation;
composing several means round-tripping through the model's context (call,
read result, reason, call again). A program expresses control flow,
iteration, composition, and error handling in one emission, so a multi-step
action costs one turn instead of N.

That argument is not specific to Gene — it is the general "code as action"
case, and it applies to a Python sandbox equally. What is specific to Gene
is the *second* half.

### Why capabilities are the load-bearing part

The reason code-as-action is not already the default is authorization
granularity. A tool call is narrow and inspectable: a human or policy engine
can approve `read_file("/etc/hosts")` on its own terms. Arbitrary code is
not reviewable that way, and a coarse sandbox grant ("you may touch the
filesystem") authorizes far more than any individual tool call would. Moving
to programs therefore trades *per-action* authorization for *per-session*
authorization, which is a real loss of control, not a detail of
implementation.

This proposal narrows that gap, within limits that must be stated. §11's
`(capabilities_of f)` returns canonical selectors; §12 can reject "a call
whose statically known context cannot satisfy a mandatory selector". Together
they support a **pre-execution verifier**: given a candidate program and a
grant, decide whether the program can exercise authority beyond the grant.

**Complete capability enumeration is not available for arbitrary Gene
programs.** §12 already concedes that dynamic dispatch, plugins, host policy
and runtime values require runtime checks; add higher-order calls, `eval`,
fexprs, dynamic imports, native extensions, and open protocol
implementations, and static enumeration is undecidable in the general case.
§5.0 compounds this: an undeclared function is effect-polymorphic, so its
requirement must be *inferred* transitively rather than read off.

The verifier is therefore sound only on a restricted subset, and its
rejection policy is part of its definition:

- closed-world imports, resolved before verification;
- no `eval`, no dynamic module loading, no native library loading;
- every call target statically resolvable, so every reachable callable has a
  computed capability summary;
- open-protocol dispatch permitted only where the implementation set is
  frozen;
- **anything unresolved is rejected, not assumed capability-free.**

Within that subset the claim holds and is stronger than a tool-call schema,
because a schema constrains the shape of one request while a capability bound
constrains everything the program can reach. Outside it, the honest position
is that the runtime boundary is the enforcement and the verifier is a filter
that refuses to certify what it cannot analyze.

This also depends on §5.0's omitted-declaration semantics and on §10.1
keeping authority out of values; if proofs became first-class, the verifier
would have to track authority through data flow, not just call structure.

Parameter-dependent selectors matter here more than anywhere else in this
document. `fs/WriteFile` narrowed by an argument is what lets a grant say
"this program may write exactly the file it was given", which is the
tool-call guarantee recovered inside a program.

### What this direction does *not* require

Worth stating plainly, because it was initially conflated with adjacent work:

- **It does not require the reversible native program format**, nor any
  model trained on it. The agent emits ordinary `.gene` *text*. See
  `reversible-ai-native-program-format.md` §"Model-training track status".
- **It does not require training a model at all.** Current frontier models
  write valid, non-trivial Gene by generalizing from other Lisps and reading
  the reference; a curated skill closes most of the remaining gap. A
  fine-tuned small model is strictly worse for this purpose, since it trades
  away the general reasoning that makes an agent useful.
- **It is available now**, ahead of the rest of this proposal, in a reduced
  form: run untrusted programs under a coarse grant, with the verifier added
  as the enforcement layer once §12 lands.

### Open problems

These are the reasons "completely replace tool calls" is a goal rather than
a conclusion:

- **Partial execution.** A malformed tool call is rejected whole. A program
  can fail halfway with some effects already applied. Capability bounds
  limit *what* can happen, not *how much of it* happened before the failure.
  Transactional or compensating semantics are an open question.
- **Adaptation.** Tool calls let a model observe a result and change course.
  A program is fire-and-forget unless it can suspend and resume. Gene's
  tasks, channels, and actors make this expressible; the interface an agent
  should see is undesigned.
- **Reviewability.** A capability bound is machine-checkable but not
  human-legible. A person approving an action wants to know what it will do,
  not only what it may reach. Rendering a verified program's intended effects
  back into something reviewable is unsolved.
- **Model competence.** Models are meaningfully weaker at Gene than at
  Python, and pretraining exposure makes that gap durable. The direction pays
  only if verified capability-bounded execution is worth more than that
  competence costs. It probably is — it is a safety property unobtainable
  from a Python sandbox at any model scale — but this is the assumption the
  whole direction rests on and should be stated before building, not after.

### What would make this concrete

In rough dependency order:

1. §12 static checking, specifically capability enumeration over a whole
   program rather than a single call boundary.
2. A host entry that accepts a program plus a grant and refuses to execute
   when enumeration exceeds the grant.
3. A capability-free verdict on a known-pure corpus as the verifier's first
   test: `training/corpus/generated/` holds 1002 programs that are pure
   computation by construction, so every one should enumerate to the empty
   set. Anything else is a verifier bug or a genuine surprise.
4. A Gene skill, so the model's output is good enough that verification
   failures are about authority rather than syntax.

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
