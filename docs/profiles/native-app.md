# Native application qualification

**Status (2026-09-28):** PROFILE-0 is implemented; the full native application
profile is **not qualified for release**. The executable authority is the
[profile manifest](../../tests/profiles/native-app/profile.gene) and
[runner](../../tests/profiles/native-app/run.py). This report consolidates the
former dated `native-app-*` audits. A probe pass is evidence for its stated
workload and platform, not promotion of a planned dependency or the whole
profile. Historical intermediate measurements remain in Git history through
`ab9c5ae`; the decisive results and known failures are retained below.

## Current gate ledger

| Workload | Latest supported claim | Remaining gate |
| --- | --- | --- |
| SCRIPT | APP-1 fixture and typed fault checks pass on macOS arm64; Rosetta Linux probe passes. | Native x86_64 Linux qualification and full profile gates. |
| Installed CLI | Offline source-built C binding, locked resource, update, and failed-update rollback pass on macOS arm64; Rosetta Linux probe passes. | PKG-2 destination-host qualification and native Linux. |
| SERVICE | 60-second HTTPS proxy/stream/SQLite probes pass functionally at 30 requests/s. A two-hour run on the repaired binary failed the unchanged 250 ms heartbeat gate. | Explain and resolve the rare idle wait overrun, repeat sustained retention/cleanup proof, and native Linux timing. |
| DATA | 10/100 MiB CSV group probes and typed limit failures pass on macOS arm64; Rosetta Linux probe passes. | APP-2, VAL-3, IO-2 release gates and native Linux. |
| LIFETIME | Ten bounded ORC/RC children hold flat class counts through 1/100/1,000/10,000 batches on macOS arm64 and Rosetta Linux. | Arbitrary mixed ownership, shared AtomicArc reclamation, installed native ownership, sustained service, and native Linux. |

Optional packages remain separate experimental evidence: `genex/tzdb`,
`genex/archive`, `genex/libuv_timer`, direct TLS, hosted registry publication,
and the owned HTTP Client. They do not promote the five core workloads. Wasm,
web/C value operations, and AtomicArc workers have independent gates.

## Reproduce and interpret results

From the repository root:

```sh
python3 tests/profiles/native-app/run.py --gene /path/to/gene --probe-blocked
nimble test
nimble spec
nimble leakcheck
nimble threadcheck
```

`--probe-blocked` executes available fixtures even when a prerequisite stage
remains planned. `--require-supported` rejects an incomplete profile. Reports
under `tmp/native-app-profile/` record platform, revision, binary, stage state,
and workload outcomes. RC claims require `-d:geneRcStats`; a plain build reports
`rc_stats?` false and skips the managed-slope gate. The runner's
`service_heap_slope` compares the minimum of the first and last thirds of
five-second samples against a 256-Value limit. A test-only collection safepoint
supports bounded lifetime children; it does not enable general collection.

The four standard gates (`nimble test`, `spec`, `leakcheck`, and `threadcheck`)
pass on the current packaged-native-module source. Each table or hash below
identifies a bounded build; evidence from one build must not be silently
transferred to another.

## Core workloads

### SCRIPT and installed CLI

SCRIPT checks golden JSON, CSV, tree, process, and API output. Bad CSV, API
errors, and child failures produce typed errors without publishing output.
The macOS full audit used release binary SHA-256
`d2eec8b1338fd972b19d55f0c3f01d036886c083a926b0e7e15b699965b9405a`.

The CLI fixture builds a selected `c_library`, calls its C function, installs
from a locked package, hides the source checkout, empties the artifact cache,
and launches without a C compiler from another working directory. Updating
changes the generation; a failed update leaves the previous installation
current. The macOS fixture pins `MacOSX26.5.sdk` through
[`cli-toolchain.lock.json`](../../tests/profiles/native-app/cli-toolchain.lock.json)
because the host's default 27 SDK cannot link that C library with the installed
linker. PKG-2 C derivations now include a per-build-installation host identity
outside copied artifact stores. Imported compiler evidence permits only the
required verified installed closure, never an ambient cache hit or rebuild.
This is conservative local reuse, not a hermetic or destination-host claim.

### SERVICE and cancellation

The service probe uses Caddy 2.11.2 as an HTTPS proxy to a loopback Gene
streaming service. It covers forwarded-header/trust checks, streamed uploads
and responses, SQLite writes, eight clients, slow requests, and graceful stop.
The 2026-09-24 full audit served 1,800 requests at 30/s with p95 14.83 ms,
p99 47.92 ms, a 59 ms maximum heartbeat gap, and zero tracked I/O resources
and leases. Three repeats of the same release binary had 52–63 ms maximum
gaps. A serve-loop fix removed a 50 ms idle-select delay for in-process Client
transfers; ten later 60-second repeats had 53–73 ms gaps and p95 9.5–16.8 ms.
These passes do not cancel the later sustained failure.

A two-hour baseline at revision `2439442` passed 216,000 requests at 30/s,
p95 5.56 ms, p99 6.99 ms, a 112 ms maximum heartbeat gap, and zero managed
slope (995 early/late minimum). It predates the stable-capture and
cancellation repairs. The independent two-hour run on repaired revision
`b7057b1` served the same 216,000 requests but returned `probe_failure`:
**319 ms maximum heartbeat gap against the 250 ms gate**. The failing sample
had 269 ms kernel wait overrun, zero loop work/CPU, no active connection, and
no in-flight request. Its p95 was 11.46 ms; the runner stopped at the failed
heartbeat gate, so that report cannot establish heap slope or shutdown
cleanup. Reports are `tmp/service-2h-claude-baseline.json` and
`tmp/service-2h-mixed-cancellation.json`.

Shorter runs later showed 211, 238, 222, 364, and 219 ms gaps, including one
more gate failure. `gc_stats` sampling and SQLite calls did not explain them.
Instrumented ORC collection took only 7–56 µs near process start, not during
the stalls. CPU saturation and scheduler-priority experiments did not reproduce
the failure. `(status server)` now separates loop wall/CPU work from select
wait overrun. The cause remains open, and the owner deferred this investigation.

Stable closure capture now copies only immediate, Str, and Sym values; mutable
reference-bearing captures use the activation Scope so a later object → closure
cycle stays visible to retirement. Cancellation of server handlers requests
scheduler unwind, preserving exactly-once `ensure` and waiting for read/handler
cleanup. The ten-child mixed ownership fixture checks channel/timer/nested Task
cancellation, retained graph usability, zero Fiber/readiness/I/O counters, and
flat managed counts. The cancellation-repaired lifetime binary SHA-256 was
`7f464e079911c9c2d37b140158771df7d70af27948bfbaeb04b39fe1bd816162`;
its mixed and HTTP children held 929 and 1,044 managed Values. The later
reader-borrowing checkpoint held 931 and 1,046 after adding read guards, with
zero guards at every checkpoint.

### DATA and long-lived VM

The DATA fixture processes deterministic 10 and 100 MiB CSV inputs into the
same 32 groups, and rejects group/record limits with typed errors. At matching
EOF checkpoints, parser payload retention is 13 bytes for either input; peak
payload is 66,570 bytes for either size, below the 8 MiB growth budget.
Upstream I/O retains zero bytes at EOF and peaks at 65,536 bytes. The counters
exclude allocator capacity/object overhead; sampled RSS is complementary.

VM-2 retires released, discarded, and failed sandbox generations through
trial deletion when no outside owner reaches their closed graph. Earlier
Type/protocol/impl generations grew 15 Values per release and a
failed-prepare pair grew 30 per iteration. The final bounded profile holds
flat counts through 10,000 iterations and keeps retained Module, function,
instance, and Type controls callable. The reader-borrowing ten-child baseline
is:

| Child | Warm/final managed Values |
| --- | ---: |
| Eval/failure; ValueEq/Hash/Order witnesses; Type cancellation | 881; 822; 794 |
| Mixed cancellation; partial selection; in-process service; HTTP cancellation | 931; 891; 866; 1,046 |
| Scalar; Type/protocol/impl; discarded/failed generations | 824; 824; 826 |

The lifetime binary SHA-256 for that ten-child checkpoint was
`af0cdfcd7494c7b9e6c762f56ebefd1ddaa283245f55d97a4d6eadb83c840088`.
Each child matches every managed-class baseline after 1/100/1,000/10,000
batches, with zero native roots and relevant Task/I/O/read-guard counters.
Selected cancellation children also passed ASAN through 1,301 iterations;
ASAN leak detection was disabled, so RC counters remain the managed-leak
oracle. VM-2 retirement is off under AtomicArc and in wasm except where a
separate host-specific path is explicitly qualified.

## Async I/O and borrowing

`gene/io` has experimental `AsyncReader`, `AsyncWriter`, and `IoResource`
contracts. The owned Client's exclusive upload borrow and a scheduler-owned
pending protocol-read admission cover canonical `AsyncReader:read` dispatch,
including Gene implementations, held/dynamic sends, pipelines, inheritance,
and `super`. A pending read refuses upload admission; an upload refuses caller
reads with `IoBusy`. Client cancellation retains the borrow and cleanup lease
until the read Task's `ensure` and transport cleanup settle. Completed pins
retire on the root lane outside scheduler locks. Native adapters keep their own
physical lifecycle; custom convenience methods or backend aliases need their
own backend policy.

The owned-Client suite passed 41 AtomicArc cases and 40 ORC cases (one worker
case skipped), five custom-reader ASAN cases, and the RC zero-guard control.
The full five-workload probe after this repair returned SCRIPT `pass` and four
`probe_pass` results. SERVICE served 1,800 requests at 30/s, p95 5.69 ms,
p99 9.10 ms, 54 ms maximum gap, zero managed slope (995 early/late minimum),
and zero cleanup Tasks, leases, resources, and retained bytes. Its release/RC
binary SHA-256 was
`8cb5e0164e844f94e84f248e11e3fd6fe8d5b9512b9c392c3262f7365020b9ed`.
The separate two-hour repaired-binary heartbeat failure remains authoritative.

Worker-backed file I/O, pipe readiness, subprocess streams, TCP, streamed HTTP
bodies/responses, gzip and ZIP adapters, direct TLS, and the owned Client have
focused tests. The native application profile is not promoted by those
component checks. The [I/O contracts](../proposals/async-io.md) and
[lifetime ledger](../../tests/lifetime/LEDGER.md) track their physical owners.

## Distribution and value operations

PKG-3's `gene-registry` service admits complete signed trees before durable
version selection. The real Caddy/CLI fixture publishes, resolves, syncs,
installs, then launches a hosted dependency with source, registry, compiler,
and user caches unavailable. Eight service tests pass normally and under
ASAN, covering forged/corrupt objects, owner scoping, conflict/idempotence,
yank persistence, storage/admission limits, writer exclusion, and restart
recovery after test-only hard exits. Sustained registry operation, clustering,
automatic published-object GC, power-loss qualification, and native Linux
remain open. The [registry storage contract](../spec/registry-service.md)
contains current implementation details.

VAL-1–3 semantic equality/hash, indexed access, stable sorting, and nominal
witnesses have native conformance and lifetime checks. The shared
[value fixture](../../tests/fixtures/value_operations.json) exercises 30
native/wasm error, reentry, activation, and witness cases. Unsupported
implicit-witness combinations are refused before emitted web JS/TS or
experimental typed-native C execution; sampled refusal is not backend parity.
The [value proposal](../proposals/value-operations.md) keeps release criteria.

The initial distribution checkpoint's CLI binary SHA-256 was
`09c81f452900b7d37354f73f7161b32bde99e2ab4cc1d512742b4009e5a5fc0d`.
Its six-sample fresh wasm binary SHA-256 was
`0bfe460feaf66418a2a0d8582f973a83ece755d7ad88bffab89974ef497c09ce`.
Those hashes describe that checkpoint, not the later expanded wasm fixture.

## Wasm and backend parity

The expanded shared fixture covers 30 cases, including recursive equality,
indexed reentry, missing/invalid witness results, forbidden suspension,
inheritance, separately evaluated Type identities, and failed publication.
A guest trap fails the test rather than counting as a Gene error. The optimized
RC-instrumented wasm audit passed 70 Node ABI cases and the same 30 semantic
and lifetime controls in Chrome for Testing. Across 1/100/1,000 host inputs,
all seven managed counts and occupied guest heap stayed flat; occupied heap
was 3,362,256 bytes after warm-up. A retained Type/instance remained callable
and returned to baseline after drop; 128 simultaneous result handles remained
readable, stale/repeated free was safe, and live handles ended at zero.

The audited optimized RC wasm SHA-256 was
`7178cdba3f900cb37ff969442469556a8e43ccb03e34dd59eb7a9ca6ea274e59`;
production without RC instrumentation was
`3a8434f4fe8cca7ea0076f2b8f225f9ab4d31983102d774d7622a2dfa5f1784a`.
A later managed-SDK/source checkpoint rebuilt wasm as
`3e36b387797807ed21b6ca8c5998e1785746c97d606306458f938bbe4a45bf1c`:
70 Node ABI cases and 30 Chrome shared/lifetime controls passed. The tracked
`web/gene.js` and `web/gene.wasm` were not replaced. The browser driver and
wasm build orchestration are Gene; Emscripten remains an external compiler.
The current synchronous-callback source produced a fresh RC-instrumented wasm
artifact with SHA-256
`9ebf941ce3b1797d7e9209cc63c58b243249d23125da3cb1f73fefe9c5eb3311`.
It passes the same 70 Node ABI cases and 30 pinned Chrome for Testing
147.0.7727.15 cases; managed counts, occupied guest heap, retained-Type
control, and browser/server shutdown remain flat/clean. Reports and the
isolated browser profile are under `tmp/native-callback-wasm/`.
The current package-loader source produced a fresh RC-instrumented wasm
artifact with SHA-256
`c4edb11c5ff4fe340b191f4afbea9b8ff289f5d01fe509ec4234a1b4429238fe`.
It passes 70 Node ABI cases and 30 pinned Chrome for Testing cases, with flat
managed counts (735), occupied guest heap (3,374,032 bytes), retained-Type
control, and graceful browser/server shutdown. Reports are under
`tmp/native-module-wasm/`; tracked web artifacts remain unchanged.
Other browsers, workers, opaque code/error graphs, and broader shared mutable
ownership are unqualified. The [wasm harness](../../tests/test_wasm_browser.gene)
and [workflow](../workflows.md) document reproduction.

## AtomicArc retirement

AAR-0 introduced an opt-in AtomicArc generation-retirement probe, not a normal
runtime switch. AAR-1 added publication guards and native entry admission.
Published Scope tables are not enumerated by the collector; known ancestors,
weak defining scopes, compiled code edges, and native handoffs are marked
before exposure. Direct raw Nim references remain permanently published.
The native admission gate drains selected outer SDK entries before analysis,
allows nested entries, defers owner-dependent work, and reopens admission
before final-owner cleanup. It does not turn a raw `Value` returned by a Nim
helper into a tracked borrow.

The owner selected opaque managed handles in
[the managed-borrow design](../proposals/native-managed-borrows.md). The
mediated registry gives each root a monotonic ID, scoped admission, copied
scalar/Bytes reads, frozen-container traversal, environment lookup/call/define,
and Task/Channel/Actor/resource adapters. Weak/code Scope tickets follow
qualified child and binding edges. Under the opt-in collector, private
namespace, Type, Channel, Actor, and definition cycles return to flat managed
counts through bounded 1/100/1,000/10,000 controls. Retained handles keep
those graphs live until release; explicit export to a raw `GeneRoot` pins them
irreversibly.

The current managed qualification runner passes disabled/probe/ASAN/targeted
TSAN at 1/39/39/10 cases; the AAR-0 compatibility runner passes 2/30/30/10.
Their build commands and binary hashes are in
`tmp/native-managed-qualification/report.json` and
`tmp/atomic-retirement-qualification/report.json`. Normal AtomicArc
retirement, AAR-2 shared/canonical reclamation, and AAR-3 activation/worker
handoff remain disabled. Managed Actor worker execution stays root-only
pending the demonstrated worker allocator-lifetime fix. Mutable shared
Buffers/graphs, arbitrary direct Nim ownership transfers, unmodeled callbacks,
and native cleanup requiring Gene worker progress remain outside the model.
After the ingress migration, the AAR runner again passes
disabled/probe/ASAN/TSAN at 2/30/30/10 cases. Its late C-entry case now proves
that the handler Scope retires after physical release; the current mode hashes
are in `tmp/atomic-retirement-qualification/report.json`.

## Native ownership and C ABI

There is now **one public C extension layout** in
[`native_api.h`](../../src/gene/native_api.h), with unversioned `GeneApi` and
`gene_module_init` names. Its numeric layout version is 6. The former v4 Nim
function table, v5 ingress table, versioned loaders, and v5/v6 headers were
removed. Direct Nim helpers remain for in-repo runtime code.

The managed loader accepts opaque environment IDs and advertises only
implemented feature bits. Its compiled C fixtures check layout, feature
negotiation, copied reads, stale handles, call/define, frozen traversal,
AtomicArc attached-lane tokens, and synchronous callback registration. The
[callback ABI suite](../../tests/test_native_callback_abi.nim) covers temporary
positional/named/environment IDs, retained
arguments, typed error/panic/cancellation, rejected borrowed results,
re-entrant close, waiter creation/cancellation during an active callback,
initializer rollback, caller ownership after failed registration, domain
shutdown, and 10,000 create/close/wait cycles with flat registry roots and
manual Value counts.
It passes under ORC, AtomicArc, ASAN, and TSAN. A library borrow prevents unload
until its C retirement callback runs outside registry locks.

An ingress-only view of the same C layout powers `$native/ingress/open`; its
C callback thread copies bytes and never touches Gene objects. Each subscription
now owns its handler, dispatch environment, active Task and library through
managed IDs rather than permanent raw handler/Scope publication. The
AtomicArc private-generation probe keeps a late admitted C entry live, then
retires the handler Scope after physical release. `genex/libuv_timer` preserves the physical unregister
proof: no future callbacks, zero in-flight entries, then handler settlement.
The installed macOS arm64 timer app passed **10,000** create/notify/close
lifetimes with source hidden and compiler unavailable, zero live C contexts
and libuv handles after each close, 20,000 handle close callbacks, and native
root/materialized-lease baselines.

The selected `gene_api` package path now returns an owned `NativeModule`
IoResource. The [installed native-module fixture](../../tests/test_genex_native_module.py)
passed **10,000** compiler-free create/call/close/wait lifetimes on macOS arm64
with two registered C callbacks per module, zero live C contexts, exact
retirement counts, and native-root,
`native_module_records`, and materialized-lease baselines. It rejects ordinary
`c_abi` metadata, rolls back a failed initializer after two registrations,
loads a selected prebuilt GeneApi variant, closes re-entrantly from an active
C callback, and auto-closes an abandoned owner. An escaped Module value then
refuses its unloaded callback safely.
The C ABI now has an opaque Task producer family. Its callback fixture proves
success, failure, cancellation followed by late completion, stale-token
rejection, and attached-lane completion after domain close. A selected
installed package also holds `NativeModule` close pending until a Task
producer reports physical completion. The concurrent C control passes 10,000
Tasks under AtomicArc RC tracking and 1,000 each under ASAN and TSAN, mixing
user cancellation with four attached C workers after domain close. All
producer and attachment counts return to zero before library close. The count
is configurable for longer soaks.
The [native ABI design](../proposals/native-managed-extension-abi.md)
and [package-module specification](../spec/native-module.md) define those gates.
A nonstandard ORC-with-threads run crashes in a concurrent Task join after all
ingress tests pass; unchanged `538764d` reproduces the same failure. The
supported AtomicArc threaded ingress suite passes.

## Linux probe and open decisions

An Ubuntu 24.04 `linux/amd64` Docker container under Apple-silicon Rosetta
passed the five profile workloads and `nimble test`, `spec`, `leakcheck`, and
AtomicArc `threadcheck` (1,538/775/64/521 cases at that checkpoint). SERVICE
served 1,800 requests at 30/s with p95 11.73 ms and a 60 ms maximum heartbeat
gap; the RC build held 995 managed Values at all 13 samples. The eight
lifetime children matched macOS counts. This is probe evidence under
emulation, not native x86_64 timing qualification. Ubuntu's packaged libuv,
utf8proc, and libcurl were older than the genex pins; the probe built pinned
versions from source. Linux work is deferred by the owner.

Next implementation work is broader native-producer use and the remaining
shared ownership gates.
The SERVICE heartbeat investigation,
Linux native timing, broader shared ownership, and profile promotion remain
deferred or gated as described above. The
[profile proposal](../proposals/python-replacement-profile.md#recommended-implementation-order)
sets the wider release sequence.
