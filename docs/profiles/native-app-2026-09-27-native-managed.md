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

Managed Actor construction, try-send, state/status reads and close use opaque
handles. Accepted messages own defining Scope tickets through the mailbox and
through a parked handler Fiber; a continuing handler transfers its returned
state provenance into the Actor before dropping the message ticket. State
reads copy the Value and tickets under the Actor lock. Gene-facing `snapshot`
is an explicit raw handoff and permanently pins affected weak state; Gene
`upgrade` and typed `ActorRef` narrowing replace managed tickets on the root
lane. Managed handlers stay on that lane for now. An ASAN worker experiment
found that a worker-created Actor field could survive after its worker's Nim
allocator exited and be destroyed on the root lane. Keeping only parked Fibers
alive did not solve the Actor-state case; worker execution remains an AAR-3 gate.

Managed environment definitions now transfer weak/code Scope tickets to the
target binding and independently to the returned root. Assignment and
redefinition release the old ticket after replacing the stored Value; mirrored
slot writes update their reflection before doing so. The retirement graph
counts binding ticket edges and detaches them with retired Scope bindings.
A weak Protocol survives either owner and then retires after both release;
10,000 self-referential definition cycles return to a flat managed baseline
under the opt-in collector. The default ORC control also retires 1/100/1,000
cycles without managed-class growth.
Direct Nim writes to `Scope.vars` remain outside this mediated contract.

AtomicCell publication snapshots its current Value under the cell lock.
Shared stores, swaps and CAS publish replacement Values before handoff, and
last-owner cleanup runs after releasing the lock.

## Qualification

`tests/qualify_native_managed.gene` builds separate normal, opt-in, ASAN and TSAN
children with bounded deadlines and records hashes/commands/logs in
`tmp/native-managed-qualification/`. Normal AtomicArc runs a disabled-retirement
SDK control; the final fixed-source run passes disabled (one control), opt-in
(37 cases), ASAN (37) and targeted TSAN (nine), without timeout or truncated
output. Binary SHA-256 values:

| Mode | SHA-256 |
| --- | --- |
| Disabled | `62827dad2934eda395cc4c4fad731a46e0e2db1bf11c7c3eebf594ac203d9176` |
| Opt-in | `4379c3d27f82e2153652188b58ad9ecdf522c6c8291d9a18c7714b7d48c6a0e8` |
| ASAN | `053cf9e22d9b11167e9a4c7b6a1a78d5765f5df7473766d2e14778af4cc6efb1` |
| TSAN | `d70e4be7dfa344c6c0f8429605baaff480a7f61f5650a4d8da5f9e733c3a9ed0` |

The opt-in controls check 1,000
released/repeated IDs, wrong lane/runtime, copied binary data, nested handle
survival, managed call result and typed error handles, frozen traversal, failure
unwinding, physical cleanup outside locks, Task producer/cancellation/foreign
completion, wrapper/pointer/Buffer ownership, Channel and Actor ticket transfer,
Actor close/upgrade/type narrowing and shutdown. Private namespace, closed
managed Channel and managed Actor/Scope cycles have flat managed-class counts
after warm-up at 1/100/1,000/10,000 lifetimes; a retained handle keeps the graph
live until it releases. The legacy export control remains retained and
explicitly tears down its test-owned graph.

The separate qualification report is the evidence for this new SDK. The AAR-0
retirement runner also passes on this tree: disabled (2), probe (30), ASAN (30)
and targeted TSAN (10). Its current hashes and commands are under
`tmp/atomic-retirement-qualification/` (disabled
`d2fe3aa2fca340488b62fd43e3e0f9db2b6a0081c5853ccb5b98133ba8324202`,
probe `393465373c80c5b5557150e94a8a350d98d40da11aa054f308669a1232288604`,
ASAN `af1c5dd4b19614a4a19633f543829c4e9d911120bb3f74039bb03cfe6247df08`,
TSAN `eae2a84aeffaa04e06d7f7732c8b814faf071524d5598ef15e9bd278a8c062c8`).
The default ORC RC leak suite, executable specs and broad `nimble test` pass. Full
`nimble threadcheck` passes on the binding-ticket core, including the ABI 6 C
fixture, native ingress, workers, owned Client and the standard RC suite.
The managed and AAR-0 sanitizer runners also pass on this core source.

A fresh instrumented wasm build from the binding-ticket core source has SHA-256
`2e6ff9da5a3d1c0787ccd402ec88a78c304f13d80d61002b0e24253853b87414`.
Node passes all 70 ABI cases. Google Chrome for Testing 147.0.7727.15 passes
the 30 shared browser cases and lifetime controls: all managed classes and
occupied heap are flat at sampled checkpoints, stale handles are rejected,
live handles finish at zero, and the server shuts down gracefully with no
pending cleanup, resource, lease or forced-connection count. Artifacts/reports
are under `tmp/wasm-managed-binding-qualification/`; tracked `web/gene.js` and
`web/gene.wasm` were not regenerated. The managed Nim SDK itself is not linked
into this wasm artifact.

## Unqualified paths

The managed API is not yet a replacement for all 35 legacy `GeneApi` entries.
Managed Actor worker execution, typed foreign Task failures, installed
extensions and arbitrary direct Nim APIs require further managed adapters and
race/lifetime controls. Mutable shared Buffers and Gene worker handoffs lack a
complete snapshot and ownership policy. Raw VM input before
`geneManagedRootFromVm` is trusted to be owner-confined; an arbitrary
pre-existing foreign Nim ref cannot gain a retrospectively tracked lifetime.
Code subclasses, opaque continuations, native cleanup requiring Gene worker
progress and mutable shared graph snapshots remain excluded. No profile stage
is promoted; Linux and the SERVICE heartbeat investigation remain deferred.
