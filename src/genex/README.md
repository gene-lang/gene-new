# Genex optional libraries

Pure Gene packages also live here. [tzdb](tzdb/README.md) carries pinned IANA
zone resources and uses the standard `gene/temporal` arithmetic and TZif
reader; it does not need the native-library build task below.

[archive](archive/README.md) is a separate experimental PKG-2 zlib codec
package with gzip I/O adapters and ZIP extraction.

[tls](tls/README.md) is an experimental PKG-2 OpenSSL adapter for direct
native-service TLS; its HTTP listener integration is pending.

Build the SDL2/OpenGL and WebSocket libraries from the repository root:

```sh
nimble genex
```

Requires `bin/gene` (build with `nimble speedy`), Python 3, a C compiler,
pkg-config, SDL2, SDL2_ttf, and libcurl with WebSocket support. On macOS:

```sh
brew install sdl2 sdl2_ttf curl pkg-config
```

The build locates Homebrew curl automatically. For other SDK locations, use
`python3 src/genex/tools/build.py --pkg-config-path PATH`; the option is repeatable.
`GENE_EXE` and `CC` override the Gene and C compilers.

Libraries are written to `src/genex/sdl2/build/` and
`src/genex/websocket/build/`. See [SDL2](sdl2/README.md) and
[WebSocket](websocket/README.md) for their APIs and tests.
