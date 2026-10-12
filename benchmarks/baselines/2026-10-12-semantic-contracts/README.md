# Semantic contract implementation qualification

Status: qualified. Baseline source is commit `eed4045`; the candidate is the
implementation captured by the source manifests and binary digests here.
Concurrent work outside this change set is not part of the qualification.

## Scope

- Test-only scheduler quanta 1, 7, 512 and 4096, without new yield or cancellation
  boundaries. Production keeps quantum 512 and ignores the test environment.
- Root-lane `sync/gate`, compatible Harness polling-guard migrations, and Cordis
  enqueue/drain/wakeup and invocation admission synchronization.
- Predicate-specific negative proofs for deeply frozen pure-data Lists and
  property Maps. Caller-environment, tail-capture and weak-scope escape checks
  use separate proof bits. Unproven kinds retain the original traversal.

Budget-exhaustion testing exposed a real cleanup defect in the first gate
prototype: ordinary Gene `ensure` can itself exhaust its inherited budget. The
owner approved native ownership cleanup. Gate permits and `sync/track` Map
registrations now follow the wrapper's VM extent and are released on return or
unwind, including budget exhaustion. No arbitrary cleanup callback receives an
extra budget, and general `ensure` rules are unchanged.

Cordis now registers before its final acceptance check, so unload either waits
for the registration or closes admission before a later callback can enter.
Its inherited-deadline regression checks that supervised evaluators and owner
registrations both retire after a timed-out invocation.

## Correctness qualification

| Check | Result |
| --- | --- |
| Full native VM suite, quantum 1 | 402 passed |
| Executable specs, quantum 7 | 892 passed |
| Frozen certificate eligibility | 6 passed |
| atomicArc native API thread suite, quantum 1 | 18 passed |
| atomicArc frozen publication and repeated worker stores, quantum 7 | Passed; multiple threads observed |
| Uninstrumented production build with an invalid test-quantum environment value | 13 ownership tests passed; override ignored |
| ASan core schedule/gate/proof matrix | Passed at all four quanta |
| ASan Cordis quiescence/deadline cases, quantum 1 | 4 passed |
| ASan Harness service probe, three separate runs of 3 turns | All completed; checksum 24 each |
| Harness, at each of 1 / 7 / 512 / 4096 | 200 passed |
| Cordis, at each of 1 / 7 / 512 / 4096 | 22 passed |
| Imagination, at each of 1 / 7 / 512 / 4096 | 151 passed |

Each setting also passes 5 scheduler, 13 ownership and 5 graph-proof fixtures.
See [application results](applications/results.json), [ASan results](asan/results.json),
[VM output](vm-quantum-1.txt), [spec output](specs-quantum-7.txt),
[thread output](atomic-api-quantum-1.txt), [worker publication](atomic-frozen-workers.txt),
and [binary digests](binaries.json). Source manifests accompany the two application
attempts: the initial run supplied quanta 1/7/512; the 4096 rerun followed the
stress-bound correction described below. Logs use `.txt` so ordinary repository
ignore rules do not discard the evidence.

The scheduler fixture verifies the effective setting. The driver rejects bad
quantum values and requires a nonempty passing test summary in addition to exit
status zero. `nimble contracts` builds and runs the small matrix plus certificate
eligibility. Full application qualification uses:

```sh
gene run tools/verify_scheduler.gene TEST_GENE NEW_OUTPUT --gates --proofs --applications
```

`TEST_GENE` is built with `-d:geneSchedulerTests -d:geneGraphProofTests`.
Application tests require the native dependencies and loopback server access.
On this machine, standalone C-generating spec tests need
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`; the default
SDK 27 stubs are incompatible with the installed linker. ASan runs use
`-d:geneDebug --passC:'-fsanitize=address -fno-omit-frame-pointer -O1'
--passL:'-fsanitize=address'` and `ASAN_OPTIONS=detect_leaks=0`. These are address
safety checks, not a claim of complete leak qualification.

## Graph-check scaling

`tools/benchmark_frozen_checks.gene ROWS 20 --stats` builds/freezes the data
before measurement. With proofs disabled, the same program and predicates take
the original scan path. Counters, unlike short elapsed-time samples, are not
affected by clock resolution or other tests running on the host.

| Frozen rows | Caller-env visits, enabled | Caller-env visits, disabled | Weak-scope visits, enabled | Weak-scope visits, disabled |
| ---: | ---: | ---: | ---: | ---: |
| 10 | 20 | 1,220 | 40 | 2,440 |
| 10,000 | 20 | 1,200,020 | 40 | 2,400,040 |

Checksums agree. Separate fixtures exercise tail-capture checks, mutable and
shallow aliases, borrowed caller authority, escaping closures and cyclic
fallbacks. The behavioral negative fixtures also pass with proofs disabled.
Nodes, types, functions and runtime resources do not receive container proofs.

This establishes bounded repeated checks for the eligible unchanged subtrees.
It does not make history serialization, copying, rendering, or whole application
turns constant time.

## Paired performance results

Both binaries report release, macOS/arm64, Nim 2.2.4, ORC, speed optimization,
bounds checks and overflow checks. These timings use uninstrumented production
binaries, quantum 512, and `GENE_WORKERS=0`. Three paired samples rotate execution
order; builds and qualification suites had stopped before timing. The baseline
service uses a clean `eed4045` source export and each service run gets a new
workspace. All paired checksums match. Raw samples and binary provenance are in
[measurements/results.json](measurements/results.json) and
[measurements/provenance.json](measurements/provenance.json); the orchestration
is preserved as [measure.gene](measure.gene).
Run that script from the repository root with a new output-directory argument.
It expects the clean baseline source at `tmp/semantic-contracts/baseline` and
the uninstrumented binaries at `tmp/semantic-contracts/gene-baseline` and
`tmp/semantic-contracts/gene-production-final`, built from their corresponding
trees with `nim c --path:src --hints:off -o:OUTPUT src/gene.nim`. The project
configuration selects release/speed for that entry point. Set `GENE_WORKERS=0`
and supply the same package store to both binaries.

| Service workload | Baseline median | Candidate median | Median reduction |
| --- | ---: | ---: | ---: |
| 25 turns | 1,591 ms | 1,522 ms | 4.3% |
| 120 turns | 11,762 ms | 9,024 ms | 23.3% |

The 25-turn ranges overlap (baseline 1,588–1,624 ms, candidate 1,505–1,597 ms), so
that small difference should not be generalized. At 120 turns, baseline samples
range from 11,639–11,793 ms and candidate samples from 8,978–9,085 ms. Average
candidate time still rises from 60.9 to 75.2 ms per turn: this change reduces
history-related overhead without eliminating all of it. These results measure
the combined implementation, not the contribution of each individual change.

For 10,000 repeated stores/returns of one already-frozen payload:

| Rows | Baseline median | Candidate median |
| ---: | ---: | ---: |
| 10 | 20 ms | 7 ms |
| 100 | 131 ms | 8 ms |
| 1,000 | 1,259 ms | 7 ms |
| 10,000 | 13,181 ms | 7 ms |

Construction, freezing and serialization are outside this isolated timing. The
graph counters above are the stronger evidence for bounded checking cost; the
candidate's 7–8 ms spread is near millisecond timing resolution.

## Fixture corrections exposed by short slices

- The Cordis entered-handler test now waits on a channel, rather than assuming
  the handler entered within a two-millisecond sleep.
- The Harness trigger test originally expected immediate scheduler destruction
  after seam withdrawal. A diagnostic showed a later heartbeat round still
  holding the old snapshot lease. The test now checks immediate withdrawal from
  discovery, joins already admitted round watchers, and then requires scheduler
  cleanup without a manual retirement drain. Deferred retirement is existing
  application behavior; the implementation was not changed to satisfy that old
  timing assumption. The corrected isolated test and full matrix pass.
- At quantum 4096, an HTTP listing repeatedly took 142 ms, exceeding the fixture's
  production-oriented 100 ms bound. This test quantum allows eight times as many
  instructions per slice. The fixture now scales its timing bound proportionally
  only for larger instrumented quanta (800 ms at 4096), preserving every progress,
  cancellation-completion and stopped-work assertion. Ordinary production and
  smaller quanta retain 100 ms. The [uninstrumented production check](production-responsiveness.txt)
  measured HTTP at 3–25 ms and cancellation at 7–16 ms. The original failure is
  retained in [large-quantum-before-bound.txt](large-quantum-before-bound.txt).

The historical profile's 17% sleeping figure is not attributed wholesale to the
migrated mutex guards. Those guards now park on channels; unrelated timer and
lifecycle waits remain.
