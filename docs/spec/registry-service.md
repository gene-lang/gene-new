# Persistent signed registry service

**Status:** experimental PKG-3 service, exercised on macOS arm64. Linux is
deferred. This is a single-writer deployment for one private POSIX filesystem;
it does not claim clustered operation or sustained-service qualification.

`gene-registry` is a separate executable. It reuses the existing inert Gene
metadata, canonical release digests, Ed25519 adapter, complete-tree validator,
and PKG-3 endpoints. It does not evaluate uploaded code or execute build recipes.
No online private signing key is required.

## Build and provision

```sh
nim c -d:release --path:src -o:bin/gene-registry src/gene_registry.nim
bin/gene-registry keygen --crypto /absolute/libcrypto.3 --out /private/registry-keys
bin/gene-registry keygen --crypto /absolute/libcrypto.3 --out /private/acme-keys
bin/gene-registry delegate --crypto /absolute/libcrypto.3 --registry-key /private/registry-keys/private.seed --owner acme --owner-key /private/acme-keys/public.key --out /private/acme-delegation
```

The keygen output directory must be new and absolute. It contains raw 32-byte
`private.seed` and `public.key`, `public-key.base64`, and a random bearer token
in `publish.token`. The directory is mode 0700 and files are mode 0600.
Delegation writes the existing `owner-record.gene` and raw 64-byte
`owner-record.sig` contract. Provision delegations offline; the running service
needs only public keys, delegation records/signatures, and owner token files.
Keep signing seeds with their signing operators, outside the service deployment.

## Service config

Supply one inert Map, at most 64 KiB, with duplicate/unknown fields refused:

```gene
{^registry_service_format 1
 ^root "/private/gene-registry"
 ^port 8080
 ^registry_key "<registry public-key.base64 contents>"
 ^crypto "/absolute/libcrypto.3"
 ^publishers [{^owner "acme"
               ^public_keys ["<acme public-key.base64 contents>"]
               ^token_file "/private/acme-keys/publish.token"}]
 ^delegations [{^record_file "/private/acme-delegation/owner-record.gene"
                ^signature_file "/private/acme-delegation/owner-record.sig"}]}
```

`root` and all key/token/adapter paths are absolute. The service makes its root
private and rejects internal symlinks and special files. Publisher tokens
must have 16–4096 bearer characters and private file permissions. Authentication
is checked for the requested owner before the body is read. Up to 128 owners
may each retain 1–16 public keys, allowing explicit owner rotation while keeping
old release keys. Delegation signatures are verified against the pinned registry
key at startup; merely configuring a record does not authorize publication.
The publisher's key list and token grant publication authority.

Optional limits:

| Field | Default | Accepted range |
| --- | ---: | --- |
| port | 8080 | 0–65535; 0 chooses a free local port |
| request_timeout_ms | 30000 | 100–300000 |
| max_object_bytes | 64 MiB | 1 byte–1 GiB |
| max_release_bytes | 1 GiB | 1 byte–16 GiB |
| max_storage_bytes | 10 GiB | 1 byte–1 TiB |
| max_stages | 128 | 1–4096 |
| stage_ttl_seconds | 86400 | 60–604800 |

The storage budget counts logical file bytes with a 4 KiB floor per file and
directory, including staging and temporary files. Commit reserves space for
validation copies and publication; it is not a filesystem free-space oracle.
An exhausted budget refuses writes with 507. Object, signature, index, release,
and version-page limits also apply independently. Expired staging is pruned at
startup and upload admission. Published data is never removed by staging cleanup.

## Run behind HTTPS

```sh
bin/gene-registry --config /absolute/registry-service.gene
```

The listener binds only `127.0.0.1`. Terminate it with SIGTERM/SIGINT to finish
the current bounded request, close the listener, and release its writer lock.
An unclean exit is recovered at the next start: stale process locks are reclaimed,
temporary request/tree/release directories are removed, and incomplete staging
can still be retried. A second live writer for the same root is refused.

Use the existing Caddy HTTPS-to-loopback route:

```caddyfile
registry.example {
    request_body {
        max_size 67108864
    }
    reverse_proxy 127.0.0.1:8080
}
```

Deploy the binary, explicit OpenSSL 3 adapter, config, public delegation files,
private owner tokens, and persistent root under an operator-owned account. Run
the registry and TLS proxy with the host's process supervisor. Align the proxy
body cap and timeouts with the service limits. This serial server deliberately
admits one active connection at a time, with a listen backlog of 32; long uploads
delay other requests. Large metadata/objects stream through 64 KiB buffers.
The request/response I/O deadline, 16 KiB header cap, bounded Content-Length,
duplicate-header refusal, and rejection of transfer encoding bound admission.
TLS, remote connection admission, and external rate limits belong to the proxy.

The existing client config in [package-release.md](package-release.md) uses the
HTTPS URL and pinned registry key. It may pin an owner key directly or retrieve
the registry-signed delegation. Its `publish_token_file` points to that owner's
token; `pkg publish --signing-key` uses the owner's raw seed. Publish, resolve,
sync, vendor, and installation need no new CLI or manifest syntax.

## Publication and recovery

PUTs stage exact objects by SHA-256, a canonical index, and a verified signature.
A signature cannot poison an unpublished stage: admission verifies its key,
signature, index address, and publication coordinate before saving it. Staging alone is never served. An admitted immutable
release may remain
addressable after an interrupted version selection; version pages expose only
selected versions.

POST publication verifies every indexed object and reconstructs the complete
tree with its executable bits, then recomputes the manifest and tree identities.
Only that admitted tree's objects enter the immutable object store. Files,
release-directory publication, and parents are synchronized before an atomic,
synchronized version-record rename selects the release. A crash can leave
unreferenced immutable objects or an admitted release directory; it cannot
select a partially admitted version. Those orphans are retained, counted against
the quota, and recoverable by an operator; automatic published-object GC is
outside this version.

Same version/digest replay is idempotent, preserves its yank state, and cleans
reuploaded staging. Another digest for a selected version returns 409. Version
pages use the existing complete-list commitment, semantic-version ordering,
500-row pages, and maximum 64 pages. A publication/yank during pagination
changes the commitment and the client refuses the inconsistent snapshot.

`POST /v1/yank/<owner>/<name>/<version>` takes
`{^yank_format 1 ^yanked true}` (or false), under the same owner authentication.
It atomically changes discovery metadata, while locked release/object URLs stay
available. This is not signature revocation. `/health` returns `ok`.

Stop the writer before taking a consistent filesystem backup. Preserve the
whole store, service config, and public trust/delegation material; keep tokens
and private seeds under their separate operator policy. A persisted registry-key
marker prevents accidentally starting the same store with another trust root.
Replacing that key requires deliberate operator replacement of the marker and
client trust pins; old delegations must be retained under the clients' chosen
trust path. Hot config reload and automatic registry-root rotation are not
implemented.

## Evidence

`tests/test_registry_service.py` exercises complete publication, crashes before
commit and after each durability boundary followed by retry/replay, owner scoping,
missing/corrupt objects, bad signatures, version conflict, yank persistence,
framing/size limits, stage expiration/admission limits, single-writer exclusion,
unsafe storage, and offline key provisioning. Its TLS probe runs the actual
service behind Caddy and uses the unchanged Gene CLI to publish twice, resolve,
sync, install, and launch with source/registry/compiler/user caches unavailable.
ASAN can instrument the service with `GENE_REGISTRY_ASAN=1`.

The tests cover process crashes and fsync/rename ordering. Actual power loss,
sustained hostile load, native Linux, multi-host storage, and clustering remain
separate qualification gates.
