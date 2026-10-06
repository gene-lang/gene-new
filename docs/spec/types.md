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
- Optionality lives on the type: a prop-schema field or fixed positional/named
  parameter whose type explicitly admits nil (`T?`, `(? T)`, a union containing `Nil`) may be
  omitted. An absent field reads as `void`; an omitted fixed parameter binds
  `nil`; explicit `^a nil` stores a present nil, distinguishable by pattern.
  `Any` alone stays required. Explicit defaults take precedence over implicit
  nil defaults. Optional positional parameters must follow required ones and
  cannot precede rest parameters. Named parameters have no ordering restriction.
  Declaration names ending in `?` are compile errors with a
  rewrite hint. An unchecked lookup of an omissible field includes `Void` in
  its result type; `(?? p/age nil)` normalizes a missing `Int?` field to `Int?`.
  See [nil/void and optional binding](nil-void.md).
- Ctor construction pre-creates `self` with an in-progress marker. Until
  validation succeeds, it cannot be stored in
  globals/containers/cells, captured by escaping closures, spawned, sent, used
  as an error/panic payload, or
  rooted natively. Only explicit Node mutation operations may target it.
- Successful validation clears the marker; failures run ordinary ensure/error
  unwinding without publishing the partial value.
- Single nominal inheritance preserves parent field schemas. Type-direct
  overrides require literal `^^override` (or `^^override`) on the message
  and preserve the inherited callable signature exactly in the MVP. The flag
  on a message without an inherited target is an error.
  Type-position `Self` binds to the declaring receiver's identity and is
  preserved under inheritance, including nested annotations and results.
  Newly supplied replacement signatures cannot depend on contextual `Self`,
  including through alias or syntax expansion; they name inherited types
  explicitly. Body-local `Self` retains the new body's declaration context.
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
- Persistent updates return a new root; explicit mutation operations change only mutable
  containers. `freeze` is deep, `freeze_shallow` is shallow, and `thaw` is deep.
- Native call borrows may pin a C pointer against explicit close, ownership
  transfer, and address replacement. The native owner retains a strong Value
  and releases the pin after the call. This protects aliases of a connection
  handle during synchronous callbacks; it does not make the pointer Send.

## Binding declaration shape

`(let PATTERN [: TYPE] [VALUE])` and `(var PATTERN [: TYPE] [VALUE])`
accept at most one initializer; an omitted initializer is nil. A constant
uses `(const NAME [: TYPE] VALUE)`, requires a constant initializer and a
plain name, and remains an unconditional module/namespace declaration.
Extra body forms and properties other than `^private` are compile errors.
The existing restrictions on where `^private` is allowed still apply.

## Collection helpers

`reverse` on a List creates a shallow copy in reverse order, including a fresh
empty result for an empty input. `drop` creates a shallow suffix copy and takes
a nonnegative Int count; a count at or beyond the size returns an empty List.
Both preserve the receiver's immutability flag and nested element identity.
Neither mutates the receiver. Root functions and receiver messages share one
native function object. Other receiver types may supply type-direct messages
for the generic operations; `reverse` rejects Streams with a collect-first hint.
Stream `drop` follows the [Stream lifecycle](streams.md).

`has_key?` accepts only PropMap or HashMap and returns whether an entry exists,
regardless of its value. PropMap Sym/Str key resolution and HashMap semantic
equality/hash stability are identical to `Map/get`. HashMap lookup holds the
same reentry guard, so key callbacks cannot mutate the active collection.
Non-Map receivers raise TypeError. `contains?` remains List/Set membership.
The web profile explicitly rejects these three helpers for now.

## Division and remainder

Int `/` truncates toward zero. `//` is the truncated remainder; for nonzero
Int `b`, `a == (+ (* b (/ a b)) (// a b))`. Integer arithmetic, including
remainder, has arbitrary precision. A nonzero remainder follows the dividend's
sign, regardless of the divisor's sign.

When either operand is F64, the VM converts Int operands to F64 and computes
the floating-point remainder (`fmod`), preserving negative zero. For finite
F64 operands and a nonzero divisor, the remainder is exact for those represented
operands; conversion from a large Int can already have rounded the input.
Both zero signs raise `RuntimeError` with message `division by zero`.
The web profile requires identical numeric operand types and uses the same
truncated semantics. Experimental C/AOT lowering does not yet accept `//`.

## Numeric buffer storage

`Buffer` remains mutable, identity-bearing Gene-owned storage. The built-in
fixed-width element types `I8` through `U64`, `F32`, and `F64` use packed
storage at their declared byte width. The corresponding explicit fixed-width
C ABI element types use the same storage. `Int`, `Any`, and other element
types retain general Gene values; an unrelated nominal type never gains a
numeric representation merely by sharing a built-in type's name.

Writes validate before changing the addressed element. F32 buffer storage
rounds once to IEEE binary32, and reads widen that stored value to the ordinary
Gene float representation. F32 scalar annotations continue to perform range
checks. Integer buffers reject overflow rather than truncate or wrap.

Negative indexing, missing reads returning `void`, alias identity, explicit
list conversion, and overlap-safe bulk copies are unchanged. A packed byte
buffer copies directly to/from `Bytes` and UTF-8 at the I/O boundary; the
result is detached from mutable buffer storage. Buffers remain non-Send by
default. Native buffer leases keep their existing copy-back and ownership
contracts.

Representation and boundary regression coverage is in `tests/test_buffers.nim`
and the native API/type suites.
