# Gene Native Application Profile and Implementation Order

**Status:** Implementation roadmap and qualification proposal, baseline reviewed at `3b2bde9`. No new feature or performance result is claimed.

**Profile:** `native-app` for the cooperative native VM, with root-lane Gene execution and supported native I/O workers.

**Initial qualification targets:** Linux x86_64 and macOS arm64, tested independently.

## What completion means

The profile covers automation, installable CLIs, services, and moderate data transformations. It is a supported workload set, not a compiler mode, package build profile, or Python source-compatibility promise. Browser/C lowering, concurrent AtomicArc Gene workers, scientific arrays/dataframes, and unimplemented optional libraries remain separately visible capabilities.

All application behavior in the fixtures is Gene. A host test harness may launch processes, generate deterministic inputs, or inject faults, but cannot perform an absent application feature on Gene's behalf.

Track current support in `docs/profiles/native-app.md` and a data-only `tests/profiles/native-app/profile.gene` manifest. Each capability records supported/experimental/planned/unsupported, runtime revision, OS/architecture, and its conformance evidence. Proposal text alone never promotes it. The ledger includes optional genex packages even when they are not required by the four core workloads.

## Cross-document decisions

- Standard libraries use gene/*; optional genex/* packages are declared/locked individually. No gene/app umbrella.
- Qualified messages are required for generic I/O protocols. The five selected core value protocols have the explicit VM fallback rules in [value operations](value-operations.md); that exception does not change general send resolution.
- I/O/native close is a request. Physical retirement and retained close failure are observable separately, with cleanup leases.
- Package resources/recipes extend existing format-1 fields and canonical encoding. Local installation comes before hosted publication.
- Reliability repairs build on the current manual RC/weak-scope/trial-deletion mechanisms. A new root scanner is not assumed to be safe.

## Recommended implementation order

Stage IDs below are defined in their linked proposals. This table is the dependency authority for the series.

| Order | Work | Prerequisites and exit |
| --- | --- | --- |
| 0 | PROFILE-0 plus [VM-0](vm-reliability.md) | Record runtime/test baseline, add fixtures/ledger/counters, reproduce reported hangs/leaks. No feature prerequisites. |
| 1 | [VM-1/2](vm-reliability.md), [APP-1](application-libraries.md), [PKG-1](package-distribution.md) | Start ownership/eval repairs immediately. Paths/CSV and resources/offline installation can land independently. Exit with a real script and installed CLI; lifetime blockers remain visible until fixed. |
| 2 | [VAL-1 → VAL-2 → VAL-3](value-operations.md) | VM ownership/eval evidence first. Complete witness selection, recursive equality/hash, indexing and ordering as one coherent feature; do not ship only top-level ==. |
| 3 | [IO-1 → IO-2 → IO-3](async-io.md) and APP-2 | Establish cleanup/protocol semantics with fakes, then files/pipes/TCP. Add streamed CSV after IO-2. |
| 4 | [NET-1 → NET-2](network-services.md) | Owned HTTP transport/body adapters use IO contracts. Qualify HTTPS via the recorded reverse-proxy fixture and service shutdown. |
| 5 | [PKG-2](package-distribution.md), [NATIVE-1 → NATIVE-2 → NATIVE-3](native-extensions.md) | Package an existing native library first. Retained callback fixtures need no registry; NATIVE-2 uses IO-1 lifecycle, NATIVE-3 uses PKG-2 packaging. |
| 6 | APP-3/APP-4, NET-3, PKG-3 | Zone resources need PKG-1; archives need IO-2/PKG-2. Direct TLS and hosted publication are independently qualified additions. |
| 7 | VM-3 and PROFILE-1 release report | Run integrated long-lived/offline/platform gates after the relevant stages. Publish actual pass/fail results and remaining optional capability status. |

VM repairs and narrow conformance tests run throughout; order 7 is final qualification, not the first time reliability is tested. IO implementation need not wait on value fallback if assigned independently, because ordinary qualified protocols already exist. Core profile qualification requires VM, APP-1/streamed CSV, VAL, IO, NET-1/2, and PKG-1/2. Hosted registry, direct TLS, retained notification callbacks, and optional formats have their own completion entries; a core pass must not imply those passed.

## PROFILE-0: executable workload contracts

Create one small package per workload under `tests/profiles/native-app/`. Reuse the normal Gene test runner for application assertions and a process harness for crashes/network faults.

| ID | Workload | Required result |
| --- | --- | --- |
| SCRIPT | Walk a deterministic tree, read JSON/CSV, invoke a process with argv, call a local API, atomically publish output. | Golden output, typed failure for malformed input/process/API error, bounded traversal/parser memory. |
| CLI | Locked dependency, resource, and a native binding; install to a temporary prefix. | Runs from unrelated cwd with source tree hidden and network disabled; update crash exposes complete old/new generation. |
| SERVICE | HTTPS reverse proxy → Gene streaming handler → SQLite, eight concurrent clients including a slow peer. | Correct streaming/framing, fast requests continue, cancelled tasks release resources, stop reports physical cleanup honestly. |
| DATA | Stream 10 MiB then 100 MiB of deterministic CSV, group into at most 100 keys, sort that bounded result. | Identical logical result, no whole-input retention, explicit errors on record/group limits. |
| LIFETIME | 10,000 lifetimes using a bounded vocabulary/module graph. | VM-3 roots/handles/heap gates; no repeated initialization of a new process to hide retention. |

The CLI binding may use the existing synchronous/native path; a retained-callback variant is added with NATIVE-3. Postgres is an additional fixture; the default requires only SQLite. No paid provider or public network is required.

The manifest contains profile_format=1, workload ID, package/entry, argv, dataset seed/size, required capabilities/stages, platform, timeout_ms, and budgets. Commands are argv arrays executed without a shell. Reports store start/end, exit status, stage, runtime/toolchain IDs, relevant native dependencies, artifacts/logs, and metrics. Missing prerequisites are explicit blocked/unsupported results, never skipped tests counted as passes.

## Budgets and evidence

Use functional gates everywhere; performance thresholds belong to a named hardware/load profile checked in before qualification. Initial service target: 30 small requests/second for 60 seconds with up to eight clients, p95 loopback response within 250 ms and host heartbeat gaps within 250 ms, while one client is intentionally slow. Exclude model/provider time; record proxy overhead separately. These are proposed targets to measure, not achieved numbers.

For DATA, compare live retained payload at identical quiescent checkpoints for 10 versus 100 MiB input; proposed growth budget is 8 MiB with fixed group/cardinality limits. Also report native buffers and process RSS so moving retention out of the Gene heap does not hide it. Workload timeouts are finite and declared; a timeout is a failure with last-progress evidence.

If a target is unattainable, fix the bottleneck or publish a narrower measured workload in a reviewed manifest change. Never lower a gate automatically in the same test run. RC/object counts, native leases, queue depth/age, peak/retained memory, p50/p95/p99 latency, and loop stalls complement one another; none alone proves support.

## PROFILE-1: release gate

1. Run relevant narrow suites and the normal native specs. Preserve existing local-world/HTTP/stdlib/package behavior unless a separately documented API change was selected.
2. Build with the committed lock, sync/vendor once, then build/install offline. Run with source checkout unavailable. Artifact/runtime identities and system dependencies must match the install manifest.
3. Run fault and lifetime workloads in real separate processes with deterministic faults. Inspect outputs/state/handle counts, not only returned status strings.
4. Qualify each OS separately. Include unavailable optional backends/features in the report rather than implying support from the native VM result.
5. Update user guides and implemented specs only when the corresponding APIs pass; leave these proposals as the rationale and stage history.

The first deliverable is the PROFILE-0 ledger and small failing/blocked fixtures. It does not require building a new benchmark service, registry, or universal test framework.
