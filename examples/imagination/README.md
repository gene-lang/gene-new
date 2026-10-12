# Imagination

An autonomous drawing agent written in Gene. A multimodal model draws by
writing small, validated patches to an SVG scene or a deterministic raster
painting program. The application renders each state to a clean PNG, shows the model the actual
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
  (`codex login`; default model `gpt-6-sol`), used as in gene-harness. With
  no key set, a Codex login is picked up from `CODEX_AUTH_FILE`,
  `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`. `IMAGINATION_PROVIDER`
  (`anthropic`, `openrouter`, `codex`), `IMAGINATION_MODEL`, and
  `IMAGINATION_EFFORT` override the choice.

The DejaVu fonts in `fonts/` are bundled (license in `fonts/LICENSE_DEJAVU`);
rendering never reaches a system font.

Raster painting uses Cairo for path coverage, project-owned linear-light
brushes/compositing and libpng. It does not require the SVG/PDF tools. Build
the worker with `gene run src/genex/raster/tools/build.gene` from the repository
root, then set `GENE_RASTER_WORKER` to its printed absolute path. See
[raster setup and behavior](docs/raster-implementation.md) for dependencies,
profiles, limits and deterministic pixel verification.

## Quick start

```sh
cd examples/imagination
bin/imagination doctor                       # tools, fonts, conversion, image transport
bin/imagination create cat-window --prompt "A stylized cat beside a rainy city window."
bin/imagination run cat-window --max-iterations 8
bin/imagination serve                        # prints http://127.0.0.1:<port>/
```

For raster, use `create sphere --media raster --prompt "A red sphere with soft
lighting."` and `serve --media raster`. The workbench also offers **Raster
painting** when creating a project. Every edit repaints the saved program
from blank; no image-generation service is invoked by the renderer.

For textured directional brushes, regional stroke helpers and PNG reference
guidance, use **Textured painting** or `--media painterly`. See the
[painterly guide](docs/painterly.md), including `reference` and
`paint-reference` commands. Its separate v2 renderer preserves existing v1 projects.

`bin/imagination` runs `${GENE_BINARY:-gene}`. Projects live in
`$IMAGINATION_HOME` (default `examples/imagination/projects/`).

In the browser: describe a picture to create a project, press **Draw**, and
watch each edit appear while it is under review. The line under the canvas
says what the run is doing and for how long; **Activity** lists what it has
done. To change the drawing, type in the box under the canvas:

- during a run, the instruction joins the goal at the run's next step;
- after a run, **Revise and draw** adds it to the line's goal and draws on
  from the head;
- on an older or unaccepted revision, it starts a new line from there and
  leaves the current line alone.

Click any thumbnail to inspect it (this turns follow-live off), **Compare**
two revisions, and **Choose as result** to record the selection.

## Commands

| Command | Purpose |
| --- | --- |
| `doctor [--no-model] [--save FILE]` | Check tool paths and flags, font isolation, a conversion fixture, the PNG header, and image transport |
| `render <program.gene> <out>` | Render SVG or raster; raster produces PNG and a manifest |
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
