# Gene

A homoiconic, general-purpose programming language implemented in [Nim](https://nim-lang.org).

Gene has **one syntactic and semantic unit: the node**. A node can be read as
data, code, type/shape, or selector/navigation plan, so code is data and data is
code. The full language direction — callable-first evaluation, slash selectors,
streams/generators, typed recoverable errors, gradual typing, structured
concurrency, and a stable native ABI — is described in
[`docs/design.md`](docs/design.md).

> **Status: early implementation.** This repository currently provides the
> **reader** (parser), the **NaN-boxed value model**, and the **printer**
> (canonical round-trip output). There is **no evaluator/VM yet** — the design
> in `docs/design.md` is the target, not the current feature set. APIs and the
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

## Quick start

Requires Nim ≥ 2.0.

```bash
# Build the CLI to ./bin/gene
nimble build

# Or compile directly
nim c -o:bin/gene src/gene.nim
```

The CLI reads a `.gene` file and prints each parsed form in canonical form
(a read → print round-trip):

```console
$ echo '(print "hello" ^times 3 [1 2 3] {^k 1})' > demo.gene
$ ./bin/gene demo.gene
(print ^times 3 "hello" [1 2 3] {^k 1})
```

(Props are printed immediately after the head, ahead of the body — hence the
reordering above.)

## Project layout

```text
src/
  gene.nim            CLI entry point (read → print)
  gene/
    reader.nim        source text  -> node values
    types.nim         NaN-boxed Value model + constructors/accessors
    equality.nim      equal / same / hash
    printer.nim       node values -> canonical Gene source
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
- Reserved quiet-NaN payloads encode `void` / `bool` / small-int / `char`
  immediates, or a handle into a process-local heap table for compound values
  (large ints, strings, symbols, lists, maps, nodes).

`sizeof(Value) == sizeof(uint64)`. Scalar paths stay allocation-free where
possible. The heap table is currently append-only and handle-indirected; a
non-moving arena with reclamation is planned before the VM allocates in hot
loops (see the `TODO(vm-memory)` note in `src/gene/types.nim`).

## License

[MIT](LICENSE) © 2026 Guoliang Cao
