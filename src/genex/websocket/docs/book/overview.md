# Overview

genex/websocket is an experimental WebSocket client built from Gene's compiled FFI adapters and libcurl's WebSocket client. It supports `ws://` and `wss://`, keeps TLS verification enabled, validates the upgrade response, reassembles fragmented messages, and queues outbound text and binary messages. It does not run Gene callbacks from native threads. The package needs libcurl >= 8.11 with WebSocket support and a C compiler, Nim, and pkg-config. Its build driver supports macOS and Linux; on macOS, use a curl that includes WebSocket support.
