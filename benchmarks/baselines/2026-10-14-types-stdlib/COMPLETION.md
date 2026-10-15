# Completion audit — 2026-10-15

Objective: implement the scoped steps 0–5 in `tmp/optimization.md`. The deferred
ideas in section 7 remain outside this implementation.

- Step 0: matched operation rows, Gene orchestration, identical Harness inputs,
  snapshot repair, retained raw outputs and build provenance verified.
- Step 1: lazy labels inspected in source and generated C; exact error records,
  hints, return paths and borrowed lifetimes verified by VM/spec/ASAN cases.
- Step 2: scalar/Any shortcuts preserve metadata and store machinery; all scalar
  spellings, identity, mismatch, alias/refinement and adaptation cases verified.
- Step 3: native dispatch preserves ownership, operator fallback, named/context
  calls, re-entry, frame requests and suspension; dedicated tests and gates pass.
- Step 4: scalar binder retains activation contracts, names, scope lifecycle,
  callback/spread/outer call behavior and return/budget paths; GIR proof checked.
  The final flag placement preserves existing hot field offsets.
- Step 5: fused loads preserve root/shadow/namespace lookup, fallback and error
  order; name and slot invalidation, deep release/replacement, budget equivalence,
  cancellation, worker behavior and GIR layout rejection verified.
- Final gates: ORC VM 428; AtomicArc VM 428; language specs 892; lifetime 90;
  real workers 50; Harness 254. ASAN new cases 25 and deeper-cache cases 8 passed.
- Performance: complete paired operation distributions retained; six general
  medians are no higher than the original baseline; 100/200-turn service medians
  improve modestly with identical checksums. Small micro controls move both ways
  and are disclosed. No universal speedup or zero-cost-type claim is made.
- Final current-workload profile captured and summarized; sampled timing is
  excluded from performance comparisons.
- Production source hashes match the measured release. `bin/gene` has the same
  SHA-256 and passes the installed CLI smoke expression and 31 operation rows.
- New Gene tools are formatter-idempotent; `git diff --check` passes. Selected
  evidence is retained here without binaries, compiler caches or workspaces.
- Pre-existing receipt-fix edits are preserved.

The implementation report links every invariant to its code/test evidence.
No required implementation or verification work remains pending.
