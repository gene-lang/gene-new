# Raster implementation

This document records the original v1 profile. [Textured painting v2](painterly.md)
adds directional bristles, stroke-field expansion and reference guidance in
a separate profile; v1 programs and binaries retain their original behavior.

The authoritative value is a normalized `(painting ^schema "raster-painting/v1" ...)` program. `src/media.gene` dispatches the small set of medium-specific operations; history, SQLite transactions, candidate reviews, budgets, steering and WebSockets retain their existing lifecycle. Historical `scene` field/column names store either medium without rewriting existing SVG projects.

## Build and use

Install a C++17 compiler, pkg-config, Cairo and libpng development files (`brew install cairo libpng pkg-config`, or Debian/Ubuntu `libcairo2-dev libpng-dev pkg-config`). From the repository root:

```sh
gene run src/genex/raster/tools/build.gene
export GENE_RASTER_WORKER="$PWD/src/genex/raster/build/raster-worker"
cd examples/imagination
bin/imagination create sphere --media raster --width 256 --height 256 \
  --prompt "Paint a red sphere with upper-left light and a soft cast shadow."
bin/imagination run sphere --max-iterations 6
bin/imagination serve --media raster
```

The build itself is Gene tooling, with CXX, PKG_CONFIG and SDKROOT operator overrides. This machine's Command Line Tools SDK 27 stubs are incompatible with its linker; using the installed SDK 26.5 via SDKROOT fixes the same bootstrap issue already handled by the repository's config.nims. This is a toolchain selection, not a change in Gene syntax or runtime.

SVG remains the default. A workbench can open both media and has a medium selector for new projects. `serve --media raster` starts without loading SVG conversion tools; it loads them only if opening an SVG project. Raster projects export PNG; vector preview, SVG and PDF exports are disabled for them. `render painting.gene out` detects the program root. `draw --media raster` and `spike --media raster` use the same renderer. `continue`, `apply`, `compare`, `replay` and `export --format png` use the saved project's medium automatically.

## Implemented contract

- Layers, paths (M/L/C/Q/Z, nonzero), solid and linear/radial gradient fills, path and immutable grayscale bitmap masks, hard/soft pressure brushes, per-layer erasing, opacity and visibility.
- Fixed canvas 1–2048 pixels per edge, 2000 identities, 20000 total path commands, 5000 points per stroke, 32 gradient stops, 128 layers/masks. The worker also caps mask storage at 32 million float samples, dab count at one million, sampled/composited work at 200 million units, input at 8 MiB and execution at 25 seconds. Limits fail the edit; they never silently simplify it.
- Geometry normalizes to 1/1024; unit factors to 1/65536, ties to even. Program canonicalization writes exact terminating decimals, preserving SVG's previous serializer/digests. Negative zero becomes zero.
- Cairo is used only for A8 path coverage (gray antialiasing, tolerance 0.1). Gradients and compositing use project-owned premultiplied float32 linear-sRGB. Gradients sample at pixel centers. Brush dabs use four quarter-pixel samples, pressure/radius mapping and build-up opacity. No jitter or brush textures in this profile.
- Bitmap masks are raw unsigned grayscale8, one byte per pixel, with integer canvas origin, nearest sampling and transparent outside. `asset <project> <grayscale.raw>` imports bytes and prints their full digest; `put_asset`/`get_asset` store and verify them. The mask resource supplies dimensions and digest. Brush texture modulation is a later profile.
- Each completed edit executes the whole program in a new worker process with fresh surfaces. No prior revision pixels or partial render cache are inputs. Hidden layers are validated and executed but not composited, so visibility never hides invalid or excessive work.
- Pixel identity hashes `raster-pixels/v1\nsrgb-rgba8\nW H\n` (decimal W/H) followed by straight RGBA8, no row padding. Output uses explicit sRGB conversion and half-up byte rounding; zero-alpha RGB is zero. PNG identity hashes the actual file separately.
- PNG encoding uses compression 6, Sub filter only, no interlace, sRGB relative-colorimetric declaration and no ambient metadata. Thumbnail/crop sampling is nearest at destination pixel centers. Crops record original PNG digest, source rectangle and resize method; zoom is explicitly pixel enlargement.
- Render profiles record executable bytes, native library versions and recursively resolved byte hashes, OS build/architecture, compiler, floating-point and algorithm settings. System dyld-cache libraries are pinned by OS build. Profile mismatch refuses repaint; no automatic migration or cross-platform equality claim.
- Patches share the existing schema/id/base/goal/intent envelope, optionally naming `^media`. Operations use explicit stable anchors. Whole-program normalization and dependency locks precede rendering. Exact replay reapplies saved edits and verifies program, pixel and PNG identities without model calls.
- Locks conservatively protect the selected object and its list position, ancestor compositing and referenced resources. Non-identity scopes currently protect the whole selected object; finer per-field independence is deferred. Bounds are conservative full-canvas bounds, not claims about visible object ownership.

## Deliberately deferred

Merge, selective restoration, adaptive replay, profile migration, wet paint, smudge, blur, affine object transforms and image-model generation are separate capabilities. Canvas size/background are selected at project creation; v1 patch operations edit resources, layers and operations. Historical viewing currently requires opening the project's pinned profile, as with the existing SVG implementation; an artifact-only mode for unavailable profiles remains future work.

The native boundary is a bounded numeric subprocess protocol rather than an FFI/native-package recipe. This supports the application's existing raw-file launcher, which does not select native build recipes. Native image work belongs in `genex/raster`; application schema, editing and orchestration remain Gene. No executable painting code, shell fragments or model-selected paths cross the worker boundary.

A language/tooling observation: `path` is intrinsic syntax at a call head. A local helper named `path` did not behave as an ordinary function on the pinned binary; the serializer now uses `emit_path`. No syntax/semantics changes were introduced.

## Validation

`gene test` from `examples/imagination`: **142 passed, zero failures/errors** (120 existing tests plus 22 raster/evidence tests). Raster tests include independently specified linear-light pixels, gradients, alpha, layer opacity, masks, erase, segment splitting, normalization, invalid data, asset verification, locks, history/branch/replay/export/crops and actual PNG delivery through a fixture VisionAgent. All 22 also pass with AddressSanitizer and UndefinedBehaviorSanitizer enabled on the native worker, including malformed wire requests and excessive dab-count rejection.

Two prompt-only model runs produced a shaded sphere (three edits/four decision calls) and an apple (four edits/five decision calls). [Programs, PNGs and assessment](../fixtures/raster/README.md) are saved as fixtures. The apple satisfied its hard requirements while leaving optional finish quality partial. Fresh-process CLI replay reproduced every saved apple program, pixel and PNG digest. A disposable Chrome tab verified the raster canvas, history, comparison, PNG-only export and medium selector.

Five local 256×256 samples per fixture measured full pipeline medians of **273 ms (sphere)** and **289 ms (apple)**, including validation, runtime dependency hashing, worker startup and artifact hashing. Native subprocess medians were **22 ms / 23 ms**, including PNG/thumbnail output. These are local smoke measurements, not cross-platform throughput guarantees. The model's decision calls took seconds and dominated these runs.

The live apple planner exposed a pre-existing correctness issue: arbitrary structural requirements received the generic medium-validation pass. New goals now reject unsupported structural checks; legacy unknown checks return `unknown` rather than falsely passing. Only the actual medium check and exact text checks have structural evaluators.
