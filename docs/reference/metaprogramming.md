# Fexprs, macros, and evaluation

**Status:** detailed design reference and rationale. The implemented contracts
are [calls](../spec/calls.md), [authority](../spec/authority.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 11. Fexprs, macro templates, and compile-time code

Gene separates runtime syntax behavior from compile-time rewriting.

```text
name!  explicit runtime fexpr / syntax callable / CallerEnv-aware DSL tool
macro  compile-time template expansion
derive protocol-local compile-time declaration generation
```

This split avoids making full Lisp-style macros the default abstraction while still preserving the pieces Gene needs for DSLs, homoiconic code, derivation, and AOT/sealed builds.

### 11.1 Explicit named fexprs

A named `fn` whose name ends in `!` defines a runtime syntax callable. The
marker belongs to the binding and its call sites, not to an alternate anonymous
function form. It receives unevaluated syntax nodes and a borrowed view of the
caller, then decides what to evaluate.

```gene
(fn unless! [cond, body...]
  (if_not (eval cond ^in caller_env)
    (eval `(do %body...) ^in caller_env)))
```

This example selects when syntax is evaluated. Each `eval` has its own binding
and control-flow scope; it does not provide an ordinary lexical `unless`:

```gene
(var x 0)
(unless! false (set x 1)) # current VM: updates an evaluation copy
x                         # => 0
```

Use a template macro (§11.2) when the body needs to assign caller variables or
use the caller's enclosing function or loop targets. See the
[fexpr demo](../../examples/fexpr_demo.gene) for both forms.

The declaration creates an `Fexpr` runtime value (§3).
Its parameter vector matches raw syntax nodes, not evaluated argument values.
Inside its body, the implementation provides read-only implicit bindings:

```text
caller_env  CallerEnv   # borrowed; valid only during this syntax call
syntax_call SyntaxCall  # the full raw call envelope, including props/site
```

The parameter bindings such as `cond` and `body` are syntax values. An fexpr
may call `eval` explicitly with the live `caller_env`, or snapshot selected
authority into a durable `Env`. `caller_env` and `syntax_call` are invocation
context and therefore do not appear in the parameter vector.

The trailing `!` is enforced. Fexprs must be named and statically identifiable;
anonymous `(fn [...] ...)` values are ordinary `Fn` values. `fn!` definition
syntax is invalid. No other binding or message name may end in `!`.

Calling an explicit fexpr supplies a borrowed `CallerEnv` view of the caller's
evaluation environment. This is access to caller names and values, distinct
from the external-operation permissions in §14. An ordinary Env overlays the
scope where `eval` executes; `caller_env` instead names the syntax caller:

- `caller_env` resolves the caller's lexical bindings, imports, module namespace, and core built-ins, in §11.5 resolution order.
- `caller_env` provides read-only access to the original caller bindings. Each
  `eval` materializes a fresh evaluation copy; declarations stay in the evaluated
  unit. The current VM permits `set` on copied bindings, but these writes affect
  only that evaluation and are discarded afterward. Rejecting such assignments
  would be a separate language change.
- Reachable mutable values — Cells, buffers, actors — retain their identities
  and can still be mutated. Invoked closures retain their existing authority
  to mutate captured bindings. Read-only caller access does not make evaluation
  effect-free.
- `CallerEnv` is valid only for the dynamic extent of the syntax call. It is not `Send` or serializable. It cannot be returned, used as an error payload, inserted into a heap container or durable `Env`, stored in an outer/global/module binding, captured by an escaping closure, or captured by a spawned task. These checks also apply to closures and containers that transitively carry the borrowed view.
- Durable capture is explicit: `(caller_env .snapshot ["name" ...])` copies
  exactly the named visible bindings into a closed Env. Missing or duplicate
  names fail. Selected closures retain their captures; unlisted names are
  absent from the snapshot. No external capability grant becomes a Gene value.
- Calling an explicit fexpr hands it caller authority. A syntax callable
  evaluating untrusted syntax should first create a purpose-built snapshot and
  apply the evaluation policies described in §11.5.

`eval` does not inherit the caller's function-return or loop targets. `return`
requires a function defined within the evaluated syntax; `break` and `continue`
require a loop within that syntax. A missing local target is a `CompileError`
when the syntax is evaluated, even if the fexpr call is inside a function or
loop. Control forms in the fexpr's own body follow that body's ordinary lexical
rules. [The fexpr contract](../macro-design.md#4-invocation-context) describes the
binding and control boundaries together.

For example, this durable environment contains `config` but not `secret`:

```gene
(fn capture_config! []
  (caller_env .snapshot ["config"]))
```

`Fexpr` values may be held for reflection, imported through their declared
name, passed around, or stored. Holding one does not preserve invocation
semantics through a differently named `var`/`let` alias, an expression head,
or a higher-order ordinary call: those paths are eager and reject the held
fexpr after evaluating their arguments. Only lexical `(name! ...)` invokes it
with a `SyntaxCall` and a fresh borrowed `CallerEnv`.

Use an explicit fexpr for:

- custom evaluation strategies;
- lazy arguments;
- runtime DSLs;
- test/configuration languages;
- explicit `Env`-bounded evaluation;
- syntax utilities that do not need to create module declarations before type checking.

Because an fexpr runs at runtime, its generated/evaluated code may be checked
later than normal code. JIT/eval caching may recover performance, but it does
not give the same early declaration graph, tooling, or AOT visibility as
compile-time expansion.

### 11.2 `macro`: compile-time templates

`macro` defines a compile-time template expander. A macro receives syntax nodes and returns syntax nodes before name resolution, type checking, native compilation, and ordinary runtime evaluation.

```gene
(macro when [cond, body...]
  `(if_yes %cond %body...))
```

Template macros extend ordinary lexical syntax and control flow. The expanded
code determines the bindings and the targets of `return`, `break`, and
`continue`. A conditional template introduces no new function or loop, so its
body can use the caller's targets; a template that introduces those constructs
must account for their scopes.

Macro names are ordinary `snake_case` names and may not end in `!`; the marker
is reserved for runtime fexpr invocation.

MVP macros are **template macros**, not arbitrary compile-time functions. A macro body contains exactly one syntax-producing expression, normally a quasiquote/template. General compile-time function macros with arbitrary compile-time evaluation are future work.

Macro call arguments are syntax nodes. Macro parameters may destructure those syntax nodes with patterns. Macro parameter annotations, defaults, named parameters, and rest parameters operate on syntax values, not evaluated runtime values. `%` at a macro call site is not a special macro-argument convention; `%` remains the normal unquote/escape operator inside template-like contexts.

A name means the same thing in head position and value position. Macro names therefore share the single namespace with runtime bindings:

- defining or importing a macro whose name matches a visible binding is an error;
- binding a name, including a function parameter, that matches a visible macro is an error;
- using a macro name in value position is an error: “call it in head position.”

Macros are compile-time rewriters, not runtime values. This is stricter than special forms: a value named `if` may exist in data or qualified positions, but a macro name reserves its name within its visibility region.

File-defined macros are module exports selected through top-level `from
"path"` import lists and honor selection aliases:

```gene
(import [when : unless_not] from "./control")
```

Because expansion happens while the importer compiles, a top-level
`from "path"` macro selection reads the dependency's cached compile artifact.
This parses and compiles macro/derive declarations but does not create a
runtime module scope or execute any dependency top-level form. Imported macros
are usable but are not re-exported by the importing module. Ordinary
namespace-path imports such as `(import gene/stream [...])` do not carry
file-defined macros in MVP because there is no dependency artifact to read. A
built-in namespace may register compiler-known template macros; a top-level
namespace selection imports those with the same alias, collision, hygiene, and
head-position-only rules. The `log` namespace's
`error`/`warn`/`info`/`debug`/`trace` forms are the first such built-ins.
Imports inside nested scopes resolve at runtime only, so all macros must still
be imported at top level.

Use `macro` for:

- small compile-time surface rewrites;
- syntax templates that should type-check as ordinary expanded code;
- AOT/sealed-build-visible code generation;
- tooling-visible transformations.

Prefer an explicit fexpr when the transformation is really a runtime DSL or depends on runtime `Env` authority.

### 11.3 Hygiene

Macros are hygienic by default. The target semantic model is expansion marks: symbols introduced by a macro carry fresh expansion identity, so introduced binders do not accidentally capture call-site names and call-site names do not accidentally capture introduced helper names.

MVP implementation may approximate this with generated fresh names for recognized template-introduced binders such as `var`, `fn`, `type`, `protocol`, `ns`, and `macro`. Full mark-set hygiene, explicit capture APIs, macro-generated imports, and hygiene for every binding context are future work.

Intentional capture must be explicit, either by unquoting a caller-provided symbol or by a future low-level hygiene escape. A `gensym`/fresh-symbol API may be exposed for macros that need explicit generated names.

### 11.4 Protocol-local `derive`

Protocol-local `derive` remains a controlled compile-time declaration generator. It receives a target `Type` value and a request node, then returns declarations, usually an `impl` for that same protocol:

```gene
(protocol HasLabel
  (message label [] : Str)

  (derive [t : Type, req]
    `(impl HasLabel for %t
       (message label [self] : Str
         ($to_str self/name)))))
```

`derive` is not a general fexpr. It runs in the compiler's derivation phase and is allowed to add declarations to a compiler-owned overlay. Source modules are not mutated.

A `derive` may generate `impl` declarations for **any protocol resolvable at
the deriving site** (its own, or another — the `Delegate` forwarding case),
but the generated impl must **target the deriving type**. That co-location is
the coherence anchor: the generated pair lives with its receiver's home, so it
classifies exactly like an inline impl of the type declaration — canonical at
static top level, overlay otherwise — and a derive can never register behavior
for an unrelated type at a distance. Rejections and conflicts name the
deriving protocol. Broader declaration generation (non-`impl` declarations) is
future work.

### 11.5 `Env` and dynamic evaluation

`Env` is the first-class name-resolution environment passed to `eval`. A binding is one name/value entry inside an `Env`. `GeneContext` remains an internal VM/FFI execution state containing thread, stack, allocator, GC, and error-state information.

An `Env` is an opaque, garbage-collected value. It may be stored, passed, returned, captured by closures, and retained by compiled/evaluated code.

```gene
(var base
  (env
    ^bindings {^x 10}
    ^imports [std/math]))

(var child
  (base .extend {^y 20}))
```

Environments are immutable by default. `extend` (on `Env`) creates a child environment whose parent is the original environment; it does not mutate the parent.

Conceptually, an environment contains:

```text
local bindings
parent Env
optional module namespace
explicit imports
optional retained capability ceiling
evaluation policy
```

Name resolution inside evaluated code proceeds in this order:

1. lexical bindings and declarations created by the evaluated unit;
2. bindings in the supplied `Env`, following its parent chain;
3. explicitly imported modules;
4. the optional module namespace carried by the `Env`;
5. the lexical scope where `eval` executes, including its available built-ins.

An ordinary Env adds overlays to the evaluation-site lexical scope; it does
not hide that scope's names. A named `CallerEnv/snapshot` is a closed capture
with no evaluation-site lexical fallback. Name visibility and operation
permission are separate; neither form grants external authority by itself.

```gene
(var secret "hidden")
(var e (env ^bindings {^x 1}))

(eval `secret ^in e) # => "hidden": evaluation-site lexical fallback

(var e2 (env ^bindings {^secret secret}))
(eval `secret ^in e2) # => "hidden"
```

Shared mutation is explicit. Ordinary environment bindings are read-only, but an environment may contain mutable values such as `Cell`, buffers, actors, or domain-specific state objects.

```gene
(var counter ($cell 0))
(var e (env ^bindings {^counter counter}))

(eval
  `(counter .set
     (+ (counter .get) 1))
  ^in e)
```

The core evaluation form is:

```gene
(eval node ^in env)
```

Normal programs must supply `^in`. A REPL may use its current session environment implicitly. `eval` accepts a node, not source text. Parsing remains a separate operation:

```gene
(var node ($read_one "(+ 1 2)"))
(eval node ^in e)
```

A convenience `eval_string` function may compose parsing and evaluation, but it is not the primitive operation.

`eval` uses the normal compilation pipeline rather than a second interpreter:

```text
validate node
→ collect declarations
→ expand macro templates
→ run protocol-local derivation
→ resolve names and visible impls
→ type-check typed regions
→ compile bytecode or eligible native code
→ execute
```

The general result type of `eval` is `Any`. Typed callers use the ordinary gradual boundary:

```gene
(var result : Int
  (eval generated_node ^in e))
```

A non-`Int` result causes a recoverable boundary `TypeError` with blame information.

Declarations produced inside `eval` are installed in an isolated, immutable evaluation overlay. They are visible to the evaluated unit but do not mutate the source module or replace existing module bindings.

```gene
(var f
  (eval
    `(do
       (fn add1 [x : Int] : Int (+ x 1))
       add1)
    ^in e))
```

The returned function retains the overlay and any captured environment it needs. The overlay remains alive while reachable functions, types, protocol impls, callbacks, or compiled artifacts refer to it.

`eval` and live code activation are separate operations:

```text
eval      compile and execute code in an isolated overlay
activate  atomically replace live module bindings; designed separately
```

An `Env`, its parent chain, and associated overlays participate in normal tracing garbage collection. They remain alive while referenced by locals, closures, compiled artifacts, other environments, or native roots. Unreachable cycles such as `Env → closure → Env` are collectable. Native code retaining an `Env` or evaluated callable must use the ordinary Gene rooting API.

Compilation failures from evaluated code are recoverable `CompileError` values. Errors raised by the evaluated program propagate normally and are dynamically errorful unless a more specific wrapper constrains them. Boundary `TypeError` values are recoverable errors. Panic, internal VM invariant failures, and native process corruption remain fatal.

An Env may retain a capability ceiling in addition to its name bindings.
`^capabilities [...]` resolves a selector row against the creator's active
context. Every `eval` intersects its current context with that retained ceiling
and all parent Env ceilings. `Env/extend` cannot drop parent restrictions.
Escaped evaluated functions keep the resulting ceiling.

With no selector row, eval inherits the evaluator's context. `^capabilities []`
selects no external capabilities. The legacy map form of `^capabilities` only
adds names; use `^bindings` for those values. It does not grant or remove
external permissions. The implemented rules and boundary tests are in
[the authority contract](../spec/authority.md).

An evaluation policy may impose execution limits:

```gene
(var policy
  {
    ^max_steps 1000000
    ^max_memory_mb 128
    ^timeout_ms 5000})

(var e
  (env
    ^bindings {^input input}
    ^capabilities []
    ^policy policy))
```

The accepted false `allow_ffi` / `allow_native_compile` policy fields do not
replace runtime permission checks or establish native-code isolation. The
sandbox-generation loader (§15.10) separately rejects privileged declarations.
Arbitrary native code cannot be confined in-process by the VM capability model.

Compiled eval units may be cached using the semantic node hash, compiler version, imported module/macro versions, visible implementation set, environment-relevant compiler options, and policy. Source-location meta need not invalidate the cache unless consumed by a macro or compiler phase.

---
