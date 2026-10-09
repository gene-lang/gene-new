# Workspace views

Classic Harness and plugin views use the same workspace host. A plugin view
can fill the application area or sit beside the conversation. Switching does
not start a round, submit a command, save a draft, or change another tab.

## Navigation

Use the host **View** picker from any view. **Show chat** docks the current
plugin view beside Classic Harness; **Hide chat** makes it full screen.
Selecting **Classic Harness** alone unmounts the plugin view while retaining
its state. Dock side and width belong to the current browser tab.

| Shortcut | Result |
| --- | --- |
| Ctrl+Shift+Space | Toggle full-screen/docked, or return from Classic alone to the previous plugin view. |
| Ctrl+Shift+1 | Classic Harness alone. |
| Ctrl+Shift+2–9 | The corresponding view in the picker. |

Bindings use physical digit keys and ignore repeated/composing input. Host
buttons remain available when an OS or browser reserves a shortcut.

The URL can name `view=project_board&presentation=full` or `presentation=docked`.
An explicit destination wins over the tab's remembered choice. Browser
Back/Forward restores navigation. Workspace settings only supply initial
defaults; changes to those defaults do not move tabs already in use.

## Plugin contract

Register a `web_components` row with `slot: view`, a title, `view_state`,
`state_version`, declared function `actions`, and a `render` callback. See
[web components](web-components.md) for the supported data-tree vocabulary.
Legacy `panel` registrations use the same renderer and default to docked mode.
Canonical views default to full-screen mode. The name `harness` is reserved.

Navigation buttons use existing Gene data syntax:

```gene
(button ^key "develop" ^switch_view "project_board" ^presentation "docked"
  "Develop in Harness")
(button ^key "overview" ^switch_view "project_overview" "Overview")
(button ^key "classic" ^switch_view "harness" "Classic Harness")
```

Omitting `presentation` restores that view's remembered/default presentation.
It is invalid on `harness`. A switch button has no function/command/prompt/state
action at the same time. Unavailable destinations show a notice and leave the
current view intact.

Plugin themes use the existing six-digit color tokens, scoped to plugin
content. Classic Harness and host recovery controls keep their own palette.
No arbitrary HTML, JavaScript, or plugin CSS is required or accepted.

## State and concurrent tabs

Each tab keeps its conversation selection, view, presentation, filters, and
unsaved forms. Only one plugin tree is mounted. Leaving a view preserves its
state in memory and session storage; returning renders current host data before
enabling actions. Stable keys preserve drafts, and a new `state_version` starts
a separate state namespace. **Discard edits** clears only the current view's
drafts. It does not erase another view's edits.

Saved plugin records, available plugins, and their revisions are shared.
A Save from another tab, a CLI command, or a model function refreshes saved
data in the visible view while preserving dirty fields and their original
record revision. Plugins must use revision checks and an atomic check/write
gate such as `ui/state_lock`; the UI cannot provide transactions for arbitrary
functions. A stale Save is rejected with its draft preserved.

Session storage is recovery for the tab, not durable domain storage. If storage
fails, drafts remain in memory with a warning. Local storage preferences are
not used by this feature. Cookies continue to handle authentication only.

## Actions without conversations

Save invokes a declared function with a workspace action receipt. It does not
create or select a conversation, even when no conversation exists. Its runtime
context has no implicit session. Plugins may explicitly pass conversation data
as ordinary arguments if their workflow needs it.

Expected failures stay in the view and host controls; they are not appended to
model input. When asked to diagnose a problem, the model can inspect receipts:

```gene
(ui_action_receipts ^view "project_board" ^status "failed" ^limit 10)
```

The result contains bounded `records`, a `before` cursor, and generation
metadata. Use `^input_id` for a particular action and the returned `^before`
for an earlier page. Receipts retain the original function/view revisions.

Each tab permits one unresolved UI mutation at a time. Switching views remains
available; other tabs can submit their own actions. The host strip identifies
the originating view and offers receipt recovery and cancellation. Cancellation
does not imply rollback. A host restart marks unfinished actions interrupted;
it does not replay them.

The action log is independent of conversation history and the domain-data
stream. Receipt-only updates do not re-render unrelated views. New identities
use the host generation already supplied with status. Generations advance every
128 admissions; four generations and all unfinished actions remain protected.
An explicit retry uses the original request and generation. Once an uncertain
receipt expires, inspect saved data before deliberately starting another action.
Never treat a missing receipt as proof that the operation did nothing.

## Development and recovery

**Develop in Harness** docks the view beside the currently selected conversation
or an empty composer. Ask the model to inspect the plugin's source and functions,
publish an improvement, and return to the same domain workflow. Compatible
publication keeps the view's draft state; stale function/view actions are refused.

A plugin `prompt` button reveals the composer without submitting. If a draft
already exists, choose Replace, Append, or Keep draft. Browser selection is not
implicitly model context; include explicit record IDs in contextual prompts.

Notifications, background questions, command confirmations, and pending action
controls remain accessible in every presentation. Disabling the active plugin
falls back to Classic Harness. Re-enabling it does not navigate tabs back.
`/ui/default` opens Classic without plugin rendering or themes, while retaining
receipt recovery. Use its return link to leave recovery explicitly.

A notification may reference `{^component "project_board" ^view_state {...}}`
without naming a conversation. Opening it changes only this tab's selected view
and supported view state. References to conversation rounds, commands, and
artifacts still require their originating session.

Protocol 8 replaces the old session-bound UI action endpoints. Old pages must
reload. An old pending action shows **Outcome unknown — recorded before an
upgrade** with Dismiss. Dismiss clears that obsolete browser record, preserves
the draft, and never repeats or cancels the old operation. Historical
conversation records are left intact.
