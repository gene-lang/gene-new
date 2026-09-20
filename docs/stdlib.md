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
JsonError. Unsupported values, cycles, and non-finite floats are rejected.
Use explicit conversion when crossing the web backend's Int/bigint boundary.

## Files and permissions

This recipe writes a file under the launch directory:

```gene
(import $fs [write_text read_text])
(write_text "greeting.txt" "Hello from Gene")
(read_text "greeting.txt")
```

The native CLI grants no external authority by default. Supply a policy before
the entry file, or use `gene eval` to have the runner display a returned value:

```sh
gene run --cap '[(fs/Read "/path/to/data")]' report.gene
gene eval --cap '[(fs/ReadWrite ".")]' '($fs/write_text "greeting.txt" "Hello from Gene")'
```

The old directory grant flags are removed. CLI policies replace environment
defaults rather than adding to them. Declaration rows and `with_capabilities`
use the same normalized policy core. Retained handles cannot replace current authority with
their origin grants. See the [authority contract](spec/authority.md) and
[implementation tracker](implementation/capabilities-v1.md).

For byte-oriented I/O use `read_bytes` / `write_bytes`. Filesystem watching,
locking and asynchronous filesystem adapters remain unsupported in the initial
normalized profile until their operation/ownership contracts are adopted.

`write_text_atomic` stages and synchronizes a regular file, then guards its
same-directory publication. Under normalized authority, revocation or a changed
binding prevents later use of a retained descriptor. Unpublished temporary
entries are removed only with live write authority; close never flushes buffered
application data after revocation. See the
[filesystem profile](implementation/capabilities-filesystem-profile.md).

`$fs/try_lock` and application file logging are also unsupported in the initial
normalized profile. They require adopted operation, ownership, and cleanup
contracts before application use; the removed `fs/WriteFile` selector is not a
way to authorize them.

## HTTP server

Save this as `server.gene` and run it with `gene run server.gene`:

```gene
(import $net/http [listen serve text])

(fn handle [request]
  (match request/path
    (when "/" (text 200 "Hello from Gene"))
    (else (text 404 "Not found"))))

(fn main [args]
  ^capabilities [(net/Listen ^host "127.0.0.1" ^port 8080)]
  (let server (listen ^host "127.0.0.1" ^port 8080))
  (serve server ^handler handle)
  0)
```

The server supports request tasks, routing, admission limits, timeouts,
access/error hooks, actor-pool dispatch, and WebSockets. A sleeping request
handler can suspend without blocking the other requests. TLS and broader
production hardening remain future work.

Use [the async-server example](../examples/async-http-server.gene) for routes,
limits, and lifecycle control. The [Todo app](../examples/todo_app/src/main.gene)
adds forms, SQLite, and browser behavior.

## HTTP client

```gene
(import $net/http_client [request])
(let response (await (request ^url "https://example.com")))
($println response/status)
```

`request` returns a Task. Use the streaming client operation for bounded chunk
consumption and cancellation. Network operations require active permissions;
host/setup errors are distinct from HTTP response status.

The normalized capability path uses `net/Http` component constraints and guards
both submission and worker startup. Preparing a request grants no authority:

```gene
(import $net/http_client [prepare describe_operation send])
(let prepared (prepare "GET" "https://api.example.com/status?"))
(let decision ($capabilities/check_operation (describe_operation prepared)))
(if decision/allowed
  (await (send prepared))
  nil)
```

`send` accepts one immutable prepared request plus transport limits or `^ca_file`;
it rejects replacement method, URL, headers, or body arguments. An explicit CA
file requires separate filesystem read authority. Exact query bytes, including
an empty query delimiter, survive preparation and transmission. Application
Authorization/Cookie headers are ordinary request data; the client has no
automatic credential or cookie store in this profile.

Redirects are returned without following them. A later request to the redirected
target needs its own guard. The initial native transport uses fresh HTTP/1.1
connections, disables environment proxies, verifies TLS, and rejects CONNECT,
authority/framing overrides and protocol upgrades. A denied request raises a
typed capability error; transport failures use `HttpClientError`. See the
[HTTP enforcement profile](implementation/capabilities-http-profile.md).

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

File-backed SQLite needs filesystem permission for its database location.
It keeps a connection-local database image and publishes committed changes
atomically through the filesystem provider. A separate `COMMIT` or outer
`RELEASE` publishes the batch before returning; `Db:exec` also preserves a
committed prefix if a later statement fails or starts another transaction.
Closing a connection discards unfinished transactions and does not rewrite
its image. Existing connections keep their snapshots, so reopen to observe
another connection's commits.

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
