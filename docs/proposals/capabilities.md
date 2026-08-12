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
  (device/Compute ^optional true)
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
4. attenuate intersects it with the inherited specification.
5. The runtime retains the inherited *sealed grant* and attaches the
   narrower effective specification to it.
6. The adapter enforces both the sealed grant and the effective
   specification.
```

Step 5 is the crux and is expanded in §3.2.

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

### 3.2.2 What a hostile or buggy `attenuate` can do

The laws in §3.1.3 are obligations on implementers, and an open protocol
means some implementation will violate them — by accident or on purpose. The
design must be safe anyway, so state the bound explicitly:

Because the runtime keeps the **inherited sealed grant** and the adapter
checks it independently (§7.4's second enforcement layer), an `attenuate`
that returns something broader than `self` **cannot widen real authority**.
The worst it achieves is failing to narrow — leaving the caller with exactly
the authority the sealed grant already carried, which an ancestor had already
approved.

So for any capability backed by a host-issued grant:

```text
effective authority <= sealed grant, always, regardless of user code
```

The specification is *advisory narrowing*. The grant is the *hard ceiling*.

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
invariant therefore holds at two levels, and only one of them depends on
that code being correct:

```text
grant level          enforced by construction — a child context can only
                     ever hold grants the parent held, and the adapter
                     validates against the sealed grant

specification level  an obligation on the implementer (§3.1.3), bounded
                     by §3.2.2 — violating it fails to narrow, and cannot
                     widen past the sealed grant
```

The security invariant is the first. The second is what makes declarations
*meaningful* rather than merely safe. For an advisory capability type with no
sealed grant behind it, only the second exists — which is exactly why §3.2.2
insists that distinction be visible.

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

Note `^^optional` above: this document elsewhere writes `^optional true`.
Gene's `^^flag` sugar is exactly "this property, set to true", so `^^optional`
is the idiomatic spelling and both are the same property. Examples in this
document should be read as equivalent.

A declaration is a list of selectors:

```gene
(fn generate_report
  [source output]
  ^capabilities [
    (fs/ReadFile source)
    (fs/WriteFile output)
    (device/Compute ^optional true)
  ]
  ...)
```

An exact selector is mandatory by default. If no inherited grant satisfies it,
the boundary fails before the body runs.

The common property `^optional true` marks an exact selector as optional:

```gene
(device/Compute ^optional true)
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

This is why `^capabilities` rows can be validated and frozen without running
user program logic: constructing a specification is a constructor call and a
`canonicalize`, both required to be pure and total, not arbitrary evaluation.
`^optional` is consumed by the capability system before the type sees its
arguments; everything else is the type's own vocabulary.

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

Capability declarations must be processed at compile time so that runtime
performance is not affected. Taken literally that conflicts with §4.5:
`(fs/WriteFile filename)` names a runtime parameter, so it cannot be resolved
before the program runs. The requirement is real but applies to a specific
half of the work.

**Compile time** — all of it, for every declaration:

- parse the row and separate `^optional` from type-owned arguments;
- construct the specification via the canonical constructor (§4.2.1);
- run `canonicalize`, which must be pure and total;
- validate arguments, properties, and unknown-type errors;
- intern the capability type and namespace to compact IDs;
- reject a type that does not explicitly implement `CapabilitySpec`;
- emit a flat descriptor, with parameter references as slot indices.

By the time the program runs there is no parsing, no property-map building,
no string comparison of type names, and no allocation for a static row.

**Runtime** — only what genuinely depends on runtime values:

- binding parameter slots into a descriptor that references them;
- matching the descriptor against the active context;
- calling `attenuate` where the inherited grant is not an exact match.

So an entirely static row (`fs/*`, `(fs/WriteDir "tmp")`) is resolvable to a
context transformation at compile time, and its runtime cost is a context
pointer swap. A parameter-dependent row costs one match plus at most one
`attenuate` on the declaring function only.

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

An omitted or empty `^capabilities` row means an empty context. There is no
implicit inherit-all behavior.

### 5.3 Imported modules

An imported module resolves its own declaration against the context made
available by its importer:

```gene
(mod report
  ^capabilities [fs/*])
```

This passes through only the importer's filesystem grants. If the importer
removed network access, the imported module cannot recover it.

Module initialization executes under the module's selected context. Cached
module instances must include an appropriate capability-context identity or
policy fingerprint in their cache key. A module initialized with broad
authority must not be reused accidentally in a narrower context.

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
  (fn persist
    [this destination]
    ^capabilities [(fs/WriteFile destination)]))
```

An implementation may use the same or narrower authority. It must not demand
authority broader than the public message contract.

Formally, for every valid parent context, an implementation's selected
context must be no broader than the public message's selected context.

This check routes through `attenuate`, not through a separate subsumption
oracle (§3.1.1). For each selector the implementation declares:

```text
message_spec.attenuate(impl_spec) must succeed and yield impl_spec
```

If it returns `nil`, the implementation demands authority the public contract
does not promise, and the implementation is rejected. If it returns something
narrower than `impl_spec`, the implementation's own declaration is broader
than what the contract can supply, which is the same rejection. Using the one
operation for both the runtime narrowing and the static contract check means
the two can never disagree about what the message permits.

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

Exact selectors are mandatory unless `^optional true` is present.

```gene
^capabilities [
  (fs/WriteFile output)
  (device/Compute ^optional true)
]
```

The function cannot start without authority for `output`. It can start
without compute acceleration.

Within the body:

```gene
(if (device/Compute ^optional true)
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

They implement `CapabilitySpec` like any other type. Importing such a library
is safe at compile time because importing it executes no module body: the
import brings in a protocol implementation, and the only code that runs is
`canonicalize` (pure and total by §3.1.3) when a declaration is processed.

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

Low-level explicit-grant APIs may still be useful for adapters and advanced
code:

```gene
(fs/write_file_with proof filename content)
```

They do not replace declaration checks. They provide an explicit plumbing
escape hatch when multiple grants would otherwise be ambiguous.

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
penalize capability-free code.

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

- capability-free direct calls;
- one exact static selector;
- one parameter-dependent filesystem selector;
- `fs/*` over small and large contexts;
- nested `with_capabilities`;
- module initialization and cache lookup;
- task spawn with context capture.

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

Migration should proceed in layers:

1. Introduce interned `CapabilityType`, immutable
   `CapabilityContext`, and unforgeable `CapabilityGrant` runtime values.
2. Parse and normalize list-form `^capabilities` rows.
3. Implement exact selectors, `^optional true`, and namespace projections.
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
- **An `attenuate` that returns a specification broader than `self` does not
  widen real authority**: the adapter still refuses the operation on the
  sealed grant. This is the single most important test in this document, and
  it should exist as a deliberately hostile implementation in the test suite,
  not only as a property test.
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

This proposal closes exactly that gap. §11's `(capabilities_of f)` returns
canonical selectors; §12 can reject "a call whose statically known context
cannot satisfy a mandatory selector". Together they support a **pre-execution
verifier**: given a candidate program and a grant, decide whether the program
can exercise authority beyond the grant, and refuse to run it if so.

That converts "the model emitted arbitrary code" into "the model emitted code
statically bounded by these authorities" — which is a stronger claim than a
tool-call schema makes, because a schema constrains the *shape* of one
request while a capability bound constrains everything the program can reach.

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
