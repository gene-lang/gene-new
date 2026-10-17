# Plugin development sessions

Implemented and verified on 2026-10-17.

Workspace plugin details and version history retain the conversations that
created and changed saved source. Selecting a title opens the existing session
in the Harness view. This feature records attribution and provides navigation;
it does not prepare prompts, retrieve source into the conversation, submit work,
create sessions, or add a replacement precondition.

## Saved metadata

Workspace source entries carry:

| Field | Meaning |
| --- | --- |
| `created_in` | Original creation session and optional turn, omitted when unknown. |
| `source_origin` | Origin of the saved source: `kind` plus an actual calling session and optional model turn. |

Kinds are `model`, `command`, `operator` and `direct`. A manager source edit
records `{^kind "operator"}` without a session. A direct script without session
context records `{^kind "direct"}`. The host never substitutes its workspace
event stream for a missing session.

```gene
{^id "project_board"
 ^created_in {^session "session-a" ^turn "3"}
 ^source_origin {^kind "command" ^session "session-b"}}
```

`source_origin` identifies the new attribution format. A missing or `nil`
`created_in` on such an entry means deliberately unknown creation. Historical
inference is only needed for older source entries without `source_origin`.
The separate operation `origin` records later administrative actions; it does
not replace source attribution.

## Publication and lifecycle

- Registration captures the caller before queuing work. Creation is determined
  against the entry present at serialized publication, so queued replacements
  cannot each claim to be the original creation.
- Replacements preserve creation and record their own source origin. Manager
  plans retain the creation association in the validated entry and use their
  existing base-revision check at Apply.
- Enable, disable and activation retry preserve both associations.
- Reverts copy the chosen source origin and preserve the current creation
  association. The reverting actor remains in operation history.
- Restore default removes the workspace override. A later new override gets a
  new creation; older associations remain in archived revisions.
- Rejected preflight, cancelled queued work and failed commits leave current
  attribution unchanged. An activation failure after a successful source commit
  retains attribution with the newly saved, quarantined code.

These rules live in `src/storage/plugin_source.gene`, with writes in
`src/storage/workspace.gene` and `src/runtime/plugin_plans.gene`.

## Legacy entries

A legacy source registration with a `model` or `command` operation origin and
a recorded session can establish a conversation. `direct` origins and ambiguous
`default` values remain unknown, even if a session with that ID exists. A
`"direct"` turn marker alone does not disqualify an operator `/run` session.

Legacy reverts follow their recorded `source_revision` through archived entries
until explicit attribution or a source registration is found. Missing history,
invalid references and unattributed manager replacements yield unknown. The
resolver never identifies authorship by the first matching content digest.
Creation recovery stays within the current plugin/override lifetime; an imported
baseline is not evidence of original creation.

## Catalog, history and UI

Plugin inventory and selected-plugin history responses include `development`
with `created_in` and `source_from`. Each known reference carries its session ID,
optional turn, current title, kind, availability and recovery state. Normal
mode resolves titles from the session index without loading conversations.
Recovery uses only saved metadata and renders IDs without navigation links.

The UI combines identical session references into one row. Missing sessions
retain their ID with **Session unavailable**. Bundled plugins without workspace
source have no local source-session action. Trigger sessions are navigable
without changing their kind or creating an interactive replacement.

Links use the existing same-tab route with `view=harness`. The conversation
client restores its ordinary per-session draft from `sessionStorage`. No new
browser primitive or plugin button action is required.

## Verification

- `tests/unit/storage/plugin_attribution_spec.gene`: context capture, explicit
  unknown values, identical digests, chained legacy reverts, imported baselines
  and override lifetime boundaries.
- `tests/integration/runtime/plugin_source_spec.gene`: real model and `/run`
  registrations, queued publication/cancellation, failed writes and activation,
  manager replacement/reversion, restarts, deleted sessions, triggers, built-in
  restoration and recovery with unreadable configuration/event state.
- `tests/unit/client/plugin_sessions_spec.gene`: same-tab URLs, encoding,
  deduplication, trigger links and missing/recovery/bundled presentation.
- `tests/fixtures/plugin_source_browser.gene`: seeds an offline workspace for
  browser verification of links, remembered full-screen views and A/B drafts.

The focused and existing plugin lifecycle run passed 37 tests. Chrome browser
checks confirmed current/history links, a remembered full-screen view returning
to Harness, A/B draft switching and reload, independent clearing/submission,
missing and legacy attribution, and trigger-session navigation. The navigation
checks produced no session-creation or round-submission requests; the one
explicit Send check submitted exactly one offline round.
