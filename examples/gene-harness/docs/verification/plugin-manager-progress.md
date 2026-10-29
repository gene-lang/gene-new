# Plugin manager implementation

Status: implemented and verified. The contract is now consolidated in [plugins.md](../plugins.md#plugin-manager);
[the acceptance audit](plugin-manager-verification.md) tracks each requirement.

## Delivered behavior

- Host-owned manager at `/plugins`, reachable independently of sidebar,
  workspace view, and `plugin_admin`.
- Searchable inventory with declared/observed capabilities, resolved providers,
  transitive consumers, retained metadata/errors, source closures and limits.
- Explicit bounded descriptor inspection with empty outward grants, discarded
  generations, no activation, and no silent grant widening.
- Tab drafts, complete before/after composition diffs, dependency impact,
  explicit dependent staging, stale-change detail and rebase/revalidation.
- Strict candidate acceptance, one durable desired commit and one publication,
  preserved old leases, rejected-candidate disposal and recorded cleanup errors.
- Immutable composition/host records with an authoritative checkpoint head,
  all mutation origins, retained blobs, validation records, readiness outcomes,
  failed attempts, pagination, and known-good pins.
- Version reversion through browser, online/offline CLI, and model functions;
  default restoration remains separate. Existing automatic model publication
  and quarantine semantics remain intact.
- Managed-state writer identity captured per activation, including older leased
  code, committed with state. Legacy/unmanaged state remains unknown.
- Independent authenticated recovery boot, exclusive workspace ownership,
  restricted routes, desired-only repair, explicit normal retry, and one
  supervisor fallback with startup diagnostics.
- Immutable package snapshots and exact runtime/host-input identity. New
  composition checkpoints use format 2; the old format-1 reader refuses them.

## Verification

- Final Harness unit suite: **69 passed, 0 failed, 0 errors**.
- Final full Harness integration suite: **184 passed, 0 failed, 0 errors**.
- Standalone Cordis suite: **22 passed, 0 failed, 0 errors**. Its lock was
  refreshed for the intentional file-selection manifest change.
- Focused manager acceptance: **27 passed**, including real dependency
  retention, model exact-node hashing compatibility, stale plans, all-or-nothing
  failure, provider handoff, leased state writers, interrupted Apply, checkpoint
  faults, and normal/recovery behavior.
- Revised CLI/notification/UI/recovery suite: **17 passed**, including owner
  authentication, CSRF, restart, lock/cleanup behavior, corrupt core stores,
  occupied listeners, and bounded recovery fallback.
- Native provenance: **4 passed** against the latest package implementation.
- Native store persistence: **22 passed**, including missing generations with
  a published CURRENT pointer.
- Native package suite: **24 passed, 1 platform-specific skip**, including
  recursive exclusion selection and unchanged digests/stamps for excluded data.
- Current browser client compiles. Browser checked all draft operations,
  sidebar/plugin_admin independence, version/composition reversion, conflict
  rejection across tabs, explicit rebase, retained-state warnings, cross-host
  defaults, history outcomes, and operator pins.
- The final conflict check named the intervening `budget_advisory` change,
  kept Apply disabled, and required validation after rebase. Both test plugins
  and all defaults are enabled again at revision 15.
- Desktop/mobile evidence is in `tmp/plugin-manager-desktop.jpg` and
  `tmp/plugin-manager-mobile.jpg`. At 390px the document width equals the
  viewport. The final test tab reported no console warnings/errors.
- Earlier broad run: 163 passed, 12 failed. Source edits
  invalidated some captures; focused reruns corrected timing, dependency-hash,
  and obsolete sidebar expectations. The final stable-source run supersedes it.
- Final validation-history regression: **7 plan cases passed**. Malformed
  drafts and invalid reports are retained with diagnostics; the browser
  confirmed persistence across restart without advancing revision 15.

## Issues exposed and fixed

- Frozen-source execution exposed documentation paths that searched mutable
  checkout parents. Docs now resolve captured package resources, with an
  explicit Gene reference dependency.
- Candidate registry lookup could read the old snapshot and leave consumers
  pending. Candidate lookup now reads candidate rows; leased reads stay stable.
- Candidate cleanup could reacquire a held registry gate. It now uses the
  publication context during reconciliation and reports disposal errors.
- Package materialization/native-module loading could bypass namespace grants.
  They now require filesystem/native-code authority.
- Checkpoint errors after CURRENT advanced could be mistaken for rejection.
  The writer rereads authority and marks unreadable outcomes uncertain.
- The filesystem store treated CURRENT with missing generations as empty.
  It now reports corruption, allowing bounded recovery failure reporting.
- Reader locations changed hashes of model-quoted dependencies. New source
  canonicalization removes location metadata while preserving other metadata
  and frozen syntax. Explicitly imported exact-node dependency spellings remain
  supported.
- CLI imports unnecessarily prepared the manager client. Web startup now warms
  that client, while CLI imports defer it.
- Snapshot discovery walked recursively excluded temporary trees. It now prunes
  only directories whose entire subtree is excluded; selection semantics stay
  unchanged. In the same populated checkout, startup fell from **5.25s to
  1.05s**. The earlier 10.64s/0.82s comparison used different checkouts and did
  not isolate client compilation from directory-scanning cost.
- History distinguishes an early `runtime_open` observation from final web
  `startup` readiness after the loop and other services are available.
- Whole-composition removals exposed absent values in the browser diff renderer.
  They now render as explicit absent values without blocking controls.
- Early validation errors escaped before a plan existed. They now append a
  durable attempted request and diagnostic; invalid reports reference their
  immutable plan. Validation failures never consume a composition revision.

## Environment and finish checks

- Installed binary: `bin/gene`, atomically copied from
  `tmp/gene-plugin-manager-optimized`; SHA-256
  `99ee32ed5f3f2e2a13480ac55f0118095ebc3bcf14f1471aae5aacb364f8f563`.
  Running processes kept their prior executable inodes during installation.
- Test stores: `/private/tmp/gene-harness-manager-packages` and
  `/private/tmp/gene-harness-manager-artifacts`.
- Disposable demo: `tmp/harness-manager-ui`, port 56706, normal offline mode.
  The earlier Gene Sheets workspace/workbook remains untouched.
- Formatting checks are complete; the final control/startup formatting edits
  preserve their canonical parsed forms. Desktop/mobile evidence reflects
  revision 15 on the installed runtime. The acceptance audit is closed.
