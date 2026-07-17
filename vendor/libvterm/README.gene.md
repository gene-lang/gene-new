# Vendored libvterm

This directory contains the source files needed to statically build
libvterm 0.3.3 into Gene's interactive terminal worker.

- Upstream: <https://www.leonerd.org.uk/code/libvterm/>
- Release: `libvterm-0.3.3.tar.gz`
- SHA-256: `09156f43dd2128bd347cbeebe50d9a571d32c64e0cf18d211197946aff7226e0`
- License: MIT; see `LICENSE`

Gene carries one narrow source patch: SGR 2/22 faint (`VTERM_ATTR_DIM`) is
retained in screen cells because the 0.3.3 release otherwise discards it.
All Gene-specific process, scrollback, OSC 7, and rendering adaptation remains
in `src/gene/vterm_bridge.c` and `src/gene/vterm.nim`.
