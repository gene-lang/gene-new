# Gene style guide

This guide defines the canonical source style for Gene code in this repository.
It complements the language contract in [`docs/spec/`](spec/README.md): the
specification says what a program means; this guide says how humans and
`gene fmt` should present it.

The executable reference is [`examples/style_guide.gene`](../examples/style_guide.gene).
The file is deliberately broad and must satisfy this byte-for-byte contract:

```sh
gene fmt examples/style_guide.gene
```

The command prints exactly the existing file, including its final newline.
Tests enforce that contract. When formatter policy changes intentionally,
update this guide, the example, and the formatter test together.

## General layout

- Indent with two spaces. Never use tabs or align code with runs of padding.
- Keep a simple expression on one line when it remains easy to scan.
- Once a form wraps, indent each body expression one level from its owner.
- Put closing delimiters after the final value; do not leave them on a line by
  themselves unless an embedded multiline value requires it.
- Separate top-level declarations into short conceptual sections. Use one
  blank line between declarations and section comments for long modules.
- Prefer a maximum line width of 100 columns. A long string or URL may exceed
  it when splitting would obscure the value.

Declarations use one indentation level for a wrapped value:

```gene
(var result
  (build_result input options))

(fn render [value : Any] : Str
  (to_str value))
```

Do not double-indent the value:

```gene
# Wrong
(var result
    (build_result input options))
```

## Conditional forms

Use compact `if` for expression-sized branches. An `if` with both results is
always multiline: keep only the condition on the opening line and put both
results at the same indentation:

```gene
(if (request_succeeded? response)
  (decode_response response)
  (transport_error response))
```

Use `if_yes` and `if_not` for guard bodies. Their whole tail is already an
implicit sequence, so a `do` wrapper is redundant:

```gene
(if_yes ready?
  (record_start)
  (run_job))

(if_not cached?
  (load_value)
  (save_cache))
```

Write a single-expression one-sided condition as `(if cond value)`. Do not add
an explicit trailing `nil`. Write `if_not` instead of `(if cond nil value)`.

When both branches contain multiple expressions, use full clauses. Clause
bodies are one level deeper than `then`, `elif`, or `else`:

```gene
(if ready?
  (then
    (record_start)
    (run_job))
  (elif retryable?
    (record_retry)
    (retry_job))
  (else
    (record_skip)
    nil))
```

Prefer `elif` over an `else` whose only expression is another `if`. This keeps
long dispatch chains at one indentation level.

`do` remains useful when an expression position genuinely needs one grouped
sequence. Function bodies, loop bodies, `if_yes`/`if_not` tails, and full
conditional clauses already accept sequences and do not need it.

## Functions, loops, matching, and errors

Keep a function's name, parameter vector, optional return type, and short
metadata on its opening line when they fit. Indent every body expression two
spaces:

```gene
(fn collect [items : (List Any), ^limit : Int = 10] : (List Any)
  (var output [])
  (for item in items
    (if_yes (< output/~size limit)
      (output ~ List/push! item)))
  output)
```

The indexed loop keywords stay together. Match and error clauses align under
their owner, and their bodies indent once:

```gene
(repeat index in count
  (visit index))

(match value
  (when (Ok result)
    result)
  (when (Err error)
    (handle error))
  (else
    nil))

(try
  (read_value)
catch (ParseError ^message message)
  (report message)
catch _
  nil
ensure
  (close_input))
```

Use early `return`, `break`, and `continue` when they remove deep nesting.

## Collections, nodes, and calls

Keep small collections and nodes on one line. For a multiline collection, use
one value or coherent short group per line, indented one level:

```gene
[1 2 3]
{^name "Ada" ^active true}
(user ^name "Ada" ^^active)

[
  (user ^name "Ada" ^^active)
  (user ^name "Grace" ^^active)]
```

Properties and metadata belong near the node head. Prefer flag sugar
(`^^active`, `@@generated`) for true-valued props and metadata. Preserve the
semantic distinction between mutable and shallow-immutable literals:
`[...]`/`{...}`/`(...)` versus `#[...]`/`#{...}`/`#(...)`.

Use receiver syntax when it reads as an operation on the receiver, and slash
paths for static navigation:

```gene
(items ~ List/push! value)
session/user/name
session/items/-1
```

For a long call, keep the callee on the opening line and indent arguments one
level. Do not vertically align arguments with arbitrary spaces.

## Syntax-facing code

Use quasiquote and unquote sugar in macros and data templates:

```gene
(macro unless! [condition, body...]
  `(if_not %condition %body...))
```

Use commas consistently in parameter, binding, and pattern vectors. The
formatter treats commas as separators, not general expression punctuation.
Names use `snake_case`; a trailing `!` identifies visible mutation or syntax
behavior, and a trailing `?` identifies predicates.

## Comments and formatter boundaries

Explain intent and invariants, not obvious mechanics. Put a space after `#`.
Use `#< ... >#` for block comments and `#_` only to discard the next datum.

The reader currently drops comments inside a parsed form. To avoid deleting
them, `gene fmt` preserves any form containing an interior comment verbatim.
Code around such comments must therefore already follow this guide. Top-level
comments and blank-line section breaks are normalized and preserved.

`gene fmt` is a layout formatter, not a semantic rewriter. It will not replace
`(if cond (do ...))` with `if_yes`, introduce `elif`, rename bindings, or choose
between equivalent APIs. Authors make those idiomatic transformations; the
formatter then makes their layout canonical.
