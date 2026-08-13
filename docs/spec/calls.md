# Calls, selectors, control, and eval contract

**Status:** normative and implemented. Executable coverage:
`tests/spec_runner.nim`, suites “explicit fexprs”, “selectors”, “pattern
destructuring”, “checked errors”, “Env and eval”, and “absence-guarded
sends”.

Ordinary calls are callable-first and always eager: `(foo a)` evaluates `foo`
and `a` before calling. A bare lexical head ending in `!` is the distinct,
statically resolved fexpr form: `(foo! a)` preserves `a` as syntax and supplies
the fexpr a borrowed `CallerEnv`. Define one with `(fn foo! [syntax...] ...)`;
the removed `fn!` form is invalid. Aliases, expression heads, and higher-order
ordinary calls cannot invoke a held `Fexpr`. Durable caller authority requires
an explicit named `snapshot` on `CallerEnv`. Message sends dispatch only: bare
names reach type-direct messages, `P:msg` reaches protocol impls, and dynamic
callees must be message values. Invalid callees are rejected before send
arguments run; message names may not end in `!`, and there is no lexical
callable fallback.

MVP compiler-dispatched heads:

<!-- compiler-head-dispatch:start -->
```text
do if if_yes if_not && || ?? ! let var const set new ~ ?~ fn macro quote quasiquote
select path msg ns env eval import import_impl mod match while loop repeat for break
continue yield return try scope supervisor spawn await fail panic type alias enum
protocol impl derive with_capabilities web_module
```
<!-- compiler-head-dispatch:end -->

`?~` is the absence-guarded send. It is `~` with one additional rule, applied
to the receiver only:

- the receiver is evaluated exactly once; if it is **absent** (`nil` or `void`)
  the send yields that receiver unchanged and no message is resolved, no
  argument or named-argument form is evaluated, and no impl runs;
- a present receiver takes the ordinary `~` path in full, so an unresolvable
  message is still a `MessageError` — guarding never suppresses a misspelled
  name;
- guarding is decided before message resolution, so `(nil ?~ anything)` is
  `nil` regardless of the name;
- it does not alter `~`. `Nil` remains an ordinary nominal type with no
  dispatch carve-out, `(nil ~ msg)` is still an error, and where
  `(impl P for Nil …)` exists `(nil ~ P:m)` runs it while `(nil ?~ P:m)`
  short-circuits before lookup;
- every `~` callee form is accepted — bare, `P:m`, `Self:m`, held `%m`, and a
  computed message expression — together with named arguments and spreads;
- leading `(?~ m …)` is the guarded self-send, observable where lexical `self`
  is absent, as in an `impl P for Nil` body;
- two forms are rejected: `super` is never absent, and a selector callee
  (`x ?~ /name`) is a projection rather than a send — use `??` for an
  absent-valued projection.

Clause/declaration heads (`then`, `elif`, `else`, `when`, `catch`, `ensure`,
`ctor`, and `message`) are meaningful only inside their owner. `new` is a core
form that invokes the nearest constructor in a type's ancestry.

Expression paths resolve their base lexically and select later segments;
declaration/import/type contexts resolve qualified names statically. Static
scalar/key selector segments are pure. Callable, call-stage, and send segments
are executable: they are non-serializable and invalid for `assoc_in` and
`update_in`. Strict missing lookup raises `SelectorMissing` with `^segment`.
