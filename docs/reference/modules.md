# Applications, packages, modules, and namespaces

**Status:** detailed design reference and rationale. The implemented contracts
are [modules](../spec/modules.md), [authority](../spec/authority.md).
Deferred sections describe future work. Original chapter numbers are retained
for source comments and older discussions. [Reference index](README.md).

## 15. Applications, packages, modules, and namespaces

Gene has an explicit runtime/code-loading hierarchy:

```text
Application
  └── Package
        └── Module
              └── Namespace
                    ├── bindings
                    ├── types
                    ├── protocols
                    ├── impls
                    └── nested namespaces
```

For MVP:

- an **Application** is one running Gene program and owns the runtime state;
- a **Package** owns source identity, declared dependencies, and build targets;
- a **Module** is a unit of code loaded from a file, source string, REPL/eval unit, or generated overlay;
- a **Namespace** is a binding scope inside a module.

Dependency solving, package versions, lockfiles, and local registry/store
materialization are implemented in [packages](../packages.md). Hosted registry
transport and publication remain deferred. Application startup, module identity,
namespace binding, and `main` follow the [module contract](../spec/modules.md).

### 15.1 Program startup

Starting a Gene program creates an `Application`.

Startup sequence for `gene run`:

```text
create Application
→ locate/load entry package
→ locate/load entry module
→ create the entry module's root namespace
→ execute the entry module top to bottom
→ if the entry module has a `main` binding, call it with command-line arguments
```

Example entry point:

```gene
(fn main [args : (List Str)] : Int
  ...)
```

A flexible dynamic entry point is also valid:

```gene
(fn main [args]
  ...)
```

`main` return convention for MVP:

```text
Nil  -> process exit code 0
Int  -> process exit code Int
else -> boundary TypeError for `gene run`
```

Top-level forms still execute in order before `main` is called. A module may intentionally perform all work at top level and omit `main`, but applications intended for `gene run` should normally provide `main`.

### 15.2 Application

`Application` is a runtime object, not a global ambient value automatically visible to all code.

Conceptually, an application owns:

```text
loaded package records
loaded module cache
application root path
module search paths
root capabilities granted by the host/CLI
command-line arguments
environment variables, if granted
scheduler and actor system
eval/cache state
native module registry
```

External-operation authority comes from the active inherited capability context.
Ordinary arguments and Env bindings carry data, functions, or resource handles;
they cannot mint grants or bypass the operation's active-context checks.

### 15.3 Package

A package groups modules and carries identity, a source layout, and declared
dependencies. There are two kinds of application package:

```text
application package
├── ad-hoc package: no package.gene was found
└── regular package: rooted at the nearest package.gene
```

Starting an Application selects one of them by walking *ancestors* from a
discovery start directory. A file-oriented command (`run`, `compile`, `build`,
`doc`) starts at the entry file's canonical parent directory, so
`gene run /elsewhere/script.gene` keeps working from any working directory and
a script tree carries its package with it. A file-less entry (`eval`, `repl`,
`runurl`, `pkg`) starts at the launch working directory, captured once. The
first `package.gene` found wins, so a nested package is a real boundary.
Nothing is generated implicitly: adding a `package.gene` later deliberately
turns a directory into a regular package.

`--package-root <dir>` replaces the discovery start directory explicitly. It
never changes the process working directory, and with it in effect the entry
file must be inside the override root.

A regular package's `package.gene` is exactly one map datum, read with
`readAll` as **data**. It is never executed: a manifest is read during
*resolution*, before any import of that package has been admitted, so
executing it would run third-party code before trust exists, make the
dependency set unreproducible, and give resolution no upper bound in time.

```gene
{
  ^format 1
  ^name "acme/my_app"
  ^version "0.1.0"
  ^description "…"
  ^library {^entry "src/index.gene"}
  ^applications [(application "my_app" ^entry "src/main.gene")]
  ^dependencies {
    ^json  (dep "acme/json" "^1.4.0")
    ^tools (dep "acme/local_tools" ^path "../local_tools")
  }
}
```

`^format 1` and `^name` are required, and a manifest without `^format 1` is
rejected outright — there is no dual-read period for the earlier prototype
shape. Unknown fields are rejected, and so is a repeated one: the manifest
reader runs with duplicate-property rejection on, because two spellings of one
field would otherwise give a manifest two meanings. Package names are
`<owner>/<name>` with lowercase `snake_case` segments — string *values*
governed by this grammar rather than by the registered-name convention, though
both land on `snake_case`. Manifest paths are `/`-separated, relative, free of
empty/`.`/`..` segments, and must already be Unicode 15.1 NFC; the tables are
pinned in-tree so an identity never depends on the host's ICU version.

The dependency head is the plain symbol `dep`: `$dep` is sugar for the
`gene/dep` member path and reads as `((path gene dep) …)`, so a manifest can
never appear to name something in the standard library.

A package declares its *targets*, not a source directory to be scanned:

```text
^library      {^entry "…"}                     at most one
^applications [(application "name" ^entry "…")] any number
^tests        {^root "tests"}
```

The library entry's parent directory is the package's single module base
(§15.6). `^workspace {^members ["packages/*"]}` makes the package a workspace
root whose members are independently buildable and share one lock.

Dependencies are a *map keyed by alias*, in three scopes — `^dependencies`,
`^dev_dependencies`, and `^build_dependencies`. The alias, not the package
name, is what imports resolve against, so one manifest can depend on two
versions of one name under two aliases and both are live at runtime. A `dep`
takes a name and at most one version constraint, and selects at most one source
— `^registry`, `^git`, `^path`, or `^workspace true` — defaulting to the
configured registry. A git dependency additionally requires exactly one of
`^commit`, `^tag`, or `^branch`; registry and workspace dependencies require a
constraint:

```gene
^dependencies {
  ^json (dep "acme/json" "^1.4.0")                     # registry
  ^wip  (dep "acme/json" ^git "…" ^commit "…")         # one exact commit
  ^util (dep "acme/util" ^path "../util")              # sibling checkout
  ^tool (dep "acme/tool" "1.0.0" ^workspace true)      # co-lived member
}
```

Resolution runs once, up front, over the whole declared graph — a version
conflict is a property of two *requirements*, so no procedure that examines one
import at a time can see one. The solver minimizes the number of instances that
satisfy every constraint, expands feature selections, and enforces packages
declared `^singleton` to exactly one instance. `PACKAGE_VERSION_MISMATCH` is one
requirement against one candidate; `PACKAGE_VERSION_CONFLICT` is two
requirements that cannot both hold. Failures are reported in sorted order, so a
given graph produces the same diagnostic on every run and every machine.

The result is written to `package.gene.lock` at the workspace root: one lock
covering every scope and every member, which each command projects down to the
subset it needs. A valid locked edge is retained until it is explicitly
unlocked (`gene pkg update`), so re-resolving does not silently move a
dependency. `gene pkg sync` materializes the locked graph into the immutable
store; nothing else writes package objects there.

```text
user store:   ~/.gene/packages/   (GENE_USER_PACKAGES overrides it)
vendor store: <workspace>/vendor/packages/  + vendor.gene.lock
```

Store objects are content-addressed and immutable, so acquisition is never
partial and never in place. A matching vendor object is authoritative: if it is
corrupt it is reported rather than falling through to machine-local state.

Each resolved *instance* gets an id of the form
`<source>:<name>@<version>#<digest>`, where the digest covers what the instance
actually came from — registry source plus tree digest, git remote plus commit
plus tree digest, a workspace-relative path plus manifest digest, and so on.
Identity is therefore the instance, not the name: the same name resolved from
two registry sources is two packages, and two versions of one name coexist
without aliasing. An ad-hoc package's id is `ad_hoc:<digest of its root>`.

A regular package may import only itself and its declared direct dependencies,
by alias; transitive presence in a store grants nothing.

A package record carries:

```text
kind: ad_hoc | regular
id, format, name, version, description
root, manifest_path
source_dir, main_module, test_dir
dependencies: alias, name, constraint, scope, source, path
origin: entry | workspace | registry_source | application_store
      | user_store | path_dependency
```

`origin` is provenance for diagnostics; it never participates in identity. Each
module body receives a compiler-provided lexical `this_pkg` binding alongside
`this_mod` — a map whose keys are the fields above, in `snake_case` — never a
process-global current package.

Module identity is logical, not a filesystem path:

```text
<package_identity>::<normalized_module_path>

pkg:acme/json@1.4.2#sha256:…::schema
<ad_hoc:application>::tools/inspect
```

The package half is the resolved instance id, so two instances of one name
never share a module identity. The Application's load-once cache keys on the
whole string, so two packages with identical relative layouts cannot collide.
Absolute paths remain provenance for diagnostics and source loading.

Every package and module failure is prefixed with one diagnostic class, so a
reader can tell at a glance whether to fix a store, a manifest, or an import:

```text
PACKAGE_MANIFEST_INVALID   PACKAGE_NAME_INVALID      PACKAGE_NOT_DECLARED
PACKAGE_NOT_FOUND          PACKAGE_IDENTITY_MISMATCH PACKAGE_VERSION_MISMATCH
PACKAGE_VERSION_CONFLICT   PACKAGE_BOUNDARY          PACKAGE_DEPENDENCY_CYCLE
PACKAGE_STORE_BUSY         MODULE_NOT_FOUND          MODULE_AMBIGUOUS
```

Deferred package features (`docs/packages.md` §14):

- hosted registries and remote discovery — the shipped registry adapter reads a
  local filesystem tree, and `gene pkg publish` requires an adapter that does
  not exist yet;
- package signatures and trust policy;
- command-valued manifest fields.

### 15.4 Module

A module is a code unit:

```text
source file
source string passed to `gene eval`
REPL cell/session unit
generated/eval overlay unit
```

A module has:

```text
source identity
normalized module path, when file-backed
root namespace
declaration stream
top-level forms
imports
execution state
metadata/provenance
```

A module can be written explicitly:

```gene
(mod web_demo
  @doc "demo module"
  ...)
```

A file may also have an implicit module wrapper derived from its normalized module path.

`mod` is a top-level declaration/special form:

```gene
(mod name
  body...)
```

Rules:

- `mod` names the module and provides the module body;
- if a file has no explicit `mod`, the loader creates an implicit module from the normalized module path;
- the module body executes in the module's root namespace;
- nested `mod` forms are invalid in MVP;
- duplicate explicit `mod` declarations in one file are invalid.

Each module body receives a compiler-provided lexical binding:

```gene
this_mod : Module
```

`this_mod` is an ordinary read-only binding created by the module loader. It is not selector magic and is not imported from another module. It may be used with ordinary selectors and reflection helpers:

```gene
this_mod/%declarations
(this_mod .path)
```

Top-level execution rules:

- top-level forms execute from top to bottom;
- declarations create bindings in the current namespace;
- ordinary expressions execute for side effects and their result is normally discarded by `gene run`;
- macro imports are resolved from compile artifacts before expansion; runtime
  import operations initialize and bind dependencies at their execution point;
- a module is loaded/executed at most once per application/module graph unless explicitly reloaded or evaluated as a separate overlay.

Both compile-time macro dependency cycles and runtime initialization cycles are
detected and rejected with phase-specific diagnostics (§15.6). Future versions
may admit declaration-only cycles.

### 15.5 Namespace

Every module has one root namespace. A namespace contains bindings for values,
types, protocols, implementations, macros, and nested namespaces. Named
declarations are public by default. An unconditional module/namespace
declaration may use `^private true`; the binding remains usable and reflectable
inside its namespace but is absent from the module's compile interface and
cannot be selected, wildcard-imported, or re-exported. Dynamic declarations
cannot be marked private because they are not part of a guaranteed export
interface.

Nested namespaces are declared with `ns`:

```gene
(ns html
  (type Node
    ...)

  (fn div [children...]
    ...))
```

Nested access uses qualified names:

```gene
html/Node
html/div
```

`ns` is a declaration/special form:

```gene
(ns name
  body...)
```

Rules:

- creates or opens a child namespace under the current namespace;
- declarations inside bind into that namespace;
- nested namespaces are allowed;
- duplicate binding names in the same namespace are errors unless an explicit replacement/reload operation is used;
- top-level executable forms inside `ns` execute when the module executes;
- namespace values can be imported, passed, reflected on, and inspected through module/namespace APIs.

Nested namespaces are ordinary namespace bindings. If a module exports a nested namespace, another module may import that namespace or selected bindings under it:

```gene
(import html from "./web")              # import exported nested namespace `html`
(import [html/div : div] from "./web")  # import nested binding with alias
```

Qualified names in static contexts such as `html/Node`, `Stream/next`, and `C/Int32` are resolved by the compiler/name resolver, not by runtime selector evaluation.

### 15.6 Imports, exports, and path normalization

#### Reserved standard-library roots

`gene`, `genex`, `geney`, and `genez` are reserved standard-library root
namespaces. They are reserved in *binding* position the way core special forms
are reserved in head position: user code may not declare, bind, alias,
import-as, or shadow them anywhere. The standard library lives under `gene`, so
every built-in is reachable qualified — `gene/map`, `gene/str/join`,
`gene/net/http/serve`. There is no `std` namespace; the former `std/*`
stream/node/parse namespaces are `gene/stream`, `gene/node`, `gene/parse`.

**`$x` is sugar for `gene/x`**, so the qualified form costs one character:
`$map`, `$str/join`, `$Actor`, `$net/http/serve`. It reads as the ordinary
member path it desugars to — `$foo` is exactly `(path gene foo)` — and since
the `gene` root cannot be shadowed, `$x` always means the standard library
regardless of what is bound locally.

The sigil is unambiguous against the two other uses of `$`, because `"` is not
a symbol character: `$"a ${b}"` stays interpolation and a lone `$` stays the
concat head (`($ "a" 1)` → `"a1"`). Only `$` immediately followed by a symbol
character is a member path.

This is what lets the bare surface shrink, and it now has: **nothing is
special except keywords, operators, and the reserved roots.** A bare name means
whatever the program binds it to, and the standard library is reached through
`$`. `(println …)` is an error; write `($println …)` or import the name.

The split is by **case**, because case already tells types from functions:

- An **uppercase** name is a *type* — a type value (`Int`, `Str`, `Cell`,
  `List`, `Map`, `Actor`), an error type (`TypeError`), or a message namespace
  for the surfaces not yet moved onto their type (`AtomicCell`, `Task`, `C`).
  These
  stay bare, because type annotations resolve names structurally rather than as
  bindings — `[xs : List]` must keep working, and `[xs : $List]` is not how an
  annotation reads. Uppercase names are also the ones a program is least likely
  to collide with by accident.
- A **lowercase** name is a library function or namespace (`println`, `map`,
  `cell`, `str`, `net`). These move under the `gene` root and are reached as
  `$x`.
- **Operators** (`+ - * / // < <= > >= == != $`) stay bare — a closed set the
  user is not expected to declare — as do a few language-level words spelled as
  names: `panic` (§9), and `not`/`same?`, the spelled forms of `!` and identity.

The VM resolves its own needs — built-in type messages, the error types it
raises — from the `gene` scope rather than the lexical chain, so a program that
binds `TypeError` locally cannot change which type an internal raise builds.

`GENE_BARE_BUILTINS=1` restores the old fully-bare surface. It exists only to
collect the bare-name lint against unmigrated sources and is not a supported
runtime mode.

The four roots form a library lifecycle in which each transition is a root-swap
with the internal path preserved (a mechanical rename that defers the semantic
migration and frees the stable name for a replacement):

```text
genex/foo   (incubating, unstable)
  → gene/foo   (stable)
    → geney/foo  (retiring: frozen, bugfix-only, with a deletion deadline)
      → deleted
```

A path lives under exactly one root at a time; a vacated name errors with a
pointer to its new location. Only `gene` and `genex` are defined today (`genex`
is an active but empty root); `geney`/`genez` stay reserved but undefined until
first needed. Tooling may warn on `genex` (unstable) and `geney` (retiring)
imports.

`import` supports two source forms:

1. importing from a built-in or already-loaded namespace path;
2. importing from a normalized module path string using `from "path"`.

Built-in / namespace imports:

```gene
(import gene/stream [map, filter, into])
(import gene/stream [map : stream_map, filter])
(import gene/stream : stream)
```

Module-path imports:

```gene
(import * : math from "./math")         # qualified module alias: math/...
(import * from "./math")                # bare-name fallback
(import ops/* : ops from "./math")      # alias one exported namespace
(import ops/* from "./math")            # namespace bare-name fallback
(import add from "./math")              # one selected binding
(import [add, sub] from "./math")       # selected bindings
(import [add : plus, sub : minus] from "./math")
(import Config from "/app/config")
```

Rules:

- `gene/stream` in source position is a static namespace path, not a string module path and not runtime selector evaluation;
- `from "path"` is the only MVP form that names a file/string module path;
- selected imports bind public names from the source namespace/module root;
- `name : alias` is the single import-renaming syntax, including namespace and
  module aliases; `^as` is invalid;
- commas inside the import list are optional separators;
- `* : alias` and `n/* : alias` create one ordinary qualified binding;
- bare `*` and `n/*` create fallback candidates, not bindings, and therefore
  do not appear in reflection or re-export implicitly;
- wildcard, alias, and re-export imports from module paths must be
  unconditional static module/namespace forms; ordinary selected imports
  retain runtime placement;
- wildcard/alias module imports are rejected by `eval`; provide dependencies
  through the associated `Env` instead.

Each module compile artifact exposes a typed namespace-tree interface for its
guaranteed public declarations. Entries distinguish values, macros, fexprs,
types, protocols, and namespaces; protocol entries also record message
identities. Only unconditional module declarations and unconditional nested
`ns` declarations enter this tree. Wildcard and alias resolution uses the tree,
so it never has to execute a dependency during compilation. Conditional names
remain available through selected imports or qualified runtime lookup.

Bare wildcard resolution is lazy. Own declarations and selected imports win.
Otherwise every matching wildcard source and the implicit builtin/prelude
source form one collision domain: one candidate resolves, multiple candidates
raise an ambiguity only when the name is used, and unused collisions are inert.
Qualification or a selected import disambiguates. A name declared anywhere in
the current static unit never falls back to a wildcard, preserving
use-before-definition errors.

Wildcard and aliased modules do not seed unqualified protocol sends merely by
being imported. An explicit protocol reference in a parameter, return, or other
interface annotation seeds exactly that identity in the nested unit's
Must/Whole/Entry candidate analysis (§10 and `docs/scoped-impls.md`). Qualified
protocol references behave the same way. Scoped impls still cross modules only
through `import_impl`.

Public declarations are exported by default. Imports are local by default and
must opt into re-export:

```gene
(import [add, Config] from "./math" ^export true)
(import * : math from "./math" ^export true)
```

Selected imports and qualified aliases may use `^export true`. Bare wildcards
cannot re-export. Protocol implementation declarations are not named exports;
their visibility and explicit pair import follow §10.1 and
`docs/scoped-impls.md`.

The compile interface is part of reload compatibility. MVP reload rejects any
change to its names, nesting, binding categories, or protocol message
identities; already-compiled wildcard/alias importers are not transactionally
recompiled.

The standard library has reserved binding roots `gene`, `genex`, `geney`, and
`genez`. User code cannot declare, bind, alias, import-as, assign, or shadow any
of these names. `gene` is defined and provides a stable qualified path to every
builtin, including nested namespaces such as `gene/str/join`; the other three
roots are reserved but initially undefined. Migration is staged: existing bare
builtins remain available for compatibility, then a small versioned prelude
will become the only implicit bare builtin source before non-prelude bare names
are removed in a major version.

Path interpretation for `from "path"`:

```text
"x"     package-relative: <library entry's directory>/x
"./x"   relative to current module directory
"../x"  parent-relative
"/x"    package-relative, same base as "x"
"."     the package entry, i.e. its declared `^library ^entry` (§15.3)
```

A regular package has exactly one module base — the directory holding its
declared library entry — and no package-root fallback: a package that declares
no library target has nothing to import by name. Only an ad-hoc package, which
declares nothing, uses its synthesized root as the base.

`"."` is the only module path the resolver rewrites, and it can never collide
with a real module because `.` does not name a file. `main_module` is derived
from the declared library entry rather than configured, and no module *name* is
magic: a package whose entry is `src/boot.gene` still reaches a literal
`src/index.gene` as `"index"`.

`^pkg "alias"` selects the package a module path is resolved in. The value is
the *dependency alias* the importing manifest declared, not the package name —
that is what lets one manifest depend on two versions of one name and reach
both:

```gene
# ^dependencies {^json (dep "acme/json" "^1.4.0")}
(import [parse] from "." ^pkg "json")        # the package entry
(import [schema] from "schema" ^pkg "json")  # a named module
```

`^pkg` is valid only on the `from` form — a bare namespace path never selects a
package, so package selection is always explicit. A package-qualified path is
always package-relative: it cannot be absolute, name a URL, or use `..`. It
joins `^export` as the only other recognized `import` prop; every other prop is
still an error, and `^as` still names its own removal.

Normalization rules:

- collapse repeated separators;
- remove `.` segments;
- resolve `..` segments;
- reject paths that escape above the *selected* package's root, checked after
  canonicalization so a symlink cannot leave a package unnoticed;
- canonicalize the module extension policy;
- produce a stable normalized module identity used for caching.

For MVP, extension handling can be simple:

```text
"x" may resolve to "x.gene" when no extension is present.
```

The loader must use normalized identities so `"./a/../b"` and `"b"` do not create duplicate modules when they refer to the same module under the same root.

Compilation and runtime initialization are separate phases with separate
caches and cycle diagnostics:

1. A compile artifact contains expanded GIR, its typed namespace-tree
   interface, and exported macro/fexpr metadata. Building it performs no runtime
   evaluation and grants no host/runtime capabilities.
2. Wildcard and alias imports read dependency interfaces. Macro expansion and
   explicit re-export may require the dependency's full compile artifact;
   cycles on those artifact edges fail as `compile-time macro dependency
   cycle`. Value-only initialization cycles remain runtime concerns.
3. Executing an import initializes the dependency's runtime phase, in the
   application's granted runtime environment, at most once per normalized
   module identity. Runtime top-level forms are never run merely to compile an
   importer.
4. Runtime initialization has its own in-progress set. A cycle there fails as
   `runtime module initialization cycle`; a compile-cache entry neither marks a
   module initialized nor suppresses its one runtime execution.

Declaration-only cyclic modules remain deferred; the MVP rejects both phase-
specific cycle classes described above.

### 15.7 Module and namespace introspection

A module exposes declarations as a stream:

```gene
this_mod/%declarations
```

`declarations` is an ordinary imported/global function stage:

```text
declarations : Module -> (Stream Node Never)
```

Users can filter/map declarations with normal stream functions:

```gene
(this_mod/%declarations
  .filter routed?
  ; .map route_entry
  ; .into {})
```

Declaration records are nodes shaped
`(Declaration ^name Str ^kind Str ^value Any)` — `^value` is the bound value
itself. Meta attached to the source declaration form (`@route ...`, `@doc ...`
on a named `fn`) becomes node meta on the record, so `decl/%meta/route` reads
it and declarations without that meta answer `void`. This is the hook for
meta-driven discovery such as route tables built from `@route` annotations.

This is runtime reflection: its stream contains only runtime bindings with a
real `^value`. Compile-time macro and derive declarations are excluded. Tooling
that enumerates those artifacts must use the compiler's compile-time
declaration view, with phase and syntax/source metadata, rather than fabricate
an `Any` runtime value or execute module top-level code.

Namespaces should expose reflection helpers such as:

```gene
Namespace/bindings
Namespace/lookup
Module/root_namespace
Module/name
Module/path
Module/meta
Module/declarations
```

`this_mod` is the module's loader-created binding for the current module value. Symbol resolution inside a module is otherwise explicit. A helper such as `resolve` should be defined as either runtime module/namespace binding lookup or compile-time module lookup; it is not implicit magic.

### 15.8 Eval integration

`gene eval` and `(eval node ^in env)` create module-like evaluation units.

An eval unit has:

```text
source identity or synthetic identity
root namespace
isolated declaration overlay
supplied Env
optional parent module/namespace
```

Evaluated declarations do not mutate the source module. They live in an overlay retained by returned functions, types, protocol impls, callbacks, or compiled artifacts. Impl declarations register only in that overlay: they are visible to code retaining it and do not alter the application-global impl registry.

Thus:

```text
Module = normal persisted code unit
Eval overlay = ephemeral/generated module-like code unit
```

Both use the same reader, compiler, namespace, import, and declaration mechanisms.

### 15.9 URL module sources (experimental)

Gene can run a remote entry module directly — the experimental
`gene runurl <https-url>` command (which folds into `gene run <url>` once the
semantics stabilize) — so one-file scripts and demos can be shared and run
without installation. The wasm playground already treats fetch as its natural
loader; this brings the same shape to the CLI. The transport is the same
libcurl binding as `net/http_client`. Design decisions:

- The canonical URL is the module identity. Module and compile-artifact
  caches are keyed by identity strings, so URLs flow through them unchanged.
- A relative import inside a URL module resolves RFC-3986-style against the
  importer's URL — after redirects, against the final URL — with the same
  `.gene` extension defaulting as file modules.
- Boundary rules mirror the package-root rule for files: a remote module can
  never import a local file (every module-path import inside a URL module
  resolves against the module's URL); URL imports are enabled only by the
  `runurl` entry — under `gene run` they are rejected at resolution (a future
  opt-in flag on `run` may relax this); same-origin remote imports are free;
  each cross-origin fetch prints its provenance. `https` only, with plain
  `http` allowed for localhost.
- Remote-module operations use the entry's host-created context, module/import
  ceilings, and normal adapter checks. A URL does not establish a deny-by-default
  sandbox. Capability grants are runtime state, and eval's source-import
  restriction is unchanged.
- Compile-time macro discovery fetches dependency sources through the same
  cache, so each URL is fetched at most once per run even when compilation
  needs it before execution.
- The implemented slice caches in memory per run. Before the feature leaves
  experimental status it needs a disk cache plus a lockfile pinning a sha256
  per URL, because URL content is mutable and runs must be reproducible.
  `reload` rejects URL modules until then. Module URLs carry no query or
  fragment.
- This is a script-running feature, not the package story: packages and
  registries (`docs/proposals/distribution.md`) remain the dependency answer.

### 15.10 Sandboxed module loading and generations

```gene
($runtime/load_sandboxed dir entry grants shared [isolation_key])
                                                    # -> module namespace
```

Load `dir/entry` at runtime with **only** the selected standard-library
namespaces directly exposed. The `grants` argument — `["fs"]`, `["net" "db"]`,
or `[]` — selects namespace exposure, not sealed resource grants. Passed values
and admitted shared modules also contribute reachable behavior. The selectable
set is the one that reaches outside
the process (`fs`, `net`, `os`, `ffi`, `db`, `store`, `terminal`, `curses`,
`repl`, `device`, `runtime`, `serde`, `aot`, `web`, `http`); `math`, `str`,
`json` and the rest are computation over values the module already has and are
never withheld. An unknown grant name is an error, not a silently tighter
sandbox.

The optional `isolation_key` separates module-cache identity for two trusted
host entries that load the same bytes. `load_sandboxed` is the compatibility
path: it initializes and publishes immediately. A trusted host loading a
declaration-only module may subsequently call `$runtime/configure_module` under
an attenuated capability context, but that cannot retroactively bound module
initialization and is not the interface for untrusted transactional plugins.

Transactional loaders use a sandbox transaction:

```gene
(var transaction ($runtime/sandbox_transaction))
(var generation
  (transaction .prepare
    {^dir plugin_root
     ^entry "plugin.gene"
     ^grants []
     ^shared shared_contracts
     ^label "tenant:plugin"
     ^policy {^max_steps 100000
              ^max_memory_mb 64
              ^timeout_ms 2000}}))

(var candidate generation/.module)
(var graph generation/.graph)
transaction/.commit       # publish every prepared generation
# or: transaction/.discard

generation/.release       # after all callers are quiescent
```

`SandboxTransaction/prepare` may add several generation roots. Each receives a
fresh runtime identity; `label` is diagnostic only. Compilation, template-macro
expansion, module initialization, and every later external function or protocol
entry are bounded by the supplied policy. Prepared module/compile caches,
protocol registrations, serde origins, and module scopes remain prospective.
Candidate code sees its own definitions, while unrelated live code does not.
Preparation pauses worker module readers and restricts any scheduler pumping
performed by candidate initialization to candidate-owned tasks. FFI and native
or capability type declarations, plus embedded `web_module` blocks, are
rejected; the policy provides no enable flag for them.

Commit first verifies that the live module and impl epochs still match the
transaction base, then publishes every generation in one non-yielding root-lane
turn. Discard drops all prospective roots. Both are idempotent in their valid
terminal state and reject the opposite terminal operation. A committed
generation remains explicitly owned until `release` removes its cache,
compile-artifact, impl, serde-origin, and scope roots. Handles are opaque,
non-`Send`, non-freezable, application-bound, and lane-owned; dropping one does
not substitute for commit, discard, or release.

`generation/graph` is deeply frozen and deterministically ordered. Every node
contains normalized identity/path, the sha256 of the bytes actually compiled,
a compile-interface digest, dependency edges tagged `runtime` or `compile`, and
an `^owned` bit. Admitted shared modules appear as `^owned false` reference
nodes and retain their host identity and policy.

What makes it a boundary rather than a convention is that `$fs` is sugar for
`gene/fs` and `gene` is resolved by a **scope-chain lookup**, so a module root
parented to a restricted builtins scope has a different standard library — and
`gene` is in the compiler's reserved roots, so a module cannot rebind it to fetch
the real one back. A denied namespace is *absent*, so naming it fails.

Five properties are load-bearing:

- **The restriction covers everything the module imports**, not just the named
  file. Otherwise a module that cannot name `$fs` imports one that can. An import
  that resolves outside `dir` must be named in `shared`; anything else is refused
  where it is written.

  This bullet and the cache bullet below used to contradict each other, and the
  code implemented the wrong one. Out-of-dir modules loaded **unrestricted**, with
  the obligation left on the host "not to put reachable code where a mod can
  reach it" — which cannot be met, because the *mod* writes the import path, so
  the reachable set is the whole package root. Measured, with a mod granted
  nothing: it imported a host module that opens a database by path, and wrote a
  file of its choosing; and it imported the host's own loader and re-entered the
  sandbox under a manifest it shipped itself asking for `fs`. `shared` is the
  repair — the host names the shared set, and it is a list you can read.
- **It follows the value, not the load.** A function exported out of a sandbox is
  still restricted when called later, which is what makes a plugin API safe to
  call back into.
- **`dir` is the boundary and the host supplies it.** `entry` is resolved inside
  it and an entry that climbs out is refused. Deriving the boundary from the
  entry lets the loaded code move it. A relative `dir` is package-root-relative,
  not cwd-relative, so it means the same thing however the program was started.
- **The module cache is keyed by the grant set.** Without that it is a hole in
  both directions: a module already loaded with full authority handed to a
  sandbox, or a module first loaded under a sandbox coming back stripped for
  trusted code. Modules *outside* `dir` are the host's and are shared — required,
  not a concession, because a recompiled module brings its own type identities
  and its types would stop being the host's.
- **A sandbox cannot load another sandbox.** Nesting would let the loaded code
  choose its own grants. The check is at the **call site**, not on "is a load in
  progress" — that was true only during the load, so a function the module
  exported and something called later walked past it.

  One residue, stated because it is the host's to hold and it is checkable: a
  *host* function that loads sandboxes cannot be attributed to the mod behind it,
  because the call's scope chain is the host's. So **do not put a module that
  loads sandboxes in `shared`.** That is one line to check against the allowlist,
  where the old obligation was a claim about every file in the package.

`genex` is withheld from a sandbox and not rebound. The grant filter runs over
the members of `gene`, so a second stdlib root would never meet it; `genex` is
empty today, which is when that is cheap to close. An incubating root is
withheld until its members are classified.

Namespace exposure and resource permission compose: exposing `fs` makes its
APIs nameable, and filesystem providers still check the active context for each
operation and resource. Shared-module admission, execution limits, and atomic
publication are additional controls. See [the authority contract](../spec/authority.md).
The web profile has no VM runtime-module or capability-context sandbox.
