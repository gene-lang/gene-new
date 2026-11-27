# Values and expressions

This chapter covers Gene's basic values (numbers, text, symbols, booleans,
and `nil`) and the expressions that combine them.

## Expressions

An expression in parentheses is a call: the first item names the operation,
and the rest are its arguments. Arithmetic is written the same way, operator
first, and one call can take more than two arguments:

```gene runnable
[(+ 1 2 3) (* 6 7) (- 10 4) (< 1 2 3)]
# [6 42 6 true]
```

Whitespace separates items, and a comma may be used as a separator too:
`[1, 2, 3]` is `[1 2 3]`. `#` starts a comment to the end of the line, and
it needs a space after it. `#< … >#` is a block comment, and `#_` skips the
next form:

```gene runnable
#_ (this form is skipped)
(+ 1 #< a block comment ># 2)  # a line comment
# 3
```

## Numbers

An Int has arbitrary precision, and a number with a decimal point or an
exponent is an F64. On Ints, `/` truncates toward zero, and `//` is the
remainder, which takes the sign of the dividend:

```gene runnable
[(/ 7 2) (// 7 2) (/ -7 2) (// -7 2) (/ 7.0 2) 1e3]
# [3 1 -3 -1 3.5 1000.0]
```

> **Watch out:** `//` is the remainder, not floor division as in Python.
> `(// -7 3)` is `-1`. For a result that is never negative when the divisor
> is positive, adjust it:

```gene runnable
(fn wrap [a : Int b : Int] : Int
  (let r (// a b))
  (if (< r 0) (+ r b) else r))
(wrap -7 3)
# 2
```

Ints do not overflow:

```gene runnable
(* 99999999999 99999999999 99999999999)
# 999999999970000000000299999999999
```

- When one operand is an F64, the other is converted, so `(+ 1 2.5)` is
  `3.5`. The web profile requires both operands to have the same type.
- `($to_float 2)` is `2.0`, and `($to_int 3.7)` truncates to `3`.
- Dividing by zero, Int or F64, raises `division by zero`.

## Text

A string is written in double quotes. An interpolated string starts with
`$`. `${name}` inserts a value, and `$(…)` inserts the result of a call:

```gene runnable
(let name "Ada")
(let visits 2)
$"Hello, ${name}; visit $(+ visits 1)"
# "Hello, Ada; visit 3"
```

Interpolation is the usual way to build a string. It reads as an ordinary
call to `$to_str`, which joins its arguments with no separator:
`$"a${b}c"` is `($to_str "a" b "c")`.

Strings answer messages for common operations: `split`, `trim`, `lower`,
`upper`, `contains?`, `starts_with?`, `ends_with?`, and `empty?`:

```gene runnable
(let names ("Ada,Grace" .split ","))
[(names .get 1) (names .join " & ") (" ok " .trim) ("Ada" .lower)]
# ["Grace" "Ada & Grace" "ok" "ada"]
```

A string's length depends on the unit, so there is no plain `size`.
`byte_size` counts UTF-8 bytes, `$chars` splits into code points, and
`$graphemes` splits into user-perceived characters:

```gene runnable
(let word "héllo")
[word/.byte_size ($size ($chars word))]
# [6 5]
```

> **Watch out:** `("abc" .size)` fails with `no message 'size' on Str`.
> Choose the unit: `byte_size`, `$chars`, or `$graphemes`.

> **Watch out:** a string literal inside `${…}` ends the interpolation early.
> `$"n: ${($str/join xs ",")}"` is a read error,
> `unterminated interpolation '{...'`. Bind the literal to a name first, or
> use a triple-quoted string, which allows it:
> `$"""n: ${($str/join xs ", ")}"""`.

## Symbols and characters

A symbol (`Sym`) is a name used as a value. `(quote ready)` makes one, and
`$to_sym` and `$to_str` convert between symbols and strings. A character
(`Char`) is written in single quotes, such as `'a'` or `'\n'`:

```gene runnable
[(quote ready) ($to_sym "ready") ($to_str (quote ready)) 'a']
# [ready ready "ready" 'a']
```

> **Watch out:** a symbol never equals a string: `(== (quote a) "a")` is
> `false`. Iterating over a Map gives its keys as symbols, so convert with
> `$to_str` before comparing a key with a string.

## Booleans and truthiness

The booleans are `true` and `false`. Only `false` and `nil` count as false
in a condition. Every other value counts as true, including `""`, `0`, and
`[]`:

```gene runnable
[(if "" "yes" else "no") (if 0 "yes" else "no") (if nil "yes" else "no")]
# ["yes" "yes" "no"]
```

`!` negates. `&&` and `||` stop at the first operand that decides the result
and return that operand:

```gene runnable
[(! nil) (&& true 1) (&& nil 1) (|| nil 2)]
# [true 1 nil 2]
```

> **Watch out:** there is no `and` or `or`. `(and true false)` fails with
> `undefined symbol: and`; write `&&` and `||`.

> **Watch out:** an emptiness test carried over from Python or JavaScript
> never fires, because `""` and `[]` count as true. Test explicitly:
> `(== s "")`, `s/.empty?`, or `xs/.empty?`.

## Absence

`nil` is the one value that means "nothing here". These all give `nil`:

- a missing key;
- an omitted optional field;
- an index past the end;
- a path step through `nil`;
- a function whose last form is a statement;
- a binding declared without a value.

`(?? value fallback)` gives the fallback only when the value is `nil`, so
`false` stays `false`. Prefer `($present? x)` to `(! ($absent? x))` when a
branch tests presence; `$present?` and `$absent?` test for `nil`:

```gene runnable
(let person {^name "Ada"})
[person/nickname
 (?? person/nickname "anonymous")
 (?? false "fallback")
 ($present? false)
 ($absent? nil)]
# [nil "anonymous" false true true]
```

Presence is not truthiness: `false`, `0`, `""`, and empty collections are
all present. In a type, `T?` means "a `T` or `nil`", and `Present` is every
value except `nil`.

> **Why:** with a single absence value, there is one test for "nothing
> here", and `??`, `$present?`, and `T?` cover every case. A mistake is
> kept apart from absence: a misspelled field raises instead of reading
> `nil` ([Missing and wrong reads](names.md#missing-and-wrong-reads)).

## Other literals

The reader also gives bytes, regular expressions, dates, times, and date-times
their own literal forms:

```gene runnable
[#B16#4869 #"[a-z]+"i 2026-07-04 09:30:15.123456
 2026-07-04T09:30:15-04:00[America/New_York]]
# [#B16#4869 #"[a-z]+"i 2026-07-04 09:30:15.123456 2026-07-04T09:30:15-04:00[America/New_York]]
```

A regex carries its flags after the closing quote (`i` is case-insensitive);
`.match` returns a Match (its `text`, `groups`, `start`, and `end`) or `nil`.
A date-time may name an IANA zone in brackets. The `$regex` namespace holds
`find_all`, `match`, `replace`, `replace_all`, and `split`.

## Collection literals

| Literal | Value |
| --- | --- |
| `[1 2 3]` | a List |
| `{^name "Ada" ^active true}` | a property map, with named keys |
| `{{"red" : 1 "blue" : 2}}` | a general Map, with keys of any type |
| `#[1 2 3]`, `#{^name "Ada"}` | immutable versions of the two above |
| `(quote (task ^!done "Write docs"))` | a node, kept as data |

In a property map or a node, `^^active` is short for `^active true`, and
`^!active` for `^active false`:

```gene runnable
(let xs [1 2 3])
(xs .push 4)
[xs {^^active ^!archived} #[1 2]]
# [[1 2 3 4] {^^active ^!archived} #[1 2]]
```

`let` fixes the binding, not the value, so the List bound to `xs` can still
grow. An immutable literal cannot: `(#[1 2] .push 3)` fails with
`cannot mutate immutable List`. Collections have a chapter of their own
([Collections and streams](collections.md)).

## Equality

`==` compares structure, and `same?` compares identity. Metadata does not
take part in `==`:

```gene runnable
(let a [1 2])
[(== a [1 2]) (same? a [1 2]) (same? a a) (== 1 1.0)]
# [true false true false]
```

`==` never converts between types, so the Int `1` and the F64 `1.0` differ,
and so do a symbol and a string.

## Printing

`$println` prints its arguments separated by spaces and ends the line.
`$print` does not end the line, and `$eprintln` writes to standard error. All
three return `nil`:

```gene runnable
($println "total:" (+ 2 3))
```

This prints `total: 5`.
