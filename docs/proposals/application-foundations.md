# Application foundations

Status: implemented on `improve/gene-application-foundations`. The selected
changes are validated; existing retention limitations are recorded below.

The goal is a fast, general-purpose, gradually typed Gene. Cordis and Miclone
provide concrete acceptance workloads. This change preserves named APIs,
lexical calls, explicit messages, node data, mutable state, and the ordinary
runtime while removing representation and portability workarounds.

## Selected changes

1. Store fixed-width numeric buffers in packed storage. Preserve generic
   buffers, checked writes, negative indexing, alias identity, overlapping
   copies, native marshalling, and GC traversal. F32 storage rounds to its
   declared width, consistently with browser typed arrays; F32 scalar
   annotations remain range checks.
2. Complete shared collection and numeric operations that currently force
   Miclone-specific adaptations: map iteration, consistent length/conversion
   contracts, and checked integer-buffer reads. Improve named defaults and
   explicit public-module exports where the current web restrictions prevent
   ordinary reusable APIs.
3. Give Cordis a direct supported way to bind an existing callable to a
   bounded execution policy, preserving suspension, authority attenuation,
   caller ownership, and typed task outcomes. Replace its generated eval
   wrapper with that operation.
4. Exercise the resulting APIs in Cordis and Miclone, update the relevant
   language contracts and examples, and record measured results.

Application validation also exposed a host-path ambiguity: registered programs
run from build snapshots, while the CLI's implicit filesystem grant is rooted
at the launch directory. `os/launch_dir` exposes that existing application value
under `os/Process`; Miclone uses it to select the host's manifest-reading grant
before resolving relative paths. Its network harness grants access only to its
world directory. A separate fix tolerates a package lock disappearing while a
concurrent build inspects it.

These changes do not require choosing a new general syntax or changing the
call/send distinction. Generic nominal records, general N-argument FFI, and
cross-module native compilation remain separate architectural work; the
review identifies their value but does not by itself specify their complete
implementation contracts.

## Verification

- [x] Capture a release-build Miclone wire benchmark before changes.
- [x] Test packed storage width, range boundaries, F32 rounding, bulk copies,
  generic fallback, byte conversion, and native buffer round trips.
- [x] Add VM/web agreement fixtures for every changed portable operation,
  including invalid input and evaluation order.
- [x] Verify bounded callbacks through suspension, cancellation, errors,
  limits, and nested policies, including Cordis lifecycle tests.
- [x] Run language specifications, unit/integration tests, web-profile
  fixtures, and the relevant threaded/retention checks.
- [x] Run Cordis's package tests and Miclone's portable probes.
- [x] Compare release-build performance and update documentation from actual
  results. Investigate regressions before declaring completion.

## Baseline

On this workspace, the unchanged release CLI compiled with Nim 2.2.4 and
`-d:release` reports, for Miclone's `wire_bench` (20 repetitions): 6.30 ms
for block sizing, 11.45 ms for encoding, and less than its millisecond timer
resolution for the byte bridge, totaling 17.75 ms per block. The benchmark's
printed V8 comparison is historical and is not a new browser measurement.

## Measured results

The final comparison used the unchanged `a1cce7c` release binary and this
branch's release binary, both built with Nim 2.2.4 and `-d:release`. Five process
runs per binary were interleaved, alternating their order, with compiler and
test jobs stopped. Both binaries ran the same benchmark source. Times are
medians with the observed minimum–maximum range, measured in milliseconds.

| Workload | Baseline | This branch |
| --- | ---: | ---: |
| Allocate 1,000 U8 buffers of 65,536 elements | 225 (224–246) | 21 (20–22) |
| Export a preallocated 65,536-element U8 buffer to Bytes 1,000 times | 271 (263–274) | 2 (1–2) |
| Miclone block sizing + encoding + byte export, per block | 17.85 (17.05–18.30) | 17.80 (17.25–19.80) |

The allocation/export workload is [benchmarks/buffers.gene](../../benchmarks/buffers.gene).
The codec workload is Miclone's `probes/wire_bench.gene`, with 20 repetitions
per process run. Reproduce with `gene run benchmarks/buffers.gene` from the
repository and `gene run probes/wire_bench.gene` from `examples/miclone`.

Packing substantially improves allocation and byte export. The byte-export
measurement is close to the timer's millisecond resolution, so a precise speedup
ratio would overstate the evidence. U8 element payloads use one byte instead of
eight; F32 payloads use four instead of eight, excluding object headers and
temporary scalar values. The scalar-heavy block codec is effectively unchanged
in this sample. It still needs faster typed execution and dispatch; packing
alone does not solve Miclone's numerical throughput requirement. These are
local before/after measurements, with no Python or new V8 comparison implied.

## Validation results

Validation was performed on an Apple M4 Pro, arm64 macOS, with Nim 2.2.4.

- The full default-runtime unit/integration suite passed 1,122 cases, including
  native buffer round trips, module loading, CLI builds, and HTTP/WebSocket I/O.
- The executable language specification passed 711 cases.
- Shared conformance passed 164 fixtures on each of the VM and web backends.
  The async cancellation, DOM component, and embedded-module runners passed,
  along with the 97 host-binding checks and TypeScript 5.9.2 artifact checks.
- All 31 default ORC retention tests passed. Bound-call checks cover shallow
  argument snapshots, returned captures, scoped Callable dispatch, fresh and
  nested limits, capability attenuation, suspension, cancellation, and errors.
- The threaded value, VM, native API, and worker behavior suites passed.
  Separate atomicArc runs passed all 20 bound-call and 11 packed-buffer tests.
  The atomicArc retention suite remains failing; see the limitation below.
- Cordis passed all 15 package tests. Timer-service coverage waits beyond a
  250 ms activation policy and verifies that intervals and lazy tick streams
  remain live, then stop when their owner is disposed.
- Miclone built all 65 web modules. All 11 portable probes produced identical
  VM/web output, including world generation, lighting, physics, inventory,
  binary protocols, ABMs, and divergence checks. The local client smoke passed,
  and persistence passed across separate create/verify processes.
- Miclone's sandboxed loader passed with the separate world-directory grant
  present: all 20 node identities, 23 items, and 2 forms agree with the linked
  mod, and the ungranted filesystem probe remains refused. The network client
  smoke passed against its own server over a real WebSocket, receiving and
  meshing all 576 blocks and exercising dig/place, inventory, forms, entities,
  and movement. The harness closed its server afterward.

## Remaining limits

The default ORC runtime still cannot collect every mixed scope/Value cycle.
An ordinary factory closure stored in an ancestor scope, and a closure stored
in a generic buffer in its own scope, retain managed values on the unchanged
`a1cce7c` baseline too. Explicitly releasing the owning binding reclaims these
cases. Cordis clears its temporary bound invocation in `ensure` after joining
the task, including failure and cancellation paths. The retention tests verify
that release; they do not claim general cycle collection.

`nimble threadcheck` passes its four behavioral suites but fails the final
atomicArc retention suite. The original commit reproduces 12 failing retention
cases; this branch also exposes the same limitation in the new bound-call
retention case. AtomicArc does not provide ORC's cycle collection, and existing
module-root self-references retain even basic scopes. This is an unresolved
runtime issue, not a passing verification result or a completed memory-management
redesign. The default ORC build is the validated retention configuration here.

General N-argument native FFI, cross-module native compilation, richer generic
nominal types, and complete Python-level library coverage are still open work.
Named defaults and public re-exports improve the current web subset; they do
not make it the full VM language. Positional defaults, first-class named-function
signatures, and named methods/constructors remain outside that profile.
