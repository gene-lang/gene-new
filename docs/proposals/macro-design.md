# Gene Macro and Fexpr Design

**Status:** focused design note  
**Scope:** user-defined syntax extension, runtime fexprs, and compile-time templates  
**Decision:** use `fn!` for fexprs and `macro` for compile-time templates.

---

## 1. Summary

Gene should not treat full Lisp-style macros as the primary metaprogramming model.

Gene has a strong node model, explicit `Env`, callable-first evaluation, and runtime typed boundaries. Those features make **fexprs** a better default abstraction for user-defined syntax and DSLs.

The proposed split is:

```text
special forms   compiler-owned core language forms
fn!             runtime syntax-callable / fexpr
macro           compile-time template expander
derive          controlled compile-time declaration generation
```

In other words:

```gene
(fn  name [args...] body...)   # ordinary function; arguments are evaluated first
(fn! name [syntax...] body...) # fexpr; arguments are passed as syntax nodes
(macro name [syntax...] body)  # compile-time template; expands syntax before normal compilation
```

`fn!` should be the common user-facing syntax-extension tool. `macro` should be smaller, more restricted, and mainly used when compile-time expansion is truly required.

---

## 2. Goals

This design aims to support:

- custom control flow;
- lazy arguments;
- DSLs;
- hygienic template expansion where useful;
- protocol-local derivation;
- explicit authority through `Env`;
- good tooling and module behavior;
- future native/AOT compilation where possible.

It avoids making arbitrary compile-time execution the default mechanism for ordinary DSLs.

---

## 3. Terminology

### 3.1 Ordinary function

An ordinary function evaluates its arguments before the call:

```gene
(fn add1 [x]
  (+ x 1))

(add1 (+ 1 2)) # add1 receives 3
```

### 3.2 Fexpr / syntax callable

A fexpr receives unevaluated argument syntax and an explicit caller environment.

Gene spelling:

```gene
(fn! name [syntax-params...]
  body...)
```

Example:

```gene
(fn! when [cond, body...]
  (if (eval cond ^in caller-env)
    (eval `(do %body...) ^in caller-env)
    nil))
```

The exact name of the caller environment binding is specified below.

### 3.3 Compile-time template macro

A macro is a compile-time template expander:

```gene
(macro when [cond, body...]
  `(if %cond
     (then %body...)
     (else nil)))
```

A macro transforms syntax before normal compilation continues.

### 3.4 Derive

`derive` is a protocol-local compile-time declaration generator. It is not a general runtime fexpr.

```gene
(protocol HasLabel
  (message label [self] : Str)

  (derive [t : Type, req]
    `(impl HasLabel for %t
       (message label [self] : Str
         (to-str self/name)))))
```

---

## 4. Evaluation model

### 4.1 Ordinary call

For a normal call:

```gene
(f a b ^x c)
```

Evaluation is:

```text
1. evaluate head `f`;
2. if result is Callable, evaluate arguments and named arguments;
3. call Callable/apply.
```

### 4.2 Fexpr call

For a fexpr call:

```gene
(f! a b ^x c)
```

Evaluation is:

```text
1. evaluate head `f!`;
2. if result is SyntaxCallable, do not evaluate body arguments or named arguments;
3. package raw syntax nodes into SyntaxCall;
4. pass SyntaxCall plus caller Env to the fexpr body;
5. the fexpr decides what, when, and where to evaluate.
```

This means only the callee position is evaluated normally. Argument evaluation is controlled by the fexpr.

---

## 5. `fn!`: fexprs / syntax callables

### 5.1 Syntax

```gene
(fn! name [params...]
  body...)
```

Anonymous form:

```gene
(fn! [params...]
  body...)
```

A `fn!` defines a runtime value implementing `SyntaxCallable`.

```gene
(protocol SyntaxCallable
  (message apply_syntax
    [self : Self, call : SyntaxCall, env : Env] : Any))
```

Conceptual `SyntaxCall`:

```gene
(type SyntaxCall
  ^props {
    ^named PropMap
    ^site Node
  }
  ^body [Node...])
```

### 5.2 Bound environment

Inside a `fn!`, Gene provides a lexical binding:

```gene
caller-env : Env
```

`caller-env` is the caller’s evaluation environment. It is explicit and can be passed to `eval`.

Example:

```gene
(fn! unless [cond, body...]
  (if (not (eval cond ^in caller-env))
    (eval `(do %body...) ^in caller-env)
    nil))
```

### 5.3 Parameters

`fn!` parameters match syntax nodes, not evaluated values.

```gene
(fn! ignore [x]
  nil)

(ignore (panic "not evaluated")) # returns nil
```

Parameter matching may use the normal pattern/destructuring syntax over syntax nodes:

```gene
(fn! second [[_, value]]
  (eval value ^in caller-env))
```

Named syntax parameters are allowed:

```gene
(fn! with-timeout [expr, ^ms timeout]
  ...)
```

Defaults are syntax defaults, not evaluated-value defaults, unless explicitly evaluated in the fexpr body.

### 5.4 `fn!` is a value

Unlike `macro`, `fn!` produces an ordinary runtime value.

It can be:

```gene
(var w when)
(w cond body...)
```

It can be passed to functions, stored in maps, exported from modules, imported through ordinary imports, and used dynamically.

This is a key difference from `macro`.

### 5.5 Authority

A fexpr can evaluate only with the `Env` values it has.

The common case uses `caller-env`:

```gene
(eval node ^in caller-env)
```

But a fexpr may evaluate in a restricted environment:

```gene
(eval node ^in sandbox-env)
```

This makes fexprs compatible with Gene’s authority model. No ambient filesystem, network, subprocess, FFI, or native-compilation authority is granted unless present in the selected `Env`.

### 5.6 Return value

A `fn!` returns an ordinary runtime value.

If it evaluates syntax, the result is the result of `eval`:

```gene
(fn! do1 [x]
  (eval x ^in caller-env))
```

If it builds data, it may return data directly:

```gene
(fn! quote-node [x]
  x)
```

---

## 6. `macro`: compile-time templates

### 6.1 Role

`macro` is not a general compile-time function system. It is a compile-time **template expander**.

A macro receives syntax nodes and returns syntax that is compiled in place.

```gene
(macro when [cond, body...]
  `(if %cond
     (then %body...)
     (else nil)))
```

Macros should be used when expansion must happen before type checking, declaration collection, or native/AOT compilation.

Most DSLs and custom control flow should use `fn!` instead.

### 6.2 Syntax

```gene
(macro name [params...]
  template-expr)
```

MVP restriction:

```text
A macro body contains exactly one syntax-producing expression.
```

Usually that expression is a template/quasiquote.

```gene
(macro twice [x]
  `(do %x %x))
```

### 6.3 Macro parameters

Macro parameters receive syntax nodes.

They may destructure syntax nodes with patterns:

```gene
(macro second [[_, value]]
  `%value)
```

Named macro parameters are syntax nodes:

```gene
(macro tagged [value, ^tag t]
  `(quote (%t %value)))
```

### 6.4 Macro namespace rule

Macros are compile-time rewriters, not runtime values.

A macro name occupies the same visible name space as bindings:

```text
- defining a macro whose name conflicts with a visible binding is an error;
- defining a binding whose name conflicts with a visible macro is an error;
- using a macro name in value position is an error;
- macros are called only in head position.
```

Example:

```gene
(macro when [cond, body...] ...)
when # error: macro cannot be used as a value
```

This differs from `fn!`, which creates a normal runtime value.

### 6.5 Macro imports

Macros are module exports, but only for compile-time use.

```gene
(import [when : unless-not] from "./control")
```

Rules:

```text
- only top-level `from "path"` imports can import macros;
- imported macros are available while compiling the importing module;
- imported macros are not runtime bindings;
- imported macros are not re-exported by default;
- namespace-path imports do not carry macros in MVP;
- importing a macro whose local name conflicts with a visible macro or binding is an error.
```

Runtime fexprs do not have these restrictions because they are ordinary values.

### 6.6 Hygiene

MVP macro hygiene is fresh-name based.

When a template introduces a binder in a recognized binding form, the compiler rewrites that introduced name to a fresh internal symbol.

Example:

```gene
(macro local [x]
  `(do
     (var tmp 1)
     (+ tmp %x)))

(var tmp 100)
[(local 2) tmp] # => [3 100]
```

The introduced `tmp` inside the expansion does not capture or overwrite the caller’s `tmp`.

Target model for the future:

```text
symbols = text + hygiene marks
```

MVP does not need full mark-set hygiene immediately, but the implementation should leave room for it.

### 6.7 Intentional capture

Intentional capture must be explicit.

The simplest MVP rule:

```text
A macro captures caller names only by unquoting caller-provided syntax.
```

Example:

```gene
(macro bind-user-name [name]
  `(var %name "Alice"))
```

A future low-level hygiene escape may be added, but it should not be part of the normal macro style.

---

## 7. Choosing between `fn!` and `macro`

Use `fn!` when:

```text
- custom evaluation order is enough;
- syntax is evaluated at runtime;
- the construct needs caller Env authority;
- the construct is a DSL or control abstraction;
- the result does not need to create compile-time declarations;
- tooling does not need to see the expanded form ahead of time.
```

Use `macro` when:

```text
- expansion must happen before type checking;
- expansion must create code that participates in AOT/native compilation;
- expansion must create declarations visible later in the same module;
- the compiler/tooling must see the expanded syntax;
- protocol derive or FFI wrapper generation needs syntax before runtime.
```

Use `derive` when:

```text
- a protocol generates an implementation for a type;
- generated declarations should live in a compiler-owned overlay;
- source modules should not be mutated.
```

---

## 8. Examples

### 8.1 Fexpr `when`

```gene
(fn! when [cond, body...]
  (if (eval cond ^in caller-env)
    (eval `(do %body...) ^in caller-env)
    nil))
```

Usage:

```gene
(when (> x 0)
  (println "positive")
  x)
```

### 8.2 Fexpr `assert`

```gene
(fn! assert [cond, ^message msg = "assertion failed"]
  (if (eval cond ^in caller-env)
    true
    (panic msg)))
```

### 8.3 Fexpr `with-resource`

```gene
(fn! with-resource [binding, body...]
  (match binding
    (when [name init]
      (var value (eval init ^in caller-env))
      (var child (caller-env ~ Env/extend {name value}))
      (try
        (eval `(do %body...) ^in child)
      ensure
        (value ~ Closeable/close)))))
```

### 8.4 Template macro `unless`

```gene
(macro unless [cond, body...]
  `(if (not %cond)
     (then %body...)
     (else nil)))
```

The generated `if` is type-checked and compiled as if it appeared in the source.

### 8.5 Template macro introducing a local

```gene
(macro with-temp [value, body...]
  `(do
     (var tmp %value)
     %body...))
```

The introduced `tmp` is hygienically fresh in MVP.

### 8.6 Protocol derive

```gene
(protocol HasLabel
  (message label [self] : Str)

  (derive [t : Type, req]
    `(impl HasLabel for %t
       (message label [self] : Str
         (to-str self/name)))))
```

---

## 9. Relationship to `Env` and `eval`

`fn!` depends directly on `Env` and `eval`.

A fexpr receives caller syntax and may evaluate it explicitly:

```gene
(eval syntax-node ^in caller-env)
```

This preserves Gene’s authority model:

```text
syntax is not automatically authority;
Env grants authority;
eval uses the normal compiler pipeline;
policy controls execution, imports, FFI, native compilation, and limits.
```

`macro` normally does not receive runtime `Env`. It expands during compilation. Future compile-time function macros may receive a compile-time environment, but that is not part of the initial macro system.

---

## 10. Tooling and compilation implications

### 10.1 `fn!`

Because `fn!` runs at runtime, tooling cannot always know what syntax it will evaluate.

This affects:

```text
- static diagnostics inside fexpr-controlled syntax;
- AOT/native compilation of the fexpr body’s evaluated syntax;
- sealed application images;
- declaration discovery;
- route discovery;
- refactoring tools.
```

The runtime may cache compiled `eval` results by semantic node hash, environment shape/version, visible implementation set, compiler version, and policy.

A JIT can optimize repeated fexpr/eval patterns, but JIT does not replace the semantic benefits of compile-time expansion.

### 10.2 `macro`

Because `macro` expands before normal compilation, tooling can inspect the expanded syntax.

This helps:

```text
- type checking;
- declaration collection;
- protocol impl visibility;
- AOT/native compilation;
- sealed builds;
- documentation generation;
- LSP and refactoring.
```

That is why `macro` remains useful even if `fn!` is the preferred DSL mechanism.

---

## 11. Implementation plan

### Phase 1: MVP template macros

Already close to current implementation:

```text
- `(macro name [params...] template-expr)`;
- syntax-node arguments;
- syntax-pattern parameter matching;
- rest and named syntax parameters;
- template/quasiquote expansion;
- fresh-name hygiene for recognized introduced binders;
- top-level `from "path"` macro imports;
- macro/value namespace conflict checks.
```

### Phase 2: `fn!` fexprs

Add:

```text
- `SyntaxCallable` protocol;
- `SyntaxCall` value;
- `fn!` definition form;
- caller-env binding;
- call dispatch that evaluates only the callee first;
- explicit eval through `caller-env`;
- tests for lazy args, named syntax args, Env authority, and dynamic fexpr values.
```

### Phase 3: compile-time derive and declaration overlays

Add or harden:

```text
- protocol-local `derive`;
- generated declaration overlay;
- provenance meta;
- normal type checking of generated impls;
- visible-implementation coherence.
```

### Phase 4: future full compile-time functions

Optional later:

```text
- compile-time Env;
- compile-time value evaluation;
- richer macro APIs;
- mark-set hygiene;
- explicit intentional capture API;
- macro-generated imports/declarations with phase tracking.
```

---

## 12. Required tests

### 12.1 `fn!`

```gene
(var hit 0)
(fn! ignore [x] nil)
[(ignore (set hit 1)) hit] # => [nil 0]
```

```gene
(fn! eval1 [x]
  (eval x ^in caller-env))

(eval1 (+ 1 2)) # => 3
```

```gene
(var x 10)
(fn! quote-syntax [x] x)
(quote-syntax (+ x 1)) # => (+ x 1)
```

### 12.2 Macro templates

```gene
(macro when [cond, body...]
  `(if %cond (then %body...) (else nil)))

[(when true 1) (when false 2)] # => [1 nil]
```

### 12.3 Macro/value separation

```gene
(macro m [] 1)
m # error: macro cannot be used as value
```

```gene
(macro m [] 1)
(var m 2) # error
```

### 12.4 Imported macros

```gene
# control.gene
(macro when [cond, body...]
  `(if %cond (then %body...) (else nil)))

# app.gene
(import [when] from "./control")
(when true 1)
```

Alias:

```gene
(import [when : if-true] from "./control")
(if-true true 1)
```

Not re-exported by default:

```gene
# middle.gene
(import [when] from "./control")

# app.gene
(import [when] from "./middle") # error unless middle defines/re-exports it explicitly
```

### 12.5 Hygiene

```gene
(macro local [x]
  `(do (var tmp 1) (+ tmp %x)))

(var tmp 100)
[(local 2) tmp] # => [3 100]
```

Pattern-binder hygiene should also be tested:

```gene
(macro m [x]
  `(match %x
     (when [tmp]
       tmp)))

(var tmp 100)
[(m [1]) tmp] # => [1 100]
```

---

## 13. Final recommendation

Gene should use `fn!` as the primary user syntax-extension mechanism and keep `macro` as a restricted compile-time template system.

```text
fn!   = runtime fexpr / syntax callable / Env-aware DSL tool
macro = compile-time template expansion for code the compiler must see
derive = protocol-local compile-time declaration generation
```

This gives Gene most of the expressive power users expect from macros, while preserving a clearer runtime authority model and avoiding the full complexity of Lisp macros as the default path.
