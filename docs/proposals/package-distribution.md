# Package Publication and Application Distribution

**Status:** Implementation proposal; source baseline `3b2bde9`.

**Stages:** PKG-1 (resources/offline install), PKG-2 (native recipes), PKG-3 (hosted publication).

**Depends on:** Current package/build system. PKG-1/2 do not require retained native callbacks or a hosted registry.

## Reuse the existing model

`package.nim` already has format-1 `files`, `build`, target `uses`, `system_dependencies`, source-tree capture, canonicalGeneData/canonicalDigest, registry adapters, locks, and vendor stores. `build.nim` explicitly rejects unavailable target recipes. Implement that reserved recipe path. Do not add format 2, parallel resources/native top-level fields, a second solver, or a new signature serialization.

Keep current package/source identities, tree digests, and lock semantics unchanged. Publication provenance and build-artifact digests are separate records. Extend closed schemas with versioned recipe nodes and structured unsupported-recipe errors; old runtimes already reject recipe-dependent targets. Selecting a package for the wrong runtime must produce an early compatibility error.

## PKG-1: resources and local distribution

Add a data-only `resources` recipe in the existing build List:

```gene
{^format 1
 ^name "acme/report"
 ^version "1.0.0"
 ^applications [(application "report"
                   ^entry "src/main.gene"
                   ^uses ["assets"])]
 ^files {^include ["package.gene" "src/**" "data/**"]}
 ^build [(resources "assets" ^files ["data/schema.json"])]}
```

This is a proposed recipe inside current manifest syntax. Its positional name is unique among recipes. files is a List of exact package-relative regular-file paths selected by the existing files policy; no new glob or destination-remapping language in v1. Reject missing files, symlink escape, duplicate normalized paths, case/Unicode collisions under the existing tree rules, and executable resources. Only selected target recipes are built.

Record resource path, size, digest, and owning package identity in the build artifact. Reads resolve from that pinned package/release, consistent with [code persistence §11.3](code-persistence.md#113-package-relative-resources):

| API | Contract |
| --- | --- |
| `($pkg/read_bytes package path ^max_bytes 16777216)` | Read a declared logical resource from the supplied Package, with a byte limit; no cwd lookup. |
| `($pkg/read_text package path ^max_bytes 16777216)` | Same, strict UTF-8. |
| `($pkg/dependency this_pkg "alias")` | Return the selected Package for a declared direct dependency; never resolve/fetch. |
| `($pkg/materialize package path)` | Verified private cache lease with a physical path and idempotent direct close; pinned lease prevents eviction. |

The Package argument is explicit, normally this_pkg, so a helper cannot accidentally read resources from its own package when the caller intended another. Missing/corrupt resources raise PackageResourceError. Mutable configuration and user output remain ordinary filesystem data. Resource reading does not require the SQLite code-store proposal to be implemented; both later share the same provider seam.

## Install transaction

Add `gene install <local-application-target> --prefix <directory>` first, then package coordinates after PKG-3. Reuse locked build/sync selection; installation never resolves newer dependencies implicitly. The default native-app installation bundles the exact Gene executable/runtime identity, the locked source/compiled closure, diagnostics source, resources, native artifacts, and an install manifest. Record dynamic system-library requirements and validate them before activation; bundling the Gene executable alone is not a static-binary claim.

On POSIX targets, write a staging generation under the same prefix filesystem, validate and synchronize its files/manifest, rename it into a content-addressed generation directory, then atomically replace that application's current pointer. A generated launcher reads the pointer once and execs that generation using an explicit package root; it never changes the user's working directory. Launcher name collisions with another owner are errors. Each invocation holds a generation lease; cleanup cannot delete a running generation.

Update failure before pointer selection leaves the old app runnable; after selection the complete new generation is runnable. Temporary/orphan generations are recoverable by manifest. `gene uninstall` removes only owned launchers/pointers and inactive generations, never application data. Windows install transactions need a separately qualified launcher/pointer implementation; initial qualification is Linux x86_64 and macOS arm64.

## PKG-2: native recipes and platform artifacts

Use ordinary data nodes under build, referenced by target uses:

| Recipe | Closed v1 schema |
| --- | --- |
| `(c_library "name" ...)` | sources: nonempty List of selected .c files; include_dirs: relative directory List; system: declared system-dependency aliases; cflags/ldflags: literal argument Lists; linkage: shared or static; targets: target-triple List. |
| `(native_binary "name" ...)` | variants: List of artifact records with target, file, digest, ABI kind/version, and declared system aliases. Exactly one compatible variant per selected target. |

No shell-string recipe execution. Invoke the configured C compiler with argument arrays in a private build directory. Resolve pkg_config/vcpkg/framework/policy_mapping requirements through the existing `system_dependency.nim` interfaces at build time, not runtime import. Capture provider/version, headers/libraries/toolchain identity and relevant digests in derivation evidence. If host SDK inputs cannot be fully pinned, label the build as environment-dependent and disable cross-host artifact reuse.

Distinguish ordinary C ABI libraries, GeneApi v4/v5 extensions, and Gene-generated FFI/AOT artifacts. A matching CPU triple alone is insufficient for the latter: record runtime/compiler ABI and required runtime identity. Never load a binary selected solely by file suffix. Stage declared shared libraries and runtime search paths without relying on the developer's cwd. Do not redistribute a system library unless its redistribution policy/notices are included; external prerequisites are recorded explicitly.

First integrate an existing local genex library with a synchronous/native boundary, such as websocket, to prove packaging independently of NATIVE-2. The later retained-notification package uses the same artifact route.

## PKG-3: hosted publication and signatures

Extend the current registry adapter with a bounded HTTPS transport. Registry metadata uses inert Gene data parsed with limits, never eval. Select versions through existing resolution; sync retrieves immutable objects and verifies size/tree/content digests before admission. Library publications retain dependency constraints from their manifest; an application installation separately pins its complete resolved lock.

The release index is a map with release_format=1, name, version, manifest_digest, tree_digest, and a path-sorted file List containing path, size, digest, and executable. Paths and permission normalization use current package tree code. Its digest uses canonicalDigest. An Ed25519 signature covers the domain-separated bytes `"gene-release-v1\0" + canonicalGeneData(index)`; signatures and keys are separate from the signed index. Use a maintained crypto library through a declared adapter, not handwritten cryptography.

Trust bootstrap is explicit: registry configuration pins its trust key or an owner's key out of band. A downloaded owner-key record signed by the configured registry key may delegate that owner; merely receiving a key over the same response is insufficient. Record verified signer identity with the cached release. Rotation requires the configured trust path or explicit operator key replacement; loss of an old key must not silently approve a replacement. Cached offline verification makes no claim about revocations published while offline.

Minimum endpoint contract:

- GET package version metadata with bounded pagination and explicit coverage.
- GET immutable release index and signature by digest.
- GET immutable object by digest and declared size; reject truncated/mismatched content.
- Authenticated upload into staging, then publish owner/name/version atomically. Repeating the same digest is idempotent; a different digest for that version is a conflict.

Registry authentication checks who can publish an owner namespace; signatures authenticate the released bytes. Yanked releases are excluded from new resolution but remain retrievable for existing locks unless explicitly revoked by configured policy. publish/sync do not execute package build recipes. Local/path/git and vendor workflows continue to work without the hosted service.

## Work map and acceptance

| Stage | Primary code/tests | Required evidence |
| --- | --- | --- |
| PKG-1 | package.nim, build.nim, CLI install, resource loader; test_package/test_build/CLI | Example recipe validates; checkout removed; offline installed CLI reads resource; forced exit before/after current-pointer switch preserves a runnable generation. |
| PKG-2 | system_dependency.nim, recipe executor, native loader | Target/ABI mismatch before loading, changed toolchain invalidates artifact, missing library diagnostic, clean install of real genex binding. |
| PKG-3 | Registry adapter/CLI and local HTTP registry fixture | Conflict/idempotent publish, bad signature/digest/key rotation, partial download, limits, offline cache/vendor replay, no import-time fetch/build. |

Reuse the existing canonical byte fixtures and source-tree collision tests. Hosted publication is a later delivery capability; it must not delay proving PKG-1's local/offline application installation.
