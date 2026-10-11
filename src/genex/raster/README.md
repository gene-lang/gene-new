# genex/raster

Deterministic CPU painting worker with Gene build/transport APIs. Cairo supplies scalar path coverage; project-owned C++ code supplies pressure-sensitive round dabs, gradients, premultiplied linear-sRGB compositing and erasing. libpng encodes fixed RGBA8 PNGs.

Build from the repository root with `gene run src/genex/raster/tools/build.gene`. Dependencies: C++17, pkg-config, Cairo, libpng and zlib. Set CXX/PKG_CONFIG/SDKROOT when selecting a toolchain. The default output is `build/raster-worker`; set GENE_RASTER_WORKER to its absolute path when using a materialized package.

`worker_profile` captures executable/runtime dependency identity. `worker_render` accepts a numeric request and a caller-owned staging directory, verifies the executable and runs one fresh process with bounded output/time. Imagination supplies the higher-level painting schema, validation, immutable assets and artifact manifests; see its [implementation notes](../../../examples/imagination/docs/raster-implementation.md).

The numeric protocol is internal and versioned: protocol 1; canvas dimensions and background RGBA bytes; indexed path/bitmap masks; layers and ordered fill/stroke/erase operations. Counts precede arrays, enum tags select fixed algorithms, absent masks use -1. Files have fixed names (`request.txt`, `asset-N.raw`, `observation.png`, `thumbnail.png`, `pixels.rgba`). Requests contain no paths, code, callbacks or network references. The native worker revalidates numeric bounds, normalized grids, reference indexes and work/memory limits. `--profile` prints build/algorithm information; `--crop` decodes a bounded source PNG and enlarges a bounded pixel rectangle by nearest-center sampling.

No cross-platform byte-equivalence guarantee is made. A native/library/OS change requires a different certified render profile.
