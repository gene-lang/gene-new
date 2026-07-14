# Gene AI Agent — Design

Status: **the usable bootstrap is shipped: streaming Responses/Chat transports,
file/shell tools, `/sh`, `/repl`, local CLI state/memory, async session actors,
the gateway/web skeleton, Telegram, and SQLite gateway persistence. Slice A is
now shipped too: typed tool declarations (one `Tool` value derives handler +
schema + validation + risk), a stable live `/repl` `session` object, an
authoritative versioned event log with `/trace`, and an extended catastrophe
guard (realpath-confined paths, normal/destructive/catastrophic command
classification, surfaced truncation). Slice B now includes terminal and
gateway cancellation/steering, attributable `/diff` + targeted `/undo`,
structured verification evidence, hierarchical `AGENTS.md` loading, and the
owned public `curses` API used by the agent prompt. Native libcurl is the
default outbound transport. MCP, worktrees, and browser automation remain
optional later work. Slice C is now shipped: the
main application owns separate `Agent` and `Pane` registries, secondary turns
run concurrently with the scheduler-friendly input editor, and closing an
agent pane detaches the view. Output panes, streaming/cancellable line-oriented
shell panes, declaration-persistent Gene REPL panes, a single workspace
mutation lease, graph/layout persistence, typed model supervision tools, and
`--gateway[=PORT]`/`--headless` startup are implemented. Gateway sessions now
own the same `AgentApplication` services as the TUI; combined mode exposes the
live local application as session `local`.**
Date: 2026-07-14.

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
with no network or key. The full scrollback TUI and launcher capability
injection remain available later but do not gate the
signature Gene experience.

Operational diagnostics are emitted separately under the `app/ai_agent/*`
logger hierarchy. The trace profile in `logging.gene` records lifecycle,
counts, sizes, durations, routing backends, and outcomes without copying prompt
text, model text, tool arguments/output, shell commands, or credentials. This
does not replace the versioned event log, which remains the authoritative
record for tool actions and confirmations.

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
libcurl cannot be loaded. A public native full-screen UI remains future work.

The goal of this doc is to make the build *actionable against the real
runtime*. Each subsystem below states what exists in this repo today, what is
missing, and the recommended way to close the gap using patterns already proven
here (the `db/sqlite`/`db/postgres` dynlib backends in `src/gene/stdlib.nim`,
the `net/http` server, capability values, and the async task/worker model).

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
  submitted prompts, and Escape cancels the active turn; extension panes stack
  on the right while input and status retain full width;
- **Target (Slice C):** one stable **main agent** will own the primary
  conversation and supervise zero or more **sub-agents**. Each sub-agent will
  have its own item history, task, status, and event identity; it will not
  implicitly inherit the main agent's conversation context;
- a conversation loop that sends the running input-item list to the Responses
  API and streams assistant text deltas into the transcript as items arrive;
- **tool use**: the model may return `function_call` items (`read_file`,
  `write_file`, `edit_file`, `list_dir`, `run_shell`, `grep`); the agent
  executes them
  against the local workspace under explicit capabilities and the catastrophe
  guard
  (§8.5), appends `function_call_output` items, and loops until the model
  returns a final message item;
- slash commands in the input line (shipped/bootstrap: `/quit`, `/sh`, `/repl`,
  `/remember`, `/memory`, `/forget-memory`, `/status`, `/trace`, `/diff`,
  `/undo`, `/ext`, `/N <prompt>`, `/N close`; later as dogfooding demands:
  the typed pane commands in §7.1, `/model`, `/clear`), and
  Ctrl-C interrupting a `/sh` command or `/repl` eval (interrupting an
  in-flight model response is part of daily-driver slice B in §10);
- the whole session is ordinary Gene code: messages are maps, tools are `fn`s
  registered in a map, and the transcript is a list — homoiconic and testable.
- the target signature experience makes that last property an official API:
  `/repl` exposes stable session objects, typed tools register from one
  declaration, and `/trace` queries the same versioned events used by the CLI,
  gateway, persistence, and tests.

The single main program always constructs the same application core. Within
one application session, an agent registry owns the main agent and its
supervised children while an independent pane registry owns visible views and
interactive subprocesses. The default TUI is an in-process adapter over that
core. `--gateway[=PORT]` additionally attaches HTTP/web and configured channel
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
`GENE_AGENT_STATE=<dir>` enables local filesystem persistence for the
single-process CLI; `GENE_AGENT_RESUME=0` keeps saving but starts with a fresh
interactive session. The persisted config deliberately excludes auth tokens and
other secrets.

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
   request/response helper, but `os/exec_stream` adds synchronous stdout chunk
   and stdout_line callbacks while retaining the final captured result. The
   current agent uses that shape for SSE streaming, with the same timeout/output
   cap contract as `os/exec`.

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
and demonstrates how types, metadata, functions, and maps compose. Every call
passes through argument validation and then the narrow catastrophe guard in
§8.5, and both the call and its result are appended to the event log (§9.2).

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
  (do
    (draw screen ^output "agent> ready" ^input "" ^status "waiting")
    (var key (await (next_event screen))))
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
controllers progress while the user types. It supports multiline input,
bracketed paste, grapheme-aware cursor movement, and per-route history. In
pipes the agent falls back to `read_line` so scripted tests stay deterministic.
The reusable blocking `curses/read_input` editor remains available for simpler
programs and implements the same key conventions. Both paths use a fixed layout:
color-coded scrollback/output above a `─` separator, one or more promptless input
rows above a second `─` separator, and a status line at the bottom. The agent
adds a short `─` separator before each user turn in the scrollback, owns one
`Screen` persistently across prompts to avoid terminal-mode flicker, and calls
`curses/close` before handing control to `/sh`, `/repl`, EOF, or process exit.
The mouse wheel moves the transcript by three lines and PageUp/PageDown by one
viewport; the status line shows `[SCROLL +N]` while the view is above the live
tail. Transcript lines word-wrap at the current terminal width, and the scroll
offset counts the resulting visual rows. Up/Down browse the agent's submitted
input history without changing transcript scroll position; moving past the
newest entry restores the current draft. While a turn is running, a standalone
Escape cancels the same authoritative `Task` as Ctrl-C. The polling path keeps
queued typing, mouse reports, and navigation sequences intact.
`close` restores echo/cbreak/keypad/cursor state before leaving
ncurses. Inside those subsessions Ctrl-C stops the running command/eval or
clears a partially typed line instead of killing the agent: the interactive
repl installs a SIGINT handler that arms a VM interrupt (surfaced as a
catchable "interrupted" error), and `/sh` traps INT in the shell loop while
`os/exec_stdio` ignores it in the parent, system(3)-style. Interrupting an
in-flight model response and steering its continuation are shipped (§10).
Search, selection, and horizontal transcript scrolling remain optional; the
reusable lifecycle, editor, drawing, vertical scrolling, resize, and
asynchronous input layer is public and covered by PTY tests.

### 7.1 Native extension panes

**Bootstrap today:** `/ext` creates a secondary `Agent`, attaches an independent
right-side `Pane`, and `/N prompt` starts a cancellable turn without blocking
the main input editor; `/N close` detaches the pane while explicit stop controls
the agent lifetime. The main model has the equivalent `open_extension`
compatibility tool. Output, streaming line-oriented shell, and
declaration-persistent Gene REPL panes are also shipped. Restored shell/REPL
panes retain captured history in a closed state and require an explicit reopen.

**Target design:** continue that separation: a pane is a typed view/controller,
not an agent. The
application owns separate agent and pane registries and may attach, detach, or
replace a pane without changing the lifetime of the thing it displays. A
sub-agent may keep working headlessly after its pane closes; conversely an
output or process pane needs no model agent at all.

| Pane kind | Backing owner | User input | Close behavior |
|---|---|---|---|
| `agent` | main agent or one sub-agent | prompt or steering message | detach view; the agent continues until explicitly stopped |
| `output` | append-only stream/projection such as logs, diff, tests, or trace | none beyond navigation/filtering | unsubscribe; producer keeps its own lifecycle |
| `shell` | one scheduler-owned shell command controller | command lines | cancel the active command and close the controller |
| `repl` | one live Gene REPL controller | Gene forms | close the REPL session after confirmation if it is busy |

The default layout keeps the main transcript on the left, vertically stacks
extension panes on the right, and reserves full-width input and status rows:

```text
main agent transcript │ [1] sub-agent
                      │─────────────────
                      │ [2] output/log
                      │─────────────────
                      │ [3] shell or REPL
────────────────────────────────────────
input
────────────────────────────────────────
status
```

Pane ids are stable for the pane's lifetime and are never reused within an
application session. Bare input always goes to the main agent. Numbered input
is dispatched by pane kind:

- `/agent new [prompt]` creates a supervised sub-agent and opens its pane;
  `/ext` remains a compatibility alias, while `/agents` lists visible and
  headless agents and `/agent A open|cancel|stop` controls one by stable id;
- `/pane output [title]` creates an output-only pane for a later producer;
- `/sh` opens or focuses a shell pane instead of closing curses and taking over
  the entire terminal;
- `/repl` opens or focuses a Gene REPL pane with the stable `session` binding;
- `/N text` prompts/steers an agent pane, sends a command to a shell pane, or
  evaluates a form in a REPL pane; output panes reject text input. `/N -- text`
  sends text that would otherwise match a control verb such as `close`;
- `/N close` closes the pane, `/N cancel` cancels its active task/process,
  `/N stop` explicitly stops an attached agent/controller, and `/N focus` makes
  it the target for pane-local navigation.

Input history is kept per route so shell commands, Gene forms, sub-agent
prompts, and main-agent prompts do not pollute one another. Escape cancels the
focused pane's active operation when focus is explicit; otherwise it cancels
the main agent's current turn. Closing a pane is never an implicit cancellation
of an agent or output producer; a pane-owned shell/REPL controller follows the
explicit close policy in the table. The status line identifies the routed
target and reports all running agents/processes compactly.

The model-facing bootstrap `open_extension` becomes a compatibility composite
over two capability-checked typed operations, conceptually shaped as:

```gene
(var agent_id
  (spawn_agent {^assignment "review the reader"
                ^context [...] }))
(var pane_id
  (open_pane {^kind "agent" ; one of agent, output, shell, repl
              ^owner_id agent_id
              ^title "reader review"}))
```

`spawn_agent` returns only an agent id and does not require a pane. `open_pane`
returns only a pane id and attaches to an existing agent, stream, or controller;
the `/agent` and legacy `/ext` commands intentionally perform both operations
as a UI convenience. Separate operations append to an output pane, send to a
process pane, focus/close a pane, and cancel/stop its backing owner. The model
may open only kinds allowed by its capabilities: creating a view is harmless,
but starting a shell or REPL must use the existing `Os/Exec` or VM authority
and the same catastrophe guard. An output pane accepts structured events or
already-redacted text; it is not an untracked channel around the authoritative
event log.

Input provenance remains explicit. Text typed by the user into a shell pane is
the same deliberate escape hatch as today's interactive `/sh`. A model cannot
inject raw input into that channel: model-initiated commands still go through
the typed `run_shell` operation, its classifier, and its events, with output
optionally projected into a shell/output pane. The same rule prevents a model
from using a visible REPL pane as an unlogged mutation backdoor.

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

Classification anchors command-name patterns at the start of each simple
command (splitting on `&&`, `;`, `|`) so `grep shutdown src/` stays normal while
`ls && git clean -fdx` is caught. File tools realpath every path and reject
anything resolving outside the workspace root, so a symlink inside the workspace
cannot point a read/write outside it. Subprocesses keep their timeouts and
output caps, and truncation is surfaced in both the transcript and the
model-visible tool result. Known auth tokens are redacted from displayed and
model-visible output — including inside event-log entries.

The two compatibility flags are independent and intentionally have different
jobs. `GENE_AGENT_GUARD=0` removes shell-command classification **including
catastrophic command hard stops**; it does not merely remove destructive
confirmations. Path confinement, output bounds, and redaction remain active.

| `GENE_AGENT_GUARD` | `GENE_AGENT_APPROVE_ALL` | Behavior |
|---|---|---|
| `1` (default) | `1` (default) | Normal work auto-approves; destructive shell commands ask once; catastrophic commands are denied. |
| `1` | `0` | The guard still denies catastrophic commands and confirms destructive ones, then the legacy layer prompts before every file write/edit or model `run_shell`; a destructive shell command can therefore require two confirmations. |
| `0` | `1` | Shell classification and catastrophic command protection are disabled, and file writes/edits plus model `run_shell` auto-approve. |
| `0` | `0` | Shell classification and command hard stops are disabled, but the legacy layer prompts before each file write/edit or model `run_shell`; accepting the prompt can run a formerly catastrophic command. |

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
Interactive `/sh` is a deliberate user-driven escape hatch — the TTY session
hands the loop to the real shell, so the classifier does not sit in front of it;
the scripted (piped) `/sh` path does run each line through the classifier.

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
- **interactive `/sh`** — the TTY shell loop is outside the classifier (above).

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
    (do
      (emit "error" {^text resp/agent_error})
      (render resp/agent_error)
      (emit "turn_done" {})
      input_items)
    (do
      (each (to_stream (response_output_items resp))
        (fn [item] (emit "model_item" {^item item})))
      (var calls (response_calls resp))
      (if (empty? calls)
        (do
          (emit "agent_text" {^text (response_text resp)})
          (if (Cell/get streamed)
            (render "")
            (render (redact (response_text resp))))
          (emit "turn_done" {^text (response_text resp)})
          (append_all input_items (response_output_items resp)))
        (if (<= budget 0)
          (do
            (render "[stopped: tool_call budget exhausted]")
            (emit "turn_done" {})
            input_items)
          (do
            # Keep awaited tool handlers in the turn fiber so cancellation
            # cannot strand a subprocess in a lazy mapper continuation.
            (var outputs (cell []))
            (for c in calls
              (do
                ((outputs ~ Cell/get) ~ List/push! (run_tool_call c emit))
                (render $"  · tool ${c/name} ${c/arguments}")))
            (run_turn
              transport
              ((to_stream (outputs ~ Cell/get)) ~ into
                (append_all input_items (response_output_items resp)))
              render
              render_stream
              (- budget 1)
              emit)))))))

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
session/workspace    session/current_task
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

The native multi-agent slice extends this stable surface rather than exposing
TUI arrays:

```text
session/main_agent   session/agents       session/panes
```

Agent and pane mutations remain message-based (`spawn_agent`, `stop_agent`,
`open_pane`, `close_pane`, `send_pane`) so supervision, capability checks,
events, and persistence cannot be bypassed by mutating a list cell.

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

# Slice C lifecycle events (target)
{^v 16 ^type "agent_spawned" ^agent_id "a2" ^parent_agent_id "main" ...}
{^v 17 ^type "agent_status" ^agent_id "a2" ^status "working" ...}
{^v 18 ^type "agent_completed" ^agent_id "a2" ^task_id "t7" ...}
{^v 19 ^type "pane_opened" ^pane_id 2 ^kind "output" ...}
{^v 20 ^type "pane_output" ^pane_id 2 ^source_agent_id "a2" ...}
{^v 21 ^type "pane_closed" ^pane_id 2 ...}
```

`run_turn` and `run_tool_call` write through an explicit **emit sink**: the CLI
passes its process-global logger, the gateway passes a per-session sink — so
each gateway session owns its complete tool trail without cross-session
interleaving. Every value is redacted at append. The event log is authoritative
for rendering and persistence; transcript text, evidence, and current UI state
are projections. Every surface consumes the same events. `/trace` exposes a few useful filters first (type, tool name, path,
event range, current turn), while `/repl` can apply normal selectors and stream
operations. Full replay/fork/compare and sanitized trajectory fixtures are later
extensions, not requirements for the first event slice.

Events carry correlation ids where needed (`application_id`, `agent_id`,
`parent_agent_id`, `task_id`, `turn_id`, `tool_call_id`, `pane_id`),
module/tool version hashes once hot reload exists, and redaction/truncation
state. Pane events describe presentation and routing; agent/tool events remain
authoritative even when no pane is open. They do not contain hidden
chain-of-thought; they record explicit plans, decisions, actions, results, and
evidence.

### 9.3 Native agent graph and supervision

The application has exactly one main agent and a bounded set of sub-agents.
This is a supervised tree, not peer-to-peer swarm infrastructure:

```text
ApplicationSession
├── AgentRegistry
│   └── main
│       ├── sub-agent a1
│       └── sub-agent a2
├── PaneRegistry
│   ├── pane 1 -> a1
│   ├── pane 2 -> output projection
│   └── pane 3 -> shell controller
└── WorkspaceCoordinator
```

Each `Agent` owns a stable id, optional parent id, Responses-style item list,
current task, status, event sink, tool/capability view, and explicit assignment.
The main agent alone receives bare user input and is responsible for spawning,
steering, cancelling, and incorporating sub-agent results. A sub-agent starts
with its assignment, the relevant workspace instructions/memory, and an
explicit context attachment chosen by the parent; it does not receive the full
main transcript by accident. Its final result is emitted as a structured child
result into the main agent's supervisor inbox. At the next safe model boundary,
the main agent receives a compact child-result item linked to the original
delegation; the child's private transcript and tool chatter are not copied into
the main context.

Sub-agents may run concurrently because model and read-only tool work is
independent. Shared-workspace mutation is coordinated separately from agent
scheduling. The first clean implementation grants at most one mutation lease
at a time for `write_file`, `edit_file`, `/undo`, and similar operations. Shell
commands take the lease by default because reliably proving that an arbitrary
command is read-only is harder than serializing it; narrowly classified
read-only commands may opt out later. Pure file reads and model requests may
overlap. The lease owner and resulting `file_change` events are attributable to
an agent and task. Per-agent worktrees remain an optional later isolation
strategy, not a requirement for native sub-agents. The current concurrent agent
turns establish the scheduler contract; mutation coordination and typed
non-agent pane controllers remain required before the slice is complete.

Stopping an agent cancels its current model request and subprocesses, releases
its mutation lease, marks it terminal, and preserves its event trail. Closing
an attached pane only detaches the view. A completed sub-agent can be retained
for inspection or explicitly removed after its result is incorporated. The
application enforces a configurable small concurrency/count bound so a model
cannot recursively create an unbounded team.

Persistence records the agent graph, durable item histories, statuses,
assignments, pane descriptors/layout, and event correlations. Output panes may
restore their event projection. Shell and REPL processes are not pretended to
survive a crash: restoration shows their captured history in a closed pane and
requires an explicit restart. No persistence format stores raw terminal state
or secrets.

### 9.4 Dogfood rule

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
  cancellation/steering;
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
   visible `/ext` behavior.
2. **Done.** Make the main agent a supervisor. Add bounded
   spawn/send/cancel/stop/result
   operations and explicit context attachments; expose them through stable
   `session/agents` and typed model tools.
3. **Done.** Generalize right-side panes to the four §7.1 kinds. Keep `/ext` as an alias,
   add output panes, and move `/sh` and `/repl` from whole-terminal subsessions
   to scheduler-owned interactive panes.
4. **Done.** Allow concurrent sub-agent turns and read-only work, with attributable
   events and a single shared-workspace mutation lease. Prove cancellation,
   lease release, bounded spawning, and result delivery with deterministic fake
   models and PTY tests.
5. **Done.** Persist the agent graph and pane layout while restoring shell/REPL panes as
   closed history rather than fake live processes. Fold gateway startup into
   the main program behind `--gateway[=PORT]`/`--headless`; keep
   `gateway.gene` only as a thin compatibility launcher. The in-process TUI and
   optional network adapters must address the same application services.

The slice is complete when the main agent can delegate two independent review
tasks, the user can interact with either sub-agent while both are running, a
third output pane can follow verification events, and a shell or REPL pane can
run without suspending input/rendering in the rest of the application. Starting
that same program with `--gateway` must expose the already-live local session
to the web/API while the TUI remains responsive; `--headless` and the temporary
`gateway.gene` wrapper must expose the same API without constructing curses.

### 10.5 Slice D — expand only where leverage is proven

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
application session contains one main agent, its supervised sub-agents, panes,
processes, and the shared workspace coordinator — it is not synonymous with
one model conversation. The main program always starts this same core and then
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
  └──────────┘           │  application/session actors:    │◄───────────────► model
                         │  main + sub-agents, panes,       │   Responses/chat APIs
  ┌──────────┐  HTTP     │  tools, guard, event log,        │
  │ Web UI   │◄─────────►│  workspace coordinator          │
  ├──────────┤  +JSON    │                                  │   libcurl (async)
  │ remote   │◄─────────►│  optional gateway adapters      │◄───────────────► channels
  │ clients  │  events   │  + sqlite persistence           │
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
agent registry, pane registry, task cells, event sink, and workspace lease.
The adapter retains only the session actor/router map needed for per-session
mailbox ordering. In combined mode it also registers the already-live TUI
application as stable session `local`, so HTTP can observe, message, and cancel
the same main agent while curses remains responsive.

Startup order is deliberate: parse and validate application flags, construct
the core and restore durable state, bind the requested HTTP listener, and only
then open curses. A requested port that is invalid or unavailable fails before
terminal mode changes. `/quit` in combined TUI+gateway mode performs one
controlled shutdown of adapters, agent/process tasks, persistence, and curses;
headless mode runs until an explicit shutdown or process signal. An unexpected
loss of the requested HTTP listener is surfaced as a fatal application error
rather than quietly leaving a supposedly shared session local-only. Optional
channel failures remain isolated and retry according to their adapter policy.

The main process owns a registry of application sessions. The TUI attaches to
one designated local session; HTTP/channel routes may address it or create
additional sessions. Each application session is a **session actor**
(`actor/spawn`, design.md §13) owning:

- an agent registry with exactly one main agent and zero or more bounded,
  supervised sub-agents; each agent owns its Responses-style model item list
  (the chat adapter normalizes wire formats at the boundary);
- a pane registry independent from the agent registry, plus any output-stream,
  shell, and REPL controllers described in §7.1;
- a monotonically versioned **authoritative event log** (12.3), from which
  transcript and surface state are projected;
- model config (base/model/flavor per session, defaulted from env as today);
- the typed tool registry, workspace mutation coordinator, §8.5 catastrophe
  guard, and at most one pending destructive-operation confirmation (12.8).

The session actor serializes control-plane transitions — create/stop agent,
open/close pane, grant/release mutation lease, append event — while agent model
requests and read-only tasks run concurrently under the scheduler. This keeps
state deterministic without forcing all sub-agent work through one turn lock.
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
| `GET  /api/sessions/:id/events?cursor=N` | **long-poll**: events after N, or park until one arrives | shipped |
| `POST /api/sessions/:id/confirmations/:cid` | resolve a rare destructive-operation confirmation | planned |
| `POST /api/sessions/:id/cancel` | cancel the in-flight turn and its subprocess | shipped |
| `POST /api/sessions/:id/agents` | spawn a supervised sub-agent with assignment/context attachment | slice C |
| `POST /api/sessions/:id/agents/:aid/messages` | prompt or steer a particular agent | slice C |
| `POST /api/sessions/:id/agents/:aid/cancel` | cancel that agent's active operation without stopping it | slice C |
| `DELETE /api/sessions/:id/agents/:aid` | stop a sub-agent and preserve its event trail | slice C |
| `GET /api/sessions/:id/panes` | list typed panes and backing-owner status | slice C |
| `POST /api/sessions/:id/panes` | open/attach a typed pane | slice C |
| `POST /api/sessions/:id/panes/:pid/input` | route user-originated input according to pane kind | slice C |
| `DELETE /api/sessions/:id/panes/:pid` | close/detach a pane without conflating owner lifetime | slice C |
| `GET  /` | the web UI page (12.5) | shipped |

Long-poll is the bootstrap streaming mechanism because the `net/http` server
sends complete `Response` bodies — a handler parked on `Channel/recv` waiting
for the next event does not stall other requests (proven by the
handler-parked-in-`sleep` e2e test), so cursor long-poll works **today**;
chunked/SSE response streaming is gap 2 in 12.9.

### 12.3 Event log

Each session appends typed events; surfaces render them and remember only a
cursor. Events are maps (JSON-friendly, like everything else here). The
shipped gateway adapter uses the same hyphenated §9.2 vocabulary as the CLI and
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
whether `--gateway` also exposes HTTP. Slice C makes its §7 pane layout a
projection of the application agent/pane registries rather than TUI-owned
conversation arrays. A future TUI running in a different process may be an
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
reply channel with a deadline (default deny on timeout), and the owning surface
renders it natively — y/N in the TUI, buttons on the web, `/confirm` in chat.
Catastrophic operations remain denied; normal operations remain auto-approved.
This is not a general approval workflow.

### 12.9 Runtime gaps for optional surfaces

| # | Gap | Blocks | Bootstrap workaround | Proper fix |
|---|---|---|---|---|
| 1 | ~~**Async subprocess**~~ — **closed (m8, cancellation extended in slice B)**: `os/exec_async`/`exec_stream_async` run the child on a dedicated OS thread; stdout lines cross through a channel, the Task settles through the scheduler, and `Task/cancel` now terminates the child and closes its stdout channel | — | — | shipped in `src/gene/stdlib.nim` + spec tests |
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
