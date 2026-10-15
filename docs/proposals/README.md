# Design proposals

Proposals describe intended designs and their rollout stages. Each file opens
with a **Status** line saying what is implemented; the guides and
[specification](../spec/README.md) describe current behavior and win when they
disagree. Records of finished work live in [reports](../reports/README.md).

## Staged roadmaps

Partly implemented: early stages ship (often as experimental), later stages
remain open.

| Proposal | Scope |
| --- | --- |
| [Application libraries](application-libraries.md) | APP-1–4: paths, CSV, streaming CSV, time zones, archives. |
| [Async I/O and resource lifetime](async-io.md) | IO-1–3: async resources, files, pipes, sockets, cleanup leases. |
| [Network services](network-services.md) | NET-1–3: owned HTTP client, server streaming, TLS. |
| [Package distribution](package-distribution.md) | PKG-1–3: installation, native artifacts, releases and registries. |
| [Value operations](value-operations.md) | VAL-1–3: equality, hashing, indexing and ordering protocols. |
| [VM reliability](vm-reliability.md) | VM-0–3: lifetime ledger, repairs, generation retirement, soak. |
| [AtomicArc retirement](atomic-arc-retirement.md) | AAR-0–3: retiring generations and cycles under the threaded memory model. |
| [Native application profile](python-replacement-profile.md) | Implementation order and qualification for the stages above. |

## Native extensions

Decided designs, largely implemented against `src/gene/native_api.h`.

| Proposal | Scope |
| --- | --- |
| [Native extension lifecycle](native-extensions.md) | Byte ingress, registration, root-lane dispatch, cleanup. |
| [Managed native extension ABI](native-managed-extension-abi.md) | The single `GeneApi` C layout. |
| [Native managed borrows](native-managed-borrows.md) | Opaque managed handles, borrows and copied reads. |
| [Foreign-created handles](native-foreign-handle-allocation.md) | The root-owned bounded handle registry. |
| [Native Task result handoff](native-task-result-handoff.md) | Copied results from worker-thread producers. |

## Not implemented

| Proposal | Status |
| --- | --- |
| [Capabilities](capabilities.md) | Proposed contract. An earlier capability system was removed from the runtime on 2026-09-20. |
| [Code persistence](code-persistence.md) | Proposed: loading packages and modules from databases and other origins. |
| [Gene representation](gene-repr.md) | Deferred: an immutable binary data format, reopened only by a real consumer. |
