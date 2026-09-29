# Foreign-created managed handles under AtomicArc

**Status:** the owner selected B, a root-owned bounded registry. The C numeric
ID path is implemented under default AtomicArc. Direct Nim wrapper transfer,
arbitrary foreign Nim refs, and AAR-2 shared reclamation remain unqualified;
this does not enable production collection.

Before B, the single `GeneApi` let an attached C lane call `retain` and
frozen `traverse`, returning a new numeric owning ID in the ordinary
`Table[uint64, ManagedEntry]`. A new entry and a growing table could use
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

The C fixture exposes `gene_test_api_transfer_many`. With B, the default
AtomicArc build transfers 10,000 IDs to the root under ASAN, using the same
numeric ABI and default allocator. A four-worker 2,048-ID control passes ASAN
and TSAN, including simultaneous inserts into the root-reserved index. A
two-slot control rejects the third retain, then recycles the slots after root
release; stale IDs stay invalid. Root-lane growth preserves IDs that were
already live. An attached lane can retain a foreign-created ID again, or
traverse a frozen parent, and the resulting ID remains readable after the
parent ID is released and the worker exits. A separate
managed SDK test keeps a foreign-created ID borrowed while the root releases
it; root polling reclaims its slot only after the borrow exits, under ASAN and
TSAN. A private-Scope control also retains its known provenance through a
foreign ID and in-flight borrow; the Scope retires only after root polling
releases that slot. The full managed probe passes under ASAN. The original
failure logs remain historical evidence for the selected design.

## Decision options

| Option | Contract and work | Tradeoff |
| --- | --- | --- |
| A. Use system malloc for qualified AtomicArc native apps | Make `useMalloc` an explicit build/profile requirement for applications advertising foreign ID creation/transfer. | Smaller registry implementation but a global allocator and package-build policy change. The focused experiment passed; this option was not selected. |
| **B. Root-owned bounded registry (selected)** | Root-lane `reserve_foreign_roots` provisions stable entries and an oversized index before attached access. A foreign operation fills a free slot or returns a copied capacity diagnostic without consuming its source. Release invalidates the ID immediately; root polling defers last-owner cleanup until borrows end, then recycles the slot. | Preserves the default allocator; requires an explicit capacity and root progress for reuse. |
| C. Restrict foreign ID creation for now | Reject attached-lane `retain` and handle-producing traversal while keeping copied reads, Task settlement and byte ingress. Add an explicit feature bit so C modules can detect the restriction. | Safe interim boundary but reduces the advertised attached-lane API. |

The selected C entry is `reserve_foreign_roots(context, absolute_capacity,
diagnostic)`, advertised by `GENE_API_FOREIGN_ROOTS_FEATURE = 1024` only in a
threaded AtomicArc table. It is root-lane-only and permits capacities 1 through
`GENE_FOREIGN_ROOT_MAX_CAPACITY` (65,536). A module reserves before starting
attached workers, then checks the
feature bit and `struct_size` as for every optional entry. Slots and index
buckets are allocated on the root lane; attached operations never grow them.
Each slot holds a root-allocated entry and a reference to the original
root-owned provenance entry; it does not copy a Nim Scope sequence on the
attached lane. An early ASAN control caught that second allocator hazard,
and the root-owned provenance link removed it.
An exhausted pool returns `GENE_API_ERROR` and a copied capacity diagnostic.
The caller can release IDs and let the root poll recycle slots, or request a
larger absolute capacity on the root lane. Numeric IDs remain monotonic, so a
reused slot never revives a stale ID. `NativeModule.status` reports
`foreign_roots`, `foreign_pending`, and `foreign_capacity`.

This qualifies the C numeric-ID transfer boundary only. A Nim
`GeneManagedRoot` wrapper itself allocated on an attached thread is still a
Nim ref and must not be handed to the root after that thread exits. The
arbitrary raw `Value`/`Scope` exports remain permanently published or
excluded under the opaque-handle contract. Complete AAR-1 native graph
inventory, mutable snapshot policy, and the AAR-2/3 lifetime matrices are
separate gates. Native Linux x86_64 qualification remains owner-deferred.
