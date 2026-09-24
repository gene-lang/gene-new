# Experimental PKG-3 release index and signatures

The release index is one inert Gene Map with `^release_format 1`, `^name`,
`^version`, `^manifest_digest`, `^tree_digest`, and a path-sorted `^files`
List. Every file record has `^path`, `^size`, `^digest`, and `^executable`.
Paths use the package tree's Unicode 15.1 normalization and case-fold
topology rules. Version 1 publication refuses symlinks. The reader limits
index text to 8 MiB, nesting to 16 levels, files to 100,000, paths to 4096
bytes, and each declared object to 1 GiB. Unknown or duplicate fields,
noncanonical paths, and conflicting file/directory topology are errors.

`buildReleaseIndex` captures selected package files without executing build
recipes. `verifyReleaseTree` requires exactly those physical files, checks
their digests, and recomputes the manifest and tree identities. The index
digest is `canonicalDigest(index)`. An Ed25519 signature covers exactly
`"gene-release-v1\0" + canonicalGeneData(index)`. The OpenSSL 3 adapter takes
an explicit absolute library path and raw 32-byte keys; it uses one-shot EVP
signing and verification. `ReleaseTrust` pins the registry public key out of
band and can additionally pin owner keys. An owner-key record carries its
owner, raw key encoded as canonical base64, and a digest key ID; the configured
registry key signs `"gene-owner-key-v1\0" + canonicalGeneData(record)` before
an unpinned owner key may sign a release. Verification returns the selected
signer identity, which the hosted adapter records beside its cached tree as
provenance. A key supplied only by a release response cannot become trusted.
Replacing a registry key needs an explicit trust-configuration change.

The local fixture checks canonical round trips, RFC 8032 vectors, wrong keys
and signatures, owner delegation, tampered and extra files, malformed paths,
and symlink rejection. `RegistryHttpsTransport` makes bounded, explicit HTTPS
GETs through a configured absolute curl 8.4+ executable. It disables curl
configuration and proxies, refuses redirects, verifies TLS with the system
store or an explicit CA file, and enforces a transfer timeout and byte cap.
Metadata GETs return at most 8 MiB in memory. Immutable object GETs write to
a private staging file, enforce the index's declared size (at most 1 GiB),
verify SHA-256, and remove the file on any failure. The local TLS fixture
covers valid objects, digest/size mismatch, truncation, unknown-length
oversize responses, redirects, untrusted servers, and timeout. Registry
releases are addressed by `GET /v1/releases/<index-sha256-hex>/index` and
`/signature`. A release-signature envelope is a bounded inert Gene Map with
`^signature_format 1`, `^signer`, `^key_id`, and a canonical-base64
`^signature`. For an unpinned owner signer, the client additionally reads
`GET /v1/owners/<owner>/keys/<key-sha256-hex>/record` and `/signature`;
the latter is the raw 64-byte registry signature over the owner-key record.
`fetchVerifiedRelease` checks the index digest before using any index field,
then verifies the signer under configured trust and returns signer identity.
`fetchVerifiedTree` downloads only the signed file list into a private
directory, validates every object before placement, then checks the complete
manifest and tree. A failed download removes the entire staging tree; the
caller publishes a successful tree through the existing package-store
transaction.

The local TLS registry fixture covers valid registry and owner signatures,
wrong trust keys, tampered indexes, malformed envelopes, bad delegation, a
complete downloaded tree, and cleanup after a corrupt later object.
Version discovery reads `GET /v1/packages/<owner>/<name>/versions/<page>`.
Each inert Gene page declares `^metadata_format 1`, package `^name`, zero-based
`^page`, `^page_count`, `^listing_digest`, and a `^releases` List of version,
index_digest, and yanked fields. Limits are 512 KiB per page, 64 pages, and
500 entries per page. The client fetches every declared page, rejects
duplicates or changed page commitments, sorts by semantic version, and
checks `listing_digest` against the canonical complete List. This proves
coverage of the registry's committed listing, not that the registry disclosed
every release it owns. Yanked entries remain visible for locked replay.

`newHostedRegistry` supplies the current package manager with verified
manifest candidates and a selected-tree loader. The solver keeps its existing
format-1 identities and lock schema. It downloads complete trees only for
selected versions, checks the signed tree digest before locking, and syncs
through the existing immutable user store. The local fixture resolves and
syncs a hosted dependency, then replays its lock offline with the registry
unavailable. A fresh resolution excludes a yanked release; a preserved locked
edge may continue to use it.

`gene pkg resolve`, `update`, `sync`, `vendor`, `tree`, and `why` accept an
explicit `--registry-config <path>` to an inert Gene Map:

```gene
{^registry_config_format 1
 ^default "test"
 ^registries [{^name "test"
               ^url "https://registry.example"
               ^registry_key "<canonical-base64-32-byte-Ed25519-key>"
               ^curl "/absolute/path/to/curl"
               ^crypto "/absolute/path/to/libcrypto.3"
               ^cache_root "/absolute/private/cache"
               ^ca_file "/absolute/optional/ca.pem"
               ^publish_token_file "/absolute/private/token"}]}
```

The config is local operator input, capped at 64 KiB and 16 registries;
optional `^pinned_owner_keys` maps owner names to canonical-base64 keys. An
optional `^timeout_seconds` selects a 1–300 second transport deadline. It
does not run Gene code or fetch trust material. Online sync caches the signed
index, signature envelope, and any owner delegation beside the verified tree.
With the same config, offline locked sync re-verifies those cached bytes under
the currently configured key before it admits the user-store object. A wrong
key or damaged signature fails without network access. Without an explicit
config, the legacy lock/tree check still works, but it does not claim offline
signature verification. `pkg vendor` carries the signed release bytes in a
separate `.signatures` area; offline sync re-verifies them even after the
hosted cache and user store are removed. These signature records stay outside
the immutable source-tree digest. CLI `build`, project `run`, `test`, and
`install` also accept `--registry-config` and use the same package-manager
trust path. The local fixture builds and installs a locked hosted-dependent
application,
then launches it from an unrelated directory with source and compiler
unavailable.

`gene pkg publish --registry-config <path> --signing-key <raw-32-byte-file>`
signs the local package as its owner by default. `--signer registry` and
`--registry <name>` select an explicitly configured alternative. The client
verifies its signing key against the pinned owner key or a registry-signed
owner delegation before uploading. A token read from `^publish_token_file`
authorizes the owner namespace; the token reaches curl through stdin, not
process arguments. The client PUTs exact file objects, the index, and the
signature under `/v1/staging/<owner>/<name>/<version>/`, then POSTs the
index digest to `/v1/publish/<owner>/<name>/<version>`. It rechecks the local
source before commit and verifies the published index afterward. The local
TLS fixture models atomic version selection: the same digest is idempotent,
while a different digest for that version returns a conflict. A deployable
hosted registry service and Linux runtime qualification remain open.
