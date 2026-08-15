# Pitfalls

Almost every entry below came from probing a plausible-looking guess and
watching it fail. Read it as: what the Lisp/Python/Ruby prior suggests, and
what Gene actually wants.

## Error message → fix

| Message | Cause | Fix |
|---|---|---|
| `undefined symbol: println` | Bare stdlib name | `($println …)` — `$x` is sugar for `gene/x` |
| `undefined symbol: foo` on a node | `(foo ^k 1)` in code position is a call | `(quote (foo ^k 1))` or `` `(foo ^k 1) `` |
| `undefined symbol: ~` | Chained sends without continuation | Start each continuation line with `; ~` |
| `undefined symbol: 0..3` | No range literal | `($range 0 3)` |
| `undefined symbol: Any` | `Any`/`Never` resolve in annotations only | Use them in `: Any` position, never as values |
| `undefined symbol: this_pkg` | Module bindings absent in `gene eval` | Probe in a file with `gene run` |
| `undefined symbol: S/a` in a parameter list | Qualified path as a default value | Bind it above the function first |
| `Read error: unterminated interpolation '{...'` | String literal inside `${…}` | Bind it out, or use `$"""…"""` |
| `map expects a Stream` | `map`/`filter`/`take`/`into` are stream ops | `(xs ~ to_stream)` first, `~ into []` last |
| `size expects a collection` | `$size` rejects strings | `($str/byte_size s)` or `($size ($chars s))` |
| `no message 'size' on Str` | `Str` carries no messages | `$str/*` functions |
| `no message 'foo' on T` | Sends dispatch only — no lexical fallback | Declare a `(message …)` in the type, or call the function directly |
| `value is not callable: vkVoid` | Missing key read as `void`, then called | Check the path; supply `(?? m/k default)` |
| `import source must be a namespace path or 'from "path"'` | Wrong import order | `(import [names] from "./path")` or `(import $str [names])` |
| `break expects no arguments` | Carrying a value out of a loop | Assign to a binding before `(break)` |
| `channel expects no positional arguments` | Capacity is named | `($channel ^capacity 2)` |
| `actor/spawn expects no positional arguments` | Actor config is named | `($actor/spawn ^init … ^handle …)` |
| `type field 'a?' may not end in '?'` | Optionality spelled on the key | `^a T?` — it lives on the type |
| `missing required field 'a' for T` | Non-nil-admitting field omitted | Supply it, or widen the type to `Int?` |
| `MissingCapability: fs/read_text requires fs/ReadFile` | No host grant | `gene run --allow_read_dir DIR …` |
| `Env/snapshot expects a CallerEnv and a binding-name list` | Bare `snapshot` | `(caller_env ~ snapshot ["x"])` |
| `message send expected Protocol, got vkType` | Qualified a type-direct message as `T:msg` | Send it bare; only protocols qualify |
| `List/push expects 2 arguments, got 1` | Wrote `(xs/~push v)` | `(xs ~ push v)` — the path shortcut takes no arguments |

## Only `nil`, `false`, and `void` are falsy

`""`, `0`, and `[]` are all **truthy**. A guard carried over from Python, JS, or
Ruby silently never fires:

```gene
(if_yes (== (trim title) "") (fail …))   # right
(if_not (trim title) (fail …))            # wrong — "" is truthy, never fails
```

Test emptiness explicitly: `(== s "")`, `xs/~empty?`, `($nil? v)`, `($absent? v)`.

## A string literal inside `${…}` is a read error

In a single-quoted interpolated string, a nested `"` terminates the
interpolation early:

```gene
$"n: ${($str/join xs ",")}"     # Read error: unterminated interpolation '{...'
$"a: $(f "x")"                  # same, in the paren form
```

Bind the literal first, or switch to a triple-quoted interpolated string, which
handles it:

```gene
(var sep ", ")
$"n: ${($str/join xs sep)}"
$"""n: ${($str/join xs ", ")}"""
```

## A qualified path cannot be a default parameter value

Bare symbols and calls work as defaults; a path does not resolve there.

```gene
(fn f [^s = k] …)          # fine
(fn f [^s = (g)] …)        # fine
(fn f [^s = S/a] …)        # Error: undefined symbol: S/a
```

Bind it above the function, or default to `nil` and fill in the body:

```gene
(var s_default S/a)
(fn f [^s : Status = s_default] …)

(fn f [^s : Status? = nil] (var status (?? s S/a)) …)
```

## Shapes that read right and are wrong

**`(a/~b c)` is not `(a ~ b c)`.** It parses as `((a ~ b) c)` — a zero-argument
send whose *result* is called. The path shortcut carries no arguments:

```gene
(buf ~ set i v)      # right
(buf/~set i v)       # wrong — sends `set` with no arguments, then calls the result
```

**`//` is remainder, not floor division.** `(/ 7 2)` is `3`; `(// 7 2)` is `1`.

**The `/~message` shortcut needs a symbol base.** On a literal it silently reads
as two values — a collection and a selector — with no error at all:

```gene
(var xs [1 2])
xs/~size        # 2
[1 2]/~size     # [1 2] (select ~size)  — two data values, not a send
([1 2] ~ size)  # 2
```

**`#(…)` is an immutable literal, not a quote.** In code position its head still
evaluates. Quote for data.

**A quoted literal is shared across calls — mutating it accumulates.** This
returns `(do (var x 1))` the first call and `(do (var x 1) (+ 5 5))` the second:

```gene
(fn build [forms]
  (var b (quote (do)))          # same node every call
  (for f in forms (b ~ push_body f))
  b)
```

Build a fresh node with quasiquote instead: `` `(do %forms...) ``.

**A splice needs a bare symbol.** `` `(do %forms...) `` works;
`` `(do %(envelope/code)...) `` fails with `value is not callable: vkList`.
Bind the expression first.

**`elif` is a clause, not an else-position form.** Once you use `elif`, every
branch must be a clause — a compact `if` cannot take one as its third argument:

```gene
(if a (then x) (elif b y) (else z))   # right
(if a x (elif b y))                    # Error: undefined symbol: elif
```

**A missing map key is `void`, not an error.** `m/b` on `{^a 1}` yields `void`,
which then fails at the point of *use* rather than the point of the typo. When a
value surprises you, print it before chasing the call that consumed it.

**`match` without `else` is not a nil default** — unlike `if`, it needs the arm.
Writing `(else nil)` there is idiomatic.

**`nil` and `void` are different.** An unset prop-schema field reads `void`; an
omitted named parameter binds `nil`. `$absent?` covers both.

**Direct construction never runs `ctor`.** `(T ^n 5)` fills the schema;
`(new T 5)` runs the constructor. Neither is a fallback for the other.

## Style contract

`docs/style.md` is enforced by `gene fmt` for layout and by review for the rest.
The transformations `fmt` will *not* make for you:

- Replacing `(if cond (do …))` with `if_yes`, or `(if cond nil …)` with `if_not`.
- Introducing `elif` instead of a nested `else (if …)`.
- Dropping an explicit trailing `nil` arm from a one-sided `if`.
- Choosing `receiver/~message` over `(receiver ~ message)` for a bare send.

So write those correctly the first time; `fmt` then makes the layout canonical.
Run it on anything you produce — a clean `gene fmt` is also a parse check.

Two places where `fmt` currently fights the style guide rather than serving it,
so review its output before adopting it wholesale:

- A **triple-quoted interpolated** string `$"""…${x}…"""` is collapsed to a
  single-quoted one, and when the content has newlines it is desugared into the
  `($ …)` concat head — the opposite of this project's preference for
  interpolation. Behavior is preserved (embedded quotes get escaped); only
  readability suffers.
- A **nested map inside a list** gets its entries aligned far to the right,
  which `docs/style.md` itself rules out ("do not vertically align arguments
  with arbitrary spaces").
