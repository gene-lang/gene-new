# Explicit fexprs and template macros

**Status:** normative and implemented. The executable contract lives in
`tests/spec_runner.nim`, especially the “explicit fexprs,” “macros from
design,” and cross-module suites.

Gene separates four mechanisms whose source forms reveal their evaluation
model:

```text
(foo a)       ordinary eager call
(foo! a)      explicit runtime fexpr call
(x .foo a)   eager message dispatch
(macro ...)   compile-time template expansion
```

Core special forms such as `if`, `match`, `fn`, and `var` keep plain names.
They are compiler primitives, not user-defined fexpr bindings.

## 1. The `!` rule

`!` is semantic syntax, not a style hint:

> A trailing `!` is reserved exclusively for a named fexpr declaration and a
> head-position fexpr invocation.

It is not a mutation convention and it is not a macro convention. Mutating
messages use ordinary snake_case names such as `push`, `put`, `set_prop`, and
`copy_from`. Macro names are ordinary snake_case names too. Message names and
all non-fexpr bindings ending in `!` are rejected.

This partition is intentionally narrow:

```gene
(foo arg)        # evaluate arg, then call foo
(foo! arg)       # pass arg as syntax to the fexpr foo!
(value .foo arg) # evaluate arg, then dispatch foo
```

Fexpr semantics apply only to a lexical call head. A send such as
`(value .foo! arg)` is invalid rather than becoming syntax-preserving message
dispatch.

## 2. Declaring an fexpr

A named `fn` ending in `!` declares an fexpr:

```gene
(fn unless! [cond body...]
  (if_not (eval cond ^in caller_env)
    (eval `(do %body...) ^in caller_env)))

(unless! false
  ($println "hi"))
```

The removed `(fn! ...)` form is an error. Anonymous functions remain ordinary
eager `Fn` values; there is no anonymous fexpr form. This puts the special
evaluation property on the callable's visible binding and call sites.

An ordinary `fn` binds evaluated values. A named fexpr binds the raw syntax
values from its call:

```text
fn add      parameters receive values after evaluation
fn quote_it! parameters receive syntax before evaluation
```

Fexpr parameters use the same positional, named, default, and rest shape
machinery, but matching operates on syntax values.

## 3. Invocation is source-visible

Ordinary calls never inspect the runtime callee to choose evaluation rules.
They evaluate every argument first. If the resulting callee is a held
`Fexpr`, the call raises `CallKindError`.

```gene
(fn quote_it! [form] form)
(var held quote_it!)

(quote_it! (+ 1 2)) # => (+ 1 2)
(held (+ 1 2))      # eager argument, then CallKindError
```

The same eager rule applies to higher-order parameters and expression heads.
There is no generic runtime “is this a syntax callable?” guard and no attempt
to reconstruct source after evaluation.

A held fexpr remains a runtime value for reflection and transport. Its runtime
type is `Fexpr`, a sibling of `Fn`, not a subtype. It does not satisfy an `Fn`
annotation and does not implement the ordinary invocation path.

Direct module imports retain fexpr metadata, so importing the declared
trailing-`!` name preserves explicit invocation:

```gene
(import [unless!] from "./control")
(unless! ready? (start))
```

Renaming it to a non-bang alias or storing it in an ordinary binding does not
create another fexpr call site. Creating arbitrary bang-suffixed aliases is
forbidden.

## 4. Invocation context

Every fexpr body receives two implicit read-only bindings:

```text
caller_env  CallerEnv   borrowed lexical environment of the invocation
syntax_call SyntaxCall  raw props, body, and optional source site
```

They do not appear in the parameter vector because the caller does not supply
them as ordinary arguments. The declared parameters bind `syntax_call`'s raw
syntax payload.

`caller_env` is authority. It resolves the caller's lexical bindings, imports,
module namespace, and built-ins. Code evaluated in it cannot create or rebind
bindings in the caller's scope, although reachable mutable values can still be
mutated.

The view is valid only for the dynamic extent of the fexpr call. It is not
`Send` or serializable and cannot escape through a return, error payload,
container, outer binding, closure, or spawned task. Durable capture is
explicit and selective:

```gene
(fn capture_config! []
  (caller_env .snapshot ["config"]))
```

This returns a durable `Env` containing `config`, not the caller's full
authority.

## 5. Runtime call envelopes

Ordinary calls carry evaluated values:

```gene
(type Call
  ^props {^named PropMap ^site Node?}
  ^body [Any...])

(protocol Callable
  (message apply [call : Call] : Any))
```

Fexpr calls carry syntax and caller context:

```gene
(type SyntaxCall
  ^props {^named PropMap ^site Node?}
  ^body [Any...])
```

`Fexpr` is a distinct runtime type, not an implementation of `Callable` and
not a user-extensible call protocol. The compiler emits its syntax-call path
only for a trailing-`!` lexical head.
Every ordinary call compiles its arguments eagerly and can use direct/fused
call opcodes without a syntax-kind guard. This also means ordinary dynamic
calls need not retain argument syntax.

## 6. Template macros

`macro` is a compile-time template expander, not a runtime value:

```gene
(macro when [cond body...]
  `(if_yes %cond %body...))

(when ready? (start))
```

Macro arguments are syntax nodes. Parameters may destructure syntax patterns
and may use named, default, typed, and rest positions. The MVP body is exactly
one syntax-producing expression, normally quasiquote. Arbitrary compile-time
function execution remains future work.

Macro names share the namespace with runtime bindings. Defining or importing a
macro over a value binding is an error, binding a value over a visible macro is
an error, and a macro cannot be used in value position. The macro name does
not end in `!`; expansion is known statically from the compiler's macro table.

File-defined macros are imported from compile artifacts without executing the
dependency's runtime top level:

```gene
(import [when : when_ready] from "./control")
(when_ready ready? (start))
```

Imported macros are usable by the importer but are not implicitly re-exported.
Built-in namespaces may expose compiler-known macros through the same import
surface. The logging namespace's `error`, `warn`, `info`, `debug`, and `trace`
macros use this mechanism to preserve lazy payload evaluation.

## 7. Hygiene

Template macros are hygienic. Names introduced by the template are fresh, so
they neither capture caller names nor get captured by them. Unquoted
caller-provided symbols intentionally retain call-site identity.

The implementation freshens recognized binder contexts including `var`, `fn`,
type/protocol/namespace declarations, and pattern binders. Full mark-set
hygiene and an explicit low-level capture API remain future work.

## 8. Choosing a mechanism

Use an explicit fexpr for runtime control of evaluation, lazy arguments,
runtime DSLs, or code that deliberately evaluates under `CallerEnv`/`Env`
authority.

Use a macro for a small compile-time surface rewrite that should become normal
Gene before name resolution, checking, tooling, or AOT lowering.

Use a core special form only for a primitive compiler semantic. Use a protocol
message for eager receiver-based behavior. These categories do not fall back
to one another.

## 9. Current implementation boundaries

- Fexprs are named `(fn name! ...)` declarations; `fn!` is rejected.
- Only `(name! ...)` selects syntax-preserving invocation.
- `caller_env` and `syntax_call` are implicit and read-only.
- Held fexprs have runtime type `Fexpr` but ordinary calls reject them.
- Macro names and message names cannot end in `!`.
- Mutation APIs use ordinary snake_case names.
- The web profile rejects fexprs because it has no live evaluator or retained
  caller syntax.
