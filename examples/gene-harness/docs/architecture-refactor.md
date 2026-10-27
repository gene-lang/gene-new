# Architecture refactor implementation

The accepted review is `tmp/harness-review.md` (2026-10-27, baseline
`24e64e5f`). It is implemented in six independently verified commits.
Durable admission/recovery, one workspace owner, leased snapshots, the
trusted-code model and the existing Gene syntax remain invariants.

| Batch | Deliverables and acceptance | Status |
| --- | --- | --- |
| 1. Fixes and policy | Five trigger routes return unavailable after disabled boot/live deactivation; re-enable preserves definitions. Remove unused private modules/helpers, update reference material and organization, retain additive PluginHost:2, identify interface mismatch accurately. | Complete |
| 2. Operator inbox | Narrow operator-inbox protocol, stored notifications replacement, unchanged plugin-owned publishers. Pre-existing/foreign/keyed message operations, revisions, replacement and restart. Public defer cleanup and an explicit built-in import boundary. | Complete |
| 3. Registries | Declarative owned specs/callbacks/keys/reservations, leased rows/row and extensible hook points/dispatch. Registry requirements move dependents pending and reactivate them. A/B/C replacement, supervision, immutable views and leased cleanup. | Complete |
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

## Batch 2 evidence

- The notification integration suite passed all 5 cases. The new stored
  replacement imports only `plugin_api`, runs in a profile with no `loop`,
  and preserves operator ownership, foreign-source visibility, keyed identity,
  frozen actions, immutable results and observed-revision clears across restart.
  Existing publisher/action and CLI/HTTP delivery cases remain green.
- The public cleanup acceptance case passed: old readers retain their resource,
  the last release retires it once, and failed activation unwinds once.
  Kernel snapshot/event cases passed (4), Cordis effect cases passed (2),
  trigger lifecycle cases passed (3), and Slack transport cases passed (6),
  including replacement/withdrawal without deleting core queues.
- Slack and triggers use public `defer` instead of growing activation lists.
  The operator-inbox handle is opaque and revoked on workspace close. Provider
  adapters now use public `ProviderError` rather than importing the kernel.
  Provider and built-in import checks passed (12 cases). The import check names
  remaining migration exceptions and rejects stale exceptions and new private
  dependencies. Feature migrations in later batches must reduce that list.
- `PluginHost:2` is unchanged. Old raw entry points remain during additive
  migration; retirement waits for batch 6's compatibility policy.

## Batch 3 evidence

- Three cooperating plugins exercise the public registry API: A defines the
  schema/key/callback/removal policy, B requires the registry and contributes,
  C requires a selected row and reads it through PluginHost. Replacement of A
  and B under leases preserves old and new selections; owner withdrawal makes
  B/C pending and reinstatement reactivates them. Old callbacks expire, nested
  data is immutable, and removal uses the old owner's captured budget once.
- All 3 new registry/hook cases passed, including schema timeout versus a
  wider contributor budget, callback timeout versus a wider consumer budget,
  generic reservations, malformed specs and ordered extensible hook dispatch.
  The host's schemas/policy/resource adapters moved to `src/registries/`;
  `contribute` has no per-feature callback, reservation or key branches.
- Existing kernel cases passed (4), notification integration (5), workspace
  storage (7), image plugin replacement (3), questions (2) and cards (9).
  The broad native unit run reported 171 passed with the same theme failure
  and three unavailable-zdump errors recorded in batch 1; speech lifecycle,
  provider and import-boundary cases passed within that run.
- Agents integration reported 46 passed and 1 failed. The failed turn-limit
  fixture expects a synthetic reply that operator pauses no longer emit.
  Running that exact case in a detached checkout at batch 2 (`3407bd5a`)
  reproduced the same error at `turn_loop_spec.gene:101`. Align that fixture
  with pause/continuation semantics during batch 5; it is not a green-suite
  claim for this batch.
- Registry decoration makes a shallow map copy, preserving live resource
  identity. Deep thaw of a cyclic runtime is a separate recorded Gene runtime
  issue; no language syntax or semantics were changed here.
