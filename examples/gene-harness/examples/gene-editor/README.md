# Gene editor demo

A standalone host for the reusable editor component in
[`client/components/gene_editor.gene`](../../client/components/gene_editor.gene).
It runs without the Harness: an ordinary Gene script serves the page, the
fixtures, revision-checked saves, and a simulated log stream.

```sh
# Build the companion analysis/format helper once (separately from `gene`).
nimble tools

# Serve the demo.
bin/gene run examples/gene-harness/examples/gene-editor/main.gene
# open http://127.0.0.1:8091
```

The analysis and format routes exec `gene-viewer --machine analyze|format`,
found next to the Gene executable and then on PATH — the CLI's lookup order.
Without the helper the routes answer `unavailable`: the editor keeps its
plain textarea and hides the outline, tree, diagnostics, and Format action.
`main.gene`'s temp draft files live under this directory's `tmp/`.

## What the demo exercises

| Piece | Where |
| --- | --- |
| Document picker, log tab, status line | [`client.gene`](client.gene) |
| Editor host services (read, save, analyze, format, drafts, events) | [`client.gene`](client.gene) |
| In-memory documents, revisions, encoding, routes | [`main.gene`](main.gene) |
| Parsable fixtures for outline/tree parity | [`fixtures/`](fixtures) |

Saves are in memory: the demo owns its documents, so a save replaces the stored
bytes and their digest and nothing on disk changes. The revision check is real.
A save whose base no longer matches returns `conflict` with the current text,
and the editor keeps the operator's draft. Re-submitting a snapshot whose bytes
already landed returns success without writing again, which is what makes a
retry after a lost response safe.

Encoding is recorded per document. The editor always sees LF text; a save
re-applies the recorded CRLF/CR style and UTF-8 BOM, and the response reports
those back for the next save. `crlf-bom.gene` is a synthetic document for that
round trip, and `mixed.gene` is synthetic too: mixed line endings open
read-only, with the reason shown in the status line.

The **Logs** tab opens the same component in stream mode. The route delivers
complete lines plus an opaque cursor, reports a gap at a deterministic poll,
and resets once — enough to exercise follow, pause, unread counts, jump to
latest, search, and gap labels.

## Fit for a Harness view outlet

The milestone-3 contract in `tmp/gene-web-editor.md` asks a host to give a view
a persistent DOM root across view-tree updates, deliver the view identity and
scoped state to a mounted controller, and dispose it when the outlet
disappears, the view or workspace changes, or the contribution is replaced or
disabled. The component already has the shape that needs:

- `mount_editor(root, document, services)` takes the outlet's root and keeps
  every bit of state in one controller; two mounts share no mutable state.
- `dispose` writes the current draft through the host store, drops the DOM, and
  makes late analysis, save, format, and log callbacks no-ops. The
  embedding-owned draft store survives, which is what lets a remount restore a
  draft after a view switch or a plugin replacement.
- `open`, `reveal`, `replace_saved`, and `append_log` cover switching documents,
  jumping from a `/view` line range, adopting an agent edit, and log increments
  without remounting.
- Selection and dirty events go out through `emit`, so the host can keep its
  own view state (a composer attachment, a tab badge) without reading DOM.

What the outlet adds is the layout, file picker, and plugin-owned routes; the
editor does not need to know whether it is docked or full-screen.

## Tests

The component's browser scenarios are compiled to a web module and run under
Node with a small DOM:

```sh
bin/gene build --target web --out-dir /tmp/gene-editor-scenarios \
  examples/gene-harness/tests/fixtures/gene_editor_scenarios.gene
node examples/gene-harness/tests/fixtures/gene_editor_driver.mjs \
  /tmp/gene-editor-scenarios
```

The Harness suite wraps the same commands in
[`tests/integration/web/gene_editor_spec.gene`](../../tests/integration/web/gene_editor_spec.gene),
which also checks the machine helper on an unfinished buffer with a
supplementary Unicode character.

Layout, caret painting, and native undo feel are browser behaviors; the Node
DOM checks state transitions, not pixels.
