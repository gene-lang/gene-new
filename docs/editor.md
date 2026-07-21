# Gene Structural Viewer and Editor

Status: **implemented through the Phase 3 MVP**. Date: 2026-07-13.
Inline scalar editing, document search, and append-follow remain deferred.

Goal: add `gene view <file>` as a fast structural browser for Gene source and
data, with reliable navigation and a safe path into editing. The viewer should
be useful for ordinary source files, large data values, and append-only files
containing many top-level Gene forms.

The recommended first version is a native CLI feature with a curses frontend,
not a general-purpose text editor. It owns structural navigation and source
location tracking, delegates unrestricted editing to `$VISUAL` or `$EDITOR`,
and later adds narrowly scoped inline scalar replacement.

## 1. Recommendation in one page

Implement:

```text
gene view [--readonly] [--editor COMMAND] <file>
```

with these properties:

- A full-screen tree browser over the file's **syntax structure**, not its
  evaluated runtime value.
- Multiple top-level forms appear under a synthetic root sequence.
- `Up`/`Down`, `PageUp`/`PageDown`, `Home`/`End`, mouse wheel, and familiar
  `j`/`k` aliases move within the current container.
- `Right` or `Enter` enters a selected container; `Left` or `Backspace`
  returns to its parent. `g` returns to the document root.
- `/` searches; `n` and `N` move between matches. Search is useful, but it
  must not force construction of the whole value tree before first paint.
- `e` suspends curses, launches an external editor at the selected source
  location, then reopens and reloads the viewer.
- `$VISUAL` takes precedence over `$EDITOR`; `--editor` overrides both.
- `i` eventually performs an inline replacement of one selected scalar. It is
  not a miniature embedded editor and does not edit container structure.
- `r` reloads. The viewer restores the deepest Gene path that still
  exists rather than relying on stale byte offsets.
- `q` quits. Terminal restoration is guaranteed on normal exit, errors,
  signals handled by the application, and editor handoff.

The implementation should be split into a pure document/navigation model, a
reader-backed source index shared with language tooling, an editor launcher,
and a thin terminal frontend. Do not copy the legacy viewer's hand-written
second Gene scanner or its direct `writeFile` replacement path.

## 2. What the legacy implementation teaches us

The earlier repository implements `gene view` in:

- `~/gene-workspace/gene/src/commands/view.nim`
- `~/gene-workspace/gene/src/gene/viewer/model.nim`
- `~/gene-workspace/gene/src/gene/viewer/app.nim`
- `~/gene-workspace/gene/src/gene/viewer/curses_backend.nim`
- `~/gene-workspace/gene/src/gene/viewer/editor.nim`

It provides a curses tree view, a frame stack for parent/child navigation,
multi-form roots, type-ahead, whole-tree search, scalar replacement, reload,
and `$EDITOR` handoff. Its tests correctly separate most state transitions
from terminal I/O.

### 2.1 Keep these ideas

| Legacy idea | Recommendation here |
|---|---|
| Navigation is a stack of frames containing node, selection, and scroll | Keep. It makes entering, leaving, and restoring a parent selection simple. |
| A multi-form file is exposed as a synthetic sequence | Keep. Logs and source units use the same navigation model. |
| Descendant rows are derived lazily | Keep and strengthen with page-oriented child access. |
| UI, model, editor launcher, and command registration are separate | Keep. Model tests should not require a terminal. |
| External editing temporarily releases curses ownership | Keep. Two full-screen terminal applications must not own the TTY simultaneously. |
| Reload uses path segments | Keep, but use Gene selector-path semantics and add hidden anchors for duplicate or reordered entries. |
| Color is semantic and optional | Keep. The viewer must remain usable without color. |

### 2.2 Change these parts

The old `model.nim` contains its own scanner for strings, atoms, regexes,
delimiters, comments, maps, and Gene properties. That scanner will inevitably
drift from the language reader. The current reader owns the authoritative
token kinds and parsing rules for datum comments, selector/path distinctions,
temporal literals, immutable containers, and multi-form `readAll`. Interpolated
string handling is still simplified and should be cleaned up as spans are
added; the proposal must not imply that this corner is already a reusable,
fully structured token stream.

There is also an existing tooling consumer in `src/gene/lsp/analysis.nim`. It
already builds line-start tables, converts between reader byte positions and
LSP UTF-16 positions, and uses `readAllWithLocs` plus a raw-source scanner to
derive form and declaration ranges. The source index should replace duplicated
location machinery over time, not become a third implementation beside the
reader and LSP.

The old implementation also:

- reads the complete file and eagerly tokenizes top-level structure;
- materializes every descendant during whole-tree search;
- measures and crops mostly by bytes rather than terminal cell width;
- recognizes only a small set of editor cursor conventions;
- edits with direct `writeFile`, without atomic replacement, permission
  preservation, or protection from a concurrent file change;
- validates inline edits with a second scalar classifier instead of the real
  reader;
- treats printable typing as implicit navigation, which makes the mode less
  discoverable and conflicts with future commands.

Those are useful prototype shortcuts, but they should not become the public
foundation in this repository.

## 3. Product boundary

### 3.1 Goals

- Browse Gene code and data without executing it.
- Navigate nodes, lists, maps, selectors, properties, and multiple top-level
  forms while retaining source order.
- Open large files without recursively allocating a runtime `Value` tree.
- Locate the selected syntax in the original file precisely.
- Share source positions and occurrence spans with the LSP rather than adding
  viewer-only location rules.
- Hand the file to the user's real editor and resume cleanly afterward.
- Support safe inline replacement for simple scalar syntax in a later phase.
- Preserve comments and formatting unless an explicitly selected source span
  is replaced.
- Remain responsive on resize and restore the terminal reliably.

### 3.2 Non-goals

- Reimplement Vim, Emacs, or a general text buffer inside Gene.
- Evaluate forms to show computed values.
- Use `gene fmt` as an implicit save step.
- Mutate an in-memory `Value` and print the whole file back. That would lose
  comments and user formatting and could change source semantics.
- Provide collaborative editing, LSP refactoring, syntax-aware completion, or
  project-wide navigation in the first version.
- Promise efficient files larger than address space in the MVP. Memory mapping
  and windowed source access can follow once the source index contract is
  stable.

## 4. User experience

### 4.1 CLI

```text
gene view [options] <file>

Options:
  --readonly             disable every write action
  --editor COMMAND       override $VISUAL and $EDITOR
  --path PATH            select an initial Gene path relative to the root
  --line N[:COLUMN]      select the smallest syntax span containing a location
  --no-color             disable semantic colors
```

`<file>` must be a readable regular file for the first version. A later
read-only `-` input can support pipelines, but reload and edit do not make
sense for a consumed stream.

The command requires an interactive input and output terminal. Unsupported
platforms or non-TTY use should fail before changing terminal mode and print a
normal CLI diagnostic.

### 4.2 Layout

```text
┌ File: app.gene                                  18 KiB  valid ┐
│ Path: port                                                 │
├─────────────────────────────────────────────────────────────┤
│    head          > server                                   │
│    host            "127.0.0.1"                              │
│  ▸ port            8080                                     │
│    routes        > [12 items]                              │
│    0             > (serve ...)                             │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ Int · line 27:11 · 3/5        / search  e editor  ? help   │
└─────────────────────────────────────────────────────────────┘
```

The header shows the file and Gene path. The body contains only visible
rows. The status line shows kind, location, selection count, transient errors,
and the most useful mode-specific keys. `?` opens complete help; the permanent
footer should not attempt to list every binding.

### 4.3 Browse-mode keys

| Action | Keys |
|---|---|
| Previous/next sibling | `Up`/`Down`, `k`/`j` |
| Move one viewport | `PageUp`/`PageDown`, `Ctrl-B`/`Ctrl-F` |
| First/last sibling | `Home`/`End` |
| Enter selected container | `Right`, `Enter`, `l` |
| Return to parent | `Left`, `Backspace`, `h` |
| Return to root | `g` |
| Search | `/`; then `n`/`N` for next/previous |
| Open external editor | `e` |
| Inline scalar edit | `i` when supported |
| Reload | `r` or `F5` |
| Toggle help | `?` or `F1` |
| Quit | `q` or `F10` |

Arrow and paging keys are the primary documented interface. Letter aliases
make the viewer comfortable over terminals that do not transmit function keys
reliably. `Esc` cancels the active mode first; in ordinary browse mode it does
nothing rather than unexpectedly discarding the user's navigation context.

Mouse wheel scrolls and changes the selected row so keyboard navigation
continues from what is visible. Clicking rows and breadcrumb segments can be
added later; mouse support must not be required.

### 4.4 Gene paths

The displayed and command-line path uses Gene's existing slash-path model,
relative to the document root:

```gene
prop/0/x/-1
config/host
routes/2/method
0/event/type       # first form in a multi-form file
head               # Node head projection
```

Symbol segments select node properties or map keys. Integer segments select
list items or Node body items, using Gene's zero-based indexing. Negative
indices have their normal Gene meaning, so `-1` selects the last item. A
multi-form file's synthetic root behaves like a list: its forms are `0`, `1`,
and so on.

The root path is displayed as `/`; every non-root path is printed without an
invented `form[...]`, `prop[...]`, or `body[...]` notation. `--path
prop/0/x/-1` accepts the same static segments as a normal Gene path. The reader
currently desugars slash syntax into ordinary `path` or `select` nodes; it does
not expose a typed selector-segment representation. The viewer therefore
introduces `SourcePathSegment` as a tooling type, reads the complete `--path`
argument with the real reader, requires exactly one form, accepts only static
symbol and integer segments, and converts those validated segments. It must not
split the argument on `/` itself.

Node projections have the same collision rule as runtime selection: an
explicit property such as `^head` wins over the `head` projection. In that
case, `--path head` selects the property; the syntactic node-head row remains
navigable through its private occurrence anchor and is labeled `head (node
head)` in the UI. No second public escape syntax is invented solely for this
rare collision.

Some source occurrences cannot be uniquely named by runtime selector semantics:
duplicate properties in invalid/work-in-progress source are the main example.
The visible path remains a Gene path. A private selection anchor adds occurrence
number, source kind, and a small fingerprint for reload restoration; that
metadata is never exposed as a competing public path syntax.

## 5. Source model: browse syntax, not runtime values

The viewer needs comments, exact spans, incomplete-file diagnostics, duplicate
syntax, and source order. A runtime `Value` is insufficient:

- immediate scalar values have no stable identity for a location table;
- maps may normalize or overwrite keys;
- comments and original quoting are not retained;
- a `Value` describes meaning after reading, not every source occurrence.

Introduce a lightweight reader-owned source index:

```nim
type
  ByteSpan = object
    startByte, endByte: int       # half-open UTF-8 byte range

  # Occurrence categories, not a copy of reader.TokenKind. The indexing code
  # must still make an exhaustive decision for every TokenKind.
  SyntaxKind = enum
    skAtom, skNode, skList, skPropMap, skGeneralMap,
    skProperty, skMetaProperty, skComment,
    skQuasiquote, skUnquote, skSpread, skInterpolation,
    skSequence, skError

  SyntaxRef = object
    id: uint64                    # document-generation-local occurrence id
    kind: SyntaxKind
    immutable: bool               # #(...), #[...], #{...} are shallow immutable
    span: ByteSpan
    openToken, closeToken: int

  SourceDocument = ref object
    path: string
    generation: uint64
    source: string
    lineStarts: seq[int]
    topLevel: seq[SyntaxRef]
    diagnostics: seq[SourceDiagnostic]
```

`SyntaxRef` is a cheap occurrence handle. Children and row summaries are
derived on demand from token ranges and cached per document generation.
`SyntaxKind` deliberately models source occurrences rather than runtime value
kinds: Gene has no set literal, `{{...}}` is the general-map form, and `#(...)`,
`#[...]`, and `#{...}` use the same structural kinds with an immutability flag.
The exact enum may evolve during implementation, but it must be derived from an
exhaustive mapping of the real `TokenKind` surface rather than an illustrative
grammar invented by the viewer.

### 5.1 Reader integration

Do not create `viewer_scan_form`. Refactor the real reader lexer so the parser,
source index, and eventually the LSP consume the same lexical decisions:

1. Keep the semantic-reader `Token` compact and expose a parallel
   `SpannedToken` tooling stream with half-open byte offsets. End offsets are
   explicit because cooked string/char/regex lexemes cannot reliably recover
   their source width.
2. Keep the current eager `tokenize` pass and public `lexAll` materializer for
   Phase 1. Add a tooling mode to that same lexer which retains comment/trivia
   spans needed by the source index without allocating them during normal
   reads. A pull cursor is deferred until `mmap` or windowed huge-file support
   supplies evidence that it is needed.
3. Add a structural indexing helper that matches delimiters and identifies
   direct child token ranges without constructing `Value`s.
4. Move line-start and byte/UTF-16 conversion primitives out of
   `lsp/analysis.nim` into a reader-adjacent source-position module used by both
   the LSP and `SourceDocument`.
5. Keep `readAllWithLocs` as the semantic reader API. The source-index API is
   tooling data and must not alter normal parse allocation behavior.

One lexer is the critical design constraint. When the language adds syntax,
the viewer must recognize it automatically or fail with the reader's normal
diagnostic—not silently invent a different tree. Once occurrence spans are
stable, `lsp/analysis.nim` should derive document-symbol and diagnostic ranges
from them and retire its raw-text form/name scanner. That follow-up also gives
immediate scalars positions, which `readAllWithLocs` cannot currently provide
through the heap-value location table.

The initial implementation confirmed the reader-hot risk: putting offsets on
every `Token` caused a repeatable regression. The shipped design instead
compile-time-specializes the same tokenizer into compact semantic and spanned
tooling paths, so normal reads do not write spans or branch per token. Baseline
to final measurements were 238.33 → 241.20 ms for `reader.single_form` and
190.49 → 192.79 ms for `reader.web_demo.read_all` (about 1.2% in both cases,
within run-to-run noise). If future
tooling cost matters, make raw-text token lexemes (symbols and numbers)
span-derived where ownership permits; do not remove exact spans.

For an interpolated string, the source occurrence span runs from the leading
`$` through the closing quote, including raw escape syntax. Phase 1 need not
expose editable spans for the desugared `$` pieces; it treats the whole form as
one `skInterpolation` occurrence and routes edits to the external editor. The
lexer cleanup should remove the current token-kind backtracking and make that
whole-form boundary unambiguous before finer-grained interpolation navigation
is considered.

### 5.2 Lazy child access

At open, build line starts and top-level spans in the reader's existing eager
`O(source)` tokenization pass. This already meets the MVP first-paint budget; a
pull lexer would add refactoring risk without making the initial source read or
top-level scan disappear. If there is one top-level form, it is the root;
otherwise create a synthetic sequence whose children are the top-level spans.

For a selected container, expose:

```nim
proc childCount(doc: SourceDocument, node: SyntaxRef): int
proc childPage(doc: SourceDocument, node: SyntaxRef,
               start, count: int): seq[ViewerRow]
```

The model asks only for the visible page plus a small look-ahead. It does not
format every child of a million-entry list merely to paint 40 terminal rows.
Cached child boundaries are retained per document generation for containers
the user opens. Reload drops the generation. A memory budget and
least-recently-used eviction remain a huge-file follow-up.

The implemented cache stores unformatted child boundaries and borrows them
without copying. In a release-build smoke check over 50,000 list items, the
first boundary count took about 6 ms and a cached 40-row page about 2 µs;
summaries were generated only for those 40 rows.

MVP still stores the source string, line-start table, and top-level spans in
memory. Its target is `O(source bytes + top-level forms + open-frame indexes)`,
not `O(all descendant Values)`.

### 5.3 Invalid and incomplete files

Opening an invalid file should not destroy the user's ability to edit it.

- If a valid prefix can be indexed, show that prefix plus an `error` row at
  the reader diagnostic location.
- If no structure can be recovered, show a diagnostic/raw-source view centered
  on the error.
- `e` remains available and opens at the error location.
- After the editor exits, retry indexing. If it still fails, retain the last
  good navigation snapshot separately from the current invalid disk state.

The parser remains authoritative. Recovery exists for navigation and repair;
it must not claim that an invalid file is a valid Gene source unit.

## 6. Navigation model

Keep terminal-independent state:

```nim
type
  SourcePathSegmentKind = enum
    spsProperty, spsIndex

  SourcePathSegment = object       # reader-validated static Gene path segment
    case kind: SourcePathSegmentKind
    of spsProperty: name: string
    of spsIndex: index: int64

  SelectionAnchor = object
    path: seq[SourcePathSegment]
    occurrence: int
    kind: SyntaxKind
    fingerprint: uint64
    priorLine: int

  ViewFrame = object
    container: SyntaxRef
    selectedChild: int
    firstVisible: int

  ViewerState = object
    document: SourceDocument
    frames: seq[ViewFrame]
    mode: ViewerMode
    anchor: SelectionAnchor
    status: StatusMessage
```

All commands are state transitions. Rendering reads state but does not change
selection. Terminal size is an input to viewport normalization rather than a
global read hidden inside model functions.

On reload, restore selection in this order:

1. exact Gene path and occurrence;
2. same parent plus matching kind/fingerprint;
3. nearest child to the prior source line;
4. deepest valid parent;
5. document root.

This behaves better than either raw byte offsets, which shift after edits, or
paths alone, which can select the wrong sibling after insertion.

## 7. Editing

### 7.1 External editor: the MVP write path

External editor handoff is the complete, dependable edit feature for the first
release.

Resolution order:

1. `--editor COMMAND`
2. `$VISUAL`
3. `$EDITOR`
4. first installed candidate from `nvim`, `vim`, `vi`

`$VISUAL` is checked first because the command is invoked from an interactive
terminal and conventionally names the full-screen editor. Parse the configured
command into executable plus arguments; do not invoke it through a shell.
This supports settings such as `EDITOR="nvim -f"` without allowing another
round of shell expansion.

Cursor placement is an adapter table, not a hard-coded Vim special case:

| Editor family | Launch shape |
|---|---|
| `nvim`, `vim`, `vi` | `+call cursor(LINE,COL) FILE` |
| `nano` | `+LINE,COL FILE` |
| `emacs`, `emacsclient` | `+LINE:COL FILE` |
| `code`, `codium` | `--goto FILE:LINE:COL` |
| `hx`, `helix` | editor-supported location form when verified |
| unknown | configured args followed by `FILE` |

The handoff sequence is:

1. capture the current selection anchor and file identity;
2. leave curses program mode and restore cooked terminal settings;
3. launch the editor with inherited stdin/stdout/stderr;
4. wait for it to exit;
5. restore curses mode and force a complete repaint;
6. reload if file identity or contents changed;
7. restore the best matching selection anchor;
8. report a non-zero editor exit without terminating the viewer.

Terminal restoration belongs in `defer`/`finally` paths around both the viewer
session and editor suspension. A failed `exec`, signal, or reload must never
leave echo disabled.

### 7.2 Inline scalar edit: a constrained second phase

`i` opens a single-line buffer only when the selected span is one atomic Gene
form. Supported initial replacements are strings, chars, bytes, numbers,
booleans, `nil`, symbols, temporal literals, and regex literals. Containers,
interpolated forms, property keys, implied boolean properties, and synthetic
nodes go through the external editor.

Save validation uses the real reader:

- replacement text must contain exactly one top-level form;
- it must have no trailing significant tokens;
- its structural kind must remain atomic;
- configured reader depth/size limits still apply.

The replacement may change scalar type; changing `1` to `"one"` is legitimate
source editing. It may not expand into multiple forms or a container.

Inline editing has no persisted undo stack in its first release. `Esc` cancels
the edit before save; after a successful replacement, users can edit the value
again or use the external editor's normal undo/history facilities. A real
viewer undo log requires its own conflict and durability design and is not
implied by the `i` command.

### 7.3 Conflict-safe replacement

Before inline editing begins, record the source generation, file identity,
permissions, selected span text, and a content hash. On save:

1. re-stat and re-read the file;
2. refuse the write if it no longer matches the recorded generation;
3. verify that the selected byte range still contains the expected text;
4. build the updated source in memory;
5. parse/index the updated source before touching disk;
6. write a unique temporary file in the target directory;
7. preserve relevant mode bits;
8. flush and atomically rename over the target;
9. reload and restore the selection.

If the file changed, show `file changed on disk; reload or use external editor`
and keep both the edit buffer and disk file intact. Never silently overwrite a
concurrent editor, formatter, build step, or log append.

The native CLI can implement atomic replacement internally before a public
`Fs/write_text_atomic` exists. It should later reuse the shared filesystem
primitive proposed in `docs/persistence.md` rather than keeping two
durability implementations.

Rename-over intentionally replaces the destination inode. It therefore breaks
hard-link identity and may be observed as replacement by inode-watching tools.
The MVP accepts those consequences for ordinary files and documents them in
help; users who require hard-link preservation or in-place write semantics
must use the external editor.

`--readonly` removes inline editing and external editor launch from the active
keymap. It is a viewer policy, not a filesystem security boundary.

## 8. Curses and terminal architecture

Curses is the right default frontend: it handles resize, keypad decoding,
mouse events, repainting, and terminal restoration better than ad hoc ANSI
output. It should remain an adapter, not leak into the model.

The repository has two curses consumers today. `src/gene/stdlib.nim` provides
the public owned Gene `curses/Screen` surface used by
`examples/ai_agent/tui.gene`; `src/gene/repl_curses.nim` separately implements
the native REPL frontend. The public `curses/draw` call is specialized to a
transcript + input + status layout, and `next_event` already covers resize,
Unicode text, mouse wheel, and common navigation but does not distinguish
every viewer key such as Page Up/Down. Building the viewer directly on that
high-level draw API would bend a line editor into a tree widget.

The C shim in `stdlib.nim` already saves/restores termios, decodes SGR wheel
events, and installs signal/exit restoration hooks. Extraction is primarily a
move and consolidation of proven behavior, not a new terminal implementation.
The MVP moves `repl_curses.nim` and the viewer onto the shared native adapter.
The asynchronous public Gene surface keeps its existing backend for now; its
behavior is protected by the existing AI-agent/curses tests. Folding that
stateful async surface onto the adapter is a follow-up, not a prerequisite for
the viewer.

Instead, extract or introduce a small shared native terminal layer:

```text
src/gene/tui/terminal.nim     lifecycle, resize, input decoding, cell width
src/gene/repl_curses.nim     existing REPL frontend
src/gene/viewer/app.nim      viewer frontend
```

The shared layer should provide:

- exclusive session ownership;
- suspend/resume for child processes;
- normalized key events including Page Up/Down and mouse wheel;
- UTF-8 text plus terminal-cell-width measurement;
- clipped drawing that never splits a UTF-8 sequence;
- style attributes independent of fixed color-pair numbers;
- cursor visibility and position;
- a complete repaint request after resize/resume;
- deterministic cleanup hooks.

After extraction, the public Gene `curses` namespace may gain a general
surface API, but `gene view` need not be implemented as a Gene script. A native
implementation is appropriate because source indexing and painting are
performance-sensitive CLI infrastructure. The pure model should still be
usable by a future Gene-level or web frontend.

Existing Gene-level behavior is a compatibility requirement: the AI-agent TUI
tests for cancellation, input history, paging, mouse wheel, resize, paste, and
word wrapping must continue to pass. If the public `curses` namespace changes,
update its executable surface contract in `docs/design.md`; internal extraction
alone should not require a language-surface change.

Windows can use a later backend. The first version should compile the command
with a clear `viewer unavailable on this platform` result when curses support
is absent rather than silently degrading to broken escape-sequence handling.

## 9. Search and large-file behavior

Search should not repeat the legacy behavior of recursively materializing all
descendant rows.

MVP search has two layers:

- row search within the current container is immediate and uses cached row
  labels/summaries;
- document search scans source/token ranges incrementally in source order and
  resolves a hit's containing syntax path only when selected.

`/` enters a visible search prompt. `Enter` selects the first/next match,
`n`/`N` continue after leaving the prompt, and `Esc` cancels prompt editing.
Plain substring search ships first. Regex and structural queries are separate
features because their performance and escaping rules need their own design.

An append-follow mode is useful for logs but deferred. It should reuse the
incremental lexer/indexer and preserve selection unless the user is already at
the tail. Polling and truncation/rotation semantics should not complicate the
initial editor.

Performance expectations for a release build should be recorded in a
benchmark fixture:

- first paint requires one source read and one top-level structural scan;
- moving selection and repainting are proportional to visible rows;
- entering a container is proportional to the child boundary work needed for
  the requested page, not the complete descendant tree;
- idle viewer CPU use is negligible;
- memory is bounded by source bytes, top-level index, open frames, and cache
  budget.

Do not add a second pass through the entire source merely to generate row
summaries. Summaries should be clipped directly from known spans and normalized
only for visible or searched rows.

## 10. Errors, safety, and observability

- The viewer never evaluates source and never loads imports.
- External editor execution is explicit user action. Command parsing does not
  use a shell.
- File paths are resolved once for display and launch, while replacement uses
  the opened file's verified identity.
- Symlink behavior must be explicit: follow the symlink for viewing, but refuse
  inline atomic replacement unless the implementation can replace the target
  without replacing the symlink itself unexpectedly.
- A read-only or permission-denied file remains fully navigable.
- Parse errors and editor failures are status/diagnostic events, not crashes.
- Terminal cleanup errors must not hide the original viewer error.
- Diagnostic logging may record file size, durations, cache sizes, command
  family, reload outcome, and error kind. It must not log source text, search
  queries, replacement text, editor arguments containing user secrets, or
  environment values.

## 11. Proposed modules

```text
src/gene/source_positions.nim   line starts and byte/UTF-16 conversions
src/gene/source_index.nim       reader-backed spans, paths, lazy child pages
src/gene/lsp/analysis.nim       LSP consumer; sheds duplicate range scanning
src/gene/viewer/model.nim       pure modes, frames, anchors, commands
src/gene/viewer/editor.nim      editor resolution and safe handoff
src/gene/viewer/file_edit.nim   conflict checks and atomic span replacement
src/gene/viewer/app.nim         render/event loop
src/gene/tui/terminal.nim       shared terminal contract
src/gene/repl_curses.nim        existing REPL frontend on the shared layer
```

`src/gene.nim` registers the CLI command directly, following the current
single-binary command dispatch. If command count continues to grow, command
dispatch can be extracted separately; the viewer should not introduce a new
command framework by itself.

`source_positions.nim` and `source_index.nim` are reader-adjacent rather than
viewer-owned because the LSP is an equal consumer of their contracts. The
model depends on source-index interfaces and ordinary data types. It does not
import curses, environment access, process launching, or direct file I/O.

## 12. Verification strategy

### 12.1 Reader and source-index tests

- every reader atom/container form produces correct half-open byte spans;
- multi-form source, comments, datum comments, interpolation, immutable
  containers, selectors, temporal literals, bytes, chars, and regexes;
- interpolated strings have one exact raw span from `$` through the closing
  quote and are not inline-editable in the MVP;
- Unicode line/column and byte offset conversion;
- malformed and incomplete sources retain reader diagnostics;
- the viewer structural index and semantic reader agree on valid fixtures;
- adding a reader token kind requires an exhaustive source-index decision;
- `lexAll` keeps its significant-token behavior and ordinary reads do not
  allocate comment/trivia records;
- shared source positions preserve all ranges in the existing LSP fixtures,
  including byte/UTF-16 round trips;
- new occurrence-index fixtures cover spans for immediate scalars that the
  current heap-value location table cannot position.

### 12.2 Pure model tests

- enter/leave restores selection and scroll;
- page movement clamps correctly at both ends;
- resize keeps selection visible;
- reload anchor resolution covers insertion, deletion, reorder, and type
  change;
- synthetic multi-form roots and empty/scalar files;
- mode-specific escape behavior;
- search ordering without eager tree construction.

### 12.3 Editing tests

- `$VISUAL`, `$EDITOR`, `--editor`, fallback, and quoted arguments;
- cursor argument adapters for supported editor families;
- a fake editor modifies the file and exits 0/non-zero;
- terminal session resumes after launch failure and interruption;
- inline replacement preserves surrounding bytes exactly;
- invalid replacement never writes;
- concurrent file changes cause a conflict, not overwrite;
- atomic replacement preserves permissions and leaves no predictable temp
  file;
- `Esc` cancels an unsaved inline edit and the UI does not promise post-save
  undo;
- hard-link/inode replacement behavior is documented and tested explicitly;
- parse failure after external editing remains recoverable.

### 12.4 Pseudo-terminal tests

Use a PTY rather than snapshots of implementation-specific curses escape
sequences. Cover arrows, paging, mouse wheel, resize, search prompt, editor
handoff, repaint, quit, and terminal echo restoration. Keep most behavior in
pure tests so PTY coverage can remain small and robust.

Run the existing public Gene curses and AI-agent TUI tests unchanged against
the extracted terminal layer, and keep a focused native REPL smoke test so
neither existing consumer regresses while the viewer is added.

### 12.5 Performance tests

Add generated fixtures for:

- many top-level log records;
- one very large flat container;
- deeply nested containers;
- long strings and wide Unicode;
- search near the beginning and end.

Track first-paint time, peak resident memory, child-page latency, and repaint
throughput in release mode. Viewer work should not regress reader or parser hot
paths merely to expose tooling offsets.

Keep the compact/spanned token split measured with before/after `nimble perf`
numbers. The acceptance target is no material regression in
`reader.single_form` or `reader.web_demo.read_all`; if noise obscures the
result, repeat the benchmark rather than combining span work with viewer code.

## 13. Implementation sequence

### Phase 1: shared spans and read-only model

1. Add the compile-time-specialized `SpannedToken` tooling stream while
   preserving the compact eager `tokenize`/`lexAll` contracts and normal-read
   allocation behavior.
2. Extract shared source-position conversions from `lsp/analysis.nim`.
3. Implement the reader-adjacent source index and pure navigation model.
4. Cover valid, invalid, single-form, and multi-form files, including exact
   whole-form interpolated-string spans.
5. Rebase LSP ranges on shared positions immediately; migrate document-symbol
   extent/name scanning to occurrence spans once the index is stable.

### Phase 2: terminal frontend and CLI

1. Extract shared terminal lifecycle/input primitives from the current curses
   implementation.
2. Adapt `repl_curses.nim` onto the shared layer and preserve the public Gene
   curses surface behind its existing async backend and compatibility tests.
3. Add viewer rendering, resize, Page Up/Down, mouse wheel, help, and CLI
   validation.
4. Add compatibility and PTY cleanup tests before enabling the command by
   default.

### Phase 3: external editor and reload

1. Resolve `--editor`, `$VISUAL`, `$EDITOR`, and fallbacks safely.
2. Suspend/resume curses around inherited-stream child execution.
3. Reload and restore semantic anchors after the editor exits.

This phase delivers the requested navigation and editing workflow and is the
recommended MVP boundary.

### Phase 4: inline scalar editing

1. Add reader-validated atomic scalar buffers.
2. Add conflict detection and atomic replacement.
3. Reuse the shared filesystem atomic-write primitive when it exists.

### Phase 5: search and log ergonomics

1. Add incremental document search and match navigation.
2. Add optional append-follow behavior with explicit truncation/rotation
   semantics.
3. Consider saved bookmarks or path copy only after real usage.

## 14. Decisions and deferred questions

Recommended decisions:

- Use curses, behind a shared native terminal abstraction.
- Keep the viewer native but its model frontend-independent.
- Index syntax occurrences from the real reader; never maintain a viewer-only
  Gene grammar.
- Put source positions and occurrence indexing beside the reader so the viewer
  and LSP share them.
- Keep eager tokenization for the MVP; defer a pull cursor until huge-file
  storage work demonstrates a need.
- Make external editor handoff the MVP edit story.
- Prefer `$VISUAL`, then `$EDITOR`, and never run editor configuration through
  a shell.
- Defer inline editing until conflict-safe atomic span replacement is ready.
- Ship inline editing without post-save undo; the external editor remains the
  durable history/undo path.
- Preserve source formatting and comments by editing spans, never by printing
  the entire parsed value.

Questions that can wait for implementation evidence:

- Whether source storage should move from an in-memory string to `mmap` for
  very large logs.
- Whether a general public curses surface should be exposed after the native
  terminal layer is extracted.
- Whether inline edit should support property keys and structural operations;
  external editing is sufficient until a clear high-frequency workflow
  justifies those semantics.
- Whether follow mode belongs in `gene view --follow` or a separate `gene
  tail` command.
