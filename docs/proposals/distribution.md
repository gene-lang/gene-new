# Gene Distribution Design

**Status:** draft image-format design, reconciled with the current
package/build proposals; pre-implementation

**Scope:** application images and executable distribution for simple and
complex Gene applications

**Builds on:** `package.md` for exact package graphs and `package-build.md` for
planning, artifacts, assembly, and installation. If older dependency/build
wording in this document conflicts with those proposals, they take precedence.
**Revision date:** 2026-08-01

---

## 1. Goal

Gene should support easy distribution of applications without requiring users to install a separate Gene runtime manually.

The core design is:

```text
GIR application image = canonical deployable program representation
Standalone executable = target launcher + embedded application image
```

A Gene application does **not** need typed-native compilation to become a
standalone executable. The default distribution path embeds the Gene runtime/VM
plus a precompiled application image containing GIR bytecode, module metadata,
resources, and optional native artifacts.

The typed-native backend remains an optimization layer, not a prerequisite for
distribution.

The durable artifact is the application image. The executable is a target-specific delivery wrapper around that image.

---

## 2. Terms

### Application

A running Gene program. At startup, Gene creates an `Application`, loads the entry package/module, executes the entry module top to bottom, then calls `main` with command-line arguments if `main` exists.

### Package

A source, identity, and dependency unit that declares library/application
targets. Its exact model and resolution semantics are defined by `package.md`.

### Module

A code unit such as a `.gene` file, `.geni` file, eval source unit, generated overlay, or compiled GIR module.

### Application image

A self-contained, mostly platform-neutral artifact containing the compiled Gene application:

```text
app.gapp
```

It contains GIR modules, metadata, resources, optional debug/source-map data, optional native artifacts, and optional signatures.

### Image digest

The canonical hash of the image's signed semantic content. The digest is computed from the canonical manifest and indexed content table, not from ambient filesystem metadata.

### Launcher

A small target-native executable that embeds or locates a Gene application image, creates the runtime, mounts the image, and starts the application.

### Standalone executable

A launcher plus embedded application image:

```text
my-app
```

A standalone executable is target-specific even when the embedded GIR modules are portable.

### Distribution bundle

A higher-level artifact containing one portable `.gapp` plus one or more target-specific launchers and native artifacts. A bundle is useful for cross-platform release distribution, but it is distinct from a single standalone executable.

---

## 3. Distribution modes

Gene should support four distribution artifacts.

### 3.1 Portable application image

A `.gapp` contains the compiled Gene application but not the runtime executable. It can run on any compatible Gene runtime that supports the image format, GIR ABI, value ABI, and required features.

Use this for:

- development builds;
- plugin distribution;
- testing;
- server environments where Gene is already installed;
- cross-platform package distribution when target-specific native artifacts are absent.

### 3.2 Standalone VM executable

This embeds:

```text
target-native launcher
Gene runtime / VM
application image
```

This should be the default end-user distribution mode. It supports dynamic Gene features while requiring no separate Gene installation.

### 3.3 Mixed-code executable

This embeds:

```text
Gene runtime / VM
GIR fallback modules
native-compiled typed functions/modules where available
application image metadata
```

Typed-to-typed calls may use direct native calls. Dynamic, reflective, untyped,
or unsupported functions remain GIR/VM code. Mixed mode preserves the same
source semantics as VM mode and must preserve GIR fallback. Format 1 defines
only `vm` and `mixed`; a strict fully native product is not designed here.

### 3.4 Multi-target distribution bundle

A bundle may contain:

```text
app.gbundle/
├── app.gapp
├── launchers/
│   ├── aarch64-apple-darwin/app
│   ├── x86_64-unknown-linux-gnu/app
│   └── x86_64-pc-windows-msvc/app.exe
└── index.gene
```

The bundle is not the canonical program representation. The `.gapp` remains canonical; launchers are target-specific wrappers.

---

## 4. Application image physical format

A Gene application image should be a deterministic indexed image format.

The semantic format is **Gene-specific**. It should not be defined as arbitrary
ZIP, arbitrary tar, or arbitrary Gene source syntax. The first format-1 writer
may use a restricted ZIP-like container for convenience, but the reader and
writer must enforce Gene image semantics.

Conceptual binary layout:

```text
app.gapp
├── fixed header
├── canonical manifest
├── canonical index / content table
├── blob region
│   ├── GIR module blobs
│   ├── resource blobs
│   ├── source/debug blobs
│   ├── native blobs
│   └── other extension blobs
└── signature / footer region
```

Conceptual logical structure:

```text
app.gapp
├── manifest.gene
├── index.gene
├── modules/
│   ├── <module-id>.gir
│   └── ...
├── sources/              # optional, debug builds only
├── sourcemaps/           # optional, usually omitted from sealed release builds
├── resources/
├── native/
│   ├── aarch64-apple-darwin/
│   ├── x86_64-unknown-linux-gnu/
│   └── x86_64-pc-windows-msvc/
└── signatures/
```

Required canonicalization rules:

```text
- one canonical manifest;
- one canonical content index;
- normalized UTF-8 logical paths;
- no duplicate logical paths;
- stable entry ordering;
- no build-machine absolute paths in semantic metadata;
- no current timestamps in hashed content;
- no ambient filesystem permissions in hashed content unless explicitly modeled;
- explicit compression method per blob;
- explicit content hash per logical entry;
- explicit encoded blob hash per stored entry;
- explicit offset, stored size, and uncompressed size per indexed blob.
```

### 4.1 Restricted ZIP-like format-1 option

A restricted ZIP-like implementation is acceptable for the MVP if and only if Gene treats ZIP as an implementation detail.

If used, the writer must enforce:

```text
- deterministic entry order;
- normalized paths;
- fixed or omitted timestamps;
- no duplicate entries;
- no archive comments;
- no platform-specific extra fields in hashed semantics;
- ZIP64 support when needed;
- manifest and index validation independent of central directory quirks.
```

The long-term contract is the Gene image model, not ZIP compatibility.

### 4.2 Memory-map compatibility

The v1 format should be memory-map-compatible even if the first implementation uses normal reads.

Format requirements:

```text
- header, manifest, and index can be read without scanning the entire file;
- every blob has explicit offset and length;
- large blobs can be aligned to predictable boundaries;
- hot GIR/module blobs may be stored uncompressed;
- cold resources may be compressed independently;
- the reader can operate on a file, byte slice, memory map, or embedded executable subrange;
- no whole-image decompression is required to start an application.
```

Memory mapping is an optimization, not a semantic dependency. A valid `.gapp` must work with ordinary reads.

---

## 5. Manifest

Every application image has a manifest. The manifest should be canonical, inspectable without executing user code, and small enough to read at startup before mounting all content.

Example conceptual form:

```gene
(app_image
  ^format_version 1
  ^compiler_version "0.1.0"
  ^value_abi 1
  ^gir_abi 1
  ^requires (runtime
    ^min_format_version 1
    ^min_value_abi 1
    ^min_gir_abi 1
    ^features [vm streams modules])
  ^root_package_id "pkg:acme/widget@1.2.0#sha256:..."
  ^application_target "widget"
  ^entry_module "src/apps/widget.gene"
  ^mode vm
  ^profile release
  ^sealing sealed
  ^debug_info min
  ^portable true
  ^targets []
  ^module_graph_digest "sha256:..."
  ^source_lock_digest "sha256:..."
  ^package_graph_digest "sha256:..."
  ^package_graph_blob "metadata/package_graph.gene"
  ^modules {}
  ^resources {}
  ^native {}
  ^signatures {})
```

The manifest should include:

- image format version;
- compiler version;
- runtime/value ABI version;
- GIR ABI version;
- compatibility requirements and required runtime features;
- immutable root package instance and application target;
- entry module;
- image mode: `vm` or `mixed`;
- build profile name and effective sealing mode (`sealed` or `open`);
- debug-info level: `full`, `min`, or `none`;
- target triples when target-specific content exists;
- module table;
- resource table;
- complete frozen package-instance graph and its digest;
- native artifact table;
- content hashes for all included content;
- image digest metadata;
- optional signature metadata.

`source_lock_digest` identifies the exact source resolution consumed by the
build. `package_graph_digest` identifies the image graph after mutable
workspace/path nodes have been frozen to source-tree digests. The graph blob is
Canonical Gene Data v1 from `package.md` §6.3 and is itself covered by the image
content index.

Use `^targets` rather than a single top-level `^target` for images that may contain multiple target-specific native artifacts. A singular target field is acceptable only for a fully target-specific image or executable metadata wrapper.

---

## 6. Module table

Each module entry should contain:

```gene
(module_entry
  ^id "/app/main"
  ^package_id "pkg:acme/widget@1.2.0#sha256:..."
  ^logical_path "/main"
  ^source_kind gene
  ^source_digest "sha256:..."
  ^gir_digest "sha256:..."
  ^gir_blob "modules/app/main.gir"
  ^imports [...]
  ^exports [...]
  ^debug_source nil
  ^sourcemap nil
  ^native [...])
```

Rules:

- Module identity uses normalized logical package/module paths, not build-machine absolute paths.
- Modules remain separate inside the image.
- Import/load-once semantics are preserved.
- Namespace identity is derived from package plus module logical path.
- Source text may be included in debug builds and omitted in release builds.
- Full source maps are omitted by default from sealed release builds.
- Minimal stack-trace metadata is preserved by default unless the effective
  `debug_info` level is `none`.
- GIR is the required portable executable form in `vm` and `mixed` modes.
- Native code, when present, is an optional acceleration for selected typed functions/modules.

Do not concatenate all modules into one large module. Module boundaries are semantically significant for namespaces, imports, declarations, reflection, protocol implementation visibility, caching, and future live-code evolution.

---

## 7. Startup sequence

A standalone executable starts like this:

```text
1. Locate embedded application image.
2. Read executable footer or platform-specific embedded image locator.
3. Open the image as a file, byte range, byte slice, or memory map.
4. Verify image magic, format version, and basic bounds.
5. Read canonical manifest and index.
6. Verify image digest and required hashes.
7. Verify signature if policy requires a trusted signature.
8. Check runtime/value ABI, GIR ABI, and required feature compatibility.
9. Create Application.
10. Mount image as read-only virtual package filesystem.
11. Create/load entry package.
12. Load entry module from the image module table.
13. Execute entry module top to bottom.
14. If entry module has main, call main with command-line arguments.
15. Convert main result to process exit code.
```

`main` result convention:

```text
nil -> exit code 0
Int -> that exit code
other value -> TypeError / startup error
```

Image startup should match source-application execution semantics as closely as
possible. The difference is where modules and resources are loaded from.

---

## 8. Assembly input

This document begins at the `Assembler` seam defined by `package-build.md`.
The assembler receives an `AssemblyRequest` and verified `BuildResult`; it does
not discover packages, resolve imports, compile modules, execute recipes, or
choose toolchains. Its input already identifies the application target,
profile, mode, target triples, frozen source snapshots, artifacts, and source
lock digest.

The same interface accepts an ad-hoc application or a regular package target.
How those roots become a `BuildResult` belongs to `package.md` and
`package-build.md`; the image format does not encode a second build path for
single-file programs.

---

## 9. Assembly output

The assembler returns one verified `ApplicationArtifact`: a portable `.gapp`,
a target-specific launcher containing that image, or a multi-target bundle.
It may sign, embed, and encode already-built artifacts, but it never mutates the
source lock or artifact store. Registry, SemVer, workspace, build recipe,
toolchain, system-dependency discovery, and cross-compilation policy remain
owned by the upstream package/build modules.

---

## 10. Frozen package graph

Every image contains the complete runtime projection of the resolved package
graph. It is not resolver-neutral metadata and it is not an invitation to solve
again at startup. Each entry is:

```gene
(image_package
  ^id "pkg:acme/widget@1.2.0#sha256:..."
  ^source_id "workspace:acme/widget@1.2.0#sha256:..."
  ^name "acme/widget"
  ^version "1.2.0"
  ^tree_digest "sha256:..."
  ^manifest_digest "sha256:..."
  ^features []
  ^dependencies {
    ^json (locked_edge
      ^scope runtime
      ^target "pkg:acme/json@1.4.2#sha256:...")
  }
  ^modules [...]
  ^capabilities [...])
```

`id`, `name`, `version`, `tree_digest`, `manifest_digest`, `features`,
`dependencies`, `modules`, and `capabilities` are required. `source_id` is
required when the source lock node had a different mutable identity; otherwise
it is omitted. Entries and alias maps use the lock ordering rules. Development
and host build edges are excluded from the runnable projection, but their
source/artifact provenance remains in the signed build statement.

Every workspace/path node is snapshotted and assigned the ordinary immutable
`pkg:<name>@<version>#sha256:<instance_identity_hex>` image ID. Its canonical
frozen source identity includes the original source ID, and its instance digest
also covers the frozen tree digest. All incoming locked edges are rewritten to
that ID. Distinct versions remain distinct entries, so an image
may contain C 1.0, 1.1, and 1.2 simultaneously. The image loader builds one
package-ID table and one alias table per package; runtime imports perform no
manifest parsing, directory search, hashing, version solving, or network I/O.

---

## 11. Open and sealed images

Gene should support two sealing modes, selected by a profile or an explicit
per-build override.

### 11.1 Sealed application

A sealed image records `^sealing sealed`.

A sealed app has these properties:

- all imports are resolved at build time;
- no filesystem module loading at runtime;
- no general runtime compilation unless explicitly included;
- reader/compiler may be omitted from the launcher when unused;
- smaller executable;
- easier dead-code elimination;
- better deployment predictability.

A sealed app may still use macros/templates expanded during build. It may still include `eval` only if the build explicitly opts into runtime compilation support.

### 11.2 Open application

An open image records `^sealing open`.

An open app may include:

- reader;
- compiler;
- dynamic `eval`;
- plugin loading;
- dynamic module search paths;
- runtime-generated code;
- optional FFI/native loading authority.

Open apps are larger and require stricter capability control, but they are
suitable for REPLs, plugin hosts, development tools, and runtime-extensible
systems.

### 11.3 Debug information profiles

The image manifest records an explicit `debug_info` level: `full`, `min`, or
`none`.

Recommended defaults:

```text
development build       -> full
release sealed build    -> min
release open build      -> min
hardened release build  -> none, only when explicitly requested
```

The `min` level should retain enough metadata for useful diagnostics:

```text
- module id;
- function/binding name;
- bytecode offset to compact span id;
- optional source file name without source text;
- symbol table data needed for stack traces.
```

The `full` level may include source maps and optional source snippets. The
`none` level strips everything not required by the VM.

Default recommendation:

```text
simple CLI/server app -> sealed
REPL/plugin/runtime-extensible app -> open
sealed release app -> omit full source maps, keep minimal stack-trace metadata
```

---

## 12. Runtime capabilities in packaged apps

A packaged executable should not imply ambient authority.

Filesystem, network, subprocess, FFI loading, and writable directories should still be represented through explicit runtime capability values.

Examples:

```gene
(fn main [args]
  ...)
```

or future explicit capability injection:

```gene
(fn main [args, ^config : fs/ReadDir, ^logs : fs/WriteDir]
  ...)
```

Build metadata may declare requested capabilities, but granting them remains a runtime/deployment decision.

---

## 13. Resources

Embedded resources live inside the application image and are read through an application resource API.

Example APIs:

```gene
(app/resource "/templates/home.html")
(app/resource-bytes "/assets/logo.png")
(app/resource-stream "/data/items.jsonl")
```

Rules:

- Embedded resources are read-only.
- Resource paths are normalized image-relative paths.
- Resources are content-hashed in the manifest.
- Resources may be compressed independently per entry.
- Resources should not pretend to be writable filesystem files.
- Writable app data belongs in external config/data/cache directories accessed through explicit capabilities.

Each resource entry should include encoding metadata and dual hashes:

```gene
(resource_entry
  ^path "/assets/app.css"
  ^content_type "text/css"
  ^encoding zstd
  ^encoding_level 6
  ^content_digest "sha256:..."      ; hash of uncompressed logical bytes
  ^blob_digest "sha256:..."         ; hash of stored encoded bytes
  ^uncompressed_size 48291
  ^stored_size 9172
  ^blob_offset 1048576)
```

Initial compression methods:

```text
store  -> no compression
zstd   -> deterministic zstd settings fixed by the builder/profile
```

Recommended resource compression policy:

```text
small hot resources       -> store
hot GIR startup modules   -> store initially
large text resources      -> zstd
large JSON / HTML / CSS   -> zstd
already-compressed media  -> store
native libraries          -> usually store
source maps               -> zstd
```

Potential standard writable locations:

```text
app config directory
app data directory
app cache directory
temporary directory
```

---

## 14. Native artifact entries

This section uses **native artifact** to mean target machine code already
produced or selected by `BuildEngine`. It does not define typed Gene lowering
(`native-type.md`) or system-library discovery (`package-build.md` §8).
Native artifacts are target-specific.

The image may contain:

```text
native/aarch64-apple-darwin/libfoo.dylib
native/x86_64-unknown-linux-gnu/libfoo.so
native/x86_64-pc-windows-msvc/foo.dll
```

Rules:

- Store each artifact under its target record with its artifact kind, logical
  load name, ABI metadata, and content digest.
- Verify hashes before loading.
- When the OS cannot load from memory, extract libraries into a
  content-addressed runtime cache before loading.
- Arbitrary dynamic loading requires an explicit `$ffi/load` capability.
- Raw pointer/unsafe FFI APIs may require `$ffi/unsafe`.
- Native artifacts should not change the logical identity of portable GIR modules.

A standalone executable is target-specific even if its GIR modules are portable.

---

## 15. Mixed-code image records

This section uses **mixed image** to mean an image containing GIR plus eligible
typed Gene machine-code artifacts. `native-type.md` owns the compiler backend;
`package-build.md` owns eligibility, compilation, link planning, and target
selection. The distribution reader only validates and exposes the records.

Modes:

```text
vm       GIR only; VM executes all Gene code
mixed    GIR fallback plus native code for eligible typed functions/modules
```

Mixed mode behavior:

```text
dynamic caller
-> typed boundary adapter
-> native typed function
-> boxed result or typed error adapter
-> dynamic caller
```

Native code may call VM code through the runtime trampoline. VM code may call native code through ordinary `Callable` dispatch/adapters.

Mixed mode must keep GIR fallback by default. This protects:

```text
- dynamic dispatch;
- reflection;
- stack traces;
- eval/open-app behavior;
- cross-target portability of the image;
- runtime deoptimization;
- unsupported language features;
- runtime overlays;
- typed/untyped boundary behavior.
```

Format 1 requires GIR fallback for every native-accelerated Gene module. A
reader rejects a mixed record whose fallback is absent.

---

## 16. Target records and launchers

This document records target-specific content; it does not define
cross-compilation. `package-build.md` owns target/toolchain selection and emits
one verified artifact set per target. A standalone launcher names exactly one
OS/architecture/runtime environment, while a bundle may index several.

A target record should use conventional target triples:

```gene
(target
  ^triple "x86_64-unknown-linux-gnu"
  ^launcher_abi 1
  ^native [...]
  ^runtime_features [...])
```

Rules:

- One standalone launcher entry exists per target.
- Multi-target distribution uses a bundle/index layer.
- The `.gapp` remains the canonical application image.
- Target-specific native libraries and launchers are represented as target records.
- Platform conveniences such as macOS universal binaries may be supported as target-platform features, not as the general distribution model.

---

## 17. Embedding strategy

The simplest executable layout is:

```text
[launcher executable][application image][footer]
```

Footer:

```text
magic bytes
footer format version
image offset
image length
image digest
optional signature block offset
optional signature block length
```

Startup reads the footer, finds the image, verifies it, and mounts it.

Implementation notes:

- Append the image before platform code-signing.
- Sign or verify the inner `.gapp` as a Gene artifact.
- Also use platform OS code signing where applicable.
- Keep a two-file fallback: `app` plus `app.gapp`.
- Some platforms may prefer dedicated executable sections/resources instead of appended data.
- The logical image format should not depend on the embedding technique.
- The image reader should support subranges so embedded images do not require copying.

---

## 18. Verification, signing, and reproducibility

Application images should support deterministic builds.

Requirements:

- canonical module ordering;
- normalized logical paths;
- stable manifest and index serialization;
- no current timestamps in hashed content;
- content hashes for all modules/resources/native files;
- encoded blob hashes for stored blobs;
- compiler/version/ABI metadata;
- required source lock and frozen package-graph digests;
- canonical image digest;
- optional signature block.

The image verifier checks:

```text
image format
ABI compatibility
manifest/index consistency
manifest hashes
resource hashes
native artifact hashes
entry module existence
required runtime features
signature validity when present
trust policy when requested
```

Signing should be layered:

```text
Layer 1: content hashes
  Every module/resource/native blob has a hash.

Layer 2: image digest
  Canonical manifest plus content table produce one image digest.

Layer 3: signature block
  One or more signatures cover the image digest.

Layer 4: provenance / transparency
  Optional build attestation, certificate chain, transparency log proof, or registry proof.

Layer 5: deployment trust policy
  Runtime or deployment configuration decides whether a signer, key, certificate, or registry root is trusted.
```

Conceptual signature block:

```gene
(signature_block
  ^image_digest "sha256:..."
  ^signatures [
    (signature
      ^scheme cose_sign1
      ^key_id "..."
      ^cert_chain [...]
      ^transparency_entry nil
      ^timestamp "..."
      ^signature_bytes #"...")])
```

Trust roots should not be hard-coded into the image. They should come from one or more external policies:

```text
- local developer keyring;
- enterprise trust policy;
- OS trust store, where appropriate;
- Gene registry trust metadata;
- explicit invocation trust policy;
- deployment orchestrator policy.
```

Recommended trust model:

```text
private/internal apps
  -> self-managed signing keys and local/enterprise policy

public Gene packages
  -> registry trust metadata, optional keyless signing, optional transparency logs

standalone executables
  -> sign the inner .gapp and also use platform code signing where applicable
```

Do not rely only on platform code signing. OS code signing verifies the executable as an OS artifact; Gene still needs to verify the embedded application image as a Gene artifact.

---

## 19. Runtime overlays do not mutate images

A `.gapp`, its embedded package graph, and its signatures are immutable.
Format 1 has no self-update or persistent code-activation protocol. An open
application may evaluate temporary code or load a host-managed external overlay
when explicit runtime capabilities allow it, but that overlay is not part of
the image identity and cannot rewrite the mounted package graph.

Any future persistent overlay protocol requires a concrete consumer and a
separate design for provenance, activation, rollback, and trust. It must keep
the signed base image intact rather than teaching the image writer or loader to
modify installed applications.

---

## 20. Command ownership

This document defines no command names or flags. `package-build.md` §13 is the
single command-surface contract for building, packing, running, inspecting,
verifying, signing, bundling, and installing application artifacts. Image
readers/writers expose internal interfaces used by those commands; they do not
grow a parallel distribution CLI.

---

## 21. Assembly pipeline

The distribution-owned portion of the pipeline is:

```text
AssemblyRequest + verified BuildResult
-> freeze mutable package nodes into the image package graph
-> close the runtime module/resource/native graph
-> write canonical manifest
-> write canonical content index
-> write deterministic application image
-> optionally sign image digest
-> optionally embed image into target launcher
-> verify resulting artifact
```

Assembly fails if:

- a required artifact or frozen package node is missing or stale;
- an artifact is incompatible with the requested target, mode, or ABI;
- a sealed image contains forbidden dynamic capability metadata;
- runtime ABI/GIR ABI mismatch is detected;
- image canonicalization fails;
- hash verification fails after writing;
- requested signing policy cannot be satisfied.

---

## 22. Delivery order and promotion gates

These are artifact increments inside the single `Assembler` module, not a
second phase plan. Preserve the final image/assembler interfaces, but promote
an increment only when its consumer exists:

| Increment | Demand that justifies it |
|---|---|
| Portable deterministic `.gapp` | an application must run without source checkout or compiler work |
| Embedded VM launcher | users must run that image without a separately installed Gene runtime |
| Sealed/open encoding | a deployment or plugin host needs an enforceable dynamic-code distinction |
| Native artifact entries and mixed records | `BuildEngine` produces a real native artifact consumed by an application |
| Signing and trust policy | images cross an untrusted transport or deployment requires signer identity |
| Multi-target bundle | one release operation must publish more than one target launcher |

Each increment adds behavior behind `Assembler.assemble`; it does not add a
parallel resolver, build planner, or command surface. Exact implementation
tasks and acceptance tests live in `package-build.md` once the corresponding
demand gate is open.

---

## 23. Resolved design decisions

The previous open questions are resolved as follows.

### 23.1 Physical image format

Use a deterministic indexed Gene image format. A restricted ZIP-like backend
is acceptable for the first writer only if Gene enforces canonical image
semantics.

### 23.2 Memory mapping

Make the v1 layout mmap-compatible. The first implementation may still use ordinary reads.

### 23.3 Source maps in sealed release builds

Omit full source maps by default. Preserve minimal stack-trace metadata unless
the effective `debug_info` level is `none`.

### 23.4 Frozen package graph

Embed the exact frozen package-instance graph from §10 in format 1. Registry,
SemVer, workspace, lockfile, and multiple-version semantics are not deferred or
redefined by the image format; `package.md` owns them. The image stores their
resolved result and never invokes them at load time.

### 23.5 Resource compression

Support per-entry compression with `store` and deterministic `zstd` initially. Record both logical content hashes and encoded blob hashes.

### 23.6 Platform-specific launchers

Emit one launcher per target. Use a separate bundle/index for multi-target distributions.

### 23.7 GIR fallback in mixed mode

Mixed mode always preserves GIR fallback in format 1. Strict native execution
is outside this proposal.

### 23.8 Signing keys and trust roots

Sign canonical image digests. Store signatures in the image. Keep trust roots external and policy-driven.

---

## 24. Summary

Gene distribution should be based on a stable application image model.

```text
.gapp = canonical deployable Gene application image
standalone executable = target launcher + embedded .gapp
multi-target bundle = .gapp + per-target launchers + bundle index
```

This gives Gene a simple path for one-file scripts, complex packages, server
apps, desktop tools, and mixed builds while preserving dynamic Gene semantics.

The default build should be VM/GIR-based and robust. Exact package resolution
precedes every image build; native artifacts, FFI bundling, signing, and
host-managed runtime overlays can be layered on top without changing the core
distribution model.
