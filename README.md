# Gene

Gene is a general-purpose, gradually typed language implemented in Nim. It
combines Lisp-like expressions with records, object messages, protocols, and
readable paths through data. Code and data share the same node representation.

Here is a complete program:

```gene runnable
(type Todo ^props {^title Str ^done Bool})

(fn unfinished_titles [todos : (List Todo)] : (List Str)
  (todos
    -> $filter (fn [todo] (! todo/done))
    => (fn [todo] todo/title)
    -> $into []))

(let todos
  [(Todo ^title "Learn Gene" ^done true)
   (Todo ^title "Write a small app" ^done false)])

($println (unfinished_titles todos))
# ["Write a small app"]
```

`^title` names a property, `todo/title` reads it, and `: Str` is a type
annotation. The pipeline filters the list, maps the remaining items, and
collects the result. Functions can also be written without annotations.

## Try it

Requires Nim 2.4.2 or later. From a checkout:

```sh
nimble build
./bin/gene eval '(+ 1 2)'
# 3
```

The CLI and companion tools build in portable release mode by default. Use
`nimble debug` for an instrumented debug build; `bin/gene --version` reports
the mode and runtime-check settings. Building a Gene application with
`--profile release` does not change the build mode of its host executable.

Save the program above as `todos.gene`, then run it:

```sh
./bin/gene run todos.gene
```

Types can define behavior too:

```gene runnable
(type Person ^props {^name Str}
  (message greet [] : Str
    $"Hello, ${self/name}!"))

(let ada (Person ^name "Ada"))
($println (ada .greet))
# Hello, Ada!
```

A dot sends a message to a receiver. Protocols let unrelated types implement
the same behavior. Gene also provides pattern matching, lazy streams,
structured tasks, modules, and template macros.

## Learn and build

| Start here | What you will find |
| --- | --- |
| [Overview](docs/book/overview.md) | What Gene is, a short tour, and how the docs are organized. |
| [Getting started](docs/book/getting_started.md) | Building Gene, `gene eval`, `gene run`, and programs with `main`. |
| [The book](docs/README.md) | Seventeen short chapters, from values to the web, native code, and tools. |
| [Errors](docs/book/errors.md) | Raising, catching, errors and faults, and how strictly to check. |
| [Testing](docs/book/testing.md) | Assertions and RSpec-style examples, fixtures, and `gene test`. |

For larger programs, read the [Todo web app](examples/todo_app/src/main.gene),
[protocol demo](examples/protocol_demo.gene), or
[Cordis plugin runtime](examples/cordis/README.md).

## Project status

Gene is under active development. The VM and a checked browser subset work;
APIs are still evolving. Native compilation and worker-thread execution remain
experimental. [Native code, builds, and deployment](docs/book/native.md) says
what the sandbox loader does and does not limit.

To contribute, read [AGENTS.md](AGENTS.md). The book replaced the earlier
guides, specification, change log, proposals, and reports; git history keeps
them under `docs/`.

## License

[MIT](LICENSE) © 2026 Guoliang Cao
