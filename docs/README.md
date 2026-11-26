# Gene documentation

The book teaches the language in reading order, one idea per `##` section,
and every example in it runs. Start with the overview, then read the
chapters you need.

| # | Chapter | Covers |
| --- | --- | --- |
| 1 | [Overview](book/overview.md) | what Gene is, a tour in short programs, how these docs work |
| 2 | [Getting started](book/getting_started.md) | building Gene, `gene eval`, `gene run`, `main` and its arguments, the REPL |
| 3 | [Values and expressions](book/values.md) | numbers, text, symbols, booleans, `nil`, collection literals, equality, printing |
| 4 | [Names, bindings, and paths](book/names.md) | bindings, naming rules, the standard library, paths and path reads, namespaces |
| 5 | [Control flow](book/control_flow.md) | `do`, `if`, `if_present`, `match` and patterns, loops |
| 6 | [Functions](book/functions.md) | `fn`, annotations, optional, named, and rest arguments, closures, `#@`, `@doc` |
| 7 | [Collections and streams](book/collections.md) | Lists, Maps, Sets, nodes, the two operation families, pipelines, streams, generators |
| 8 | [Types, messages, and protocols](book/types.md) | record types, messages, constructors, protocols, inheritance, enums, type expressions |
| 9 | [Errors](book/errors.md) | raising, catching, errors and faults, declared errors, cleanup, strictness |
| 10 | [Modules and packages](book/modules.md) | modules, imports, impl imports, packages, dependencies |
| 11 | [Input and output](book/io.md) | files, paths, JSON, CSV, processes, the environment, SQLite, serializing |
| 12 | [Tasks, channels, and actors](book/concurrency.md) | tasks, channels, cells, cancellation, actors, events |
| 13 | [Code as data](book/code_as_data.md) | quoting, templates, macros, fexprs, `eval` |
| 14 | [Testing](book/testing.md) | assertions, `*_spec.gene` examples, fixtures, `gene test` |
| 15 | [Gene on the web](book/web.md) | HTTP server and client, HTML and CSS as data, the web profile |
| 16 | [Native code, builds, and deployment](book/native.md) | `gene build`, `gene install`, C libraries, untrusted code |
| 17 | [Tools](book/tools.md) | the `gene` command, inspecting code, editors, logging |

The library reference is generated from the source into `build/docs/`.
`gene doc build` writes the pages, `gene doc index` is the entry point, and
`gene doc show <id or name>` reads one page; `$docs/index`, `$docs/show`,
`$docs/ls`, and `$docs/search` are the same lookup from Gene code. The
reference covers every namespace the runtime exposes: reflection supplies
names and signatures, and `.doc.gene` sidecars supply the prose where they
exist.

The book replaced the earlier guides, the specification, the change log,
proposals, and reports. Git history keeps them under `docs/`, and code
comments cite them as `archive/docs/…`, the untracked copy kept beside the
repository's other retired material.
