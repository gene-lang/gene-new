# Gene package builds and application installation

**Status:** design proposal; implementation begins only after approval

**Scope:** build targets, build recipes, hermetic execution, artifact caching,
native dependencies, application assembly, prebuilt artifacts, and installation

**Builds on:** `package.md` for source packages and resolved graphs;
`distribution.md` for `.gapp` images and standalone launchers;
`native-type.md` for FFI and native layout semantics.

**Revision date:** 2026-08-01

---

Terminology is deliberately split: a **system dependency** is an external ABI
requirement discovered through §8; a **native artifact** is target machine code
consumed or produced by the build graph; the **typed-native backend** in
`native-type.md` lowers eligible Gene code; and a **mixed image** in
`distribution.md` packages native artifacts alongside mandatory GIR fallback.
None of these terms implies the others.

## 1. Decision summary

Gene should use one build engine for libraries and applications, with these
rules:

- The build engine consumes an immutable materialized graph description and
  snapshots mutable workspace/path sources before planning. It does not resolve
  or acquire source dependencies itself.
- Co-lived packages under `<app>/packages/<member>` are planned and cached as
  separate package targets within one workspace build graph.
- Library and application targets are declared in `package.gene`; build recipes
  form a dependency graph beneath those targets.
- Built-in recipes cover common Gene, C, web, resource, and native-library
  work. An explicit command recipe is the escape hatch.
- Build commands run in a sandbox with read-only inputs and one writable output
  tree. They never write into package source.
- Build cache keys include every effective input, including the compiler,
  toolchain, target, profile, features, dependency artifacts, and declared
  environment.
- Artifacts are immutable and content-addressed outside source packages.
- Acquisition never builds. Building happens only for an explicit build, test,
  run, pack, or install request.
- A source package archive, a compiled library artifact, an application image,
  and an installed application are distinct things.
- Libraries are made available through dependency resolution. `gene install`
  installs runnable applications and their receipts, not libraries into an
  ambient import path.
- Prebuilt artifacts are selected by compatibility and verified by digest and
  provenance; they never replace source identity in the lockfile.

The design favors reproducibility, cacheability, and supply-chain safety over
shell-script convenience. The escape hatch remains powerful, but its authority
is visible and policy-controlled.

## 2. Build lifecycle

The complete pipeline is:

```text
Resolution
-> MaterializedGraph
-> SourceSnapshot
-> BuildPlan
-> optional ArtifactSync
-> Derivations
-> Artifacts
-> Assembly
-> optional Installation
```

| Phase | Responsibility | Network | Arbitrary execution |
|---|---|---:|---:|
| Resolve | choose package instances | metadata policy only | no |
| Acquire | obtain and verify source objects | allowed by sync policy | no |
| Snapshot | freeze mutable workspace/path inputs for this build | no | no |
| Plan | select targets and construct build DAG | no | no |
| Artifact sync | obtain compatible prebuilt artifacts for planned derivations | allowed by build policy | no |
| Build | execute derivations | no by default | only declared recipes under policy |
| Assemble | create library bundle, `.gapp`, launcher, or source archive | no | no package hooks |
| Install | atomically expose an assembled application | no | no new hooks |
| Load | initialize Gene modules | according to runtime capabilities | module initialization only |

There are no implicit `postinstall` hooks. If installing from source requires a
build, `gene install` submits an explicit build request and displays any recipe
that needs authority before it executes.

## 3. Product targets

Targets describe what a package produces. They are not build steps.

```gene
^library {
  ^entry "src/index.gene"
  ^uses [sqlite_shim templates]
}

^applications [
  (application "widget"
    ^entry "src/apps/widget.gene"
    ^uses [sqlite_shim templates web_assets])
]
```

The primary target kinds are:

| Target | Product | Typical consumer |
|---|---|---|
| Library | compiled Gene module bundle plus metadata | another package build or runtime |
| Application | verified GIR/resource/native artifact set | `gene run` or `Assembler` |
| Test | isolated test application | `gene test` |
| Documentation | generated package documentation | publisher or local author |

`.gapp`, standalone launcher, and multi-target bundle are assembly outputs
selected by an `AssemblyRequest`; they are not additional manifest targets.

The library target is implicit in dependency builds: if a package is present as
a runtime dependency, its library target is built when the selected backend
needs compiled output. Application targets are built only when named or when a
package has exactly one application and the command permits a default.

For a workspace, the selected application/member target is the build root and
the root lock determines dependency edges. Co-lived members are not flattened
into the application package: each keeps its own target graph, source snapshot,
artifact identity, diagnostics, and cache reuse. Independent member targets are
scheduled in parallel, and changing `packages/pkg1` invalidates only
derivations whose graph reaches `pkg1`.

The build engine snapshots every mutable workspace/path package as one
consistent source tree before deriving keys or starting recipes. If files
change while a snapshot is being captured, the engine retries or reports a
source-changed diagnostic; it never combines a pre-edit key with post-edit
bytes.

The workspace root maintains an incremental Merkle index under `.gene/` so a
warm no-op build does not re-read or re-hash every member file. Changed metadata
causes content revalidation; correctness never depends on directory enumeration
order or timestamps alone.

The built-in profiles are `dev`, `test`, and `release`. A custom profile is
declared in the top-level `^profiles` map:

```gene
^profiles {
  ^release_small (profile
    ^inherits release
    ^optimization size
    ^debug_info min
    ^assertions false
    ^sealing sealed
    ^lto true)
}
```

A `profile` has exactly `inherits`, `optimization`, `debug_info`, `assertions`,
`sealing`, and `lto`. `inherits` is one built-in profile and is required;
omitted properties inherit it. Optimization is `none`, `speed`, or `size`;
debug information is `full`, `min`, or `none`; sealing is `open` or
`sealed`; the remaining values are booleans. Profiles never change dependency
source selection or activate features; profile-dependent source graphs would
make one lockfile describe multiple programs ambiguously.

## 4. Build recipes and the build DAG

`^build` declares named recipes whose outputs may be used by product targets or
other recipes:

```gene
^build [
  (c_library "sqlite_shim"
    ^sources ["native/sqlite_shim.c"]
    ^headers ["native/sqlite_shim.h"]
    ^uses_system [sqlite]
    ^public_headers ["native/sqlite_shim.h"])

  (resource_bundle "templates"
    ^inputs ["resources/templates/**"])

  (web_module "web_assets"
    ^entry "src/web/client.gene")

  (command "atlas"
    ^program "dep:asset_tool"
    ^args ["build" "{src}/resources/atlas.gene" "{out}/atlas"]
    ^inputs ["resources/atlas.gene" "resources/images/**"]
    ^outputs ["atlas/**"]
    ^needs [])
]
```

Recipe names use `snake_case` and are unique within a package. `^needs` creates
edges between recipes; target `^uses` creates edges from products to recipes.
The build engine rejects cycles before execution and schedules independent
derivations in parallel.

### 4.1 Built-in recipes

The initial built-in vocabulary should remain small and deep:

- `c_library`: compile and link C-family source owned by the package;
- `resource_bundle`: normalize, hash, and index declared resources;
- `web_module`: transpile a Gene web entry and its module closure;
- `command`: execute an explicit tool for cases the built-ins do not cover.

Gene library/application compilation is owned directly by the build engine and
does not need a manifest recipe. More built-ins should be added only when they
can hide substantial cross-platform behavior behind a smaller interface than a
command recipe.

Built-ins know their complete input closure and emit typed artifacts. A
`c_library` produces a native-library artifact, not a bag of caller-supplied
link flags. A `resource_bundle` produces an indexed resource artifact, not
files copied into an unspecified directory.

All recipe schemas are closed. Every recipe body contains exactly one local
recipe name and the common `^needs [<recipe_name> ...]` property defaults to an
empty list. The initial recipe-specific properties are:

| Recipe | Required properties | Optional properties |
|---|---|---|
| `c_library` | `^sources [<pattern> ...]` | `^headers [...]`, `^public_headers [...]`, `^include_dirs [...]`, `^defines {<string>: <string>}`, `^standard <c11|c17|c23>`, `^kind <static|shared>`, `^uses_system [<alias> ...]`, `^needs [...]` |
| `resource_bundle` | `^inputs [<pattern> ...]` | `^strip_prefix <path>`, `^needs [...]` |
| `web_module` | `^entry <path>` | `^format <esm|iife>`, `^needs [...]` |
| `command` | `^program <coordinate>`, `^args [<string> ...]`, `^inputs [<pattern> ...]`, `^outputs [<pattern> ...]` | `^env {<string>: <string>}`, `^authority [<name> ...]`, `^timeout_ms <integer>`, `^needs [...]` |

Required lists are non-empty except `command.args`, which may be empty.
Patterns use the package pattern grammar from `package.md` §5.1. Header and
include paths are package-relative; public headers must be selected by
`headers`. `standard` defaults to `c11`, `kind` to `static`, and web `format` to
`esm`. Define and environment keys are strings because their spelling is a
foreign toolchain protocol, not a Gene name. Every input pattern must match at
least one regular file; every output pattern must match at least one produced
file. `strip_prefix` must contain every resource input and defaults to their
longest common directory. The only
initial extra authority is `network`; it is forbidden for release or published
prebuilt derivations. `timeout_ms` is positive and defaults from host policy.
Unknown properties and artifact-name collisions are errors.

### 4.2 Command recipes

A command recipe invokes a tool from `^build_dependencies` or a host toolchain
selected by policy. `^program` is either `dep:<alias>/<application>` or
`tool:<tool_name>`. The application segment may be omitted only when the build
dependency declares exactly one application target. Build dependencies execute
for the host platform even during cross-compilation. Host tool names are
resolved only through the injected `ToolchainSet`; `^program` never searches
ambient `PATH`, shell aliases, or the current directory.

`^args` is an argv vector, not a shell string. The build engine recognizes only
these path placeholders:

```text
{src}   read-only package source root
{deps}  read-only dependency artifact root
{out}   writable output root
{tmp}   private temporary root
```

A placeholder may be the whole argument or its first path segment followed by
`/`; it cannot occur later, occur twice, or be concatenated with other text.
Expansion always yields one argv item. There is no implicit word splitting,
glob expansion, environment interpolation, pipe, redirect, or `&&`. A shell
can be a declared build dependency and invoked explicitly, subject to the same
sandbox and trust policy.

`^inputs` and `^outputs` are required. Globs are evaluated by the build engine,
sorted by normalized logical path, and included in the derivation. Every output
must be beneath `{out}` and match `^outputs`; undeclared output is an error.
The command receives no writable package checkout to “move outputs from” after
execution.

## 5. Build sandbox and authority

Every derivation executes in an isolated directory:

```text
sandbox/
├── src/        # package source, read-only
├── deps/       # declared build/runtime artifacts, read-only
├── toolchain/  # selected tools, read-only
├── out/        # only durable writable output
├── tmp/        # private scratch, discarded
└── home/       # empty synthetic home, discarded
```

Each workspace member receives its own `{src}` mount. A recipe in one member
cannot read another member's checkout by relative filesystem traversal; it can
read only artifacts exposed through declared dependency edges under `{deps}`.
This makes co-location convenient without making undeclared source coupling
part of the build.

Default authority is:

- read declared source inputs;
- read declared dependency artifacts;
- execute declared tools;
- write `{out}` and `{tmp}`;
- no network;
- no host home directory;
- no host credentials, agents, sockets, or undeclared environment;
- no writes to package sources, stores, sibling sandboxes, or installation
  prefixes.

These are semantic guarantees, not best-effort requests. A host adapter that
cannot enforce read isolation, output confinement, environment clearing, and
network denial for a recipe reports `BUILD_SANDBOX_UNAVAILABLE`; it does not
silently run with weaker authority. Host policy may select a stronger adapter
or explicitly allow an interactive, non-publishable unsafe development run,
which is never cached, installed, or used for an attestation.

Environment variables are empty except for deterministic build variables and
those explicitly declared by the recipe and allowed by policy. Declared values
enter the derivation key. Secrets are never reproducible inputs and cannot be
used by publishable builds.

Built-in recipes need no package trust grant. A third-party `command` recipe
requires a trust decision keyed by package source digest, recipe digest, and
requested authority. Interactive commands show the exact request; CI supplies
a checked-in or host-managed policy. A package update changes the digest and
therefore requires a new decision.

Networked code generation is intentionally split in two: acquisition fetches a
declared, digest-pinned input; the build consumes it offline. This preserves
rebuildability and prevents a build server from returning different source for
the same derivation.

## 6. Build planning and derivations

The planner consumes:

```text
BuildRequest
MaterializedGraph
BuildEnvironment
```

and returns an immutable DAG of derivations. A derivation is one recipe or one
compiler/linker action with all effective inputs named.

`BuildRequest` identifies one root package instance, product target, target
triple, profile plus effective mode/sealing/debug values, prebuilt/source
preference, rebuild mode, reproducibility mode, and maximum parallelism. It
cannot alter locked features or dependency edges. `BuildEnvironment` supplies
the toolchain set, system-dependency providers, build policy, source
snapshotter, local/remote artifact sources,
artifact store, and sandbox runner. Those capabilities are injected once when
constructing a `BuildEngine`; neither the planner nor a recipe reads process
globals to find them.

### 6.1 Derivation key

The derivation key includes:

- recipe or compiler action in canonical form;
- source package tree digest, computed from the build snapshot for mutable
  workspace/path inputs;
- exact input-file digests;
- dependency and prior-recipe artifact digests;
- root lock digest and selected features relevant to the action;
- Gene compiler version and executable digest;
- GIR, runtime, value, native-extension, and image ABI versions as applicable;
- complete target triple and CPU feature policy;
- build profile and effective flags;
- exact toolchain identities and sysroot digest;
- normalized system-dependency result;
- declared environment values;
- sandbox/build-engine format version.

If an input can change output bytes, it belongs in the derivation key. A
coarser “source key” may be useful for search and provenance, but it must never
be used as proof that two binaries are interchangeable.

### 6.2 Output identity and provenance

The derivation key identifies the build instruction. The artifact digest
identifies the produced bytes. A successful record contains both:

```text
derivation_id
artifact_digest
artifact_type
compatibility metadata
input/provenance statement
reproducibility status
```

An artifact digest hashes `gene-artifact-v1\0`, the artifact-type tag, its
Canonical Gene Data v1 metadata (`package.md` §6.3), and a Canonical Source
Tree v1 payload. Artifact metadata contains only logical paths and stable
compatibility/provenance fields; timestamps, store locations, sandbox paths,
and installation prefixes are excluded. Typed single-file artifacts use a
one-entry payload. Each artifact kind defines which metadata fields are
semantic, and golden vectors prevent adapters from inventing a second encoding.

Two builders using the same derivation should produce the same artifact. If
they do not, the build is non-reproducible and both outputs remain distinct by
digest; the cache never aliases them silently. The first successful observation
may serve as a cache hit while it is the only observation. If a later local or
trusted remote result has a different digest, insertion atomically marks the
derivation **poisoned**, retains every observation, and fails the current
build. A poisoned derivation never serves a cache hit and cannot be cleared for
that derivation ID: a known byte disagreement is part of its permanent
provenance. Recovery requires fixing or declaring the missing input, tool, or
engine rule, which produces a new derivation ID. Artifact objects remain
available to existing references but cannot support a reproducibility claim.

System dependencies make a build reproducible only when their headers,
libraries, and relevant tool identity are themselves digest-addressed. Merely
recording `sqlite3 3.45` is compatibility metadata, not a complete input
identity.

## 7. Artifact stores and project build view

Build artifacts live in a user-level content-addressed store, separate from
source packages:

```text
~/.gene/artifacts/
├── derivations/sha256/<derivation_id>/
│   ├── index.gene             # active/poisoned state and observation set
│   └── observations/<artifact_digest>.gene
├── objects/sha256/<artifact_digest>/...
└── tmp/
```

The project gets a disposable view:

```text
.gene/build/
├── dev/<target>/<product> -> artifact object or materialized view
├── test/<target>/<product> -> ...
└── release/<target>/<product> -> ...
```

The implementation may use links, copy-on-write materialization, or an index on
platforms without safe links. The semantic rule is the same: `.gene/build/` is
a reference/view, not the canonical artifact.

`gene clean` removes project build references and sandboxes. It does not delete
shared artifacts still referenced by another project or installation. `gene
pkg cache gc` traces lockfiles, project references, and installation receipts
before deleting unreferenced source or artifact objects.

Artifacts and observation records are inserted atomically and are immutable.
Concurrent builders that produce the same digest converge on one observation;
different digests atomically poison the derivation as specified in §6.2. The
derivation index may transition only from empty to active or active to
poisoned. Garbage collection may remove the complete record only when no lock,
project, installation, attestation, or retained diagnostic refers to it.

One workspace root owns `.gene/build/`. Its view is grouped by package instance
and target so equal target names in `app`, `pkg1`, and `pkg2` cannot collide.
Running a command from inside a member still writes references through that
workspace root; running the copied member outside the workspace uses its own
`.gene/build/`.

## 8. Native and system dependencies

Gene package dependencies and host system dependencies are different graphs.
A package dependency supplies Gene modules or declared build artifacts. A
system dependency supplies an ABI-visible external library or toolchain
facility.

```gene
^system_dependencies {
  ^sqlite (system_library
    ^name "sqlite3"
    ^version ">=3.40 <4"
    ^providers [pkg_config vcpkg system_framework]
    ^linkage either)
}
```

A `system_library` has no positional body values. `name` and `version` are
required. `providers` defaults to the host policy order and may contain only
`pkg_config`, `vcpkg`, `system_framework`, or `policy_mapping`; `linkage` is
`static`, `dynamic`, or `either` and defaults to `either`; optional
`components` is a list of foreign provider component strings. Unknown
properties are errors. The package aliases (`sqlite` above) are `snake_case`,
while foreign names and components are strings with provider-defined spelling.

Recipes refer to the alias (`sqlite`), not raw flags. A system-dependency
adapter returns a normalized result:

```text
package alias and foreign name/version
target triple and ABI
header roots and per-file/tree digests
library files and digests
ordered compile definitions/options and link names/options
provider kind, executable/configuration identity, and query
linkage kind and redistribution metadata
```

The `SystemDependencyResolver.resolve(request) -> result` module is the only
consumer-facing seam. Its request contains the closed manifest requirement,
target triple, toolchain identity, and host policy. Provider adapters may use
absolute host paths internally, but their normalized result is canonical data
and every output-relevant value enters the derivation key. `pkg_config` runs
with an explicit executable, sysroot, search path, and environment supplied by
policy; it never inherits ambient `PKG_CONFIG_PATH` during a reproducible
build.

Initial adapters may include `pkg_config`, `vcpkg`, macOS frameworks, and an
explicit host-policy mapping. The manifest expresses requirements; host policy
chooses acceptable providers. Published manifests should not contain absolute
machine paths.

Native libraries built by Gene packages are ordinary typed artifacts and flow
through dependency edges. Link planning follows the artifact graph in stable
topological order and handles platform-specific whole-archive, rpath, import
library, and framework behavior behind the native linker module's interface.

The build-time system dependency is separate from an FFI declaration's runtime
library handle. Assembly validates that every runtime native requirement is
satisfied by an embedded artifact, an installed system dependency allowed by
policy, or an explicit runtime capability.

## 9. Artifact kinds

The design distinguishes these artifacts:

| Artifact | Contains | Stable public format? | Installed directly? |
|---|---|---:|---:|
| `.gpkg` source archive | manifest and declared source/resources | yes | no |
| Gene library artifact | GIR/modules, exports, resources, native requirements | internal initially | no |
| Native library artifact | library, headers/metadata, ABI and link metadata | internal initially | no |
| Resource artifact | normalized blobs and index | internal initially | no |
| `.gapp` application image | complete runnable Gene application image | yes | yes, through installer |
| Standalone executable | launcher plus `.gapp` | platform public artifact | yes |
| Prebuilt artifact bundle | one or more typed artifacts plus provenance | registry transport | no, imported into artifact store |

A package version remains source identity. Prebuilt artifacts are derivatives
of that source for a target and build configuration; they do not create a new
package version and do not alter dependency resolution.

## 10. Application assembly

An application target is assembled by:

```text
select application target
-> close runtime package/module graph
-> compile modules to GIR
-> collect library/resource/native artifacts
-> validate ABI and runtime capabilities
-> write deterministic .gapp
-> optionally sign image
-> optionally combine with target launcher
-> verify final artifact
```

`distribution.md` owns the `.gapp` physical format, sealed/open profiles,
launcher embedding, signatures, and mixed-native policy. This proposal owns how
package and build artifacts reach that assembler.

An application image records:

- root package and application target;
- co-lived workspace members frozen to exact source snapshot digests;
- source lock digest plus the complete frozen image package graph and its
  digest;
- module identities and source/GIR digests;
- artifact derivations and content digests;
- required runtime and ABI versions;
- target/profile/features;
- resources and native artifacts;
- declared runtime capabilities;
- provenance and signatures.

Assembly performs no dependency solving and invokes no arbitrary build recipe.
Everything it consumes is already a verified artifact.

## 11. Prebuilt artifacts

A registry may publish prebuilt artifact bundles alongside a source package.
The consumer preference is:

```text
1. matching verified local artifact
2. matching trusted prebuilt artifact, if policy allows
3. build from verified source
4. fail with a complete compatibility/trust explanation
```

Prebuilt selection happens after planning, when the required derivations and
compatibility constraints are known, and before any local recipe executes.
Artifact sync is an inert transport/verification phase: it may fetch bytes but
cannot execute artifact or package code. Prebuilt selection matches source
package digest, locked dependency context, target triple, CPU policy, profile,
Gene/ABI compatibility, and declared system requirements. It does not claim
reproducibility merely because these fields match.

Every bundle carries:

- artifact digests and types;
- source and lock digests;
- derivation description;
- builder/toolchain provenance;
- compatibility metadata;
- publisher/builder signatures;
- optional transparency-log proof and reproducibility attestations.

The host trust policy decides which builders and signatures are acceptable.
After verification, artifacts enter the same immutable artifact store as local
outputs. Runtime code cannot tell whether a byte-identical artifact was built
locally or acquired prebuilt.

## 12. Installation semantics

`gene install` installs application targets. Library dependencies are acquired
by `gene pkg sync` and consumed through locked graphs; there is no ambient
user-wide library search path.

Default user installation layout:

```text
~/.gene/apps/
└── acme/
    └── widget/
        └── 1.2.0/
            └── <application_digest>/
                ├── app.gapp
                ├── launcher
                └── install.gene

~/.gene/bin/
└── widget -> selected immutable installation
```

`GENE_INSTALL_ROOT` may replace the user root. A system installation requires
an explicit prefix and host authorization; package manifests cannot request it.

Install from a package coordinate:

```text
resolve exact application request
-> acquire source and/or trusted prebuilts
-> build release target if needed
-> assemble and verify application
-> stage immutable installation directory
-> write installation receipt
-> atomically switch command shim/link
```

The receipt records package instance, application target, source lock,
artifact/image digests, selected command names, installation time, and the
previous selection needed for rollback. Installation never mutates a package
store object or artifact object.

If multiple application targets export the same command name, installation
requires an explicit rename or reports a conflict. Upgrades install a new
immutable version first, then atomically switch the command. Uninstall removes
the selected receipt and command references; shared source/artifact objects are
left for garbage collection.

Project-local use does not require installation:

```sh
gene run widget
gene build widget
```

Both operate on the current package and lockfile. Installation is for making a
runnable application available outside its project.

## 13. Command surface

| Command | Purpose |
|---|---|
| `gene build [target]` | build a library or application target |
| `gene build --all` | build every declared target in the current workspace |
| `gene run [application]` | build as needed and run a project application |
| `gene run <path.gapp>` | verify and run an assembled image |
| `gene test [selector]` | build and run package tests with dev dependencies |
| `gene pack [application] [-o path.gapp]` | assemble a verified portable `.gapp` |
| `gene pack [application] --standalone -o path` | assemble one target launcher with embedded `.gapp` |
| `gene bundle [application] --target <triple>... -o path` | assemble a multi-target distribution bundle |
| `gene inspect <artifact>` | print canonical image, target, package, and signature metadata |
| `gene verify <artifact> [--trust_policy file]` | verify structure, digests, compatibility, and requested trust policy |
| `gene sign <artifact> --key <file> -o path` | produce a newly signed immutable artifact |
| `gene clean` | remove project build views and abandoned sandboxes |
| `gene install <package>[@version] [--app name] [--prefix dir]` | resolve/build and atomically install an application |
| `gene install <path.gapp> [--prefix dir]` | verify and atomically install an assembled image |
| `gene uninstall <package> [--app name]` | remove an installation receipt and command selection |
| `gene rollback <package> [--app name]` | atomically select the previous retained installation receipt |
| `gene installed` | list receipts, selected commands, and retained versions |

Common build options include:

```text
--target <triple>
--profile <name>
--mode vm|mixed
--sealed | --open
--debug_info full|min|none
--locked
--offline
--jobs <n>
--prefer_binary | --source
--rebuild
--explain
--policy <file>
```

`--release` is shorthand for `--profile release`. `--sealed`, `--open`, and
`--debug_info` are explicit per-request overrides of the selected profile and
enter every affected derivation and the image manifest. Conflicting shorthand
and explicit values are errors. Format 1 supports only `vm` and `mixed`, and
mixed images always retain GIR fallback; `native` and `--no_gir_fallback` are
not recognized options.

`gene build` writes only the keyed project build view and never interprets
`-o`. `gene pack` and `gene bundle` are the only build-family commands that
materialize a user-named distribution artifact. Inspection, verification, and
signing consume existing artifacts and never resolve packages or execute build
recipes. Before a demand-gated feature in §17 exists, its final command spelling
returns a stable `BUILD_FEATURE_UNAVAILABLE` diagnostic rather than doing a
weaker operation.

`--explain` reports why a derivation was reused or rebuilt. `--rebuild` bypasses
lookup but still writes an immutable result and detects non-reproducibility.
`--offline` permits local source builds but no registry or prebuilt download.

## 14. Build, assembly, and installer modules

The system has three deep modules with narrow interfaces:

```text
new_build_engine(BuildEnvironment) -> BuildEngine
BuildEngine.build(BuildRequest, MaterializedGraph) -> BuildResult

new_assembler(AssemblyEnvironment) -> Assembler
Assembler.assemble(AssemblyRequest, BuildResult) -> ApplicationArtifact

new_installer(InstallEnvironment) -> Installer
Installer.install(InstallRequest, ApplicationArtifact) -> InstallReceipt
```

`BuildEngine` hides target planning, recipe expansion, prebuilt artifact sync,
sandboxing, scheduling, toolchains, derivation keys, caches, and provenance.
`Assembler` hides image and launcher formats. `Installer` hides prefix layout,
atomic switching, receipts, conflicts, rollback, and uninstall bookkeeping.

Construction is the single composition seam. `BuildEnvironment` contains the
`ToolchainSet`, `BuildPolicy`, `SourceSnapshotter`, `ArtifactSources`,
`ArtifactStore`, `SandboxRunner`, and `SystemDependencyProviders` described in
§6. `AssemblyEnvironment` contains image/launcher writers, signing policy, and
an artifact reader. `InstallEnvironment` contains the clock plus user and
explicit-prefix filesystem adapters. Production constructors assemble host
adapters; tests provide temporary filesystem and in-memory adapters. After
construction, callers and tests exercise observable outcomes through the three
operation interfaces above, and no module silently consults ambient global
configuration.

Deleting any one of these modules would spread substantial policy across every
CLI and embedder, which is the leverage the interfaces are intended to retain.

## 15. Failures and diagnostics

Build and install failures use stable families:

```text
BUILD_PLAN_*
BUILD_FEATURE_*
BUILD_RECIPE_*
BUILD_AUTHORITY_*
BUILD_TOOLCHAIN_*
BUILD_SYSTEM_DEPENDENCY_*
BUILD_EXECUTION_*
BUILD_OUTPUT_*
BUILD_REPRODUCIBILITY_*
ARTIFACT_INTEGRITY_*
ASSEMBLY_COMPATIBILITY_*
INSTALL_CONFLICT_*
INSTALL_TRANSACTION_*
```

Every failure names the package instance, target, recipe/derivation, and
relevant policy. Command failures include argv, sandbox-relative working
directory, exit status, bounded stdout/stderr, and declared outputs, but redact
policy-marked secrets.

A failed build leaves source and prior artifacts untouched. A failed install
leaves the previous command selection active. Temporary directories are either
removed or retained behind an explicit diagnostic flag.

## 16. Reproducibility and security gates

A release or published prebuilt must pass:

- locked dependency graph validation;
- offline build after acquisition;
- no undeclared input/output detection for command recipes;
- clean sandbox and minimal environment;
- artifact and image verification after writing;
- license/redistribution validation for bundled native artifacts;
- provenance generation;
- a second-build comparison when claiming reproducibility;
- signature policy when publishing or installing trusted binary artifacts.

`gene build --verify_reproducible` runs required derivations twice in fresh
sandboxes and compares artifact digests. It is mandatory for a
`reproducible=true` attestation, not for every local development build.

Build-time authority never becomes runtime authority. Network access granted
to an authoring tool, if policy ever permits it, does not grant network access
to the resulting `.gapp`.

### 16.1 The shortest path to unblocking AOT

This design began from a specific blocker: `native-type.md` deferred build
integration on 2026-07-28 because "both answers come from the dependency
graph," and no declaration for a native library existed. The
declaration/discovery half of that blocker is cleared by the Phase 0
`system_library` slice (§8): the closed manifest declaration, normalized
resolver, `pkg_config` adapter, and integration with the existing experimental
AOT harness. It needs no derivation engine, artifact store, sandbox, or prebuilt
selection.

That slice lets `examples/native` drop hardcoded discovery and lets the
experimental compiler consume package-declared headers/link metadata. It does
**not** claim that `gene build` can already produce a linked native artifact;
managed native artifacts, sandboxed compilation, link planning, caching, and
application assembly arrive through Phases 1-3. This separates an immediately
useful adapter from the complete build product without describing either as
the other.

## 17. Implementation phases after approval

The final interfaces and artifact identities should land first. Later phases
deepen the implementations rather than introduce parallel build systems.

### Phase 0: native dependency declaration and discovery

- Begin after the format-1 manifest reader in `package.md` Phase 1 exists.
- Implement the final `system_library` schema,
  `SystemDependencyResolver` interface, `pkg_config` provider, canonical result,
  and diagnostics.
- Route the existing experimental AOT/native example harness through that
  result so it has no hardcoded header or library discovery.
- Keep the harness output explicitly experimental and unmanaged; this phase
  does not create `gene build` native products or a second build system.

### Phase 1: target graph and pure Gene artifacts

- Implement product targets, profiles, `BuildRequest`, planning, derivation
  records, workspace-wide scheduling, project build views, and Gene
  library/application compilation.
- Implement `gene build`, `gene run`, `gene test`, and explainable no-op builds.
- Use the final `BuildEngine` interface with a simple local artifact store.

### Phase 2: complete identities and portable application assembly

- Add complete derivation keys, `.gapp` assembly, verification, `gene pack`,
  `gene inspect`, and `gene verify`.
- Keep the Phase 1 local `ArtifactStore` adapter until cross-project reuse or
  measured rebuild cost justifies the user-level content-addressed adapter;
  adding that adapter does not change `BuildEngine` or `Assembler`.
- Integrate lock/package provenance from `package.md`.

### Phase 3: built-in native and resource recipes

- Add `resource_bundle`, `web_module`, `c_library`, remaining toolchain/system
  dependency adapters, native link planning, linked products, and ABI
  validation.
- Replace repository build scripts only after equivalent built-ins exist.

### Phase 4: sandboxed command recipes

- Add build dependencies, command sandboxes, authority policy, trust receipts,
  declared input/output enforcement, and reproducibility verification.
- Keep acquisition and resolution inert.

### Phase 5: application installation

- Add standalone launcher assembly first if its deployment gate is open.
- Add user/prefix installation layouts, receipts, atomic command switching,
  rollback, uninstall, and GC roots.
- Support source builds and local prebuilt artifacts through one installer
  interface.

### Phase 6: signing, remote prebuilts, and supply-chain hardening

- Add local artifact signing and trust verification when its gate is open.
- Add artifact-registry transport, builder provenance,
  transparency proofs, compatibility selection, and reproducible-build
  attestations.
- Add cross-compilation only through explicit toolchain adapters.
- Add `gene sign` and multi-target `gene bundle` only when their corresponding
  promotion gates are open.

### Promotion criteria

Phase 0 is intentionally independent and its demand gate is already open: the
experimental AOT harness needs declared system libraries. Promote later work
only for a concrete consumer or measured cost:

| Increment | Demand gate |
|---|---|
| Target graph and pure Gene build | a package declares more than one product or a workspace member must build independently |
| Portable `.gapp` assembly | an application must run without source checkout/compiler work |
| User-level artifact CAS | warm rebuild or cross-project duplication is measurably expensive |
| Native/resource built-ins | a repository target needs that artifact kind |
| Command recipes | a real build cannot be represented by approved built-ins |
| Standalone launcher | users must run a `.gapp` without an installed Gene runtime |
| Application installation | a runnable target must be selected outside its project checkout |
| Artifact signing | an image crosses an untrusted transport or deployment requires signer identity |
| Remote prebuilts | a consumer lacks a toolchain or CI build cost justifies trusted transport |
| Multi-target bundle | one release must publish more than one target launcher |

An unopened gate does not justify a second temporary interface. The preceding
module and adapter interfaces remain the implementation path when demand
arrives.

Every phase requires end-to-end CLI tests, crash/transaction tests, cache and
parallelism stress tests, security tests, and before/after build benchmarks.

## 18. Required acceptance tests

The final design requires coverage for:

- one package building a library and multiple applications;
- an application using editable `<app>/packages/pkg1` and member-to-member
  dependencies through the shared root lock;
- workspace scheduling preserving separate package artifacts, parallelizing
  independent members, and invalidating only reverse dependencies of an edit;
- a source edit during workspace snapshot capture causing a retry or explicit
  failure, never a mismatched derivation key;
- a member recipe unable to read a sibling's source without a declared edge;
- target and recipe cycle detection before execution;
- parallel independent derivations with stable logs and outputs;
- no-op rebuilds performing no source parse, process spawn, or artifact copy;
- every derivation-key input independently invalidating the correct actions;
- command recipes seeing only declared read inputs and writable output paths;
- source/store writes, undeclared outputs, network, home, and credential access
  denied by default;
- trust invalidation when package or recipe digest changes;
- interrupted and concurrent artifact insertion without partial objects;
- two builders disagreeing on output never aliasing artifacts;
- system dependency provider selection and complete ABI diagnostics;
- stable transitive native link ordering;
- deterministic `.gapp` assembly from identical artifacts;
- `gene build` producing only project build views while `gene pack`/`bundle`
  alone materialize user-named distribution artifacts;
- inspect, verify, and sign performing no resolution, source acquisition, or
  recipe execution;
- every mixed image retaining verified GIR fallback for native-accelerated
  modules;
- install conflict, atomic upgrade, rollback, and uninstall behavior;
- coordinate and direct-`.gapp` installation producing the same verified
  receipt shape, with direct images never invoking a build;
- failed install preserving the prior selected command;
- project-local run requiring no installation;
- acquired libraries never becoming ambient imports;
- prebuilt rejection for wrong source, lock, target, ABI, policy, digest, or
  signature;
- garbage collection preserving all project and installation roots;
- release reproducibility verification from two clean sandboxes.

Performance baselines should measure cold plan/build, warm no-op build,
parallel scaling, artifact materialization, application startup from `.gapp`,
and install/upgrade latency. Avoidable source passes, store scans, global locks,
and artifact copies are regressions.

## 19. Deferred policy, not deferred structure

The following may arrive later through the existing interfaces:

- remote execution and shared build caches;
- sandbox implementations stronger than the host default;
- additional language/toolchain recipe adapters;
- multi-target and universal binaries;
- profile-guided and incremental native compilation;
- enterprise signing and attestation policy;
- system package-manager integration;
- deterministic timestamps for protocols that require them.

They should not require manifests to become executable, build outputs to enter
source trees, libraries to become ambient installations, or runtime imports to
perform package-manager work.
