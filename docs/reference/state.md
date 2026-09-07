# Mutation, immutable values, and cells

**Status:** detailed design reference and rationale. The implemented contracts
are [types](../spec/types.md), [concurrency](../spec/concurrency.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 12. Mutability, immutable values, and cells

Gene distinguishes container mutability from binding mutation and from cross-task safety.

Strings are immutable. Plain lists, maps, general nodes, and typed instances may be mutable values:

```gene
[1 2 3]
{^name "Alice"}
(User ^name "Alice")
```

The `#` reader prefix constructs a **shallow immutable** container:

```gene
#[1 2 3]
#{^name "Alice" ^age 30}
`#(user ^name "Alice")
```

Shallow immutability means the container's head, props, body, keys, and positions cannot be changed. Values stored inside it are not recursively frozen:

```gene
#[($cell 1)] # immutable list containing a mutable Cell
```

Immutable containers support persistent functional updates with structural sharing where practical:

```gene
(var xs  #[1 2 3])
(var xs2 (xs .assoc 1 20))

(var user2 ($assoc_in user /address/city "Raleigh"))
(var user3 ($update_in user /score (fn [x] (+ x 1))))
```

`assoc_in` and `update_in` never mutate their input. They return a new root and preserve the root's mutable/immutable class unless an API explicitly requests another representation. Missing intermediate paths are errors unless the chosen operation explicitly permits construction. Writing `void` into a map or untyped/optional prop removes it; writing `void` into a list/body position stores `nil`. Every typed instance reconstructed along the path is revalidated, including a node whose `head` is changed to a `Type`; functional updates cannot forge an invalid nominal value.

Mutable containers use explicit mutating messages:

```gene
(xs .set 1 20)
(xs .push 30)
(m .put key value)
(n .set_prop name value)
```

`List/push` appends to a mutable list in amortized O(1) time and returns the
inserted value. It stores `nil` when given `void`. Use it for owned local
accumulators; repeated copy-and-append growth is quadratic.

A `Buffer` additionally has two **bulk** mutations, and they are not sugar over
a `set` loop — they do strictly less work:

```gene
(b .fill 0.0)
(b .fill 0.0 start end)
(dst .copy_from src)
(dst .copy_from src source_start source_end dest_start)
```

The bare forms address the whole buffer; the long forms take a half-open
`[start, end)` range, and `copy_from`'s last argument is the offset written to
in the destination.

Writing `n` elements one `set` at a time re-validates the element type `n`
times, re-decodes the index `n` times, and pays one interpreter dispatch per
element. `fill` checks its value **once** — the element boundary is a property
of the value, not of the slot — and `copy_from` skips the check entirely when
the two buffers share an element type, because every element of the source
already satisfied that identical boundary on the way in. Measured at 512
elements: 348x for the fill, 150x for the copy. The web profile emits
`TypedArray.fill` and `TypedArray.set`, so the same source is bulk on both
backends.

Range endpoints are half-open, so `end - start` is the count. An endpoint past
the end of the buffer, or an `end` before its `start`, raises — a wrong bound
is a mistake rather than a request to clamp. `copy_from` onto the same buffer
**moves** rather than smears: overlapping ranges copy in the safe direction, so
shifting a buffer along itself is well defined.

For a typed instance, `set_prop` accepts only declared properties and checks
the declared field type before changing the value. Removing a required field
with `void` is an error; `void` still removes an optional or untyped property.
`set_body` and `push_body` likewise enforce the declared fixed/rest body
schema after construction and leave the original instance unchanged on failure.

Selectors remain read-only paths; Gene does not overload selector access with hidden mutation.

### 12.1 Binding forms and mutation

Gene has three binding forms. `let` and `var` differ only in whether the binding
may be rebound, never in what the value can do; `const` additionally freezes an
aggregate value, which is the one exception and is spelled out below:

```gene
(let x 1)     # fixed binding, fixed value — the default idiom
(var y 1)     # fixed binding, rebindable value
(const K 1)   # fixed compile-time constant, module level (see below)
(set y 2)     # rebinds a `var`; `(set x ...)` on a `let`/`const` is a compile error
```

| Form    | Binding | Value       | `set` allowed | Scope |
| ------- | ------- | ----------- | ------------- | ----- |
| `let`   | fixed   | fixed       | no            | any |
| `var`   | fixed   | rebindable  | yes           | any |
| `const` | fixed   | fixed, resolved before runtime, frozen | no | module / namespace |

`set` takes either a bare name or a glued path. `(set name value)` rebinds a
`var`; applying it to a `let` or `const` is a compile-time error. `(set path
value)` mutates the addressed slot in place. Extra arguments are an error.
Mutation APIs use ordinary snake_case names such as `set_prop`, `put`, and
`push`; trailing `!` is reserved for fexpr invocation. Selectors stay read-only
for reading—`set` is an explicit write form, not hidden mutation through
selector access.

```gene runnable
(type T ^props {^n Int})
(var t (T ^n 1))
(set t/n 2)      # 2 — checked against the field's declared type
(var xs [1 2 3])
(set xs/0 9)     # [9 2 3]
(var m {^a 1})
(set m/a 2)      # {^a 2}
```

For a path target, evaluation is fixed left to right:
base, then any dynamic segments, then the value once. Intermediates resolve
**read-only** and only the final container is mutated, in place — `assoc_in`
remains the copying counterpart, and having both is the point.

Every `set` goes through one checked seam, so assignment obeys exactly the
rules construction does: the closed schema, declared field types for props
**and** typed body positions, the frozen bit, and `void` handling. A path
segment is a key, never something applied: a dynamic `%k` segment must evaluate
to a `Sym`, `Str`, or `Int`. The virtual `Node` projections — `head`, `props`,
`body`, `meta` — are rejected as assignment targets because they return
detached copies (§1.3), so writing through one would silently update a
temporary; a *real* prop of that name keeps ordinary precedence and is
assignable. A `ctor` may use `(set self/field v)` to populate fields
incrementally, and the completed instance is still validated atomically at
publication.

**`let` is the default; `var` is the marked exception.** "Fixed value" means the
binding is not rebound, not that the value's internal state is frozen. Mutable
state lives *inside* the value, so idiomatic mutable state is a `let` binding of
a mutable value:

```gene
(let counter ($cell 0))          # the binding never moves; the Cell mutates
(counter .update (fn [x] (+ x 1)))
```

A namespace-level `var` is unsynchronized mutable global state — shared across
tasks and not `Send` (§13) — so it is deliberately the unusual spelling. Named
declarations (`fn`, `type`, `enum`, `protocol`, `ns`, `macro`, `alias`)
behave as `let`: their bindings are fixed.

**Stable bindings enable member folding (§2.1).** Because a `let`/`const` member
is fixed in both slot and value, a slash path resolving to one may be compiled to
a direct member reference. A `var` member is fixed in slot but rebindable, so a
path to one compiles to a guarded slot load, never a folded value. The
`let`/`var` distinction is therefore part of a module's compile interface and a
binding *category* for reload compatibility (§15.6).

**`const` denotes a value that resolves before runtime**, and it is a
**module- and namespace-level declaration** — not a function body, and not a loop
body. A body binding is created per call or per iteration, which is not a value
that resolves before runtime; `let` covers those, and its value in a body is
fixed anyway.

**It must also be declared *unconditionally*,** which is stronger than "outside a
function and a loop": a `const` nested in a branch is a compile error.

```gene
(if debug (const LEVEL 2) (const LEVEL 1))   # error: not unconditional
(do (const LEVEL 1))                         # fine — `do` groups, it does not branch
```

A use of a `const` resolves to its value rather than to a load of the binding,
so a conditionally-declared one would let a use site and the binding disagree
within one program. `do` is transparent grouping and stays legal.

Its initializer must *already be* a constant rather than produce one: a scalar,
or a `List`/`Map` whose every element is itself constant. A name in value
position is a binding read, not a literal, so `(const K other)` is rejected even
when `other` is itself a `const`. That closed subset is why `const` needs none of
the compile-time evaluation deferred in §11.2 — the value is in hand while
compiling, and nothing runs.

**A `const` aggregate is frozen, and this is the one place `const` differs from
`let` in what the *value* does rather than what the binding does.**
`(let xs [1 2 3])` hands out a mutable list; `(const xs [1 2 3])` is `#[1 2 3]`
and a mutation through it raises. The alternative would mean a module constant is
frozen when compiled for the web profile and mutable on the VM, from identical
source.

That backend agreement is what `const` is for. A top-level `let` is a runtime
slot on the VM and a literal-only compile-time constant in the web profile, which
is one word meaning two things depending on which side reads it; `const` means
the one thing on both. Top-level `let` keeps working, so no existing module
breaks.

Two extensions are deliberately not built: an initializer folded from arithmetic
over other constants, and an imported `const` counting as a constant in the
importer. The second is the one with a real question behind it — folding a value
across a module boundary has to say what invalidates a dependent when that value
changes.

### 12.2 `Cell`

`Cell` is a first-class mutable reference and may contain any Gene value, including immediate values:

```gene
(var count   ($cell 0))
(var enabled ($cell true))
(var current ($cell nil))

(count .get)
(count .set 10)
(count .swap 20)                 # returns the old value
(count .update (fn [x] (+ x 1)))
```

`Cell` is a **type**, not a namespace of functions, and `get`/`set`/`swap`/
`update` are its **type-direct messages** (§3). So they take the bare form:
`(count .get)`, `(count .set 10)`, and the path form `count/.get` all resolve
the same message, through the same lookup that serves a user-declared type. A
qualified send names a *protocol* message, so `(count .Cell:get)` is an error;
`Cell/get` is not callable either. Use `(count .get)` for a send or `Self:get`
when the type-direct message is needed as a value.

Being a real type is what makes `Cell` nameable as an impl receiver:

```gene
(protocol Shown (message show [] : Str))
(impl Shown for Cell
  (message show [] : Str ((self .get) .Shown:show)))
```

`List`, `Map`, `Node`, `Buffer`, `Stream`, `Channel`, `Actor`, `AtomicCell`,
`Task`, and `ReplyTo` are types on the same footing and can be named as impl
receivers.

Typed cells use `(Cell T)`. The first checked boundary validates the current
value and retains `T` with the annotation's visibility scope. Every later
`set`, `swap`, and `update` result is checked in that captured scope; `get`
therefore exposes `T`, not `Any`. When `T` is scope-sensitive (for example, a
protocol), another `(Cell T)` boundary must share that conformance scope. A
native compiler may keep primitive values unboxed inside specialized typed
cells, but the semantic model remains a mutable reference containing a Gene
value.

Cell element types are invariant. A raw `Cell` specializes at its first
`(Cell T)` boundary, including `T = Any`; later boundaries must name the same
closed `T`, so passing a cell through `(Cell Any)` first does not permit a later
reinterpretation as `(Cell Int)`. A mismatch reports the retained runtime type,
such as `(Cell Any)`, and identifies invariance as the reason.

`Cell` is intended for local mutable state, closure state, and actor-private state. It is not thread-safe and does not implement `Send`.

### 12.3 `AtomicCell`

`AtomicCell` is the explicit shared-memory escape hatch:

```gene
(var state ($atomic_cell 0))

(state .load)
(state .store 1)
(state .swap 2)
(state .compare_exchange 2 3)
```

Operations are linearizable. The runtime may use machine atomics for supported immediate types and a lock-backed representation for general Gene values. `AtomicCell T` may implement `Send` when `T` is sendable and the implementation provides the required GC barriers.

Actors and channels are preferred over `AtomicCell` for coordinated application state.

### 12.4 Equality, hashing, and freezing

Mutable containers may use structural equality, but they are not valid structural hash keys because their hash could change. `Cell` and `AtomicCell` use identity equality and are not structurally hashable.

An immutable value is hashable only when every value participating in its structural hash is hash-stable. Thus `#[1 2 3]` is hashable, while `#[(cell 1)]` is not.

Library operations may provide explicit conversion:

```gene
($freeze_shallow value)
($freeze value)       # recursive validation/freezing
($thaw value)         # mutable copy
```

Deep freezing fails when it encounters a value that cannot be safely frozen, such as a raw native handle without a defined immutable representation.

---
