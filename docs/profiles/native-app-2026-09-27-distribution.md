# Package distribution continuation — 2026-09-27

Linux work is deferred at the user's request. All evidence here is macOS arm64
or the explicitly built wasm module. No profile stage is promoted.

## PKG-2 native artifact policy

Environment-dependent C derivations include a hostname and random per-user
build-installation identity outside artifact stores. Different build installations
sharing the same compiler, source, SDK path strings, and artifact store therefore
cannot reuse that C derivation. SDK/default-header/linker inputs are still not
fully pinned; this is conservative local reuse, not a hermetic build claim.

Compiler evidence imported by an installed bundle authorizes only its required,
verified artifact closure. It cannot authorize an optional/ambient cache hit or
a rebuild. Prebuilt native variants retain their existing target/ABI/runtime and
system-dependency contracts. Destination-host compatibility remains qualified
separately. The unreachable duplicate `c_library` selection branch was removed.

`tests/test_build.nim` passes its complete suite, including a real C library built
against two simulated host identities: same-host reuse succeeds, another host
rebuilds, ambient imported-evidence reuse is refused, and required installed
replay succeeds with the original artifact digest. Existing CLI C/shared/static,
system dependency, installed genex, and compiler-free launch checks pass.

## PKG-3 persistent service

The separate `gene-registry` executable implements the existing publication,
release, object, version, and owner-delegation routes. It admits complete signed
trees before durable version selection; owner tokens are checked before uploads.
It bounds headers, body sizes, total request I/O, staging count/age, release size,
and accounted storage. It streams file traffic and runs one writer/connection at
a time behind the established HTTPS proxy seam. Offline keygen/delegation tools
use the existing Ed25519 records and require no online private signing key.

See [the deployment/storage contract](../spec/registry-service.md). The actual
Caddy/CLI fixture publishes twice, resolves/syncs a hosted dependency, installs
it, then launches and observes its value with source, registry, compiler, and
user caches unavailable. Native Linux, sustained registry operation, clustering,
automatic published-object GC, and actual power-loss qualification remain open.

Eight service tests pass normally and under ASAN. They cover missing/corrupt
objects, forged signatures, owner/token scoping, version conflict/idempotence,
yank persistence, private provisioning, writer exclusion, unsafe storage,
admission/expiry/storage/deadline limits, and restart recovery. Test-only hard
exits after object durability, release-directory durability, and version selection
prove that retries never select a partial tree. They distinguish an admitted
but unselected immutable release from a selected version. Graceful shutdown
must exit successfully; the sanitizer is a memory-error check, not a managed
lifetime or power-loss oracle.

The broad `nimble test` suite and `nimble spec` pass, including the old HTTPS
registry/offline signature replay tests and 39 cases against the existing tracked
wasm artifact. The added backend-boundary suite was also run independently.
The release/RC CLI profile returns `probe_pass`, preserving compiler/cache/source
independence, complete generation changes, and the old current pointer after a
failed update. Its binary SHA-256 is
`09c81f452900b7d37354f73f7161b32bde99e2ab4cc1d512742b4009e5a5fc0d`;
report `tmp/package-distribution-cli-profile.json` records parent revision
`9506f3c` and a dirty continuation worktree.

## Value-operation backend audit

The six shared semantic cases in `tests/fixtures/value_operations.json` cover
held/recursive equality, frozen Set/general-Map keys, missing hash, numeric
paths/selectors/size/writes, huge/F64 index bounds, ordering, and nominal sorting.
They pass on the native VM and a freshly built wasm VM. The latter passes all
45 ABI cases (39 existing plus six shared) under Node with Nim 2.2.4 and
Emscripten 5.0.5; wasm SHA-256:
`0bfe460feaf66418a2a0d8582f973a83ece755d7ad88bffab89974ef497c09ce`.
The tracked `web/gene.js`/`web/gene.wasm` were not replaced.

| Backend | Audited outcome | Remaining qualification |
| --- | --- | --- |
| Native VM | Full existing value-operation spec and six shared samples pass. | Full stage release criteria, native Linux, worker callback support. |
| Wasm VM | Fresh module agrees with all six shared samples. | Complete error/reentry/activation/lifetime matrix and browser-host qualification. |
| Emitted web JS/TS | Five witness declaration combinations are refused with `unknown web protocol`, before emission/execution. | Implement canonical witness identities and operations with shared conformance before accepting them. |
| Experimental typed-native C | Five witness-bearing native-wrapper operation probes are refused with `cannot lower`, before emission/execution. | A witness-aware bridge or explicit admission for a qualified subset. |

These refusal probes do not imply that ordinary explicit protocols or built-in
operations are unavailable on web/C. They guard the canonical implicit value
fallback boundary. Sampled parity/refusal does not promote VAL-1–3 or qualify
every program, lifecycle, worker, or backend edge.

Reproduce the native/refusal audit with:

```sh
rtk proxy nim c -r --path:src tests/test_value_backend_boundaries.nim
rtk proxy env GENE_WASM_MODULE=tmp/value-backend-wasm/gene.js GENE_WASM_VALUE_CASES=1 node tests/test_wasm.mjs
```

The fresh wasm build uses the `gene.nimble` wasm flags with output/nimcache under
`tmp/value-backend-wasm/`, whose local package.json selects CommonJS for the
generated Emscripten loader. `GENE_WASM_MODULE` selects that module explicitly;
the default ABI test continues to exercise the tracked artifact.

## Sustained SERVICE result

The earlier repaired binary's two-hour soak failed the unchanged 250 ms
heartbeat limit with a 319 ms idle gap (269 ms wait overrun, no loop work/CPU,
active connections, or in-flight requests). Its report lacks managed-slope and
shutdown results after that failure. The earlier baseline's passing soak remains
separate evidence. See [the cancellation audit](native-app-2026-09-26-cancellation.md).
