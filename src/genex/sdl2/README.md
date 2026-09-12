# SDL2 and OpenGL for Gene

Gene `ffi/fn` declarations compile into loadable adapters. This uses the
existing `gene compile --target c` / `aot/load` path, including full SDL
signatures, without extending the VM's dynamic FFI table.

Requires a C compiler, Nim, pkg-config, SDL2 >= 2.0.18 and SDL2_ttf >= 2.0.18.
The build driver supports macOS and Linux. OpenGL functions are resolved through
SDL at runtime; the renderer needs OpenGL 3.3 core or newer.

From the repository root:

```sh
python3 src/genex/sdl2/tools/build.py
bin/gene run src/genex/sdl2/tests/window.gene "$PWD/src/genex/sdl2/build/libgene_sdl2.dylib"
bin/gene run src/genex/sdl2/tests/triangle.gene "$PWD/src/genex/sdl2/build/libgene_sdl2.dylib"
```

`nimble genex` builds all genex libraries. Use `.so` on Linux.
`GENE_EXE`, `CC`, and repeated `--pkg-config-path` arguments
select the compiler and explicit SDK search paths. Dependencies are resolved
from `package.gene`; the build replaces its library atomically.

`src/sdl2.gene` loads the compiled bindings and supplies SDL constants.
`src/buffers.gene` packs portable F32/U32/U8 buffers into the C-byte buffers
accepted by the existing FFI. Numeric packing is explicitly little-endian.

The C adapters own GPU buffers, meshes, programs, textures, fonts and a bounded
text cache under a device. Mesh/font ids belong to that device. They provide
array uploads, input events, text/rectangles and queued tone/noise audio;
game rules and mesh generation remain in Gene.

Call from the application thread. Close the device before its SDL window, and
close windows before `quit`. Devices, windows and event storage are owned
pointers; use `$C/close` in `ensure` blocks. Integer operations return a negative
value on failure; `error` reports SDL's diagnostic. Closing a device releases its
GPU and font resources. Released mesh ids are rejected.

The window test verifies native context creation. The triangle test reads real
GPU pixels and checks mesh lifetime. Miclone's native smoke exercises the full
world, input, UI and networking integration.
