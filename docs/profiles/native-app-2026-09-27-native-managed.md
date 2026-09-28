# Opaque managed native SDK — 2026-09-27

The owner selected [opaque managed handles](../proposals/native-managed-borrows.md).
This checkpoint implements the additive core of that design. Legacy `GeneApi`
v4/v5 signatures, Gene syntax, normal AtomicArc retirement and activation
collection remain unchanged. Shared/canonical reclamation remains disabled.

## Ownership boundary

`src/gene/native_managed.nim` provides opaque `GeneManagedDomain`,
`GeneManagedRoot`, `GeneNativeBorrow`, `GeneManagedEnvironment` and
`GeneManagedResult` types. Roots use monotonic positive IDs in a live-only domain
registry. A structured `geneWithNativeBorrow` callback ends admission on success
or error. Wrong-lane, ended-borrow, released-root, closed-domain and wrong-runtime
uses fail before a Gene graph read. An attached foreign lane can borrow a root;
only the VM root lane can create VM-origin roots, invoke Gene calls, create
environments or export legacy roots.

The entire callback is owner-dependent because user code can await root-lane
progress, so a collecting root defers rather than draining it. A dedicated
foreign-callback/root-acknowledgement regression bounds that case.

Managed roots keep known Value/Scope/code graphs on atomic reference counts
without setting the experiment's permanent raw-publication pin. In the opt-in
collector, a live registry/borrow owner remains an outside owner. After it drops,
qualified private namespace generations retire. Root entries keep known weak
defining Scopes strongly until physical release, including through cloned
handles. A separate raw-publication
marker preserves the old permanent pin for worker/shared and legacy SDK exports.
Exporting a managed root to `GeneRoot` pins the graph irreversibly, even after
both named roots release. This is explicit interop, not an automatic ownership
conversion for v4/v5.

The first mediated operations copy Bool, Int64, Str and Bytes; traverse only
deep-frozen List/Map/Node values and return independently owned handles; invoke
Gene callables on the root lane with opaque argument/environment/result/error
handles. Status and message are copied into `GeneManagedResult` without a raw
Gene Value field. A domain close denies new admission and reports outstanding
roots/borrows; release and already admitted reads can still finish. Registry
last-owner drops happen outside its lock and the native admission lock.

The next adapters define/read native wrapper fields without raw Values and
construct borrowed/owned C pointers. A scoped address callback holds the
existing physical C-pointer ticket: close fails during the callback, and
cleanup runs outside registry/admission locks. Private root-lane Buffer
new/get/set retains typed item checks; published mutable Buffers are excluded
until they have a shared mutation policy.

An external managed Task keeps a producer owner after its user root drops.
User cancellation does not retire that owner; completion, failure or explicit
physical cancellation retirement ends it. An attached foreign lane can
complete an untyped Task. TaskState retains result/error defining Scopes for
the Task result lifetime, and the collector models its Value/Scope edges.

Managed Channel send/receive uses the existing Send/type checks. Queued items
own known defining Scopes until SDK dequeue or Channel drop; SDK dequeue
transfers that ownership into the returned handle. ChannelState's queued
Values and Scope pins are modeled by the collector, allowing flat closed-cycle
batches. A legacy VM receive permanently pins affected released roots. That
handoff is an explicit raw publication, including on default ORC.

AtomicCell publication snapshots its current Value under the cell lock.
Shared stores, swaps and CAS publish replacement Values before handoff, and
last-owner cleanup runs after releasing the lock.

## Qualification

`tests/qualify_native_managed.gene` builds separate normal, opt-in, ASAN and TSAN
children with bounded deadlines and records hashes/commands/logs in
`tmp/native-managed-qualification/`. Normal AtomicArc runs a disabled-retirement
SDK control; the final fixed-source run passes disabled (one control), opt-in
(28 cases), ASAN (28) and targeted TSAN (six), without timeout or truncated
output. Binary SHA-256 values:

| Mode | SHA-256 |
| --- | --- |
| Disabled | `1fc39c3eeb04d676c2af4727884662e10867187a969e0bc254b63a5aa8782f6e` |
| Opt-in | `829029a486b1b7cd98bc29bce9ae2eea68fd70e5dfcef21af73eb7bed3a97955` |
| ASAN | `41257a2dae63515ce659e3ecf7f4eafc61ed145e2facba7a1b18b6a19d0f0fea` |
| TSAN | `b7f6f933a3ca3f1d25f799c44974bd443affbadc8966cdf89bfa00cbd4c97d4e` |

The opt-in controls check 1,000
released/repeated IDs, wrong lane/runtime, copied binary data, nested handle
survival, managed call result and typed error handles, frozen traversal, failure
unwinding, physical cleanup outside locks, Task producer/cancellation/foreign
completion, wrapper/pointer/Buffer ownership, Channel ticket transfer and
shutdown. Private namespace and closed managed Channel cycles have flat
managed-class counts after warm-up at 1/100/1,000/10,000
lifetimes; a retained handle keeps the graph live until it releases. The legacy
export control remains retained and explicitly tears down its test-owned graph.

The separate qualification report is the evidence for this new SDK. The earlier
AtomicArc retirement runner was also rerun on this tree and passes disabled (2),
probe (30), ASAN (30) and targeted TSAN (10) controls. Its final report is under
`tmp/atomic-retirement-qualification/`; old binary hashes do not describe this
source. The default ORC RC leak suite, executable specs and broad `nimble test`
pass. The full AtomicArc `threadcheck` passed before the last SDK-only borrow
callback classification; the final SDK probe/ASAN/TSAN and normal-mode control
were rerun after that change. Native ingress, workers, owned Client and the
standard RC suite are covered by the earlier full threadcheck.

A fresh instrumented wasm build from the same core source has SHA-256
`e06473b2089aef2206ed564c274c72678c6ec58d79da80f685a2cb19edd0da3e`.
Node passes all 70 ABI cases. Google Chrome for Testing 147.0.7727.15 passes
the 30 shared browser cases and lifetime controls: all managed classes and
occupied heap are flat at sampled checkpoints, stale handles are rejected,
live handles finish at zero, and the server shuts down gracefully with no
pending cleanup, resource, lease or forced-connection count. Artifacts/reports
are under `tmp/wasm-managed-qualification/`; tracked `web/gene.js` and
`web/gene.wasm` were not regenerated. The managed Nim SDK itself is not linked
into this wasm artifact.

## Unqualified paths

The managed API is not yet a replacement for all 35 legacy `GeneApi` entries.
Managed Actor queues, typed foreign Task failures, installed extensions and
arbitrary direct Nim APIs require managed adapters and race/lifetime controls.
Mutable shared Buffers and Gene worker/actor handoffs lack complete snapshot
and ownership policy. Raw VM
input before `geneManagedRootFromVm` is trusted to be owner-confined; an arbitrary
pre-existing foreign Nim ref cannot gain a retrospectively tracked lifetime.
Code subclasses, opaque continuations, native cleanup requiring Gene worker
progress and mutable shared graph snapshots remain excluded. No profile stage
is promoted; Linux and the SERVICE heartbeat investigation remain deferred.
