# Nil, void, optional binding, and mapping

`nil : Nil` is a stored absence value. `void : Void` is missing/no-result,
with operation-specific normalization. `T?` means `T | Nil`; it excludes Void.
Neither singleton type is `Never`.

## Fixed parameters

`x : T?` and `^x : T?` have an implicit nil default. Explicit `(? T)`, unions
admitting Nil, and aliases expanding to those forms follow the same rule.
An explicit default takes precedence. A supplied nil does not select a default.
`Any` alone stays required. Parameter binding checks supplied arguments and
then binds and checks defaults before entering the body.

```gene
(fn age_label [age : Int?] : Str
  (if ($nil? age) "unknown" $"${age}"))

(age_label)       # "unknown"
(age_label nil)   # "unknown"
(age_label 25)    # "25"
```

Optional positional parameters follow required positionals and cannot precede
a rest parameter. Named parameters may interleave with positionals. Rest
parameters retain zero-or-more arity; their element annotation does not supply
a default. Callable type vectors describe their existing explicit call shapes;
a nullable type within `(Callable [Int?] R)` does not make that view's slot optional.
Foreign ABI declarations also retain their own fixed call shapes; the implicit
default is supplied by a Gene function's parameter binder.

A positional void is supplied and fails a `T?` check. Literal void named props
are omitted by the reader; computed named Void remains supplied and is checked.
A map that removed a void entry before argument spreading supplies no such key.

## Fields and storage

A declared field type constrains present values. An omissible field's unchecked
lookup type is its declared type union Void. A required-field pattern on a
validated nominal receiver proves presence and therefore excludes Void while
preserving a possible stored nil. The same symbolic pattern can match raw Gene
node data; a matching head alone does not prove that its fields satisfy a schema.

```gene
(type Person ^props {^age Int?})
(fn age_of [p : Person] : Int? (?? p/age nil))
```

For an omitted age, `p/age` is void; for `^age nil`, it is nil. Raw `p/age` does
not satisfy an `Int?` return boundary when the key is absent.

| Operation | Result of void |
| --- | --- |
| Raw prop/map storage | Delete/omit the entry |
| List/body storage | Store nil, preserving position; check the normalized value's type |
| `yield void` | Emit no item |
| Missing lookup | Return void |
| `map` callback | Normalize to nil, then store/emit and check the output type |
| `filter_map` callback | Drop the result |

## Mapping laws

Let `N(void) = nil`, and `N(v) = v` otherwise. `map` emits `N(f(x))` for each
input. Lists and streams preserve one result per input; maps preserve keys.
Sets retain ordinary deduplication. `filter_map` drops only void and retains
nil, false, zero, and empty strings. Generic calls and direct sends share these
rules: `($filter_map xs f)` and `(xs .filter_map f)` use the same operation.

```gene
(fn keep_positive [x : Int] : (| Int Void) (if (> x 0) x void))
($map [-1 2] keep_positive)                              # [nil 2]
($into ($map ($to_stream [-1 2]) keep_positive) [])       # [nil 2]
($filter_map [-1 2] keep_positive)                       # [2]
```

For a finite sequence and a pure, total callback, eager map and fully collected
lazy map produce equal data. Fusion must retain intermediate normalization:

```text
map(map(xs, f), g) = map(xs, x => g(N(f(x))))
```

This is mathematical notation, not Gene syntax. Ordinary unnormalized function
composition is sufficient when f cannot produce void. Laziness still changes
evaluation timing, partial consumption, side effects, and error timing.

The iterate delimiter `=>` uses map normalization. Generator yield and selector
stream projections retain their explicit non-emission/missing-result policies.

Coverage: `tests/test_nil_void.nim`, executable specs, pipeline tests, and shared
`nil_void.*` VM/web fixtures. Runnable introduction: `examples/nil_void_demo.gene`.
