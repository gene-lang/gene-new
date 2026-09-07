# Gene Self Type Design

**Status:** Implemented in the compiler, VM, and web backend. See [implementation verification](reports/self-type-verification.md).

**Date:** 2026-09-05

**Updated:** 2026-09-07 — implementation and verification of impl-level inheritance, per-protocol bindings, declaration readiness, and backend contracts.

**Scope:** `Self` in type annotations, nominal inheritance, protocol conformance, overrides, and runtime dispatch.

**Decision:** Bind `Self` to a declaration or conformance, not to the receiver's runtime subtype. Use `^override true` on a type-direct message to declare replacement, or on a protocol `impl` to inherit and customize ancestor bodies. Newly supplied replacement signatures must not use contextual `Self`; both impl forms preserve inherited contracts.

## 1. Decision

`Self` in type annotations is **declaration-bound**, while message dispatch remains dynamic.

> The receiver's runtime type selects the implementation. The method's declared contract determines which arguments that implementation must accept.

These are separate operations. Inheriting a method must not narrow its argument contract merely because the actual receiver belongs to a subtype.

The implemented rules are:

| Context | Meaning of `Self` |
| --- | --- |
| A new method declared on `Dog` | `Dog` |
| A concrete method introducing behavior in `impl Eq for Dog` | `Dog` |
| An abstract requirement or default body inside non-universal `protocol Eq` | An abstract type parameter belonging to `Eq`, bound when its conformance is introduced |
| A new protocol extending an inherited protocol | Each protocol identity retains its own binding; newly introduced identities bind to the introducing receiver |
| A universal protocol's requirement/default closure | Dependence on abstract protocol `Self` is prohibited in the MVP (§6.5) |
| A method or protocol conformance inherited from `Dog` | Its existing `Dog` substitution, unchanged |
| A newly written method body on `Pup`, including an override body | `Pup` in body-local annotations |
| The newly supplied signature of a message replacing an ancestor provider, in either impl form or a type-direct declaration | Contextual `Self` is prohibited; name the inherited contract's types explicitly |

The substitution applies uniformly in parameter, return, and nested type positions. It is fixed for that declaration or conformance rather than recalculated at each invocation.

For type-direct messages, `^override true` remains a per-message declaration of replacement and requires an inherited target. For protocol implementations, the flag belongs on the `impl`: `(impl P for T ^^override ...)` inherits applicable ancestor bodies and replaces the supplied messages. An impl without the flag builds a complete implementation from local bodies and protocol defaults, borrowing no ancestor bodies. It may still replace ancestor behavior and must preserve the inherited conformance bindings and resolved contracts.

The impl flag controls body reuse. It does not create a new specialization of a protocol's `Self`, and its absence does not exempt a complete child implementation from compatibility checking. Protocol messages carry no per-message override flag.

Message bodies become callable only after their declaration's binding, override dependencies, and resolved signature are ready. Forward assembly must not create a temporary runtime interpretation that changes when later declarations initialize (§6.4).

This proposal does not change ordinary receiver-based dispatch, make `Self` mean an exact runtime type, or add a receiver-dependent type system. It retains Gene's MVP policy of exact inherited callable-signature compatibility and applies it to the resolved signatures. The override flag and the prohibition on `Self` in override signatures supplement that check; neither permits a narrower explicit type. [R1, R2]

## 2. Problem with runtime-relative `Self`

The previously documented rule substitutes the receiver's runtime type for `Self`. Its example intentionally allows:

```gene
(dog .Eq:eq pup)   # succeeds
(pup .Eq:eq dog)   # TypeError
```

For a `Dog` receiver, the inherited method accepts `Dog`. For a `Pup` receiver, the same method accepts only `Pup` and its descendants. That is a receiver-dependent contract, not a fixed inherited input contract. [R1]

Consider:

```gene
(fn compare_dogs [a : Dog, b : Dog] : Bool
  (a .Eq:eq b))
```

Both arguments admit a `Pup`. Nevertheless, placing a `Pup` in `a` can make an otherwise valid `Dog` in `b` unacceptable to the inherited method.

A runtime check can detect this mismatch. The concern is not that dynamic checking necessarily fails to protect the implementation; it is that a parent-type boundary no longer supplies the stable method-input contract that ordinary substitutability suggests.

For Gene's MVP, stable contracts are preferable to making every method involving `Self` potentially receiver-dependent. Prohibiting `Self` in all parameter positions would avoid part of the problem, but would also discard useful notation unnecessarily. Declaration-bound substitution preserves that notation with simpler semantics.

## 3. Declaration-bound substitution

### 3.1 Concrete declarations

Where `Self` annotations are permitted within a concrete type or implementation declaration, resolve them to the receiver type named by that declaration. Override signatures must instead write the inherited types explicitly (§5.3):

```gene
(type Dog
  ^props {^name Str}

  (message same_name [other : Self] : Bool
    (== self/name other/name)))
```

The effective message signature is:

```text
same_name(other: Dog) -> Bool
```

Within this declaration, the following annotations resolve consistently:

```text
Self          -> Dog
Self?         -> Dog?
(List Self)   -> (List Dog)
(Cell Self)   -> (Cell Dog)
```

Resolve to the actual type identity, not to the text of its name. A later binding that shadows `Dog` cannot alter an already-resolved method contract. Forward references may require delayed resolution during declaration assembly, but invocation must not repeat lexical name lookup to determine this substitution.

Outside a receiver-bearing declaration or a protocol declaration supplying an abstract `Self`, `Self` in a type annotation remains invalid. This proposal does not create a globally available type named `Self`.

### 3.2 Abstract protocol declarations

A protocol can use `Self` before a concrete receiver type exists:

```gene
(protocol Eq
  (message eq [other : Self] : Bool))
```

Here `Self` is an abstract parameter belonging to this protocol identity. When a type first introduces this conformance, it binds the parameter:

```text
Eq introduced for Dog:
    protocol Self = Dog
    required signature = eq(other: Dog) -> Bool
```

Inheriting that conformance preserves the binding. It does not introduce a fresh conformance with a different `Self` argument for every subtype.

Protocol inheritance preserves separate bindings for each protocol identity in the closure (§6.2). Universal protocols, whose defaults can run without an explicit conformance introduction, have the MVP restriction in §6.5.

This substitution is internal conformance information. It does not add public generic protocol syntax such as `(Eq Dog)` as part of this proposal.

### 3.3 `Self` does not exclude subtypes

`Self = Dog` means the ordinary nominal type `Dog`, which admits its subtypes. It does not mean “a value whose runtime type is exactly Dog.”

Exact runtime-type identity and ordinary nominal admission are different conditions. Code requiring exact identity must state that condition separately.

### 3.4 `self` is a value; `Self` is a type annotation

In a method declared on `Dog` and inherited by `Pup`:

```text
self at runtime             the actual Pup object
self's declared body view   Dog
Self in annotations         Dog
```

The object does not lose its runtime identity. A subsequent message send can still dispatch to a `Pup` implementation. The inherited body simply cannot assume fields or contracts that were not available under its declared `Dog` view.

A newly written override on `Pup` can use `self` as a `Pup`, while preserving a broader inherited argument contract such as `other : Dog`. Its body-local annotations, including annotations in nested functions declared inside the body, may use `Self = Pup`. The prohibition on `Self` applies to the overriding message's declared signature, not to its body or the receiver value `self`.

## 4. Complete example

The following examples describe expected behavior under this proposal, not results from an executed test suite.

```gene
(protocol Eq
  (message eq [other : Self] : Bool))

(type Dog
  ^props {^name Str})

(impl Eq for Dog
  (message eq [other : Self] : Bool
    (== self/name other/name)))

(type Pup : Dog
  ^props {})

(let dog (Dog ^name "rex"))
(let pup (Pup ^name "rex"))

(dog .Eq:eq dog)   # true
(dog .Eq:eq pup)   # true
(pup .Eq:eq dog)   # true
(pup .Eq:eq pup)   # true
```

All four calls are accepted because the conformance's argument contract is `Dog`. The implementation compares names, so the values in this particular example are equal.

The earlier helper now has a stable argument contract:

```gene
(fn compare_dogs [a : Dog, b : Dog] : Bool
  (a .Eq:eq b))
```

Assuming the relevant `Eq` conformance is visible in this function's scope, substituting a `Pup` for either parameter does not introduce an argument failure caused by rebinding `Self`.

This is not a promise that arbitrary method bodies cannot fail. Domain errors, absent implementations in another scope, and other ordinary runtime failures remain governed by their existing contracts. The guarantee here is specifically that inheritance does not narrow this resolved method-input type.

## 5. Inheritance and overriding

### 5.1 Inherited methods retain their signatures

If `Dog.same_name` accepts `Dog`, its inherited version on `Pup` accepts `Dog`. No new type substitution occurs merely because dispatch begins at `Pup`.

The same rule applies to return types and nested type expressions. For example, a method inherited from `Dog` with a result annotation `(List Self)` continues to promise `(List Dog)`.

### 5.2 Override flag placement and meaning

`^override true` has two declaration-level uses: on a type-direct `message`, it explicitly acknowledges replacement; on a protocol `impl`, it selects inheritance and customization of ancestor implementations (§6.1). The impl flag is not an assertion that every message in the block replaces an ancestor: a child protocol may also introduce new message identities.

The property is literal declaration metadata, interpreted after ordinary syntax expansion:

| Source property | Type-direct message | Protocol impl |
| --- | --- | --- |
| Absent | No declared replacement intent. | Complete implementation; no ancestor bodies borrowed. |
| `^override true` or `^^override` | Declares replacement of an inherited message. | Inherit applicable ancestor bodies and customize supplied messages. |
| `^override false` | Same as absent. | Same as absent. |
| Any other value, including an expression that would evaluate to a boolean | Declaration error; literal boolean required. | Declaration error; literal boolean required. |

`^^override` uses Gene's existing true-flag sugar. Placing the property on a `type` or `protocol` declaration, a protocol requirement/default message, or an individual message inside an `impl` is an error regardless of its value. Protocol implementations select their mode once on the enclosing `impl`, including inline impls. [R1]

| Declaration | Required behavior |
| --- | --- |
| Introduces a new type-direct message | No declared replacement intent; `^override true` is an error because there is no inherited target. |
| Replaces a type-direct message inherited from any nominal ancestor | `^override true` is required. |
| Protocol impl with no applicable ancestor message provider in its closure | Use complete mode; `^^override` on the impl is an error. Protocol defaults alone do not supply an ancestor provider. |
| Protocol impl with applicable ancestor providers | Choose complete mode or `^^override` to inherit bodies. Both preserve inherited bindings and resolved contracts. |
| Merely inherits a message or conformance without a new declaration | No flag or repeated declaration is needed. |

Type-direct override detection follows the existing message-name lookup through nominal ancestry. Protocol override detection uses the qualified message identity through that ancestry, including identities supplied by child protocols. An unrelated protocol's same-named message is not an override target.

An unmarked type-direct declaration that replaces an inherited message is an error even when its signature is identical. A marked type-direct declaration without an inherited target is also an error. A complete protocol impl, however, may replace ancestor providers without an impl flag; the contract checks still apply. An inheriting impl requires at least one applicable ancestor message provider, even if every body is explicitly supplied.

For example, a compatible but unmarked `Pup.same_name` should report:

```text
Pup.same_name replaces inherited message Dog.same_name.
Add ^override true to declare this replacement explicitly.
```

These rules concern message declarations. They do not change the separate constructor inheritance rules.

### 5.3 Override signatures must not use `Self`

An overriding message must name the resolved inherited types explicitly wherever the inherited signature uses `Self`. `Self` is prohibited throughout its declared callable contract: positional and named parameter annotations, the return annotation, checked error annotations where applicable, and nested type expressions such as `Self?`, `(List Self)`, or `(Callable [Self] Bool)`. Omitted annotations continue to use the ordinary `Any` equivalence for compatibility.

For protocol implementations, this restriction applies to each newly supplied message that replaces an ancestor provider, in both complete and inheriting mode. A new message identity may use the concrete impl receiver's `Self` even inside an inheriting impl. Reused ancestor definitions retain their already resolved signatures; protocol defaults use their declaring protocol's bound template. Neither is reinterpreted as a newly written child signature.

This also prohibits the legacy `[self : Self]` receiver annotation in an overriding declaration. Use the implicit receiver or the unannotated `[self]` spelling. The receiver value `self` remains available, and body-local annotations may still use `Self` (§3.4).

Given:

```gene
(type Dog
  ^props {^name Str}

  (message same_name [other : Self] : Bool
    (== self/name other/name)))
```

this independently written child declaration is invalid:

```gene
(type Pup : Dog
  ^props {}

  (message same_name [other : Self] : Bool
    ^override true
    (== self/name other/name)))
```

The marker correctly declares override intent, but the signature uses forbidden `Self`. The parent's `Self` resolves to `Dog`; a newly written child `Self` would denote `Pup`. The override must name the inherited `Dog` contract explicitly.

A useful diagnostic is:

```text
Pup.same_name uses Self in an override signature.

Inherited: other : Dog  (from Dog's Self)
Declared:  other : Self

Write other : Dog to preserve the inherited argument contract.
```

The valid override declares its intent and names the inherited input type:

```gene
(type Pup : Dog
  ^props {}

  (message same_name [other : Dog] : Bool
    ^override true
    (== self/name other/name)))
```

Here `self` is a `Pup`, but `other` can be any `Dog`. The body can use pattern matching when it needs to distinguish a `Pup` argument from another `Dog`.

#### Aliases and expanded syntax

Reject an override annotation that depends on the overriding declaration's contextual `Self`, including through expanded declaration syntax or an alias expanded at the annotation's use site. Perform this check before contextual `Self` is erased by substitution, retaining its origin for diagnostics. A textual search through the whole message is insufficient: body-local annotations and `Self:msg` expressions remain legal.

An alias that resolves without contextual `Self` to the inherited concrete type is permitted and compared normally. A closed type identity is also permitted even if it was originally obtained by resolving `Self` in a different declaration. Its historical spelling does not make it dependent on the override's context.

Current Gene aliases store unevaluated type syntax and expand at the use site (`compileAlias` in `src/gene/compiler.nim`). Defining `(alias Parent Dog)` can supply the expected `Dog` identity when resolved in the override's annotation scope. Defining `(alias HiddenSelf Self)` does not close it to the type surrounding the alias declaration: its expansion still uses contextual `Self` and is prohibited in an override signature. This proposal does not add a new alias-closing syntax or change general alias lookup rules. [R5]

### 5.4 Preserve the MVP's exact-compatibility policy

For this revision, retain the existing exact callable-signature policy rather than introducing parameter contravariance or return covariance at the same time. Apply Gene's existing normalized type comparisons and call-shape rules to the fully resolved signature.

The type-direct marker checks replacement intent; the impl marker selects ancestor-body reuse. Neither replaces compatibility checking. A newly supplied message accepting `other : Pup` still narrows the inherited `other : Dog` contract and is rejected, even in a complete impl with no flag and no occurrence of `Self`.

Resolve both sides before comparison: an inherited `Self` resolved to the `Dog` type identity must compare equal to an explicit `Dog` annotation naming that same identity. Source spelling alone is insufficient. [R2]

The shared implementation entry points are `callableSignatureMismatch(expected, actual)` and the three-argument `validateCallableSignature(expected, actual, label)` in `src/gene/type_contracts.nim`, re-exported by `src/gene/vm.nim`. `signatureTypeEqual` and `typeExprEquivalent` supply annotation comparison. Route the newly resolved signatures through this shared policy; the VM and web analyzer use the same predicate after resolving their type identities. [R5]

The current predicate checks the following contract components:

| Component | Existing comparison policy to retain |
| --- | --- |
| Callable category | Same category, including `fn` versus `fexpr`. |
| Positional parameters | Same count, required count, optional/default-presence shape, and corresponding types. Default expressions need not be identical. |
| Rest arguments | Same presence or absence and equal element types; local binding names do not define compatibility. |
| Named parameters | Same count and corresponding external names, default-presence shape, and types in the existing declaration order. |
| Result | Equal resolved result type. |
| Checked errors | Same checked/unchecked status and equal resolved error entries in the stored row's existing order. |
| Type equivalence | Preserve omitted-annotation/`Any` equivalence and existing structural normalization, including operand-order normalization for unions and intersections. |

This revision does not introduce reordering of named parameters or error rows, variance, or comparison of default expression bodies. The separate `capabilityContractCompatible` check already applied to protocol implementations remains part of their validation; calling the signature comparator must not bypass it.

A future variance design may permit additional safe overrides. It must still prohibit narrowing inherited input acceptance and account for nested invariant types. That work is separate from defining what `Self` means.

### 5.5 New narrower operations are allowed

A child may introduce an operation whose input is explicitly child-specific:

```gene
(type Pup : Dog
  ^props {}

  (message compare_pup_details [other : Pup] : Bool
    (== self/name other/name)))
```

This does not override a broader `Dog` operation. It therefore makes no contradictory promise to callers using only the parent interface and must not carry `^override true`. As a new message, it could also spell its input `other : Self`.

## 6. Protocol conformances and child implementations

### 6.1 Complete and inheriting implementations

Changing inherited method substitution alone is insufficient. A child protocol implementation must not reintroduce the same narrowing through nearest-receiver dispatch.

The proposed rule is:

> When a subtype inherits a protocol conformance, both a complete implementation and an inheriting implementation preserve that conformance's established `Self` bindings and resolved contracts. Choosing fresh bodies does not introduce a new specialization of `Self`.

Gene's documented protocol dispatcher selects the nearest applicable receiver implementation for a message identity. Consequently, a child implementation can be selected for a value admitted through a parent-type boundary. It must preserve that inherited contract. [R3, R4]

The two forms differ in how they obtain bodies:

| Form | Effective implementation |
| --- | --- |
| `(impl Eq for Pup ^^override ...)` | Resolve applicable ancestor providers by message identity; local bodies replace the corresponding entries, and omitted inherited entries retain their ancestor bodies. New identities must be supplied locally or by protocol defaults. |
| `(impl Eq for Pup ...)` | Build the full protocol message closure from local bodies and protocol defaults. No omitted message borrows an ancestor body. |

Both forms must produce a complete effective implementation. Missing a message with no permitted source is an error. The absence of `^^override` requests fresh body assembly, not permission to reset an inherited conformance or narrow its contract.

If `Dog` introduced `Eq` with `Self = Dog`, an inheriting child implementation is:

```gene
(impl Eq for Pup ^^override
  (message eq [other : Dog] : Bool
    (== self/name other/name)))
```

If `Eq` also declares `ne` and the ancestor impl supplies it, this declaration replaces `eq` and retains that ancestor `ne` definition. It does not replace `ne` with a protocol default merely because the message was omitted.

For the single-message `Eq` used in §4, this complete child implementation is also valid:

```gene
(impl Eq for Pup
  (message eq [other : Dog] : Bool
    (== self/name other/name)))
```

For a larger protocol, the complete form must supply every remaining message locally or through a protocol default. An ancestor implementation alone cannot satisfy a missing body in complete mode.

There are two relevant type contexts:

```text
Inherited protocol requirement:
    Self was bound to Dog when the conformance was introduced.
    Required input is Dog.

New concrete implementation body:
    Its receiver declaration is Pup.
    Body-local Self annotations mean Pup.
    Its overriding message signature must not use Self.
```

The newly supplied replacement writes `Dog` explicitly for the inherited parameter, in either form. Writing `[other : Self]` is rejected as an invalid replacement signature; writing `[other : Pup]` is rejected by resolved-signature compatibility checking. Body-local `Self` remains `Pup`. Individual protocol messages must not carry their own override flag.

An unrelated type introducing `Eq` has its own binding:

```gene
(type Point
  ^props {^x Int ^y Int})

(impl Eq for Point
  (message eq [other : Self] : Bool
    (&&
      (== self/x other/x)
      (== self/y other/y))))
```

Here the conformance binds `Self` to `Point`; no inherited `Dog` contract is involved. With no ancestor provider in the protocol closure, this impl must use complete mode. A protocol default does not count as ancestor behavior for enabling `^^override`.

### 6.2 Default bodies and protocol inheritance

#### Preserve a binding for each protocol identity

Conformance assembly preserves a separate `Self` binding for each non-universal protocol identity in the inheritance closure. An inherited conformance retains its established binding. A protocol identity whose conformance is newly introduced binds `Self` to the introducing receiver type. Requirements and default bodies use the binding belonging to their declaring protocol; flattening message identities must not replace inherited bindings with the new protocol's binding.

Multiple inheritance paths to the same protocol identity must agree on its binding by type identity, or assembly fails. This check supplements existing provider-coherence rules: agreeing bindings do not make duplicate providers at the same receiver depth legal. Marker protocols participate in conformance binding even when they contribute no messages. Universal protocol identities use the restriction in §6.5 instead of acquiring a concrete `Self` argument.

For example:

```gene
(protocol P
  (message copy [] : Self))

(protocol Q
  ^inherit [P]
  (message special_copy [] : Self
    (self .P:copy)))

(type Dog ^props {})
(impl P for Dog
  (message copy [] : Self self))

(type Pup : Dog ^props {})
(impl Q for Pup ^^override
  (message P:copy [] : Dog
    self))
```

The resulting contracts are:

| Requirement origin | Conformance binding | Resolved result |
| --- | --- | --- |
| `P`, inherited from `Dog` | `P.Self = Dog` | `P:copy() -> Dog` |
| `Q`, newly introduced for `Pup` | `Q.Self = Pup` | `Q:special_copy() -> Pup` |

The impl opts into ancestor-body reuse because its closure includes an applicable `P:copy` provider; an exact ancestor `impl Q` is not required. The locally supplied `P:copy` replaces that provider and therefore writes `Dog`, without a per-message flag. `Q:special_copy` introduces a new message identity and may use the protocol default. A locally supplied `special_copy` could use `: Self` because it introduces new behavior. In a different fixture where a type introduces `Q` without inheriting any `P` conformance, complete mode binds both `P.Self` and `Q.Self` to that introducing type.

#### Check defaults against their resolved contracts

A protocol default body is instantiated against its declaring protocol's binding in the selected conformance environment. Inheriting the conformance does not reinstantiate that body against the receiver's runtime subtype. Preserve the protocol body's defining lexical scope; a per-conformance substitution environment must not redirect its lexical message visibility to the impl's scope. Shared code may be reused with immutable environments or wrappers, but specializing one conformance must not mutate another conformance's default. Body-local annotations and escaping nested functions retain that environment.

In the example above, the `Q` default promises `Pup` while the call to `P:copy` promises only `Dog`. The example still succeeds because the selected child body returns the actual `Pup` receiver. In an isolated variant whose child `P:copy` returns `(Dog)`, that call satisfies its `Dog` contract but `Q:special_copy` fails its resolved `Pup` result check with a `TypeError`.

This distinction uses Gene's ordinary runtime boundaries. The feature does not require mandatory static rejection merely because an expression promises a broader result type. A static checker or backend must use the resolved contracts when establishing safety and must retain the result check whenever it has not proved the actual result satisfies `Pup`. Identical source spelling `Self` is not a proof that the two contracts are equal.

#### Assemble bodies according to the impl mode

An inheriting impl must have at least one applicable ancestor provider for a message identity in its protocol closure. Resolve each identity using normal nearest-ancestor selection and coherence in the impl's assembly scope. Providers may originate from different nominal ancestors or from impls of related protocols. Unrelated same-named messages, marker-only conformances, and universal fallback alone do not satisfy this requirement. An empty inheriting block is permitted when applicable ancestor providers and defaults complete its closure.

Use the following source order independently for every message identity:

| Impl mode | Source order |
| --- | --- |
| Inheriting (`^^override`) | Locally supplied body; otherwise applicable ancestor provider; otherwise protocol default; otherwise missing-message error. |
| Complete (absent or false) | Locally supplied body; otherwise protocol default; otherwise missing-message error. |

Local replacements are checked against inherited resolved contracts in both modes. Defaults selected in complete mode also satisfy those contracts using the established per-protocol binding environment; they do not bind a new child-relative `Self`. This intentionally allows complete mode to select a protocol default instead of an ancestor's customized body. Inheriting mode explicitly preserves that customized body when the message is omitted.

“Copy” means retain the inherited method definition and its resolved signature, lexical scope, protocol-default environment where applicable, and `super` origin. Do not recompile or stamp the body as a new declaration on the child. The runtime receiver remains the actual child object, so ordinary nested sends can still dispatch dynamically under the inherited body's original visibility rules.

The assembled child impl supplies the full protocol closure at the child receiver. Reused entries retain links to their source providers; importing or invoking that composed impl does not reselect their source bodies from the caller's scope. Later activation/reload must track and revalidate those dependencies (§6.3), rather than leaving untracked copies of old bodies. Reusing entries introduces a controlled form of partial source definition: the runtime implementation is still complete, and arbitrary same-receiver impl merging remains disallowed. [R3, R4]

Compiler-generated and derived impls choose complete or inheriting mode under the same rules. Generated type-direct replacements carry message-level flags; generated protocol impls carry only the impl-level flag when they opt into reuse. Newly supplied replacement signatures must name inherited types and pass the same checks as handwritten code. Derivation supplies no exemption.

### 6.3 Scoped visibility, activation, and reload

Gene allows canonical, scoped, and overlay implementations, with visibility-sensitive selection and later activation. Impl composition dependencies, conformance bindings, and compatibility must therefore be checked whenever ancestor and descendant implementations become applicable together, not only when two declarations happen to be compiled consecutively. [R4]

Required behavior:

- Record the impl's complete/inheriting mode, each effective message's source, and the resolved contracts and conformance bindings. Type-direct messages separately retain their declared replacement intent.
- During forward assembly, determine inherited targets and conformance substitutions against the complete static declaration group defined in §6.4 together with applicable initialized providers. Do not finalize them from sequential registration order within that group. Runtime registration paths are separate events, not assumed members of the group.
- Check inheriting impls' ancestor providers and reused-entry dependencies, plus resolved message contracts in both modes, during scope assembly, registration, and transactional activation wherever affected scopes are known.
- Recompose affected inherited entries against the prospective provider set in their declaration/assembly scope when dependencies change. Validate all affected enumerable state before committing updated entries and the activation epoch. A previously reused identity must retain a compatible ancestor source; losing that source must not silently substitute a protocol default or leave an untracked old body.
- Reject activation/reload that leaves an inheriting impl without a valid ancestor provider, breaks a reused-entry dependency, changes an established conformance binding, or introduces incompatible signatures. Complete impls are not rejected solely for lacking `^^override` when an ancestor provider becomes applicable.
- Where live overlays cannot be enumerated in advance, revalidate affected source dependencies and recompose valid entries at the affected lookup before entering a body. Report invalid combinations there, consistent with the existing late-conflict model.

Reordering otherwise equivalent static declarations within one group must not choose different final replacement classifications, body sources, or contracts. Calls interleaved with initialization still obey readiness rules; arbitrary executable code is not order-independent. Later visibility is a separate event, whether caused by publication or runtime registration. It cannot reinterpret an established conformance binding or a newly supplied signature's original dependence on contextual `Self`.

For example, if a complete child impl independently established `Eq.Self = Pup`, later making a `Dog` conformance with `Eq.Self = Dog` applicable is a conflict because the established bindings disagree. Matching message signatures do not authorize rebinding. Conversely, if bindings, signature restrictions, and contracts are compatible, the complete impl's absent flag is not a conflict. Inheriting impls additionally require their selected ancestor dependencies to remain valid.

Adding or removing ancestor providers can therefore still invalidate a composition or conformance without changing a message signature. The reason is a binding or dependency conflict, not a missing per-message protocol flag. This is an activation/reload compatibility rule as well as an assembly rule.

Ordinary visibility and nearest-receiver dispatch continue to apply to the complete effective impls. Copied definitions preserve their recorded source context, while compatibility checks cover ancestor/descendant combinations in affected scopes. An imported composed impl need not separately import its recorded ancestor bodies, but importing it does not make the ancestor impl itself visible for unrelated sends.

### 6.4 Forward assembly and declaration readiness

#### Static groups and runtime registration events

An assembly unit is a module initialization or reload candidate, a top-level program/REPL input unit, or an eval unit. Within that unit, a **static declaration group** contains its unconditional top-level declarations with statically named protocol and receiver operands, including statically declared inline impls on those types. Metadata for this group may be collected before the unit executes. Referenced type/protocol bindings and implementation bodies still initialize through ordinary execution; collecting metadata does not execute a declaration or make its body callable.

Declarations in conditional branches or callable bodies, computed impl operands, conditional/runtime imports, and impls emitted by executing derive handlers are not assumed to exist merely because their source is present. They enter through the existing registration or activation path when execution produces them. A skipped branch or a derive producing no impl supplies no override target. Successfully generated impls retain their existing canonical/scoped/overlay classification, but their existence is a runtime fact. [R4]

Static grouping is a rule for forward dependency analysis, not a new publication mechanism:

| Unit or event | Visibility and validation boundary |
| --- | --- |
| Module initialization or reload candidate | Static canonical/scoped declarations may be staged during initialization. Validate the complete candidate and affected enumerable scopes before existing atomic publication. |
| Top-level program/REPL input | Analyze the static group for that input unit and complete its validation before successful unit completion. A later input is a later registration event. |
| Eval unit | Analyze its static group for forward dependencies, while retaining eval-local overlay visibility and existing completion/`^impl` barriers. Eval does not acquire module-wide canonical activation or a new global transaction. |
| Runtime registration or activation | Validate the concrete candidate against applicable declarations, including relevant pending static metadata, at that event. Never count unexecuted conditional or computed declarations as providers. |

Current module loading calls `run` before `activateStagedImpls`, while `opEval` creates an `implOverlayRoot` scope. Readiness checks must cover both paths rather than treating them as interchangeable transactions. Existing `^impl` barriers remain as specified in `docs/scoped-impls.md` §5. [R4, R5]

#### Body entry requires a ready declaration

A callable message provider is **pending** until its receiver/protocol identities, per-protocol conformance bindings, inherited contract dependencies, selected body source, initialized implementation body, and resolved signature have been established and validated. An inheriting impl also waits for the ancestor entries it reuses. Its static metadata participates in dependency and replacement analysis while pending, but it supplies no callable body. The provider becomes **ready** once those checks succeed; it may then be used within its existing initialization scope before external publication. Abstract protocol requirements need initialized and validated declaration metadata, not an implementation body; their abstract `Self` remains a template until conformance assembly. An invalid declaration fails validation and must not become callable.

Readiness must account for every relevant static ancestor provider, even one whose declaration has not executed yet. In particular, an apparently independent child cannot become ready with a temporary child-bound `Self` merely because a known forward ancestor provider is still uninitialized. Previously ready contracts are not rebound when a later runtime event introduces more providers; that event must pass the compatibility rules or fail.

When a send's selected provider or an inherited dependency is pending, report a declaration-state error with a `declaration not ready` diagnostic naming the unresolved dependency before body entry. This uses the existing declaration/lookup error machinery; this proposal does not introduce a new public error type. A pending nearest provider must not be skipped to run an ancestor body or a protocol default. Unknown forward identities that prevent establishing the applicable winner likewise prevent body entry; they are not permission to guess a binding.

For example, in one static group:

```text
initialize child impl with ^^override
attempt to invoke its message       -> declaration not ready
initialize ancestor impl target
invoke the child message            -> allowed after validation succeeds
finish unit                        -> final validation/publication
```

The continuation in this example assumes the first error is caught. If no call occurs before dependencies initialize, parent-first and child-first declarations produce the same final contracts. If the only potential ancestor impl is in an unexecuted branch, it is not a forward target: an inheriting child impl fails for lacking an applicable ancestor provider. A complete child may instead establish an independent contract; subsequently executing the ancestor registration must validate against that established binding and contract, and may fail as described in §6.3. An absent impl flag is not itself an error.

All declarations required for successful static-group completion must be ready before the existing completion/publication barrier passes. These checks prevent temporary type or override interpretations; they do not make arbitrary top-level side effects transactional.

### 6.5 Universal protocols: MVP restriction

Gene permits a `^universal true` protocol's defaults to run without a per-type impl. That path has no explicit introducing receiver to bind abstract `Self`. For this MVP, reject a universal protocol if any requirement or default body in its inherited message closure depends on abstract protocol `Self`. The restriction includes annotations in nested default-body functions and dependence exposed by syntax or alias expansion. It also applies when a newly universal child inherits a `Self`-dependent requirement/default from a non-universal parent. [R3]

Universal defaults may still use the receiver value `self` and message expressions such as `Self:msg`. Concrete type identities and annotations independent of abstract protocol `Self` remain valid. No implicit `Self = Any`, protocol-type substitution, or runtime-receiver substitution is introduced. Universal fallback does not instantiate a per-receiver binding map, and universal entries in an explicit conformance environment carry no concrete `Self` binding.

An explicit concrete impl of an admitted universal protocol retains the normal concrete declaration context: its body-local `Self` may name its receiver type, and its signature must satisfy the protocol's already `Self`-independent requirements. A universal fallback alone is not an ancestor provider and cannot enable inheriting mode. With an explicit ancestor impl, either mode is permitted; inherited contract checks and the restrictions on newly supplied replacement signatures apply in both.

Supporting abstract `Self` in universal fallback contracts is deferred until a separate stable-binding rule is specified. This restriction is an intentional migration item, not an implementation-time fallback to the old runtime-relative meaning.

## 7. Return types and fluent APIs

### 7.1 What declaration-bound `Self` promises

Consider:

```gene
(type Dog
  ^props {^name Str}

  (message keep [] : Self
    self))
```

The declared result is `Dog`.

Calling the inherited method on a `Pup` still returns the actual `Pup` object because the body returns `self`. However, the inherited signature promises only `Dog`, not preservation of the caller's more precise subtype.

Similarly, a method declared on `Dog` as `clone [] : Self` promises a `Dog` result. It does not, merely through that annotation, promise to clone every future subtype while retaining its exact runtime type.

This is a deliberate limitation of the simpler model.

A `Pup` override of `keep` must therefore name `Dog` as its result and declare the replacement:

```gene
(type Pup : Dog
  ^props {}

  (message keep [] : Dog
    ^override true
    self))
```

Writing `: Self` in that override is prohibited. Writing `: Pup` is also rejected by the MVP's exact return-signature policy. Returning the actual `Pup` receiver remains valid because it is a `Dog`.

### 7.2 Receiver-preserving returns are a separate feature

A stronger contract could express:

```text
For every receiver subtype R of Dog:
    keep(receiver: R) -> R
```

That is different from:

```text
keep(receiver: Dog) -> Dog
```

Such a receiver-polymorphic contract needs explicit typing and implementation rules. It should not arise from making `Self` declaration-bound in inputs but runtime-bound in outputs.

For Gene's MVP, defer that mechanism. Ordinary generic functions or later receiver-polymorphic facilities can supply stronger guarantees when the type system can express and enforce them.

### 7.3 Nested result types require care

“Allow runtime-relative `Self` only in return positions” is not a complete solution.

For example, `(Cell Self)` in a return annotation contains an invariant mutable type. A `(Cell Pup)` cannot generally replace a promised `(Cell Dog)`: a caller permitted to store an arbitrary `Dog` could violate the former's constraint.

The textual location of `Self` inside a result does not automatically make narrowing safe. Fixed substitution handles this case without introducing variance analysis solely for `Self`.

## 8. Equality policy is separate from argument admission

A library may want either of these behaviors:

```text
Accept and compare another member of the Dog family.
Accept a Dog, but consider different runtime types unequal.
```

Both can keep the stable argument contract `Dog`.

For the second policy, an illustrative implementation is:

```gene
(impl Eq for Dog
  (message eq [other : Dog] : Bool
    (&&
      (same? ($head self) ($head other))
      (== self/name other/name))))
```

For these nominal typed instances, the head-identity condition makes a `Dog` and a `Pup` compare false in either direction rather than accepting one direction and raising an argument-type error in the other. [R1]

This is an example of policy, not a complete equality design for arbitrary subclasses with additional fields. Equality's symmetry, transitivity, and consistency with hashing remain obligations of the implementation. Signature compatibility alone cannot enforce them.

The distinction is:

> The type contract determines which inputs the operation accepts. The operation's body determines what those accepted inputs mean.

## 9. A protocol type does not establish a shared `Self`

This function is not guaranteed to work for every pair of values admitted by `Eq`:

```gene
(fn compare [a : Eq, b : Eq] : Bool
  (a .Eq:eq b))
```

`a` might use a conformance anchored to `Dog`, while `b` is a `Point`. Both conform to `Eq`, but their binary contracts differ.

Therefore:

> Two values satisfying the same protocol are not thereby proven to have compatible `Self` arguments.

A dynamically permitted call must retain the appropriate argument check. A static checker may require a more specific relationship before proving the call safe. This proposal does not require a particular new compile-time rejection policy, but it must not let the checker conclude compatibility merely from two identical protocol annotations.

A future generic constraint could express the required relationship. A library can also accept an explicit comparator with a suitable two-argument callable contract.

Do not replace protocol `Self` with the protocol type or `Any` to avoid the check. That would discard the concrete relationship the requirement expresses.

## 10. `Self:msg` is distinct syntax

This proposal concerns `Self` in type annotations. It does not change the reserved message expression:

```gene
Self:msg
```

That expression means an unbound, type-direct message whose implementation is selected from the supplied receiver. It must not be rewritten into `Dog:msg` merely because it appears inside a `Dog` declaration.

For example:

```gene
(x .Self:msg)
(x .msg)
```

continue to name type-direct dispatch. The supported prefix form `(Self:msg x)` likewise retains its existing send semantics. The signature restriction on overrides does not prohibit `Self:msg` expressions in their bodies.

The language documentation should explicitly distinguish these uses:

```text
Self in type position     declaration/conformance-bound type substitution
Self:msg expression       type-direct dispatching message value
self expression           the current receiver value
```

The previous rationale linking type-position `Self` directly to the receiver's runtime type should be replaced. [R1]

## 11. Compiler and runtime model

### 11.1 Retained information

Conceptually, the compiler/runtime needs:

```text
Implementation:
    receiver_type
    direct_replacement_intent      # type-direct messages only
    annotation_origins
    resolved_signature
    body
    body_origin                   # local, protocol default, or reused ancestor
    declaration_scope
    conformance_environment        # for an instantiated protocol default
    readiness_dependencies

ProtocolImpl:
    protocol_identity
    receiver_type
    mode                          # complete or inherit_and_customize
    assembly_scope
    local_message_declarations
    effective_messages_by_identity
    ancestor_source_dependencies

ProtocolConformance:
    root_protocol_identity
    receiver_type
    self_bindings_by_protocol_identity
        protocol_identity -> bound_type_identity
                           | SelfUnavailableForUniversal
    resolved_requirements_by_message_identity
```

These are semantic fields, not mandated runtime object layouts. An implementation may share or derive this information where safe.

The binding map may instead be represented by separate linked conformance records. Each requirement/default refers to its declaring protocol identity. A mixed `Q` conformance on `Pup` can therefore retain `{P: Dog, Q: Pup}`; one substitution must not be applied indiscriminately to the flattened closure. Universal identities have an explicit absence of abstract `Self`, not an `Any` binding.

An implementation's resolved contract is stable, while readiness and visibility-coherence proofs are checked in the applicable assembly/scope context. A global ready bit must not authorize dispatch in a scope whose provider set has changed. Default code and lexical scope may be shared, but each conformance's immutable substitution environment must remain distinct. Reused ancestor entries retain the definition's original scope, binding, and `super` origin, and a tracked source dependency for recomposition.

For an `Eq` conformance introduced by `Dog`, the requirement remains:

```text
eq(other: Dog) -> Bool
```

A `Pup` override can supply a different body without changing that requirement.

### 11.2 Assembly and checking

At declaration or conformance assembly:

```text
Collect the static group's metadata; leave runtime registration paths unexecuted.
For a runtime registration event, assemble only its concrete candidate
and applicable existing/pending declarations under section 6.4.
Expand declaration syntax and validate literal override metadata.
Identify the declaration's concrete receiver type, if any.
Identify inherited targets per type-direct name or protocol message identity.
Require a message-level flag exactly for type-direct replacements.
For each protocol impl, select complete or inherit-and-customize mode.
Reject per-message flags within impls; inheriting mode requires ancestor behavior.
Expand newly supplied signature aliases and reject contextual Self in replacement annotations
before erasing its origin through substitution.
Resolve permitted concrete Self annotations to the declaration's type identity.
Preserve inherited bindings per protocol identity; bind newly introduced identities.
Reject disagreeing bindings for repeated protocol identities in a diamond.
Reject abstract-Self-dependent universal requirement/default closures.
Instantiate requirements and default environments by their declaring protocol.
Assemble every effective impl message using the mode's source order.
Retain source definitions and track dependencies for reused ancestor entries.
Reject any message left without a body; complete mode never borrows ancestor bodies.
Resolve explicit type annotations on both sides of each comparison.
Run the shared callable-signature comparator and applicable capability checks.
Keep declarations pending until their body and required dependencies initialize.
Make validated declarations ready without changing existing visibility rules.
At the existing unit completion/publication barrier, reject unresolved or invalid sets.
```

Keep source spelling and resolved types for diagnostics, plus type-direct replacement intent, impl mode, and body-source provenance. Distinguish invalid flag grammar/placement, a missing type-direct marker, a type-direct marker without a target, an inheriting impl without an ancestor source, an incomplete impl, contextual `Self` in a supplied replacement signature, incompatible signatures/bindings, a broken reused-entry dependency, and a declaration that is not ready. Diagnostics should name the relevant declaration/dependency and resolved types, including original `Self` spelling where useful.

### 11.3 Invocation

At invocation:

```text
Select the implementation using the receiver's runtime type
and the ordinary implementation-visibility rules.

If pending declarations prevent a validated selection or its required
dependencies are unready, report declaration not ready; do not fall back.

Reject any late composition, conformance-binding, or contract conflict in the applicable set
before entering a body.

Validate evaluated arguments against the applicable,
already-resolved callable contract.

Execute the body and enforce its result/error contract.
```

There is no per-invocation substitution of `Self` with the runtime receiver type.

This proposal does not determine callee-versus-argument evaluation order, message-value scope capture, or prefix-versus-dot call semantics. Those remain separate invocation-design decisions. It addresses the signature used when an invocation is checked.

### 11.4 Optimization

Stable resolved contracts let the compiler reuse ordinary nominal and container-boundary machinery. They do not eliminate receiver dispatch or make an implementation address permanently stable.

Existing visibility, activation, and reload dependencies still constrain specialization and dispatch caches. Do not cache a `Self` substitution using only the receiver's runtime type; the relevant substitution belongs to the declaration or conformance. [R4]

Activation and reload dependency discovery must include ancestor/descendant receiver relationships for the same message identity, plus the source links of composed impls. An index that finds only registrations on the exact same receiver is insufficient. Discovery must also notice newly applicable ancestors for identities that previously had no inherited source. Rebuild affected composed entries and invalidate their readiness/compatibility and dispatch proofs when source selection changes; a copied function reference alone is insufficient for reload correctness.

The same substitution and compatibility rules should be shared by the VM and other backends. A backend must not recover runtime-relative `Self` merely because it is convenient for its target language.

## 12. Conformance tests

Run these as semantic tests after implementation. Each isolated declaration example should have an explicit fixture so conflicting sample definitions are not combined accidentally.

| Area | Required result |
| --- | --- |
| Inherited inputs | All four `Dog`/`Pup` receiver-and-argument combinations pass the inherited `Dog` argument check. |
| Parent-typed helper | `compare_dogs` does not acquire a `Self`-narrowing failure when either parameter contains a `Pup`, with conformance visibility held constant. |
| Type-direct override marker | Compatible type-direct replacements without `^override true` are rejected, including replacements of grandparent messages. The flag on a new type-direct message is also rejected. |
| Override property grammar | Literal true and `^^override` enable the flag; absent and literal false disable it. The flag is allowed on type-direct messages and on impls. Reject other values without evaluating them, and reject the property on `type`, `protocol`, protocol requirement/default messages, or individual messages inside an impl. |
| Inheriting impl prerequisite | Reject `^^override` on an impl with no applicable ancestor message provider in its closure. Protocol defaults, universal fallback, and marker-only conformances do not provide a target. |
| Complete impl replacing ancestors | Admit a complete child impl without a flag when its local/default bodies cover the closure and preserve inherited bindings and contracts. An absent impl flag alone never causes a replacement-intent error. |
| Override signature syntax | A newly supplied replacement signature using contextual `Self` is rejected in a direct message and in either impl mode, including named parameters, results, nested container/callable annotations, and the legacy explicit receiver annotation. |
| Alias and syntax expansion | Reject contextual `Self` exposed through an alias or expanded declaration signature. Permit aliases resolving independently to the inherited identity and already closed concrete type identities, including ones originally derived from another declaration's `Self`. |
| Explicit narrowing | A child replacement explicitly accepting `Pup` instead of inherited `Dog` is rejected by compatibility checking in both impl modes and type-direct declarations. |
| Explicit compatible override | A marked direct replacement and either protocol impl mode may supply a `Pup` body accepting `Dog`; it is dynamically selected for a `Pup` receiver. Explicit `Dog` compares equal to inherited `Self` resolved to the same identity. |
| Shared signature policy | Exercise required/default positional shape, rest presence, named parameter names/order/default shape, result types, and checked-error rows through the same comparator used by existing declarations. Preserve applicable capability checks. |
| Override body context | A direct replacement or newly supplied body in either impl mode may use `self`, `Self:msg`, and body-local `Self = Pup` annotations, including in nested functions; none changes its inherited signature. |
| Protocol inheritance and customization | An impl with `^^override` replaces supplied identities and retains omitted ancestor bodies. An empty inheriting block is admitted when ancestors/defaults complete its closure. |
| Message identity | Ancestor sources are selected per qualified message identity across receiver ancestry and protocol inheritance, without requiring an exact ancestor impl for the child protocol. Unrelated protocols' same-named messages do not count as sources. |
| Independent conformance | An unrelated `Point` conformance binds its own protocol `Self` to `Point`. |
| Mixed protocol bindings | Introducing `Q ^inherit [P]` on `Pup` with inherited `P` on `Dog` retains `P.Self = Dog` and binds `Q.Self = Pup`; without an inherited `P` conformance, both new identities bind to the introducing type. |
| New messages in inheriting impls | An inheriting `Q` impl may reuse `P` entries and introduce `Q` entries. Newly supplied replacements name inherited types, while new `Q` message signatures may use `Self = Pup`. |
| Protocol diamonds | Repeated paths to one protocol identity share one agreed binding and message identity. Reject disagreeing bindings without publishing partial state; equal bindings do not excuse existing duplicate-provider conflicts. |
| Nested annotations | `Self?`, `(List Self)`, and `(Cell Self)` retain their resolved declaration/conformance types under inheritance. |
| Return contract | An inherited `: Self` result declared on `Dog` promises `Dog`; returning `self` does not change the object's actual `Pup` identity. |
| Return override | A marked child override returning `Dog` is admitted; signatures returning `Self` or `Pup` are rejected by the syntax and exact-compatibility checks respectively. |
| Protocol defaults | A default body inherited with a conformance retains that conformance's `Self` substitution. |
| Mixed-binding default results | The §6.2 `Q` default calling `P:copy` accepts an actual `Pup` result and raises `TypeError` for an actual `Dog` result. A broader declared intermediate result is not by itself a new mandatory static error. |
| Shared default environments | Instantiating one default for multiple conformances does not mutate earlier bindings or change its defining lexical scope. Escaping nested functions retain the correct conformance binding. |
| Universal protocol restriction | Reject abstract `Self` dependence in a universal protocol's own or inherited requirement/default closure, including nested annotations and alias/syntax expansion. Admit `self`, `Self:msg`, and abstract-Self-independent defaults. |
| Explicit universal impls | A first concrete impl uses complete mode when only universal fallback exists; its body-local `Self` is concrete. An explicit ancestor impl enables the inheriting form, while compatible complete replacements remain allowed. |
| Body source precedence | In inheriting mode, omitted messages prefer ancestor customizations over protocol defaults. In complete mode, omitted messages use protocol defaults only. Locally supplied bodies take precedence in both modes. |
| Complete impl completeness | A missing local body with no protocol default is rejected in complete mode even if an ancestor supplies that message; inheriting mode may reuse that ancestor provider. |
| Reused definition context | Copied ancestor entries retain resolved signatures, lexical scope, default environment, and `super` origin while receiving the actual child object. Nested sends preserve ordinary dynamic dispatch. Importing the composed impl does not reselect copied bodies in the caller's scope. |
| Parent delegation | `super` invokes the appropriate ancestor body without rebinding that body's `Self`. |
| Type identity | Shadowing a type's name cannot change a resolved signature. |
| Protocol-typed pairs | Two `Eq` values with incompatible concrete conformance inputs do not bypass argument checking. |
| Scoped visibility | Compatible contracts preserve existing visibility rules; incompatible applicable ancestor/child combinations cannot dispatch unchecked. |
| Activation and reload | Recompose reused entries when tracked ancestor sources change. Reject lost required sources, disagreeing established bindings, and incompatible signatures transactionally where scopes are enumerable; detect live-overlay conflicts before body entry. Do not silently keep stale copies or replace lost inherited sources with defaults. |
| Declaration order | Parent-first and child-first static impl declarations in the same group yield the same final classifications and bindings when dependencies initialize before invocation. |
| Pre-publication invocation | A call between forward-related declarations reports `declaration not ready` before body entry; after catching that error and initializing dependencies, the same call succeeds. Ready staged declarations remain usable in their initialization scope. |
| Pending nearest provider | A pending child provider blocks the affected send; neither the ancestor body nor a protocol default runs as a temporary fallback. |
| Unexecuted registration paths | A potential ancestor present only in a skipped branch, uncalled function, or unexecuted computed/derive path supplies no source for inheriting mode. A complete independent child retains its binding; executing a conflicting ancestor registration later is rejected for the binding/contract conflict, not merely for an absent flag. |
| Unit boundaries | Exercise module initialization/reload, program/REPL inputs, eval-local static groups, and runtime overlays separately. Readiness checks preserve their existing visibility and `^impl` barriers. |
| Later visibility | A complete impl is not rejected solely for lacking a flag when an ancestor provider becomes applicable. Existing `Self` bindings and signature restrictions remain fixed; incompatible bindings may conflict even when signatures match. Inheriting impls also revalidate source selection/dependencies. |
| Message syntax | `Self:msg` remains type-direct dispatch syntax and is not converted to a concrete-type qualifier. |
| Derived implementations | Generated protocol impls choose complete or inheriting mode and carry no per-message flags. Generated direct replacements use message flags. Newly supplied replacement signatures avoid contextual `Self` and pass the shared checks. |
| Backend agreement | Supported backends agree on admission, rejection, and inherited return contracts. |

These tests establish type-contract behavior. Equality laws and domain-specific invariants need their own tests.

## 13. Migration and integration

The compatibility changes are intentional: inherited `Self` contracts remain stable, type-direct replacements require explicit message flags, and protocol impl flags select whether omitted bodies may be inherited.

| Previous behavior or expectation | Proposed behavior |
| --- | --- |
| Inherited `Self` follows the runtime receiver subtype. | Inherited signatures retain their declaration/conformance substitution. |
| `(pup .Eq:eq dog)` can fail because inherited `Self` becomes `Pup`. | The inherited `Dog` argument contract admits the call. |
| A child type-direct message implicitly replaces an ancestor's message. | Require `^override true` on that message; reject the flag when there is no inherited target. |
| Protocol replacement intent is marked on each message. | Move the flag to the impl when ancestor-body reuse is wanted. A complete impl may replace ancestor behavior without the flag, while preserving contracts. |
| A child implementation can appear compatible because both source signatures spell `Self`. | Prohibit `Self` in the override signature, name inherited types explicitly, and retain exact resolved-signature checks. |
| A child impl needs only a few custom bodies. | Use `^^override` on the impl; retain omitted ancestor bodies before considering protocol defaults. |
| A complete child impl omits a message supplied only by its ancestor. | Report a missing-message error. Complete mode permits local bodies and protocol defaults, but does not borrow ancestor bodies. |
| Inherited `: Self` is expected to preserve the precise receiver subtype. | The signature promises the anchored type; a stronger receiver-polymorphic contract is separate work. |
| A newly supplied replacement repeats a parent's `: Self` return annotation. | Write the inherited resolved result type, such as `: Dog`. Direct replacements require a message flag; impl flags separately select body reuse. |
| A newly introduced child protocol substitutes one `Self` across its entire closure. | Preserve inherited bindings per protocol identity and bind only newly introduced identities to the receiver. |
| Initialization calls use whichever partial declarations have executed. | Block affected calls until forward dependencies are ready; do not guess bindings or fall back past a pending provider. |
| An ancestor impl is added or reloaded without changing existing signatures. | Revalidate established bindings and composed source dependencies. Absence of a flag on a complete impl is not itself a conflict. |
| A universal fallback uses abstract protocol `Self`. | Reject the universal declaration in the MVP; use a concrete/Self-independent contract or a non-universal protocol with explicit conformances. |
| `Self` is used as an exact-runtime-type test. | Use an explicit value-level identity policy or a distinct narrower operation. |

The implementation is organized around these responsibilities:

1. Define per-protocol conformance bindings, type-direct replacement intent, impl modes, effective body-source records, and readiness dependencies.
2. Validate flag placement/literal values and expanded annotations, prohibit contextual `Self` in newly supplied replacement signatures in both impl modes, and enforce the universal-protocol restriction.
3. Resolve permitted `Self` and explicit annotations, compose effective impl entries according to their mode, instantiate defaults, and compare signatures through the shared predicate while retaining capability checks.
4. Resolve inherited contracts and body sources across static forward groups, distinguish runtime registration events, and gate invocation on initialized and validated dependencies.
5. Integrate source recomposition and compatibility checks with scoped activation, overlays, and reload, including ancestry-aware dependency discovery and existing unit barriers.
6. Update diagnostics, executable tests, and backend checks together.

Repository integration points are the `docs/reference/types.md` and `docs/reference/protocols.md` chapters; `docs/spec/types.md`; `docs/spec/protocols.md`; `docs/core.md`; `docs/scoped-impls.md`; and the corresponding protocol/type suites. Replace runtime-relative narrowing examples and update the existing deferral of partial impl composition to describe this controlled inheritance form. Earlier drafts of this proposal's per-message protocol markers and missing-marker activation errors are superseded by impl modes and their source/binding dependencies.

Implementation and test evidence is recorded in [the verification report](reports/self-type-verification.md).

## 14. Contract summary

> `Self` in a concrete type or implementation declaration denotes that declaration's receiver type wherever that annotation is permitted. Each non-universal protocol identity has its own abstract `Self` parameter, bound when its conformance is introduced. Protocol inheritance preserves established bindings and binds newly introduced identities to the introducing receiver; requirements and defaults use their declaring protocol's binding. Repeated inheritance paths to the same identity must agree. Inheritance never rebinds an established `Self` to the receiver's runtime subtype.
>
> A type-direct message replacing nominal ancestor behavior must carry literal `^override true` (or `^^override`), and that flag is invalid without an inherited target. On a protocol impl, the flag selects inheritance and customization: supplied bodies replace corresponding ancestor entries, omitted entries reuse applicable ancestor definitions, and remaining messages may use protocol defaults. This form requires at least one applicable ancestor message provider. An impl without the flag, or with literal false, builds a complete implementation from local bodies and protocol defaults without borrowing ancestor bodies. Protocol messages carry no individual override flag. Other flag values and placement on types, protocols, or protocol message declarations are errors.
>
> Both impl forms preserve established conformance bindings and inherited resolved contracts. Newly supplied replacement signatures must not depend on contextual `Self`, including through syntax or alias expansion, and must pass the shared callable-signature compatibility rule. New message identities may use the concrete receiver's `Self`; body-local annotations may also use it. Reused definitions retain their original type environment, lexical scope, and `super` origin, with tracked source dependencies for activation and reload.
>
> A declaration's body may be entered only after its conformance bindings, inherited contract and body-source dependencies, implementation body, and resolved signature are ready. Pending providers cannot be bypassed by ancestor/default fallback. Static forward groups and executed runtime registrations follow their existing visibility and publication mechanisms; neither may create a provisional binding that is later silently revised. Default bodies retain ordinary checks against their resolved result contracts. Universal protocol requirement/default closures must be independent of abstract protocol `Self` in the MVP. Message dispatch continues to use the receiver's runtime type.

For the MVP, “satisfy the inherited resolved contract” uses Gene's exact callable-signature compatibility policy. Receiver-polymorphic results, broader variance rules, and generic relationships between multiple protocol values are separate extensions.

**Stable declaration-bound types; explicit impl inheritance; dynamic receiver dispatch; no narrowing of inherited input contracts.**

## References

This implemented design consolidates the Gene discussions of 2026-09-05 and 2026-09-06. Repository paths below identify the contracts and integration points; the verification report records implementation evidence.

- **[R1]** `docs/reference/types.md` and `docs/reference/protocols.md` — declaration-bound Self, receiver/type distinctions, and message-expression syntax.
- **[R2]** `docs/spec/types.md` — nominal inheritance, inherited field contracts, and exact type-direct override signatures in the documented MVP.
- **[R3]** `docs/spec/protocols.md` and `docs/core.md` — protocol conformance, inherited message identities, defaults, and dispatch.
- **[R4]** `docs/scoped-impls.md` — lexical implementation visibility, nearest-receiver selection, conformance scopes, transactional activation/reload, and live-overlay caveats.
- **[R5]** `src/gene/compiler.nim` (`compileAlias`, `implMessageProto`), `src/gene/reader.nim` (true-flag sugar), and `src/gene/vm.nim` (`callableSignatureMismatch`, the three-argument `validateCallableSignature`, `capabilityContractCompatible`, `registerImpl`, `activateStagedImpls`, and `opEval`) — implementation integration points; the verification report describes the supported readiness and binding behavior.
