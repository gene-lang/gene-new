# Working with Gene

## Scripts

A single file needs no package manifest. Top-level forms execute in order;
`gene run` then calls `main` when one is present:

```gene
(fn main [args]
  (let name (?? args/0 "world"))
  ($println $"Hello, ${name}!")
  0)
```

```sh
gene run hello.gene Ada
gene eval '(+ 1 2)'
```

`main` may return nil for success or an integer exit code. Program arguments
are strings; they do not carry capability grants.

## Packages

From a project directory, initialize an application package:

```sh
gene pkg init --app
```

The generated `package.gene` is a data-only manifest. A small application with
a local dependency looks like this:

```gene
{
  ^format 1
  ^name "acme/hello"
  ^version "0.1.0"
  ^applications [(application "hello" ^entry "src/main.gene")]
  ^dependencies {
    ^utils (dep "acme/utils" "0.1.0" ^path "../utils")
  }
}
```

Import through the declared dependency alias:

```gene
(import [greet] ^from "." ^pkg "utils")
```

For files within one package, use relative imports such as
`(import [greet] ^from "./greetings.gene")`.

Useful commands:

| Command | Purpose |
| --- | --- |
| `gene pkg add alias=owner/name@constraint` | Add a dependency using a configured source. |
| `gene pkg remove alias` | Remove a dependency. |
| `gene pkg resolve` | Resolve the graph and write its lock. |
| `gene pkg update` | Explicitly update unlocked choices. |
| `gene pkg sync` | Materialize locked source objects. |
| `gene pkg members`, `tree`, `why` | Inspect the workspace and graph. |
| `gene pkg vendor` | Materialize a project-local vendor store. |
| `gene pkg cache gc` | Remove unreferenced cached objects. |

Workspaces, multiple package versions, lockfiles, git/path sources, and local
registry adapters are implemented. Hosted publication is not yet available.
Runtime imports consume the resolved graph rather than performing dependency
resolution as a side effect.

## Builds

```sh
gene build hello
gene build --all --profile release --jobs 4
```

The pure-Gene build path plans target dependencies, snapshots source, and
reuses artifacts by derivation identity. `--locked` preserves the resolved
graph; `--offline` avoids fetching missing sources. `--explain` describes build
decisions.

Native/resource recipes, mixed application images, and full install/distribution
work remain incomplete. Accepting a flag or a manifest field does not imply
that every backend can build it; unsupported combinations produce diagnostics.

## Testing

```sh
gene test
gene test tests/math_spec.gene --name "adds"
gene test examples/testing_demo.gene
```

The native runner discovers `tests/**/*_spec.gene`, collects examples, and
reports assertion failures with source locations. See [testing](testing.md)
for `$assert`, `describe`, `it`, fixtures, and error assertions.

The existing manifest-driven test build workflow is available as
`gene test --package [selector]`. It builds each selected `^tests` entry and
invokes its `main`; use this mode for those package test targets.

## Editor and command-line tools

`nimble build` builds the CLI and its companion tools. If you built only
`src/gene.nim`, use `nimble tools` for the formatter, LSP, and viewer.

| Command | Use |
| --- | --- |
| `gene parse file.gene` | Inspect reader output without running it. |
| `gene fmt file.gene` | Format source. |
| `gene doc file.gene` | Inspect module declarations and metadata. |
| `gene compile file.gene` | Inspect compiled GIR. |
| `gene lsp` | Start the language server over stdio. |
| `gene view file.gene` | Open the structural source viewer. |

Use two-space indentation, snake_case names, and ordinary names for mutation
methods such as `push` or `put`. A trailing `!` is reserved for fexprs. The
[style example](../examples/style_guide.gene) is the formatter's canonical fixture.
See the [VS Code extension](../tools/vscode-extension/README.md) for editor setup.

The language server recognizes `#@greet name` like `(greet name)` for hover
and go to definition, including nested wrappers and `$` root-namespace shorthand.
Wrapped declarations appear in the outline; incomplete wrappers produce reader
diagnostics while the last valid outline stays available. Rebuild the server
with `nimble tools` and restart it in your editor after updating.

## Web applications

A standalone web-profile module can be compiled to ESM and TypeScript:

```gene
(mod browser ^profile web)
(fn double [value : Int] : Int (* value 2))
```

```sh
gene build --target web --out-dir web-out browser.gene
```

The output includes JavaScript, TypeScript declarations/source, and source
maps. Exported boundaries are validated at runtime. Int uses JavaScript bigint:

```js
import { double } from "./web-out/browser.mjs";
console.log(double(21n)); // 42n
```

| Gene | JavaScript |
| --- | --- |
| Int / F64 | bigint / number |
| Nil / Void | null / undefined |
| List | Array |
| PropMap | Object |
| Nominal type | Generated class instance |

The web profile supports annotated functions, macros, types/protocols, matching,
paths, collections, streams, a structured async subset, and checked DOM/JS
interop. Fexprs, runtime eval, actors/channels, native FFI, and VM capability
contexts remain outside it. It rejects unsupported forms rather than silently
running different semantics.

For a server and browser in one file, use `web_module`. It sees its own
compiled web unit, not surrounding server bindings such as a database handle.
The [Todo app](../examples/todo_app/src/main.gene) demonstrates the complete
route/HTML/CSS/browser flow; [web_component.gene](../examples/web_component.gene)
is a smaller browser example.

For a browser client split across Gene files, load its entry with
`($web/load "path/to/client.gene")` and pass that asset to
`($web/script asset ^mount "root")`. The entry has the same
`main [root : EventTarget] : Void` contract. `web/load` reads the import graph
under the caller's filesystem capabilities and serves only compiled Gene;
it does not admit `js/fn` imports. Generated mounts, dependencies, and source
maps are content-addressed together. The
[Harness browser client](../examples/gene-harness/README.md#browser-client)
uses this path without an authored JavaScript bootstrap or a separate bundler.

Browser bindings include `$http/request method url body headers callback`,
whose callback receives `(Int status, Str body)` including non-2xx responses;
status `0` means a transport failure. `$session_storage/get|set|remove` handles
tab-local drafts, and `$browser/origin|hash|search|replace_url|request_id|copy`
provides location, submission identity, and clipboard operations. All application
state and interaction logic can remain in Gene.

The alternative is the wasm VM. `nimble wasm` requires Emscripten and builds
the runtime for the browser. Choose it when you need the evaluator and broader
VM semantics; host facilities still depend on what the embedding provides.
The build uses a hosted startup that keeps Nim globals alive after initialization.
Run `nimble wasm` after changing value lifetimes or VM startup; it also exercises
the exported ABI through Node.

## Native interop

Call-scoped synchronous callbacks use typed native shims on the owning root
lane. SQLite `visit_text_rows` is the first library adapter. The Nim-facing
native API is version 4 and transports cancellation explicitly. See the
[callback contract](spec/modules.md#synchronous-native-callbacks) for entry,
lifetime, and failure rules.

Native extensions use opaque Gene values and explicit root handles. Managed
wrapper types own native resources; typed-native code uses explicit unboxed
representations and generated ownership adapters.

```sh
gene compile --target c examples/native/sqlite_rows.gene
nimble native_example
```

The C backend is experimental. Use the [native example](../examples/native/README.md)
for the actual compile/link/load workflow and platform prerequisites. Dynamic
FFI loading requires active `ffi/Load` permission. Admitting arbitrary native
code does not create an in-process sandbox.

## Permissions and deployment

Ordinary native CLI runs have compatibility grants for the launch directory
and built-in host facilities. Additional directory flags are host policy:

```sh
gene run --allow_read_dir /path/to/data report.gene
```

Narrow within Gene using capability rows or `with_capabilities`. Namespace
exposure, retained resource restrictions, and execution policy are separate
controls. If embedding untrusted code or plugins, read the
[authority contract](spec/authority.md) and [known limits](development.md#status)
before treating an Env or a restricted namespace as a sandbox.
