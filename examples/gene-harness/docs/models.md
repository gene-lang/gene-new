# Providers, models and effort

Status: implemented, 2026-10-31. [Implementation and verification](verification/models-implementation.md).
This design was written on 2026-10-30; "Today" describes the code at f613a338.
Vendor facts were checked on that date; see
[Sources](#sources).

## What we want

1. One place to add providers and models.
2. Existing ChatGPT and Anthropic logins are found automatically, and OpenRouter is
   supported from the first version.
3. One provider, model and effort can be chosen as the default.
4. The prompt box can select the model and effort.
5. One effort setting works across providers.
6. A trigger can choose its own model and effort when it is created.

## The short version

- **The central place is a data file**, `<manager root>/.gene-harness/models.gene`.
  It adds models and OpenAI- or Anthropic-compatible endpoints, and holds the
  default. It never holds a secret. Provider plugins remain the only code path
  to a new wire protocol.
- **Every provider reports a connection and a model list.** The Harness merges
  them with the file into one catalog, which feeds the picker, the effort menu,
  compaction and image checks.
- **"Discover by OAuth" means different things for each vendor.** For Anthropic
  subscriptions the Harness may only ask `claude auth status` and send through
  the `claude` binary. It must never read that login's token. ChatGPT has an
  official route for local open-source apps, but it is not the one we use today.
- **Effort is one ordered ladder, plus what each model really supports.** The
  operator requests a level, the catalog resolves it for the model, and the
  picker shows the result when they differ. Levels are not equal across vendors,
  and the design does not pretend they are.

## Today

| Area | Behavior | Where |
| --- | --- | --- |
| Providers | `providers` plugin rows: `configure`, `prepare`, `send`, optional `available`, `auto`, `capabilities` | `src/registries/contracts.gene:32` |
| Models | A free string. Each row hardcodes one default. There is no list. | `src/builtin/provider_*.gene` |
| Effort | One enum checked in `configure_model`, then passed to the wire nearly as is. Empty means `medium`. | `src/public/provider.gene:15` |
| Default | `provider`, `model`, `effort` in each workspace's `config.gene`, or the environment | `src/agents/provider_selection.gene` |
| Per-session choice | `metadata/model_settings` exists and is honored, but only delegated children write it | `src/runtime/round_controller.gene:113` |
| Readout | The header and status drawer show model, provider and effort. Nothing selects them. | `client/main.gene:577`, `:1114` |

Problems this design has to fix:

| Problem | Evidence |
| --- | --- |
| A Claude-subscription-only user gets "no provider is available". | The `claude` row has no `auto` or `available`, and `choose_auto` skips rows without `auto`. |
| A metered key beats a plan that is already paid for. | Auto ranks are OpenRouter 0, Anthropic 1, Codex 2. |
| Effort `none` fails on current Claude models. | The `anthropic` row always sends `thinking: disabled`. Anthropic documents a 400 for that on Opus 5.5, Sonnet 5.5 and Fable 5/5.1. Not exercised live. |
| `none` and `minimal` reach Codex models that do not list them. | Every model in the local Codex catalog starts at `low`. The row forwards the value unchanged. Not exercised live. |
| `ultra` cannot be selected. | The Codex catalog lists it on some models, and `configure_model` rejects it. |
| The `medium` fallback overrides each model's own default. | The Codex catalog defaults some models to `low`. Anthropic's default is `high` on Sonnet 5.5. |
| Higher effort can turn into failures. | The `anthropic` budget is 8,192 tokens including thinking, and a token-limit stop is an error. OpenRouter defaults to 3,000. |
| One context window is used for every model. | `context_window` falls back to 128,000 (`src/agents/turn_loop.gene:282`). Local Codex models report 272,000 and 500,000, and current Claude models 1M. |
| The default shown in status does not update. | `service/model_info` is computed once when the service opens (`src/web/session_service.gene:378`). |
| Truncated OpenRouter output reaches the response evaluator. | `openrouter_text` checks only the status and that content is a string. A probe passed a `finish_reason: "length"` response through unchanged, and an empty response and an error choice also came back as text. The README says only complete responses are evaluated. |
| Precedence has two orders. | Managed and session settings read saved-first, direct launches read environment-first (`provider_selection.gene:35`, `:74`). |

## Concepts

- **Provider**: a plugin row that speaks one wire protocol through one transport.
  `codex`, `anthropic`, `claude` and `openrouter` exist today.
- **Connection**: a provider's live state: signed in or not, which credential,
  and who pays. Discovery produces it.
- **Model**: a catalog row belonging to one provider. `anthropic` and `claude`
  can offer the same Claude model separately, because cost, limits and features
  differ by route.
- **Selection**: `{^provider ^model ^effort}`, always kept together. A model
  name has no meaning without its provider.

## Initial providers

The first version supports these providers, and each one gets discovery, the picker and
effort resolution. Anything else is added through `models.gene` or a plugin.

| Provider | Route | Credential | Billing | Sign-in from the Harness |
| --- | --- | --- | --- | --- |
| `codex` | Codex login, `backend-api` | `~/.codex/auth.json` | Plan | No; run `codex login` |
| `claude` | `claude` binary | Claude Code's own login | Usually plan | No; run `claude auth login` |
| `anthropic` | Messages API | API key, later `ant` | Metered | No |
| `openrouter` | Chat Completions | API key | Metered | Later, through OpenRouter's OAuth |

The ChatGPT sign-in provider comes after these; see [ChatGPT](#chatgpt).

## The central place

### Three ways to add something

| To add | Do this |
| --- | --- |
| A model on an existing provider | Add a line to `models.gene`, or let discovery find it |
| An endpoint that speaks a known protocol | Add a provider entry naming an `^adapter` |
| A new wire protocol | Write a provider plugin, as today |

### `models.gene`

It lives in the manager root because that location already resolves without a
running manager: `--root`, then `GENE_HARNESS_ROOT`, then `~/.gene-harness-root`.
Manager-launched children must inherit the resolved root, including `--root`, so
they read the same file.

The format is inert serde data, like `config.gene`. This example parses with
`$serde/read_data`; the endpoint and model names are illustrative.

```gene
(serde_v1
{^version 1
 ^default {^provider "anthropic" ^model "claude-opus-5-5" ^effort "high"}
 ^providers
   [{^name "ollama" ^adapter "openai_chat"
     ^base_url "http://127.0.0.1:11434/v1"
     ^^discover
     ^models [{^id "qwen3:32b" ^window 128000}]}
    {^name "work_proxy" ^adapter "openai_responses"
     ^base_url "https://llm.example.com/v1"
     ^credential {^env "WORK_LLM_KEY"}
     ^!discover
     ^models [{^id "gpt-6.1-sol" ^label "Sol (work)" ^window 500000
               ^efforts ["low" "medium" "high"] ^default_effort "medium"}]}]
 ^models
   [{^provider "openrouter" ^id "moonshotai/kimi-k3" ^window 256000}
    {^provider "codex" ^id "gpt-5.6-luna" ^^hidden}]
 ^presets
   [{^name "fast" ^provider "anthropic" ^model "claude-haiku-5-5" ^effort "low"}
    {^name "deep" ^provider "anthropic" ^model "claude-fable-5-1" ^effort "high"}]}
)
```

Rules:

- **No secrets.** `^credential` is `{^env "NAME"}` or `{^command [...]}`. The
  validator rejects unknown fields, so `^api_key` is an error, not a stored key.
  One shared resolver reads credentials; see [Reading credentials](#reading-credentials).
- **Adapters are small but not interchangeable.** `openai_chat`, `openrouter_chat`,
  `openai_responses` and `anthropic_messages` become constructors in
  `src/public/provider.gene`. The two chat adapters share message construction and
  HTTP handling, but each keeps its own effort and output-budget fields; see
  [Mapping to the wire](#mapping-to-the-wire).
- **A broken file never stops the host.** Built-in providers keep working, and
  the Models page shows the parse error. `doctor` and recovery do not read it.
- **Name conflicts are reported on the entry.** A file entry named `codex`
  shows an error there and does not fail startup.
- **Saves are serialized across hosts.** Every host shares this file, so a save needs
  a lock that spans hosts; see [Saving the shared file](#saving-the-shared-file).
- **Edits reach a row between turns only if its connection is unchanged.** Saving
  reactivates the plugin that contributes file-defined rows, and a running turn
  finishes on the row it leased. A changed endpoint or credential source stops a running
  round instead; see [One selection per round](#one-selection-per-round).

Precedence for model fields is the file, then discovery, then the plugin's
built-in list. The built-in list exists only so the picker works offline or
before the first refresh. We do not maintain a master list of the world's models
in this repository, because it would go stale immediately.

### Provider row additions

Both callbacks are optional. A row with neither still works and accepts a typed
model id.

```gene
^connection (fn []
  {^state "ready"              # ready | sign_in_required | expired | unavailable
   ^label "ChatGPT · Codex login"
   ^billing "plan"             # plan | metered | local | unknown
   ^reason nil})
^models (fn []                 # may call the network; time-boxed by the caller
  [{^id "gpt-6.1-sol" ^label "GPT-6.1-Sol" ^rank 1
    ^window 475000 ^max_output nil ^input ["text" "image"]
    ^efforts ["low" "medium" "high" "xhigh" "max" "ultra"]
    ^default_effort "low" ^!hidden}])
```

`connection` replaces `available`. It may start a process, so it must not run in
the per-turn path. A host service runs discovery and caches the result, and
`provider_reason` reads that cache. It runs at host start without blocking it, on
**Refresh**, every 24 hours, and marks a connection `expired` after a provider
401. Each probe gets 5 seconds. On failure the last catalog stays, marked stale.
Transient failures preserve a previously ready connection; positive signed-out
or expired results replace it. Unavailable or stale connections retry after
30 seconds, with exponential backoff capped at five minutes. Healthy providers
retain their 24-hour refresh interval, and a manual Refresh probes immediately.

The merged catalog is cached in `<manager root>/.gene-harness/model_catalog.gene`
with an atomic write, so a new host has a list immediately. Last writer wins is
fine for a cache. It is not fine for tokens; see [ChatGPT](#chatgpt).

`capabilities` can then read `image_input` from the catalog instead of answering
`unknown`, and the context window comes from the selected model:
`window × effective percent` for Codex. Workspace `context_window` becomes an
optional cap.

### Reading credentials

Authenticated discovery needs the same credentials as inference, so
`resolve_credential` in `src/public/provider.gene` is the one reader for file-defined
credentials. Built-in rows follow the same rules for their own.

- **Who may call it:** transport operations only: `send` and the discovery calls in
  `connection` and `models`. `prepare` never receives a credential.
- **Where the output never goes:** prepared requests, transcripts, the catalog cache
  and error messages. A failed `^command` reports a generic reason without its stderr,
  as `provider_codex` already does for `auth.json` parse errors.
- **The time limit:** a command's run counts toward the probe's 5 seconds.

A probe never spends money. Listing models is the check, and a paid inference call is
never used just to establish a connection:

| Probe result | Connection | Model list |
| --- | --- | --- |
| 200 | `ready` | Replaced |
| Credential cannot be resolved | `sign_in_required` | Last list, stale |
| 401 or 403 | `expired` | Last list, stale |
| 404 or 405, no list endpoint | Unchanged | Models from the file |
| Timeout, network error, 5xx or bad JSON | Unchanged | Last list, stale |
| `^!discover` | `ready` if the credential resolves | Models from the file |

So `ready` means the credential resolves and has not been rejected. It does not prove
access to a given model; only a completed turn does.

A provider whose model list is public needs a separate check, or a 200 proves nothing about
the key. [OpenRouter](#openrouter) is one.

## Discovering logins

| Provider | Detect | Model list | Effort data | Checked |
| --- | --- | --- | --- | --- |
| `codex` | `codex login status`, plus `auth.json` as today | `codex debug models` | `supported_reasoning_levels`, `default_reasoning_level` | Ran here: 10 models |
| `claude` | `claude auth status` JSON: `loggedIn`, `authMethod`, `subscriptionType` | No list command in `--help`; built-in aliases and typed ids | `--effort` low to max | Ran here |
| `anthropic`, API key | `ANTHROPIC_API_KEY` | `GET /v1/models` | `capabilities.effort.*`, `capabilities.thinking.types.*` | Docs only |
| `anthropic`, `ant` login | `ant auth status` | `GET /v1/models` | same | Docs only; `ant` not installed here |
| `openrouter` | API key, checked with `GET /api/v1/key` | `GET /api/v1/models` | `reasoning.supported_efforts`, `default_effort`, `mandatory` | Called here without a key: 456 models |
| ChatGPT sign-in (new) | Harness's own credential record | `GET https://api.openai.com/v1/models` | Not documented; must be probed | Docs only |
| Custom endpoint | `^credential` resolves, or none needed | `GET {base_url}/models` if `^^discover` | Assume none: `auto` only | Design only |

`codex debug models` is labeled debugging tooling, and `~/.codex/models_cache.json`
has no stated contract. Treat both as best effort and fall back to the built-in
list. The app-server's `model/list` has the right fields, but OpenAI labels the
app-server command experimental, and starting a server is heavy for one read.

### Anthropic

There are two legitimate OAuth routes, and they mean different things.

| Route | What it is | Billing | Transport |
| --- | --- | --- | --- |
| Claude subscription | The user signs in to the unmodified `claude` binary | Plan | `claude` provider, one process per attempt |
| Console OAuth | `ant auth login`, bound to one org and workspace | API | `anthropic` provider, with a Bearer token and `anthropic-beta: oauth-2025-04-20` |

Hard rules for the subscription route:

- **Never read the `Claude Code-credentials` keychain item or any Claude.ai
  token.** Anthropic's terms say developers "may not collect, store, or
  intermediate Claude.ai credentials or session tokens", and do not permit
  routing requests through Free, Pro or Max credentials on behalf of users. The
  same page does not prevent an end user from signing in to the unmodified binary.
- **There is no "Sign in with Claude" button.** Sign-in must complete through
  Anthropic's flow, so the Connect action shows `claude auth login`.
- **The limits stay visible.** The CLI route accepts text only and refuses prompts
  over 128 KiB. The picker shows this, so the operator can see why the `anthropic`
  route differs.
- **Distribution needs a separate look.** This is sound for one person's local
  Harness, which is the current posture. Shipping Claude Code inside a product
  has its own conditions on the same page. Plan limits also assume ordinary
  individual use, which matters for unattended triggers.

For Console OAuth, `ant auth print-credentials --access-token` refreshes as needed,
so the resolver calls it for both `send` and `GET /v1/models`, rather than reading
`~/.config/anthropic`. That fits `^credential {^command [...]}` with Bearer auth. An exported `ANTHROPIC_API_KEY`
outranks the profile in `ant`, and the connection label must say which one won.

### ChatGPT

Today `provider_codex` reads `~/.codex/auth.json` and posts to
`chatgpt.com/backend-api/codex/responses`. Three things matter:

1. **It breaks with keyring storage.** Codex may keep credentials in the OS store,
   so a signed-in user can have no file. Discovery should say that instead of
   "run codex login".
2. **It never refreshes.** Codex refreshes tokens "during use". If Codex has not
   run recently, the Harness gets a 401 and tells the user to log in again.
3. **It is not the documented route.** OpenAI has a Sign in with ChatGPT flow for
   open-source and local apps. That flow says to call the public Responses
   endpoint and not "ChatGPT's `backend-api` endpoints". The pages I read do not
   say whether reading Codex's file is allowed.

The documented route:

- Open the browser at `auth.openai.com`, with `client_id=dynamic_agent_client` the
  first time and a loopback callback on `127.0.0.1`. Save the issued `client_id`.
- Request the plan scopes `offline_access resource.invoke chatgpt.tokens.use.direct`.
- Store a record per client and account with mode `0600`. The path is ours to
  choose: `~/.config/gene-harness/chatgpt/`.
- Call `POST https://api.openai.com/v1/responses` with `store: false` and
  `stream: true`. Omit `max_output_tokens`, `temperature` and similar fields.
- Serialize refreshes. OpenAI warns about two processes racing a rotating token,
  and each Harness workspace is its own process, so this needs a file lock shared
  across hosts, not an in-process gate.
- Own refresh exchanges in the host rather than an individual probe or round.
  Persist rotated tokens before fallible ID-token checks, with pending credentials
  unavailable for inference until verification succeeds. Cancellation must not
  abandon the exchange, and delayed verification must not extend access expiry.

Two cautions. It is a preview with listed limits, and one OpenAI page describes
access as limited to select partners while the open-source guide describes
self-registration. Try a real sign-in before building on it.

**Recommendation:** ship discovery of the existing Codex login first, because it
needs no new auth code and works today. Then add ChatGPT sign-in as a separate
`chatgpt` provider and prefer it when both are ready. Remove the `backend-api` path
once sign-in has proved itself, since we keep no compatibility paths.

### OpenRouter

`provider_openrouter` already exists, reading `OPENROUTER_API_KEY` or `OPENROUTER_KEY`. There
is no login to discover, so a set key is what makes it a ready connection. Four things bring it
up to the same level as the others.

**Checking the key.** The reference page says the model list needs a bearer token, but
`GET /api/v1/models` returned 200 with no credential when I called it. So the list says nothing
about the key. `GET /api/v1/key` returned 401 with no credential, and its response includes
`limit_remaining`, so it checks the key without inference and can show remaining credits. I have
not called it with a key.

**Filling the catalog.** Each model maps directly. The list had 456 models, 333 with a `reasoning`
object, and its supported efforts vary, including `["high"]` and `["high" "low" "none"]`:

| OpenRouter field | Catalog field |
| --- | --- |
| `id`, `name` | `id`, `label` |
| `context_length` | `window` |
| `top_provider.max_completion_tokens` | `max_output` |
| `architecture.input_modalities` | `input` |
| `reasoning.supported_efforts`, `null` meaning all | `efforts` |
| `reasoning.default_effort` | `default_effort` |
| `reasoning.mandatory: true` | Remove `none` from `efforts` |
| No `reasoning` object | `efforts` is empty, so effort is omitted |

Because `resolve_effort` runs first, OpenRouter's own nearest-level rounding never applies. A
`medium` request becomes `low` on the second list above. On `["high"]` it becomes `high`, the one
case that spends more, and the picker shows it.

**Keeping the menu short.** 456 rows is not a menu. It shows the `^models` entries for `openrouter`
in `models.gene`, plus the current selection, and everything else is reached through search. The
API has no visibility field to do this for us. Showing `pricing` next to each result matters here,
since prices vary widely across this list.

**Rejecting incomplete responses.** `openrouter_text` must check `finish_reason`, and reject
`length`, `error`, a choice with an `error` object, and empty content, the way `anthropic_text`
and `provider_codex` already do. This fix comes first, and is worth doing on its own: the row
defaults to `max_tokens` 3,000, and thinking counts toward the limit on some models, so truncation
is a realistic outcome.

**Connect, later.** OpenRouter documents a PKCE flow with no client registration, allowing a
localhost callback on any port: send the user to `https://openrouter.ai/auth`, then exchange the code
at `POST /api/v1/auth/keys` for a key billed to the user's own credits. Unlike a Claude login, this is
offered to third-party apps. There is no refresh token to rotate, so it needs no cross-host lock. The
key is stored like a ChatGPT record, with mode `0600` under `~/.config/gene-harness/openrouter/`, and
an environment key wins over it. The docs do not say whether the key expires. I have not run this flow.

### Token exposure

Response code runs as the same OS user, and `docs/design.md` is explicit that
there is no authority code. It can read `~/.codex/auth.json` today and would be
able to read a Harness token file too. The rule that credentials stay out of
prompts and transcripts still holds, but the real boundary is the OS sandbox the
README already recommends.

## Choosing the default

Use a single order everywhere: readiness, plugin-plan validation, status and model
requests. It replaces the `session_override` flag and the two orders in
`provider_selection.gene`.

| Order | Source | Set by |
| --- | --- | --- |
| 1 | Profile pin | Internal profiles such as `offline` |
| 2 | Session `model_settings`, or the trigger's fields on a trigger round | Prompt-box picker, `/model`, delegation, `create_trigger` |
| 3 | Workspace `config.gene` | Workspace settings |
| 4 | `models.gene` `^default` | "Set as default" |
| 5 | Environment | Ambient launch environment |
| 6 | Automatic | Below |

The environment moves below saved values everywhere, since a saved choice has to
beat an inherited shell. This breaks direct launches that rely on environment-first
order, such as the `env GENE_HARNESS_PROVIDER=claude` recipe in `docs/claude.md`,
so a one-off launch override becomes a `--provider`/`--model` flag acting as a
pin. The generic environment model and effort still apply only when the chosen
provider matches, as managed hosts do today.

**Automatic selection:**

- With one ready connection, use it.
- With several and an interactive browser, the first prompt shows a one-time
  chooser and saves the answer as `^default`.
- Headless with no default, take the lowest `auto` rank, with ranks reordered so
  plan beats metered: `claude`, `chatgpt`/`codex`, `anthropic`, `openrouter`.
- `claude` gets an `auto` rank and a real connection state, which fixes the
  subscription-only failure.

**No silent fallback.** That existing rule stays. If the default's connection is
signed out, the profile is `not_ready` with the reason, and the picker stays usable
so the operator can choose something else. A model id missing from the catalog is
allowed but marked unverified, because a list does not prove access. OpenAI's
app-server guidance says to treat `model/list` as a catalog, not an entitlement
check, and that a completed turn is what verifies a model.

### One selection per round

Today a running round does not hold a fixed selection. `run_round` reads settings once,
but it selects the provider inside the turn loop, with a new composition lease each turn
(`src/agents/turn_loop.gene:191`, `:274`). An automatic choice can move when readiness
changes, and a catalog and shared default would add more inputs that can change.

So the selection is resolved once, at admission, and stored on the round receipt next to
`effective_limits`. It then survives `^resume`:

```gene
^selection
  {^provider "anthropic" ^model "claude-opus-5-5"
   ^requested_effort "high" ^effective_effort "high"
   ^source "session" ^billing "metered" ^transport "<digest>"
   ^window 1000000 ^max_output 128000 ^input ["text" "image"]}
```

Admission readiness (`src/runtime/round_controller.gene:434`), every turn's call,
compaction, the context window and image checks all use this one value. That also means
readiness is checked for what the round will really run.

| Input | During a round |
| --- | --- |
| Provider, model, requested and effective effort | Fixed |
| Window, output limit, input types | Fixed |
| Picker, default, workspace config, environment, auto rank | Next round |
| Catalog refresh | Next round |
| Provider row code | Next turn, under the same provider name, if the transport identity is unchanged |
| Token value | Live within the same credential source, so a refresh still works |
| Connection state | Live: if signed out, the turn fails readiness, with no fallback |
| Transport identity, which includes billing class | Fixed: a change stops the round |

**Transport identity** is what separates replacing code from changing the connection. A
provider name is not enough: if `work_proxy` changes its `base_url`, the next call would
go to a different service with the old model metadata and readiness assumptions, and both
endpoints can be `metered`, so billing alone misses it.

The identity is a non-secret digest over the provider name, adapter, `base_url`, credential
source, billing class, and the account where a connection reports one. The credential source
means its kind plus the environment variable name or command, never the value it produces.
It is stored as a digest because receipts are durable and a `^command` can name paths or
accounts. File-defined rows compute it from their entry. Built-in rows report it through the
cached `connection`, and a row with no `connection` uses its provider name. So the check on
each turn is a comparison and starts no process.

| Change between turns | Result |
| --- | --- |
| Plugin code reloaded, same connection | Next turn uses the new code |
| Token refreshed from the same source | Continues |
| `base_url`, adapter or credential source edited | Round stops with the reason |
| Login moves to another account | Round stops with the reason |
| Round admitted on `plan` would now be `metered` | Round stops with the reason |

This sees only what discovery sees: a `claude` route's own credential selection can still
change between probes.

**A continuation is a new admission.** It keeps the source round's provider, model and
requested effort, as it keeps `effective_limits` (`src/runtime/round_controller.gene:607`),
and resolves metadata and transport identity again. Copying the whole snapshot would make
it fail the same check immediately. If the identity differs from the source round:

- An automatic continuation does not proceed, or it would quietly undo the stop. It ends
  through the existing `stop_continuation`, including when `resume_continuations` retries it
  after a restart.
- A continuation the operator submits proceeds on the new connection, because the stop
  already told them what changed.

An operator can also submit a continuation with a different model in the picker, since
choosing a stronger model to finish a stuck task is a normal reason to continue.

**A delegated child resolves its own complete selection.** `provider_settings` carries the
provider, the model and the *requested* effort; today it copies the parent's effective effort
(`src/runtime/delegations.gene:157`). The child's admission then uses the same resolver as any
round, so `window`, `max_output`, `input` and effective effort all describe the child's model.
Patching only the model id would let a child on a smaller model inherit a larger window, skip
compaction and fail its request, or inherit image support its model lacks.

A `^model` missing from the catalog gets no metadata and never the parent's: the window uses
the same fallback as any unknown model, and image support is unknown. Because children can
start later than the parent's admission, `provider_settings` also carries the parent's
`transport`. A child whose connection no longer matches is refused with the reason, so delegated
work is not sent to a different endpoint.

## The prompt box

Two controls go in `composer_actions` (`src/web/page.gene:160`), on the row with the
hint and Send:

```text
┌────────────────────────────────────────────────────────────────┐
│ Ask a question or describe a task…                             │
│                                                                │
├────────────────────────────────────────────────────────────────┤
│ Shift+Enter for a new line        [Opus 5.5 ▾] [High ▾] [Send] │
└────────────────────────────────────────────────────────────────┘

Model menu                             Effort menu (Opus 5.5)
┌──────────────────────────────────┐   ┌──────────────────────────┐
│ Search models…                   │   │ ○ Auto (Medium)          │
│ Fast · Deep                      │   │ ○ Low                    │
│ ANTHROPIC · API key · metered    │   │ ○ Medium                 │
│ ✓ Claude Opus 5.5        default │   │ ● High                   │
│   Claude Sonnet 5.5              │   │ ○ Extra high             │
│ CLAUDE CODE · Pro plan · text    │   │ ○ Max                    │
│   opus · sonnet · fable          │   ├──────────────────────────┤
│ CHATGPT · Codex login · plan     │   │ Set as default           │
│   GPT-6.1-Sol                    │   └──────────────────────────┘
│   GPT-6-Astra                    │
│ OPENROUTER — no key    Connect…  │
│ Use a model id…                  │
│ Set as default · Manage models…  │
└──────────────────────────────────┘
```

- **The buttons always show the real state.** A session without its own choice shows
  a muted `Default · Opus 5.5`. A resolved effort shows `High → Medium`, with a
  tooltip giving the reason.
- **The menus show only what can run.** Efforts come from the selected model.
  Signed-out connections appear with a Connect action, not as selectable models.
- **Billing is visible** because plan versus metered is the choice the operator
  most needs to see.
- **Slash commands match.** `/model [name]` and `/effort [level]` use the existing
  command descriptors, so the Harness CLI gets them too; `send` also gains
  `--model` and `--effort`. Slack needs a separate look.

**Scope:** a choice sticks to the session from the next round. It is sent with the
submit (`src/web/server.gene:271`) and saved under the session gate at admission,
then the backend uses the session's current selection to resolve the round. There
is no preview-revision check: another tab or a shared-default edit can change what
is current before admission, and the backend uses that current value. A running round keeps its selection through
the [round snapshot](#one-selection-per-round). New sessions follow the current
default until the operator picks something. Delegated children [resolve their own
selection](#one-selection-per-round) from the parent's, and `^model` stays limited to the
parent's provider, as `docs/sub-agent.md` says.

**Switching mid-conversation** works, because history is the Harness's own text and
thinking blocks are already dropped. There are three costs. Provider prompt caches
are per model, and at least on Anthropic a top-level effort change also invalidates
the message cache, so the next turn may cost more. A smaller window can trigger
compaction, run by the new model. A model without image input hits the existing
image checks. Show the cost in the menu, and do not block the switch.

**Protocol changes:**

- Status `model` adds `requested_effort`, `effective_effort` and `source`. While a
  round runs it reports that round's snapshot; otherwise it reports what the next
  operator round would use. The session's stored value alone is not enough, because
  a trigger round does not use it.
- Status adds `catalog_revision`, and the client fetches the catalog separately.
  OpenRouter's list alone is 456 models and about 810 KB, so it must not go in every
  status frame.
- `model_info` is recomputed when the default changes.
- The web protocol version goes up.

**Plugin shape:** add a `composer_actions` slot and implement the picker as a built-in
plugin. The `composer` slot sits above the form, so it is the wrong place. The
catalog service, commands, Models page and picker all belong to that plugin, which
keeps the layer test true:

| Layer | Owns | Without the rest |
| --- | --- | --- |
| Recovery kernel | Nothing here | `doctor` never reads `models.gene` |
| Loop | Selection order, `resolve_effort`, round snapshot | Works with no catalog: typed model, `auto` omitted from the wire, no model metadata in the snapshot |
| Contributions | Provider rows, adapters, catalog, picker | Removing the plugin loses the picker, not the ability to run turns |

### Models page

The picker's "Manage models…" opens a full page with connections (state, account
label, billing, Refresh, Connect), models per connection with a hide toggle, the
default, and an "add endpoint" form. The form writes `models.gene`, which remains
the source of truth and stays hand-editable.

### Saving the shared file

`update_workspace_settings` is the wrong model for this file. Its digest check runs under an
in-process gate and assumes workspace ownership, while separate workspace hosts share
`models.gene`. Two hosts can read the same digest, both pass the check, and one silently
discards the other's edit, even though each write is atomic.

Every writer (Models page, "Set as default", first-run chooser) goes through one function,
which holds a file lock around the whole read, digest check and write:

- **The lock file is `<manager root>/.gene-harness/models.lock`.** It cannot be
  `acquire_workspace_lock`, because the manager host holds that lock for its whole life.
  `$fs/try_lock` and the wait loop in `src/runtime/workspace_lock.gene` are the right
  primitives; extract that loop instead of copying it. The cross-host token refresh lock in
  [ChatGPT](#chatgpt) can use it too.
- **A lock, not a single writer process**, because direct launches run with no manager.
- **A stale revision returns `revision_conflict`**, and the page reloads for review. Waiting
  is bounded, and timing out returns a retryable error.
- **Readers take no lock.** The atomic write means they see either the old file or the new one.
- **A hand edit cannot take the lock.** The check under the lock catches any edit saved before
  it runs. An editor saving in the moment between that check and the rename can still lose, and
  that window is accepted as the cost of keeping the file hand-editable.

## Triggers

A trigger can choose its model and effort when it is created, in the browser form
or through `create_trigger`. It uses the same field name as a session:

```gene
(create_trigger
  {^id "nightly-audit" ^kind "cron" ^cron "0 3 * * *"
   ^timezone "Europe/Berlin" ^request "Audit the project."
   ^model_settings {^provider "anthropic" ^model "claude-haiku-5-5" ^effort "low"}})
```

| `^model_settings` | Meaning |
| --- | --- |
| Absent | Follow the default each time it fires. This is today's behavior. |
| `{^effort "low"}` | Follow the default model, at this effort |
| `{^provider ^model}`, optional `^effort` | Pin this model |
| `{^model}` without `^provider` | Rejected, because a model name means nothing alone |

**An unset trigger stays unset.** It does not inherit the creating session's choice,
even when the model creates it. A schedule outlives the conversation, and an
interactive `max` on the most expensive model should not quietly become a nightly
job. The browser form starts on "Default", and the model pins only when asked to.

**A trigger's selection belongs to its rounds, not to a session.** `start_due` passes the
definition's fields to `submit_round`, and admission resolves them into the
[round snapshot](#one-selection-per-round): the profile pin, then the trigger's fields,
then the current default order. The session's stored `model_settings` is skipped, and
the trigger never writes it.

This matters with `continue_session`, where one session lives across firings. If the
session's value counted, someone choosing an expensive model while reading that session
would change the schedule, and clearing a pin would not restore the default. Under this
rule both behave as the table above says. A browser choice in that session applies only
to rounds the operator submits there. A delegated child still resolves its selection from the
parent's through `provider_settings`.

**Create-time checks:**

| Case | Result |
| --- | --- |
| Unknown provider | Rejected |
| Provider signed out | Accepted with a warning; the login may be back by the time it fires |
| Model not in the catalog | Accepted with a warning, as in the picker |
| Effort above what the model supports | Stored as requested and resolved at each firing, with the result shown |
| Unknown top-level field | Rejected |

The last row fixes a trap. `validate_definition` copies its input and checks no
field names, so `^model "x"` is accepted and silently ignored today. A model
guessing at the signature would believe it had pinned a model. Returned warnings
matter for the same reason, since `docs/triggers.md` tells callers to verify the
returned definition.

**The model needs a way to see the options.** Add a discoverable `list_models`
function returning provider, id, label, efforts and billing for ready connections.
It reaches the model only through `discover`, so the stable prompt prefix is
unchanged.

### One signed-out trigger must not stop the others

This is the one existing behavior that has to change first. A readiness refusal
escapes `start_due` and ends the whole tick. It was harmless while every trigger
shared one provider, because they would all have failed anyway.

I confirmed it with a probe against the current code. Two heartbeats were due in the
same tick, and the first one's session named a missing provider:

```text
tick 1 raised:  web cannot run: providers/missing is missing
   a_signed_out   due
   b_healthy   due
tick 2 raised:  web cannot run: providers/missing is missing
   a_signed_out   due
   b_healthy   due
model calls:  0
```

The healthy trigger never runs, and neither do the steps after `start_due` in that
tick: pruning, retention and idle unloading. The error goes only to host stdout
(`poll_triggers`, `src/runtime/triggers.gene:382`), so from the browser the schedule
just looks idle.

The fix:

- Catch `not_ready` per occurrence in `start_due`, leave that occurrence `due`, as
  the existing readiness spec requires, and continue with the next one.
- Show the reason on the trigger's row, such as `Waiting: Claude Code signed out`,
  and raise one notification when a trigger becomes blocked. There is no session
  yet to mark for attention.
- Never fall back to another model. A nightly job that moved to a metered provider
  overnight is the worst version of a silent fallback.

Add a regression spec with the same two-trigger shape. The test provider fixture pins
the profile, and a pin outranks the session's choice, so the spec must clear that pin
or the "signed-out" trigger runs normally. My first probe failed that way.

### Changing a trigger later

Triggers have only create and delete today. From the code, a delete keeps a tombstone
in `definitions` and `create_trigger` refuses any id it finds there, so a deleted id
cannot be reused. Models get retired and logins change, so this design needs an edit
path. Add `update_trigger` that accepts only `^model_settings` for now, where removing the
field returns the trigger to the default. The next occurrence uses the new value,
including one already due, and a started round keeps its snapshot. Plugin-declared triggers (`sync_plugin_triggers`) take the same field,
and a change to it must count as a definition change.

### Browser form

The Create trigger form (`src/web/page.gene:197`) gets the same two menus and the same
catalog as the prompt box, placed after Request:

```text
Request   [ Audit the project.                              ]
Model     [ Default (Claude Opus 5.5)                     ▾ ]
Effort    [ Auto (Medium)                                 ▾ ]
          Runs unattended on your Pro plan
```

- The trigger list shows the selection on each row (`Haiku 5.5 · Low`, or `Default`)
  with a menu that calls `update_trigger`.
- Presets appear in the model menu. `fast` suits a frequent heartbeat, and it writes a
  normal selection like everywhere else.
- A billing line appears for the selected connection. It informs and does not block.
- `xhigh` or `max` shows a hint when the round limit may be too short. Trigger rounds
  default to `trigger_timeout_ms` 300,000, which is half of one provider attempt's
  600,000 timeout. Add a per-trigger limit only if real runs need it.
- A `continue_session` trigger on the `claude` provider eventually hits that route's
  128 KiB prompt limit, so the form says so.

## Effort

### What providers really offer

| Provider | Control | Levels | Default | Turning thinking off |
| --- | --- | --- | --- | --- |
| Anthropic Messages | `output_config.effort` with `thinking` | `low medium high xhigh max`, per model | `medium` on Opus 5.5, Haiku 5.5; `high` on others | 400 on Opus 5.5 and Fable 5/5.1; `between_tools` on Sonnet 5.5; `disabled` on Sonnet 5 and Opus 4.7/4.8, and at `high` or below on Opus 5 and Haiku 5.5 |
| Claude Code CLI | `--effort` | `low medium high xhigh max` | CLI's choice | `alwaysThinkingEnabled: false`, as today |
| Codex catalog | `reasoning.effort` | `low medium high xhigh max`, `ultra` on some | Per model, `low` or `medium` | None listed |
| OpenAI Chat Completions | Top-level `reasoning_effort` | `none minimal low medium high xhigh max` | `medium` | `none` |
| OpenRouter | Nested `reasoning.effort` | `none minimal low medium high xhigh max`, per model through `supported_efforts` | Model's | `none`, unless `mandatory` |
| Local compatible server | Often none | Unknown | Unknown | Unknown |

Three conclusions:

1. **The words have converged.** `low` through `max` means the same order everywhere,
   so a new vocabulary would only add a translation layer.
2. **The meaning has not.** Levels are not comparable between vendors or even between
   one vendor's models. Anthropic recalibrated Sonnet 5.5's levels and says lower
   effort on Fable can beat `xhigh` on older models. Codex defaults its newest
   models to `low`. "High" on two models is not the same cost or depth.
3. **Not every level is about depth.** `ultra` is described as "maximum reasoning
   with automatic task delegation", which is a behavior change.

### The definition

```text
auto | none < minimal < low < medium < high < xhigh < max | native extras
```

- **`auto`** is the default: use the catalog's `default_effort` and record which
  level that was. With no known default, omit the parameter and let the provider
  decide. It is not a per-prompt router.
- **The ladder** is the portable part. Settings and presets use these words.
- **Native extras** such as `ultra` are model-specific. They can be selected only on
  a model that lists them and are never reached by rounding.
- **A catalog row says what is supported**, including extras, in `^efforts`. Absent
  means unknown, and an empty list means the model has no effort control.

Keep `none` rather than renaming it. It is the word OpenAI-style APIs already use.

### Resolving a request

The operator's request is stored, and the effective level is derived. Changing to
another model and back restores the original request. The rule never spends more
than was asked, unless the model has nothing lower.

1. `auto` or unset: the model's `default_effort`.
2. Efforts unknown: pass the request through, and the provider decides.
3. Listed: use it. This is how `ultra` works.
4. Not on the ladder: fail with a clear error.
5. Otherwise: the nearest supported level below, else the lowest supported, else omit.

```gene
(const effort_ladder ["none" "minimal" "low" "medium" "high" "xhigh" "max"])

(fn resolve_effort [requested, model]
  (if (|| ($absent? requested) (== requested "auto"))
    (return model/default_effort))
  (if ($absent? model/efforts) (return requested))
  (if (model/efforts .contains? requested) (return requested))
  (if_not (effort_ladder .contains? requested)
    (fail $"${requested} is not an effort level for this model"))
  (var below nil)
  (var lowest nil)
  (var passed false)
  (for level in effort_ladder
    (if (== level requested) (set passed true))
    (if (model/efforts .contains? level)
      (do
        (if ($absent? lowest) (set lowest level))
        (if_not passed (set below level)))))
  (?? below lowest))
```

I ran this prototype with `bin/gene`. The rows use the same `^efforts` lists as the
catalog:

| Request | Model | Result |
| --- | --- | --- |
| `auto` | Codex, default `low` | `low` |
| unset | Opus 5.5, default `medium` | `medium` |
| `minimal` | Codex | `low` |
| `none` | Opus 5.5 | `low` |
| `xhigh` | Opus 4.6 | `high` |
| `ultra` | Codex, listed | `ultra` |
| `ultra` | Opus 5.5 | error |
| `high` | Unknown model | `high`, passed through |
| `high` | Model with no effort control | nil, omitted |

OpenRouter rounds to the nearest level instead of down. Ours differs on purpose:
the operator should not be surprised by a larger bill. The picker reports the change
either way, and a resolved level is an adjustment, not an error, so switching models
does not start failing.

### Mapping to the wire

The effective level goes to the adapter in `prepare`, and the mapping stays there.
The `model/request` record shows the native parameter as it does now. It should also
record `requested_effort`, so a transcript explains any adjustment.

| Effective | `anthropic_messages` | `claude` | `openai_responses` | `openai_chat` | `openrouter_chat` |
| --- | --- | --- | --- | --- | --- |
| omitted | No `output_config.effort` | No `--effort` | No `reasoning` | No `reasoning_effort` | No `reasoning` |
| `none` | Per-model form from the table above | `alwaysThinkingEnabled: false` | `reasoning.effort: none` | `reasoning_effort: none` | `reasoning.effort: none` |
| `minimal` … `max` | `thinking: adaptive` + `output_config.effort` | `--effort` | `reasoning.effort` | `reasoning_effort` | `reasoning.effort` |
| extra | Not applicable today | Not applicable | `reasoning.effort` | `reasoning_effort` | `reasoning.effort` |

The two chat columns are why extracting `provider_openrouter` unchanged would be wrong.
OpenAI's Chat Completions takes a top-level `reasoning_effort`, and OpenRouter documents a
nested `reasoning` object, so a compatible server could reject or ignore the wrong one.
`openrouter` is an `openrouter_chat` row, and `^adapter "openai_chat"` means the standard
field. A custom server with unknown efforts sends neither, as the definition above says.
`prepare` returns plain data, so a table test can check each adapter's payload with no
network.

Anthropic's Models API exposes effort levels directly, but the documented thinking
capabilities list `enabled` and `adaptive`, not `disabled`. So the `anthropic` plugin
keeps a small table of the models where `none` is offered, and an unknown model does
not offer it.

Effort also has to change the output budget and may need a longer timeout:

| Setting | Today | Proposal |
| --- | --- | --- |
| Output budget | Fixed 8,192 (`anthropic`), 3,000 (`openrouter`) | The adapter derives it from effective effort and the catalog's `max_output` |
| `anthropic` transport | Non-streaming | Stream and buffer, as `provider_codex` does, because large budgets need it |
| OpenRouter budget models | Thinking budget is a ratio of `max_tokens`, so 3,000 starves it | Same adapter rule |
| `openai_chat` budget field | Not applicable | OpenAI deprecates `max_tokens` for `max_completion_tokens`, which also counts reasoning. Compatible servers vary, so this field is per adapter too, and needs a live check |
| Timeout | 600 s for every level | Keep the setting. If real runs exceed it at `xhigh`/`max`, add a per-level multiplier |
| ChatGPT sign-in | Not applicable | Send no budget; OpenAI's limits page says to omit `max_output_tokens` |

The exact budget per level needs measuring, so it is not specified here.

### Presets, not tiers

The honest answer to "fast" or "deep" across vendors is to pick the model and the
effort together, and a level alone cannot do that. `^presets` in `models.gene` are
named selections that appear at the top of the picker, and `/model fast` works too.
They are shortcuts that write a normal selection, with no separate resolution path.

## Rejected

| Idea | Why not |
| --- | --- |
| Reading Claude Code's token and calling the Messages API | Anthropic's terms forbid it, and the cost saving does not change that |
| Abstract tiers such as fast, balanced, deep as the effort model | A per-model table to maintain forever, hides what is sent, and vendors already share the words. Presets give the benefit honestly. |
| Numeric effort or token budgets | Fixed thinking budgets are rejected on current Claude models |
| Rounding up, or rounding to the nearest level | Spends more than the operator asked for without being asked |
| `ultra` as the top rung | It changes behavior and is not portable. Delegation also belongs to the Harness. |
| Falling back to another provider on failure | Conflicts with the no-silent-fallback rule and hides a billing change |
| A hardcoded master model table | Stale at once. Discovery plus small built-in lists avoids it. |
| Secrets in `models.gene` | The file is meant to be read, edited and copied |
| Moving providers into the kernel so the picker can rely on them | `doctor` must run without plugins |
| Catalog in the instructions so the model can choose | Churns the stable prompt prefix. `list_models` through `discover` does the job. |
| New triggers inheriting the creating session's model | A schedule outlives the conversation, and the cost would be invisible |
| A trigger falling back to a working model when its own is signed out | Hides a billing change on work nobody is watching |

Speed tiers (Codex `priority`, Anthropic `speed: fast`) are a separate setting with
different billing. They should not be folded into effort, and they are out of scope
for now. So are image generators, which have their own registry.

## Order of work

Each step can ship and be used on its own.

1. **Contract and effort.** Add `connection` and `models` to rows, built-in lists,
   `resolve_effort`, `auto` as the default, per-model windows, one precedence order, the
   round snapshot with transport identity, and complete child selections. Fixes the `none`,
   `ultra` and window problems. `docs/sub-agent.md` changes with it, since children no longer
   copy effective effort. The OpenRouter completion check also lands here, or sooner.
2. **Discovery of existing logins.** `codex` and `claude` probes, `resolve_credential`,
   Anthropic and OpenRouter model lists, the OpenRouter key check and short menu, the catalog
   cache, `claude` auto rank. A login is now found without configuration.
3. **Picker and default.** `composer_actions` slot, session selection on submit,
   `/model`, `/effort`, "Set as default", first-run chooser, status changes.
4. **Trigger selection.** First the per-occurrence readiness fix and its spec, which
   is worth doing on its own. Then `^model_settings`, field validation, `update_trigger`,
   `list_models`, the form and row menus, and `docs/triggers.md`.
5. **`models.gene` and adapters.** Custom endpoints, hidden models, presets, the shared
   save lock, Models page.
6. **Budgets.** Stream `anthropic`, derive budgets from effort, with measurements.
7. **First-party sign-in.** OpenRouter Connect, which is the simplest, then ChatGPT sign-in
   with a cross-host refresh lock, then `ant` as a credential source, then retire
   `backend-api`.

Tests stay hermetic: `GENE_HARNESS_ROOT` for the file, fake `claude` and `codex`
executables for probes, and a pure table test for `resolve_effort` using the table
above. Live probes stay behind an explicit flag, because they spend money. One live
check per adapter is still needed for the "Not exercised live" items.

Specs these rules need:

- **Round snapshot:** a multi-turn round with a default change and a catalog refresh
  between calls. Both wait for the next round, while a row replacement applies on the next
  turn.
- **Billing change:** a connection moving from `plan` to `metered` mid-round stops the round.
- **Transport change:** two fake transports, with an endpoint edit between turns. The round
  stops and the second transport is never called. A code reload and a token refresh on the
  same connection both continue. An automatic continuation stops, and an operator's proceeds.
- **Delegated child:** a parent and child with different context limits and input types. The
  child uses its own window and image support, and an unknown `^model` inherits neither.
- **Shared file:** two processes saving from the same revision. Exactly one succeeds, the other
  gets `revision_conflict`, and neither edit is silently lost.
- **Trigger selection:** a browser choice in a `continue_session` session between firings
  does not change the trigger's model, and clearing a pin returns it to the default.
- **Adapters:** a prepared-payload table covering each adapter's effort and budget fields.
- **OpenRouter responses:** `length`, `error`, an `error` object and empty content are all
  rejected. The current spec only covers a complete response.
- **OpenRouter catalog:** the field table above, including `supported_efforts: null`,
  `mandatory` and a model with no `reasoning`, from a recorded fixture.
- **Discovery:** each row of the probe table, with a check that no credential reaches
  the catalog cache or a prepared request.

## Open questions

These need an owner decision. Each has my recommendation.

1. **ChatGPT route.** Keep reading Codex's file, or move to OpenAI's sign-in?
   Recommendation: both for now, then sign-in only, subject to a real sign-in working.
2. **Environment order.** Should saved values beat the environment for direct launches
   too? Recommendation: yes, with a launch flag for one-off overrides. It changes the
   current `docs/claude.md` recipe.
3. **Subscription-backed triggers.** Should a trigger be allowed to follow a default
   that resolves to a `claude` plan? Recommendation: yes, with the billing line in the
   form, because plan limits assume ordinary individual use. An operator who wants
   otherwise can now pin that trigger to another model.

## Sources

Vendor pages, checked 2026-10-30:

- [Claude Code legal and compliance: authentication and credential use](https://code.claude.com/docs/en/legal-and-compliance)
- [OpenAI: Sign in with ChatGPT for open-source apps](https://developers.openai.com/siwc/token-sharing-open-source),
  with [sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
  [accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions),
  [models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
  [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations),
  [app-server use](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)
  and [client ID requests](https://developers.openai.com/siwc/request-client-id)
- [Codex authentication](https://learn.chatgpt.com/docs/auth) and
  [Codex app-server](https://learn.chatgpt.com/docs/app-server)
- [OpenRouter reasoning tokens](https://openrouter.ai/docs/use-cases/reasoning-tokens)
  and [its best-practices guide](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)
- [OpenAI Chat Completions reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
- OpenRouter [models list](https://openrouter.ai/docs/api/api-reference/models/get-models),
  [OAuth PKCE](https://openrouter.ai/docs/guides/overview/auth/oauth) and
  [key limits](https://openrouter.ai/docs/api/reference/limits)
- Anthropic thinking, effort, Models API and `ant` facts come from the Claude API
  reference bundled with Claude Code 2.1.314, whose model table is dated 2026-10-06.
  Re-check them against [the API docs](https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking)
  when implementing.

Local checks on this machine: Codex CLI 0.165.0 (`codex login status`,
`codex debug models`, `~/.codex/models_cache.json`) and Claude Code 2.1.314
(`claude auth status`, `claude --help`). Only credential metadata was read, not
token values. OpenRouter's `/models` and `/key` were called without a credential.

## Review comments (2026-10-30)

1. **Resolve trigger choices independently of a continuing session's pin.** The
   trigger table says an absent selection follows the default on every firing,
   but the firing section says it leaves an existing session's selection alone.
   These produce different behavior after someone chooses an expensive model in
   the browser, or after `update_trigger` removes a previous pin. The old model
   would keep running unattended. Today's
   [session_settings](../src/agents/provider_selection.gene) honors that stored
   session override, so passing nothing does not restore the default. Prefer a
   round-scoped trigger selection, resolved from the current default plus the
   trigger's fields, rather than changing persistent session settings. Cover both
   a browser choice between firings and clearing a trigger pin in regression specs.

   Resolution: accepted. A trigger's fields now resolve into the round snapshot, skipping
   the session's stored value, and the trigger never writes it. See
   [Triggers](#triggers). Both specs are listed under [Order of work](#order-of-work).

2. **Make the round's resolved selection an explicit snapshot.** Reading settings
   once does not yet guarantee the promise that a running round keeps its
   selection. [run_round](../src/agents/turn_loop.gene) selects the provider inside
   the turn loop and acquires a new composition lease for each turn. An automatic
   provider choice can therefore change as readiness changes, and the proposed
   catalog and default introduce more mutable inputs. Resolve provider, model and
   requested/effective effort at admission, and retain the model metadata used for
   context and capability checks with that round. Define how this interacts with
   the earlier rule that file edits apply between turns. A multi-turn spec with a
   catalog/default refresh between calls should prove which changes wait for the
   next round, including a change that would move from plan to metered billing.

   Resolution: accepted; the earlier claim was wrong (`turn_loop.gene:191`, `:274`). See
   [One selection per round](#one-selection-per-round). Row code and credentials stay live
   between turns, and identity and model metadata stay fixed. A billing change stops the
   round rather than waiting, because the next call would already be billed differently.

3. **The generic Chat Completions adapter needs a different effort mapping from
   OpenRouter.** The wire table sends `reasoning.effort` for `openai_chat`, matching
   the current OpenRouter provider. Standard
   [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
   uses the top-level `reasoning_effort` field;
   [OpenRouter](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)
   documents the nested `reasoning` object. Extracting the current provider
   unchanged would make some compatible endpoints reject or ignore the selected
   effort. Share message construction and HTTP handling, but preserve the
   provider-specific parameter mapping and verify each adapter's prepared payload.

   Resolution: accepted, and checked against both vendor pages. OpenRouter becomes
   `openrouter_chat`, and `openai_chat` uses `reasoning_effort`. See
   [Mapping to the wire](#mapping-to-the-wire). The same page also deprecates `max_tokens`,
   so the output-budget field is per adapter too.

4. **Allow credential resolution for authenticated discovery too.** The file rules
   restrict command credential reads to `send`, while discovery requires
   authenticated `GET /models` calls, including for the proposed `ant` route and
   custom endpoints. Those probes cannot work under the stated contract. Define a
   shared credential resolver used only by transport operations, including
   discovery, and keep its output out of prepared requests, transcripts and the
   catalog cache. Probe failures should leave the last model list usable without
   requiring a paid inference call just to establish the connection.

   Resolution: accepted. See [Reading credentials](#reading-credentials), including a table
   of what each probe result does to the connection and the model list.

### Second review (2026-10-30)

The revisions address the first four comments. Three substantive gaps remain:

5. **Serialize writes to the shared configuration across hosts.** The Models page
   proposes reusing the digest check in
   [update_workspace_settings](../src/runtime/workspace_settings.gene), but that
   function has only an in-process gate and assumes workspace ownership. Different
   workspace hosts share `models.gene` without sharing that gate or workspace lock.
   Two hosts can read the same digest, both pass the check, and overwrite each
   other's changes despite atomic writes. Use a separate manager-root file lock
   around the complete read/check/write transaction, or route saves through one
   writer. Add a two-process conflict spec; the same revision must not allow both
   saves to succeed and silently discard one edit.

   Resolution: accepted. See [Saving the shared file](#saving-the-shared-file). It uses a
   dedicated lock file, because the manager host holds the workspace lock for its whole life
   and direct launches have no single writer to route through. A hand edit in the moment before
   the rename is an accepted remaining window.

6. **Bind the round to a transport identity, not just a provider name.** The new
   snapshot still permits a `models.gene` provider-row edit on the next turn. If
   `work_proxy` changes its `base_url`, adapter or credential source, the next call
   uses a different connection while retaining the old model metadata and readiness
   assumptions. Both endpoints can be `metered`, so comparing billing classes does
   not catch this. Keep code replacement possible, but distinguish it from a
   connection change: retain a non-secret transport identity with the snapshot and
   require a new admission when that identity changes. Refreshing a token within
   the same credential source can remain live. Cover an endpoint change between
   turns with two fake transports.

   Resolution: accepted. See [One selection per round](#one-selection-per-round). The snapshot
   now holds a non-secret digest that includes billing class. This also changed the
   continuation rule from comment 2: a continuation re-resolves the connection, and an
   automatic one stops on a change, because copying the snapshot would either fail again or
   undo the stop.

7. **Rebuild all model-dependent metadata when a child overrides the model.** The
   prompt-box section says delegated children copy the parent's snapshot and
   re-resolve effort when `^model` changes. That must also replace `window`,
   `max_output` and `input` with the child's model metadata. Otherwise a child on a
   smaller model can inherit a larger context window, skip needed compaction and
   fail its request; it can also inherit image support the chosen model lacks.
   Resolve a complete child selection on a model override, using the inherited
   effort request, rather than patching only the model id and effective effort.
   Add a parent/child spec with different context limits and input capabilities.

   Resolution: accepted. See [One selection per round](#one-selection-per-round). Children go
   through the normal resolver with the requested effort, and an unknown `^model` gets no
   metadata rather than the parent's. Children also carry the parent's transport identity,
   because they can start after the parent's connection has changed.

### Third review (2026-10-30)

The earlier resolutions still hold. One substantive admission gap remains:

8. **Check that an operator submission still matches the choice shown in the tab.**
   The round snapshot prevents changes after admission, but the prompt-box promise
   that "what the tab displays is what runs" also needs protection before admission.
   A tab can show a plan-backed default, another host can save a metered default,
   and Send can then resolve the new default without the operator seeing it. The
   same race exists when another tab changes the session's selection. Sending only
   `model_settings` does not cover a session following Default, and a
   `catalog_revision` in status does not check the submitted request. Carry the
   previewed selection's identity with operator submissions and compare it with
   the resolved selection at admission, including provider, model,
   requested/effective effort and transport identity. On a mismatch, preserve the
   draft and refresh the choice for review before sending. Keep this expectation
   with pending requests across retries; triggers should continue following their
   documented firing-time resolution. Add a regression spec where another host
   changes the default from plan to metered between preview and submit, and verify
   that neither provider is called until the operator reviews the new choice.

   Resolution: not adopted. The owner chose the simpler behavior: the backend uses
   the current session selection when admitting a send, following the current
   default when the session has no pin. No preview identity or stale-choice
   rejection is required. A submitted picker change is saved under the session
   gate before resolution, and the admitted round still keeps its snapshot.
