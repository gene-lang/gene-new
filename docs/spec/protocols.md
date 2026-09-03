# Protocol and message contract

**Status:** normative and implemented. `docs/core.md` supplies detailed
examples and rationale; its deferred/open-question sections are not normative.
Executable coverage: `tests/test_protocols.nim` and protocol suites in
`tests/spec_runner.nim`.

- An explicit `impl` establishes conformance. Defaults fill omitted messages
  only after an impl exists. Universal conformance must be explicit.
- Protocol inheritance flattens qualified message identities. Satisfaction may
  walk the inheritance closure; dispatch uses the qualified message identity.
- An impl covers the full inherited message closure. Partial impl composition
  is deferred.
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
