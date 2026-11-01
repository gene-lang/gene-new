# Providers, models and effort

The Models page manages connections, the shared model catalog, endpoint
definitions and the default selection. The conversation composer selects a
model and effort for that session. Triggers can select their own model.

## Providers and connections

A provider is a plugin row that implements a transport. A connection describes
its current account, readiness and billing. Models belong to providers: the
same model offered through two connections is two different choices.

| Provider | Connection | Credentials |
| --- | --- | --- |
| `chatgpt` | Public Responses API with ChatGPT plan authorization | Continue with ChatGPT on the Models page |
| `claude` | Installed Claude Code CLI | Claude Code owns its login and billing selection |
| `anthropic` | Anthropic Messages API, metered | `ANTHROPIC_API_KEY`, then an existing `ant` Console login |
| `openrouter` | OpenRouter Chat Completions | `OPENROUTER_API_KEY`, then `OPENROUTER_KEY`, then the Harness Connect record |

See [Claude providers](claude.md) for CLI setup, API authentication and transport
limits. Harness sign-in records default to `~/.config/gene-harness/`;
`GENE_HARNESS_AUTH_HOME` selects another directory. Account records use
owner-only permissions. ChatGPT sign-in requires both a validated identity and
the granted plan scopes; the Models page supports account selection,
reauthorization, sign-out and a usage-settings link.

The former `codex` backend transport and its credential-file reader are
retired. Use the `chatgpt` connection for Harness-managed ChatGPT sign-in.

Connections report `ready`, `sign_in_required`, `expired` or `unavailable`,
with a reason and billing class (`plan`, `metered`, `local` or `unknown`).
A model list is catalog metadata, not proof of permission to run every model.

## Choosing a model

The composer picker, `/model`, `/effort` and CLI send overrides choose a
session's model. New sessions follow the current default until a session choice
is saved. A selection contains its provider and model together, plus optional
effort; a model ID alone is ambiguous.

Selection precedence is:

1. Internal profile pins and explicit host launch pins.
2. The session's choice, or a trigger's fields for a trigger round.
3. Workspace `.gene-harness/config.gene`.
4. The shared `models.gene` default.
5. Compatible environment defaults.
6. Automatic provider selection.

Use `--provider`, `--model` and `--effort` for explicit launch overrides.
Saved configuration takes precedence over ambient
`GENE_HARNESS_PROVIDER`, `GENE_HARNESS_MODEL` and
`GENE_HARNESS_THINKING_EFFORT`. Model defaults from a different provider do
not leak into the selected provider.

Automatic selection prefers ready plan/local routes to metered routes. Built-in
ranks are Claude Code, ChatGPT, Anthropic and OpenRouter. The browser can ask for
a first-use default when several connections are ready. A selected unavailable
connection makes the profile `not_ready`; it does not silently fall back.

A typed model ID absent from the catalog is accepted as unverified. Unknown
model metadata uses a 128,000-token context window unless capped by workspace
configuration, and image support remains unknown.

### One selection per round

Admission resolves and persists provider, model, requested/effective effort,
model metadata, source and transport identity. Compaction, image checks and
inference use that same selection for the whole round.

Changing the picker, workspace configuration, shared default or catalog affects
subsequent admissions. Same-connection provider code can reload between turns;
credential refresh within the same source can continue. Changing the endpoint,
adapter, credential source, account or reported billing identity stops the
round rather than sending work through a different connection.

Deliberate continuation is a new admission and can choose a different model.
Automatic continuation refuses a changed connection. Delegated children resolve
their own model metadata from the parent's provider and requested effort, and
must retain the parent's connection identity.

A submission without a new selection uses the backend's current session choice.
There is no stale-preview revision check. Busy or rejected submissions do not
save a new choice.

## Shared configuration

The file is `<manager root>/.gene-harness/models.gene`. The root resolves from
the explicit manager root, then `GENE_HARNESS_ROOT`, then
`~/.gene-harness-root`. Managed workspaces inherit the resolved root.

The file is inert serde data. It contains the default, custom endpoint
providers, model overrides and named presets. It contains credential
references, never secret values. For example:

```gene
(serde_v1
  {^version 1
   ^default {^provider "local" ^model "example-model" ^effort "auto"}
   ^providers
     [{^name "local" ^adapter "openai_chat"
       ^base_url "http://127.0.0.1:11434/v1"
       ^^discover
       ^models [{^id "example-model" ^window 128000}]}]
   ^models []
   ^presets
     [{^name "local-default" ^provider "local"
       ^model "example-model" ^effort "auto"}]})
```

The endpoint and model above are illustrative; replace them with a running
service and a model it supports.

| Entry | Fields |
| --- | --- |
| Top level | `version` (1), `default`, `providers`, `models`, `presets` |
| Provider | `name`, `adapter`, `base_url`, optional `credential`, `discover`, `models` |
| Credential reference | Exactly one of `{^env "VARIABLE"}` or `{^command ["executable" "argument"]}` |
| Model | `id`; `provider` for top-level overrides; optional `label`, `rank`, `window`, `max_output`, `input`, `efforts`, `default_effort`, `hidden`, `effective_percent`, `prompt_limit_bytes`, `pricing` |
| Preset | `name`, `provider`, `model`, optional `effort` |

Supported adapters are `openai_chat`, `openrouter_chat`,
`openai_responses` and `anthropic_messages`. They preserve their distinct
wire fields and response handling. Known protocols can be configured through
the file; a new protocol requires a provider plugin.

Unknown fields are rejected. Endpoint URLs must use HTTP(S) without embedded
credentials, query or fragment. Conflicting provider names and invalid entries
produce per-entry errors. A malformed file is reported without preventing the
host from starting; an invalid configured default requires correction or an
explicit selection.

Model fields merge in this order: file overrides, discovery, built-in metadata.
Built-in lists support offline or initial use; they are not a universal model
catalog. Hidden models stay out of normal picker results.

### Saving and reloading

The Models page and Set as default use an atomic write under a cross-process
`models.lock`, with an expected digest. A stale save returns
`revision_conflict`; lock waits are bounded. Hand edits are supported, although
an editor does not participate in this lock and can race a simultaneous save.

File-defined provider rows reactivate when configuration changes. A running
round retains its selection and stops if the transport identity changes.
The catalog is optional: removing its plugin removes its picker and metadata
services, while provider execution and recovery remain separate.

## Discovery and effort

Connection/model discovery runs outside the inference path. The catalog
publishes cached immutable snapshots and a revision. Startup, Refresh and
background retries update it; reading status or listing models does not start
an inference call.

Healthy connections refresh daily. Non-ready or stale entries retry after
30 seconds with exponential backoff capped at five minutes. Transient failures
can retain a previous ready connection and its models as stale; explicit
sign-out or expiry replaces readiness. A transport 401 expires the cached
connection. Manual Refresh requests another discovery pass.

The portable effort ladder is:

```text
none → minimal → low → medium → high → xhigh → max
```

`auto` uses the model's advertised default, or leaves effort unspecified when
no default is known. Supported requested levels pass through. An unsupported
portable level resolves down to a supported level, or to the lowest supported
level when none lies below it. Native extras such as `ultra` require explicit
model support. The UI shows requested and effective effort when they differ.

Effort levels are not equivalent reasoning budgets across vendors. Adapter
output budgets depend on effective effort and are capped by model limits;
explicit call budgets, including summaries, take precedence within those caps.
CLI and plan transports retain their own supported controls. Only complete,
successful responses reach response evaluation; incomplete or token-limited
responses are errors.

## Triggers and programmatic access

Triggers accept `model_settings`. Omitting it follows the current workspace
default at firing time; an effort-only map follows that model with the requested
effort. Trigger selections never inherit the creating session's choice. See
[Triggers](triggers.md) for creation, updates and readiness behavior.

`list_models` returns ready, visible provider/model pairs, effort and context
metadata, and billing. It supports `provider`, `q`, `offset` and `limit`
with a maximum page size of 200 and a `next_offset` result.

Provider plugins contribute `configure`, `prepare` and `send`, with optional
`connection` and `models` discovery callbacks. `prepare` produces
model-visible input without credentials; transport resolves credentials.
See [Plugins](plugins.md) for registry ownership and public host protocols.
The `models/catalog` service exposes snapshots, configuration, refresh,
connection/account workflows, saves, defaults and session selection.

Web protocol 9 publishes `catalog_revision` separately from the catalog.
Clients fetch `GET /api/v9/models` on change and request discovery with
`POST /api/v9/models/refresh`. Round submissions and deliberate continuations
accept `model_settings`; an empty map clears the session pin at admission.
See [Web client](web-client.md#wire-protocol-9).

## Verification and limits

The [test guide](../tests/README.md) describes model-free regression checks.
Catalog, selection, authentication and adapter tests use fixtures and isolated
local processes. Passing those tests does not demonstrate live provider access.

The output-budget regression retains a small historical coding-usage sample in
`tests/fixtures/recorded-coding-token-observations-20261031.json`. It checks that
the minimum default covers the observed summary peak while respecting explicit
budgets and model caps. That sample does not establish production budgets for
every model or effort.
