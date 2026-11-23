# Gene reference semantics

This package is a small evaluator written in Gene. It accepts a subset of
quoted Gene forms and makes the rules for values, calls, Paths, and message
dispatch explicit. The evaluator implements these operations itself with
data and lexical bindings. Its specs exercise the same cases in the Gene
VM where possible.

Run the specs from this directory with `gene test`, or run
`../../bin/gene test` with the repository's executable.

```gene
(import empty_world evaluate ^from "./src/model")
(let world (empty_world))
(evaluate world (quote (/person/name data)) {^data {^person {^name "Ada"}}})
# {^kind "value" ^value "Ada"}
```

## Reading the model

- `evaluate(world, expression, bindings)` evaluates supported forms. A
  function value holds its parameters, body, and the bindings it captured.
  Calls evaluate the callee and arguments before applying a function or
  Path. A message send resolves the receiver and method before evaluating
  its explicit arguments.
- `lookup_path(world, selector, value)` distinguishes a found value,
  a missing step, and a fault. It preserves a stored `nil` as a found
  value. `apply_path` supplies the read result, with strictness taking
  precedence over a default for missing steps. An invalid lookup or
  failed message propagates its fault.
- `declare_type` extends the world with a nominal type and checks direct
  overrides against the inherited contract. Runtime `self` is the
  receiver. The `Self` in a reused method's signature remains anchored
  to its original declaring receiver.
- `with_impl` adds a visible protocol method table. A qualified send uses
  the nearest applicable table in the receiver's ancestry. Multiple
  applicable definitions at that level yield an ambiguity. Bare sends
  consult the type-direct methods.

The result of a successful operation is `{^kind "value" ^value v}`. Lookup
can return `{^kind "missing" ^index i}` with a zero-based step number.
Model faults use short codes, such as `unknown_field`. The specs compare
behavior with the VM rather than requiring identical diagnostic strings.

## Scope

The model covers well-formed literals, name lookup, quotation, functions
with fixed unannotated positional parameters, static Paths, and positional
arguments in sends. Model nominal instances and their field names come
from fixtures. The fixed implementation world stands in for an already
resolved module scope.

The current model leaves heap effects, computed Path segments, general-key
map literal evaluation, schema construction, protocol defaults, and
dynamic module loading for later. Macros and fexprs belong in a separate
layer that describes expansion and borrowed evaluation environments.

The specs cover Path identity and composition over plain data, the
distinction between stored `nil` and absence, and the scope of inherited
contracts. The missing-key example demonstrates where a lens-style
round-trip law fails: writing back the result of reading an absent key
creates a key with value `nil`.
