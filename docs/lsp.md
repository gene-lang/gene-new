# Gene Language Server

Status: **shipped** — `gene lsp` runs a JSON-RPC 2.0 language server over
stdio. It powers the VS Code extension (`tools/vscode-extension`,
docs/vscode-extension.md) and works with any LSP client that can spawn a
stdio server. Date: 2026-07-09.

## Launch

```bash
gene lsp
```

No flags. The transport is standard LSP framing (`Content-Length` headers)
on stdin/stdout; stdout carries protocol messages only. Set `GENE_LSP_LOG=1`
to log server activity to stderr.

## Code layout

| File | Role |
|---|---|
| `src/gene/lsp/analysis.nim` | Pure text → LSP data: diagnostics, symbol tree, definition index, position conversion. No I/O; unit-tested directly. |
| `src/gene/lsp/server.nim` | Transport framing, request dispatch, document/workspace state. |
| `src/gene.nim` | `lsp` subcommand → `runLspServer()`. |
| `tests/test_lsp.nim` | Analysis unit tests + a full stdio e2e (initialize → diagnostics → symbols → definition → hover → shutdown). |

## Capabilities

| LSP method | Behavior |
|---|---|
| `initialize` / `initialized` | Advertises capabilities; then indexes every `.gene` file under `rootUri` (skipping `.git`, `node_modules`, `nimcache`, `bin`, `.vscode`; capped at 2000 files / 1 MB each). |
| `textDocument/didOpen` / `didChange` | Full-text sync (`change: 1`). Each change re-analyzes the document and publishes diagnostics. |
| `textDocument/didClose` | Clears the document's diagnostics and re-indexes the file from disk, so unsaved buffer definitions do not outlive the buffer. |
| `workspace/didChangeWatchedFiles` | Keeps the index current for files created/changed/deleted outside open buffers (the VS Code client watches `**/*.gene`). Open documents win — their buffer text drives the index. |
| `textDocument/publishDiagnostics` | Reader parse errors (`ReadError`) as error-severity diagnostics with real tokenizer positions. One error per document (the reader stops at the first failure). |
| `textDocument/documentSymbol` | Hierarchical outline: `fn`/`fn!`/`macro` (Function), `var` (Variable), `type` (Class, with nested `message`/`ctor`), `enum` (with unit and tuple variants as EnumMembers), `protocol` (Interface, with messages), `impl P for T` (with messages), `ns` (Namespace, recursive), `mod` (Module). |
| `textDocument/definition` | The symbol under the cursor, matched by name against the current document first, then the workspace index. Slash paths resolve the segment under the cursor (`Cell/set` on `set` looks up `set`). |
| `textDocument/hover` | The definition's first source line in a `gene` code block plus its file:line. |
| `workspace/symbol` | Case-insensitive substring search over the workspace definition index (capped at 500 results). |
| `shutdown` / `exit` | Standard lifecycle; exit code 0 after a shutdown request. |

Unknown notifications are ignored; unknown requests answer
`-32601 method not found`. Handler exceptions answer `-32603` and never kill
the server.

## How analysis works

Analysis uses the real reader, not regexes:

- `readAllWithLocs` (src/gene/reader.nim) returns every top-level form, the
  source location of each form (`formLocs`), and a `locs` table mapping each
  nested heap value (nodes, lists) to its location — which covers every
  declaration form the outline cares about.
- Form **end** positions and declared-**name** token positions come from a
  small raw-text scanner that respects the reader's lexical surface: line
  comments (`# …`), nested block comments (`#< … >#`), strings (`"…"`,
  `"""…"""`, `$"…"`), regex literals (`#"…"`), bytes literals
  (`0!…`/`0x…`/`0#…` — the base64 `#` is not a comment), char literals
  (`'a'`, `'\n'` — including delimiter chars like `')'`), and datum
  comments (`#_ datum` is spacing: the marker and its datum are skipped,
  stacking like the reader). Enum unit variants (bare symbols carry no
  `locs` entry) are located by a bounded token search inside the enum form.
- Coordinates: the reader reports 1-based line / 1-based **byte** column;
  LSP wants 0-based line / 0-based **UTF-16** column. `analysis.nim` owns
  the conversion (`byteColToUtf16` / `utf16ColToByte`), so multi-byte
  identifiers position correctly.
- On a parse error the server keeps the document's **last good** symbol
  tree, so outline and navigation keep working while the user types through
  a broken state.
- URIs are canonicalized (`file://` percent-encoding normalized) so a
  client's `didOpen` URI and the workspace indexer key the same entry —
  definitions never duplicate.

## Design decisions and limits

- **Name-based definition lookup.** Definitions match by name against
  indexed declarations; there is no scope or import resolution yet. For a
  single-project language this finds the right declaration nearly always,
  and wrong candidates are visibly wrong (multiple results). Resolving
  through imports/scopes is future work.
- **No semantic tokens.** Highlighting comes from the TextMate grammar in
  the VS Code extension; the LSP adds navigation and diagnostics on top.
- **Full-document sync.** Gene sources are small; incremental sync is
  complexity without measurable benefit today.
- **Single-threaded, synchronous.** Requests are answered in arrival order;
  analysis of a typical file is sub-millisecond, so no async machinery is
  warranted yet.

## Extending

Add a request handler in `server.nim`'s dispatch `case` and, if it needs new
document data, grow `analysis.nim` (keep it pure — everything there is
unit-testable without a process). Wire new capabilities into
`handleInitialize`. Cover new behavior in `tests/test_lsp.nim`: unit tests
against `analyze`/`flattenDefs`, plus an assertion in the stdio e2e when the
wire shape matters.
