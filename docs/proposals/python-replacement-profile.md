# Gene Native Application Profile

**Status:** Proposed design; the profile and its gates are not implemented.  
**Purpose:** Make “use Gene instead of Python” a testable claim for native applications.  
**Target:** The Gene VM. The web and experimental C backends report their own coverage; they do not define this profile.

## Decision

Define a `native-app` support profile in documentation and executable conformance fixtures. This is a distribution and quality promise, not a new language mode or source annotation. An application remains ordinary Gene code using existing files, modules, packages, calls, and tasks. The profile is satisfied only when all required workloads pass from a clean checkout and from an installed artifact.

The initial scope is scripts, command-line applications, HTTP services, and moderate data transformations. Numerical computing at NumPy scale is a separately declared future `numeric-data` profile. Browser-only APIs and source compatibility with Python are outside `native-app`.

## Capability ledger

Maintain `docs/profiles/native-app.md` as the human-facing ledger and a machine-readable fixture manifest under `tests/profiles/native-app/`. Every capability has one of `supported`, `experimental`, `planned`, or `unsupported`, a minimum Gene revision, supported operating systems, and a conformance test or a documented reason it has none. A proposed API never appears as supported because a design document exists. The ledger distinguishes the VM, web, and C backends where a feature has different behavior.

The profile depends on the companion proposals for [value operations](value-operations.md), [application libraries](application-libraries.md), [network services](network-services.md), [async I/O](async-io.md), [native extensions](native-extensions.md), [package distribution](package-distribution.md), and [VM reliability](vm-reliability.md). Their implementation status is tracked independently.

## Required workload fixtures

| Fixture | Required behavior | Evidence |
| --- | --- | --- |
| Automation script | Traverse a fixture tree, read bounded text/binary inputs, parse JSON and CSV, launch a subprocess with explicit arguments, call a local HTTP API, write an atomic result, and return a meaningful exit code. | Output fixture, failure cases, no shell interpolation, bounded memory. |
| Installable CLI | Use a locked dependency and packaged data file; build, install, invoke from another directory, print useful errors, and run offline after installation. | Clean-machine or clean-container install and test log. |
| Service | Serve HTTPS behind the selected supported termination mode, stream a request body, query SQLite or Postgres, handle concurrent slow/fast clients, and stop cleanly. | Correct responses, cancellation/resource checks, sustained-load measurements. |
| Data transformation | Stream a bounded-memory input, parse and group records, sort an explicitly bounded result, and emit a reproducible output. | Golden output and peak-memory report at two input sizes. |

The fixtures use local servers, generated data, and a fake external process so normal CI needs no paid service. A Postgres variant may run in a separate integration job, but the default SQLite path must pass. Each fixture contains one injected I/O failure and one cancellation or interrupted-run case where relevant.

## Gate and publication contract

1. **Correctness:** Run the native VM spec, the fixture's Gene tests, and end-to-end CLI invocation. An expected error must identify its source location and cause without a host-language traceback being the only explanation.
2. **Packaging:** Resolve with the committed lock, build with `--locked` and `--offline` after sync/vendor, install to a separate prefix, and run with the source checkout unavailable. The installed artifact declares required native libraries and resources.
3. **Lifecycle:** The service and repeated-script fixtures meet [VM reliability](vm-reliability.md) gates. A successful one-shot run is insufficient for a long-lived feature claim.
4. **Performance:** Record hardware, Gene/runtime revision, input sizes, latency distribution, throughput, peak/retained memory, and output size. Establish workload-specific budgets in the fixture manifest before qualifying a release; a changed budget is reviewed rather than silently overwritten. The first profile release need not beat Python on every metric, but must remain within its published supported envelope.
5. **Portability:** State supported OS/architecture combinations. Passing on one host does not imply another target works.

CI generates a report with each fixture, status, revision, platform, and command result. The release notes link that report. A regression changes the profile status or blocks a supported-profile release; it cannot be hidden by an unrelated passing spec suite.

## Implementation sequence

1. Add the ledger and fixture manifest with current behavior honestly marked. Build small fixtures using existing APIs so the gaps are observable before new libraries are added.
2. Implement companion proposals in dependency order. The native-callback fixture can use a local library first; format-2 resources can land independently; then package that extension and qualify hosted publication. Keep tests at both the narrow API boundary and the workload boundary; a library unit test alone does not promote a workload to supported.
3. Add install-from-artifact and sustained-service jobs. Qualify each platform only after those jobs pass.

**Acceptance:** a contributor can answer which of the four workloads Gene supports on a named platform, run the same commands locally, and see why any unsupported workload is blocked. No new parser form or backend-wide parity claim is required.
