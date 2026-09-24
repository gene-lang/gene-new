# Experimental streamed HTTP requests

**Status:** `net/http/serve ^body_mode "stream"` is implemented experimentally
for Content-Length and chunked requests on the native POSIX VM. Buffered mode
remains the default. The executable contract is the streamed-body cases in
`tests/test_http_server.nim`. Streamed responses remain NET-2 work.

In stream mode, the server validates and bounds the header block, request
admission, and declared body length before dispatching the handler. It creates
a `StreamRequest` whose `body` implements qualified `AsyncReader` and
`IoResource`. The handler may await `(req/body .AsyncReader:read n)` for Bytes;
nil means the declared body length or final chunk and trailer arrived completely. A truncated body closes
the reader with an error or cancellation, never successful EOF. The handler
may close the body early; the server then closes that connection after its
response. The body reader is also closed when the request ends.

The server feeds the body through a bounded `io/pipe`, with at most one pipe
write pending and at most one socket chunk retained before pausing socket
reads. A slow body consumer does not block unrelated requests or a native
worker. `^max_body_bytes` is finite in stream mode (0..64 MiB, default 10 MiB).
Header blocks retain the existing 32 KiB and 128-line limits. The body idle
deadline is `^body_idle_ms` (1..300000, default 10000). It resets on received
body bytes and pauses while the server itself is backpressured; the request
task's total deadline remains active. `^body_idle_ms` has no meaning in
buffered mode and is rejected there.

Stream mode accepts Content-Length framing, including zero length, or exactly
`Transfer-Encoding: chunked`. A chunk size is parsed as bounded hexadecimal,
optional chunk extensions are ignored under a 4 KiB chunk-line cap, and
trailers are syntax-checked then discarded under the 32 KiB/128-line header
limits. Declared or decoded body bytes over `^max_body_bytes` answer 413;
malformed chunk framing answers 400.
Content-Length combined with Transfer-Encoding, duplicate framing headers,
and other transfer codings answer 400. The server never exposes chunk framing
bytes to `AsyncReader`. Stream mode uses task-per-request dispatch;
actor-pool streaming is not yet implemented.
Existing `serve` calls without `^body_mode` keep their buffered `Request`
with a Str body. Buffered response helpers remain unchanged; the separate
`StreamResponse` is described in [its contract](http-stream-response.md).
