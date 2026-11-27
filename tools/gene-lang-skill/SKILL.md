---
name: gene-lang
description: Write, run, and debug Gene source (.gene files). Use when writing or changing Gene code, when a Gene construct's spelling is uncertain, or when diagnosing a Gene reader or runtime error.
---

# Overview

Each section below is a page; `modules.md` names `book/modules`
and `values.md#absence` names `book/values/absence`. Load a page
with `($docs/show "book/...")`; outside a Gene program use
`gene doc show book/...`.

Gene is a general-purpose, gradually typed language whose code and data share
one representation. This chapter tours the language in a few short programs
and explains how these docs are organized.

## What Gene is

Gene is a general-purpose language implemented in Nim. It combines Lisp-like
expressions with typed records, messages, protocols, and readable paths
through data. A program and the data it works on are made of the same nodes,
so code can be read, built, and changed as ordinary values.

Types are gradual. A function can go without annotations, and where you add
one, it is checked when a value crosses it. Programs run on Gene's virtual
machine, and a checked subset also runs in the browser, called the web
profile. Native compilation is experimental.

## A first program

This program keeps the titles of the unfinished items in a todo list:

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

(unfinished_titles todos)
# ["Write a small app"]
```

- `(type Todo ^props {…})` declares a record type with two fields. `^title`
  names a property, and `: Str` is a type annotation.
- `(fn …)` defines a function. Its last expression is its result.
- `todo/done` reads a field through a path.
- `->` passes the whole value to the next step, and `=>` maps each item.
- `$filter` and `$into` come from the standard library. `$filter` is short for
  `gene/filter`.

> **Watch out:** a standard library name always carries its `$`. A bare
> `(println "hi")` fails with `undefined symbol: println`; write
> `($println "hi")`.

Save a program in a file and run it with `gene run todos.gene`
([Getting started](getting_started.md)).

## Code is data

A node has a head, named properties, and positional body items. Quoting a
form keeps it as a node instead of running it:

```gene runnable
(let form (quote (+ 1 2)))
[($head form) ($body form)]
# [+ [1 2]]
```

The same shape holds application data, syntax, and templates, so the same
operations work on all three. Macros build on this
([Code as data](code_as_data.md)).

## Types and messages

A type can carry behavior. A dot sends a message to a receiver:

```gene runnable
(type Person ^props {^name Str}
  (message greet [] : Str
    $"Hello, ${self/name}!"))

((Person ^name "Ada") .greet)
# "Hello, Ada!"
```

`$"…${…}"` builds a string by interpolation. Protocols let unrelated types
provide the same messages ([Types, messages, and protocols](types.md)).

## Absence

`nil` is the one value that means "nothing here". A missing key, an omitted
optional field, and an index past the end all read as `nil`, and `??`
supplies a fallback. A mistake is not absence, so a misspelled field raises:

```gene runnable
(type Person ^props {^name Str ^nickname Str?})
(let ada (Person ^name "Ada"))
[ada/nickname (?? ada/nickname "none") (try ada/nmae catch Fault "raised")]
# [nil "none" "raised"]
```

`Str?` is a type that admits `nil`, which is what makes `^nickname` optional
([Absence](values.md#absence), [Missing and wrong
reads](names.md#missing-and-wrong-reads)).

## Tasks

A `scope` owns the tasks spawned inside it. It waits for them on the way out,
and if one fails it cancels the rest:

```gene runnable
(scope
  (let left (spawn (+ 10 20)))
  (let right (spawn (+ 30 40)))
  (+ (await left) (await right)))
# 100
```

Channels and actors add explicit communication
([Tasks, channels, and actors](concurrency.md)).

## Macros

A macro runs ordinary Gene code at compile time and returns the code to put
in its place. A backquoted template is the usual way to build that code:

```gene runnable
(macro unless [condition body...]
  `(if_not %condition %body...))

(var count 0)
(unless false (set count 1))
count
# 1
```

## How these docs work

The docs have two parts. This book teaches the language in reading order,
one idea per section. The library reference documents every standard name,
one entry per name, and is generated from the source. A section or an entry
can be loaded on its own.

## How to read these docs

Load the index first; it is small.
To load a page in Gene: `($docs/show "book/<chapter>/<section>")`.
Before writing or changing Gene code, load `book/overview` once.
To learn a feature: find its chapter in the index, load the chapter page
  (its list of sections), then load only the sections you need.
To use a name you know: load its entry, `lib/gene/<name path>`
  (`$str/join` is `lib/gene/str/join`).
To find a library for a job: scan the index's reference groups, then load
  that namespace's page.
For an error message: `gene doc search "<message>"`.
  Watch out notes quote the messages they explain.
Load a section or an entry, not a whole chapter or namespace.
