# Value-operation wasm qualification — 2026-09-27

This audit extends the [distribution audit](native-app-2026-09-27-distribution.md)
from six samples to a shared 30-case native/wasm matrix. It qualifies the bounded
cases below on macOS arm64; VAL stages remain experimental. Linux and the
two-hour SERVICE heartbeat failure remain deferred at the user's request.

## Coverage and repairs

The [shared fixture](../../tests/fixtures/value_operations.json) covers equality,
hashing, indexed reads/writes, ordering, stable sorting, nominal identity,
activation and failed publication, invalid results, immutable/read-only receivers,
missing witnesses, recursion guards and guard recovery, forbidden suspension,
inheritance restrictions, and separately evaluated Type identities. Error cases
check both ABI status and a diagnostic substring. A guest trap fails the test and
stops subsequent checks; it cannot count as an expected Gene error.

| Repair | Before | Implemented behavior |
| --- | --- | --- |
| Wasm stack | The default 64 KiB Emscripten stack traps on recursive indexed access instead of reporting `ValueOperationReentry`. | The wasm task reserves 8 MiB and enables Emscripten stack overflow checks. Recursive-operation fixtures report Gene errors. |
| Result registry | Freeing an opaque result empties a sequence slot, retaining one slot per historical evaluation. | A table contains only live results. Positive identities remain monotonic; they are never recycled. Exhausting the positive i32 identity space rejects further evaluations. |
| Host evaluation lifetime | A Type returned from nested eval holds child scopes whose owners are hidden behind that Type. The partial retirement walk stops before discovering the closed cycle; the witness probe grows about 15 KiB per host input. | Each input is an isolated eval overlay. After rendering its result and releasing the compiled chunk, the host performs complete reachable-graph trial deletion. Outside owners still seed liveness; ordinary call retirement keeps its existing smaller walk. |
| Ephemeral HTTP ports | `listen ^port 0` reserves a kernel-selected port but reports `0`. | The returned Server and status report the reserved port, allowing Gene test tooling to use it without a free-port race. |
| Compiler path allocations | Returning an empty spelling list after allocating a partial numeric/dynamic path overwrites its storage under Nim 2.2.4. The allocations never appear in manual Value counters. | The compiler validates path segment kinds before allocating the spelling list. A compilation-only regression checks total occupied memory. |
| Subprocess cancellation | An async exec Task becomes terminal before its child is reaped; the host can exit while the browser remains alive. | The adapter owns cancelled settlement through child reaping and pipe/channel close. `join` waits for physical cleanup; termination escalates to kill after one second for an unresponsive direct child. |
| Binary digests | `gene/crypto/sha256` accepts only Str, requiring a binary artifact to pass through a text view. | The existing API also accepts Bytes and hashes them directly; NUL/non-UTF8 input has a fixed-vector regression. Both build orchestration and browser process/server/report tooling are Gene. |

Wasm uses the existing read-only, layout-probed ORC header adapter with 32-bit
target words. The instrumentation requires that probe to succeed. AtomicArc
retirement remains disabled. Native embedders' `run(chunk, scope)` reuse contract
has not changed; automatic root retirement is specific to the text-only wasm
host, where no raw Value escapes.

## Evidence

Optimized RC-instrumented wasm SHA-256:
`7178cdba3f900cb37ff969442469556a8e43ccb03e34dd59eb7a9ca6ea274e59`
(7,136,748 bytes; Nim 2.2.4, Emscripten 5.0.5, ORC, threads off).

The production artifact without RC instrumentation/test exports is 7,123,725
bytes, SHA-256 `3a8434f4fe8cca7ea0076f2b8f225f9ab4d31983102d774d7622a2dfa5f1784a`.

- Node 25.9.0 passes all 70 ABI cases on both production and instrumented artifacts: the existing 39 plus the 30 shared cases and a binary-digest vector.
- Node and Google Chrome for Testing 154.0.8037.57 pass the same 30 cases and
  identical lifetime checks. The Gene browser driver serves snapshotted artifact
  bytes on loopback, launches an isolated browser profile, bounds execution, joins
  process cancellation, writes its JSON report, and verifies server cleanup.
- Inner-eval batches of 1/100/1,000 preserve all seven managed class counts,
  `live_managed` 730, and zero native roots. A retained Type and instances still
  dispatch equality/hash/order after intervening batches; dropping them returns
  from the retained count to baseline (738 before/after).
- Cross-host batches of 1/100/1,000 keep occupied guest heap at exactly
  **3,362,256 bytes** after warm-up and collection. This includes Nim scopes,
  strings, result records and table capacity, beyond manual Value counters.
- Six repeated reentry, suspension and partial-activation fixtures also hold
  occupied guest heap flat at **3,362,240 bytes** through the same checkpoints.
  Their unchanged diagnostic/status assertions remain part of every batch.
- 128 simultaneously live handles remain readable. Repeated free is harmless,
  stale status is `-1`, new identities differ, and live handles end at zero.
- Native RC and AddressSanitizer suites pass the new nested-eval cycle and
  externally held Type controls. An outside-held Type survives root retirement,
  remains callable in another scope, and permits retirement after it is dropped.
- The Gene browser driver reports complete/graceful server shutdown with zero
  forced connections, cleanup leases, open resources and pending cleanup Tasks.
  Its browser process is absent after `join` and CLI exit. A POSIX subprocess
  regression verifies nonterminal cancellation followed by `join`, and confirms
  that even a child ignoring TERM is reaped rather than left as a zombie.

All four standard gates pass (`nimble test`, `spec`, `leakcheck`, and `threadcheck`); the native RC suite also passes AddressSanitizer. The default test gate still uses the tracked wasm artifact; the fresh 70-case ABI and browser evidence are recorded separately above.

Ignored local evidence is under `tmp/wasm-qualification-release/`: `build.json`,
`abi.log`, `node-report.json`, and `gene-browser-report.json`. The tracked
`web/gene.js` and `web/gene.wasm` artifacts are not replaced by this audit.

## Reproduction

Run from the repository root. Build a native Gene driver with Nim if needed;
this is the bootstrap step. Both wasm build orchestration/metadata and the
browser server/process/report driver are Gene. Nim/Emscripten remain external
compiler tools. The JavaScript adapter and checks execute in the browser and
Node host environments.

```sh
nim c --threads:on -d:release --path:src --hints:off -o:tmp/gene-wasm-host-driver src/gene.nim
tmp/gene-wasm-host-driver run tests/build_wasm_qualification.gene --build-dir tmp/wasm-qualification
env GENE_WASM_MODULE=tmp/wasm-qualification/gene.js GENE_WASM_VALUE_CASES=1 node tests/test_wasm.mjs
env GENE_WASM_MODULE=tmp/wasm-qualification/gene.js GENE_WASM_REPORT=tmp/wasm-qualification/node-report.json node tests/test_wasm_values.mjs
tmp/gene-wasm-host-driver run tests/test_wasm_browser.gene tmp/wasm-qualification /path/to/chromium tmp/wasm-qualification/browser-report.json
```

`--production` builds without RC instrumentation or test-only exports; use the
70-case ABI runner for that artifact. `--debug` is useful for Node diagnostics.
The debug browser artifact stopped during its first evaluation and produced no
completion report; only the optimized browser artifact has passing evidence.

## Limits

This is neither an arbitrary-cycle collector nor an all-browser release claim.
Compiled-code constants, error evidence and opaque continuation owners retain
their conservative policy. Browser workers, additional browser engines, broader
retained-global graphs and other host facilities still require their own gates.
The browser profile is retained beside the report for diagnosis; the harness
does not use the user's normal profile. Sustained service, native Linux and
AtomicArc retirement are separate tasks. No profile stage is promoted.
