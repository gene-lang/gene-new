# Tools

This chapter covers the `gene` command, the tools for inspecting code, editor
support, and logging.

## The gene command

| Command | What it does |
| --- | --- |
| `gene run file.gene [args…]` | runs a file, then its `main` ([Getting started](getting_started.md)) |
| `gene eval "source"` | evaluates source and prints the last value |
| `gene repl` | evaluates input in a session that keeps its bindings |
| `gene test [paths…] [--name text]` | runs `*_spec.gene` examples ([Testing](testing.md)) |
| `gene pkg …` | manages dependencies and the lock ([Modules and packages](modules.md)) |
| `gene build`, `gene install` | build and install package targets ([Native code, builds, and deployment](native.md)) |
| `gene build --target web` | compiles a web-profile module to JavaScript ([Gene on the web](web.md)) |
| `gene doc file.gene` | prints a module's doc, imports, and declarations |
| `gene doc build [dir]` | builds the documentation corpus under `build/docs/` |
| `gene doc index` | prints the corpus index (`llms.txt`) |
| `gene doc show <id or name>` | prints one page; `$str/join` and `lib/gene/str/join` both work |
| `gene doc ls [id]` | lists a page's children with their sizes |
| `gene doc search <text>` | full-text search over the pages |
| `gene doc skill` | regenerates `tools/gene-lang-skill/SKILL.md` from `book/overview` |
| `gene fmt file.gene` | prints the canonical layout to stdout; also a parse check |
| `gene parse file.gene` | prints the forms the reader produces |
| `gene compile file.gene` | prints the compiled bytecode |
| `gene lsp` | runs the language server over standard input and output |
| `gene view file.gene` | opens a structural viewer for source or serialized data |

`gene --help` lists every command and option, and `gene --version` reports
the build: release or debug, platform, and runtime checks.

In a terminal, Tab completes a name at the cursor. Press Tab on an empty
prompt to see names from the session, or after a slash to see members such as
`person/name` or `$str/upper`. Use Up and Down to recall earlier submissions
and Ctrl-R to search them. Ctrl-E opens the draft in `$VISUAL` or `$EDITOR`
and returns it to the prompt for review. Enter evaluates a complete draft or
opens a continuation line when the reader needs more input. History keeps
each submission together, including multiline ones, for the current session.

## Inspecting code

`gene doc file.gene` prints a module's doc, imports, and declarations. It
reads the source the way the documentation build does, so nothing is compiled
or run: top-level forms do not execute and `main` is not called.

```sh
gene doc greet.gene
# Module: greet
# Path: /home/me/greet.gene
# Doc: Greetings.
# Declarations:
# - hello : Fn
```

An import shows the file it resolves to, or why it does not resolve. A `let`,
`var`, or `const` shows its declared type or the type of its literal value;
when only running the form would tell, it shows `var`.

`gene fmt` prints the canonical layout to stdout and leaves the file alone.
It is also a parse check: if it cannot format the source, the source does not
read. Formatting its output again gives the same text.

> **Watch out:** `fmt` expands a triple-quoted interpolated string containing
> newlines into a `($to_str …)` call, so the preferred interpolation spelling
> is not always what it prints back.

`gene parse` shows what the reader made of a file, with shorthand expanded.
It is useful when a form does not mean what it seems to:

```sh
gene parse greet.gene
# (fn @doc "Say hello." hello [name : Str] : Str ((path gene to_str) "Hello, " name))
```

From inside a program, `$runtime/signature` describes a function or type
([Documenting a function](functions.md#documenting-a-function)), and
`$runtime/messages` lists the messages a value answers.
`$runtime/messages_of_type` lists the messages a type declares or inherits,
or a protocol's requirements, without constructing a value. Each entry's
`declared_on` is the type or protocol that holds it:

```gene runnable
(let first ($first ($runtime/messages_of_type Error)))
[($size ($runtime/messages_of_type List)) first/name first/declared_on]
# [19 "message" (type Throwable)]
```

## Documentation

`gene doc build` writes a corpus under `build/docs/`. The builder reads source
without compiling it; the generator, a Gene package under `tools/docs/`, turns
the builder's data and the book into the pages. The outputs are:

- `build/docs/md/<id>.md`, one Markdown page per chapter, section, namespace,
  and entry. An id is addressable: `$str/join` is `lib/gene/str/join`.
- `build/docs/llms.txt`, the small index agents load first.
- `build/docs/manifest.gene`, coverage, check results, and page sizes.
- `build/docs/names.gene`, the name table: every Gene spelling mapped to its id.
- `build/docs/gene-docs.sqlite`, full-text search and the name table.

`gene doc skill` writes the agent-facing skill file
`tools/gene-lang-skill/SKILL.md` from the generated `book/overview` page; edit
the book, then regenerate the skill. The doc-builder test fails when the two
drift, so the skill is never hand-edited.

`gene doc index`, `show`, `ls`, and `search` read that corpus. `--corpus <dir>`
reads another package's corpus. `$docs/index`, `$docs/show`, `$docs/ls`, and
`$docs/search` are the same lookup from Gene code; `($docs/show $str/join)`
also works by value. A doc call reads files and never runs a documented module.
The commands and `$docs` describe the corpus of the binary that is running; in
another package, pass `--corpus` (or set `GENE_DOCS_ROOT`) to read that
package's corpus.

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
(import $log/[log_debug new_logger])
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
