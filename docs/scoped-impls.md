# Scoped and Co-located Protocol Implementations

**Status:** implemented 2026-07-21 — compiler Must/Whole/Entry candidate
analysis, canonical/scoped/overlay classification and activation,
`import_impl`, per-identity nearest-receiver resolution, declaration-scope
conformance, and transactional reload live in `src/gene/compiler.nim` and
`src/gene/vm.nim`; behavior is pinned by `tests/test_protocols.nim`,
`tests/test_modules.nim`, and the impl-visibility suites in
`tests/spec_runner.nim`.

**Decision:** an impl is globally visible when it is defined with its protocol
or receiver type. Every other impl is module-local unless explicitly exported
and explicitly imported.

This design replaced the activation/visibility rules previously stated in
`docs/design.md` §10/§10.1 and refines protocol conformance and message
resolution in `docs/core.md` §3.5/§9.

## 1. Model

There are three impl classes:

| Class | Definition site | Visibility |
| --- | --- | --- |
| Canonical | Protocol or receiver type's home module | All loaded modules |
| Scoped | Any other static module-level site | Defining module, plus explicit importers |
| Overlay | Eval or any non-static/non-top-level site | Capturing lexical scope only |

```gene
# canonical: defined in ToJson's or Url's module
(impl ToJson for Url ...)

# scoped: defined elsewhere
(impl ToJson for Url
  ^export true
  ...)

(import_impl ToJson for Url from "lib/pretty_json")
```

Canonical impls provide behavior that travels with values. Scoped impls are
explicit local policy. Overlays support eval and runtime-local declarations.
No layer silently overrides another.

## 2. Message candidates

### 2.1 Fixed candidate references

An unqualified send `(x ~ render)` has a compile-time set of **protocol
references** declaring `render`. A reference is either an imported interface
identity or an immutable lexical slot for a protocol declaration. The set of
references never grows after the send is compiled, although a local slot may
be initialized later and impl applicability remains dynamic.

This slot model preserves ordinary forward references. For a compiled unit
`U`, the compiler computes:

- `Must(U, p)`: protocol references established on every control-flow path
  reaching point `p`;
- `Whole(U)`: references established on every successful normal exit from
  `U`; and
- `Entry(U)`: references guaranteed before `U` starts.

A send executed directly in `U` uses `Must(U, send)`. A nested function or
closure declared at `d` receives:

```text
Entry(nested) = Must(U, d) + Whole(U) + interface references of nested
```

`Whole(U)` is a post-pass over the entire unit, not a declaration-point
snapshot. Therefore these existing patterns remain valid:

- a top-level function may send a message declared by a later protocol;
- a factory may create a closure before a later protocol declaration and
  return it after that declaration runs; and
- a closure may exist before an impl is registered and use it afterward.

Only references guaranteed on every normal exit enter `Whole(U)`. A local
protocol slot is captured per module/eval/invocation scope, so a factory's
runtime-created protocol identity remains specific to that invocation.

If a nested callable is invoked before a forward slot is initialized, that
reference is ineligible and a failed send names the uninitialized protocol
candidate. Successfully returning/publishing a unit whose `Whole(U)` contains
the slot guarantees initialization first.

### 2.2 Control flow, failures, and entry state

`Must` is a forward must-analysis. A join intersects predecessor sets by exact
protocol reference. Equal-identity imports in every branch survive; an import
in only one branch and an import in a possibly-empty loop do not survive the
join. Inside the importing branch or loop iteration, the reference is present.

The CFG includes exceptional edges. A declaration/import adds its reference
only to its successful normal successor, after binding installation and module
activation commit. An edge into `catch` or `ensure` carries the pre-form set.
Thus a caught missing-module or coherence failure does not make the imported
protocol available after the `try`. An uncaught edge that cannot reach the send
does not participate in that send's join.

Entry state is explicit:

- a module starts with protocols guaranteed by its parent/prelude and imports
  completed before body entry;
- a nested unit uses the formula above, including protocol identities closed
  into its parameter/return or re-exported message interface; and
- each eval/REPL unit snapshots protocol bindings in its associated `Env` and
  parent chain when compiled.

Completed imports contribute their visible protocol/message interfaces and
re-exports transitively. A seeded protocol's home must already be loaded.
Merely existing in the global canonical registry does not seed a candidate.
A later environment mutation can affect qualified lookup and later eval units,
but never changes an already-compiled unqualified send.

Conditional imports intentionally split qualified and unqualified behavior.
After a one-arm import, the persistent module binding may make `(x ~ P/m)`
work on executions where `P` has been initialized. A post-join `(x ~ m)` does
not gain `P`, because `P` was not established on every path. Move the send into
the branch or establish the same protocol on every path to use the unqualified
form.

### 2.3 Dynamic selection

At runtime, initialized candidate references are filtered to protocols with an
impl applicable to the receiver's runtime type in the send's visibility scope:

- zero applicable candidates: missing implementation;
- one: dispatch;
- more than one: ambiguous simple message name.

Qualification `(x ~ P/render)` selects the exact message identity and bypasses
simple-name ambiguity. It still requires `P` to resolve as an ordinary binding.

A closed candidate set does not imply a stable result. If a module already
knows unrelated `A/render` and `B/render`, later activation of canonical
`impl Q for T` where `Q ^inherit [B]` can make the existing `B/render`
candidate applicable and turn a formerly unique send ambiguous. Loading a new
protocol reference not already in the set cannot extend the send.

## 3. Impl classification and activation

### 3.1 Canonical impls

A standalone impl is canonical only when:

1. it is in an unconditional static top-level position;
2. protocol and receiver are statically resolvable paths; and
3. the defining module owns the protocol or receiver type.

Inline impls and successful `^derive` results on a top-level type are canonical
because they live with the receiver. A derive may produce no pair; successful
results must target the deriving type, and duplicate pairs are errors. Derived
pairs are runtime activation facts, not unconditional AOT facts.

There are two eligible homes for `(P, T)`. With the MVP's acyclic import graph,
defining the same pair in both homes requires a rejected cycle. Duplicate
definitions within one home still fail. If declaration-only cycles are added,
the receiver's module becomes the sole home inside such a cycle.

Canonical impls activate atomically when their module finishes loading. Module
loading is executable: a conditional/runtime import activates only when reached,
and a caught failure leaves its binding and registration unpublished. Every
execution that attempts two incompatible activations rejects the second; an
execution that never reaches one import need not fail.

After an assembly unit publishes, every resolved candidate's defining scope is
initialized. For module-owned protocols and receiver types, canonical impls in
either eligible loaded home are active. During assembly, a forward candidate
slot may still be uninitialized; no cross-module or devirtualization guarantee
applies until the assembly boundary commits.

### 3.2 Scoped and overlay impls

A static top-level impl outside both homes is scoped. It is visible in its
defining module. `^export true` makes it importable, and
`import_impl P for T from "path"` imports exactly that exported pair. There is
no aliasing, renaming, or re-export in MVP. Canonical impls cannot be exported.

An impl with computed operands, under control flow, inside a callable, or in an
eval unit is an overlay impl. It executes normally but is never exportable,
importable, canonical, or an AOT fact. `^export true` on it is an error.

Today a top-level impl with a computed protocol or receiver can become globally
visible. This proposal makes it overlay-only, so the compiler must diagnose
every such form even without `^export true`. The diagnostic must identify the
non-static operand and state that the impl is not visible to other modules.

## 4. Visibility and coherence

A module's base scope contains all canonical impls from loaded modules plus its
own and explicitly imported scoped impls. Active lexical overlays join that
pool. Layers decide membership, never precedence.

Dispatch uses the module containing the send, not the caller's module. A
library send cannot see a scoped impl imported only by its caller. Behavior
that must cross a module boundary belongs in a canonical impl; otherwise pass
the produced value or an explicit callback.

Resolve receiver depth independently for each candidate message identity:

1. collect that identity's providers along the receiver's single `^is` chain;
2. retain only its providers at the nearest applicable receiver depth; and
3. require exactly one provider at that depth.

After this per-identity resolution, an unqualified send requires exactly one
surviving identity. Receiver depth never chooses between unrelated identities:
if `A/render` survives at `Child` and unrelated `B/render` survives at
`Parent`, `(child ~ render)` is ambiguous. Qualification selects one identity.

An impl of child protocol `Q ^inherit [P]` supplies inherited `P` message
identities. `impl P for T` and `impl Q for T` therefore conflict at the same
receiver and are rejected when the second registration becomes visible, even
if the program never sends the overlapping message. Marker ancestors with no
messages do not conflict. Impl registrations at different receiver depths are
legal; the nearest receiver wins only within the same message identity.

Base-scope conflicts are detected when a module scope is assembled. A reverse
index from `(receiver, message identity)` to loaded module scopes lets later
canonical activation check scoped registrations without scanning all modules.
The index is intentionally not keyed by simple name: unrelated `A/render` and
`B/render` may coexist, with ambiguity only in a send that knows both.

Overlay scopes are not globally enumerable. Registration rejects conflicts
already visible to the overlay, but a later canonical activation may conflict
with a live overlay; the next affected send reports that ambiguity.

## 5. Protocol conformance

Conformance uses the same lexical visibility scope as dispatch, not a separate
canonical-only registry. When protocol-as-type annotations are implemented,
`[x : P]` on a callable is checked in the callable's defining scope. An
app-scoped impl can satisfy an app callable but not an otherwise identical
library callable. Canonical conformance works in both.

The same rule applies to data. A property such as
`(type Box ^props {^item P})` uses `Box`'s declaration scope. A receiving
`(List P)` annotation rechecks elements in the receiving annotation's scope.
Protocol-typed data crossing modules therefore normally needs canonical
element conformance.

Parameterized container checks are element-wise. Without a cache, `(List P)`
is O(elements) per typed boundary and a scope-local proof cannot be reused in a
different scope. A cache must include container mutation/version, closed type,
scope identity/version, and activation epoch. Only a proof using canonical
impls exclusively may be reused across scopes. No cache may enlarge `Value` or
add work to scalar dispatch.

`^impl [P]` remains a requirement, not a source of conformance. It is checked:

- for a top-level type, before its module commits;
- for an eval type, before the eval unit publishes; and
- for any other overlay type, before the `type` form yields a usable value.

Inline impls and derives run before the last barrier. A later standalone impl
in the same invocation cannot retroactively satisfy it. Protocol inheritance
counts, and a scoped impl satisfies the requirement only in a scope that sees
it.

## 6. Reload and lifetime

Reload builds a prospective canonical registry and prospective base scopes for
the reloaded module and affected importers. It removes old registrations before
adding replacements, then validates pair/message coherence, reverse-index
constraints, and module-level `^impl` requirements.

An `import_impl P for T` re-resolves only to the same exported pair. Removing,
hiding, or renaming that pair while it has importers rejects reload. Changing
its transitive message identities revalidates every importer. Success commits
registrations, importer references, indexes, caches, and one new activation
epoch atomically; failure preserves the old state.

Live overlays are outside this transaction. Reload can succeed and later make
an overlay send ambiguous, or make a later conformance check fail for an
overlay type whose earlier `^impl` barrier passed. Atomic reload means no
partially committed enumerable state, not preservation of every live lexical
computation.

MVP has no individual module unload. Loaded modules persist until reload or
whole-application teardown. A future unload must be the removal-symmetric form
of reload and retain the same live-overlay caveat.

## 7. Compilation and performance

Module interfaces record protocol references, message identities, impl class,
homes, exports, and whether a pair is unconditional. Candidate construction
requires the `Must`/`Whole` CFG pass, including exceptional edges, plus entry
seeding from imported interfaces and eval environments.

A direct protocol call is allowed only when receiver type and winning
unconditional canonical pair are statically known and no overlay is reachable.
In a runtime with loading/reload it is guarded by the activation epoch; an
epoch change re-resolves and may report ambiguity. Only closed-world AOT may
omit the guard.

The reverse index adds no send-hot-path work. Protocol-typed aggregate
boundaries are separate: `nimble perf` must cover repeated same-scope and
cross-module `(List P)` checks at multiple sizes, reporting time and
allocations. Any cache must benchmark hit, mutation invalidation, scope-version
invalidation, and activation/reload invalidation.

## 8. Required verification

Add or amend executable specs for:

- canonical visibility across modules;
- scoped local visibility, export rules, and exact-pair `import_impl`;
- computed/non-top-level impls remaining overlay-only, with the required
  diagnostic for top-level computed operands;
- forward references from functions and factory closures to later protocols;
- closures created before an impl and dispatched after registration;
- one-arm imports excluded after joins, same-identity imports in every arm
  included, and qualified lookup following the runtime binding;
- caught missing-module and coherence failures contributing exceptional CFG
  edges without installing protocol candidates;
- eval entry seeding from successful prior units but not caught failed imports;
- transitive/re-exported protocol interfaces seeding nested units;
- same-identity ancestor/descendant impl conflicts failing at assembly;
- marker ancestors and per-identity nearest-receiver behavior;
- unrelated same-name protocols remaining ambiguous across different receiver
  depths, including later applicability ambiguity;
- call-site module dispatch and caller-scoped impl invisibility in libraries;
- callable, property, and `(List P)` conformance using declaration scope;
- all three `^impl` validation barriers;
- reload success, importer breakage rejection, and live-overlay caveats;
- guarded direct-call invalidation after activation/reload; and
- absence of individual module unload in MVP.

Update `docs/design.md` §10/§10.1 and the relevant conformance and dispatch
text in `docs/core.md` §3.5/§9 when this proposal is implemented.
