# Gene Distribution Design

**Status:** draft design, decisions incorporated, pre-implementation  
**Scope:** packaging and executable distribution for simple and complex Gene applications  
**Revision date:** 2026-06-28

---

## 1. Goal

Gene should support easy distribution of applications without requiring users to install a separate Gene runtime manually.

The core design is:

```text
GIR application image = canonical deployable program representation
Standalone executable = target launcher + embedded application image
```

A Gene application does **not** need to be fully native-compiled to become a standalone executable. The default distribution path should embed the Gene runtime/VM plus a precompiled application image containing GIR bytecode, module metadata, resources, and optional native components.

Native compilation remains an optimization layer, not a prerequisite for distribution.

The durable artifact is the application image. The executable is a target-specific delivery wrapper around that image.

---

## 2. Terms

### Application

A running Gene program. At startup, Gene creates an `Application`, loads the entry package/module, executes the entry module top to bottom, then calls `main` with command-line arguments if `main` exists.

### Package

A collection of modules, resources, metadata, and optional native dependencies. Full package dependency resolution can evolve later, but a package is the natural unit for complex builds.

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

```bash
gene pack . -o app.gapp
gene run app.gapp
```

A `.gapp` contains the compiled Gene application but not the runtime executable. It can run on any compatible Gene runtime that supports the image format, GIR ABI, value ABI, and required features.

Use this for:

- development builds;
- plugin distribution;
- testing;
- server environments where Gene is already installed;
- cross-platform package distribution when target-specific native dependencies are absent.

### 3.2 Standalone VM executable

```bash
gene build . -o app
```

This embeds:

```text
target-native launcher
Gene runtime / VM
application image
```

This should be the default end-user distribution mode. It supports dynamic Gene features while requiring no separate Gene installation.

### 3.3 Mixed native executable

```bash
gene build . --mode mixed -o app
```

This embeds:

```text
Gene runtime / VM
GIR fallback modules
native-compiled typed functions/modules where available
application image metadata
```

Typed-to-typed calls may use direct native calls. Dynamic, reflective, untyped, or unsupported functions remain GIR/VM code. Mixed mode preserves the same source semantics as VM mode and must preserve GIR fallback by default.

A future fully native mode may exist, but it should be optional and stricter.

### 3.4 Multi-target distribution bundle

```bash
gene bundle . \
  --targets aarch64-apple-darwin,x86_64-unknown-linux-gnu,x86_64-pc-windows-msvc \
  -o app.gbundle
```

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

The semantic format is **Gene-specific**. It should not be defined as arbitrary ZIP, arbitrary tar, or arbitrary Gene source syntax. A Phase 1 implementation may use a restricted ZIP-like container for convenience, but the reader and writer must enforce Gene image semantics.

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

### 4.1 Restricted ZIP-like Phase 1 option

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
(AppImage
  ^format-version 1
  ^compiler-version "0.1.0"
  ^value-abi 1
  ^gir-abi 1
  ^requires (Runtime
    ^min-format-version 1
    ^min-value-abi 1
    ^min-gir-abi 1
    ^features [vm streams modules])
  ^entry-package "app"
  ^entry-module "/main"
  ^mode vm
  ^profile sealed
  ^debug-info min
  ^portable true
  ^targets []
  ^module-graph-hash "sha256:..."
  ^lock-hash nil
  ^modules {...}
  ^resources {...}
  ^dependencies [...]
  ^native {...}
  ^signatures {...})
```

The manifest should include:

- image format version;
- compiler version;
- runtime/value ABI version;
- GIR ABI version;
- compatibility requirements and required runtime features;
- entry package;
- entry module;
- build mode: `vm`, `mixed`, or future `native`;
- image profile: `sealed`, `open`, `debug`, `release`, `portable`, or `targeted` as applicable;
- debug-info level: `full`, `min`, or `none`;
- target triples when target-specific content exists;
- module table;
- resource table;
- dependency metadata table;
- native dependency table;
- content hashes for all included content;
- image digest metadata;
- optional signature metadata.

Use `^targets` rather than a single top-level `^target` for images that may contain multiple target-specific native artifacts. A singular target field is acceptable only for a fully target-specific image or executable metadata wrapper.

---

## 6. Module table

Each module entry should contain:

```gene
(ModuleEntry
  ^id "/app/main"
  ^package "app"
  ^logical-path "/main"
  ^source-kind gene
  ^source-hash "sha256:..."
  ^gir-hash "sha256:..."
  ^gir-blob "modules/app/main.gir"
  ^imports [...]
  ^exports [...]
  ^debug-source? nil
  ^sourcemap? nil
  ^native? [...])
```

Rules:

- Module identity uses normalized logical package/module paths, not build-machine absolute paths.
- Modules remain separate inside the image.
- Import/load-once semantics are preserved.
- Namespace identity is derived from package plus module logical path.
- Source text may be included in debug builds and omitted in release builds.
- Full source maps are omitted by default from sealed release builds.
- Minimal stack-trace metadata is preserved by default unless `--debug-info=none` is requested.
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

The executable startup model should match `gene run` as closely as possible. The difference is where modules and resources are loaded from.

---

## 8. Simple application build

For a single source file:

```bash
gene build hello.gene -o hello
```

The builder creates an ad hoc package:

```text
package: <adhoc>
entry module: hello.gene
resources: none unless specified
native dependencies: none unless specified
```

The builder then:

```text
read source
parse
compile to GIR
create minimal app image
embed app image in launcher
write executable
verify executable and embedded image
```

A `package.gene` file is not required for single-file applications.

---

## 9. Complex package build

For a package directory:

```bash
gene build . --release -o my-app
```

The builder should:

```text
read package.gene
resolve entry package/module
resolve imports
build module graph
reject import cycles unless a future cycle-safe mode is defined
compile each module to GIR
collect resources
collect approved native dependencies
write resolver-neutral dependency metadata
write manifest and content index
write application image
embed image in launcher when building an executable
verify resulting artifact
```

Package dependency resolution, registry support, semver, hosted packages, and lockfile policy can evolve separately. The image format should already have stable fields for dependency hashes, package identity, module graph hashes, and lock metadata.

---

## 10. Dependency metadata

The image should include minimal dependency metadata before the full dependency resolver exists. This metadata should be resolver-neutral and content-addressed.

Example conceptual form:

```gene
(Dependency
  ^id "pkg:example"
  ^name "example"
  ^version nil
  ^source nil
  ^resolved nil
  ^content-hash "sha256:..."
  ^module-graph-hash "sha256:..."
  ^modules [...])
```

Include now:

```text
- declared package identity;
- package name when known;
- optional version string when known;
- content hashes;
- module graph hashes;
- target-specific native dependency records;
- capability declarations;
- optional provenance/signature fields;
- optional lockfile hash when a lockfile exists.
```

Defer until package management is designed:

```text
- registry URL semantics;
- semver interpretation;
- lockfile schema details;
- hosted package trust model;
- dependency override policy;
- workspace policy;
- transitive dependency conflict resolution.
```

This gives Gene reproducibility hooks without freezing the package manager too early.

---

## 11. Open and sealed builds

Gene should support two important build profiles.

### 11.1 Sealed application

```bash
gene build . --sealed -o app
```

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

```bash
gene build . --open -o app
```

An open app may include:

- reader;
- compiler;
- dynamic `eval`;
- plugin loading;
- dynamic module search paths;
- runtime-generated code;
- optional FFI/native loading authority.

Open apps are larger and require stricter capability control, but they are suitable for REPLs, plugin hosts, development tools, and self-evolving systems.

### 11.3 Debug information profiles

Gene should support explicit debug-info levels:

```bash
gene build . --release --sealed --debug-info=min
gene build . --release --sealed --debug-info=none
gene build . --release --sealed --debug-info=full
```

Recommended defaults:

```text
development build       -> full
release sealed build    -> min
release open build      -> min
hardened release build  -> none, only when explicitly requested
```

The `min` profile should retain enough metadata for useful diagnostics:

```text
- module id;
- function/binding name;
- bytecode offset to compact span id;
- optional source file name without source text;
- symbol table data needed for stack traces.
```

The `full` profile may include source maps and optional source snippets. The `none` profile strips everything not required by the VM.

Default recommendation:

```text
simple CLI/server app -> sealed
REPL/plugin/self-evolving app -> open
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
(fn main [args, ^config : Fs/ReadDir, ^logs : Fs/WriteDir]
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
(ResourceEntry
  ^path "/assets/app.css"
  ^content-type "text/css"
  ^encoding zstd
  ^encoding-level 6
  ^content-hash "sha256:..."      ; hash of uncompressed logical bytes
  ^blob-hash "sha256:..."         ; hash of stored encoded bytes
  ^uncompressed-size 48291
  ^stored-size 9172
  ^blob-offset 1048576)
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

## 14. Native dependencies and FFI

Native dependencies are target-specific.

The image may contain:

```text
native/aarch64-apple-darwin/libfoo.dylib
native/x86_64-unknown-linux-gnu/libfoo.so
native/x86_64-pc-windows-msvc/foo.dll
```

Rules:

- Prefer static linking into the launcher when practical.
- Otherwise include dynamic libraries per target triple.
- Hash native artifacts in the manifest.
- Verify hashes before loading.
- When the OS cannot load from memory, extract libraries into a content-addressed cache before loading.
- Arbitrary dynamic loading requires an explicit `Ffi/Load` capability.
- Raw pointer/unsafe FFI APIs may require `Ffi/Unsafe`.
- Native artifacts should not change the logical identity of portable GIR modules.

A standalone executable is target-specific even if its GIR modules are portable.

---

## 15. Native compilation inside distribution

Native compilation should be optional.

Modes:

```text
vm       GIR only; VM executes all Gene code
mixed    GIR fallback plus native code for eligible typed functions/modules
native   future stricter mode; all reachable code must be native-compatible
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
- overlays and self-evolving applications;
- typed/untyped boundary behavior.
```

Stripping GIR fallback belongs to a future strict native mode or explicit expert profile, for example:

```bash
gene build . --mode native --no-gir-fallback
```

A `mixed` build should not silently remove GIR fallback.

---

## 16. Cross-compilation and platform-specific launchers

Launchers are target-specific artifacts. A single standalone executable should target one OS/architecture/runtime environment.

Recommended commands:

```bash
# Build one target-specific executable
gene build . --target x86_64-unknown-linux-gnu -o app-linux

# Build portable image only
gene pack . -o app.gapp

# Build multiple target-specific executables
gene build . \
  --target aarch64-apple-darwin \
  --target x86_64-unknown-linux-gnu \
  --out-dir dist/

# Build a multi-target distribution bundle
gene bundle . \
  --targets aarch64-apple-darwin,x86_64-unknown-linux-gnu \
  -o app.gbundle
```

A target record should use conventional target triples:

```gene
(Target
  ^triple "x86_64-unknown-linux-gnu"
  ^launcher-abi 1
  ^native [...]
  ^runtime-features [...])
```

Rules:

- One standalone executable is emitted per target.
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
- optional dependency lock hash;
- canonical image digest;
- optional signature block.

`gene verify` should check:

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
(SignatureBlock
  ^image-digest "sha256:..."
  ^signatures [
    (Signature
      ^scheme cose-sign1
      ^key-id "..."
      ^cert-chain [...]
      ^transparency-entry nil
      ^timestamp "..."
      ^signature-bytes #"...")])
```

Trust roots should not be hard-coded into the image. They should come from one or more external policies:

```text
- local developer keyring;
- enterprise trust policy;
- OS trust store, where appropriate;
- Gene registry trust metadata;
- explicit command-line trust configuration;
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

Commands:

```bash
gene inspect app.gapp
gene verify app.gapp
gene inspect ./app
gene verify ./app
gene sign app.gapp --key developer.key
gene verify app.gapp --trust-policy policy.gene
```

---

## 19. Self-evolving applications

The embedded base image is immutable.

Generated or replacement code should live in external overlays:

```text
base application image        immutable
runtime eval overlay          temporary / GC-managed
activated module versions     persistent external version store
application data              external writable state
```

Do **not** rewrite the running executable. Rewriting the executable conflicts with:

- code signing;
- OS loader behavior;
- rollback;
- file locks;
- security review;
- deterministic deployment.

Future self-evolution should use explicit operations:

```text
generate candidate
-> eval/test in isolated Env
-> compile module artifact
-> activate versioned overlay
-> rollback if needed
```

The distribution design should preserve stable base-image identity while allowing runtime overlays.

---

## 20. CLI design

Recommended commands:

```bash
# Run source, image, or executable-like image
gene run app.gene
gene run app.gapp

# Build standalone executable
gene build hello.gene -o hello
gene build . -o app
gene build . --release -o app
gene build . --target aarch64-apple-darwin -o app
gene build . --mode vm -o app
gene build . --mode mixed -o app
gene build . --sealed -o app
gene build . --open -o app
gene build . --release --sealed --debug-info=min -o app
gene build . --release --sealed --debug-info=none -o app

# Create portable app image only
gene pack . -o app.gapp
gene pack hello.gene -o hello.gapp

# Build multi-target releases
gene build . \
  --target aarch64-apple-darwin \
  --target x86_64-unknown-linux-gnu \
  --out-dir dist/
gene bundle . \
  --targets aarch64-apple-darwin,x86_64-unknown-linux-gnu \
  -o app.gbundle

# Inspect/verify artifacts
gene inspect app.gapp
gene verify app.gapp
gene inspect app
gene verify app

# Signing
gene sign app.gapp --key developer.key
gene verify app.gapp --trust-policy policy.gene
```

Potential later commands:

```bash
gene extract app.gapp ./out
gene list-modules app.gapp
gene list-resources app.gapp
gene list-targets app.gapp
gene list-signatures app.gapp
gene verify-bundle app.gbundle
```

---

## 21. Build pipeline

Conceptual build pipeline:

```text
input source/package
-> resolve package context
-> resolve imports
-> build module graph
-> read + parse modules
-> macro/template expansion
-> type/protocol/impl checks
-> compile modules to GIR
-> optionally native-compile typed functions/modules
-> collect resources
-> choose per-resource compression
-> collect native dependencies
-> write resolver-neutral dependency metadata
-> write canonical manifest
-> write canonical content index
-> write deterministic application image
-> optionally sign image digest
-> optionally embed image into target launcher
-> verify resulting artifact
```

Builds should fail if:

- imports cannot be resolved;
- cycles are detected in MVP;
- selected exported bindings are missing;
- module graph is target-incompatible;
- required native artifacts are unavailable for the target;
- sealed build encounters forbidden dynamic behavior;
- runtime ABI/GIR ABI mismatch is detected;
- image canonicalization fails;
- hash verification fails after writing;
- requested signing policy cannot be satisfied.

---

## 22. Implementation phases

### Phase 1: Deterministic GIR application image

- Define `.gapp` header, manifest, content index, and footer.
- Use a deterministic indexed image writer.
- A restricted ZIP-like backend is acceptable if it obeys Gene image rules.
- Store GIR modules and resources.
- Support `store` and deterministic `zstd` resource encodings.
- Record content hashes and encoded blob hashes.
- Implement `gene pack`.
- Implement `gene run app.gapp`.
- Implement `gene inspect` and basic `gene verify`.
- Preserve an mmap-compatible layout even if mmap is not implemented yet.

### Phase 2: Standalone VM executable

- Build target-native launcher.
- Append/embed image.
- Read image footer at startup.
- Support subrange image reader.
- Mount image as read-only module/resource store.
- Support `gene build . -o app`.
- Verify embedded image before startup.

### Phase 3: Sealed/open profiles and debug-info profiles

- Implement sealed build checks.
- Implement open build support.
- Optionally omit reader/compiler from sealed launchers.
- Include reader/compiler in open launchers.
- Add capability metadata.
- Implement `--debug-info=full|min|none`.
- Default sealed release builds to `--debug-info=min` and omit full source maps.

### Phase 4: Native dependencies

- Include target-specific native libraries.
- Extract/load dynamic libs safely when memory loading is not supported.
- Verify native artifact hashes.
- Integrate with `Ffi/Load` capability.
- Add target table support.

### Phase 5: Mixed native mode

- Add native-compiled typed function artifacts.
- Keep GIR fallback by default.
- Generate dynamic/typed adapters.
- Preserve uniform stack traces and error behavior.
- Reject stripping GIR fallback in mixed mode unless a future explicit expert policy is introduced.

### Phase 6: Signing, trust policy, and reproducibility

- Implement deterministic image digest.
- Implement signature block.
- Keep trust roots external to the image.
- Add local developer key signing.
- Add trust-policy verification.
- Integrate lockfile/dependency hash metadata when package resolution exists.
- Add optional provenance/transparency metadata later.

### Phase 7: Multi-target bundles

- Implement `gene bundle`.
- Represent one `.gapp` plus per-target launchers.
- Add bundle index.
- Verify all launchers and the shared image.
- Support target listing and bundle inspection.

---

## 23. Resolved design decisions

The previous open questions are resolved as follows.

### 23.1 Physical image format

Use a deterministic indexed Gene image format. A restricted ZIP-like backend is acceptable for the MVP only if Gene enforces canonical image semantics.

### 23.2 Memory mapping

Make the v1 layout mmap-compatible. The first implementation may still use ordinary reads.

### 23.3 Source maps in sealed release builds

Omit full source maps by default. Preserve minimal stack-trace metadata unless `--debug-info=none` is requested.

### 23.4 Early dependency metadata

Include resolver-neutral, content-addressed dependency metadata now. Defer registry, semver, lockfile, and override policy.

### 23.5 Resource compression

Support per-entry compression with `store` and deterministic `zstd` initially. Record both logical content hashes and encoded blob hashes.

### 23.6 Platform-specific launchers

Emit one launcher per target. Use a separate bundle/index for multi-target distributions.

### 23.7 GIR fallback in mixed mode

Mixed mode preserves GIR fallback by default. Stripping fallback belongs to future strict native or expert profiles.

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

This gives Gene a simple path for one-file scripts, complex packages, server apps, desktop tools, and future native/mixed builds while preserving dynamic Gene semantics.

The default build should be VM/GIR-based and robust. Native compilation, FFI bundling, signing, dependency resolution, and self-evolving overlays can be layered on top without changing the core distribution model.
