# Claude providers

Gene Harness supports two explicit Claude connections, shared by browser chat,
the terminal, and plugin authoring:

| Provider | Connection | Credentials and billing |
| --- | --- | --- |
| `claude` | Installed Claude Code CLI in print mode | Claude Code owns login, refresh, and billing selection. Can use your signed-in Claude subscription. |
| `anthropic` | Anthropic Messages API | `ANTHROPIC_API_KEY`; separate API billing. |

## Using a Claude subscription

Install a current Claude Code release and sign in outside the Harness:

```sh
claude auth login
claude auth status
```

From `examples/gene-harness`, start the browser host:

```sh
mkdir -p /tmp/harness-claude
env GENE_HARNESS_PROVIDER=claude \
  ../../bin/gene run \
  --allow_read_write_dir /tmp/harness-claude \
  --allow_read_dir ../../tools/gene-lang-skill \
  src/web/server.gene --home /tmp/harness-claude
```

Open the connection URL printed by the server. To use the terminal instead,
replace the entry and arguments with `src/main.gene chat` and set
`GENE_HARNESS_HOME=/tmp/harness-claude` in the environment.

The default CLI model is `sonnet`, resolved by Claude Code. Set
`GENE_HARNESS_MODEL` to another CLI alias or exact supported model ID. Set
`GENE_HARNESS_CLAUDE_COMMAND` to an executable path if `claude` is not on PATH.
This value is an executable, not a shell command or an argument string.

The CLI needs the launcher's `os/Exec` authority. The Harness does not need a
read grant for `~/.claude` and does not read, copy, or refresh Claude OAuth
tokens. Claude Code performs its own authentication. If you have API/provider
environment variables configured for Claude Code, its own credential selection
can choose those instead of the subscription; inspect `claude auth status`.

### What subscription usage means today

Checked on 2026-09-14: Anthropic's June 15 update says its proposed separate
Agent SDK credit change was paused. The update says Agent SDK, `claude -p`, and
third-party app usage still draw from subscription usage limits. It does not
promise unlimited use. [Anthropic's current plan guidance](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)

This integration runs the official local CLI for the signed-in user's use.
It does not add a Claude.ai OAuth login service or reuse subscription tokens
in a custom HTTP client. Shared or hosted products should use an API key;
Anthropic distinguishes individual CLI/SDK use from services routing requests
through their users' subscription credentials. [Authentication and credential use](https://code.claude.com/docs/en/legal-and-compliance)

## Using the Anthropic API

Configure `ANTHROPIC_API_KEY` in the process environment, then use the same
launch command with `GENE_HARNESS_PROVIDER=anthropic`. No Claude Code executable
or Claude login is required. OAuth setup-tokens are not accepted as API keys.

The default API model is `claude-sonnet-5`; `GENE_HARNESS_MODEL` overrides it.
The adapter sends the system prompt and user/history text to
`https://api.anthropic.com/v1/messages`, with `x-api-key` authentication and
`anthropic-version: 2023-06-01`. It extracts assistant text blocks and ignores
thinking blocks. [Messages API](https://platform.claude.com/docs/en/api/http/messages/create)

The API path uses adaptive thinking and `output_config.effort`. Supported effort
levels depend on the selected model. `none` sends disabled thinking and omits
effort; `minimal` maps to `low`. Use an adaptive-thinking model with the default
configuration; for older models without adaptive thinking, select `none` if the
model supports disabled thinking. The API rejects unsupported model/effort
combinations rather than silently changing models. [Thinking controls](https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking)

Default API response budgets are 8,192 tokens for normal turns and 16,384 for
plugin authoring, including thinking. A token-limit stop is an error even if
the partial text happens to look like valid Gene.

## Execution boundary and limits

Claude Code is used as a text-generation backend. The Harness passes its own
system prompt, disables native tools and MCP tools, skips customizations with
safe mode, disables hooks and slash commands, and disables session persistence.
It does not bypass permissions. The CLI is limited to one turn; the Harness
continues to own conversation history, tool dispatch, and plugin evaluation.
Managed administrative policy still applies to the CLI. The subprocess is not
a Gene filesystem sandbox. [Claude Code CLI options](https://code.claude.com/docs/en/cli-reference)

Do not add `--bare` for the subscription connection: Anthropic documents that
bare mode skips OAuth/keychain credentials. Safe mode preserves authentication
while disabling ordinary customizations. A current CLI with `--safe-mode` and
`--effort` is required; flags were checked against Claude Code 2.1.263.
[Programmatic Claude Code](https://code.claude.com/docs/en/headless)

Both new providers return completed responses; raw token previews are currently
specific to Codex. Only successful, nonempty text enters the existing Gene
envelope validator. CLI nonzero exits, reported errors, timeouts, malformed JSON,
and output truncation are rejected. API refusals, tool-use stops, and incomplete
turns are also rejected. Cancelling the Harness run cancels its CLI subprocess.

Requests have a 180-second timeout and a 2 MB captured-response limit. The CLI
uses argument arrays without shell interpolation. System and user text together
are limited to 128 KiB to stay below common process argument limits; use the
native API for larger contexts. Prompts are process arguments, so local process
inspection may expose them. The CLI controls its own token budget; the API's
`max_tokens` setting is not forwarded to it.

Provider errors are summarized without copying raw API error bodies or CLI
stderr into the transcript. Credentials never enter model prompts or persisted
Harness state.

## Hermes and OpenClaw findings

OpenClaw's current preferred route invokes the installed Claude CLI and leaves
native login/refresh to Claude. Hermes' native Anthropic OAuth adapter instead
reads and refreshes Claude credentials and shapes direct API requests with
Claude Code identity headers. Hermes' documented Max-plus-extra-credits caveat
applies to that direct OAuth route. It is not a general rule for official CLI
use. [OpenClaw provider](https://docs.openclaw.ai/providers/anthropic),
[Hermes provider](https://hermes-agent.nousresearch.com/docs/integrations/providers#anthropic-native)

The Harness follows the official CLI approach for local subscriptions and
provides a separate API-key transport. The implementation deliberately does not
depend on token extraction, setup-token reuse, client impersonation, or a proxy.

## Verification

Focused provider checks cover configuration, API request fields, content/stop
validation, CLI arguments, error redaction, and subprocess cancellation. A
controlled CLI fixture exercised the real browser-profile runtime through chat,
plugin generation, activation, and a tool call returning `42`. The installed
Claude CLI accepted the invocation flags but reported no authenticated account
on this machine at implementation time; no API key was configured. A real
subscription/API success requires the user's login/key. No package test suite
was run, following the Harness development workflow.
