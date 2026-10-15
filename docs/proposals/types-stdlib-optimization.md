# Typed boundaries and standard-library dispatch

Implemented the scoped plan in `tmp/optimization.md`. Gene keeps its dynamic
type contracts while avoiding unnecessary boundary work and stdlib-call setup.
The verified release is installed at `bin/gene`.

[Measurements, provenance, raw results and verification logs](../../benchmarks/baselines/2026-10-14-types-stdlib/README.md)
are retained with the benchmark baselines. Results are from one macOS/arm64
workstation and one paired set of release builds; they are workload-specific.

## Changes

| Step | Implementation |
| --- | --- |
| 0 | Matched typed/untyped operation rows and a Gene runner with rotating fresh processes, warmup exclusion, result checks, source/binary hashes, gross/net distributions. Harness runs use snapshots and support 100/200-turn comparisons against identical source. |
| 1 | Boundary labels are rendered only on failure. Scoped wrappers borrow names safely during checking; nested adapters borrow active label frames. Return frames reuse their function name. |
| 2 | Bare `Any` and satisfied exact-kind scalars bypass the general matcher at the supported boundaries. The definition shortcut is outlined to avoid inflating the interpreter dispatch body. Store ownership, strict checks, metadata, stamps and pins remain intact. |
| 3 | Plain positional natives dispatch before general callable machinery for local/direct/stack call instructions. Operator shortcuts, operand ownership, native frame requests, suspension, and named/context fallbacks remain intact. |
| 4 | Compiler-qualified scalar/Any signatures use a shared positional binder that avoids generic argument processing and name-based slot lookup. Every typed slot keeps its contract, including captured/native writes. The existing typed-call scope lifecycle, names, return checks and budgets remain intact. |
| 5 | `opLoadStdlibPath` fuses static `gene` paths. Non-owning side caches guard the module binding and every namespace's name/slot stamps. Dynamic/message/special paths and unsupported traversal use existing behavior. Budget charges and failure order are preserved. |

GIR format is **32**. The codec validates the scalar-binding proof, static
selectors and extra-cache layout. Error analysis, macro environment retention,
closure/spawn capture analysis and loop-scope classification understand the new
load. AtomicArc retains its existing cache-disable gate.

The scalar binder is deliberately separate from `simpleCall`: scopeless
lowering has different proofs. Named/default/rest/generic/adapting signatures,
syntax functions and macro bodies retain the general binder. A mismatching
argument also falls back to it, preserving the original diagnostic.

## Measured outcome

Operation figures below are median gross nanoseconds per iteration, including
the loop. The retained report also includes net figures and every control row.

| Case | Baseline | Final |
| --- | ---: | ---: |
| Typed Int counter | 144 | 70 |
| Typed Float stores | 198 | 129 |
| Any call | 456 | 356 |
| Float parameter/result call | 389 | 359 |
| String parameter/result call | 441 | 411 |
| Mixed two-argument typed call | 430 | 397 |
| Stdlib-path native call | 184 | 118 |
| Native bound locally | 118 | 104 |

All six general-workload medians are no higher than the original baseline.
Integer/closure work is close; records, text indexing, JSON and event replay
improve. Small microbenchmark controls move in both directions, so this is not
an across-the-board opcode speedup claim.

Harness service medians are 7657→7507 ms for 100 turns and 17857→17754 ms for
200 turns, with identical checksums. This modest application effect is consistent
with the final profile's waiting/filesystem costs. No checkpoint frequency,
durability policy or scheduler wakeup behavior was changed.

## Verification and requirement audit

| Requirement / invariant | Evidence |
| --- | --- |
| Exact boundary error details, hints and return labels | New VM cases for complete failure records, anonymous/bytecode/native-callback returns, stream hints, fields and body indices; language specs |
| Scalar spellings and bare Any retain contracts/metadata | VM matrix for scalar definitions/stores, Any object identity and signature metadata, alias/refinement/optional/Cell fallback |
| Captured writes, native scope access and pooling | New scalar-binder cases for escaped setters, native parameter reads/writes and alternating pooled signatures |
| All ordinary call entries and general fallbacks | Direct, outer, computed, spread and callback cases; arity/named errors; callable/protocol language specs |
| Native ownership, re-entry, suspension and frame requests | New native bridge and heap-result tests; lifetime and ASAN gates |
| Cache invalidation and root isolation | Distinct roots, host-local `gene` shadows, root/member/intermediate replacement, slot writes, misses and non-namespace fallback |
| Borrowed cache lifetime at arbitrary path depth | Replacement plus GC at two and three levels; ORC, AtomicArc and ASAN cache suites |
| Budget and evaluation/error order | Expanded-vs-fused step-budget equivalence, missing-call argument ParseError precedence, cancellation/cleanup test and scheduler specs |
| AtomicArc compatibility | 428 VM cases with caches disabled and 50 real-worker cases |
| GIR compatibility and proof integrity | Format bump, round trips, stale-format rejection, corrupt scalar proof/path/offset rejection |
| Real application behavior | 254 Harness cases, paired 100/200-turn workloads, checksum equality and exact patch-content assertions |
| Measured benefit and broad performance checks | Paired operation, six general-workload and Harness distributions with source/binary provenance |

Final gates: **428 ORC VM**, **428 AtomicArc VM**, **892 language specs**,
**90 lifetime**, **50 real-worker**, and **254 Harness** cases passed.
AddressSanitizer passed the **25 new boundary/call/cache cases**. A later
third-level cache assertion passed the eight cache cases under ORC, AtomicArc
and ASAN; production code remained unchanged. Source hashes match the measured
binary. The installed CLI passed a scalar/native smoke expression and all 31
operation rows at a small iteration count.

Final executable SHA-256:
`193173af215b1ba6592963ac775637110d4bf22352fedc6266eb8546d1ba6c87`.

## Decisions and remaining scope

An initial owned-string label representation was discarded after measurements
showed no gain: generated C copied names and replaced the avoided allocations.
The scoped borrowed representation removed that work. An inline definition
shortcut inflated the dispatch body and regressed untyped controls; outlining
it removed the consistent regression. The scalar-binding flag uses trailing
Boolean padding to preserve existing hot field offsets.

The pre-existing Harness receipt-retention fix and regression test were kept;
`$drop` is skipped while no truncation is necessary. Stale Miclone references
in two qualification checks/docs were corrected to the current examples.

Deferred work remains outside this pass: general annotation descriptors,
parameter-boundary storage redesign, complete native signatures/effects,
compile-time member errors, effect-based scope reuse, constant folding,
container membership caches, C-backend entries, fused resolve-and-call, broader
frozen proofs, scheduler wakeups and checkpoint policy changes.

A baseline probe exposed a separate issue: typed `Cell.set` raises its boundary
error, but nominal `catch TypeError` did not catch it in a bare eval application.
That behavior predates these changes and is recorded for a separate error
identity/scope investigation. This pass preserves its existing behavior.
