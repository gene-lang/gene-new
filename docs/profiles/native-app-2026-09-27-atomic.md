# AtomicArc retirement experiment — 2026-09-27

Normal AtomicArc retirement remains disabled. This checkpoint implements AAR-0
of [the staged design](../proposals/atomic-arc-retirement.md): an opt-in experiment
for unpublished released generations under an actual paused-root boundary.
It does not promote VM-2, shared collection, or worker activation retirement.

## Implementation and repairs

- A read-only, acquire-loaded AtomicArc header adapter uses one RC word and a
  three-bit shift. Its own layout probe passes; ORC still uses its two-word,
  four-bit adapter. A hybrid/mismatched qualification build is rejected.
- The qualification flag requires genuine AtomicArc, threads and RC stats.
  Only generation passes inside the VM's paused-root boundary may run.
  Activation retirement remains unavailable even in the experiment.
- Published Values stay pinned; their mutable owning edges are not counted.
  Foreign native threads are not stopped by a scheduler worker pause.
- The module pause now tracks nesting. A non-owner lane is rejected instead
  of waiting for its own Fiber to leave execution.
- Worker teardown remains visible after bytecode completion. The local owner
  drops first, then the scheduler owner releases outside its lock under a
  retiring marker. Progress and pause checks include that marker.
- Nim 2.2.4 inferred a retiring temporary's nil assignment as an overwrite.
  An explicitly owned reference plus `reset` preserves real destruction. The
  existing typed-Task failure string-lifetime case catches the lost owner.
- Instrumented managed counters use atomic updates/reads in threaded builds.
  Cross-class snapshots still need quiescent checkpoints.

The initial ThreadSanitizer run reported root/worker allocator access after the
old inactive acknowledgement. The final active-worker and foreign-reader tests
pass with actual Fiber destruction before acknowledgement. The temporary lost
owner also appeared as a one-string typed-Task leak with workers enabled; that
existing RC regression passes after the explicit reset.

## Bounded evidence

Nim 2.2.4, macOS arm64, genuine AtomicArc, threads on, RC instrumentation:

| Class | Evidence | Limit |
| --- | --- | --- |
| Private namespace cycles holding managed payloads | All seven classes flat at live 683 through 1/100/1,000/10,000 retirements after warm-up. | Synthetic closed Scope/Namespace graph. |
| Scalar sandbox generations | All classes flat at live 693 through 10,000 retirements. | Unpublished scalar generation. |
| Private Type/direct-method generations | Release, discard and failed prepare hold all classes flat at live 683 through 1,000 batches of all three forms. | No canonical impl publication. |
| Retained private instance | Its method still returns 7 after generation release; dropping it returns pending roots to baseline. | Root-lane retained control. |
| Private/native outside roots | Candidate stays live and usable while held; dropping the private/native root permits retirement. | Does not qualify arbitrary foreign Nim reference transfer. |
| Running workers/nested pause | Ten worker runs finish before analysis; nested resume preserves the outer pause. | Gene Fiber quiescence, not all native work. |
| Published native reader | 1,000 collection attempts preserve a concurrently read namespace. | Permanent publication pin, not eventual collection. |
| Canonical Type/protocol/impl generations | Remain retained; output explicitly says `qualified: false`. | Shared reclamation is still open. |

The Gene harness runs separate disabled, opt-in, ASAN and targeted TSAN binaries
with hard deadlines and logs. Normal-build negative controls prove that the
experiment is not silently enabled. Opt-in and ASAN pass the private/control
matrix; TSAN covers the active-worker and foreign-reader cases. Existing spec,
ORC leakcheck and default AtomicArc threadcheck pass.

Local reports, hashes and build commands are recorded in
`tmp/atomic-retirement-qualification/report.json`; per-mode logs accompany it.
Reproduce with:

```sh
nim c --threads:on --path:src --hints:off -o:tmp/gene-qualification src/gene.nim
tmp/gene-qualification run tests/qualify_atomic_retirement.gene --asan --tsan
```

## Next gate

AAR-1 must inventory and fence foreign publication/access, including native roots
and public Nim Scope refs. Atomic counts read at different instants do not form a
consistent ownership snapshot. Permanent publication pins may only be replaced
where a complete edge model and native/worker quiescence are proved. Public SDK
ownership changes need owner review before implementation. Other continuations,
worker-local activation cycles, Linux and the SERVICE heartbeat investigation
remain separate gates. No profile stage is promoted.

The subsequent [AAR-1a publication audit](native-app-2026-09-27-atomic-publication.md)
records the mutable-Scope exclusion and expanded race controls. In that later
experiment SDK roots stay pinned after release; the private/native-root release
control above describes the earlier AAR-0 checkpoint. Native borrow quiescence
and shared reclamation remain open.
