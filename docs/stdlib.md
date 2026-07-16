# Standard Library Plan

This document defines the standard-library work needed to build an end-to-end
Gene web application with a SQLite backend. The goal is not to clone a large
general-purpose stdlib immediately; it is to provide a coherent, small surface
that makes the web app path real, testable, and stable.

Implementation status:

- Phase 1 (`std/stream`, `std/node`, `std/parse`, `str`) — implemented as
  built-in namespaces; spec-tested in `tests/spec_runner.nim`.
- Phase 2 (`html` escape, `url` encode/decode/parse_query/format_query with
  typed `UrlError`) — implemented; spec-tested.
- Phase 3 (`net/http` blocking server: `serve`, `Request`/`Response`/`Server`
  types, `text`/`html`/`json`/`redirect`/`not_found` helpers, `HttpError`,
  `^max_requests` for tests) — implemented; `examples/todo_app.gene` is the
  end-to-end proof (HTML page + JSON API). Deviations from this plan: response
  construction uses helpers or `(Response ^status N ^body s)` because type
  constructors take named fields only; `cookie`/`set_cookie`/`static_file` are
  not implemented yet.
- `net/http_client` — implemented as a capability-gated, dynamically loaded
  libcurl client. `request` returns a cancellable `Task`; `stream` returns a
  task plus a bounded channel of raw response chunks. TLS certificate
  verification remains enabled by libcurl. There is no link-time dependency;
  `GENE_LIBCURL` overrides library discovery.
- Phase 4 (databases) — implemented beyond the original SQLite-only plan: a
  shared `Db` protocol (`exec`/`query`/`query_one`/`execute`/`transaction`/
  `close`/`closed?`) in the `db` namespace with `db/sqlite` and `db/postgres`
  backends. Both load their C client library at runtime via dynlib (no
  link-time dependency; `GENE_LIBPQ` overrides the libpq path). Connections
  are `SqliteDb`/`PostgresDb` nodes whose `^handle` is an owned C pointer
  wired to the library close function. Rows are maps with typed values;
  parameters are positional (`?` for sqlite, `$1` for postgres — SQL dialect
  is not abstracted). Failures raise catchable `DbError`. `transaction` rolls
  back on recoverable error or panic and commits on normal return. Statement
  values, named parameters, and blob columns are not implemented.
  `examples/todo_app.gene` persists through `db/sqlite`. Backend impls live
  on the namespace scopes, so only importing programs pay protocol-dispatch
  cost.
- Phase 5 (`web/router` etc.) — not started.
- `serde` (Gene-text serialization) — stages 1–6 implemented:
  `serde/write_data`/`read_data`/`data?`, full `serde/write`/`read`,
  typed refs/instances, policy-gated restore hooks, `SerdeRef`,
  `SerdeError`, and `SerdePolicy`, per docs/proposals/serialization.md.
- `store` (durable serde-backed persistence) — controlled-stop MVP
  implemented: shared `Store` protocol, `StoreError`, `store/sqlite`,
  `store/fs`, and `Fs/make_dir`/`Fs/remove`, per
  docs/proposals/persistence.md.

## Goals

- Make `examples/web_demo.gene` runnable without test-only stubs.
- Support a small server-rendered web app with routes, request parsing, HTML
  rendering, forms, redirects, cookies, and static assets.
- Support SQLite-backed persistence with prepared statements, transactions,
  typed rows, and structured database errors.
- Keep stdlib APIs ordinary Gene modules and namespace imports where possible.
- Preserve the core language boundary: selectors read data, sends invoke
  behavior, and capabilities make host authority explicit.

## Non-Goals

- Full package management, registries, or dependency solving.
- A production async HTTP *server* stack with TLS and HTTP/2. The client can
  negotiate either through libcurl.
- ORM/query builder abstraction over SQL.
- Browser client framework or reactive frontend runtime.
- Cross-database compatibility.

## Module Layout

Initial modules should be available through namespace imports:

```gene
(import std/stream [to_stream to_pairs_stream map filter take each into])
(import std/node [head props body meta declarations])
(import std/parse [parse_int read_all ParseError])
(import str [join split starts_with? ends_with? trim byte_size slice_bytes])
(import html [escape render])
(import net/http [Request Response Server serve redirect])
(import net/http_client [Http request stream HttpClientError])
(import log [Logger LogLevel new_logger info! debug!])
(import curses [Screen open close dimensions draw read_input refresh_input
                escape_pressed? next_event CursesError])
(import sqlite [Database Statement Row SqliteError])
```

`str/slice_bytes` returns at most the requested number of UTF-8 bytes without
splitting a character. Its zero-based start offset must itself be a UTF-8
boundary. This is the bounded primitive used by agent-facing ranged reads.

For MVP, these may be built-in namespaces registered by the runtime. File-backed
stdlib modules can replace or wrap those namespaces later, but source programs
should not need to change.

### `log`

Structured diagnostic logging is configured by the launcher and is separate
from program output, typed errors, authoritative event/audit logs, metrics, and
execution traces. The default route emits `warn` and `error` to stderr.

```gene
(import log [Logger LogLevel new_logger debug!])

(var logger
  (new_logger "app/http" ^payload {^service "api"}))

(logger ~ info "listening" ^payload {^port 8080})  # eager
(debug! logger (expensive_message)                  # lazy
  ^payload {^request_id id})
```

`Logger` is an immutable, Send-safe native handle. `new_logger` creates names
under `app/*`; `child` derives a descendant and `with` adds immutable base
payload. Eager `error`/`warn`/`info`/`debug`/`trace` methods evaluate arguments
normally. Their `!` macro counterparts evaluate the logger once and skip
message/payload evaluation when disabled. `enabled?` accepts `LogLevel`; `emit`
is the eager level-parametric primitive.

Payloads are PropMaps/general maps with string or symbol keys and data-only
values. Base and event payloads merge with event keys winning. Payloads are
bounded and recursively redacted before reaching any sink; common credential
keys are redacted by default. Programming/boundary mistakes raise normally,
while accepted-event renderer or sink I/O failures never enter application
control flow.

`gene run --log-config path app.gene` explicitly loads a data-only config
before the entry module. It supports hierarchical segment-aware routes,
console/file sinks, Gene/text/JSON Lines formats, color policy, and flush policy;
file paths are relative to the config file. Config is immutable during entry
execution. Under wasm, console logging uses captured host output and file sinks
are unavailable. See [the logging proposal](proposals/logging.md) for the full
schema and performance contract.

When application-selected file output is required, `new_file_logger` takes an
explicit `Fs/WriteDir`, logger name, and path and returns a direct one-file
logger. It defaults to one reader-valid Gene data map per line. Pass
`^format "json"` or `^format "jsonl"` only when JSON interoperability is
required; `^format "text"` remains available for concise human lines. It does
not mutate process routing and is unavailable under wasm.

### `os`

The subprocess surface separates captured execution from whole-terminal
handoff:

```gene
(import os [executable_path exec_async exec_stream_async exec_stdio_async Exec])

# Absolute path of the currently running Gene executable.
(var gene (executable_path))

(var result
  (await (exec_async Exec ^cmd "sh" ^args ["-lc" "nimble test"])))

# The child inherits stdin/stdout/stderr, while only this fiber waits.
(var status
  (await (exec_stdio_async Exec ^cmd "vi" ^args ["notes.txt"])))
```

`exec_async` returns a cancellable `Task` yielding the same captured result map
as `exec`. `exec_stream_async` additionally sends complete stdout lines through
the required bounded `^stdout_chan`. `exec_stdio_async` returns a cancellable
`Task[Int]`; its child inherits the parent streams, but waiting happens on a
dedicated worker so unrelated fibers, HTTP sessions, and application workers
continue. Inherited-stream children are serialized because they share one
physical terminal and process-wide terminal signal disposition. The synchronous
`exec_stdio` remains available for simple programs that intentionally block
their scheduler.

All subprocess entry points require `Os/Exec`. Cancellation terminates an
active async child. `exec_stdio_async` accepts only `^cmd`, `^args`, and `^dir`;
capturing, timeouts, and output limits do not apply to a terminal handoff.
`executable_path` takes no arguments and returns the absolute path of the
current Gene executable, which lets a program launch a subcommand through the
same runtime without guessing from `PATH`.

### `net/http_client`

The native client is separate from the server namespace because its authority,
error, lifetime, and streaming contracts differ:

```gene
(import net/http_client [Http request stream])

(var response
  (await (request Http ^method "POST" ^url "https://example.test/api"
                  ^headers {^content-type "application/json"}
                  ^body "{}" ^timeout_ms 30000 ^max_bytes 4000000)))

(var transfer
  (stream Http ^url "https://example.test/events"
               ^channel_capacity 256 ^max_pending_bytes 1000000))
```

`request` returns `Task`; its value has `status`, normalized `headers`, `body`,
`effective_url`, `truncated`, and `headers_truncated`. Non-2xx HTTP statuses are
ordinary response data. Setup and transport failures fail the task.

Synchronous setup problems raise `HttpClientError` with a `^kind` prop:
`"unavailable"` means libcurl could not be loaded/initialized — the only case
a caller should treat as "fall back to another transport" — while `"usage"`
marks authority, argument, and option mistakes that must surface. Transport
failures after the transfer starts fail the returned task and do not carry
the `HttpClientError` type, so a fallback path can never replay a partially
consumed stream.

`stream` returns `{^task ^channel}`. The channel carries raw response chunks
and closes before the task settles. Native callbacks only copy bytes into
bounded shared buffers; channel delivery, SSE framing, and JSON parsing happen
on the scheduler thread. Cancelling the task aborts the transfer. URLs are
restricted to `http://` and `https://`, header newlines are rejected, and
libcurl's default peer/hostname verification is not disabled.

### `curses`

The POSIX terminal API uses an explicitly owned `Screen`:

```gene
(import curses [open close dimensions draw next_event])

(var screen (open))
(try
  (draw screen ^output "agent> ready" ^status "waiting" ^input "")
  (var size (dimensions screen))
  (var event (await (next_event screen)))
  ensure
    (close screen))
```

`open` requires a TTY and permits one live screen. `close` is idempotent and
restores terminal modes; callers should still use `ensure`. `draw` is a
non-variadic, color-coded full-screen renderer. `dimensions` returns
`{^rows ^cols}`. `next_event` returns a cancellable `Task` and reports text as
complete UTF-8 strings plus named enter, edit, navigation, paste-boundary,
modified-Enter, interrupt (Ctrl-C), EOF, and resize events. Scheduler polling
uses non-blocking `getch`, so waiting for a key does not stop other tasks. If
ordinary typing is already queued behind a standalone Escape when the scheduler
polls, the text byte is pushed back and delivered by the next event rather than
being consumed as an unknown escape sequence. While a `Screen` owns
the terminal, diagnostic console log sinks are paused to prevent out-of-band
stdout/stderr writes from corrupting the full-screen display; file and callback
sinks remain active.

`read_input` provides the shared multiline editor with bracketed-paste and
Unicode support. Its optional `^history` argument is a list of strings;
Up/Down replace the current input with the previous/next entry and restore the
draft after the newest entry. While input is active, the mouse wheel scrolls
the transcript by three lines and PageUp/PageDown by one viewport; a
`[SCROLL +N]` status prefix marks a view detached from the latest output.
Transcript text word-wraps into visual rows at the current terminal width, and
scrolling counts those wrapped rows. `refresh_input` redraws while retaining
screen ownership. `draw`, `read_input`, and `refresh_input` also accept
`^panes`, a list of
`{^title Str ^output Str ^scroll Int = 0 ^focused Bool = false
^maximized Bool = false}` maps; `draw`
additionally accepts a non-negative `^output_scroll` visual-row offset. Pane
scroll offsets use the same visual-row, live-tail-relative convention and a
scrolled pane marks its title with `[SCROLL +N]`. On terminals at least 48
columns wide, the primary transcript keeps the left side while panes are
stacked vertically on the right; input separators, input rows, and status keep
the full terminal width. A maximized pane occupies the full output region.
Narrow terminals show the focused pane full-width when one is focused, and
otherwise retain the primary transcript; hidden panes keep their state.
`escape_pressed?`
non-destructively checks a live screen for
a standalone Escape, preserving queued text and terminal escape sequences so a
caller can use it to cancel concurrent work.
Terminal failures raise `CursesError`. The older `os/read_input`,
`os/refresh_input`, and `os/close_input` names remain compatibility wrappers.

The `repl` namespace supports both a whole interactive session and incremental
controllers suitable for panes:

```gene
(import repl [open eval_source close])
(var session (open (env ^bindings {^answer 42})))
(try
  (eval_source session "(var x answer)")  # {^status "ok" ^text "42"}
  (eval_source session "(+ x 1)")         # {^status "ok" ^text "43"}
  ensure
    (close session))
```

`repl/open` creates an owned declaration-persistent evaluation scope.
`repl/eval_source` returns `{^status ^text}` with status `ok`, `incomplete`, `error`,
or `panic`; incomplete source is retained for the next call. `repl/close` is
idempotent. `repl/run` remains the blocking stdin/stdout session helper.

## Phase 1: Core Utility Modules

### `std/stream`

Current runtime already has most stream helpers as built-ins. The stdlib module
should export them under a stable namespace:

- `to_stream`
- `to_pairs_stream`
- `map`
- `filter`
- `take`
- `each`
- `into`
- `Stream/has_next`
- `Stream/peek`
- `Stream/next`
- `Stream/close`

Acceptance:

- `examples/web_demo.gene` imports `std/stream` successfully.
- Stream helpers remain lazy where they are lazy today.
- `each` consumes a stream for side effects and returns `nil`.

### `std/node`

Expose node anatomy and module introspection:

- `head`
- `props`
- `body`
- `meta`
- `declarations`

Acceptance:

- `this_mod/%declarations` returns declaration nodes as a stream.
- Route discovery can filter function declarations by `@route` metadata.

### `std/parse`

Initial parsing helpers:

- `parse_int : Str -> Int ^errors [ParseError]`
- `read_all : Str -> (Stream Any ParseError)`
- `ParseError` from the existing reader error family. Reader failures expose
  `source`, `line`, `col`, and `contexts`; each context records an opener,
  expected closer, and opening location. Numeric conversion failures may omit
  the location fields.

Acceptance:

- Invalid integer input is catchable as `ParseError`.
- Delimiter diagnostics retain machine-readable source locations and open-form
  context for the CLI, LSP, and programmatic consumers.
- `parse_int` rejects trailing junk unless a later API explicitly permits it.

### `str`

String utilities needed by HTML and HTTP:

- `join : (List Str), Str -> Str`
- `split : Str, Str -> (List Str)`
- `trim : Str -> Str`
- `lower : Str -> Str`
- `byte_size : Str -> Int` (UTF-8 bytes; allocation-free)
- `slice_bytes : Str, Int, Int -> Str` (bounded UTF-8-safe byte range)
- `starts_with? : Str, Str -> Bool`
- `ends_with? : Str, Str -> Bool`
- `contains? : Str, Str -> Bool`

Acceptance:

- `join` works as a send or normal callable in render pipelines:
  `(items ~ join "")`.
- Functions are allocation-conscious but correctness comes first for MVP.

## Phase 2: HTML and URL Modules

### `html`

HTML should remain ordinary Gene node data until render time.

Exports:

- `escape : Str -> Str`
- `attr_escape : Str -> Str`
- `render : Node|Str|Any -> Str`
- `render_node : Node -> Str`
- `doctype : Str`

Rules:

- Text content is escaped.
- Attribute values are escaped.
- `void` props are omitted.
- Boolean attrs can be modeled later; MVP renders explicit values only.
- Raw HTML is not supported by default. Add an explicit `Html/raw` type later if
  needed.

Acceptance:

- The demo renderer can move from app-local functions to `html/render`.
- XSS-sensitive escaping tests cover text, attributes, quotes, `<`, `>`, and
  `&`.

### `url`

Needed for request parsing and redirects:

- `encode_component`
- `decode_component ^errors [UrlError]`
- `parse_query : Str -> (Map Str Str) ^errors [UrlError]`
- `format_query : (Map Str Str) -> Str`
- `UrlError ^impl [Error]`

Acceptance:

- `Request/params` can be produced by the HTTP server wrapper.
- Malformed percent escapes are typed recoverable errors.

## Phase 3: HTTP Server MVP

### `net/http`

The server is single-process and cooperative: a non-blocking event loop on the
scheduler thread with task_per_request handler fibers (originally a blocking
accept loop; upgraded per `docs/proposals/async-http-server.md` Phase 1). The
API stays capability-shaped so richer backends can replace it.

Types:

```gene
(type Request
  ^props {^method Str
          ^path Str
          ^query Str
          ^params (Map Str Str)
          ^headers (Map Str Str)
          ^body Str})

(type Response
  ^props {^status Int
          ^headers? (Map Str Str)}
  ^body [Str])

(type Server
  ^props {^host Str ^port Int})

(type HttpError
  ^props {^message Str}
  ^impl [Error])
```

Functions:

- `serve : Server, Fn -> Nil ^errors [HttpError]`

`serve` runs a readiness-driven event loop with **task_per_request dispatch**
(the first slice of `docs/proposals/async-http-server.md`): each parsed
request runs the handler as a scheduler fiber settling a pending `Task`, so a
handler that `sleep`s/`await`s parks without stalling other connections.
Non-fiber callables fall back to an inline call. Connections are
`connection: close`; request parsing is incremental over non-blocking sockets.

Named arguments to `serve` (all optional):

- `^max_requests Int` — serve N connections then return (tests/embedding);
- `^max_connections Int` — accept cap; excess connections are shed (default 1024);
- `^max_in_flight Int` — concurrent dispatched handlers; excess answers the
  overload response (default 256);
- `^max_body_bytes Int` — declared request bodies beyond this answer
  `413 Payload Too Large`; negative disables the cap (default 10485760);
- `^request_timeout_ms Int` — overdue handlers answer `504 Gateway Timeout`
  and the still-running task is orphaned (default 30000);
- `^drain_timeout_ms Int` — graceful-stop drain window for in-flight
  requests after `(stop server)` (default 5000);
- `^overload_response Response` — what admission-limit rejections answer
  instead of the default `503 Service Unavailable` (rendered once at serve
  start, e.g. `(text 503 "busy")`);
- `^handler Fn` — the handler as a named argument instead of positional;
- `^routes List` — route table of `(route ^method ^path ^handler)` nodes or
  `[method path handler]` lists; unmatched requests answer 404 (mutually
  exclusive with a handler). Paths may contain `:name` segments — `/job/:id`
  captures the segment into `req/params` (a path capture wins over a
  same-named query key); first matching route wins;
- `^on_error Fn` — maps a handler's recoverable error value to a `Response`
  (panics and cancellations stay generic 500s);
- `^dispatch task_per_request | (actor_pool ...)` — dispatch mode;
  `(actor_pool ^workers N ^mailbox N ^init fn ^handle fn)` runs requests as
  `RequestMsg` values on a fixed worker-actor pool; full mailboxes answer the
  overload response (note: a bare symbol evaluates as a lookup, so quote the
  mode — `` ^dispatch `task_per_request ``);
- `^supervision (supervisor_policy ...)` — worker-pool supervision
  (actor_pool dispatch only): `` (supervisor_policy ^strategy `restart
  ^max_restarts 10 ^within_ms 60000 ^events chan ^dead_letter chan) ``.
  Strategy `restart` (default) rebuilds worker state with ^init under the
  restart budget; `stop` closes the failing worker. Worker failures emit
  `ActorFailure` values to `^events`/`^dead_letter` channels without
  blocking the failure path;
- `^access_log Fn` — called once per chosen response with an
  `(AccessLog ^method ^path ^status ^ms ^headers)` record; header values
  named by `^redact_headers` are replaced with `"[redacted]"` (defaults:
  authorization, cookie, set-cookie). A failing log fn goes to stderr and
  never breaks serving;
- `^error_log Fn` — called on handler errors/panics with an
  `(ErrorLog ^method ^path ^message ^panic)` record, before any ^on_error
  mapping; same never-break-serving contract;
- `^redact_headers List` — header names (case-insensitive) whose values
  never reach access_log records.

Stalled request reads answer `408 Request Timeout`; malformed requests and
oversized headers answer `400 Bad Request` as before.
- `Response : ^status Int, Str -> Response`
- `text : Str -> Response`
- `html : Str -> Response`
- `json : Str -> Response`
- `redirect : Str -> Response`
- `not_found : Str -> Response`
- `header : Response, Str, Str -> Response`
- `set_cookie : Response, Str, Str -> Response`
- `cookie : Request, Str -> Str|Nil`
- `static_file : Str -> Fn`

Runtime integration:

- `gene run` should continue to call ordinary CLI `main` as today.
- A separate host launcher or command can inject `Http/Server` and `Io/Write`
  capabilities into a web entrypoint. Do not overload normal `gene run` until
  capability invocation is designed.

Acceptance:

- A demo app can listen on localhost, route by `Request/path`, and return HTML.
- Request query params populate `Request/params`.
- Request cookies are readable and response cookies can be set.
- Static files can be served from an explicitly provided directory.
- Static file serving rejects `..` traversal and never serves outside that
  directory.
- Handler failures produce a 500 response during MVP, with stderr diagnostics.
- Server shutdown can be process-level for MVP.

## Phase 4: SQLite MVP

### `sqlite`

SQLite should be the first database backend because it is local, easy to test,
and fits a single-binary story. Implementation may use a native module or FFI
binding over `sqlite3`.

Types:

```gene
(type Database)
(type Statement)
(type Row)

(type SqliteError
  ^props {^message Str ^code Int}
  ^impl [Error])
```

Functions:

- `open : Str -> Database ^errors [SqliteError]`
- `close : Database -> Nil ^errors [SqliteError]`
- `exec : Database, Str -> Nil ^errors [SqliteError]`
- `prepare : Database, Str -> Statement ^errors [SqliteError]`
- `query : Database, Str, params... -> (List Row) ^errors [SqliteError]`
- `query_one : Database, Str, params... -> Row|Nil ^errors [SqliteError]`
- `execute : Database, Str, params... -> Int ^errors [SqliteError]`
- `transaction : Database, Fn -> Any ^errors [SqliteError]`
- `Row/get : Row, Str -> Any`
- `Row/to_map : Row -> Map`

Parameter binding:

- Support `Nil`, `Bool`, `Int`, `Float`, `Str`, and binary buffers if available.
- Positional parameters are enough for MVP: `?`, `?1`, `?2`.
- Named parameters can be added later.

Row conversion:

- SQLite integer -> `Int`
- SQLite float -> `Float`
- SQLite text -> `Str`
- SQLite null -> `nil`
- SQLite blob -> `Buffer U8` when practical; otherwise defer blobs.

Safety:

- Prepared statements are finalized.
- Database handles are closed explicitly and eventually by runtime cleanup.
- `transaction` rolls back on recoverable error or panic, commits on normal
  return.
- SQL syntax and constraint failures become `SqliteError`.

Acceptance:

- Create schema, insert rows, list rows, fetch one row, update/delete rows.
- SQL injection-safe parameter binding is covered by tests.
- Transaction rollback test proves failed insert does not persist.
- Multiple tests can open independent temp databases without global state leaks.

## Phase 5: Web App Convenience Layer

This phase should be small and optional; the low-level modules above must remain
usable directly.

### `web/router`

- `route : Str, Fn -> Route`
- `router : (List Route) -> Fn`
- `not_found`
- path params can wait; exact path matching is enough for MVP.

### `web/session`

Defer unless the first app needs login. If included:

- signed cookie sessions only;
- no encryption in MVP;
- explicit secret capability/config.

### `web/form`

- parse URL-encoded form body;
- basic field validation helpers;
- typed errors for malformed form input.

Acceptance:

- A CRUD app can be written with less boilerplate than raw `net/http`.
- Convenience layer does not hide `Request`, `Response`, or database handles.

## Reference App Target

The stdlib is sufficient when this app can be implemented without local stubs:

```gene
(import net/http [Request Response Server serve redirect])
(import html [render])
(import sqlite [open exec query execute transaction])
(import std/parse [parse_int ParseError])

(fn init_db [db]
  (exec db "create table if not exists notes (id integer primary key, text text not null)"))

(fn list_notes [db req]
  (var rows (query db "select id, text from notes order by id desc"))
  (Response ^status 200 (render `(html (body ...)))))

(fn create_note [db req]
  (execute db "insert into notes(text) values (?)" req/params/text)
  (redirect "/"))

(fn main [args : (List Str)] : Int
  (var db (open "app.db"))
  (init_db db)
  (serve (Server ^host "127.0.0.1" ^port 8080)
    (fn [req]
      (match req/path
        (when "/" (list_notes db req))
        (when "/notes" (create_note db req))
        (else (Response ^status 404 "not found")))))
  0)
```

The exact syntax can change as capability injection evolves, but the required
library behavior is fixed by this target.

## Implementation Order

1. Register stdlib namespaces for existing built-ins:
   `std/stream`, `std/node`, `std/parse`.
2. Add `str/join`, `str/split`, and `html/escape`.
3. Move app-local HTML rendering from `web_demo.gene` into `html`.
4. Add `url` query parsing and wire it into `Request/params`.
5. Add blocking `net/http` server capability and response helpers.
6. Add SQLite native binding with open/close/exec/query/execute.
7. Add transactions and prepared statement cleanup.
8. Build a minimal SQLite-backed CRUD example.
9. Add `web/router` only after the raw app works.

## Testing Strategy

- Unit tests for every pure helper.
- Spec tests for import surface and documented examples.
- Integration tests using temp directories and temp SQLite files.
- HTTP tests should bind to localhost on an ephemeral port.
- Database tests must not require network access or global state.
- Leak tests should cover database/statement close paths once handles are native
  resources.

## Open Design Questions

- Should stdlib modules be built-in namespaces first, file-backed Gene modules,
  or a hybrid where native functions are injected into file modules?
- Should web entrypoints use ordinary `main [args]` plus explicit construction,
  or a separate capability-injected command?
- Should SQLite rows be maps, row objects, or both?
- How should native resource finalization interact with the planned arena /
  reclamation work?
- Do `str` function names use underscores (`starts_with?`) or hyphens
  (`starts-with?`)? Pick one convention before broad stdlib expansion.
