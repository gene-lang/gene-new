# Overview

genex/sdl2 is an experimental binding to SDL2 and OpenGL built through Gene's compiled FFI and ahead-of-time loader. Its `ffi/fn` declarations compile into loadable adapters with SDL signatures, without extending the VM's dynamic FFI table. It requires a C compiler, Nim, pkg-config, SDL2 >= 2.0.18, and SDL2_ttf >= 2.0.18. The build driver supports macOS and Linux; OpenGL functions resolve through SDL at runtime and need OpenGL 3.3 core or newer.
