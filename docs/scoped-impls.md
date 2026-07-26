# Scoped and Co-located Protocol Implementations

**Status:** implemented 2026-07-21, revised 2026-07-24 —
canonical/scoped/overlay classification and activation, `import_impl`,
per-identity nearest-receiver resolution, declaration-scope conformance, and
transactional reload live in `src/gene/compiler.nim` and `src/gene/vm.nim`;
behavior is pinned by `tests/test_protocols.nim`, `tests/test_modules.nim`, and
the impl-visibility suites in `tests/spec_runner.nim`. The compile-time
candidate-set analysis described by earlier revisions of §2 was removed when
unqualified sends became type-direct only.

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

## 2. Message resolution

An unqualified send `(x ~ m)` reaches only the receiver's type-direct messages,
walking `^is` (`docs/design.md` §3). It never reaches a protocol impl, so a send
site carries no protocol candidate set and simple-name ambiguity cannot arise
from one.

A protocol message is always qualified — `(x ~ P:m)` — which names exactly one
message identity. `P` must resolve as an ordinary binding at the send site.
Choosing the impl for that identity happens at dispatch time, against the
receiver's runtime type and in the send's visibility scope (§4).

Because the identity is fixed where the send is written, later loading cannot
make a send ambiguous. Activation can only change which impl is selected for an
identity that was already named, which §4's per-identity receiver-depth rule
governs.

> Superseded: earlier revisions specified a compile-time `Must`/`Whole`/`Entry`
> candidate set for unqualified sends. Removed in `4bb95f9`.

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

After an assembly unit publishes, every protocol it resolved has an initialized
defining scope. For module-owned protocols and receiver types, canonical impls in
either eligible loaded home are active. During assembly a forward protocol
binding may still be uninitialized; no cross-module or devirtualization guarantee
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

Resolve receiver depth independently for each message identity:

1. collect that identity's providers along the receiver's single `^is` chain;
2. retain only its providers at the nearest applicable receiver depth; and
3. require exactly one provider at that depth.

A qualified send names its identity, so unrelated same-name identities never
compete: `A/render` surviving at `Child` and `B/render` at `Parent` are simply two
different sends. Receiver depth chooses only among providers of one identity.

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
homes, exports, and whether a pair is unconditional.

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
- conditional imports leaving qualified lookup to follow the runtime binding;
- caught missing-module and coherence failures leaving no impl registered;
- same-identity ancestor/descendant impl conflicts failing at assembly;
- marker ancestors and per-identity nearest-receiver behavior;
- unrelated same-name protocols staying distinct because each send names one
  identity;
- call-site module dispatch and caller-scoped impl invisibility in libraries;
- callable, property, and `(List P)` conformance using declaration scope;
- all three `^impl` validation barriers;
- reload success, importer breakage rejection, and live-overlay caveats;
- guarded direct-call invalidation after activation/reload; and
- absence of individual module unload in MVP.

`docs/design.md` §10/§10.1 and the conformance and dispatch text in
`docs/core.md` §3.5/§9 must stay consistent with this file.
