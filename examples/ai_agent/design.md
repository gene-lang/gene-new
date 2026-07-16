# Gene AI Agent — Design

Status: **the usable bootstrap is shipped: streaming Responses/Chat transports,
file/shell tools, `/sh`, `/repl`, local CLI state/memory, async session actors,
the gateway/web skeleton, Telegram, and SQLite gateway persistence. Slice A is
now shipped too: typed tool declarations (one `Tool` value derives handler +
schema + validation + risk), a stable live `/repl` `session` object, an
authoritative versioned event log with `/trace`, and an extended catastrophe
guard (realpath-confined paths, normal/destructive/catastrophic command
classification, surfaced truncation). Slice B now includes terminal and
gateway cancellation plus explicit cancel-then-prompt continuation,
attributable `/diff` + targeted `/undo`,
structured verification evidence, hierarchical `AGENTS.md` loading, and the
owned public `curses` API used by the agent prompt. Native libcurl is the
default outbound transport. MCP, worktrees, and browser automation remain
optional later work. Slices C and C2 are now shipped: every runnable or
output-producing entity is one worker (agents are a subtype), panes and all
interaction state are surface-local views, and the process-wide workspace
coordinator distinguishes colliding session-local worker ids. Secondary turns
run concurrently with the scheduler-friendly input editor; output, log-tail,
stats, file-view, streaming shell, and persistent REPL workers share the same
lifecycle, bounded-output, snapshot, and input-admission contracts. Combined
`--gateway[=PORT]` mode exposes the live local application as session `local`
without starving TUI input, while `--headless` constructs no curses or pane
state. Snapshot/resume, projection non-amplification, restart identities,
external editing, typed worker routes, and reject-while-busy admission are
implemented and covered by deterministic CLI/PTY tests (§10.5). Slice C3 is
now shipped too: isolated restore records, structured terminal agent results,
registry-derived help and safe slash commands, hidden/focused pane operations,
and explicit project progress make the worker model discoverable, operable,
and recoverable under the complex-project dogfood flow (§10.6). The next core
slice is C4: each worker kind declares one Gene-typed operation table, and
user commands, model tools, delegated peer workers, REPL scripts, and gateway
routes all invoke those same operations under declared
effect/audience/admission/audit policies — a worker id is an address, never
authority (§7.2, §10.7). C5 then hardens persistence into durable knowledge
and the daily surface into a discoverable one: atomic checkpoint generations,
durable-vs-ephemeral handler registration, pinned artifacts, at-rest policy,
the four-axis help system, and a completion-capable input editor (Tab/Ctrl-R/
Ctrl-E over one overlay primitive) (§7.3, §10.8).**
Date: 2026-07-16.

Implemented (see `examples/ai_agent/tui.gene` and `src/gene/stdlib.nim`): the `os`
namespace (`get_env`/`env?` under `Os/Env`, `exec` under `Os/Exec` with
timeout + output caps, `exec_stream` with stdout callbacks, `read_line`, and
legacy input compatibility helpers), the public `curses` namespace (`Screen`,
lifecycle, dimensions, drawing, editor, and cancellable `next_event`),
`Fs/read_text`/`Fs/write_text`/
`Fs/list_dir`/`Fs/real_path`, the `json` namespace (`parse`/`stringify`/
`JsonError`), `net/http_client` (native async libcurl request/stream), and the
agent itself — a streaming Responses-API loop over native HTTP with a curl(1)
bootstrap fallback, the §8.5 catastrophe guard (realpath-confined workspace
paths, normal/destructive/catastrophic command classification with hard stops
for host-destroying commands and one confirmation for destructive-but-intended
ones, timeout/output caps with surfaced truncation, secret redaction; routine
work auto-approves), and typed tool use — each of `read_file`, `write_file`,
`edit_file`, `list_dir`, `run_shell`, `grep` is one `Tool` value from which the
model-facing JSON Schema, argument validation, risk class, and handler all
derive. Turn, tool, guard, registration, and memory actions append to a
versioned event log (§9.2) that `/trace`
queries and the `/repl` `session` object exposes, plus optional `store/fs`
state persistence for non-secret config, the interactive session, memory, and
the event log. An offline demo transport keeps the loop runnable (and verified)
with no network or key. The full-screen scrollback TUI is shipped (§7);
launcher capability injection remains later work and does not gate the
signature Gene experience.

Operational diagnostics are emitted separately under the `app/ai_agent/*`
logger hierarchy. The trace profile in `logging.gene` records lifecycle,
counts, sizes, durations, routing backends, and outcomes without copying prompt
text, model text, tool arguments/output, shell commands, or credentials. This
does not replace the versioned event log, which remains the authoritative
record for tool actions and confirmations.

Diagnostic event-boundary records copy stable worker/agent/task correlation
ids and surface-local pane/surface ids when present. Pane ids cannot be a
required field: one worker may be headless or viewed by several surfaces under
different pane ids. Process diagnostic routing and severity stay immutable
launcher configuration; a pane-local `/log LEVEL` command would therefore be
misleading. Pane-local inspection uses `/tail worker=W` (or `/trace worker=W`)
over the authoritative event log instead.

This document specifies a live, programmable AI coding application written in
Gene. It normally presents a terminal UI, can optionally expose gateway
surfaces, holds conversations with a hosted model API, lets agents call local
tools (read/write files, run shell commands, search), and lets the user inspect
and reshape the running application through ordinary Gene values. The API auth
token is read from an environment variable; nothing is hard-coded.

**Product decision:** this is first and foremost the author's personal power
tool for developing Gene, not a multi-user service or a parity project against
every commercial coding agent. Optimize for flow, leverage, inspectability,
and dogfooding. Native supervision of a small number of sub-agents is part of
that power tool; decentralized or unbounded agent teams are not. Routine local
work stays auto-approved. Safety is deliberately narrow: prevent catastrophic,
hard-to-recover actions without surrounding normal edits, commands, tests,
installs, or network calls with permission theater. Features such as MCP,
worktree isolation, browser automation, and a plugin marketplace are a menu to
adopt when daily use proves their value.

The central product tension is explicit: **expose a very powerful
programmable object model without requiring the human to operate that object
model manually.** Workers, operation tables, policies, cursors, and snapshots
stay precise internally; the ordinary experience stays "talk, delegate,
inspect, run, resume tomorrow" — names over ids, composites over assembly,
and a small default `/help` with the full grammar behind it (§7.2, §10.8).

**Backends (implemented).** The agent speaks two wire shapes, both entirely
env-configured:

- **Responses API** (default) against the Codex/ChatGPT backend
  (`https://chatgpt.com/backend-api/codex`), auth via `OPENAI_AUTH_TOKEN` or
  `CODEX_ACCESS_TOKEN`;
- **Chat Completions** against any OpenAI-compatible endpoint — MiniMax,
  DeepSeek, vLLM, `api.openai.com`, etc.:

  ```bash
  OPENAI_BASE_URL=https://api.minimax.io/v1 OPENAI_MODEL=MiniMax-M2 \
  OPENAI_API_KEY=... gene run examples/ai_agent/tui.gene
  ```

`OPENAI_API=responses|chat` picks the shape explicitly; it defaults to
`responses` for the Codex backend and `chat` for any custom `OPENAI_BASE_URL`.
Internally the agent always works on Responses-style items; the chat layer
converts items to messages on the way out and normalizes `choices`/`delta`
chunks (including fragmented streamed `tool_calls`) back into items, so the
turn/tool loop is shared. A loopback fake endpoint in `tests/test_cli.nim`
verifies the chat round trip end-to-end, including the assistant
`tool_calls` → `role:"tool"` message ordering.

**API surface: target the Responses API, not Chat Completions.** OpenAI now
recommends the Responses API (`POST /v1/responses`) for new agent-style
projects; Chat Completions (`/v1/chat/completions`) remains supported but is the
older surface. Responses is built around typed output *items* (message items,
`function_call` items, reasoning items) and first-class tool/function calls,
which maps far more cleanly onto this agent's tool loop than digging tool calls
out of `choices[].message.tool_calls`. Model the client around Responses items;
Chat Completions is the compatibility shape for third-party endpoints, and is
implemented as an adapter over the same item vocabulary (see Backends above).
(Migration guide: https://platform.openai.com/docs/guides/migrate-to-responses.)

**Current transport:** `net/http_client` now dynamically loads libcurl and runs
requests off the scheduler, including bounded streaming and cancellation. The
agent uses it by default; `curl(1)` remains only as a bootstrap fallback when
libcurl cannot be loaded. The full-screen TUI itself is shipped (§7).

The goal of this doc is to make the build *actionable against the real
runtime*. Each subsystem below states what exists in this repo today, what is
missing, and the recommended way to close the gap using patterns already proven
here (the `db/sqlite`/`db/postgres` dynlib backends in `src/gene/stdlib.nim`,
the `net/http` server, capability values, and the async task/worker model).

## 0. Normative invariants

The rest of this document elaborates these; when text and invariant disagree,
the invariant wins and the text is stale:

1. One process-level workspace coordinator per canonical (realpath) workspace
   root; every application-mediated mutation of that root, including a
   whole-terminal `/tty` handoff, shares its single mutation lease for the
   lifetime the application can observe. This guarantee is exact for
   structured file operations and cooperative foreground subprocesses.
   Mediated shell channels reject recognized background/detach forms; an
   arbitrary executable can still daemonize internally, so descendant
   containment is explicitly best-effort rather than an OS sandbox. `/tty` is
   the user-originated escape for persistent processes, and explicitly granted
   raw host capabilities remain outside this guarantee.
2. Every runnable or output-producing entity is a **worker** with exactly one
   session-stable worker id. Agents are a worker subtype; supervision metadata
   never mints a second id or a second lifecycle.
3. Workers, agents, tools, the guard, and the event log are session state.
   Panes, layout, focus, maximize, and scroll are per-surface state; a surface
   never mutates another surface's presentation.
4. A pane attaches exactly one worker and owns no producer lifecycle.
5. `close` detaches a view; `cancel` interrupts the current operation;
   `stop` ends the worker. Nothing else ends a worker during a live session;
   controlled application shutdown and restore normalization are boundaries.
6. The event stream's `^v` is a per-session cursor, not a schema version.
   Vocabulary evolves additively; shipped types/props are never renamed.
7. Under the default guard posture, normal work auto-approves, destructive
   work takes one confirmation, and catastrophic work is denied.
   `GENE_AGENT_GUARD=0` is an explicit escape from that risk classifier, not
   from the mediated foreground-lifetime contract (§8.5).
8. Every model-originated mutation passes capabilities, the catastrophe guard,
   the workspace coordinator, and the event sink, on every surface.
9. Bounded live counts, stopped-worker retention, output caps, and context
   limits apply to every worker and every surface. History buffers overflow by
   dropping oldest entries with explicit loss metadata; stale cursors get an
   explicit gap response, never a silent skip.
10. Remote adapters never require the local TUI to exist.
11. Command-shaped input is never silently reinterpreted as worker input. An
   unknown leading-slash command is a local error; literal slash-prefixed input
   requires `//...` or `/N -- ...`.
12. Every agent operation has one durable terminal outcome and one structured
   result, including failure and cancellation. Availability (`idle`/`busy`),
   lifecycle (`running`/`stopped`), last outcome, and unread result state are
   separate facts on every surface.
13. Restore validates records independently. One malformed or obsolete pane,
   worker, or surface record is quarantined with an attributable event and can
   never prevent the main session from loading, and never causes a host
   operation to be retried.
14. A worker's functionality is exposed only as typed, declared operations
   (§7.2). User command, model tool, peer agent/worker, REPL script, and
   remote adapter all invoke the same operation under the same declared
   effect, audience, admission, and audit policies — no caller class has a
   private path, and no operation bypasses provenance. A worker id is an
   address, not a capability: a sub-agent reaches another worker only through
   an explicitly delegated handle, and read-only does not mean public.
15. Persisted state never claims a live closure is durable. Dynamically
   registered tools, operations, and handlers restore only through versioned
   module-qualified references; anything else restores disabled with an
   attributable event, never silently dropped and never executed from
   deserialized code.
16. Snapshots install atomically per checkpoint generation. Restore selects
   the highest complete, hash-valid generation and never mixes records from
   different generations; persisted record schemas are versioned from their
   first release and migrate through pure functions, with quarantine as the
   fallback.

## 1. What the agent is

A CLI, launched as:

```bash
OPENAI_AUTH_TOKEN=... gene run examples/ai_agent/tui.gene
```

The same main program optionally attaches the gateway adapters. The `--`
separates Gene runner options from application options:

```bash
# TUI only (default)
gene run examples/ai_agent/tui.gene

# TUI plus HTTP/web gateway on the configured/default port
gene run examples/ai_agent/tui.gene -- --gateway

# TUI plus gateway on an explicit port
gene run examples/ai_agent/tui.gene -- --gateway=8787

# Gateway and configured remote channels without curses
gene run examples/ai_agent/tui.gene -- --gateway --headless
```

`--gateway` uses `GENE_GATEWAY_PORT` when set and otherwise port 8090;
`--gateway=PORT` wins over the environment and must be in 1–65535.
`--headless` requires `--gateway`, so an accidental invocation cannot start an
invisible application with no control surface. The existing
`GENE_GATEWAY_HOST`, `GENE_GATEWAY_TOKEN`, database, and channel settings keep
their meaning. The listener binds to `127.0.0.1` by default; a non-loopback
host must be explicit and requires authentication rather than merely printing
a warning.

Behavior:

- a shipped multiline TTY prompt with persistent transcript/status rendering
  and mouse/page transcript scrolling while input is active; Up/Down browse
  submitted prompts, Ctrl-C clears the draft, Ctrl-D exits, and Escape cancels
  the active turn; extension panes stack on the right while input and status
  retain full width;
- one stable **main agent** owns the primary conversation and supervises zero
  or more **sub-agents** (shipped, slice C). Each sub-agent has its own item
  history, task, status, and event identity; it does not implicitly inherit
  the main agent's conversation context;
- a conversation loop that sends the running input-item list to the Responses
  API and streams assistant text deltas into the transcript as items arrive;
- **tool use**: the model may return `function_call` items (`read_file`,
  `write_file`, `edit_file`, `list_dir`, `run_shell`, `grep`); the agent
  executes them
  against the local workspace under explicit capabilities and the catastrophe
  guard
  (§8.5), appends `function_call_output` items, and loops until the model
  returns a final message item;
- slash commands in the input line. The canonical grammar is `/help`, `/pane
  ...`, `/agent ...`, and `/worker ...` (§7.1); `/?` is the exact short help
  alias, while `/0`, `/N ...`, `/close [N]`, `/sh`, `/repl`, `/tail`,
  `/stats`, and `/view` remain concise commands. Unknown
  command-shaped input is rejected locally rather than sent to the focused
  worker. Session commands include `/quit`, `/exit`, `/remember`, `/memory`,
  `/forget-memory`, `/status`, `/progress`, `/trace`, `/diff`, and `/undo`, and
  Ctrl-C interrupting a `/sh` command or `/repl` eval, and Escape/Ctrl-C
  cancelling an in-flight model response (shipped, slice B);
- the whole session is ordinary Gene code: messages are maps, tools are `fn`s
  registered in a map, and the transcript is a list — homoiconic and testable.
- the target signature experience makes that last property an official API:
  `/repl` exposes stable session objects, typed tools register from one
  declaration, and `/trace` queries the same versioned events used by the CLI,
  gateway, persistence, and tests.

The single main program always constructs the same application core. Within
one application session, a worker registry owns the main agent, its supervised
children, and the interactive process/projection workers (§7.1); each attached
surface owns its own panes and layout over those shared workers. The default
TUI is an in-process adapter over that core. `--gateway[=PORT]` additionally attaches HTTP/web and configured channel
adapters; it does not select a second session implementation or start another
orchestration layer. §12 describes this Hermes-style personal multi-surface
shape.

## 2. Capability gap analysis

The pieces below split into two kinds: **host capabilities** — new authority
over the machine that must be capability-gated (§8) — and **pure stdlib /
runtime pieces** that add no new authority, only code. Distinguishing them keeps
the security surface clear: only the first group can do damage.

Host capabilities (gated authority):

| Capability | Needed for | Status today | Section |
|---|---|---|---|
| Env var read (`Os/Env`) | API token, model, base URL | **implemented** | §3 |
| Outbound HTTPS (`Net/Http`) | call the API | **implemented** through `net/http_client` + libcurl | §4 |
| Subprocess (`Os/Exec`) | `run_shell`, `grep`, bootstrap `curl` | **implemented** | §6 |
| File read/write/list (`Fs/*`) | file tools | **implemented** — sync + async helpers | §6 |

Pure stdlib / runtime pieces (no new authority):

| Piece | Needed for | Status today | Section |
|---|---|---|---|
| JSON parse / serialize | API request + response bodies | **implemented** | §5 |
| TLS transport code | native HTTP client | **implemented** through dynamically loaded libcurl | §4 |
| Terminal UI (curses) | the TUI | **implemented safe API + prompt**, including mouse/page transcript scrolling | §7 |

What already exists and is directly reusable:

- **Capabilities** as ambient values: `Fs/ReadDir`, `Fs/WriteDir`,
  `Fs/ReadWriteDir`, `Net/Connect`, `Ffi/Load` (`src/gene/vm.nim`
  `buildBuiltins`). New host authority should follow this shape.
- **Runtime dynamic library loading**: `ffi/open` + `ffi/bind` over an
  `Ffi/Load` capability, and — more importantly — the *native-namespace over
  dynlib* pattern used by `db/sqlite`/`db/postgres` in `src/gene/stdlib.nim`.
  That pattern (own `LibHandle`, cache resolved symbols in a Nim `object`, wrap
  handles as owned C pointers, raise a typed error) is the template for curses
  and the HTTPS client.
- **Async tasks + worker I/O queue**: `Net/tcp_read_text_async`,
  `Net/tcp_write_text_async`, `Fs/*_async`, and `spawn`/`await` already suspend
  a Gene task on real I/O and resume it. A
  streaming HTTP client and non-blocking `getch` fit this model.
- **`str`, `url`, `std/stream`** stdlib helpers for building request bodies and
  slicing output. (`std/parse` is currently only `parse_int`, so it does not
  help with JSON/SSE yet — the `json` scanner in §5 is what covers that.)

### Why the existing dynamic FFI is not enough

`ffi/bind` only accepts the finite signature set in
`isSupportedDynamicFfiSignature` (`src/gene/vm.nim`): at most three parameters,
enumerated scalar/pointer/CStr combinations, and **no varargs**. The two
libraries this agent needs both rely on shapes outside that set —
`curl_easy_setopt(handle, option, ...)` and ncurses `printw(fmt, ...)` are
variadic, and TLS setup needs callbacks. So curses and the HTTPS client must be
implemented as **native namespaces with hand-rolled dynlib bindings** (exactly
like `db/sqlite`), not as user-level `ffi/bind` calls. User `ffi/bind` remains
fine for simple 0–3 arg C functions but is not the vehicle here.

## 3. Environment variables (§3)

The agent reads a bearer token from `OPENAI_AUTH_TOKEN`, `OPENAI_API_KEY`, or
`CODEX_ACCESS_TOKEN` (in that order), and optionally `OPENAI_BASE_URL`
(default: the Codex backend), `OPENAI_MODEL`, and `OPENAI_API`
(`responses`|`chat` wire shape; defaults by backend as described above).
`GENE_AGENT_STATE` selects the single-process CLI's Store backend. The initial
forms are `fs:<path>` and `db:sqlite:<path>`; the `db:` suffix is a backend URL
dispatch point, so future database drivers do not change the persistence
contract. Unsupported database schemes fail explicitly. Both backends use the
same record keys and Gene serialization for config, application/session state,
memory, and events. Starting the agent again with the same store restores them
automatically. If `GENE_AGENT_STATE` is unset or blank,
`GENE_AGENT_HOME=<dir>` selects `fs:<dir>`. A bare state path remains accepted
as a filesystem compatibility form. `GENE_AGENT_RESUME=0` keeps saving while
starting fresh; a future launcher flag may expose the same opt-out without
changing the persistence format. The persisted config deliberately excludes
auth tokens and other secrets.

Persistence is checkpoint-driven, not limited to graceful shutdown. Each
submitted input and each semantic application transition (tool call/result,
worker or agent lifecycle, pane lifecycle, file change, check result, memory
change, compaction, and completed turn) saves the bounded application/session
snapshot synchronously. Streaming `worker_output` is the only high-volume
checkpoint source and is rate-limited to once per
`GENE_AGENT_CHECKPOINT_INTERVAL_MS` (1000 ms by default). A small checkpoint
record is written after the snapshot records as a boundary marker containing
its sequence, reason, turn, and latest event version. Restore never resumes an
in-flight native task: the persisted operation metadata is normalized to a
safe terminal/interrupted state, after which the user or supervisor can
explicitly retry it. Gateway applications use their own persistence path and
do not overwrite the local CLI application's store.

Restore is record-isolated. The session core (main agent, bounded transcript,
memory, and event cursor) loads first; workers and each surface/pane descriptor
are validated and installed independently afterward. Invalid kind, type, path,
limit, or stale schema data produces a bounded `restore_record_rejected` event
with record kind/id and redacted error, then that record is skipped. A rejected
file view, projection, or layout can reduce the restored UI but cannot abort the
main session. No validator evaluates ad-hoc syntax from persisted data. The
all-kinds restore fixture covers agent, shell, REPL, output, log-tail, stats,
and file-view workers together, including one deliberately malformed pane.

Writes are grouped into **checkpoint generations** (invariant §0.16). A
checkpoint carries a schema version, a monotonically increasing generation
number, the event high-water mark, and per-record content hashes. The SQLite
backend writes all records plus the checkpoint marker in one transaction; the
filesystem backend writes and fsyncs the new records, then writes and fsyncs a
manifest, then atomically updates a `CURRENT` pointer. Restore selects the
highest complete generation whose hashes validate and never combines the
session core of one generation with workers of another. Every persisted record
kind — checkpoint, session core, worker, surface, tool/operation declaration —
carries its schema version from its first release; pure migration functions
upgrade old records before validation, and record quarantine remains the
fallback when no migration applies. (The §9.2 rule that the *journal*
introduces `^schema` only at its first incompatible change is unchanged;
snapshot records are stricter because they restore executable state.)

Local state is sensitive even after redaction: item lists, transcripts, memory,
and worker output can contain source excerpts or credentials the redactor did
not recognize. The storage policy is explicit — filesystem records and SQLite
databases are created with owner-only permissions; the gateway never serves
store files as static content; optional encryption-at-rest (an OS
keychain-derived key) is a later hardening, not an implied present guarantee;
and any future export command must make redacted-versus-full an explicit
choice, never a default.

Before this work there was no OS-environment access at the Gene surface. The
`Env` value type (`env`, `Env/extend`) remains the eval sandbox's binding
environment, unrelated to `getenv`. The implemented `os/get_env` surface below
exposes Nim's `os.getEnv` under explicit `Os/Env` authority.

**Implemented**: an `os` namespace with `os/get_env` gated by a new
`Os/Env` capability, so environment reads are explicit host authority like
everything else:

```gene
(import os [get_env Env])
(var token (get_env Env "OPENAI_AUTH_TOKEN"))   ; Env : Os/Env
```

Native surface (small, in `src/gene/stdlib.nim` next to the db backends):

- `os/get_env : Os/Env, Str -> Str` (raises `OsError` if unset), and
  `os/get_env : Os/Env, Str, Str -> Str` (with default) — nil-safe variant
  `os/env? : Os/Env, Str -> Str | Nil` for optional keys.

`Os/Env` is granted the same way `native`/`Ffi/Load` is in tests: defined on the
root scope, or injected by a launcher (see §8).

## 4. HTTPS client (§4)

The API is HTTPS with `Authorization: Bearer <token>` and JSON request bodies.
For a good UX the Responses API streams (`"stream": true` yields SSE
`data: {json}` events for `response.output_text.delta`, `response.completed`,
etc.). The current agent uses `net/http_client/stream`: libcurl callback bytes
cross a bounded native buffer into a Gene channel, where scheduler-thread code
frames SSE lines and repaints the ncurses prompt. `curl -N` through
`os/exec_stream_async` remains only as a library-discovery fallback.

The runtime's built-in TCP client is plaintext-only
(`Net/tcp_read_text_async` / `Net/tcp_write_text_async` in
`src/gene/vm.nim`); HTTPS is supplied separately by the first option below:

1. **libcurl native namespace (implemented).**
   `net/http_client` is backed by libcurl loaded via dynlib, mirroring the
   `db/sqlite` bindings:
   - candidates `libcurl.4.dylib` / `libcurl.so.4` (present on macOS via the
     dyld cache and on typical Linux); `GENE_LIBCURL` override like
     `GENE_LIBPQ`;
   - bind `curl_easy_init`, `curl_easy_setopt`, `curl_easy_perform`,
     `curl_slist_append`, `curl_easy_cleanup`. `curl_easy_setopt`/`getinfo` are
     variadic; small typed C shims make the real variadic calls per value shape.
     This is required on AArch64, where casting the symbol to a fixed-signature
     Nim proc passes trailing arguments with the wrong ABI.
   - run `curl_easy_perform` on a bounded persistent worker pool, so `await` on
     the request task does not block the scheduler.
   - **streaming callback — concurrency boundary.** Streaming
     uses `CURLOPT_WRITEFUNCTION`, a `{.cdecl.}` callback that curl invokes on
     the worker/perform thread. That callback **must not run any Gene code, walk
     VM state, or allocate managed values** — the VM is not reentrant from an
     arbitrary native thread. It may only copy the received bytes into a
     lock-protected bounded buffer. Scheduler polling materializes Gene strings
     and sends them through the rooted bounded `Channel`.
     SSE framing and JSON decoding of each event happen on the *scheduler*
     thread, in the Gene coroutine that drains the channel with `Channel/recv`.
     This keeps the native/VM boundary inside the machinery that already exists
     for foreign-thread task settlement.

2. **OpenSSL over the existing TCP client.** Bind `libssl`/`libcrypto`, wrap the
   current socket path in `SSL_read`/`SSL_write`. More surface than libcurl (BIO
   setup, cert verification, handshake) for the same result. Only worth it if a
   libcurl dependency is unacceptable.

3. **Shell out to `curl(1)`** via the subprocess capability (§6). Zero new TLS
   code — the bootstrap milestone. `os/exec` is still a blocking
   request/response helper, while `os/exec_stream` (synchronous) and
`os/exec_stream_async` add stdout chunk and stdout_line callbacks with the
same timeout/output cap contract as `os/exec`. `os/exec_stdio_async` gives an
inherited-stdin/stdout/stderr handoff whose returned status Task is settled by
the same worker machinery; it is used by `/edit` and `/tty`, so suspending the
local terminal surface never blocks remote sessions or background workers. The
current agent's curl fallback uses the captured async variant.

### Streaming vs. the blocking subprocess — resolving the conflict

These two facts are now split into distinct subprocess primitives: `os/exec`
returns a complete `{^status ^stdout ^stderr}` result, while `os/exec_stream`
returns the same shape and also invokes callbacks as stdout arrives.

- **Bootstrap:** `os/exec_stream` + `curl -N` gives visible Responses SSE text
  deltas without adding TLS code to Gene.
- **Native client:** `net/http_client` is now the default agent transport;
  cancellation and worker-thread boundaries are explicit. The subprocess path
  remains only for installations where libcurl discovery fails.
- **Future general subprocess API:** a long-lived `os/spawn` with stdin/stdout
  handles or channels may still be useful, but is not needed for the current
  agent.

Both transports present the same non-streaming Gene API; only the native client
adds `stream`:

```gene
(import net/http_client [request Http])
(var resp (await (request Http ^method "POST" ^url url ^headers hs ^body json_body)))
; resp => {^status Int ^body Str}

(import net/http_client [stream Http])
(var transfer (stream Http ^method "POST" ^url url ^headers hs ^body json_body))
; transfer/channel => bounded Channel of raw Str chunks, drained with Channel/recv
; transfer/task => cancellable Task yielding the final response map
```

## 5. JSON (§5)

Requests and responses are JSON. Gene is homoiconic but JSON is not Gene
syntax, so a real parser/serializer is required; the implemented `json`
namespace provides that. The older `http/json` helper only tags a string body
with a content-type.

**Implemented**: a pure-Gene-surface but native-implemented `json` namespace in
`src/gene/stdlib.nim`:

- `json/parse : Str -> Any ^errors [JsonError]` — objects → `Map`, arrays →
  `List`, strings → `Str`, numbers → `Int`/`Float`, `true`/`false` → `Bool`,
  `null` → `nil`. Mirrors the `DbError`/`UrlError` typed-error pattern.
- `json/stringify : Any -> Str` — inverse over the same value kinds.

A native scanner is the safe choice (correct number/string/escape handling,
depth limit against malicious input — same defensive posture as the HTTP
request parser's caps in `src/gene/stdlib.nim`). Implementation is
self-contained and needs no external library.

With `json`, the Responses request body is just data:

```gene
(json/stringify
  {^model model
   ^input input_items      ; Responses API: a list of typed input items
   ^tools tool_schemas
   ^stream true})          ; shipped transports stream SSE deltas (§4)
```

## 6. Agent tools: files and subprocess (§6)

The model calls tools; the agent executes them under capabilities and returns
results. Tools needed for a coding agent:

- `read_file`, `write_file`, `edit_file`, `list_dir` — files.
  `Fs/read_text_async` / `Fs/write_text_async` still exist; `Fs/read_text`,
  `Fs/write_text`, and `Fs/list_dir` are implemented for the line-oriented
  agent tools.
  Writes and edits of `.gene` files run the public reader in-process and return
  structured parse warnings without rejecting or rolling back intermediate
  source. Exact-edit mismatches return bounded, line-numbered candidate
  excerpts. `read_file` accepts line and byte ranges, defaults to a 64 KiB
  (`max_bytes=65536`) response cap, and permits an explicit maximum of 256 KiB
  (`max_bytes=262144`), including for a file containing one very long line.
  Path confinement runs before hierarchical instruction discovery.
- `run_shell`, `grep` — subprocess via the implemented `os` namespace entry
  gated by a new `Os/Exec` capability:

  ```gene
  (import os [exec Exec])
  (var r (exec Exec ^cmd "grep" ^args ["-rn" pattern "."] ^timeout_ms 10000))
  ; r => {^status Int ^stdout Str ^stderr Str}
  ```

  Native implementation over Nim `std/osproc` (`startProcess`), with an
  output-size cap, truncation flags, and timeout, returning a typed result map.
  `run_shell` accepts a model-visible `timeout_ms` from 1 through 120000
  (default 10000) and reports elapsed time against the requested cap.
  `run_shell` is the stateless one-shot spelling; the stateful per-worker
  variant with persistent cwd/env is §7.2's `shell run` operation, under the
  same classifier, lease, and events.
  `Os/Exec` is deliberately a *distinct* capability from `Os/Env` so a launcher
  can grant file+env without shell access.

Tools are **typed `Tool` declarations** (shipped, slice A). One `Tool` value is
the single source of truth; the registry entry, model-facing JSON Schema (both
wire shapes), argument validation, and risk class all derive from it:

```gene
(register_tool! (Tool
  ^name "read_file"
  ^description "Read a UTF-8 text file inside the workspace."
  ^risk "read"
  ^params [{^name "path" ^type "string" ^required true
            ^doc "workspace-relative file path"}]
  ^handler (fn [args] (read_text ReadDir (safe_path args/path)))))
```

`Tool` is a `type` with `schema` and `validate_args` messages (§9.1); the turn
loop reads the live registry (`tool_schemas_now`), so a tool added or replaced
from `/repl` reaches the very next model call. This removes the earlier
drift-prone duplication between a handler map and a hand-written schema list,
and demonstrates how types, metadata, functions, and maps compose.

The shipped `^params` list is still half stringly-typed (`^type "string"`
maps) — a small second schema vocabulary beside Gene's own. The target form
references real Gene type values and derives everything from them:

```gene
(type ReadFileArgs ^props {^path Str ^start_line? Int ^max_bytes? Int})

(Tool ^name "read_file" ^args ReadFileArgs ^result ToolText
      ^errors [FsError ToolError] ^risk "read" ^handler read_file)
```

JSON Schema for both wire shapes, runtime validation, CLI parsing, and help
all derive from `ReadFileArgs` — one type value instead of five parallel
descriptions, and a stronger demonstration of Gene's type system doing real
work. §7.2 operation declarations use this Gene-typed form from their first
release; the shipped `^params` form remains a compatibility spelling that
migrates onto the same derivation (slice C4). Every call
passes through argument validation and then the narrow catastrophe guard in
§8.5, and both the call and its result are appended to the event log (§9.2).

The return boundary is typed too. A handler returns either `Str` or
`{^text Str ^truncated Bool}`; any other shape becomes a bounded tool error
before rendering, event append, or model reinsertion. Helpers that render
collections validate or convert each element explicitly — they never pass an
unchecked list to `str/join`. A formatting failure preserves tool name, call
id, worker/task ids, and a redacted error in the structured agent result rather
than unwinding supervision with an empty result.

## 7. Terminal UI via curses (§7)

A native `curses` namespace backed by linked `libncurses`. ncurses' variadic
`printw` is avoided by binding non-variadic primitives:

- lifecycle: `initscr`, `endwin`, `cbreak`, `noecho`, `keypad`, `curs_set`,
  `start_color`, `init_pair`;
- drawing: `waddstr`/`mvwaddstr` (non-variadic, unlike `printw`), `wattron`/
  `wattroff`, `werase`, `wrefresh`, `wmove`, `getmaxyx` (via `getmaxx`/
  `getmaxy`);
- input: `wgetch`, polled with `timeout(0)` by the scheduler so streaming work
  and keystrokes interleave without blocking.

The shipped Gene-facing surface is a thin, safe layer over the raw binding:

```gene
(import curses [Screen open close dimensions draw next_event])
(var screen (open))
(try
  (draw screen ^output "agent> ready" ^input "" ^status "waiting")
  (var key (await (next_event screen)))
ensure
  (close screen))
```

`Screen` makes terminal ownership explicit. `close` is idempotent and callers
use `ensure`, matching the cleanup discipline of db connections. `draw` is a
non-variadic color-coded renderer, `dimensions` reports live rows/columns, and
`next_event` returns a cancellable `Task`. It preserves FIFO ordering,
assembles complete UTF-8 text events, and reports `KEY_RESIZE` as resize.

The agent's TTY editor is a Gene-level state machine over public
`curses/next_event` and `curses/draw`; this is what lets sub-agents and pane
controllers progress while the user types. It supports multiline input
(`Shift+Enter` inserts, `Enter` submits), bracketed paste, grapheme-aware
cursor movement, and per-route history; §7.3 specifies the complete key
contract, incremental history search, context-sensitive completion, and the
overlay primitive they share. In
pipes the agent falls back to `read_line` so scripted tests stay deterministic.
The reusable blocking `curses/read_input` editor remains available for simpler
programs and implements the same key conventions. Both paths use a fixed layout:
color-coded scrollback/output above a `─` separator, one or more promptless input
rows above a second `─` separator, and a status line at the bottom. The agent
adds a short `─` separator before each user turn in the scrollback, owns one
`Screen` persistently across prompts to avoid terminal-mode flicker, and calls
`curses/close` before EOF, process exit, or the whole-terminal `/tty` and
`/view` escape hatches (§8.5; the bootstrap spelled `/tty` as interactive
`/sh`, while C2 gives the two meanings distinct commands); the shell and REPL
*panes* are scheduler-owned
and never leave curses (§7.1).
The mouse wheel moves the focused view by three lines and PageUp/PageDown by
one viewport. A newly opened extension pane takes navigation focus; `/pane
focus N` (aliases `/N` and `/N focus`) selects it and `/pane focus 0`
(aliases `/0` and `/focus 0`) returns to main. The main status line or a
scrolled pane title
shows `[SCROLL +N]` while that view is above its live tail.
While an agent turn is pending, its surface may pulse a final `...` row. That
row is a presentation overlay: it is never appended to the shared transcript,
worker output, event journal, or persisted snapshot, and the first real output
replaces it visually.
Transcript lines word-wrap at the current view width, and each independent
scroll offset counts the resulting visual rows. Up/Down browse the agent's submitted
input history without changing transcript scroll position; moving past the
newest entry restores the current draft. While a turn is running, a standalone
Escape cancels the same authoritative `Task` as Ctrl-C. The polling path keeps
queued typing, mouse reports, and navigation sequences intact.
`close` restores echo/cbreak/keypad/cursor state before leaving
ncurses. Inside the `/tty` real-shell escape and the legacy whole-terminal
REPL, Ctrl-C stops the running command/eval or clears a partially typed line
instead of killing the agent: the interactive repl installs a SIGINT handler
that arms a VM interrupt (surfaced as a catchable "interrupted" error), and
the shell loop traps INT while `os/exec_stdio` ignores it in the parent,
system(3)-style. The shell/REPL panes need none of this — they cancel through
the ordinary worker `cancel` path. Interrupting an
in-flight model response and steering its continuation are shipped (§10).
Search, selection, and horizontal transcript scrolling remain optional; the
reusable lifecycle, editor, drawing, vertical scrolling, resize, and
asynchronous input layer is public and covered by PTY tests.

Status help is route-specific, not one universal “Enter sends” string. An
agent, shell, or REPL names its worker id, operation state, and send/cancel
keys. An output, file, stats, or tail view is labeled `read-only` and advertises
scroll, focus-main, maximize, and close controls; its input editor is inactive
except for recognized global commands. Every non-main route shows `/0 main`.
Examples:

```text
[0 main] Enter send | /pane list | /help
[1 agent a1: working] /0 main | Esc cancel | PgUp/PgDn scroll
[2 shell w1: idle] Enter run | /0 main | Ctrl-C cancel
[4 output w3: read-only] /0 main | PgUp/PgDn scroll | /close
```

Presentation refresh is coalesced: worker/event callbacks mark dirty regions
and at most one draw runs per scheduler turn. The input queue is drained before
that draw, so rapid child tool events cannot repeatedly repaint a partially
typed command or delay its submission behind every delta. PTY acceptance uses
an event-heavy child and primarily requires exact draft bytes/route plus
acknowledgement by the second scheduler turn. CI uses a generous wall-clock
watchdog (default one second) rather than treating host scheduling as product
behavior; an otherwise idle-host measurement tracks 250 ms as a diagnostic
performance target. Rendering may drop intermediate frames but never input or
authoritative events.

### 7.1 Workers and panes

**Bootstrap today:** `/agent new` creates a secondary `Agent`, attaches an
independent right-side `Pane`, and `/N prompt` starts a cancellable turn
without blocking the main input editor. Bare `/N` focuses that pane;
`/close` detaches the focused pane and `/close N` detaches a named pane, while
explicit stop controls the agent lifetime. The main model has the equivalent
`open_extension`
compatibility tool. Output, streaming line-oriented shell, and
declaration-persistent Gene REPL panes are also shipped. Restored shell/REPL
panes retain captured history in a closed state and require an explicit reopen.

**Shipped design (slice C2): one worker model.** The shipped slice already
separates a pane from the thing it displays, but names that thing three ways —
"backing owner", "producer", "controller". The refinement collapses them into
one concept. A **worker** is anything that owns state and a lifecycle and
produces output; a **pane** is a view over exactly one worker.

Workers are **session** state with session-stable ids. Panes are
**surface** state: each attached surface — the TUI, a browser tab, a phone
client — owns its own pane set, layout, focus, and scroll over the same shared
workers (invariant §0.3). Pane ids are scoped to their surface, so a web
client closing or reordering its panes can never rearrange the terminal. The
shipped session-owned pane registry becomes the TUI surface's attachment
during the migration; the session itself keeps no pane state:

```text
ApplicationSession              SurfaceAttachment (per TUI/tab/client)
  AgentRegistry (index)           pane registry and layout
  WorkerRegistry                  focus, maximize
  process workspace coordinator   scroll and filter view state
  EventLog
```

Surface identity is a small explicit contract. **Layout surfaces** own panes
and are distinct from **interaction adapters**, which only exchange messages
(Telegram is an adapter, not a layout surface; a client can be both). The
local TUI uses one stable surface key, `local_tui`, and persists its layout
snapshot under it. Each attachment also has a distinct `surface_instance`
epoch used by pane events; `(surface_instance, pane_id)` is never reused even
when a persisted surface key reconnects after restart. A browser tab keeps its
layout in browser-local storage rather than minting durable server-side
surface records. C2 therefore has no server-tracked ephemeral browser
attachments; if a later adapter introduces them, their count and reconnect
lease must be bounded and disconnect must release worker-retention pins. The
attachment epoch is the `^surface_id` value that pane
events carry (§9.2); the stable key remains layout-persistence policy rather
than event identity.

Interfaces then have three states per surface: the always-present **main pane
0** (the main agent's transcript), zero or more **visible panes** stacked on
the right, bounded **hidden panes** retained by that surface, and **headless
workers** with no pane on that surface. C3 adds hidden panes because dogfooding
showed that six useful workers cannot all remain legible in one stacked column:
`hide` preserves that pane's scroll/filter/view state and counts against the
surface pane bound, while `close` discards the descriptor. Neither operation
changes worker lifecycle. A worker with no visible or hidden pane on this
surface is headless here and can be reattached through `/pane open W`.

| Worker | User input | Output | Stop semantics |
|---|---|---|---|
| `agent` (main or one sub-agent) | prompt; steering is explicit cancel-then-prompt | streamed turn transcript | cancel model request and subprocesses, release lease, keep the event trail |
| `shell` | command lines | bounded streamed stdout/stderr | cancel the active command; cwd/env are worker state |
| `repl` | Gene forms; incomplete forms continue | printed values and diagnostics | close the `repl/Session` |
| `output` | none; producers append through the typed append operation | bounded append-only buffer (diffs, test runs, model projections) | detach producer links and preserve the bounded terminal snapshot |
| `log_tail` | a filter expression (same syntax as `/trace`) | matching events as they append | unsubscribe from the event log |
| `file_view` | none beyond navigation | one file, wrapped and scrollable | release the file snapshot/resources |
| `stats` | none | live context/agent/lease/event counters | release the projection |

The `output` worker exists so the "one pane, one worker" rule has no
exception: a pane never owns a mutable buffer itself. `open_pane ^kind
"output"` creates (or attaches to) an output worker, and the shipped
`append_pane` operation appends to that worker's bounded buffer. The canonical
surface addresses the worker directly with `/worker W append <text>`; `/N
append <text>` is a pane-id convenience alias. `/worker OUT follow SOURCE`
adds a bounded projection link from another worker (for example a verification
shell) and `unfollow` removes it. Links are explicit worker state, survive pane
close, never duplicate source journal events, and are removed when either
worker stops. The follow graph must remain acyclic: self-links and any link
that would create a transitive cycle are rejected with a typed
`worker_follow_cycle` error before state changes or output propagates.
`append` and `follow` are the first instances of a general pattern — §7.2
gives every worker kind such a typed operation table.

Worker state separates three orthogonal concepts, because one flat status
cannot describe both request/command workers and continuous projections:

```text
lifecycle:          running | stopped                (stopped is terminal)
current operation:  none | busy(task_id, kind)
last outcome:       completed | cancelled | failed   (observational only)
```

An agent additionally retains one bounded structured result for its latest
operation:

```gene
{^task_id "t7" ^outcome "failed" ^text ""
 ^error {^kind "TypeError" ^message "..."}
 ^finished_v 381 ^read false ^incorporated false}
```

The result exists for all terminal outcomes; an empty final model message does
not erase an error. `read` means a surface/user inspected it, while
`incorporated` means the main model context received the bounded result. Those
flags are distinct and persisted.

An input-capable worker also has a short-lived **admission reservation**. It is
set synchronously before an adapter acknowledges input and cleared atomically
when the operation Task becomes visible (or when preflight denies/stops it).
The reservation is reported as busy/confirming but is not itself a runnable
operation: it prevents two surfaces from both accepting one idle slot while a
destructive confirmation is still being resolved.

`cancel` interrupts the current operation and leaves the worker running with
no operation; `stop` ends the lifecycle, preserves the captured history and
event trail, and leaves attached panes rendering the terminal state rather
than closing them (invariant §0.5). A UI may render "idle" for a running
worker with no current operation and "busy" otherwise; a `log_tail`'s or
`stats`' continuous subscription is worker-owned background state, not a
forever-busy operation. A completed agent task or finished shell command
clears the operation — the worker stays running and can take the next prompt
or command.

Stopped is genuinely terminal: a stopped worker is never resurrected under
its old id. `/worker W open` on a stopped worker attaches a view of its
captured history; restarting mints a **new** worker id whose `worker_started`
event records `^restarted_from W`. This is also how persistence restores shell
and REPL workers whose processes cannot survive: the restored worker remains
stopped for inspection, while `/sh` or `/repl` creates its successor.
Visibility is never a status: headless workers
keep running, `/workers` lists them, and bounded per-kind counts refuse new
spawns rather than silently expiring idle workers — reclaiming a slot is an
explicit `stop`.

The main worker is the one lifecycle restriction: it cannot be stopped inside
an application session because permanent pane 0 and session identity depend on
it. Ending or replacing the main agent means controlled application shutdown or
a new session; sub-agents and every non-agent worker use the ordinary stop
contract.

Every bounded stream shares one overflow contract (invariant §0.9): encoded
UTF-8 bytes and entry counts are accounted explicitly, the **oldest** retained
content is dropped first, and loss is visible —

```gene
{^dropped_before 3812 ^dropped_bytes 65536}
```

Text tails truncate only at a valid UTF-8 scalar boundary and keep one in-band
loss marker whose byte count is updated rather than accumulated. The marker
itself consumes capacity; configured worker-output and transcript floors (32
and 64 bytes) ensure it can be represented. Structured event records are
atomic: a record larger than the journal capacity becomes a typed bounded
summary retaining its event type/cursor/correlation ids plus
`^truncated true ^original_bytes N`, never a sliced invalid map. Event journals
are bounded by both count and encoded bytes.

`dropped_before` is stream-specific but never unitless: for a session journal
it is the cursor of the last fully evicted event; for a bounded worker-text
snapshot it is the worker-local output sequence whose append most recently
caused prefix loss, with the exact cumulative byte loss in `dropped_bytes`.
Worker-text snapshots are not resumable within a partially retained chunk:
clients replace them atomically and continue from their `output_seq`; only the
session journal's cursor is a replay position. Gateway stale cursors receive
HTTP 409 with `{error:"cursor_gap", dropped_before, oldest_cursor,
snapshot_url}`; clients install the bounded session/worker snapshot and then
continue after its cursor, never silently skip (§12.2).

The main rendered transcript is a separate bounded stream because it also
contains user rows and presentation prefixes that are not worker-output
events. It therefore exposes `transcript_seq`,
`transcript_dropped_before`, and exact cumulative
`transcript_dropped_bytes` alongside the agent worker's ordinary output
sequence. Its in-band loss marker and snapshot metadata derive from the same
retained payload, so repeated overflow never counts an older marker as new
producer text.

Defaults are 256 KiB per worker output, 1 MiB per main transcript, 200 accepted
inputs per worker, 200 recall entries per `(surface, worker route)`, 64 pending
supervisor results, 4,096
events and 2 MiB per in-memory session journal, 256 KiB per surface draft, 16
panes per surface, 8 live agents including main, 32 total live workers
including agents, and 64 **unreferenced** stopped-worker snapshots. A stopped worker
immediately releases its live slot; attached and headless running workers
consume the same budget. All are configurable through the
`GENE_AGENT_*`/gateway equivalents, and restore enforces the current limits
rather than trusting an older larger snapshot. An evicted stopped worker
leaves a `worker_retention_dropped` tombstone; a stopped worker referenced by
any server-tracked surface remains until its last view detaches. Browser-local
layouts do not pin server state, and C2 creates no ephemeral server-side
browser attachments. Thus neither abandoned surfaces nor a surface-relative
“headless” bit can bypass the stopped-worker retention bound.

This contract applies uniformly to output-worker buffers, log-tail
projections, per-surface transcript/render caches, the in-memory event journal,
and shell output streamed while no pane is attached. A pane whose scrolled-to
rows are evicted clamps its scroll position and shows that older output was
dropped. (Tool
*results* keep their §8.5 rule — the incoming value is truncated with a
surfaced flag — because the model must see the newest output of the command it
just ran; history buffers drop oldest instead.)

The journal is logically append-only but its in-memory observation window is
bounded. SQLite/store snapshots persist that retained window and its cursor-gap
metadata; they are not an unbounded archival tier. A later audit archive may
choose a separate policy without changing live cursor semantics.

`stats` and `log_tail` are projections over state the application already owns
— the §9.2 event log and slice B's context accounting — so they add rendering,
not new authority, and update on event append rather than polling. Derived
projection rows are retained only in the worker's bounded snapshot; they are
not appended as `worker_output` records to the authoritative journal. Otherwise
N live tails would multiply each source event N times and evict the history
they observe. The canonical source event invalidates remote views. Each
gateway event batch returns a non-journal `changed_worker_ids` set; C2
conservatively includes every live `stats`/`log_tail` worker when a batch is
non-empty. Clients replace only snapshots whose `output_seq` advanced. This
bounded over-invalidation avoids duplicating server filters in every client
without appending one invalidation event per projection to the journal. Ordinary
agent, shell, REPL, and manually appended output remains canonical
`worker_output` journal data.
`log_tail` follows the event log only; tailing arbitrary files needs polling plus
rotation/truncation semantics and stays deferred for the same reasons `gene
view --follow` is deferred in `docs/proposals/editor.md`. `file_view` starts as
wrapped read-only text over the existing transcript machinery; a structural
Gene view should later reuse the reader-backed viewer model from that proposal
rather than growing a second implementation here.

The default layout keeps pane 0 on the left, vertically stacks panes on the
right, and reserves full-width input and status rows:

```text
[0] main agent        │ [1] sub-agent
                      │─────────────────
                      │ [2] log tail
                      │─────────────────
                      │ [3] shell or REPL
────────────────────────────────────────
input
────────────────────────────────────────
status
```

Stacking is used only while every visible right-side pane can retain a useful
minimum body (default six rows plus header). Beyond that threshold the right
column becomes a focused-pane stack: one right pane is rendered, and a compact
header lists the other pane ids with busy/unread markers. `/pane list` is the
authoritative switcher; Ctrl-PageUp/Ctrl-PageDown cycle visible panes without
claiming Up/Down, which remain input history. `/pane hide N` removes a pane
from layout without stopping its worker, `/pane show N` restores it, `/pane
close N` detaches it, and `/pane max N` remains the deliberate full-worker-area
view. Focusing a hidden pane shows it first.

Pane 0 is always present and cannot be closed; `/0 text` prompts the main
agent explicitly. Narrow terminals (the shipped renderer's `width < 48` guard)
collapse to a single full-width view: pane 0, or the focused pane rendered
full-width when focus is elsewhere — input is never routed to a worker whose
pane is invisible. Pane ids remain stable and never reused within a surface
attachment's lifetime. `/N max` maximizes one pane over the whole worker area
while the input and status rows stay; the same command (or Escape, below)
restores the split.

**Focus routes input, with a deterministic grammar.** Focus is upgraded from
pane-local navigation to input routing. Parsing is surface-first:

1. the surface parses the complete global-command registry first — `/help`,
   `/?`, `/pane`, `/agent`, `/worker`, `/close`, session commands, `/0`,
   `/N ...`, and
   their documented aliases;
2. an unrecognized leading `/` is a local `unknown command` error with a
   `/help` hint; on an input-capable route the diagnostic also teaches the
   `//...` and `/N -- ...` literal escapes. It is never model, shell, or REPL
   input;
3. everything else is sent verbatim to the focused input-capable worker;
4. `//text` sends `/text` literally to the focused worker, and `/N -- text`
   is the explicit routed-literal form.

This deliberately collides with legitimate shell input such as
`/usr/bin/env ...`: typo safety wins, and the contextual diagnostic shows that
`//usr/bin/env ...` sends the absolute path to the focused shell. The routed
form `/N -- /usr/bin/env ...` sends it to shell pane N. The status/help text
for shell and REPL routes includes this escape instead of making the user infer
it from a rejection.

Both the input row and the status line name the route (for example
`[3 shell]`) so a prompt can never be typed into a shell silently. Bare `/N`
focuses pane N (`/N focus` remains accepted); newly opened panes start focused
(shipped behavior); `/0` or
`/focus 0` or Escape on an empty input resets focus to the main agent. Escape
keeps one deterministic priority order, PTY-tested: cancel the focused
worker's active operation; else restore a maximized pane; else, **only when the
draft is empty**, reset focus to pane 0; else nothing. With a composed draft
and nothing to cancel or restore, Escape leaves both the draft and its route
untouched — an already-composed shell command or Gene form is never silently
rerouted to the main agent.

The input contract is uniform across input-accepting workers: multi-line
editing, worker-owned accepted-input history with adapter provenance, and
surface-local recall lists/navigation cursors per route, plus
**external composition** — `/edit` suspends curses, opens `$VISUAL`/`$EDITOR`
on the current draft, and returns the saved buffer as the focused worker's
draft without submitting it. This reuses the `/sh` suspend/resume discipline
and the editor-resolution rules in `docs/proposals/editor.md` §7.1; the draft
is ordinary user input and passes the same redaction-at-append when submitted.
`/edit` is strictly a surface operation: suspending the TUI's curses session
sets an explicit local-surface suspension state, and event callbacks must not
reopen curses over the child. The editor runs through scheduler-friendly
`os/exec_stdio_async`, so remote turns and workers keep running and events keep
accumulating; on editor exit the TUI clears suspension and repaints from its
event cursor. A failed or non-zero editor exit preserves the prior draft
unchanged; success replaces only this surface's draft.

**Help always has a known home.** `/help` and `/?` are equivalent global
commands from every route. With no argument they restore a maximized layout if
needed, focus pane 0, and print one bounded comprehensive help block in the
main viewport. The block covers navigation and keys, focus and literal-input
escapes, pane/worker/agent lifecycle verbs, every worker kind, session
commands, concise aliases, and where to inspect status, progress, results,
trace, diff, and undo. `/help <topic>` and `/? <topic>` accept `pane`, `agent`,
`worker`, `input`, `session`, and `trace`; `/help worker <kind>` additionally
renders that kind's §7.2 operation table from the same declaration the parser
uses. They still display the selected section in pane 0.

**Progressive disclosure (C5 target):** the comprehensive block is reference,
not the default. Bare `/help` teaches the small product model — type to talk,
`/sh`, `/repl`, `/agent new`, `/status`, `/help <topic>` — in a dozen lines;
`/help all` prints the full block above. Worker kinds, operation tables,
surface attachments, and correlation ids are expert surfaces that appear when
asked for, never prerequisites for ordinary use.

The help system scales along four axes as the system grows, all derived from
the one registry so none can drift or go stale:

- **layered** — bare `/help` (small model) → `/help <topic>` → `/help all`
  → `/help <command>`: one page per command generated from its declaration —
  syntax, argument types, aliases, effect/audience/admission where relevant,
  and one example; `/help worker <kind>` renders that kind's operation table;
- **contextual** — the route-specific status line (shipped, C3) names the
  keys and commands that matter *now*; every non-main route teaches `/0
  main`; error diagnostics teach the fix (`unknown command` suggests the
  nearest registered name — "did you mean `/pane focus 2`?" — and the `//`
  literal escape when the focused worker accepts input);
- **searchable** — `/help search <term>` matches command names, aliases,
  argument names, and description text; the `/`-palette is the interactive
  form of the same query;
- **interactive** — typing `/` opens the §7.3 overlay: registry commands
  filtered as you type, argument hints from the declaration once a command is
  chosen, `Tab` to accept. The palette, `/help search`, and Tab completion
  are one mechanism with three entry points.

Because help, parsing, completion, and the palette share one registry, a
command that exists is discoverable in all four ways the moment it is
declared — including operations added at runtime (§9.1) — and acceptance
tests reject undocumented or stale entries (shipped, C3).

Help is generated from the same command registry and key-binding metadata used
for parsing, so acceptance tests can reject undocumented or stale commands. It
is a surface-local presentation notice: invoking it never starts a model turn,
sends worker input, appends to model context or the authoritative event
journal, marks an agent result read, or checkpoints a duplicate transcript
item. Repeated help replaces the prior help notice rather than consuming
unbounded main scrollback.

The canonical command grammar included by comprehensive help begins with:

```text
/help [pane|agent|worker|input|session|trace]    # /? is identical

/pane list
/pane new <agent|shell|repl|tail|output|view|stats> [args]
/pane open <worker-id> [title]
/pane focus <0|N>
/pane show|hide|close|max <N>
/pane <N> focus|show|hide|close|max     # accepted id-first equivalent
/close [N]                              # focused pane by default; never pane 0

/agent list
/agent new [prompt]
/agent <A> send <prompt>
/agent <A> result|incorporate|cancel|stop

/worker list
/worker <W> open|cancel|stop|restart
/worker <W> status                    # any kind: lifecycle, operation, outcome
/worker <W> tail [n]                  # any kind: bounded recent output
/worker <W> run <command>             # shell workers (stateful cwd/env)
/worker <W> filter <expr>             # log-tail workers
/worker <W> view <path>|reload|info   # file-view workers
/worker <W> snapshot                  # stats workers
/worker <W> append <text>             # output workers
/worker <OUT> follow|unfollow <SOURCE>
/help worker <kind>                   # that kind's operation table (§7.2)
/help all                             # the full reference block (C5: bare
                                      # /help teaches the small model)

/pin result [A] | /pin worker <W> tail   # promote to a durable artifact (§9.5)
/artifacts | /artifact <id>

/status          /progress        /trace [filters] [--detail]
/diff            /undo [change-id]
/remember ...    /memory          /forget-memory ...
/edit            /tty             /quit | /exit
/view <file>                         # terminal handoff to gene view
```

Everywhere `<W>` or `<A>` appears, a unique session-local worker `^name`
(`build-shell`, `reader-review`) is accepted interchangeably with the id
(§7.2); ids stay canonical in events and snapshots. `/pane new` is an
intentional surface-local composite: it creates the requested
worker when needed, opens a local pane, and focuses it. `/pane open W` attaches
a fresh local view to an existing headless worker. Every listing prints pane id,
worker id, kind, lifecycle/current operation, last outcome, and unread result
state in one row; pane 0 is reported as `pane=0`, not `headless`. The concise
aliases below remain part of the interface:

- `/agent new [prompt]` creates a supervised sub-agent and opens its pane;
  `/agents` lists visible and
  headless agents. `/agent A result` displays and marks the latest result read
  without changing model context; `/agent A incorporate` explicitly appends
  its bounded result to main context. `/agent A send|open|cancel|stop` controls
  one by stable id;
- `/workers` lists every worker — kind, stable id, status, plus
  `visible_here`/local pane ids from the invoking surface; the shared worker
  API has no global attached/headless field. `/worker W open|cancel|stop|restart`
  controls one by id, where `open`
  attaches a fresh pane to a headless worker;
- `/pane output [title]` creates a bounded `output` worker and a pane over it;
  `/N append <text>` and `/worker W append <text>` add user-visible evidence;
- `/sh` opens or focuses the line-oriented shell worker's pane; `/repl` opens
  or focuses the Gene REPL pane with the stable `session` binding;
- `/tty` suspends the TUI and hands the terminal to the real interactive
  shell — the deliberate, user-originated escape hatch that runs outside
  worker capture and the §8.5 classifier while holding the workspace mutation
  lease for the entire handoff (the bootstrap spelled this
  "interactive `/sh`"; one command must not mean both);
- `/view <file>` suspends the TUI and launches `gene view <file>` through the
  same running Gene executable; quitting the viewer restores the agent. It is
  a local terminal handoff, holds the workspace mutation lease because the
  viewer can invoke an editor, and creates no worker or persisted/remote output.
  `/pane new view <workspace-path>` remains the confined shared file-view
  worker;
- `/stats` opens or focuses the stats pane; `/tail [filter]` opens a log tail
  (a bare token is `type=` shorthand, as in `/trace`);
- `/N text` prompts an idle agent pane, sends a command to a shell pane,
  evaluates a form in a REPL pane, or replaces the filter of a log-tail pane;
  stats and file-view panes reject text input, while output panes accept only
  the explicit `append` verb. `/N -- text` sends text that would otherwise
  match a control verb such as `close`;
- bare `/N` focuses pane N; `/close` closes the focused non-main pane and
  `/close N` closes pane N. Pane 0 cannot be closed. `/N close` remains an
  accepted compatibility spelling. `/N cancel` cancels its active task/process,
  `/N stop` explicitly stops the attached worker, `/N focus` routes input to
  it, and `/N max` toggles maximize.

The close rule is uniform, with no per-kind exceptions: `close` detaches the
view and never stops any worker — a busy shell or REPL keeps running headless
and stays visible in `/workers`. `stop` cancels the current operation and ends
the worker immediately, without confirmation, for agents, shell, output, log
tail, file view, and stats — a blanket "are you sure" on every busy stop would
be exactly the permission theater §8.5 rejects, and lifecycle control must
stay cheap. The one exception: a REPL stop confirms only when the worker has
explicitly tracked unsaved or transient state worth preserving, not merely
because an eval is running. Destructive confirmation remains about host
mutation (§8.5), never about worker lifecycle; API/headless callers therefore
never park on a stop.

Accepted input is kept per worker so shell commands, Gene forms, sub-agent
prompts, and main-agent prompts do not pollute one another. Draft text, the
Up/Down recall list, and its navigation cursor belong to the surface: one web
client cannot move the TUI's editor cursor. The local TUI recalls its own
accepted submissions for that worker; global control commands are presentation
history rather than worker input. Unsubmitted drafts may be restored only in
the same local surface snapshot, are byte-bounded on restore, and are never
placed in the redacted event journal until submitted. The status line identifies
the routed target and reports all running agents/processes compactly.

**Input admission is reject-while-busy, not an implicit queue.** The session
actor is the one admission point across TUI, gateway, channels, and model
supervision. Once one input reserves an idle worker, another input for that
worker fails immediately with a typed busy result until the current operation
finishes or is cancelled; it is never silently queued, used to cancel/replace
the operation, or inferred as steering from timing. C2 deliberately uses
explicit cancel-then-prompt for steering: cancel the current operation, wait
for its terminal outcome, then submit the continuation as a new prompt. There
is no ambiguous “prompt or steer” endpoint and no second prompt submitted
during a turn. The reservation is made before an
HTTP request returns 202, so concurrent surfaces cannot both observe idle and
receive false acceptance. Accepted-input history records only admitted input
with adapter/surface provenance; rejected input is not history. Shell and REPL
therefore also execute at most one submitted command/form at a time.

The model-facing bootstrap `open_extension` becomes a compatibility composite
over two capability-checked typed operations, conceptually shaped as:

```gene
(var agent_id
  (spawn_agent {^assignment "review the reader"
                ^context [...] }))
(var pane_id
  (open_pane {^kind "agent" ; agent, output, log_tail, file_view; shell and
              ^owner_id agent_id ; repl panes are user-opened only
              ^title "reader review"}))
```

`spawn_agent` returns only a worker id and does not require a pane. Because
panes are surface state, model/session operations never open panes directly
(invariant §0.3): they create or identify a **worker** and may emit a bounded
**presentation hint** event:

```gene
{^type "worker_attention_requested" ^worker_id "a2"
 ^preferred_view "pane" ^title "reader review"}
```

Each surface independently decides how to honor a hint — the local TUI
auto-accepts hints as product policy, a browser may show a notification, and
headless mode records only the worker and the hint. `pane_opened` is emitted
only after a real surface creates a pane, and pane events always carry a
stable `^surface_id`: because pane ids are surface-scoped, correlation is the
pair `(surface_id, pane_id)`, never `pane_id` alone. The model-facing
`open_pane` tool is retained as a compatibility name for "create/identify the
worker, then hint"; for `^kind "output"` it creates the output worker as a
convenience, and `/agent new` performs
worker-plus-local-pane as a UI shortcut on the surface the user typed into.
Separate operations append to an output worker, send to a process worker,
focus/close a local pane, and cancel/stop a worker. The model may create only worker kinds allowed by its capabilities and request attention: creating a
view is harmless, but starting a shell or REPL must use the existing `Os/Exec`
or VM authority and the same catastrophe guard, so those kinds stay
user-opened. The shipped rule restricts model-opened panes to `agent` and
`output`; extending it to the `log_tail` and `file_view` view kinds is
harmless in principle but stays behind the bounded worker/pane counts and
waits until dogfooding shows the model uses them productively. An output
worker accepts structured events or already-redacted text; it is not an
untracked channel around the authoritative event log.

Input provenance remains explicit, with three distinct channels. User input to
a shell **pane** is attributable worker input: each line passes the §8.5
classifier and lands in the event log like scripted `/sh` lines do. The
`/tty` escape is the one unclassified channel, and it is user-originated by
construction — the TUI must be suspended by the person at the keyboard. A
model cannot inject raw input into either: model-initiated commands still go
through the typed `run_shell` operation, its classifier, and its events, with
output optionally projected into a shell/output pane. The same rule prevents a
model from using a visible REPL pane as an unlogged mutation backdoor.
Every shared `file_view` resolves its path through the same workspace
`safe_path` confinement as `read_file`, including `/pane new view`.
File-view output is session state exposed by snapshots and persistence, so a
local arbitrary-host read must not silently become shared remote data.
The `/view` terminal handoff may inspect a path the local user selects, but its
screen content remains local and does not create a session worker.

The live `/repl` exposes coordinator-aware `session` mutations (`undo`, tool
registration, supervised worker operations) and those preserve the ordinary
lease/event contracts. If an embedding deliberately grants raw filesystem or
subprocess capabilities into that REPL, direct calls through them are a
user-originated escape hatch just like using an external terminal: they are
outside application mediation and the coordinator invariant, and the host must
label that authority rather than implying it is tracked.

The shipped shell and REPL panes run as scheduler-owned, cancellable controllers
behind the curses renderer rather than entering nested blocking terminal loops.
The shell pane is line-oriented: it reuses the async command runner, streams
bounded output, retains cwd/environment fields as controller state, and
supports cancellation, but does not claim job control or full-screen terminal
programs.
Drawing arbitrary PTY bytes inside curses would require a real terminal
emulator; do not approximate one with ANSI stripping. Add that layer or hand
off to an external terminal only if dogfooding requires it. The REPL is a
form-oriented controller over the owned `repl/Session` API, so declarations and
incomplete forms persist without replaying earlier side effects. This boundary
is reusable by the TUI, web UI, and gateway; curses remains only a view.

### 7.2 Worker operations — one typed surface for user, model, and peers

Slice C2 made every runnable thing a worker; C3 makes the workers operable by
the user. The remaining asymmetry is that a worker's functionality is reachable
unevenly: `append`/`follow` exist on output workers, `send`/`result` on agents,
`run_shell` for one-shot commands — but a supervising agent cannot check a
verification shell's recent output, and a REPL script cannot drive a log tail,
except by rendering a pane. Slice C4 closes this: **each worker kind declares
one typed operation table, and that single declaration is the only functional
surface the worker has.**

An operation declaration mirrors the §6 `Tool` pattern — one value derives
everything: argument validation, the `/worker W <op>` slash dispatch, the
`session ~ call_worker` message, the gateway route, model-tool access, and
`/help worker <kind>` documentation, with no second registration to drift.
The declaration keeps independent concerns as **orthogonal policies** rather
than one flat risk class, and its argument/result schemas are real Gene type
values, not a parallel string vocabulary:

```gene
(type ShellRunArgs ^props {^command Str ^timeout_ms? Int})

(Operation
  ^name "run"
  ^args ShellRunArgs ^result ToolText ^errors [ShellError WorkerStopped]
  ^effect "host_write"        ; observe | session_write | host_read | host_write
  ^audience ["user" "supervisor" "delegated"]
  ^admission "worker_exclusive"  ; none | interrupt | worker_exclusive
  ^audit "full"               ; none | attributed | full
  ^cancellable true ^idempotent false
  ^handler shell_run)
```

- **effect** — what the operation touches. `observe` reads bounded worker
  state and changes nothing; `session_write` mutates session state (results,
  filters, buffers, lifecycle); `host_read` reads the machine under a
  capability and path confinement; `host_write` mutates it under the §8.5
  classifier and the workspace lease. Reading a workspace file is host
  authority even though it mutates nothing — the capability model already
  says so.
- **audience** — who may call. `user` (any authenticated surface, local or
  remote), `supervisor` (the main agent), `delegated` (a sub-agent that
  received this worker as an explicit handle in its §9.3 context attachment),
  plus the worker itself. **A worker id is an address, not a capability**:
  knowing `"main"` does not entitle a sub-agent to `tail` the main transcript.
  Observation of another worker requires audience membership, so the bounded
  context attachment remains the only channel by which a child sees parent or
  sibling state. Read-only does not mean public.
- **admission** — how the call interacts with the worker's single operation
  slot. `none` (runs anytime, even mid-operation), `interrupt` (targets the
  currently installed operation instead of competing with it), and
  `worker_exclusive` (the normal reject-while-busy slot; for `host_write`
  operations the workspace lease is acquired on top, per §9.3 ordering).
  `cancel` and `stop` are `interrupt` operations — a `worker_exclusive`
  `cancel` would be rejected exactly when it is needed. `stop` is an atomic
  cancel-then-terminate; `restart` requires a stopped worker and uses ordinary
  exclusive admission on the successor.
- **audit** — journal policy. `none` for surface-driven observe polling
  (projection non-amplification), `attributed` for non-surface observe calls
  when provenance matters, `full` for every effectful operation.

The per-kind operation table (audience abbreviations: U user, S supervisor,
D delegated):

| Worker | Operation | Effect | Audience | Admission |
|---|---|---|---|---|
| *every kind* | `status`, `tail [n]` | observe | U S D | none |
| *every kind* | `cancel` | session_write | U S | interrupt |
| *every kind* | `stop` | session_write | U S | interrupt (cancel + terminate) |
| *every kind* | `restart` | session_write | U S | worker_exclusive (stopped only) |
| `agent` | `send <prompt>` | session_write | U S | worker_exclusive |
| `agent` | `result` | observe | U S | none |
| `agent` | `mark_result_read` | session_write (idempotent) | U S | none |
| `agent` | `incorporate` | session_write (idempotent) | U S | none |
| `shell` | `run <command>` | host_write | U S D | worker_exclusive + lease |
| `repl` | `eval <form>` | host_write (VM) | U only | worker_exclusive |
| `output` | `append <text>` | session_write | U S D | none (bounded buffer) |
| `output` | `follow`/`unfollow <src>` | session_write | U S | none |
| `log_tail` | `filter <expr>` | session_write | U S | none |
| `file_view` | `info` | observe | U S D | none |
| `file_view` | `view <path>`, `reload` | host_read (confined) | U S | worker_exclusive |
| `stats` | `snapshot` | observe | U S D | none |

Decisions the table encodes:

- **`result` has one meaning everywhere; read-marking is a separate write.**
  `result` is a pure observe operation on every adapter. `mark_result_read`
  and `incorporate` are idempotent session writes. The CLI's `/agent A result`
  is a declared surface composite — `result`, render, `mark_result_read` —
  while gateway `GET .../result` invokes only the primitive. The adapters
  differ in composition, never in operation semantics, which is what keeps
  C4's one-surface thesis true.

- **Stateful `shell run` is distinct from one-shot `run_shell`.** The §6
  `run_shell` tool stays the stateless spelling; `call_worker W run` executes
  in a named shell worker whose cwd and environment persist between calls —
  that persistence is the feature. Both pass the same classifier, take the
  same lease, and emit the same events; only the execution context differs.
  A model composing a build in one worker (`cd build`, `cmake ..`, `make`)
  no longer needs to re-derive state per command.
- **`repl eval` stays user-originated.** §7.1's rule that a model must not use
  a REPL as an unlogged mutation backdoor extends to peers: no model, agent, or
  remote caller may evaluate forms in a REPL worker in C4. Peers get observe
  operations only. If dogfooding ever justifies programmatic eval, it arrives
  as an explicitly granted capability with full evented provenance — a new
  decision, not a default.
- **Observation replaces projection where a pane is overkill.** A supervising
  agent that wants a verification shell's last lines calls `tail`, which reads
  the worker's existing bounded buffer; it does not open a pane, add a
  `follow` link, or append journal events. `follow` remains the right tool for
  *continuous* projection into an output worker; `tail` is the point read.
- **The primary input verb is the default operation.** `/N text` on a shell
  pane is sugar for `run`, on an agent pane for `send`, on a log-tail pane for
  `filter`. The table makes the verb explicit so a non-surface caller can use
  it; it does not change surface input routing (§7.1).

Callers and attribution: the model reaches operations through one typed
`call_worker` tool (`^worker_id`, `^op`, `^args`) validated against the target
kind's table, with the operation's declared effect/audience/admission enforced
at one choke point; `agent_result`, `send_agent`, and `append_pane` remain
compatibility spellings over the same operations. Workers accept an optional
unique session-local `^name` (`"build-shell"`, `"reader-review"`), and every
command or operation that takes a worker/agent id accepts the name
interchangeably — ids stay authoritative in events, snapshots, and
`/trace --detail`, names exist so routine interaction never requires an id.
REPL scripts use the message form
(`session ~ call_worker "build-shell" "run" {^command "nimble test"}`), which
is the §9.1 signature story extended to workers. Every effectful invocation
records its caller: the existing `worker_operation_started/finished` events
gain additive `^origin` (`user|model|worker|remote`) and `^caller_worker_id`
props, and `attributed`-audit observe calls append one bounded access record,
so `/trace` can answer "who ran this" — and "who read this" where it matters.
Reject-while-busy admission applies to `worker_exclusive` operations from
every caller with an identical typed `worker_busy` rejection across CLI,
model tool, and gateway; `interrupt` operations succeed against a busy worker
by design.

Surface composites remain first-class. `/sh`, `/repl`, `/agent new`, `/tail`,
`/stats`, and `/pane new` stay convenient one-step commands; they are declared
compositions over canonical operations (create worker if needed, open pane,
focus, invoke primary verb), never private paths. The user should never have
to assemble a worker, a pane, focus, and an operation by hand for ordinary
work — the operation table is what makes the composites cheap to define and
impossible to drift.

### 7.3 Input editing, completion, and overlays

The input editor is where system complexity either stays invisible or leaks
onto the user, so its key contract is specified once and PTY-tested. Shipped
behavior and C5 targets, in one table:

| Key | Behavior | Status |
|---|---|---|
| `Up`/`Down` | browse the focused worker's accepted-input history; past the newest entry restores the live draft | shipped |
| `Shift+Enter` | insert a newline in the multi-line draft (`Enter` submits) | shipped |
| bracketed paste | multi-line paste lands in the draft without submitting | shipped |
| `Escape` | the §7.1 priority ladder (cancel → unmaximize → focus reset when draft empty → nothing) | shipped |
| `Ctrl-E` | key binding for `/edit`: compose the draft in `$VISUAL`/`$EDITOR` | C5 |
| `Ctrl-R` | incremental reverse search over the focused worker's history | C5 |
| `Tab` | context-sensitive completion (below) | C5 |
| `Ctrl-PgUp`/`Ctrl-PgDn` | cycle visible panes (never Up/Down, which stay history) | shipped |

`Ctrl-R` searches the same worker-scoped history that Up/Down browses: typing
narrows incrementally, `Ctrl-R` again steps to the older match, `Enter`
accepts into the draft (never auto-submits), and `Escape` restores the prior
draft. Search never crosses routes — a shell pane's `Ctrl-R` cannot surface a
main-agent prompt — because history is per worker (§7.1).

**Tab completion is context-sensitive by parse position**, derived from the
same command registry, operation tables, and session state the parser uses —
never a second hardcoded word list:

- command position (`/pa…`) → command and alias names;
- after `/worker`, `/agent`, `/pane` → worker/agent names and ids, pane ids,
  each annotated with kind and status;
- verb position after a target → that worker kind's §7.2 operations, filtered
  by the caller's audience;
- argument position → the operation's declared Gene argument type drives the
  source: workspace-confined paths for path args, `/trace` filter keys for
  filter args, artifact ids for artifact args;
- on a shell route, plain-text position → workspace-confined path completion
  plus tokens from that worker's own history; on a REPL route → the stable
  `session` projections and top-level bindings.

Completion is surface-local presentation: it reads live registries
synchronously, mutates nothing, and is never journaled. A completion that
would name another worker respects §7.2 audience — a sub-agent-delegated
surface never completes worker names the caller cannot observe.

**One overlay primitive, not a widget toolkit.** Tab completion, `Ctrl-R`
search, the `/`-palette (§7.1 help), and any future drop-down menu are the
same interaction: a transient, bounded, keyboard-navigable list rendered
above the input row, filtered as the user types, dismissed by `Escape`
without side effects. The curses renderer gains exactly one such overlay-list
component (draw last in the frame, clip by cell width, reuse the §7 dirty/
coalescing rules); everything else is a parameterization. This is the honest
answer to "how hard are drop-down menus": a *transient keyboard-driven
overlay* is straightforward on the existing full-frame renderer, and the
palette, completion, and menus should all be it. A persistent mouse-driven
menu bar is a different animal — permanent screen real estate, hit-testing,
and mouse-report handling beyond the shipped wheel support — and is deferred
until dogfooding shows keyboard overlays are insufficient. Overlay state is
per-surface (invariant §0.3): it never appears in snapshots, events, or
remote projections, and a repaint storm may drop overlay frames but never
draft bytes (§7's input-before-draw rule).

## 8. Capabilities and the launcher (§8)

Every new host power is a capability value, consistent with the existing model
(`src/gene/vm.nim` defines `Net/Connect`, `Fs/*`, `Ffi/Load`):

- `Os/Env` — read environment variables (§3);
- `Os/Exec` — spawn subprocesses (§6);
- `Net/Connect` — outbound network (reuse; §4);
- `Fs/ReadWriteDir` — workspace file tools (reuse; §6).

`gene run` now supports explicit named entrypoint grants such as
`--grant env=Os/Env --grant exec=Os/Exec --`. The current personal-agent script
still reads the built-in capability values for backward compatibility; moving
its `main` signature to named grants is the next packaging/hardening slice, not
a missing runtime mechanism. Embedding hosts can already pass the same named
capabilities through `GeneCall`.

### 8.5 Catastrophe guard

**Official posture (2026-07-09): single-user personal power tool, routine work
auto-approved, narrow hard stops for catastrophic and hard-to-recover actions.**
The goal is not to sandbox the author from their own agent or to construct an
enterprise permission system. Normal workspace reads/edits, shell commands,
tests, builds, package installs, and network calls should run without prompts.

The shipped guard classifies each `run_shell`/`/sh`-bound command as `normal`,
`destructive`, or `catastrophic` (`classify_command` in `examples/ai_agent/tui.gene`)
and acts accordingly:

- **Normal:** run immediately.
- **Destructive but plausibly intentional:** show the exact target and require
  one explicit confirmation (`confirm_destructive?`; EOF/no-stdin denies, so a
  destructive command never auto-approves in a scripted run).
- **Catastrophic or nonsensical:** deny outright, and emit a `confirmation`
  event recording the denial.

Before that optional risk classification, every mediated shell channel applies
the workspace-lifetime contract from invariant §0.1. An unquoted single `&`
shell operator (excluding `&&`, `&>`, and `>&` redirections) and a deliberately
small set of explicit detaching launchers (`daemon`/`daemonize`, forking
`setsid`, non-waiting `systemd-run`, background `start-stop-daemon`, detached
`tmux`, and detached `screen`) are denied with `risk=detached_process`. This
check cannot be confirmed or disabled with `GENE_AGENT_GUARD=0`; use the local,
user-originated `/tty` handoff for persistent/background work. Quoted or escaped
ampersands and ordinary redirections remain valid.

Classification anchors command-name patterns at the start of each simple
command (splitting on `&&`, `;`, `|`) so `grep shutdown src/` stays normal while
`ls && git clean -fdx` is caught. File tools realpath every path and reject
anything resolving outside the workspace root, so a symlink inside the workspace
cannot point a read/write outside it. Subprocesses keep their timeouts and
output caps, and truncation is surfaced in both the transcript and the
model-visible tool result. Known auth tokens are redacted from displayed and
model-visible output — including inside event-log entries.

The two compatibility flags are independent and intentionally have different
jobs. `GENE_AGENT_GUARD=0` removes shell-command risk classification
**including catastrophic command hard stops**; it does not remove the mediated
foreground-lifetime contract and does not merely remove destructive
confirmations. Path confinement, output bounds, and redaction remain active.

| `GENE_AGENT_GUARD` | `GENE_AGENT_APPROVE_ALL` | Behavior |
|---|---|---|
| `1` (default) | `1` (default) | Normal work auto-approves; destructive shell commands ask once; catastrophic commands are denied. |
| `1` | `0` | The guard still denies catastrophic commands and asks once for destructive shell commands. The legacy layer prompts for normal model `run_shell` and every file write/edit, but coalesces with an already-approved destructive guard decision so one operation never asks twice. |
| `0` | `1` | Shell risk classification and catastrophic command protection are disabled, and file writes/edits plus model `run_shell` auto-approve; mediated background/detach syntax is still denied. |
| `0` | `0` | Shell risk classification and catastrophe hard stops are disabled, but the legacy layer prompts before each file write/edit or model `run_shell`; accepting can run a formerly catastrophic foreground command, while mediated background/detach syntax is still denied. |

The default `1`/`1` posture is the product design. `APPROVE_ALL=0` exists for
occasional prompt-before-operation use; `GUARD=0` is an explicit unsafe escape
hatch that must be set outside the session.

Shipped coverage (`classify_command` in `examples/ai_agent/tui.gene`):

- **catastrophic** — recursive deletion (`rm -rf`/`-fr`/`-r`) of `/`, `$HOME`,
  a top-level absolute directory, the workspace root, `.`, `..`, or `.git`;
  disk formatting (`mkfs`), raw-device writes (`of=/dev/…`), fork bombs
  (`:(){`), and `shutdown`/`reboot`/`poweroff`/`halt`; `DROP DATABASE`;
- **destructive** (one confirmation) — recursive deletion of any other tree;
  `git reset --hard`, `git clean -fd`, force push, `git branch -D`;
  `DROP TABLE`, `TRUNCATE TABLE`, and `DELETE`/`UPDATE` with no `WHERE`;
  `terraform destroy`; `kubectl delete namespace`/`ns`/`cluster`;
- printing, persisting, or sending known auth tokens is prevented separately by
  redaction (below), not by the classifier.

Prefer structured wrappers for database, Git, and deployment tools because
parsing arbitrary shell is necessarily incomplete. For `run_shell`, block or ask
only on the high-confidence patterns above; do not pretend this is an OS sandbox.
`/tty` (the bootstrap's interactive `/sh`) is a deliberate user-driven escape
hatch — the TTY session hands the loop to the real shell, so the classifier
does not sit in front of it. Every other shell channel is classified: scripted
(piped) `/sh` lines, shell-pane input, and model `run_shell` calls alike.
The foreground-lifetime check covers obvious shell syntax and launchers, but
cannot prove that an arbitrary binary will not fork and daemonize internally;
such a program is outside the exact lease guarantee once its tracked parent
returns.

Reliability rules apply even with auto-approval:

- resolve real paths before protected-root checks so symlinks cannot bypass
  them;
- preserve and distinguish pre-existing user changes;
- enforce command timeouts and bounded output, surface truncation flags in the
  transcript/model result, and avoid extra unbounded copies;
- redact known secrets before transcript persistence, logs, errors, and model
  transmission;
- regression-test the seeded worst cases while ensuring ordinary dogfood
  commands remain interruption-free.

Known current gaps (documented, not yet classified):

- **large-tree deletion** — a recursive `rm` of an ordinary path is destructive
  but its size is not measured, so a huge-but-unprotected tree is not escalated;
- **cloud/infra breadth and production targets** — only the specific `kubectl`
  namespace/cluster and `terraform destroy` forms above are recognized; broad
  cloud-resource deletion, production deploy/rollback, and "is this prod?"
  detection are not modeled;
- **parsed wrappers** — database/Git/deployment classification is substring- and
  segment-based rather than argument-parsed, so an unusual spelling can slip a
  destructive command through as normal or trip a false confirmation; DB
  connection awareness (which database, ephemeral vs. not) is not modeled;
- **`/tty`** — the real-shell TTY loop is outside the classifier (above).

A general policy language, default-on approval modes, OS/container sandboxing,
multi-user isolation, and compliance controls are explicit non-goals unless the
project later chooses to become a distributed product.

## 9. Agent loop (Gene)

The following is actual Gene surface syntax, condensed directly from
`examples/ai_agent/tui.gene`. Transport decoders and small item helpers are elided,
but this tool_call recursion is the shipped loop rather than language-neutral
pseudocode.

```gene
(fn call_model [transport, input_items, render_stream]
  (var body
    (if (== api_flavor "chat")
      (stringify {^model model
                  ^messages (items_to_chat_messages input_items)
                  ^tools (chat_tool_schemas_now)
                  ^tool_choice "auto"
                  ^stream true})
      (stringify {^model model
                  ^store false
                  ^stream true
                  ^input input_items
                  ^tools (tool_schemas_now)
                  ^tool_choice "auto"
                  ^parallel_tool_calls true})))
  (transport body render_stream))

# Call the model; if it asks for tools, execute them and recur with the model
# output plus function_call_output items. Otherwise render and retain the final
# assistant message. `budget` prevents an endless tool_call loop.
(fn run_turn [transport, input_items, render, render_stream, budget, emit]
  (var streamed (cell false))
  (var resp
    (call_model transport input_items
      (fn [text]
        (Cell/set streamed true)
        (emit "text_delta" {^text (redact text)})
        (render_stream (redact text)))))
  (if (!= resp/agent_error void)
    (then
      (emit "error" {^text resp/agent_error})
      (render resp/agent_error)
      (emit "turn_done" {})
      input_items)
    (else
      (each (to_stream (response_output_items resp))
        (fn [item] (emit "model_item" {^item item})))
      (var calls (response_calls resp))
      (if (empty? calls)
        (then
          (emit "agent_text" {^text (response_text resp)})
          (if (Cell/get streamed)
            (render "")
            (render (redact (response_text resp))))
          (emit "turn_done" {^text (response_text resp)})
          (append_all input_items (response_output_items resp)))
        (elif (<= budget 0)
          (render "[stopped: tool_call budget exhausted]")
          (emit "turn_done" {})
          input_items)
        (else
          # Keep awaited tool handlers in the turn fiber so cancellation
          # cannot strand a subprocess in a lazy mapper continuation.
          (var outputs (cell []))
          (for c in calls
            ((outputs ~ Cell/get) ~ List/push! (run_tool_call c emit))
            (render $"  · tool ${c/name} ${c/arguments}"))
          (run_turn
            transport
            ((to_stream (outputs ~ Cell/get)) ~ into
              (append_all input_items (response_output_items resp)))
            render
            render_stream
            (- budget 1)
            emit))))))

# The interactive path adds one user item and stores the returned item list.
(items ~ Cell/set
  (run_turn_tracked live_transport
            (append (items ~ Cell/get) (user_item line))
            (fn [text]
              (render_agent_text transcript streaming text))
            (fn [text]
              (render_agent_delta transcript streaming text))
            max_tool_turns
            emit_event!))
```

The `emit` sink redacts every nested value at append (§9.2); that sink is the
load-bearing event-log invariant for `error`, `agent_text`, `turn_done`, tool
payloads, and future event types. The extra `redact` around streamed/final text
above is defensive because live rendering does not pass through the event
sink. Call sites must not be relied upon to remember event redaction.

### 9.1 Stable live session object

`/repl` is the agent's defining control surface, not merely an escape hatch.
The shipped REPL binds `session` to a stable `Session` value (a typed node whose
props hold the live cells and tool registry) rather than exposing incidental map
layout. The shipped projections are:

```text
session/config       session/items        session/transcript
session/memory       session/tools        session/events
session/workspace    session/current_task session/progress
```

(`evidence` arrives with slice B's later evidence work.) Reads use ordinary
selectors. Mutations go through messages so the session can keep invariants
(system-prompt memory refresh, persistence) and append an audit event:

```gene
(session ~ add_tool (Tool ^name "check" ^description "..." ^risk 'read
                          ^params [...] ^handler my_domain_check))
(session ~ remember "reader datum comments are spacing")
(session ~ subscribe "tool_call")     ; echo future events of this type
(session ~ trace "type=tool_call")    ; same filters as /trace
(session ~ resume)                    ; continue the current turn on exit
```

`add_tool` registers into the same typed registry the turn loop reads, so a tool
added or replaced from `/repl` reaches the very next model call. The API begins
small: it stabilizes the pieces needed to inspect a real turn, add/replace a
typed tool, query events, and continue — not every implementation field or a
general plugin system.

Live registration meets persistence through an explicit durability split
(invariant §0.15). A handler defined ad hoc in `/repl` is typically a closure
over live cells and environments; no serialization can honestly reconstruct
it. So a dynamically registered tool or worker operation is **ephemeral** by
default: its declaration (name, schema, policies) may be recorded for
inspection, but on restore the handler is disabled with a
`restore_record_rejected`-style attributable event — never silently dropped,
never resurrected from deserialized code. A **durable** registration instead
names its handler as a versioned module-qualified reference:

```gene
{^module "my/workflows" ^path "run_check" ^version "sha256:..."}
```

On restore, a matching version enables the tool, a compatible version
revalidates and migrates, and a missing or incompatible one disables it with
the attributable event. The same rule covers dynamically added worker
operations, hot-reloaded handlers, and any REPL-created callable retained by
session state — promoting a proven `/repl` experiment into a module (§10.9)
is exactly the act that makes it durable.

The native multi-agent slice extends this stable surface rather than exposing
TUI arrays:

```text
session/main_agent   session/agents       session/panes   (shipped)
session/workers                                           (C2)
```

Agent, worker, and pane mutations remain message-based (`spawn_agent`,
`stop_agent`, `agent_result`, `incorporate_agent_result`, `update_progress`,
`open_pane`, `close_pane`, `send_pane`, `stop_worker`, and the general
`call_worker` over the §7.2 operation tables) so
supervision, capability checks, events, and persistence cannot be bypassed by
mutating a list cell. `call_worker` makes the REPL a first-class worker
scripting surface — `(session ~ call_worker "w3" "run" {^command "nimble
test"})` drives the same typed operation as `/worker w3 run nimble test` —
while observe operations (`status`, `tail`, `snapshot`) give scripts bounded,
event-free reads of any worker. `session/panes` is the shipped projection of the local
TUI's panes; slice C2 moves pane/layout state into per-surface attachments
(§7.1), after which `session/workers` is the stable enumeration and
`session/panes` survives only as the local surface's compatibility view.
It is an empty projection in a headless session; new code inspects a concrete
`SurfaceAttachment` rather than treating pane state as a stable session field.
Focus, maximize, and layout are deliberately absent from the session surface:
they are presentation state owned by each surface attachment (§12.4), not
session state — a phone client must not observe or perturb the terminal's
focus. Worker and agent state persist with the session; pane/layout state
persists per surface (the TUI's local layout snapshot).

### 9.2 Authoritative event log and `/trace`

CLI and gateway share one append-only, versioned event vocabulary. The first
group below is shipped and includes attributable changes, verification checks,
memory, errors, and compaction. Slice C adds the agent/pane lifecycle group:

```gene
{^v 1 ^type "user_input"  ^text "..."}
{^v 2 ^type "model_item"  ^item {...}}
{^v 3 ^type "tool_call"   ^id "..." ^name "read_file" ^args {...}}
{^v 4 ^type "tool_result" ^id "..." ^value "..." ^truncated false}
{^v 5 ^type "text_delta"  ^text "..."}          ; streamed model text
{^v 6 ^type "agent_text"  ^text "..."}          ; the turn's final text
{^v 7 ^type "turn_done"   ^text "..."}          ; exactly one per turn
{^v 8 ^type "confirmation" ^risk "destructive" ^decision "deny" ^target "..."}
{^v 9 ^type "tool_registered" ^name "..." ^risk "read"}
{^v 10 ^type "file_change" ^id 1 ^path "src/x.gene" ^op "edit" ...}
{^v 11 ^type "check" ^command "nimble test" ^status 0 ^verified true ...}
{^v 12 ^type "context_compacted" ^removed_turns 3 ^retained_turns 8
 ^elided_tool_outputs 1 ^irreducible_over_limit false ...}
{^v 13 ^type "context_limit_warning" ^bytes 900000 ^items 9 ...}
{^v 14 ^type "memory" ^text "reader datum comments are spacing"}
{^v 15 ^type "error" ^text "transport failed"}

# Slice C lifecycle events (shipped with slice C)
{^v 16 ^type "agent_spawned" ^worker_id "a2" ^agent_id "a2"
 ^parent_agent_id "main" ...}
{^v 17 ^type "agent_status" ^agent_id "a2" ^status "working" ...}
{^v 18 ^type "agent_completed" ^agent_id "a2" ^task_id "t7" ...}
{^v 19 ^type "pane_opened" ^surface_id "local_tui:1" ^pane_id 2
 ^worker_id "w2" ^kind "output" ...}
{^v 20 ^type "pane_output" ^surface_id "local_tui:1" ^pane_id 2
 ^worker_id "w2" ^source_agent_id "a2" ...}
{^v 21 ^type "pane_closed" ^surface_id "local_tui:1" ^pane_id 2
 ^worker_id "w2" ...}

# Slice C2 worker lifecycle and presentation hints (shipped)
{^v 22 ^type "worker_started" ^worker_id "w4" ^kind "log_tail" ...}
{^v 23 ^type "worker_operation_started" ^worker_id "w3" ^task_id "t9"
 ^operation_kind "shell_command"}
{^v 24 ^type "worker_output" ^worker_id "w3" ^task_id "t9"
 ^seq 14 ^stream "stdout" ^text "..." ^projection false ^source_v nil}
{^v 25 ^type "worker_operation_finished" ^worker_id "w3" ^task_id "t9"
 ^operation_kind "shell_command" ^outcome "completed"}
{^v 26 ^type "worker_stopped" ^worker_id "w4" ...}
{^v 27 ^type "worker_started" ^worker_id "w5" ^kind "log_tail"
 ^restarted_from "w4"}
{^v 28 ^type "worker_retention_dropped" ^worker_id "w2"
 ^reason "stopped_worker_limit" ^limit 64}
{^v 29 ^type "worker_attention_requested" ^worker_id "a2"
 ^preferred_view "pane" ^title "reader review"}

# Dogfood hardening additions
{^v 30 ^type "worker_operation_finished" ^worker_id "a2" ^task_id "t10"
 ^operation_kind "agent_turn" ^outcome "failed"}
{^v 31 ^type "agent_finished" ^worker_id "a2" ^agent_id "a2"
 ^task_id "t10" ^outcome "failed" ^source_v 30 ^error_kind "TypeError"
 ^error_text "..." ^result_unread true}
{^v 32 ^type "restore_record_rejected" ^record_kind "pane"
 ^record_id "local_tui/6" ^error_kind "invalid_path" ^error_text "..."}
{^v 33 ^type "progress_updated" ^phase "verifying" ^status "active"
 ^summary "running repository gates" ^evidence_v [301 304]}

# Slice C4 worker-operations surface (target): additive caller attribution on
# the existing operation events; observe operations emit nothing.
{^v 34 ^type "worker_operation_started" ^worker_id "w3" ^task_id "t11"
 ^operation_kind "run" ^origin "worker" ^caller_worker_id "a2"}
```

Slice C2 adds `^worker_id` and `^surface_id` to pane events additively;
existing shipped types are never renamed. Pane events are observational
records of one surface's presentation (correlated by `(surface_id, pane_id)`);
`worker_attention_requested` is the only session-originated presentation
event, and it is a hint, not a command (§7.1). Focus and maximize changes are
not logged — they are presentation-only and would be pure noise next to
authoritative worker/agent events; local layout snapshots capture them
instead.

The worker boundary is canonical even with no pane: each operation emits one
start and exactly one finish (`completed|cancelled|failed`), and every produced
chunk carries the worker id plus a worker-local `seq`; task output also carries
its task id. `worker_operation_cancelling` is an intermediate request, not a
second terminal outcome. Every agent operation also emits exactly one
`agent_finished` carrying the same task id/outcome and bounded structured
result metadata. Its `^source_v` points to that operation's
`worker_operation_finished`; terminal-summary consumers render the richer
agent record and suppress the linked worker summary. The older
`agent_completed` remains an additive compatibility alias for successful
operations only and points to `agent_finished` through `^source_v`. Thus all
deduplication is structural rather than based on task text or timing. Failure
and cancellation are never represented as a return to plain `idle`. The
shipped agent text/delta and `pane_output` types
remain additive compatibility events. During this compatibility window each
streamed delta emits its legacy event plus a generic `worker_output`; a
non-streamed final `agent_text` does the same. The generic record carries
`^source_v` pointing at its source. After deltas, the complete `agent_text` is
terminal metadata and emits no second generic chunk, so neither client mode
duplicates the final answer. Agent-specific clients render legacy records and
ignore their generic aliases; generic worker clients render `worker_output`.
Deduplication never compares text. Non-agent
`worker_output` has `^source_v nil` and is canonical. Derived
`log_tail`/`stats` rows are
worker-snapshot state rather than journal events (§7.1), so they cannot amplify
or recursively consume their own source journal.

`run_turn` and `run_tool_call` write through an explicit **emit sink**: the CLI
passes its process-global logger, the gateway passes a per-session sink — so
each gateway session owns its complete tool trail without cross-session
interleaving. Every value is redacted at append.

The event log's contract is **authoritative journal, not event sourcing**:
live session state and its persisted snapshots are canonical for *execution*,
while the append-only event stream is canonical for *observation* — rendering,
audit, correlation, and surface cursors. Session-visible output and evidence
are projections of it; focus, maximize, drafts, scroll, and layout come from a
surface snapshot plus current worker projections. Because values are redacted at append, replaying
events is deliberately not guaranteed to reconstruct exact model context, and
no reducer is required to rebuild executable state from events alone. `^v` is
the per-session monotonic **cursor**, not a schema version: the vocabulary
evolves additively (new types and new props only; shipped types and props are
never renamed or re-typed), and an explicit envelope `^schema` field is
introduced only with the first incompatible change, so consumers assume
schema 1 when it is absent. Every surface consumes the same events. `/trace`
exposes type, tool name, path, worker/agent/task, event range, and current-turn
filters. Its default formatter is event-specific: terminal operations always
show ids, operation, outcome, duration, and bounded error text; tool and file
events show their primary target. `/trace ... --detail` prints the full
redacted, bounded record. `log_tail` uses the same formatters and filter parser,
while `/repl` can apply normal selectors and stream operations. Full
replay/fork/compare and sanitized trajectory fixtures are later extensions,
not requirements for the first event slice.

Persisted cursor fields such as result `^finished_v`, progress `^updated_v`,
and `^evidence_v` entries are soft references into the bounded journal. When a
cursor is below `dropped_before`, projections render an explicit placeholder
such as `evidence expired (v301)`; expiry is neither a restore error nor a
reason to silently omit the reference.

Events carry correlation ids where needed (`application_id`, `worker_id`,
`agent_id` — for agents the same value as `worker_id`, kept for compatibility
— `parent_agent_id`, `task_id`, `turn_id`, `tool_call_id`, `pane_id`),
module/tool version hashes once hot reload exists, and redaction/truncation
state. Pane events describe one surface's presentation and routing and are
observational only; worker/agent/tool events remain authoritative even when no
pane is open anywhere. They do not contain hidden
chain-of-thought; they record explicit plans, decisions, actions, results, and
evidence.

### 9.3 Native agent graph and supervision

The application has exactly one main agent and a bounded set of direct
sub-agents. C2 is a supervised **star**, not recursive delegation or
peer-to-peer swarm infrastructure:

```text
ApplicationSession
├── WorkerRegistry           owns every worker's lifecycle, one id space (C2)
│   ├── main   agent
│   ├── a2     agent (sub-agent of main)
│   ├── w3     shell
│   ├── w4     log tail
│   └── w5     stats
├── AgentRegistry            supervision index over the agent subset
│   └── main ── a2
└── workspace coordinator handle (process-level, keyed by workspace root)

SurfaceAttachment (per TUI/tab/client, §7.1)
└── PaneRegistry             pane -> worker id
    ├── pane 0 -> main (fixed)
    ├── pane 1 -> a2
    ├── pane 2 -> w4
    └── pane 3 -> w3
```

Identity is singular (invariant §0.2): every worker — agents included — has
exactly one session-stable worker id, and the `WorkerRegistry` owns worker
state (running/stopped lifecycle, current operation, last outcome, event
correlation) for all of them. An
agent is a worker subtype whose record adds supervision and model-context
metadata (parent id, assignment, item list, tool/capability view); the
`AgentRegistry` is an index over that subset and mints no second id and no
second lifecycle. Shipped events keep their `^agent_id` prop for
compatibility — for an agent, `agent_id` *is* its worker id. `/agent` verbs
remain sugar over the agent subset; `/worker` verbs address anything.

The main agent is the default focus target for bare input (§7.1 focus routing
may direct input elsewhere), and it alone is responsible for spawning,
explicit cancel-then-prompt continuation, cancelling, and incorporating
sub-agent results. A sub-agent starts
with its assignment, the relevant workspace instructions/memory, and an
explicit context attachment chosen by the parent; it does not receive the full
main transcript by accident. Attachments are **bounded copied snapshots**,
never live references: the permitted kinds are selected transcript items, file
excerpts (path plus range), memory entries, event references, and a
parent-written summary, each subject to size/count limits and redacted at
attach time. A child must not retain a mutable reference into the parent's
item list or session cells, and the `agent_spawned` delegation event records
attachment kinds and content digests so the parent can later show exactly what
context the child received. Its final result is emitted as a structured child
result into the main agent's bounded, persisted supervisor inbox. Completion,
failure, and cancellation all create a result; the main surface immediately
shows a bounded notification such as `a2 failed — /agent a2 result`, and
`/agents` reports availability and last outcome separately. Results begin
unread and are never consumed by an unrelated slash command. `/agent A result`
displays and marks one read without changing model context; `/agent A
incorporate` explicitly appends a compact child-result item linked to the
original delegation. Model-driven supervision uses the typed `agent_result`
operation as its explicit incorporation boundary. The child's private
transcript and tool chatter are not copied into the main context.

Sub-agents may run concurrently because model and read-only tool work is
independent. Shared-workspace mutation is coordinated separately from agent
scheduling, and the coordinator is **process-level, keyed by canonical
(realpath) workspace root** — not per session (invariant §0.1). The gateway
can create several sessions; if two of them point at the same workspace, they
share one coordinator and one mutation lease, otherwise the single-writer
guarantee evaporates exactly when it matters. Two independent agent
*processes* on one workspace are outside this guarantee entirely; C5 adds an
advisory ownership check (lockfile/heartbeat with a visible warning, §10.8),
and full cross-process lease arbitration stays deferred until routine
multi-launch use demands it. The coordinator grants at most
one mutation lease at a time for `write_file`, `edit_file`, `/undo`, and
similar operations. Shell commands take the lease by default because reliably
proving that an arbitrary command is read-only is harder than serializing it;
narrowly classified read-only commands may opt out later. Pure file reads and
model requests may overlap. Because worker ids are only session-stable and
therefore collide (`main`, `a1`, `w1`), coordinator owners and waiters are keyed
by `(application_instance, worker_id)`, never by worker id alone; one session's
stop or shutdown cannot release another session's lease.

The lease covers a mediated subprocess until its tracked process/task settles.
To keep that boundary honest, `/sh`, shell-worker input, remote shell-worker
input, and model `run_shell` reject the high-confidence background/detach forms
listed in §8.5 before admission or lease acquisition. `/tty` is the explicit
local escape and holds the lease only for the terminal handoff itself. The
application does not claim OS-level containment: a binary which daemonizes
internally can escape descendant tracking, so exact serialization ends with
the cooperative foreground process while that exceptional descendant is
best-effort/out-of-contract. An acceptance test proves a recognized background
writer is denied and never runs after the lease would have been released.

Mutating operations follow one ordering. Confirmation happens **before** the
lease so that human think time never holds the process-wide single-writer
lease hostage — one unattended prompt must not block every other session's
normal writes on that workspace:

```text
classify -> request confirmation (if destructive) -> acquire workspace lease
         -> revalidate target/state -> execute -> append events -> release
```

A confirmation binds a digest of the normalized command/operation and its
displayed target. After the lease is acquired, paths are re-resolved and the
state the confirmation displayed is rechecked; a material change denies the
stale approval (or requests a fresh confirmation) rather than letting it
authorize a different target. "At most one pending confirmation per session"
remains a session-actor rule and is unaffected by lease scheduling.

The lease is released on completion, timeout, cancellation, failure, and
worker stop alike. Lease requests are FIFO; cancelling a worker that is still
queued dequeues it. `/tty` is the explicit fairness exception: it owns the
lease until the human exits, and status surfaces name that owner so another
session does not merely appear hung.

Input admission first installs the short-lived reservation from §7.1. For
operations requiring local preflight, classification and destructive
confirmation happen while that reservation is visible but before a host Task
or workspace lease exists. Denial clears the reservation and emits its
confirmation/result events without inventing an operation start. Once
preflight succeeds, Task installation and `worker_operation_started` occur in
one scheduler turn; lease waiting is inside that operation, so cancellation
while queued produces its one `cancelled` finish and revalidation failure its
one `failed` finish. Stop revokes either a reservation or the installed Task.
Cancellation/stop invalidates the confirmation id and lease request id; a late
confirmation is stale, and a lease grant racing with dequeue is immediately
released without host execution. Exactly one transition installs the
operation's terminal outcome. C2 keeps
the shipped remote rule that a
gateway/headless destructive operation denies immediately, so no invisible
prompt parks a task. The optional §12.8 extension replaces that denial with a
deadline-bound reply channel broadcast to authorized interaction adapters;
the first response wins and disconnect does not cancel it. The lease owner and
resulting `file_change` events are attributable to a worker and task.
Per-agent worktrees remain an optional later isolation strategy, not a
requirement for native sub-agents.

Stopping an agent cancels its current model request and subprocesses, releases
its mutation lease, marks it terminal, and preserves its event trail. Closing
an attached pane only detaches the view. A completed sub-agent can be retained
for inspection or explicitly stopped after its result is incorporated. The
application enforces a configurable small concurrency/count bound. Only the
main agent receives the supervision tools; every C2 `parent_agent_id` is
`main`. The field remains general so a later recursive design can evolve
additively, but recursion is not part of this contract.

Persistence splits along the session/surface boundary: the session records
the worker/agent graph, durable item histories, statuses, assignments, and
event correlations; each surface persists its own pane descriptors and layout
under a surface key (the TUI's local layout snapshot). Output workers may
restore their buffered projection. Shell and REPL processes are not pretended
to survive a crash: restoration shows their captured history on a stopped
worker and requires an explicit reopen. No process-local Task, admission
reservation, confirmation, lease owner, or lease waiter is resumed. A
previously busy agent restores running and idle and emits an attributable
failed `worker_operation_finished` plus its canonical failed `agent_finished`
and unread structured result (or a legacy normalization record when an old
snapshot lacks the task id); a pending reservation emits
`worker_admission_cancelled`. Records install independently after the session
core: a malformed pane, confined path, projection, or obsolete worker record
emits `restore_record_rejected` and is skipped rather than aborting startup.
Mutation execution is never retried from snapshot state. No persistence format
stores raw terminal state or secrets.

### 9.4 Main project progress

Runtime `Task` values describe cancellable execution; they are not a project
plan. The application therefore keeps one bounded, main-agent-owned
`ProjectProgress` record for the current user objective:

```gene
{^objective "add durable background jobs"
 ^phase "verifying"                 ; planning|research|implementing|verifying|handoff
 ^status "active"                   ; active|blocked|complete
 ^summary "running repository gates"
 ^blocked_reason nil ^required_action nil
 ^updated_v 304
 ^agent_ids ["a1" "a2"] ^worker_ids ["w1"]
 ^evidence_v [287 301 304]}
```

The main agent updates it through a typed `update_progress` operation; the user
can inspect it with `/progress`. Transitions emit `progress_updated`, checkpoint
immediately, and appear as one concise status-bar line. Evidence links point to
bounded authoritative events rather than copying logs; evidence that must
outlive the journal window points to durable artifact ids (§9.5) instead. A
blocked state carries
non-nil `^blocked_reason` and `^required_action`; other states omit or nil both.
Sub-agents may report progress in their own result/event stream but cannot
overwrite the main project record.

### 9.5 Durable artifacts

The bounded journal, bounded worker output, and expiring evidence references
are the right shape for a responsive live application — but they are *restart*
persistence, not knowledge persistence. A verification transcript, a diff, an
agent's research summary, or a benchmark comparison can age out of every
retained window, and today the design deliberately renders an expired
reference rather than keeping everything. The missing piece is explicit
**promotion**: the user (or the main agent, through a typed operation) pins a
live value into a durable, content-addressed artifact:

```gene
(Artifact
  ^id "sha256:..."              ; content hash; storage is deduplicated
  ^kind "verification"          ; verification | diff | result | note | capture
  ^mime "text/plain"
  ^source_worker "w3" ^source_task "t11" ^created_v 9021
  ^content "...")
```

Artifacts live in the same Store as the session (fs records or SQLite rows),
are bounded in count/total bytes with the standard refuse-then-explicit-delete
policy rather than silent eviction, pass redaction at promotion time, and are
never silently exported off the machine. Surface commands:

```text
/pin result [A]        # promote an agent's latest structured result
/pin worker <W> tail   # promote a worker's current bounded output
/artifacts             # list: id prefix, kind, source, age, size
/artifact <id>         # open one in a read-only view
```

`pin` is a `session_write` operation in the §7.2 table (audience: user and
supervisor), so a model can preserve its own verification evidence
attributably. `ProjectProgress/evidence` and agent results may reference
artifact ids where they currently reference journal cursors; soft `^v`
references remain correct for ordinary transient evidence.

### 9.6 Dogfood rule

The quality bar is whether the author voluntarily uses this agent to build
Gene. Repeated friction observed during that work chooses the next feature.
Competitor parity does not. When a real failure is instructive, sanitize the
smallest event sequence into a deterministic fake-model/tool regression test.

## 10. Product strategy and staged plan

The feature inventory in this document is a menu. This section is the official
order. Each slice must improve daily dogfooding and remain independently
testable.

### 10.1 Shipped foundation

The previous numbered milestones remain useful as implementation history:

- **Bootstrap 1–4:** `os`, `json`, streaming model loop, file/shell tools,
  multiline prompt, minimal catastrophe guard, and fake-transport tests.
- **Async/gateway 8:** async subprocesses, concurrent session actors, HTTP/JSON
  API, cursor long-poll, bearer auth, and embedded web chat.
- **Telegram 9:** allowlisted Telegram sessions and streamed replies.
- **Persistence 11:** SQLite gateway sessions/events plus `store/fs` CLI
  config, session, and `/remember` memory.

These shipped pieces prove the transport, tool loop, actor concurrency, event
delivery, and persistence patterns needed by the next work. Historical numbers
are retained in §12 where they explain existing code; they no longer define the
forward priority order.

### 10.2 Slice A — program the agent that exists (shipped)

1. **Done.** The duplicated tool map/schema list is replaced by typed `Tool`
   declarations; the registry entry, model-facing JSON Schema (both wire
   shapes), argument validation, and risk class all derive from one value
   (§6, §9.1).
2. **Done.** `/repl` binds a stable `Session` object with message-based
   mutations (`add_tool`, `remember`, `subscribe`, `trace`, `resume`) (§9.1).
3. **Done.** CLI and gateway emit one versioned event vocabulary — `user_input`,
   `model_item`, `tool_call`, `tool_result`, `agent_text`, `text_delta`,
   `turn_done`, `tool_registered`, `file_change`, `check`,
   `context_compacted`, `context_limit_warning`, `confirmation`, `memory`,
   `error` (§9.2, §12.3).
4. **Done.** `/trace` filters the log by `type`/`tool`/`path`/`turn`/`from`/`to`
   (a bare token is shorthand for `type=`); the `session` object exposes the
   same filters.
5. **Done.** The §8.5 guard realpath-confines file paths, classifies commands as
   normal/destructive/catastrophic, surfaces output truncation, and redacts
   known secrets — all without prompting for normal work.
6. **Done.** Deterministic fake-model tests cover derived-schema-on-the-wire,
   catastrophe denial, event/trace behavior (`tests/test_cli.nim`), and
   `Fs/real_path` (`tests/spec_runner.nim`).

The shipped signature demo is deliberately one main session: inspect live state
in `/repl`, add or replace a typed Gene tool, query the event trail, and
continue the same turn. The native multi-agent slice builds on that control
plane; it still requires no MCP, worktrees, browser, or additional provider
protocol.

### 10.3 Slice B — make it the best daily driver

Choose exact ordering from dogfood pain:

- **Done:** tracked turn Tasks, subprocess termination, `Session/cancel`,
  gateway busy state, `POST /api/sessions/:id/cancel`, and terminal Ctrl-C
  cancellation followed by an explicit continuation prompt;
- **Done:** `/diff`, targeted `/undo`, and preservation of pre-existing changes;
- **Done:** structured command/test/benchmark evidence and explicit unverified
  claims;
- **Done:** approximate context visibility plus deterministic whole-turn
  compaction preserving system/workspace instructions, remembered decisions,
  recent turns, and tool-call/output integrity. If the retained floor is still
  oversized, oldest tool output text is replaced without separating its call
  pair; irreducible user/system content is surfaced explicitly;
- **Done:** dogfood feedback improvements: structured reader opener contexts,
  immediate `.gene` write/edit parse warnings, bounded edit mismatch excerpts,
  configurable shell timeouts, `List/push!`, and configurable tool-round
  landing notices;
- prompt/TUI improvements where the current UI causes friction;
- **Done:** hierarchical `AGENTS.md` loading for work outside the Gene
  repository.

### 10.4 Slice C — native multi-agent application

1. **Done.** Introduce independent `AgentRegistry`, `PaneRegistry`, and
   `WorkspaceCoordinator` application services with stable ids and events;
   migrate the current extension conversations onto them without changing the
   visible secondary-agent behavior.
2. **Done.** Make the main agent a supervisor. Add bounded
   spawn/send/cancel/stop/result
   operations and explicit context attachments; expose them through stable
   `session/agents` and typed model tools.
3. **Done.** Generalize right-side panes to the four bootstrap kinds (agent,
   output, shell, repl; §7.1 now extends these into the slice C2 worker
   model). Add output panes, and move `/sh` and `/repl` from whole-terminal subsessions
   to scheduler-owned interactive panes.
4. **Done.** Allow concurrent sub-agent turns and read-only work, with attributable
   events and a single shared-workspace mutation lease. Prove cancellation,
   lease release, foreground-shell enforcement, bounded spawning, and result
   delivery with deterministic fake models and PTY tests.
5. **Done.** Persist the agent graph and pane layout while restoring shell/REPL panes as
   closed history rather than fake live processes. Fold gateway startup into
   the main program behind `--gateway[=PORT]`/`--headless`; keep
   `gateway.gene` only as a thin compatibility launcher. The in-process TUI and
   optional network adapters must address the same application services.

Acceptance (met by the shipped slice): the main agent can delegate two
independent review tasks, the user can interact with either sub-agent while
both are running, a third output pane can follow verification events, and a
shell or REPL pane can run without suspending input/rendering in the rest of
the application. Starting that same program with `--gateway` exposes the
already-live local session to the web/API while the TUI remains responsive;
`--headless` and the temporary `gateway.gene` wrapper expose the same API
without constructing curses.

This was structural acceptance, not the final operability bar: C3 owns visible
terminal outcomes, explicit result incorporation, command discovery, dense-pane
management, and record-isolated restore.

### 10.5 Slice C2 — one worker model for the TUI

Slice C shipped the registries and concurrency. This follow-up unifies the
interface model around §7.1 workers and interfaces under the §0 invariants;
order within the slice comes from dogfood pain:

1. **Done.** Introduce the single worker id space: the `WorkerRegistry` owns every
   worker's state (agents included, one id each — invariant §0.2; lifecycle
   `running|stopped`, current operation, last outcome), the `AgentRegistry`
   becomes a supervision index, and the shell/REPL/output controllers migrate
   to workers (including the bounded `output` worker) with
   pane-independent operation/output/start/stop events, restart-mints-a-new-id semantics
   (`^restarted_from`), and a `/workers` listing — without changing visible
   secondary-agent, `/sh`, or `/repl` behavior.
2. **Done.** Move panes, layout, focus, and zoom into per-surface attachments with the
   §7.1 surface-identity contract (`local_tui` key and browser-local layouts;
   invariant §0.3); the session keeps no pane state,
   `session/panes` becomes the local surface's compatibility view, and
   model/session presentation becomes `worker_attention_requested` hints —
   `pane_opened` fires only when a real surface opens a pane and carries
   `^surface_id`.
3. **Done.** Key the workspace coordinator by canonical workspace root at process level
   (invariant §0.1) and implement the §9.3 ordering — confirm before lease,
   digest-bound revalidation after lease, release on
   timeout/cancel/failure/stop, dequeue-on-cancel.
4. **Done.** Make the main transcript pane 0. Upgrade focus to input routing with the
   surface-first parsing grammar (`//` literal escape), the route named in the
   input row and status line, the documented Escape priority order (including
   the non-empty-draft no-op branch), `/N max`, the narrow-terminal
   full-width-focused-pane fallback, and the `/sh` (worker pane) vs `/tty`
   (real-shell escape) split. PTY-test focus/zoom/reset, the Escape-with-draft
   case, and the "never type into an invisible or wrong worker" guarantees.
5. **Done.** Add `/edit` external composition over the shared curses suspend/resume
   handoff and the editor-resolution rules shared with
   `docs/proposals/editor.md`; suspension is surface-local and pauses nothing
   in the application.
6. **Done.** Add the `stats` and `log_tail` projection workers over existing state; the
   `/tail` filter shares the `/trace` parser rather than growing a second
   syntax.
7. **Done.** Add the `file_view` MVP as wrapped read-only text, with workspace
   `safe_path` confinement for every shared view, regardless of initiating
   adapter; adopt the structural viewer model
   from `docs/proposals/editor.md` only when that work lands.
8. **Done.** Implement the §7.1 bounded-ring overflow contract (drop-oldest with loss
   metadata) across output buffers, projections, surface caches, and the
   event journal; bound retained stopped-worker snapshots; add the §12.2
   cursor-gap plus snapshot/resume response and the typed `POST /workers`
   creation route. Derived projection rows stay out of the source journal.
9. **Done.** Make session-actor input admission reject-while-busy across every adapter;
   reserve before acknowledging an HTTP request so simultaneous surfaces
   cannot both receive acceptance for one worker operation slot.

The slice is complete when the §0 invariants hold observably: a focused shell
pane can be used bare-handed while a sub-agent runs; Escape layering behaves
exactly per the documented order, including leaving a composed draft and its
route untouched; a maximized log tail follows a verification run and restores;
`/edit` round-trips a multi-line draft through `$EDITOR` while a remote turn
keeps streaming; two sessions on the same workspace share one mutation lease,
an obvious background writer is denied before it can escape that lease, and an
unattended confirmation blocks neither; a headless `open_pane` yields a
worker plus a hint but no `pane_opened`; an overflowed output worker reports
its dropped range and a stale gateway cursor receives an explicit gap followed
by a coherent snapshot/resume; simultaneous inputs to one busy worker produce
one acceptance and one typed busy rejection; several live projection workers
do not multiply authoritative journal records and are invalidated through
`changed_worker_ids`; one compatibility agent chunk has a structural
`source_v` alias and renders once per client mode; restore clears dead
tasks/reservations without retrying mutations; a sub-agent cannot recursively
spawn another; an arbitrary host file rejected by shared `/pane new view` never enters a
remote or persisted snapshot; and a gateway client sees identical session
state regardless of local panes, focus, or zoom.

### 10.6 Slice C3 — make the worker model operable and recoverable

The worker model is structurally complete, but the tmux 12.0 complex-project
dogfood flow exposed failures that block routine use. Fix them in this order:

1. **Restore isolation.** Remove executable/ad-hoc type checks from persisted
   record validation, load the main session before surface records, quarantine
   bad records, and pass the all-worker/all-pane-kind restart fixture with one
   malformed pane. No view record may prevent startup.
2. **Terminal agent results.** Normalize every tool/result value at its
   boundary, preserve structured failures, emit exactly one `agent_finished`
   for every outcome, and expose last outcome plus unread result through CLI,
   REPL, gateway, and snapshots. Successful and failed research turns both
   notify main; only explicit result/incorporate actions affect model context.
3. **Safe, discoverable commands.** Ship comprehensive `/help` and identical
   `/?`, plus the canonical `/pane`, `/agent`, and `/worker` grammar from §7.1;
   generate help from the parser registry, retain short aliases, accept
   `/focus 0`, and reject unknown slash commands locally. Help always renders
   in pane 0, while status help is contextual and teaches `/0 main` off the
   main route.
4. **Usable pane operations.** Add pane listing/switching/hiding, the
   minimum-height focused-right-pane layout, output append/follow operations,
   pane/worker ids in one report, and read-only editor behavior. Up/Down remain
   input history.
5. **Observable coordination.** Add detailed shared trace/tail formatters,
   explicit `ProjectProgress`, unread-result indicators, and a repaint/input
   stress test with rapid child events. Coalesce presentation refreshes so
   worker output cannot starve command acknowledgement.

Slice C3 is complete only when the complex-project dogfood flow works without
consulting this design: start a research agent, return to main, open and use
shell/tail/output/file/stats panes, observe a success and a failure, incorporate
one result explicitly, exit, and restore the session. The TUI must teach every
required command in context, a command-shaped typo must execute nowhere, and
one corrupt pane record must be visible but non-fatal.

### 10.7 Slice C4 — every worker's functionality is a shared, typed surface

C3 makes workers operable by the user; C4 makes the same functionality
uniformly reachable by peers and scripts (§7.2, invariants §0.14). Steps:

1. Introduce per-kind **operation tables**: one declaration — with argument
   and result schemas that are real Gene type values — derives validation,
   slash dispatch, the `call_worker` session message, the gateway route,
   model-tool access, and help, mirroring the §6 `Tool` derivation so nothing
   registers twice. New declarations start Gene-typed; the shipped `Tool`
   `^params` string maps remain a compatibility form that migrates onto the
   same type-derived path.
2. Ship the universal **observe** operations (`status`, `tail`, plus `snapshot`
   for stats): admission-free, journal-event-free under `none` audit, bounded
   with loss metadata. A busy worker is always observable *by an authorized
   audience*: user and supervisor always, a sub-agent only for workers
   delegated to it in its context attachment — a worker id alone is never
   authority.
3. Ship the `call_worker` model tool and session message with declared
   effect/audience/admission/audit enforced at one choke point. `cancel` and
   `stop` use `interrupt` admission and succeed against a busy worker;
   `worker_exclusive` operations keep the typed reject-while-busy contract;
   `repl eval` remains user-originated and is rejected for every other caller
   with a typed error. Split `result` (pure observe) from `mark_result_read`
   and `incorporate` (idempotent session writes); `/agent A result` becomes a
   declared surface composite over the primitives.
4. Add **stateful `shell run`** on an explicit worker (persistent cwd/env)
   as distinct from one-shot `run_shell`; identical classification, lease,
   and events.
5. Add optional unique worker `^name`s accepted wherever an id is accepted;
   ids remain canonical in events and snapshots.
6. Add the C4 gateway routes and the additive `^origin`/`^caller_worker_id`
   props on `worker_operation_*` events (plus bounded access records for
   `attributed` observes); extend `/help worker <kind>` to render the kind's
   operation table from the same declaration.

The slice is complete when the main agent supervises a busy verification
shell by `tail`/`status` without opening a pane, a `follow` link, or journal
events, while a sub-agent's identical call is rejected until the worker is
delegated to it; `cancel` succeeds against a busy worker from every adapter;
the main agent runs a multi-step stateful shell sequence through
`call_worker` with each step classified, leased, and attributed; a `/repl`
script drives a log tail's filter by worker *name* and reads its `status`; a
model attempt to `eval` in a REPL worker is denied with a typed error and an
attributable event; gateway `GET result` provably does not mutate read state
while `mark_result_read`/`incorporate` stay idempotent; and the same
operation invoked from CLI, REPL script, model tool, and gateway produces
byte-identical journal records except for `^origin`/`^caller_worker_id`.

### 10.8 Slice C5 — durable knowledge and storage hardening

C4 makes the live system uniform; C5 makes what matters survive it
(invariants §0.15/§0.16). Steps, ordered by risk:

1. **Checkpoint generations**: schema-versioned, hash-validated, atomic per
   backend (single SQLite transaction; fs generation + fsynced manifest +
   atomic `CURRENT` update); restore picks the highest complete generation
   and never mixes generations. Schema versions and pure migration functions
   for every persisted record kind, with quarantine as fallback.
2. **Durable vs ephemeral registration**: versioned module-qualified
   `HandlerRef`s for tools and worker operations; ephemeral handlers restore
   disabled with an attributable event. Promotion of a `/repl` experiment to
   a module is the durability boundary (§9.1).
3. **Durable artifacts** (§9.5): content-addressed promotion via `/pin` and a
   typed `pin` operation, bounded with explicit deletion, redacted at
   promotion; progress/results reference artifact ids where evidence must
   outlive the journal ring.
4. **At-rest policy**: owner-only file modes, never-served store files, the
   explicit redacted-vs-full choice on any future export; encryption-at-rest
   stays a documented later option.
5. **Cross-process workspace advisory**: a lockfile or store-backed lease
   with process identity and heartbeat under the workspace root; a second
   Gene agent process opening the same workspace sees a prominent warning
   naming the owner. Full cross-process lease arbitration remains deferred —
   the in-process coordinator contract (§9.3) is unchanged.
6. **Progressive disclosure and the four-axis help system** (§7.1): layered
   `/help` → `/help <topic>` → `/help all` → `/help <command>` pages derived
   from declarations; contextual did-you-mean diagnostics; `/help search`;
   and the `/`-palette. Worker names (C4) carry the same goal: ids, kinds,
   and operation tables are expert surfaces, not prerequisites.
7. **Input editor completion** (§7.3): the single transient overlay-list
   primitive; context-sensitive `Tab` completion sourced from the command
   registry, operation tables, and live session state under §7.2 audience;
   `Ctrl-R` incremental history search per worker; `Ctrl-E` bound to `/edit`.
   Persistent mouse-driven menu bars stay deferred until keyboard overlays
   prove insufficient.

The slice is complete when a kill -9 during a checkpoint restores the prior
complete generation with no mixed records; an ephemeral `/repl` tool restores
visibly disabled while its module-promoted twin restores enabled with a
version match; a pinned verification artifact survives journal eviction and
restart and is reachable from `/artifacts` and a progress evidence link; a
second agent process on the same workspace warns with the owner's identity;
and a new user completes the §10.6 dogfood flow using only default `/help`.
The input-editor bar (PTY-tested): `Tab` after `/worker ` completes only
workers the caller may observe, annotated with kind and status; on a shell
route it completes confined workspace paths; `Ctrl-R` finds an earlier shell
command without crossing routes and never auto-submits; `Ctrl-E` round-trips
the draft through `$EDITOR` mid-turn; an unknown command's diagnostic names
the nearest registered command; and an overlay dismissed with `Escape`
leaves the draft, route, and journal byte-identical to before it opened.

### 10.9 Slice D — expand only where leverage is proven

- Promote repeated `/repl` experiments into small Gene workflow modules;
  record module/tool version hashes and hot-reload new calls without changing
  already-running calls.
- Add hook points only after the same manual workflow repeats. Add a Gene-aware
  module/symbol map if raw search becomes a measured bottleneck, and stable
  JSONL automation if scripting the agent becomes useful.
- Orchestrate `git worktree` only when parallel edits are genuinely useful;
  worktrees are greenfield subprocess orchestration, not a current runtime
  primitive.
- Add MCP only when a needed integration justifies its greenfield protocol,
  transport, authentication, and lifecycle surface.
- Add browser/visual automation only when frontend work becomes frequent.
- Extend TUI/web/chat surfaces only when they improve the author's workflow.
- Extend the native client only when proxy controls, certificate pinning,
  WebSockets, or measured performance provides a user-visible reason.

There is no obligation to complete slice D. A personal agent with typed tools,
live state, queryable events, reliable edits, and excellent Gene support is
already a killer application and language demonstration.

Every implemented slice follows the repository gates: `nimble test`, `nimble
spec`, `nimble perf`, and `nimble wasm` before commit (or `nimble verify` for
broad/risky runtime changes); performance regressions must remain visible.

## 11. Non-goals for the personal tool

- Windows terminal support (curses assumes a Unix TTY);
- a full provider abstraction — the agent speaks the OpenAI Responses shape
  and the OpenAI-compatible Chat Completions shape (which covers MiniMax,
  DeepSeek, vLLM, and most hosted/self-hosted gateways); a first-class `Chat`
  protocol over non-OpenAI wire formats (e.g. Anthropic's) can follow the
  `Db` protocol precedent later;
- multi-user or multi-tenant operation — the gateway (§12) stays a
  **single-user** tool: one bearer token, one workspace owner, allowlisted
  chat ids; no accounts, roles, or per-user isolation;
- general permission modes, default-on approval prompts, enterprise policy,
  compliance controls, and OS/process-level sandboxing (`seccomp`, containers,
  `chroot`) beyond the explicit capability values and §8.5 catastrophe guard;
- crash-safe exactly-once recovery — controlled stop/reload is sufficient until
  dogfooding demonstrates that crash consistency repays its complexity;
- a large formal eval/analytics program — deterministic harness tests plus
  small regressions captured from real Gene work are the quality mechanism;
- MCP, worktree orchestration, browser automation, a general multi-language
  code graph, and decentralized or unbounded agent teams as prerequisites;
  each remains optional slice-D work triggered by actual use. One main agent
  with a bounded set of supervised sub-agents is the core slice-C design;
- TLS certificate pinning and proxy configuration.

## 12. Local-first main program and multi-surface adapters

One long-running **main program** owns every application session. An
application session contains one main agent, its supervised sub-agents, and
the process/projection workers — it is not synonymous with one model
conversation. Panes and layout belong to each attached surface (§7.1), and
workspace coordination is process-level, keyed by workspace root (§9.3,
invariants §0.1/§0.3). The main program always starts this same core and then
attaches surfaces:

- by default, only the in-process terminal TUI;
- with `--gateway[=PORT]`, the TUI plus HTTP/web and any configured channel
  adapters;
- with `--gateway --headless`, only the network/channel adapters.

The word **gateway** therefore names an optional adapter set and exposed API,
not a second executable architecture. The local TUI calls application services
directly; it must not serialize through localhost HTTP merely because the
gateway is enabled. Remote surfaces use the same commands and event projections
through the HTTP/channel adapters. A session started in the terminal can thus
be continued from the phone without copying state between a CLI agent and a
gateway agent.

```text
                         ┌──────────────────────────────────┐
  ┌──────────┐  direct   │        main agent program        │
  │ TUI      │◄─────────►│                                  │   libcurl (async)
  └──────────┘           │  application/session actors:     │◄───────────────► model
                         │  main + sub-agents, workers,     │   Responses/chat APIs
  ┌──────────┐  HTTP     │  tools, guard, event log;        │
  │ Web UI   │◄─────────►│  per-workspace coordinator;      │
  ├──────────┤           │  panes live on each surface      │
  ├──────────┤  +JSON    │                                  │   libcurl (async)
  │ remote   │◄─────────►│  optional gateway adapters       │◄───────────────► channels
  │ clients  │  events   │  + sqlite persistence            │
  ├──────────┤           │                                  │
  │ channels │◄─────────►│                                  │
  └──────────┘           └──────────────────────────────────┘
```

Design rules: every piece reuses a pattern already proven in this repo, every
new host power is a capability value, and each addition is independently
shippable and testable over loopback with fake endpoints.

### 12.1 Main process, adapters, and session actors

**Shipped foundation:** `tui.gene` is the primary composition entrypoint and
parses the §1 flags. `gateway_adapter.gene` is UI-neutral and receives the
agent core as an explicit API value; it contains the milestone 8 HTTP
API/long-poll/auth/web page, milestone 9 Telegram channel, and milestone 11
SQLite persistence. `gateway.gene` is a thin compatibility launcher over those
same two modules. Every gateway session owns an `AgentApplication` and uses its
worker/agent registries, task cells, event sink, and handle to the process-level
per-workspace coordinator; only concrete layout surfaces own pane attachments
(§7.1, §9.3).
The adapter retains only the session actor/router map needed for per-session
mailbox ordering. In combined mode it also registers the already-live TUI
application as stable session `local`, so HTTP can observe, message, and cancel
the same main agent while curses remains responsive.

Startup order is deliberate: parse and validate application flags, construct
the core and restore durable state, bind the requested HTTP listener, and only
then open curses. A requested port that is invalid or unavailable fails before
terminal mode changes. `net/http/serve` remains the root scheduler-driving
event loop in combined mode and the local TUI runs as its sibling Task;
spawning `serve` inside the TUI fiber would create a recursive scheduler pump
and starve terminal input. `/quit` or `/exit` in combined TUI+gateway mode
performs one controlled shutdown of adapters, agent/process tasks, persistence,
and curses; headless mode runs until an explicit shutdown or process signal. An
unexpected loss of the requested HTTP listener is surfaced as a fatal
application error rather than quietly leaving a supposedly shared session
local-only. Optional channel failures remain isolated and retry according to
their adapter policy.

The main process owns a registry of application sessions. The TUI attaches to
one designated local session; HTTP/channel routes may address it or create
additional sessions. Each application session is a **session actor**
(`actor/spawn`, design.md §13) owning:

- an agent registry with exactly one main agent and zero or more bounded,
  supervised sub-agents; each agent owns its Responses-style model item list
  (the chat adapter normalizes wire formats at the boundary);
- the non-agent workers described in §7.1 (shell, REPL, output, log tail,
  file view, stats; slice C2 indexes all workers in one registry). Pane
  registries now live in per-surface attachments; the session keeps no pane
  state (§7.1, invariant §0.3);
- a monotonically versioned **authoritative event log** (12.3), from which
  shared transcript/worker observations are projected; panes, focus, drafts,
  zoom, and scroll come only from each surface attachment;
- model config (base/model/flavor per session, defaulted from env as today);
- the typed tool registry, a handle to the process-level per-workspace
  mutation coordinator (§9.3, invariant §0.1), the §8.5 catastrophe guard, and
  at most one pending destructive-operation confirmation (12.8).

The session actor serializes control-plane transitions — worker/agent
creation and stop, lease requests toward the per-workspace coordinator, event
append — while agent model requests and read-only tasks run concurrently under
the scheduler. Pane and layout changes are not session transitions: each
surface attachment serializes its own (§7.1). This keeps state deterministic
without forcing all sub-agent work through one turn lock.
The existing task-per-request `net/http` model and `http/actor_pool` remain the
in-repo precedent for routing requests into actors via `RequestMsg`/reply.

### 12.2 Gateway API (HTTP + JSON)

When `--gateway[=PORT]` is enabled, the adapter serves this API through the
existing `net/http` server. It binds to `GENE_GATEWAY_HOST` or `127.0.0.1` by
default. A single static bearer token (`GENE_GATEWAY_TOKEN`) is checked on every
request when set. An unset token is permitted only on a loopback bind;
non-loopback startup without authentication is rejected — single-user posture
(§11), no accounts.

| Route | Meaning | Status |
|---|---|---|
| `POST /api/sessions` | create session → `{^id ...}` | shipped |
| `GET  /api/sessions` | list sessions with event version and busy state | shipped |
| `POST /api/sessions/:id/messages` | append a user turn; returns immediately | shipped |
| `GET  /api/sessions/:id/events?cursor=N` | **long-poll**: events after N plus non-journal `changed_worker_ids`, or park until one arrives | shipped |
| `GET  /api/sessions/:id/snapshot` | atomically bounded shared session/worker projection plus event cursor | shipped |
| `POST /api/sessions/:id/confirmations/:cid` | resolve a rare destructive-operation confirmation | planned |
| `POST /api/sessions/:id/cancel` | cancel the in-flight turn and its subprocess | shipped |
| `POST /api/sessions/:id/agents` | spawn a supervised sub-agent with assignment/context attachment | shipped |
| `POST /api/sessions/:id/agents/:aid/messages` | prompt a particular idle agent (busy rejects; steering remains explicit cancel-then-prompt) | shipped |
| `GET /api/sessions/:id/agents/:aid/result` | inspect the bounded latest result without changing its state | C3 |
| `POST /api/sessions/:id/agents/:aid/result/read` | explicitly mark that result read, idempotently | C3 |
| `POST /api/sessions/:id/agents/:aid/incorporate` | explicitly add that result to main context, idempotently | C3 |
| `POST /api/sessions/:id/agents/:aid/cancel` | cancel that agent's active operation without stopping it | shipped |
| `DELETE /api/sessions/:id/agents/:aid` | stop a sub-agent and preserve its event trail | shipped |
| `GET /api/sessions/:id/workers` | list workers: kind, lifecycle, current operation, last outcome, unread result | C3 extension |
| `POST /api/sessions/:id/workers` | create a typed worker: `{kind, config}` → `{worker_id}` | shipped |
| `POST /api/sessions/:id/workers/:wid/input` | send input per worker kind (§7.1 table) | shipped |
| `POST /api/sessions/:id/workers/:wid/cancel` | cancel the worker's active operation | shipped |
| `DELETE /api/sessions/:id/workers/:wid` | stop a worker and preserve its event trail | shipped |
| `GET /api/sessions/:id/progress` | inspect the main `ProjectProgress` record | C3 |
| `PUT /api/sessions/:id/progress` | main-supervisor update under session serialization | C3 |
| `GET /api/sessions/:id/workers/:wid/status` | observe: bounded status snapshot (§7.2) | C4 |
| `GET /api/sessions/:id/workers/:wid/tail?n=` | observe: bounded recent output + loss metadata | C4 |
| `POST /api/sessions/:id/workers/:wid/ops/:op` | typed kind-specific operation `{args}` under its declared effect/audience/admission | C4 |
| `GET  /` | the web UI page (12.5) | shipped |

The read-marking asymmetry is intentional. The interactive `/agent A result`
command both displays and marks the result read as one user action. HTTP `GET`
remains safe and side-effect-free for polling, previews, and retries; a remote
client uses the explicit idempotent `POST .../result/read` after it actually
presents the result. Incorporation is a separate mutation on both surfaces.

Worker control failures are typed at every adapter boundary. HTTP uses 409
with stable codes such as `worker_busy` (including `worker_id`, current
`task_id` when installed, and reservation state), `worker_idle`,
`worker_stopped`, `worker_input_rejected`, and
`main_worker_cannot_stop`; a missing session/worker remains 404. Successful
cancel is distinct from an idle/stale no-op. Channel adapters render the same
code as a user-visible notice rather than silently dropping rejected input;
Telegram, for example, sends a `worker_busy` notice. Remote destructive
operations continue to deny rather than parking on an unavailable local
confirmation (§12.8).

There are deliberately no session pane routes: panes, layout, focus, and zoom
are surface state (§7.1, invariant §0.3), so each remote client manages its
own layout locally (for the web page, in the browser) over the shared worker
routes above. Worker creation is kind-typed and keeps each kind's capability
and provenance rules — remote creation of `output`, `log_tail`, `file_view`,
and `stats` workers is view-harmless, while `shell` and `repl` creation stays
unavailable remotely at first. Gateway/channel `file_view` paths are
workspace-confined through `safe_path`; arbitrary host reads remain a local
TTY action or require a separately granted host-read capability. The
agent-specific routes are convenience
aliases over the same worker operations (spawn carries
assignment/attachments); aliasing is explicit so the two routes can never
develop different cancellation or stop semantics.

Long-poll is the bootstrap streaming mechanism because the `net/http` server
sends complete `Response` bodies — a handler parked on `Channel/recv` waiting
for the next event does not stall other requests (proven by the
handler-parked-in-`sleep` e2e test), so cursor long-poll works **today**;
chunked/SSE response streaming is gap 2 in 12.9. Because the journal is a
bounded ring (§7.1), a client cursor older than retained history gets an
explicit **cursor-gap** response carrying the new oldest cursor — the server
never silently resumes from a later position, so a client can render "N events
dropped" instead of misrepresenting continuity. A fresh or stale client then
loads `GET /snapshot`: the response contains the bounded redacted main
transcript, shared worker lifecycle/admission/current-operation state, bounded
worker output, `output_seq`/loss metadata, and the session event cursor, but no
surface pane/layout state. The main worker additionally carries the separate
`transcript_seq`/transcript-loss metadata defined in §7.1. The same bounded
main/worker projection is persisted
independently of the retained event window. Capture occurs in one session-actor
turn: every worker sequence and the event cursor describe that same logical
boundary. The handler implements this without awaiting; the client installs
the projection atomically and resumes
events strictly after its cursor. Per-worker output sequences suppress an
already-snapshotted output chunk at the capture boundary. SQLite persists the
event high-water mark separately from its retained window, so restart never
reuses an earlier `^v`.

### 12.3 Event log

Each session appends typed events; surfaces install one bounded shared-state
snapshot, then render incremental events and remember its cursor. Events are
maps (JSON-friendly, like everything else here). The
shipped gateway adapter uses the same underscore-separated §9.2 vocabulary as the CLI and
`/trace`:

```gene
{^v 41 ^type "text_delta"        ^text "..."}
{^v 42 ^type "turn_done"         ^text "full reply"}
{^v 43 ^type "tool_call"         ^id "tc_7" ^name "run_shell" ^args {...}}
{^v 44 ^type "tool_result"       ^id "tc_7" ^value "..." ^truncated false}
{^v 45 ^type "confirmation"      ^id "cf_2" ^risk "destructive" ^target "..."}
{^v 46 ^type "error"             ^text "..."}
{^v 47 ^type "error"             ^kind "cancelled" ^text "turn cancelled"}
{^v 48 ^type "turn_done"         ^cancelled true}
```

All text passes the §8.5 `redact` before entering the log — tokens live only in
the main process; surfaces can only ever receive redacted text. The same event
schema must drive in-process TUI rendering, remote adapters, and `/trace`; do
not maintain a second gateway-only vocabulary.

### 12.4 TUI surface

The TUI is always an in-process adapter when it is enabled, regardless of
whether `--gateway` also exposes HTTP. Slice C moved its rendering onto the
application registries rather than TUI-owned conversation arrays; slice C2
makes the TUI a **surface attachment** that owns its pane registry, layout,
focus, and zoom locally while rendering shared session workers (§7.1,
invariant §0.3). A future TUI running in a different process may be an
HTTP gateway client, but that transport distinction must stay below the same
surface command/event interface. The shipped cancellable `curses/next_event`
already provides the non-blocking input needed to update sub-agent, output,
shell, and REPL panes while the user types; neither local nor remote adapters
may reintroduce a between-turn-only rendering loop.

### 12.5 Web UI

A single static page served by the optional gateway adapter (`html` helpers;
`examples/todo_app.gene` is the in-repo precedent for a self-contained web
app): vanilla JS, `fetch` to post messages, a long-poll loop for events,
rare destructive-operation confirmations rendered as allow/deny buttons
posting to 12.2. No build step, no framework, no external assets — the page is
a string in the Gene source. Session switcher reads `GET /api/sessions`.

### 12.6 Telegram channel (implemented, milestone 9)

The cheapest remote surface, and deliberately the first: it needs **outbound
HTTPS only**, which the native HTTP transport provides. The behavior below is
shipped in `examples/ai_agent/gateway_adapter.gene` behind the main program's
gateway flags (and the compatibility launcher), without changing its protocol
or event semantics:

- an adapter task long-polls `getUpdates` (`timeout=50`, offset cursor) via
  `net/http_client/request` (curl(1) is the library-discovery fallback);
- updates route to sessions keyed by `chat.id` (`tg-<chat-id>`, also visible
  to the HTTP API and web UI); unknown chat ids are dropped unless listed in
  `TELEGRAM_ALLOWED_CHAT_IDS` (single-user posture; `*` allows all);
- replies stream by `sendMessage` + `editMessageText` throttled by size
  (one edit per ~200 new characters), final edit on `turn_done`;
- session events reach Telegram through an **outbound queue**: the session's
  on-event hook does a non-blocking `Channel/try_send` of the event as a
  JSON string (channel items must be Send-safe, i.e. immutable), and a
  dedicated sender fiber drains the queue and talks to the Bot API — so a
  slow Telegram call never stalls a turn, and the hook never suspends inside
  a native render callback;
- config: `TELEGRAM_BOT_TOKEN`, optional `TELEGRAM_API_BASE` (points at the
  fake Bot API in tests); no inbound port, no webhook, no TLS server.

Optional later work can render the rare destructive-operation confirmation as
a Telegram message (`/confirm cf_2`). Routine work stays auto-approved, so this
does not gate the shipped channel.

### 12.7 Slack channel

Two integration modes, both requiring runtime work — hence optional slice-D
work:

1. **Socket Mode** (preferred; outbound-only like Telegram): needs a
   WebSocket framing/upgrade support over the native TLS-capable client —
   blocked on optional WebSocket work (§4, slice D).
2. **Events API**: inbound webhooks to the gateway → needs public HTTPS
   exposure (tunnel) + request signing (`X-Slack-Signature`,
   HMAC-SHA256) → needs a small `crypto` namespace (12.9 gap 4), plus the
   3-second-ack/retry discipline.

Outbound (`chat.postMessage`, throttled `chat.update` for streaming) works
over native HTTP today. Sessions key by `(channel, thread_ts)` so each Slack thread
is a conversation.

### 12.8 Rare destructive confirmations across surfaces

§8.5's catastrophe guard normally produces no interaction. The guard's
confirmation strategy and event sink are injectable (`set_guard_confirm`; the
per-turn emit sink), because an embedding host has no terminal: the CLI
confirms on stdin, while the shipped gateway **denies destructive commands
outright** — never blocking the scheduler on an invisible prompt — and records
the deny as a `confirmation` event in the owning session's log. The planned
extension: when a structured operation is destructive but plausibly
intentional, the session emits a `confirmation` event, parks the turn on a
reply channel with a deadline (default deny on timeout), and broadcasts it to
authorized attached interaction adapters — y/N in the TUI, buttons on the web,
`/confirm` in chat. It belongs to the session/worker/task and normalized
operation digest, not to one layout surface; the first valid response wins,
disconnect does not cancel it, and the deadline covers a headless session.
Catastrophic operations remain denied; normal operations remain auto-approved.
This is not a general approval workflow.

### 12.9 Runtime gaps for optional surfaces

| # | Gap | Blocks | Bootstrap workaround | Proper fix |
|---|---|---|---|---|
| 1 | ~~**Async subprocess**~~ — **closed (m8, cancellation extended in slice B/C2)**: `os/exec_async`/`exec_stream_async` run captured children on dedicated OS threads; stdout lines cross through a channel, the Task settles through the scheduler, and `Task/cancel` terminates the child and closes its stdout channel. `os/exec_stdio_async` uses the same settlement/cancellation boundary with inherited terminal streams for `/edit` and `/tty` | — | — | shipped in `src/gene/stdlib.nim` + spec tests |
| 2 | Streaming HTTP responses (chunked/SSE) in `net/http` | smoother web streaming | cursor long-poll (12.2) | `Response ^stream` fed by a channel |
| 3 | WebSocket + TLS client | Slack Socket Mode | Events API + tunnel | libcurl / native TLS when justified |
| 4 | `crypto/hmac_sha256` (+ constant-time compare) | Slack Events signing | none for public exposure — do not skip | small native namespace beside `json` |
| 5 | ~~**Non-blocking TUI input**~~ — **closed**: public cancellable `curses/next_event` polls `getch` without blocking the scheduler and emits UTF-8/resize events | — | — | shipped in `src/gene/stdlib.nim` + PTY tests (§7) |

Gap 1 was the single load-bearing piece: it converts the agent from "one
blocking conversation" to "N concurrent sessions" and was prerequisite to
every surface. It shipped with milestone 8; the remaining gaps all have
workable bootstraps.

### 12.10 Testing posture

As with the shipped bootstrap: every surface must be drivable over loopback with no
network or real accounts. The fake `/chat/completions` endpoint (test_cli)
proves the model side; milestone 8 shipped its e2e (a 900 ms fake endpoint
serves two gateway sessions — create → post → long-poll — asserting streamed
`text_delta` events, bearer auth, and that both turns finish in ~one endpoint
latency, i.e. sessions really run concurrently). Slice B adds a five-second
fake model turn that is cancelled through the gateway and must emit its
cancelled `turn_done` in under two seconds. Milestone 9 adds a fake
Telegram API server (canned `getUpdates` + captured `sendMessage`), and the
pty harness pattern from the Ctrl-C work covers the TUI client. Slice C adds a
fake-model scenario with two concurrent sub-agents, deterministic result
delivery to the main agent, a contended mutation lease that is released on
cancellation, output-pane projection, and PTY coverage showing that embedded
shell/REPL panes do not stall main input or rendering. Gateway-unification
coverage starts the main program on a loopback test port in combined and
headless modes, proves that TUI and HTTP commands reach the same session/event
log, checks explicit-port precedence and bind failure before curses startup,
and runs the compatibility launcher against the same route fixtures.

Slice C3 adds the exact complex-project dogfood failures as acceptance tests:

- one fake research agent performs several `list_dir`/`grep`/`read_file` rounds
  and then both succeeds and fails; every tool result is normalized, each run
  has one `agent_finished` linked by `^source_v` to its worker finish,
  `/agents` retains its last outcome, and the bounded result survives restart;
- successful results remain unread and outside main context until explicit
  inspect/incorporate actions; completion and failure notifications are visible
  without submitting another command;
- from every worker kind, `/help` and `/?` focus pane 0 and render the same
  comprehensive registry-derived help without starting a model turn, appending
  a journal/transcript item, or marking an unread result. Topic help replaces
  the prior surface notice and includes the matching command grammar;
- one PTY types `/0`, `/sh`, `/pane list`, escaped absolute-path shell input,
  and an unknown `/focus typo` while a child emits rapid tool events. Draft
  bytes and route are exact, acknowledgement satisfies the scheduler-turn
  contract under a generous watchdog, Up/Down still browse history, and the
  typo executes nowhere while its diagnostic teaches the literal escape;
- the all-kinds state fixture restores agent, shell, REPL, output, tail, stats,
  and confined file view together. A second run corrupts each descriptor in
  turn and proves main still loads with one `restore_record_rejected`. It also
  advances `dropped_before` beyond saved result/progress references and renders
  explicit expired-evidence placeholders;
- enough panes to cross the minimum-height threshold exercise list/focus/hide,
  contextual read-only help, output append/follow, scrolling, maximize, and
  restart of the selected layout; self-follow and a two-output transitive
  follow cycle are rejected without changing either buffer;
- default and `--detail` trace/tail rendering expose terminal ids/outcomes and
  bounded errors without leaking redacted payloads; progress transitions and
  unread-result state match CLI, snapshot, and gateway projections. Repeated
  gateway `GET result` calls do not mark it read; the explicit read and
  incorporate requests are independently idempotent.

Slice C4 adds the worker-operations acceptance tests (§10.7):

- a fake sub-agent supervises a busy verification shell purely through
  `status`/`tail` **after the shell is delegated in its context attachment**:
  the reads succeed while the shell is mid-command, return bounded output with
  loss metadata, and append zero journal events; the same calls before
  delegation are rejected — worker id alone is never authority;
- `cancel` and `stop` succeed against a busy worker from CLI, model tool, and
  gateway (`interrupt` admission), while a second `send`/`run` receives the
  typed `worker_busy` rejection;
- the main agent runs a three-step stateful sequence (`cd`, configure, build)
  through `call_worker` on one shell worker: cwd persists between steps, each
  step is classified and leased, and every event carries `^origin "model"`
  plus the caller's worker id;
- a `/repl` script sets a log-tail filter and reads worker `status`,
  addressing the worker by `^name`; the same filter change through
  `/worker W filter` and the gateway ops route produces byte-identical
  journal records except `^origin`;
- `result` is a pure observe primitive on every adapter: gateway `GET` never
  mutates read state, the CLI composite marks read exactly once, and
  `mark_result_read`/`incorporate` remain independently idempotent;
- a model `call_worker` targeting `repl eval` is rejected with a typed error
  and an attributable event, and a sub-agent invoking `stop` on a sibling is
  rejected by the declared audience;
- `/help worker shell` renders the operation table from the live declaration,
  and an operation added to a kind in `/repl` appears in help, slash dispatch,
  and the gateway route without further registration — and restores disabled
  after restart unless registered through a versioned module reference
  (§9.1, invariant §0.15).
