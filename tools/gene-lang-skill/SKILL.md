---
name: gene-lang
description: Write, run, and debug Gene source (.gene files). Use when writing or changing Gene code, when a Gene construct's spelling is uncertain, or when diagnosing a Gene reader or runtime error.
---

# Overview

Gene is a general-purpose, gradually typed language whose code and data share
one representation. This chapter tours the language in a few short programs
and explains how these docs are organized.

## Sections

- [What Gene is](overview/what_gene_is.md) — Gene is a general-purpose language implemented in Nim. (569 B)
- [A first program](overview/a_first_program.md) — This program keeps the titles of the unfinished items in a todo list: (1.1 KB)
- [Code is data](overview/code_is_data.md) — A node has a head, named properties, and positional body items. (389 B)
- [Types and messages](overview/types_and_messages.md) — A type can carry behavior. (397 B)
- [Absence](overview/absence.md) — nil is the one value that means "nothing here". (611 B)
- [Tasks](overview/tasks.md) — A scope owns the tasks spawned inside it. (356 B)
- [Macros](overview/macros.md) — A macro runs ordinary Gene code at compile time and returns the code to put in its place. (301 B)
- [How these docs work](overview/how_these_docs_work.md) — The docs have two parts. (1.0 KB)

## How to read these docs

Load the index first; it is small.
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
