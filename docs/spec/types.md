# Types, construction, and mutation contract

**Status:** normative and implemented. Executable coverage:
`tests/spec_runner.nim`, suites “nominal types”, “direct construction, new, and
ctor”, “typed variable boundaries”, “numeric boundaries”, and “mutable
containers”.

- `Any` is the gradual top; `Never` is the bottom. `Nil` and `Void` are
  ordinary singleton types. Type expressions use the canonical constructors
  exercised by the spec suite.
- `(T ...)` performs closed-schema data construction and never runs `ctor`.
  `(new T ...)` runs the ctor when present, otherwise the same schema mapping.
- Ctor construction pre-creates `self` with an in-progress marker. Until
  validation succeeds, it cannot be stored in
  globals/containers/cells, captured by escaping closures, spawned, sent, used
  as an error/panic payload, or
  rooted natively. Only explicit Node mutation operations may target it.
- Successful validation clears the marker; failures run ordinary ensure/error
  unwinding without publishing the partial value.
- Single nominal inheritance preserves parent field schemas. Type-direct
  overrides preserve the inherited callable signature exactly in the MVP.
- Persistent updates return a new root; `!` operations mutate only mutable
  containers. `freeze` is deep, `freeze_shallow` is shallow, and `thaw` is deep.
