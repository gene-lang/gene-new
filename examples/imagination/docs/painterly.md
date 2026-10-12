# Textured, reference-guided painting

The `painterly` medium adds `raster-painting/v2` and the separate `raster-cairo-linear/v2` worker profile. It keeps Gene's language syntax unchanged. These are domain-data additions to Imagination, implemented with Gene planning/editing and native pixel work.

## Build and start

From the repository root:

```sh
gene run src/genex/raster/tools/build.gene
# The build prints both worker paths. If using materialized packages:
export GENE_RASTER_WORKER="$PWD/src/genex/raster/build/raster-worker"
export GENE_RASTER_WORKER_V2="$PWD/src/genex/raster/build/raster-worker-v2"
cd examples/imagination
bin/imagination create landscape --media painterly --width 256 --height 256 \
  --prompt "A swirling blue sky, luminous yellow sun, golden fields and a dark cypress, with visible directional brushwork."
bin/imagination run landscape --max-iterations 4
bin/imagination serve --media painterly
```

On the SDK/linker combination described in [raster-implementation.md](raster-implementation.md), set SDKROOT to a compatible installed SDK when invoking the C++ build. The separate `nimble genex` SDL/WebSocket driver selects its SDK automatically.

Existing `--media raster` projects retain their v1 schema and worker. The build retains an existing v1 executable and builds v2 separately; frozen `worker_v1.cpp` supplies clean installations. Old project profile fingerprints must still match their actual binaries/libraries. No old program is silently migrated, and no cross-platform pixel equivalence is claimed.

## Bristle brush

```gene
(brush ^id "brush" ^kind "bristle/v1"
  ^hardness 0.8 ^spacing 0.25 ^flow 1 ^min_radius_ratio 0.25
  ^aspect 0.35 ^angle 0 ^texture 0.7 ^bristles 24)
```

- `aspect` is the minor/major ellipse-radius ratio, 1/16–1.
- `angle` is a -360–360 degree offset from the stroke tangent. A single-point stroke has tangent zero; zero-length leading segments are skipped when finding its initial direction.
- `texture` mixes uniform coverage with bristle bands, 0–1. `bristles` is the number of bands across the minor axis, 1–64.
- The stroke's explicit `seed` independently determines band strengths using `hash32/v1`. No global random stream or wall clock is used. Zero texture removes seed influence.
- Coverage uses the existing four subpixel samples, pressure/radius mapping, linear-light compositing and per-dab opacity. Taper is expressed through pressure points, rather than an implicit endpoint effect.

The worker computes ellipse-local coordinates, radial coverage and sinusoidal band coverage. Band strength uses defined wrapping uint32 arithmetic: xor-shift16, multiply `0x7feb352d`, xor-shift15, multiply `0x846ca68b`, xor-shift16, with seed xor (band index × `0x9e3779b9`) as input. This is a procedural dry-brush texture, not a simulation of physical bristles, pigment or impasto.

## Regional stroke generation

A patch can contain:

```gene
(paint_region ^id "n1-sky" ^brush "brush"
  ^region [0 0 256 128] ^count 240 ^radius 7 ^length 24 ^seed 42
  ^color "#345fa0ff" ^pattern "swirl" ^angle 0 ^bend 0.2
  ^jitter 0.6 ^color_variation 0.08 ^opacity 0.85 ^underpaint true)
```

`parallel` follows the supplied angle. `swirl` follows tangents about the region center. `reference` follows the local reference luminance gradient's tangent, falling back to the supplied angle in flat areas. Color comes from exactly one literal `color` or attached `reference` ID.

Placement is a stratified grid with independently seeded jitter. `stroke-field/v1:seed:index:channel` is SHA-256 hashed; its first eight hex digits divided by 2^32 supply each random value. Length varies by 0.7–1.3 times the requested length; five explicit points describe a curved centerline with pressure `[.18, .75, 1, .75, .18]`. Shared RGB brightness variation operates in encoded sRGB and preserves alpha. Geometry and pressure are quantized before saving.

`underpaint true` adds an 8×8 grid of ordinary path fills sampled at cell centers before the strokes. This establishes a colored base and avoids unintended white gaps. It is especially useful for the first reference pass; later passes should usually omit it. It adds 64 identities to the requested stroke count.

The helper creates one named layer at the end of the program. Generated IDs are `<layer>-sN` and `<layer>-baseROW-COLUMN`. Centerlines are clamped to the requested region; brush footprints can extend beyond it. Use a normal layer mask for strict clipping. The usual move/set operations can reposition the layer or change its opacity/mask. A helper request is bounded to 1800 strokes, while the whole painting remains bounded to 2000 identities, 4 MiB, and the worker's existing cost limits. Multiple passes share those total limits.

The original patch records the helper request. Its **normalized patch contains the expanded insert_layer with explicit strokes/fills**. Exact replay never invokes the helper or decodes a reference. The renderer receives ordinary saved operations and fresh surfaces on every edit.

## Reference guidance

Attach a PNG through the workbench's **Reference PNG** control, or:

```sh
bin/imagination reference landscape reference.png
# Prints an ID such as n1-reference.
bin/imagination paint-reference landscape n1-reference --count 400 --radius 14 --length 35 --seed 42
bin/imagination paint-reference landscape n1-reference --count 800 --radius 5 --length 20 --seed 43
```

The first CLI pass adds underpainting when the canvas has no layers. The second adds finer strokes. `--line` selects a branch. These commands publish unreviewed visual work: structural checks pass, but visual checks remain unknown until a model reviews the actual result.

References are PNG only, at most 4 MiB and 2048 pixels per edge. Up to four can be attached. Native libpng decoding creates canonical RGBA8/sRGB pixels and a canonical PNG; the immutable store retains both original and canonical byte digests. A resource records ID, label, source/asset digests and dimensions. Missing or changed assets fail explicitly. Reference sampling maps the whole reference onto the canvas; differing aspect ratios therefore stretch it.

A model receives each attached reference PNG separately, labeled as guidance, followed by the actual working/candidate renders. Reference content is not completion evidence. It can request `paint_region ^reference "ID" ^pattern "reference"` to generate another pass. Existing strokes never change when reference metadata changes, and standalone repaint needs only the materialized program (plus bitmap masks if used). Publishing into a history verifies retention of attached assets.

The upload endpoint uses the existing same-origin/token protection and durable idempotency receipts; imports are refused while a run is active on the target line. The image endpoint serves only reference IDs attached to the requested revision. The workbench displays guidance beside the painting and offers PNG export.

## Scope and validation

This is a deterministic painterly construction system. The reference planner is a bounded color/edge heuristic, not neural stroke optimization. Van Gogh-inspired results depend on composition, palette and the model's stroke planning; this release does not promise faithful reproduction or photorealism. Reference fitting, natural-media mixing and high-resolution optimization can be developed separately.

Tests cover legacy profile separation, seeded repeatability, tip orientation, materialized helper replay, coarse underpainting, immutable reference decoding, model image handoff, import idempotency and revision-scoped serving. **151 tests pass**, including nine painterly/reference tests; all nine also pass with native ASAN/UBSAN. [Editable examples and acceptance results](../fixtures/painterly/README.md) include a two-pass reference apple and a prompt-only landscape made through four model edits. Both outputs were visually inspected; all four landscape revisions reproduce their saved program, pixel and PNG digests on exact replay.

Implementation observation: the pinned Gene binary did not resolve a path-valued parameter default (`limits/response_bytes`) in `read_domain`; the optional limit is resolved inside the function using the ordinary nil/default idiom. No language syntax or semantics were changed. Stored program files may use the existing 4 MiB program limit while model responses retain their 256 KiB limit.
