# Gene AI Agent — Design

Status: **the usable bootstrap is shipped: streaming Responses/Chat transports,
file/shell tools, `/sh`, `/repl`, local CLI state/memory, async session actors,
the gateway/web skeleton, Telegram, and SQLite gateway persistence. Slice A is
now shipped too: typed tool declarations (one `Tool` value derives handler +
schema + validation + risk), a stable live `/repl` `session` object, an
authoritative versioned event log with `/trace`, and an extended catastrophe
guard (realpath-confined paths, normal/destructive/catastrophic command
classification, surfaced truncation). Native libcurl, the full TUI, MCP,
worktrees, browser automation, and general multi-agent orchestration are
optional later work, not prerequisites.**
Date: 2026-07-09.

Implemented (see `examples/ai_agent/tui.gene` and `src/gene/stdlib.nim`): the `os`
namespace (`get-env`/`env?` under `Os/Env`, `exec` under `Os/Exec` with
timeout + output caps, `exec-stream` with stdout callbacks, `read-line`,
`read-input`/`refresh-input`/`close-input`), `Fs/read-text`/`Fs/write-text`/
`Fs/list-dir`/`Fs/real-path`, the `json` namespace (`parse`/`stringify`/
`JsonError`), and the agent itself — a streaming Responses-API loop over a
`curl` subprocess, the §8.5 catastrophe guard (realpath-confined workspace
paths, normal/destructive/catastrophic command classification with hard stops
for host-destroying commands and one confirmation for destructive-but-intended
ones, timeout/output caps with surfaced truncation, secret redaction; routine
work auto-approves), and typed tool use — each of `read_file`, `write_file`,
`edit_file`, `list_dir`, `run_shell`, `grep` is one `Tool` value from which the
model-facing JSON Schema, argument validation, risk class, and handler all
derive. Every action appends to a versioned event log (§9.2) that `/trace`
queries and the `/repl` `session` object exposes, plus optional `store/fs`
state persistence for non-secret config, the interactive session, memory, and
the event log. An offline demo transport keeps the loop runnable (and verified)
with no network or key. The native libcurl client, full scrollback TUI, and
launcher capability injection remain available later but do not gate the
signature Gene experience.

This document specifies a live, programmable AI coding agent written in Gene:
a terminal program that holds a conversation with a hosted model API, lets the
model call local tools (read/write files, run shell commands, search), and lets
the user inspect and reshape the running agent through ordinary Gene values.
The API auth token is read from an environment variable; nothing is hard-coded.

**Product decision:** this is first and foremost the author's personal power
tool for developing Gene, not a multi-user service or a parity project against
every commercial coding agent. Optimize for flow, leverage, inspectability,
and dogfooding. Routine local work stays auto-approved. Safety is deliberately
narrow: prevent catastrophic, hard-to-recover actions without surrounding
normal edits, commands, tests, installs, or network calls with permission
theater. Features such as MCP, worktree teams, browser automation, and a plugin
marketplace are a menu to adopt when daily use proves their value.

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

**Packaging target, not current priority:** a single self-contained binary with
native TLS and a native full-screen UI remains attractive, but replacing
working `curl(1)`/prompt infrastructure is scheduled only when it produces a
visible daily-driver benefit. The next slice is the programmable-agent surface
in §10.

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

Behavior:

- a shipped multiline TTY prompt with persistent transcript/status rendering;
  a full-screen curses UI with richer scrollback remains optional later work;
- a conversation loop that sends the running input-item list to the Responses
  API and streams assistant text deltas into the transcript as items arrive;
- **tool use**: the model may return `function_call` items (`read_file`,
  `write_file`, `edit_file`, `list_dir`, `run_shell`, `grep`); the agent
  executes them
  against the local workspace under explicit capabilities and the catastrophe
  guard
  (§8.5), appends `function_call_output` items, and loops until the model
  returns a final message item;
- slash commands in the input line (shipped: `/quit`, `/sh`, `/repl`,
  `/remember`, `/memory`, `/forget-memory`, `/status`; planned next: `/trace`,
  later as dogfooding demands: `/model`, `/clear`, `/diff`, `/undo`), and
  Ctrl-C interrupting a `/sh` command or `/repl` eval (interrupting an
  in-flight model response is part of daily-driver slice B in §10);
- the whole session is ordinary Gene code: messages are maps, tools are `fn`s
  registered in a map, and the transcript is a list — homoiconic and testable.
- the target signature experience makes that last property an official API:
  `/repl` exposes stable session objects, typed tools register from one
  declaration, and `/trace` queries the same versioned events used by the CLI,
  gateway, persistence, and tests.

The single-process CLI above is the **embedded bootstrap** of a larger shape:
§12 extends the same session/turn/tool machinery into a Hermes-style personal
**gateway** — one long-running process that owns every conversation, with the
terminal TUI, a browser web UI, and chat channels (Telegram, Slack) as thin
surfaces onto it.

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

1. **libcurl native namespace (recommended native option).**
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
- **Optional native client:** replace the subprocess with libcurl when
  packaging, cancellation, WebSockets, or measured performance justifies it;
  expose a scheduler-friendly stream/channel API so cancellation and
  worker-thread boundaries are explicit.
- **Future general subprocess API:** a long-lived `os/spawn` with stdin/stdout
  handles or channels may still be useful, but is not needed for the current
  agent.

Both transports present the same non-streaming Gene API; only the native client
adds `stream`:

```gene
(import net/http-client [request Http])         ; optional native client
(var resp (request http ^method "POST" ^url url ^headers hs ^body json-body))
; resp => {^status Int ^body Str}

(import net/http-client [stream])               ; optional native client
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
- `json/stringify : Any -> Str` — inverse over the same value kinds.

A native scanner is the safe choice (correct number/string/escape handling,
depth limit against malicious input — same defensive posture as the HTTP
request parser's caps in `src/gene/stdlib.nim`). Implementation is
self-contained and needs no external library.

With `json`, the Responses request body is just data:

```gene
(json/stringify
  {^model model
   ^input input-items      ; Responses API: a list of typed input items
   ^tools tool-schemas
   ^stream true})          ; shipped transports stream SSE deltas (§4)
```

## 6. Agent tools: files and subprocess (§6)

The model calls tools; the agent executes them under capabilities and returns
results. Tools needed for a coding agent:

- `read_file`, `write_file`, `edit_file`, `list_dir` — files.
  `Fs/read-text-async` / `Fs/write-text-async` still exist; `Fs/read-text`,
  `Fs/write-text`, and `Fs/list-dir` are implemented for the line-oriented
  agent tools.
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

Tools are **typed `Tool` declarations** (shipped, slice A). One `Tool` value is
the single source of truth; the registry entry, model-facing JSON Schema (both
wire shapes), argument validation, and risk class all derive from it:

```gene
(register-tool! (Tool
  ^name "read_file"
  ^description "Read a UTF-8 text file inside the workspace."
  ^risk "read"
  ^params [{^name "path" ^type "string" ^required true
            ^doc "workspace-relative file path"}]
  ^handler (fn [args] (read-text ReadDir (safe-path args/path)))))
```

`Tool` is a `type` with `schema` and `validate-args` messages (§9.1); the turn
loop reads the live registry (`tool-schemas-now`), so a tool added or replaced
from `/repl` reaches the very next model call. This removes the earlier
drift-prone duplication between a handler map and a hand-written schema list,
and demonstrates how types, metadata, functions, and maps compose. Every call
passes through argument validation and then the narrow catastrophe guard in
§8.5, and both the call and its result are appended to the event log (§9.2).

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
ncurses. Inside those subsessions Ctrl-C stops the running command/eval or
clears a partially typed line instead of killing the agent: the interactive
repl installs a SIGINT handler that arms a VM interrupt (surfaced as a
catchable "interrupted" error), and `/sh` traps INT in the shell loop while
`os/exec-stdio` ignores it in the parent, system(3)-style. Interrupting an
in-flight model response is part of daily-driver slice B (§10). A full `curses`
namespace and scrollable transcript TUI remain optional later work, pulled
forward only when the current prompt is the limiting daily-use problem.

## 8. Capabilities and the launcher (§8)

Every new host power is a capability value, consistent with the existing model
(`src/gene/vm.nim` defines `Net/Connect`, `Fs/*`, `Ffi/Load`):

- `Os/Env` — read environment variables (§3);
- `Os/Exec` — spawn subprocesses (§6);
- `Net/Connect` — outbound network (reuse; §4);
- `Fs/ReadWriteDir` — workspace file tools (reuse; §6).

Open runtime question (tracked in `docs/stdlib.md`): how an entrypoint receives
capabilities. Today these are defined on the built-ins root, so the agent script
imports them directly. Capability injection through `gene run` flags remains a
sound future mechanism for embedding or distributing the agent, but it is not
required before the personal tool's live programming model. Capability values
still matter now because typed tools and future actors can state their authority
explicitly even when the launcher grants the normal personal-tool bundle.

### 8.5 Catastrophe guard

**Official posture (2026-07-09): single-user personal power tool, routine work
auto-approved, narrow hard stops for catastrophic and hard-to-recover actions.**
The goal is not to sandbox the author from their own agent or to construct an
enterprise permission system. Normal workspace reads/edits, shell commands,
tests, builds, package installs, and network calls should run without prompts.

The shipped guard classifies each `run_shell`/`/sh`-bound command as `normal`,
`destructive`, or `catastrophic` (`classify-command` in `examples/ai_agent/tui.gene`)
and acts accordingly:

- **Normal:** run immediately.
- **Destructive but plausibly intentional:** show the exact target and require
  one explicit confirmation (`confirm-destructive?`; EOF/no-stdin denies, so a
  destructive command never auto-approves in a scripted run).
- **Catastrophic or nonsensical:** deny outright, and emit a `confirmation`
  event recording the denial. `GENE_AGENT_GUARD=0`, set outside the session,
  disables classification.

Classification anchors command-name patterns at the start of each simple
command (splitting on `&&`, `;`, `|`) so `grep shutdown src/` stays normal while
`ls && git clean -fdx` is caught. File tools realpath every path and reject
anything resolving outside the workspace root, so a symlink inside the workspace
cannot point a read/write outside it. Subprocesses keep their timeouts and
output caps, and truncation is surfaced in both the transcript and the
model-visible tool result. Known auth tokens are redacted from displayed and
model-visible output — including inside event-log entries. `GENE_AGENT_APPROVE_ALL=0`
retains the older prompt-before-write/shell mode for occasional use, but it is
not the primary design.

Shipped coverage (`classify-command` in `examples/ai_agent/tui.gene`):

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
but this tool-call recursion is the shipped loop rather than language-neutral
pseudocode.

```gene
(fn call-model [transport, input-items, render-stream]
  (var body
    (if (== api-flavor "chat")
      (stringify {^model model
                  ^messages (items-to-chat-messages input-items)
                  ^tools chat-tool-schemas
                  ^tool_choice "auto"
                  ^stream true})
      (stringify {^model model
                  ^store false
                  ^stream true
                  ^input input-items
                  ^tools tool-schemas
                  ^tool_choice "auto"
                  ^parallel_tool_calls true})))
  (transport body render-stream))

# Call the model; if it asks for tools, execute them and recur with the model
# output plus function_call_output items. Otherwise render and retain the final
# assistant message. `budget` prevents an endless tool-call loop.
(fn run-turn [transport, input-items, render, render-stream, budget]
  (var streamed (cell false))
  (var resp
    (call-model transport input-items
      (fn [text]
        (Cell/set streamed true)
        (render-stream text))))
  (if (! (== resp/agent_error void))
    (do
      (render resp/agent_error)
      input-items)
    (do
      (var calls (response-calls resp))
      (if (empty? calls)
        (do
          (if (Cell/get streamed)
            (render "")
            (render (redact (response-text resp))))
          (append-all input-items (response-output-items resp)))
        (if (<= budget 0)
          (do
            (render "[stopped: tool-call budget exhausted]")
            input-items)
          (do
            (var outputs
              ((to_stream calls) ~ map run-tool-call ; ~ into []))
            (each (to_stream calls) (fn [c]
              (render $"  · tool ${c/name} ${c/arguments}")))
            (run-turn
              transport
              ((to_stream outputs) ~ into
                (append-all input-items (response-output-items resp)))
              render
              render-stream
              (- budget 1))))))))

# The interactive path adds one user item and stores the returned item list.
(items ~ Cell/set
  (run-turn live-transport
            (append (items ~ Cell/get) (user-item line))
            (fn [text]
              (render-agent-text transcript streaming text))
            (fn [text]
              (render-agent-delta transcript streaming text))
            max-tool-turns))
```

### 9.1 Stable live session object

`/repl` is the agent's defining control surface, not merely an escape hatch.
The shipped REPL binds `session` to a stable `Session` value (a typed node whose
props hold the live cells and tool registry) rather than exposing incidental map
layout. The shipped projections are:

```text
session/config       session/items        session/transcript
session/memory       session/tools        session/events
session/workspace
```

(`current-task` and `evidence` arrive with slice B.) Reads use ordinary
selectors. Mutations go through messages so the session can keep invariants
(system-prompt memory refresh, persistence) and append an audit event:

```gene
(session ~ add-tool (Tool ^name "check" ^description "..." ^risk 'read
                          ^params [...] ^handler my-domain-check))
(session ~ remember "reader datum comments are spacing")
(session ~ subscribe "tool-call")     ; echo future events of this type
(session ~ trace "type=tool-call")    ; same filters as /trace
(session ~ resume)                    ; continue the current turn on exit
```

`add-tool` registers into the same typed registry the turn loop reads, so a tool
added or replaced from `/repl` reaches the very next model call. The API begins
small: it stabilizes the pieces needed to inspect a real turn, add/replace a
typed tool, query events, and continue — not every implementation field or a
general plugin system.

### 9.2 Authoritative event log and `/trace`

CLI and gateway share one append-only, versioned event vocabulary. Shipped
types (`file-change` and `check` arrive with slice B's evidence work):

```gene
{^v 1 ^type "user-input"  ^text "..."}
{^v 2 ^type "model-item"  ^item {...}}
{^v 3 ^type "tool-call"   ^id "..." ^name "read_file" ^args {...}}
{^v 4 ^type "tool-result" ^id "..." ^value "..." ^truncated false}
{^v 5 ^type "text-delta"  ^text "..."}          ; streamed model text
{^v 6 ^type "agent-text"  ^text "..."}          ; the turn's final text
{^v 7 ^type "turn-done"   ^text "..."}          ; exactly one per turn
{^v 8 ^type "confirmation" ^risk "destructive" ^decision "deny" ^target "..."}
{^v 9 ^type "tool-registered" ^name "..." ^risk "read"}
```

`run-turn` and `run-tool-call` write through an explicit **emit sink**: the CLI
passes its process-global logger, the gateway passes a per-session sink — so
each gateway session owns its complete tool trail without cross-session
interleaving. Every value is redacted at append. The event log is authoritative
for rendering and persistence; transcript text, evidence, and current UI state
are projections. Every surface consumes the same events. `/trace` exposes a few useful filters first (type, tool name, path,
event range, current turn), while `/repl` can apply normal selectors and stream
operations. Full replay/fork/compare and sanitized trajectory fixtures are later
extensions, not requirements for the first event slice.

Events carry correlation ids where needed (turn, tool call, actor), module/tool
version hashes once hot reload exists, and redaction/truncation state. They do
not contain hidden chain-of-thought; they record explicit plans, decisions,
actions, results, and evidence.

### 9.3 Dogfood rule

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
   mutations (`add-tool`, `remember`, `subscribe`, `trace`, `resume`) (§9.1).
3. **Done.** CLI and gateway emit one versioned event vocabulary — `user-input`,
   `model-item`, `tool-call`, `tool-result`, `agent-text`, `text-delta`,
   `turn-done`, `tool-registered`, `confirmation`, `memory`, `error` (§9.2,
   §12.3).
4. **Done.** `/trace` filters the log by `type`/`tool`/`path`/`turn`/`from`/`to`
   (a bare token is shorthand for `type=`); the `session` object exposes the
   same filters.
5. **Done.** The §8.5 guard realpath-confines file paths, classifies commands as
   normal/destructive/catastrophic, surfaces output truncation, and redacts
   known secrets — all without prompting for normal work.
6. **Done.** Deterministic fake-model tests cover derived-schema-on-the-wire,
   catastrophe denial, event/trace behavior (`tests/test_cli.nim`), and
   `Fs/real-path` (`tests/spec_runner.nim`).

The signature demo is deliberately single-session: inspect live state in
`/repl`, add or replace a typed Gene tool, query the event trail, and continue
the same turn. It requires no MCP, worktrees, browser, native TLS, or subagents.

### 10.3 Slice B — make it the best daily driver

Choose exact ordering from dogfood pain:

- cancel/steer in-flight model and subprocess work;
- `/diff`, targeted `/undo`, and preservation of pre-existing changes;
- structured command/test/benchmark evidence and explicit unverified claims;
- context visibility and compaction when long sessions actually lose intent;
- prompt/TUI improvements where the current UI causes friction;
- hierarchical `AGENTS.md` loading for work outside the Gene repository.

### 10.4 Slice C — keep repeated workflows

- Promote repeated `/repl` experiments into small Gene workflow modules.
- Record module/tool version hashes and hot-reload new calls without changing
  already-running calls.
- Add hook points only after the same manual workflow repeats.
- Add a Gene-aware module/symbol map if raw search becomes a measured
  bottleneck.
- Add stable JSONL automation if scripting the agent becomes useful.

### 10.5 Slice D — expand only where leverage is proven

- Add one supervised explorer or reviewer actor before general agent teams.
- Orchestrate `git worktree` only when parallel edits are genuinely useful;
  worktrees are greenfield subprocess orchestration, not a current runtime
  primitive.
- Add MCP only when a needed integration justifies its greenfield protocol,
  transport, authentication, and lifecycle surface.
- Add browser/visual automation only when frontend work becomes frequent.
- Extend TUI/web/chat surfaces only when they improve the author's workflow.
- Replace `curl` with native libcurl when packaging, cancellation, WebSockets,
  or performance provides a user-visible reason.

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
  code graph, and large agent teams as prerequisites; each remains optional
  slice-D work triggered by actual use;
- TLS certificate pinning and proxy configuration.

## 12. Local-first multi-surface architecture (gateway, TUI, web, channels)

One long-running **gateway** process owns every conversation; surfaces are
thin views onto it. The terminal agent of §1 becomes one surface among four,
and a session started in the terminal can be continued from the phone. The
gateway is already useful infrastructure, but expanding surfaces is slice-D
work: the embedded CLI and its live Gene control plane remain the primary
product.

```
                       ┌───────────────────────────────┐
  ┌──────────┐  HTTP   │            gateway            │
  │ TUI      │◄───────►│                               │   curl (async)
  ├──────────┤  +JSON  │  session actors (one per      │◄───────────────► model
  │ Web UI   │◄───────►│  conversation): events,       │   Responses/chat APIs
  ├──────────┤ cursor  │  turn loop, typed tools,      │
  │ Telegram │◄──long──│  catastrophe guard            │   curl (async, long-poll)
  ├──────────┤  poll   │                               │◄───────────────► api.telegram.org
  │ Slack    │◄───────►│  event log per session,       │
  └──────────┘         │  sqlite persistence (m11)     │
                       └───────────────────────────────┘
```

Design rules: every piece reuses a pattern already proven in this repo, every
new host power is a capability value, and each addition is independently
shippable and testable over loopback with fake endpoints.

### 12.1 The gateway process and session actors

The gateway is ordinary Gene: `gene run examples/ai_agent/gateway.gene`
(**shipped foundation** — historical milestone 8 sessions/HTTP
API/long-poll/auth/web page, milestone 9 Telegram channel, milestone 11 SQLite
persistence). Additional surfaces and rare remote confirmations are optional
slice-D work. Each
conversation is a **session actor** (`actor/spawn`, design.md §13) owning:

- the Responses-style model item list (the chat adapter normalizes wire
  formats at the boundary);
- a monotonically versioned **authoritative event log** (12.3), from which
  transcript and surface state are projected;
- model config (base/model/flavor per session, defaulted from env as today);
- the typed tool registry + §8.5 catastrophe guard, and at most one pending
  destructive-operation confirmation (12.8).

Actors give per-session ordering for free (one turn at a time per session)
while the scheduler runs sessions concurrently — the same task-per-request
model the `net/http` server already uses, with `http/actor-pool` as the
in-repo precedent for routing requests into actors via `RequestMsg`/reply.

### 12.2 Gateway API (HTTP + JSON)

Served by the existing `net/http` server, bound to `127.0.0.1` by default.
A single static bearer token (`GENE_GATEWAY_TOKEN`) is checked on every
request when set; when unset the API is open and the gateway warns to keep
the bind on localhost — single-user posture (§11), no accounts.

| Route | Meaning |
|---|---|
| `POST /api/sessions` | create session → `{^id ...}` |
| `GET  /api/sessions` | list sessions (id, title, surface, last-event) |
| `POST /api/sessions/:id/messages` | append a user turn; returns immediately |
| `GET  /api/sessions/:id/events?cursor=N` | **long-poll**: events after N, or park until one arrives |
| `POST /api/sessions/:id/confirmations/:cid` | resolve a rare destructive-operation confirmation |
| `POST /api/sessions/:id/cancel` | cancel the in-flight turn (`Task/cancel`, slice B) |
| `GET  /` | the web UI page (12.5) |

Long-poll is the bootstrap streaming mechanism because the `net/http` server
sends complete `Response` bodies — a handler parked on `Channel/recv` waiting
for the next event does not stall other requests (proven by the
handler-parked-in-`sleep` e2e test), so cursor long-poll works **today**;
chunked/SSE response streaming is gap 2 in 12.9.

### 12.3 Event log

Each session appends typed events; surfaces render them and remember only a
cursor. Events are maps (JSON-friendly, like everything else here). The block
below is the **current gateway shape** (string types, snake_case names);
converging it with the §9.2 vocabulary into one set of type names shared by
the CLI, gateway, and `/trace` is slice-A work (§10.2):

```gene
{^v 41 ^type "text_delta"        ^text "..."}          ; coalesced ~100ms
{^v 42 ^type "turn_done"         ^text "full reply"}
{^v 43 ^type "tool_call"         ^id "tc_7" ^name "run_shell" ^args {...}}
{^v 44 ^type "tool_result"       ^id "tc_7" ^value "..." ^truncated false}
{^v 45 ^type "confirmation"      ^id "cf_2" ^risk "destructive" ^target "..."}
{^v 46 ^type "error"             ^text "..."}
```

Deltas are coalesced server-side (~100 ms batches) so chat surfaces that edit
messages (12.6/12.7) and long-poll clients see bounded event rates. All text
passes the §8.5 `redact` before entering the log — tokens live only in the
gateway process; surfaces can only ever receive redacted text. The same event
schema must drive embedded CLI rendering and `/trace`; do not maintain a second
gateway-only vocabulary.

### 12.4 TUI surface

The current CLI keeps working unchanged as **embedded mode** (no gateway).
Optional slice-D work turns the §7 curses TUI into a gateway client: send via
`POST messages`, render via the events long-poll. Live background updates
while the user types require non-blocking input — `nodelay`/`timeout`
`wgetch` polling from a Gene task, exactly as §7 already plans; until then a
client TUI renders events only between keystrokes/turns, which matches
today's behavior.

### 12.5 Web UI

A single static page served by the gateway (`html` helpers;
`examples/todo_app.gene` is the in-repo precedent for a self-contained web
app): vanilla JS, `fetch` to post messages, a long-poll loop for events,
rare destructive-operation confirmations rendered as allow/deny buttons
posting to 12.2. No build step, no framework, no external assets — the page is
a string in the Gene source. Session switcher reads `GET /api/sessions`.

### 12.6 Telegram channel (implemented, milestone 9)

The cheapest remote surface, and deliberately the first: it needs **outbound
HTTPS only**, which the curl transport already provides. As shipped in
`examples/ai_agent/gateway.gene`:

- an adapter task long-polls `getUpdates` (`timeout=50`, offset cursor) via
  `os/exec-async`;
- updates route to sessions keyed by `chat.id` (`tg-<chat-id>`, also visible
  to the HTTP API and web UI); unknown chat ids are dropped unless listed in
  `TELEGRAM_ALLOWED_CHAT_IDS` (single-user posture; `*` allows all);
- replies stream by `sendMessage` + `editMessageText` throttled by size
  (one edit per ~200 new characters), final edit on `turn_done`;
- session events reach Telegram through an **outbound queue**: the session's
  on-event hook does a non-blocking `Channel/try-send` of the event as a
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
   WebSocket client over TLS — blocked on optional native networking work
   (§4, slice D).
2. **Events API**: inbound webhooks to the gateway → needs public HTTPS
   exposure (tunnel) + request signing (`X-Slack-Signature`,
   HMAC-SHA256) → needs a small `crypto` namespace (12.9 gap 4), plus the
   3-second-ack/retry discipline.

Outbound (`chat.postMessage`, throttled `chat.update` for streaming) works
over curl today. Sessions key by `(channel, thread_ts)` so each Slack thread
is a conversation.

### 12.8 Rare destructive confirmations across surfaces

§8.5's catastrophe guard normally produces no interaction. The guard's
confirmation strategy and event sink are injectable (`set-guard-confirm`; the
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
| 1 | ~~**Async subprocess**~~ — **closed (m8)**: `os/exec-async`/`exec-stream-async` run the child on a dedicated OS thread; stdout lines cross via `nativeChannelTrySend` (values marked shared → atomic rc), the Task settles via `tryCompleteTask`+`wakeTaskWaiters`, and root-level `await`/`Channel/recv` poll instead of declaring deadlock while external native ops are in flight | — | — | shipped in `src/gene/stdlib.nim` + spec tests |
| 2 | Streaming HTTP responses (chunked/SSE) in `net/http` | smoother web streaming | cursor long-poll (12.2) | `Response ^stream` fed by a channel |
| 3 | WebSocket + TLS client | Slack Socket Mode | Events API + tunnel | libcurl / native TLS when justified |
| 4 | `crypto/hmac-sha256` (+ constant-time compare) | Slack Events signing | none for public exposure — do not skip | small native namespace beside `json` |
| 5 | Non-blocking TUI input | live TUI updates while typing | render between turns | `nodelay` `wgetch` (§7) |

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
latency, i.e. sessions really run concurrently). Milestone 9 adds a fake
Telegram API server (canned `getUpdates` + captured `sendMessage`), and the
pty harness pattern from the Ctrl-C work covers the TUI client.
