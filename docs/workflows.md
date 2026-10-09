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

`gene eval` accepts the same imports as a file module. It treats the supplied
source as an in-memory module located in the current working directory, so
`^from "./helper"` loads `helper.gene` there, including exported macros and
wildcards. No source file is created. The current directory is its ad-hoc
package boundary. Language-level `(eval …)` and the REPL retain their separate
Env-based import rules.

`main` may return nil for success or an integer exit code. Program arguments
are strings.

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
| `gene pkg publish --registry-config <path> --signing-key <file>` | Sign and stage a local package release, then publish its immutable version. |
| `gene pkg cache gc` | Remove unreferenced cached objects. |

Workspaces, multiple package versions, lockfiles, git/path sources, and local
registry adapters are implemented. Experimental hosted resolution and sync
use `gene pkg resolve --registry-config <path>` and
`gene pkg sync --registry-config <path>` with an operator-pinned key. Keep the
same config for offline sync so cached signatures are rechecked. See the
[release format and config](spec/package-release.md). The publish client is
experimental; a deployable hosted registry service is not yet included.
`gene build`, project `gene run`/`test`, and `gene install` accept the same
`--registry-config` for hosted dependencies.
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

Native recipe qualification, mixed application images, and hosted distribution
work remain incomplete. Resource recipes and local POSIX installation are
available for the qualified source profile. Experimental `native_binary`
and `c_library` recipes can verify, build, and install C ABI libraries.
Accepting a flag or a manifest field does not imply
that every backend can build it; unsupported combinations produce diagnostics.

## Local native installation

On POSIX hosts, a locked local application with pure Gene sources and a
selected `resources` recipe can be installed to a separate prefix:

```sh
gene pkg resolve
gene install my_app --prefix "$HOME/.local" --package-root .
"$HOME/.local/bin/my_app"
gene uninstall owner/name:my_app --prefix "$HOME/.local"
```

`gene install` uses the lock offline, stages a copy of the selected package
closure and Gene executable, verifies an offline build, then switches the
launcher to the complete generation. It retains prior generations on update.
The launcher pins its generation for its whole run, so uninstall leaves a
generation in place while a process still uses it; rerun uninstall to reclaim
it later. The package source checkout and user package cache are not needed
for the installed CLI. Packaged genex binding qualification, hosted release selection,
Windows installation, and system-service integration remain separate stages.

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

`nimble build` builds the CLI and its companion tools in portable release
mode. Use `nimble debug` for an instrumented build, and `gene --version` to
inspect the current binary. If you built only
`src/gene.nim`, use `nimble tools` for the formatter, LSP, and viewer.

| Command | Use |
| --- | --- |
| `gene parse file.gene` | Inspect reader output without running it. |
| `gene fmt file.gene` | Format source. |
| `gene doc file.gene` | Inspect module declarations and metadata. |
| `gene compile file.gene` | Inspect compiled GIR. |
| `gene lsp` | Start the language server over stdio. |
| `gene view file.gene` | Open the structural source viewer. |

For a `(serde_v1 …)` file, `gene view` opens at the data payload instead of
the serialization envelope. Lists and maps remain navigable, and escaped
`serde_map`, `serde_set`, and `serde_data_node` forms expose their logical
children. The bottom preview shows the selected source value; press `v` for a
scrollable full-value view, then `v` or Escape to return. `--path` selects a
data path (for example `--path 12/payload/name`); keys containing spaces or
slashes can use existing Gene string syntax, such as
`--path '(path 12 "odd key")'`. Use `--raw` to inspect the envelope and
encoding tags as ordinary source. This view only reads source; it does not
deserialize or execute stored values.

Use two-space indentation, snake_case names, and ordinary names for mutation
methods such as `push` or `put`. A trailing `!` is reserved for fexprs. The
preferred spelling for a zero-argument send is `a/.x` rather than `(a .x)`
when the receiver is a simple symbol or path. Sends with arguments, computed
receivers, and `super` keep the explicit form. Preserve quoted syntax values.
The [style example](../examples/style_guide.gene) is the formatter's canonical fixture.
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
interop. Fexprs, runtime eval, actors/channels, and native FFI remain outside
it. It rejects unsupported forms rather than silently running different
semantics.

For a server and browser in one file, use `web_module`. It sees its own
compiled web unit, not surrounding server bindings such as a database handle.
The [Todo app](../examples/todo_app/src/main.gene) demonstrates the complete
route/HTML/CSS/browser flow; [web_component.gene](../examples/web_component.gene)
is a smaller browser example.

For a browser client split across Gene files, load its entry with
`($web/load "path/to/client.gene")` and pass that asset to
`($web/script asset ^mount "root")`. The entry has the same
`main [root : EventTarget] : Void` contract. `web/load` reads the import graph
and serves only compiled Gene; it does not admit `js/fn` imports. Generated
mounts, dependencies, and source maps are content-addressed together. The
[Harness browser client](../examples/gene-harness/README.md#browser-client)
uses this path without an authored JavaScript bootstrap or a separate bundler.

A server-rendered page can also be exported to a static host. Choose its public
asset location with `($web/set_asset_base "/docs/assets")`, render the page,
then write each entry of `($web/published_routes)` under that location. Entries
are `{^file ^content_type ^body ^source_map}` maps sorted by file name, and
match what the application's HTTP server answers, including the
`$web/set_source_maps` policy. Asset URLs are absolute, so build one export per
base path. The
[Harness website exporter](../examples/gene-harness/src/website/export.gene)
is a complete example.

Browser bindings include `$http/request method url body headers callback`,
whose callback receives `(Int status, Str body)` including non-2xx responses;
status `0` means a transport failure. `$session_storage/get|set|remove` handles
tab-local drafts, and `$browser/origin|hash|search|replace_url|push_url|request_id|copy`
provides location, submission identity, and clipboard operations. All application
state and interaction logic can remain in Gene.

Use `$event/code` with `$event/ctrl_key|shift_key|alt_key|meta_key` for physical
keyboard shortcuts; `$event/repeat` and `$event/is_composing` allow handlers to
ignore repeated/composing input. `$dom/focused? element` checks focus before
replacing a view. `$browser/push_url` adds a history entry; register a `popstate`
listener on `$dom/window` to restore local navigation without reloading.
`$dom/add_event_listener` and `$dom/remove_event_listener` accept `^capture true`
for host-level controls that must run before a focused widget handles an event;
use the same capture flag and callback identity when removing a listener.

For incremental DOM updates, `($dom/insert_at parent child index)` inserts or
moves a node at a zero-based child position, preserving focus and text selection
inside a retained node. `($dom/remove node)` detaches it if attached.
`($dom/remove_attribute element name)` removes an attribute, and
`($dom/set_style element name value)` sets one CSS property (including custom
properties); an empty value removes it. Typed function fields can be called
through paths, such as `(controller/send payload)`, with the callee evaluated
before the argument expressions.

The alternative is the wasm VM. `nimble wasm` requires Emscripten and builds
the runtime for the browser. Choose it when you need the evaluator and broader
VM semantics; host facilities still depend on what the embedding provides.
The build uses a hosted startup that keeps Nim globals alive after initialization.
Run `nimble wasm` after changing value lifetimes or VM startup; it also exercises
the exported ABI through Node.

For a fresh isolated artifact with shared value-operation and lifetime checks,
follow the [wasm qualification audit](profiles/native-app.md#wasm-and-backend-parity).
Its browser driver is Gene; the same host-side checks run in Node and Chromium.
This leaves the tracked playground artifact untouched until it is regenerated
deliberately with `nimble wasm`.

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
for the actual compile/link/load workflow and platform prerequisites.
The experimental generated C API uses checked status plus out-result calls
and `GeneNativeError` diagnostics. AOT manifest version 2 requires rebuilding
older libraries; native field-layout fingerprinting remains version 1.
Admitting arbitrary native code does not create an in-process sandbox.

## Permissions and deployment

`gene run` and `gene eval` run with the permissions of the invoking user; Gene
has no ambient permission system. Namespace exposure and execution policy are
separate controls: the sandbox loader (`$runtime/load_sandboxed`) exposes only
the namespaces a module is granted, and `^policy` limits bound steps, memory,
and time. If embedding untrusted code or plugins, read the
[known limits](development.md#status) before treating an Env or a restricted
namespace as a sandbox.
