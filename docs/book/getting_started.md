# Getting started

This chapter builds Gene, evaluates expressions, and runs programs from files.

## Building Gene

Gene builds with Nim 2.4.2 or later. From a checkout:

```sh
nimble build
bin/gene --version
```

`nimble build` builds `bin/gene` and its companion tools (the formatter, the
language server, and the viewer) in release mode. `nimble debug` builds an
instrumented debug binary instead, which runs much slower. `--version` says
which one you have:

```text
Gene 0.1.0 (release; macosx/arm64; Nim 2.4.2; mm=orc; nim-opt=speed; …)
```

The examples below write `gene` for `bin/gene`.

## Evaluating an expression

`gene eval` evaluates source given on the command line and prints the value
of its last expression:

```sh
gene eval '(+ 1 2)'
# 3
gene eval '(let a 2) (* a 21)'
# 42
```

The source is read as a module located in the current directory, so imports
work as they do in a file: `^from "./helper"` loads `helper.gene` from there.

## Running a file

`gene run` runs a file. Its top-level forms run in order:

```gene
($println "Hello, world!")
```

```sh
gene run hello.gene
# Hello, world!
```

## Programs with main

When a file defines `main`, `gene run` calls it after the top-level forms
and passes the command-line arguments:

```gene
(fn main [args]
  (let name (?? args/0 "world"))
  ($println $"Hello, ${name}!")
  0)
```

```sh
gene run hello.gene Ada
# Hello, Ada!
```

- `args` is a `(List Str)`, empty when no arguments are given. `args/0`
  reads the first one, and a position past the end reads `nil`, so `??`
  supplies a default.
- `main` returns `nil` for success or an Int to use as the exit code.

## The REPL

`gene repl` reads source from standard input, a line at a time, and prints
each result. Bindings carry over from line to line:

```console
$ printf '(+ 1 2)\n(let a 5)\n(* a 2)\n' | gene repl
3
5
10
```

## Working loop

Use `gene eval '<source>'` for one expression; it prints the last value and
needs no file. It can import namespaces with `import`, but it has no module
bindings: `this_pkg` and `this_mod` are undefined there. Use
`gene run file.gene` for code that needs the module or package context. Probe the
shape that blocks the next change, then persist a small working version early
and grow it with focused tests. The implementation is done when it runs and
tests cover its intended behavior and the failure cases that matter.

## Other commands

| Command | What it does |
| --- | --- |
| `gene test` | runs the `*_spec.gene` examples ([Testing](testing.md)) |
| `gene parse file.gene` | prints the forms the reader produces, without running them |
| `gene doc file.gene` | prints a module's doc, imports, and declarations |
| `gene build` | builds a package product ([Native code, builds, and deployment](native.md)) |
| `gene lsp` | runs the language server for editors ([Tools](tools.md)) |

`gene --help` lists every command.
