# Architecture refactor implementation

The accepted review is `tmp/harness-review.md` (2026-10-27, baseline
`24e64e5f`). It is implemented in six independently verified commits.
Durable admission/recovery, one workspace owner, leased snapshots, the
trusted-code model and the existing Gene syntax remain invariants.

| Batch | Deliverables and acceptance | Status |
| --- | --- | --- |
| 1. Fixes and policy | Five trigger routes return unavailable after disabled boot/live deactivation; re-enable preserves definitions. Remove unused private modules/helpers, update reference material and organization, retain additive PluginHost:2, identify interface mismatch accurately. | Complete |
| 2. Operator inbox | Narrow operator-inbox protocol, stored notifications replacement, unchanged plugin-owned publishers. Pre-existing/foreign/keyed message operations, revisions, replacement and restart. Public defer cleanup and an explicit built-in import boundary. | Pending |
| 3. Registries | Declarative owned specs/callbacks/keys/reservations, leased rows/row and extensible hook points/dispatch. Registry requirements move dependents pending and reactivate them. A/B/C replacement, supervision, immutable views and leased cleanup. | Pending |
| 4. Feature services | Narrow feature host contracts, retire raw loop/command-context access, static host service dependencies with normal/recovery/partial-open cleanup, feature HTTP routes and browser handlers behind authenticated admission and the core stream coordinator. Failure injection and existing client/recovery coverage. | Pending |
| 5. Turn participants | Explicit internal phase/transaction contract, delegation then a second consumer; one lease, unconditional core records/base Outcome rules, no replay, cancellation/panic cleanup, owned/schema-checked extension keys and initiators. | Pending |
| 6. Compatibility | Separate exact entry requirements from supported versions; shared load/plan/revert checks, legacy migration and unsupported-version/history cases. Retire HarnessRender, views/HarnessView after checking stored descriptors; preserve archived history. | Pending |

Each batch records its actual validation here before committing. The final
audit must check every row against implementation and runtime/test evidence;
passing a narrow test is not evidence for the entire refactor.

## Batch 1 evidence

- Trigger HTTP availability: 2 integration cases passed, covering all five
  endpoints at disabled boot and after live disable, followed by re-enable.
  Admission checks committed disable state even while an older scheduler is
  retained for admitted work.
- Workspace storage: 7 cases passed; interface policy: 1 case passed;
  plugin inventory: 3 cases passed; manager HTTP/restart/recovery: 3 cases
  passed. The event catalog check reports current.
- The broader native unit run reported 170 passed, 1 failed and 3 errors.
  The existing theme test finds `#0002` in unchanged `src/web/style.gene`;
  three calendar tests require `zdump -i`, unavailable in this environment.
  These are recorded limitations, not a green full-suite claim.
- Private dead modules/helpers were removed after checking callers. Public
  view contracts and exact-map admission remain until batch 6. Reference
  inventories and disclosure behavior were corrected, proposal/evidence
  documents moved with their local links rebased, and the manager plugin
  definition expanded. Notifications formatting lands with batch 2's rewrite.
