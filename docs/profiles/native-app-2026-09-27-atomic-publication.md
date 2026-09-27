# AtomicArc publication guards — 2026-09-27

This continuation implements AAR-1a, the conservative publication portion of
[the staged retirement design](../proposals/atomic-arc-retirement.md).
Normal AtomicArc and activation retirement remain disabled. AAR-1b native borrow
quiescence, published reclamation and profile promotion remain open.

## Change

The previous experiment pinned shared Values but still expanded a pending root's
Scope tables. A foreign lane could mutate those tables while the root lane counted
their entries. Scope publication is now recorded before known handoffs, including
lexical ancestors and weak defining environments. Published Scope tables are not
enumerated; a published pending root conservatively retains its entire batch.

The opt-in build treats SDK root creation as publication of the known Scope/code
graph. Releasing a root does not revoke copies previously returned by `rootGet`,
so publication pins remain after release. Ingress subscription creation records
its dispatch Scope even when the native handler has no lexical capture. Existing
v5 byte ingress keeps its independent admission/in-flight fence and physical
retirement rules. Neither fence claims to cover arbitrary foreign Gene access.

The VM publication walk also follows functions inside Set/HashMap/callable-view/
Cell wrappers, and the opt-in Scope walk includes module refs, fallbacks, pending
Types, cleanup Tasks and impl assembly environments. Known compiled constants and
default bodies are visited through the existing Chunk/FunctionProto walk. This
is an inventory improvement, not a complete model for arbitrary compiled-code
subclasses or continuations.

## Qualification matrix

The bounded Gene runner retains the original private-generation/control matrix
and adds six cases:

- SDK publication after root release (updates the existing native-root control).
- Weak defining Scope and ancestor publication.
- Mixed private/published batch retention.
- Scope references reachable through compiled constants.
- Foreign table growth/deletion during 1,000 collection attempts.
- Foreign function retain/drop transfers after SDK root release during 1,000
  collection attempts.
- An admitted C ingress callback during 1,000 attempts; close rejects new entry,
  subscription release fails until the admitted callback ends, and physical
  retirement then succeeds.

The first item replaces a previous case; the other six expand the opt-in suite
from 13 to 19 cases. Published controls deliberately tear down their test graphs
after foreign lanes join. That cleanup is not collector evidence.

Results and commands are recorded in
`tmp/atomic-retirement-qualification/report.json`, with separate disabled,
probe, ASAN and TSAN logs. The sanitizer selection includes the original worker
barrier/foreign reader and the new writer, transfer and late-ingress cases.

On Nim 2.2.4/macOS arm64, the final bounded run passes disabled (2 cases),
opt-in (19), ASAN (19) and targeted TSAN (5), with no timeout or truncated output.
The seven managed classes remain flat at live 683 for private namespaces and
private Type batches, and 693 for scalar generations. Namespace/scalar batches
reach 10,000; Type release/discard/failed-prepare batches reach 1,000.
The canonical impl control still reports `qualified: false` and retains 63 Values.

Binary SHA-256 values:

| Mode | SHA-256 |
| --- | --- |
| Disabled | `cd53fd5d2919cad5b363742f2a4255bd9e1304ee7290d91e848713ef321fc73e` |
| Opt-in | `234715b0f93a84575d0d0accbbb9cdb3b4a8ded52c78c869b7d6ce134a1e7caa` |
| ASAN | `c0d4ec9993c60c3c26db6162ce5ca76cd6ae911377caac04eaf99120a2719f36` |
| TSAN | `920e8b14c645e78b6e7f823b1026e0503bd295ac940091771167d14537a3475b` |

Executable specs and the ORC `test_rc` leak suite pass on the final source tree;
their logs are `provenance-spec.log` and `provenance-leakcheck.log` in the same
qualification directory. The ORC check uses a separate output/cache so it cannot
overwrite the concurrent AtomicArc threadcheck binary.
The full default `nimble threadcheck` also passes, including native ingress,
workers, owned HTTP Client and the final AtomicArc RC suite; its log is
`provenance-threadcheck.log`.

## Remaining work

The proposal inventories known worker, canonical impl, SDK root/callback, ingress,
native Scope/environment and direct Nim exposures. It specifies a future native
borrow domain with sealed admission, active-borrow draining, nested/self-entry
handling and cleanup outside locks. That borrow domain is not implemented.

An API-call fence cannot cover a raw Value that escapes `rootGet`. Public SDK
ownership/access changes require owner review before implementation. Arbitrary
unmarked Nim ref transfers, concurrent get/release of one SDK root, opaque code
and continuations, mutable shared collection and activation retirement remain
unqualified. Linux and the SERVICE heartbeat investigation remain deferred.
