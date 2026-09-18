# Gene Code Persistence

**Status:** Proposed design; not a claim of implemented database-backed module loading.  
**Focus:** Persisting, publishing, locating, and loading Gene packages, modules, and resources from origins other than a source directory.  
**First origin:** Local SQLite. Remote databases, a code-store service, and plain HTTPS/Git origins can follow.  
**Execution model:** The existing Gene package/module loader, compiler, and runtime.  
**Retrieval model:** A single origin interface splitting mutable *resolution* from immutable *retrieval*, with one shared local cache on the retrieval side.  
**Explicit boundary:** Application-state capture, automatic checkpointing, resuming suspended execution, and live in-place module replacement are separate, more complex problems and are not specified here.

## 1. Core idea

Gene programs should be runnable when their packages and modules are stored in a database rather than in a source directory:

```sh
export GENE_IN_DB=sqlite
export GENE_DB_FILE=test.sqlite

gene run x.gene
```

In this mode, `x.gene` is a logical module path inside the selected database-backed application. It does not need to exist as a filesystem file.

The launcher selects a code store and a published release. The normal module loader retrieves source through that store, resolves imports through the release's fixed dependency graph, and compiles and runs the program normally.

> **Change where Gene code is stored and retrieved, not what a Gene program means.**

The database may also contain application data. Co-location is a useful expression of Gene's code-as-data model, but it is not required for database-backed code execution and must not turn this project into a persistent-heap or execution-resume project.

## 2. Motivation and scope

### 2.1 Why store code in a database?

A database-backed code store can provide:

- A single local container for an application's Gene source, package manifests, locked dependencies, and resources.
- Transactional publication of complete code releases rather than independently replacing files.
- A shared repository from which remote Gene processes retrieve approved releases without maintaining source checkouts.
- Queryable module inventories, provenance, release history, and links to generated-code validation results.
- A storage foundation for Gene Harness extensions without making Harness invent a separate module-execution system.

The main benefit is not that `SELECT` replaces `read_file`. It is that a complete, identifiable code release can be stored, selected, verified, and distributed through one interface.

Remote storage eliminates a separate source-file deployment step. It does **not** eliminate transfer of executable content to the machine that runs it. The executing machine still needs a compatible Gene runtime, the source or compatible compiled artifacts, and any required host/native facilities. This proposal is neither remote execution nor source-code secrecy.

### 2.2 Initial deliverable

The first useful implementation must be able to:

1. Import a locked filesystem project and its pure-Gene dependency closure into a local SQLite database.
2. Publish an immutable application release and select it through a named reference.
3. Run an entry module with the original source checkout unavailable.
4. Resolve ordinary relative and package imports from that release.
5. Retrieve packaged resources and report accurate source locations.
6. Export the stored project for inspection and ordinary filesystem development.

Support publication of a newer release while an existing run remains pinned to its original release. Do not require live replacement to demonstrate this property.

### 2.3 Non-goals

This proposal does not introduce:

- SQL stored procedures that execute Gene inside the database server.
- Automatic execution of values merely because they were read from a table.
- A second interpreter based on querying text and calling `eval`.
- Automatic persistence of variables, object graphs, closures, tasks, streams, sockets, or native pointers.
- Automatic resumption of a process at its previous instruction or continuation.
- A universal state schema, state-migration engine, or exactly-once external-effect protocol.
- Implicit hot reload when a database row changes.
- In-place replacement of an already-loaded module inside a running Application.
- An HTTP-style revalidating cache, or any cache entry with a freshness lifetime.
- A new dependency solver or mandatory hosted package registry.
- A requirement to abandon Git, files, or existing editors during development.
- A complete native application packager in the first SQLite milestone.

Native libraries and other platform artifacts remain part of deployment. Putting Gene source in a database does not make those dependencies disappear.

## 3. Architectural decision: a source backend, not a new runtime

The storage boundary belongs beneath ordinary package/module loading:

```text
Filesystem sources -----+
                        |
SQLite code store ------+--> Source provider --> Package/module loader
                        |                            |
Remote code store ------+                            v
                        |                         Compiler
HTTPS / Git origin -----+                            |
                                                     v
                                                Gene runtime
```

The diagram describes retrieval routes, not an implicit fallback search order.

The existing loader continues to own module identity, import resolution, initialization order, load-once behavior, protocol visibility, and dependency relationships. A storage adapter supplies authenticated source and metadata to that loader. Gene's previously reviewed module contract already separates package identity from module path and distinguishes compile-time artifacts from runtime initialization. [G1]

### 3.1 Resolution and retrieval are different operations

Every origin — SQLite, a remote service, a Git host, a plain directory — divides into exactly two operations, and the whole design follows from keeping them apart:

```text
Origin.resolve(selection, host_load_context) -> PinnedRelease
Origin.fetch(pinned_id, logical_path)        -> SourceUnit | Resource
```

**Resolution** turns something mutable — a reference name, a branch, a URL a user typed — into an immutable release identity. It is the only step that can observe change, it runs **once** per application launch, and it is never cached across runs except as an explicitly recorded resolution (§4.5).

**Retrieval** answers for content that the pinned release already authenticates. Its inputs are immutable by construction, so it is freely cacheable, shareable between processes, and shareable between origins (§7.4).

This split is what makes the origin interface generic. A backend differs only in how it resolves and how it transports bytes; everything above the split — module identity, import resolution, load-once, diagnostics, caching — is common code.

A conceptual internal interface is:

```text
Origin.resolve(selection, host_load_context) -> PinnedRelease
Origin.fetch(pinned_id, content_ref)         -> bytes

PinnedRelease:
    release_id            # content digest over the canonical release manifest
    origin_ref            # origin kind + safe display alias (never a credential)
    release_manifest      # root package revision, locked graph, entrypoint metadata
    package_manifests     # per package revision
    inventories           # logical path -> content ref, per package revision

CodeSnapshot.release_manifest() -> ReleaseManifest
CodeSnapshot.package_manifest(package_identity) -> PackageManifest
CodeSnapshot.module_inventory(package_identity) -> ModuleInventory
CodeSnapshot.read_module(package_identity, logical_path) -> SourceUnit
CodeSnapshot.read_resource(package_identity, logical_path) -> Resource
CodeSnapshot.close() -> Unit

SourceUnit:
    source_bytes
    source_digest
    source_origin

Resource:
    bytes
    content_digest
    content_type
```

`CodeSnapshot` is the loader-facing view of one `PinnedRelease`, with retrieval routed through the cache. These are semantic interfaces, not final public Gene declarations. Extend the existing loader at its source-read boundaries rather than exposing all of this as a new application framework.

`CodeSnapshot` is an immutable **release view**. It is not a snapshot of VM execution or necessarily a database transaction held open for the life of the process.

An inventory is a first-class object with its own digest, not merely a set of database rows. An origin with no native inventory must synthesize one during resolution (§13.1). Everything downstream — offline completeness, absence answers, cache GC roots — depends on the inventory being retrievable as content.

### 3.2 Bootstrap dependency

The first SQLite adapter must be available to the trusted launcher before database-backed Gene modules are loaded. It must not depend on a Gene database package that can only be found inside the unopened database.

Authoring, inspection, and publication utilities may be written in Gene after that bootstrap exists. Later backends must make their own bootstrap requirements explicit.

### 3.3 Module semantics must remain intact

Do not implement `gene run x.gene` as:

```text
SELECT source ...
eval(source)
```

That shortcut is insufficient for normal module identity, imports, initialization, source locations, and scoped declarations. A standalone dynamic evaluation API may still exist independently; it is not this feature's execution path.

## 4. Launcher configuration and entry selection

### 4.1 Preserve the proposed environment form

```sh
export GENE_IN_DB=sqlite
export GENE_DB_FILE=test.sqlite

gene run x.gene
```

An invocation-scoped alternative avoids leaving a shell in database mode:

```sh
GENE_IN_DB=sqlite GENE_DB_FILE=test.sqlite gene run x.gene
```

For the first form to work without more configuration, the database must declare a default application and its default release reference.

A database can contain several packages and applications. The launcher must first select one application release; it must not search all stored packages for an entry named `x.gene`.

### 4.2 Proposed selection settings

| Setting | Meaning |
| --- | --- |
| `GENE_IN_DB` | Source mode/backend. Version 1 recognizes `sqlite`. Unset or empty preserves ordinary filesystem mode. An unknown nonempty value is an error. |
| `GENE_DB_FILE` | Existing SQLite code-store file. Required in SQLite mode. |
| `GENE_DB_APP` | Optional application key, otherwise the database's configured default. |
| `GENE_DB_REF` | Optional named release reference, otherwise that application's configured default. |
| `GENE_DB_RELEASE` | Optional exact immutable release ID. Mutually exclusive with an explicitly supplied reference. |

The first two names are the user's proposed interface. The additional selectors are proposed ways to remove ambiguity for multi-application stores; their final CLI/configuration integration can follow the existing launcher conventions.

Provide equivalent explicit command-line configuration so tooling need not modify environment variables. CLI option spellings are not fixed by this document. If a launcher configuration file is supported, resolve selection with explicit CLI values above environment values above file defaults. Do not implicitly merge independent code stores.

Validate selection once at startup. Later changes to environment variables cannot redirect imports in an already-running application. A database-file setting alone must not silently enable database execution when the source mode is not selected.

### 4.3 Meaning of `gene run x.gene`

Under database mode:

1. Resolve the database file against the captured launch directory and open the existing store.
2. Validate the format and select the application.
3. Resolve a release reference once, or use the exact requested release ID.
4. Resolve `x.gene` inside that release's root package.
5. Run it with the existing entry-module and `main` conventions.

The entry must be part of the selected root package. It cannot name a different package by escaping the logical root. The release may record a default entrypoint for authoring tools and a future shorthand; this does not change the explicit example above.

Running starts a **fresh Gene Application**. Module initialization and `main` run normally. Nothing about choosing the same database implies continuation from an earlier process.

### 4.4 Fail rather than guess

A missing database, unsupported schema, missing application selection, unknown reference, missing release, or missing entry module is an error.

`run` does not create a database, migrate its schema, publish a release, or fall back to a same-named file in the current directory. Database creation and migration belong to explicit authoring operations.

The process working directory is not changed. Database source roots are not filesystem directories and do not create filesystem permission grants.

### 4.5 Ad-hoc origins and resolution modes

A SQLite code store declares its releases, so resolution is a lookup. Some origins declare nothing: a plain HTTPS URL, or a Git host reference that moves. Supporting those is desirable — `gene runurl https://.../x.gene` is a useful way to run something without a checkout — and it must not weaken pinning for everything else.

The reconciling rule is:

> **A mode flag selects whether a *resolution* happens. It never gives a cache entry a lifetime.**

An ad-hoc origin is one whose release is **discovered rather than declared**. Resolution fetches the entry, walks its statically discoverable import closure, hashes everything it retrieved, and constructs a release manifest from what it found. That synthesized manifest is pinned exactly like a declared one, and from that point the run is an ordinary pinned run. Retrieval and caching are unchanged; only resolution differs.

#### Resolve the closure eagerly

Resolution must complete before execution begins. Fetching each module on demand as the compiler reaches it leaves a window spanning the whole run, in which an upstream change produces exactly the mixed graph §6 forbids: one module retrieved before an upstream update and another after it.

Walking the closure up front narrows that window to the walk itself, and it produces the inventory that offline operation, absence answers, and a recordable release digest all require. The existing static import scan is the basis for this walk.

Two limits must be stated rather than assumed away:

- Static discovery is best-effort. Ordinary import forms scan cleanly; macro-generated or computed import paths do not.
- **An import that resolves outside the pinned closure is an error by default.** Permitting it instead — extending the pinned release mid-run — must be an explicit choice, and the addition must be recorded in the run's resolution, never applied silently.

For a generic HTTPS origin the walk window cannot be closed and the documentation should say so. For an origin that can name a whole tree it closes completely; see §13.1.

#### Modes

Reuse the existing `--locked` and `--offline` launcher flags rather than introducing cache-freshness options. Their current meanings already fit: `--locked` preserves the resolved graph, `--offline` avoids fetching.

| Flags | Resolution | Retrieval |
| --- | --- | --- |
| *(default)* | Resolve once at launch | Fetch what the cache lacks |
| `--locked` | None; use the recorded resolution | Fetch what the cache lacks |
| `--offline` | None; implies `--locked` | Cache only; fail naming the missing pinned content |

The default follows the origin's capability rather than a global preference. An origin that declares releases defaults to using them; an ad-hoc origin defaults to resolving at launch. `--locked` is how an ad-hoc origin is held stable across runs. No `--latest`, `--refresh`, or cache-freshness option is required, and none should be added.

#### Recorded resolutions

An ad-hoc run has no project lock to write, so its resolution is recorded in the cache under a namespace kept separate from content:

```text
resolutions/<selection digest> -> release_id, resolved_at, origin_ref
```

This is the one mutable record the cache holds, and its rules are deliberately narrow: written only by a resolution, read only at launch, **never consulted during a run**. It is not content, it is not authenticated by any release, and it must never be substituted for a pinned identity.

Recording resolutions makes one safety property nearly free. The previous release identity for a selection is already on hand, so a changed identity is reportable:

```text
gene: https://example.org/app/x.gene now resolves to a different release
      previous: <release_id>  (resolved 2026-09-01)
      current:  <release_id>
```

Trust-on-first-use with change reporting is the right posture here, for the same reason it is right for host keys: the tool cannot tell an intended update from an unintended one, but it can refuse to let the change pass unmentioned.

#### Ad-hoc runs are the most restricted, not the least

Pinning and approval are different acts. Selecting a declared release approves a release identity; running an ad-hoc URL approves a *locator* and accepts whatever it currently serves. The second is a weaker statement, so ad-hoc execution carries the **tightest** capability defaults, not the loosest — the opposite of the convenience gradient users expect. State the posture explicitly wherever ad-hoc mode is documented.

Ad-hoc content is otherwise ordinary. Its objects are content-addressed and verified on read like any other, and its compiled artifacts key on a content-derived release identity, so ad-hoc runs share the cache with declared releases without special-casing and without a path for one to poison the other.

## 5. Logical packages, paths, and imports

Ordinary source should keep ordinary import forms:

```gene
(import [helper] ^from "./utils.gene")
(import [parse] ^from "." ^pkg "parser")
```

The relative import resolves within the importing package's logical path space. The package import resolves its alias through the pinned dependency lock.

For example:

```text
Root package: acme/report at package revision P1
Module:       src/x.gene
Import:       ./utils.gene
Resolved:     P1 :: src/utils.gene
```

A file and a database row representing the same admitted package revision must not acquire different nominal type/protocol identities merely because their bytes were retrieved differently. Conversely, equal source text in two distinct package revisions is not sufficient reason to merge their module instances.

Reuse Gene's existing package identity, provenance, canonicalization, and lock semantics. The database path or SQL connection ID is a retrieval locator, not a substitute for package identity. Preserve source provenance during import/export rather than recreating identity from package name and version alone. [G1]

### 5.1 Path rules

Stored module and resource paths are relative, slash-separated logical paths. Use one canonical resolver across filesystem snapshots and database inventories.

- Resolve `.` and `..` using ordinary module-relative rules, rejecting escape above the package root.
- Reject absolute paths, NULs, and alternate spellings that produce duplicate logical entries.
- Use a defined, case-sensitive logical namespace; publishing must detect collisions relevant to supported filesystem exports.
- Keep supported extension and package-entry conventions in the ordinary resolver, not in separate SQLite-specific heuristics.
- Bind paths as SQL values; never concatenate a module path into a SQL statement.

A mixed-source dependency graph may be added later, but each dependency's source must be explicit and locked. The initial self-contained SQLite release requires its complete pure-Gene dependency graph in the store, apart from the compatible runtime's built-in facilities.

## 6. Immutable releases and consistent loading

### 6.1 Pin once

At launch, select an immutable release:

```text
application: acme/report
reference:   production
release:     R42
root:        P1
lock:        L7
```

Every runtime import, compile-time import, and packaged resource lookup for this run uses R42's graph.

Publishing R43 affects later selections of `production`. It does not change R42's running application or cause a deferred import to use R43.

This avoids a mixed application assembled from individually valid but incompatible module versions:

```text
x.gene       loaded before an update
utils.gene   loaded after an update
```

### 6.2 Pinning is a graph property

A release identifies:

```text
application key
root package revision
entrypoint metadata
exact locked dependency graph
package inventories with module/resource digests
format and runtime-compatibility requirements
```

**The release identity is a content digest over the canonical release manifest, not a sequence number.** Writing `R42` in this document is shorthand for such a digest. A sequence number is unique only within one store, which forces every cache entry and every compiled artifact to be namespaced by the store that produced it; a content-derived identity is unique everywhere, so a cache is safely shared across stores, across origins, and across machines, and a warm cache can be shipped beside a distributable store (§14). Deriving it requires the canonical metadata encoding that §7.2 already demands. This is inexpensive now and expensive once a schema has shipped.

Identity is derived from the manifest, and the manifest carries provenance (§5). Two origins serving identical bytes therefore yield identical *objects* but distinct *releases*, which is the intended outcome: content deduplicates, provenance does not.

The graph includes compile-time dependencies. Runtime imports must not run a package solver, consult a mutable latest-version table, or download an unlisted dependency as a side effect.

The selected release must authenticate its package inventories and their content references. Verifying each blob against a digest read from an unauthenticated, mutable mapping is not sufficient to prove the blob belongs to the selected release.

### 6.3 Do not keep a server-long database read transaction

Use a short consistent read to resolve the reference and obtain the release metadata. Then retrieve immutable records by their pinned identities.

For the first release, retain all published revisions. Online deletion is not necessary to demonstrate code persistence. In particular, do not garbage-collect modules that a pinned run may still import later.

A later retention design needs explicit roots and coordination with active readers, publishers, exports, and caches. If pinned content is unavailable, fail with a pinned-release error; never substitute another version.

## 7. Source representation and integrity

### 7.1 Store complete modules first

The authoritative form is complete UTF-8 module source. Preserve its bytes, comments, and source layout during import/export. Hash the stored byte sequence without silently reformatting or normalizing line endings.

Gene can parse that source into nodes for analysis or transformation, but a first implementation should not require a relational row for every function, expression, or property.

ASTs, declaration indexes, dependency indexes, and documentation indexes may be stored as derived data later. They must identify their source digest and format and be rebuildable from authoritative source.

A model-authored AST can be rendered to canonical source before publication. That is an explicit authoring step; loading does not reinterpret arbitrary database values as programs.

### 7.2 Digests and provenance

Use the existing package/source digest conventions where available. Digests cover source, manifests, lock data, and resource bytes. Canonical metadata serialization must define ordering and encoding before it is used to derive identities.

Keep descriptive provenance such as author, source repository, generation tool, and validation report separately from trusted publisher authentication. Model-supplied author fields are claims, not proof of authorship.

At read time, verify that returned bytes match their expected digest and size before handing them to the compiler or resource consumer. A corrupt cached copy is not a reason to select different source.

### 7.3 Compiled artifacts are optional caches

Source is sufficient for the first backend. A compiled cache may be added when useful, but its key must include all compilation-relevant inputs:

```text
source identity/digest
compiler and bytecode format
runtime ABI where relevant
target and compilation options
compile-time dependency/interface identities
```

Gene already implements this. The build artifact store keys objects by a derivation digest covering source digest, sorted dependency artifact digests, lock digest, features, compiler identity, target triple, profile, and optimization settings; its compiler identity is a hash of the running executable specifically because a version string covers neither build flags nor artifact ABI. Reads verify the payload digest *and* that the stored metadata agrees with the derivation it claims. This proposal should extend that store, not introduce a second one (§7.4).

The remaining risk in that key list is the last line. Gene has macros, fexprs, and compile-time imports, so a compiled module depends on more than its own bytes, and an under-specified dependency set fails silently rather than loudly. A pinned release already fixes the entire graph, which makes a coarse key available that cannot be wrong:

```text
release_id + package_revision + logical_path + compiler_identity
```

This forfeits reuse across releases that changed one unrelated module. Start here, and narrow the key toward the true compile-time dependency set only when that set can be computed exactly.

Security-policy admission must still run where required. Cache presence cannot bypass sandbox declaration restrictions or confer host authority: **admission re-runs on a cache hit.**

A writable local cache can live outside a read-only code database. Storing compiled results back in the database is an optional authoring/cache policy, not a requirement of `run`.

### 7.4 The local cache

Caching appears at several points in this design — prefetched remote content, compiled artifacts, materialized files, per-run reuse. They are one mechanism, and it should be named once rather than assumed separately in each place.

#### Contract

> The cache holds content that a pinned release authenticates, keyed by identities that release fixes. **A cache hit must be indistinguishable from a miss.**

Everything a store publishes is immutable and digest-named except its mutable reference records. A cache restricted to the immutable part is sound without any coherence protocol: entries cannot go stale, because nothing they are derived from can change.

The consequence worth stating plainly, because it is what makes the cache generic across origins:

> **The cache has no TTL, no freshness, and no revalidation.** Every entry is immutable by key. Freshness exists only in resolution (§3.1), which is not cached.

This is deliberately unlike an HTTP cache. Keying on a locator with revalidation would reintroduce the mixed-graph failure §6 exists to prevent — one module served from cache, another revalidated and refetched, within a single run. A URL is a locator, not an identity.

#### Layout

The two-level structure the artifact store already uses generalizes without change:

```text
objects/sha256/<aa>/<rest>        content, deduplicated across origins
derivations/sha256/<hex>/         pinned name -> active object
resolutions/<selection digest>    recorded resolutions only (§4.5)
```

A source cache is a second kind of derivation beside the existing build derivations. Content deduplicates across origins automatically, because objects are addressed by what they contain rather than by where they came from.

Gene has two local stores today: `~/.gene/packages` for package source objects, with its own GC, and `~/.gene/artifacts` for build artifacts, with verify-on-read, atomic insertion under a process lock, and permanent poisoning of derivations that failed reproducibly. Both are overridable by environment variable. The work here is to route origin retrieval through this existing shape, not to add a third store.

#### Digest algorithms

Origins authenticate content differently: this proposal's stores use SHA-256, while a Git host exposes SHA-1 blob identities. The cache should not become multi-algorithm to accommodate that. Instead:

- The **origin adapter** verifies whatever integrity the upstream provides, at fetch time.
- The **cache** verifies only its own SHA-256, computed locally, for both keying and integrity.
- The upstream digest is the adapter's obligation, never the cache's key.

Record honestly what each upstream digest is worth. A Git blob SHA-1 pins against corruption and a non-adversarial upstream; it is not collision-resistant and does not pin against an adversarial one. §12's rule that a hash detects mismatched bytes rather than an authorized publisher needs the companion observation that a weak hash barely detects even that. Where an adversarial upstream is in scope, the trust anchor is a signature or a locally recorded SHA-256, not the upstream's own identifier.

#### The compiled cache is a trust boundary; the object cache is not

These two are asymmetric and the difference decides how much protection each needs.

A cached source object is verified against the digest in the pinned inventory, so a corrupted or substituted entry is detected on read and the run fails as §6 requires. Storage integrity adds nothing the verification does not already provide.

**A compiled artifact cannot be verified against its source.** The only available check is that it agrees with the derivation it claims, which anyone able to write to the cache can satisfy for a payload of their choosing. A compiled cache hit is therefore trusted-path input to execution, and §12's separation of loading from authority depends on it not being writable by anything that is not already trusted.

Minimum: the cache root is private to the user, and a root whose permissions are wider than that is refused rather than used. It must never default to a shared or world-writable location. Hardening path, if a shared root is ever needed: a per-root secret with a MAC over each entry, so entries written by anything else are inert.

#### Eviction belongs here

§6.3 correctly refuses online garbage collection in the store, because a pinned run may import a module it has not reached yet. The cache is where collection *is* sound, since every entry is reconstructible from its origin. Placing eviction here relieves the retention pressure §6.3 defers rather than leaving it unowned.

- **GC roots are pinned releases.** A release is a root while it is recorded as a resolution, referenced by a lock, or pinned explicitly.
- Reachability runs through inventories, so an inventory must itself be a cached object.
- A pin operation materializes a release's complete closure and roots it. This is what makes `--offline` answerable and what the existing package `sync` already does for locked source.

Gene's artifact store has **no eviction at all** today; the existing cache GC covers package objects only. That gap is independent of this proposal and worth closing regardless.

#### Which caches to build, and when

| Cache | Scope | When |
| --- | --- | --- |
| In-process source/inventory | One Application, keyed by pinned identity | Exists; keep per-Application so distinct releases never share module instances |
| Compiled artifacts | Shared, keyed per §7.3 | When compile cost justifies it; extends the existing artifact store |
| Objects and inventories | Shared, content-addressed | With the first remote origin |
| Materialized files | Shared, digest-named paths | When the first native consumer needs real files (§11.3) |

A local SQLite store needs no object cache: the store file is already local, verified, and fast, and a cache in front of it is pure overhead. Keep §7.3's position that source is sufficient for the first backend, define the contract now, and add each layer when it earns its place.

### 7.5 What must never be cached

The rules above are only sound if the exclusions are explicit:

- **Reference resolution.** A reference-to-release mapping is the mutable part of the store. Recording one is permitted under §4.5's narrow rules; caching one as content is not, and no run consults one after launch.
- **Anything from a partially validated release.** Content becomes cacheable after the release authenticates it, not before.
- **Absence.** "Not in this release" is answered by the pinned inventory, never by remembering a failed fetch. A rate-limited or transient failure must not become a sticky negative entry.
- **Compilation failures.** A failed compile is not an artifact.
- **Admission and capability decisions.** Policy re-runs on every hit (§7.3, §12).

## 8. Proposed `gene_*` storage model

The following is a logical schema, not a mandatory SQL DDL or a promise that all database backends use identical storage types.

| Table | Main contents and key |
| --- | --- |
| `gene_meta` | Schema/format version, repository identity, default application selection. |
| `gene_blobs` | Content digest, byte length, and exact bytes for source, manifests, locks, inventories, and resources. |
| `gene_packages` | Immutable package-revision identity, package name/version, source provenance, manifest digest, and authenticated inventory digest. |
| `gene_modules` | `(package_revision, logical_path)` to source digest. Unique within the package revision. |
| `gene_resources` | `(package_revision, logical_path)` to resource digest and content type. |
| `gene_releases` | Immutable release identity, application key, root package revision, locked graph, and entrypoint/runtime metadata. |
| `gene_refs` | `(application_key, reference_name)` to release identity and publication generation. |

The package inventory authenticates the module/resource mappings. The corresponding tables are queryable indexes of that inventory and must agree with it. A reader cannot trust a changed index row over the pinned inventory.

Use foreign keys and unique constraints where the backend supports them, plus the same validation in publisher/reader code. Structural SQL integrity is not a substitute for checking digests, package ownership, and lock-graph completeness.

Reject a module/resource collision in the shared logical package namespace rather than making resolution depend on which table is queried first.

### 8.1 Mutable and immutable records

Published package contents, module mappings, resource mappings, and releases are immutable. `gene_refs` and selected repository defaults are mutable control records.

Authoring edits create a new candidate package/release. They do not run `UPDATE` against published source in place. Raw SQL modification outside the publishing API is an integrity/trust violation that readers should detect where their authenticated metadata permits it.

The `gene_*` namespace is reserved for code-store metadata. User data belongs in application-selected tables or databases. This naming rule is organizational; it is not access control.

### 8.2 Keep state tables outside this specification

There is intentionally no required `gene_state`, `gene_heap`, `gene_frames`, or universal checkpoint table. An application may store state alongside these tables, but this proposal does not define its representation or restoration semantics.

## 9. Publication protocol

Publishing changes stored code availability. It does not enter the application's `main` or replace a live module.

A proposed publisher flow is:

```text
Select a locked input project and intended application.
Collect exact module/resource bytes and dependency metadata.
Validate paths, manifests, compatibility, digests, and closure completeness.
Construct immutable package inventories and a release manifest.
Optionally compile/test candidates through explicitly bounded tooling.
Begin a short publication transaction.
Insert immutable content and metadata, verifying any existing identical IDs.
Compare-and-swap the selected application reference.
Commit.
```

Optional compilation and tests can execute compiler/macro or application behavior. They are separate, explicitly supervised validation work, not inert SQL validation and not something to run while holding the publication lock.

### 9.1 Compare-and-swap

A reference has a monotonically increasing publication generation. A publisher supplies the generation it observed. A concurrent change causes publication to fail with a conflict rather than overwrite the winner silently.

Updating the reference is the publication linearization point. Readers must see either the previous complete release or the new complete release, never a partially written graph.

For SQLite version 1, bounded package imports can insert their records and update the reference within one write transaction. All parsing, hashing, and expensive validation should happen before entering that transaction. Transactional behavior is a reason SQLite is a useful initial application container. [S1]

### 9.2 Rejection and interruption

A validation failure leaves the selected reference unchanged. A failed reference CAS must not activate the losing candidate in a running application.

If a publisher loses its connection around commit, resolve the result by checking the intended release and reference generation. Do not assume it failed and blindly issue a second update.

No code publication promises rollback of external effects caused during optional testing. Tests must use appropriate disposable resources and authority boundaries.

## 10. Loading and execution

A normal database-backed run follows this sequence:

1. Resolve the trusted backend configuration without exposing its credentials to application code.
2. Open the existing database in code-reader mode and validate its supported format.
3. Resolve the application/reference to an immutable release.
4. Validate the locked graph, package metadata, and runtime/backend compatibility before application execution.
5. Register source locations and package inventories with the ordinary loader.
6. Retrieve and verify the entry source and the source needed for compilation/imports.
7. Compile through the ordinary compiler under the chosen execution/admission policy.
8. Initialize modules and invoke the entrypoint through the ordinary runtime.
9. Release loader connections and resources at the end of their required lifetimes.

A compatible runtime and allowed host/native dependencies remain prerequisites. Unsupported web/native forms must continue to fail as they do for other source backends; database storage is not a backend capability upgrade.

Modules already initialized in an Application remain subject to normal load-once behavior. Multiple applications or distinct package revisions must not accidentally share mutable module instances just because they read the same database.

### 10.1 SQLite implementation boundary

The trusted adapter owns a dedicated connection for code retrieval. Its version-1 behavior should include:

- Open an existing database; never create or migrate it on `run`.
- Use read-only code access and bounded reads. Enable stronger read-only/authorizer settings appropriate to the embedding.
- Use fixed queries and bound parameters against validated expected schema objects.
- Do not load SQL extensions or install application-controlled SQL callbacks to read code.
- Apply source, manifest, resource-size, nesting, and load-time limits before unbounded allocation or compiler work.
- Report backend failures with the selected application, release, and logical object, without leaking credentials.

Read-only code access does not promise that no operating-system auxiliary file or cache will ever be involved. Storage/journal configuration and export behavior must be tested on supported platforms.

### 10.2 Offline and deferred access

A local SQLite file can supply the complete selected pure-Gene release. A remote implementation may prefetch and verify an immutable release into a local cache (§7.4).

Only a cache complete for the required pinned graph/resources can be advertised as fully offline. An incomplete cache must report which pinned content is unavailable.

Completeness is a question about the inventory, not about accumulated fetches. A cache can answer whether it holds a release's whole closure only if it holds that release's inventories, so the pin operation materializes inventories first and content second. `--offline` is then answered by comparing the inventory against the object store, and names precisely what is missing; it never degrades into fetching, and it never infers absence from a failed request (§7.5).

Do not query a database on every function call. After source loading, compilation, and initialization, ordinary execution uses normal runtime values. Further storage reads are needed only for deferred imports, explicit resource reads, or application data operations.

## 11. Resources, reflection, and diagnostics

### 11.1 Separate origin from filesystem location

Represent source origin conceptually as:

```text
package_identity
logical_module_path
source_digest
diagnostic_uri
optional_physical_path
```

A diagnostic could use an origin such as:

```text
gene-src://main/acme/report@R42/src/x.gene:27:5
```

`main` is a safe display alias, not a connection string. Origins must not contain passwords, access tokens, or sensitive database connection details.

Use one scheme across origins rather than a per-backend spelling such as `gene-db://`. The origin kind belongs in the alias, which the launcher assigns from its own configuration, so a diagnostic never carries a URL with embedded credentials and never has to be reformatted when the same release is served from somewhere else.

Use the immutable release/package identity in diagnostics so a later reference update does not make the diagnostic point to different source.

### 11.2 Audit filesystem assumptions explicitly

Existing filesystem-oriented `this_mod`/`this_pkg` paths and tools require an integration audit. [G1, G2]

Filesystem behavior should remain compatible. A database module must not pretend to have a physical directory when it does not. Introduce explicit origin/logical-path access where needed, and identify legacy operations that require materialization rather than silently manufacturing a path.

This limitation must be visible: a program that appends `/templates/page.html` to a source filename assumes a filesystem layout. Supporting its pure Gene imports does not automatically satisfy that assumption.

### 11.3 Package-relative resources

A portable resource API should retrieve bytes or text by package identity and logical resource path. The public function names are a separate library decision; the contract is:

```text
read packaged resource from the same pinned package revision
without changing directory or deriving a path from a diagnostic URI
```

Packaged resources are release inputs. Generated files, user documents, logs, and mutable configuration are ordinary application data and remain governed by their own paths and capabilities.

Tools or native libraries that require actual files can use an explicit materialization facility with a verified content cache and defined lifetime. That facility is a namespace in the shared cache (§7.4), not a separate mechanism: paths are derived from content digests, so they are stable and reusable, and "defined lifetime" becomes ordinary eviction once no pinned release roots them. Extracting executable content to a predictable path is security-relevant, so it inherits §7.4's requirement that the cache root be private to its owner. General native/resource extraction need not block pure-Gene SQLite execution.

### 11.4 Tooling and browser output

Errors, stack traces, module inspection, and source retrieval should work without the source checkout. Editor support can initially export or open read-only virtual source; a database editor is not a prerequisite.

For browser applications, the build/server retrieves database-backed Gene source and resources and emits normal browser artifacts. The browser does not receive database credentials. Supporting database sources in `$web/load` requires routing its source reads through the shared provider rather than assuming a filesystem graph. The reviewed workflow currently describes filesystem-based graph loading. [G2]

## 12. Security and capabilities

> **The host's ability to load code is not authority delegated to the loaded program.**

The loader's database connection, publication handles, credentials, and root capability configuration stay inside the trusted host. Application access to any database is an independent grant.

Separate these roles:

| Role | Authority |
| --- | --- |
| Code reader | Retrieve approved, selected code releases. |
| Publisher | Introduce immutable code revisions and update approved references. |
| Application | Execute with its separately selected operational capabilities. |

Capability requirements stored with code are inert requests. They do not mint grants. Apply the existing runtime capability intersections and chosen module/execution ceilings regardless of source backend. [G3]

For untrusted source, policy must exist before compilation, macro expansion, and initialization. Use the existing protected module-loading path instead of loading first and trying to restrict the result afterward.

Repository authenticity, release integrity, and execution permission are different checks. A hash detects mismatched bytes, not an authorized publisher. A trusted database connection is not a proof that every stored program is permitted to execute. The launcher must identify the trust policy for the selected application/reference or exact release.

### 12.1 Code and data in one SQLite file

Co-location is allowed, but an application with arbitrary write access to the entire SQLite file can undermine code-store immutability. The `gene_*` prefix is not a security boundary.

Possible deployments include a trusted application that manages its own database, a mediated data interface that excludes code publication, or physically separated code/data stores. Choose the trust boundary deliberately; do not claim table-level separation merely from distinct connections or names.

For generated plugins, keep publication behind an explicit host operation even when the underlying code and data occupy one database.

## 13. SQLite first and other origins later

The first backend is an ordinary local SQLite file. Its purpose is to prove the package/source abstraction and a usable self-contained code container.

### 13.1 Git hosts and plain HTTPS

Running an application straight from a Git host is a natural second origin, and it is a good test of whether the §3.1 split is real: it has no `gene_*` schema, no publication protocol, and no declared releases.

It fits better than it first appears. A commit identifier already pins a whole tree immutably, and a Git host's tree endpoint returns every path in that tree with its blob identity and size in a single request. That is an authenticated inventory — the thing §6.2 requires and a bag of raw URLs otherwise lacks. Resolution becomes:

```text
reference (branch, tag) -> commit identifier          one request, at launch
commit identifier       -> tree listing               one request
tree listing + manifest -> synthesized release        release_id = digest of it
```

Every content URL below that point names an immutable commit, so retrieval, caching, deferred imports, and offline operation all behave exactly as they do for a declared release. Nothing downstream needs to know the origin was a Git host.

This gives ad-hoc mode a useful gradient. **An ad-hoc origin that can name a whole tree is promoted to a pinned one automatically**, closing the walk window of §4.5 entirely; ad-hoc resolution remains the fallback only for origins that cannot, such as unrelated HTTPS URLs. A branch reference is still resolved once, at launch, and the resolved commit is recorded and reported.

Credential handling is unchanged from §12. A private repository's token belongs to the host, never to application code, never to a diagnostic origin (§11.1), and never to a cache key.



A later remote implementation can use:

```text
Gene launcher --> authenticated client/server database
```

or:

```text
Gene launcher --> code-store service --> SQLite or another database
```

Both must preserve immutable release selection, integrity checks, bounded reads, credentials separation, and explicit outage/cache policy.

Do not make a shared SQLite file on a network filesystem the default multi-machine architecture. A client/server database or a service boundary is the intended remote direction. SQLite's deployment guidance distinguishes these uses. [S2]

Remote fetches should batch manifests and source where useful. Lazy fetches still use pinned identities; they must not consult a mutable reference for each module.

Publishing, connection pooling, credential management, and backend-specific transactions are adapter concerns. The application import syntax and package identity model should not depend on whether the backend is SQLite, a remote database, or a Git host.

### 13.2 URL modules today

Gene's experimental `runurl` entry already loads a remote module graph, and its current shape is the one this proposal argues against: the canonical URL *is* the module identity, sources are fetched on demand as the walk reaches them, and the only cache is an in-process table living for one run. Nothing is hashed, pinned, or recorded, so two runs of the same command can execute different code with no way to tell that they did. Relative imports resolve against the final URL after redirects, so identity follows the locator wherever it leads.

Retrofitting it onto §3.1 is the cheapest available proof that the origin abstraction is genuine, and it is a prerequisite for the module identity fix in §15.1 rather than a separate effort.

## 14. Authoring, import/export, and maintenance

Filesystem/Git development remains a first-class workflow:

```text
Edit ordinary Gene project
    -> resolve/lock dependencies using existing package tools
    -> import into code store
    -> publish release
    -> run without checkout
```

Database-authored or Harness-generated code can follow the reverse path:

```text
Construct or edit candidate module
    -> validate and publish a new revision
    -> export source for review, version control, or debugging
```

Authoring command names are not fixed here. Required operations are explicit database creation, locked-project import, inventory inspection, release publication/reference update, source export, and integrity verification.

An export preserves source bytes, manifests, lock relationships, and logical resource paths. It does not silently fetch unlisted dependencies or overwrite unrelated destination files.

A distributable SQLite file must be produced as a consistent snapshot, using an appropriate backup/export mechanism rather than casually copying a changing database and ignoring its journaling state. SQLite provides supported snapshot-copy mechanisms; integrate one and test the result. [S3]

The initial version has no automatic online code-store GC. Deletion, compaction, cross-store deduplication, and remote active-reader retention are separate maintenance work. Schema migration is also explicit and must preserve a recoverable copy of the previous store.

## 15. Relationship to Gene Harness and Cordis

Gene Harness can use the code store for generated source, immutable dependencies, and approved code revisions. This can replace ad hoc materialized source-cache paths once the ordinary loader accepts database sources; the replacement is the shared cache of §7.4, which is the point of defining one mechanism rather than letting each consumer grow its own.

Responsibility remains divided:

```text
Code store:
    persist and retrieve immutable source/releases

Gene module loader:
    compile and initialize admitted modules

Cordis:
    own live plugin composition, activation, quiescence, and replacement

Gene Harness:
    choose desired plugins, approvals, execution policy,
    durable application state/history, and operator recovery
```

A database publication must not silently activate a plugin. A Cordis candidate may use a newly published immutable module, but live activation still requires its normal transaction and lifetime checks.

A rejected candidate can remain in the code store as an unselected revision or be retained for diagnosis. That is not the same as an active plugin. Store the distinction explicitly in the appropriate layer.

### 15.1 Version coexistence

A long-lived application raises a question pinning alone does not answer: an operator on one release wants a newer one, and the running process holds live values, closures, channels, and types minted from the old release's module bodies. The new code agrees with none of them.

Separate this from the freshness problem, which is already solved. A deferred import reaching for a module the run has not loaded yet retrieves the pinned release's bytes, so no run assembles a mixed graph by accident (§6.1); ad-hoc origins get the same property from eager closure resolution, with imports outside the closure rejected (§4.5). What remains is a *deliberate* version change, and that is a lifecycle problem, not a storage one.

The design already routes it correctly: §2.3 rules out implicit hot reload, and §15 gives activation, quiescence, and replacement to Cordis. The main thing to resist is the pull to solve it in the loader. In-place replacement of a module inside a live graph is how reload facilities become unsound in every language that has tried it.

The constraint that makes coexistence tractable:

> **Version boundaries must coincide with value boundaries.** Two code versions may coexist only where nothing but plain data crosses between them. Types, protocol implementations, closures, and object identity do not cross a version boundary.

That is why message passing tolerates coexisting versions and why reloading a module into a live object graph does not. It converts an open-ended compatibility problem into a checkable constraint on interfaces.

Three sound options, in order of ambition:

1. **Restart.** A new release runs in a fresh Application; the old one drains. Always correct, and already the model of §4.3. The cost is in-memory state, which is exactly why §16 keeps state persistence separate.
2. **Quiesce and swap** at plugin granularity. Cordis's existing job: stop in-flight calls, tear down, instantiate the new version, re-establish state through a values-only interface.
3. **Deliberate coexistence.** §5 already preserves distinct identities for distinct package revisions, so two versions can be loaded at once — provided the boundary between them carries only values.

Three Gene-specific consequences:

- **Module identity must include the release.** File modules key the load-once cache on `<package_identity>::<normalized_module_path>`, which is correct. URL modules currently key on the bare URL, so two versions of one URL collapse into a single cache entry and cannot coexist at all. Synthesizing a package identity from the resolved release makes the key uniform and is the single highest-value change this proposal implies for existing code.
- **Nominal type identity is an asset.** §5 requires distinct revisions to keep distinct type identities, so a value from the old release entering new code raises a type error instead of corrupting quietly. Preserve that behavior rather than smoothing it away.
- **Protocol implementations are the leak path.** Implementations register beyond the module that declares them, so a second version's implementations can become visible to the first version's call sites. Dispatch already invalidates cached sends when the implementation set changes, but the exposure here is visibility, not staleness, and scoped implementations and derive overlays sharpen it. Audit this before permitting coexistence.

Finally, a cheap win: the compiler already builds a compile interface per module. Comparing a candidate's interface against the one the running code compiled against turns a class of incompatibility from a runtime surprise into a pre-activation diagnostic. It will not catch semantic drift, but it gives Cordis grounds to reject a candidate before it goes live.

## 16. Code and data can co-live — motivation, not a resume design

A Gene database can contain executable module source, quoted forms, ordinary data, and application-defined state. An application may inspect stored code as data, transform it, validate a candidate, and publish another version. Merely retrieving the stored form remains inert; execution is explicit.

This creates a useful direction:

> **An application can keep descriptions of its behavior and its data together, while retaining distinct identities, permissions, and lifecycle rules.**

For example, an application-defined record might associate a saved world or plugin configuration with a code release. Such associations can help an application choose compatible behavior. This proposal neither specifies that record nor automatically creates it.

Co-location can also make a future code-and-data publication transaction possible. It does not tell us which live objects to capture, how to serialize them, when execution is at a safe boundary, how to restore resources, or whether repeating an interrupted operation is safe.

Those questions require a separate state-persistence/resume design. At minimum that future work must address object identity and cycles, schema/code compatibility, explicit checkpoints, deferred execution, native resources, authority restoration, and external-effect deduplication or compensation.

For this feature, the boundary is simple:

| Operation | Meaning here |
| --- | --- |
| Reopen the code database | Make stored code releases available to a fresh run. |
| Run a stored entrypoint | Initialize and execute normally. |
| Read application data | An explicit application operation. |
| Resume from application state | Application-specific today; no new automatic guarantee. |
| Resume a suspended VM/process | Out of scope. |

Code-only rollback changes the selected code release. It does not roll back user data, schema migrations, or external effects.

## 17. Implementation sequence

### Phase A — Shared source-read boundary

Identify filesystem assumptions in package discovery, module reads, compile-time imports, web loading, source locations, and resource lookup. Add an internal source-provider interface while retaining filesystem behavior and tests.

Split that interface along §3.1 from the start: resolution separate from retrieval, with the filesystem provider resolving trivially. Conflating them in the first adapter is what makes later origins expensive.

Two existing gaps belong here, because both are cheap now and structural later:

- Module identity for URL modules keys on the bare URL rather than a package identity, so versions cannot coexist and load-once cannot distinguish them (§15.1).
- Diagnostic origins should carry an origin kind and safe alias from the outset (§11.1), rather than being reformatted once a second origin exists.

Completion criterion: ordinary filesystem programs still use the same package/module semantics, and a small in-memory source provider can exercise the loader without relying on `eval`.

### Phase B — Local SQLite container

Implement the trusted SQLite adapter, versioned `gene_*` format, explicit creation/import tooling, and the proposed environment selection. Support one default application with a locked pure-Gene dependency graph and logical entry paths.

Completion criterion: the user's `gene run x.gene` example works with the checkout absent, including relative/package imports and useful diagnostics.

### Phase C — Release publication and resources

Add immutable release selection, reference CAS, full inventory/digest checks, package-relative resource retrieval, and source export. Test publication while an older run remains pinned.

Completion criterion: no mixed-version graph, no implicit filesystem fallback, and no live reload caused solely by reference publication.

### Phase D — Application integration

Exercise a representative Harness plugin package and a browser build/resource path through the source backend. Retain their existing live-state and recovery mechanisms rather than moving them into the code store.

Completion criterion: database storage is a usable alternative source for real applications, not only a one-module demonstration.

### Phase E — Ad-hoc and remote origins

Retrofit the experimental URL entry onto the resolve/retrieve split (§13.2): eager closure resolution, synthesized releases, recorded resolutions with change reporting, and `--locked`/`--offline`. Add a Git host origin and confirm it promotes to a pinned release through its tree listing (§13.1).

Completion criterion: the same cache, module identity, and diagnostic machinery serve a database store and a Git host with no origin-specific paths above the adapter, and a recorded resolution reproduces a previous run's exact release.

### Later work

Add a remote backend, optimized fetch/cache behavior, optional compiled artifacts, richer declaration indexes, publication authentication integrations, and coordinated retention when required. Close the artifact store's missing eviction (§7.4) and give it GC roots from pinned releases.

Do not make automatic state capture/resume, a persistent object heap, or general online GC prerequisites for these phases.

## 18. Acceptance tests

Tests should compare observable behavior with filesystem loading where the same program is supported, while separately testing database-specific selection and integrity.

| Case | Required result |
| --- | --- |
| Minimal database run | With only the runtime and `test.sqlite` present, `gene run x.gene` runs the stored entry. |
| Missing database | Fail; do not create a file or use local source. |
| Missing/ambiguous default application | Require an explicit selection; do not search all packages. |
| Missing module in selected release | Report its package/path/release; do not fall back to disk. |
| Relative import | Resolve against the importing module's logical package path. |
| Package alias import | Resolve through the exact locked dependency edge. |
| Multiple versions | Preserve distinct admitted package/module identities. |
| Load once | Repeated imports initialize a module once per ordinary Application contract. |
| Compile-time dependency | Load from the pinned graph without runtime dependency solving. |
| Escaping logical path | Reject before querying or executing the target. |
| Publication during a run | Existing and deferred imports/resources remain on the original release. |
| Concurrent publishers | Exactly one wins the same reference-generation CAS; the loser does not overwrite it. |
| Failed publication | Readers keep selecting the old complete release. |
| Changed source or index row | Digest/inventory validation rejects mismatch before execution. |
| Unknown format/runtime requirement | Fail with a compatibility diagnostic; do not migrate on run. |
| Packaged resource | Return the version from the pinned package, independent of working directory. |
| Source error | Report logical origin and line/column without leaking connection secrets. |
| Read-only code mode | Ordinary execution does not update `gene_*` metadata or require cache writes there. |
| Untrusted initialization | Limits and authority policy apply before compilation/initialization, not afterward. |
| Loader credential boundary | Application code cannot obtain the loader connection or publication authority. |
| Export round trip | Preserve source bytes, inventories, resources, and dependency relationships. |
| Incompatible compiled cache | Recompile from pinned source or report incompatibility; never execute blindly. |
| Browser build | Emit normal assets without exposing the database connection to the browser. |
| Repeated run of same database | Start fresh runtime execution; no implied variable/task restoration. |
| Code and application data co-location | Reading code does not execute data; data writes do not gain publication rights through the code-store API. |
| Future remote outage | Use only verified available pinned content or fail explicitly; never switch release. |
| Cache hit equals cache miss | A run with a warm cache and a run with an empty one produce identical observable behavior. |
| Cache entry has no lifetime | No elapsed time and no upstream change alters what a pinned identity retrieves. |
| Corrupt cached object | Detected against the pinned inventory; refetch or fail, never substitute. |
| Foreign compiled artifact | A compiled entry not written by a trusted cache root is refused, not executed. |
| Admission on a cache hit | Capability and sandbox policy re-run identically whether or not an artifact was cached. |
| Cache root permissions | A root readable or writable beyond the owning user is refused rather than used. |
| Ad-hoc resolution | Resolving twice across an upstream change yields two recorded releases, each internally consistent. |
| Ad-hoc change reporting | A selection resolving to a new release identity reports the previous one. |
| Import outside the pinned closure | Rejected by default, naming the module and the pinned release. |
| `--locked` on an ad-hoc origin | Reuses the recorded release without contacting the origin for resolution. |
| `--offline` with an incomplete cache | Fails naming the missing pinned content; never falls back to fetching. |
| Cross-origin object reuse | Identical bytes from two origins occupy one object and two distinct releases. |
| Git host promotion | A branch reference resolves once to a commit and thereafter behaves as a pinned release. |
| Two versions loaded | Distinct releases yield distinct module identities and distinct nominal types; no load-once collision. |

## 19. Decisions to keep and limited follow-up choices

The following are the stable decisions of this proposal:

- Database storage is an alternative source for ordinary Gene packages/modules.
- Local SQLite is first; the architecture permits other backends.
- The proposed environment invocation remains supported.
- Source is authoritative, module-granular, and inert until explicitly loaded.
- Runs pin complete immutable release graphs, including compile-time dependencies and resources.
- Publisher authority, loader authority, and application capabilities stay separate.
- Code and data may share physical storage, but automatic state capture/resume is not part of this work.
- Every origin splits into mutable resolution and immutable retrieval; resolution happens once per launch.
- Release identity is a content digest, so caches and artifacts are shareable across stores and machines.
- The local cache holds only what a pinned release authenticates, has no freshness semantics, and is one mechanism reused rather than one per backend.
- Ad-hoc origins synthesize a release by resolving eagerly; a mode flag selects whether resolution happens, never whether an entry is fresh.
- Version boundaries coincide with value boundaries; deliberate replacement belongs to Cordis, not the loader.

Before implementation, align the additional CLI names, canonical inventory encoding, package-identity mapping, and source-origin/resource APIs with the current repository. These are bounded integration choices, not permission to introduce another package system or execution model.

## 20. Basis and references

This document records the database-backed code-storage discussion and the decision to keep application-state capture/resume separate. All interfaces and schema additions above are proposed. No implementation or test-suite execution is claimed.

Repository references identify the baseline already inspected in the preceding discussion, commit `0cb9cc76562d2d8e7319cbc15a1d99cf523b6e85`; they are not a new audit of a later `main`:

- **[G1]** Gene `docs/spec/modules.md`: package/module identity, locked imports, initialization, and sandbox-generation lifecycle.
- **[G2]** Gene `docs/workflows.md`: package/build workflows, browser graph loading, source paths, and native deployment boundaries.
- **[G3]** Gene `docs/spec/authority.md`: separation of namespace access, operational capabilities, resource restrictions, and execution policy.
- **[G4]** Gene `src/gene/build.nim`: the build artifact store — derivation identity, compiler identity, content-addressed objects, verify-on-read, atomic insertion, and derivation poisoning.
- **[G5]** Gene `src/gene/package.nim`: the package object store and its cache collection, and the user package store root.
- **[G6]** Gene `src/gene/vm.nim`: module identity and the load-once cache, static import collection, protocol-dispatch invalidation, and the experimental URL module entry.
- **[G6a]** Gene `src/gene/compiler.nim`: per-module compile interfaces, the basis for a pre-activation compatibility check.
- **[G7]** Gene `docs/workflows.md`: existing `--locked` and `--offline` launcher semantics, package sync/vendor/cache commands, and build artifact reuse by derivation identity.

External background discussed previously:

- **[S1]** SQLite, application-file-format guidance: `https://www.sqlite.org/appfileformat.html`.
- **[S2]** SQLite, appropriate deployment models: `https://www.sqlite.org/whentouse.html`.
- **[S3]** SQLite, online backup guidance: `https://www.sqlite.org/backup.html`.

Repository references [G4]–[G7] describe mechanisms that exist today and that this proposal extends rather than replaces. They were read at the same baseline commit and are not a claim about later `main`.

**Summary:** Persist Gene packages, modules, and resources outside a source tree; resolve a selection once to a verified immutable release; retrieve its content through one shared local cache; run it through the ordinary Gene runtime. Permit code and data to co-live without equating code persistence with automatic application-state persistence, resumption, or live module replacement.
