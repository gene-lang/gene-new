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

Requires Nim 2 or later. From a checkout:

```sh
nimble build
./bin/gene eval '(+ 1 2)'
# 3
```

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
| [Language guide](docs/language.md) | Values, functions, types, protocols, collections, errors, and concurrency—with examples. |
| [Design](docs/design.md) | The main language choices, illustrated in code. |
| [Library recipes](docs/stdlib.md) | Strings, JSON, files, HTTP, databases, logging, and events. |
| [Workflows](docs/workflows.md) | Scripts, packages, editor tools, browser output, and native interop. |

For larger programs, read the [Todo web app](examples/todo_app/src/main.gene),
[protocol demo](examples/protocol_demo.gene), or
[Cordis plugin runtime](examples/cordis/README.md).

## Project status

Gene is under active development. The VM and a checked browser subset work;
APIs are still evolving. Native compilation and worker-thread execution remain
experimental. See [support and known limits](docs/development.md#status) before
choosing a backend or relying on sandbox behavior.

To contribute, see [development](docs/development.md). Exact edge-case contracts
live in [the specification](docs/spec/README.md); they are reference material,
not required reading for a first program.

## License

[MIT](LICENSE) © 2026 Guoliang Cao
