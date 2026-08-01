# Gene package organization and dependency management

**Status:** design proposal for the end state; an earlier, smaller version of
this proposal is already implemented (§0). Work beyond that begins only after
approval.

**Scope:** package organization, manifests, dependency resolution, lockfiles,
package stores, vendoring, publication, and runtime package identity

**Related:** `package-build.md` defines builds and installation;
`distribution.md` defines application images and standalone executables.

**Revision date:** 2026-08-01

---

## 0. What already ships

This document describes a desired end state, but it is not a greenfield: an
earlier, smaller version of this proposal was implemented and is in the tree.
Anything below that contradicts shipped behavior is a **migration**, not a
blank-slate choice, and the phases in §14 must say which.

Implemented today (previously "Stages 1-3"): package discovery, ad-hoc and
regular packages, the data-only manifest, path and named dependencies, package
stores, and package-aware module resolution. The normative surface lives in
`docs/design.md` §15.3/§15.6 and `docs/spec/modules.md`; executable coverage is
the "spec — packages" suite in `tests/spec_runner.nim` and the "cli — gene pkg"
suite in `tests/test_cli.nim`.

Three questions this document left open were settled during that work, and the
answers are load-bearing rather than incidental:

- **Symlinks.** A package keeps both a lexical `root` and a fully resolved
  `real_root`. Containment is checked against the lexical root first (so `../`
  is rejected without touching the filesystem) and then against the resolved
  root (so a symlink inside a package whose target is outside it is rejected on
  the resolved path). Module identities keep the lexical spelling.
- **`MODULE_AMBIGUOUS`.** It fires when extension defaulting has two matches — a
  reference `"x"` where both `x.gene` and a file literally named `x` exist in
  the same base — rather than silently resolving to one. Precedence between the
  two module bases (`source_dir` before the root) is precedence, not ambiguity,
  and does not raise.
- **User store location.** `~/.gene/packages` is the normative spelling; the
  `GENE_USER_PACKAGES` environment variable overrides it so tests and sandboxed
  runs never write to a real home directory.

`gene pkg install <dir> [--user|--app]` also ships, and it copies a package
tree into a store. §11 and `package-build.md` §12 reassign the word `install`
to applications, which makes that command's removal or rename a breaking change
this proposal owns rather than inherits.

## 1. Decision summary

Gene should have one package model for libraries, applications, and packages
that contain both. The important decisions are:

- A package is a source and dependency unit. Library and application targets
  are products declared by that package.
- A single-file program remains an ad-hoc package and needs no manifest.
- Regular packages use a declarative, data-only `package.gene` manifest.
- An application may own co-lived workspace packages under
  `<application_root>/packages/<member>`; every member keeps its own manifest,
  identity, targets, and package boundary.
- Source imports name dependency aliases, not registry package names or
  versions.
- A deterministic solver writes `package.gene.lock`; runtime imports never run
  the solver.
- Multiple versions of the same package may coexist. A locked package instance
  is identified by name, version, source, and content digest.
- User-level packages live in an immutable content-addressed store under
  `~/.gene/packages/`.
- Application-level packages live in `vendor/packages/` and are an exact,
  lockfile-verified snapshot, not an unversioned shadow directory.
- Acquiring a package never executes package code or build commands.
- Libraries are resolved and acquired; applications are installed. “Install a
  library” is not a separate global state transition.
- Package resolution, acquisition, building, and installation are separate
  phases with separate interfaces and failure modes.

This proposal describes the desired end state. Existing behavior may be
migrated in phases; it does not constrain the design.

## 2. Package lifecycle

The package lifecycle is:

```text
discover -> resolve -> acquire -> build -> assemble -> install/load
```

| Phase | Input | Output | May execute package code? |
|---|---|---|---:|
| Discover | entry path or working directory | ad-hoc or regular root package | no |
| Resolve | manifests, registry metadata, policy | immutable resolution | no |
| Acquire | resolution | verified package objects | no |
| Build | materialized graph, target, profile | immutable build artifacts | yes, under build policy |
| Assemble | build artifacts | library artifact, `.gapp`, or executable | no arbitrary package code |
| Install | assembled application | atomic installation receipt | no new build code unless install explicitly requested a source build |
| Load | materialized/runtime graph | initialized modules | normal Gene module initialization only |

Keeping these phases distinct is the central design rule. In particular,
ordinary imports must never discover remote packages, solve versions, modify a
store, or invoke a build.

## 3. Package organization

A package may contain a library, one or more applications, or both:

```text
widget/
├── package.gene
├── package.gene.lock
├── src/
│   ├── index.gene              # library entry
│   ├── parser.gene
│   └── apps/
│       ├── widget.gene         # application entry
│       └── widget_admin.gene   # another application entry
├── tests/
├── resources/
├── native/
├── tools/
├── packages/
│   └── pkg1/                    # editable co-lived workspace dependency
│       ├── package.gene
│       └── src/
├── vendor/
│   └── packages/               # optional locked application snapshot
└── .gene/
    └── build/                  # generated project-local build view
```

Only `package.gene` is required for a regular package. The other names are
defaults and conventions:

- `src/` contains Gene source;
- `src/index.gene` is the default library entry;
- application entries are explicit in the manifest;
- `tests/` contains package tests and fixtures;
- `resources/` contains declared runtime resources;
- `native/` contains native source owned by the package;
- `tools/` contains authoring tools and build inputs;
- `packages/` conventionally contains editable co-lived workspace packages;
- `vendor/packages/` is generated by `gene pkg vendor` from the lockfile;
- `.gene/` contains generated state and is safe to remove.

Published source archives exclude `.gene/`, application-local `vendor/`, VCS
metadata, editor state, and undeclared files. Build outputs never modify
`src/`, `resources/`, or another package's source tree.

### 3.1 Package, library, and application

A **Package** is the unit of naming, versioning, dependencies, publication,
and source integrity.

A **Library target** is an importable module graph produced by a package. A
package has at most one primary library target because its package identity is
already the library identity. Additional reusable behavior should be exposed
as modules beneath that library rather than as independently versioned targets.

An **Application target** is a named entry module assembled into a runnable
application. A package may declare multiple application targets.

This avoids two weak models:

- treating every executable as a separate package even when it shares one
  version and dependency graph with a library;
- treating `main_module` as both a library import entry and an application
  startup entry.

### 3.2 Co-lived workspace packages

An application may keep editable dependency packages beside its own source:

```text
app/
├── package.gene
├── package.gene.lock
├── src/
└── packages/
    ├── pkg1/
    │   ├── package.gene       # ^name "acme/pkg1"
    │   └── src/index.gene
    └── pkg2/
        ├── package.gene       # ^name "acme/pkg2"
        └── src/index.gene
```

The application manifest declares the workspace explicitly:

```gene
^workspace {
  ^members ["packages/*"]
}
```

`packages/` is the default convention used by `gene pkg init --mixed`, but it
is not scanned implicitly. Member patterns are normalized relative to the
workspace root, expanded in lexical order, and may not escape the root. Every
match must be a directory containing `package.gene`. Overlapping or nested
member roots, unmatched patterns, and duplicate package names are errors.

Each member is a regular package, not a submodule of the application package.
It owns its manifest, targets, dependency aliases, module cache identity, and
filesystem boundary. Workspace membership only makes the member available as
a dependency source; it does not grant an import or merge namespaces.

A dependency selects the co-lived member explicitly:

```gene
^dependencies {
  ^pkg1 (dep "acme/pkg1" "^1.0.0" ^workspace true)
}
```

The resolver matches `^name "acme/pkg1"` among declared members. It does not
depend on the directory basename, so `packages/pkg1` may be moved within the
declared member patterns without rewriting Gene imports. A workspace-only
development dependency may omit its version constraint; publishing requires a
constraint and a member version.

Workspace members use one root `package.gene.lock`. A member lockfile, if it
exists for standalone development outside the workspace, is ignored by
workspace commands. Members can depend on each other, but every edge remains
explicit and package dependency cycles use the same diagnostics as external
packages.

Co-lived packages and vendored packages serve different purposes:

| | `packages/<member>` | `vendor/packages/` |
|---|---|---|
| Intent | editable source developed with the application | immutable offline snapshot |
| Declared by | `^workspace.^members` and dependency `^workspace true` | root lockfile and `vendor.gene.lock` |
| Source identity | workspace-relative member root | immutable tree digest |
| Modified by developer | yes | no |
| Acquired from registry | no | materialized from locked objects |
| Included in builds | as live source snapshots | as verified immutable source |

## 4. Package discovery

Discovery starts from the entry, not unconditionally from process `cwd`:

- file-oriented commands start at the entry file's parent directory;
- directory-oriented and file-less commands start at the supplied directory or
  captured launch working directory;
- an explicit `--package <dir>` replaces the discovery start.

The runtime walks ancestors and selects the nearest `package.gene` as the
active package:

```text
discover(start):
  dir = lexical_absolute(start)
  loop:
    if dir/package.gene is a file:
      return regular_package(dir)
    if dir has no parent:
      return ad_hoc_package(start)
    dir = parent(dir)
```

The lexical root is retained for stable diagnostics and module identity. A
fully resolved real root is retained for symlink-aware containment checks.
Discovery captures its inputs once and never changes process `cwd`.

After selecting an active regular package, discovery continues upward only to
find a workspace root whose declared members contain that package. If found,
that workspace supplies the root lockfile, vendor store, and shared resolution;
the active package still supplies the selected entry target and module root.
Nested workspaces are rejected so this association is unambiguous. Thus running
`app/packages/pkg1/src/tool.gene` directly selects `pkg1` as the active package
while using `app/package.gene.lock` as its workspace graph.

### 4.1 Ad-hoc packages

If no ancestor manifest exists, Gene creates an in-memory ad-hoc package:

```text
kind: ad_hoc
name: nil
version: nil
root: discovery start
targets: one application target supplied by the command
dependencies: command-line dependencies, normally none
```

Ad-hoc packages provide zero-configuration scripts, module caching, and a
filesystem boundary. They are not publishable and cannot be selected as a
named dependency.

An ad-hoc program does not search whichever package versions happen to exist
in a user store. External dependencies must be explicit:

```sh
gene run script.gene --dep json=acme/json@^1.4
```

The command creates an ephemeral root manifest and resolution in memory. For
repeatable work, `gene pkg init` writes a regular package and lockfile. An
ad-hoc directory may also use a previously generated vendor snapshot only when
that snapshot contains its own valid root lock metadata.

## 5. Manifest

`package.gene` is exactly one Gene map datum parsed with `readAll`. It is never
executed. Unknown fields are errors for the declared manifest format.

```gene
{
  ^format 1
  ^name "acme/widget"
  ^version "1.2.0"
  ^description "Widget parsing and command-line tools"
  ^license "MIT"
  ^repository "https://example.invalid/acme/widget"

  ^workspace {
    ^members ["packages/*"]
  }

  ^library {
    ^entry "src/index.gene"
  }

  ^applications [
    (application "widget" ^entry "src/apps/widget.gene")
    (application "widget_admin" ^entry "src/apps/widget_admin.gene")
  ]

  ^dependencies {
    ^json (dep "acme/json" "^1.4.0")
    ^http (dep "gene/http" "~2.3.0" ^features [tls])
    ^pkg1 (dep "acme/pkg1" "^1.0.0" ^workspace true)
  }

  ^dev_dependencies {
    ^test_data (dep "acme/test_data" "1.0.0")
  }

  ^build_dependencies {
    ^asset_tool (dep "acme/asset_tool" "^3.0.0")
  }
}
```

The dependency head is the literal symbol `dep`, not `$dep`; `$dep` names a
standard-library path and has different reader semantics.

### 5.1 Core fields

| Field | Required | Default | Meaning |
|---|---:|---|---|
| `^format` | yes | none | Manifest schema version |
| `^name` | yes for regular packages | none | Registry identity `<owner>/<name>` |
| `^version` | yes for published packages | none | Semantic version |
| `^description` | no | `nil` | Short documentation string |
| `^license` | required to publish | none | SPDX expression |
| `^repository` | no | `nil` | Canonical source repository |
| `^workspace` | no | `nil` | Co-lived member declarations owned by this root |
| `^library` | no | inferred only by `pkg init --lib` | Primary library target |
| `^applications` | no | `[]` | Named application targets |
| `^dependencies` | no | `{}` | Runtime dependencies |
| `^dev_dependencies` | no | `{}` | Tests and authoring only |
| `^build_dependencies` | no | `{}` | Tools used only while building |
| `^features` | no | `{}` | Optional, additive package capabilities |
| `^singleton` | no | `false` | Package instances may not coexist in one graph |
| `^resources` | no | `[]` | Declared runtime resources |
| `^build` | no | `[]` | Build recipes defined by `package-build.md` |
| `^system_dependencies` | no | `{}` | Host ABI requirements defined by `package-build.md` |

At least one of `^library` or `^applications` is required for publication.
Local regular packages may temporarily omit both while being initialized.

Package-name segments and dependency aliases use lowercase `snake_case`.
Package names contain exactly one or more owner segments plus a final name,
separated by `/`; `.`, `..`, empty segments, backslashes, and percent-encoded
separators are invalid.

All manifest paths are normalized UTF-8 relative paths. They cannot be
absolute, contain `..`, or escape through symlinks. A `^path` dependency is the
one exception: its root path may leave the declaring package because the
dependency becomes a separate package with its own boundary.

### 5.2 Dependency aliases

The key in a dependency map is a local alias. Source imports use that alias:

```gene
(import [parse] from "." ^pkg "json")
(import [request] from "client" ^pkg "http")
```

Aliases give source code three useful properties:

- registry ownership can change without rewriting every import;
- a short local name is enough in source;
- two direct versions can coexist intentionally:

```gene
^dependencies {
  ^json_v1 (dep "acme/json" "^1.9.0")
  ^json_v2 (dep "acme/json" "^2.1.0")
}
```

The manifest owns alias-to-package mapping. A transitive package is not
importable unless it is also declared directly. Dependency aliases may not
collide with `self`, which is reserved for explicit self-package imports.

### 5.3 Dependency sources

A dependency selects exactly one source kind:

```gene
(dep "acme/json" "^1.4.0")
(dep "acme/json" ^git "https://example.invalid/acme/json.git" ^tag "v1.4.2")
(dep "acme/local_tools" ^path "../local_tools")
(dep "acme/pkg1" "^1.0.0" ^workspace true)
```

Registry requirements use SemVer constraints. Git dependencies pin a commit
in the lockfile even when the manifest names a tag or branch. Path dependencies
record a normalized locator and manifest digest in the lockfile, but remain
non-portable and are rejected from published source archives. Workspace
dependencies resolve by declared member package name and record the member's
workspace-relative root and manifest digest.

Path and workspace trees are mutable development inputs. Their current tree
digests are captured by each build snapshot and derivation, not rewritten into
the lockfile after every edit. A release or publication first freezes every
such input into an immutable source tree with a content digest.

Features are additive. A package cannot use features to remove dependencies or
change the meaning of existing public declarations. Selected features are part
of the locked graph and build derivation.

## 6. Resolution

Resolution consumes root requirements and produces an immutable graph before
the VM loads an application module.

### 6.1 Solver policy

The solver:

1. reads manifests and signed registry metadata as data;
2. resolves explicit workspace requirements against declared co-lived members;
3. selects the highest non-yanked version satisfying all constraints for a
   package instance when one version can satisfy them;
4. permits multiple versions when constraints are incompatible;
5. unifies selected features per package instance;
6. honors an existing lockfile unless an update was requested;
7. sorts candidates and diagnostics canonically, never by enumeration order;
8. produces the same graph from the same inputs and registry snapshot.

Multiple versions are safe because every dependency edge is keyed by local
alias and points to a package instance. Packages that bind process-global
state, export a singleton native runtime, or otherwise cannot coexist declare
`^singleton true`; the solver then reports an explicit conflict instead of
duplicating them.

The solver should explain conflicts as an incompatibility chain, including the
root requirement and every transitive constraint that made the graph
unsatisfiable.

### 6.2 Lockfile

`package.gene.lock` is the complete, machine-independent resolution:

```gene
{
  ^lock_format 1
  ^manifest_digest "sha256:..."
  ^workspace_digest "sha256:..."
  ^registry_snapshots [
    (registry "gene" ^index_digest "sha256:...")
  ]
  ^roots {
    ^json "pkg:acme/json@1.4.2#sha256:..."
    ^http "pkg:gene/http@2.3.4#sha256:..."
  }
  ^packages [
    (locked_package
      ^id "pkg:acme/json@1.4.2#sha256:..."
      ^source (registry "gene")
      ^archive_digest "sha256:..."
      ^tree_digest "sha256:..."
      ^features []
      ^dependencies {})
  ]
}
```

Each locked node records:

- package instance ID;
- name and exact version;
- canonical source identity;
- archive and unpacked-tree digests;
- selected features;
- dependency-alias edges to other instance IDs;
- yanked status at resolution time;
- required runtime, compiler, and package-format compatibility.

`^workspace_digest` covers the root workspace declaration, the canonical
member list, and every member manifest digest. It does not cover ordinary
member source files; those are build inputs rather than resolution inputs.

An immutable registry/git/archive node uses its tree digest in the package
instance ID. A mutable workspace/path node instead records its source kind,
workspace- or manifest-relative locator, package identity, and manifest digest.
Its live tree digest belongs to the build derivation. This keeps dependency
resolution stable while a developer edits `packages/pkg1`, without allowing a
release artifact to omit the exact source snapshot it used.

The lockfile contains no machine-specific absolute paths. Path dependencies use
manifest-relative paths in the serialized lock and are re-canonicalized on the
current machine.

Applications commit their lockfile. Libraries should also commit a development
lockfile so their tests and tools are reproducible, but consumers ignore a
dependency package's development lock and resolve from its published manifest.
The development lock is not included in a published library-only source
archive.

A published package containing application targets includes a release lock for
those applications. The installer treats that lock as the publisher's complete
application graph; a consumer importing the same package as a library ignores
it. A mixed package can therefore publish reproducible applications without
pinning the versions chosen by downstream library consumers.

`gene pkg sync --locked` fails if the root manifest, workspace membership, or a
member manifest disagrees with the lockfile. Editing ordinary source beneath a
member does not require resolving again.
Only `gene pkg resolve`, `gene pkg update`, `gene pkg add`, and `gene pkg
remove` may intentionally rewrite the lockfile.

## 7. Package stores and acquisition

Package stores contain immutable verified source objects. The lockfile, not a
directory scan, selects an object.

### 7.1 User store

The user store is content-addressed:

```text
~/.gene/packages/
├── objects/
│   └── sha256/
│       └── ab/cdef.../
│           ├── package.gene
│           └── ...
├── archives/
│   └── sha256/...
├── registry/
│   └── <registry metadata snapshots>
└── tmp/
```

`GENE_USER_PACKAGES` may override the root for sandboxes, CI, and tests. Store
objects are read-only after atomic insertion. The same digest is stored once
regardless of how many applications use it.

### 7.2 Application store

`gene pkg vendor` materializes the current lock under the application root:

```text
vendor/packages/
├── vendor.gene.lock
└── acme/
    └── json/
        └── 1.4.2/
            └── <tree_digest>/
                ├── package.gene
                └── ...
```

`vendor.gene.lock` records the root lock digest and the relative path for every
package instance. A vendored object is usable only when its digest matches the
root lock. Vendoring therefore overrides *location*, not identity or version;
a stale or modified vendor tree is an integrity error and never silently
shadows the locked object with different code.

Vendoring materializes immutable external nodes only. Workspace and path nodes
remain at their declared editable roots and are recorded as such in
`vendor.gene.lock`; a self-contained application source release freezes them
during publication instead of treating live source as vendor content.

Application lookup order for a locked node is:

```text
1. matching object in vendor/packages/
2. matching object in ~/.gene/packages/
3. acquire the exact locked archive, unless --offline
4. PACKAGE_OBJECT_MISSING
```

Workspace nodes resolve directly to their declared co-lived member roots before
this immutable-object lookup. Path dependencies remain at their declared paths.
Neither is copied into the user store unless explicitly frozen and packed as a
source archive.

### 7.3 Acquisition rules

Acquisition may download bytes, unpack archives, and verify metadata. It may
not execute manifests, hooks, build recipes, module top level, or native code.
For workspace members it performs no copy or download; it validates membership,
manifest identity, and the locked manifest digest, then materializes a graph
reference to the live member root.

Insertion is transactional:

```text
download to temporary file
-> verify archive digest and signature policy
-> unpack into temporary directory
-> validate paths, manifest identity, and tree digest
-> fsync as required by platform policy
-> atomically rename into content-addressed store
```

Archives reject absolute paths, `..`, duplicate normalized paths, device files,
unsafe symlinks, and case-fold collisions on case-insensitive platforms.

## 8. Module and package identity

Runtime package selection is an O(1) lookup on the importing package instance's
locked alias table. Imports do not probe stores or parse manifests.

`"."` means the selected package's library entry:

```gene
(import [parse] from "." ^pkg "json")
(import [schema] from "schema" ^pkg "json")
```

Every other module path resolves literally beneath the selected library root.
There is no root fallback and no magic `index` rewrite after the manifest has
selected an entry. Relative imports stay within the importing package.

Portable immutable identities are:

```text
package instance = name + version + source identity + tree digest
module instance  = package instance + normalized logical module path
```

During workspace development, the Application-local package instance uses the
workspace identity, member-relative root, declared name/version, and manifest
digest. The build snapshot digest is added to compiled artifact provenance.

An ad-hoc package receives an Application-local identity based on its lexical
root and source digest; it is never serialized as a publishable identity.

Each Package keeps lexical and real roots. Resolution rejects lexical `..`
escapes before filesystem access and rejects real-path escapes after resolving
symlinks. Module cache keys never depend on build-machine absolute paths.

## 9. Publishing source packages

The publishable library unit is a deterministic source package archive
(`.gpkg`). Publication:

1. validates the manifest and package name ownership;
2. rejects unresolved path dependencies, mutable git references, and
   workspace-only dependencies without publishable version constraints;
3. replaces `^workspace true` with the retained registry/version requirement
   for a library publication, or freezes the declared members into an
   application release source graph;
4. resolves dependency constraints independently of development pins and, for
   application targets, creates the release lock shipped for installation;
5. includes only declared source, resources, native source, documentation, and
   license files;
6. normalizes paths, modes, timestamps, and ordering;
7. computes archive and unpacked-tree digests;
8. optionally signs provenance with a configured publisher key;
9. uploads the archive and immutable version metadata;
10. verifies the uploaded object before declaring success.

Published versions are immutable. A registry may mark a version yanked but may
not replace its bytes. Owners, delegated publishers, signing policy, and
transparency logs belong to the registry design; the archive and lock formats
already carry the required digests.

Application targets may be present in a source package, but end-user
installation uses the application build and installation design in
`package-build.md`. A `.gpkg` is source, not an installed application and not a
`.gapp` application image.

A library publication that replaces `^workspace true` may proceed only when
the referenced member version with the same source-tree digest is already
published or is part of the same atomic publication set. This prevents a
library from being tested against co-lived bytes and published against
different registry bytes under the same version constraint.

## 10. Package-manager module

Package complexity should sit behind one deep module. Its external interface
is intentionally small:

```text
resolve(ResolveRequest) -> Resolution
sync(Resolution, SyncPolicy) -> MaterializedGraph
vendor(MaterializedGraph, VendorRequest) -> VendorReceipt
```

Callers do not manipulate store paths, registry indexes, solver state, or
temporary directories. `Resolution` and `MaterializedGraph` are immutable
values passed to the build engine and runtime loader.

The implementation has two real internal seams:

- **Package source adapters:** registry, git, filesystem path, workspace, and
  vendored objects provide metadata and bytes through one internal interface.
- **Store adapters:** user store and application vendor store provide verified
  objects through one internal interface.

Tests replace those local I/O adapters with temporary filesystem stores and an
in-memory registry. The external package-manager interface remains the test
surface; tests should not depend on solver traversal order or store internals.

## 11. Command surface

Package commands manage source and the resolved graph:

| Command | Purpose |
|---|---|
| `gene pkg init --lib|--app|--mixed` | create a package layout and manifest |
| `gene pkg add <alias>=<package>@<constraint>` | add a root requirement and resolve |
| `gene pkg remove <alias>` | remove a root requirement and resolve |
| `gene pkg resolve` | create or refresh the complete lockfile |
| `gene pkg update [alias]` | intentionally unlock and re-resolve selected nodes |
| `gene pkg sync` | acquire and verify the locked graph |
| `gene pkg vendor` | materialize the locked graph in `vendor/packages/` |
| `gene pkg members` | list co-lived workspace packages and their roots |
| `gene pkg tree` | show aliases, instances, features, and duplicate versions |
| `gene pkg why <package>` | explain why an instance is present |
| `gene pkg publish` | produce and publish a deterministic `.gpkg` |
| `gene pkg cache gc` | remove unreferenced user-store objects safely |

`gene build`, `gene test`, `gene run`, `gene install`, and `gene uninstall`
consume package-manager results but are not package-resolution subcommands.
Their behavior is defined in `package-build.md`.

From a workspace root, `gene pkg init packages/pkg1 --lib` creates the member
and registers it in `^workspace.^members`. `gene pkg add
pkg1=acme/pkg1@^1.0 --workspace` adds an explicit dependency edge to the
matching declared member. Neither command makes every workspace member an
implicit dependency.

All mutating commands support `--locked`, `--offline`, and machine-readable
diagnostics where meaningful. `--locked` never permits a lockfile rewrite;
`--offline` never permits network access.

## 12. Diagnostics and policy

Errors carry a stable code, concise message, and structured context. Required
families include:

```text
PACKAGE_MANIFEST_*
PACKAGE_DISCOVERY_*
PACKAGE_REQUIREMENT_*
PACKAGE_RESOLUTION_*
PACKAGE_LOCK_*
PACKAGE_SOURCE_*
PACKAGE_INTEGRITY_*
PACKAGE_STORE_*
PACKAGE_BOUNDARY_*
PACKAGE_MODULE_*
```

Resolution conflicts explain the chain of requirements. Integrity failures
show expected and actual digests without falling through to a lower-trust
candidate. Offline failures list the exact missing locked objects.

Policy is explicit input to resolution and sync. It controls registries,
allowed git hosts, signature requirements, yanked versions, offline behavior,
maximum archive size, and filesystem source permissions. Package manifests
cannot weaken host or application policy.

## 13. Security and reproducibility invariants

- Manifests, lockfiles, and registry metadata are data, never executable code.
- Resolution is deterministic for a registry snapshot and policy.
- Acquisition is inert and transactional.
- Vendored content must match the root lock exactly.
- Published versions and content-addressed objects are immutable.
- Imports use the materialized graph and perform no solver, network, or store
  mutation work.
- Every package and module path is checked lexically and after symlink
  resolution.
- Package source never writes into another package or the immutable store.
- Runtime capabilities are not granted merely because a package was acquired,
  built, or installed.

## 14. Implementation phases after approval

The phases establish the final interfaces early and deepen their
implementation without later command or manifest churn.

### Phase 1: package and target model

- Finalize the manifest format and migration rules.
- Implement discovery, ad-hoc packages, library/application targets, dependency
  aliases, co-lived workspace members, package instances, and package-aware
  module identities.
- Keep resolution local and exact-version-only behind the final `resolve`
  interface while the full solver is absent.

### Phase 2: lockfile and immutable stores

- Implement the final lockfile shape, content digests, user object store,
  transactional acquisition, and O(1) locked imports.
- Implement `sync`, `tree`, `why`, offline mode, and garbage-collection roots.

### Phase 3: solver and vendoring

- Add SemVer solving, multiple versions, feature unification, singleton
  conflicts, deterministic explanations, workspace/path/git sources, and
  `vendor`.
- Preserve the Phase 1 interface; only the solver implementation deepens.

### Phase 4: source archives and registries

- Add deterministic `.gpkg` creation, signatures, registry adapters,
  publication, yanking, and provenance verification.
- Keep registry/network behavior out of runtime imports.

### Phase 5: hardening and scale

- Add transparency integration, mirror policy, resumable acquisition,
  concurrent store insertion, robust GC, and large-graph performance work.
- Validate integration with application images and binary artifact registries.

Each phase requires executable language examples, CLI integration tests,
corruption/adversarial archive tests, and before/after package-resolution
benchmarks.

## 15. Required acceptance tests

The final design requires coverage for:

- nearest-manifest and ad-hoc discovery from file and file-less commands;
- manifest schema, target, alias, path, and `snake_case` validation;
- two direct aliases selecting two versions of one package;
- deterministic lock output and deterministic conflict explanations;
- application lockfiles versus dependency development lockfiles;
- active-package discovery inside `<app>/packages/pkg1` using the workspace
  root lock while preserving `pkg1` as the package boundary;
- explicit workspace membership, deterministic glob expansion, duplicate-name,
  overlap, escape, unmatched-pattern, and nested-workspace rejection;
- co-lived members remaining unimportable until declared as dependency aliases;
- co-lived edits invalidating build derivations without rewriting the lockfile;
- library publication replacing workspace selection with the retained version
  constraint, and application release freezing member source digests;
- vendor-first, user-store-second, network-last acquisition of the *same*
  locked digest;
- stale or modified vendor objects failing integrity checks;
- transactional recovery from interrupted downloads and unpacking;
- archive traversal, symlink, duplicate path, and case-fold attacks;
- offline sync reporting all missing locked objects;
- runtime imports doing no manifest read, directory enumeration, hashing,
  allocation-heavy solving, or network work after graph materialization;
- module-cache isolation for duplicate package versions;
- path dependencies outside the root retaining their own package boundary;
- package publication reproducibility from two clean directories;
- safe concurrent sync and garbage collection.

## 16. Deferred policy, not deferred structure

The following can arrive later without changing the package model:

- registry federation and namespace transfer;
- alternative solving strategies;
- patch/replace sections for development;
- private registries and enterprise mirrors;
- signed transparency logs;
- capability-aware package metadata;
- cross-language package adapters.

Build recipes, native/system dependencies, binary artifacts, application
images, and installed application layouts are specified in
`package-build.md`; they are deliberately not overloaded into source package
resolution.
