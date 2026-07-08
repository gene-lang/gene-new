# Gene AI Agent — Design

Status: **milestones 1–4 implemented; subprocess streaming prompt shipped; 5–7 planned.** Date: 2026-07-03.

Implemented (see `examples/ai_agent.gene` and `src/gene/stdlib.nim`): the `os`
namespace (`get-env`/`env?` under `Os/Env`, `exec` under `Os/Exec` with
timeout + output caps, `exec-stream` with stdout callbacks, `read-line`,
`read-input`/`refresh-input`/`close-input`), `Fs/read-text`/`Fs/write-text`/
`Fs/list-dir`, the `json` namespace (`parse`/`stringify`/`JsonError`), and the
agent itself — a streaming Responses-API loop over a `curl` subprocess, a
minimal single-user safety policy (§8.5: `rm -rf` denial, simple path check,
timeout/output caps with truncation flags, display-side secret redaction;
tools auto-approve by default), and tool use
(`read_file`, `write_file`, `edit_file`, `list_dir`, `run_shell`, `grep`),
plus an offline
demo transport so the loop runs (and is verified) with no network or key. Not
yet built: the native libcurl client (§4 option 1, milestone 5), the full
scrollback TUI (§7, milestone 6), and capability injection via `gene run` flags
(milestone 7).

This document specifies a Claude-Code-like AI coding agent written in Gene: a
terminal program that holds a conversation with OpenAI's hosted API
(`api.openai.com`), lets the model call local tools (read/write files, run
shell commands, search), and renders the session in a full-screen terminal UI
built on a native `curses` binding. The API auth token is read from an
environment variable; nothing is hard-coded.

**API surface: target the Responses API, not Chat Completions.** OpenAI now
recommends the Responses API (`POST /v1/responses`) for new agent-style
projects; Chat Completions (`/v1/chat/completions`) remains supported but is the
older surface. Responses is built around typed output *items* (message items,
`function_call` items, reasoning items) and first-class tool/function calls,
which maps far more cleanly onto this agent's tool loop than digging tool calls
out of `choices[].message.tool_calls`. Model the client around Responses items;
treat Chat Completions only as a fallback shape if a deployment requires it.
(Migration guide: https://platform.openai.com/docs/guides/migrate-to-responses.)

**Final target is a single self-contained binary** (native TLS client, native
curses); the bootstrap milestone (§10) deliberately depends on `curl(1)` and a
line UI to get the agent talking before that native work lands.

The goal of this doc is to make the build *actionable against the real
runtime*. Each subsystem below states what exists in this repo today, what is
missing, and the recommended way to close the gap using patterns already proven
here (the `db/sqlite`/`db/postgres` dynlib backends in `src/gene/stdlib.nim`,
the `net/http` server, capability values, and the async task/worker model).

## 1. What the agent is

A CLI, launched as:

```bash
OPENAI_AUTH_TOKEN=... gene run examples/ai_agent.gene
```

Behavior, mirroring a coding agent:

- a full-screen terminal UI (curses): scrollable transcript pane, a status
  line, and an input line;
- a conversation loop that sends the running input-item list to the Responses
  API and streams assistant text deltas into the transcript as items arrive;
- **tool use**: the model may return `function_call` items (`read_file`,
  `write_file`, `list_dir`, `run_shell`, `grep`); the agent executes them
  against the local workspace under explicit capabilities and safety policy
  (§8.5), appends `function_call_output` items, and loops until the model
  returns a final message item;
- slash commands in the input line (`/model`, `/clear`, `/quit`), and Ctrl-C to
  interrupt an in-flight response;
- the whole session is ordinary Gene code: messages are maps, tools are `fn`s
  registered in a map, and the transcript is a list — homoiconic and testable.

## 2. Capability gap analysis

The pieces below split into two kinds: **host capabilities** — new authority
over the machine that must be capability-gated (§8) — and **pure stdlib /
runtime pieces** that add no new authority, only code. Distinguishing them keeps
the security surface clear: only the first group can do damage.

Host capabilities (gated authority):

| Capability | Needed for | Status today | Section |
|---|---|---|---|
| Env var read (`Os/Env`) | API token, model, base URL | **implemented** | §3 |
| Outbound HTTPS (`Net/Connect`) | call the API | **partial** — capability exists, but transport is plaintext-TCP-only | §4 |
| Subprocess (`Os/Exec`) | `run_shell`, `grep`, bootstrap `curl` | **implemented** | §6 |
| File read/write/list (`Fs/*`) | file tools | **implemented** — sync + async helpers | §6 |

Pure stdlib / runtime pieces (no new authority):

| Piece | Needed for | Status today | Section |
|---|---|---|---|
| JSON parse / serialize | API request + response bodies | **implemented** | §5 |
| TLS transport code | ride on `Net/Connect` | **missing** (native client) | §4 |
| Terminal UI (curses) | the TUI | **partial** — prompt layout + repaint helper exist; full scrollback controls pending | §7 |

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
- **Async tasks + worker I/O queue**: `Net/tcp-*-text-async`, `Fs/*-async`, and
  `spawn`/`await` already suspend a Gene task on real I/O and resume it. A
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

The agent reads `OPENAI_AUTH_TOKEN` (required), and optionally `OPENAI_BASE_URL`
(default `https://api.openai.com`) and `OPENAI_MODEL`.

Before this work there was no OS-environment access at the Gene surface. The
`Env` value type (`env`, `Env/extend`) remains the eval sandbox's binding
environment, unrelated to `getenv`. The implemented `os/get-env` surface below
exposes Nim's `os.getEnv` under explicit `Os/Env` authority.

**Implemented**: an `os` namespace with `os/get-env` gated by a new
`Os/Env` capability, so environment reads are explicit host authority like
everything else:

```gene
(import os [get-env Env])
(var token (get-env env "OPENAI_AUTH_TOKEN"))   ; env : Os/Env
```

Native surface (small, in `src/gene/stdlib.nim` next to the db backends):

- `os/get-env : Os/Env, Str -> Str` (raises `OsError` if unset), and
  `os/get-env : Os/Env, Str, Str -> Str` (with default) — nil-safe variant
  `os/env? : Os/Env, Str -> Str | Nil` for optional keys.

`Os/Env` is granted the same way `native`/`Ffi/Load` is in tests: defined on the
root scope, or injected by a launcher (see §8).

## 4. HTTPS client (§4)

The API is HTTPS with `Authorization: Bearer <token>` and JSON request bodies.
For a good UX the Responses API streams (`"stream": true` yields SSE
`data: {json}` events for `response.output_text.delta`, `response.completed`,
etc.). The current agent supports this through `curl -N` launched by
`os/exec-stream`: stdout-line callbacks parse SSE lines and repaint the
ncurses prompt as text deltas arrive. This is still a bootstrap transport; it
does not replace the native HTTPS client planned below.

The runtime's networking is **plaintext TCP only** (`Net/tcp-read-text-async` /
`Net/tcp-write-text-async` in `src/gene/vm.nim`), with no TLS. Three ways to get
HTTPS, in order of recommendation:

1. **libcurl native namespace (recommended, and the only path that streams).**
   Add `net/http-client` backed by libcurl loaded via dynlib, mirroring the
   `db/sqlite` bindings:
   - candidates `libcurl.4.dylib` / `libcurl.so.4` (present on macOS via the
     dyld cache and on typical Linux); `GENE_LIBCURL` override like
     `GENE_LIBPQ`;
   - bind `curl_easy_init`, `curl_easy_setopt`, `curl_easy_perform`,
     `curl_slist_append`, `curl_easy_cleanup`. `curl_easy_setopt` is variadic in
     C, but each call passes exactly one trailing argument, so the Nim binding
     declares one concrete `{.cdecl.}` proc type per value shape
     (`setoptStr`, `setoptLong`, `setoptPtr`, `setoptFn`) and casts the *same*
     `curl_easy_setopt` symbol to each. (This differs from the sqlite bindings,
     which cast several *distinct* symbols — `sqlite3_bind_int64`,
     `sqlite3_bind_text`, … — to typed procs; the shared idea is a typed Nim
     proc per C call shape, not multiple symbols.)
   - run `curl_easy_perform` on the worker-backed async-I/O lane (the same queue
     that serves `Fs/*-async` and `Net/tcp-*-async`), so `await` on the request
     task does not block the scheduler.
   - **streaming callback — concurrency boundary (must be specified).** Streaming
     uses `CURLOPT_WRITEFUNCTION`, a `{.cdecl.}` callback that curl invokes on
     the worker/perform thread. That callback **must not run any Gene code, walk
     VM state, or allocate managed values** — the VM is not reentrant from an
     arbitrary native thread. It may only copy the received bytes into a
     lock-protected buffer, or hand them to a bounded `Channel` through the
     runtime's rooted, thread-attached native path
     (`geneAttachThread` + a rooted channel send, per `src/gene/native_api.nim`).
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
   request/response helper, but `os/exec-stream` adds synchronous stdout chunk
   and stdout-line callbacks while retaining the final captured result. The
   current agent uses that shape for SSE streaming, with the same timeout/output
   cap contract as `os/exec`.

### Streaming vs. the blocking subprocess — resolving the conflict

These two facts are now split into distinct subprocess primitives: `os/exec`
returns a complete `{^status ^stdout ^stderr}` result, while `os/exec-stream`
returns the same shape and also invokes callbacks as stdout arrives.

- **Bootstrap:** `os/exec-stream` + `curl -N` gives visible Responses SSE text
  deltas without adding TLS code to Gene.
- **Native client (milestone 5):** still replaces the subprocess with libcurl
  and should expose a scheduler-friendly stream/channel API, so cancellation and
  worker-thread boundaries are explicit.
- **Future general subprocess API:** a long-lived `os/spawn` with stdin/stdout
  handles or channels may still be useful, but is not needed for the current
  agent.

Both transports present the same non-streaming Gene API; only the native client
adds `stream`:

```gene
(import net/http-client [request Http])         ; milestone 1 + 5
(var resp (request http ^method "POST" ^url url ^headers hs ^body json-body))
; resp => {^status Int ^body Str}

(import net/http-client [stream])               ; milestone 5 only
(var ch (stream http ^method "POST" ^url url ^headers hs ^body json-body))
; ch => Channel of SSE event payloads (Str), drained with Channel/recv
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
- `json/stringify : Any -> Str` — inverse over the same value kinds; reuses the
  escaping already hand-rolled in `examples/todo_app.gene` (promote it here).

A native scanner is the safe choice (correct number/string/escape handling,
depth limit against malicious input — same defensive posture as the HTTP
request parser's caps in `src/gene/stdlib.nim`). Implementation is
self-contained and needs no external library.

With `json`, the Responses request body is just data:

```gene
(json/stringify
  {^model model
   ^input input-items      ; Responses API: a list of typed input items
   ^tools tool-schemas})   ; ^stream omitted — MVP is non-streaming (§4)
```

## 6. Agent tools: files and subprocess (§6)

The model calls tools; the agent executes them under capabilities and returns
results. Tools needed for a coding agent:

- `read_file`, `write_file`, `list_dir` — files. `Fs/read-text-async` /
  `Fs/write-text-async` still exist; `Fs/read-text`, `Fs/write-text`, and
  `Fs/list-dir` are implemented for the line-oriented agent tools.
- `run_shell`, `grep` — subprocess via the implemented `os` namespace entry
  gated by a new `Os/Exec` capability:

  ```gene
  (import os [exec Exec])
  (var r (exec sh ^cmd "grep" ^args ["-rn" pattern "."] ^timeout-ms 10000))
  ; r => {^status Int ^stdout Str ^stderr Str}
  ```

  Native implementation over Nim `std/osproc` (`startProcess`), with an
  output-size cap, truncation flags, and timeout, returning a typed result map.
  `Os/Exec` is deliberately a *distinct* capability from `Os/Env` so a launcher
  can grant file+env without shell access.

Tools are registered as ordinary Gene functions and described to the model with
a JSON schema list; dispatch is a `Map Str Fn` lookup on the `function_call`
item's name — the same pattern the `net/http` router uses for routes. Every
tool runs under the operational safety contract in §8.5, which is not optional
for a coding agent.

## 7. Terminal UI via curses (§7)

A native `curses` namespace backed by `libncurses` via dynlib — again the
`db/sqlite` pattern. ncurses' variadic `printw` is avoided by binding the
non-variadic primitives:

- lifecycle: `initscr`, `endwin`, `cbreak`, `noecho`, `keypad`, `curs_set`,
  `start_color`, `init_pair`;
- drawing: `waddstr`/`mvwaddstr` (non-variadic, unlike `printw`), `wattron`/
  `wattroff`, `wclear`, `wrefresh`, `wmove`, `getmaxyx` (via `getmaxx`/
  `getmaxy`);
- input: `wgetch`. For a responsive UI without blocking the scheduler, set
  `nodelay`/`timeout` and poll `wgetch` from a Gene task on the worker lane, or
  drive input from the async-I/O lane so the streaming response and keystrokes
  interleave through `await`/`Channel`.

Gene-facing surface (a thin, safe layer over the raw binding):

```gene
(import curses [Screen with-screen add-line refresh read-key])
(with-screen (fn [scr]
  (add-line scr "you> hello")
  (refresh scr)
  (var key (read-key scr))))
```

`with-screen` wraps `initscr`/`endwin` so the terminal is always restored, even
on error (the same `ensure`-based cleanup discipline as `db` connection close).
Window handles are owned C pointers wired to `endwin`/`delwin`, matching the db
`^handle` ownership model.

Curses is the largest single piece; it can trail the rest. The current agent uses
a narrow `os/read-input` helper for the prompt: on a TTY it opens a small
ncurses editor with multiline input and bracketed paste support, and in pipes it
falls back to `read-line` so scripted tests stay deterministic. The helper owns
a fixed layout:
color-coded scrollback/output above a `─` separator, one or more promptless input
rows above a second `─` separator, and a status line at the bottom. The agent
adds a short `─` separator before each user turn in the scrollback, uses
`read-input` persistently across prompts to avoid terminal-mode flicker, and
calls `close-input` before handing control to `/sh`, `/repl`, EOF, or process
exit. `close-input` restores echo/cbreak/keypad/cursor state before leaving
ncurses. A full `curses` namespace and scrollable transcript TUI can still
remain a later milestone.

## 8. Capabilities and the launcher (§8)

Every new host power is a capability value, consistent with the existing model
(`src/gene/vm.nim` defines `Net/Connect`, `Fs/*`, `Ffi/Load`):

- `Os/Env` — read environment variables (§3);
- `Os/Exec` — spawn subprocesses (§6);
- `Net/Connect` — outbound network (reuse; §4);
- `Fs/ReadWriteDir` — workspace file tools (reuse; §6).

Open runtime question (tracked in `docs/stdlib.md`): how an entrypoint receives
capabilities. For MVP these are defined on the built-ins root (as the test
harness grants `native` today), so the agent script imports them directly.
A hardened build would have `gene run` inject a capability set into `main`
based on flags (`--allow-exec`, `--allow-net`), so the agent runs least-
privilege. The agent design assumes the capability-value shape either way; only
the *granting* mechanism changes.

### 8.5 Tool safety contract

**Current posture (2026-07-08): the agent is a single-user personal tool, so
the shipped policy is deliberately minimal** — deny `rm -rf` in `run_shell`,
reject absolute/`..` paths in file tools, enforce timeouts and output caps,
and redact the token from displayed output. Tools auto-approve by default;
set `GENE_AGENT_APPROVE_ALL=0` to be prompted before writes and shell
commands. The full contract below is the hardening spec for any shared or
hostile-input deployment, deferred to milestone 7.

Capability-gating says *whether* a tool may touch the filesystem or shell; it
says nothing about *what* the model is allowed to do with that access. Because a
coding agent executes model-chosen file writes and shell commands, the following
is the full operational contract for a shared deployment:

- **Workspace-root confinement.** Every file tool resolves its path argument
  against a configured workspace root and rejects anything that escapes it. The
  `net/http` static-file handler and `resolveModulePath`
  (`src/gene/vm.nim`, "module path escapes package root") already establish this
  pattern: normalize, then verify the result is still within root.
- **Path normalization first.** Normalize (`..`, symlinks, absolute paths)
  *before* the confinement check, so `../../etc/passwd` and a symlinked escape
  are both caught. Never string-prefix-match raw input.
- **Command timeout and output caps.** `run_shell` runs with a hard timeout and
  bounded captured stdout/stderr (truncate + flag), so a runaway or noisy
  command cannot hang the agent or blow up the transcript/next request. `os/exec`
  (§6) takes `^timeout-ms` and an output cap for exactly this.
- **Approval / policy hook.** A pluggable policy decides per call: auto-allow
  (read-only tools), prompt the user (writes, shell), or deny (configurable
  deny-list, e.g. no `rm -rf`, no network from within `run_shell`). Default
  posture: reads auto-allowed, writes and shell require confirmation unless a
  `--yolo`-style flag opts out.
- **Secret redaction.** The API token and any `Authorization` header are redacted
  from transcript, logs, and error messages. Tool output that echoes the
  environment must not leak the key back into the next model request.
- **Least privilege by default.** `Os/Exec` is distinct from `Os/Env` and
  `Fs/*` precisely so a run can grant file+env without shell, or read-only
  files. The default launcher grants the minimum the requested toolset needs.

These are enumerated here so the hardening milestone treats them as acceptance
criteria, with spec tests for the escape/timeout/redaction cases — the same
defensive-test posture as the `net/http` request-parser caps. Known gaps in the
current minimal build, in rough priority order for milestone 7: tool output is
not redacted before being sent back to the model (one-line fix: wrap
`run-tool-call`'s output in `redact`), `safe-path` does not realpath so a
symlink inside the workspace can point outside it, and the `run_shell`
deny-list is a naive substring match.

## 9. Agent loop (pseudo-Gene sketch)

> **This is pseudo-Gene, not runnable code.** It shows the control-flow shape the
> runtime work in §3–§8 must support. Capability/handle values (`env`, `sh`,
> `fs`, `http`) are assumed already granted and in scope (see §8). Helpers shown
> as one-liner comments (`decode-response`, `run-tools`, `render`, `tool-schemas`)
> are elided; the point is the turn loop against Responses-API items, not a
> complete program. It targets the non-streaming milestone-1 transport (§4).

```
# capabilities/handles granted by the launcher (§8): env sh fs http
token := os/get-env(env, "OPENAI_AUTH_TOKEN")              # required
base  := os/get-env(env, "OPENAI_BASE_URL", "https://api.openai.com")
model := os/get-env(env, "OPENAI_MODEL",   "gpt-4o")

# tool name -> fn(args-map) -> result value; each fn is wrapped by the §8.5
# safety policy before it runs.
tools := {
  "read_file":  fn(a) -> fs.read_text(a.path),
  "write_file": fn(a) -> { fs.write_text(a.path, a.content); "ok" },
  "list_dir":   fn(a) -> fs.list_dir(a.path),
  "run_shell":  fn(a) -> sh.exec(cmd="sh", args=["-c", a.command], timeout_ms=10000),
}

fn call_model(input_items) -> response {
  body := json/stringify({ model: model,
                           input: input_items,        # Responses API: `input`
                           tools: tool_schemas })     # function tools
  resp := http.request(method="POST",
                       url=base + "/v1/responses",
                       headers={ authorization: "Bearer " + token,
                                 content_type:  "application/json" },
                       body=body)
  json/parse(resp.body)          # -> {output: [ items... ], ...}
}

# One turn: call the model, then either finish (message item) or run the
# function_call items it emitted and loop with their outputs appended.
fn run_turn(input_items) -> input_items {
  resp  := call_model(input_items)
  calls := filter(resp.output, is_function_call)   # typed output items
  if empty(calls) {
    render(text_of(resp.output))                   # final assistant message
    return input_items
  }
  outputs := for c in calls:                        # {type:"function_call_output",
               run_tool(tools, c)                   #  call_id:.., output:..}
  run_turn(input_items + resp.output + outputs)     # loop until no more calls
}

fn main() {
  with_screen(fn(scr) {                             # milestone 6; line UI before
    items := [ system_item("You are a coding agent.") ]
    loop {
      line := read_input(scr)
      if line == "/quit": break
      items := run_turn(items + [ user_item(line) ])
    }
  })
}
```

## 10. Staged plan

Ordered so each stage is independently testable and the risky pieces (TLS,
curses) are isolated behind working milestones.

1. **`os` namespace**: `get-env`/`env?` (`Os/Env`), `exec`/`exec-stream`
   (`Os/Exec`) with `^timeout-ms` + output cap, `read-line`, `read-input`,
   `refresh-input`, `close-input`; `Fs/read-text`/`Fs/list-dir` sync
   helpers. Spec-tested.
2. **`json`**: `parse`/`stringify` with `JsonError`; round-trip spec tests
   including escapes, nesting, and a depth cap.
3. **Agent loop, bootstrap transport — streaming subprocess.** One streaming
   request against `POST /v1/responses` by shelling out to `curl -N` via
   `os/exec-stream`; parse SSE `data:` lines with `json/parse`; stream text
   deltas into the transcript while retaining the final response item list for
   tool calls. The interactive prompt uses ncurses-backed multiline input while
   preserving line-based behavior in non-TTY tests. Gated on `OPENAI_AUTH_TOKEN`;
   tests inject a fake
   transport (a recorded Responses body) so CI needs no network or key. Model
   the response decoder around Responses output *items* from the start, so the
   later streaming client slots in without reshaping the agent.
4. **Tool use + minimal safety.** `read_file`/`write_file`/`edit_file`/
   `list_dir`/`run_shell`/`grep` as `function_call` handlers, the tool schema
   list, and the dispatch loop — shipped with the minimal single-user policy
   (§8.5 current posture: `rm -rf` denial, simple path check, timeout/output
   caps, display-side redaction, auto-approve). Verified against a scripted
   model-response fixture; the full §8.5 contract and its escape/redaction
   spec tests move to milestone 7.
5. **`net/http-client` (libcurl namespace)**: replace the `curl` subprocess with
   the native client; keep streaming via the channel path in §4 and add real
   cancellation rather than killing a child process.
6. **`curses` namespace + TUI**: scrollable transcript, status line, input line,
   Ctrl-C interrupt; `with-screen` cleanup; swap the line UI for the full
   screen.
7. **Hardening**: the full §8.5 contract (realpath confinement, approval
   policy default-on, redaction of tool output sent to the model, escape/
   redaction spec tests), capability injection via `gene run` flags (§8),
   broader policy config, and interrupt/cancel wired through `Task/cancel`.

Milestones 1–4 make the agent genuinely usable (real API, real tools, real
safety). The new runtime surface they require is: the `os` namespace
(`get-env`/`env?`/`exec`/`exec-stream`/`read-line`/`read-input`/`refresh-input`/`close-input`
with `Os/Env`+`Os/Exec`), the `Fs/read-text` and `Fs/list-dir` sync helpers,
and the `json` namespace — plus the minimal §8.5 safety layer in Gene.
Crucially,
**no TLS, full curses namespace, or OS-level sandbox build-out is required
first** — that is what makes this the sharp MVP. The prompt may use ncurses and
subprocess SSE streaming, but the full TUI (6) and native HTTP client (5) are
isolated behind it. Each
stage follows the repo's rule set: `nimble
test` / `nimble spec` / `nimble perf` before commit, natives implemented in
`src/gene/stdlib.nim` beside the existing db/http code, and every new host power
expressed as a capability value.

## 11. Non-goals (for the first version)

- Windows terminal support (curses assumes a Unix TTY);
- provider abstraction — this targets the OpenAI Responses API shape;
  a `Chat` protocol over multiple providers/surfaces can follow the `Db`
  protocol precedent later;
- persistent session storage — the transcript lives in memory (the `db/sqlite`
  backend is available if persistence is wanted later);
- **OS/process-level** sandboxing of `run_shell` (containers, seccomp, chroot)
  beyond the `Os/Exec` capability gate, the §8.5 in-agent safety contract
  (workspace confinement, approval policy, redaction), and output/time caps;
- TLS certificate pinning and proxy configuration.
