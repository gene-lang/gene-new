# Spreadsheet application experiment

Run started 2026-10-12 from Harness revision `9cdb31b4`. The operator drove a
real Codex-backed Harness conversation in a fresh workspace and tested the
resulting native plugin in Chrome. Harness authored the application; operator
changes to the repository address observed infrastructure defects.

Workspace: `tmp/harness-excel-20261012` at the repository root. The app source,
README, publication tool and app-authored `ISSUES.md` are retained there. The
operator's detailed issue log and acceptance evidence are in
`tmp/harness-excel-20261012-issues.md` and
`tmp/harness-excel-20261012-verification.md`.

## Application

Gene Sheets is a native `web_components` view, backed by registered Gene
functions and durable PluginHost state. It implements a sparse A1:Z100
workbook, multiple sheets, arithmetic and aggregate formulas, reference and
cycle handling, formatting, undo/redo, revision-checked mutations and CSV/TSV
exchange. It uses the existing `ui/state_lock` service and content-addressed
module dependencies. No standalone application server or browser JavaScript
was added by the app.

The first usable generation completed at session turn 38, after two provider
interruptions and continuations. It passed 31 direct and registered checks.
Two browser-driven improvement rounds brought the run to 70 session turns
across five user rounds. The final domain suite passes 73 checks in direct,
packaged fresh-process and live registered execution. Browser and supervised
host-restart acceptance passed. The live local app is at
`http://127.0.0.1:56519/`; the operator left its authenticated Chrome tab open.

## Findings

| Finding | Evidence and impact | Resolution |
| --- | --- | --- |
| Escaped regex quotes did not round-trip through the Gene printer | A saved dependency's digest changed after parsing/printing; the original source passed tests while the registered module failed with `undefined symbol: \\`. | Fixed the printer to preserve existing escape pairs. Reader/formatter round-trip coverage and a Harness publication/restart regression pass. |
| Provider stream errors discarded their explanation | Turn 14 ended with only `codex stream failed (error)`. | Preserve bounded provider code/message/reason fields; five provider tests pass. |
| A transient receive error stops the round | Turn 8 ended with `Failure when receiving data from the peer`; source/history survived. | Continued in the same session. Broader transient retry policy remains open. |
| Module dependency packaging was not discoverable | `discover "dependencies"` returned nothing; the model searched internals and initially hashed the wrong representation. | Added a canonical dependency example and searchable dependencies/modules tags to the plugin guide. |
| Native controls lack spreadsheet-specific interactions | The contract provides tables, keyed forms and scalar view state, with no grid arrow-key handling, drag-fill, column resizing or clipboard/download actions. | App uses a bounded table, formula editor and explicit paste/export controls. A reusable grid capability remains a future option. |
| Initial app layout hid most rows | The initial desktop view placed the table near y=700 and exposed only a few rows. | Final measured layout fits eight complete rows at 1456×900 and nine at the normal 1864×947 viewport; table starts at y=451.82. |
| Text format evaluated formulas | Browser A1 `=2+3` with text format rendered `5.0`. | Fixed and regression-tested; browser Z100 displayed the literal formula. |
| Export completion lacked a usable result | Export wrote correct CSV but the UI only showed `Saved.`. | Native export section now shows the path, source revision and selectable preview. Export preserves workbook revision/history. |
| Narrow-screen columns were clipped | At 390×844, a 429px table extended beyond the paint-contained view while its outer panel could not scroll horizontally. | A native `table_scroll` wrapper exposes horizontal scrolling; the browser reached column F. |
| Grapheme scanning misread CSV syntax | A combining accent after a comma grouped with the delimiter, turning two fields into one. | An ASCII-aware UTF-8 scanner preserves combining marks, emoji, quotes and CRLF. Added focused cases and a 120-cell paste regression. |
| Legacy layout settings overrode the expected full-screen default | A fresh browser tab opened the native view docked despite the app documentation. | Operator set `default_view: gene_sheets`, `layout: chat`, and an empty legacy `panel`; a fresh post-restart tab opened full screen. |

Authoring friction was substantial: guessed documentation names and source
paths, unsupported compound assignment, repeated bindings, multi-expression
`if` branches, empty-separator string splitting and interpolation containing
quoted strings consumed turns. These are separate from infrastructure bugs.
The ordinary-interpolation restriction is documented; no language syntax or
semantic change was made during this experiment.

## Final verification

- Full Gene reader test binary passed, including escaped-regex regression.
- Release Gene binary rebuilt; 12 provider and workspace integration checks passed.
- Browser: dependent recalculation, consecutive saves, undo/redo, division-by-zero
  and cycle errors, TSV paste, sheet add/rename/delete and fallback all passed.
- Raw CSV file matched the pasted table and retained its formula and CRLF rows.
- Two-tab test rejected a stale save and retained its unsaved `1300` draft;
  Discard edits reconciled it with the saved `1410` value.
- An unsaved draft survived switching sheets and was safely abandoned with
  Discard edits; the saved value remained unchanged.
- Text format, Z100, currency decimals, visible export feedback, compact desktop
  layout and narrow-screen horizontal scrolling passed browser checks.
- Browser reload preserved the workbook. Supervised restart on the rebuilt
  runtime preserved the complete workbook, revision, undo/redo and export
  metadata; all 73 registered checks passed again afterward.
- Final workbook revision is 21. Budget C3 is `1410`, C6 calculates `2010`,
  and Sheet 2's sample table totals `20`. The Z100 test edit was undone.
- Browser consoles contained no errors or warnings during acceptance.
- Temporary test tabs were closed and the viewport override was reset. The
  final full-screen app tab and supervised host remain open.

## Remaining scope

This is an Excel-style native prototype with a bounded workbook, not Excel
file-format compatibility. It has no XLSX import/export, cross-sheet formulas,
grid arrow-key navigation, drag-fill, column resizing or automatic browser
downloads. CSV exchange uses native forms, a selectable preview and workspace
files. Large dense workbooks are not a measured scalability claim.

To rerun the pure app checks from the repository root:

```text
bin/gene run tmp/harness-excel-20261012/tests.gene
bin/gene run tmp/harness-excel-20261012/tests_packaged.gene
bin/gene run tmp/harness-excel-20261012/operator_probe.gene
```

The app's README explains publication through Harness. The operator's runtime
fixes, regression tests and this report are left uncommitted for review.

The architecture supported a substantial app through ordinary plugin APIs.
The main remaining pressure points are authoring ergonomics, data-rich native
UI controls and provider recovery. The serialization defect demonstrates why
testing the packaged plugin matters in addition to testing its source module.
