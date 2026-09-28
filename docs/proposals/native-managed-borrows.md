# Native managed borrows

**Status:** the project owner selected opaque managed handles on 2026-09-27.
The additive ownership/borrow, copied-read, frozen-container, managed-call,
environment and explicit legacy-export core is implemented in
`src/gene/native_managed.nim`. Initial managed wrapper/owned-pointer, private
Buffer, Channel, Actor and external Task adapters are implemented. The Actor
adapter owns message tickets through the mailbox and parked handler Fiber,
and transfers returned-state provenance into the Actor. Managed Actor handlers
remain on the root lane until AAR-3 worker allocation lifetimes are qualified.
Installed-extension integration,
complete shared mutation/worker handoff policy, and AAR-2 qualification remain
open. This is the remaining
native ownership program for AAR-1 in
[AtomicArc generation retirement](atomic-arc-retirement.md). Existing SDK v4/v5
and Gene syntax stay unchanged. Production/shared retirement remains disabled.
The additive installed-extension contract is specified in
[Managed native extension ABI](native-managed-extension-abi.md).

## Problem and decision

SDK entry admission ends at API return. `geneRootGet`, `geneModuleScope`, VM
`run`/`call`, and ordinary Nim `Value`/`Scope` fields allow native code to retain
and transfer references afterward. A returned raw Value cannot be made a tracked
borrow by changing an internal mutex. Atomic reference counts do not report the
interval in which a caller reads or moves graph edges.

Choose one ownership contract before removing publication pins:

| Design | Enforcement | Consequence |
| --- | --- | --- |
| **Recommended: opaque managed handles** | SDK operations mediate all Gene graph access; exporting a raw ref switches the affected graph to permanent publication. | More SDK operations, but an enforceable lifetime boundary and a path to eventual collection. |
| Scoped raw Value borrows | Caller promises not to retain, store, transfer or access a raw ref after the borrow ends. Nim cannot enforce this promise for `Value.bits`, Scope fields, captured closures or foreign memory. | Smaller API, but shared collection depends on a new explicit unsafe native-code contract. |
| Keep existing raw SDK only | Retain existing permanent pins. | No ownership migration, but published generation lifetime stays unqualified; AAR-2 cannot be enabled. |

The selected design follows below. The existing raw SDK does not gain this
contract or a new interpretation of its results.
Enforcement concerns supported SDK operations; arbitrary unsafe native memory
access or casts remain outside the runtime's ownership guarantees.

## Opaque handle contract

Use an additive SDK surface, separate from the legacy `GeneRoot`/`GeneResult`
procedures. The following Nim SDK spellings are implemented; they are not Gene
syntax:

- `GeneManagedRoot`: an owning, opaque handle to a Value or environment in one
  stable runtime domain. It exposes no `Value`, `Scope`, raw bits or object field.
- `GeneNativeBorrow`: a lane-bound, scoped admission lease. It owns its root
  entry; operations retain other handle inputs for their call extent and upgrade
  admission when root-lane progress may be needed. The lease cannot be
  transferred to another lane.
- `GeneManagedResult`: status/message plus owned value/error handles. It must not
  contain the legacy raw `GeneResult.value` or `errorValue` fields.
- `GeneManagedEnvironment`: an opaque dispatch Scope holder.
- `GeneManagedTask`: an external producer ticket. `GeneManagedAck` and
  `GeneManagedReceive` return copied status plus, for receive, an owned handle.

`geneManagedRoot` creation consumes an owning reference through a participating
VM boundary **before foreign handoff**. It must not accept an arbitrary raw
foreign Value and pretend its earlier transfers were fenced. A root exported
through legacy SDK APIs remains permanently published. Moving an already
published graph into a managed handle does not undo publication.

The initial `geneManagedRootFromVm(domain, scope, value)` adapter requires the
runtime root lane, one application, and an owner-confined value at that handoff.
It cannot prove where a caller previously obtained an arbitrary Nim `Value`;
direct/unmarked Nim transfers remain outside qualification. The SDK's managed
operations themselves accept only opaque handles.

`geneWithNativeBorrow(root, body)` admits one outer borrow; nested managed calls
share that admission. Handle traversal returns more opaque handles, not raw
Values. Scalars, copied text/bytes and copied diagnostics may leave the borrow.
The whole callback is classified as requiring root-lane progress: caller code
can wait outside any SDK getter. A collector defers rather than draining such a
callback while blocking the root lane it may need.
An object returned by a Gene call leaves as an owned managed handle. Access after
lease end, wrong-lane access and use of released handles fail before reading Gene
memory. Separate owned handles may be sent to another attached native lane; the
receiver starts its own borrow before traversing them.

Legacy interoperability is explicit: `geneExportManagedRoot` publishes the entire
known Scope/code graph before returning a legacy `GeneRoot`. A corresponding
environment export publishes its Scope graph. That transition is irreversible
for this collector. Avoid a general raw `get` on managed handles.

Handle identity must be stable across registry growth. Physical release removes
the owning registry reference outside the registry/admission locks; stale IDs
must never resolve to a reused object. Domain lifetime must outlive all handles,
leases and queued native completion/cleanup records. Runtime shutdown closes new
admission and drains those owners before destroying the domain.

## Native API inventory and integration

The source of truth is `src/gene/native_api.nim`'s 35-entry `GeneApi` table plus
its separately exported module/ingress and VM callback APIs.

| Existing paths | Current qualification coverage | Managed counterpart requirement |
| --- | --- | --- |
| Root create/get/release | Entry gate and permanent Scope/code publication. | Own/release opaque roots; traversals require a lease; legacy export publishes. |
| Module create/value/Scope/define, defineNative/defineNativeCall | Base module entries gated; returned raw Scopes and defined Values published. | Opaque environment handles; definitions take managed handles and native callback registrations. |
| `geneCall`, callCallback, VM synchronous callback APIs | Prepared callback target/dispatch Scope publication; trampoline execution is not a complete managed borrow. | Managed arguments, environment, result/error handles; defer collection for calls needing VM/root progress. |
| Wrapper type/newWrapper/wrapperField | Legacy raw Type/Node/prop Values. | Schema and props use handles; field reads return handles. Preserve nominal identity validation. |
| CPtr/CConstPtr/OwnedPtr/close/CSlice | Raw Gene wrappers and independent foreign ownership policies. | Handle wrappers; physical address/span borrows retain their existing resource tickets. No promise to trace Gene refs hidden in foreign memory. |
| Buffer new/len/get/set | Raw buffer/items and typed Scope input. | Copy scalar storage or return item handles; mutation observes both borrow admission and existing type checks. |
| Channel trySend/tryRecv and actor trySend | Root-based input but raw outputs/Scope arguments; only nested root accesses currently fenced. | Enqueue owned handles/Values under admission; native queue owns them until physical dequeue/drop. Receive returns handles. Preserve Send/type/queue policies. |
| Async Task create/complete/fail/cancel | Raw Tasks/results and native completion lifetimes. | Task/result/error handles retained through physical completion; cancellation does not prematurely end ownership. |
| Module init/load/versioned and v5 ingress subscriptions | Legacy module pointers; ingress owns rooted handlers/libraries and dispatch Scope. | Initializer/export environment handles; callback/registration contexts own handles until physical unregistration and zero in-flight work. Byte-only ingress remains separate. |
| Thread attach/detach and logging | No direct Gene graph returned by these entries. | Associate leases with attached lanes; copied diagnostic payloads require no Gene borrow. |
| Direct Nim VM/Scope/Value APIs and custom `FunctionCode`/continuations | Arbitrary unmarked refs remain outside qualification. | Keep legacy accesses published/unqualified. Require explicit adapters and complete edge models before admitting any additional graph class. |

The initial Actor adapter is `geneManagedNewActor(environment, capacity,
state, handler, messageType?)`, `geneManagedActorTrySend(actor, message,
environment)`, `geneManagedActorState(actor, environment)`, copied
`geneManagedActorStatus`, and `geneManagedActorClose`. Its handler uses
the existing Gene `ActorStep` return convention. The constructor retains
state, handler and optional contract provenance; accepted messages own Scope
tickets while queued and while a handler Fiber is running or parked. On
`$actor/continue`, the new state obtains its own ticket before the message
ticket drops. State reads snapshot the Value and ticket under the Actor lock
before creating an opaque result. The existing Send, capacity and closed checks
still apply. Close drains queued messages and rejects new sends; an already
running handler completes under the existing Actor lifecycle rule. A complete
policy for arbitrary shared mutable Actor graphs and safe worker-produced Value
ownership is still needed before this family is considered fully migrated.
Gene-facing `snapshot` is a raw export and permanently pins any weak state
provenance it returns. `upgrade` and implicit `ActorRef T` contract narrowing
replace managed ownership tickets on the root lane; these mutations reject a
worker-lane call until worker-produced graph ownership is qualified.

Managed environment definitions now transfer their known weak/code Scope
provenance into a per-name binding ticket on the target Scope and independently
into the returned handle. Gene `set`/redefinition releases the previous ticket
after replacing the Value, including mirrored-slot writes. The retirement
graph counts those Scope-to-Scope edges and detaches tickets with the retired
bindings. Direct Nim mutation of `Scope.vars` bypasses this mediated contract
and remains outside managed qualification.

Do not mechanically classify every SDK function as a blocking drainable borrow.
Constructors, mutation, trampoline execution and release can invoke cleanup or
need root/worker progress. The collector must defer for those active operations.
An admitted operation upgrading its progress requirement must wake a draining
collector and make it defer; nested calls must still be able to finish.

## Collector and cleanup ordering

1. Stop worker admission and wait through Fiber teardown.
2. Seal managed native admission. Drain only operations whose completion cannot
   depend on the collecting lane. Defer for owner-dependent work, self-entry,
   competing collection and enclosing analysis seals.
3. Count only graphs with complete provenance/edge models and a stable domain.
   Raw exports, mutable containers lacking a snapshot policy, opaque callbacks,
   code subclasses and continuations keep their exclusions.
4. Pin doomed owners, detach all candidate Scope edges, then reopen native
   admission before last-owner drops. Keep the collector reservation until
   physical cleanup ends. No callbacks run under registry/admission locks.
5. Restore worker/native admission in failure/refusal paths. Cleanup needing Gene
   worker execution requires a separate physical-retirement design; the current
   worker pause does not establish that contract.

This API decision alone does not qualify AAR-2. Provenance must include every
Scope/code/weak edge, mutation must follow each container's synchronization
policy, and managed-root/registry/queue owners must appear in the graph model.

## Implementation sequence and acceptance

1. After owner review, implement domain/handle ownership and borrow admission
   without enabling reclamation. Cover stale/repeated release, wrong lane/domain,
   shutdown, registry growth and cleanup outside locks.
2. Implement scalar/text/bytes and immutable container traversal, then managed
   call/result/error and environment APIs. Test returned-handle survival and
   explicit irreversible legacy export.
3. Adapt wrappers/resources, buffers, native queues/Tasks, callbacks and installed
   extensions. Retain each physical ticket through cancellation/unregistration.
   Preserve v4/v5 behavior; do not silently reinterpret old roots as managed.
4. Run foreign reader/retainer/drop-transfer, late callback, progress-dependency,
   nested/self-entry and shutdown races under supported TSAN. Native and ASAN
   must pass, with controlled failure unwinding and resource closure.
5. Only then run AAR-2 canonical/retained Type/function/instance, container/error,
   native handle and mutable snapshot matrices through 1/100/1,000/10,000 batches.
   Require all managed classes and pending roots to return to baseline after
   managed controls drop. Legacy export controls must remain usable and retained.

No production enabling or profile promotion is implied by this proposal.
