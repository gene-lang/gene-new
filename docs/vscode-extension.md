# Gene VS Code Extension

Status: **shipped** in `tools/vscode-extension`. Two layers: a TextMate
grammar that highlights Gene with zero setup, and a language client that
spawns `gene lsp` (docs/lsp.md) for diagnostics, outline, go to definition,
hover, and workspace-wide symbol search. Date: 2026-07-09.

## Install

The extension is not published to the marketplace; build it from the repo:

```bash
cd tools/vscode-extension
npm install                  # pulls vscode-languageclient
npx @vscode/vsce package     # produces gene-lang-0.1.0.vsix
code --install-extension gene-lang-0.1.0.vsix
```

For development instead of packaging: open `tools/vscode-extension` in
VS Code and press **F5** — an Extension Development Host starts with the
extension loaded.

Build the `gene` binary first (`nimble build` at the repo root); the
language features need it, the highlighting does not.

## Features

**Highlighting** (grammar, no server needed) — matched to the reader's
actual lexical surface (src/gene/reader.nim):

- line comments `# …`, nested block comments `#< … >#`, datum comments `#_`
  (`#(`, `#[`, `#{` stay literals, not comments);
- strings `"…"`, triple-quoted `"""…"""`, regular and triple interpolated
  strings with embedded Gene bodies, and regular/triple regex literals with
  flags;
- bytes literals `0!binary` / `0xhex` / `0#base64` (listed before the
  comment rule so a base64 `#` never reads as a comment) and char literals
  `'a'` / `'\n'` (Gene's `'` exclusively introduces chars — there is no
  quote sugar);
- date, time, and datetime literals, highlighted before numeric fallback;
- special forms in head position (`fn`, `var`, `type`, `match`, `impl`, …)
  and boolean control (`&&`, `||`, `!`);
- properties `^name`, meta `@name`, spread `...`, send `~`, quasiquote
  `` ` ``/`%`;
- decimal numbers, `true`/`false`/`nil`/`void`/`self`;
- head-position calls as function names, capitalized symbols as types.

**Language features** (via `gene lsp`):

| Feature | VS Code surface |
|---|---|
| Parse errors as you type | red squiggles + Problems panel |
| Document outline | Outline view, breadcrumbs, `Ctrl/Cmd-Shift-O` |
| Go to definition | `F12` / Cmd-click on any known name |
| Hover | declaration's source line + defining file |
| Workspace symbols | `Ctrl/Cmd-T` search across all `.gene` files |

**Editing** (language configuration): `#` line-comment toggling, `#< >#`
block comments, bracket matching/auto-closing for `()[]{}` and `"`, and a
word pattern matching Gene symbols (so double-click selects `read_text`,
not just `read`).

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `gene.lsp.enabled` | `true` | Start the language server for `.gene` files. |
| `gene.lsp.path` | `""` | Path to the `gene` binary. Empty → try `bin/gene` in the workspace root, then `gene` on PATH. |
| `gene.trace.server` | `off` | LSP wire tracing in the Gene output channel (`messages`/`verbose`). |

## Troubleshooting

- **Highlighting works but no squiggles/outline** — the server did not
  start. Check that `gene` resolves (set `gene.lsp.path` to an absolute
  path, e.g. `<repo>/bin/gene`), then reload the window. Server-side logs:
  launch VS Code from a shell with `GENE_LSP_LOG=1` and watch the Gene
  output channel / stderr.
- **Go to definition finds nothing across files** — the workspace index is
  built from the folder VS Code opened (`rootUri`). Open the project root,
  not an individual file. Files beyond 2000 count / 1 MB each are skipped.
- **Stale definitions after a big refactor** — the index refreshes per file
  on open/change; reload the window to rebuild it wholesale.

## Code layout

| File | Role |
|---|---|
| `package.json` | Language + grammar + configuration contributions; `vscode-languageclient` dependency. |
| `extension.js` | Plain-JS client: resolves the binary, spawns `gene lsp`, warns (once) if it fails — highlighting keeps working without it. |
| `syntaxes/gene.tmLanguage.json` | TextMate grammar (scope `source.gene`). |
| `language-configuration.json` | Comments, brackets, auto-closing pairs, word pattern. |

The grammar and the reader must stay in sync: when the lexical surface
changes (new literal forms, comment syntax), update
`syntaxes/gene.tmLanguage.json` alongside `src/gene/reader.nim`.
