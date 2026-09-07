# Runtime representation, CLI, and tooling

**Status:** detailed design reference and rationale. The implemented contracts
are [modules](../spec/modules.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 17. Runtime and representation

The v1 VM direction is retained and extended with mixed execution:

- bytecode compiler and stack VM;
- computed-goto dispatch where available;
- `NativeFn` and native extension entry points;
- optional AOT-compiled typed functions/modules;
- generated dynamic/typed ABI adapters;
- a VM-entry trampoline allowing native code to call bytecode or dynamic Gene callables;
- NaN-boxed values for compact dynamic representation;
- heap objects for nodes, strings, streams, closures, applications, packages, modules, namespaces, `Env` values, eval overlays, tasks, channels, actors, mailboxes, and boxed immediates with meta;
- cooperative fibers and an experimental bounded worker lane; production M:N
  scheduling remains future work.

Runtime diagnostics may expose read-only GC/RC counters such as
`$runtime/gc_stats` so optimization and custom-GC work can be tested without
exposing object layouts.

`Any` uses dynamic representation. Type annotations enable optimization later: sealed layouts, unboxed fields, and specialized generic instantiations are post-MVP optimizations.

`^sealed` is reserved for a later optimization promise: a type's instance layout is closed enough for flat representation. It is not required in MVP.

---

## 18. CLI and tooling

MVP CLI:

```text
gene run
gene eval
gene repl
gene parse
gene compile
gene fmt
gene doc
gene pkg
gene view
```

`gene run path.gene args...` creates an `Application`, loads the entry package/module, executes the entry module top to bottom, and calls `main` with command-line arguments if present. The experimental `gene runurl <https-url>` runs a remote entry module under the URL-module rules of §15.9 and folds into `gene run` once stable.

Every command that creates an `Application` — `run`, `runurl`, `eval`, `repl`,
`compile`, `build`, `doc`, `pkg` — determines its package context the same way
(§15.3) and preserves the process working directory. Pure reader commands
(`parse`, `fmt`) have no package context.

`fmt`, `lsp`, and `view` are **delegating subcommands**: the `gene` binary
resolves a sibling executable (`gene-fmt`, `gene-lsp`, `gene-viewer`) next to
itself, then on `PATH`, and `execv`s it with the remaining arguments. The
formatter, language server, and structural viewer are tools rather than
runtime, and keeping them out of the `gene` binary is what removes the
formatter, the LSP analyzer, the structural index, and the viewer from every
Gene process. Because `execv` replaces the process, the tool inherits stdio,
the controlling terminal, and signal disposition directly, and its exit code
is the command's exit code.

The consequence is a distribution requirement: **`gene` alone does not provide
`fmt`, `lsp`, or `view`.** A packaged installation ships the tool binaries
alongside it. When one is missing, the subcommand fails with a message naming
both locations it searched.

For the same reason there is no `format` function in `gene/parse`: canonical
formatting is reachable through `gene fmt`, not from inside a running program.

`gene pkg` manages the source graph without executing package module bodies:

```text
gene pkg init --lib|--app|--mixed
gene pkg add <alias>=<owner/name>@<constraint>
gene pkg remove <alias>
gene pkg resolve|update|sync
gene pkg members|tree|why
gene pkg vendor
gene pkg cache gc
```

`resolve` writes the workspace lock; `sync` materializes immutable source
objects. `publish` currently reports that a registry adapter is required.
The prototype `show`, `locate`, `graph`, and `pkg install` commands are removed.
See [packages](../packages.md) and [package builds](../package-builds.md).

`gene eval` creates or reuses an application/runtime context, parses the supplied source as an eval module-like unit, evaluates it in an explicit or CLI-created `Env`, and prints the final result when appropriate.

`gene repl` retains a garbage-collected session environment and evaluation overlays across inputs.

`gene parse` and `gene fmt` operate on modules/source units but do not execute top-level forms.

`gene view [options] path.gene` opens a native, non-evaluating structural
browser over reader-owned source spans. Navigation paths use ordinary static
Gene slash segments. External-editor handoff is the initial write path;
`--readonly` disables it. The viewer must restore terminal state on exit and
must not reconstruct the file by printing runtime Values.

`gene fmt` uses the human source formatter and must round-trip selector slash
spacing, immutable-literal prefixes, prop order, meta order, import forms,
namespace forms, and pipe sugar reliably. `docs/style.md` defines the canonical
layout and idioms. `examples/style_guide.gene` is the broad executable fixture:
formatting it must reproduce the file byte for byte.

Prop print order should be deterministic. MVP recommendation: preserve source order when available; otherwise sort by symbol text for stable generated output.

---
