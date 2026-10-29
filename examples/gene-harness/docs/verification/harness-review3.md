# Harness design review 3 implementation

Source: `tmp/harness-review3.md`, reviewed baseline `b6856d27`.

Status: **complete and verified — 2026-10-29**. The final complete suite passed
677 tests on unchanged functional inputs. See Final verification below.

This is an implementation and verification record, not a reference contract.
Unchecked requirements remain in scope until implementation and direct evidence
are recorded here.

## Requirements

- [x] Delete dead workspace turns/status and kernel turn recorders; reduce the
  facade to 45 exports and remove string composition-event turn identifiers.
- [x] Remove private loop/voice-runtime bindings with their filters; retain
  public receiver lifecycle, projection and unsupported-version coverage.
- [x] Remove compatibility imports, request ownership inference, first-prompt
  media reconstruction, workspace alias, flat themes and old browser reply
  upgrade. Remove initiator/operator fallbacks and rename unknown-source data.
- [x] Give all profile plugins public receivers and callback projections;
  preserve host budgets and mandatory-participant policy. Keep direct kernel
  contributions on kernel contexts. Move the provider text helper to the SDK.
- [x] Move Outcome feature data into owned extensions; retain declared short
  spellings through leased constructors, reject duplicate spellings, admit
  owned suspension before continuation checks, and consolidate done deferral.
- [x] Make voice a participant; keep reply transcript and wire fields stable.
- [x] Give the loop construction/lifecycle an owner outside web; classify host
  specs by layer and startup mode. Doctor opens only kernel services; metadata
  recovery opens no event/configuration/execution state.
- [x] Extract durable image repair and consolidate catalog validation, reasoned
  session repair and the all-session call sweep in that order. Preserve image
  recovery outside running rounds and controller/channel shutdown order.
- [x] Remove runtime aliases and controller back-patching. Inject session unload
  policy, use receipts for recovery decisions and one per-session rounds map.
- [x] Share next-request assembly between loop and both resume paths.
- [x] Tighten kernel imports, move product services to runtime and split the
  plugin contract/helpers with an exact Plugin:3 retirement boundary.
- [x] Split workspace storage, module registry, activation and operator repair.
- [x] Share the opaque handle table without weakening activation revocation.
- [x] Centralize API paths, voice protocol and browser retention in the web
  contract; enforce the absence of API-version literals elsewhere.
- [x] Replace publication callback slot with subscriptions. Investigate
  published-set duplication and keep evidence for retained state/opaque cells.
- [x] Address smaller ownership observations: service references, web transport
  state, registry-name validation, module basename ambiguity, settled history
  representation and workspace-scoped browser storage. Preserve distinct
  server/browser Slack presentation responsibilities.
- [x] Split design/protocol/contributor documentation, consolidate only docs
  with compatible ownership, remove plan residue while keeping owner decisions,
  correct live drift and indexes, and preserve registered chapters/proposal.
- [x] Verify affected focused suites, complete Harness suite, web build and
  generated event catalog; audit every requirement against current sources.

## Decisions and compatibility breaks

- `panel` remains a distinct docked presentation feature; references describe
  its own defaults rather than a legacy alias.
- No Gene syntax changes were made. Outcome short spellings use the existing
  call/constructor machinery and the recorded owner's decision.

## Evidence

The following evidence records intermediate work and its resolved failures.
The final status is established by the complete run and input comparison at
the end of this record.

- Dead workspace turn/status functions and kernel turn recorders are removed.
  The frozen facade now has 45 exports. Composition events use integer turns
  (zero for work outside a model turn); the generated catalog rejects strings.
- Private `loop` and `voice/runtime` bindings and their filters were removed
  together. Current public-contract tests moved to `plugin_contract_spec.gene`;
  receiver lifecycle, nested command, prompt projection, unsupported versions
  and row/resolve absence assertions remain.
- Mechanical removals cover compatibility import modules, inferred receiving
  turns, first-prompt media reconstruction, workspace alias, flat themes and
  the browser input-reply upgrade. Operator admission now reads only the stored
  operator flag. The collection-marker removal followed with Outcome integration.
- Every Cordis activation now receives the public host and projected callback
  contexts. Direct kernel rows keep raw contexts. Host budgets remain intact;
  profile participants receive an explicit mandatory policy. The text helper
  moved to `public/text.gene` and all in-repo imports moved with it.
- Focused results: cleanup batch **30 passed**; receiver/kernel/SDK batch
  **21 passed**; profile/public-participant/workspace batch **18 passed**.
  No failures, errors or skips in these runs. Full verification followed below.
- The shared `agents/next_request.gene` now prepares receipt references,
  settled text and request sources and writes the matching protocol record for
  ordinary turns, answered questions and delegation resumes. Deferred history
  admission remains after the loop's question/suspension branches. The round,
  continuation, delegation and transaction suites passed **32 tests**.
- Publication observers now have independent cancellation handles. Input-mode
  shutdown cancels only its own subscription. Composition/REPL/current-contract
  verification passed **10 tests**, including two simultaneous observers.
- Profile contract tests passed **2 tests**, including a public participant
  remaining mandatory despite matching persisted quarantine data. A broader
  public-service/participant/UI/image batch passed **15 tests**.
- The leased Outcome constructor is implemented and independently tested
  (**2 tests** initially). The subsequent Outcome integration is recorded below.
- Published-set investigation: retain `BridgeState/published`. Cordis updates
  its `record/current` before rethrowing a retirement failure
  (`runtime/cordis_adapter.gene`, end of `reconcile_composition`), while the
  bridge may not yet have published its registry snapshot. These are different
  publication boundaries, not interchangeable caches.
- Retain the Composer's opaque Cell handle. It prevents structural thaw from
  recursively walking Harness back through its Composer, without changing Gene
  syntax or silently expanding runtime equality/thaw semantics.
- Older history messages now store only their settled `content`; the newest
  request and assistant pair keep full/settled forms. Real provider request
  stability, history policy, persistence and continuation checks passed
  **17 tests**.
- Activation receivers and narrow service handles share `runtime/handle_table`.
  Existing service overrides and public lifetime checks passed **11 tests**.
- Checked extension admission can carry a generic owned suspension before
  core continuation grammar. The primitive rejects done/questions conflicts
  and malformed verdicts. Its initial primitive/public-schema verification
  passed **27 tests** before evaluator integration.
- Wire paths, parsed version segments, voice subprotocol and browser retention
  now derive from `web/contract.gene`. This pure module is explicitly part of
  the SDK so built-in view links use the same contract as host/browser code.
  Receipt retention uses `receipt_limit`. Wire/SDK/import/browser-state checks
  passed **9 tests**; the full main browser module graph built successfully to
  `tmp/review3-web`. Transport verification was pending at this checkpoint.
- Outcome evaluators now use the constructor from the turn/command lease.
  Core Outcome has only grammar fields and checked extensions. Schema inputs
  and consumers use canonical keys, with no alias write-back or legacy context.
  Delegation owns its staging queue and one done-deferral verdict; the generic
  coordinator settles completion after participant commit. Voice contributes a
  participant that projects checked speech into the unchanged reply payload.
  Core/schema/public-participant/voice checks passed **39 tests**. Delegation
  collection, crash recovery, child results, continuation and round/controller
  checks subsequently passed **35 tests**. One earlier run used the removed
  collection marker in its fixture; that assertion now uses `collection_turns`.
- During wire verification, same-directory generated imports initially omitted
  `./`, which failed under captured package execution. Those imports were fixed.
  The next transport run reached listeners and was refused by the sandbox;
  local HTTP verification subsequently ran with loopback access.
- Local HTTP verification with loopback access passed **5 tests**: channels,
  delegation controls, media and both disabled/restored trigger routes.
- `plugin_api.gene` is now an implementation-independent contract. Response
  helpers moved to `public/response.gene`, backed by the calling loop's live
  append/card callbacks; shared error identities are declared in the contract.
  `Plugin:3` is the only supported shared API version. No compatibility shim is
  provided. In-repo imports moved to the helper module, and the obsolete
  `registration_interfaces` alias was removed. Contract/card/image/workspace/
  SDK/import verification passed **49 tests**.

## Subsequent ownership work

- Startup now has explicit normal, doctor and metadata-recovery modes. Every
  production runtime spec declares its layer. Doctor opens kernel specs only
  and ignores execution configuration; metadata recovery still opens no event
  store. The generic graph exposes its opened values as the primary index.
- Catalog admission validates cold streams before repair. The recovery kernel
  orders receipt-based session recovery, the all-session interrupted-call sweep
  and storage-only image reconstruction. Image reconstruction no longer creates
  an ImageHost or imports provider execution. Catalog refusal leaves the event
  checkpoint unchanged. Recovery/image/store checks passed **20 tests**, and
  receipt/cancellation/recovery checks passed **16 tests**.
- Workspace functions now have four acyclic owners: `composition_store`,
  `module_registry`, `workspace_activation` and `workspace_repair`. The old
  `storage/workspace.gene` was deleted and consumers import actual owners.
  Store/history/plan/current-contract verification passed **30 tests**. Follow-up
  inspection tests exposed an old passive-normal-mode fixture and an obsolete
  string-turn assertion; both fixtures now express the current contracts.
- The round controller owns one per-session frame containing task, watcher and
  completion. Round/delegation/continuation/live-delivery checks passed **44
  tests**. The HTTP responsiveness case passed separately with loopback access.
- Browser drafts, replies, confirmations, media and pending actions now use
  workspace-scoped session storage. Both normal and recovery HTML provide the
  same stable identity for a workspace. `tools/verify_workspace_storage.gene`
  builds the actual browser code and checks six state families, quota failures
  and missing identities through Node. That boundary check passed.
- A migration exposed a native regex defect: omitted trailing captures started
  at `(0, 0)` instead of remaining unmatched. Capture initialization now uses
  `(-1, -1)`. All five regex VM tests passed, including nil versus empty groups,
  streams and replacement behavior. The rebuilt CLI at repo-root
  `tmp/review3-gene` also passed a direct probe. It is the CLI used for subsequent
  verification; the workspace's existing `bin/gene` has not been replaced.
- Loop construction lives in `runtime/loop_services.gene`; web observers live
  in `web/observers.gene`. WorkspaceService no longer stores a controller.
  Nested graphs can quiesce before destruction and share one value index while
  preserving ownership of borrowed dependencies. Lifecycle/voice/kernel checks
  passed **15 tests**. A missing voice dependency on participant installation
  was made explicit after the new ordering exposed it.
- Boundary modules now have distinct names: `plugin_receiver`,
  `callback_context` and `plugin_sdk`. Their import/contract checks passed
  **15 tests**. Host registry literals have a source-level declaration guard;
  registry/kernel/workspace architecture checks passed **7 tests**.
- Runtime product fields are moving to the shared service index. Command-owned
  modes and the session unload policy are already implemented; runtime fields
  for commands, actions, images, manager, cards, delegations, voice, queues and
  channels have been removed. Command/profile/voice/kernel/lifecycle verification
  passed **16 tests** after the corrected migration.

The temporary runtime-field migration initially encoded source characters as
character literals. Every affected file was restored with an exact character
round trip before the corrected token-aware rewrite ran; source backups are
under `tmp/runtime-values-character-backup` and `tmp/runtime-values-source-backup`.
This exposed a tooling gap: constructing strings from Char sequences lacks a
direct inverse of `$chars`. No application code uses the temporary converter.

At this checkpoint, remaining work was documentation consolidation, the complete package
suite on unchanged final sources, verify all browser entry graphs and the
generated catalog, and audit every requirement against the final sources.

Existing workspace breaks so far: aliases in workspace metadata fail validation;
flat theme overrides must be reapplied under `light`/`dark`; old inferred
assistant requests without `for_turn` are omitted; old first-prompt media is no
longer reconstructed; old input-reply browser storage is ignored; receipts
without explicit operator admission read as non-operator. Old string-turn
composition events fail catalog validation. Stored sources importing
`src/text.gene` must be re-registered with `src/public/text.gene`.
Stored entries requiring `gene-harness/Plugin:2` must be re-registered for
`Plugin:3`; plugin-side `append_prompt` and `show_card` imports now come from
`src/public/response.gene`. Receipts carrying only `delegation_collection` no
longer grant a collection turn; the coordinator records `collection_turns`.

## Final ownership and greenfield pass

- The runtime constructs one controller and supplies delegation callbacks and
  trigger-host dependencies at construction. Controller-owned command rows
  replace CommandManager callback slots. Trigger managers belong to their
  activation revisions; their resource scope owns scheduling and cleanup.
  The focused controller/trigger/HTTP batch passed **20 tests**.
- `Harness/services` is removed. Runtime values own appearance, UI defaults,
  readiness, inbox state and the UI action manager. UI builders receive the
  runtime; manager revision is read from its owner. Kernel Host delegates
  persistence and publisher operations through injected callbacks, so its
  import allowlist no longer includes storage/state or notifications/publisher.
  Registry ownership and schema admission remain kernel operations. Initial
  adapter checks passed **7 tests**; UI/recovery/appearance checks then passed
  **19 tests**.
- Composition operations accept explicit readiness callbacks and retain them
  through queued publication. The regression proves a missing configured
  provider records degraded readiness, then a newly available provider records
  ready without recreating the callback. The first regression assertion read
  an archive wrapper instead of its `result`; the corrected test passed.
- Bridge state belongs to the Composer. Its published-set distinction and
  opaque Cell remain. The kernel now has 21 fields, with no product-state bag.
  WorkspaceService no longer duplicates events, sessions or the controller;
  its observer scope owns subscriptions. Browser request projections and
  snapshot jobs remain transport caches. Server Slack formatting and browser
  interaction remain separate responsibilities.
- The ownership/history/contract batch passed **17 tests**, with the new
  readiness test initially failing on the fixture assertion above. A separate
  web/manager/UI batch passed **19 tests** and exposed one direct evaluator
  quickstart call missing its newly explicit publication-preview callback.
  That fixture now supplies it, and the quickstart rerun passed **1 test**.
  Final provider/web-session/channel verification passed **27 tests** with
  loopback access.
- Additional greenfield cleanup removed six import-only host wrappers in
  agents, audio and builtin; callers import their public library owners.
  Removed failed-limit receipt projection/resumption, command-output upgrade
  filtering, untagged browser-cookie upgrading, and old pending-action handling.
  Current pause/continue, explicit attachments, generation rejection and receipt
  recovery contracts remain. Their focused batch passed **28 tests**; its one
  provider HTTP case was denied a sandbox listener and subsequently passed in
  the **27-test** loopback run above.
- The compiled main browser graph and real page identity/storage boundary
  passed again after the pending-action change. This exercises six state
  families, workspace isolation, quota failure and missing identity.
- Documentation work has started: design.md now focuses on ownership and
  lifetimes (277 lines); protocol.md owns grammar, bindings, patch/questions,
  all 21 PluginHost messages and the generated-catalog link. CONTRIBUTING.md
  owns development constraints. Short Outcome spellings, protocol 8, README
  helper availability and the verification index were corrected. Remaining
  chapter consolidation and removal of embedded plans/reviews followed below.

Additional workspace breaks: untagged browser credentials require a fresh
owner-link exchange; unsupported pending UI-action formats are discarded;
failed receipts from the retired turn-limit representation are no longer
projected as paused or eligible for Continue. Queued explicit command attachments
are delivered as recorded, with no upgrade filter based on their ids. Native
imports of the six removed wrappers must use their public module owners.

The milestone suite started before this pass ran under session 30218. Sources
changed while it ran, so its result is interim diagnostic evidence only.

- Notification documentation is now a current reference (200 lines), with
  workflow ownership, publisher/NotificationHost APIs, actions, acknowledgment
  and CLI delivery. Plan phases and the superseded behavior description were
  removed. Its HTTP caller was also updated to supply the explicit runtime
  inbox; notification transport and common feature admission passed **2 tests**.
- Manager review threads, historical checks and owner decisions moved to the
  indexed `workspace-manager-history.md` verification record. The reference
  retains the current single-root, API-control, confirmed-deletion and
  credential-free-result decisions, and documents the public WorkspaceHost
  boundary instead of a privileged Harness receiver.
- Event-catalog `--check` reports current. CONTRIBUTING.md is included in the
  package file set so the new documentation link survives package capture.

## Documentation completion and final preflight

- `plugins.md` now absorbs the unregistered manager/source chapters. Their
  duplicated files are removed; the registered manager guide and every owned
  UI recipe remain separate. The reference uses Plugin:3, explicit SDK paths,
  current managed-state provenance and source attribution. Local links were
  repaired after consolidation.
- Theming and sub-agent rollout/review material moved into indexed dated
  verification records. The references describe current per-mode themes,
  service-owned appearance, question wakeups, ordinary limit policy and
  delegation-owned Outcome schemas. Workspace-view navigation and theming
  remain focused, cross-linked human references; merging these optional
  chapters would not remove duplicated contracts.
- Kept audio benchmarks because the voice availability guide cites their
  results. Kept the memory proposal and every registered cross-owner chapter.
  README's implementation map was replaced by links to design, protocol and
  contributor guidance. All **207 local Markdown links** resolve, and a direct
  parse of PluginHost confirms the protocol table covers all **21 messages**.
- The prior milestone run is terminal: **582 passed, 91 failed, 6 errors**.
  It mixed snapshots with changing sources and a stale manifest lock, so it is
  diagnostic evidence only. The package lock was refreshed offline and its
  locked check now succeeds. Remaining stale media/voice/probe fixtures were
  corrected; their focused run passed **15 tests**.
- Removed automatic source-attribution inference and format-1 composition/media
  admission. Current attribution uses recorded metadata only; current media
  reservation and archive contracts remain. Source/planning/history/media
  verification passed **27 tests**.
- Compiled-browser qualification found fixtures using unscoped raw storage.
  They now supply the page's workspace identity and inspect scoped records.
  Missing identity elements also disable persistence, as missing identities
  already did. Compiled feature/Spotlight acceptance passed **2 tests**, and the
  real rendered-page/compiled-module storage check passed again, including the
  absent-element case.
- All five first-party browser entry graphs build independently: conversation,
  plugin manager, website, voice and Spotlight. The generated event catalog is
  current and `git diff --check` is clean.

Additional breaks: composition checkpoints and media indexes require format 2;
unsupported older formats are refused. Entries without explicit creation/source
attribution remain unknown, without archive inference. No existing user
workspace was rewritten or deleted during these removals.

## Requirement audit before the final full suite

The implementation sources and focused evidence support the following mapping.
This mapping was checked against the final unchanged-input suite and the
explicit build, catalog, documentation and native-runtime checks below.

| Review requirement | Authoritative implementation and gate |
| --- | --- |
| 1: one plugin boundary | composition_bridge gives every activation plugin_receiver; registry policies retain host budgets and mandatory participants; profile contracts and public-participant suites |
| 2: feature-free Outcome | core grammar plus CheckedOutcome; leased alias constructor; generic suspension admission; delegation/voice participants; Outcome, schema, collection, voice and transaction suites |
| 3: layer and startup modes | runtime_services layer/mode table; loop_services and web/observers; catalog → receipt repair → all-session sweep → storage image repair; kernel_recovery, image_failure, host/session lifecycle suites |
| 4: remove aliases/back-patching | service value index; trigger activation managers; constructor-supplied delegation callbacks; injected unload policy; receipt authority; one rounds frame; manager revision read from its owner |
| 5: one request assembler | agents/next_request used by loop and both resume paths; continuation, history, questions and delegation recovery suites |
| 6: kernel direction and SDK | host imports no publisher/state implementation; injected callback adapter; no h/services; dependency-free Plugin:3 plus public/response; kernel/import/SDK/provenance suites |
| 7: workspace owners and dead vocabulary | composition_store, module_registry, workspace_activation and workspace_repair; dead turn/status helpers absent; facade45; integer composition-event turns; boundaries and catalog checks |
| 8: participant consumers | public transaction contract retained; voice added beside cards/delegation; public-participant, transaction, voice and response tests |
| 9: receiver and handles | plugin_receiver plus handle_table shared with service_handles; deferred revocation and current contract tests |
| 10: wire contract | web/contract owns API paths, voice subprotocol and relevant bounds; literal guard, transport and compiled browser tests |
| Smaller: publication and composition ownership | independent subscriptions; bridge under Composer; retain published-set distinction and opaque Cell for documented lifecycle/thaw reasons |
| Smaller: runtime/web ownership | nullable product aliases removed; WorkspaceService keeps transport caches; browser_assets basename distinct; Slack server formatting and browser interactions remain separate |
| Smaller: registry/history/browser state | declaration guard; one settled representation for older history; workspace-scoped storage; serialized-prefix/restart and emitted-browser boundary checks |
| Documentation | design/protocol/CONTRIBUTING split; same-owner consolidation; reference drift fixed; dated records indexed; owner decisions, recipes, benchmarks and proposal retained |
| Greenfield ledger | private bindings removed with filters; retired execution/import/ownership/operator/theme/browser paths removed together; explicit unknown/unsupported rejection preserved |
| C1–C5 | no private seam leakage; suspension before continuation validation; modes separate from layers; reply payload stable; all-session recovery retained after catalog/reasoned repair |

Final verification includes the complete package suite, independent browser
builds, actual browser-storage boundary, catalog generation check and input
fingerprint comparison. Only dated verification reports and temporary artifacts
are excluded from the functional-input fingerprint.

The final recovery audit found that catalog admission loads streams outside
the session index too. The consolidated sweep now visits that complete loaded
set after reasoned session recovery, preserving the former boot-stream repair
as well as every indexed session. The regression includes an unfinished call
in an unindexed boot stream. Recovery/image qualification passed **11 tests**.

The first unchanged-input full suite is terminal: **663 passed, 14 failed,
0 errors, 0 skipped**. Before/after fingerprints both equal
`sha256:634d5eb693f15395f3b58abb2b58a22e4d24e827e2fc05c20df845eec472c75d`
across 602 files. Every failure was a native channel fixture using removed
WorkspaceService `events`/`sessions` fields. The four affected specs now read
`harness/runtime/events` and `harness/runtime/sessions`, and controller lookups
use its runtime service owner. Assertions and scenarios were retained; product
code and reference documents did not change. Focused and full reruns followed.

The four-spec channel rerun passed **46 tests**, with one further stale
`restored/sessions` reference exposed deeper in the sharing-restart scenario.
After updating it, all **4 sharing tests passed**. A second full run followed;
only those four fixture files differ from the first frozen-input run.

## Final verification — 2026-10-29

- Complete Harness suite: **677 passed, 0 failed, 0 errors, 0 skipped**;
  process exit 0. Command: `../../tmp/review3-gene test tests` with the isolated
  package/artifact stores and loopback access used throughout qualification.
  Report: `tmp/review3-final-suite2.log`.
- The **602-file** before/after functional-input fingerprints match exactly:
  `sha256:004391a64c7f2b69b47428131df9423def674357f6ac508b0b45deff6cd72744`.
  Reports: `tmp/review3-final-before2.gene` and `tmp/review3-final-after2.gene`.
  The comparison reports an empty changed-file list. Dated verification records
  and temporary output are deliberately excluded; product code, tests,
  reference docs, manifest/lock, catalog, review source and runtime binary are
  included.
- All **five** first-party browser entry graphs build independently:
  conversation, plugin manager, website, voice and Spotlight. Compiled feature,
  Spotlight, submission, media, voice and form recovery checks also pass in
  the complete suite. The rendered-page/compiled-storage boundary passes for
  six state families, workspace isolation, quotas and absent identities/elements.
- All **five native regex VM tests pass**, including omitted versus empty
  captures, streaming matches and replacement. The existing `bin/gene` was not
  replaced; the rebuilt test CLI is the fingerprinted executable above.
- The event-catalog generator's `--check` reports current; the protocol reference
  covers all **21 PluginHost messages**; all **207 local Markdown links** resolve;
  the package lock is current; `git diff --check` is clean.
- Final audit covers findings 1–10, smaller ownership observations, documentation,
  the greenfield ledger and accepted comments C1–C5. Optional retention choices
  are explained above. Every implementation and verification requirement is
  satisfied; no required work remains.

Standalone kernel clients using PluginHost persistence/publication must supply
the runtime callback adapter; normal `open_runtime` composes it automatically.
The recorded version, storage and import retirements remain intentional
greenfield breaks. Existing user workspaces and live services were not rewritten
or deleted to obtain these results.
