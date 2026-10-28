# Architecture refactor implementation

The accepted review is `tmp/harness-review.md` (2026-10-27, baseline
`24e64e5f`). Work is split into six independently verified commits.
Durable admission/recovery, one workspace owner, leased snapshots, the
trusted-code model and the existing Gene syntax remain invariants.

| Batch | Deliverables and acceptance | Status |
| --- | --- | --- |
| 1. Fixes and policy | Five trigger routes return unavailable after disabled boot/live deactivation; re-enable preserves definitions. Remove unused private modules/helpers, update reference material and organization, retain additive PluginHost:2, identify interface mismatch accurately. | Complete |
| 2. Operator inbox | Narrow operator-inbox protocol, stored notifications replacement, unchanged plugin-owned publishers. Pre-existing/foreign/keyed message operations, revisions, replacement and restart. Public defer cleanup and an explicit built-in import boundary. | Complete |
| 3. Registries | Declarative owned specs/callbacks/keys/reservations, leased rows/row and extensible hook points/dispatch. Registry requirements move dependents pending and reactivate them. A/B/C replacement, supervision, immutable views and leased cleanup. | Complete |
| 4. Feature services | Narrow feature host contracts, migrate built-ins off raw loop/command-context access, static host service dependencies with normal/recovery/partial-open cleanup, feature HTTP routes and browser handlers behind authenticated admission and the core stream coordinator. Failure injection and existing client/recovery coverage. | Complete |
| 5. Turn participants | Explicit internal phase/transaction contract, delegation then a second consumer; one lease, unconditional core records/base Outcome rules, no replay, cancellation/panic cleanup, owned/schema-checked extension keys and initiators. | Complete |
| 6. Compatibility | Separate exact entry requirements from supported versions; shared load/plan/revert checks, legacy migration and unsupported-version/history cases. Retire HarnessRender, views/HarnessView after checking stored descriptors; preserve archived history. | Complete |

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

## Batch 4 evidence

- Nine feature route modules now sit behind the shared HTTP admission checks.
  An HTTP acceptance case verifies authentication, Origin and CSRF across
  those routes. Trigger HTTP cases pass at disabled boot and live deactivation.
- Runtime startup/cleanup uses a static host service table with separate
  normal/recovery dependencies. Five runner cases and two real-runtime cases
  pass, including failure after each acquired prefix, caller-owned event
  storage, optional-plugin-free recovery and ownership released last.
- Failure injection exposed an existing shutdown defect: snapshot state was
  closed before effect cleanup, preventing cleanup callbacks from running.
  Admission now closes first, state stays readable through cleanup, and then
  snapshot storage closes. A cleanup failure is reported rather than hidden
  in Cordis diagnostics. Both public cleanup cases pass.
- Opaque, activation-scoped MediaHost, TriggerHost, ChannelHost, SessionHost,
  VoiceHost, UiHost and WorkspaceHost replace the corresponding raw accesses.
  API-only stored media, trigger and Slack replacements pass replacement and
  restart cases without `loop`. The built-in import-boundary exception list
  is empty. Workspace navigation returns BrowserTarget IDs;
  only the authenticated HTTP route resolves owner credentials.
- Browser subscriptions use a page-owned generic event hub. Payload/failure
  isolation, arbitrary event names, replacement, stale/failed bridges and
  automatic subscription cleanup pass against emitted modules. Conversation,
  first-submission, notification and Slack browser fixtures pass.
- Existing focused checks passed: voice integration (3), UI integration (11),
  computer (5), image plugin replacement (3), notification integration (5),
  kernel (4), registry extensions (3), manager HTTP/restart/recovery (3).
  Manager runtime checks passed six cases initially and the two remaining
  cases after fixing their fixture cleanup to await both host and supervisor
  locks; deleting their live startup markers had caused the teardown races.
  The cross-process channel recovery case passes all eleven crash checkpoints
  with fake sockets/API responses; its fixture now models HELLO per socket and
  installs crash hooks through host setup rather than a raw-loop plugin.
- ComputerHost and OperatorHost now own computer admission, driver receipts,
  and shell/REPL resources; CompositionHost owns publication operations.
  Built-ins use no raw Harness/loop/runtime fields and have no private import
  exceptions. Public helpers live under an exact shared-module manifest, with
  transitive import checks and stored SDK/restart acceptance. Provider/import
  cases pass (13), workspace storage/publication (7), REPL (1), shell (4), and
  public SDK loading (1).
- A new computer acceptance case passes operator grant admission, a stored
  replacement retaining grants, screenshot delivery, exactly-once action and
  receipt recovery across restart. It also rejects a manufactured command
  context outside admission. Computer and mode resources use explicit counted
  ownership, with admission quiesced before plugin retirement and durable
  resources closed afterwards; the service runner now has 5 passing cases.
- Active service-binding replacement exposed recursive-lock cleanup during a
  direct dependency update. Seam mutations now run through staged composition.
  A focused acceptance case passes replacement under an old lease, distinct
  old/new values, deferred cleanup and old-handle revocation; kernel cases
  remain green (4).
- Slack/share/author, triggers, voice glue and delegation handlers now live in
  feature modules with page-owned state. A new emitted-client acceptance case
  passes arbitrary events, failed observers, sequence gaps, stale epochs and
  selected/background delegation isolation through the real stream coordinator.
  Conversation, submission, notifications, voice, audio, live output, history,
  Slack identity/title, session menus, media, sidebar, Spotlight and form fixtures pass.
- Session-host wiring now uses the static lifecycle runner too. The session
  service cases pass (19), as does failure injection after every session stage.
  Observers detach before controller work drains, channels remain available
  while admitted rounds drain, and workspace ownership is released last.
- Final broad unit qualification reports 177 passed, with the same existing
  theme failure and three unavailable-zdump errors. All 22 Cordis lifecycle
  cases pass; the event catalog is current.
- The full integration run reported 412 passed, 4 failed and 1 error. Focused
  reruns after the fixes below pass the CLI control case, all 3 provider-image
  cases and all 3 source-attribution cases. The only remaining failure is the
  previously reproduced turn-limit fixture documented under batch 3, scheduled
  for the pause/continuation work in batch 5. This is not a green full-suite
  claim; the complete initial report is retained in
  `tmp/harness-batch4-integration.log` at the repository root.
- Broad qualification exposed a CLI control fixture that let its five-second
  work finish before its busy/stop assertions. The cancellation targets now
  stay active until cancelled. It also exposed local wait expiry leaking the
  HTTP `control_timeout` code. Receipt polling now reports `wait_timeout` when
  that local deadline expires, while preserving non-timeout errors. The full
  CLI control case and all 6 focused CLI receipt/deadline cases pass.
- Provider-image fixtures now use the public ProviderError contract of the
  shared helpers. Source-attribution qualification exposed operator execution
  scopes being mislabeled as model turns. Admitted commands now retain command
  authorship and a direct source-turn label while their internal execution
  scope continues to own queued changes. Attribution unit cases pass (4), and
  the integration cases cover edits, plans, reverts, cancellation and restart.
- Legacy entry points stay available until batch 6's compatibility policy.
  That policy must also cover prompt renderers: their current two-argument
  callback receives the raw runtime, as noted in the latest review addendum.

## Batch 5 evidence

- The [transaction contract](turn-participants.md) specifies mandatory phase
  order, invalid-Outcome behavior, durable finalization, terminal recording,
  cancellation/panic cleanup and receipt-based recovery without phase replay.
- The isolated runner has 9 passing unit cases. It contains callback errors,
  panics and timeouts, revokes exact phase-admission frames, rejects forged or
  retained contexts, attempts all cleanup and keeps core terminal recording
  unconditional after a failed finalizer.
- Internal delegation and card adapters pass host-state acceptance for staged
  admission, terminal-durability dispatch fences, a lost commit result without
  replay, invalid-Outcome discard, card progress and response-source
  acknowledgment across restart. These exercise the new interface directly.
- A native registry now installs both guarded adapters before plugin activation.
  Five host-state cases pass, including old/new phase reads on distinct leases,
  rejection of closed/foreign leases and rejection of unadmitted contributors.
  Both real startup/unwind cases pass with the new service prefix too.
- The production loop now dispatches the selected transaction. Delegation's
  eight production cases and the nine card cases passed before public
  registration was enabled. Mandatory failure injection covers all nine turn
  phases with no repeated model/response record and one terminal record.
  Cancellation after durable child admission preserves the dispatch fence.
- API-only stored callbacks receive immutable public projections and owned
  per-turn state. Namespaced response bindings contain data, not host objects.
  Public schema rejection repairs model input, while implementation errors or
  deadline failures abort once. Seven public cases cover optional fields,
  collisions, forbidden aliases/annotations, replacement during an active
  model call, contributor deadlines and sequential final-only commits.
- Outcome fields are checked against owned schemas from the same lease. The
  direct Outcome validator refuses an unchecked bag. All 16 Outcome unit cases
  pass, including field preservation through audio normalization and every
  existing completion deferral. The model's legacy field spellings remain
  additive until batch 6's compatibility interval.
- Owned initiator rows replace controller prefix policy. The Slack adapter
  owns channel validation independently of transport activation; admitted
  receipts persist operator policy. Two integration and two policy cases pass,
  including source disable/continuation, overlap refusal and historical readers.
  The seven existing channel-admission cases pass too.
- Broad agent/runtime qualification passed 203 cases; HTTP crash/session
  qualification passed 21, including all eleven fake-peer handoff checkpoints.
  The initial broad unit run reported 193 passed with the same theme failure
  and three missing-zdump errors recorded in batch 1. Additional focused Outcome
  cases pass after that run. Import/discovery checks passed (5) and the event
  catalog is current. Reports are retained under repository-root
  `tmp/harness-batch5-{agents-runtime,http,unit}.log`; no green all-suite claim
  is made for the known environmental/baseline unit failures.
- The obsolete turn-limit fixture now checks a pause, retained pending input,
  no synthetic final reply and an explicit continuation. All four turn-loop
  cases pass. Registry callbacks retain exact phase admission, and the native
  startup/unwind cases still release ownership last with the new service.

## Batch 6 evidence

- Entry requirements are exact strings, independently of the host's supported
  version lists. Unannotated source retains PluginHost:2; existing module author
  metadata explicitly selects PluginHost:3. Preflight, restricted inspection and
  actual activation all receive the entry's selected version.
- One interface diagnostic is used by descriptor loading and inert historical
  verification, which also underpins plan validation and reversion. The stored
  compatibility cases pass host-only additions, unsupported known versions,
  unknown interfaces and unsupported render versions through all three paths.
- The real stored-plugin loader passes whole-map legacy loading, typed raw
  command callbacks, prompt rendering, restart, explicit version-3 replacement
  and historical reversion. Normalization preserves archived requirements and
  source bytes; it drops only HarnessRender:1 with the proven version-2 pair.
- Stored version 3 receives an opaque receiver. Command and input-mode adapters
  expose immutable revision data and no managers/runtime; prompt adapters expose
  workspace/session data. Real command admission accepts public projections and
  nested command delegation while rejecting fabricated and retained contexts.
  Durable-record subscriptions use inert envelopes and opaque cancellation.
- Replacement under an outstanding lease passes old/new selection, deferred
  cleanup, owner removal callbacks, deactivation and receiver revocation. The
  receiver stays usable through cleanup and becomes unavailable afterwards.
  The compatibility/computer run reports 5 passed. The final focused registry,
  cleanup and compatibility run reports 10 passed, including partial activation.
  That new case exposed a retained registry definition after failed activation;
  cleanup now retires each owned definition by exact revision, preserving a
  replacement's registry and attempting both row and definition cleanup.
- A passive pre-removal scan of actual ignored workspace roots found 169 source
  files and 9,278 descriptor records with no views requirements or unreadable
  files. It never opens or activates a workspace. The scanner now also flags
  computed requirements; its two unit cases pass. The final quiescent scan
  reports 181 source files, 9,390 descriptor records, zero findings and zero
  unreadable files. A concurrent earlier scan reported disappearing fixture
  files; that incomplete result is not used as qualification.
- HarnessRender, HarnessView, GuardedView, their modules and the actual terminal
  views registry are removed. Legacy metadata queries have an empty projection;
  recorded descriptor requirements receive an explicit retirement diagnostic.
  Version-3 raw-seam requirements are rejected before activation, and plans for
  those descriptors are invalid.
- The final broad unit run reports 199 passed, with the same pre-existing theme
  failure and three missing-zdump errors. The generated event catalog is current.
  The agent/runtime/storage run reports 235 passed and one fixture failure:
  its synthetic entry copied the host's supported-version matrix instead of
  exact requirements. That fixture now uses registration requirements; its
  focused inventory/inspection rerun passes all 3 original cases (plus the new
  registry dependency case below). The HTTP/UI/channel/builtin/profile remainder
  reports 200 passed and one cross-process recovery failure, resolved below.
  The original reports are retained rather than described as green full runs.
- The emitted-client acceptance fixtures are now included in a standard Gene
  integration case. It passes all eleven previously manual feature fixtures,
  including stream sequencing, subscription disposal, background-session
  isolation, notifications, output, menus, Slack identity and voice. The
  existing Spotlight case covers the remaining three browser fixtures.
- Final inspection found that registry requirements worked at activation but
  were rejected by passive descriptor metadata. The same existing requirement
  now retains its registry identity in metadata; snapshots capture immutable
  registry owner/revision data, so catalogs and plans use the leased owner.
  Plans count an observed definition only while its provider is unchanged and
  enabled. A new integration case passes pending/ready metadata, inspection,
  dependency impact, withdrawal, reactivation, old-lease selection and restart.
  All 24 focused metadata/composition/registry/compatibility cases pass.
- The cross-process failure's retained transcript records an instruction
  renderer failing with "callback activation revision has retired". Callback
  table retirement rebuilt an unsynchronized list and could discard a different
  activation's newly added callbacks. Registration, lookup and retirement now
  share one gate; plugin invocation runs outside it. A concurrent live-owner
  regression and both cleanup cases pass (3), and all eleven authenticated
  fake-peer crash checkpoints pass without replay. The seven responsiveness,
  budget and leased-registry cases pass after this fix.
- The final public participant/compatibility run passes 12 cases, and the
  manager HTTP/recovery/reversion run passes 4. Reports are retained in
  repository-root `tmp/harness-batch6-{unit-final,integration,http-ui,
  cleanup-final,registry-metadata-final,public-final,supervision-final,
  callback-race,manager-http,client,cross-process-final}.log`. The actual scan
  is `tmp/harness-retired-views-scan-final.log`. No live Slack transport or model
  service was used in these checks.

## Final acceptance audit

The final gate is the accepted review body and its compatibility addenda, not
only the deliverable labels above. The completed audit maps the implementation
and exercised acceptance cases below to every batch and review requirement.
The broad reports and focused corrections are recorded above, including the
unchanged theme failure and calendar environment limitation. They do not leave
an unqualified architecture acceptance case.

| Requirement | Implementation and acceptance source |
| --- | --- |
| Disabled trigger reads/writes, disabled boot and live withdrawal | `web/routes/triggers.gene`; `tests/integration/web/trigger_routes_spec.gene` |
| Reference organization, inventories and private dead-code deletion | `docs/design.md`, `docs/plugins.md`, `docs/web-client.md`, `docs/proposals/`, `docs/verification/`; removed recording view/model client/profile helper |
| Operator inbox preserves ownership, keyed revisions, foreign entries and restart | `notifications/host.gene`, `notifications/publisher.gene`; `tests/integration/notifications/host_spec.gene` |
| Built-ins use public imports and cleanup rather than internal managers | `runtime/public_modules.gene`, `builtin/`; `tests/unit/builtin/import_policy_spec.gene`, `tests/integration/runtime/public_sdk_spec.gene`, `plugin_cleanup_spec.gene` |
| Declarative registries, guarded contributor callbacks and owner policy | `registries/`, generic kernel registry machinery; `tests/integration/runtime/registry_extensions_spec.gene` |
| A/B/C leased replacement, pending/reactivation and final-reader cleanup | `runtime/cordis_adapter.gene`, `runtime/composition.gene`; `registry_extensions_spec.gene` |
| Narrow Media/Trigger/Channel/Session/Voice/UI/Workspace/Computer/Operator/Composition services | Opaque host modules under `runtime/`; API-only stored replacement tests for those services and SDK; empty private-import exception list |
| Static host wiring in normal/recovery modes, partial-open unwind and workspace ownership last | `runtime/host_services.gene`, `runtime/runtime_services.gene`, `web/service_lifecycle.gene`; unit runner, real-runtime prefix and session-service prefix failure-injection tests |
| HTTP feature extraction preserves shared admission and unavailable behavior | `web/routes/`, `web/server.gene`; feature admission, auth, trigger, voice, image, media, channel and plugin HTTP tests |
| Client extraction preserves coordinator ordering and isolation | Feature client modules, `client/feature_events.gene`, stream coordinator; emitted-client/browser fixtures for sequence gaps, stale epochs, subscriptions, replacement, selected/background sessions and page-owned output |
| Mandatory participant transaction, delegation then cards, one lease and no phase replay | `runtime/turn_participants.gene`, `turn_participant_registry.gene`, `docs/turn-participants.md`; engine, internal-consumer and production-loop failure/cancellation tests |
| Unconditional protocol records and base Outcome rules; owned/schema-checked extensions | `agents/outcome.gene`, `agents/outcome_admission.gene`, `runtime/outcome_extensions.gene`; Outcome unit cases and public participant/schema integration cases |
| Owned initiator rows replace controller source-prefix policy | `runtime/initiators.gene`; initiator policy and integration tests, channel admission and historical-receipt cases |
| Exact requirements, shared compatibility check and immutable archives | `runtime/interface_policy.gene`, storage load/verify paths, plan validation; interface-policy unit cases and `interface_compatibility_spec.gene` |
| Legacy command/prompt/receiver behavior versus explicit public opt-in | `runtime/public_context.gene`, `public_host.gene`, `command_scope.gene`; actual loader, command, input-mode, restart, lease, cleanup and historical-revert cases |
| Stored descriptor scan and explicit public-contract retirement | `tools/scan_retired_views.gene`; scanner units, actual workspace scan, retired-descriptor admission and plan cases; deleted terminal view/render modules |
| Six independently committed batches | Batches 1–5 are `ef7250dd`, `3407bd5a`, `db755a78`, `14fb61b7`, `2a5a383d`; compatibility and this final audit form the sixth separate commit. |

Retained version-2 receivers, raw callbacks and runtime seams are the explicit
compatibility interval, not an incomplete migration of built-ins. Native host
state still belongs to the trusted host; the public version-3 API supplies
projections and opaque handles. Shared shell/REPL resources retain their
explicit counted ownership, as the accepted plan requires. No new Gene syntax
or language semantics are introduced.
