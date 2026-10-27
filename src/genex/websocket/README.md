# WebSocket client for Gene

This library combines Gene's existing compiled FFI adapters with libcurl's
WebSocket client. It supports `ws://` and `wss://`, keeps TLS verification
enabled, validates the upgrade response, reassembles fragmented messages, and
queues outbound text and binary messages.
It does not run Gene callbacks from native threads.

Requires a C compiler, Nim, pkg-config and libcurl >= 8.11 with WebSocket
support enabled. The build driver supports macOS and Linux.

```sh
bin/gene run src/genex/websocket/tools/build.gene
node src/genex/websocket/tests/echo.mjs
node src/genex/websocket/tests/qualification.mjs
```

On macOS, Apple's curl lacks WebSocket support. With Homebrew curl installed:

```sh
PKG_CONFIG_PATH=/opt/homebrew/opt/curl/lib/pkgconfig bin/gene run src/genex/websocket/tools/build.gene
```

`nimble genex` builds all genex libraries and locates Homebrew curl automatically.
The Gene build tool also locates Homebrew curl and probes installed macOS SDKs
when the default compiler SDK cannot link. `CC`, `SDKROOT`, `PKG_CONFIG` and
`PKG_CONFIG_PATH` remain explicit overrides. An optional output-directory argument
keeps native artifacts outside the package source when needed.

The PKG-2 package regression in `tests/test_genex_package.py` copies this
package into an isolated source tree, builds its existing generated FFI
adapter, and records a target-specific `native_binary` recipe with the exact
Gene runtime identity and libcurl system dependency. It then installs a Gene
consumer and exchanges a binary frame through the installed launcher with
the source tree, user artifact cache, and compiler unavailable. This local
fixture leaves the source package manifest inert; published variants still
need target/runtime-specific release records.

`src/websocket.gene` exposes `load`, `connect`, `connect_protocol`, `send`, and
`receive`. `connect_protocol` offers one subprotocol (`Sec-WebSocket-Protocol`)
and fails unless the server selects exactly that protocol; a name outside
letters, digits, `.`, `_` and `-` is refused before connecting.
`receive` returns nil when no complete message is ready; an empty U8 buffer
represents an actual empty message. The native binding's `kind` reports text
(1) or binary (2). `send` queues bytes; polling `receive` also advances writes.
Errors raise `WebSocketError`. Close the owned socket with `$C/close` in an
`ensure` block. Close is best-effort and may discard unsent queued messages.

`open native url` performs the handshake through cooperative polling. It accepts
named `timeout_ms` (default 5000), `protocol` (default none), `ca_file` (default
system trust), `max_message_bytes` (default 16 MiB) and `max_queued_bytes`
(default 8 MiB). Task cancellation while connecting releases the native socket.
`connect` and `connect_protocol` retain their older synchronous setup API.

`send_text native socket text` queues a UTF-8 text message. `receive_text` returns
nil while waiting, a string for a complete text message (including an empty
string), and refuses binary or invalid UTF-8 messages. `flush native socket`
advances pending writes and returns true when curl has consumed every queued
payload. This is not a remote application acknowledgment. Polling receive also
advances writes. TLS peer and hostname verification are always enabled; the
adapter does not inherit proxy settings or follow HTTP redirects.

The native binding also provides `ping socket` (1 sent, 0 would block, -1 error)
and `idle_ms socket`, elapsed monotonic time since the last received frame.
PING/PONG control frames count as activity without becoming application text.
TCP keepalive is enabled. The consuming protocol owns heartbeat intervals and
reconnection policy; the Harness Slack integration uses a 30-second PING interval and a 90-second receive
deadline. Rebuild the native adapter when upgrading to these bindings.

Messages are bounded to 16 MiB. Output is bounded to 8 MiB and 256 queued
messages. Each socket belongs to its creating thread. Native libraries are
trusted after admission through `aot/load`; this is not a native-code sandbox.

The independent test peer checks binary/NUL preservation, client masking,
partial frames, fragmentation around a PING, automatic PONG, empty messages and
the queued send round trip, plus subprotocol selection, a server that ignores
the offer, and an invalid protocol name. The adapter follows libcurl's
[receive](https://curl.se/libcurl/c/curl_ws_recv.html) and
[send](https://curl.se/libcurl/c/curl_ws_send.html) contracts.

`qualification.mjs` adds independent WS/TLS peers for cooperative connection,
fragmented UTF-8, empty text, a backpressured 2 MiB text round trip, input/output
limits, invalid handshakes, connection deadlines, peer closure, CA/hostname
verification and task cancellation during handshake and receive. It checks the
native socket count after each failure/cancellation. The upgrade validator also
checks the RFC 6455 accept hash: libcurl 8.19 leaves that validation to its user.
