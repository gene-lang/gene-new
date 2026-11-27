# Code as data

This chapter treats code as values: quoting it, building it with templates,
generating it with macros, receiving it with fexprs, and running it with
`eval`.

## Quoting

Gene code is made of nodes, the same values a program uses as data. `quote`
returns a form as a node instead of running it:

```gene runnable
(let form (quote (+ 1 2)))
[form ($head form) ($body form)]
# [(+ 1 2) + [1 2]]
```

A quoted form can be inspected and changed like any node
([Nodes as data](collections.md#nodes-as-data)).

> **Watch out:** a quoted literal is one value, shared by every run of the
> code that holds it. A function that pushes onto `(quote (do))` adds to the
> same node on each call, so the second call returns `(do 1 2)`. Build a fresh
> node with a template instead.

## Templates

A backquote starts a template: a quoted form with holes. `%x` fills a hole
with the value of `x`, and `%xs...` splices the items of a List in place:

```gene runnable
(let x 5)
(let forms [(quote (a)) (quote (b))])
[`(+ %x 1) `(do %forms...)]
# [(+ 5 1) (do (a) (b))]
```

A template builds a new node each time it runs, so the shared-literal
problem above does not arise.

> **Watch out:** `%(…)` is a call. `` `(do %(env/code)...) `` calls
> `env/code` and fails with `value is List, which is not callable`. A path
> splices without parentheses: `` `(do %env/code...) ``. A splice takes a
> name: `%(mk)...` with a callable `mk` puts the whole list in and leaves
> `...` as a literal symbol, so bind the value and write `%v...`.

## Macros

A macro receives its arguments as unevaluated syntax, runs ordinary Gene code
at compile time, and returns the code that replaces the call:

```gene runnable
(macro unless [condition body...]
  `(if_not %condition %body...))
(var value 0)
(unless false (set value 1))
value
# 1
```

The macro's body is ordinary Gene, so a template is only one way to produce
the result. This macro computes a number during expansion:

```gene runnable
(macro add_one [x] (+ x 1))
(add_one 2)
# 3
```

- Names in the macro's body resolve where the macro is defined.
- Names in the code it returns resolve where the macro is called.
- A macro defined at module level expands when the module compiles.
- A macro defined inside a function expands each time its call runs, and can
  read that function's locals:

```gene runnable
(fn f [n]
  (macro m [] (+ n 1))
  (m))
[(f 2) (f 9)]
# [3 10]
```

A local macro compiles its expansion on every call, so prefer a module-level
macro on a hot path.

## Computed paths

A path expression is data as well as a read. `data/a` is read as
`(path data a)`, and the quoted form shows it:

```gene runnable
(quote data/a)
# (path data a)
```

Segments are literal: `(path data a)` reads the key `a`. Prefix a segment
with `%` to evaluate it instead, which is how a segment can come from a
variable:

```gene runnable
(let data {^a 1})
(let k "a")
[(path data a) (path data %k)]
# [1 1]
```

Both forms are ordinary code; a macro uses the same shape when it has to
insert a computed segment into code it generates.

## Bindings inside an expansion

Bindings that an expansion makes stay inside it. The caller's names are
unchanged afterwards:

```gene runnable
(macro with_value [name value body...]
  `(do (let %name %value) %body...))
(let answer 100)
[(with_value answer 21 (* answer 2)) answer]
# [42 100]
```

Names are not renamed automatically, so a template's own binding can capture
a name the caller passes in. When a template binds a name around caller
code, make the name with `$gensym`. It returns a symbol no caller code is
using, and it works only while a macro body runs:

```gene runnable
(macro swap [a b]
  (let tmp ($gensym "tmp"))
  `(do (var %tmp %a) (set %a %b) (set %b %tmp)))
(var tmp 1)
(var y 2)
(swap tmp y)
[tmp y]
# [2 1]
```

> **Why:** macro bodies are ordinary code, and expansions follow ordinary
> scoping. There is no separate macro language and no hidden renaming to learn,
> and `$gensym` is there for the one case that needs a fresh name.

## Fexprs

A function whose name ends in `!` is an fexpr. It receives its arguments as
syntax at run time and decides what to evaluate. `caller_env` is the
caller's environment, for evaluating chosen syntax there:

```gene runnable
(fn twice! [form]
  (* 2 (eval form ^in caller_env)))
(let x 21)
[(twice! x) (twice! (+ x 1))]
# [42 44]
```

An fexpr's evaluation works on a copy of the caller's bindings. A `set` it
evaluates does not change the caller's variable, and it cannot `return`,
`break`, or `continue` on the caller's behalf. Mutable values, such as a
Cell, are shared as usual.

## eval

`eval` compiles and runs a syntax value in an environment given with `^in`.
`(env ^bindings {…})` makes one with extra names:

```gene runnable
(let e (env ^bindings {^value 20}))
(eval (quote (+ value 2)) ^in e)
# 22
```

`^in` is required: `(eval form)` fails with `eval requires ^in Env`.

> **Watch out:** an Env is not a sandbox. Evaluated code can use any
> namespace the surrounding code can, including `$fs` and `$os`. To run
> untrusted code, use the sandbox loader, which grants a module only the
> namespaces it names.

## Which one to use

| Tool | Receives | Runs | Use it for |
| --- | --- | --- | --- |
| function | evaluated values | at run time | ordinary computation |
| macro | syntax | its body at compile time, then the code it returns | new syntax and control-flow wrappers |
| fexpr | syntax | at run time | deliberate interpretation of the syntax it gets |

Prefer a function. Reach for a macro when the caller's code must be wrapped
or rearranged, and for an fexpr only when the syntax itself is the input.
