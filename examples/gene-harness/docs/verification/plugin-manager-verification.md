# Plugin manager acceptance audit

Status: **verified** against [plugin-manager.md](../plugin-manager.md).

The full objective is implemented, including managed-state writer provenance.
The contract's explicitly separate designs remain outside this implementation:
isolated trial hosts, schema/migration callbacks, exact historical built-in
execution, and artifact garbage collection.

## Verification gates

| Gate | Result | Evidence |
| --- | --- | --- |
| Full Harness integration suite | 184 passed; no failures/errors | [Report](../../../../tmp/plugin-manager-integration.log) |
| Full Harness unit suite | 69 passed; no failures/errors | [Report](../../../../tmp/plugin-manager-unit.log) |
| Standalone Cordis suite | 22 passed; no failures/errors | [Report](../../../../tmp/plugin-manager-cordis.log) |
| Native provenance suite | 4 passed | [Report](../../../../tmp/plugin-manager-provenance.log) |
| Native store persistence suite | 22 passed | `tests/spec_runner.nim`, store persistence protocol |
| Native package suite | 24 passed, 1 filesystem-specific skip | [Report](../../../../tmp/plugin-manager-package.log) |
| Browser client | Compiled; desktop/mobile workflows verified | Screenshots below |
| Final validation-history regression | 7 plan cases passed, also included in the full integration suite | [Report](../../../../tmp/plugin-manager-plans.log) |
| Final formatting | New manager modules checked; last two formatting edits preserve parsed forms | `gene-fmt`, canonical parse comparison |
| Patch hygiene | `git diff --check` passed | Current worktree |

Earlier interrupted/source-conflict runs are superseded by these stable-source
results. The earlier scheduling timeouts did not recur: all unit tests pass.

## Requirement evidence

Source and test paths below are relative to `examples/gene-harness/`.

| Requirement | Authoritative implementation and verification |
| --- | --- |
| Host-owned manager remains usable without optional UI or `plugin_admin` | `web/plugin_page.gene`, normal/default UI links, host APIs. Browser disabled sidebar and plugin_admin, then restored the complete composition. |
| Searchable built-in/workspace/override inventory, desired/runtime states | `runtime/plugin_manager.gene` and browser client. Inventory tests cover active, disabled, pending, retained metadata and errors; browser search/filter/details inspected. |
| Separate declared and observed capabilities, documentation, historical observations | `storage/plugin_metadata.gene`; inventory and metadata tests distinguish undeclared contributions, disabled observations, and earlier-host evidence. Missing metadata stays unknown. |
| Requirements resolve registry entries to real providers; reverse/transitive effects | Producer/middle/leaf fixture in `runtime/plugin_manager_spec.gene`; browser qa_consumer requires qa_greeter. Explicit dependent staging invalidates validation and never silently applies. |
| Passive inspection executes no workspace plugin code | Marker fixture verifies no init during catalog reads. Recovery skips application event streams/controllers. State provenance reads checkpoint metadata only. |
| Explicit bounded restricted reads, empty grants, disposable generation, no activation or widened retry | Pure, I/O-dependent and spinning fixtures in `runtime/plugin_manager_spec.gene`; native package-authority tests; generation discarded in ensure. Diagnostics persist separately. |
| Full-grant descriptor is independently loaded and revalidated | `plugin_plans.gene` compares inert reviewed descriptors; Cordis verifies the actual source graph and contract. Explicit mismatch test rejects before activation. |
| Draft enable/disable/replace/default restore/plugin and composition reversion | Browser exercises each operation. Source editor accepts root and dependency modules; plan entries retain complete closure/interfaces/limits. |
| Concrete preview, including additions/removals and exact versions | Client renders `plan/diff` before/after enabled states, digests, closures and limits. Browser whole-composition reversion displayed removal and retained-state provenance, then was discarded. |
| Profile/host/configuration/concurrent changes invalidate validation | Fingerprints checked under the composition gate and again before commit. Tests change host, profile, config and model composition. Browser stale Apply names the intervening change and requires rebase plus revalidation. |
| Atomic acceptance and one publication, preserving old leases | Four atomic-plan cases cover failed second entry, unchanged desired/published revisions, old leased calls, cleanup failures, and provider handoff without an intermediate missing provider. |
| Failure cleanup and external effects represented honestly | Candidate disposal diagnostics are archived; validation/UI explicitly says disposal cannot undo external initialization/activation effects. |
| Failed validation retains the attempted draft and diagnostics | Malformed-source and invalid-report tests preserve requests/plan references across reopen without changing desired or published revisions. Browser confirmed the malformed draft remained in history after restart at revision 15. |
| Recovery repair may remain degraded without activating broken code | Recovery validates inert state/restricted evidence and saves desired entries only. Crash/repair/retry integration and browser recovery workflow pass. |
| Model/direct automatic publication and quarantine preserved | Existing turn queue and direct commit-before-activation path retained. Full integration suite and real failed-model/offline-revert CLI workflow pass. |
| All mutation origins share complete immutable history | `storage/workspace.gene` shared commit boundary; model/direct/offline fixtures inspect origins, entries and host IDs. Command context is captured at the calling boundary; unknown author fields are not invented. |
| Exact, location-independent host identity with immutable lifetime | Native tests execute captured bytes after editing root/dependency files, compare relocated graphs, detect input changes and reject mutable provenance. Host record includes runtime bytes, captured closure and interfaces. |
| History manifest includes limits, reason and validation evidence | Entry limits and effective profile limits are retained; direct registration records bounded-descriptor validation, manager revisions reference immutable plans, baseline validation/reason can be explicitly unknown. Later results are appended. |
| Legacy identity remains unknown; old writers cannot erase history | Baseline tests retain unknown original host plus importer. New checkpoint format is 2; inspected prior reader accepts only format 1 and rejects newer formats. |
| Crash-consistent archive authority | History head is in the authoritative composition checkpoint. Orphan/pruning tests and injected precommit/lost-ack/unreadable-authority failures pass. Reopen recovers the committed revision without replay. |
| Desired, accepted and readiness observations remain distinct | Separate fields and timestamped outcome records. Browser history shows runtime_open separately from final ready startup, with observation host and diagnostic. ACTIVE alone is not used as readiness proof. |
| Operator known-good pins and paginated history | Pin immutability unit assertions, browser pin/unpin and CLI pagination. Annotations do not rewrite manifests. |
| Single-plugin revert on all requested surfaces | Browser, online/offline CLI, and plugin_admin share retained-entry verification. Actual online CLI switched versions and restored the prior one; model failure/offline repair/normal restart passed. |
| Reversion creates a new revision and preserves enabled preference/data | History tests retain working/failed/reverted origins, workbook-like application data, and a disabled preference. No event-store/file rewind occurs in reversion. |
| Stale queued/operator reverts and missing/corrupt blobs fail explicitly | Reversion tests and online CLI stale-base rejection. No fallback to current defaults or fabricated history. |
| Full closure survives more than three checkpoints and restart | Real helper module fixture passes five revisions, offline repair and reopen, verifies both retained blob hashes, and keeps historical entry identity. No module collector is introduced. |
| Quoted dependency code remains usable by the model | Location-normalization unit test preserves other metadata/frozen syntax. Model tests cover canonical dependency paths and exact-node paths computed inside a response. |
| Managed-state last writer is the executing revision, including old leases | Dedicated provenance test holds an older function across replacement, writes from old/new revisions, verifies both digests/host IDs, reopens recovery and normal mode, and verifies unknown legacy writes. State and provenance share one checkpoint. |
| State compatibility is unverified and data restoration remains separate | Details and plan warnings show retained state and provenance. Matching code is not claimed to prove compatibility; custom projections/files may remain unknown. |
| Current-default restoration and cross-host limits are explicit | Separate restore/revert operations. Browser cross-host composition preview lists current built-in defaults and warns it cannot reproduce the old host. |
| Durable results prevent replay after lost response/interruption | Completed-plan idempotence test and actual process exit during Apply pass. Persisted applying records from an old epoch become interrupted and cannot be replayed. |
| Owner auth, CSRF and exclusive workspace ownership | Normal/recovery route tests, owner-client/credential tests, and workspace lock fixture pass. Recovery refuses rounds, arbitrary execution, scheduled work and plugin actions. |
| Explicit recovery launcher, bounded fallback and normal retry | Explicit recovery never initializes the crashing plugin. Supervisor records pre-readiness failure, falls back once, retries repaired normal startup on the same port, and exits on unrepaired core-store/listener failure. |
| Reusable runtime fixes and Gene policy/tooling | Harness policy remains Gene. Package provenance/snapshot APIs reuse the package runtime. Store corruption checking and safe excluded-subtree pruning are covered by native suites. No Gene syntax change. |

## Browser evidence

The disposable workspace is `tmp/harness-manager-ui`, served at
`http://127.0.0.1:56706/plugins`. It is at revision 15 with no draft; all
defaults and both verification plugins are enabled. The previous Gene Sheets
workspace and workbook were not modified.

Desktop and 390px mobile screenshots are saved as
[desktop](../../../../tmp/plugin-manager-desktop.jpg) and
[mobile](../../../../tmp/plugin-manager-mobile.jpg). Mobile document width equals
viewport width. The fresh conflict-test tab reported no console warnings or
errors.

## Operational result

The optimized native runtime is installed atomically at `bin/gene`.
Same-checkout snapshot startup improved from 5.25s to 1.05s after excluded-tree
pruning. The initial comparison across different checkouts did not isolate
browser compilation cost and is not used as evidence for that optimization.

Reports, screenshots, and the disposable demo are local verification artifacts
retained under the ignored `tmp/` directory; they are not part of the commit.
