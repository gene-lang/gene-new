# Application foundations

Status: implementation in progress on `improve/gene-application-foundations`.

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

These changes do not require choosing a new general syntax or changing the
call/send distinction. Generic nominal records, general N-argument FFI, and
cross-module native compilation remain separate architectural work; the
review identifies their value but does not by itself specify their complete
implementation contracts.

## Verification

- [x] Capture a release-build Miclone wire benchmark before changes.
- [ ] Test packed storage width, range boundaries, F32 rounding, bulk copies,
  generic fallback, byte conversion, and native buffer round trips.
- [ ] Add VM/web agreement fixtures for every changed portable operation,
  including invalid input and evaluation order.
- [ ] Verify bounded callbacks through suspension, cancellation, errors,
  limits, and nested policies, including Cordis lifecycle tests.
- [ ] Run language specifications, unit/integration tests, web-profile
  fixtures, and the relevant threaded/retention checks.
- [ ] Run Cordis's package tests and Miclone's portable probes.
- [ ] Compare release-build performance and update documentation from actual
  results. Investigate regressions before declaring completion.

## Baseline

On this workspace, the unchanged release CLI compiled with Nim 2.2.4 and
`-d:release` reports, for Miclone's `wire_bench` (20 repetitions): 6.30 ms
for block sizing, 11.45 ms for encoding, and less than its millisecond timer
resolution for the byte bridge, totaling 17.75 ms per block. The benchmark's
printed V8 comparison is historical and is not a new browser measurement.
