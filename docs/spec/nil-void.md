# Absence: nil is the one absence value

`nil : Nil` is Gene's only absence value. There is no `void`. `nil` means
"there is no value here": a missing Map key, an omitted optional field, an
index out of range, a step through `nil`, a function that ends in a statement,
and a `(return)` with no value all yield it. A read that cannot be right, such
as a misspelled field or a path through a number, raises instead (see
[Path reads](#path-reads)). `T?` means `T | Nil`. `Never` is the uninhabited
type and is unrelated to `Nil`.

## Presence

`($absent? value)` is true exactly for `nil`. `($present? value)` is its
opposite. Neither is a truthiness or emptiness check: `false`, zero, empty
strings and empty collections are present. Only `false` and `nil` are falsy.

```gene
[($present? nil) ($present? false) ($present? 0) ($present? "") ($present? [])]
# [false true true true true]
```

`Present` is the type of every value except nil. It is a type, not a class: it
carries no tag, cannot be a parent, and has no messages. `Any = Present | Nil`
and `Present? = Any`. A runtime check against `Present` is "not nil", and it
looks only at the value itself, not at its contents.

```gene
(fn require_value [x : Present] x)    # (require_value nil) raises
```

## Fixed parameters

A fixed parameter, positional or named, may be omitted only when it declares a
default with `=`. Its type says which values it accepts and nothing about
omission. So a parameter that must be passed and may be `nil` is writable:

```gene
(fn a [x : Int?] x)          # required; (a) is an arity error; (a nil) is nil
(fn b [x : Int? = nil] x)    # may be omitted
(fn c [^x : Int?] x)         # required; (c) is "missing named argument: x"
(fn d [^x : Int? = nil] x)   # may be omitted
```

The rule covers `fn`, `message` and `ctor` parameters and protocol message
requirements. `Any`, `Present`, `Present?` and `T?` all behave alike. An
explicit default runs at call time, and a supplied nil does not select it.
Optional positionals follow required positionals and cannot precede a rest
parameter. Record prop fields and a checked `Callable` view's `^named` shape
are schemas, where a nil-admitting type still permits omission.

```gene runnable
(fn age_label [age : Int? = nil] : Str
  (if ($absent? age) "unknown" $"${age}"))

[(age_label) (age_label nil) (age_label 25)]
# ["unknown" "unknown" "25"]
```

## Testing and binding

`(if_present name expr body… (else body…))` evaluates `expr` once. When its
value is present, `name` is bound to it and the body runs; otherwise the
optional trailing `else` clause runs, and without one the form is `nil`.
Presence is the test, so `false`, `0`, `""` and empty collections take the
body.

```gene runnable
(let options {^subject "Ada"})
[(if_present s options/subject ($str/upper s) (else "none"))
 (if_present s options/topic ($str/upper s) (else "none"))]
# ["ADA" "none"]
```

`name` belongs to the form: it is visible in the body only, not in `expr`,
not in the `else` clause and not after the form, and it shadows an outer
binding of the same name for the body. Bindings the body or the `else` clause
make with `let` or `var` keep the enclosing scope, as in `if`. Each execution
binds `name` afresh, so a closure made in the body keeps that execution's
value. `return`, `break`,
`continue`, `yield` and `await` act as they do inside `if`, and the last form
of each clause is in tail position. `(then …)` and `(elif …)` are rejected, and
`(else …)` must be last.

To leave early when a value is absent, bind it with `??` instead:

```gene
(let task (?? (find_task id) (return nil)))
```

## Path reads

A path step reads one member of a target. The result depends on the target:

| Target | Name segment | Int segment |
| --- | --- | --- |
| `nil` | `nil` | `nil` |
| PropMap | stored value or `nil` | raises |
| general Map | `nil` | raises |
| plain node, enum value | stored prop or `nil` | body item or `nil` |
| List | raises | item or `nil` |
| typed value | see below | body item, `IndexRead`, or `nil` |
| Namespace, Module, Type, Protocol | the member or `nil` | raises |
| Stream | raises | raises |
| anything else | raises | raises |

"Anything else" is every value with no members a path can read: Int, Float,
Bool, Str, Char, Sym, functions, Set, Range, date and time values, Bytes,
Buffer, Cell, Task, Channel and the rest. A Stream is read item by item with an
explicit `($map stream /x)`; a direct path step rejects it before pulling any
item. A Map has no positions, so an integer key is read with `(m .get k)`.

A name segment reads a prop, never node anatomy: `q/head` is the prop named
`head`. The anatomy is read with the explicit projections, `value/.body` and
the like, or a computed function segment such as `q/%$head`.

On a typed value a name segment answers, in this order:

1. a stored prop: its value;
2. a diagnostic the runtime attached to an error (`file`, `line`, `col`,
   `trace`, `cleanup_truncated`, `cleanup_reason`): its value;
3. a field the type or an ancestor declares but the value does not store:
   `nil`;
4. if the value is an `Error`: `nil`, because a handler probes an error of
   unknown type for `code`, `cause` and the like;
5. otherwise it raises `P has no field 'name'`, the same error a write makes.

Every read spelling follows the table: `v/x`, `v/%k`, `(/x v)`,
`((Path "x") v)`, a Path used as a callback or a pipeline stage, and
`(v .get k)` on a node. A Path's `^default` supplies a value for a missing
step; it does not catch these errors. Three spellings test rather than read,
and stay total: `($has_key? v k)` is `false`, a pattern that names the field
does not match, and `v/.props/k` reads the open props Map, so it is `nil`.

```gene runnable
(type P ^props {^name Str ^age Int?})
(let p (P ^name "Ada"))
[p/name p/age ($has_key? p "nmae") p/.props/nmae
 (try p/nmae catch Error "raised") (try (let n 6) n/b catch Error "raised")]
# ["Ada" nil false nil "raised" "raised"]
```

## Fields, storage, and presence

A declared field type constrains a stored value. A field whose type admits nil
may be omitted, and reading it gives `nil`; storing `^age nil` keeps the key.
The two differ only in presence:

```gene
(type Person ^props {^age Int?})
(fn age_of [p : Person] : Int? p/age)     # nil when omitted, with no (?? …)
($has_key? (Person) "age")                # false
($has_key? (Person ^age nil) "age")       # true
```

Writing nil stores nil. Removal is explicit:

| Operation | Result |
| --- | --- |
| `(m .delete k)` | removes `k`, returns the removed value or nil; mutates, so a frozen receiver raises even for an absent key |
| `(m .dissoc k)`, `($dissoc_in v /a/b)` | a new root without the entry; untouched children are shared; a missing entry still returns a new equal root |
| `($has_key? v k)` | whether the key is stored, for a Map or a Node (typed records included) |

Typed records get `delete` and `$has_key?` too. `delete` makes the checks a
prop write makes (frozen, native-wrapper, and unknown-field errors) and raises
`cannot remove required field` for a required field. Equality compares stored
entries, so an omitted field and a stored nil differ.

## Statement functions

A function whose declared return type is exactly `Nil` discards its body's
value and returns nil, and `(return)` or `(return nil)` ends it early;
`(return value)` is a compile error. The rule reads the annotation after alias
expansion: `(alias Unit Nil)` gives `: Unit` the same meaning. `Nil?` and unions
containing `Nil` are ordinary return types.

## Collections

`map` yields one result per input, and nil results stay nil. `filter_map` maps
and then drops nil results; it keeps `false`, `0`, `""` and empty collections.
Generators emit what they `yield`, including nil, and end on fallthrough or
`(return)`. A Path mapped over items, `($map items /x)`, emits nil for a missing
step and raises for a read that cannot be right.

```gene
($map [-1 2] keep_positive)           # [nil 2]
($filter_map [-1 2] keep_positive)    # [2]
```

## JSON

`$json/stringify` writes a stored nil as `null` and an absent key not at all.
`^^omit_nil` leaves out every nil-valued map key at every depth; nil list
elements are always written, because position carries meaning. A typed node
whose body has no items is written as its stored props, so an omitted optional
field is absent and a stored nil is `null`. A node with body items, a plain
node with a non-Type head, and a native-wrapper instance are rejected.

```gene
($json/stringify {^a nil ^b 1})              # {"a":null,"b":1}
($json/stringify {^a nil ^b 1} ^^omit_nil)   # {"b":1}
```

## Removed names

`void`, `Void`, `$void?` and `$nil?` do not exist; each reports a targeted
error naming its replacement. `C/Void` remains the C foreign-signature type.

Coverage: `tests/test_nil_void.nim`, executable specs, and the shared
`nil_void.*` and `if_present.*` VM/web fixtures. Runnable introduction:
`examples/nil_void_demo.gene`.
