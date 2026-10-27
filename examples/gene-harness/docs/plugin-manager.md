# Harness plugin manager

Status: implemented and verified. See the
[acceptance audit](verification/plugin-manager-verification.md), the
[implementation ledger](verification/plugin-manager-progress.md), and the
[operator guide](plugin-manager-guide.md) for the implemented
UI and commands. This document defines the design and acceptance contract;
the presence of an implementation does not by itself establish acceptance.

Build a host-owned plugin manager in Recovery UI, also accessible from the
normal workspace. It must remain usable when `plugin_admin`, the sidebar, or
a custom view is disabled or broken.

Operator edits in the manager become reviewable plans. Durable history and
restoration cover every origin of composition changes, including the model,
commands, the REPL, and offline repair.

Preserve the current automatic model workflow: plugin operations queued by a
model turn publish at the turn boundary without an added operator approval.
Direct command and offline repair operations retain their existing execution
boundaries. All paths must record complete revisions through a shared storage
service; the manager must not become the only source of recoverable history.

## Plugin inventory and inspection

Provide a searchable list of built-in plugins and workspace overrides,
including disabled, pending, and failed entries.

| Field | Information |
| --- | --- |
| Identity | Plugin ID, description, documentation |
| Source | Built-in, workspace plugin, or override of a built-in |
| Development sessions | Original creation and current-source conversations, with ordinary navigation; unknown or unavailable associations remain explicit |
| Desired state | Enabled or disabled |
| Runtime state | Active, pending, failed, or not loaded |
| Provides | Declared capabilities and observed registry contributions |
| Requires | Required registry entries and their current providers |
| Required by | Dependent plugins and profile requirements |
| Revision | Code digest, dependency closure, last change, previous versions |
| Diagnostics | Missing requirements, activation errors, validation results |
| Actions | Enable, disable, replace, restore default, revert version, inspect history |

Selecting a requirement should explain who satisfies it or why it is missing.
Dependencies are registry-entry requirements, so the UI should show the
resolved provider rather than assuming every requirement names a plugin.
Reverse-dependency inspection should include transitive effects.

Plugin `provides` declarations are not necessarily exhaustive. Show declared
capabilities and observed contributions separately, and improve built-in
declarations where appropriate. `plugin_admin` now declares its contributed
functions and documentation, including history and reversion. An absent
declaration must not be presented as proof that a plugin contributes nothing.

Persist the last verified descriptor metadata and contribution inventory.
Recovery can then explain disabled or unloadable plugins without executing
their code. Label historical observations so they are not confused with
currently active contributions. Associate observations with the exact source
digest and host build. Missing metadata remains unknown during passive
inspection. Offer an explicit restricted descriptor read to attempt to fill
that gap without granting the candidate outward namespaces; failure must not
automatically retry with broader grants.

## Draft changes and impact preview

Enable and disable controls update a draft. A visible pending-changes bar
offers review, validation, apply, and discard. Multiple changes can be staged
together, such as disabling one provider and enabling its replacement.

The workflow is:

```text
Edit draft → inspect impact → validate → apply → inspect result
```

The impact preview describes concrete consequences. For example:

> Disable sidebar: removes conversation navigation. Open conversations
> continue. Recovery navigation remains available.

> Disable this provider: two plugins will become pending, and the configured
> model will become unavailable.

Do not silently disable dependents. Offer to add affected plugins to the
draft and show the resulting composition before applying it.

A plan identifies its base composition revision and exact candidate digests.
Validation results belong to that plan. Editing the plan, changing the host
or profile, or applying a concurrent composition change invalidates relevant
results. Apply must recheck these identities under the composition mutation
gate and reject a stale plan.

A common conflict is a model turn publishing a plugin replacement while the
operator has a draft open. Show what changed and offer to rebuild the draft
against the new revision, then revalidate it. Do not silently overwrite that
replacement or reuse the old validation result.

## Validation before application

Keep pre-application checks separate from application results:

| Level | Checks |
| --- | --- |
| Structure, without candidate execution | Parsed source shape, digests, dependency closure, declared interface compatibility |
| Restricted descriptor read, executes code | Load with an empty namespace grant list, run bounded `init`, and validate its returned descriptor |
| Composition prediction | Missing requirements, conflicts, affected dependents, expected profile readiness and configured provider availability |
| Application result | Full-grant load, descriptor revalidation, admission, activation, validated contributions, and runtime readiness |

The runtime already supports loading candidate code with an empty namespace
grant list. Use this for requested inventory refreshes, archived entries
without metadata, and version-reversion previews. Candidate code can compute
its descriptor but cannot directly access `fs`, `net`, `os`, `ffi`, or other
withheld outward namespaces. It still executes code, so make it an explicit
operation rather than initializing every plugin at recovery startup.

A probe with the real shared `src/plugin_api.gene` import confirmed that a
restricted module can return the canonical `Plugin` type. A descriptor with
an I/O-dependent `init` failed under empty grants and succeeded under full
grants. A pure `init` could return an activation callback containing I/O;
reading the descriptor did not require calling that callback.

For the manager integration, bound loading, compilation, initialization, and
`init` with memory and wall-clock limits. Use a disposable sandbox
generation, extract inert metadata, and discard it without publishing
candidate declarations or retaining callbacks. The existing sandbox
transaction API is a foundation for this lifecycle. Admit only the trusted
shared plugin contract and the verified dependency closure; run without a
live turn context, host handles, or other mutable capabilities. Shared
contract functions remain trusted code and must not confer unintended
authority. Empty namespace grants alone are not proof about arbitrary shared
functions supplied by a host.

If loading or `init` needs a withheld capability, fails, or exceeds its
budget, retain the failure diagnostic and mark metadata unknown. That result
does not prove the plugin would fail under normal activation. Never invoke
`activate` or silently widen grants to complete a restricted read.

Activation still needs a fresh full-grant load under registration's current
trust model. It must revalidate the resulting descriptor; restricted-read
metadata is evidence, not an activation object. A manager plan must reject
a full-grant descriptor that contradicts the contract the operator reviewed.
Full-grant initialization and activation can access files, network, and
processes, and budgets do not undo their effects. The existing model
registration path retains its bounded full-grant descriptor preflight.

Composition predictions use declarations and retained observations. Dynamic
or undeclared contributions can leave a result unknown until activation.
Report unverified checks explicitly; passing preflight does not establish
state compatibility, successful UI rendering, or working external services.

An isolated trial host is outside the initial scope. A future design would
need enforced effect restrictions and disposable state, not just a temporary
directory. The restricted descriptor read above is narrower than an isolated
activation trial; there is no established workflow for the latter in
Harness. Even a restricted trial would not verify live provider,
computer-use, or trigger integrations whose effects it denies.

The target application behavior is to keep the current composition published
until the candidate is accepted, then publish the reviewed set as one change.
Existing snapshot leases allow work already using an older composition to
finish before its resources retire. Whole-plan publication and failure
handling must ship with multi-change drafts, not as a later enhancement. The
reviewed set needs one desired revision and one accepted publication, without
an intermediate provider-less composition between disable and enable.

Boot's `put_cordis_plugins` stages admissions and reconciles once, but is not
the manager's live batch operation. The manager uses `apply_plugin_set` and
the adapter's `reconcile_strict` path to stage replacements and removals,
check acceptance, commit desired state, and publish the set. Ordinary
reconciliation can retain a failed plugin's old revision while accepting
peers; that behavior must remain separate from reviewed batch Apply.

Record validation and application failures with the attempted plan. Preserve
the previous usable composition when candidate admission fails. General
external effects cannot be undone by switching plugin code, so activation
and migration effects need explicit handling rather than a blanket promise
of transactional rollback.

Manager plans use an all-or-nothing acceptance rule. Stage the complete
candidate set; every enabled entry must be accepted at its requested version
and the plan's readiness policy must pass before committing a new desired
revision or publishing the candidate. If any entry fails, publish none of
the candidate set, dispose candidate instances that already activated, keep
the old desired and published revisions, and archive a failed attempt with
its diagnostics. Record disposal failures too; they must not be presented as
a clean rollback. The UI must explain that disposal does not undo external
effects. Recovery repair plans may explicitly permit pending or unavailable
entries; their declared repair policy determines acceptance instead of
claiming normal readiness.

The shared service must therefore support two explicit commit orders:

- **Reviewed manager plans:** prepare and accept the whole set, then commit
  the desired revision and publish it. Failed attempts do not consume a
  composition revision. Persist enough acceptance/commit information to
  recover an interrupted publication deterministically.
- **Existing model and direct publication:** retain commit-before-activation
  and quarantine behavior. Archive the desired revision and its actual
  activation outcome, including a failed entry retaining older live code.

Offline repair commits desired state without activating it. It records that
activation and readiness are unverified until normal startup, rather than
claiming that the manager's live acceptance rule was satisfied.

The manager's normal Apply should protect profile readiness. Recovery should
allow an explicit repair change that leaves the workspace degraded, such as
disabling a broken required plugin, while explaining what remains
unavailable. Saving a repair must not require the broken plugin to activate.
These manager policies do not add a review gate to automatic model changes.

## Durable history and reversion

Store immutable manifests for the complete plugin composition. Each manifest
records plugin IDs, source digests, dependency closures, enabled states,
limits, interface versions, and the profile and host build identity.

Define host build identity before writing the first archive record. A version
string, Git commit, or interface version alone does not identify the code
running the host, especially from a modified source checkout.

Use a versioned, content-addressed host build record with these inputs:

| Field | Identity input |
| --- | --- |
| `format` | `1`, the host build record schema version |
| `runtime_digest` | SHA-256 of the actual Gene executable bytes |
| `host_inputs` | Harness application target and the resolved host package/dependency closure, including built-ins, the shared plugin API, selected resources, and declared native artifacts; record package source-tree digests and artifact digests where applicable |
| `interfaces` | The exact `current_interfaces` map |

Compute `host_build_id` as the SHA-256 of this record using the package
system's canonical data encoding. Identify package nodes by logical name,
version, and content digest; record alias edges and sort them deterministically.
Use normalized package-relative file paths. Reuse package source snapshot
and artifact digests; do not define a second tree-hashing scheme inside
Harness. Location-derived resolver IDs, absolute checkout paths, timestamps,
Git working-tree status, and display labels must not affect the digest.
Runtime version strings, build flags, and a Git commit may be retained
separately as explanatory metadata.

For a built application, use its authenticated package/artifact closure and
the actual executing runtime. For source execution, capture immutable
selected source snapshots before loading the host and use those snapshots
for that host lifetime. Local path dependencies and uncommitted source edits
must affect the identity. Never label an already running instance using
whatever source or executable happens to be on disk after it started.

Persist the host build record once under its digest. Composition manifests,
descriptor observations, and readiness observations reference that same
record. Record the selected profile separately; workspace plugin blobs,
workspace data, credentials, and mutable configuration are outside the host
build identity. Configuration still participates in readiness and plan
validation. This fingerprint identifies declared host inputs, not the whole
OS or the behavior of external services, and does not by itself make an old
build available to run.

New commits require a complete host build record; do not silently substitute
`gene --version` or an unknown identity. A migrated baseline or backfilled
historical revision whose original build cannot be established must say
`host_build_id: unknown` and separately record the build that imported it.
Do not attribute today's host to a historical commit. Comparisons involving
unknown builds report uncertainty rather than claiming a match.

Each revision also records its parent, author or origin, timestamp, reason,
validation report, and application result. Capture provenance at the calling
boundary. Existing entries contain `by`, `model`, `session`, and `turn`, but
some fields are optional or empty; do not invent an author or model when it
is unknown.

Distinguish the desired revision, the runtime's accepted revision, and a
recorded readiness observation. Define "ready at application" to mean all
enabled entries match their requested revisions, none is pending or
quarantined, and profile requirements and configured-provider readiness
pass. Record the time and host build of that observation. This establishes
composition readiness, not application correctness or external-service
health. An offline repair has no such observation until normal startup.
An operator may separately pin a revision as known-good after using it.

Keep default restoration and historical reversion distinct:

- **Restore default:** retain `restore_plugin id` and CLI `restore ID` with
  their existing meaning: drop an override and return to the current profile
  default. This still requires a built-in default for that ID.
- **Revert plugin version:** create a change using one historical entry,
  check it against the current composition, and show the persisted-state
  provenance and compatibility limits described below.
- **Revert composition:** create a new plan containing the
  historical plugin configuration, then validate it on the current host.

Reverting to revision 12 while on revision 20 creates revision 21, referencing
revision 12 as its reversion source. It does not rewind the revision
counter or erase intervening history.

Start with durable manifests and single-plugin reversion before building
the draft editor. A revert request identifies a historical entry, including
its digest, dependency closure, interfaces, and limits; a root digest alone
is insufficient. Preserve the current enabled/disabled setting unless the
operator explicitly changes it. Reuse publication and replacement machinery,
with an expected-base revision check, without requiring the later draft UI.

Expose single-plugin reversion through these surfaces:

| Surface | Operation and behavior |
| --- | --- |
| Recovery page | History per plugin, select an archived entry, inspect the change, and Revert version |
| CLI | `revert ID --revision N`, where N identifies the archived composition containing the entry; default mode uses the running host |
| Offline CLI | `revert ID --revision N --offline`; hold the workspace lock, validate inert records and blob integrity, and commit desired state without loading descriptors or activating plugins |
| `plugin_admin` | `revert_plugin id revision`, using the same historical-entry service and the existing turn-boundary queue when invoked by the model |

The CLI provides `history [ID]`, and `plugin_admin` provides `plugin_history`,
so callers can choose a retained revision before requesting reversion.
A revision is a composition revision, not a digest or a
per-plugin counter; reversion fails if that revision has no restorable entry
for the requested ID. Do not infer omitted metadata from whichever code is
currently active. Historical reversion must not implicitly create missing
history or fall back to restoring the built-in default.

Each revert captures a base revision when prepared and checks it when
committing, including queued model reverts. The manager passes its observed
base revision explicitly; other clients should be able to do the same.
Offline reversion never preflights candidate code automatically. Online
reversion initially reuses direct publication semantics, including quarantine
on failure; label that outcome. Reviewed live manager plans use their
all-or-nothing acceptance rule.

Archive committed manifests at the shared composition write boundary so
model publications and offline changes are covered. Make archival publication
crash-consistent with the authoritative revision: startup must distinguish
an uncommitted candidate from an applied revision whose outcome was not yet
recorded. Store later validation and activation outcomes as appended records
rather than mutating an immutable manifest.

History starts with the current revision when this feature is introduced.
Backfill only complete entries recoverable from existing records. Older code
blobs or digest-only events are not enough to invent missing closures,
limits, or provenance.

The history archive must retain every code blob and dependency referenced by
retained manifests. The current module store has no collector; preserve that
behavior initially. A future collector must respect history references and
pinned revisions. Ordinary crash-recovery checkpoints are not a sufficient
history store.

Restoring plugin code preserves application data by default. The current
plugin contract has no declared state schema or compatibility callback.
Although stored `plugin/state` events have a `state_version` field, the
`PluginHost.update_state` API does not expose a version or compatibility
contract. The manager cannot infer that an older spreadsheet plugin can read
the current workbook format.

As a follow-up to the archive and reversion core, add host-recorded provenance
for the plugin revision that last wrote each managed workspace or session
state. Attribute a write to the executing plugin revision, including a leased
older revision, rather than whichever revision is currently desired. When
restoring different code,
show that state compatibility is unverified. A matching digest is useful
evidence, not proof of compatibility. Legacy state, custom event projections,
and directly written files may have unknown provenance; do not imply that
the host tracks all application data.

Do not add schema or migration callbacks implicitly as part of this manager.
Those need a separate plugin-contract design. Conversations, files, workbook
contents, and undo history must not be implicitly rewound with the plugin
configuration. Any data restoration remains a separate explicit operation.

Restoring a built-in default always selects the default bundled with the
current host. Exact historical built-in restoration is outside this manager's
scope; use version control or the matching host release for that. Historical
workspace overrides remain eligible for reversion if their interfaces are
compatible. A whole-composition revert from another host build must show
the current built-in defaults in its diff and must not claim to reproduce
the old host exactly.

## Recovery ownership

Essential inventory, planning, validation, application, and restoration APIs
belong to the host and use the existing owner authentication. CLI operations
and any richer plugin-manager view should share these services. The repair
path must not depend on registered functions supplied by `plugin_admin`.

An optional plugin can provide a richer presentation, while the host retains
a minimal manager in Recovery UI and a stable way to reach it independently
of the sidebar or workspace view.

Recovery also needs a startup mode that reads composition manifests,
historical metadata, and stored diagnostics without loading workspace
plugins. The explicit launcher entry point is
`gene-harness --workspace DIR --recovery`, so an operator can start it even
when a stored plugin crashes normal startup. The mode uses
`open_runtime ^^recovery`, skips normal application stores and execution
controllers as well as activation, serves the host-owned
recovery pages, and refuses new rounds, scheduled work, plugin actions, and
arbitrary code execution. Explicit restricted descriptor reads use the
bounded path described above. Repairs change desired state; Retry normal
startup hands control back to the normal supervised host.

The supervisor may enter recovery automatically after a normal child fails
before signaling startup readiness. Make this a bounded fallback, preserve
the startup failure diagnostic, and show that recovery mode is active. Do not
treat intentional stop or restart as failure or create an automatic crash
loop. If the host cannot open its core stores or bind its listener, report
that remaining failure rather than assuming plugin-free boot repairs it.
The supervisor now tracks a per-start readiness marker and attempts one
recovery fallback. This path and explicit restart handling must continue to
meet the acceptance checks below.

Workspace ownership must remain exclusive; a recovery process must not
compete with a running host for writes.

Do not reuse offline `doctor` as the implementation of passive recovery
inspection. It calls `prepare_workspace`, which initializes enabled stored
plugins. A recovery mode that executes no workspace plugin code depends on
the persisted metadata introduced by the inventory work. Missing metadata
stays unknown unless the operator requests a restricted descriptor read or
normal startup supplies new observations.

## Implementation foundations and remaining limits

The working implementation connects these components. Their presence is
distinct from completing the acceptance checks below:

- [Workspace storage](../src/storage/workspace.gene) stores
  content-addressed plugin code and dependencies, composition revisions,
  built-in overrides, and enable/disable state. Registration performs bounded
  descriptor preflight, but commits desired state before activation.
- [Plugin administration](../src/builtin/plugin_admin.gene)
  exposes registration, inspection, enable, disable, and restoration of
  built-in defaults, plus separate `plugin_history` and `revert_plugin`
  operations. Model changes retain their turn-boundary publication behavior.
- [Retained metadata](../src/storage/plugin_metadata.gene) and
  [inventory](../src/runtime/plugin_manager.gene) distinguish
  declared capabilities, observed contributions, and restricted-read
  evidence. Disabled entries can use retained observations; missing metadata
  stays unknown, and observations from another host remain historical.
- [Composition snapshots](../src/runtime/composition.gene)
  provide mutation serialization, publication, leases, and delayed resource
  retirement. [Manager plans](../src/runtime/plugin_plans.gene),
  [the kernel](../src/kernel.gene), and
  [the Cordis adapter](../src/runtime/cordis_adapter.gene) add
  strict candidate acceptance and a commit boundary before live publication.
  Candidate disposal cannot undo external activation effects.
- [Offline maintenance](../src/runtime/maintenance.gene) can
  enable, disable, or restore entries without loading stored descriptors or
  activating them. Its `doctor` operation does load descriptors and run
  `init`, so it is not a metadata-only inspection path.
- [The web host](../src/web/server.gene) and the independent
  [recovery server](../src/web/recovery.gene) expose the host-owned
  manager. Recovery boot skips workspace plugin activation and normal work;
  [the supervisor](../src/runtime/supervisor.gene) provides the
  bounded startup-failure fallback and explicit retry path.
- [The store implementation](../../../src/gene/stdlib.nim) retains only three
  checkpoint generations. The separate
  [history archive](../src/storage/plugin_history.gene) retains
  complete manifests and appended outcomes; the authoritative composition
  checkpoint carries its committed history head. Referenced module blobs
  remain retained without a collector.
- [Source snapshots and provenance](../../../src/gene/build.nim) capture the
  executable and selected package/dependency inputs before loading. The
  [host identity service](../src/runtime/host_identity.gene)
  persists the versioned build record. Mutable source execution without
  captured provenance cannot supply a complete host identity for new commits.
- [The runtime loader](../../../src/gene/vm.nim) supports restricted namespace
  grants. Harness currently requests the full sandbox namespace set for
  generated plugins; its descriptor preflight is bounded execution with
  effects available, not an isolated trial. The inventory service implements
  an explicit empty-grant read using a disposable generation and inert
  metadata extraction. This does not verify full activation or state
  compatibility.
- [Plugin state](../src/storage/state.gene) stores free-form
  data and host-recorded last-writer provenance in the same checkpoint.
  Activation contexts retain their own digest, so leased older revisions
  remain correctly attributed after replacement. The
  [plugin API](../src/plugin_api.gene) still has no state
  compatibility declaration or migration hook; legacy and unmanaged data
  may have unknown provenance.

The existing `ACTIVE` marker can advance for accepted pending entries. It
must not be treated as proof that a revision met the manager's readiness
criteria.

## Implementation order and acceptance checks

Ship the archive first. Every change made before it exists can lose the
complete historical entry needed for reliable reversion. It depends on the
host identity and storage contracts, not on inventory, drafts, or a web UI.

### 1. Host identity and archive

Define and persist the host build record, then archive complete manifests at
the shared composition commit boundary for every mutation origin. Seed the
current baseline with honest historical provenance. Keep archival writes and
the authoritative revision crash-consistent; later outcomes are appended.

Acceptance checks:

- Model publication, direct commands, and offline repair each produce a
  complete archived manifest with origin and host identity. After more than
  three revisions and a restart, older entries and all referenced dependency
  blobs remain retrievable. Interrupted archive/commit writes recover without
  inventing an applied revision or losing an authoritative one.
- The same runtime and selected host inputs produce the same build ID in
  different checkout locations. A runtime binary change, built-in source
  edit, or local dependency change produces a different ID. Legacy history
  with unknown build identity stays explicitly unknown.

### 2. Inventory and restricted inspection

Add a host-owned inventory service and recovery page showing declarations,
observed contributions, resolved dependencies, and diagnostics. Persist
metadata for passive inspection and offer requested, bounded empty-grant
descriptor reads when metadata is missing.

Acceptance checks:

- Active, disabled, pending, and failed plugins remain inspectable after a
  restart, with declared versus observed contributions and missing providers
  distinguished. Merely opening the inventory runs no workspace plugin code.
- A restricted descriptor importing the real plugin API returns inert
  metadata. I/O-dependent or over-budget initialization produces a diagnostic
  without retrying with broader grants or publishing candidate declarations;
  a subsequent full-grant activation load is independent of the discarded read.

### 3. Single-plugin reversion

Expose archived versions in the recovery page, online/offline CLI, and
`plugin_admin`. Reuse publication machinery, include stale-request checks,
and state that application data is retained and compatibility is unverified.
State-writer provenance and timestamped readiness observations can follow
without blocking the archive and reversion core; missing data stays unknown.

Acceptance checks:

- A model turn replaces a working plugin with one that fails activation.
  After stopping the host, `revert ID --revision N --offline` followed by
  normal startup activates the earlier version. History retains the working,
  failed, and reverted revisions with their origins, while application data
  and the plugin's current enabled/disabled preference are preserved.
- A queued model revert or operator request with a stale base revision is
  rejected without overwriting an intervening change. Missing entries or
  dependency blobs fail explicitly; `restore` still means the current built-in
  default, and no historical revert silently substitutes it.

### 4. Reviewed drafts and atomic application

Add operator drafts for enable, disable, replacement, restore-default, and
reversion, including whole-composition reversion. Ship impact analysis,
preflight results, stale-plan checks, and the specified atomic acceptance and
batch publication rule together.

Acceptance checks:

- In a two-entry plan whose second entry fails activation, the desired
  revision and published snapshot stay unchanged. Running turns retain their
  original leases, staged instances are disposed, and one failed attempt is
  archived with any disposal errors. A successful provider swap publishes
  once without exposing an intermediate composition missing both providers.
- A model publication while an operator draft is open makes that draft stale.
  Apply rejects it until it is rebuilt and revalidated, while the model path
  retains its existing automatic publication and quarantine behavior.

### 5. Recovery startup

Add the recovery launcher mode and bounded supervisor startup-failure
fallback, using the persisted metadata and archive. Refuse normal work in
recovery mode and expose repair plus an explicit retry of normal startup.

Acceptance checks:

- A stored plugin that crashes normal startup leads to recovery mode, where
  it can be disabled using stored metadata without running workspace plugin
  code. Retrying normal startup then succeeds. The explicit `--recovery`
  launcher works without first starting the failing normal host.
- Recovery refuses new rounds, scheduled work, plugin actions, and arbitrary
  execution while preserving owner authentication and exclusive workspace
  ownership. Repeated startup failure does not cause a crash loop; failed
  store opening or listener binding remains a visible diagnostic.

Isolated trial hosts, automatic state migrations, exact historical built-in
restoration, and artifact garbage collection are separate follow-up designs.

Implement Harness policy and tooling in Gene. If isolation or persistence
work exposes broadly useful missing runtime or library capabilities, address
those in `gene/` or `genex/` as appropriate. This proposal does not require new
Gene syntax or an implicit change to language semantics.
