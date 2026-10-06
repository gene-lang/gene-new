# Imagine Raster: deterministic painting in the Gene Imagination framework

**Status:** implementation design, version 0.1  
**Framework:** the `Evolution`/`Media` architecture in `imagination.md`  
**Authoritative medium:** an editable Gene painting program  
**Visual output:** PNG rendered directly from raster surfaces  
**Required behavior:** after every completed edit, repaint the entire program from a fresh canvas

## 1. Purpose and governing decision

Build a Gene example that creates raster artwork through brushes, gradients, masks, textures, and compositing. A multimodal model edits a compact painting program, receives its actual rendered PNG, and continues refining the result. The same creation framework supports inspection, alternatives, restoration, merging, and continuation from any saved revision.

The user's governing decision is:

> After every edit, repaint from the beginning. Painting must be deterministic.

An edit changes the painting program. It does not directly mutate a persistent bitmap. The renderer executes the complete resulting program against fresh surfaces, including unchanged early operations. Pixel buffers and PNGs are derived artifacts. Immutable program snapshots are the values versioned by `Evolution`.

```text
Render(canonical_program, immutable_assets, renderer_profile) -> pixels, PNG, manifest
```

Identical complete inputs must produce identical pixel bytes within a certified renderer profile. The pinned PNG encoder must also produce identical PNG bytes. Model decisions and evaluation are outside this pure rendering function and can be nondeterministic; saved decisions are never regenerated during rendering.

This document specializes the existing framework. It replaces the optional integer/pixel-art raster adapter in `imagination.md` for this application. It does not change the SVG adapter or require a rewrite of the generic history engine. The raster application can be implemented directly without completing the SVG backend first.

## 2. What is reused and what changes

| Existing framework component | Raster specialization |
| --- | --- |
| `Evolution[T]`, immutable revisions, named lines, provenance | Instantiate conceptually as `Evolution[RasterPainting]` |
| Drafts and atomic validated patches | Apply edits to the painting program |
| Goals, locks, budgets, acceptance and completion | Reuse; add raster selection/dependency rules |
| `Media` adapter boundary | Implement `raster-painting/v1` |
| SQLite index and immutable object store | Store complete programs, assets, patches, evaluations, and renders |
| Multimodal model adapter | Submit actual PNG bytes plus bounded program summaries |
| Jobs, cancellation, idempotency, SSE | Reuse the same lifecycle and publication rules |
| React/TypeScript workbench and revision DAG | Show raster PNGs and program-aware inspectors |
| Structural/semantic merge, restore, replay | Specialize for layers, operations, resources, order, and pixel-reading dependencies |
| SVG → PDF → PNG renderer | Use direct raster → PNG for this medium |

Use the pinned Gene checkout's implemented syntax and host bridge. All Gene examples below are serialized domain data, not executable functions. `Evolution[RasterPainting]` is conceptual type notation, not a claim about available Gene generic syntax. Keep creative orchestration, validation, and history logic in Gene; native code performs bulk pixel work.

## 3. First release and later capabilities

The first release must support:

- A fixed-size canvas, transparent named layers, and an explicit background.
- Solid path fills and linear/radial gradient fills.
- Hard-round and soft-round pressure-sensitive brushes.
- Static path masks and optional content-addressed grayscale texture assets.
- Source-over painting, layer opacity, and erasing within a layer.
- Stable IDs, atomic edits, full repaint, PNG output, and deterministic verification.
- The existing web interface, branching history, and bounded multimodal feedback loop.

Later profiles may add textured/bristle brushes, smudging, layer blend modes, blur, procedural stroke generators, and libmypaint. Physical wet paint, pigment transport, watercolor diffusion, and photorealistic output are separate capabilities. A convincing painted scene does not require physical paint simulation, but the model's ability to construct realistic form and lighting must be measured.

No generative image service is called inside the renderer. Initial texture assets are small brush/paper masks with recorded provenance. Reference photographs may guide planning in an explicit reference mode; the prompt-only acceptance scenario must start without a hidden target image.

## 4. Dependencies and native boundary

| Dependency | Responsibility | Initial status |
| --- | --- | --- |
| Gene runtime and its Nim/native bridge | Program representation, application logic, history, model loop | Required, pin revision |
| Skia CPU build | Geometry rasterization, gradient evaluation, surface operations, PNG encoding | Required, pin build |
| Small project-owned C++ renderer bridge | Versioned ABI, program execution, deterministic brush stamper | Required |
| SQLite adapter | Transactional history/index operations | Reuse existing framework |
| React, TypeScript, Vite, `@xyflow/react` | Workbench and history visualization | Reuse existing frontend |
| Image-capable model transport | Actual image submission and validated responses | Reuse existing model adapter |
| libmypaint | Richer brush behavior through a separate profile | Optional after basic renderer |
| CanvasKit | Browser-side interactive rendering if later needed | Optional |

Skia provides gradient, shader, blend, and PNG facilities; it is not by itself a natural-media brush planner. Implement the initial brush stamper with explicit rules. Expose the renderer through a narrow project-owned C ABI wrapping Skia's C++ API; do not assume Skia provides the exact stable C ABI Gene needs.

Start with a subprocess worker as the application boundary if direct FFI is inconvenient in the pinned checkout. A worker accepts one bounded structured request and writes artifacts under an application-owned staging directory. It cannot select arbitrary output paths or load arbitrary code. Direct FFI can later use the same request/result schema and ownership contract.

The browser initially displays backend-generated PNGs. It does not need its own painting engine. Any later browser preview is advisory unless verified under the same renderer profile. Inkscape, Poppler, and PDF conversion are not runtime dependencies for this raster route. Direct PNG export preserves the renderer's pixels; routing existing raster pixels through PDF cannot create missing detail.

## 5. The authoritative painting program

### 5.1 Structure and identity

A `RasterPainting` value contains canvas configuration, immutable resource definitions, and an ordered list of layers. Each layer contains an ordered operation list. Stable IDs identify layers, resources, and operations across revisions. Labels and roles are semantic metadata and do not change pixels.

```gene
(painting
  ^schema "raster-painting/v1"
  ^width 1024 ^height 1024
  ^background "#f2e8d8ff"
  ^working_space "linear-srgb"
  (resources
    (brush ^id "soft-round" ^kind "soft-round/v1"
      ^hardness 0.2 ^spacing 0.2 ^flow 1
      ^min_radius_ratio 0.25)
    (gradient ^id "apple-light" ^kind "linear"
      ^from [300 350] ^to [700 700]
      (stop ^offset 0 ^color "#f08c59ff")
      (stop ^offset 1 ^color "#8b222aff"))
    (mask ^id "apple-shape" ^kind "path" ^fill_rule "nonzero"
      (path
        (M 330 390) (C 240 540 310 740 500 745)
        (C 690 745 760 540 650 390)
        (C 560 330 420 330 330 390) (Z))))
  (layer ^id "apple" ^label "Apple" ^role "subject"
    ^opacity 1 ^blend "source_over" ^^visible
    (fill_mask ^id "apple-base" ^mask "apple-shape"
      ^paint "apple-light" ^opacity 1)
    (stroke ^id "apple-highlight" ^brush "soft-round"
      ^color "#ffe2b5ff" ^radius 35 ^opacity 0.2
      ^mask "apple-shape" ^seed 42
      (points
        [390 425 0.3 0]
        [380 470 0.8 40]
        [390 520 0.2 80]))))
```

The path and colors are an illustrative program, not a finished or evaluated apple. Point tuples are `[x, y, pressure, time_ms]`; time is relative to that stroke. Time is explicit input for future brush dynamics. The initial dry-brush algorithm does not use wall-clock time or speed-dependent paint deposition.

Resource references are IDs, resolved to immutable definitions inside this snapshot. External texture/font/reference assets use full content digests; placeholder digest strings in documentation are not accepted as stored hashes. A saved revision must retain all referenced asset bytes.

### 5.2 Coordinates and composition

- Coordinates are continuous canvas units; x increases rightward and y downward.
- One canvas unit equals one output pixel in the initial profile. Changing width/height is a program edit, not an implicit scale of existing coordinates.
- Normalize geometry to a grid of 1/1024 canvas unit using an explicit round-to-nearest, ties-to-even rule; reject nonfinite numbers. Canonical numbers describe this normalized value.
- Normalize pressure, hardness, flow, opacity, gradient offsets, and minimum-radius ratios to multiples of 1/65536 with the same tie rule; clamp only where an operation explicitly permits it. Validate ranges before normalization. Times are integer milliseconds. Serialize normalized binary-grid values as exact terminating decimal strings with trailing fractional zeros removed, and normalize negative zero to zero.
- Layers render independently into transparent surfaces, bottom to top in root child order.
- Within a layer, operations execute in child order. Later paint sees that layer's earlier paint.
- Layer opacity and layer mask apply once after its operation list completes, before compositing the layer onto the accumulated output.
- Operation masks apply at the operation's paint-deposition stage. A layer mask is a separate compositing stage; reusing the same mask at both stages intentionally multiplies its effect twice.
- The background is initialized once before layer compositing. A transparent background is supported; the default model observation uses an explicit opaque background.
- Erasing removes alpha from the target layer. It does not erase lower layers or the canvas background.

The initial schema has no automatic reparenting, object detection, or hidden transforms. Moving a painted object is an explicit edit of selected geometry, with associated masks/gradients adjusted through a reviewed resource mapping. Later affine transforms need their own versioned semantics for brush size, spacing, textures, and sampling.

### 5.3 Resources and operation registry

| Kind | Required semantics |
| --- | --- |
| `brush` | Versioned brush kind, hardness, spacing, flow, radius mapping, optional immutable texture |
| `gradient` | Canvas-space geometry, ordered color stops, clamped extent, interpolation policy |
| `mask` | Static path coverage or immutable grayscale bitmap with explicit placement |
| `texture` | Content digest, dimensions, sampling/filtering and wrap rules |
| `fill_path` | Typed path geometry, solid color or gradient, opacity, optional mask |
| `fill_mask` | Paint a static mask with a solid color or gradient |
| `stroke` | Brush reference, ordered points, color, base radius, opacity, seed, optional mask |
| `erase` | Same path/dab model as a stroke; scales destination color and alpha by remaining coverage |

The v1 mask graph is static: masks cannot sample a live layer or contain painting operations. Resource references must be valid and acyclic. `M`, `L`, `C`, `Q`, and `Z` are accepted path commands. The initial fill rule is `nonzero`; other rules require explicit profile support.

Unknown operation heads/fields, invalid ranges, missing resources, duplicate IDs, and excess resource costs are schema errors. The schema registry drives both interpreter validation and model-facing documentation. Never evaluate these domain nodes as arbitrary Gene code.

For fills, use exactly one of `^color` (a literal RGBA color) or `^paint` (a gradient resource ID). Canonicalization sorts properties by their schema key, preserves child/list order, uses fixed string escaping and UTF-8/newline rules, and emits explicit normalized defaults. It never sorts layers, operations, points, or stops to make hashes convenient. Preserve operation IDs when replacing the same authored operation; a distinct new operation receives a new ID.

## 6. Determinism contract

### 6.1 Profile identity

A renderer profile is immutable and includes:

| Input | Record |
| --- | --- |
| Semantics | Painting schema, normalization, brush and mask algorithm versions |
| Executable | Worker/bridge digest, Skia revision and build configuration |
| Numerical environment | OS/architecture, selected CPU features, floating-point mode, compiler options |
| Processing | CPU backend, operation order, threading policy, raster sampling rules |
| Color | Working format, color conversion and blending policy, output profile |
| Assets | Actual texture, preset, and font digests where applicable |
| Encoding | PNG encoder, compression library versions, filters, compression and chunk policy |

The first certified profile uses CPU rendering, ordered operations, no concurrent writes to a surface, and no fast-math compiler options in project-owned pixel code. Certification requires repeat-render tests in fresh processes on that exact build/environment; CPU selection alone is not proof of determinism.

Cross-platform byte equality is not an initial guarantee. A different platform/build is a different profile until explicitly certified as equivalent. The application must never quietly substitute another profile. If the original profile is unavailable, display the saved PNG and report that original-profile repainting is unavailable; an explicit migration creates a new revision with a new render profile.

### 6.2 State reset and randomness

Every render allocates fresh layer surfaces. Every stroke starts with a defined empty brush state; state may evolve only within that stroke. Stateful brush behavior that crosses stroke boundaries is deferred until the state-transfer rule is represented in the program.

All stochastic brush operations have an explicit integer seed. The normalizer never creates seeds during rendering. Seeds are chosen when the edit is normalized and stored in the program, or supplied by the model.

For the initial custom brush, define random values independently per operation: hash a fixed algorithm tag, a big-endian 32-bit seed, a big-endian 64-bit dab index, and a fixed channel tag with SHA-256; interpret the first four digest bytes as an unsigned big-endian integer and divide by 2^32. Restrict seeds to nonnegative signed-32-bit range for straightforward Gene transport. This is a simple deterministic specification, not a cryptographic requirement. A faster PRNG changes the algorithm/profile version unless it produces the same values.

Unrelated added operations do not consume randomness belonging to another stroke. Render filenames, revision timestamps, process IDs, wall time, model calls, and operating-system entropy never enter pixel computation.

### 6.3 Three separate identities

1. **Program digest:** SHA-256 over the canonical complete program, including semantic metadata; changing only a label can produce another program digest with identical pixels.
2. **Pixel digest:** SHA-256 over a version tag, width/height, output color-space tag, and row-major straight RGBA8 pixels with no row padding.
3. **PNG digest:** SHA-256 over the actual encoded artifact bytes.

Record all three plus the profile and referenced asset digests. Pixel equality and PNG-file equality are separate assertions. Exclude volatile PNG metadata such as timestamps; use fixed encoder options and stable chunk ordering.

## 7. Initial brush algorithm

Implement a small brush stamper before adopting a sophisticated engine. The proposed rules below are part of `round-dab/v1` and must be implemented identically in planning fixtures and production.

### 7.1 Path sampling

1. Require one or more point tuples. Pressure lies in `[0,1]`; times are nonnegative and nondecreasing.
2. Treat multi-point strokes as polylines with linearly interpolated pressure/time. Curved fills remain separate geometry. A future curved stroke kind must specify its flattening tolerance and algorithm.
3. Compute nominal spacing `s = max(1/1024, base_radius * brush.spacing)` in canvas units. Spacing uses base radius, not the varying pressure radius.
4. Place dabs at arc lengths `0, s, 2s, ...` up to the polyline's total length. Carry residual distance across segment boundaries. Do not force an additional last dab unless it falls at a sampled distance under the profile's rounding rule.
5. Remove zero-length interior segments deterministically. A single-point/all-zero-length stroke emits one dab using its first point's pressure. A conflicting pressure change at an identical position does not create time-based airbrush deposition in this profile.
6. Normalize generated positions/pressure according to the profile. Cap the generated dab count before allocating large buffers.

Round-brush radius at a sampled pressure `p` is:

```text
r = base_radius * (min_radius_ratio + (1 - min_radius_ratio) * p)
```

Pressure zero deposits no paint. Default `min_radius_ratio` is 0.25. The initial profile has no implicit pressure-to-color or tilt mapping.

### 7.2 Coverage, texture, and opacity

For each dab, evaluate its radial footprint at four fixed subpixel sample locations per affected pixel: `(1/4,1/4)`, `(3/4,1/4)`, `(1/4,3/4)`, `(3/4,3/4)`, relative to that pixel's top-left corner. Hard-round coverage is 1 inside the radius and 0 outside. For soft-round, coverage is 1 up to `hardness * r`, then falls linearly to zero at `r`; hardness 1 uses the hard-round rule. Average the four sample coverages. This is the custom brush's antialiasing contract; geometry fills use the pinned Skia coverage implementation.

Multiply coverage by the defined texture sample, operation mask value, brush flow, stroke opacity, color alpha, and pressure. Clamp the result to `[0,1]`. All modulation inputs are explicitly defined, including texture origin, nearest/bilinear filtering, and transparent/clamped/repeated boundaries.

v1 uses **build-up opacity**: each dab deposits paint, and overlaps accumulate. A separate whole-stroke opacity mode would first paint to an isolated stroke surface and apply opacity once; it is a different future operation kind. Do not treat these behaviors as interchangeable settings.

The first profile disables random displacement/rotation. Add texture and jitter in a later profile only after their sampling rules and seeds pass repeatability fixtures.

### 7.3 Painting and erasing

Use linear-sRGB premultiplied RGBA float32 surfaces in project-owned compositing code. Source-over is:

```text
C_out = C_src + (1 - a_src) * C_dst
a_out = a_src + (1 - a_src) * a_dst
```

`C_src` and `C_dst` are premultiplied linear RGB vectors. For eraser coverage `e`, multiply destination color and alpha by `1-e`. RGB at alpha zero is zero. Group/layer opacity scales both premultiplied color and alpha exactly once before layer compositing.

Skia geometry/gradient output must be configured or converted into this same representation before project-owned compositing. Specify surface color type, channel order, row stride, and alpha representation explicitly at the bridge boundary. Do not assume raw Skia or libmypaint buffers share a format.

## 8. Gradients, masks, filters, and richer brushes

### 8.1 Gradients and masks

Gradient stop offsets are ordered in `[0,1]`, with explicit endpoints at 0 and 1; v1 rejects duplicate offsets. Colors are supplied as straight encoded sRGB RGBA, converted to linear premultiplied RGBA, then interpolated. Linear gradients project onto the defined axis; radial gradients use distance from the defined center divided by positive radius. Clamp the parameter outside the gradient extent. The implementation must verify that configured Skia behavior matches this policy, or evaluate the gradient in project-owned code.

Path masks rasterize at canvas resolution with the pinned coverage policy. Mask values represent scalar coverage, not sRGB color. A bitmap mask's placement, decode rules, and filtering are part of its resource definition. Rendering a mask is pure and may be reused within a single render; previous revision surfaces are not reused.

Blur is deferred. When introduced, specify kernel type, sigma, truncation, rounding, edge behavior, and the point in the operation sequence where it samples its input. Its read footprint can extend beyond its write region.

### 8.2 Smudging and libmypaint

Smudging remains compatible with full repaint: it reads colors produced by earlier operations in the same render. It must declare whether it samples only its own layer or the visible lower-layer composite. Start with own-layer sampling; merged-layer sampling creates additional dependencies.

An optional libmypaint profile supplies position, pressure, tilt if supported, and explicit relative time. Reset its brush state at every stroke. Freeze preset bytes and seed/state initialization, and provide its required dab/color-sampling surface callbacks. Use its documented native surface implementation or a verified adapter; approximate callbacks cannot be advertised as identical to MyPaint's output. Supported settings, pixel format conversion, and clipping need integration fixtures.

Do not silently replace the initial stamper with libmypaint when opening an old program. A program/profile migration is an explicit new revision. A preset or brush engine change can alter every dependent stroke and requires a full repaint and visual review.

### 8.3 Automatic stroke placement

The model chooses painting instructions in the core application. A deterministic procedural helper may later generate hatching or contour-following strokes from explicit input parameters. Store its algorithm version and all inputs, or expand it to explicit stable-ID strokes when the edit is accepted.

Hertzmann's coarse-to-fine painterly method is an optional reference-image planner: use broad strokes first, then refine regions that differ from a blurred reference. The author's implementation is available. This is a reference-image capability; it does not itself turn a text prompt into a realistic scene. Neither learned planners nor model calls execute during repaint.

## 9. Program editing and atomic application

Supported patch operations are `insert_layer`, `remove_layer`, `set_layer`, `insert_operation`, `remove_operation`, `replace_operation`, `set_operation`, `set_points`, `move_operation`, `move_layer`, `add_resource`, `replace_resource`, and `remove_resource`. Each has a registered field schema and preconditions. Geometry may be edited through `set_points` or complete operation replacement; shorthand transformations expand to these explicit changes before publication.

```gene
(patch
  ^base "revision-07"
  ^media "raster-painting/v1"
  (intent "Move the highlight upward and make it narrower.")
  (set_operation ^target "apple-highlight" ^radius 22 ^opacity 0.18)
  (set_points ^target "apple-highlight"
    [390 400 0.3 0] [375 440 0.8 40] [380 480 0.2 80]))
```

An edit is one complete validated patch transaction, potentially containing many operations. Validate the whole candidate and enforce locks before rendering. Intermediate operations inside that patch do not trigger separate full repaints or revisions.

Insertion/move specifies a destination list and one stable anchor: `before`, `after`, or an explicit start/end position. Missing/stale anchors are errors. Changing resources triggers a dependency-aware check against all consumers, including locked ones. IDs are unique within a history and allocated independently across forks; restore preserves an existing identity only when it denotes the same authored entity.

Apply the patch to an isolated draft, normalize to a complete program, and repaint it from scratch. An invalid patch leaves the original program and line head unchanged. Editing the first stroke reruns every later operation; changed downstream smudging is expected behavior, not nondeterminism.

## 10. Render worker and PNG artifact contract

### 10.1 Request/result boundary

```text
RenderRequest:
  request_id, canonical_program_ref, program_digest,
  profile_digest, immutable_asset_refs, staging_handle, limits

RenderResult:
  status, program_digest, profile_digest, asset_digests,
  pixel_digest, png_digest, width, height, artifact_refs,
  diagnostics, render_statistics
```

The application resolves asset refs and controls staging handles. The worker rechecks schema limits and verifies program/asset digests. Requests cannot introduce network loads, arbitrary executable flags, callbacks, or model-generated shader code. Error results are bounded typed data.

### 10.2 Full render procedure

1. Verify profile, canonical program, assets, dimensions, and resource estimates.
2. Allocate a fresh output surface and initialize the declared background.
3. Rasterize static resource masks as needed for this render.
4. For each visible layer in order, allocate a fresh transparent layer surface.
5. Execute its complete operation list, resetting brush state at each stroke.
6. Apply its layer mask/opacity, composite it onto the output, and release temporary layer storage when no longer needed.
7. Convert the completed output to canonical straight RGBA8 encoded sRGB, with explicit zero-alpha handling and rounding.
8. Compute the pixel digest, encode PNG with fixed settings, and compute the artifact digest.
9. Write the manifest and return a successful result only when every artifact is complete.

No rendered pixels from earlier edits are input to this procedure. Each completed edit performs this full process, even if its only change is metadata. Deduplication may reuse identical stored bytes after verification; render-skipping and cross-revision prefix caches are outside this design.

### 10.3 Observation and export

The canonical observation PNG is RGBA8, sRGB, and the program's exact width/height. Its color profile/chunk policy is pinned. Quantization uses round-to-nearest with the profile's tie rule; unpremultiply only for nonzero alpha. The manifest includes the background and profile identity.

The initial encoder profile uses compression level 6 and the Sub row filter only. Pin libpng/zlib or the actual equivalent encoder implementation. Emit a fixed color-space declaration and no timestamps, arbitrary comments, or user-dependent metadata. Record any deterministic ancillary chunks and their order in the profile; encoder defaults must not decide the contract implicitly.

The model and frontend receive the same observation PNG. A viewer checkerboard, selection outline, label, or cursor is UI decoration and never enters model input. For transparent exports, use a separately declared opaque observation variant if required; its background and digest must be recorded rather than added invisibly.

Thumbnails, comparison images, and inspection crops derive from that completed observation. A crop records source digest, pixel rectangle, and any resize algorithm. Larger output dimensions constitute an explicit program/profile change; an upscaled PNG is not a higher-detail repaint. Preserve original revision evidence when creating alternative exports.

## 11. Integration with the multimodal loop

Reuse the framework's response union: propose an edit, request inspection, declare completion with evidence, or report blocked work. The model receives the user goal, chosen revision, rendered PNG, bounded painting structure, allowed operations, locks, and remaining budget. Supply selected stroke geometry/resource details on request instead of filling context with every point.

```text
current = accepted_revision
while budget remains and job is active:
    decision = model.observe_and_propose(current.program_summary, current.PNG, goal)
    if inspect/done/blocked: use the existing framework handler
    candidate_program = validate_and_apply(current.program, decision.patch)
    candidate_render = repaint_from_blank(candidate_program, pinned_profile)
    review = model.evaluate(actual_candidate_PNG, goal)
    save candidate program, patch, render, and artifact-bound review
    if accepted and expected head matches: advance the working line
    otherwise: retain candidate as a trial and continue from the accepted revision
```

The renderer is deterministic; the next model proposal need not be. Repainting a revision never calls the model. Repeating a creative run may produce different programs, all of which must render deterministically.

Teach the agent to establish composition and silhouettes, lay down broad values/colors, add lighting/material cues, then refine edges and details. Use stroke batches and gradient fills for broad regions. Detail crops retain their canvas coordinates so proposed edits refer to the correct region.

Keep the framework's actual completion statuses, no-progress detection, saved rejected candidates, and hard-requirement checks. Recognizable photorealistic results are an experimental quality target, not a renderer guarantee.

## 12. History, comparison, and restoration

Each revision stores the complete canonical painting program, its patch relative to its first parent, actual structural diff, asset closure, pinned render profile, clean PNG, manifest, goal/intent, and evaluation. Branching snapshots share immutable resource bytes through content addressing. Pixel tiles are not authoritative history values.

`Evolution` ancestry, expected-head publication, trials, transactions, and crash recovery remain unchanged. PNGs allow immediate historical viewing; explicitly repainting an old revision executes its complete saved program with its original profile. Every new edited candidate is repainted before publication.

Structural diff groups changes by stable ID, fields, points, resource references, and list order. A pixel difference image supplements this diff but cannot infer object ownership or prove artistic meaning.

Restoring a layer or stroke copies its selected source fields and required resource closure into a new program. If a resource ID already exists with different bytes, return a conflict or explicitly remap the restored resource to a new ID and update its selected consumers. Restoring a stroke restores its seed and placement; its effect can differ against changed earlier paint. Restore plans show relevant dependencies and always receive a full repaint preview.

## 13. Three-way merge and order dependencies

Merge complete program snapshots from left, right, and the framework-selected common base. Use the same ambiguous-base handling and explicit merge plans as the existing framework.

| Situation | Structural behavior |
| --- | --- |
| One side changes an operation field | Take that change if dependencies/locks permit |
| Both make the identical normalized change | Take it once |
| Both change the same field differently | Conflict requiring explicit choice/synthesis |
| One deletes an operation the other changes | Conflict |
| Independent new operations | Preserve unique IDs; resolve shared insertion/order constraints |
| Resource changed on one side, consumer changed on the other | Flag an interaction for review |
| Incompatible layer/operation order changes | Order conflict |
| Changes to isolated separate layers | Usually structurally compatible, still review composition |

List order is painting behavior. Retain compatible order constraints from both branches and detect cycles. Two insertions at the same anchor are an explicit order ambiguity in the first implementation; do not choose a lexical ID order that changes compositing invisibly.

The media adapter computes conservative read/write dependencies:

- Dry paint/erase reads the destination pixels it composites against.
- Smudge reads its pickup region, potentially beyond its paint footprint.
- Blur reads its neighborhood.
- Gradient/mask/preset changes affect every referencing operation.
- Lower-layer changes affect the final composite, and future merged-layer sampling would read them directly.

Use conservative region bounds for interaction detection; uncertain bounds expand to the full relevant layer. Disjoint write bounds alone do not establish independence. Interaction warnings can require visual review without being structurally unmergeable.

AI resolution edits the merged program under explicit user intent, then full repaint and evaluation decide whether the combination is acceptable. Both source parents remain preserved. A merge stores its executable patch relative to the first parent and the complete merged snapshot. It never substitutes pixel averaging for an instruction-level resolution.

## 14. Exact replay and adaptive replay

Separate two operations:

1. **Repaint a revision:** run its complete program from blank with its saved profile. This is deterministic rendering.
2. **Replay edits onto another revision:** apply saved normalized program patches to a different base. Preconditions, IDs, order anchors, and resource changes can conflict.

Exact edit replay requires compatible structural preconditions. Adaptive replay asks the model to translate a saved intent into a new patch; its new output program receives new provenance and a full deterministic repaint. Moving an apple early in history does not automatically move later absolute-coordinate highlights. The adaptive planner must adjust selected later geometry/resources or report the limitation.

Do not merge these meanings under a single UI promise of deterministic replay. Rendering determinism guarantees evaluation of a given program, not equivalence of artistic results after rebasing its edits.

## 15. Web frontend and API specialization

Reuse the existing local-first workbench, API/job contracts, idempotency keys, expected heads, SSE reconnect, and distinction between viewing a revision and continuing from it.

Add:

| UI area | Raster behavior |
| --- | --- |
| Canvas | Saved observation PNG, fit/zoom, optional detail crop |
| Inspector | Layers, operation order, brush settings, masks/resources, selected stroke points |
| History graph | Program revision thumbnails and accepted/trial status |
| Compare | Side-by-side PNGs plus instruction/resource/order diff |
| Edit preview | Full repaint candidate and changed-program summary |
| Merge/restore | Dependency-aware selection, conflict choices, reviewed repaint |
| Model view | Exact input image/crops with source digest and dimensions |
| Diagnostics | Renderer profile, deterministic verification status, render time/dab count |

Natural-language edits remain the initial authoring interface. Direct point editing/freehand input can later generate the same validated domain patches. Backend credentials stay on the backend. Keep operation names and numerical details in optional inspectors, not in the ordinary user prompt flow.

Add `GET .../revisions/{r}/program` as the raster projection of the framework's scene-inspection endpoint, retaining version tokens and bounded selections. Exports support PNG and a self-contained program/history bundle. A separate PDF export is optional and has no role in canonical observation rendering.

## 16. Storage and module responsibilities

Reuse `project.gene`, `index.sqlite`, immutable `objects/`, `renders/`, and application-owned `staging/`. A raster render bundle contains `observation.png`, `thumbnail.png`, and `manifest.gene`; the canonical program is an immutable object referenced by the revision. Assets live in the existing immutable blob store.

Publication order remains: validate/apply, full repaint, evaluate, write and flush immutable artifacts, then commit revision/trial/head/job events in the index transaction. Failure or cancellation cannot publish a partial PNG as a successful revision. An evaluation timeout may leave a valid unreviewed trial according to the existing framework.

| Module | Responsibility |
| --- | --- |
| `raster/types.gene` | Painting, resource, operation, profile, and artifact schemas |
| `raster/schema.gene` | Registered fields, limits, normalization, model documentation |
| `raster/program.gene` | Immutable program traversal, identity, resource closure |
| `raster/patch.gene` | Atomic editing, preconditions, locks, order anchors |
| `raster/media.gene` | Implementation of the existing `Media` descriptor/interface |
| `raster/dependencies.gene` | Conservative regions, consumers, reads and order interactions |
| `raster/render.gene` | Worker orchestration, full repaint, profiles, manifests and PNG handoff |
| `native/raster/` | Skia wrapper, custom dab engine, asset decode and fixed encoder settings |
| Existing evolution/store/jobs/server modules | Shared framework responsibilities |
| `prompts/raster/` | Schema-derived drawing, evaluation and merge templates |
| Existing `web/` | Raster inspectors and workbench specialization |

The proposed media methods are `validate`, `canonicalize`, `apply_patch`, `compare`, `merge_structure`, `dependencies`, `render`, `summarize`, and `evaluation_inputs`, matching the framework boundary. Keep raster brush and compositing rules out of `Evolution` itself.

## 17. Resource limits and performance

Full repaint is a deliberate requirement. Optimize native loops, in-render resource reuse, allocations, and encoding without reusing prior-revision pixel surfaces. Do not silently introduce incremental repaint, cached stroke prefixes, or preview-only partial updates as the canonical execution path.

Starting limits are configurable implementation defaults, not performance promises:

| Resource | Initial limit |
| --- | --- |
| Canvas | Default 1024 × 1024; maximum 2048 × 2048 |
| Layers | 16, with allocation estimates checked before execution |
| Operations | 5,000 per program; 50 changes per model patch |
| Stroke points | 100,000 total; separate per-stroke cap |
| Generated dabs | 250,000 total per repaint |
| Canonical program | 8 MiB |
| Model proposal | 256 KiB |
| Decoded assets | 128 MiB total, plus bounded image dimensions |
| Renderer process | 512 MiB memory budget; 30-second starting timeout |
| Agent run | 12 edits, 3 consecutive no-progress candidates, existing repair budgets |

Enforce estimated peak memory rather than assuming each independent cap fits simultaneously. A 4096 × 4096 RGBA8 surface is 64 MiB; an RGBA float32 surface is 256 MiB. Float32 working layers, masks, filter buffers, and decoded assets need separate accounting. Process layers sequentially when dependencies permit; cross-layer live sampling is deferred in part to avoid retaining every layer surface.

Record repaint time, operation count, generated dabs, peak allocation estimate, and PNG size. Benchmark increasing stroke counts and soft-brush radii before selecting final limits. Model/API latency may dominate small paintings; long brush programs can make repainting dominate later.

Cancellation is checked at safe operation boundaries. A cancelled repaint discards unpublished artifacts and preserves all published history. Jobs that exceed resource limits report typed errors and leave the accepted head unchanged.

## 18. Implementation milestones and acceptance evidence

### Milestone 1: deterministic manual painting and PNG

Implement schema/normalization, static masks, fills/gradients, round brushes, erasing, CPU bridge, full repaint, canonical pixels, pinned PNG encoding, and render manifests. Build handwritten sphere/apple programs. No model is needed for this milestone.

**Acceptance:** render each fixture repeatedly in the same and fresh worker processes; pixel and PNG digests match. Change an early stroke, repaint, and compare against an independent fresh execution of the complete changed program. A fixture deliberately contaminates prior worker state; the next render must remain unchanged.

### Milestone 2: framework integration and web history

Implement the raster `Media` adapter, program patches, transactional revisions, branches, restoration, program inspector, PNG viewer, and structural comparison.

**Acceptance:** branch from an early painting, develop two versions, reopen/restart the app, inspect all saved PNGs, and explicitly repaint each selected program with matching digests. Invalid/stale patches and render failures leave the accepted line unchanged.

### Milestone 3: multimodal creation loop

Reuse model transport/evaluation/jobs and add schema-derived painting prompts, bounded summaries, detail crops, live progress, cancellation, and truthful completion.

**Acceptance:** prompt-only shaded sphere and apple/still-life tasks progress through multiple edited programs. Actual PNG inputs are recorded. Compare fixed task outcomes for recognizable form, light direction, artifacts, iteration/cost, and unresolved requirements. Repeat-render each saved program independently; repeated model runs are not expected to yield the same program.

### Milestone 4: semantic merging and richer brushes

Implement resource/order interaction detection, reviewed three-way merge, dependency-aware partial restore, then optional textures/smudge/libmypaint under new profiles.

**Acceptance:** combine separate subject/background improvements, surface conflicting stroke/order/resource changes, resolve a smudge interaction, preserve both parents, and reproduce the merged program/PNG under its profile.

### Milestone 5: adaptive replay and realism experiments

Adapt later stroke intentions after an early geometry correction; add reference-guided procedural planning if useful. Evaluate more difficult scenes with explicit reference/prompt-only modes.

**Acceptance:** corrected geometry stays corrected, later highlights are adapted deliberately, each derived program has truthful provenance, and unsupported realistic tasks end as partial results rather than claimed success.

## 19. Meaningful verification fixtures

Test the contracts, especially where mistakes are easy:

- Pressure ramps, zero-length strokes, segment splitting, endpoint spacing, and seed isolation.
- Soft-brush overlap distinguishing dab build-up from layer opacity.
- Transparent color conversion, premultiplied alpha, erasing, and compositing against a known background.
- Gradient endpoints/interpolation and mask multiplication, including intentional operation-plus-layer masking.
- Identical assets/presets by digest; missing/changed assets rejected before rendering.
- Repeatability across process restart, prior render contamination, and different concurrency schedules at the application level.
- Earlier-operation changes followed by deterministic downstream sampling once smudge exists.
- Invalid batches, indirect lock violations through resources, stale order anchors, and publication races.
- Merge insert-order ambiguity, delete/modify conflict, shared-resource interaction, and read-footprint interaction.
- Crash between immutable artifact write and index commit; no partial revision becomes visible.
- Canvas/model image identity, crop coordinates, cancellation, idempotent jobs, and SSE recovery.

Expected primitive pixels must come from independently specified small fixtures, not merely snapshots generated by the same implementation. Record and review golden images for complete painting examples. Passing deterministic tests establishes reproducibility; it does not establish artistic quality.

## 20. Critical risks and implementation decisions

| Risk | Decision |
| --- | --- |
| Renderer repeatability | Certify a pinned CPU profile; record pixels and PNG identities separately |
| Brush-engine integration | Start with a specified stamper; integrate libmypaint through verified callbacks later |
| Numerical/color discrepancies | Explicit working/output formats, conversion rules, and bridge tests |
| Long-program repaint cost | Native bulk execution, bounded dabs, profiling; retain full repaint semantics |
| Program-order/resource merge effects | Conservative dependency analysis plus full visual review |
| Model's realistic painting ability | Run simple visual tasks early and measure progress before adding advanced features |
| Runtime/package portability | Pin Gene and renderer builds; ship supported worker binaries/frontend assets |

Before coding, confirm the target Gene checkout's parser, numeric representation, errors/async support, file access, native/subprocess boundary, and applicable repository instructions. No VM-level history type or new language feature is required to demonstrate the design. Exact ABI names and build commands must be chosen against that checkout; the domain contract above is independent of them.

## 21. Sources and relationship to existing work

The rendering rules, schemas, limits, and milestone choices here are proposed application contracts. They must be implemented and verified; existing dependencies do not automatically guarantee them.

- `imagination.md`: existing Gene `Evolution`/`Media` design, publication, model loop, web frontend, merge, storage and job contracts. This companion defines the deterministic raster specialization; its full-program repaint rule overrides that document's optional materialized-tile raster proposal for this application.
- [Skia SkPaint overview](https://skia.org/docs/user/api/skpaint_overview/): primary documentation for gradient/shader and blending capabilities.
- [Skia color management](https://skia.org/docs/user/color/): primary documentation for color-space conversion and alpha handling. The project's linear working/compositing policy still needs explicit configuration.
- [Skia PNG encoder interface](https://skia.googlesource.com/skia/+/refs/heads/main/include/encode/SkPngEncoder.h): direct pixel/image encoding and encoder options.
- [libmypaint](https://github.com/mypaint/libmypaint) and [surface interface](https://github.com/mypaint/libmypaint/blob/master/mypaint-surface.h): reusable brush engine and required drawing/color-sampling callbacks. Choose a specific release/build during implementation; master URLs are discovery references.
- [CanvasKit documentation](https://skia.org/docs/user/modules/canvaskit/): optional browser rendering route, not required for the initial PNG workbench.
- [Hertzmann's painterly rendering project](https://mrl.cs.nyu.edu/publications/painterly98/) and [author's implementation](https://github.com/hertzmann/painterJava): reference-guided coarse-to-fine stroke placement.

The central invariant is executable and reviewable: **a revision identifies a complete painting program and its immutable inputs; every edited candidate is painted from the beginning, and its actual PNG becomes the evidence for the next decision.**
