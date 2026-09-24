# Experimental owned HTTP Client

**Status:** The reusable Client has experimental buffered and streamed
responses on the native threaded VM. Its loopback contract is
`tests/test_owned_http_client.py` under ORC and AtomicArc. The existing
module-level `net/http_client/request` and `stream` APIs retain their return
shapes and fresh-connection behavior. Full service qualification remains open.

`($net/http_client/open ...)` returns a Task yielding a non-Send Client.
Options are fixed at open: total/per-origin connection caps (16/8 by default),
pending request cap (64), idle age (30 seconds), connect/total timeouts
(10/30 seconds), buffered/stream body byte caps (8/64 MiB), proxy policy,
and an optional `^ca_file`. The CA file is read on the native service thread
and captured for later requests; changing it on disk does not change an
already opened Client. Unknown or invalid options fail before admission.
`^redirects` accepts 0..20 (default 0) and bounds the number of followed
hops.

Across Clients, one Application admits at most 4,096 outstanding owned HTTP
requests. Each request also reserves its response buffer or stream queue,
upload queue or static body, and CA snapshot against the Application I/O byte
budget.

`(client .request ^url url ...)` returns a Task yielding a Map with `status`,
`headers` as an ordered List of `[name value]` pairs (duplicates preserved),
`effective_url`, and `body` as Bytes. Request options currently support
method (default GET), URL, headers as a Map or ordered pair List, nil/Str/Bytes
body, exact `^content_length` for buffered bodies, a finite timeout, and a
finite `^max_bytes` within the Client's configured buffered cap. Invalid framing
headers, CR/LF injection, and duplicate options fail synchronously.

`^body` also accepts an AsyncReader. The source remains caller-owned; the
Client cancels an outstanding read on request cancellation or close, but does
not close the source. A second owned upload using the same reader is rejected
with IoBusy until the first transfer retires. The caller must not read the
source concurrently outside the Client. The native upload queue is bounded
to 64 KiB; an empty queue pauses only that transfer, and the multi worker
resumes it after a root-lane AsyncReader read supplies Bytes. Unknown length
uses HTTP/1.1 chunked framing. With `^content_length`, the Client verifies
both the exact byte count and actual source EOF, failing short or extra data
with HttpClientError. Total upload bytes are capped by the Client's
`^max_stream_body_bytes`. A stream upload can be paired with either buffered
or streamed response handling.

When `^redirects` is positive, the Client follows 301, 302, 303, 307, and
308 only for GET/HEAD without an upload body. The next URL is resolved
against the current URL; only HTTP(S) targets without embedded credentials
are allowed. HTTPS-to-HTTP downgrades fail with HttpClientError. Cross-origin
hops remove Authorization and Cookie, and every hop rebuilds Host. The
original timeout includes queue wait and every hop. A redirect with no
Location, a request with an upload body, or a response after the hop limit
is returned to the caller; the Client never retries a body-bearing request.
Followed hop bodies are discarded within the native worker rather than
counting against the final response byte cap.

`(client .stream ^url url ...)` accepts the same currently supported request
options and returns a Task when final headers arrive. Its response Map has
the same metadata, with `body` as a non-Send `BodyReader` implementing
AsyncReader and IoResource. `read max_bytes` accepts 1..1,048,576 and yields
Bytes or nil only after complete HTTP framing; a short response, transport
error, deadline, or `^max_bytes` breach after headers fails a read with
HttpClientError. The reader retains the transfer and a root-owned cleanup
lease after the header Task settles. Closing the reader or Client cancels an
active transfer and pending read; `wait_closed` waits for native cleanup.
The native receive queue is bounded to 1 MiB or the selected `^max_bytes`,
whichever is smaller. A full queue pauses only that transfer; the native
multi worker resumes it after the reader drains capacity. Other Client
requests can complete while one reader is paused.

One native libcurl multi service belongs to the Application and owns all its
easy/multi handles on one worker thread. Multiple Clients share that service;
connection reuse is observable across sequential requests. The root lane
only enqueues commands and settles Tasks. Each Client enforces its own total
and per-origin running caps before handing requests to the shared service;
requests waiting for a slot retain their admission deadline. The transport caps native response
bytes and counts request snapshots plus the maximum buffered response or
stream queue against
the Application I/O byte budget. A canceled request can have sent a prefix;
it is not retried or rolled back. Closing a Client cancels active requests,
stops admission, and requests service retirement when it is the last Client.
Every `IoResource:wait_closed` call returns a fresh Task that waits for physical
cleanup or returns the retained close result.
