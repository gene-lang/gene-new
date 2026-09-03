# Declarations

Normative contract: `docs/spec/types.md`, `docs/spec/protocols.md`,
`docs/spec/modules.md`, `docs/spec/calls.md`. Everything below is probed.

## Bindings

```gene
(var x 1)          # mutable binding
(const K 5)        # constant
(set x 2)          # assignment
```

## Functions

Name, parameter vector, optional return type, and short metadata stay on the
opening line. Every body expression indents two spaces.

```gene
(fn normalize [name : Str] : Str
  ($str/trim name))

(fn make [name : Str, ^roles : (List Str) = [], ^active : Bool = true] : User
  (User ^name name ^roles roles ^active active))

(fn append_all [target, values...]
  (for value in values
    (target .push value))
  target)
```

Positional parameters are optional only via defaults. A named parameter is
optional when its type admits nil (`T?`, `(? T)`, a union containing `Nil`); an
omitted one binds `nil`. Call sites reject unknown props.

Declaring a name ending in `?` is a compile error — optionality lives on the
type, not the key.

## Fexprs

A **bare lexical head ending in `!`** is the fexpr call form. It preserves its
arguments as syntax and receives a borrowed `CallerEnv`.

```gene
(fn peek! [form]
  ($to_str form))

(var x 1)
(peek! (+ x 2))     # "(+ x 2)"
```

Only a bare head invokes one — aliases, expression heads, and higher-order
calls cannot. The `CallerEnv` is borrowed, so durable caller authority needs an
explicit named snapshot: `(caller_env .snapshot ["x"])`.

## Macros

Compile-time, template-shaped, using quasiquote and unquote sugar:

```gene
(macro unless [condition, body...]
  `(if_not %condition %body...))
```

## Types

```gene
(type User @doc "a small record"
  ^props {^name Str ^roles (List Str) ^active Bool?})

(type Admin : User ^props {^level Int})     # single nominal inheritance
```

**`(T …)` constructs directly and never runs `ctor`. `(new T …)` runs the
nearest `ctor` in `T`'s ancestry** and fails when none is defined.

```gene
(type Point ^props {^n Int}
  (ctor [n] (set self/n n)))

(Point ^n 5)      # direct — closed-schema construction
(new Point 5)     # runs ctor
```

Until ctor validation succeeds, `self` carries an in-progress marker: it cannot
be stored globally, captured by an escaping closure, spawned, sent, or used as
an error payload.

Type-direct messages live in the type body and are sent bare:

```gene
(type User ^props {^name Str}
  (message shout [self] : Str $"${self/name}!"))

(u .shout)
```

## Enums

```gene
(enum Status pending active (failed Str))

(match status
  (when Status/pending "pending")
  (when (Status/failed message) $"failed: ${message}")
  (else nil))
```

## Protocols and impls

An explicit `impl` establishes conformance; defaults fill omitted messages only
once an impl exists. Universal conformance is never implicit.

```gene
(protocol Labelled
  (message label [] : Str))

(impl Labelled for User
  (message label [self] : Str
    (if self/active
      self/name
      $"${self/name} (inactive)")))

(u .Labelled:label)
```

A protocol send is always qualified `P:msg`. `T:msg` on a *type* is a
`CallKindError` — type-direct messages go bare, and use the reserved `Self:msg`
spelling only where a message value is required.

An impl covers the full inherited message closure. Zero applicable visible impls
is missing behavior; two is ambiguity — import order never picks a winner.

## Errors

An error type implements `Error`, and a function declares what it may raise:

```gene
(type ExampleError ^props {^message Str} ^impl [Error])
(impl Error for ExampleError)

(fn checked [value] ^errors [ExampleError]
  (if_not value (fail (ExampleError ^message "value is required")))
  value)
```

## Namespaces and modules

```gene
(mod my_module @doc "what this module is")

(ns fixtures
  (var default_name "Ada")
  (fn default_roles [] : (List Str) ["reader" "writer"]))

fixtures/default_name
```

Two import forms, and the source comes first in only one of them:

```gene
(import $str [join, trim])                  # from a namespace
(import [double, factor] from "./util")     # from a file, relative to this module
(import [double : dbl] from "./util")       # `:` aliases
```

`this_mod` and `this_pkg` are implicit lexical bindings for the current module
and its package — available in a module, not in `gene eval`.

## Entry point

`gene run` executes top level, then calls `main`. Positional arguments arrive as
one node.

```gene
(fn main [args]
  ($println args/0)
  nil)
```

`main` returns `Nil` for exit 0 or an in-range `Int` exit code. Any other value
is a boundary error.

## Capabilities

Host authority is explicit. An ungranted `$fs` call fails with
`MissingCapability` rather than reading anything:

```console
$ ./bin/gene run --allow_read_dir /etc app.gene
```

The pre-entry grant options are `--allow_read_dir`, `--allow_write_dir`, and
`--allow_read_write_dir`. `with_capabilities` narrows the active set inside a
block, and `$check_capabilities` asserts one is held. `examples/capabilities/`
holds six worked cases; `docs/proposals/capabilities.md` is the full model.

## Eval

`eval` runs a form under the scope and the authority it is written in. An `Env`
narrows from there:

```gene
(eval form ^in (env))                                   # inherits scope + authority
(eval form ^in (env ^bindings {^x 1}))                  # plus extra names
(eval form ^in (env ^capabilities [(fs/ReadDir ".")]))  # narrowed authority
(eval form ^in (env ^capabilities []))                  # no authority at all
```

`^capabilities` takes a **list** for the authority row and a **map** for a
binding overlay — the list is resolved against the creating context, so an `Env`
can never carry more than its creator held. A `(caller_env .snapshot ["x"])`
stays closed: it sees exactly the names it captured, never the evaluating scope.
