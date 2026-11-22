# Gene editor in the Harness

The classic workspace has a host-owned editor panel beside the transcript. It
mounts the reusable component from
[`client/components/gene_editor.gene`](../client/components/gene_editor.gene)
and is served by the bundled `editor` plugin's owner routes. The standalone
demo and component reference live in
[the editor demo](../../examples/gene-editor/README.md).

## Open from `/view`

A `/view path:from-to` result contributes only a **Open in Gene editor**
button next to **Next page**. The button appears when the selected file kind is
`gene` and the editor plugin's workspace status entry is `ready`. It opens the
panel with the same path and line range; the panel then reads the file through
the owner route, so nothing else is submitted to the conversation and no file
pointer is attached.

A file can also be opened directly: the panel's path field accepts any
workspace-relative path and **Open** loads it.

## Panel lifetime

The panel is inside `classic_workspace`, so:

- transcript updates during streaming do not rebuild it;
- switching conversations leaves the same mount, caret, scroll position, and
  undo history in place (a document belongs to the workspace, not a
  conversation);
- switching to a full-screen workspace view hides `classic_workspace` without
  unmounting the panel, so analysis and an in-flight Save continue;
- returning reveals the same mount;
- **Close** disposes the mount. The draft remains in the workspace-scoped draft
  store, so reopening the file restores it.

## Drafts

Drafts are stored under `gene-harness/editor-draft/<slot>/<document>` in
session storage. `workspace_storage` scopes the key by the page's stable
workspace identity, so two workspaces in one origin never see each other's
drafts. A draft is written on every edit and on disposal.

Storage is best-effort. A draft above 256 KiB, a storage quota failure, or a
page without a workspace identity keeps the draft in the tab's memory and the
panel warns that it will not survive a reload. Restoring a draft whose base
revision is older than the current saved file surfaces that in the status line
and offers comparison; the newer revision is never adopted silently.

## Routes

All routes are `owner` routes under the versioned API root, `/api/v9/p/editor`
(the `api_root` of the current protocol), and therefore run after
the existing same-origin, owner-cookie, and CSRF checks.

| Route | Purpose |
| --- | --- |
| `GET /document?path=REL` | Raw bytes, digest as revision, decoded LF text, line-ending style, BOM, and read-only reason. |
| `POST /save` | `{path, text, base_revision, line_endings, bom}`; digest-checked save under the workspace patch gate. |
| `POST /selection` | `{path, revision, start_byte, end_byte}`; returns the exact text for a saved selection, or `{changed true}`. |
| `POST /analyze` | `gene-viewer --machine analyze` for a draft; response is tagged with the draft version. |
| `POST /format` | `gene-viewer --machine format` for a draft. |
| `GET /logs?source=host&cursor=…` | A bounded, filtered increment of the retained Harness host log. |

### Saving

A save runs inside `with_patch_gate`, the same gate agent patches use, so a
patch and a save cannot interleave. The save validates the base revision and
reads the file only after acquiring the gate, so a patch that lands while the
save was waiting produces a conflict rather than a lost update. It follows the patch path rules, reads
through a symbolic link and renames the replacement onto the link's target
(keeping the link), and preserves the file mode. The revision is the SHA-256 of
the raw bytes.

- If the submitted snapshot's bytes already match the file, the save succeeds
  without writing. This is what makes a retry after a lost response safe.
- If the base revision differs, the route returns `409` with the current text
  and revision. The editor keeps the draft and offers **Compare with saved
  version**; it does not adopt the returned revision, so a later save cannot
  overwrite a change the operator has not reviewed.
- Line endings and the BOM are checked against the bytes the save is based on;
  a mismatch is a conflict rather than a silent reformat.
- Mixed line endings and invalid UTF-8 are read-only. Rewriting either would
  destroy text the operator never saw.

The whole HTTP body is bounded by the server's 16 MiB limit. An oversize save
reports an error and leaves the draft intact.

### Analysis

Analysis and formatting exec `gene-viewer --machine`, found next to the Gene
executable and then on PATH. Without the helper the route answers
`{ok false, unavailable true}`: the panel keeps the textarea, hides the outline,
tree, diagnostics, and Format, and says the helper is missing.

## Plugin availability

The panel reads the `editor` entry in the workspace status `^plugins` list on
every status update:

- `ready` enables opening files and route-backed work, and shows the
  transcript button;
- any other state shows **Editor unavailable**, keeps the draft, and answers new
  analysis and save requests with an `unavailable` result. An already submitted
  Save still reports its outcome.
- when the plugin returns to `ready`, the preserved buffer is re-analyzed and
  saving resumes with the existing revision check.

## Attachments

**Attach selection** verifies the selected byte range and revision against the
saved bytes before staging a message that names the path, range, and revision.
Ranges are byte offsets into the editor's LF, BOM-free text — the same text
analysis reports — not offsets into the raw file. The route checks the raw-byte
revision and then slices that text, so CRLF and BOM files keep the helper's
offsets. A range that does not fall on UTF-8 boundaries is rejected with `400`.
If the file changed, the operator is asked to reopen it rather than sharing
text from a different version. The staged label says "UTF-8 bytes" so it is not
confused with `/view`'s line range. **Attach draft** stages exactly the text on
screen from the analyzed draft and labels it as a draft selection.

## Logs tab

The panel's **Logs** tab mounts a second copy of the component in stream mode.
The source and log surfaces stay mounted: switching tabs preserves the source
draft, caret, undo history, and each surface's scroll position. Logs are
polled only while the tab is visible; hiding it stops the timer chain, and a
delayed reply for a previous tab or plugin state is discarded.

The Logs tab reads the core `GET /api/v9/logs` route, which reads the retained
`.gene-harness/host.log` and its `host.log.1` predecessor. Its filter row sends
`type` (exact or `family/*`), `level` (minimum), `session` and `since` (epoch
ms); an Apply clears the loaded tail and cursor before polling again. A line
that parses as a Harness log record is rendered as console text; any other line
is shown as raw text. Redaction runs on the complete line before the display budget truncates it, so
a credential at the cut boundary cannot leak a prefix. The cursor is opaque: a
segment name, a byte offset at a line boundary, and a SHA-256 digest of that
segment's prefix through the offset. Each poll compares the prefix:

- matching active segment: deliver only the new complete lines;
- matching previous segment: the log rotated; finish the previous segment,
  then continue with the active one in the same bounded response;
- neither matching: report a gap, label it in the view, and resume from the
  available tail.

Only complete lines advance the cursor, so an incomplete final line is carried
into the next poll. A rotation can fall mid-line: the previous segment's tail
is joined to the start of the active file as bytes before decoding, rendering,
and redaction, and the cursor stays on the partial tail until the active line
completes. A UTF-8 sequence or credential split by rotation is therefore never
delivered in halves. Long lines are truncated with a visible marker and the cursor advances
past them; each response is bounded (64 KiB and 8 KiB per line by default).
Text is redacted with the same replacements the manager's diagnostics use,
applied before delivery and independently of the manager's excerpt cap.

**Attach log** stages the last bounded, already-redacted lines in the composer,
labelled as a host-log selection. The component's own toolbar offers follow,
pause, jump to latest, filtering, and Copy over the same buffer.

A workspace with no retained host log (for example a foreground launch whose
output stayed on the terminal) shows that state instead of an empty stream. The
manager's existing per-workspace Diagnostics action remains the way to inspect
`bootstrap.log`, `startup_failure`, and the previous/current host log while the
workspace host is down. Diagnostics and the browser route share the credential
replacements; only the excerpt cap differs.

Measured on the development machine, opening a 756 KiB segment takes about
8 ms and a poll that delivers one appended line about 9 ms, so the default
800 ms cadence costs roughly one percent of a core. The cursor compares a
prefix digest rather than file identity: an in-place byte-identical
replacement is undetectable by design, while truncation, appends, rotation,
and same-length different content are all detected.

## Dockable view and view-owned outlet

The editor plugin also publishes a **view-scoped** browser client (`editor_view`)
and a `web_components` view of the same name. Opening the **Gene editor** view
mounts the same component and owner-route adapter as the direct panel, with its
own scoped draft store (`view` slot) and a compact file picker + Source/Logs
tabs. Path, tab, and log cursor are kept in scalar view state, so a view switch
restores the selected file and continues the log cursor. Source and log mounts
are independent, so each keeps its own scroll position and draft while the other
is hidden.

The host renders the outlet as an empty keyed `div` with `^data-outlet
"editor_view"`. The outlet node is retained across view-tree updates and its
browser client receives the view identity and view state through
`root/harness_bridge`:

- `bridge/view` names the view, title, presentation, state version, and current
  scalar view state;
- `bridge/save_view_state changes` persists selection and display preferences;
- the standard bridge fields (`api`, `state`, `subscribe`, `navigate`,
  `attach`, capabilities) remain available.

The controller is disposed when the outlet disappears, the view or workspace
changes, or the contribution is replaced or disabled. A module load that
finishes after the outlet is gone is discarded. Switching away from the view
disposes the mount; returning restores the scoped draft. The view-scoped client
is not mounted into the page toolbar or composer, so a contribution that only
belongs to a view declares `^scope "view"`.

`Cmd/Ctrl+S` saves the source buffer from the view. **Attach selection** verifies
the saved range through the owner route and stages it through the page bridge
when the host offers attachment. The view keeps the draft and shows the
unavailable state when the plugin is disabled.

The outlet can only mount compiled Gene browser modules; external JavaScript
imports remain disallowed. Rich text widgets such as CodeMirror would need a
host-provided adapter.

