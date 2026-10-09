# Experimental workspace UI

This opt-in experiment offers a project board and project overview, full screen
or docked beside Classic Harness. Views are quoted Gene data rendered on the server. The browser
preserves keyed controls, drafts and view state while data changes.

Rendering and UI actions are disabled by default. The baseline profile always
exposes `ui_configure` and `ui_preview` to the model; `ui_preview` reports that
the experiment is disabled until it is enabled. This keeps discovery stable
at the cost of two function entries in model instructions.
Its API may change or be removed.
See [RESULTS.md](RESULTS.md) for the observed behavior, measurements and
keep/revise/remove recommendation.

## Try it

From the repository root, with no Harness process owning the chosen workspace:

```text
bin/gene run examples/gene-harness/experiments/ui/install.gene /path/to/test-workspace
bin/gene run examples/gene-harness/src/web/server.gene --workspace /path/to/test-workspace --offline
```

In another terminal, retrieve the owner link with `bin/gene run
examples/gene-harness/src/main.gene --workspace /path/to/test-workspace link`
and open it. Filter tasks, select one, edit
its fields and save. Saves have workspace receipts and create no conversation.
Use Overview, Edit tasks, and Develop in Harness to navigate between views and
dock the current view. The board's selection and drafts survive switching and reloading.
Discard edits reloads the task's current values after a conflict.

The installer registers `project_board.gene` through the normal workspace
plugin loader and explicitly enables the experiment. Reinstalling replaces the
plugin while retaining its durable task state. It does not require a model.

In a running Harness, the following operator commands configure the experiment:

```gene
/run (ui_configure {^^enabled ^layout "panel" ^panel "project_board" ^side "left" ^width 45 ^theme {^accent "#335577"}})
/run (ui_configure {^^enabled ^layout "chat" ^panel "project_board"})
/run (ui_configure {^!enabled})
```

The host View picker, Show chat / Hide chat, dock side/width, and shortcuts
change only the current browser tab. `ui_configure` sets fresh-tab defaults.
The direct
`/ui/default` URL opens the standard interface for that page, omitting plugin
views, their render callbacks and theme overrides. It preserves the workspace
selection and uses the normal authentication checks. The recovery page offers
a host-owned **Return to workspace UI** link for the selected conversation.

## Work through the same functions

The board registers two ordinary functions. They are available to model turns,
`/run` and the Harness REPL:

```gene
(board_tasks)
(board_save ^id "welcome" ^revision "1" ^title "Updated from Gene" ^status "doing")
(ui_preview "project_board" {^filter "updated" ^selected "welcome"})
```

Read the current revision from `board_tasks` before editing. A stale revision
fails instead of overwriting another edit. Use a new id and omit revision to
create a task. Omitted title, status and notes keep their current values on an
update; pass `^notes ""` to clear notes explicitly. New tasks require a title
and default to status `todo` and empty notes.
The board uses the runtime's `ui/state_lock` service around its revision check
and write, so concurrent function calls share the same gate across sessions
and plugin activations.

State changes from these functions invalidate the board even when the call
originates from a model turn or another conversation. The browser re-renders
with its current filter and selection; it retains dirty input fields and their
original edit revision.

## Action behavior

Save calls the registered function with the usual budget, cancellation and
output sink, but with no implicit conversation. Its durable workspace receipt
is independent of conversation history. Progress, errors and recovery controls
remain in the host strip while another view is open.

The pending action records its original generation-bound input identity in
session storage. Resolve checks that receipt before an explicit retry. An
uncertain mutation is never automatically replayed; an expired receipt remains
an unknown outcome. Inspect `(ui_action_receipts ^view "project_board")` when
asked to diagnose a problem. No automatic diagnostic is attached to model input.
View-state requests are bounded reads and create no action record.
The HTTP helper aborts requests after 30 seconds. **Retry view** retries a failed
render while preserving the filter, selection and draft edits.

## Change the plugin

Edit a workspace copy of `project_board.gene` and register it normally:

```gene
(register_plugin ^^replace "project_board" ($fs/read_text "project_board.gene"))
```

The model receives a bounded outline or render error for views owned by the
plugins successfully published in that turn, including in a CLI session without
a browser. Complete nodes are retained with an explicit truncation marker;
unrelated views are not rendered for publication feedback. It can call `ui_preview`
for other view states and exercise the action function before asking the
operator to use it. A preview does not establish browser layout or usability.

The authoring API, supported controls and preview rules are documented in
[web-components.md](../../docs/web-components.md). The host implementation is
in `src/ui/`: `components.gene` validates trees, `state.gene` owns settings and
descriptors, `views.gene` renders them, `outline.gene` summarizes publication
feedback, and `actions.gene` admits function calls. `client/ui/` separates the
panel model/storage, keyed DOM patching and request/action controller. The
HTTP host and page shell live in `src/web/`.
The fixture and installation tooling are Gene source.
