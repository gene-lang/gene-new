# Package Support

**Status:** implemented (Stages 1-3). Stage 4 and everything in §17 remain
deferred. The normative surface now lives in `docs/design.md` §15.3/§15.6 and
`docs/spec/modules.md`; executable coverage is the "spec — packages" suite in
`tests/spec_runner.nim` and the "cli — gene pkg" suite in `tests/test_cli.nim`.

Two implementation notes where this document left a choice open:

- **Symlinks.** A package keeps both a lexical `root` and a fully resolved
  `real_root`. Containment is checked against the lexical root first (so `../`
  is rejected without touching the filesystem) and then against the resolved
  root (so a symlink inside a package whose target is outside it is rejected on
  the resolved path). Module identities keep the lexical spelling.
- **`MODULE_AMBIGUOUS`.** §10 says "normal extension defaulting and ambiguity
  rules apply" without saying what is ambiguous. It fires when extension
  defaulting has two matches — a reference `"x"` where both `x.gene` and a file
  literally named `x` exist in the same base — rather than silently resolving to
  one of them. Precedence between the two module bases (`source_dir` before the
  root) is precedence, not ambiguity, and does not raise.
- **User store location.** `~/.gene/packages` stays the normative spelling; the
  `GENE_USER_PACKAGES` environment variable overrides it so tests and sandboxed
  runs never write to a real home directory.

**Scope:** package discovery, package identity, local package stores, and
package-aware module resolution

**Revision date:** 2026-07-30

---

## 1. Goal

Gene should make a single file easy to run while giving larger applications a
stable package boundary and deterministic local dependencies.

The package model has two kinds of application package:

```text
application package
├── ad-hoc package: no package.gene was found
└── regular package: rooted at the nearest package.gene
```

Regular dependency packages may be loaded from two stores:

```text
application store: <application_root>/vendor/packages/
user store:        ~/.gene/packages/
```

The application store has higher precedence than the user store. This lets an
application vendor a dependency without changing the user's installation and
lets the same application resolve the same package on another machine.

This proposal extends the Application / Package / Module / Namespace model in
`docs/design.md`. It does not define a hosted registry or a complete package
manager.

### What exists today

`Application` already carries a `packageRoot` and enforces containment through
`isWithinPackageRoot`, and `gene run` sets that root to the entry file's parent
directory. So the *boundary* half of this proposal is partly built; what does
not exist is discovery (nothing looks for `package.gene`), package identity
(the root is a path, not a name), the two stores, dependency declarations, or
package-qualified imports. Module caching is keyed by absolute path, which is
what §10 replaces.

Two adjacent surfaces already exist as well: `gene runurl` anchors its
Application at the launch working directory and gates fetching behind
`Application.allowUrlModules` (design §15.9), and `parseImportSpec` admits
exactly one import prop, `^export`, rejecting everything else (§9 widens that
allow-list deliberately).

Stating this matters for Stage 1: the work is mostly *replacing* an implicit
root with a discovered one, not introducing containment from nothing.

## 2. Design principles

Package support follows these rules:

- Running an unconfigured script requires no manifest.
- A `package.gene` creates an explicit package boundary and supplies stable
  package metadata.
- Package discovery is based on ancestors, not arbitrary descendants or
  siblings.
- File-oriented commands discover from the entry file's directory; file-less
  entries (`eval`, `repl`, `runurl`) discover from the launch working
  directory.
- Package names are string values governed by the package-name grammar (§6),
  not by the registered-name convention — though both land on `snake_case`.
- Application-vendored packages shadow user-installed packages.
- A package candidate is accepted only when its manifest identity matches the
  requested package name.
- Module identities use logical package and module paths. Absolute filesystem
  paths are provenance, not portable identity.
- Resolution never depends on directory enumeration order.
- Package and module paths are canonicalized before cache or boundary checks.
- Loading a dependency does not change the process working directory.
- All Gene-facing names use `snake_case`.

## 3. Terms

### Application package

The package selected when an Application starts. It is either an ad-hoc
package or a regular package.

### Ad-hoc package

A runtime package synthesized when no `package.gene` exists in the current
directory or any parent directory. It gives scripts a package root and module
cache without requiring package metadata.

### Regular package

A directory tree rooted at a `package.gene` manifest. A regular package has a
declared name and may declare version, source layout, entry module, and
dependencies.

### Application root

The root of the application package. For a regular package it is the directory
containing the discovered `package.gene`. For an ad-hoc package it is the
discovery start directory defined in §4.

### Application package store

The `vendor/packages/` directory beneath the application root. It contains
dependencies selected specifically for that application.

### User package store

The per-user `~/.gene/packages/` directory. It contains packages available to
applications that have not vendored their own copy.

## 4. Application package discovery

Discovery starts at a directory determined by the entry, not always at the
launch working directory:

- a file-oriented command (`run`, `compile`, `build`, …) starts at the entry
  file's canonical parent directory;
- a file-less entry (`eval`, `repl`, `runurl`, future test/dependency
  commands) starts at the launch working directory, captured once at startup.

Starting file commands at the entry file preserves today's behavior, where the
package root is the entry file's parent: `gene run /elsewhere/script.gene`
keeps working from any working directory, and a script tree carries its
package with it. Anchoring at the launch cwd instead would make that
invocation fail the boundary check below — a regression, not a boundary. The
runtime checks the start directory for `package.gene`, walks toward the
filesystem root, and stops at the first match.

```text
start_dir(entry):
  if entry is a file:  canonical(parent(entry))
  else:                canonical(launch_working_directory)

find_package(start_dir):
  dir = start_dir
  loop:
    if dir/package.gene is a file:
      return regular_package(dir)
    if dir has no parent:
      return ad_hoc_package(start_dir)
    dir = parent(dir)
```

The nearest manifest wins. A nested package is therefore a real boundary:

```text
workspace/
├── package.gene              # package outer/app
└── tools/
    ├── package.gene          # package outer/tools
    └── inspect.gene
```

`gene run tools/inspect.gene` selects `outer/tools` from any working
directory; discovery does not keep walking after finding that manifest. A
`repl` or `eval` started in `workspace/` instead selects `outer/app`.

Package discovery and imports must not mutate `cwd`. A CLI package-root
override, if provided, replaces the discovery start directory explicitly
rather than changing the working directory; with an override in effect, the
entry file must be inside the override root.

With entry-relative discovery the entry file is inside the selected
application root by construction — the root is an ancestor of the entry's
directory. The containment check therefore only bites on an explicit override
or on a later `import`, which is where boundary violations actually occur.

## 5. Ad-hoc packages

An ad-hoc package exists to make this work without setup:

```sh
mkdir scratch
cd scratch
gene run hello.gene
```

Its synthesized metadata is:

```text
kind:          ad_hoc
name:          nil
version:       nil
root:          canonical discovery start directory (§4)
source_dir:    root
main_module:   entry module supplied by the command
manifest_path: nil
```

An ad-hoc package:

- may contain any number of modules beneath its root;
- resolves relative and package-root-relative module imports normally;
- may import named packages from `vendor/packages/` and the user store;
- has no declared dependency allow-list;
- cannot be published or selected as a named dependency;
- cannot claim a stable package identity;
- still enforces its filesystem boundary.

The ad-hoc application store is `<application_root>/vendor/packages/`, the same
rule as any other package (§7). This allows a small script tree to carry
vendored libraries without forcing the script itself to acquire a manifest.

No `package.gene` file is generated implicitly. Adding one later deliberately
turns the directory into a regular package.

## 6. Regular packages

A regular package is rooted by `package.gene`:

```text
my_app/
├── package.gene
├── src/
│   ├── main.gene
│   └── config.gene
├── tests/
└── vendor/
    └── packages/
```

The manifest is data read with `readAll`; it is never executed as program
code. It is exactly one map datum: a second top-level form of any kind is
rejected. There is no flat-properties form — top-level `^key value` does not
read as properties outside a compound (`gene parse` shows it as separate `^`
and symbol forms), so the map is the only shape:

```gene
{
  ^name "acme/my_app"
  ^version "0.1.0"
  ^source_dir "src"
  ^main_module "main"
  ^test_dir "tests"
  ^dependencies [
    (dep "acme/json" "1.4.2")
    (dep "acme/local_tools" ^path "../local_tools")
  ]
}
```

The dependency head is the plain symbol `dep`, not `$dep`. `$x` is reader sugar
for the `gene/x` member path, so `($dep …)` does not read as a node with a
symbol head at all — it reads as a node whose head is `(path gene dep)`:

```console
$ gene parse manifest_fragment.gene
((path gene dep) "acme/json" "1.4.2")
```

A manifest is data validated against a schema, and it must not appear to name
something in the standard library. Schema validation matches on the literal
head symbol `dep`.

Initial fields:

| Field | Required | Default | Meaning |
|---|---:|---|---|
| `^name` | yes | none | Stable package name |
| `^version` | no | `nil` | Package version metadata |
| `^description` | no | `nil` | Short human-readable documentation string |
| `^source_dir` | no | `"src"` | Module source directory relative to the root |
| `^main_module` | no | `"index"` | Package entry module relative to `source_dir` |
| `^test_dir` | no | `"tests"` | Test directory relative to the root |
| `^dependencies` | no | `[]` | Direct named or path dependencies |

Package names have the form `<owner>/<name>`. Each segment uses lowercase
`snake_case` and must not be `.`, `..`, or empty. Names are logical identities,
not raw filesystem paths. Package names are string *values*, not registered
Gene names, so the repository's registered-name convention does not decide
their spelling — this grammar does. It deliberately lands on the same
`snake_case` rule, so package names read like every other Gene-facing name.

`source_dir`, `main_module`, and `test_dir` are normalized relative paths. They
must not be absolute and must not escape the package root.

A stored dependency must be a regular package and must declare both `^name`
and `^version`. A store (non-`^path`) dependency declaration must therefore
name an exact version; a `^path` declaration may omit it, so sibling
checkouts can move freely. The application package may omit `^version` during
local development.

### Why the manifest is data, not code

An obvious alternative is to execute `package.gene` as an ordinary Gene module
and read the value it produces. The usual objection is cost — a slow manifest
multiplied across a deep dependency graph. **Measured, that objection is
wrong**, so it should not be the reason for the rule.

Per manifest, on the manifest above (release build, warm cache):

| Path | Per manifest | 200 packages |
|---|---:|---:|
| `readAll` as data | 6.5 us | 1.3 ms |
| compile only | 9.0 us | 1.8 ms |
| compile + run, shared scope | 13.9 us | 2.8 ms |
| compile + run, fresh scope each | 22.1 us | 4.4 ms |

For scale, the filesystem work resolution must do anyway dominates both: 200
`fileExists` probes cost 0.26 ms and 200 `readFile` calls cost 2.8 ms, so
**reading the files costs more than parsing them**, and parsing 200 manifests
adds roughly 0.06 ms on top of reading them. Choosing execution over data costs
about 3 ms across a 200-package graph. A half-second budget is off by two
orders of magnitude.

The real reasons are not about speed:

- **Execution has no upper bound.** Parsing costs something proportional to
  manifest size. Executing costs whatever the manifest decides to do — a loop,
  a `sleep`, a filesystem walk, an HTTP call. The problem is not the 3 ms; it
  is that no budget can be enforced.
- **It runs third-party code before trust exists.** Manifests are read during
  *resolution*, before any import of that package has been admitted. Executing
  them means a package that is merely present in a store, possibly transitively
  and unintentionally, runs code. This is the `postinstall` failure mode, and
  §13 already forbids it.
- **It destroys reproducibility.** An executed manifest may return a different
  dependency set per run, per machine, or per environment variable. Lockfiles
  and content hashes (Stage 4) then have nothing stable to describe.
- **It breaks tooling.** `gene pkg add` has to read a manifest and write it
  back. Data round-trips through the printer with a structural-equality
  guarantee; code does not survive being rewritten.
- **It needs a bootstrap that does not exist.** Executing the canonical example
  fails immediately with `undefined symbol: dep`, because as code `(dep …)` is
  a call. Supplying the vocabulary means a scope per manifest, and a manifest
  that could `import` would need packages resolved in order to resolve
  packages.

If a package genuinely needs computed configuration, that belongs in an
explicit script invoked by a command that asks for it — never on the resolution
path. Keeping the default declarative is what makes resolution fast, safe, and
cacheable; an opt-in escape hatch stays visible and does not tax every other
package.

### Computed fields, if they are ever needed

Stage 1 and 2 ship literal manifests only. This section records the design so
the question is settled rather than reopened, because the shape that works is
narrow and the shape that fails is the obvious one.

The failing shape is a manifest field whose value is a command run by whoever
*reads* the manifest. Measured against the same baseline:

| Operation | Each | 200 packages |
|---|---:|---:|
| parse manifest as data | 0.0065 ms | 1.3 ms |
| direct spawn of `/bin/echo` (floor) | 1.02 ms | 203 ms |
| `sh -c "echo hi"` | 2.41 ms | 482 ms |
| `git describe --always` | 13.29 ms | 2 657 ms |

One command-valued field costs roughly 370x an entire manifest parse at the
floor, and about 2000x for anything realistic. A shell command is also a
*larger* hole than the evaluated-manifest option §6 already rejected: `eval`
has `^policy` step and capability limits, and a subprocess has none.

The workable shape has five rules:

1. **`^name`, `^version`, and `^dependencies` are always literal.** Resolution
   reads them from every node in the graph to build and validate it, so a
   computed value there means resolution cannot run offline, a lockfile cannot
   be generated, and `gene pkg add` cannot rewrite the file. This is the
   `setup.py` failure, and it is the rule the other four depend on.
2. **Any other field may be command-valued**, with the output taken as a string
   or parsed as Gene. A parsed result is validated against *that field's*
   schema; it is never spliced into the manifest, or a command could inject
   `^dependencies` and defeat rule 1.
3. **Evaluation is lazy** — on first read, not at load. Combined with rule 1
   this is what keeps consumers safe: resolution only ever touches literal
   fields, so importing a package never spawns a process no matter what its
   optional fields contain.
4. **Results are memoized** per Application. Caching *across* runs needs the
   command to declare its inputs, the way `cargo:rerun-if-changed=` does —
   output depends on git state, environment, and the filesystem, so no valid
   cache key can be derived from the manifest alone. Undeclared inputs are how
   `$(shell …)` makes a Makefile both slow and non-reproducible.
5. **Publishing freezes every computed field.** Anything in a package store is
   fully literal. Rule 3 already protects resolution; this closes the remaining
   case where inspecting a dependency's metadata would run that dependency's
   shell command.

Cost then lands once on the author instead of on every consumer, transitively,
which is what Cargo does when `cargo publish` normalizes a manifest, npm does
by running `prepack` for the publisher and never the installer, and Maven's
flatten plugin exists to do for `${revision}`.

Two expectations are worth stating because they are assumptions rather than
guarantees. Most packages should never need this, so the cost is proportional
to use rather than to graph size — but it is weighted by *popularity*, since a
computed field in a widely depended-on package is paid by everyone below it.
And Gene applications are expected to have small dependency graphs, which the
deliberately broad standard library supports; that is a reasonable bet, but it
is a policy rather than a mechanism, and rules 1 and 3 are what keep resolution
cheap by construction if the bet is ever wrong.

### Existing manifests

Two `package.gene` files already exist in the tree, and neither validates
against the schema above:

```gene
# examples/todo_app/package.gene
{^name "todo-app" ^description "Gene Todo Example" ^version "0.1.0" ^dependencies []}

# examples/ai_agent/package.gene
{^name "genni-agent" ^description "Genni - your special agent" ^version "0.1.0" ^dependencies []}
```

Three conflicts, each resolved by this proposal:

- **`^name` has no owner segment.** `"todo-app"` is a bare name, not
  `<owner>/<name>`. Resolved by requiring the owner segment; the examples
  become `gene/todo_app` and `gene/ai_agent`.
- **`^name` is hyphenated.** The grammar requires `snake_case` segments. These
  names are string *values*, not registered Gene names, so the repository's
  naming convention does not decide this on its own — the package-name grammar
  does, and it chooses the same `snake_case` rule.
- **`^description` is not in the field table**, and §13 requires rejecting
  unknown fields. Resolved by adding `^description` as an optional
  documentation field.

Both manifests are updated to `gene/todo_app` / `gene/ai_agent` in the same
change that lands schema validation (Stage 1), so the committed examples
become positive validation tests rather than breakage.

## 7. Package stores

Both stores use the package name as a directory path:

```text
vendor/packages/
└── acme/
    └── json/
        ├── package.gene      # ^name "acme/json"
        └── src/
            └── index.gene

~/.gene/packages/
└── acme/
    └── json/
        ├── package.gene      # ^name "acme/json"
        └── src/
            └── index.gene
```

Lookup constructs the candidate path directly —
`<store>/<owner>/<name>/package.gene` — and never enumerates store
directories, so neither the result nor the cost of resolution depends on what
else happens to be installed.

The initial on-disk contract permits one active version of a package name per
store. `^version` remains part of package identity and dependency validation,
but the resolver does not scan version-named subdirectories or choose a
"latest" version. A future package manager may back this logical layout with a
versioned or content-addressed cache, provided the resolver still receives one
unambiguous candidate for each store and package name.

The stores have different roles:

| Store | Location | Ownership | Portability | Precedence |
|---|---|---|---|---:|
| Application | `<application_root>/vendor/packages/` | application/project | may be copied or committed with the application | 1 |
| User | `~/.gene/packages/` | current user | machine-local | 2 |

The application store is always anchored to the entry application's root. A
dependency's own `vendor/packages/` does not introduce another search tier.
This prevents resolution from changing according to the route by which a
package was reached and ensures the Application owns one dependency graph.

The user-store path should be obtained through a platform-aware runtime helper.
`~/.gene/packages/` is the normative user-visible spelling; the helper is
responsible for expanding the home directory without consulting Gene code.

The resolver does not search arbitrary siblings, ancestors named `packages`,
the runtime installation directory, or the current module directory for named
packages. Additional package roots, if introduced later, must be explicit and
ordered rather than ambient guesses.

## 8. Dependency declarations

A dependency declaration associates a package name with a version requirement
or an explicit path:

```gene
^dependencies [
  (dep "acme/json" "1.4.2")
  (dep "acme/local_tools" ^path "../local_tools")
]
```

For the first implementation:

- a string version is an exact version, not a semver range;
- a store declaration must carry an exact version, and the candidate's
  `^version` must match it;
- a `^path` declaration may omit the version; when present it must match
  exactly;
- `^path` is resolved relative to the declaring package root;
- a path dependency must contain `package.gene`;
- the dependency manifest's `^name` must match the declared name;
- duplicate dependency names are an error;
- dependency cycles are reported with the package chain.

Regular packages may import only themselves and their declared direct
dependencies. Transitive presence in a package store does not grant a direct
import. Ad-hoc packages have no manifest, so named imports resolve directly
against the two stores; they still receive ambiguity, identity, and boundary
checks.

### Conflicting requirements across the graph

`^dependencies` rejects duplicates *within one manifest*, but the interesting
conflict is across packages, and the rules above make it unavoidable rather
than rare: §7 permits one active version per package name per store, and
versions are exact. So if `acme/app` requires `acme/json 1.4.2` while its
dependency `acme/http` requires `acme/json 1.3.0`, exactly one candidate exists
and one of the two requirements cannot be met.

Resolution **fails** in this case, with a `PACKAGE_VERSION_CONFLICT`
diagnostic (§12) naming both requiring packages and the single candidate.
Failing is deterministic, and it never silently runs a package against a
version it did not ask for. The alternatives were rejected: satisfying the
application and warning for transitive mismatches makes "exact version"
untrue for every package except the root, and permitting multiple installed
versions is explicitly deferred (§17). Failing is the only rule consistent
with exact versions and with §9's refusal to fall through past a
wrong-version candidate, and it keeps the first resolver from quietly
becoming a partial solver.

`PACKAGE_VERSION_CONFLICT` is a distinct error class from
`PACKAGE_VERSION_MISMATCH` — one requirement against one candidate is a
different failure from two requirements that cannot both hold, and the two
must not share a message.

### Path dependencies and the application boundary

`(dep "acme/local_tools" ^path "../local_tools")` resolves *outside* the
application root by construction, which sits awkwardly beside §4's "the entry
file must be inside the selected application root" and §13's "reject package
and module path traversal". These are not actually in conflict, but only
because they constrain different things, and the proposal should say so:

- a **path dependency** may point anywhere the author can name, and becomes its
  own package with its own root;
- **module resolution** inside any package, including that one, may never leave
  that package's canonical root.

So `..` is legal in a dependency path and illegal in a module path. Stating
that explicitly is what stops an implementer from applying the traversal check
at the wrong level and breaking either sibling-checkout development or the
boundary guarantee.

Semver ranges, dependency solving, lockfile generation, and fetching are
separate concerns. Exact versions make the first local resolver useful without
silently defining a partial solver.

## 9. Package resolution

A package-qualified import keeps module selection separate from package
selection:

```gene
(import [parse] from "." ^pkg "acme/json")        # the package entry (§10)
(import [schema] from "schema" ^pkg "acme/json")  # a named module
```

Two constraints from the existing `import` form, both of which this proposal
must extend deliberately rather than assume:

- The selection is a **list**, and `parseImportSpec` requires the path string to
  be the final body element. `^pkg` is a prop, so it does not disturb that.
- `import` currently rejects every prop except `^export` with
  `"import got unexpected option: ^…"`, and rejects `^as` specifically with
  `"import ^as was removed; use \`source : alias\`"`. Adding `^pkg` means
  widening that closed allow-list, which is the right shape — both messages
  are part of the surface and must stay exhaustive.
- `^pkg` is valid only on the `from` form. A namespace-path import such as
  `(import acme/json [parse])` carries no package selection: a bare namespace
  path never selects a package, and `^pkg` without `from` is rejected.
  Package selection is always explicit.

Resolution has **two phases**, and the split is what makes §8's conflict rule
reachable at all. Selecting a candidate and validating a version cannot happen
in the same step: a conflict is a property of two *requirements*, so no
procedure that examines one import at a time can detect one. Interleaving them
would also make the reported error depend on which import happened to resolve
first, which §2 forbids.

**Phase 1 — select and collect.** Starting from the application package, walk
declared dependencies. For each package name reached:

```text
1. Validate the ^pkg value as a string satisfying the package-name grammar
   (else PACKAGE_NAME_INVALID).
2. If the importer refers to its own package name, use the importer package.
3. For a regular importer, require a matching direct dependency declaration
   (else PACKAGE_NOT_DECLARED).
4. If that declaration has ^path, resolve and validate that path.
5. Otherwise check <application_root>/vendor/packages/<owner>/<name>/package.gene,
   and only if no application candidate exists,
   ~/.gene/packages/<owner>/<name>/package.gene.
6. Validate the candidate's own ^name against the requested name
   (else PACKAGE_IDENTITY_MISMATCH).
7. Read its manifest and record its declared dependencies as further
   requirements.
```

Candidate selection is by constructed path (§7), never enumeration, so both the
reachable set and the candidate chosen for each name are independent of
traversal order. **No version is validated in this phase.**

**Phase 2 — validate versions.** For each package name in the collected
requirement table:

```text
if two or more declarations require different exact versions
  -> PACKAGE_VERSION_CONFLICT, naming every requiring package
else if the single required version != the selected candidate's ^version
  -> PACKAGE_VERSION_MISMATCH, naming the requirement and the candidate
```

Failures are reported sorted by package name, then by requiring package name,
so the diagnostic for a given graph is identical on every run and every
machine. A `^path` declaration that omits its version (§8) contributes no
requirement and so can never produce either failure.

Module resolution inside the selected package (§10) happens after phase 2, so
no module is ever loaded from a package whose version was never agreed.

An existing application-store candidate is authoritative. If it is malformed,
has the wrong name, or has the wrong version, resolution fails; the resolver
must not fall through to the user store. This prevents a broken or tampered
vendored package from being masked by machine-local state.

The selected package root is canonicalized before it enters the Application's
package table. Symlinks may be supported, but validation and containment checks
operate on the canonical target so a symlink cannot escape a package boundary
unnoticed.

## 10. Module resolution within a package

After selecting a package, the module resolver searches within that package
only. For a regular package, the initial module bases are:

```text
<package_root>/<source_dir>/
<package_root>/
```

The declared `source_dir` wins. The root fallback supports intentionally flat
packages and migration from ad-hoc layouts. (For an ad-hoc package
`source_dir` is the root, so the two bases coincide.) Resolution must not add
unrelated fallbacks such as `lib/` or `build/` unless a later proposal makes
them part of the language contract.

**Every module name resolves literally. The package entry is spelled `"."`:**

```gene
(import [parse] from "." ^pkg "acme/json")        # the package entry
(import [schema] from "schema" ^pkg "acme/json")  # a named module, literally
```

`"."` is the only module path the resolver rewrites, and it rewrites to
`main_module`. It can never collide with a real module because `.` does not
name a file, and it works identically for regular and ad-hoc packages — an
ad-hoc package's `main_module` is the entry the command supplied.

No module *name* is magic. An earlier draft mapped the name `"index"` to
`main_module`, which forced a rule forbidding a package from keeping both a
non-`index` `main_module` and a `<source_dir>/index.gene`, because the literal
file became unreachable. That rule was a symptom: a name-level indirection
makes one real filename unaddressable, and the fix is to stop overloading a
name rather than to prohibit the file. `^main_module` still means what §6 says
— the package's entry — and is now the *only* thing `"."` consults.

For every other module name, normal extension defaulting and ambiguity rules
apply.

Every resolved module path must remain inside the selected package root after
canonicalization. A package-qualified import cannot use `..`, symlinks, or an
absolute path to escape the package.

The portable module identity is:

```text
<package_identity>::<normalized_module_path>
```

For example:

```text
acme/json@1.4.2::schema
<ad_hoc:application>::tools/inspect
```

The filesystem path is retained for diagnostics and source loading but is not
the cache key by itself. The Application load-once cache keys modules by
package identity plus normalized module path so two packages with identical
relative layouts cannot collide.

## 11. Runtime model

An Application owns:

```text
application package
application root
application and user store roots
resolved package table
resolved dependency edges
module cache keyed by package/module identity
```

A Package record contains at least:

```text
kind: ad_hoc | regular
name: Str | nil
version: Str | nil
root: canonical path
manifest_path: canonical path | nil
source_dir: normalized relative path
main_module: normalized module path
test_dir: normalized relative path
dependencies: validated direct dependency declarations
origin: entry | application_store | user_store | path_dependency
```

`origin` is provenance for diagnostics and for `gene pkg locate` (§14); it
never participates in package identity.

Each loaded Module links to its owning Package. The compiler provides a lexical
`this_pkg` binding alongside `this_mod`; it is not a process-global current
package. Package metadata accessors use `snake_case`, including `source_dir`,
`main_module`, and `test_dir`.

Package records and manifests are cached per Application. Import hot paths must
not reparse manifests, rescan ancestors, or enumerate package stores. Package
resolution happens once per dependency edge, and subsequent imports use the
resolved package table directly.

## 12. Diagnostics

Package failures should identify the importer, requested package, and searched
locations without exposing irrelevant global state.

Required error classes include:

```text
PACKAGE_MANIFEST_INVALID
PACKAGE_NAME_INVALID
PACKAGE_NOT_DECLARED
PACKAGE_NOT_FOUND
PACKAGE_IDENTITY_MISMATCH
PACKAGE_VERSION_MISMATCH
PACKAGE_VERSION_CONFLICT
PACKAGE_BOUNDARY
PACKAGE_DEPENDENCY_CYCLE
MODULE_NOT_FOUND
MODULE_AMBIGUOUS
```

`PACKAGE_VERSION_MISMATCH` is one requirement against one candidate;
`PACKAGE_VERSION_CONFLICT` is two requirements that cannot both hold (§8). A
reader needs to know immediately whether to fix a store or a manifest.

Example:

```text
PACKAGE_VERSION_MISMATCH: acme/my_app requires acme/json 1.4.2
  importer: acme/my_app::main
  candidate: /work/my_app/vendor/packages/acme/json/package.gene
  found version: 1.3.0
  user store was not searched because an application candidate exists
```

```text
PACKAGE_VERSION_CONFLICT: acme/app and acme/http require incompatible acme/json versions
  acme/app requires acme/json 1.4.2
  acme/http requires acme/json 1.3.0
  single candidate: /work/app/vendor/packages/acme/json/package.gene (found version 1.4.2)
```

Diagnostics should preserve user-spelled import text while also showing the
normalized package/module identity when useful.

## 13. Security and reproducibility

Package discovery and loading are code-loading operations. The implementation
must therefore:

- parse manifests as data without executing them;
- reject unknown control fields according to the manifest schema (duplicate
  map keys cannot be rejected after parsing — the reader collapses them
  last-wins — so duplicate detection applies only where it stays observable:
  repeated dependency names in `^dependencies`, §8);
- canonicalize paths before containment checks;
- reject package and module path traversal;
- never fall back past an invalid higher-precedence candidate;
- avoid network access during ordinary import resolution;
- avoid using process `cwd` after Application initialization;
- keep native-library trust and loading out of this initial package resolver.

"No network access during ordinary import resolution" needs one carve-out
stated rather than left implicit: the experimental `gene runurl` entry
(design §15.9) *does* fetch module sources, gated by
`Application.allowUrlModules` and enabled only by that entry. A URL entry has
no entry file, so its application package is discovered from the launch
working directory (§4). The rule this proposal wants is that **package
resolution never fetches** — a URL-entry application still resolves named
packages from the two local stores, and no `package.gene` lookup may reach
the network. A URL module graph and a package
store are separate mechanisms, and neither should silently acquire the other's
authority.

Vendoring improves reproducibility but is not by itself an integrity system.
Content hashes, signatures, and lockfile verification belong to a later package
installation proposal.

## 14. CLI behavior

The package context applies consistently to every command that creates an
Application — `run`, `runurl`, `eval`, `repl`, `compile`, `build`, and future
test and dependency commands. Pure reader commands (`parse`, `fmt`) have no
package context. Each Application-owning command must:

- determine the discovery start directory from the entry (§4) and capture the
  launch working directory;
- discover the nearest regular package or create an ad-hoc package;
- preserve the process working directory;
- expose the same application root and stores to every command;
- use the same manifest parser and resolver implementation.

Useful inspection commands may include:

```sh
gene pkg show
gene pkg locate acme/json
```

These command names are proposed interface, not required for the first runtime
slice. They must report whether the application package is `ad_hoc` or
`regular` and show which store supplied a dependency.

## 15. Implementation stages

### Stage 1: package context

- Discover the nearest `package.gene`.
- Create ad-hoc and regular Package records.
- Parse and validate the regular manifest.
- Migrate the two committed example manifests to the final schema (§6).
- Link every Module to its Package.
- Key the module cache by package/module identity.

### Stage 2: local stores

- Add the application and user package stores.
- Add deterministic precedence and manifest identity validation.
- Add exact-version and explicit-path dependency validation.
- Add package-qualified imports and package boundary checks.

### Stage 3: tooling

- Add package inspection commands.
- Add install/copy tooling for application and user stores.
- Add dependency graph and cycle diagnostics.

### Stage 4: reproducibility

- Design lockfile and content-hash semantics.
- Permit multiple installed versions behind a deterministic selection index.
- Integrate package metadata into `.gapp` application images.

Each stage should add executable examples to `tests/spec_runner.nim` when it
introduces language-visible behavior.

## 16. Required test matrix

The implementation must cover at least:

- nearest-parent manifest discovery;
- discovery from the entry file's directory, including `gene run` invoked
  from an unrelated working directory;
- ad-hoc creation when no ancestor manifest exists, anchored at the entry
  file's directory for file commands and at the launch cwd for file-less
  entries;
- an explicit package-root override rejecting an entry file outside the
  override root;
- no implicit manifest creation;
- regular manifest defaults and validation;
- imports within ad-hoc and regular package roots;
- application-store resolution;
- user-store fallback;
- application-store shadowing of the user store;
- invalid application candidate blocking user fallback;
- package name and exact-version mismatch;
- conflicting exact-version requirements from two packages report
  `PACKAGE_VERSION_CONFLICT`, not `PACKAGE_VERSION_MISMATCH` (§8, §9);
- the same conflicting graph produces a byte-identical diagnostic when the
  importing order is reversed — the property the two-phase split in §9 exists
  to guarantee, and the one a single-pass resolver silently loses;
- a `^path` dependency that omits its version contributes no requirement and
  triggers neither version failure;
- undeclared direct dependency rejection for regular packages;
- store dependency declarations without an exact version rejected; `^path`
  declarations without a version accepted;
- `^pkg` rejected on a namespace-path import (no `from`), and a bare
  namespace path never selecting a package;
- `"."` resolving to `main_module` in regular and ad-hoc packages, and a
  module literally named `index` remaining reachable as `"index"` in a package
  whose `main_module` is something else;
- direct store import from an ad-hoc package;
- explicit path dependencies relative to the declaring package, including one
  resolving outside the application root, whose own modules still cannot
  escape its package root;
- `dep` as the literal dependency head, and rejection of `$dep`, whose head is
  a `(path gene dep)` node rather than a symbol;
- manifest rejection of unknown fields, and validation of the migrated
  committed example manifests (§6);
- if computed fields are ever implemented: a command-valued optional field is
  never evaluated during resolution, and a command-valued `^name`, `^version`,
  or `^dependencies` is rejected outright (§6);
- a URL-entry application discovering its package from the launch cwd and
  resolving named packages from local stores with no network access during
  package resolution (§13);
- package and module traversal rejection, including symlinks;
- duplicate module names in separate packages without cache collision;
- load-once behavior across repeated imports;
- dependency-cycle diagnostics;
- unchanged process working directory;
- `readAll` manifest parsing: exactly one map datum, with a second top-level
  form of any kind rejected;
- `snake_case` for every registered package-facing name.

Performance tests should verify that a cached import performs no manifest read,
ancestor walk, package-store enumeration, or avoidable allocation.

The measured budget from §6 is the one to hold: resolving a 200-package graph
should stay dominated by filesystem I/O (~3 ms), with manifest parsing adding
well under a millisecond. A regression here means something reparsed, rescanned,
or re-walked — not that parsing got slower.

## 17. Deferred work

This proposal intentionally defers:

- hosted registries and remote discovery;
- command-valued manifest fields (designed in §6, not implemented; literal
  manifests only through Stage 2);
- semver range solving;
- lockfile format and update policy;
- content-addressed storage and garbage collection;
- package publishing;
- package signatures and trust policy;
- native dependency selection and ABI policy;
- multi-package workspaces;
- globally configured search-path stacks;
- multiple active versions of one package name in a single store.

Those features can build on the Package identity and Application-owned
resolution graph defined here without changing the ad-hoc/regular distinction
or the application-before-user store precedence.

## 18. Summary

The package contract is deliberately local and predictable:

```text
nearest package.gene found from the entry file's directory
(or the launch working directory for file-less entries)
  -> regular application package
otherwise
  -> ad-hoc application package rooted at the discovery start directory

named dependency lookup
  -> explicit path, when declared
  -> <application_root>/vendor/packages/
  -> ~/.gene/packages/
  -> error
```

This keeps one-file Gene programs frictionless, gives regular applications a
real package boundary, and provides both project-local reproducibility and
user-level reuse without introducing a registry or an underspecified version
solver.
