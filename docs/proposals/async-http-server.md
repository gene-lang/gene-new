# Gene Async HTTP Server Design

**Status:** Phases 1–2 (§21) implemented — event-loop serve, task_per_request
dispatch, bounded admission (`^max_connections`, `^max_in_flight`,
`^max_body_bytes` → 413, `^request_timeout_ms` → 504, `^overload_response`),
status metrics; actor_pool dispatch with native-created `ReplyTo` (double send
raises `ReplyAlreadySent`), mailbox overload → overload response,
`^supervision (supervisor_policy ^strategy ^max_restarts ^within_ms ^events
^dead_letter)` with restart rate limiting (§18.5); Phase 3 complete
(`^routes` table with `:param` path captures into `req/params`, `^on_error`
mapper, `^access_log`/`^error_log`/`^redact_headers` §17, meta-based route
discovery §8 — declaration records carry source `@meta` as node meta and a
`^value` prop, so the §8 pattern works as user code with `d/value` instead of
the Namespace/lookup dance). Remaining: Phase 4 WebSocket, Phase 5 hardening.
See `src/gene/http_server.nim` and `docs/stdlib.md`.  
**Scope:** native async HTTP and WebSocket server for Gene applications  
**Primary namespace:** `net/http`  
**Goal:** support high-concurrency native HTTP I/O while keeping Gene request handlers simple, synchronous when possible, and isolated through tasks and actors.

---

## 1. Thesis

Gene should use a **native async HTTP edge** and a **Gene concurrency core**.

The default request path should be:

```text
native async socket/server runtime
  -> accepts connections and parses HTTP concurrently
  -> converts each request into an immutable Send value
  -> admits the request under bounded limits
  -> runs one Gene task per accepted request
  -> the task calls an ordinary Gene handler
  -> handler uses actors for shared/session/serialized state
  -> native runtime writes the response asynchronously
```

Actors remain central, but they should not be the only request dispatch mechanism. A fixed actor worker pool is useful for stateful or CPU-bound serialized routes, but it caps request concurrency at the number of workers and can cause head-of-line blocking if handlers await I/O. Therefore:

```text
task_per_request is the default dispatch model
actor_pool dispatch is explicit and deliberate
```

This follows the best lessons from Erlang/Elixir and Akka:

- cheap concurrent execution units for request-level concurrency;
- actors/processes for isolated state and message passing;
- bounded queues and admission limits for backpressure;
- supervision and failure events for resilience;
- no shared mutable state by default.

---

## 2. Relationship to `net/http`

The async server should **evolve the canonical `net/http` namespace**, not fork a parallel HTTP vocabulary.

Existing or early `net/http` APIs such as:

```gene
(import net/http ^as Http)

(Http/serve server handler)
(Http/text "hello")
```

should remain the compatibility path where practical. The native async implementation should become a backend for `net/http`, while preserving a migration path for older simple/blocking helpers.

Recommended direction:

```gene
(import net/http ^as Http)
```

Long-term public API:

```gene
(server ~ Http/serve ^handler handle_request)
(server ~ Http/start ^handler handle_request)
(server ~ Http/stop)
(server ~ Http/status)
```

`Http/Server`, `Http/Request`, `Http/Response`, `Http/Headers`, WebSocket types, and helper constructors should live in `net/http`. If an experimental namespace is needed during transition, use something explicit such as `net/http/async`, then converge back to `net/http`.

### Compatibility note

If the current stdlib has a simple `Response` shape such as string body helpers, keep those as ergonomic constructors and normalize internally to the lower-level response representation:

```gene
(Http/text 200 "hello")   # builds Response with Bytes body and text/plain header
(Http/json 200 value)
(Http/html 200 node)
(Http/bytes 200 bytes)
```

The existing locked `net/http` surface (see `tests/spec_runner.nim`, "net/http
surface from stdlib plan") defines these helpers with implicit statuses:
`text : Str -> Response` (200), `redirect : Str -> Response` (302), etc. The
status-first forms above are **arity overloads of the same names in the same
namespace**, not replacements:

```text
(Http/text "hello")        # 1-arg: implicit 200 — unchanged, spec-locked
(Http/text 200 "hello")    # 2-arg: explicit status-first
(Http/redirect "/x")       # 1-arg: implicit 302 — unchanged, spec-locked
(Http/redirect 302 "/x")   # 2-arg: explicit status-first
```

The 1-arg behaviors must not change; `nimble spec` enforces them.

---

## 3. Capability model

Starting a listener is authority. Gene should not expose ambient network bind authority.

Preferred forms:

```gene
(fn main [args : (List Str), ^server : Http/Server] : Int
  (server ~ Http/serve
    ^handler handle_request)
  0)
```

or, when the application creates the listener:

```gene
(fn main [args : (List Str), ^net : Net/Listen] : Int
  (var server
    (Http/listen net
      ^host "0.0.0.0"
      ^port 8080))

  (server ~ Http/serve
    ^handler handle_request)

  0)
```

Rules:

```text
Net/Listen      authority to bind/listen on network addresses
Http/Server     authority to accept requests on one listener
Http/Running    authority/handle for a running background server
```

`Http/serve ^host ... ^port ...` without an explicit capability should be a convenience only in trusted scripts or tests, not the core runtime model.

---

## 4. Layered architecture

```text
Application
  └── net/http server runtime
        ├── listener group
        │     ├── accept loop(s)
        │     ├── TLS handshake, if enabled
        │     └── socket registration
        │
        ├── connection tasks / native state machines
        │     ├── read buffers
        │     ├── HTTP parser
        │     ├── request body reader
        │     ├── WebSocket frame parser
        │     └── response writer
        │
        ├── bounded admission
        │     ├── max connections
        │     ├── max in-flight requests
        │     ├── max body bytes
        │     ├── request timeout
        │     └── overload response
        │
        ├── dispatcher
        │     ├── route lookup
        │     ├── task_per_request dispatch
        │     ├── optional actor_pool dispatch
        │     └── status/metrics
        │
        └── Gene application layer
              ├── request tasks
              ├── actors for shared state
              ├── optional request worker pools
              └── supervisors/failure channels
```

The native runtime owns raw sockets and buffers. Gene code receives immutable, typed request values and returns typed response values.

---

## 5. Dispatch models

### 5.1 Task-per-request: default

Each accepted request runs in its own Gene task.

```gene
(server ~ Http/serve
  ^dispatch task_per_request
  ^max_in_flight 5000
  ^request_timeout_ms 30000
  ^handler handle_request)
```

Handler shape:

```gene
(fn handle_request [req : Http/Request] : Http/Response
  (match [req/method req/path]
    (when ["GET" "/"]
      (Http/text 200 "hello"))

    (else
      (Http/text 404 "not found"))))
```

Properties:

```text
- high concurrency;
- awaiting DB/network/file I/O suspends only that request task;
- shared state must go through actors, channels, or explicit thread-safe handles;
- bounded admission limits prevent unbounded task growth.
```

This is the recommended default for web applications.

### 5.2 Actor-pool dispatch: explicit serialized worker pool

A fixed actor pool is useful when handlers must own private state, serialize access, or run CPU-heavy work with bounded parallelism.

```gene
(server ~ Http/serve
  ^dispatch (actor_pool
    ^workers 8
    ^mailbox 1024
    ^init make_worker_state
    ^handle request_worker))
```

Properties:

```text
- exactly one message is handled at a time per worker actor;
- effective request handler concurrency is capped by ^workers;
- awaiting inside a worker handler suspends that actor and its mailbox;
- use for deliberately serialized/stateful work, not as the default for all requests.
```

Actor-pool request message:

```gene
(type RequestMsg
  ^props {
    ^req   Request
    ^reply (ReplyTo Response)
  }
  ^impl [Send])
```

Qualified as `Http/RequestMsg` when imported through `net/http`.

Handler shape:

```gene
(fn request_worker
  [ctx : (ActorContext Http/RequestMsg),
   state : AppState,
   msg : Http/RequestMsg]
  : (ActorStep AppState)

  (match msg
    (when (Http/RequestMsg ^req req ^reply reply)
      (try
        (reply ~ ReplyTo/send (route req state))
      catch e
        (reply ~ ReplyTo/send
          (Http/text 500 "internal server error")))
      (actor/continue state))))
```

Guideline:

```text
Actor-pool handlers should avoid long awaits. If a handler needs asynchronous work, spawn a task or delegate to another actor and arrange a later reply.
```

### 5.3 Route-specific dispatch

Later, routes may choose dispatch explicitly:

```gene
(server ~ Http/serve_routes
  ^routes [
    (route ^method "GET"  ^path "/"       ^handler home)
    (route ^method "POST" ^path "/state"  ^dispatch stateful_pool ^handler update_state)
    (route ^method "GET"  ^path "/report" ^dispatch cpu_pool      ^handler report)
  ])
```

This lets most routes use task_per_request while a few routes use actors for serialized state.

---

## 6. Core HTTP types

Inside the `net/http` module, declare unqualified names such as `Request`, `Response`, and `Headers`; user code sees them as `Http/Request`, `Http/Response`, etc. when importing with `^as Http`.

### 6.1 Request

```gene
(type Request
  ^props {
    ^id          Str
    ^method      Str
    ^path        Str
    ^query       PropMap
    ^params      PropMap
    ^headers     Headers
    ^body        Bytes
    ^remote_addr Str
    ^scheme      Str
  }
  ^impl [Send])
```

Request values should be immutable or otherwise sendable before crossing task/actor boundaries.

### 6.2 Response

```gene
(type Response
  ^props {
    ^status  Int
    ^headers Headers
    ^body    Bytes
  }
  ^impl [Send])
```

Helper constructors:

```gene
(Http/response ^status 200 ^headers headers ^body bytes)
(Http/text 200 "hello")
(Http/json 200 value)
(Http/html 200 node)
(Http/bytes 200 bytes)
(Http/redirect 302 "/login")
```

### 6.3 Headers

HTTP headers are not a plain `Map Str Str` semantically, because repeated headers are valid and lookup is case-insensitive.

MVP representation:

```gene
(type Header
  ^props {^name Str ^value Str}
  ^impl [Send])

(type Headers
  ^is #[Header...])   # frozen list of zero or more Header values
```

`Headers` values must be **frozen lists** (`#[...]`). A mutable `(List Header)`
is not sendable (design §13.3), so declaring `^impl [Send]` on a mutable-list
alias would assert something false of its values; frozen lists derive `Send`
from their (sendable) elements. The native runtime constructs header lists
frozen, and `with_header` returns a new frozen list.

Semantics:

```text
- header lookup is case-insensitive;
- original casing may be preserved;
- repeated headers are allowed;
- helpers provide first/all lookup;
- header lists are immutable; "modification" builds a new frozen list.
```

Helpers:

```gene
(headers ~ Http/header "content-type")   # first value or void
(headers ~ Http/headers "set-cookie")    # list/stream of all values
(headers ~ Http/with_header "cache-control" "no-store")
```

---

## 7. Handler APIs

### 7.1 Direct handler

```gene
(fn handle [req : Http/Request] : Http/Response
  ...)
```

May raise typed recoverable errors. The server converts unhandled errors according to policy.

```gene
(fn handle [req : Http/Request] : Http/Response
  ^errors [AppError]
  ...)
```

### 7.2 Handler with application state

For shared state, pass an immutable state bundle containing actor references or thread-safe native handles:

```gene
(type App
  ^props {
    ^users (ActorRef UserMsg)
    ^db    Db/Pool
  }
  ^impl [Send])

(fn handle [req : Http/Request, app : App] : Http/Response
  (var user
    (await
      (app/users ~ actor/ask
        (fn [reply]
          (GetUser ^id req/params/id ^reply reply)))))

  (Http/json 200 user))
```

The request task can await. Shared mutable state stays behind actors or explicit thread-safe handles.

`^handler` expects `Http/Request -> Http/Response`, so a stateful handler is
wired by closure capture — safe here because `App` is `Send` and closures are
sendable when all captured values are (design §13.3):

```gene
(var app (App ^users users ^db db_pool))

(server ~ Http/serve
  ^handler (fn [req] (handle req app)))
```

### 7.3 Route table

Prefer extensible route nodes over positional tuples:

```gene
#[
  (route ^method "GET"  ^path "/"        ^handler home)
  (route ^method "GET"  ^path "/health"  ^handler health)
  (route ^method "POST" ^path "/users"   ^handler create_user)
]
```

Short tuple route entries may be accepted as convenience:

```gene
#[
  ["GET" "/" home]
  ["GET" "/health" health]
]
```

The canonical route_entry shape should be the node form.

---

## 8. Meta-based route discovery

Gene can discover routes through module declarations and meta:

```gene
(fn home [req : Http/Request]
  @route (route ^method "GET" ^path "/")
  (Http/html 200 `(html (body "home"))))
```

Router construction:

```gene
(fn routed? [decl]
  (not (= decl/%meta/route void)))

(fn route_entry [ns decl]
  (var r decl/%meta/route)
  (route
    ^method  r/method
    ^path    r/path
    ^handler (ns ~ Namespace/lookup decl/0)))

(var app_ns (this_mod ~ Module/root_namespace))

(var routes
  (this_mod/%declarations
    ~ filter routed?
    ; ~ map (fn [decl] (route_entry app_ns decl))
    ; ~ into #[]))
```

Notes:

- node meta is reached through the `%meta` selector stage (or the `(meta x)`
  projection); a bare `decl/meta` segment is a static lookup of a *prop named*
  `meta` and always misses (design §5);
- **as implemented** (design §15.7): declaration records are
  `(Declaration ^name Str ^kind Str ^value Any)` nodes carrying the source
  form's `@meta` as node meta — so the handler is simply `decl/value` and the
  route data is `decl/%meta/route`; no `Namespace/lookup` resolution step is
  needed.

This uses existing module introspection and selectors rather than a separate query subsystem.

---

## 9. Backpressure and overload

Every queue must be bounded.

Recommended limits:

```gene
(server ~ Http/serve
  ^max_connections 10000
  ^max_in_flight 5000
  ^max_body_bytes 10485760
  ^request_timeout_ms 30000
  ^overload_response (Http/text 503 "busy")
  ^handler handle)
```

Backpressure points:

| Boundary | Limit | Failure behavior |
|---|---:|---|
| accepted sockets | `^max_connections` | refuse/close connection |
| in-flight requests | `^max_in_flight` | 503 / overload response |
| request body | `^max_body_bytes` | 413 Payload Too Large |
| task dispatch | scheduler/admission limit | 503 / overload response |
| actor pool mailbox | `^mailbox` | immediate 503 by default |
| response write buffer | per-connection write limit | close slow client |

For MVP actor_pool overload, prefer immediate `actor/try_send` failure -> 503. Timed actor send is optional future runtime surface, not required for the first server.

---

## 10. Request/reply and cancellation

The native server must be able to create a one-shot reply capability:

```text
native request state -> ReplyTo Http/Response
```

This is the same semantic capability as `actor/ask`, but constructed by the server runtime.

Rules:

```text
- ReplyTo is single-use.
- sending after reply was already sent raises `ReplyAlreadySent` (§18.2);
- if the client disconnects, the reply capability is closed;
- sending to a closed reply raises PendingReplyClosed;
- if request cancellation and PendingReplyClosed both apply, cancellation wins;
- response writing occurs in the native server, not inside the actor/task handler.
```

A task_per_request handler returns a response directly. An actor_pool handler replies through `ReplyTo`.

Timeout behavior:

```text
handler returns response          -> write response
handler raises recoverable error  -> error policy / 500 / supervisor event
handler panics                    -> panic policy / escalate
handler timeout                   -> 504 Gateway Timeout
client disconnects                -> cancel request task or close ReplyTo
mailbox full                      -> 503 Service Unavailable
server shutdown                   -> stop accepting, drain or cancel in-flight work
```

---

## 11. Error taxonomy

Application errors should be explicit values where possible:

```gene
(type NotFound
  ^props {^path Str}
  ^impl [Error])
```

Server-level policy:

```text
domain error converted by handler       -> chosen response
unhandled recoverable Error             -> 500 + failure event
panic                                   -> escalate / terminate component
native crash or memory corruption       -> process-fatal
client disconnect                       -> cancellation / PendingReplyClosed
request timeout                         -> 504 + cancellation
```

A default error mapper can be supplied:

```gene
(server ~ Http/serve
  ^handler handle
  ^on_error error_to_response)
```

Example:

```gene
(fn error_to_response [err : Error] : Http/Response
  (match err
    (when (NotFound ^path p)
      (Http/text 404 $"not found: ${p}"))
    (else
      (Http/text 500 "internal server error"))))
```

---

## 12. Supervision and observability

The server should own a supervisor scope for its runtime tasks and optional actor pools.

The `supervisor` form in design §13.6 is a *scope form* that wraps a body of
actor spawns; it is not a value. Server configuration therefore passes a
**policy value**, and the server runtime applies it to the supervisor scope it
creates internally:

```gene
(server ~ Http/serve
  ^supervision (supervisor_policy
    ^strategy restart
    ^max_restarts 10
    ^within_ms 60000
    ^events failures
    ^dead_letter dead)
  ^handler handle)
```

Recommended failure event (declared unqualified inside `net/http`, seen as
`Http/Failure` by importers, per §6):

```gene
(type Failure
  ^props {
    ^where     Sym
    ^request?  Request
    ^message   Str
    ^error?    Error
    ^panic     Bool
  }
  ^impl [Send])
```

Status snapshot:

```gene
(var status (server ~ Http/status))

status/active_requests
status/queued_requests
status/overloaded_requests
status/timeouts
status/connections
status/workers
```

Use slash selectors, not dot access.

The native server may inspect its own dispatch structures and actor pools for diagnostics. This is server-owned introspection; it does not expose raw actor mailboxes generally.

---

## 13. Body streaming

Small request bodies may be materialized as `Bytes`.

Large bodies should use streams. `Request` declares `^body Bytes` for MVP
(§6.1); a prop cannot be two types at once, so streaming widens the prop in a
later phase:

```gene
^body (| Bytes (Stream Bytes Http/BodyError))   # Phase 5 widening
```

Handlers that need not care can call a `(Http/body-bytes req)` helper that
materializes either representation (subject to `^max_body_bytes`).

Rules:

```text
- body streams are pull-based;
- unread bodies are drained or closed according to keep-alive policy;
- server enforces max body bytes;
- closing/cancelling a request closes the body stream;
- upload parsing errors are typed Http/BodyError values.
```

For MVP, materialized `Bytes` with strict size limits is acceptable. Body streams are required for production-grade uploads, SSE, and proxying.

---

## 14. WebSocket design

WebSocket connections are long-lived and stateful. Model them with opaque connection refs and session actors.

WebSocket types live in a `ws` namespace nested inside `net/http`
(`net/http/ws`); declarations below are unqualified inside that module and are
seen as `Ws/ConnRef` etc. after `(import net/http/ws ^as Ws)`:

```gene
(type ConnRef
  ^impl [Send])
```

`ConnRef` is not a raw socket. It is an opaque command target owned by the native server.

Messages:

```gene
(type Open
  ^props {^conn ConnRef ^req Http/Request}
  ^impl [Send])

(type Frame
  ^props {^conn ConnRef ^data Bytes ^kind Sym}
  ^impl [Send])

(type Closed
  ^props {^conn ConnRef ^reason Str}
  ^impl [Send])
```

Commands:

```gene
(conn ~ Ws/send_text "hello")
(conn ~ Ws/send_bytes bytes)
(conn ~ Ws/close ^code 1000 ^reason "bye")
```

Architecture:

```text
native WebSocket parser
  -> frame messages to session actor or sharded actor pool
  -> actor updates session state synchronously
  -> actor issues Ws commands
  -> native server writes frames asynchronously
```

For per-connection state, spawn one session actor per WebSocket. For very high fanout, shard by connection id.

---

## 15. Server lifetime

### 15.1 Blocking serve

```gene
(server ~ Http/serve ^handler handle)
```

Runs until stopped, cancelled, or failed. Owned by the current scope.

### 15.2 Background start

```gene
(var running
  (server ~ Http/start ^handler handle))

(running ~ Http/stop)
```

`Http/start` returns an `Http/Running` handle. Because it creates tasks/actors that outlive the caller’s immediate expression, it must have an explicit owner:

```text
- application root scope; or
- supplied supervisor/scope; or
- returned Running handle requiring explicit stop.
```

`Http/start` must not silently detach unowned tasks.

---

## 16. State and database access

Per-request state should be immutable or task-local.

Shared application state should be behind actors or explicitly thread-safe native handles:

```gene
(type App
  ^props {
    ^users (ActorRef UserMsg)
    ^db    Db/Pool
  }
  ^impl [Send])
```

If using an actor pool with per-worker state, avoid opening a separate DB pool in every worker unless intended. Prefer:

```gene
(var db_pool (Db/open_pool config))

(server ~ Http/serve
  ^dispatch (actor_pool
    ^workers 8
    ^init (fn [] (WorkerState ^db db_pool))
    ^handle worker_handle))
```

`Db/Pool` must be a thread-safe/sendable native handle by construction.

Blocking database APIs should not block HTTP event-loop threads. They should be async-aware, run in a dedicated native pool, or be wrapped by a DB actor/task pool.

---

## 17. Security and logging

Defaults:

```text
- redact request bodies from logs;
- redact Authorization, Cookie, Set-Cookie, and configured secret headers;
- enforce max header size and max body size;
- reject malformed requests with 400;
- do not expose panic details to clients in production mode;
- expose structured diagnostics through status and failure events.
```

Logging hook:

```gene
(server ~ Http/serve
  ^access_log access_log
  ^error_log error_log
  ^redact_headers #["authorization" "cookie" "set-cookie"]
  ^handler handle)
```

---

## 18. Required runtime additions

This server design uses current Gene features plus a small set of explicit runtime additions.

### 18.1 Native-created `ReplyTo`

The HTTP runtime needs to construct one-shot reply capabilities for request/response bridging.

### 18.2 Pending reply closure

`PendingReplyClosed` and its cancellation precedence are **already settled** in
design §13.1.1; this proposal adopts those semantics for server-created replies
rather than adding them:

```text
client disconnect closes reply
send to closed reply raises PendingReplyClosed
request cancellation wins over PendingReplyClosed when both apply
```

The genuinely new name introduced here (§10) is `ReplyAlreadySent` — the
programming error raised by a second send on a single-use reply. Design §13.5
declares `ReplyTo` single-use without naming the double-send error; this
proposal names it.

### 18.3 Bounded admission counters

The server runtime needs first-class admission controls and status metrics:

```text
max_connections
max_in_flight
max_body_bytes
request_timeout_ms
overload counters
active/queued counts
```

### 18.4 Server-owned pool introspection

If actor_pool dispatch is enabled, the server may inspect its own pool queue depths for status and load balancing. This does not expose general actor mailbox introspection to user code.

### 18.5 Supervisor restart rate limiting

Add restart policy fields:

```gene
^max_restarts 10
^within_ms 60000
```

### 18.6 Optional future timed send

MVP can use immediate `try_send` for overload behavior. Timed send is optional future runtime surface:

```gene
(actor/send ref msg ^timeout_ms 5)
```

Do not require timed send for the first async HTTP implementation.

---

## 19. Native implementation boundary

The native HTTP extension should expose safe Gene values and not leak native internals.

Native owns:

```text
socket fd/handle
TLS context
HTTP parser state
write buffers
connection lifecycle
kernel event registration
```

Gene owns:

```text
request tasks
route handlers
application actors
response construction
supervision policy
```

Foreign threads may interact with Gene only through runtime attachment and rooted send/call APIs. Native code must root Gene values that outlive the call that created them.

---

## 20. Build and distribution

A native HTTP Gene application should build cleanly as a standalone executable:

```bash
gene build . -o my-server --mode mixed --sealed
```

The executable may contain:

```text
Gene runtime / VM
net/http native extension
compiled GIR application image
optional native-compiled typed functions
resources/templates/static files
```

The app image remains the canonical deployable program representation. The standalone executable is a launcher plus runtime plus embedded image.

---

## 21. Implementation plan

### Phase 1: task_per_request HTTP

- `Http/Server` capability/listener.
- Native accept/read/write loop.
- Materialized `Http/Request` with `Bytes` body and limits.
- `Http/Response` and helper constructors.
- `Http/serve` with `^dispatch task_per_request`.
- Bounded admission and overload responses.
- Basic status metrics.

Capability delivery: capability injection into `main` is not yet designed
(`docs/stdlib.md`: "Do not overload normal `gene run` until capability
invocation is designed"). Phase 1 therefore ships with the §3 trusted-script
convenience form (`Http/listen ^host ... ^port ...` constructing its own
capability), and switches `main` to injected `Net/Listen`/`Http/Server` values
once the launcher mechanism exists. The API shape does not change — only who
constructs the capability.

### Phase 2: actor_pool dispatch

- `Http/RequestMsg` and native-created `ReplyTo`.
- Explicit actor_pool dispatch mode.
- Bounded actor mailboxes.
- Failure events and dead-letter support.
- Supervisor restart limits.

### Phase 3: route framework

- Route node table.
- Method/path matching.
- Meta-based route discovery from `this_mod/%declarations`.
- Error mapper.
- Access/error logging with redaction.

### Phase 4: WebSocket

- Upgrade support.
- Opaque `Ws/ConnRef`.
- Session actor helpers.
- Frame parsing/writing.
- Connection close/cancellation semantics.

### Phase 5: production hardening

- TLS configuration.
- Streaming bodies.
- Slow-client write backpressure.
- Graceful shutdown/drain.
- Native extension ABI hardening.
- Standalone executable integration.

---

## 22. Recommended default

For most applications:

```gene
(import net/http ^as Http)

(fn handle [req : Http/Request] : Http/Response
  (match [req/method req/path]
    (when ["GET" "/"]
      (Http/text 200 "hello"))
    (else
      (Http/text 404 "not found"))))

(fn main [args : (List Str), ^net : Net/Listen] : Int
  (var server
    (Http/listen net ^host "0.0.0.0" ^port 8080))

  (server ~ Http/serve
    ^dispatch task_per_request
    ^max_in_flight 5000
    ^request_timeout_ms 30000
    ^handler handle)

  0)
```

Use actor_pool dispatch only when the route deliberately needs serialized actor-owned state or bounded CPU concurrency.

---

## 23. Summary

The accepted architecture should be:

```text
native async HTTP edge
+ bounded admission
+ task_per_request default
+ actors for shared/session/serialized state
+ explicit actor_pool dispatch when desired
+ capability-shaped server/listener API
+ net/http as the canonical namespace
+ native-created ReplyTo for bridging to actors
+ supervision, failure events, overload metrics, and WebSocket session actors
```

This gives Gene the ergonomic feel of synchronous handlers while preserving the concurrency and fault-isolation lessons from Erlang/Elixir and Akka.
