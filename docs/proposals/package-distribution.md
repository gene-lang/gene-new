# Package Publication and Application Distribution

**Status:** Proposed design; format-1 workspaces, locking, immutable source stores, and pure-Gene builds are implemented.  
**Purpose:** Make a Gene library or application installable and runnable outside its source checkout, including declared resources and native dependencies.  
**Relationship:** This extends the current package/build graph. It does not replace the loader or the separate [code-persistence proposal](code-persistence.md).

## Package identity and manifest evolution

Keep `<owner>/<name>@version` plus origin/content digest as the package identity. A released version is immutable. Retain format-1 manifests unchanged; introduce `^format 2` only for new resource/native distribution fields. Unknown fields continue to fail. The manifest stays one data value, never executable code. `^resources` lists package-relative immutable files; `^native` lists target-specific binary inputs or a declarative native build recipe with exact source/dependency inputs. A recipe cannot run arbitrary Gene as part of dependency resolution. Build execution is a separate explicit step.

A minimal format-2 package with one platform binary uses existing Gene data syntax:

```gene
{^format 2
 ^name "acme/report"
 ^version "1.0.0"
 ^applications [(application "report" ^entry "src/main.gene")]
 ^resources ["data/schema.json"]
 ^native [(native ^name "codec"
                  ^target "aarch64-apple-darwin"
                  ^file "lib/libcodec.dylib"
                  ^sha256 "<64 lowercase hex digits>")]}
```

The `native` data node and fields are proposed manifest schema, not executable declarations. A target mismatch rejects the package before application startup. The first recipe kind is `c`: source files, include files, declared system libraries, compiler family/version constraint, and literal argument lists. Shell scripts and environment-dependent discovery are outside this first reproducible recipe; a package may instead publish a prebuilt target binary with its digest.

Package-relative resource reads use the pinned package revision, not `this_mod`'s physical source path. Provide `$pkg/read_bytes` and `$pkg/read_text` with a logical resource path and optional package reference. Mutable configuration, logs, and user files are outside this API. A native library that needs a file path uses explicit verified materialization into a private content-addressed cache, matching §11.3 of [code persistence](code-persistence.md).

## Hosted publication and trust

Add `gene pkg publish` for a complete source release. The client validates the manifest, lock-relevant dependencies, resources, license/provenance metadata, and digest before upload. The hosted registry authenticates the publisher's right to the `<owner>` namespace; it rejects a second payload for an existing owner/name/version. Index metadata points to immutable digests, and `pkg resolve` records the selected origin and digest in the lock as it does for other sources. `pkg sync` verifies every fetched payload before it enters the immutable store. Offline and vendor modes consume verified locked objects without contacting the registry.

Hosted release manifests are signed with an owner-controlled Ed25519 public key. The signature covers a versioned release index containing the canonical manifest digest and sorted source/resource/native-artifact path-and-digest pairs. Canonicalization uses a specified UTF-8 encoding and ordering, not the incidental printer output of a Gene map; the published index bytes themselves are immutable and hashed. The registry publishes a versioned owner-key record; applications may pin trusted keys, and key rotation requires signatures by the old and new keys rather than silently accepting a new signer for a locked release. HTTPS protects transport, while digest/signature verification protects the cached object independently of transport. Registry authorization and signing are separate checks.

The first index encoding is byte-defined: ASCII `GENE-RELEASE-1` plus newline; the package identity as decimal UTF-8 byte length, colon, bytes, and newline; one 64-character lowercase manifest SHA-256 plus newline; a decimal entry count plus newline; then entries sorted by normalized relative path's UTF-8 bytes. Each entry is a decimal byte length, colon, path bytes, one space, a 64-character lowercase SHA-256, and newline. Path normalization rejects absolute paths, `..`, empty components, and duplicate normalized paths. The signer signs exactly these bytes; the verifier hashes and checks exactly these bytes before reading objects. A future encoding gets a new header rather than changing the meaning of version 1.

## Build, install, and run

`gene build` continues to derive artifacts from source, lock, compiler identity, target, profile, and dependencies. Extend the derivation with native recipe inputs, toolchain identity, resources, and platform triple. A binary artifact is never reused for a mismatching target/ABI. Installable applications contain an entrypoint/launcher, compatible Gene runtime or declared runtime requirement, locked package closure, resources, and needed native libraries. `gene install <package-or-local-target> --prefix <dir>` writes an immutable installation generation and atomically switches its launcher only after all content validates. A failed install leaves the previous generation runnable. `gene uninstall` removes only that generation's owned files; user data remains separate.

An installed app resolves imports/resources from its pinned closure, not the current working directory or mutable global cache. It reports its release ID and Gene runtime version. A service install uses the same artifact; service-manager integration is a deployment layer, not a different package format.

## Implementation sequence

1. Implement format-2 resources and package-relative reads for local/path/git sources. Build and run the installable CLI fixture with the source directory unavailable.
2. Add native artifact metadata, target/ABI validation, and one extension package from [native extensions](native-extensions.md). Test wrong-platform rejection before code runs.
3. Add hosted immutable publication, digest verification, owner authorization, signing/key pinning, and offline/vendor round trips. Do not enable a hosted source in the supported profile before integrity checks work.
4. Add atomic install/update/uninstall and clean-machine fixture jobs on each supported platform.

**Acceptance:** a developer can publish a library, lock and sync it, build an app with a resource and native extension, install it to a separate prefix, run it without the checkout or registry, and update it without leaving a half-installed application.
