# Protocol and message contract

**Status:** normative and implemented. `docs/core.md` supplies detailed
examples and rationale; its deferred/open-question sections are not normative.
Executable coverage: `tests/test_protocols.nim` and protocol suites in
`tests/spec_runner.nim`.

- An explicit `impl` establishes conformance. Defaults fill omitted messages
  only after an impl exists. Universal conformance must be explicit.
- Protocol inheritance flattens qualified message identities. Satisfaction may
  walk the inheritance closure; dispatch uses the qualified message identity.
- Every effective impl covers the full inherited message closure. A complete
  impl uses local bodies and protocol defaults. An impl with literal
  `^override true` (or `^^override`) inherits applicable ancestor bodies for
  omitted messages, then uses protocol defaults for remaining identities.
  Local bodies replace the corresponding entries. This mode requires at least
  one ancestor message provider; arbitrary same-receiver impl merging remains
  disallowed. The flag belongs on the impl, including inline impls, and is
  invalid on its individual messages.
- Each non-universal protocol identity retains a separate conformance `Self`
  binding. Nominal inheritance preserves established bindings; newly introduced
  identities bind to the introducing receiver. Requirements and defaults use
  their declaring protocol's binding. Both impl modes preserve inherited exact
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
  emits one complete impl for its own protocol.
- Required `^impl` constraints are checked after forward impls in their
  declaration unit. Eval impls remain overlay-local. Module activation validates
  and publishes impls transactionally.
- Zero applicable visible impls is missing behavior; multiple applicable impls
  is ambiguity. Import order does not choose a winner.
- Unqualified sends resolve only receiver type-direct behavior, walking nominal parents;
  there is no protocol or lexical fallback. Protocol sends use `P:msg`.
- Only protocols qualify messages. Type-direct messages are sent bare and use
  the reserved `Self:msg` spelling when a message value is required; `T:msg`
  is a `CallKindError` expecting `Protocol`.
