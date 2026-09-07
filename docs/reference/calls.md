# Evaluation, calls, and parameters

**Status:** detailed design reference and rationale. The implemented contracts
are [calls](../spec/calls.md), [nil-void](../spec/nil-void.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 3. Evaluation and callability

Gene has two lexically distinct invocation kinds:

1. ordinary value callability, where arguments are evaluated before the callee receives them;
2. explicit fexpr callability, where a trailing-`!` head receives raw syntax nodes plus the caller environment and decides what to evaluate.

Ordinary calls use a `Call` envelope:

```gene
(type Call
  ^props {^named PropMap ^site Node?}
  ^body  [Any...])

(protocol Callable
  (message apply [call : Call] : Any))
```

Syntax calls use a `SyntaxCall` envelope:

```gene
(type SyntaxCall
  ^props {^named PropMap ^site Node?}
  ^body  [Any...])
```

`Fn`, `Type`, `Selector`, native functions, and user-defined callable values
implement `Callable`. A protocol message in value position is a dispatching
closure, so it implements `Callable` too (§3). `Fexpr` is a separate runtime
type and does not implement `Callable`; the compiler may invoke one only from
its explicit lexical call form.

To evaluate `(h ^p v c1 c2)`:

1. If `h` names a special form, use that special-form rule.
2. If `h` names a compile-time `macro`, expand it before runtime evaluation.
3. If `h` is a bare lexical name ending in `!`, resolve it as a statically
   known fexpr binding, build a `SyntaxCall` from the **unevaluated** prop/body
   syntax nodes, and invoke the `Fexpr` with a borrowed `CallerEnv`.
4. Otherwise evaluate `h`, then evaluate props/body into a `Call` envelope.
5. If the callee implements `Callable`, call `apply`.
6. If an ordinary call encounters a held `Fexpr`, raise `CallKindError`; never
   reinterpret already-evaluated arguments as syntax.
7. Otherwise it is a call error.

The source therefore determines evaluation locally:

```gene
(foo a)   # always eager
(foo! a)  # explicit fexpr invocation; a is syntax
```

There is no runtime syntax-callability guard on an ordinary call. Aliases,
expression heads, higher-order parameters, and `Env`-provided ordinary names
cannot invoke an `Fexpr`. A held fexpr may be inspected or transported as a
runtime value, but invocation is available only through its statically known
trailing-`!` binding. Direct selected imports preserve that declaration
metadata. This keeps ordinary calls simple, permits argument-first fused
opcodes without a syntax-kind check, and avoids retaining argument syntax for
dynamic calls.

`Fexpr` is a sibling of `Fn` in the type hierarchy (§7.2), not a subtype. It
does not satisfy an `Fn [...] ...`-typed parameter. `!` is semantic syntax,
reserved exclusively for fexpr declaration and head-position invocation; it
is not a mutation or macro naming convention.

Normal calls are callable-first:

```gene
(f x y)
```

There is no implicit subject-call rule.

Message sends use a dot-prefixed descriptor:

```gene
(x .f a b)   # send message f to x; dispatches on x's runtime type
(x .P:f a b) # qualified: P:f names a protocol message, dispatched on x
(x .%m a b)  # send a held message value m (§8)
(super .f a) # delegate to the implementation above this one (§10)
(.f a b)     # send to lexical self: (self .f a b)
(x ?.f a b)  # absence-guarded send: nil/void receiver yields itself (below)
(?.f a b)    # guarded send to lexical self
```

**`?.message` is the absence-guarded send.** It is the same send as `.message` with one
added rule, applied to the *receiver only*: when the receiver is absent the
send yields that receiver unchanged — `nil` stays `nil`, `void` stays `void` —
and the message is never resolved, nor is any argument form evaluated. A
present receiver takes the ordinary path, so a misspelled message is still a
`MessageError`:

```gene
(some ?.msg)   # dispatches normally
(nil  ?.msg)   # => nil    — no lookup, no MessageError
(void ?.msg)   # => void
(nil  ?.nope)  # => nil    — absence is decided before the name is
(some ?.nope)  # MessageError: absence-guarding never hides a typo
```

This is deliberately *not* a global rule about `nil` receivers. `Nil` remains
an ordinary nominal type with no dispatch carve-out (`docs/core.md` §10), so
`(nil .msg)` is still an error and `(impl P for Nil …)` still works. The two
spellings stay distinguishable even when that impl exists — `?.message` short-circuits
*before* any lookup, so it does not run it:

```gene
(impl P for Nil (message pm [] : Str "—"))
(nil .P:pm)    # => "—"   dispatches to the Nil impl
(nil ?.P:pm)   # => nil   guarded: absence decided before lookup
```

That is the point of the guard being a call-site choice: `?.message` states that
*this* send tolerates absence, rather than resolving to whatever an impl
elsewhere happens to define for `Nil`. Choose `.message` when nil's behavior is the
answer, `?.message` when absence should propagate. The guard lives at the call site because that is where the
decision belongs: `?.message` says *this* send tolerates absence, without making every
send silent about it. `super` is never absent, so `(super ?.m)` is rejected;
selectors remain ordinary callables such as `(/name x)` — use `??` for an
absent-valued projection. Leading `(?.m …)`
is the guarded self-send, which matters inside an `impl P for Nil` body where
lexical `self` is itself absent. The normative contract is
`docs/spec/calls.md`.

**A dot send dispatches, and only dispatches — there is no lexical fallback.** A bare
name in send position resolves receiver-first against the receiver's type; it is
never resolved as an ordinary lexical binding. A bare call `(f x)` stays purely
lexical, and message names are not bound in the enclosing scope, so the two
mechanisms never mix.

An unqualified send resolves `f` against the receiver's **type-direct** messages
only, walking the nominal parent chain. Protocol messages are **always qualified** —
`(x .P:m)` — so a protocol impl is never reached by a bare name. If the
receiver's type declares no such message, the send raises a recoverable
**`MessageError`** (a subtype of `TypeError`) carrying `^where`,
`^receiver_type`, and `^message`; when the failed name also names a lexical
callable, the diagnostic says so ("… is a function — did you mean to call it,
not send it?"). Full resolution rules: `docs/core.md §9`.

**Every non-bare callee must be a message value.** A protocol-qualified message
(`x .P:m`), a held value (`x .%m`), and a computed descriptor (`x .%(expr)`) all have
to denote or evaluate to a message; the implementation is then dispatched on
`x`. A plain function, a slash-selected namespace member, or a held `Fexpr` is
**rejected, not invoked** — so
`(xs .%$str/join "-")` and `(x .%some_fn)` are errors rather than
back-door function calls. This is what makes "dispatches, and only dispatches"
true of the whole operator and not just of bare names.

Only protocols give messages a qualified spelling. **Bare means type-direct;
`P:m` means protocol-qualified.** Built-in operations on real built-in types
follow the same rule: `Cell` owns the type-direct messages `get`, `set`, `swap`,
and `update`, so `(c .get)` dispatches. `Cell:get` is invalid because `Cell` is
a type, not a protocol; `Cell/get` is not a callable path either.

**Case carries meaning in the stdlib: uppercase names denote types, protocols,
enums, and capabilities; lowercase names denote functions or namespaces.** A
lowercase companion is not required for every type. Where both exist, an
operation with a receiver belongs to the type and an operation without one is
a function. For actors, the type is `gene/Actor` and the creation/control
functions are under `gene/actor`:

```gene
(a .send msg)              # Actor/send — acts on an actor reference
(a .ask   f)               # Actor/ask, Actor/try_send, Actor/snapshot, ...
($actor/spawn ^init i ^handle h)   # makes one — no receiver, so a function
($actor/continue state)            # actor-body control signal — no receiver
```

`Module`, `Namespace`, `Capability`, and `Env` likewise expose receiver
operations as type-direct messages: `(this_mod .path)`,
`(ns .lookup "x")`, and `(cap .name)`. These messages are sent bare;
`Actor:send` and `Actor/send` are both invalid spellings.

Most uppercase built-in receiver surfaces are real types, not namespaces of
natives. This includes the scalar types and `List`, `Map`, `Node`, `Range`,
`Date`, `Time`, `DateTime`, `Timezone`, `Duration`, `Buffer`, `Cell`,
`AtomicCell`, `Task`, `Channel`, `Stream`, `Actor`, `ReplyTo`, `Module`,
`Namespace`, `Capability`, `Env`, and `CallerEnv`. Their message tables use the
same type-direct resolution path as user types, and they can be named by
`(impl P for T)`.

The separate built-in fallback is deliberately narrow: it supplies operations
for runtime surfaces that are not real types (`Set`, `Regex`, and `Logger`),
shared structural behavior such as `Range/to_stream` and typed-node anatomy,
and type/enum reflection. It is not the implementation path for the real types
listed above.

`snapshot` illustrates the receiver rule: it takes a `CallerEnv`, so
`CallerEnv` is a real type with a `snapshot` message and the operation is sent
as `(caller_env .snapshot ["x"])`; it is not an `Env` function.

Selectors are not message descriptors. Apply one as an ordinary callable,
`(/name x)`, when projecting a receiver.

The recoverable error for the wrong kind of non-bare callee or qualifier is
`CallKindError`, a subtype of `TypeError`, with `^where`, `^expected`, `^actual`,
and `^actual_value` diagnostics. An ordinary non-message callee reports
`^expected "Message"`; a direct qualifier must be a `Protocol`; and a held
`Fexpr` reports its distinct call kind. Rejection happens before any remaining
send argument is evaluated. Fexprs are invoked only in explicit trailing-`!`
call-head position; send syntax is never reinterpreted as a syntax call.

**Direct message heads normalize to sends.** `(P:msg x a)` is equivalent to
`(x .P:msg a)`, including receiver-first evaluation, descriptor resolution,
argument evaluation, and failure timing. `(Self:msg x a)` likewise means
`(x .msg a)`. Normalization happens before pipeline preparation. The receiver
must be the first explicit positional form; a leading receiver spread or no
receiver is rejected. Bind the message first for ordinary eager spread calls.

**`Self` is the reserved value spelling for a type-direct message.** It names
no qualifier, so `(x .Self:msg)` is exactly the bare send `(x .msg)` and
dispatches on `x`'s runtime type. A type cannot qualify a message: `T:msg`
raises `CallKindError` with `^expected "Protocol"`. A program may not declare
`Self`.

`Self:msg` is what gives a bare message name a *value* spelling, since message
names are not lexical bindings:

```gene
($map xs P:show)      # each element's impl of P
($map xs Self:show)   # each element's own type-direct show
```

In any other position `P:msg` or `Self:msg` is a **message value**, not a
function: it prints as `(message msg)`, satisfies `Callable` but *not* `Fn`, and
is accepted as a held send callee `(x .%m)` — which a function is not. A
higher-order callable consumer applies one to its first argument, so
`($map xs P:msg)` dispatches per element and needs no lambda; the callable shape
is `(receiver, ...send args)`. The standard collection operations are this
shape at stdlib scale: `$map` and friends are message identities shared across
the built-in collection types (§6.2), so `($map xs f)` and `(xs .map f)` are
one dispatch. Direct source syntax `(P:msg x)` uses the same canonical send
operation as its dot spelling.

The value carries the scope it was **written** in. Higher-order application has
no send site, so it resolves in that authored scope. A held send `(x .%m)` is
different: it does have a send site and resolves the held message in that
site's scope. This distinction lets a lazy combinator retain and apply only the
message value without silently adopting the eventual consumer's scope.

`/` never spells a message. `P/m` is an error that names `P:m` as the
replacement. `T/m` is also invalid; use the bare send `(x .m)` or the
type-direct message value `Self:m`.

If no `self` binding is in scope, `(.f a b)` is a compile-time error.

### 3.1 Tail calls

Gene recognizes calls in tail position. Tail position begins at the last
expression of a function or message body and flows through selected `if`
branches, `if_yes`/`if_not` bodies, `match` arm bodies, `do` bodies, the last
operand of `&&`/`||`/`??`, and an explicit `return` value.

A tail call reuses the current VM activation when that activation has no
observable work left after the call. Self-recursive, mutually recursive,
higher-order, send, held protocol-message, and user-`Callable` chains made
entirely of such activations run in constant VM frame space. Match-arm chunks
are expression frames and are removed before the owning function is replaced.

The activation is kept when it must still adapt a return value, check a
declared `^errors` row, validate required implementations, run structured
cleanup, restore capabilities, or preserve a caller scope retained by the
callee or a bound value. A compiler-proven exact `Int`, `F64`, `Bool`, `Str`, `Nil`, `Void`, or
identity `Any` result has no dynamic return adaptation and may still be
elided. Keeping an activation is an exact semantic fallback, not an error.

Tail position does not flow through arguments, conditions, patterns, binding
initializers, loop bodies, `try`/`catch`/`ensure`, capability/task/supervisor
bodies, constructors, namespace/module bodies, `new`, or fexpr invocation.
Native and generator calls do not add an ordinary Gene bytecode frame.

Elided calls are represented in diagnostics by a bounded recent window plus an
elision count. `gene run --report_tail_fallbacks` reports once per source call
site when a marked call must keep its activation and names the reason.

MVP core special forms:

<!-- compiler-head-dispatch:start -->
```text
do if if_yes if_not && || ?? ! let var const set new .?.fn macro quote quasiquote
select path msg ns env eval import mod match while loop repeat for break continue yield
return try scope supervisor spawn await fail panic type alias enum protocol impl
derive import_impl with_capabilities web_module
```
<!-- compiler-head-dispatch:end -->

`&&`, `||`, and `!` are boolean control flow (§9), and `??` is
absence-coalescing (§1.6); `while`, `loop`, `repeat`,
`break`, and `continue` are loop control; `supervisor` owns a concurrency scope
(§13.6). Like the rest, they are reserved in head position, so `(&& ...)`,
`(while ...)`, and `(break)` always use the special-form rule and cannot be
shadowed by a binding.

Core special forms are reserved in head position. They are not ordinary bindings that `Env` can shadow. A value named `if` may exist in data or as a qualified member, but `(if ...)` always uses the special-form rule. Clause heads such as `then`, `elif`, `else`, `when`, `catch`, and `ensure` are recognized only inside their owning special form.

`path` and `msg` are the canonical reader/compiler nodes behind glued slash and
colon syntax; users normally write `a/b` and `P:m`. `ctor`, `message`, `then`,
`elif`, `else`, `when`, `catch`, and `ensure` are clause/declaration heads, not
independently dispatched core forms. `new` is a compiler-dispatched constructor
form and is reserved in head position.

`select` is special because selector bodies are quoted-like contexts: bare names become static segments, and `%` escapes to lexical values.

`with_capabilities` resolves a capability selector row against the active
context, runs its body under the resulting attenuation, and restores the
previous context on every exit path. Its full contract is in
`docs/capabilities.md`.

Normative front-end order for one read unit:

```text
read comments/discards
→ tokenize according to the reader EBNF, including slash paths and qualified-name/path tokens
→ build raw nodes
→ pipe folding
→ local reader sugars such as flags, spread markers, and interpolation
→ quasiquote/template expansion with depth tracking
→ macro expansion and special-form analysis
```

A dot descriptor is recognized only in send position: after a receiver or as
the leading head of a lexical-`self` send. The reader lowers it to the canonical
send node used by the compiler and printer. A standalone `.message` descriptor
is an error, and the removed spaced-tilde spelling is a read error with a
migration diagnostic. Resolution happens at compile/dispatch time
(`docs/core.md §9`).

---

## 4. Parameters and argument matching

Argument matching is separate from pattern matching. A function parameter vector describes call arguments, not arbitrary value shapes.

```gene
(fn draw [shape, ^color : Color = Color/red, ^width : Int = 1]
  ...)

(fn draw [shape, ^color c : Color = Color/red, ^width w : Int = 1]
  ...)
```

Rules:

```gene
name : T = default        # positional parameter
^arg : T = default        # named arg; local name is arg
^arg local : T = default  # named arg with custom local name
x...                      # gather rest positional args
x... : T                  # typed rest: each gathered arg is checked against T
```

`= default` makes a fixed parameter optional. A positional or named parameter
whose type explicitly admits nil (`T?`, `(? T)`, or a union containing `Nil`,
including aliases expanding to these forms) also has an implicit nil default.
An explicit default takes precedence; a supplied nil does not select a default.
The body receives a value inside its declared type:

```gene
width : Int?  # omitted positional argument binds width to nil
^width : Int? # omitted named argument binds width to nil
```

Optional positional parameters follow all required positional parameters and
cannot precede a rest parameter. Matching does not skip slots based on argument
types. Named parameters have no corresponding ordering restriction. `Any` alone
stays required. `T?` still means `T | Nil`; parameter binding supplies a default
for omission and does not add `Void` to that type.
Declaration names may not end in `?` — `^width? : Int` is a compile error
pointing at the `^width : Int?` spelling.

A rest parameter may carry a type: `xs... : T` gathers the trailing arguments
into a list and checks each one against `T` at the call boundary (an untyped
`xs...` admits any value). A rest parameter still takes no default.

Comma is a separator in parameter, binding, and pattern vectors. It is not a general expression separator. Commas are optional where whitespace already separates vector elements, but the formatter should choose one consistent style.

Argument matching is closed and non-backtracking: positional arity is checked, named arguments are checked, defaults are evaluated at call time, typed parameters check dynamic `Any` values at the boundary, and no pattern alternatives are involved.

---
