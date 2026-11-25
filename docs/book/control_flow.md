# Control flow

This chapter covers grouping, conditionals, pattern matching, and loops.
Each of them is an expression with a value.

## Grouping with do

`do` runs its forms in order and returns the value of the last one:

```gene runnable
(do (let a 2) (* a 21))
# 42
```

Most forms that take a body, such as a function or an `if` arm, already
accept several expressions, so `do` is needed only where exactly one form is
expected.

## if

`if` takes a condition and an arm, and the arm's last value is the result.
`else` opens the alternative, and `elif` adds another condition:

```gene runnable
(fn sign [n : Int] : Str
  (if (< n 0)
    "negative"
    elif (== n 0) "zero"
    else "positive"))
[(sign -3) (sign 0) (sign 5)]
# ["negative" "zero" "positive"]
```

- The condition is exactly one form, and the arm starts right after it.
- An arm holds one or more expressions, so nothing extra is needed to run
  several.
- `elif` and `else` are bare symbols among `if`'s own items, not
  parenthesized clauses.
- With no `else`, a false condition gives `nil`.
- Only `false` and `nil` count as false ([Booleans and
  truthiness](values.md#booleans-and-truthiness)).

> **Watch out:** `(if c a b)` is one arm of two expressions, not a choice
> between `a` and `b`. When `c` holds, both run; when it does not, the result
> is `nil`. Write `(if c a else b)`.

> **Watch out:** a parenthesized `(else …)` or `(elif …)` is not a marker.
> `(if c 1 (else 2))` fails with `grouped clause syntax was removed; write
> flat arms`.

`(if c else x)` runs `x` only when `c` is false. `if_not` is the guard form
for that case. Its forms all run when the condition is false, and it has no
`else`:

```gene runnable
(var log [])
(if_not (> 1 2) (log .push "checked") (log .push "logged"))
log
# ["checked" "logged"]
```

> **Watch out:** `(if_not c a b)` is not a two-way choice either. Every form
> after the condition is its body, so `(if_not false true false)` is `false`.

## if_present

`if_present` tests a value for presence and names it for the arm. The name
is visible in the arm only, and an optional `else` arm runs when the value is
`nil`:

```gene runnable
(fn greeting [options] : Str
  (if_present name options/name
    $"Hello, ${name}!"
    else "Hello!"))
[(greeting {^name "Ada"}) (greeting {})]
# ["Hello, Ada!" "Hello!"]
```

The value is evaluated once. Presence is the test, so `false`, `0`, and `""`
take the arm. To leave a function early when a value is missing, bind it with
`??` instead, as in `(let task (?? (find_task id) (return nil)))`.

## match

`match` evaluates a value once and compares it with each `when` arm in order.
Each `when` takes one pattern followed by one or more expressions, and a
final `else` handles the rest:

```gene runnable
(fn number_label [x : Int] : Str
  (match x
    when 1 "one"
    when 2 "two"
    else "other"))
[(number_label 2) (number_label 9)]
# ["two" "other"]
```

Prefer `match` to a chain of `==` tests on the same value.

> **Watch out:** `match` needs a final `else` or an arm that always matches,
> such as `when _ …`. Without one, it fails to compile with
> `match is not exhaustive; add else, a binding arm, or ^!exhaustive`.

To leave a `match` partial on purpose, write `^!exhaustive` before the value.
An unmatched value then raises `MatchFault: no matching pattern`:

```gene
(match value ^!exhaustive
  when 1 "one"
  when 2 "two")
```

## Patterns

A pattern matches a shape and binds names to its parts.

- A literal matches an equal value.
- A name matches anything and binds it, and `_` matches anything without
  binding.
- A list pattern matches a List item by item, and a final `rest...` collects
  the items left over.

```gene runnable
(fn describe [values] : Str
  (match values
    when [] "empty"
    when [only] $"one: ${only}"
    when [first rest...] $"first=${first}, then $($size rest) more"
    else "not a list"))
[(describe []) (describe [7]) (describe [10 20 30])]
# ["empty" "one: 7" "first=10, then 2 more"]
```

Property maps, typed values, and nodes match by their fields. `%name`
compares with the value of an existing binding instead of binding a new
name:

```gene runnable
(type Point ^props {^x Int ^y Int})
(let origin_x 0)
(fn place [p] : Str
  (match p
    when (Point ^x %origin_x ^y y) $"on the y axis at ${y}"
    when (Point ^x x) $"at x=${x}"
    when {^name name} $"named ${name}"
    else "unknown"))
[(place (Point ^x 0 ^y 4)) (place (Point ^x 3 ^y 1)) (place {^name "Ada"})]
# ["on the y axis at 4" "at x=3" "named Ada"]
```

A field a pattern names must be there: a missing optional field does not
match by binding `nil`. The same patterns destructure in `let`:

```gene runnable
(let [first second] [1 2])
[second first]
# [2 1]
```

## Loops

`for` runs its body once for each item of a List or a Stream. `while` runs
while its condition holds, and `loop` runs until a `break`. `continue`
skips to the next pass:

```gene runnable
(var total 0)
(for n in [1 2 3 4]
  (if (== n 2) (continue))
  (set total (+ total n)))
(while (< total 10) (set total (+ total 1)))
(var steps 0)
(loop
  (set steps (+ steps 1))
  (if (== steps 3) (break)))
[total steps]
# [10 3]
```

`(repeat n …)` runs its body `n` times, and `(repeat i in n …)` also binds an
index from `0` to `n - 1`:

```gene runnable
(var squares [])
(repeat i in 4 (squares .push (* i i)))
squares
# [0 1 4 9]
```

A loop's variable belongs to the loop. It shadows an outer binding of the
same name only inside the loop, and a later loop may use the name again.
A loop is a statement, so its value is `nil`. To build a result, collect it
in a binding as above, or transform the collection instead
([Collections and streams](collections.md)).

> **Watch out:** `break` carries no value. `(break 5)` fails with
> `break expects no arguments`; assign the value to a binding before the
> `break`.

> **Watch out:** `for` reads list-like values. `(for x in {^a 1} …)` fails
> with `for cannot iterate a Map; use (map_for [key value] in …)`
> ([Collections and streams](collections.md)).
