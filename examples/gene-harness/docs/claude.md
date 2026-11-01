# Claude providers

Gene Harness supports two explicit Claude connections, shared by the browser
and the terminal:

| Provider | Connection | Credentials and billing |
| --- | --- | --- |
| `claude` | Installed Claude Code CLI in print mode | Claude Code owns login, refresh, and billing selection. Can use your signed-in Claude subscription. |
| `anthropic` | Anthropic Messages API | `ANTHROPIC_API_KEY`, otherwise `ant` Console OAuth; metered API billing. |

## Using a Claude subscription

Install a current Claude Code release and sign in outside the Harness:

```sh
claude auth login
claude auth status
```

From `examples/gene-harness`, start the browser host on a project workspace:

```sh
../../bin/gene run src/web/server.gene \
  --workspace /path/to/project --provider claude
```

Retrieve the connection URL with `../../bin/gene run src/main.gene --workspace
/path/to/project link`. CLI session commands connect to this same running host.
You can set `^provider "claude"` in the workspace's `.gene-harness/config.gene`
instead. Saved settings beat the ambient `GENE_HARNESS_PROVIDER`; the explicit
`--provider` launch flag overrides saved settings.

The default CLI model is `sonnet`, resolved by Claude Code. Set
`--model` to another CLI alias or exact supported model ID. `GENE_HARNESS_MODEL`
is a fallback when no saved or launch choice applies to this provider. Set
`GENE_HARNESS_CLAUDE_COMMAND` to an executable path if `claude` is not on PATH.
This value is an executable, not a shell command or an argument string.

The Harness does not read, copy, or refresh Claude OAuth tokens. Claude Code performs its own authentication. If you have API/provider
environment variables configured for Claude Code, its own credential selection
can choose those instead of the subscription; inspect `claude auth status`.

### What subscription usage means today

Checked on 2026-10-31: Anthropic permits an end user to sign in to the
unmodified Claude Code binary with their own subscription. Advertised plan
limits assume ordinary individual use. Harness leaves authentication and
billing selection to that binary. It does not add a Claude.ai login service
or handle subscription tokens in its HTTP adapters.
[Authentication and credential use](https://code.claude.com/docs/en/legal-and-compliance)

The running verification host completed a Sonnet round using an existing
Claude Pro login, with connection billing reported as `plan`.
[Recorded verification](verification/claude-subscription-check-20261031.json)

## Using the Anthropic API

Configure `ANTHROPIC_API_KEY` in the process environment, then use the same
launch command with `--provider anthropic`. If no API key is set, Harness can
use an existing `ant auth login` Console profile. The API key takes precedence.
Harness invokes `ant auth print-credentials --access-token` only for discovery
and transport; `ant` owns refreshing its Console login. Both sources use
metered API billing. No Claude Code executable or subscription login is
required. Subscription and setup tokens are not accepted as API keys.
[Console CLI authentication](https://platform.claude.com/docs/en/cli-sdks-libraries/cli/authentication)

The default API model is `claude-sonnet-5-5`; `--model` overrides it.
The adapter sends the instructions as the system prompt and the session history
as user/assistant messages to `https://api.anthropic.com/v1/messages`, with
`x-api-key` authentication for API keys and `anthropic-version: 2023-06-01`.
Console OAuth instead uses Bearer authentication and the Console OAuth beta
header. It buffers streamed Messages through successful completion, extracts
assistant text blocks and ignores thinking blocks.
[Messages API](https://platform.claude.com/docs/en/api/http/messages/create)

The last two assistant messages carry `cache_control` checkpoints. History
rewrites at most one older message per turn, so everything before the previous
response stays cached; see the history section of [the design](design.md).

The API path uses adaptive thinking and `output_config.effort`. Supported effort
levels depend on the selected model. `auto` uses its catalog default, and an
unsupported portable level resolves down, or to the model's lowest supported
level. For example, `none` becomes `low` on Opus 5.5; Sonnet 5.5 uses
`between_tools` for `none`. The model itself never changes as a fallback.
An unfamiliar model with no verified thinking-off form rejects an explicit
`none` before sending; choose Auto or a supported effort instead.
[Thinking controls](https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking)

The API output budget includes thinking and follows effective effort:
8,192 tokens for none/minimal/low or an unspecified effort, 16,384 for medium,
32,768 for high, 65,536 for xhigh, and 128,000 for max/ultra. The selected
model's output limit caps it; an explicit call budget, including a compaction
summary's budget, takes precedence within that cap. The minimum covers a
recorded 5,694-token summary. Higher-effort reserves remain provisional;
see the [measurement evidence](verification/models-implementation.md#openrouter-live-verification-2026-10-31).
A token-limit stop is an error even if the partial text looks like valid Gene.

## Execution boundary and limits

Claude Code is used as a text-generation backend. The Harness passes its own
system prompt, disables native tools and MCP tools, skips customizations with
safe mode, disables hooks and slash commands, and disables session persistence.
It does not bypass permissions. The CLI is limited to one turn; the Harness
continues to own conversation history, response evaluation, and plugins.
Managed administrative policy still applies to the CLI. The subprocess is not
a Gene filesystem sandbox. [Claude Code CLI options](https://code.claude.com/docs/en/cli-reference)

Do not add `--bare` for the subscription connection: Anthropic documents that
bare mode skips OAuth/keychain credentials. Safe mode preserves authentication
while disabling ordinary customizations. A current CLI with `--safe-mode` and
`--effort` is required; flags were checked against Claude Code 2.1.263.
[Programmatic Claude Code](https://code.claude.com/docs/en/headless)

Both providers return completed responses. Only successful, nonempty text
reaches the response splitter, byte for byte. CLI nonzero exits, reported
errors, timeouts, malformed JSON, and output truncation are rejected. API
refusals, tool-use stops, and incomplete turns are also rejected. Cancelling
the round cancels its CLI subprocess.

The default request timeout is 600 seconds, configurable through
`provider_timeout_ms`. Captured CLI responses are limited to 2 MB; streamed
API responses are limited to 8 MiB. The CLI uses argument arrays without
shell interpolation. Because the CLI takes one
prompt, the Harness serializes the session's message history into it. System
and prompt text together are limited to 128 KiB to stay below common process
argument limits, so long sessions need the `anthropic` provider. Prompts are
process arguments, so local process inspection may expose them. The CLI
controls its own token budget; the API's `max_tokens` setting is not forwarded
to it.

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

The package specs run without a model.
`tests/integration/builtin/provider_anthropic_spec.gene`
serializes actual Anthropic requests across turns and checks that message
content stays byte-stable while the two cache checkpoints move.
The provider specs under `tests/unit/builtin/` check that the Anthropic,
Claude CLI, OpenAI and OpenRouter transports preserve response bytes, so
blocks that end at EOF still split correctly. A real subscription or API
success requires the user's login or key.
