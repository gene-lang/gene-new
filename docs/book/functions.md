# Functions

This chapter defines functions, annotates them, passes optional, named, and
rest arguments, and describes functions as values.

## Defining functions

`fn` defines a function: a name, a parameter list in brackets, and a body.
The body's last expression is the result. Without a name, `fn` makes an
anonymous function, which is an ordinary value:

```gene runnable
(fn square [n] (* n n))
(let add_one (fn [n] (+ n 1)))
[(square 5) (add_one 5) ((fn [x] (* x 10)) 4)]
# [25 6 40]
```

Functions can be passed to other functions and returned from them:

```gene runnable
($map [1 2 3] (fn [n] (* n 2)))
# [2 4 6]
```

## Type annotations

`: T` after a parameter checks the argument, and `: T` after the parameter
list checks the result. Annotations are optional, and a function can have
some and not others:

```gene runnable
(fn square [n : Int] : Int (* n n))
(square 7)
# 49
```

A value that does not fit raises a `TypeFault` when it crosses the
annotation: `(square "x")` fails with `parameter 'n' expected Int, got Str`,
and a wrong result fails with `return from 'square' expected Int, got Str`.

Common type expressions are `Int`, `F64`, `Str`, `Bool`, `(List Int)`,
`(Map Str Int)`, `(| Int Str)` for "either", and `Int?` for "an Int or
`nil`". `Any` accepts every value. Types have a chapter of their own
([Types, messages, and protocols](types.md)).

## Optional arguments

A parameter may be left out only when it declares a default with `=`. The
default is computed at each call and may use earlier parameters:

```gene runnable
(fn span [start = 0 width = (+ start 10)] [start width])
[(span) (span 5) (span 5 1)]
# [[0 10] [5 15] [5 1]]
```

A supplied `nil` is an argument, so it does not select the default:

```gene runnable
(fn age [value : Int? = 18] : Int? value)
[(age) (age nil) (age 25)]
# [18 nil 25]
```

> **Watch out:** `T?` says which values a parameter accepts, not whether it
> may be left out. `(fn a [x : Int?] x)` must still be called with an
> argument; `(a)` fails with `function 'a' expects 1..1 argument(s), got 0`.
> Write `[x : Int? = nil]` for a parameter callers may omit.

Optional positional parameters come after the required ones and cannot come
before a rest parameter.

## Named arguments

A parameter written with `^` is passed by name, at the declaration and at the
call:

```gene runnable
(fn greet [name : Str ^ending : Str = "!"] : Str
  $"Hello, ${name}${ending}")
[(greet "Ada") (greet "Ada" ^ending "?")]
# ["Hello, Ada!" "Hello, Ada?"]
```

- Named arguments can come anywhere in the call.
- A named parameter without a default must be passed:
  `function 'greet' missing named argument: ending`.
- A name after the named parameter gives it a different local name:
  `[^from start]` is passed as `^from` and read as `start`.

> **Watch out:** that local-name rule means a comma matters in a parameter
> list. `[^from start]` is one named parameter, while `[^from, start]` is a
> named `from` followed by a positional `start`.

## Rest arguments and spread

A parameter ending in `...` collects the remaining positional arguments as a
List. At a call, `values...` spreads a List into positional arguments:

```gene runnable
(fn total [values... : Int] : Int
  (var result 0)
  (for n in values (set result (+ result n)))
  result)
(let more [3 4])
[(total 1 2) (total more...)]
# [3 7]
```

A named rest parameter, `^attrs...`, collects the named arguments that match
no other named parameter, as a property map. Spreading a map at a call
passes its entries as named arguments:

```gene runnable
(fn tag [^attrs... body...] [attrs body])
(let defaults {^class "card"})
[(tag ^id "main" "hello") (tag defaults...)]
# [[{^id "main"} ["hello"]] [{^class "card"} []]]
```

A later named value replaces an earlier one with the same name, including one
from a spread. A function without a named rest rejects named arguments it
does not declare.

## Closures

A function made inside another keeps the bindings it uses, even after the
outer function returns:

```gene runnable
(fn make_counter []
  (var n 0)
  (fn [] (set n (+ n 1)) n))
(let next (make_counter))
(next)
(next)
(next)
# 3
```

## Early return

`return` leaves the function at once with a value:

```gene runnable
(fn first_negative [xs]
  (for x in xs
    (if (< x 0) (return x)))
  nil)
(first_negative [3 -1 -2])
# -1
```

A function whose result type is `Nil` returns `nil` whatever its last form
gives. It ends early with `(return)`, and `(return 5)` in it fails to
compile with `return in a Nil function takes no value`.

## Wrapping with #@

`#@` reads the next two forms as a call of the first on the second, so
`#@f x` is `(f x)`. It is handy for wrapping an existing expression without
moving its parentheses:

```text
#@$println x     →  ($println x)
#@f #@g x        →  (f (g x))
[1 #@f x 3]      →  [1 (f x) 3]
```

`#@` always takes exactly two forms: `#@f x y` leaves `y` outside the call.
It is also how a function wraps another at its definition, as in
`(let cached #@memoize (fn [n] …))`.

## Documenting a function

`@doc` attaches a description to a function, and `$runtime/signature`
describes a function without calling it, its `@doc` included:

```gene runnable
(fn greet [name : Str ^ending : Str = "!"] : Str
  @doc "Greet someone by name."
  $"Hello, ${name}${ending}")
(let signature ($runtime/signature greet))
[signature/name signature/doc signature/result]
# ["greet" "Greet someone by name." Str]
```

The library reference is built from these descriptions.
