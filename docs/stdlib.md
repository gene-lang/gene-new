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
  `^max-requests` for tests) — implemented; `examples/todo_app.gene` is the
  end-to-end proof (HTML page + JSON API). Deviations from this plan: response
  construction uses helpers or `(Response ^status N ^body s)` because type
  constructors take named fields only; `cookie`/`set_cookie`/`static_file` are
  not implemented yet.
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
- A production async HTTP stack with TLS and HTTP/2.
- ORM/query builder abstraction over SQL.
- Browser client framework or reactive frontend runtime.
- Cross-database compatibility.

## Module Layout

Initial modules should be available through namespace imports:

```gene
(import std/stream [to_stream to_pairs_stream map filter take each into])
(import std/node [head props body meta declarations])
(import std/parse [parse_int ParseError])
(import str [join split starts_with? ends_with? trim])
(import html [escape render])
(import net/http [Request Response Server serve redirect])
(import sqlite [Database Statement Row SqliteError])
```

For MVP, these may be built-in namespaces registered by the runtime. File-backed
stdlib modules can replace or wrap those namespaces later, but source programs
should not need to change.

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

- `this-mod/%declarations` returns declaration nodes as a stream.
- Route discovery can filter function declarations by `@route` metadata.

### `std/parse`

Initial parsing helpers:

- `parse_int : Str -> Int ^errors [ParseError]`
- `ParseError` from the existing reader error family.

Acceptance:

- Invalid integer input is catchable as `ParseError`.
- `parse_int` rejects trailing junk unless a later API explicitly permits it.

### `str`

String utilities needed by HTML and HTTP:

- `join : (List Str), Str -> Str`
- `split : Str, Str -> (List Str)`
- `trim : Str -> Str`
- `lower : Str -> Str`
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
scheduler thread with task-per-request handler fibers (originally a blocking
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

`serve` runs a readiness-driven event loop with **task-per-request dispatch**
(the first slice of `docs/proposals/async-http-server.md`): each parsed
request runs the handler as a scheduler fiber settling a pending `Task`, so a
handler that `sleep`s/`await`s parks without stalling other connections.
Non-fiber callables fall back to an inline call. Connections are
`connection: close`; request parsing is incremental over non-blocking sockets.

Named arguments to `serve` (all optional):

- `^max-requests Int` — serve N connections then return (tests/embedding);
- `^max-connections Int` — accept cap; excess connections are shed (default 1024);
- `^max-in-flight Int` — concurrent dispatched handlers; excess answers the
  overload response (default 256);
- `^max-body-bytes Int` — declared request bodies beyond this answer
  `413 Payload Too Large`; negative disables the cap (default 10485760);
- `^request-timeout-ms Int` — overdue handlers answer `504 Gateway Timeout`
  and the still-running task is orphaned (default 30000);
- `^drain-timeout-ms Int` — graceful-stop drain window for in-flight
  requests after `(stop server)` (default 5000);
- `^overload-response Response` — what admission-limit rejections answer
  instead of the default `503 Service Unavailable` (rendered once at serve
  start, e.g. `(text 503 "busy")`);
- `^handler Fn` — the handler as a named argument instead of positional;
- `^routes List` — route table of `(route ^method ^path ^handler)` nodes or
  `[method path handler]` lists; unmatched requests answer 404 (mutually
  exclusive with a handler);
- `^on-error Fn` — maps a handler's recoverable error value to a `Response`
  (panics and cancellations stay generic 500s);
- `^dispatch task-per-request | (actor-pool ...)` — dispatch mode;
  `(actor-pool ^workers N ^mailbox N ^init fn ^handle fn)` runs requests as
  `RequestMsg` values on a fixed worker-actor pool; full mailboxes answer the
  overload response (note: a bare symbol evaluates as a lookup, so quote the
  mode — `` ^dispatch `task-per-request ``);
- `^supervision (supervisor-policy ...)` — worker-pool supervision
  (actor-pool dispatch only): `` (supervisor-policy ^strategy `restart
  ^max-restarts 10 ^within-ms 60000 ^events chan ^dead-letter chan) ``.
  Strategy `restart` (default) rebuilds worker state with ^init under the
  restart budget; `stop` closes the failing worker. Worker failures emit
  `ActorFailure` values to `^events`/`^dead-letter` channels without
  blocking the failure path.

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
