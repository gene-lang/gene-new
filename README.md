# Gene

A homoiconic, general-purpose programming language implemented in [Nim](https://nim-lang.org).

Gene has **one syntactic and semantic unit: the node**. A node can be read as
data, code, type/shape, or selector/navigation plan, so code is data and data is
code. The full language direction — callable-first evaluation, slash selectors,
streams/generators, typed recoverable errors, gradual typing, structured
concurrency, and a stable native ABI — is specified under
[`docs/spec/`](docs/spec/README.md). [`docs/design.md`](docs/design.md) retains
architecture, rationale, and deferred directions.

> **Status: active implementation.** APIs and the language surface are still
> evolving. What is implemented today is summarized in
> [`docs/implementation-status.md`](docs/implementation-status.md) and locked by
> `nimble spec`.

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

## Highlights

- **Callable-first VM** — lexical scope, closures, pattern matching and
  destructuring, namespaces, and file-based modules.
- **Gradual nominal types** — schema-validated construction, single
  inheritance, and checked boundaries for parameters, returns, and numeric/C
  ABI values.
- **Protocols** with nominal dispatch, scoped visibility, and `derive`.
- **Typed recoverable errors** — `fail`, `^errors` rows, `try/catch/ensure`,
  kept distinct from `panic`.
- **Streams and generators** as lazy pull combinators; a function containing
  `yield` returns a stream.
- **Structured concurrency** — tasks, channels, and actors under supervising
  scopes. Still experimental (see below).
- **A batteries-light stdlib** — `html`/`css`/`url`/`json`, an event-loop HTTP
  server and client, SQLite/Postgres behind one `Db` protocol, serialization,
  durable stores, and structured logging.
- **Compile to the browser** — `gene build --target web` emits readable
  TypeScript/ESM from a statically decidable subset, and an embedded
  `web_module` block lets one source file carry a page's server logic, HTML,
  CSS, and browser behavior with no build step or bundler.
- **Native interop** — a Nim-facing native API, runtime FFI, and an
  experimental typed C backend.
- **Tooling** — `repl`, `fmt`, `doc`, `compile`, a structural `view` browser,
  an LSP server, and a wasm build of the VM.

> **Concurrency is experimental.** Tasks run on a cooperative scheduler by
> default: fibers yield at VM safepoints, and channel operations, actor
> mailboxes, `await`, and `sleep` park only the current task. Threaded
> `--mm:atomicArc --threads:on` builds can additionally run snapshot-isolated
> tasks and sendable actor turns on a bounded worker lane (`GENE_WORKERS=N`).
> Production M:N lifecycle and load balancing, broader async-I/O backends, and
> stable concurrency semantics are not built yet.

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
$ echo '(fn main [args] ($println "Hello," args/0) nil)' > demo.gene
$ ./bin/gene run demo.gene Gene
Hello, Gene
```

Three larger programs worth reading:
[`examples/style_guide.gene`](examples/style_guide.gene) is an end-to-end language
showcase, and [`examples/todo_app/src/main.gene`](examples/todo_app/src/main.gene)
is a complete web application — routes, SQLite, HTML, CSS, and browser
behavior — in one file. [`examples/cordis`](examples/cordis) is a tested
Gene-native plugin runtime with spatial services, deterministic effects,
sandboxed composition, and recoverable hot reload.

### Other commands

| Command | What it does |
|---|---|
| `gene parse <file>` | Canonical parsed forms, without executing |
| `gene fmt <file>` | Human-oriented formatter ([`docs/style.md`](docs/style.md)) |
| `gene compile <file>` | Compiled GIR bytecode, without running |
| `gene doc <file>` | Module metadata, imports, and declarations |
| `gene build --target web <file>` | TypeScript/ESM for the browser |
| `gene view <file>` | Structural source browser; `e` opens `$EDITOR` in place |

## Project layout

```text
src/
  gene.nim            CLI entry point
  gene/
    reader.nim        source text  -> node values
    printer.nim       node values  -> canonical Gene source
    types.nim         NaN-boxed Value model + constructors/accessors
    equality.nim      equal / same / hash
    compiler.nim      node values  -> GIR bytecode chunks
    gir.nim           bytecode instructions + function prototypes
    vm.nim            stack VM + runtime
    stdlib.nim        standard-library surface
    http_server.nim   event-loop HTTP/WebSocket server
    web.nim           the `web` profile: Gene -> readable TypeScript
    native_api.nim    Nim-facing native/FFI boundary
    lsp/ tui/ viewer/ editor and terminal front ends
docs/spec/            normative implemented language contract
docs/design.md        architecture, rationale, and deferred directions
examples/             runnable programs, including the showcase and todo app
tests/                unit tests + executable language specs
benchmarks/           release-mode core benchmarks
```

## Development

```bash
nimble test        # unit tests
nimble spec        # executable language-surface specs (tracks docs/spec/)
nimble transpile_spec  # shared VM/web-profile conformance fixtures
nimble perf        # release-mode core benchmarks (smoke check, no thresholds)
nimble wasm        # wasm host-ABI build (requires emcc)
nimble leakcheck   # refcount/scope leak assertions
nimble threadcheck # threaded atomicArc smoke checks
nimble verify      # everything above
```

Performance is a first-class concern — value layout, reader hot paths, and
allocation behavior are treated as performance-sensitive. See
[`AGENTS.md`](AGENTS.md) for the conventions contributors and agents follow.

## License

[MIT](LICENSE) © 2026 Guoliang Cao
