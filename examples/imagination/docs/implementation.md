# Imagination: implementation record

**Covers:** milestones 1–4 of [design.md](design.md) v0.3, implemented 2026-10-02.
**Toolchain checked:** macOS, librsvg 2.60.0, Poppler 25.05.0, cairo 1.18.4;
model `anthropic/claude-opus-5.5` through OpenRouter.

This page records what was built against each milestone, the decisions taken
where the design left a choice open, deviations from the design text, and
what remains. Section numbers refer to the design.

## Milestone status

### Milestone 1: deterministic drawing without an AI — complete

Scene schema registry (§7.3), strict parser boundary (§8.4 step 1), the
eleven operations (§8.2) resolved into normalized primitives, locks (§6)
including indirect changes, per-proposal ID allocation, versioned canonical
form (§7.4), deterministic SVG, the rsvg-convert → pdfinfo → pdffonts →
pdftocairo route with font isolation and render manifests, detail crops and
thumbnails, and `imagination doctor`.

Exit evidence (`tests/scene_spec`, `patch_spec`, `render_spec`):

- `fixtures/replay/landscape.gene` is a recorded drawing of four steps made by
  `imagination draw` from the handwritten patches in `fixtures/patches/`.
  Replaying its normalized patches reproduces every scene and SVG digest, and
  the PNG digests too when the tool versions match the record.
- A mixed valid/invalid batch leaves the base unchanged and reports the
  operation index, target, field, and expected condition.
- Text, thin strokes, gradients, clipping, transforms, opacity, and blur render
  correctly through the PDF route (`fixtures/scenes/effects.gene`,
  `text.gene`); page count, page size, PNG dimensions, embedded fonts, and the
  digests in the manifest are verified on every render.
- Every failure stage (SVG to PDF, multi-page and invalid PDF, PDF to PNG,
  timeout, missing tool, effect-surface limit) reports its stage, using stub
  tools in `fixtures/tools/`.

### Milestone 2: drawing-loop spike — gate passed

`imagination spike` runs the §10.5 loop with files only (`src/rundir.gene`).
The three live examples of §17.3 were run once each with default budgets.

| Example | Status | Edits | Model calls | Tokens in / out |
| --- | --- | --- | --- | --- |
| Landscape with one tree, a river, and a setting sun | complete | 3 | 4 | 36,802 / 5,445 |
| Poster with the exact headline "RAIN CITY" | complete | 2 | 3 | 29,016 / 6,171 |
| Stylized cat beside a rainy city window | complete | 4 | 6 | 82,392 / 12,322 |

Each final picture is recognizable as the request (`fixtures/transcripts/*/final.png`).
The transcripts show the model acting on problems it reported in its own
renders: the landscape's "olive rim-light circle reads as a muddy blob" was
softened in the next edit and the missing river shimmer added; the cat run
reported "no rain is visible on the glass" and "the interior is empty" and
fixed both in order. The cat run also contains one repaired response: an
`(issue ...)` placed outside the review was rejected as surplus content and
corrected on the next call. Total spend was about one US dollar.

The gate result also bears on the follow-on merge design: the model works
well at the scale of small, intent-labelled patches against stable IDs,
which is the material a semantic merge would operate on.

### Milestone 3: Evolution and the web shell — complete

`src/store.gene` (project folder, SQLite index in WAL mode, immutable blobs,
staging, startup recovery, project lock), `src/evolution.gene` (immutable
revisions, lines, compare-and-swap publication, fork, goal change, selection,
compare, exact replay, export), the API server, and the web-profile client.

Exit evidence (`tests/evolution_spec`): forking from an early revision and
developing both lines leaves every earlier revision unchanged; exactly one of
two head updates succeeds; a crash after blob publication and before the
index commit shows no revision; history, selection, lines, and artifacts are
identical after a restart; a corrupt object is reported, not recreated. In a
browser, a project with two lines shows the revision graph, every
intermediate image, the inspector, and comparisons, and survives a server
restart.

### Milestone 4: the drawing loop in the application — complete

`src/jobs.gene` runs the loop on an Evolution (`EvolutionSession`): runs are
persisted with phase, accepted revision, budgets, usage, last error, and
terminal status; cancellation, steering (a new goal record at the next safe
boundary), and resume are implemented; events are appended to the outbox in
the transaction that makes the change and pushed over the WebSocket.

Exit evidence: `tests/jobs_spec` and `tests/agent_spec` cover the response
union, reviews, acceptance and rejection, a patch based on a rejected
candidate, missing reviews, no-ops, inspection, the iteration limit,
cancellation, and model failure with saved responses; `tests/transcript_spec`
replays the three saved live transcripts through the application loop and
reaches the same status and final scene. Two live runs were driven from the
browser with Playwright, end to end: prompt → planned goal → run → previews
under review → truthful terminal status. "A lighthouse on a rocky shore at
dusk" completed in one edit (three calls, one of them a repaired patch); "a
cozy log cabin in a snowy pine forest at night" completed through six edits
with every intermediate render shown live. After a page reload and after a
server restart the history, selection, and model view (the exact submitted
PNG digests) were unchanged. Against the running server, a repeated
selection with the same idempotency key acted once, a stale selection and a
run against an old head returned 409 with the current state, and a change
made by another client reached an open page over the event socket.

## Decisions and deviations

- **Antialiasing.** `-antialias best` corrupts TrueType glyphs with this
  Poppler and cairo (shapes are unaffected); the profile uses `good`, which is
  byte-identical to the default. The design's §7.7 command was corrected.
- **Font environment.** `$os/exec` has no environment option, so the profile
  starts `rsvg-convert` through the fixed path `/usr/bin/env` with
  `PANGOCAIRO_BACKEND=fc` and `FONTCONFIG_FILE=<project>/fonts.conf` as argv
  entries. No shell is involved. An `^env` option for `$os/exec` belongs in
  the standard library and was not added here: the asynchronous spawn path
  marshals options across worker threads and deserves its own change.
- **Canonical transforms.** A transform field at its default (`translate
  [0 0]`, `rotate 0`, `scale [1 1]`, `pivot [0 0]`) is omitted from the
  canonical form, so an edit that only restates a default is an exact no-op
  and is detected by digest.
- **Background.** The reserved background rectangle covers the whole canvas,
  including letterbox margins when the view box and canvas differ in aspect.
- **Transparent artwork.** The model's viewing PNG is Poppler's white page,
  recorded as `^matte "#ffffff"`; the RGBA image is a separate artifact.
- **IDs.** New object IDs use a per-proposal prefix `n<k>-` reserved before
  each model call, so concurrent lines can never create the same identity;
  `object_ids` records every published ID. Revision IDs are a project-wide
  sequence (`r000`, `r001`, ...), run IDs `run-NN`, jobs `<project>.<run>`.
- **Patch envelope.** `^goal` and one `(intent "...")` are required.
- **Acceptance policy (§10.2).** A candidate is rejected when any requirement
  ranks lower than on the previous accepted revision (pass > partial > fail,
  unknown as fail). The prompt states the rule so the model can predict the
  patch base. Deliberate temporary regressions are not supported.
- **Completion (§10.3).** A `done` on an image without a visual review for the
  current goal triggers one `VisionAgent.evaluate` call; a second refused
  `done` ends the run as partial instead of asking again.
- **Goal planning.** A request becomes a goal record through one planner call;
  the original request text is always kept verbatim. Literal text adds a
  structural `^text` requirement that the application checks itself.
- **Inspection.** Object inspection returns canonical subtrees and bounds;
  crop inspection renders from the stored PDF at twice the observation scale.
- **Provider.** The OpenRouter path is exercised live. The Anthropic Messages
  path (base64 image blocks, cached system prompt, `fallbacks: "default"` with
  its beta header, which `IMAGINATION_ANTHROPIC_FALLBACKS=off` removes) was
  written from the API reference but not run: no Anthropic key was available.
- **Codex sign-in.** Added after the first release, like gene-harness: the
  `codex` provider reads the Codex CLI's `auth.json` at every call (the CLI
  owns and refreshes it), posts to the ChatGPT Codex Responses endpoint with
  streaming and `store=false`, sends images as `input_image` data URLs, and
  takes only the final answer of a completed response, so commentary or a
  severed stream never becomes a response. Parser errors on `auth.json` are
  never echoed. Checked live: `doctor`'s image transport and a complete
  poster run with `gpt-6-astra`.
- **Sandboxing.** The tools receive only SVG the serializer generated, which
  can hold no URL, script, or external reference; there is no additional
  network sandbox around the processes.
- **Browser session.** Single-user loopback: Host and Origin are checked on
  every request, and mutations need a per-process token embedded in the page.

## Standard-library additions

Made in `src/gene/stdlib.nim` (tested in `tests/test_stdlib_data.nim`,
documented in `docs/stdlib.md`):

- `$base64/encode` and `$base64/decode` (canonical form only).
- `$parse/read_all ^reject_duplicate_props ^max_depth` for untrusted text.
- `$fs/write_bytes_atomic` for staged, synchronized, renamed binary blobs.

## Language and runtime findings

- `continue` is rejected inside a `match` branch and inside `catch`; the loop
  body became a step function that returns nil to continue.
- A local named `path` in head position reads as the path form, so
  `(path .push x)` fails with an unrelated message.
- The head of a type is the type itself, so `($head ($head x)) == Sym` is
  also true of a bare symbol; node detection must exclude it.
- `(== 1 1.0)` is false; canonical numbers normalize integral floats to Int.
- Two `repeat i` loops in one function are a duplicate binding.

## Open items

- §10.2's set of non-dominated candidates is not kept; the loop keeps one
  working candidate.
- History pagination is served but the client loads the first page only; very
  large histories would need lazy thumbnail loading.
- Export bundles with a reachable DAG and import (§12.3) are not built.
- The optional `inkscape-pdf-poppler/v1` profile and a 2048-pixel profile are
  not implemented; the profile edge is configurable in code.
- The browser checks were run with Playwright; there is no committed browser
  test suite.
- The compare panel shows both images and the computed changes; the optional
  slider, heat map, and AI explanation of a diff (§11.2) are not built.
- §17.5 scenario 2 (clicking an older thumbnail during a live run keeps the
  inspection view) is implemented through follow-live but was not exercised
  during a live run.
