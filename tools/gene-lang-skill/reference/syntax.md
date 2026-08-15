# Syntax and values

Normative contract: `docs/spec/reader.md`. Everything below is probed.

## The node

One syntactic and semantic unit. Four slots:

```text
head   singular identity / dispatch face
props  named side data, keyed by symbol   (^key value)
body   ordered positional data
meta   information about the node, ignored by value semantics   (@key value)
```

```gene
(var n (quote (foo @src "x" @@gen ^k 1 2 3)))
($head n)    # foo
($props n)   # {^k 1}
($body n)    # [2 3]
($meta n)    # {^src "x" ^^gen}
```

`^^flag` and `@@flag` are sugar for a `true` value. Ordinary `^prop` and `@meta`
require a value. Structural equality and hash ignore meta.

**In code position a node is a call.** `(foo ^k 1)` evaluates `foo` and calls it.
Reach for `quote` or quasiquote when you want the data:

```gene
(quote (foo ^k 1 2))
`(foo ^k 1 %computed)
```

## Scalars

```gene
nil  void  true  false
42  -7  3.5
"text"
$"hello ${name} ${(+ 1 2)}"      # interpolation
"""line one
line two"""                       # multiline
'λ'                               # Char
#B16#4869                         # bytes, base 16
#"[a-z]+"im                       # regex
2026-07-04                        # Date
09:30:15.123456                   # Time
2026-07-04T09:30:15-04:00[America/New_York]
```

`nil` and `void` are distinct. `void` means absent — an unset prop-schema field
reads as `void`, while an omitted named parameter binds `nil`. `$absent?` covers
both; `$nil?` and `$void?` separate them.

Prefer interpolation over the `$` concat head: write `$"a${x}b"`, not
`($ "a" x "b")`.

## Collections

Mutable and shallow-immutable literals are semantically distinct:

```gene
[1 2 3]        #[1 2 3]        # List
{^name "Ada"}  #{^name "Ada"}  # Map, symbol-keyed
{{"k" : 1}}                     # Map, general keys
```

`{^a 1}` keys by symbol and reads back with a path: `m/a`. `{{"k" : 1}}` takes
arbitrary keys and reads through `(m ~ get "k")`.

`freeze` is deep, `freeze_shallow` is shallow, `thaw` is deep. `assoc` returns a
new root; `set`/`push`/`put` mutate a mutable container in place.

## Paths and selectors

A glued path navigates. A glued *leading* slash is a selector literal — a
first-class navigation value.

```gene
session/user/name        # navigate
xs/0                     # index
xs/-1                    # from the end
xs/~size                 # zero-argument send (see SKILL.md)
(path m a b)             # same navigation, computed form
```

```gene
(var s /a/b)             # selector literal
(s {^a {^b 7}})          # 7 — apply it
({^a {^b 7}} ~ /a/b)     # 7 — send it
({^a {^b 7}} ~ (select a %field))   # computed segment
```

A delimited `/` — whitespace on both sides — is an ordinary symbol, which is how
division is spelled: `(/ 10 2)`.

A missing key reads as `void`, so supply defaults with `??`:

```gene
(var m {^a 1})
m/b              # void
(?? m/b "dflt")  # "dflt"
```

Strict selector lookup instead raises `SelectorMissing` carrying `^segment`.

`$assoc_in` and `$update_in` navigate with a selector too:

```gene
($assoc_in {^a {^b 1}} /a/b 9)              # {^a {^b 9}}
($update_in {^a 1} /a (fn [v] (+ v 1)))     # {^a 2}
```

Static scalar and key segments are pure. Callable, call-stage, and send segments
are executable — non-serializable, and rejected by `assoc_in`/`update_in`.

## Spread and destructuring

```gene
(var xs [2 3])
[1 xs... 4]                       # [1 2 3 4]

(fn f [a, rest...] [a rest])      # variadic parameter

(var [a, b] pair)                 # positional destructuring
(var {^x x} record)               # prop destructuring
(for [k v] in {^a 1 ^b 2} …)      # map iteration yields pairs
```

Commas are separators in parameter, binding, and pattern vectors — use them
consistently there and nowhere else.

## Comments

```gene
# line comment — the # needs whitespace, ! or end of line after it
#< block #< nested ># comment >#
#_ (this datum is discarded)
```

`#` dispatch is closed: `#(` `#[` `#{` `#"` `#_` `#<` and the line comment are
the whole set. Every other `#` sequence is a read error reserved for future
syntax.

The reader drops comments *inside* a parsed form, so `gene fmt` preserves any
form containing an interior comment verbatim rather than reprinting it.
