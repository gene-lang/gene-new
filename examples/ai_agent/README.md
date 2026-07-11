# Gene AI Agent

A live, programmable AI coding agent written in Gene — the language's
flagship example. Full design, roadmap, and architecture: [design.md](design.md).

| File | Role |
|---|---|
| `tui.gene` | The terminal agent: streaming model loop, typed tools, event log, `/repl` live programming. Runs standalone (embedded mode). |
| `gateway.gene` | Multi-session gateway over the same turn loop: session actors, HTTP+JSON API with cursor long-poll, embedded web chat, Telegram channel, SQLite persistence. Imports `tui.gene`. |
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
```

## The TUI

Slash commands: `/repl` (live Gene REPL with a stable `session` object —
add tools, inspect state, `(session ~ resume)` to continue the turn),
`/trace` (query the versioned event log: `type=`, `tool=`, `path=`, `turn=`),
`/diff` and `/undo [id]` (only attributable file operations), `/sh` (shell
subsession), `/remember <note>` / `/memory` / `/forget-memory` (durable notes
in the system prompt), `/status`, `/quit`. Ctrl-C cancels an active model/tool
turn and returns to a prompt for steering.

Key environment variables (all optional beyond the auth token):

| Variable | Meaning |
|---|---|
| `OPENAI_AUTH_TOKEN` / `OPENAI_API_KEY` / `CODEX_ACCESS_TOKEN` | bearer token, checked in that order; unset → offline demo |
| `OPENAI_BASE_URL`, `OPENAI_MODEL`, `OPENAI_API` | endpoint, model, wire shape (`responses`\|`chat`) |
| `GENE_AGENT_STATE=<dir>` | persist config/session/memory/events across restarts (`GENE_AGENT_RESUME=0` for a fresh session) |
| `GENE_AGENT_GUARD=0` | disable the catastrophe guard (design.md §8.5) |
| `GENE_LIBCURL=<path>` | override native libcurl discovery; curl(1) is used only if the library cannot load |
| `GENE_AGENT_CONTEXT_MAX_BYTES`, `GENE_AGENT_CONTEXT_MAX_ITEMS` | approximate wire-size/item limits that trigger deterministic compaction |
| `GENE_AGENT_CONTEXT_KEEP_TURNS` | complete recent turns retained during compaction (default 8) |

Tools auto-approve (single-user posture); the guard denies catastrophic
commands and asks once for destructive ones.

## The gateway

```bash
GENE_GATEWAY_PORT=8090 bin/gene run examples/ai_agent/gateway.gene
# then open http://127.0.0.1:8090/ for the web chat
```

Sessions are actors sharing the tui's turn loop; surfaces (web, Telegram
via `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALLOWED_CHAT_IDS`) read one versioned
event log per session. `GENE_GATEWAY_DB=<path>` persists sessions in
SQLite; `GENE_GATEWAY_TOKEN` adds bearer auth (keep the bind on localhost
when unset). `POST /api/sessions/:id/cancel` cancels an active model/tool turn
and terminates its subprocess; `GET /api/sessions` exposes each session's
`busy` state. API routes: design.md §12.2.

## Tests

Everything is verified over loopback with fake endpoints — no network or real
accounts. `tests/test_http_client.nim` includes local HTTP, streaming,
cancellation, bounds, and certificate-verified TLS; `tests/test_cli.nim`
covers the agent and gateway. Run all of it with `nimble test`.
