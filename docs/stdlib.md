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
($println (read_text "greeting.txt"))
```

The native CLI grants filesystem access under the launch directory by default.
Additional directories can be selected before the entry file:

```sh
gene run --allow_read_dir /path/to/data report.gene
```

Narrow permission inside the program with a declaration row or
`with_capabilities`. A retained file/database handle cannot restore permission
removed by the current context. See the [capability examples](../examples/capabilities/README.md)
and [authority contract](spec/authority.md).

For byte-oriented I/O use `read_bytes` / `write_bytes`. Filesystem watching is
available through `$fs/watch`; close watchers when finished.

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
Postgres is available through `$db/postgres` with the same Db operations and
its backend-specific connection and placeholder syntax. Do not interpolate
untrusted values into SQL.

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
| Structured concurrency | `scope`, `spawn`, `await`, `$channel`, `$actor` |
| Numeric data/native buffers | `$buffer` and the [native example](../examples/native/README.md) |
| URLs and forms | `$url`; [Todo app](../examples/todo_app/src/main.gene) |
| Command execution/environment | `$os`, subject to the active context |
| Interactive terminals | `$terminal` / `$curses`; runtime support is platform-dependent |

Use the [language guide](language.md) for call, message, and import syntax.
Exact lifecycle and boundary rules remain in [the specification](spec/README.md).
