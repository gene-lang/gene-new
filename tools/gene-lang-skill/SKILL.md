---
name: gene-lang
description: Write, run, and debug Gene source (.gene files). Use when writing or changing Gene code, when a Gene construct's spelling is uncertain, or when diagnosing a Gene reader or runtime error.
---

# Writing Gene

Gene is homoiconic and Lisp-shaped, so Lisp priors fire — and most of them are
wrong here. `(println …)` is an undefined symbol. Eager and lazy collections
share map operations, with explicit consumption for streams.
`(foo ^k 1)` in code position is a call, not data. Guessing produces code that
reads plausibly and does not run.

Start from documented patterns and persist a small working version early.
Verify the actual implementation with execution and focused tests. Use an
isolated probe when a specific uncertainty blocks the next implementation
step; batch independent probes and reuse their results.

## Probe

`./bin/gene eval '<source>'` evaluates and prints. It is the whole loop — sub-second,
no file needed for an expression. Imports require a source file run with
`gene run`. Build the binary first with `nimble build` if `bin/gene` is absent.

```console
$ ./bin/gene eval '($println (([1 2 3] .to_stream) .into []))'
[1 2 3]
```

Probe the *shape* that blocks the next change. A successful run or test of the
working implementation also verifies the constructs it exercises. Convert
useful probes into regression tests as the implementation grows.

In a multi-turn Harness session, group relevant documentation reads and
independent checks in one response. Aim for a minimal runnable artifact after
roughly 2–3 preparation turns when feasible. Further exploration should answer
a concrete implementation question or test failure.

The rest of the surface:

| Command | Use |
|---|---|
| `./bin/gene run f.gene [args…]` | Run top level, then call `main`. Positional args arrive as a node — `args/0` is the first. |
| `./bin/gene fmt f.gene` | Canonical layout. Doubles as a syntax check, and shows you the idiomatic spelling of what you wrote. |
| `./bin/gene parse f.gene` | What the reader actually built. Reach for it when a form means something you did not intend. |

**Completion criterion:** the finished implementation runs and focused tests
exercise its intended behavior and relevant failure cases. Use documented
patterns for routine constructs and targeted probes for remaining blockers.
Adopt canonical `gene fmt` output and check second-pass idempotence; formatting
is behavior-preserving.

## The rules that catch most errors

**`$` reaches the standard library.** `$x` is sugar for `gene/x`. Lowercase
library functions and namespaces need it; uppercase types are bare, because
type annotations resolve structurally.

```gene
($println ($str/join names ", "))   # library function
(fn f [x : Int] : Str …)            # types stay bare
```

**Prefer `receiver/.message` for a send with no arguments.** Rewrite
`(a .x)` as `a/.x` when the receiver is a simple symbol or path, including
`resource/.IoResource:close` for a qualified send. With arguments, use
`(receiver .message args…)`. Literal/computed receivers and parent dispatch
keep their explicit sends: `([1 2] .size)`, `((make_a) .x)`, `(super .x)`.
Preserve quoted syntax as data. Chain with a leading `;` on continuation lines.

```gene
(var n xs/.size)
(xs .push value)
(xs
  .to_stream
  ; .filter (fn [x] (> x 1))
  ; .into [])
```

`(a/.b c)` is not a shortcut for `(a .b c)` — it means `((a .b) c)`, a
zero-argument send whose result is then called.

**`->` sequences an incoming value before the next eager call.** With no direct
`_`, the value becomes the first positional argument. One direct `_` may put it
in the head, body, or a property value; nested `_` is ordinary nested syntax.

```gene
(source
  -> parse options
  -> validate schema
  -> save db _)

(value -> _ .render options)      # dot-send the threaded value
```

The first form has the call shape `(save db (validate (parse source options)
schema))`, but `source` is guaranteed to finish before `parse` is evaluated.
The value in front of the first `->` is one form: write `((read path) -> parse)`,
not `(read path -> parse)`.

**`=>` runs its stage per item.** The item, not the collection, fills the slot,
and the stage's callee and other arguments are evaluated once before iterating.
Every `=>`, including a final stage, returns a lazy Stream. Use `$into` to
collect or `$each` to drain effects; constructing a pipeline does not run it.

```gene
(rows => save)                              # lazy; no save calls yet
(rows -> $each save)                        # immediate effects; nil
(rows => parse -> $into [])                 # lazy through parse; into collects
(producer => step -> $take 5 -> $into [])   # endless producer, bounded result
```

`->` and `=>` mix freely; neither mixes with `;` at the same parenthesis depth.

**Sends dispatch only.** A bare name reaches a type-direct message; `P:msg`
reaches a protocol impl. There is no lexical callable fallback, so a function
in scope is invisible to a dot send.

**Collection operations have eager and lazy forms.** Map/filter/filter_map
accept eager collections and streams. Map normalizes void to nil; filter_map
drops only void. `to_stream` creates a cursor and `into` consumes it.

**One-sided conditions omit the else arm.** `(if cond value)` already yields
`nil` on the false path. Use `(if_not cond body…)` and `(if_yes cond body…)`
for guards — their tails are implicit sequences, so a `do` wrapper is
redundant. Reserve `then`/`elif`/`else` for branches that all do real work.

**Only `nil`, `false`, and `void` are falsy.** `""`, `0`, and `[]` are truthy,
so test emptiness explicitly: `(== s "")`, `xs/.empty?`, `($absent? v)`.

**Boolean operators are `&&`, `||`, and `!`.** Write `(&& ready valid)`,
`(|| empty missing)`, and `(! done)`. Bare `and` and `or` are not boolean
operators.

**Node literals are data only under quote.** In code position `(foo ^k 1 2)`
is a call. Write `(quote (foo ^k 1 2))` or `` `(foo ^k 1 2) `` for the node.

**Every name is `snake_case`.** A trailing `!` marks a fexpr call, a trailing
`?` a predicate; `-` never appears in a registered name.

## Reference

In Gene Harness, use `(doc "gene/syntax")`, `(doc "gene/declarations")`,
`(doc "gene/control_flow")`, `(doc "gene/stdlib")`, and `(doc "gene/pitfalls")`.
The relative links below name repository files; Harness chapter names use the
short `gene/...` names above. For a first UI plugin, use
`(doc "harness/ui/quickstart")`.

Load by branch — each file is self-contained:

- [`reference/syntax.md`](reference/syntax.md) — literals, nodes, props/meta, paths, selectors, interpolation, spread, destructuring.
- [`reference/declarations.md`](reference/declarations.md) — `fn`, fexprs, `macro`, `type`, `enum`, `protocol`/`impl`, `ns`, `mod`, `import`, `main`.
- [`reference/control-flow.md`](reference/control-flow.md) — conditionals, loops, `match`, checked errors, streams and generators, tasks and channels.
- [`reference/stdlib.md`](reference/stdlib.md) — the namespace inventory and the message surface of every built-in type.
- [`reference/pitfalls.md`](reference/pitfalls.md) — error message → cause → fix. Read this first when a probe fails.

In the repository itself:

- `examples/style_guide.gene` — every everyday construct, formatted canonically. The most reliable source to copy a spelling from.
- `docs/spec/` — normative contract for the implemented surface, split by subsystem.
- `docs/language.md` — the current language guide.
- `docs/workflows.md` — tools, project organization, and formatting conventions.

Changing the *implementation* (Nim under `src/`) rather than writing Gene is a
different job with different gates — `AGENTS.md` governs it.
