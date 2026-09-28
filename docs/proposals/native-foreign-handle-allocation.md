# Foreign-created managed handles under AtomicArc

**Status:** owner decision required before AAR-1 foreign ownership transfer or
AAR-2 shared reclamation can be promoted. No production allocator or ABI
behavior changes are made by this proposal.

The single `GeneApi` currently lets an attached C lane call `retain` and
frozen `traverse`, returning a new numeric owning ID. Its managed registry is
a Nim `Table[uint64, ManagedEntry]`. A new entry and a growing table can use
the creating thread's Nim allocator. If that C thread exits while the ID or
expanded table remains, later root-lane release/destruction accesses allocator
storage already freed at thread exit. Atomic reference counting does not make
that allocator lifetime safe.

## Reproduction and boundary

The compiled C fixture retained an Int ID on an attached thread, detached and
joined that thread, then released the new ID on the root lane. Default
`--mm:atomicArc --threads:on` under ASAN reported a heap-use-after-free in
`apiRelease` / Nim allocator deallocation. Sharing the original root's
`ManagedEntry` avoided that single-entry failure but **did not** solve the
boundary: retaining 2,048 IDs forced the registry table to grow on the foreign
thread, and root-lane teardown again triggered an ASAN use-after-free. The
experimental entry-sharing code was reverted.

The same 2,048-ID transfer passes under
`--mm:atomicArc --threads:on -d:useMalloc`, with the original registry code,
under both ASAN and TSAN. The 39-case opt-in managed AAR probe also passes in
that allocator mode. These focused results establish an allocator-sensitive
failure and a viable candidate policy; they do not qualify every foreign
constructor, traversal, owner drop, or production workload. Reproduction logs
are in `tmp/native-task-producer-qualification/`:
`abi-transfer-asan-run.log`, `abi-transfer-many-asan.log`,
`abi-transfer-malloc-asan-run.log`, `abi-transfer-malloc-tsan-run.log`, and
`native-malloc-probe.log`.

The committed C fixture exposes `gene_test_api_transfer_many`; its test runs
the transfer only when `useMalloc` is defined. Default AtomicArc's existing
same-lane read/retain/release tests remain enabled. Passing them does **not**
authorize cross-lane ownership transfer or unbounded foreign registry growth.

## Decision options

| Option | Contract and work | Tradeoff |
| --- | --- | --- |
| **A. Use system malloc for qualified AtomicArc native apps (recommended)** | Make `useMalloc` an explicit build/profile requirement for applications advertising foreign ID creation/transfer. Record it in runtime identity and package metadata; run foreign retain, traversal, wrapper/result, installed-module, 1/100/1,000/10,000, ASAN/TSAN and performance gates before promotion. Keep numeric GeneApi version 6 and negotiate the owning capability with a feature bit. | Smallest ownership implementation; changes allocator policy and requires platform/performance qualification. |
| B. Root-owned bounded registry | Allocate stable slots/table capacity on the root lane, reserve them before foreign access, and defer all last-owner cleanup to the root. Define capacity/backpressure and refill behavior when a foreign lane exhausts slots. Qualify every path that creates an ID, not only `retain`. | Preserves default allocator; adds a bounded public behavior and substantial registry/scheduler complexity. |
| C. Restrict foreign ID creation for now | Reject attached-lane `retain` and handle-producing traversal while keeping copied reads, Task settlement and byte ingress. Add an explicit feature bit so C modules can detect the restriction. | Safe interim boundary but reduces the advertised attached-lane API. |

Option A is the recommended next experiment for this greenfield project. It
does not itself approve production shared reclamation. First qualify the
allocator policy on macOS arm64, then on native Linux x86_64 when that
platform gate resumes. A build without the selected policy must not advertise
cross-lane owning transfer as qualified. Existing raw Nim `Value`/`Scope`
exports remain permanently published or excluded under the opaque-handle
contract, regardless of allocator choice.

The owner must select the policy because it changes the public meaning of an
attached owning handle or the supported AtomicArc build configuration. After
selection, implement only the chosen capability gate and test matrix before
attempting AAR-2. The current default build retains its conservative
publication behavior; no AAR-2 or AAR-3 collection is enabled by this record.
