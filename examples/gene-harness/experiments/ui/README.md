# Experimental workspace UI

This opt-in experiment puts a plugin-owned project board beside the existing
conversation. Views are quoted Gene data rendered on the server. The browser
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

Open the bootstrap link printed by the server. Filter tasks, select one, edit
its fields and save. The first Save creates a normal session if necessary.
The board's selection and drafts survive changing conversations and reloading.
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

Hide board / Show board changes the shared workspace layout. The direct
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

Save calls the registered function inside a normal command task. It receives
the existing budget, cancellation, output sink and durable receipt. UI action
blocks are hidden from conversation transcripts; their progress, errors and
Cancel action control stay in the panel.

The pending action records its original session and input identity in browser
storage. Resolve action first looks up that receipt. If none is retained, an
explicit retry uses the same identity. An uncertain mutation is never replayed
automatically. Switching conversations does not change the receipt's owner.

A failed action contributes one diagnostic to the submitting conversation's
next user request. Successful actions do not attach themselves to model input.
View-state requests are bounded reads and create no command record.
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
