# Types and gradual checking

**Status:** detailed design reference and rationale. The implemented contracts
are [types](../spec/types.md), [protocols](../spec/protocols.md), [nil-void](../spec/nil-void.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 7. Types, basic generics, and gradual typing

### 7.1 Type declaration

```gene
(type Task
  ^props {^id Int ^done Bool ^title Str}
  ^body  [Note...]
  ^impl  [ToHtml]
  ^derive [Clone ToJson])
```

Construction stamps the value's head with the type value. Construction schemas are closed by default unless the type explicitly permits rest props.

`^repr` declares the type's representation. Its one accepted value is
`native_wrapper`, for a type whose props hold native state: only its `ctor`
may create an instance, its declared fields are initializer-only, and the rule
is inherited through the nominal parent. See §16.6. `^sealed` remains reserved.

`^capability "namespace/Type"` marks an ordinary type as the Gene facade for
a host-admitted capability descriptor. Such a type must contain exactly one
explicit inline `CapabilitySpec` implementation. The compiler derives its
schema hash from the declared `^props` and `^body`; the linker derives its
declaration identity and verifies both against the frozen host registry. The
marker does not admit a provider or mint authority. See
`docs/capabilities.md` §3.1.1.

### 7.1.1 Direct construction, `new`, and `ctor`

Gene separates **direct data construction** from **constructor invocation**.

Direct construction uses the type value as the call head:

```gene
(User ^name "Ada" ^age 37)
(Point ^x 10.0 ^y 20.0)
```

`(T ...)` is the canonical typed-data form. It maps named arguments to props,
positional arguments to body fields, normalizes `void`, checks required fields,
rejects unknown fields, validates field/body types, stamps the head with the
type, and returns the new instance. It **does not** call `ctor`, even when the
type defines one.

`(construct_type T fields)` is the data-driven equivalent when `T` and the
field map are runtime values. It performs the same closed-schema validation as
direct `(T ^field value ...)` construction and never invokes `ctor`; registries
can therefore keep a declared type as their sole argument schema without
generating syntax or maintaining a parallel validation vocabulary.
`(T .fields)` returns the closed property schema as data records containing
`^name`, `^type`, and `^optional`; `(T .name)` returns its declared name. The
type expressions are the original Gene values, so schema consumers reflect
the language vocabulary rather than translating it to a second internal one.

This is intentional. Gene values must be printable/serializable back into Gene
data without replaying arbitrary constructor code, side effects, normalization
logic, network calls, clock reads, or validation policies. The printer should
prefer direct construction for typed instances, because it represents the value
that exists, not the process that originally produced it.

A type may additionally define one constructor with `ctor`:

```gene
(type Point
  ^props {^x F64 ^y F64}

  (ctor [x : F64, y : F64]
    (self .set_prop `x x)
    (self .set_prop `y y)))
```

Constructor invocation uses `new`:

```gene
(var p (new Point 10.0 20.0))
```

`new` is the compiler-dispatched operation for running constructor logic. It
looks for a `ctor` on the requested type, then walks nominal ancestors until it
finds the nearest one. If the hierarchy has no `ctor`, construction fails; use
direct `(T ...)` construction for schema mapping without constructor logic.
The construction sequence is:

```text
evaluate the type expression to a Type
→ allocate a new in-progress instance with that type as head
→ select the nearest ctor, starting at that type and walking its ancestors
→ bind that in-progress instance as lexical `self`
→ argument-match the arguments after the type expression against the ctor parameter vector
→ execute the ctor body
→ validate the completed instance against the type schema
→ return `self`
```

There is no `init` special form. The constructor mutates the pre-created `self`
instance with `(set self/field v)` (§12.1) or the explicit mutable node/type
messages — `set_prop`, `set_body`, `push_body` (on `Node`). The ctor
body result is ignored; construction returns the validated `self` instance unless
the ctor raises a recoverable error or panics.

An in-progress constructor may populate fields and body positions incrementally;
the completed instance is checked atomically before publication. After
construction, every property or body mutation must preserve the closed schema.

A constructor uses normal function-style argument matching:

```gene
(type User
  ^props {^name Str ^age Int ^active Bool}

  (ctor [name : Str, ^age : Int = 0, ^active : Bool = true]
    (self .set_prop `name name)
    (self .set_prop `age age)
    (self .set_prop `active active)))

(new User "Ada" ^age 37)
(User ^name "Ada" ^age 37 ^active true) # direct data construction
```

Constructors may declare checked errors:

```gene
(type Port
  ^props {^value Int}

  (ctor [n : Int]
    ^errors [ValidationError]
    (if (&& (>= n 0) (<= n 65535))
      (self .set_prop `value n)
      (fail (ValidationError ^message "invalid port")))))

(new Port 8080)
(Port ^value 8080) # direct data construction; no ctor code runs
```

The distinction is semantic, not just syntactic:

```text
(T ...)      canonical typed data construction; replay-safe; no ctor side effects
(new T ...)  constructor invocation; requires a ctor in T's ancestry; may normalize/fail/effect
```

Therefore a `ctor` is an ergonomic and validation entry point, not the only way
to materialize a value of that type. If a library needs stronger invariants, it
should combine `ctor` with future visibility/opaque-field controls, a validation
protocol, or trusted deserialization policy. Schema validation always runs for
both direct construction and `new`, but semantic invariants encoded only in
`ctor` are not automatically enforced by direct construction.

Constructors are inherited. `new` selects the nearest `ctor` in the requested
type's ancestry; a child `ctor` overrides its parent's, and constructors do not
chain automatically. The selected constructor receives a `self` whose head is
the originally requested type and must leave it valid for that type's full
inherited schema:

```gene
(type Animal
  ^props {^name Str}

  (ctor [name : Str]
    (self .set_prop `name name)))

(type Dog
  : Animal)

(new Dog "Rex") # runs Animal's ctor and returns a Dog
```

A partially constructed `self` carries an in-progress construction marker and
is not publishable. While the marker is set, the runtime rejects Send,
actor/channel transfer, global or container storage, native rooting, escaping
closure capture, and error/panic publication. Transient helper returns remain
inside the constructor's dynamic extent and cannot cross any durable boundary.
Only the constructor's
explicit node mutation operations (`Node/set_prop`, `Node/set_body`, and
`Node/push_body`) may target it; arbitrary receiver dispatch is rejected.
After schema validation succeeds, the marker is cleared before `new` returns.
If construction fails, normal error unwinding and `ensure` cleanup run, and no
partial instance is registered or exposed. A ctor's declared `^errors` form
part of the checked-error behavior of `new`.

### 7.2 MVP type hierarchy

MVP uses a small nominal type hierarchy:

```text
Any
├── Nil
├── Void
├── Bool
├── Str
├── Number
│   ├── Integer
│   │   ├── Int
│   │   │   └── Fixnum
│   │   ├── SignedInt
│   │   │   ├── I8
│   │   │   ├── I16
│   │   │   ├── I32
│   │   │   └── I64
│   │   └── UnsignedInt
│   │       ├── U8
│   │       ├── U16
│   │       ├── U32
│   │       └── U64
│   └── Float
│       ├── F32
│       └── F64
├── List
├── Map
├── Gene
├── Fn
├── Fexpr    # runtime syntax callable; sibling of Fn
├── Env
├── Task
├── Channel
└── ActorRef

Never <: every type
```

`Any` is the top gradual type in MVP. Unannotated code defaults to `Any`, and `Any` can flow into typed code only through a runtime typed-boundary check.

`Never` is the bottom type because it has no values. A computation with type `Never` never returns normally, so it can appear wherever another type is expected.

`Nil` and `Void` are ordinary singleton types under `Any`:

```gene
nil  : Nil
void : Void
```

They are not bottom types. `nil` is explicit absence. `void` means missing, skipped, deleted, or no produced value. Optional values are explicit:

```gene
T?          = (| T Nil)        # symbol suffix
(? X)       = (| X Nil)        # prefix head, any type expression
(? X Y ...) = (| X Y ... Nil)  # several alternatives, all made optional together
```

`?` is the sole optionality operator: there is no `opt` keyword and no `Option`
wrapper type — absence is the ordinary `nil`. As a symbol suffix (`Int?`,
`User?`) it is read as an ordinary symbol and interpreted only in type position
(annotations, parameter/return types, prop schemas), so predicate names like
`empty?` in value position are unaffected. As a head (`(? (List Int))`) it works
on any type — including compounds a suffix cannot reach.

A typed list or map is not implicitly initialized to `nil`:

```gene
(var xs : (List Int) [])          # empty list
(var ys : (? (List Int)) nil)     # absent list
```

A future static top type such as `Value` may be added later to distinguish “some statically known Gene value” from dynamic unchecked `Any`. It is not part of MVP.

Union types are normal types:

```gene
(| Int Nil)  # an Int or nil
```

A union is a subtype of `Any`; each alternative keeps its own runtime identity.
### 7.2.1 Planned type additions

Status: **Partially implemented**. `Range` and the date/time family now have
native runtime values. The remaining planned items in this subsection are not
part of the MVP type hierarchy above, but they are expected additions as the
language grows toward practical web, database, and application code.

#### `Range`

`Range` is a small native value/object used by loops, stream conversion, and
later slicing/index traversal.

```gene
($range 0 10)      # 0, 1, ..., 9
($range 10 0 -1)   # 10, 9, ..., 1
($range 0 10 2)    # 0, 2, 4, 6, 8
($range 0 4 2 true) # 0, 2, 4
```

The default range should be half-open, `[start, stop)`, because that matches
indexing and repeat-count use cases. A fourth boolean argument marks an
inclusive range. A range has `start`, `stop`, `step`, and `inclusive?`
semantics; zero step is invalid.

#### Date and time values

The date/time family is implemented as small immutable native values:

```gene
Date
Time
DateTime
Timezone
Duration
```

`Date`, `Time`, and `DateTime` support reader literals and canonical printing
for the old Gene ISO-like surface:

```gene
2026-07-04
09:30
09:30:15.123456
2026-07-04T09:30
2026-07-04T09:30Z
2026-07-04T09:30:15.123456-04:00[America/New_York]
09:30[America/New_York]
```

DateTime bracketed IANA names require a preceding `Z` or fixed offset, matching
the old reader. Time literals may use a bracketed name without an offset.

Constructors are available for generated code and host APIs:

```gene
($date 2026 7 4)
($time 9 30 15 123456 -240 "America/New_York")
($datetime 2026 7 4 9 30 15 123456 0 "UTC")
($timezone "+08:00" "Asia/Shanghai")
($duration 1500000) # microseconds
```

Accessor messages live on the corresponding type namespaces and may be sent
unqualified through the receiver-message resolver:

```gene
(d .year)
(d .year)
(t .hour)
(dt .offset)
(tz .name)
(dur .seconds)
```

`Duration` is included with the family because date arithmetic is incomplete
without an explicit duration type. Duration is currently constructor/API based;
the old Gene parser reserved number-with-unit support but did not implement
duration literals, so unit suffix forms such as `5ms` or `1h30m` remain future
syntax.

Timezone support starts with `UTC` and fixed-offset zones. Full IANA timezone
database support is deferred until the stdlib has a dependency policy for it.
Comparison and SQLite-friendly round trips beyond canonical text are planned
next steps.

#### Enums (sum types)

Enums are a **core declaration special form** (not a stdlib type): a closed,
named set of variants under one type. One `enum` form unifies simple
enumerations (all variants carry no payload) and tagged sum types / ADTs
(variants carry payloads) — states, message sets, `Option`/`Result`, JSON/AST
nodes. `enum` is a declaration special form parallel to `type`. The MVP gives
tagged-value ergonomics, nominal boundaries, and runtime matching first;
Static exhaustiveness checking is the planned follow-on once the checker can
reliably know the scrutinee's enum type.

```gene
(enum Color                 # simple enum — all unit variants
  red green blue)

(enum Shape                 # tuple variants carry positional payloads
  (circle Int)              # radius
  (rect Int Int))           # w, h

(enum Option [T]            # generic sum type (§7 basic generics)
  none
  (some T))

(enum Result [T E]
  (ok T)
  (err E))

(enum Status ^backing Str   # optional backing scalar for storage
  (active "A") (closed "C"))
```

**Members and construction.** Each variant is a qualified member `Enum/variant`
(§2.1). A unit variant *is* a value — an interned singleton (`Color/red`, so
`same?` compares by identity). A payload variant is a constructor:
`(Shape/circle 5)`, `(Option/some x)`. A value's runtime enum identity is the
enum itself (`Color`, `Option`); generic type arguments are erased at runtime
and enforced by static/type-boundary checks. Thus `(Option Int)` is a static
type expression over runtime enum `Option`, and the unit singleton `Option/none`
is shared across instantiations. The variant is a discriminant tag *within* the
enum, not a separate type. Structural `=` compares enum identity, variant
identity, and payloads.

**Enums are types.** `Enum` is a kind of `Type`, so an enum is usable everywhere
a type is — annotations (`^c : Color`), generic application (`(Option Int)`),
unions, and dispatch. An enum body may declare type-direct messages and inline
`impl`s exactly like `type` (§10), and protocol impls may target it, so enums
carry behavior and join the protocol system:

```gene
(enum Direction
  north east south west
  (message degrees [self] : Int
    (* (self .ordinal) 90)))   # north 0, east 90, south 180, west 270
```

This `Enum`/`Type` relationship lives at the meta-level of §7.1: `Color` is a
runtime type value, like a declared `type`, while `Color/red` is a value whose
receiver type is `Color`.

**Pattern matching.** Variants match with the ordinary engine (§8) via `when`;
payloads bind positionally (named fields for struct variants, deferred):

```gene
(match r
  (when (Result/ok v)  v)
  (when (Result/err e) (fail e)))
```

When the scrutinee's static type is the enum, `match` is intended to be
**exhaustiveness-checked** — a set of `when` clauses missing a variant, with no
`else`, is a compile error naming the gap; this is the headline benefit of a
closed variant set (static check deferred, see below). A dynamically-typed
scrutinee falls back to a runtime `MatchError`. A fully covered `match` with an
`else` may become an unreachable-branch warning later; it is not part of MVP.

**Reflection and storage** (the web/sqlite path). Every variant has a stable
0-based `ordinal` (declaration order) and a `name` (a `Sym`). The enum type
exposes the variant descriptor set and reverse lookups for (de)serialization:

```gene
(Color .variants)           # => [Color/red Color/green Color/blue]
(Color .names)              # => [red green blue]
(Color/red .name)           # => red
(Color/green .ordinal)      # => 1
(Color .from_name `red)     # => Color/red  (symbol arg is quoted)
(Color .from_name "red")    # Str accepted for codec convenience
```

For unit-only enums, `variants` returns the interned unit values. For mixed or
payload enums, `variants` returns variant descriptors; a payload descriptor such
as `Shape/circle` is a constructor, not an already-constructed enum value.
`from_name` returns the same descriptor/member, so ``(Shape .from_name `circle)``
returns the `Shape/circle` constructor descriptor. Unknown `from_name` and
`from_ordinal` inputs return `void`; raising parse helpers can be added later.

An optional `^backing T` gives unit enums a stable scalar independent of
declaration order — the natural DB-column representation. `^backing` is rejected
if any variant carries payload. Every variant must provide a unique backing
value of type `T`, and backing values must be hash-stable:

```gene
(enum Status ^backing Str
  (active "A")
  (closed "C"))
```

`(Status/active .backing)` is `"A"`, `(Status .from_backing "A")` is
`Status/active`, and unknown `from_backing` inputs return `void`.
Auto-provided enum reflection names — `variants`, `names`, `name`, `ordinal`,
`from_name`, `from_ordinal`, `backing`, and `from_backing` — are reserved on
enum types/variants; declaring a type-direct message with one of those names is
an error.

**Relationship to other forms.** A union `(| A B C)` (§7.2) is *open, structural,
untagged* — "any of these existing types"; an enum is *closed, nominal, tagged*
with named variants, constructors, and exhaustiveness. Optionality stays `nil` /
`T?` / `(? X)`, not `Option`; recoverable errors stay `fail`/`try`/`catch` with
`Error` (§9), not `Result`. `Option`/`Result` remain available as stdlib enums
for code that prefers explicit tags or errors-as-values, but are not the default
idiom.

**Representation.** Unit variants are interned per enum and may be NaN-box-inlined
as `(enum-id, ordinal)` with no allocation; because generic type arguments are
erased, an inline unit variant carries only enum identity and ordinal. Payload
variants are heap values holding the runtime enum identity, variant tag, and
payload, so zero-payload enums stay allocation-free on hot paths.

**MVP vs deferred.** MVP: unit and tuple variants; qualified members; enums as
types (annotations, generics, dispatch, methods, inline/target `impl`s);
recursive payload references to the enclosing enum; `when`-pattern binding;
`ordinal`/`name`/`names`/`variants`/`from_name`/`from_ordinal` reflection.
Deferred: **struct variants** (named payload fields, `(point ^x Int ^y Int)`);
**static exhaustiveness checking** (until the gradual type checker can resolve
the scrutinee's enum type — dynamic matches still `MatchError`); and versioning
rules for adding a variant to a published enum.

#### Additional planned stdlib types

The following are useful for the web/sqlite path and should start as stdlib
types or stdlib APIs unless performance evidence justifies making them core VM
value kinds:

- `Json`: represented by ordinary Gene maps, lists, strings, numbers, booleans,
  and `nil`, with parser/printer APIs.
- `Url` / `Uri`: parsed URL values for web routing, request handling, and
  clients.
- `Uuid`: stable identifier type for database-backed applications.
- `Decimal`: exact base-10 numeric value for money and database precision.
- `File` / `Directory`: capability-scoped resource handles, not ambient global
  filesystem authority.

### 7.3 Single nominal inheritance

Gene supports single nominal inheritance only:

```gene
(type Animal
  ^props {^name Str})

(type Dog
  : Animal
  ^props {^breed Str})
```

The `: Parent` header declares one nominal parent. Multiple inheritance is not
supported in MVP:

```gene
(type X
  : [A B]) # invalid
```

Multiple behaviors are expressed through protocols:

```gene
(type Dog
  : Animal
  ^impl [Send ToJson Comparable])
```

A child type must be substitutable for its parent:

- the child inherits all parent props/body fields;
- the child may add fields;
- required parent fields remain required;
- inherited fields keep the same type in MVP;
- direct parent construction remains closed to unknown child fields;
- subtype values may contain extra child fields and still pass a parent boundary.

Example:

```gene
(fn print_name [x : Animal]
  ($print x/name))

(print_name (Dog ^name "Rex" ^breed "Lab")) # valid
```

Invalid examples:

```gene
(type BadDog
  : Animal
  ^props {^name Any}) # invalid: inherited field type changed

```

A child may add no fields. `(type Dog : Animal ^props {})` is valid; an
instance of that child must still supply every inherited required field.

A message body may delegate to the implementation above it with `(super .m)`
(§10). `super` is not available in a `ctor`: constructors are inherited by
nearest-ancestor selection, but explicit parent-constructor chaining is
post-MVP, along with field narrowing, abstract parent types, final/sealed
inheritance, layout inheritance, and schema-evolution adapters.

### 7.4 Numeric model

MVP numeric types:

```gene
Int     # arbitrary-precision integer at the language level
Fixnum  # immediate Int in the inclusive range -140737488355328..140737488355327
Float   # abstract floating-point family
F64     # 64-bit IEEE float; representation of unannotated runtime floats
F32     # IEEE binary32 storage; a range boundary in scalar annotations
```

`Int` has mathematical integer semantics. The MVP VM implements this as a
checked-I64 fast path with heap-bignum promotion on overflow (`intAdd` /
`intSub` / `intMul` / `intDiv` in the runtime: when both operands fit in
int64 and the result fits in int64, arithmetic stays as a NaN-boxed fixnum;
otherwise the runtime promotes to a heap bignum). Overflow of the fixnum
range **never wraps silently** — it either promotes to an exact heap bignum
when promotion is implemented for the operation, or raises a recoverable
error. The language-level contract is mathematical integer semantics; the
MVP contract is "promote to bignum on overflow or raise." Silent wraparound
is forbidden. Typed native code may specialize `Fixnum`, `I64`, `F64`, and
`F32`; using such fixed-width types creates range-checked boundaries (a
fixed-width result out of range raises rather than wrapping).

Numeric equality is kind-strict in the MVP: integers compare only with
integers and floats only with floats, so `(== 1 1.0)` is false. IEEE NaN is
unequal to every value, including itself, and is rejected as a hash-map or set
key. Positive and negative floating-point zero compare equal and have identical
hashes. These rules ensure that every admissible pair equal under `==` has the
same hash.

FFI types such as `C/Int32`, `C/Long`, and `C/Size` are ABI types, not aliases for Gene `Int`. Passing a Gene `Int` to an FFI integer parameter performs an explicit range check and then marshals to the target ABI width.

Division is `(/ a b)`. The remainder operator is `//`, not `%` or `mod`: `%` is
the unquote prefix (§2) and `mod` is the module declaration form (§15.4), and
neither can be shadowed. `//` belongs to the closed operator set (§2.2), so it
stays bare like `/` rather than moving under the `gene` root. `(// a b)`
truncates toward zero, so its sign follows the dividend and it pairs exactly
with `/`:

```gene
(/ 17 5)     # 3
(// 17 5)    # 2
(// -17 5)   # -2
(// 17 -5)   # 2
```

A selector needs at least one segment, so `//` is never read as one; the reader
gives it back as the operator symbol. An interior `//` in a path (`a//b`) still
collapses to `a/b`.

A floored variant (`mod_floor`) may be added later.


Generic functions put type parameters on the function name:

```gene
(fn ($first item err) [s : (Stream item err)] : item
  ^errors [EndOfStream err]
  (s .next))
```

Call-site inference uses local unification. Given:

```gene
(var users : (Stream User Never) ...)
($first users)
```

The compiler compares `(Stream item err)` with `(Stream User Never)` and infers `item = User`, `err = Never`.

MVP generics include generic declarations, type application, generic functions, and local unification-based call inference. MVP generics do not include variance, higher-kinded types, associated types, complex constraints, or required explicit type application syntax.

### 7.4.1 Type-expression grammar

The executable MVP accepts the following type expressions. A compound form is
ordinary Gene data, so quoting and printing it preserves the spelling shown.

```ebnf
type-expr       = type-name | type-name "?"
                | "(" "|" type-expr+ ")"
                | "(" "&" protocol-name protocol-name+ ")"
                | "(" "?" type-expr+ ")"
                | "(" "List" type-expr ")"
                | "(" "Set" type-expr ")"
                | "(" ("Map" | "PropMap" | "HashMap")
                      type-expr type-expr ")"
                | "(" "Tuple" type-expr* ")"
                | "(" "Fn" "[" type-expr* [ type-name "..." ] "]" type-expr
                      [ "^errors" "[" type-expr* "]" ]
                      [ "^named" "{" ( "^" name type-expr )* "}" ] ")"
                | "(" generic-enum-name type-expr* ")"
```

`(& P Q ...)` is a **protocol intersection**: it matches a value that satisfies
every operand, under the ordinary applicability rules, so protocol inheritance
and receiver ancestry apply exactly as they do for a single operand. Operands
must be protocols and there must be at least two — a value has one type lineage
(§7.3), so an intersection of *types* is uninhabitable and is rejected rather
than silently never matching. Type parameters are not permitted as operands;
protocol-constrained generics are a separate feature.

Operand order carries no meaning. `(& P Q)` and `(& Q P)` are the same type at
every comparison site — boundary matching, the stored type of an invariant
container such as `(Cell T)`, and callable-signature compatibility at `impl`
registration. The same now holds for `(| A B)`. Like every other annotation,
an intersection is validated when a boundary is first exercised, not when the
enclosing function is defined, so forward-referenced protocols resolve
normally.

`(Tuple A B ...)` is a fixed-length positional product represented by a Gene
list. `(Fn [A B ...] R)` describes an ordinary `fn`, never an `Fexpr`, by one call
shape: it matches any function that admits a call with exactly the listed
positional arguments — the function's required positional count may not exceed
the listed arity, extra declared positionals must be optional or absorbed by a
rest parameter, and every named parameter must be optional unless listed in
`^named`. This is usable-as admission, not subtyping: one function may match
several `Fn` types at different arities. A trailing `T...` uses the
body-schema repeated-field spelling and requires a rest parameter; the repeated
tail compares against the rest binder's element type — `Any` for an untyped
`xs...`, or `T` for a typed `xs... : T` — so `(Fn [Int...] R)` matches a
function declaring `xs... : Int` and rejects one declaring `xs... : Str`. `^named {^y T ...}` entries must exist on the function with
invariant-equal declared types — a nil-admitting spelling mirrors the
declaration-side optionality rule — and a function's required named
parameters must be listed. The error row is unchecked by default; supplying
`^errors [E ...]` instead requires the checked error row to match exactly.
A generic function matches when one consistent instantiation of its type
parameters makes every compared signature component equal — `(identity T)`
with `[x : T] : T` satisfies `(Fn [Int] Int)` but not `(Fn [Int] Str)` —
and type parameters unify inside compound components such as `(List T)`.
`T?` and `(? T)` are the same type in signature comparisons regardless of
which spelling each side chose. Parameter, result, and error types are
invariant in the MVP.

Generic declarations currently comprise `(enum Name [T ...] ...)` and generic
functions whose name is `(name T ...)`. Enum applications such as `(Option
Int)` must supply exactly the declared number of arguments; arguments are
erased from runtime enum identity. Generic nominal record declarations are not
accepted yet.

Schemas are closed for props. A field whose type explicitly admits nil
(`T?`, `(? T)`, or a union containing `Nil`) may be omitted; an absent
field reads as `void` (falsy), while an explicit `^a nil` stores a
present nil (pattern-distinguishable). A lookup of an omissible field has the
declared type union Void; the declared field type constrains a present value.
For example, a getter returning `Int?` for a field `age : Int?` should use
`(?? p/age nil)`; returning the raw lookup can fail when age is missing.
`Any` is gradual slack, not an
optionality marker: an `Any` field stays required. Field names may not
end in `?`. Body schemas admit one final repeated field as `[A B T...]`. Open/rest prop
schemas and generic record declarations are reserved for a later extension; the
compiler rejects `^rest`, `^open`, and `(type (Name T) ...)` rather than
silently assigning them semantics.

A **transparent type alias** names a reusable type expression, so a union or
compound need not be repeated at every annotation:

```gene
(alias Id     Str)
(alias Widget (| Pane Worker Nil))

(fn render [w : Widget] : Str ...)   # w : (| Pane Worker Nil)
```

`(alias Name TypeExpr)` binds `Name` in the current scope; wherever `Name`
appears in type position it expands to `TypeExpr` against the *use-site* scope,
including in `var`/parameter/return/prop annotations and pattern type guards.
An alias is transparent (`(alias Id Str)` and `Str` check identically), never a
nominal or distinct type, and is not constructible — `(Name ...)` is an error.
Aliases are ordinary type-category exports (importable, wildcard-visible,
`^private`-able). An alias `Name` that shadows a built-in type name (e.g.
`Node`) is not honored in annotation position; choose a distinct name. An alias
whose expansion is a protocol does not seed unqualified send candidates
(§10) — a parameter typed by such an alias must reach protocol messages by
qualification; alias a union of concrete types, not a bare protocol, when you
need unqualified sends through it.

Gene remains gradually typed. Unannotated code defaults to `Any`:

```gene
(fn f [x, y]
  ...)
```

means conceptually:

```gene
(fn f [x : Any, y : Any] : Any
  ...)
```

Untyped data can flow freely inside dynamic code. It is checked when it crosses a typed boundary.

Typed boundaries include:

- assignment to a typed variable;
- passing a value to a typed function argument;
- returning from a function with an annotated return type;
- constructing a typed value;
- inserting a value into a typed container;
- adapting a dynamic stream to `(Stream T E)`.

Example:

```gene
(var req : Request raw_req)
(handle raw_req) # if handle expects Request, raw_req is checked at call boundary
```

If a value whose static type is `Any` fails a typed-boundary check, Gene raises a recoverable `TypeError` with blame information. This is the normal defensive boundary for untrusted dynamic input.

If fully typed code violates an already-checked internal representation invariant, that is a compiler/runtime bug or panic, not an ordinary recoverable boundary error.

For generic containers, Gene checks element types. For streams, checking is lazy: each item is checked as it is pulled.

### 7.5 Hashable collections and bytes

These extend the §7.2 hierarchy beyond the original MVP.

**`Set`** — `(Set 1 2 3)`. A hashable-element collection. The first
implementation is immutable and preserves first-insertion order for printing and
iteration; duplicate equal elements collapse to the first occurrence. Elements
must be hash-stable, so mutable structural values are rejected by the §12.4
mutable-key rule. Mutable/frozen set variants may be added later if they pull
their weight.

**General map `{{ … }}`** — an any-key hashed map, distinct from the Sym-keyed
`PropMap` literal `{^k v}`. The literal shape is flat and requires `:` between
each evaluated key and value:

```gene
{{k1 : v1 k2 : v2}}
```

`{{` is tokenized specially; the close is two ordinary `}` tokens, so adjacent
ordinary map closes such as `{^a {^b 1}}` remain unchanged. Keys must be
hash-stable; mutable structural keys raise `TypeError`. Iteration and
`to_pairs_stream` yield `[key value]` pairs in insertion order. Duplicate equal
keys use last-write-wins; a final `void` value deletes the key. `(Map K V)`
accepts both `PropMap` and general maps for compatibility; `PropMap` and
`HashMap` name the precise variants.

**Binary / `Bytes`** — immutable byte strings distinct from the mutable typed
`Buffer` (§16). Three literal notations:

```gene
#B#01010101    # bits
#B16#1f3a      # hex
#B64#SGVsbG8=  # base64
```

Bytes are currently heap-backed; inlining 1–4 byte values into the NaN-boxed
payload remains an optimization option. `0x` is a hexadecimal integer literal
(§7.4); bytes use the `#B#` family above. Bit literals must contain a multiple
of 8 bits. The reader accepts all three spellings and the printer emits one
canonical form, `#B16#<hex>`, so `#B#` and `#B64#` are input spellings and the
value round-trips whichever way it was written. Base64 literals accept padded
or unpadded input; an unpadded literal ends at the first non-base64 character
(whitespace or a closing `)`/`]`). A `~` separator may appear between byte
groups and may be followed by whitespace, including newlines:

```gene
#B#11111111~ 11111111~ 11111111
#B16#aaaa~ aaaa
#B64#SGVs~ bG8=
```

### 7.6 Regular expressions

The universal `/pattern/` literal is unavailable — a leading `/` is a selector
literal (§5) — so regex literals use a `#`-reader form, `#"pattern"`:

```gene
#"\d{4}-\d{2}"        # a Regex value, compiled at read time in native builds
#"hello"i             # trailing flags: i (case), m (^$ multiline), s (dotall), x (verbose)
#"""^\s*(\w+)\s*$"""  # triple-quoted so " needs no escaping
```

Regex literals are **raw**: they preserve backslash escapes literally (`\d`, `\w`,
`\.`) and hand the pattern to the engine unchanged — unlike normal Gene strings,
which reject unknown escapes such as `\d`. So the reader does **not** reuse string
parsing; it scans only enough to terminate the literal: a closing `"` (with `\"`
permitted so a pattern may contain a quote), or the `#"""…"""` triple-quoted form
where nothing needs escaping.

Regex literals produce immutable compiled `Regex` values directly. `Regex` is
also a constructor function and type annotation; the explicit constructor takes
an **ordinary** string, so escapes double: `(Regex "\\d+")` equals `#"\d+"`.
Regex uses PCRE through Nim's `std/re` wrapper. `Regex` is an immutable, opaque
value under `Any` (§7.2), compiled once, printing back as `#"..."`. Because
strings are UTF-8, Unicode matching is the default.

MVP surface:

```gene
#"\d+"
#"""^\s*(\w+)\s*$"""
(Regex "\\d+")
(re .match s)            # => a Match, or void if no match
(re .find_all s)         # => a (Stream Match Never), lazy (§6)
(re .replace s tmpl)     # first match; tmpl backrefs \1, \k<name>
(re .replace_all s tmpl) # every match
(re .split s)            # => (List Str)
```

`Match` is a **typed node** (§7.1) with specified fields: `^text` (whole match),
`^groups` (numbered captures, `(List Str?)`), `^named` (`(HashMap Str
Str?)`, name→capture), and `^start`/`^end` (half-open byte offsets:
`start <= i < end`). Unmatched optional captures are `nil`. It destructures with
the ordinary pattern engine (§8).

Flags are canonicalized in `i`/`m`/`s`/`x` order. Invalid or duplicate flags are
read/constructor errors. `(Regex ^flags "im" "\\d+")` is equivalent to
`#"\d+"im` after ordinary string escaping.

Replacement templates recognize `\0` for the whole match, `\1` style numbered
captures, `\k<name>` named captures, and `\\` for a literal backslash. Unknown
replacement escapes are errors.

**Deferred until the basic value/API lands** — both overcommit to capture-binding
and template semantics before the core is proven:

- **Regex as a `match` pattern** — `(when #"..." …)` binding named/numbered
  captures branch-locally, with the failed-match and duplicate-group-name rules.
- **`^to` rewrite rules** — a regex carrying its replacement template so
  `(rule .apply s)` substitutes without a call-site template.

Implementation note: the first implementation uses Nim's PCRE-backed `std/re`
API in native builds. Wasm builds preserve the `Regex` value shape but report
regex operations as unavailable until PCRE is linked into the wasm artifact.
Named-capture extraction records the common PCRE group declaration forms
`(?<name>...)`, `(?'name'...)`, and `(?P<name>...)`.

### 7.7 Statement return types: `Nil` and `Void`

A function declared `: Nil` or `: Void` is a **statement signature**. Its body's
trailing value is discarded and the call yields the declared unit — `nil` for
`Nil`, `void` for `Void` — whatever the body last evaluated.

```gene
(fn note [entry : Str] : Nil        # no trailing `nil` needed
  (log .push entry))

(fn reset [cell : (Cell Int)] : Nil
  (if_yes (< (cell .get) 0) (return))   # `return` needs no argument
  (cell .set 0))
```

Three consequences, all deliberate:

- **A body may end on real work.** Without this rule, every effectful function
  ends in a bookkeeping `nil` that exists only to satisfy the annotation, and a
  statement in tail position has to be wrapped in a throwaway binding purely to
  discard its value.
- **`(return)` takes no argument**, and `(return nil)` means the same thing. A
  bare `return` previously yielded `void` and so was rejected by a `: Nil`
  signature — a rule with no upside.
- **`(return <value>)` is a compile error**, not a silent discard:

  ```text
  return in a Nil/Void function takes no value; use (return) or (return nil)
  ```

  The distinction is between a value the author *wrote* and one that merely
  happens to be in tail position. Discarding the trailing value is the point of
  the rule; discarding an explicit `(return 42)` would hide a mistake, since the
  only reason to write it is a belief that the caller receives it. The check is
  syntactic — the argument must be absent or the literal `nil` or `void` — so it
  is decidable without inference and reads the same in the compiler and in the
  head. It fires at compile time on both backends.

Only the **bare** `Nil` and `Void` symbols select this behavior. `Int?` is a
union that happens to admit nil, and it adapts its value normally — so
`(fn f [x : Int] : Int? (if (> x 0) x))` still returns the `Int` when there is
one.

The web profile (`docs/web-compilation.md`) implements the identical rule:
a `Nil`/`Void` function evaluates its body for effect and returns `null` /
`undefined`. The two backends must stay in step, or the same source means
different things depending on where it runs.

### 7.8 `gene/math`

The numeric primitives, in one namespace reachable as `gene/math` or `$math`:

```gene
($math/floor 3.7)          # => 3.0
($math/clamp 15 0 10)      # => 10
($math/hypot 3 4)          # => 5.0
```

| | |
|---|---|
| rounding | `floor` `ceil` `trunc` `round` |
| sign | `abs` `sign` |
| powers | `sqrt` `pow` `exp` `log` `log2` `log10` `hypot` |
| trigonometry | `sin` `cos` `tan` `asin` `acos` `atan` `atan2` |
| ordering | `min` `max` `clamp` |
| constants | `pi` `e` `tau` |

Two rules decide the surface, and both follow from §7.4:

**Rounding and sign are kind-preserving.** `(floor 3.7)` is `3.0`, not `3`; an
Int argument yields an Int. That follows C and JavaScript rather than the
tidier-sounding "rounding produces an integer", because kind-strict equality
makes a silent `Float`→`Int` hop a live hazard in a comparison chain, and
because the web profile lowers `Int` to `bigint` — so a rounding step that
returned `Int` would drop a bigint into otherwise-`number` arithmetic and throw
at the first mixed operation. The transcendental functions always return
`Float`, which is the only honest result kind for them.

Because §7.4 makes every mixed operation an error, the conversion has to be
written down, and the two builtins that do it are `to_int` and `to_float`:

```gene
($to_int 3.7)     # 3     — truncates toward zero, like the trunc it follows
($to_int -2.9)    # -2
($to_int 42)      # 42    — already an Int
($to_float 3)     # 3.0
($to_float 3.0)   # 3.0   — already a Float
```

`to_int` raises on NaN and on any Float outside the Int range, for the same
reason `(sqrt -1)` raises: a silently wrapped or saturated integer propagates
to the far end of a computation and reports the wrong place as the failure.
`to_float` is exact up to 2^53 and returns the nearest Float beyond it, which
is the value the arithmetic would have produced anyway. Neither is in the
portable web stdlib — the profile has one numeric kind, so a module that needs
them is a VM module and the profile says so rather than lowering them to
something that only looks equivalent.

`min`, `max`, and `clamp` return the winning *argument* rather than a rebuilt
value, so an Int past the Float mantissa keeps its precision.

**A domain violation raises; it never returns NaN.** `(sqrt -1)`, `(log 0)`,
`(asin 2)`, and a `clamp` whose bounds are inverted are all errors. NaN
propagates silently to the far end of a computation and reports the wrong place
as the failure.

The web profile provides the same namespace, lowering to `Math.*` with guards
only where the VM raises — so `(sqrt -1)` fails on both backends rather than
erroring on the server and yielding NaN in the browser. It is stricter in one
way: the profile's signatures are `F64`, not kind-preserving, because
`Math.floor` on a bigint throws. A polymorphic signature would compile and then
fail at runtime on exactly the argument the annotation invited, so the profile
rejects `Int` at compile time instead. `tests/transpile/fixtures.json` pins the
agreement.

### 7.9 `gene/bit` and `gene/binary`

The primitives a binary format needs. Without them a checksum cannot be written
in Gene at all, which is what kept every binary encoder in a host language.

```gene
($bit/xor 12 10)                    # => 6
($binary/from_list [137 80 78 71])  # => #B16#89504e47
($fs/write_bytes "out.png" data)
```

**`gene/bit`** — `and` `or` `xor` `not` `shl` `shr`, over Int. Operands are the
I64 fast path rather than the arbitrary-precision range: a bit operation on a
value wider than 64 bits has no single obvious meaning — two's complement of
what width? — so it is rejected rather than silently truncated. Shift counts
outside `0..63` are an error for the same reason. **`shr` is logical**, not
arithmetic: an arithmetic shift would sign-extend and corrupt the high byte of
every masked value, which is precisely what a checksum loop does.

**`gene/binary`** — `from_list` `to_list` `size` `get` `concat` `slice`
`from_str` `to_str`, over the immutable `Bytes` value (§7.5). Building one is a
two-step job: accumulate into an ordinary mutable `List` of Int, then convert
once. That keeps `Bytes` immutable as designed instead of introducing a second
mutable sequence type whose only purpose is construction.

The namespace is `binary` and not the obvious `bytes` because `bytes` is
already a global function — `(bytes "hi")` gives a Str's bytes as a List of
Int — and shadowing a shipped name to gain a tidier spelling is not a trade
worth making.

**`fs/write_bytes`** completes the path: same capability and same path
confinement as `fs/write_text`, but the payload is `Bytes`, so a byte with the
high bit set survives instead of being mangled by UTF-8 handling.

The archived `new_world` example carried the worked case — CRC32, Adler-32, a
zlib stream, and PNG chunk layout, all in Gene with no host help.

### 7.10 Loop bodies are scopes; integral Floats index sequences

Two rules that keep the VM and the web profile meaning the same thing.

**A loop body is a scope.** A `var` inside `while`, `loop`, or `repeat` is one
declaration executed once per iteration, not a redeclaration, so it rebinds:

```gene
(while (< i 3)
  (var x (* i 2))        # fresh each iteration
  (set i (+ i 1)))
```

`for` already behaved this way, and JavaScript block scope gives the web
profile the same thing — so before this the same source ran transpiled and
failed on the VM with "duplicate binding". A genuine redeclaration
(`(var x 1) (var x 2)` in one scope) is still an error, and two `var` forms in
mutually exclusive branches are still legal, because the compiler distinguishes
them by loop depth rather than by name alone. A function defined inside a loop
starts at depth zero and keeps the strict rule.

**An integral Float indexes a List or Node**, for reads and writes alike:

```gene
(var i 1.0)
xs/%i            # => the second element
(set xs/%i 99)
```

The web profile lowers an `F64` index to `xs[i]`, which JavaScript accepts, so
rejecting it on the VM made the same source index a list in the browser and
fail — or worse, on the read path, silently yield `void`, which is a legal
value rather than an error. A *non*-integral Float still names no element:
`xs/%1.5` is a bug in any backend, and truncating it is how that bug survives.

### 7.11 Named parameters reach the web profile

`^name : T` was a VM-only parameter form. A module function declaring one
failed to transpile, which put every named-argument API on one backend — and
`^name` is where argument ergonomics belong for a registration-style API, so
that ruled the shape out rather than the spelling.

The profile now takes them on **module functions**, with `^name local : T` and
`^name : T?` as on the VM, and lowers them to positional JavaScript slots in
declaration order: the profile knows every callee statically, so a call's props
are placed into their slots at analysis time. No options object, no allocation,
and an exported function stays positionally callable from JavaScript.
Named parameters remain limited to module functions in the web profile.
Positionals and named parameters may interleave; optional positionals follow
required positionals. Fixed parameters support explicit defaults, and a
nil-admitting annotation supplies an implicit nil default. A function with
required named arguments cannot satisfy a positional-only callable shape;
optional named defaults may be omitted through that shape. See
`docs/web-profile.md` for the supported callable forms and default rules.

**And a call now accounts for every prop.** Props on a call were dropped
silently — `(add 1.0 2.0 ^oops 9.0)` compiled and discarded `^oops`, while the
VM raised `got unexpected named argument` for the same source. That is the
divergence class §7.10's two rules exist to close, and it was invisible to
every fixture because the profile emitted working code.

---
