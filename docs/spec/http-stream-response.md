# Experimental streamed HTTP responses

**Status:** `net/http/stream` is experimental on the native POSIX VM. Its
executable contract is the streamed-response cases in `tests/test_http_server.nim`.
The existing buffered `Response`, `text`, `html`, `json`, and `bytes` helpers
retain their current behavior. The owned pooled HTTP client and full service
qualification remain open.

`(stream reader)` selects status 200; `(stream status reader)` selects an
explicit body-permitting status. The reader must implement qualified
`AsyncReader`. Named options are `^content_type` (default
`"application/octet-stream"`), `^headers` (Map of Str), `^content_length`
(nonnegative Int when known), `^max_bytes` (default 64 MiB, hard cap 1 GiB),
and `^own_reader` (default false). Invalid options, reserved framing headers,
CR/LF header injection, and a body that lacks the required protocol fail
before response admission. Owned readers also implement `IoResource`.

The handler returns a `StreamResponse`. With `^content_length`, the server
writes that Content-Length and reads exactly that many Bytes, then confirms
EOF. Without it, the server uses HTTP/1.1 chunked framing and writes the
final zero chunk only after clean EOF. The server asks for at most 64 KiB per
read, retains one output chunk, and waits for socket write readiness before
reading more. A `HEAD` response sends the same headers without reading or
sending body bytes.

An upstream read failure, empty Bytes result, declared-length mismatch,
byte-limit overrun, timeout, or peer disconnect after headers closes the
connection. Partial output is never replaced with a fictional complete error
response, and an incomplete chunked body never receives a final zero chunk.
`^^own_reader` requests close and awaits physical retirement on successful
completion; an unowned reader remains the caller's responsibility. The
server cancels its pending read on abort without claiming to undo bytes
already sent.

The same request-body reader may be returned directly as the response source.
The server then keeps request socket reads and response writes active together,
with bounded pipe and socket buffers; it can echo bytes before the upload
finishes. Malformed or truncated request framing after response headers closes
the partial response without a final chunk. The reverse-proxy fixture and
pooled client body streams remain further NET-2/NET-1 work.
