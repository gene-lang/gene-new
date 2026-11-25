# Tools

This chapter covers the `gene` command, the tools for inspecting code, editor
support, and logging.

## The gene command

| Command | What it does |
| --- | --- |
| `gene run file.gene [args…]` | runs a file, then its `main` ([Getting started](getting_started.md)) |
| `gene eval "source"` | evaluates source and prints the last value |
| `gene repl` | reads, evaluates, and prints lines from standard input |
| `gene test [paths…] [--name text]` | runs `*_spec.gene` examples ([Testing](testing.md)) |
| `gene pkg …` | manages dependencies and the lock ([Modules and packages](modules.md)) |
| `gene build`, `gene install` | build and install package targets ([Native code, builds, and deployment](native.md)) |
| `gene build --target web` | compiles a web-profile module to JavaScript ([Gene on the web](web.md)) |
| `gene doc file.gene` | prints a module's doc, imports, and declarations |
| `gene parse file.gene` | prints the forms the reader produces |
| `gene compile file.gene` | prints the compiled bytecode |
| `gene lsp` | runs the language server over standard input and output |
| `gene view file.gene` | opens a structural viewer for source or serialized data |

`gene --help` lists every command and option, and `gene --version` reports
the build: release or debug, platform, and runtime checks.

## Inspecting code

`gene doc` reads a module without running it:

```sh
gene doc greet.gene
# Module: greet
# Doc: Greetings.
# Declarations:
# - hello : Fn
```

`gene parse` shows what the reader made of a file, with shorthand expanded.
It is useful when a form does not mean what it seems to:

```sh
gene parse greet.gene
# (fn @doc "Say hello." hello [name : Str] : Str ((path gene to_str) "Hello, " name))
```

From inside a program, `$runtime/signature` describes a function or type
([Documenting a function](functions.md#documenting-a-function)), and
`$runtime/messages` lists the messages a value answers.

## Editors

`gene lsp` speaks the Language Server Protocol, for diagnostics, outline,
and hover in any editor that supports it. `gene view` opens a terminal view
of a file's structure: move through forms, preview values, and hand off to
an external editor. For a `(serde_v1 …)` data file it opens at the data
itself, and `--path` jumps to a path inside it.

## Logging

`$log` writes structured log records. A logger has a name, and each record a
level, a message, and an optional payload:

```gene
(import $log [log_debug new_logger])
(let logger (new_logger "app/demo" ^payload {^component "example"}))
(logger .info "ready" ^payload {^items 3})
(logger .warn "disk almost full")
(log_debug logger $"details: $(expensive_summary)")
```

- A logger's name sits under `app/`, as in `app/demo`. `(new_logger "demo")`
  fails with `log/new_logger names must be in the app/* namespace`.
- With no configuration, records at `warn` and above go to standard error,
  one Gene data record per line (`^schema "gene.log.v1"`), with the time,
  level, logger, message, payload, and source location.
- `gene run --log-config path` selects routes and levels.
- Level messages, such as `.info`, evaluate their arguments right away. The
  `log_*` macros, such as `log_debug`, skip evaluating the message and
  payload when the level is off, so expensive details cost nothing.

An application configures where logs go. A library should take or create a
named logger, never configure routes.
