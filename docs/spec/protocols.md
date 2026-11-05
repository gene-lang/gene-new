# Protocol and message contract

**Status:** normative and implemented. The [language guide](../language.md#protocols)
and [protocol demo](../../examples/protocol_demo.gene) introduce the public forms.
Executable coverage: `tests/test_protocols.nim` and protocol suites in
`tests/spec_runner.nim`.

- An explicit `impl` establishes ordinary conformance. Protocol defaults fill
  omitted messages after that impl exists. A protocol explicitly marked
  `^^universal` provides fallback conformance without a per-type impl; its
  requirements/defaults must meet the universal-contract restrictions.
- Protocol inheritance flattens qualified message identities. Satisfaction may
  walk the inheritance closure; dispatch uses the qualified message identity.
- Every effective impl covers the full inherited message closure. For each
  message identity, a local body wins; otherwise the nearest applicable
  ancestor body wins; otherwise a protocol default fills the omission. An
  omitted required message with no ancestor body or default is an error.
  This rule also applies to identities inherited from another protocol.
  Impl-level `^^override` is accepted temporarily as a redundant legacy
  spelling; the native compiler warns about it. It does not change body
  selection or require an ancestor provider.
  It remains invalid on an individual impl message. Arbitrary same-receiver
  impl merging remains disallowed.
- Each non-universal protocol identity retains a separate conformance `Self`
  binding. Nominal inheritance preserves established bindings; newly introduced
  identities bind to the introducing receiver. Requirements and defaults use
  their declaring protocol's binding. Impls preserve inherited exact
  signatures; newly supplied replacements cannot use contextual `Self` in
  their signatures. Universal requirement/default closures must be independent
  of abstract `Self`.
- Reused bodies retain their original signature, lexical scope, default
  environment, and `super` origin. Reload revalidates and recomposes their
  source dependencies transactionally for enumerable scopes; live overlays
  detect conflicts at lookup before body entry.
- Static forward declarations may remain pending until inherited dependencies
  initialize. Pending nearest providers cannot be bypassed by ancestor/default
  fallback. Computed, conditional, and generated registration paths count only
  when executed; module and eval visibility/publication rules remain distinct.
- Deriving a child protocol runs only that protocol's derive handler, which
  emits one impl for its own protocol.
- Required `^impl` constraints are checked after forward impls in their
  declaration unit. Eval impls remain overlay-local. Module activation validates
  and publishes impls transactionally.
- A type's `^impl [P]` establishes conformance by itself when P's inherited
  message closure is empty, because an impl would carry no bodies. Nominal
  subtypes and P's protocol ancestors follow, as they do for impls. A redundant
  explicit empty impl remains legal. A defaulted message still requires an
  explicit impl, so `^impl [Error]` alone is rejected.
- Zero applicable visible impls is missing behavior; multiple applicable impls
  is ambiguity. Import order does not choose a winner.
- `(import_impl Protocol for Receiver ^from "path.gene")` imports an exported
  scoped impl for that exact protocol/receiver pair. `^from` must be a literal
  string and may appear anywhere among the positional operands. `for` remains
  positional; the old positional `from "path"` clause is rejected. No other
  named properties are accepted. A relative `^from` path resolves against the
  module that contains the `import_impl`.
- Placement follows `import` (owner decision, 2026-11-05, replacing the
  2026-11-01 module-level-only rule): `import_impl` is accepted wherever `import`
  is, which is everywhere except `eval`, and the pair becomes visible in the
  scope where an `import` at the same position binds its names. Run in the
  module's base scope (module level, including inside a top-level conditional,
  `try` or `do`, and after other statements), it adds the pair to the module, so
  every function of the module sees it once the form has run; code that runs
  earlier does not. Run in a nested activation (a `fn`, lambda, `message`,
  `ctor`, `spawn` or loop body, or a macro-marked block), it adds the pair to
  that activation only: the body and the closures created in it see the pair,
  code after the activation does not, and each execution imports again. A
  nested import is an overlay impl, like an `impl` in a function body, so its
  sends take uncached dispatch and each execution moves the dispatch epoch.
  Impls never shadow: importing a pair identical to one already visible is a
  no-op, and a different visible impl of the pair or one of its messages is a
  conflict. Only code running in the base scope adds to a module's impls, so
  they are final once the module has loaded. The web profile rejects
  `import_impl` because web impl visibility must be fixed at compile time.
- Conflict diagnostics name both origins (canonical, scoped, imported or overlay
  impl and its module). A canonical impl added to a pair that a scoped policy
  already supplies is rejected with the migration (give the policy its own
  protocol and pass its operation explicitly). Hidden-impl advice never treats
  an `import_impl` copy as a provider and spells its suggested `^from` as a
  portable path relative to the checking module.
- Unqualified sends resolve only receiver type-direct behavior, walking nominal parents;
  there is no protocol or lexical fallback. A failed bare send may list
  published, visible protocol-qualified candidates as a diagnostic hint;
  that lookup never changes dispatch. Protocol sends use `P:msg`.
  The native VM's selected equality, hash, numeric-index, size, and ordering
  operations have sealed core witnesses; they do not change ordinary send
  resolution. See [value operations](../proposals/value-operations.md).
- Only protocols qualify messages. Type-direct messages are sent bare and use
  the reserved `Self:msg` spelling when a message value is required; `T:msg`
  is a `CallKindError` naming type `T` and explaining the bare or `Self:msg`
  alternatives.
