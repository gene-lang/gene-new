# General-purpose runtime optimization

Work branch: `perf/general-workloads`, based on runtime revision `f9d731c`.
The runtime implementation and regression tests are committed as `349dab2`.

The objective is to reduce ordinary application overhead without changing Gene
syntax, evaluation rules, ownership rules, or execution-policy enforcement.
The paired Gene/Python workloads live in `benchmarks/general/`; the real
Harness service probe exercises admission, model-free turns, transcript
snapshots, patch application, and durable completion.

## Implementation

- Simple `for` bindings avoid allocating a temporary pattern-match table.
  Destructuring still uses the complete matcher.
- An iteration can reuse its scope storage only when the compiler's existing
  non-capture analysis allows it and a runtime check positively proves unique
  ownership. Captures and native retained scopes prevent reuse. Unsupported
  refcount layouts and AtomicArc use fresh scopes. Bindings and annotations
  are cleared before reuse; stream, error, cancellation, and loop-exit handling
  keep their existing paths.
- Name lookup and namespace access borrow scope references during read-only
  walks. An owning caller still obtains an owning reference when it retains a
  namespace's scope. Regression coverage includes temporary namespaces and
  aliased lookup output.
- Immediate scalar assignments avoid constructing an error label for an
  authority/construction check that cannot reject an immediate value. Heap
  values retain the complete checks. Binding contracts remain enforced.
- Borrowed-authority and tail-call capture checks inspect container contents
  without copying their backing storage or property names. Small visited sets
  stay inline and larger graphs use a hash set. Cycles still terminate, and
  the same graph edges and tail-call eligibility rules are checked. Regressions
  include a captured mutable binding beyond a 40-container cycle and closures
  stored in node heads.

The internal executable-GIR format advances from 27 to 28 to carry the loop
reuse hint. This invalidates old compiled artifacts; it does not change source
syntax or language behavior. Super-specialized chunk copies preserve the hint.

## Measurement and qualification

Portable release builds retain bounds and overflow checks. Measurements must
alternate independently built baseline/current executables, exclude warmup and
calibration, verify identical results, and preserve raw samples and build
identities. Timing runs must not overlap this task's compilation or validation.
The host is a shared macOS arm64 workstation, so sample spread is part of the
evidence. Python is a workload reference, not a claim that either language has
one universal speed ratio.

The first two passes improved the general workloads but left Harness service
time essentially unchanged. A subsequent service profile accounted for 10,584
main-thread samples: about 50% belonged to scope-retention/escape work and 31%
to publication. That evidence motivated borrowing during the tail-call capture
walk. Idle worker-thread samples are excluded from those percentages.

The Harness probe now uses the supported scripted profile instead of the
retired `open_session_service ^provider` argument. Workload version 2 checks
completed receipts and exact output-file contents. Its absolute times must not
be compared with the October 4 callback-based capture. Runtime comparisons use
the same version-2 source and fresh workspaces for both binaries.

The [final evidence](../../benchmarks/baselines/2026-10-10-general-runtime/README.md)
records 1.20–1.74x improvements across the general workloads and a 1.39x
Harness service improvement (53.1 to 38.1 seconds per 100 turns). An independent
fresh-cache rebuild confirms 1.19–1.71x improvements on the general workloads.
The evidence includes raw samples, hashes, source snapshots, profiles, and
qualification logs. Initial noisy captures are not the headline estimate.

The final source currently passes 1,678 broad-suite cases, 846 language specs,
395 VM cases under both ORC and AtomicArc, 87 lifetime cases, and 21 Cordis
cases. A targeted AddressSanitizer run using the system allocator passes 383
VM cases. The normal builds cover all 395, including the allocation-budget
fixture: that fixture depends on Nim's occupied-memory counter, which is
unavailable with `-d:useMalloc`. An initial unfiltered sanitizer attempt was
stopped at that fixture and is retained as an incomplete run, not counted as
passing. Sanitizer leak detection is disabled; the separate RC suite checks
managed retention.

The final-build Harness run passed 178 cases and failed its one-shot activation
expiry fixture. Its one-second global startup budget could expire required
documentation/command plugins; startup diagnostics reproduced the timeouts on
both baseline and optimized runtimes. The fixture now verifies readiness with
a five-second activation budget and waits 6.5 seconds before scheduling the
trigger, retaining the original expiry invariant and 20-second completion
bound. Its three-case file passes on the optimized runtime, and the revised
expiry case passes on the baseline. All 179 cases are covered across the full
and focused runs; the original full run is retained as 178/1, not relabeled as
an entirely green run. No runtime budget or language semantics were changed.

## Existing issues exposed during investigation

These observations reproduce on the unchanged baseline and remain separate
from this optimization:

1. A function stored in a node head through a local weak binding can lose its
   captured value. This returns `nil` on both the baseline and the second
   optimized build, although the function should retain `x`:

   ```gene
   (var saved nil)
   (fn retain [value] (set saved value) 0)
   (fn outer [x]
     (let inner (fn [] x))
     (set x (+ x 1))
     (retain ($node/rebuild (quote (held)) ^head inner)))
   (outer 11)
   (($head saved))
   ```

   A direct function literal in the node head works. This is a lifetime defect
   to investigate, not a supported workaround or a changed semantic contract.

2. A source tail call after some `repeat` loops can fall back with
   `operand_region`. A cycle-construction fixture reproduced this on the
   baseline with `--report_tail_fallbacks`. The capture-check regression builds
   its graph outside the tested function so that it actually exercises the
   captured-scope guard. Investigate the leftover operand separately.

3. Existing verification fixtures contained malformed `^^^override`, or used
   `^^!override` where they intended `^^override false`. Those fixtures were
   repaired to exercise their original override checks. Three printer/error
   expectations and one LSP column expectation were aligned with independently
   verified baseline behavior. These test-only repairs are a separate commit;
   they did not alter the reader or message-resolution rules.
