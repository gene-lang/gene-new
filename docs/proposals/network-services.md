# Gene Network Services

**Status:** Proposed design; present HTTP behavior is documented in `docs/stdlib.md`.  
**Purpose:** Make the existing HTTP server/client usable for ordinary deployed services and API-consuming applications.  
**Boundary:** Network adapters use the current Gene Task and application APIs. They do not introduce a second scheduler or new call syntax.

## Current base and selected shape

The current server provides routing, admission limits, request tasks, timeouts, and WebSockets. The client returns redirects, opens fresh HTTP/1.1 connections, disables environment proxies, and verifies TLS. Keep its existing `request` convenience function with those defaults for compatibility. Add a reusable `Client` object for policy and connection ownership. Add TLS configuration to server `listen`, or use an explicitly documented reverse-proxy mode until direct TLS qualifies. Neither mode makes a plain public listener silently secure.

## Client contract

`$net/http_client/open` creates a `Client` with immutable options: connection limit and idle lifetime per origin; connect, header, body, and total timeouts; redirect policy; proxy policy; trust roots; and response/body byte limits. `(client .request ...)` returns a Task as the current convenience call does. `(client .close)` rejects new requests, cancels or settles outstanding requests under a declared close policy, and releases pooled connections. The old `$net/http_client/request` uses a short-lived client with current defaults.

Proposed first-release option names and defaults for `open`:

| Option | Default | Meaning |
| --- | --- | --- |
| `^max_connections_per_origin` | `8` | Bound active plus idle connections for one scheme/host/port. |
| `^max_pending_requests` | `64` | Bound requests waiting for a connection; excess admission fails before retaining a body. |
| `^max_idle_ms` | `30000` | Close an unused pooled connection after this interval. |
| `^connect_timeout_ms` / `^total_timeout_ms` | `10000` / `30000` | Wall-clock deadlines; nil is rejected by the supported profile. |
| `^redirects` | `0` | Maximum redirects; zero preserves current return-without-following behavior. |
| `^proxy` | nil | Direct connection. An explicit proxy URL or `"environment"` opts in. |
| `^ca_file` | nil | Use the platform trust store; an explicit file replaces that trust source for this Client. |
| `^max_buffered_body_bytes` | `8388608` | Limit only the convenience API that materializes the whole body; streaming has per-chunk and total limits. |
| `^max_stream_body_bytes` | `67108864` | Bound a streamed response unless the application supplies a larger finite limit. |

Invalid option combinations fail before network I/O. A `Client` is owned by one Application; it is not implicitly serialized, Send-safe, or shared across worker lanes. `(client .close)` returns nil when close has been requested; outstanding Task outcomes remain inspectable. The first supported protocol is HTTP/1.1, matching the current transport. HTTP/2 is a separate compatibility and performance decision.

Redirects remain disabled unless `^redirects` selects a maximum count. The first release follows them automatically only for GET/HEAD; other methods return the redirect response. An HTTPS request never auto-follows to HTTP. A redirect never forwards Authorization or Cookie to a different origin by default. Proxy use is opt-in and may select an explicit URL or approved environment settings. TLS verification remains on by default; custom CA material is explicit. The pool never shares a connection across incompatible proxy/TLS settings or origins, and it bounds queued requests and idle sockets.

For streaming, a request body can be Bytes or an [async reader](async-io.md). The response exposes status/headers and a bounded async body reader. The caller either consumes or closes that body; cancellation closes the underlying request and returns the connection to the pool only when its protocol state is reusable. The existing buffered response path may be implemented as a bounded consumer of this reader.

## Server and socket contract

`$net/http/listen` gains an optional `^tls` data map naming certificate, private key, and trust/client-auth policy. The server loads a complete validated configuration before accepting TLS connections. A reload publishes a complete new configuration for future handshakes while existing connections finish under the old one; a failed reload leaves the old configuration active and reports the error. Plain HTTP remains available on explicit loopback or behind a separately configured reverse proxy. Reverse-proxy mode must define trusted peer addresses and the exact forwarded-header policy; arbitrary client-supplied forwarding headers are ignored.

The public reload call is `(server .reload_tls config)` and returns a Task whose result means the new configuration is active for new handshakes. It never changes an established TLS session. Listener shutdown closes admission first, then settles or cancels request tasks under a configured grace period before releasing sockets. A timeout reports how many requests were interrupted.

Request handlers can read bounded or streamed bodies. Admission limits apply before unbounded body buffering; slow readers, stalled writers, and oversized headers/bodies receive documented errors or connection close without blocking unrelated handlers. WebSocket upgrade keeps its current application-level receipt responsibilities. Add a general TCP byte-stream client/listener after [async I/O](async-io.md) is established; UDP is a later separately qualified profile.

## Implementation order

1. Refactor current HTTP client transport behind an owned Client while preserving all current tests and defaults. Add pooling, limits, opt-in redirect/proxy behavior, and local test peers.
2. Expose async request/response body readers and cancellation. Verify byte-for-byte results, early close, server disconnect, and pool reuse decisions.
3. Add TLS server mode and certificate reload, or qualify the documented reverse-proxy deployment first. Test local CA, bad certificate/key pairs, expiration/hostname failures, and reload failure.
4. Adapt server bodies and socket byte streams to the same bounded I/O contract. Run the service workload from [the native profile](python-replacement-profile.md) with slow clients and concurrent requests.

**Acceptance:** an installed Gene application can serve HTTPS under one supported mode, make repeated verified HTTPS requests efficiently, stream large bodies without whole-body buffering, and cancel work without retaining sockets or starving other requests.
