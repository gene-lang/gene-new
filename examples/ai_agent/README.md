# Gene AI Agent

A live, programmable AI coding agent written in Gene — the language's
flagship example. Full design, roadmap, and architecture: [design.md](design.md).

| File | Role |
|---|---|
| `tui.gene` | Main application: terminal agent, native agents/panes, streaming model loop, typed tools, event log, `/repl`, and optional gateway flags. |
| `gateway_adapter.gene` | UI-neutral HTTP/web/Telegram gateway adapter composed by the main application. |
| `gateway.gene` | Thin headless compatibility launcher over `tui.gene` + `gateway_adapter.gene`. |
| `logging.gene` | Trace-level JSONL diagnostic profile for the agent; writes `logs/agent.jsonl` beside the config. |
| `design.md` | The design document (formerly `docs/ai-agent.md`) — what exists, what's next, and why. |
| `package.gene` | Package manifest. |

## Quick start

```bash
nimble build   # from the repo root

# Offline demo — no network or key; drives the full tool_call loop:
bin/gene run examples/ai_agent/tui.gene

# Live against the Codex/ChatGPT Responses backend:
OPENAI_AUTH_TOKEN=... bin/gene run examples/ai_agent/tui.gene

# Live against any OpenAI-compatible chat endpoint (MiniMax, DeepSeek, vLLM...):
OPENAI_BASE_URL=https://api.minimax.io/v1 OPENAI_MODEL=MiniMax-M2 \
OPENAI_API_KEY=... bin/gene run examples/ai_agent/tui.gene

# One-shot (no interactive prompt):
OPENAI_AUTH_TOKEN=... bin/gene run examples/ai_agent/tui.gene "explain src/gene/reader.nim"

# Detailed structured diagnostics (prompts, model text, tool args/output, and
# credentials are deliberately excluded):
bin/gene run --log-config examples/ai_agent/logging.gene \
  examples/ai_agent/tui.gene
```

## Diagnostic logging

The agent has two intentionally separate records:

- `/trace` and `session/events` are the authoritative, versioned action log.
- `app/ai_agent/*` structured logs are best-effort operational diagnostics.

The checked-in `logging.gene` profile captures trace through error records as
JSONL in `examples/ai_agent/logs/agent.jsonl`. It covers startup/shutdown,
turns and model rounds, HTTP backend and timings, tool outcomes, guard
decisions, context compaction, state persistence, instructions, cancellation,
and failures. It records sizes, counts, identifiers, durations, and outcomes;
it does not copy conversation or command content.

Event-boundary diagnostics carry `worker_id`, `agent_id`, `task_id`, and the
surface-local `pane_id`/`surface_id` when the event has them. Global, headless,
and worker-only records intentionally have no pane id. Use `/trace worker=W` or
open `/tail worker=W` for a pane-local filtered view of the authoritative log;
diagnostic severity remains launcher-owned through `--log-config`.

Level policy:

| Level | Agent use |
|---|---|
| `error` | Unexpected turn failure that aborts the active turn |
| `warn` | Transport degradation/failure, denied dangerous action, exhausted limits, or state/instruction failure |
| `info` | Agent and turn lifecycle, tool outcomes, accepted destructive action, context compaction, state restoration |
| `debug` | Model rounds, request/response sizes and timings, HTTP backend, subprocess/check details, state writes |
| `trace` | Content-free stream delta sizes, authoritative-event boundaries, state reads, resource cleanup |

## The TUI

Slash commands: `/repl` (live Gene REPL with a stable `session` object —
add tools, inspect state, `(session ~ resume)` to continue the turn),
`/trace` (query the versioned event log: `type=`, `tool=`, `path=`, `turn=`),
`/diff` and `/undo [id]` (only attributable file operations), `/sh` (open or
focus a cancellable foreground shell pane), `/tty` (local user-driven escape
for interactive or persistent/background shell work), `/remember <note>` / `/memory` /
`/forget-memory` (durable notes in the system prompt),
`/effort [level]` (show all reasoning-effort levels and the current choice, or
set it for subsequent model requests),
`/model [model]` (show or change the main agent's model),
`/model N [model]` (show or change the agent attached to pane N; pane 0 is the
main agent),
`/agent new [prompt]` (open a secondary agent pane), `/agents`,
`/pane output [title]`, bare `/N` (focus), `/N <input>`, `/close [N]`,
`/N cancel|stop|max`
(address or control pane N), `/max [N]` (toggle maximize for the focused
pane, or pane N; focusing another pane restores the split), `/export <file>` / `/N export <file>` (write the
focused pane's — or pane N's — retained content to a new workspace file; with
no pane focused, `/export` writes the main transcript), `/status`, `/quit`,
`/exit`. The primary agent can
also use the independent `spawn_agent`, `send_agent`, `agent_result`,
`cancel_agent`, `stop_agent`, `open_pane`, `append_pane`, and `close_pane`
tools; `open_extension` remains a convenience composite. Each agent keeps its
own model context for follow-up prompts. Ctrl-C cancels an active
model/tool turn and returns to a prompt for steering.

`/view <file>` temporarily leaves the agent TUI and runs `gene view <file>`
through the current executable. Quit the viewer to return to the agent.
`/pane new view <workspace-path>` instead creates a confined shared read-only
pane that is persisted with the application.

Key environment variables (all optional beyond the auth token):

| Variable | Meaning |
|---|---|
| `OPENAI_AUTH_TOKEN` / `OPENAI_API_KEY` / `CODEX_ACCESS_TOKEN` | bearer token, checked in that order; unset → offline demo |
| `OPENAI_BASE_URL`, `OPENAI_MODEL`, `OPENAI_API` | endpoint, initial main-agent model, wire shape (`responses`\|`chat`); new sub-agents inherit the main model and can then be changed independently with `/model` |
| `OPENAI_REASONING_EFFORT` | initial reasoning effort: `default`, `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`; `default` omits the request field and individual models may support only a subset |
| `OPENAI_REQUEST_TIMEOUT_MS` | model request timeout for both wire shapes; defaults to 300000 ms so high-effort and post-tool rounds can finish |
| `GENE_AGENT_STATE=fs:<path>` | persist config, application/session state, memory, and events as filesystem records under `path`; a bare path remains accepted for compatibility |
| `GENE_AGENT_STATE=db:sqlite:<path>` | persist the same records in SQLite; additional database URL schemes can be added behind the same Store interface |
| `GENE_AGENT_HOME=<dir>` | filesystem fallback when `GENE_AGENT_STATE` is unset or blank; reusing the same home restores state automatically |
| `GENE_AGENT_RESUME=0` | start fresh while continuing to save into the selected store |
| `GENE_AGENT_CHECKPOINT_INTERVAL_MS` | minimum interval between high-volume progress checkpoints (default 1000 ms); tool calls and lifecycle transitions save immediately |
| `GENE_AGENT_GUARD=0` | disable destructive/catastrophic risk classification; mediated background/detach forms remain denied (design.md §8.5) |
| `GENE_LIBCURL=<path>` | override native libcurl discovery; curl(1) is used only if the library cannot load |
| `GENE_AGENT_CONTEXT_MAX_BYTES`, `GENE_AGENT_CONTEXT_MAX_ITEMS` | approximate wire-size/item limits that trigger deterministic compaction |
| `GENE_AGENT_CONTEXT_KEEP_TURNS` | complete recent turns retained during compaction (default 8) |
| `GENE_AGENT_MAX_TOOL_ROUNDS` | maximum model/tool rounds per turn (default 12); transient landing notices appear with two and one executable rounds left |

Tools auto-approve (single-user posture); the guard denies catastrophic
commands and asks once for destructive ones. All mediated shell channels also
enforce foreground lifetime independently of that optional classifier; use
`/tty` for deliberate persistent/background work.

## The gateway

```bash
# Integrated headless gateway:
bin/gene run examples/ai_agent/tui.gene -- --gateway --headless

# TUI and gateway in one process (explicit port overrides the environment):
OPENAI_AUTH_TOKEN=... bin/gene run examples/ai_agent/tui.gene -- --gateway=8090

# Compatibility launcher:
GENE_GATEWAY_PORT=8090 bin/gene run examples/ai_agent/gateway.gene
# then open http://127.0.0.1:8090/ for the web chat
```

Sessions are actors sharing the tui's turn loop; surfaces (web, Telegram
via `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALLOWED_CHAT_IDS`) read one versioned
event log per session. Each session owns the same native agent/pane application
services as the TUI. In combined mode, `GET /api/sessions` includes `local`,
which addresses the already-live terminal session. `GENE_GATEWAY_DB=<path>` persists sessions in
SQLite; `GENE_GATEWAY_TOKEN` adds bearer auth (keep the bind on localhost
when unset). `POST /api/sessions/:id/cancel` cancels an active model/tool turn
and terminates its subprocess; `GET /api/sessions` exposes each session's
`busy` state. API routes: design.md §12.2.

## Tests

Everything is verified over loopback with fake endpoints — no network or real
accounts. `tests/test_http_client.nim` includes local HTTP, streaming,
cancellation, bounds, and certificate-verified TLS; `tests/test_cli.nim`
covers the agent and gateway. Run all of it with `nimble test`.
