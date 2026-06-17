# Gene

A homoiconic, general-purpose programming language implemented in [Nim](https://nim-lang.org).

Gene has **one syntactic and semantic unit: the node**. A node can be read as
data, code, type/shape, or selector/navigation plan, so code is data and data is
code. The full language direction — callable-first evaluation, slash selectors,
streams/generators, typed recoverable errors, gradual typing, structured
concurrency, and a stable native ABI — is described in
[`docs/design.md`](docs/design.md).

> **Status: early implementation.** This repository provides the **reader**
> (parser), the **NaN-boxed value model**, the **printer** (canonical round-trip
> output), and an initial **compiler → GIR → bytecode VM** pipeline (arithmetic,
> `if`/`do`/`var`/`set`, functions, and closures). The design in
> `docs/design.md` is the target, not the current feature set. APIs and the
> language surface are unstable.

## The node

Every Gene value exposes four slots through the `Node` projection:

```text
head   singular identity / dispatch face
props  named side data, keyed by symbol  (^key value)
body   ordered positional data
meta   information about the node, ignored by value semantics  (@key value)
```

The pure projections:

```gene
42            # bare head / scalar value
[1 2 3]       # pure body / list
{^a 1 ^b 2}   # pure props / map
(t ^a 1 2 3)  # general node: head t, props {^a 1}, body [2 3]
```

Immutable literals use a `#` prefix (`#[1 2 3]`, `#{^a 1}`). Meta never
participates in equality or hashing.

## What works today

- **Reader** (`src/gene/reader.nim`) — tokenizes and parses Gene source into the
  node model: scalars, lists, maps, nodes, props/meta, immutable literals,
  string interpolation, char/selector/quote sugars, datum comments as spacing,
  and multi-form source units via `readAll`.
- **Value model** (`src/gene/types.nim`) — a 64-bit NaN-boxed `Value` (see
  [Implementation notes](#implementation-notes)).
- **Equality & hashing** (`src/gene/equality.nim`) — structural, meta-blind `=`;
  scalar/heap-aware `same?`; a matching `hash`.
- **Printer** (`src/gene/printer.nim`) — prints a value back to canonical Gene
  source that re-reads to a structurally equal value.
- **Compiler/GIR/VM** (`src/gene/compiler.nim`, `src/gene/gir.nim`,
  `src/gene/vm.nim`) — callable-first execution pipeline (design §3/§17):
  self-evaluating literals, lexical scope, `do`/`if`/`var`/`set`/`fn`/`quote`/
  `quasiquote`/`ns`/`import`/`mod`/`match`/`for`/`while`/`try`/`fail`/`type` special forms,
  nominal types
  with construction, schema validation, and single inheritance (`(type T ^props
  {…} ^is Parent)`), gradual typed-boundary checks for function parameters,
  returns, and typed construction, positional/named/rest/default function
  arguments, MVP protocol declarations with `Error`/`Send` marker protocols,
  nominal message dispatch, parent-type implementation applicability, ambiguity
  checks, `^impl` requirement checks, and protocol-local `^derive` execution,
  static and dynamic selector/slash-path access,
  functional selector updates, namespaces with qualified access, file-based
  modules (`import … from "path"`) with a load-once cache and cycle detection,
  pattern matching and destructuring (`match`, `(var [x y] …)`, `(var {^k v} …)`,
  node-shape `(Type ^k v …)`, rest patterns, `%name`, `| & not`), `for`/`while`
  loops, typed recoverable errors (`Error`, built-in `TypeError`/`MatchError`/
  `CompileError`, `fail`, `^errors`, `try/catch/ensure`), `panic`, closures,
  recursion, first-class `Cell` mutable references, quasiquote templates with runtime `unquote`/splicing, first-class `Env` values with explicit `eval node ^in env`,
  `gene run` entrypoint invocation, GIR disassembly via `gene compile`, and built-ins
  (`+ - * / < > <= >= = not head props body meta assoc-in update-in panic
  cell Cell/get Cell/set Cell/swap Cell/update print println`).

## Quick start

Requires Nim ≥ 2.0.

```bash
# Build the CLI to ./bin/gene
nimble build

# Or compile directly
nim c -o:bin/gene src/gene.nim
```

Evaluate an expression, or run a file:

```console
$ ./bin/gene eval '(+ 1 2)'
3
$ ./bin/gene eval '(var fib (fn [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))) (fib 10)'
55
$ echo '(fn main [args] (println "Hello," args/0) nil)' > demo.gene
$ ./bin/gene run demo.gene
Hello, void
$ ./bin/gene run demo.gene Gene
Hello, Gene
$ ./bin/gene compile demo.gene
constants:
  [0] "Hello,"
  ...
```

`gene parse <file>` prints the canonical parsed forms without executing them
(a read → print round-trip; props print immediately after the head). `gene
compile <file>` prints the compiled GIR bytecode without running it.

## Project layout

```text
src/
  gene.nim            CLI entry point (eval / run / parse / compile)
  gene/
    reader.nim        source text  -> node values
    types.nim         NaN-boxed Value model + constructors/accessors
    equality.nim      equal / same / hash
    printer.nim       node values -> canonical Gene source
    compiler.nim      node values -> GIR bytecode chunks
    gir.nim           bytecode instructions + function prototypes
    vm.nim            stack VM + runtime built-ins
docs/design.md        full language design (the target)
examples/web_demo.gene  end-to-end design showcase (not yet runnable)
tests/                unit tests + executable language specs
benchmarks/           release-mode core benchmarks
```

## Development

```bash
nimble test     # unit tests (tests/test_all.nim)
nimble spec     # executable language-surface specs (tracks docs/design.md)
nimble perf     # release-mode core benchmarks (smoke check, no thresholds yet)
nimble verify   # tests + specs + benchmarks
```

Performance is a first-class concern for this codebase — value layout, the
reader hot paths, and allocation behavior are treated as performance-sensitive.
See [`AGENTS.md`](AGENTS.md) for the conventions contributors and agents follow.

## Implementation notes

`Value` is a single 64-bit word using **NaN boxing** (`src/gene/types.nim`):

- Non-NaN `float64` values are stored directly.
- The all-zero bit pattern is `nil`, so a zero-initialized `Value` is `nil`.
- Reserved NaN tags encode `void` / `bool` / small-int / `char` / `+0.0` /
  symbol immediates (allocation-free), or a heap pointer for compound values
  (large ints, strings, lists, maps, nodes, functions). One tag (`0xFFFF`) is a
  generic object whose concrete kind (namespace, type, …) lives in the object
  header, so new heap kinds don't each need a NaN-box tag.

`sizeof(Value) == sizeof(uint64)`. Compound values are manually heap-allocated
with a `refCount` header; `Value`'s `=copy`/`=sink`/`=dup`/`=destroy` hooks drive
reference counting automatically, so values free at count 0 — no global table, no
per-read lock, no leak. Symbols are interned to immediate ids. Build with
`-d:geneRcStats` to expose `liveManaged` for retain/release auditing. (RC is
non-atomic for the single-threaded MVP; see `TODO(vm-shared-rc)` in
`src/gene/types.nim` for the planned per-object atomic-on-publish upgrade.)

## License

[MIT](LICENSE) © 2026 Guoliang Cao
