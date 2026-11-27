# Modules and packages

This chapter splits a program into modules, imports names between them, and
uses other packages as dependencies.

## Modules

Each source file is a module, and its top-level definitions are what other
modules can import. `(mod name @doc "…")` at the top names the module and
documents it:

```gene
# stats.gene
(mod stats @doc "Small statistics helpers.")

(fn twice [n] (* n 2))
(fn half [n] (/ n 2))
(fn ^^private scale [n] (* n 10))
```

`^^private` keeps a definition inside its module. Importing it fails with
`module/namespace has no export: scale`. `gene doc stats.gene` prints a
module's doc and declarations.

## Module and package bindings

Inside a file, `this_mod` is the module's `mod` node and `this_pkg` is the
package map (name, version, root, dependencies, and manifest path). They are
not available in `gene eval`, which has no module context; run a file when
the code needs them.

## Importing

`import` names what it takes, and `^from` names the module, by a path
relative to the importing file. The `.gene` suffix is optional:

```gene
# main.gene
(import half twice:double ^from "./stats")
(import *:stats ^from "./stats")

($println (double 3) (half 8) (stats/twice 5))
```

```sh
gene run main.gene
# 6 4 10
```

- `twice:double` binds `twice` under the name `double`. The colon has no
  spaces around it.
- `*:stats` binds the whole module as the namespace `stats`.
- A module runs once, however many modules import it. `(import ^from
  "./setup")` runs a module for its effects without binding any names.

Imports through a namespace use `/`, and a group shares a prefix:

```gene
(import sample/biggest ^from "./stats")
(import stats/[mean:average sample/[max min]] ^from "./metrics")
```

The same forms import from the standard library, whose namespaces need no
`^from`:

```gene runnable
(import $str/[join trim:clean])
(import $str:strings)
[(join ["a" "b"] "-") (clean " x ") (strings/upper "y")]
# ["a-b" "x" "Y"]
```

A namespace belongs to the module that defines it, so `ns` blocks in one
module are reached from another only through an import.

## Importing impls

An impl is visible in the module that defines it. To use it elsewhere, mark
it `^^export` and bring it in with `import_impl`:

```gene
# show_widget.gene
(import Shown Widget ^from "./shapes")
(impl Shown for Widget ^^export
  (message show [] : Str $"widget ${self/name}"))
```

```gene
# main.gene
(import Shown Widget ^from "./shapes")
(import_impl Shown for Widget ^from "./show_widget")
($println ((Widget ^name "w1") .Shown:show))
```

Without the `import_impl`, the send fails with
`no implementation of message 'show' for Widget`. `import_impl` can go
anywhere `import` can, and the impl is visible where an `import` at that spot
would bind its names. Two different impls of the same pair in view at once
are a conflict, and import order never picks one.

## Packages

A package is a directory with a `package.gene` manifest. `gene pkg init --app`
creates one for an application. The manifest is data: the package's name,
its version, what it provides, and what it depends on:

```gene
{^format 1
 ^name "acme/hello"
 ^version "0.1.0"
 ^applications [(application "hello" ^entry "src/main.gene")]
 ^dependencies {
   ^utils (dep "acme/utils" "0.1.0" ^path "../utils")}}
```

A library package names its entry module instead:

```gene
{^format 1
 ^name "acme/utils"
 ^version "0.1.0"
 ^library {^entry "src/utils.gene"}}
```

Package names are `owner/name` in snake_case. The `gene` and `genex` owners
are reserved for the project: `gene/…` for the runtime and its packages,
`genex/…` for experimental packages.

## Using a dependency

A dependency is imported through the alias its manifest gives it, with
`^pkg`. `^from "."` names the dependency's entry module:

```gene
# hello/src/main.gene
(import greet ^from "." ^pkg "utils")

(fn main [args]
  ($println (greet (?? args/0 "world"))))
```

```sh
gene pkg resolve
gene run src/main.gene Ada
# Hello, Ada!
```

`gene pkg resolve` resolves the dependency graph and writes
`package.gene.lock`, and later runs use the locked versions. A package's
other modules are imported by their path from its library entry's directory:
`^from "./extract" ^pkg "documents"`.

> **Watch out:** `^pkg` takes the alias from your own manifest, not the
> package's name. With `^utils (dep "acme/utils" …)`, write `^pkg "utils"`.

| Command | What it does |
| --- | --- |
| `gene pkg add alias=owner/name@constraint` | adds a dependency |
| `gene pkg remove alias` | removes one |
| `gene pkg resolve` | resolves the graph and writes the lock |
| `gene pkg update` | updates unlocked choices on purpose |
| `gene pkg sync` | fetches the locked sources |
| `gene pkg tree`, `gene pkg why` | show the graph and why a package is in it |
| `gene pkg vendor` | copies the locked sources into the project |

Running a program never resolves dependencies as a side effect. It reads the
lock.

> **Why:** `$str` and the rest of `gene/…` are always the runtime's own
> library. A package is never a global name: code reaches it only through an
> alias its own manifest declares. Adding a dependency to one package cannot
> change what a name means in another.
