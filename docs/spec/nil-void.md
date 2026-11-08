# Absence: nil is the one absence value

`nil : Nil` is Gene's only absence value. There is no `void`. A missing
property, key, or index read yields `nil`; so does a function that ends in a
statement, a `(return)` with no value, and an omitted `T?` parameter. `T?` means
`T | Nil`. `Never` is the uninhabited type and is unrelated to `Nil`.

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

`x : T?` and `^x : T?` have an implicit nil default; so do `(? T)`, unions that
admit `Nil`, and aliases expanding to them. An explicit default takes
precedence, and a supplied nil does not select a default. `Any` alone stays
required, and so does `Present`; `Present?` is optional. Optional positionals
follow required positionals and cannot precede a rest parameter.

```gene
(fn age_label [age : Int?] : Str
  (if ($absent? age) "unknown" $"${age}"))

(age_label)       # "unknown"
(age_label nil)   # "unknown"
(age_label 25)    # "25"
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
`(return)`. Path and selector projections emit nil for a missing step.

```gene
($map [-1 2] keep_positive)           # [nil 2]
($filter_map [-1 2] keep_positive)    # [2]
```

## JSON

`$json/stringify` writes a stored nil as `null` and an absent key not at all.
`^^omit_nil` leaves out every nil-valued map key at every depth; nil list
elements are always written, because position carries meaning.

```gene
($json/stringify {^a nil ^b 1})              # {"a":null,"b":1}
($json/stringify {^a nil ^b 1} ^^omit_nil)   # {"b":1}
```

## Removed names

`void`, `Void`, `$void?` and `$nil?` do not exist; each reports a targeted
error naming its replacement. `C/Void` remains the C foreign-signature type.

Coverage: `tests/test_nil_void.nim`, executable specs, and the shared
`nil_void.*` VM/web fixtures. Runnable introduction: `examples/nil_void_demo.gene`.
