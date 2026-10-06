# Gene Network Services

**Status:** NET-1 has an experimental owned Client with an Application-scoped libcurl multi service, reusable buffered requests, header-first streamed responses with bounded AsyncReader bodies, bounded AsyncReader uploads with known-length EOF checks or chunked framing, controlled GET/HEAD redirects, ordered response header pairs, binary bodies, captured CA files, proxy policy, cancellation, per-Client/per-origin caps, queue deadlines, and I/O byte-budget accounting on macOS arm64. An AsyncReader upload holds an exclusive protocol read borrow for the request's whole life, so a caller's qualified read is refused as `IoBusy`, including Gene-defined readers, held/dynamic messages, pipelines, and inherited implementations. Native file/pipe/TCP/test readers and Client BodyReaders additionally enforce backend exclusion. Cancellation retains the borrow until the read Task cleanup and transport retirement settle; failed admission rolls it back. Custom convenience APIs and distinct backend aliases remain responsible for their backend policy. `http/serve` polls at 1 ms while native work is pending, so a handler or root-lane task awaiting a Client transfer no longer waits out the 50 ms idle select. Full platform/service qualification remains open. The IO-3 prerequisite has experimental raw TCP streams/listeners. NET-2 has experimental streamed request/response bodies, same-connection upload-to-response tests, a pinned Caddy HTTPS-to-loopback service fixture, and a tracked-cleanup shutdown report. The macOS 60-second service workload passes functionally, but one repeat exceeded its 250 ms host-loop heartbeat target (336 ms). After the idle-select fix, ten consecutive release-binary repeats passed with maximum heartbeat gaps of 53–73 ms and p95 of 9.5–16.8 ms; the fixture now records its slowest synchronous SQLite call (2–4 ms in the last six), so a recurrence can be attributed. The 336 ms outlier has not reproduced or been explained; performance stability, Linux runtime, and VM-3 qualification remain open. NET-3 now has an experimental PKG-2 OpenSSL adapter, direct `listen ^tls` transport, and Task-valued `Server.reload_tls`. The installed-package fixture passes HTTPS, plaintext and untrusted-server rejection, failed reload, and certificate rotation on macOS arm64; the C fixture covers required client authentication and old live sessions. Sustained service and Linux runtime qualification remain open. Design baseline `3b2bde9`.

**Stages:** NET-1 (owned HTTP Client), NET-2 (streamed service/proxy deployment), NET-3 (direct TLS).

**Depends on:** IO-1/2 contracts and cleanup. TCP/server body adapters coordinate with IO-3.

## Preserve existing entry points

The current HTTP client accepts text bodies and returns a Task for buffered calls; its stream function returns a task/channel record. It uses positive timeout/size limits, verifies TLS, disables proxies, returns redirects, and creates fresh HTTP/1.1 connections. Keep those signatures, option names, result shapes, and defaults. Reimplement behind shared internals only after compatibility tests pass.

The new reusable Client is a separate API. The server keeps buffered text requests by default; streaming is an explicit serve mode. The browser HTTP binding is a different adapter and is not silently changed by this native proposal.

## NET-1: Client API and policy

`($net/http_client/open ...)` returns a Task yielding an Application/root-lane-owned Client. Trust-file loading and transport setup happen within that Task. It implements IoResource from [async I/O](async-io.md); generic close/wait_closed use qualified messages.

| Call | Result |
| --- | --- |
| `(client .request ^url url ...)` | Task yielding response with status, ordered header pairs, effective_url, and body as Bytes. Text decoding is explicit. |
| `(client .stream ^url url ...)` | Task yielding the same metadata when final headers are available; body is an AsyncReader + IoResource. |
| `(client .IoResource:close)` | Abort outstanding requests and body readers, stop new admission, start transport retirement. |
| `(client .IoResource:wait_closed)` | Fresh Task reporting physical closure/retained error. |

Request options are method (default GET), url, headers (Map or ordered pair List), body (nil, Str encoded as UTF-8, Bytes, or AsyncReader), timeout_ms, max_bytes, and content_length when known. Client transport options are fixed at open. Existing wrapper header List-of-Str remains supported there; the new pair form preserves duplicate response headers without flattening them.

| Open option | Default and rule |
| --- | --- |
| max_connections / max_connections_per_origin | 16 total / 8 per origin, including idle sockets. |
| max_pending_requests | 64 waiting admissions, also subject to IO Application byte budget. |
| max_idle_ms | 30,000. |
| connect_timeout_ms / timeout_ms | 10,000 / 30,000. Positive monotonic durations; total starts at admission, including queue wait and body consumption. |
| max_buffered_body_bytes / max_stream_body_bytes | 8 MiB / 64 MiB. Request max_bytes can select a different finite bound within host configuration. |
| redirects | 0; positive value permits up to that many allowed hops. |
| proxy | nil, explicit URL, or "environment"; environment settings are captured at open. |
| ca_file | nil uses platform trust; explicit file replaces that trust source for this Client. |

Reject unknown/invalid options before network admission. Header blocks are capped at 256 KiB and 256 entries; no CR/LF injection. Queueing retains only bounded body/config snapshots. Client objects are non-Send and not serializable.

## Transport, redirects, and body ownership

Use one native libcurl multi transport service per Application, owning its easy/multi handles on one native thread. Bounded command/result queues connect it to the Gene root lane. Native callbacks copy bytes/status only; they never invoke Gene. This permits connection reuse and concurrent transfers without sharing one handle across threads; follow [libcurl's thread-safety contract](https://curl.se/libcurl/c/threadsafe.html). Reuse current curl loading/error adapters and preflight the required multi/wakeup functions.

An upload callback with no queued bytes pauses its transfer and requests a root-lane AsyncReader read; it cannot call that Gene reader from the transport thread. A full response queue pauses native receive until the root consumer frees capacity. Resume/cancel commands wake the multi loop; neither side busy-polls. All easy-handle use, including pause/unpause and cancellation cleanup, remains on the owning transport thread.

Pool identity includes origin, proxy, and trust/client-auth configuration. Start with HTTP/1.1. Do not add a cookie store, environment credential loading, automatic retries, or automatic content decompression in this release. Byte limits apply to delivered content-encoded bytes; explicit decoders impose their own expansion limits.

Follow 301/302/303/307/308 only for GET/HEAD with no upload body. Reject an HTTPS-to-HTTP downgrade. Resolve relative Location against the last URL, restrict schemes to HTTP(S), count every hop under one total deadline, and strip Authorization/Cookie on origin changes. Explicit proxy credentials remain proxy-only. Other methods/body-bearing requests return the redirect. Transport failure never implicitly repeats a potentially applied operation.

Uploads from AsyncReader borrow exclusive read use, leaving final close to the caller. Admission refuses a reader with a pending protocol read; protocol reads from the caller are refused until the transfer retires. This covers Gene-defined readers as well as native adapters. Cancellation requests cancellation of the pending read and retains the borrow through its Task cleanup and transport retirement. Failed admission rolls the borrow back. Native adapters also retain physical exclusion through worker retirement; custom convenience APIs and backend aliases enforce their own physical exclusion. Known content_length must match actual EOF; otherwise use supported HTTP/1.1 chunked framing. Bodies are not rewound or reread for redirect/auth retry.

The streamed-response Task succeeds on final headers, not on complete body receipt. Truncation, size limit, framing, TLS, and timeout failures after headers surface through the body reader; EOF means the HTTP body framing completed correctly. The total deadline remains active until EOF or body close. Closing early discards the connection unless it can be drained within a fixed small bound; no unbounded drain to preserve pooling. At complete EOF a healthy connection becomes reusable. Returned bodies keep their request alive independently of the consumed header Task, with bounded buffers and explicit cleanup leases.

## NET-2: server streaming and first HTTPS deployment

Add `serve ^body_mode "stream"` alongside existing buffered mode. Parse/validate headers and acquire request admission before accepting an unbounded body. Stream-mode requests expose a reader implementing AsyncReader/IoResource; buffered-mode request/body retains today's shape. `($net/http/stream reader)` or `($net/http/stream status reader ^content_length n ^max_bytes limit ^!own_reader)` selects a bounded AsyncReader response, using chunked framing when content length is unknown. Existing `bytes` and text response helpers retain their shapes.

Bound incomplete headers, body bytes, request queue, and socket writes. Enforce monotonic header/body-idle/total deadlines. A slow socket parks its task rather than holding the root loop. Unexpected EOF and oversized input fail the request; partial output cannot be replaced with a fictional complete error response. Early body close either bounded-drains or closes the connection. WebSocket upgrade retains its existing validated handshake and queue rules and is not a generic body reader.

First qualify HTTPS with a pinned local reverse-proxy fixture terminating TLS and forwarding to a loopback/Unix-socket Gene listener. Default ignores forwarded headers. A configured trusted-proxy list may authorize a documented single-hop forwarding scheme only when that peer overwrites incoming forwarding headers. The release fixture includes this proxy configuration and dependency; do not label the Gene listener itself TLS-capable.

Graceful server shutdown closes admission, gives active request tasks a default 5-second grace period, then requests cancellation/socket close and waits on cleanup leases. If native cleanup exceeds the host's shutdown deadline, return an incomplete-shutdown report. Existing server lifecycle functions remain adapters to this behavior.

## NET-3: direct TLS contract

Add listen's `^tls` map with cert_file, key_file, optional client_ca_file, and client_auth ("none" or "required"). Initial minimum TLS version is 1.2; negotiate 1.3 where supported. Use a maintained TLS transport adapter (OpenSSL) with declared build/runtime dependencies; do not implement TLS in Gene.

`(server .reload_tls config)` returns a Task. Read and validate complete material off the root loop, then atomically publish a new immutable context for future handshakes. Existing connections retain their context. Failed reload keeps the previous context and returns an error. A server opened without TLS cannot silently switch protocol on that port through reload. Trust/client-auth checks run during handshake before application data admission.

## Code map and gates

| Stage | Seams | Required tests |
| --- | --- | --- |
| NET-1 | stdlib HTTP client, new native transport module, IO bodies; test_http_client | Reuse counted by peer, queue deadline, per-origin/total caps, cross-origin redirect stripping, no body replay, invalid TLS, cancellation before/after headers, short upload/download. |
| NET-2 | ext/http_server.nim parser/serve loop, IO-3 socket readiness; test_http_server | Slow body next to fast requests, backpressure, early close, buffered API parity, proxy TLS fixture, shutdown with active streams. |
| NET-3 | TLS adapter/listener contexts and reload | Mismatched cert/key, untrusted client/server, context rotation with old live sessions, failed reload, retained contexts released on physical close. |

Measure full request latency, queue age, native/root queue bytes, and host-loop stalls with the recorded workload profile. NET-1/2 deliver the first service qualification; direct TLS is separately advertised only after NET-3 passes.
