# Calls, selectors, control, and eval contract

**Status:** normative and implemented. Executable coverage:
`tests/spec_runner.nim`, suites “fn! runtime fexprs”, “selectors”, “pattern
destructuring”, “checked errors”, and “Env and eval”.

Calls are callable-first. Dynamic call sites resolve the callee and distinguish
ordinary `Callable` from `SyntaxCallable` before evaluating arguments. `fn!`
receives raw syntax and a borrowed `CallerEnv`; durable authority requires an
explicit named `Env/snapshot`. Message-send lexical fallback accepts ordinary
callables only and rejects syntax callables before send arguments run.

MVP compiler-dispatched heads:

<!-- compiler-head-dispatch:start -->
```text
do if if_yes if_not && || ?? ! var set ~ fn fn! macro quote quasiquote select path
ns env eval import import_impl mod match while loop repeat for break continue yield return try
scope supervisor spawn await fail panic type enum protocol impl derive
```
<!-- compiler-head-dispatch:end -->

Clause/declaration heads (`then`, `elif`, `else`, `when`, `catch`, `ensure`,
`ctor`, and `message`) are meaningful only inside their owner. `new` is an
ordinary runtime callable.

Expression paths resolve their base lexically and select later segments;
declaration/import/type contexts resolve qualified names statically. Static
scalar/key selector segments are pure. Callable, call-stage, and send segments
are executable: they are non-serializable and invalid for `assoc_in` and
`update_in`. Strict missing lookup raises `SelectorMissing` with `^segment`.
