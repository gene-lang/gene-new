# Plugin manager

Open **Plugins** in the host control bar, or visit `/plugins`. The manager is
host-owned and remains available when the sidebar, `plugin_admin`, or a
workspace view is disabled.

Search by plugin or capability and select a row to inspect its source, desired
enabled state, runtime status, declared capabilities, observed contributions,
requirements and current providers, and direct/transitive dependents. Disabled
plugins retain their last observations. Observations from another host build
are labeled historical; missing declarations are unknown rather than empty.
Source details include the retained dependency closure and execution limits.

## Review and apply

Checkboxes, source replacement, default restoration, and version reversion
add operations to a browser-tab draft. They do not immediately change the host.

1. Stage changes, including related provider swaps in one draft.
2. Select **Validate changes**. Review predicted dependencies, conflicts,
   affected consumers, and any unverified checks. You can explicitly add
   affected dependents to the draft; doing so requires validation again.
3. Select **Apply changes**. The complete candidate must activate and satisfy
   readiness before its desired revision is committed and published.

A failed candidate leaves the prior composition published, disposes acquired
candidate resources, and records a failed attempt. Disposal failures are
reported. External effects performed by full-grant initialization or activation
cannot be undone by this publication mechanism.

Changes to the composition, host, profile, or configuration invalidate a
validated plan. Refresh and rebase a stale draft, then validate again. A
completed plan has a durable result and is never applied a second time after
a lost response. An interrupted result requires inspection and a new plan.

**Allow a degraded workspace for repair** permits unmet requirements in an
otherwise accepted candidate. Activation failures still reject the batch.
This option does not claim normal readiness.

## Inspection and source

**Read descriptor safely** performs an explicit, bounded read with no outward
namespace grants. It uses a disposable module generation, never calls
`activate`, and never retries with broader grants. I/O-dependent or over-budget
initialization remains unverified. Full-grant loading during Apply rechecks
the reviewed descriptor.

**Add plugin** and **Replace source** accept a root `(mod plugin ...)` and
optional dependency modules, one mod form per dependency. The existing
content-addressed import contract applies; see [plugin authoring](plugins.md).

## History

Version history selects a stored entry from a historical composition.
Composition history can stage the entire historical configuration. Both
create a new revision rather than erasing intervening history. Earlier pages
remain available beyond the store's ordinary three-checkpoint window.

Reversion retains application data and the current enabled/disabled preference
for an individual plugin. State compatibility is explicitly unverified; it
does not rewind conversations, files, workbook data, or undo history.
Managed state records the digest and host of the plugin revision that last
wrote it, including writes made by an older leased revision. These records
commit with the state checkpoint. Legacy state, custom event projections,
and directly written files can have unknown provenance. A matching digest
does not prove compatibility.

**Restore default** selects the built-in from the current host. A historical
composition from a different or unknown host build shows which current
built-ins it will use. Exact historical host binaries and automatic state
migrations are outside this feature.

Use **Pin as known-good** to annotate a revision you have used successfully.
This is an operator judgment, separate from the recorded readiness check.
History shows timestamped application/readiness outcomes and rejected
attempts separately from immutable revision records.

## Recovery startup

```text
gene-harness --workspace DIR --recovery
```

Recovery opens composition metadata without loading workspace plugins,
application event streams, or execution controllers. It refuses rounds,
scheduled work, plugin actions, and arbitrary execution. The normal owner
authentication and exclusive workspace lock still apply.

Review the inventory, stage repairs, validate, and choose **Save repair**.
Saving changes desired state without activation. Select **Retry normal
startup** to hand control back to the supervised host. The browser waits for
the new host and retains unresolved drafts.

The launcher also falls back once to recovery when a normal child exits
before publishing its startup-readiness marker. It retains bounded startup
diagnostics. A recovery startup failure is reported and exits; it does not
produce an automatic crash loop. Direct `gene run` without the supervisor
requires starting the normal host again from the terminal.

## CLI and model access

```text
gene-harness --workspace DIR plugins
gene-harness --workspace DIR plugins --offline
gene-harness --workspace DIR history [ID] --limit 50 --before N
gene-harness --workspace DIR revert ID --revision N --expected-revision CURRENT
gene-harness --workspace DIR revert ID --revision N --offline
```

Offline operations require the normal host to be stopped. Offline reversion
checks inert entries and all source blobs without running historical code.

The model retains its existing automatic publication flow. `plugin_history`
and `revert_plugin` are exposed by `plugin_admin`; model changes are not
subject to an additional operator review gate. Direct publication continues
to commit desired state before activation and quarantine failures. All
origins share the same durable composition archive.

The launcher uses `gene run --snapshot` so history identifies the runtime
binary and captured host/dependency inputs. New checkpoints use format 2;
older hosts refuse them rather than dropping history. Imported legacy
baselines explicitly retain an unknown historical build identity.
