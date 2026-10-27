# Harness plugins

The profile lists trusted built-in plugin defaults. Stored plugins are
content-addressed modules in the workspace. Both use the same contribution
registries, snapshot leases, activation, retirement and error reporting.
`doctor` opens the workspace without activation if a plugin prevents normal
startup.

## Register from a session

Use `register_plugin` with one quoted `(mod plugin ...)` form or attachment
text. The module must define `init` returning a `Plugin`. Its top level is
inert; `init` is preflighted under a bounded budget. Allowed top-level forms are
import, import_impl, fn, type, impl, protocol, alias and enum. Top-level `const`
is currently rejected, even for literal lists; use a zero-argument function.
Generated imports are
limited to `src/plugin_api.gene` and the supplied content-addressed
dependency closure.

```gene
(append_prompt "plugin"
  (register_plugin "line_counter" (attachment "plugin")))
(Outcome ^prompt "Read the publication result, then test count_lines.")
```

The call returns a digest and `queued`. After response evaluation, the
Harness commits the desired composition generation, activates the candidate,
and sends `[N.plugins]` with one short line per plugin: id, revision, state
(`active`, `pending` or `quarantined`), digest prefix and any activation error.
A turn that queued a plugin change cannot finish with `Outcome ^done`; its
reply is progress and the next turn receives this
result. Cancellation discards uncommitted queued changes. Once committed,
the plugin belongs to the workspace: another session can use it, and startup
loads it from the stored source after restart. Plugin state written through
`PluginHost:update_state` is durable; ordinary in-memory variables are not.

The host records the calling session and optional model turn with saved plugin
source. Creation is established when registration is committed, preserved across
replacements, and shown with the current source session in the plugin manager.
Authors do not need to embed session IDs in their modules. Direct scripts and
manager edits without a conversation do not acquire a fabricated `default`
session. See [development sessions](plugin-source.md).

Use `PluginHost:notify` for operator-facing milestones. The host stamps the
publisher, scopes keys by source, and stores messages outside ordinary plugin
state so notifications do not invalidate unrelated panels. The protocol also
provides `notifications`, `notification_update` and `notification_clear` for
source-owned records. Publishing returns an explicit `ok` result; report a
notification failure separately from a successful business save. Keep policy
in the plugin's owned usage chapter and use a real decision workflow for
questions. See [publishing notifications](recipes/notification-publishing.md).

When the UI experiment is enabled, successfully published plugins that own
stateful views also receive `[N.ui]` outlines or render errors. These previews
run without a browser. Read the publication feedback before finishing, then
exercise the action functions and verify the browser interactions as needed.

## Contributions

### Package a helper module

Each dependency is one quoted `mod` form, just like the root plugin; it may use
its own module name and does not need `init`. Hash the canonical `$to_str` of
the exact dependency node passed to `register_plugin`. Its import path is
`./<64-character SHA-256 hex>.gene`. Hashing the original source file's bytes
does not produce that path, because the reader expands source shorthand.
Harness normalizes reader location metadata in newly stored module sources.
For compatibility it also retains an exact-node dependency spelling when a
supplied module explicitly imports that digest. Other metadata and frozen
data literals are preserved.

```gene
(let dependency
  (quote (mod numbers
    (fn double [value] (* value 2)))))
(let import_path ($to_str "./" ($crypto/sha256 ($to_str dependency)) ".gene"))
(let plugin
  `(mod plugin
    (import ^from "src/plugin_api.gene" [Plugin PluginHost])
    (import ^from %import_path [double])
    (fn init [descriptor]
      (Plugin ^id "double_numbers"
        ^activate (fn [host]
          (host .PluginHost:contribute "functions"
            {^name "double_number" ^doc "Double a number." ^fn double}))))))
(register_plugin "double_numbers" plugin ^dependencies [dependency])
```

For source already written as one module, use
`($read_one ($fs/read_text "numbers.gene"))` to obtain the dependency node.
An ordinary file with `(mod numbers)` followed by separate declarations must
first be packaged into one `mod` node containing those declarations. Supply
the full dependency closure; imports between helpers use the same digest-path
rule. Source imports remain restricted to the shared API and supplied closure.
Persist human-editable source and publication tooling alongside the app so a
new digest can be derived and imported after each edit.

### Registry rows

Activation receives a `PluginHost`. Each row it contributes is owned by that
plugin and is removed when the activation unloads. Common rows are:

| Registry | Row |
| --- | --- |
| `functions` | `{^name ^doc ^fn}`; response code, `/run` and the REPL bind it by name |
| `commands` | `{^name ^usage ^doc ^run}`; an operator slash command |
| `input_modes` | `{^name ^label ^hint ^submit_label ^prompt ^classify ^run ^close}`; a transient operator input mode |
| `prompt` | `{^name ^text}` or `{^name ^render}`; an instruction section |
| `docs` | `{^name ^summary ^tags ^text}` or `{^name ^summary ^tags ^path}`; body read with `(doc name)` |
| `providers` | `{^name ^doc ^available ^configure ^prepare ^send}`; a text model adapter, optionally declaring `capabilities` and `media_recording` |
| `image_generators` | `{^name ^doc ^available ^configure ^capabilities ^prepare ^send}`; a separately selected image adapter returning exactly one PNG |
| `speech_recognizers`, `speech_synthesizers` | Owned speech engines with availability, open/close and recognition/synthesis callbacks; see [Voice](audio.md) |
| `hooks` | `{^point ^name ^run}`; an ordered listener at a published shaping point |
| `triggers` | A definition that starts workspace work without a user |
| `web_components` | `{^name ^slot ^view}` or `{^name ^slot ^render}`; quoted UI, with `view_state` and `actions` for experimental panel forms |
| `browser_clients` | Owned browser asset and optional stylesheet mounted through the host bridge |
| `ui_actions`, `ui_links` | Named supervised functions used by workspace views and navigation |

The host also maintains `seams`, `event_types`, `subscriptions`, `interactions`
and the legacy `views` registry. Hook points are declared in `hook_points`.
Additive PluginHost messages preserve
`PluginHost:2`; removing or changing a contract requires an explicit version
and compatibility policy. A stored-entry mismatch names the differing interface.

### Host services and activation cleanup

Resolve `notifications/host` to use the public `NotificationHost` protocol.
`post message` and `update id changes` write as `"operator"`; `list` returns
the whole inbox and its opened watermark; `detail id` reads any retained
message; `clear id revision` clears only the observed revision, across sources.
The returned collections are immutable. Keyed updates preserve the original
source, identity, origin and frozen actions unless explicitly changed, with
the same host validation as the built-in. An older clear never hides a newer
revision. This facade does not change PluginHost's source-owned `notify`,
`notifications`, `notification_update` and `notification_clear` messages.

Use `(host .PluginHost:defer (fn [] ...))` to register activation cleanup.
It returns nil; Cordis invokes the callback under the activation's cleanup
policy after the final reader releases the retired generation, including
failed-activation unwind. Register cleanup as soon as a resource is acquired.
Shell and REPL keep explicit accounting for sessions shared by overlapping
generations; `defer` does not supply a shared-resource lifetime policy.

Provider adapters can raise the public `ProviderError` from `plugin_api`.
Transport and content helpers remain separate modules.

The [built-in import check](../tests/unit/builtin/import_policy_spec.gene)
allows `plugin_api`, declared shared helpers and public Gene/genex libraries.
Remaining private imports are named migration exceptions; removing an import
requires removing its exception, and new private imports fail the check.
Stored plugins retain the enforced source-closure boundary described below.

### Define an extension point

`PluginHost:create_registry` accepts a data spec:

```gene
(host .PluginHost:create_registry
  {^name "reviewers" ^^unique ^^ordered ^key "name" ^callbacks ["run"]
   ^schema (fn [row] row)
   ^on_remove (fn [owner_context, row] nil)})
```

The spec may set `unique`, `ordered`, `schema`, `key`, `callbacks`, `reserved`,
`on_remove`, `prepare`, `signature` and `same_owner`. `key` is a field name
(default `"name"`) or a callable returning the logical key. `callbacks` names
fields whose callable values are supervised; the schema decides whether a
field is required and which values are valid. `signature` names a callback
whose original signature is published as row metadata. `reserved` maps logical
keys to their allowed contributor; an empty owner reserves a key for the host.
`same_owner` prevents cross-owner replacement. `prepare owner row` is an
optional owned adapter after schema validation.

Schemas, key functions, adapters and removal callbacks use the registry
owner's captured budget. Each contributed callback uses its contributor's
activation and budget, including when another plugin calls it. The creation
result is immutable identity metadata. Public `rows registry` and
`row registry key` return immutable views selected from the caller's lease;
they expose no mutable registry storage. Retaining a row callback does not
keep a retired activation callable.

A contributor declares `^requires [{^registry "reviewers"}]`. A consumer can
require a selected row with `^requires [["reviewers" "main"]]`. Both may be
installed before the provider: they remain pending until their dependency
exists, return to pending when it disappears, and reactivate when it returns.
Old readers keep their old selection and cleanup until their lease ends.

To define a generic hook point, contribute `{^name "review/finished"}` to
`hook_points`, and require that row before contributing `hooks` rows at that
point. `PluginHost:run_hooks point context` calls those callbacks in registry
order with an immutable context and returns an immutable list of results.
Failure aborts that dispatch. The existing `request/prepare` and
`history/compact` points declare coordinator dispatch and retain their
specialized host contracts; `run_hooks` refuses to call them.

### Make every plugin discoverable

Plugins use progressive discovery themselves. Their functions and other active
contributions appear automatically in `(discover "topic")`; there is no separate
catalog to synchronize. Keep doc descriptions concise. Add optional `summary`,
`tags` (topic strings) and `docs` (chapter names) on contribution rows. A summary
is a string; tags/docs are lists of nonempty strings. Legacy rows remain valid.

Put detailed contracts, examples and workflow instructions in owned docs rows.
Give those chapters a searchable summary/tags and a plugin-specific prefix.
Functions refer to relevant chapters through `docs`. For example, inside
activation:

```gene
(host .PluginHost:contribute "docs"
  {^name "line_counter/usage" ^summary "Counting nonempty lines in workspace files."
   ^tags ["files" "lines"]
   ^text "Call count_lines with a workspace-relative path. It returns the number of nonempty lines and reads without modifying the file."})
(host .PluginHost:contribute "functions"
  {^name "count_lines" ^doc "Count nonempty lines in a file."
   ^tags ["files" "lines"] ^docs ["line_counter/usage"] ^fn count_lines})
```

The starting prompt does not enumerate these signatures/manuals. The model can
discover them and call the functions already bound in its environment. Keep
prompt sections to essential behavioral rules or brief orientation; do not inject
the plugin's full API manual. Prompt sections have deterministic order. Describe
only contributed capabilities so retirement withdraws the guidance with them.
Docs rows have the same ownership and lease semantics as function rows.
See [discovery](discovery.md) for search, pagination and metadata behavior.

The baseline's `working_instructions` plugin supplies the default preferences
for goal comments, progress replies, discovery and verification. Replace it
with `register_plugin ^^replace "working_instructions" ...`, disable it, or
restore it like any other built-in. Its prompt contribution is optional; the
host always supplies the response grammar, runtime constraints, discovery
helper contracts and dynamic workspace/session context.

The baseline's optional `sidebar` plugin owns the conversation sidebar layout.
It can be disabled, replaced and restored in the same way. Its
`conversation_sidebar` component composes named host navigation controls with
ordinary plugin content. The hamburger and Recovery UI remain host-owned.
See [sidebar plugins](sidebar.md).

`prepare` on a provider row returns plain model-visible data
without credentials; `send` adds transport authentication and makes one
attempt. A provider row is inert until selected. Callback limits apply to
generated provider and hook rows just as to other plugin callbacks.

Stored descriptor evaluation has its own limits (normally two seconds and
64 MiB). Live callbacks and their modules inherit the configured host response
budget, just like built-ins; plugin inspection shows descriptor and effective
callback limits separately. `host/.PluginHost:execution_budget` returns an
immutable snapshot of response/callback deadlines, the effective deadline,
remaining time and memory budget. Deadlines use `$os/monotonic_ms` and
cannot be extended by editing task context. Callback timers also cancel
waiting work when its deadline expires.

An image-aware provider can declare `^media_recording "inventory"` when its
prepared data preserves the supplied base64 or data-URL encodings, including
those embedded in JSON strings. The host records reversible media references
in a separate copy; `send` receives the original frozen prepared value.
Undeclared, uncatalogued or unsupported image transformations produce an
explicit omitted-body record with media identities. This changes recording,
not provider transport signatures. Credentials still belong only in `send`.

### Image workflow and generator plugins

The optional baseline `image` plugin contributes `image_generate` and
`image/usage`. Replace the whole workflow with `register_plugin ^^replace
"image" ...`; disabling it removes the function. The separate
`image_openrouter` plugin contributes the `openrouter` image generator.
Neither plugin makes provider calls until selected. See
[image generation](image-generation.md) for public inputs, configuration,
results and retention.

A workflow imports `Plugin`, `PluginHost` and `ImageHost` from the shared
`src/plugin_api.gene`, declares `^requires ["image/runtime"]`, then resolves
that seam during activation. No private host imports are needed.

| `ImageHost` operation | Contract |
| --- | --- |
| `begin request` | Validate and admit one run for the current user round. The request accepts `prompt`, ordered `reference_images`, `max_attempts`, `generator`, `generation_model`, `size`, `background`. Returns the run ID and state; `reused` means return the recorded result without another loop. |
| `generate run instructions` | Reserve storage, invoke the pinned generator once, inspect and durably store one PNG. Returns metadata and media IDs. The prior candidate must have a valid review before refinement. |
| `review run instructions` | Call the pinned main reviewer with original requirements, references, candidate pixels and measured facts. Validates integer `score`, nonempty `comments`, and `revision`. A malformed result can set `repair_allowed`. |
| `review run instructions ^^repair` | Make the one permitted format repair within the same review-phase deadline. Transport failures never get a repair. |
| `finish run reason` | Publish final metadata and media after `target_reached`, `attempt_limit` or `cancelled`. The host validates the stopping condition; failures already return a finished run. |
| `image_input run id` | Return `{^id ^mime ^bytes}` only to the selected generator during its active `send`, and only for that call's references or previous candidate. Workflows never need image bytes. |

These operations require an active model-response scope with an authenticated
round and pinned reviewer. They cannot create image runs from the REPL or an
operator `/run` without that context. The host enforces attempt limits,
deadlines, reservations and durable results, and finalizes unfinished runs
after response cancellation. The workflow supplies prompts and its bounded
generation/review loop. Both roles use the current composition lease, so
publication takes effect on subsequent runs.

Generator callbacks have these shapes:

- `available []` returns nil or a concise reason the adapter is unavailable.
- `configure [input]` receives `model`, `size`, `background`, `max_attempts`,
  `reference_count`, `timeout_ms`, `max_response_bytes`, `max_image_bytes` and
  operator `options`; returns credential-free JSON settings.
- `capabilities [settings]` returns `image_input`, `image_output`, `image_edit`
  as `yes`, `no` or `unknown`. It may declare `max_images`, `max_input_bytes`,
  `image_formats` (MIME names), `output_formats` (`["png"]`) and routing metadata.
  Known `no` fails preflight. Reviewer `providers` can declare the same callback;
  a missing callback means unknown support.
- `prepare [call]` receives `run`, `attempt`, original `prompt`, ordered
  `reference_images`, optional `candidate`, prior `revision`, workflow
  `instructions`, settings and call limits. Return JSON data with media IDs.
- `send [prepared]` expands those IDs through `ImageHost:image_input`, adds
  authentication, and makes one bounded transport attempt. Return
  `{^images [{^mime "image/png" ^bytes data}] ^usage usage}`. Enforce the
  16 MiB response cap; the host also checks one image, valid PNG structure and
  the 10 MiB decoded-file cap. Usage may include numeric cost and token fields.

Store selected routing/capability details in settings or capabilities, never
credentials, base64 data or response bodies. PNG output is mandatory and must
not be transcoded silently. Provider errors should use `ImageError` with a
short `code`, `message`, optional HTTP `status` and numeric `usage` when known,
excluding transport bodies. An optional `diagnostic` opts into retaining a
provider explanation in the run result, model record and console. The adapter
must remove credentials and echoed image bytes first; the host also bounds
the diagnostic and rejects recognizable image payloads. Other provider error
messages remain opaque. Failed generation usage is retained with its call.

### Contribute UI

Use [web components](web-components.md) for slot contributions, stateful views,
forms and registered-function actions. The host validates quoted element data
and renders it through the shared `ui/` layer. Plugins import only the shared
`src/plugin_api.gene` contract and their declared dependencies; the `ui/`
modules are host implementation details.

The [project board](../experiments/ui/README.md) is a complete example. It stores
task data through `PluginHost:update_state`; the browser owns filters,
selection and drafts. It declares `ui/state_lock` as a required seam to make
revision checks and updates atomic across direct calls and UI actions. The
configuration plugin keeps `ui_configure` and `ui_preview` available while
rendering and actions are disabled by default.

### Provide an operator input mode

An operator command enters a mode by returning `CommandResult ^mode "name"`.
Its plugin contributes an `input_modes` row of that name. The display fields
are non-empty strings. `classify` takes input text and returns `input`,
`incomplete`, `ignored` or `leave`; `run` takes the ordinary CommandContext;
`close` takes the session id and a reason. All three callbacks are bounded.
The built-in `repl` plugin provides the persistent Gene REPL through this API.

The host owns mode state, instance ids, serialized input admission, durable
command receipts and cancellation. Input records retain the client input id
for deduplication. A `run` result should use `^!attached` for activity
that belongs only to the operator transcript. Model response code cannot
enter a mode by returning a CommandResult; mode entry is handled only by
operator command completion.

Keep native handles and other transient mode resources in activation memory,
not durable PluginHost state. The host calls `close` before session removal,
when the last browser viewer has been absent for 60 seconds, and when the
entered registry row is withdrawn or replaced. It cancels the running input
first and always clears the mode even if cleanup fails. An operator can leave
through the host control regardless of what `classify` returns. Deactivation
should release any resources left as a backstop.

A mode that owns native processes can set `^reset_on_interrupt true`. After a
cancelled input, or a failed input without an exit status, the host invokes
`close(session, "interrupted")` outside the input's exhausted execution budget.
It keeps the mode instance open; the next input can recreate its resources.
Normal command failures with an exit status preserve state. The shell mode
opts in; the Gene REPL keeps its existing bindings after interruption.

### Shape a request or compaction decision

`request/prepare` receives a context with `items`, session, round, turn and
round budget, plus `continuation_mode` (`manual` or `automatic`) and `task_root`
for an operator task. Preserve context fields when forwarding, for example
with `context .assoc "items" items`, so other hooks retain continuation metadata.
Transient guidance uses `settled: false` and is regenerated when a paused task
continues in a new round. Automatic continuation uses an explanatory advisory
instead of repeatedly asking the model to wrap up at a round boundary.
Its `run` callback takes that context and `next`. Calling
`next` delegates; returning without it decides. The loop writes the result
as `turn/request`, then records the final provider-specific input as
`model/request` immediately before `send`. A hook that fails or times out is
skipped with a `trace` diagnostic. A listener may call `next` once; a second
call is diagnosed and does not rerun later listeners.

`history/compact` receives a frozen context containing `session`, `round`,
`turn`, `window_tokens`, `instructions` and `messages`. Messages are the current
history records, including their round ids, content and settled forms. The hook
takes the first valid policy; returning nil delegates to the next listener.
Policies are plain data, with finite numbers satisfying
`trigger_bytes > target_bytes > 0` and these optional fields:

| Field | Default | Effect |
| --- | --- | --- |
| `retain_rounds` | `[]` | Round ids whose messages must survive compaction without assistant-code elision or summarization. Unknown ids have no effect. |
| `elide_assistant` | `true` | Allow older, unretained assistant code to be shortened to comments, append_prompt, Outcome and elision lines before summarization. |
| `summary_instructions` | `"Summarize earlier work, decisions, outputs and recall ids."` | The summary task; the host appends the prose-only and byte-budget constraints. |

For example, a hook can choose retained rounds from `context/messages` and
return:

```gene
{^trigger_bytes (* context/window_tokens 2.625)
 ^target_bytes (* context/window_tokens 1.925)
 ^retain_rounds ["round-with-important-decisions"]
 ^!elide_assistant
 ^summary_instructions "Preserve deployment decisions, test failures and recall ids."}
```

Threshold-only plugins retain the existing defaults. Invalid policies are
diagnosed and skipped. Retention applies to the current history representation;
it cannot recover text already elided or summarized. The host still protects
the active task and latest assistant/request pair, preserves media references,
records model calls and persists history. If retained context cannot fit below
the target, compaction fails without publishing a replacement history.

The built-in `history_basic` policy applies the usual 75% and 55% thresholds.
The baseline requires its `history/compact/history_basic` hook, so a replacement
must contribute that key. Hook rows come from the turn's leased composition;
a concurrent plugin replacement does not change an in-progress turn.

### Observe durable facts

```gene
(import ^from "src/plugin_api.gene" [DurableRecord])
(host .PluginHost:subscribe DurableRecord
  (fn [event]
    (if (== event/name "turn/end")
      (handle_turn_end event/envelope/payload))))
```

`DurableRecord` is emitted after a workspace or session event is appended.
Select an exact record by `name`; `scope`, `stream` and the frozen `envelope`
give its location and payload. The bus is for observation. Model calls have
one `model/request` containing the frozen prepared value and one
`model/result` per attempt, including timeout, error and interrupted
outcomes. Large prepared text strings use content-addressed blob references;
image payloads use media references. Literal marker maps are escaped so
inspection can restore supported provider inputs exactly, without replaying
a model call. Opaque image preparations are explicitly marked as omitted.
Model-call records include wall-clock time and attempt results
also include elapsed timing. The loop writes these facts even if an observer
or hook fails.

## Inspect and repair

`plugin_states` returns the leased plugin list and profile readiness report;
`inspect_plugin id` reads one plugin from that same snapshot.
`disable_plugin` and `enable_plugin` work on stored and built-in ids.
`restore_plugin id` removes a stored override only when the profile has a
default for that id. Replacing any taken id with `register_plugin` requires
`^^replace`. The CLI recovery commands `doctor`, `enable ID`,
`disable ID` and `restore ID` do not activate plugins. A quarantined entry
remains durable and visible to repair commands; it does not supply functions
until it can activate. `doctor` does not commit a composition generation; it
uses the last successful activation marker to distinguish pending work from a
clean workspace.

## History and version reversion

Composition commits retain complete historical entries, including source and
dependency digests, interfaces, limits, enabled state, and mutation origin.
History extends beyond the store's short checkpoint-retention window.
`plugin_history` reads the current archive; pass a plugin ID to focus on its
stored versions, and use `^limit` and `^before` to select older revisions.
Pass `^page true` for a result containing `history`, `revision`, and
`next_before`, including when a filtered page has no entries.

```gene
(plugin_history "my_plugin")
(revert_plugin "my_plugin" 12 ^expected 20)
```

Here 12 identifies the historical composition containing the version and 20
is the expected current composition. Reversion creates a new revision. It
retains application data and the current enabled/disabled preference; it does
not prove that older code can read newer application data. A stale expected
revision is rejected. Model reverts use the existing turn-boundary queue and
report their publication result before the round can finish.

`restore_plugin` continues to mean restoring the current built-in default.
It is distinct from reverting a stored version and still fails when the
profile has no default for that ID.

The CLI exposes `history [ID]` and `revert ID --revision N`, with optional
`--expected-revision N`. Their default mode talks to the running host. Add
`--offline` while the host is stopped to inspect history or repair desired
state under the exclusive workspace lock. Offline reversion checks records
and source digests without invoking plugin code; activation remains unverified
until normal startup. Online direct reversion retains the existing
commit-before-activation and quarantine behavior.

New history-enabled checkpoints use composition format 2. Existing format-1
workspaces import their current baseline with unknown historical host identity;
older Harness builds refuse format 2 rather than silently dropping history.
