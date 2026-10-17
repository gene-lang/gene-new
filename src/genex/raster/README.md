# genex/raster

Deterministic CPU painting worker with Gene build/transport APIs. Cairo supplies scalar path coverage; project-owned C++ code supplies pressure-sensitive round dabs, gradients, premultiplied linear-sRGB compositing and erasing. libpng encodes fixed RGBA8 PNGs.

Build from the repository root with `gene run src/genex/raster/tools/build.gene`. Dependencies: C++17, pkg-config, Cairo, libpng and zlib. Set CXX/PKG_CONFIG/SDKROOT when selecting a toolchain. Outputs are `build/raster-worker` (frozen v1) and `build/raster-worker-v2` (textured painting). Existing v1 binaries are preserved. Set GENE_RASTER_WORKER and GENE_RASTER_WORKER_V2 to their absolute paths when using materialized packages.

`worker_profile` captures executable/runtime dependency identity. `worker_render` accepts a numeric request and a caller-owned staging directory, verifies the executable and runs one fresh process with bounded output/time. Imagination supplies the higher-level painting schema, validation, immutable assets and artifact manifests; see its [implementation notes](https://github.com/gene-lang/imagination/blob/main/docs/raster-implementation.md) in the standalone Imagination repository.

The numeric protocol is internal and versioned: protocol 1; canvas dimensions and background RGBA bytes; indexed path/bitmap masks; layers and ordered fill/stroke/erase operations. Counts precede arrays, enum tags select fixed algorithms, absent masks use -1. Files have fixed names (`request.txt`, `asset-N.raw`, `observation.png`, `thumbnail.png`, `pixels.rgba`). Requests contain no paths, code, callbacks or network references. The native worker revalidates numeric bounds, normalized grids, reference indexes and work/memory limits. `--profile` prints build/algorithm information; `--crop` decodes a bounded source PNG and enlarges a bounded pixel rectangle by nearest-center sampling.

No cross-platform byte-equivalence guarantee is made. A native/library/OS change requires a different certified render profile.

Protocol 2 adds `bristle/v1` stroke tips (aspect, tangent-relative angle,
seeded band texture and band count), plus bounded `--decode` PNG decoding
for reference planning. `decode_png` returns canonical PNG and RGBA pixels
from a private staging directory. No reference-image sampling takes place
during repaint; callers save the planned strokes first. Protocol 1 remains
in `native/worker_v1.cpp` and its separate executable.

`decode_png profile bytes directory ^timeout_ms 30000` accepts an optional
positive timeout in milliseconds (default 30 seconds). Callers with an enclosing
deadline should pass its remaining time. A worker timeout raises `RasterError`
with `timed_out = true`; cancellation of the surrounding task still terminates
the worker. The caller owns cleanup of the staging directory and outputs.
