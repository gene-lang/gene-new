# Gene package organization and dependency management

**Status:** greenfield end-state design proposal; implementation begins only
after approval

**Scope:** package organization, manifests, dependency resolution, lockfiles,
package stores, vendoring, publication, and runtime package identity

**Related:** `package-build.md` defines builds and installation;
`distribution.md` defines application images and standalone executables.

**Revision date:** 2026-08-01

---

This proposal resolves Gene source packages only. A system dependency, native
build artifact, typed-native compiler backend, and mixed application image are
distinct concepts owned by `package-build.md`, `native-type.md`, and
`distribution.md`; none changes source package identity or resolution.

## 0. Prototype status

The tree contains an earlier package prototype, but this is a greenfield
contract. The prototype is implementation evidence, not a compatibility
surface. Format-1 implementation replaces its manifest reader, dependency
model, store layout, import rules, and package commands directly. There is no
legacy adapter, migration command, dual-read period, old-store conversion, or
deprecated CLI alias in the end-state design.

Three prototype findings remain useful because they protect the final model:

- **Symlinks.** A package keeps both a lexical `root` and a fully resolved
  `real_root`. Containment is checked against the lexical root first (so `../`
  is rejected without touching the filesystem) and then against the resolved
  root (so a symlink inside a package whose target is outside it is rejected on
  the resolved path). Module identities keep the lexical spelling.
- **`MODULE_AMBIGUOUS`.** It fires when extension defaulting has two matches — a
  reference `"x"` where both `x.gene` and a file literally named `x` exist in
  the same module root — rather than silently resolving to one.
- **User store location.** `~/.gene/packages` is the normative spelling; the
  `GENE_USER_PACKAGES` environment variable overrides it so tests and sandboxed
  runs never write to a real home directory.

Prototype manifests without `^format 1` are rejected. Prototype store contents
may be deleted and reacquired. The prototype `gene pkg install` command is
removed without replacement; source objects enter the private immutable store
only through `gene pkg sync`, while `gene install` installs applications. This
keeps store mechanics out of the package-manager interface and every
downstream caller.

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

This proposal is the implementation contract. Prototype behavior does not
constrain it.

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
metadata, editor state, and files excluded by `^files`. Build outputs never modify
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
- an explicit `--package_root <dir>` replaces the discovery start.

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
    ^tls_backend (dep "acme/tls_backend" "^2.0.0" ^optional true)
  }

  ^dev_dependencies {
    ^test_data (dep "acme/test_data" "1.0.0")
  }

  ^build_dependencies {
    ^asset_tool (dep "acme/asset_tool" "^3.0.0")
  }

  ^features {
    ^tls ["dep:tls_backend" "dep:http/tls"]
  }
  ^default_features []

  ^tests {
    ^root "tests"
  }

  ^files {
    ^include ["**/*"]
    ^exclude ["scratch/**"]
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
| `^version` | yes for regular packages | none | Semantic version |
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
| `^default_features` | no | `[]` | Feature names enabled unless an incoming edge disables defaults |
| `^singleton` | no | `false` | Package instances may not coexist in one graph |
| `^tests` | no | `nil` | Package test source root |
| `^files` | no | default set below | Publication and source-tree file selection |
| `^profiles` | no | `{}` | Custom build profiles defined by `package-build.md` |
| `^build` | no | `[]` | Build recipes defined by `package-build.md` |
| `^system_dependencies` | no | `{}` | Host ABI requirements defined by `package-build.md` |

At least one of `^library` or `^applications` is required for publication.
Local regular packages may temporarily omit both while being initialized.

`format` is the integer `1`; `name`, `version`, `description`, `license`, and
`repository` are UTF-8 strings when present; `singleton` is a boolean. An
omitted optional field takes its table default—explicit `nil` is not a second
spelling. Dependency, feature, profile, and system-dependency fields are maps;
applications and recipes are vectors. Map keys that name Gene entities are
symbols, not strings.

Package-name segments and dependency aliases use lowercase `snake_case`.
Package names contain exactly two segments, `<owner>/<name>`, separated by one
`/`; `.`, `..`, empty segments, additional slashes, backslashes, and
percent-encoded separators are invalid. This keeps package identity shallow
and leaves registry federation to registry
metadata rather than encoding it into the name.

All manifest paths are normalized UTF-8 relative paths. They cannot be
absolute, contain `..`, or escape through symlinks. A `^path` dependency is the
one exception: its root path may leave the declaring package because the
dependency becomes a separate package with its own boundary.

Every nested schema is closed: unknown properties, extra positional values,
duplicate map keys after symbol normalization, and a value of the wrong kind
are manifest errors. The format-1 shapes are:

- `^workspace` is `{ ^members [<pattern> ...] }`. It is valid only in the
  workspace root; `members` is required and non-empty.
- `^library` is `{ ^entry <path> ^uses [<recipe_name> ...] }`. `entry` is
  required; `uses` defaults to empty. The library root is the entry's parent
  directory: `^pkg "alias"` with module `"."` selects the exact entry, while
  every other logical module path is relative to that root.
- Each application is `(application <target_name> ^entry <path>
  ^command <command_name> ^uses [...])`. The body contains exactly one target
  name, `entry` is required, `command` defaults to the target name, and `uses`
  defaults to empty. Target and command names are
  package-local `snake_case` names and must be unique in their namespaces.
- `^tests` is `{ ^root <path> }`. Test discovery beneath that root belongs to
  `gene test`; the directory is not a runtime module root.
- `^files` is `{ ^include [<pattern> ...] ^exclude [<pattern> ...]
  ^executable [<pattern> ...] }`. `include` defaults to `["**/*"]`; `exclude`
  and `executable` default to `[]`. The immutable
  default exclusions are `package.gene.lock`, `.gene/**`, `vendor/**`,
  `.git/**`, `.hg/**`, `.svn/**`, `.DS_Store`, `Thumbs.db`, `*~`, `*.swp`, and
  `*.tmp`. Explicit
  exclusions are subtracted after the include union. Executable patterns set
  the portable executable bit instead of inheriting host filesystem modes.
  Exclusions cannot exclude
  `package.gene`, a declared target entry, resource, native source, or recipe
  input.

Manifest patterns use `/` separators. `*` matches within one segment and `**`
matches zero or more complete segments; no brace expansion, character classes,
negation, or platform-dependent escaping is supported. Matches are made
against normalized relative paths and sorted by their UTF-8 bytes.

`^features` maps a feature name to a list of strings in one of three forms:
`"feature:<name>"` enables another feature of the same package,
`"dep:<alias>"` enables an optional dependency, and
`"dep:<alias>/<feature>"` enables a dependency feature. Cycles are allowed and
collapse to a fixed point. A referenced dependency feature is sent only when
that dependency edge is enabled. `^default_features` names keys in this map;
unknown feature or dependency references are errors.

Dependency scope is structural. `^dependencies` edges are runtime edges and
are transitive. `^dev_dependencies` are available only to tests, examples, and
authoring commands of an active workspace member; they never propagate when
that member is consumed. `^build_dependencies` form a host-platform tool graph
for every package recipe that uses them; they do not enter the target runtime
graph. One alias may appear in only one scope in a manifest.

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

A `dep` node has one or two positional values: the package name and an
optional constraint string. The constraint is required for registry and
workspace dependencies and optional for path and git development dependencies.
Its allowed properties are:

| Property | Default | Meaning |
|---|---|---|
| `^registry <name>` | configured default | select a registry source |
| `^git <url>` | none | select a git source |
| `^commit`, `^tag`, or `^branch` | none | exactly one selector for a git source |
| `^path <path>` | none | select a manifest-relative filesystem source |
| `^workspace true` | `false` | select a declared workspace member |
| `^features [<name> ...]` | `[]` | requested dependency features |
| `^default_features <bool>` | `true` | enable that package's defaults |
| `^optional <bool>` | `false` | require activation through a feature |

Exactly one of registry, git, path, or workspace is selected; the absence of
all source properties means the configured default registry. `^registry`
cannot be combined with another source property. `^workspace` accepts only
`true`, and a git dependency has exactly one of `commit`, `tag`, or `branch`.
The lock always records an exact commit. When a path or git dependency includes
a constraint, its manifest version must satisfy it. Optional dependencies are
allowed only in `^dependencies`, must be named by at least one feature, and are
absent from the graph until enabled. Unknown properties are errors.

Registry and git identity URLs use one canonical URI form. Only `https` and
`ssh` are accepted initially; scheme and DNS host are lowercase, IDNs use
lowercase IDNA A-labels, default ports are omitted, dot segments are removed,
and percent escapes use uppercase hex after decoding unreserved bytes. A URI
has no password, query, or fragment; SSH may include a username. SCP-like git
spellings are rejected rather than rewritten. Path case and a trailing `.git`
are retained. Registry names and configured URLs have a one-to-one mapping
within a resolution policy.

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

### 5.4 Versions and constraints

Package versions use SemVer 2.0.0. The initial constraint language supports an
exact version, `=`, `<`, `<=`, `>`, `>=`, caret, tilde, `*`, and a whitespace-
separated intersection of comparators. It deliberately does not support `||`,
hyphen ranges, or ecosystem-specific wildcard spellings; unsupported syntax is
a manifest error rather than an approximate interpretation.

Caret and tilde follow SemVer compatibility, including the `0.x` rules. Build
metadata is retained in identity but ignored for precedence. A prerelease is
eligible only when at least one comparator in that requirement explicitly
names a prerelease with the same major, minor, and patch tuple. Registry
metadata provides a total tie-break for versions equal in SemVer precedence;
the canonical version string, then archive digest, is compared by UTF-8 bytes.

## 6. Resolution

Resolution consumes root requirements and produces an immutable graph before
the VM loads an application module.

### 6.1 Solver policy

The solver consumes canonical root manifests, one immutable metadata snapshot
per registry, source metadata for path/workspace/git requirements, host policy,
and an optional existing lock. Filesystem or network enumeration order is never
an input.

Lock preservation happens before optimization. `gene pkg sync --locked` treats
the complete lock as immutable. `gene pkg resolve` retains every locked edge
whose requirement, source identity, selected features, and target node remain
valid; a changed root requirement unlocks that edge and only the now-unreachable
or incompatible portion of its closure. `gene pkg update <alias>` unlocks the
selected root edge and its reachable closure while retaining valid nodes shared
by locked roots. `gene pkg update` unlocks every external edge. A yanked locked
version remains usable unless policy forbids it, but a fresh solution does not
select a yanked version.

For the remaining finite candidate graph, the solver chooses the unique
solution with the following lexicographic objective:

1. satisfy all version, source, feature, compatibility, and singleton
   constraints;
2. minimize the total number of package instances;
3. for each canonical `(package_name, source_identity)` in UTF-8 byte order,
   minimize its instance count, then maximize its descending SemVer vector;
4. among versions equal in SemVer precedence, choose the greatest canonical
   version string by UTF-8 bytes; reject registry records that give one exact
   source/name/version more than one immutable digest;
5. serialize nodes and diagnostics in canonical package-ID and alias order.

This deliberately allows the solver to use one version for overlapping
constraints when possible, while producing two or more instances when that is
required by incompatible constraints, including constraints on direct aliases.
It is a specified result, not a promise about a particular solving algorithm; an implementation
may use incompatibility propagation plus branch-and-bound as long as it proves
the objective before emitting a lock.

Feature expansion is a monotone fixed point. Requests unify only on the same
selected package instance; two versions do not share feature state. Enabling an
optional dependency adds an ordinary requirement edge and may therefore change
the solution. Runtime, development, and host build graphs are solved together
so aliases have one locked meaning, then projected by scope for a command.

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
  ^root_manifest_digest "sha256:..."
  ^workspace_digest "sha256:..."
  ^registry_snapshots [
    (registry "gene" ^url "https://packages.example.invalid/gene/"
      ^index_digest "sha256:...")
  ]
  ^roots ["workspace:acme/a@1.0.0#sha256:w..."]
  ^packages [
    (locked_package
      ^id "workspace:acme/a@1.0.0#sha256:w..."
      ^name "acme/a"
      ^version "1.0.0"
      ^manifest_digest "sha256:..."
      ^source (workspace ^path ".")
      ^features []
      ^dependencies {
        ^b (locked_edge ^scope runtime ^target "pkg:acme/b@1.0.0#sha256:b...")
        ^c (locked_edge ^scope runtime ^target "pkg:acme/c@1.1.0#sha256:c11...")
        ^d (locked_edge ^scope runtime ^target "pkg:acme/d@1.0.0#sha256:d...")
      }
      ^compatibility (compatibility ^package_format 1 ^runtime ">=0.4 <0.5"))
    (locked_package
      ^id "pkg:acme/b@1.0.0#sha256:b..."
      ^name "acme/b"
      ^version "1.0.0"
      ^manifest_digest "sha256:bm..."
      ^source (registry "gene" ^archive_digest "sha256:ba..."
        ^tree_digest "sha256:b...")
      ^features []
      ^dependencies {
        ^c (locked_edge ^scope runtime ^target "pkg:acme/c@1.0.0#sha256:c10...")
      }
      ^yanked false
      ^compatibility (compatibility ^package_format 1 ^runtime ">=0.4 <0.5"))
    (locked_package
      ^id "pkg:acme/c@1.0.0#sha256:c10..."
      ^name "acme/c" ^version "1.0.0"
      ^manifest_digest "sha256:c10m..."
      ^source (registry "gene" ^archive_digest "sha256:c10a..."
        ^tree_digest "sha256:c10...")
      ^features [] ^dependencies {} ^yanked false
      ^compatibility (compatibility ^package_format 1 ^runtime ">=0.4 <0.5"))
    (locked_package
      ^id "pkg:acme/c@1.1.0#sha256:c11..."
      ^name "acme/c" ^version "1.1.0"
      ^manifest_digest "sha256:c11m..."
      ^source (registry "gene" ^archive_digest "sha256:c11a..."
        ^tree_digest "sha256:c11...")
      ^features [] ^dependencies {} ^yanked false
      ^compatibility (compatibility ^package_format 1 ^runtime ">=0.4 <0.5"))
    (locked_package
      ^id "pkg:acme/d@1.0.0#sha256:d..."
      ^name "acme/d" ^version "1.0.0"
      ^manifest_digest "sha256:dm..."
      ^source (registry "gene" ^archive_digest "sha256:da..."
        ^tree_digest "sha256:d...")
      ^features []
      ^dependencies {
        ^c (locked_edge ^scope runtime ^target "pkg:acme/c@1.2.0#sha256:c12...")
      }
      ^yanked false
      ^compatibility (compatibility ^package_format 1 ^runtime ">=0.4 <0.5"))
    (locked_package
      ^id "pkg:acme/c@1.2.0#sha256:c12..."
      ^name "acme/c" ^version "1.2.0"
      ^manifest_digest "sha256:c12m..."
      ^source (registry "gene" ^archive_digest "sha256:c12a..."
        ^tree_digest "sha256:c12...")
      ^features [] ^dependencies {} ^yanked false
      ^compatibility (compatibility ^package_format 1 ^runtime ">=0.4 <0.5"))
  ]
}
```

The example intentionally locks three `acme/c` instances: `a -> b -> c@1.0`,
`a -> c@1.1`, and `a -> d -> c@1.2`. Each importing package follows its own
alias edge in O(1); no global “current version of C” exists.

Each locked node records:

- package instance ID;
- name and exact version;
- canonical source identity;
- archive and unpacked-tree digests for immutable sources;
- selected features;
- dependency-alias edges to other instance IDs;
- yanked status at resolution time;
- required runtime, compiler, and package-format compatibility.

The top-level lock schema contains exactly `lock_format`,
`root_manifest_digest`, `workspace_digest`, `registry_snapshots`, `roots`, and
`packages`. `roots` is a non-empty list of package instance IDs. `packages` is
sorted by ID and contains every root and transitive node exactly once. A
`locked_package` always has `id`, `name`, `version`, `manifest_digest`,
`source`, `features`, `dependencies`, and `compatibility`; immutable nodes
additionally require `yanked`. A `registry` source has one registry name plus `archive_digest` and
`tree_digest`. A `git` source has one normalized URL plus `commit` and
`tree_digest`; a transport archive digest is optional. A `workspace` source has
only its root-relative `path`. A `path` source has only its
declaring-manifest-relative `path`. The compatibility node
has `package_format`, `runtime`, and optional `compiler`; all are checked before
materialization. No other lock fields are accepted in format 1.

`registry_snapshots` is sorted by registry name and contains exactly one
`(registry <name> ^url <canonical_url> ^index_digest <digest>)` for each
registry consulted by the solution. Duplicate names or URLs are errors.
Signature and transparency evidence is verified acquisition metadata
referenced by the index digest, not an
open-ended field in lock format 1.

`^dependencies` maps the declaring package's alias to
`(locked_edge ^scope <runtime|development|build> ^target <package_id>)`.
Aliases are unique across scopes, every target must exist, and no undeclared
transitive package may be addressed directly. The graph may contain cycles only
in feature expansion metadata, never in package dependency edges. Lock format 1
describes one machine-independent source graph and does not encode host paths;
the build engine interprets build edges for the host platform and runtime edges
for the target platform when selecting artifacts.

`^workspace_digest` covers the root workspace declaration, the canonical
member list, and every member manifest digest. It does not cover ordinary
member source files; those are build inputs rather than resolution inputs.

An immutable registry/git node uses an instance-identity digest
covering its canonical source identity and tree digest. A mutable
workspace/path node instead records its source kind, workspace- or
manifest-relative locator, package identity, and manifest digest.
Its live tree digest belongs to the build derivation. This keeps dependency
resolution stable while a developer edits `packages/pkg1`, without allowing a
release artifact to omit the exact source snapshot it used.

Instance IDs are canonical strings: immutable IDs are
`pkg:<name>@<version>#sha256:<instance_identity_hex>`, where the final digest
covers the Canonical Gene Data v1 tuple `(source_identity, tree_digest)`;
workspace IDs are
`workspace:<name>@<version>#sha256:<source_identity_hex>`; path IDs are
`path:<name>@<version>#sha256:<source_identity_hex>`. The path source-identity
digest covers the declaring package's canonical source identity plus the
normalized relative locator and dependency manifest digest, so equal spellings
in different packages cannot collide. A workspace source-identity digest
covers the root package name/version, root-relative member path, and that
member's manifest digest; an unrelated member edit therefore does not change
this identity. Git source
identity covers normalized repository URL and exact commit; its immutable
package ID also covers the verified tree digest. IDs are unique
within a lock and are treated as opaque lookup keys by import code.

Canonical registry source identity is `(registry, canonical_registry_url)`;
canonical git source identity is `(git, canonical_repository_url, commit)`.
The configured local registry nickname is recorded for diagnostics but is not
the trust identity. Workspace and path source identities are the tuples
described above. Source-kind tags are part of every tuple, so equal URL/path
bytes from different adapters cannot collide.

The lockfile contains no machine-specific absolute paths. Path dependencies use
manifest-relative paths in the serialized lock and are re-canonicalized on the
current machine.

Applications commit their lockfile. Libraries should also commit a development
lockfile so their tests and tools are reproducible, but consumers ignore a
dependency package's development lock and resolve from its published manifest.
The development lock is not included in a published library-only source
archive.

A published package containing application targets includes the generated
`package.gene.release.lock` for those applications. The installer treats that
lock as the publisher's complete application graph; a consumer importing the
same package as a library ignores it. A mixed package can therefore publish
reproducible applications without pinning the versions chosen by downstream
library consumers.

`gene pkg sync --locked` fails if the root manifest, workspace membership, or
any workspace/path manifest disagrees with the lockfile. Editing ordinary
source beneath a mutable package does not require resolving again.
Only `gene pkg resolve`, `gene pkg update`, `gene pkg add`, and `gene pkg
remove` may intentionally rewrite the lockfile.

### 6.3 Canonical bytes and digests

All `sha256:` values in package identities use SHA-256 and a named canonical
encoding; implementations may not hash pretty-printed Gene text, directory
enumeration order, archive timestamps, or host-native paths.

**Canonical Gene Data v1.** Manifests, locks, registry records, and derivation
metadata are encoded recursively with unsigned 64-bit big-endian lengths and
counts. The one-byte tags are `0x00` nil, `0x01` false, `0x02` true, `0x03`
integer, `0x04` string, `0x05` symbol, `0x06` vector, `0x07` map, and `0x08`
Gene node. An integer is a length followed by the shortest ASCII decimal
representation. Strings and symbols are a length followed by their raw UTF-8
bytes. A vector is a count followed by its values. A map is a count followed by
key/value pairs sorted by the complete canonical bytes of each key and rejects
duplicate encoded keys. A node encodes its head value, its property map, then a
body count and ordered body values. Floats and all executable/runtime-only
values are forbidden in these data formats. The
byte stream starts with `gene-data-v1\0`; golden encoding vectors are part of
the format test suite.

Identifiers and manifest paths are validated before encoding. Package names,
aliases, features, target names, and properties are ASCII `snake_case` where
their schema requires names. Paths are Unicode NFC, use `/`, and have no empty,
`.` or `..` segment. Descriptive strings and file contents are not Unicode- or
line-ending-normalized.

**Canonical Source Tree v1.** File selection follows `^files`; directories are
implicit and empty directories do not contribute. Entries are sorted by
normalized path UTF-8 bytes. A regular-file record is tag `0x01`, path length
and bytes, one `0x00`/`0x01` executable byte selected by `^files.^executable`,
then content length and raw bytes. A symlink record is tag `0x02`, path length
and bytes, then normalized relative-target length and bytes. All lengths are
unsigned 64-bit big-endian. Symlinks with absolute targets, a `..` escape, a
cycle, or a target outside the selected tree are rejected. Other mode bits,
owners, ACLs, extended attributes, timestamps, and host directory separators
do not contribute. The stream starts with `gene-tree-v1\0`; its SHA-256 is the
tree digest. The prefix is followed by the unsigned 64-bit entry count and then
the records. Duplicate normalized paths and Unicode or case-fold collisions are
rejected on every platform, not only on platforms where they collide. Unicode
normalization and Default Case Folding use the Unicode 15.1 tables fixed by
package format 1; changing those tables requires a new package format.

The archive digest hashes the exact `.gpkg` transport bytes and is independent
of the tree digest. The root manifest digest hashes its Canonical Gene Data v1
value. `workspace_digest` hashes a canonical vector containing the root
workspace declaration (or `nil`) followed by
`(relative_member_path, manifest_digest)` pairs for declared members in path
order. A standalone regular package therefore hashes `[nil]`. The lock digest
hashes the entire canonical lock value; the lock has no self-digest field.
Every producer writes canonical ordering and every reader recomputes the
relevant digests before trusting an identity.

**Source Package v1.** A `.gpkg` is an uncompressed deterministic container,
not a tar or ZIP dialect. Its bytes are `gene-gpkg-v1\0`, an unsigned 64-bit
length, one Canonical Gene Data v1 metadata value, an unsigned 64-bit entry
count, then the Canonical Source Tree v1 entry records in the same order and
encoding (without repeating the tree stream's domain prefix). Metadata contains
exactly `format`, `name`, `version`, `manifest_digest`, and `tree_digest`; it
cannot contain the archive digest. The SHA-256 of the complete container is the
archive digest. HTTP content encoding may compress transport, but registries
store and verify the decoded canonical `.gpkg` bytes. Adding container-level
compression or random access requires a new source-package format.

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

- Replace the prototype reader and model with the closed format-1 manifest
  schema. Reject manifests without `^format 1`; do not add a compatibility
  adapter.
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

### Promotion criteria

The phase order is architectural, not a commitment to build speculative
machinery. Promote only when the preceding interface is stable and the named
demand exists:

| Phase | Demand gate |
|---|---|
| 1 | the format-1 package/workspace model is approved for source and tests |
| 2 | a resolved graph must survive restart, run offline, or reproduce on another machine |
| 3 | a real graph needs ranges, duplicate versions, or workspace/path/git sources rather than exact local requirements |
| 4 | a package must be shared outside its repository rather than through a path/workspace edge |
| 5 | registry/store measurements or incidents justify mirrors, resumability, transparency, or scale work |

The required graph with incompatible versions opens the Phase 3 gate; later
registry hardening remains closed until there is corresponding use or evidence.

Each phase requires executable language examples, CLI integration tests,
corruption/adversarial archive tests, and before/after package-resolution
benchmarks.

## 15. Required acceptance tests

The final design requires coverage for:

- nearest-manifest and ad-hoc discovery from file and file-less commands;
- manifest schema, target, alias, path, and `snake_case` validation;
- rejection of missing/unknown manifest formats without fallback parsing;
- two direct aliases selecting two versions of one package;
- the `A -> B -> C@1.0`, `A -> C@1.1`, `A -> D -> C@1.2` graph producing three
  isolated C module identities and exact alias edges;
- vendoring that graph materializing all three C objects at distinct
  version/digest paths and reproducing the same edges offline;
- solver objective tests for overlapping constraints, lock retention, selected
  updates, yanked pins, prereleases, singleton conflicts, and registry-order
  independence;
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
- golden Canonical Gene Data v1 and Canonical Source Tree v1 vectors, including
  Unicode, mode, symlink, collision, timestamp, and line-ending cases;
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
