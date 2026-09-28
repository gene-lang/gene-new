# Library recipes

Standard libraries live under `gene`; `$str` is shorthand for `gene/str`.
Import names when you use them repeatedly. These recipes show the common path;
[examples](../examples/) contain larger programs.

## Text and JSON

```gene runnable
(import $str [split trim join])
(let names ($map (split " Ada, Grace " ",") trim))
(join names " & ") # "Ada & Grace"
```

```gene runnable
(import $json [parse stringify])
(let data (parse "{\"name\":\"Ada\",\"scores\":[3,5]}"))
[data/name (stringify data)]
# ["Ada" "{\"name\":\"Ada\",\"scores\":[3,5]}"]
```

JSON supports objects, arrays, scalars, and escapes. Invalid input raises
JsonError. For input from an untrusted peer, `(parse text ^strict true
^max_depth 16)` also rejects a repeated object key and text that is not valid
UTF-8 (so bytes from a binary WebSocket frame meet the same decoder as a text
frame), and bounds nesting. Unsupported values, cycles, and non-finite floats are rejected.
Use explicit conversion when crossing the web backend's Int/bigint boundary.

`($crypto/sha256 input)` hashes the stored bytes of a Str or Bytes and returns
a lowercase hexadecimal digest. Use Bytes for binary files and payloads:

```gene
($crypto/sha256 ($binary/from_list [0 255 128 97]))
# "79301df919df82d717f591339d85235fb8bb8683b2c74680306959327d4a4464"
```

## Files

This recipe writes a file under the launch directory:

```gene
(import $fs [write_text read_text])
(write_text "greeting.txt" "Hello from Gene")
(read_text "greeting.txt")
```

Run a file with `gene run`, or use `gene eval` to have the runner display a
returned value:

```sh
gene run report.gene
gene eval '($fs/write_text "greeting.txt" "Hello from Gene")'
```

`write_text_atomic` stages and synchronizes a regular file, then publishes it in
the same directory. `^owner_only true` restricts the file to its owner before
any content is written, for a secret such as a connection credential. For byte-oriented I/O use `read_bytes` / `write_bytes`.
Filesystem watching, locking, and asynchronous filesystem adapters are also
available.

An application target can declare immutable resources with an existing
format-1 `^build [(resources "assets" ^files ["data/schema.json"])]`
recipe and select it through `^uses ["assets"]`. When the target is built and
run, `$pkg/read_bytes` or `$pkg/read_text` reads the selected resource from
the owning `this_pkg`. The runtime checks its recorded size and digest. The
resource path is package-relative; neither call searches the current working
directory. `$pkg/materialize` returns a verified, closeable lease exposing a
physical cache path when a native library needs one. The cache is private to
the current user and has no automatic eviction in this release.

```gene
(let schema ($pkg/read_text this_pkg "data/schema.json"))
(let lease ($pkg/materialize this_pkg "data/schema.json"))
(try ($println (lease .path)) ensure (lease .close))
```

Experimental PKG-2 `native_binary` recipes select a prebuilt file by target,
ABI, and digest. `($pkg/native_binary this_pkg "alias")` returns the same
closeable materialization lease. Pass its path to `ffi/open` or the matching
native extension loader, and close the lease after closing the library.
Experimental source-built `c_library` recipes produce verified shared
libraries or static archives from selected C sources. The same
`$pkg/native_binary` lookup materializes their output; see
[package installation](spec/package-install.md).
For a `gene_api` recipe, `($pkg/native_module this_pkg "alias")` performs the
verified load and returns an owned `NativeModule` with `.module`,
`.IoResource:close`, and `.IoResource:wait_closed`. A source-built recipe opts
in with `^abi_kind gene_api`; selected prebuilt variants declare the ABI in
their variant record. See [native module ownership](spec/native-module.md).

## Paths and CSV

`$path` performs lexical path operations without filesystem access. The native
VM currently qualifies these operations for POSIX paths:

```gene runnable
(import $path [join relative extension])
[(join "reports" "2026" "summary.csv")
 (relative "reports/2026" "reports")
 (extension "summary.csv")]
# ["reports/2026/summary.csv" "2026" ".csv"]
```

`join` rejects an absolute later component. `relative` rejects incompatible
roots or unresolved leading `..` segments. `$fs/walk` returns a lazy Stream of
`{^path ^relative_path ^kind ^size}` records in depth-first order. It sorts one
directory at a time, does not follow symlinks by default, and enforces depth,
per-directory, and total entry limits. Close a partially consumed Stream.

```gene
(let entries ($fs/walk "reports" ^max_depth 2))
(try
  (for entry in entries ($println entry/relative_path))
  ensure (entries .close))
```

`$csv/parse_rows` is the bounded, eager convenience operation. Fields remain
strings; `^headers true` yields property maps, and malformed rows raise typed
`CsvError` with offset, record, and field positions. The parser accepts LF or
CRLF records, quoted newlines, and a UTF-8 BOM at the start. Experimental
`$csv/reader` accepts a qualified `AsyncReader`; each concrete `.next` returns
a Task yielding one row or nil. Close it through `IoResource`. Pass
`^own_reader true` when the wrapper should close the upstream reader too.

```gene runnable
(import $csv [parse_rows encode_row])
[(parse_rows "name,count\nAda,3\n" ^headers true)
 ($binary/to_str (encode_row ["a,b" "two"]))]
# [[{^name "Ada" ^count "3"}] "\"a,b\",two\r\n"]
```

```gene
(import $io [open_read IoResource])
(let rows ($csv/reader (await (open_read "large.csv"))
                        ^headers true ^own_reader true))
(try
  (let row (await (rows .next)))
  (if ($nil? row) nil row/name)
  ensure (rows .IoResource:close))
```

## Value protocols and ordering (native VM experimental)

`ValueEq` and `ValueHash` select equality and hash behavior for a nominal Type.
They apply inside Lists, Sets, and general-key Maps as well as to `==` and
`$hash`. An equality-only Type cannot be used as a key. `same?` still checks
identity. `IndexRead` supplies `size` and numeric path reads; `IndexWrite`
supplies final numeric `set` writes. Unqualified messages such as `(x .get 0)`
do not dispatch through these protocols.

`gene/order` supplies stable List sorting. `sort_by` evaluates its key function
once per item and preserves input order when keys compare equal:

```gene runnable
(import gene/order [sort_by])
(let rows [{^rank 2 ^name "Ada"} {^rank 1 ^name "Bob"}
           {^rank 2 ^name "Cy"}])
(let sorted (sort_by rows /rank))
[sorted/0/name sorted/1/name sorted/2/name]
# ["Bob" "Ada" "Cy"]
```

`$order/compare` and numeric operators use `ValueOrder` for matching nominal
Types. Default sorting rejects mixed numeric types, NaN, and unrelated Types;
pass `^compare f` to `sort` or `sort_by` for an explicit policy. These
callbacks are synchronous on the root lane.

## Async byte I/O (native VM experimental)

`gene/io` exports `AsyncReader`, `AsyncWriter`, and `IoResource`. Generic code
uses qualified sends such as `(reader .AsyncReader:read 65536)` and
`(resource .IoResource:close)`; implementing a protocol does not add a bare
`.read` or `.close` message. Reads return fresh Tasks with Bytes or nil at EOF.
`close` requests retirement synchronously, while each `wait_closed` call returns
a fresh Task for the physical result.

`($io/write_all writer bytes)` returns a Task and loops over partial writes.
`($io/copy reader writer ^limit n ^chunk_bytes 65536)` returns a Task, borrows
both endpoints, and requires a finite nonnegative byte limit. The protocol and
generic operations have fake-adapter conformance coverage. Worker-backed
`$io/open_read path` and `$io/open_write path ^mode "create_new"` are experimental
on threaded POSIX runtimes. Write modes are `create_new`, explicit `truncate`,
and `append`; unthreaded runtimes return a failed open Task. File read/write,
flush, and close use cleanup leases. `($io/pipe)` returns a `[reader writer]`
pair on threaded POSIX runtimes with the same qualified protocols; closing its
writer delivers EOF after buffered bytes, and a closed reader makes later
writes fail with `IoError`.
`($io/tcp_connect host port ^timeout_ms 10000)` returns a Task yielding a
duplex `TcpStream`; `($io/tcp_listen host port ^backlog 128)` returns a Task
yielding a `TcpListener`. A listener's concrete `.accept` returns a Task of
`TcpStream`, and `.local_port` exposes the selected port when listening on
port 0. Both stream directions use the same `AsyncReader`/`AsyncWriter`
protocols and byte budgets as files and pipes. Close is a full socket close;
there is no local half-close or TLS on these raw TCP streams. A blocked accept,
read, or write parks in the POSIX readiness watcher, leaving native workers
available for unrelated work.

```gene
(let IoResource $io/IoResource)
(let listener (await ($io/tcp_listen "127.0.0.1" 0)))
(let accepting (listener .accept))
(let client (await ($io/tcp_connect "127.0.0.1"
                                     (listener .local_port))))
(let server (await accepting))
(client .IoResource:close)
(server .IoResource:close)
(listener .IoResource:close)
(await (client .IoResource:wait_closed))
(await (server .IoResource:wait_closed))
(await (listener .IoResource:wait_closed))
```

For binary subprocess output, pass pipe writers as `^stdout_pipe` and/or
`^stderr_pipe` to `$os/exec_stream_async`, then consume their readers through
`AsyncReader`. Each option consumes and closes its writer when the child
finishes; the returned Task keeps its existing process-result map. Existing
`^stdout_chan` line streaming is unchanged. For binary input, pass an `io/pipe`
reader as `^stdin_pipe` and write through its paired `AsyncWriter`; close that
writer to deliver EOF to the child. The subprocess consumes and closes the
reader on completion or cancellation. HTTP client and response body adapters
remain open; the server's request-body adapter is experimental.
The streamed channel's captured text field in that map is empty; use the pipe
reader for its raw bytes.
When capturing both stdout and stderr through pipes, read them concurrently;
a child can block on one full pipe while the other reader waits for EOF.
`$io/testing/new` provides a deterministic native resource for adapter tests;
`$io/testing/complete_read` and `complete_write` stand in for physical worker
completion. It is a test surface, not a file or socket transport.

## HTTP server

Save this as `server.gene` and run it with `gene run server.gene`:

```gene
(import $net/http [listen serve text])

(fn handle [request]
  (match request/path
    (when "/" (text 200 "Hello from Gene"))
    (else (text 404 "Not found"))))

(fn main [args]
  (let server (listen ^host "127.0.0.1" ^port 8080))
  (serve server ^handler handle)
  0)
```

The server supports request tasks, routing, admission limits, timeouts,
access/error hooks, actor-pool dispatch, and WebSockets. `ws_accept` takes
`^subprotocol` to select one the client offered (browsers fail a handshake
that offered one and got none), and `ws_queued` reports how many bytes a peer
has not yet accepted, so a sender can stop producing replaceable data before
the bounded outbound queue drops anything. In the web profile,
`$ws/connect_protocol url protocol` offers that subprotocol. A sleeping request
handler can suspend without blocking the other requests. TLS and broader
production hardening remain future work.

For a bounded streamed request body, pass `^body_mode "stream"` to `serve`.
The handler receives a `StreamRequest` with `request/body` implementing
qualified `AsyncReader` and `IoResource`; nil from `read` means the declared
Content-Length or final chunk/trailer arrived completely. This mode accepts
Content-Length or `Transfer-Encoding: chunked` with task-per-request dispatch;
`^body_idle_ms` sets its body idle timeout (default 10000). Buffered `Request`
bodies and responses keep their existing shapes. For output, `(stream reader)`
or `(stream status reader ^own_reader true ^content_length n)` sends a bounded
`AsyncReader` response with Content-Length when known, otherwise chunked
framing. A handler can return `(stream request/body)` to echo a streamed upload
before that upload finishes. See the [response contract](spec/http-stream-response.md) and the
[streamed request contract](spec/http-stream-request.md).

Use [the async-server example](../examples/async-http-server.gene) for routes,
limits, and lifecycle control. The [Todo app](../examples/todo_app/src/main.gene)
adds forms, SQLite, and browser behavior.

## HTTP client

The experimental reusable Client is separate from the module-level one-shot
functions below. Open returns a Task; a Client's `.request` returns a Task with
Bytes body and ordered header pairs, and qualified `IoResource` close waits for
native retirement. It reuses HTTP/1.1 connections across requests from the
same Application. See the [owned Client contract](spec/http-client-owned.md)
for the current buffered surface and remaining streamed features.

```gene
(let IoResource $io/IoResource)
(let client (await ($net/http_client/open)))
(let response (await (client .request ^url "http://127.0.0.1:8080/data")))
(client .IoResource:close)
(await (client .IoResource:wait_closed))
```

```gene
(import $net/http_client [request])
(let response (await (request ^url "https://example.com")))
($println response/status)
```

`request` returns a Task. Use the streaming client operation for bounded chunk
consumption and cancellation. Host/setup errors are distinct from HTTP response
status.

An explicit CA file can be supplied with `^ca_file`. Exact query bytes,
including an empty query delimiter, survive transmission. Application
Authorization/Cookie headers are ordinary request data; the client has no
automatic credential or cookie store.

Redirects are returned without following them. The native transport uses fresh
HTTP/1.1 connections, disables environment proxies, verifies TLS, and rejects
protocol upgrades. Transport failures use `HttpClientError`.

## SQLite

Database backends expose the shared Db protocol. Bind SQL values as parameters:

```gene runnable
(import $db/sqlite [open Db])
(let db (open ":memory:"))
(try
  (db .Db:exec "create table people (name text)")
  (db .Db:execute "insert into people(name) values (?)" "Ada")
  (db .Db:query "select name from people")
  ensure (db .Db:close))
# [{^name "Ada"}]
```

File-backed SQLite keeps a connection-local database image and publishes
committed changes atomically to its database file. A separate `COMMIT` or outer
`RELEASE` publishes the batch before returning; `Db:exec` also preserves a
committed prefix if a later statement fails or starts another transaction.
Closing a connection discards unfinished transactions and does not rewrite
its image. Existing connections keep their snapshots, so reopen to observe
another connection's commits.

That whole-image path rewrites the entire file on every commit, so its cost
grows with the database. For a long-lived store, `open_file` opens the file
itself: SQLite's pager and journal persist each commit by writing only the
pages it changed, and nothing is republished.

```gene
(import $db/sqlite [open_file Db])
(let db (open_file "world.sqlite" ^create true ^busy_timeout_ms 5000))
(db .Db:query_one "PRAGMA journal_mode=WAL")   # durability settings are yours
(db .Db:exec "PRAGMA synchronous=FULL")
```

A missing file is an error unless `^create true`; a created file (and its WAL
and journal sidecars) is owner-only. Connections share the same `Db` protocol
and report `db/storage` as `"file"`. The Commons world store
(`examples/world/server/persistence.gene`) is the worked example.

Postgres is available through `$db/postgres` with the same Db operations and
its backend-specific connection and placeholder syntax. Do not interpolate
untrusted values into SQL.

SQLite also supports synchronous C-backed row visitation:

```gene runnable
(import $db/sqlite [open Db visit_text_rows])
(let db (open ":memory:"))
(let rows [])
(try
  (visit_text_rows db "select 1 as id union all select 2"
    (fn [columns values]
      (rows .push [columns values])
      true))
  rows
  ensure (db .Db:close))
# [[["id"] ["1"]] [["id"] ["2"]]]
```

`visit_text_rows` accepts one query with result columns that SQLite reports as
read-only, without SQL parameters. The callback receives copied column-name
and value Lists, preserving duplicate names and SQL NULL as nil. Values follow
SQLite's text/C-string conversion; use `Db:query` for typed results, blobs,
embedded-NUL data, and parameter binding. The callback returns Bool: true
continues and false stops normally. The operation returns the number of rows
delivered, including the stopping row.

This operation runs on the owning root lane. Callback errors, panic, and
cancellation propagate after SQLite returns; waits and native callback re-entry
are rejected. The active connection cannot be reused or closed by its callback,
including through its raw owned handle. Disposal and ownership transfer remain
blocked until the native borrow ends. See the
[native callback contract](spec/modules.md#synchronous-native-callbacks).

## Serialization and persistence

For Gene data, start with the data-only serde pair:

```gene runnable
(import $serde [write_data read_data])
(let original {^name "Ada" ^scores [3 5]})
(== original (read_data (write_data original))) # true
```

These operations do not reconstruct arbitrary functions or native resources.
The full serde mode can resolve references against already-loaded modules;
restore hooks require an explicit trusted opt-in.

For durable named records, create a state directory and use a Store backend:

```gene
(import $store/fs [open Store])
(let state (open ^root ".state"))
(try
  (state .Store:put "settings" {^theme "dark"})
  ($println (state .Store:get "settings"))
  ensure (state .Store:close))
```

Point writes are atomic. Use checkpoint generations when several records must
be restored together. The application chooses save timing; this does not
replay arbitrary in-flight effects. [Cordis](../examples/cordis/README.md)
illustrates lifecycle and persistence in an application.

## Logging

```gene runnable
(import $log [new_logger log_debug])
(let logger (new_logger "app/demo" ^payload {^component "example"}))
(logger .info "ready" ^payload {^items 3})
(log_debug logger $"details: ${[1 2 3]}")
```

Level methods evaluate their arguments eagerly. The `log_*` macros defer
payload evaluation until the level is enabled. An application configures
routes and levels; a library should use or accept a named logger. Diagnostic
logging is separate from a durable application event log.

## Application events

An event's nominal type identifies its family. A bus is an explicit value:

```gene runnable
(type UserJoined : $event/Event ^props {^name Str})
(let seen ($cell []))
(let bus ($event/Bus))
(bus .subscribe UserJoined
  (fn [event] ((seen .get) .push event/name)))
(bus .publish (UserJoined ^name "Ada"))
(bus .close)
(seen .get) # ["Ada"]
```

Subscriptions match nominal ancestry; cancel a subscription or close the bus
to release handlers. Publishing creates an immutable event snapshot. Read the
[event example](../examples/events.gene) for error policies, event families,
and sinks. Optional VM-wide event instrumentation is not implemented.

## HTML and CSS

Markup is ordinary node data; render at the output boundary:

```gene runnable
(import $html [render])
(let title "Ada & Grace")
(render `(article (h1 %title)))
# "<article><h1>Ada &amp; Grace</h1></article>"
```

The `$css` library supplies rules, declarations, rendering, and scoped class
names. Embedded `web_module` code can enhance server-rendered markup; see
[web workflows](workflows.md#web-applications).

## More libraries

| Need | Starting point |
| --- | --- |
| Collection operations | `$map`, `$filter`, `$filter_map`, `$take`, `$into`, `$each` |
| Assertions and unit tests | `$assert` and the [`$test` framework](testing.md) |
| Structured concurrency | `scope`, `spawn`, `await`, `$channel`, `$actor` |
| Numeric data/native buffers | `$buffer` and the [native example](../examples/native/README.md) |
| URLs and forms | `$url`; [Todo app](../examples/todo_app/src/main.gene) |
| Command execution/environment | `$os`, subject to the active context |
| Interactive terminals | `$terminal` / `$curses`; runtime support is platform-dependent |

Use the [language guide](language.md) for call, message, and import syntax.
Exact lifecycle and boundary rules remain in [the specification](spec/README.md).
