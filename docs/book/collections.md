# Collections and streams

This chapter covers Lists, Maps, Sets, and nodes, the two families of
operations that read them, and the pipelines and Streams that transform
them.

## Lists

A List holds values by position. `.get` reads a position, and a negative
position counts from the end. A position past the end reads `nil`:

```gene runnable
(let xs [10 20 30])
[(xs .get 0) (xs .get -1) (xs .get 9) xs/.first xs/.last (xs .contains? 20)]
# [10 30 nil 10 30 true]
```

A List made with `[…]` is mutable. `push` appends, and `set` replaces a
position:

```gene runnable
(let xs [1 2])
(xs .push 3)
(xs .set 0 9)
xs
# [9 2 3]
```

`(strings .join separator)` joins a List of strings, and `$reverse`,
`$take`, and `$drop` make new Lists from part of one.

## Maps

A property map, `{^name "Ada"}`, has symbols for keys. A general Map,
`{{"red" : 1 2 : "two"}}`, takes keys of any type. Both answer the same
messages:

```gene runnable
(let m {^name "Ada"})
(m .put "role" "admin")
[(m .get "name") ($has_key? m "role") m/.size (m .assoc "x" 1) m]
# ["Ada" true 2 {^name "Ada" ^role "admin" ^x 1} {^name "Ada" ^role "admin"}]
```

- `get` reads a key and `put` writes one. `delete` removes a key and returns
  the removed value.
- `assoc` and `dissoc` return a new Map and leave the original alone.
- A property map takes its key as a string or a symbol.
- `$has_key?` tells a stored `nil` from a missing key.

> **Watch out:** a property map's keys are symbols, and a symbol never
> equals a string. When you iterate over a Map, convert a key with
> `$to_str` before comparing it with a string.

## Two families of operations

Collection functions come in two families, and the name says which view of
the value they read:

- **The list family reads items:** `for`, `$size`, `$empty?`, `$map`,
  `$filter`, `$filter_map`, `$each`, `$first`, `$last`, `$contains?`,
  `$take`, `$drop`, `$reverse`, `$into`, and `.to_stream`. It works on Lists,
  Sets, Streams, Ranges, and strings.
- **The map family reads entries:** `map_for`, `$map_size`, `$map_empty?`,
  `$map_map`, `$map_filter`, `$map_filter_map`, `$map_each`,
  `$to_pairs_stream`, and `$has_key?`. It works on Maps and on a node's
  properties.

The `.size` and `.empty?` messages work on both Lists and Maps.

> **Watch out:** a list-family function given a Map names the map-family one.
> `($size {^a 1})` fails with `use $map_size for a Map's entries`, and
> `($map {^a 1} f)` fails with `use $map_map for a Map's entries`.

## Transforming lists

`$map` keeps one result per item, and `$filter` keeps the items its function
accepts. `$filter_map` maps and then drops `nil` results, while keeping
`false`, `0`, and `""`:

```gene runnable
(fn keep_positive [n] (if (> n 0) n else nil))
[($map [1 2 3] (fn [n] (* n 10)))
 ($filter [1 2 3 4] (fn [n] (> n 2)))
 ($map [-1 2] keep_positive)
 ($filter_map [-1 2] keep_positive)]
# [[10 20 30] [3 4] [nil 2] [2]]
```

A Path works as the function, which reads a field from each item:

```gene runnable
(let people [{^name "Ada"} {^name "Grace"}])
($map people /name)
# ["Ada" "Grace"]
```

`$each` runs a function for its effect on each item and returns `nil`.

## Iterating maps

`map_for` binds each key and value in turn. The map-family transforms take a
function of the value:

```gene runnable
(let scores {^Ada 7 ^Grace 9})
(var lines [])
(map_for [name score] in scores
  (lines .push $"${name}: ${score}"))
[lines
 ($map_map scores (fn [score] (* score 10)))
 ($map_filter scores (fn [score] (> score 8)))
 ($into ($to_pairs_stream scores) [])]
# [["Ada: 7" "Grace: 9"] {^Ada 70 ^Grace 90} {^Grace 9} [[Ada 7] [Grace 9]]]
```

Like `for`, `map_for` is a statement whose value is `nil`, so collect results
in a binding. `$to_pairs_stream` gives the `[key value]` pairs when a
function needs both.

## Sets

`(Set …)` makes a Set, which ignores repeated values:

```gene runnable
(let s (Set 1 2 2))
[($set_size s) ($set_has? s 2) (s .contains? 3)]
# [2 true false]
```

## Nodes as data

A node has a head, properties, and body items. Quoting keeps it as data.
`.head` and `.body` read its anatomy, a name in a path reads a property, and
the map family reads its properties:

```gene runnable
(let task (quote (task ^done false "Write docs")))
[task/.head task/done task/.body ($map_size task)]
# [task false ["Write docs"] 1]
```

`$head`, `$props`, `$body`, and `$meta` return the four parts. Metadata
(`@source "x"`) rides along with a value but is ignored by `==`.

> **Watch out:** a name in a path always reads a property, never the
> anatomy: `task/body` reads a property named `body`. Use `task/.body`.

## Pipelines

`->` passes a value into the first argument of the next call, and `_` puts it
in another position. `=>` maps each item through the next step, lazily, and
`$into` collects:

```gene runnable
[(2 -> + 3 -> * 4)
 (10 -> / 100 _)
 ([1 2 3] => * 2 -> $into [])]
# [20 10 [2 4 6]]
```

A pipeline reads left to right in the order the work happens:

```gene runnable
([1 2 3 4 5]
  -> $filter (fn [n] (> n 1))
  => (fn [n] (* n n))
  -> $take 3
  -> $into [])
# [4 9 16]
```

> **Watch out:** `=>` is lazy even at the end of a pipeline. `([1 2 3] => * 2)`
> is a Stream, and nothing has run until something consumes it, such as
> `$into` or `$each`.

## Streams

A Stream produces items one at a time, when they are pulled. `.to_stream`
makes one from a List, `$range` makes one over Ints, and `.next` pulls an
item:

```gene runnable
(let s ([1 2 3] .to_stream))
[s/.next s/.next (($range 0 3) -> $into [])]
# [1 2 [0 1 2]]
```

`$take` bounds how many items are pulled, and `.close` ends a Stream early.
Closing runs the cleanup of anything the Stream holds open.

## Generators

A function marked `^^generator` returns a Stream. Its body runs only as items
are pulled, and `yield` produces each one:

```gene runnable
(fn ^^generator naturals []
  (var n 0)
  (while true
    (yield n)
    (set n (+ n 1))))
((naturals) => * 2 -> $take 4 -> $into [])
# [0 2 4 6]
```

The Stream is infinite here, and `$take 4` is what stops it. `yield`
requires the `^^generator` marker on its own function.

## Chaining sends

A `;` between send stages passes each stage's result to the next stage,
starting with the value before the first `;`. It keeps a chain at one
indentation:

```gene runnable
(var xs [1 2 3])
(xs .to_stream ; .filter (fn [x] (> x 1)) ; .into [])
# [2 3]
```

The stage before the first `;` is an ordinary call or send; each later stage
starts with `.` and receives the previous result. `(xs .size ; .to_str)`
therefore sends `to_str` to an Int and raises `no message 'to_str' on Int`.

## Immutable values

`#[…]` and `#{…}` are immutable literals. `$freeze` makes a value and
everything inside it immutable, and `$thaw` makes a mutable copy:

```gene runnable
(let frozen ($freeze [1 [2]]))
(let copy ($thaw frozen))
(copy .push 3)
[(try (frozen/1 .push 3) catch Throwable "immutable") copy]
# ["immutable" [1 [2] 3]]
```

`$assoc_in` and `$update_in` change a nested value along a Path and return a
new root, leaving the original as it was:

```gene runnable
(let v {^a {^b 1}})
[($assoc_in v /a/b 2) ($update_in v /a/b (fn [x] (+ x 10))) v]
# [{^a {^b 2}} {^a {^b 11}} {^a {^b 1}}]
```

## Ordering

`$order/sort` sorts a List, `$order/sort_by` sorts by a key, and
`$order/compare` gives `-1`, `0`, or `1`:

```gene runnable
[($order/sort [3 1 2])
 ($order/sort_by [{^n 2} {^n 1}] /n)
 ($order/compare 1 2)]
# [[1 2 3] [{^n 1} {^n 2}] -1]
```
