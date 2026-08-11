# Gene Module References: `#Ref` / `#Deref` and `$ref` / `$deref`

## Status

Implemented on 2026-08-11.

The initial implementation supports shared and forward-referenced lists, maps,
nodes, typed values, sets, general maps, and cells through loader-owned
structural fixups. Mutable cell-backed cycles are supported. Cycles made only
from immutable structural containers are deliberately rejected with
`InvalidRefDefinition`, and serde rejects cyclic values with `SerdeError`,
rather than publishing a partial graph or overflowing while traversing it.
Those explicit limitations preserve the broader cyclic model described in
§14 without making cyclic immutable allocation part of this first version.

This document defines a module-scoped reference mechanism that bridges Gene's representation/read layer and runtime execution layer.

The feature has four public forms:

```gene
#Ref name value
#Deref name

($ref name expr)
($deref name)
```

`$ref` and `$deref` are aliases of:

```gene
gene/ref
gene/deref
```

All four forms operate on the same module-level reference namespace.

---

## 1. Goals

The design must support all of the following:

1. Define a data item once and refer to the same logical value from multiple
   places.
2. Preserve object identity for identity-bearing values rather than copy a
   structurally equal object.
3. Allow references to values known at read/parse time.
4. Allow references to values calculated at runtime.
5. Allow runtime `$deref` to access a value introduced by `#Ref`.
6. Allow `#Deref` to refer to a module reference whose value is resolved later at runtime.
7. Support forward references within a module.
8. Avoid requiring a special `graph` wrapper or graph-only context.
9. Keep reference names distinct from ordinary lexical/module variable bindings.
10. Provide a foundation for identity-preserving serialization and cyclic/shared structures.
11. Permit identity-free atomic/scalar-like values to be copied, re-boxed, or
    interned without turning representation sharing into observable semantics.

The central rule is:

> A module owns a reference table. `#Ref`, `#Deref`, `$ref`, and `$deref` all address entries in that table.

---

## 2. Non-goals

This design does not define a general mutable reference/cell abstraction.

A module reference is primarily an identity and resolution mechanism. It is not a replacement for ordinary variables, cells, or mutable state.

It also does not promise shared storage for values whose Gene identity is
defined entirely by value. A reference to `42`, `true`, `nil`, or another
identity-free scalar-like value is a stable named resolution, not an allocation
identity guarantee.

This design also does not require references to be restricted to graph literals, serialization, quoted data, or any other special representation context.

---

## 3. Conceptual module model

Each module owns a reference table in addition to its ordinary bindings and exports.

Conceptually:

```text
Module
  bindings
  exports
  refs
    name -> RefEntry
```

A reference entry is itself identity-bearing and may initially be unresolved:

```text
RefEntry
  module
  name
  state
    unresolved
    resolving
    resolved(value)
    failed(error)        # optional implementation state
```

The logical identity of a module reference is:

```text
(module identity, reference name)
```

Reference names are therefore module-local by default and do not form a process-global namespace.

### 3.1 Target identity and permitted duplication

The identity of a `RefEntry` and the identity of its resolved target are
different questions.

Gene's `same?` contract divides values into two relevant classes:

- **Identity-free values** compare by value under `same?`. This includes
  numbers (including heap-backed large integers), booleans, symbols,
  characters, strings, bytes, regexes, ranges, dates/times/timezones,
  durations, `nil`, and `void`.
- **Identity-bearing values** compare by object identity under `same?`. This
  includes lists, maps, sets, nodes, functions, namespaces, modules, types,
  protocols, cells, streams, tasks, actors, capabilities, buffers, and other
  opaque runtime resources.

The distinction is semantic, not an implementation-layout test. A heap-backed
large integer or string remains identity-free; an immutable list remains
identity-bearing.

Every resolved entry stores one canonical `GeneValue`. Dereferencing an
identity-bearing target must return the same object. Dereferencing an
identity-free target may copy, re-box, or intern the value; only its Gene value
must be preserved. No public behavior may depend on the address, box, or bit
pattern used for an identity-free target.

---

## 4. Public syntax

### 4.1 Read/representation forms

```gene
#Ref name value
#Deref name
```

These are reader/parser-level forms.

`#Ref` associates a parsed Gene value with a module reference entry.

`#Deref` denotes a reference to a module reference entry from parsed Gene structure.

For the initial implementation, `name` is a literal simple symbol following
Gene's `snake_case` convention. It is not evaluated as a lexical expression,
and paths/dynamic names are not accepted. Module qualification can be added
later together with cross-module reference visibility.

### 4.2 Runtime forms

```gene
($ref name expr)
($deref name)
```

These are executable forms.

They are aliases of:

```gene
(gene/ref name expr)
(gene/deref name)
```

Both spellings are compiler-recognized forms, not ordinary eager function
calls: their `name` operand is the same literal reference name used by the
reader forms. Only `$ref`'s `expr` operand is evaluated.

`$ref` evaluates `expr` and resolves the named module reference to the resulting runtime value.

`$deref` retrieves the value currently resolved for the named module reference.

---

## 5. One shared namespace

There is not one namespace for `#Ref` and another for `$ref`.

These forms must interoperate.

Example:

```gene
#Ref shared [1 2]

(var a #Deref shared)
(var b ($deref shared))
```

Because the target is a list, both `a` and `b` refer to the exact same list
object.

Likewise:

```gene
($ref config ($load_config))

(var a ($deref config))
(var b #Deref config)
```

`#Deref config` and `$deref config` address the same module reference entry.

The implementation must not create duplicate identity-bearing targets or
parallel reference tables for parse-time and runtime forms. Identity-free
targets may be duplicated as described in §3.1, but they still resolve through
the one shared entry.

---

## 6. `#Ref` semantics

```gene
#Ref name value
```

`#Ref` is a reader/representation declaration.

In value position, `#Ref name value` resolves the entry and yields `value`.
The yielded value and the canonical stored target are the same object when the
target is identity-bearing.

For a value available while the module is read/materialized:

```gene
#Ref shared [1 2]
```

The reader creates the ordinary Gene runtime value corresponding to `[1 2]` and associates that exact list object with the module reference named `shared`.

Conceptually:

```text
module.refs[shared] -> [1 2]
```

The canonical stored target must be an ordinary `GeneValue`, not a
parser-private AST representation that later requires conversion before
runtime use. Copies of an identity-free target are permitted at dereference
sites; the reference table still stores its canonical value.

This is required so that runtime code can directly execute:

```gene
($deref shared)
```

without a separate materialization path.

### 6.1 Identity preservation

Example:

```gene
#Ref shared [1 2]

[
  #Deref shared
  #Deref shared
]
```

The result must preserve identity:

```text
result[0] ─┐
           ├──> same List instance [1 2]
result[1] ─┘
```

It must not behave as if `[1 2]` had been copied twice.

This guarantee applies because a list is identity-bearing. For an
identity-free target such as `42`, repeated dereferences need only produce the
same Gene value; they need not share storage or boxing.

---

## 7. `#Deref` semantics

```gene
#Deref name
```

`#Deref` is a structural/read-layer reference to `module.refs[name]`.

It must not be defined merely as "look up the value immediately while parsing" because the referenced value may not yet be available.

Instead, the reader/compiler records a reference to the module reference entry.

This allows:

```gene
[
  #Deref config
  #Deref config
]

($ref config ($load_config))
```

The `config` target is unknown during parsing but is resolved later during module execution.

Once `config` is resolved, both structural dereferences produce the resolved
Gene value. If it is identity-bearing, they refer to the exact same runtime
object. If it is identity-free, equivalent copies are permitted.

### 7.1 Important distinction

`#Deref name` means:

> Embed/reference this module reference identity from parsed structure.

`$deref name` means:

> At runtime, obtain the currently resolved value for this module reference.

They address the same `RefEntry`, but they occur at different phases.

### 7.2 Structural materialization and forward fixups

An unresolved structural `#Deref` is an implementation-only fixup, not a
public proxy value. It must never remain observable as a `RefEntry`, placeholder,
or wrapper in the completed module.

When an enclosing list, map, node, or typed value is materialized before the
target resolves, the loader records the destination slot as a fixup owned by
the `RefEntry`. Resolution patches every such slot:

- an identity-bearing target installs the same object into every slot;
- an identity-free target may be copied into each slot.

Immutable containers may be built through an internal allocate–patch–seal
path. This is loader machinery, not user-visible mutation. A pending structure
must not cross the module's external seam, and an attempt to inspect a pending
slot from module-initialization code raises `RefNotResolved`. Module
initialization fails if any structural fixup is still unresolved when the
module would otherwise become available.

Inside a function or another expression executed after initialization,
`#Deref` may compile directly to the same module-reference load used by
`$deref`; no persistent placeholder is needed.

---

## 8. `$ref` semantics

```gene
($ref name expr)
```

`$ref` is a module-level executable reference definition.

It performs the following steps:

1. Obtain the entry and reject `resolved`/`resolving` state before evaluating
   `expr`.
2. Mark the entry `resolving`.
3. Evaluate `expr` exactly once and obtain the resulting `GeneValue`.
4. Resolve `module.refs[name]` to that value and patch structural fixups.
5. Return the resolved value.

If evaluation fails, the original error propagates and the entry transitions
to `failed` (or back to `unresolved` if the implementation deliberately permits
retry). The implementation must choose one policy globally; it must not leave
the entry stuck in `resolving`.

Example:

```gene
($ref db ($connect settings))
```

The connection expression executes once.

All references to `db` then point to that same resulting connection value:

```gene
(var repo   (Repository ^db ($deref db)))
(var health (HealthCheck ^db ($deref db)))
```

### 8.1 Module-level restriction

`$ref` should only be valid as a module-level declaration/initialization form.

Reject forms such as:

```gene
(fn f []
  ($ref x ($make_x)))
```

This avoids ambiguous semantics around repeated calls, races, lexical scope, and initialization order.

`$deref`, however, is valid inside functions and other runtime code.

---

## 9. `$deref` semantics

```gene
($deref name)
```

At runtime:

1. Locate `module.refs[name]`.
2. If the entry is resolved, return the exact target object when it is
   identity-bearing, or an equivalent value when it is identity-free.
3. If the entry is unresolved, raise a typed unresolved-reference error.
4. If the name does not exist, raise a typed unknown-reference error.

Example:

```gene
#Ref shared [1 2]

(fn get_shared []
  ($deref shared))
```

`get_shared` returns the exact list registered by `#Ref`.

---

## 10. Reference names are not variable bindings

The module reference namespace is separate from the ordinary Gene binding namespace.

This is valid:

```gene
(var shared 10)

#Ref shared [1 2]

[
  shared
  #Deref shared
  ($deref shared)
]
```

Semantics:

```text
ordinary binding `shared` -> 10
module ref       `shared` -> [1 2]
```

The names may be identical without collision because they belong to different namespaces.

---

## 11. Forward references

Forward references must be supported at module scope.

Example:

```gene
(var x #Deref shared)

#Ref shared [1 2]
```

or:

```gene
(var x #Deref config)

($ref config ($load_config))
```

The implementation must therefore establish module reference identities before all reference targets are necessarily resolved.

A practical compilation/loading strategy is:

1. Scan/collect all module reference declarations from `#Ref`, `$ref`, and
   structural `#Deref` forward uses. A bare `$deref` use does not declare a
   reference merely by mentioning it.
2. Allocate module `RefEntry` objects for those declared/forward-declared
   references.
3. Parse/compile all uses against those stable entries.
4. Resolve `#Ref` targets available during read/materialization.
5. Execute module initialization.
6. `$ref` resolves runtime-computed targets.

The exact compiler architecture may differ, but reference identity must be stable across all phases.

---

## 12. Resolution is not ordinary mutation

A module reference should normally transition once:

```text
unresolved -> resolving -> resolved(value)
```

A second attempt to assign a different value should fail unless Gene later explicitly introduces replaceable module references.

Example:

```gene
($ref x ($make_a))
($ref x ($make_b))
```

Recommended result:

```text
RefAlreadyResolved
```

This distinguishes module references from cells/variables.

A `Cell` represents mutable storage.

A module `RefEntry` represents a stable one-time resolution slot that may
initially be unresolved. Once resolved to an identity-bearing value, it also
preserves that target object's shared identity. For an identity-free target,
the stable property is the value, not its storage.

---

## 13. Circular resolution

The `resolving` state should be tracked so circular runtime initialization can be diagnosed.

Example:

```gene
($ref a ($make_a ($deref b)))
($ref b ($make_b ($deref a)))
```

If `a` requires `b` before `b` has been resolved, ordinary runtime `$deref` must not magically suspend or fabricate a value.

Recommended behavior:

```text
$deref unresolved entry -> RefNotResolved
```

or, when the runtime can identify the active dependency chain:

```text
CircularRefResolution
```

Structural `#Deref` is different because it may represent a pending reference to a stable `RefEntry` during materialization.

This distinction leaves room for cyclic/shared data structures without giving ordinary `$deref` implicit coroutine or lazy-evaluation semantics.

---

## 14. Shared and cyclic structures

One major use of module references is identity-preserving data representation.

Shared structure:

```gene
#Ref shared {^value 10}

{
  ^left  #Deref shared
  ^right #Deref shared
}
```

Both properties refer to the same object.

The design should also permit future support for cycles:

```gene
#Ref alice
  (Person
    ^name "Alice"
    ^friend #Deref bob)

#Ref bob
  (Person
    ^name "Bob"
    ^friend #Deref alice)
```

Whether every immutable cyclic value can be constructed in the first implementation depends on the VM/container construction model.

The implementation may initially support cycles only where the underlying mutable/object construction machinery can safely patch references after allocation.

The public reference model should not prohibit future cyclic support.

---

## 15. Module scope and imports

References are private to their defining module by default.

Two modules may independently define:

```gene
#Ref cache ...
```

without collision.

The implementation identity is effectively:

```text
(module, cache)
```

Cross-module reference export/import is not required for the first implementation.

If later supported, it should use normal module visibility/export rules rather than introducing a global reference namespace.

Possible future syntax could use qualified references such as:

```gene
($deref config/cache)
```

but this is outside the initial scope unless Gene's existing path/module lookup makes it trivial.

---

## 16. Relationship to serialization

`#Ref` / `#Deref` naturally provide an identity-preserving Gene representation
for identity-bearing values.

Given runtime values:

```text
x = [1 2]
v = [x x]
```

A serializer may emit:

```gene
#Ref r1 [1 2]

[
  #Deref r1
  #Deref r1
]
```

rather than duplicating:

```gene
[
  [1 2]
  [1 2]
]
```

This also provides a future representation for cyclic structures.

A serializer should normally emit repeated identity-free values directly:

```gene
[42 42 nil nil]
```

Generated `#Ref` / `#Deref` pairs add no semantic information for such values,
because Gene does not observe their allocation identity. Explicit user-authored
references to identity-free values remain valid as named resolutions.

The serializer should generate reference names that do not conflict with user-defined references in the same serialization unit.

---

## 17. Runtime representation

A reasonable internal structure is:

```text
ModuleRefTable
  map[Symbol, RefEntry]

RefEntry
  name: Symbol
  state: RefState
  value: GeneValue        # valid only when resolved
```

Possible state enum:

```text
REF_UNRESOLVED
REF_RESOLVING
REF_RESOLVED
REF_FAILED               # optional
```

The runtime must keep resolved values GC-reachable through the owning module reference table.

This rooting requirement matters for identity-bearing heap targets. An
identity-free value may be held, copied, re-boxed, or interned according to its
ordinary runtime representation without an additional identity promise.

A structural unresolved `#Deref` must also retain a GC-safe/reference-safe link to the `RefEntry`, never a raw pointer that can become invalid when module tables move or are reallocated.

---

## 18. Parser/compiler representation

The implementation should not model `#Deref` as textual substitution.

Recommended conceptual representation:

```text
ParsedRefDef
  module_ref_entry
  parsed_value

ParsedRefUse
  module_ref_entry
```

or direct internal values/opcodes that carry a stable reference-entry index.

For compiled code, use module-local reference indexes rather than repeatedly performing string-map lookup when practical:

```text
module ref table
  0 -> shared
  1 -> config
  2 -> db
```

Possible bytecode operations:

```text
REF_GET index
REF_BEGIN_RESOLVE index
REF_FINISH_RESOLVE index
REF_FAIL_RESOLVE index
```

`#Deref` used structurally becomes an internal fixup that is patched or
materialized through the same module reference index (§7.2). It must not become
a public placeholder object.

Do not expose these indexes as public semantic identity.

---

## 19. Suggested reader behavior

### `#Ref`

Reader sees:

```gene
#Ref name value
```

Recommended steps:

1. Validate `name` as a reference identifier/path according to the chosen grammar.
2. Obtain/create the module `RefEntry`.
3. Read/materialize `value` as a normal Gene value/structure.
4. Associate/resolve the entry to that value when possible.
5. Preserve the ordinary value in the surrounding representation as appropriate to Gene's reader grammar.

### `#Deref`

Reader sees:

```gene
#Deref name
```

Recommended steps:

1. Obtain/create or look up the module `RefEntry` for `name`.
2. Emit a structural fixup to that entry.
3. Do not require it to be resolved immediately.

This enables forward references.

---

## 20. Suggested runtime behavior

### `$ref`

```gene
($ref name expr)
```

Compile approximately to:

```text
REF_BEGIN_RESOLVE ref_index   # reject resolved/resolving before side effects
evaluate expr
REF_FINISH_RESOLVE ref_index  # store target and patch structural fixups
return value
```

The exception path after `REF_BEGIN_RESOLVE` must execute
`REF_FAIL_RESOLVE` (or its equivalent) so the entry never remains accidentally
`resolving`.

### `$deref`

```gene
($deref name)
```

Compile approximately to:

```text
REF_GET ref_index
```

`REF_GET` fails if unresolved.

---

## 21. Errors

Define typed errors with clear distinction between missing and unresolved references.

Recommended errors:

```text
UnknownRef
  module
  name

RefNotResolved
  module
  name

RefAlreadyResolved
  module
  name

CircularRefResolution
  module
  name
  dependency_chain?       # optional

InvalidRefDefinition
  module
  name
  reason
```

Errors should include source position when originating from compiled/read source.

---

## 22. Interaction with module initialization

`#Ref` values available during module read/materialization may be resolved before ordinary module execution starts.

`$ref` values are resolved during module initialization/execution.

Therefore a module can contain both:

```gene
#Ref defaults {
  ^timeout 10
}

($ref config ($load_config #Deref defaults))

(fn current_config []
  ($deref config))
```

This creates one continuous module reference namespace spanning the representation and runtime phases.

---

## 23. Interaction with functions and closures

`$deref` may be used from ordinary runtime code:

```gene
#Ref constants {^pi 3.14159}

(fn get_constants []
  ($deref constants))
```

The compiled function should capture/address the owning module's reference table, not the caller's module or lexical environment.

A function retains the module identity under which it was compiled/defined.

Thus `$deref x` resolves against the function's defining module unless Gene already has a different explicit module-resolution rule that should be reused consistently.

---

## 24. Interaction with embedding

The module reference table may later be useful as a host dependency-injection
seam.

A host could pre-resolve module refs such as:

```text
host
config
database
application
```

before executing module initialization.

This is not required for the first implementation, but the internal API should avoid making host-side resolution impossible.

Potential future host API:

```text
module_ref_resolve(module, name, GeneValue)
module_ref_get(module, name)
```

Host-preloaded references and Gene `#Ref`/`$ref` should obey the same one-time resolution rules.

---

## 25. Recommended semantic invariants

1. Every module has exactly one module reference table.
2. `#Ref`, `#Deref`, `$ref`, and `$deref` use that same table.
3. Module reference names are distinct from ordinary Gene variable/binding names.
4. A resolved reference stores one canonical ordinary `GeneValue`.
5. `$deref` of a `#Ref` value is valid.
6. `#Deref` may structurally refer to a reference resolved later by `$ref`.
7. Runtime `$deref` of an unresolved reference is an error.
8. Reference resolution is one-time by default.
9. Identity-bearing resolved targets remain GC-rooted for at least the lifetime
   of the owning module.
10. Multiple dereferences return the same object for an identity-bearing
    target and the same Gene value for an identity-free target.
11. Forward `RefEntry` identity is established before target resolution.
12. No `graph` or other wrapper is required.
13. Module references are module-local unless explicitly exported by a future extension.
14. Reader references do not copy identity-bearing targets; identity-free
    targets may be copied.
15. Reader references are not implemented by textual substitution.
16. Structural fixups never remain observable as public placeholder values.
17. A module is not published while any structural fixup is unresolved.
18. Identity-free targets carry no address, box, or representation-sharing
    guarantee.

---

## 26. Examples

### 26.1 Parse-time value, runtime dereference

```gene
#Ref shared [1 2]

(fn get_shared []
  ($deref shared))

(var a #Deref shared)
(var b (get_shared))

(assert (same? a b))
```

### 26.2 Runtime-computed value, runtime dereference

```gene
($ref config ($load_config))

(fn config []
  ($deref config))
```

### 26.3 Runtime-computed value referenced structurally

```gene
(var app
  (Application
    ^config #Deref config))

($ref config ($load_config))
```

The structural reference to `config` and runtime `$deref config` use the same
module `RefEntry`. The completed `Application` contains the resolved target
value, never the entry or a placeholder.

### 26.4 Shared identity

```gene
#Ref values [1 2 3]

(var x [
  #Deref values
  #Deref values
  ($deref values)
])

(assert (same? x/0 x/1))
(assert (same? x/1 x/2))
```

### 26.5 Identity-free atomic value

```gene
#Ref answer 42

(var answers [
  #Deref answer
  ($deref answer)
])

(assert (== answers [42 42]))
(assert (same? answers/0 answers/1))
```

The last assertion follows from scalar value identity. It does not require the
two positions to share a box, address, or stored representation; the
implementation may duplicate the integer.

### 26.6 Separate namespace from bindings

```gene
(var value 10)
#Ref value [20]

(assert (== value 10))
(assert (== ($deref value) [20]))
```

### 26.7 Forward reference

```gene
(var app
  (Application ^config #Deref config))

($ref config ($load_config))
```

### 26.8 Duplicate resolution error

```gene
($ref config ($load_config))
($ref config ($load_other_config))

# => RefAlreadyResolved
```

### 26.9 Unresolved runtime dereference

```gene
(var x ($deref not_ready))

# => UnknownRef or RefNotResolved depending on whether `not_ready`
#    was declared/known in the module reference table.
```

---

## 27. Implementation plan

### Phase 1 — module reference table

- Add `RefEntry` representation.
- Add per-module reference table.
- Ensure identity-bearing resolved targets are GC rooted.
- Add module-local reference lookup/indexing.

### Phase 2 — runtime forms

- Add `gene/ref` and `gene/deref`.
- Add `$ref` and `$deref` aliases.
- Restrict `$ref` to module-level initialization/declaration context.
- Add `REF_BEGIN_RESOLVE`, `REF_FINISH_RESOLVE`, `REF_FAIL_RESOLVE`, and
  `REF_GET` bytecode or equivalent VM operations.
- Add typed errors.

### Phase 3 — reader forms

- Add reader syntax for `#Ref` and `#Deref`.
- Resolve `#Ref` values into the same module reference table.
- Represent unresolved structural `#Deref` with the internal fixup mechanism
  from §7.2, without a public proxy or textual substitution.
- Support forward references.

### Phase 4 — identity and materialization

- Verify multiple `#Deref` and `$deref` uses produce the same object for
  identity-bearing targets and equivalent values for identity-free targets.
- Implement and verify structural allocate–patch–seal materialization (§7.2).
- Add supported cyclic/shared-object cases.

### Phase 5 — serialization

- Teach Gene serialization/printer to preserve shared identity-bearing values
  using generated `#Ref` / `#Deref` names while emitting identity-free values
  directly.
- Add cycle-aware output where runtime representation allows it.

### Phase 6 — embedding hooks (optional)

- Allow host code to inspect/resolve module refs through the embedding API.
- Preserve the same resolution and error semantics.

---

## 28. Required tests

### Reader/runtime interoperability

```text
#Ref -> #Deref
#Ref -> $deref
$ref -> $deref
$ref -> #Deref
```

All four combinations must address the same module reference table.

### Identity and value duplication

- Two `#Deref` uses return the same identity-bearing target object.
- `#Deref` and `$deref` return the same identity-bearing target object.
- Mutable target mutation through one path is visible through the other path.
- Repeated dereferences of integers, booleans, `nil`, `void`, strings, and
  other identity-free values compare correctly by value and do not require
  shared storage.

### Forward references

- `#Deref` before `#Ref`.
- `#Deref` before `$ref`.
- Multiple forward dereferences to the same entry.
- inspecting a pending structural slot raises `RefNotResolved`.
- module publication fails while a structural fixup remains unresolved.
- completed structures expose the resolved value, never a placeholder.

### Runtime errors

- `$deref` unknown name.
- `$deref` known but unresolved name.
- duplicate `$ref` resolution.
- conflicting `#Ref` and `$ref` definitions.
- circular runtime resolution.

### Namespace isolation

- ordinary variable and module ref may use same name.
- same ref name in two modules is independent.

### GC

- identity-bearing value referenced only by module ref survives GC.
- structural dereference remains valid after GC.
- module teardown releases reference targets normally.

### Serialization

- shared identity-bearing value round-trips with identity preserved.
- repeated identity-free values round-trip without generated references.
- unsupported cycles fail explicitly rather than recurse forever.

---

## 29. Deferred extensions and open questions

The initial decisions above are sufficient for implementation. Revisit these
extensions only when a concrete use case requires them.

### 29.1 Future reference-name grammar

This document uses:

```gene
#Ref name value
#Deref name
```

The initial grammar is fixed by §4.1: `name` is a simple `snake_case` symbol.
Only revisit paths or dynamic names together with a concrete cross-module use
case.

### 29.2 Declaration-only `#Ref` variant

The initial form occupies a value position:

> `#Ref name value` resolves the reference and yields `value`.

This makes constructs such as the following natural:

```gene
[
  #Ref x [1 2]
  #Deref x
]
```

and produces two positions referring to the same list.

A declaration-only variant is deferred. Add one only if a concrete reader or
serialization use case cannot express its intent with the value-producing
form.

### 29.3 Explicit declaration of unresolved references

The compiler can infer an entry from `#Deref` before a later `#Ref`/`$ref`, so an explicit declaration form is not initially required.

A future form may be useful if diagnostics or interfaces need it.

### 29.4 Cross-module refs

Keep private/module-local initially. Revisit only when a concrete use case requires exported reference identity.

### 29.5 Cyclic immutable values

The semantic model permits stable reference identity, but VM support for fully immutable cyclic values may require allocate-then-seal construction. This can be implemented later without changing the public module-ref model.

---

## 30. Summary

Gene module references provide one shared resolution mechanism across
representation and execution, preserving object identity where Gene values
have observable object identity.

```text
                  read / representation             runtime
                         │                              │
                   #Ref / #Deref                 $ref / $deref
                         │                              │
                         └──────────────┬───────────────┘
                                        ▼
                              Module Reference Table
                                        │
                                        ▼
                                   GeneValue
```

The essential semantics are:

- `#Ref` defines a module reference from a parsed value.
- `#Deref` embeds/uses a module reference from parsed structure.
- `$ref` resolves a module reference from a runtime-computed value.
- `$deref` retrieves a module reference at runtime.
- All four forms share the same module-level reference table.
- Runtime `$deref` can directly retrieve values introduced by `#Ref`.
- Structural `#Deref` may point to a reference that is resolved later by `$ref`.
- Multiple uses preserve the same object for identity-bearing targets.
- Identity-free atomic/scalar-like targets may be duplicated; their Gene value,
  not their allocation representation, is preserved.
- No graph wrapper or graph-only restriction exists.
