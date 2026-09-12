# WebSocket client for Gene

This library combines Gene's existing compiled FFI adapters with libcurl's
WebSocket client. It supports `ws://` and `wss://`, keeps TLS verification
enabled, reassembles fragmented messages, and queues outbound binary messages.
It does not run Gene callbacks from native threads.

Requires a C compiler, Nim, pkg-config and libcurl >= 8.11 with WebSocket
support enabled. The build driver supports macOS and Linux.

```sh
python3 src/genex/websocket/tools/build.py
node src/genex/websocket/tests/echo.mjs
```

On macOS, Apple's curl lacks WebSocket support. With Homebrew curl installed:

```sh
python3 src/genex/websocket/tools/build.py --pkg-config-path "$(brew --prefix curl)/lib/pkgconfig"
```

`nimble genex` builds all genex libraries and locates Homebrew curl automatically.

`src/websocket.gene` exposes `load`, `connect`, `send`, and `receive`.
`receive` returns nil when no complete message is ready; an empty U8 buffer
represents an actual empty message. The native binding's `kind` reports text
(1) or binary (2). `send` queues bytes; polling `receive` also advances writes.
Errors raise `WebSocketError`. Close the owned socket with `$C/close` in an
`ensure` block. Close is best-effort and may discard unsent queued messages.

Messages are bounded to 16 MiB. Output is bounded to 8 MiB and 256 queued
messages. Each socket belongs to its creating thread. Native libraries are
trusted after admission through `aot/load`; this is not a native-code sandbox.

The independent test peer checks binary/NUL preservation, client masking,
partial frames, fragmentation around a PING, automatic PONG, empty messages and
the queued send round trip. The adapter follows libcurl's
[receive](https://curl.se/libcurl/c/curl_ws_recv.html) and
[send](https://curl.se/libcurl/c/curl_ws_send.html) contracts.
