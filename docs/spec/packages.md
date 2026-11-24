# Package owners and the install store

**Status:** implemented. This file defines how the `gene` and `genex` owner names
relate to the `gene` namespace, and where a lock resolves immutable packages
from.

## §1 Owners and names

A manifest's `^name` is `<owner>/<name>`, lowercase `snake_case` (see
[modules](modules.md)). Two owners are reserved for the project:

- `genex` holds experimental packages: `genex/crypto`, `genex/documents`, and so
  on.
- `gene` holds the runtime itself (`gene/runtime`), the standard libraries that
  ship as `gene/…` packages, and project packages that are neither
  (`gene/harness`, `gene/reference`).

Both are ordinary owners. A package from either one is an ordinary package: it
is module-scoped, imported per module with `^from` and `^pkg`, and never enters a
global namespace. The reserved status is operator policy, not a format rule:
only the project's keys are delegated those owners (see
[registry-service](registry-service.md)).

## §2 The `gene` namespace is not the `gene` owner

The name `gene` has two separate meanings, and they never collide:

| Meaning | Where it appears | Example | How code reaches it |
| --- | --- | --- | --- |
| the `gene` namespace | Gene code | `gene/str/join`, `$str/join` | always available; global |
| the `gene` owner | package manifests | `gene/runtime`, a `gene/foo` package | `(dep "gene/foo" …)`, then `(import … ^pkg "<alias>")` |

Only items the runtime loads are in the `gene` namespace: Nim natives and
runtime-loaded Gene source (for example `src/gene/lib/sync.gene`). A standard
library shipped as a `gene/foo` package is **not** added to the namespace; it is
imported like any dependency. Package names never appear in Gene code as symbols
— `^pkg` selects a dependency alias of the importing package, so `gene/x` in code
always means the namespace.

## §3 Names in the namespace and in the owner are independent

The `gene` namespace and the `gene` owner are separate namespaces of names, and
they load differently: the namespace is what the runtime binds, while a package
is a module-scoped dependency reached through its alias. Neither constrains the
other. A package may therefore take any valid `<owner>/<name>` in the `gene`
owner, including a name the runtime binds — `gene/str` is a legal package name
beside the `$str` namespace, and `genex/crypto` may be promoted to `gene/crypto`
even though `$crypto` exists.

What the two spellings mean when they coincide:

- `$foo` / `gene/foo` in code is always the runtime binding, because that is
  what the runtime loaded. It never means a package.
- The package is reached through a dependency, `(dep "gene/foo" "0.3.0")`, and
  imported with `^pkg` under its alias. That path has nothing to do with `$foo`.
- Moving a library between the runtime and a package still changes callers:
  `$foo/x` becomes an import, or the reverse. That keeps "what is in the
  runtime" a deliberate decision, without reserving names either way.

## §4 The install store

A Gene install provides a read-only, content-addressed store of the packages it
ships:

```text
<prefix>/share/gene/packages/objects/sha256/<xx>/<rest>/   # one tree per digest
```

`<prefix>` is the parent of the running binary's directory (`<prefix>/bin/gene`),
so it sits beside `<prefix>/share/gene/docs`. `GENE_INSTALL_PACKAGES` overrides
the path for a relocated install. The tree layout inside `objects/` is exactly
the user store's, so one digest names the same bytes in either store.

`sync` consults the install store before the user store. A tree is used only when
its digest matches the locked tree digest, so it can never substitute a different
release; packages served from it report the `install_store` origin and keep their
root inside the store. The offline availability check counts the install store,
so a lock that pins a shipped version replays with no network and no registry.

A lock that pins a version the install does not provide resolves like any
registry dependency: from the user store, or by download when the network policy
allows. Offline, it fails as a missing locked object.

Populating the store is packaging work — a release step, not `sync`. Until a
package ships, the store is empty, and a `gene/foo` dependency resolves as an
ordinary registry dependency.

## §5 Promotion and retirement

Promotion, moving `genex/foo` to `gene/foo`, changes the package identity and
nothing else in source: importers keep their `^pkg` alias. Everything that
records the identity is regenerated — the `dep` lines, each lock and its
manifest/workspace digests, and documentation names with the links that point at
them. A promoted name may coincide with a runtime binding (§3); `$x` stays the
binding and the package keeps its alias.

Retirement needs no extra namespace root: the registry's yank endpoint marks a
release, a fresh resolution excludes it, and a preserved lock still replays it
(see [package-release](package-release.md) and
[registry-service](registry-service.md)).
