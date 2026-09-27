# AtomicArc native entry admission — 2026-09-27

This continues [publication guards](native-app-2026-09-27-atomic-publication.md)
with qualification-only admission for selected SDK entries. It does not complete
the full AAR-1 managed-borrow contract or enable shared/activation/production
retirement. The [proposal](../proposals/atomic-arc-retirement.md) records the
implemented phases and remaining ownership requirements.

## Implemented boundary

`src/gene/retirement_native_gate.nim` coordinates SDK root create/get/release and
native module create/value/Scope/define calls with released-generation analysis.
The VM pauses workers before sealing native admission. Only outermost native
entries count globally; admitted entries can finish nested SDK operations.
Late entries wait during analysis. Nested seals retain closure, and analysis
inside an enclosing native seal or native entry defers without waiting for itself.
The gate uses one conservative process-wide domain, not per-application domains.

Calls that may invoke cleanup needing root-lane progress defer collection.
An admitted entry can upgrade to that class while the collector drains it;
the collector then reopens admission and defers. This prevents native release
from waiting for an acknowledgement that the collecting root cannot provide.

Once all candidate Scope edges detach, admission reopens before last-owner
cleanup. A collector reservation prevents another collection until cleanup ends.
Both owning-thread SDK cleanup and foreign SDK callbacks can finish without a
callback running under the gate mutex or behind its own admission fence.
Worker admission remains governed by the existing VM pause. Cleanup needing
arbitrary Gene execution/worker progress or resurrection remains unqualified.

The entry leases stop at the API return. Raw returned Values and Scopes remain
permanently published; the gate is not mutual exclusion for handle fields or
mutable containers. Concurrent get/release on one SDK root and unmarked direct
Nim ref transfers remain unsupported by the experiment. Normal builds contain
neither this gate nor a new SDK ownership/access policy. API versions/signatures
and Gene syntax are unchanged.

## Publication inventory extension

The opt-in VM code walk now follows the object Value-edge inventory, reaching
Type methods/constructors/core witnesses and wrapper-held functions. It follows
borrowed nominal identities, error annotations/proof targets/return contracts,
declaration metadata, rest annotations, super identities, derived chunks,
nested constructors/inline impl operands, monomorphization arguments, web forms
and native layout field expressions. Visited prototype identities bound recursion
through headers, summary targets and Scope bindings.

Native module handles publish their Scopes and defined Values before exposure.
Prepared synchronous native callbacks separately publish target and dispatch
Scope, including a native handler with no lexical capture. Metadata must be
live and owner-confined before handoff. Opaque code subclasses, continuations,
canonical shared collection and arbitrary native callbacks remain separate gates.

## Regression controls

The suite expands from 19 to 30 opt-in cases. New controls cover:

- Existing native entries draining before private generation analysis.
- Late SDK entry waiting through nested seals and subsequent successful retirement.
- A native release requiring root acknowledgement upgrading a draining entry,
  forcing collection to defer until the root can provide that acknowledgement.
- Self-entry collection deferral, SDK failure unwinding and analysis reentry rejection.
- Owning-thread SDK cleanup and a foreign SDK callback after Scope edges detach.
- Type method code, declaration/error metadata, nested constructor and derived-chunk
  environments remaining published after their SDK root drops.
- Native module handles and prepared synchronous callback dispatch Scopes
  remaining pinned after their named handles drop.

Test-owned published graphs are explicitly torn down after controls finish. This
is not eventual shared reclamation. The Gene runner retains separate bounded
disabled/probe/ASAN/TSAN builds, commands, hashes and logs under
`tmp/atomic-retirement-qualification/`. Native synchronization and ownership
fixtures remain Nim because they exercise the SDK and foreign threads directly.

On Nim 2.2.4/macOS arm64, the final fixed-source run passes normal-disabled
(2 cases), opt-in (30), ASAN (30) and targeted TSAN (10), with no timeout or
truncated output. All seven managed classes remain flat at 683/693/683 for
private namespace/scalar/private Type generation batches. Namespace/scalar
batches reach 10,000, and Type release/discard/failed-prepare batches reach 1,000.
Canonical impl publication still reports `qualified: false`, retaining 63 Values.
Executable specs, the separate-cache ORC RC suite and default AtomicArc
`threadcheck` pass; logs are `native-admission-{spec,leakcheck,threadcheck}.log`.

| Mode | SHA-256 |
| --- | --- |
| Disabled | `5a4293266594efa774bbb494b73d52f07b9a4fbdffcada3207b7de78b7639241` |
| Opt-in | `f1c4d854c9ab1e18cc15a7b44dce03cbdf7e1463d2143abc0fe3a917f85a586b` |
| ASAN | `3b7135fe1d786c4c7cb2fca0cfb5a4909384523c2324c3c4e7286cd0c9862894` |
| TSAN | `72789230e4fd1fcb73e7c5f77a52a553f865fcfe898c5e4b8c830590adf4fa38` |

## Next boundary

Complete native API/exposure integration and review an additive managed-borrow
contract before changing public SDK ownership/access behavior. The current gate
does not span accesses to raw returned objects, and permanent pins cannot be
removed on its evidence. AAR-2 published graph reclamation and AAR-3 activation
handoff remain separate. Linux and the SERVICE heartbeat investigation stay
deferred; no profile stage is promoted.
