# Imagination

An autonomous drawing agent written in Gene. A multimodal model draws by
writing small, validated patches to a structured SVG scene; the application
renders each state through PDF to a clean PNG, shows the model the actual
pixels, and keeps every step in a branching history (`Evolution`) that a
person can inspect, compare, and continue from.

The design is [docs/design.md](docs/design.md) (first release, milestones 1–4);
[docs/implementation.md](docs/implementation.md) records what was built,
the decisions made during implementation, and what is still open.

## Requirements

- This repository's `gene` binary (`nimble build`).
- librsvg and Poppler: `brew install librsvg poppler` on macOS, or
  `sudo apt-get install -y librsvg2-bin poppler-utils` on Debian/Ubuntu.
  If they are already installed, there is nothing to install: run
  `bin/imagination doctor` to check them. (`brew install` on an installed but
  outdated formula tries to upgrade it, which fails on a macOS release
  Homebrew does not recognize yet.) The checked versions are librsvg 2.60.0
  and Poppler 25.05.0; PNG digests in the saved fixtures are only compared
  under those versions.
- For drawing runs, a model: `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY`
  (default model Claude Opus 5.5), or a ChatGPT sign-in through the Codex CLI
  (`codex login`; default model `gpt-6-astra`), used as in gene-harness. With
  no key set, a Codex login is picked up from `CODEX_AUTH_FILE`,
  `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`. `IMAGINATION_PROVIDER`
  (`anthropic`, `openrouter`, `codex`), `IMAGINATION_MODEL`, and
  `IMAGINATION_EFFORT` override the choice.

The DejaVu fonts in `fonts/` are bundled (license in `fonts/LICENSE_DEJAVU`);
rendering never reaches a system font.

## Quick start

```sh
cd examples/imagination
bin/imagination doctor                       # tools, fonts, conversion, image transport
bin/imagination create cat-window --prompt "A stylized cat beside a rainy city window."
bin/imagination run cat-window --max-iterations 8
bin/imagination serve                        # prints http://127.0.0.1:<port>/
```

`bin/imagination` runs `${GENE_BINARY:-gene}`. Projects live in
`$IMAGINATION_HOME` (default `examples/imagination/projects/`).

In the browser: create a project from a prompt, press **Draw on this line**,
watch candidates appear under review, click any thumbnail to inspect it (this
turns follow-live off), **Continue from this revision** to fork a line, and
**Compare** two revisions. **Choose as result** records the selection.

## Commands

| Command | Purpose |
| --- | --- |
| `doctor [--no-model] [--save FILE]` | Check tool paths and flags, font isolation, a conversion fixture, the PNG header, and image transport |
| `render <scene.gene> <out>` | Export SVG, PDF, PNG, and a manifest for one scene |
| `draw <out> <patch.gene>...` | Apply handwritten patches to a blank scene, exporting every step |
| `spike <run-dir> --prompt TEXT` | The milestone 2 loop: draw with a live model, keeping each step as files |
| `create`, `run`, `history`, `show`, `continue`, `apply`, `compare`, `replay`, `export` | Project operations on an Evolution |
| `serve [--port N]` | The web workbench and API on 127.0.0.1 |

## Tests

```sh
cd examples/imagination
gene test
```

The specs cover scene validation and canonical form, the patch interpreter
and locks, the render route and its failure stages, the agent protocol with
saved responses, the Evolution history and publication transaction, runs, and
replay of three saved live transcripts. They need the native tools but no
model.

## Layout

| Path | Contents |
| --- | --- |
| `src/scene_schema.gene` | The svg-scene/v1 registry used by validation, the interpreter, and the prompt |
| `src/scene.gene`, `svg.gene`, `patch.gene`, `diff.gene` | Scenes, canonical SVG, the atomic patch interpreter, structural diffs |
| `src/render.gene`, `src/adapters/` | The rsvg-pdf-poppler/v1 profile, bounded tool processes, the model transport |
| `src/evaluation.gene`, `agent.gene`, `prompts/` | Goals, reviews, acceptance and completion, the drawing loop |
| `src/store.gene`, `evolution.gene`, `jobs.gene` | Project folder, SQLite index, immutable blobs, history operations, runs |
| `src/server.gene`, `style.gene`, `client/` | The API, event socket, and the web-profile workbench |
| `fixtures/` | Scenes, handwritten patches, a replay record, tool stubs, live transcripts |
