# Types, construction, and mutation contract

**Status:** normative and implemented. Executable coverage:
`tests/spec_runner.nim`, suites “nominal types”, “direct construction, new, and
ctor”, “native wrapper types”, “typed variable boundaries”, “numeric
boundaries”, “mutable containers”, and “optionality lives on the type, not the
key”.

- `Any` is the gradual top; `Never` is the bottom. `Nil` and `Void` are
  ordinary singleton types. Type expressions use the canonical constructors
  exercised by the spec suite.
- `(T ...)` performs closed-schema data construction and never runs `ctor`.
  `(new T ...)` runs the nearest `ctor` in `T`'s ancestry and fails if none is
  defined.
- `(type Child : Parent ...)` declares the type's one nominal parent. A type
  without a parent omits the header: `(type Root ...)`.
- Optionality lives on the type: a prop-schema field or named parameter whose
  type explicitly admits nil (`T?`, `(? T)`, a union containing `Nil`) may be
  omitted. An absent field reads as `void`; an omitted named parameter binds
  `nil`; explicit `^a nil` stores a present nil, distinguishable by pattern.
  `Any` fields stay required. Positional parameters are optional only via
  defaults. Declaration names ending in `?` are compile errors with a
  rewrite hint.
- Ctor construction pre-creates `self` with an in-progress marker. Until
  validation succeeds, it cannot be stored in
  globals/containers/cells, captured by escaping closures, spawned, sent, used
  as an error/panic payload, or
  rooted natively. Only explicit Node mutation operations may target it.
- Successful validation clears the marker; failures run ordinary ensure/error
  unwinding without publishing the partial value.
- Single nominal inheritance preserves parent field schemas. Type-direct
  overrides preserve the inherited callable signature exactly in the MVP.
  Constructors are inherited by nearest-ancestor selection; they do not chain
  automatically.
- `^repr native_wrapper` marks a type whose props hold native state (design
  §16.6). Only `(new T ...)` creates one: direct construction,
  `construct_type`, serde, functional-update reconstruction, head replacement,
  and node literals all reject the type. Declared fields are initializer-only —
  writable on the in-progress ctor `self`, rejected afterwards — and a failed
  ctor releases the owned pointers it already installed, in props and body.
  Both rules are inherited through the nominal parent.
  Deep `freeze` rejects a wrapper (its reachable native state cannot be made
  immutable), while `freeze_shallow` and `thaw` return it unchanged; serde
  reopens one through `serde_state`/`serde_restore` rather than reconstructing
  it. Native receiver guards admit a wrapper Type or a nominal descendant, by
  Type identity and never by name. `^sealed` is reserved and rejected.
- Persistent updates return a new root; `!` operations mutate only mutable
  containers. `freeze` is deep, `freeze_shallow` is shallow, and `thaw` is deep.
