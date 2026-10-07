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

When the UI experiment is enabled, successfully published plugins that own
stateful views also receive `[N.ui]` outlines or render errors. These previews
run without a browser. Read the publication feedback before finishing, then
exercise the action functions and verify the browser interactions as needed.

## Contributions

Activation receives a `PluginHost`. Each row it contributes is owned by that
plugin and is removed when the activation unloads. Common rows are:

| Registry | Row |
| --- | --- |
| `functions` | `{^name ^doc ^fn}`; response code, `/run` and the REPL bind it by name |
| `commands` | `{^name ^usage ^doc ^run}`; an operator slash command |
| `input_modes` | `{^name ^label ^hint ^submit_label ^prompt ^classify ^run ^close}`; a transient operator input mode |
| `prompt` | `{^name ^text}` or `{^name ^render}`; an instruction section |
| `docs` | `{^name ^summary ^tags ^text}` or `{^name ^summary ^tags ^path}`; body read with `(doc name)` |
| `providers` | `{^name ^doc ^available ^configure ^prepare ^send}`; a model adapter selected by the profile or configuration |
| `hooks` | `{^point ^name ^run}`; an ordered listener at a published shaping point |
| `triggers` | A definition that starts workspace work without a user |
| `web_components` | `{^name ^slot ^view}` or `{^name ^slot ^render}`; quoted UI, with `view_state` and `actions` for experimental panel forms |

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

`prepare` on a provider row returns plain model-visible data
without credentials; `send` adds transport authentication and makes one
attempt. A provider row is inert until selected. Callback limits apply to
generated provider and hook rows just as to other plugin callbacks.

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

### Shape a request or compaction decision

`request/prepare` receives a context with `items`, session, round, turn and
round budget. Its `run` callback takes that context and `next`. Calling
`next` delegates; returning without it decides. The loop writes the result
as `turn/request`, then records the final provider-specific input as
`model/request` immediately before `send`. A hook that fails or times out is
skipped with a `trace` diagnostic. A listener may call `next` once; a second
call is diagnosed and does not rerun later listeners.

`history/compact` takes the first valid policy containing `trigger_bytes`
and `target_bytes`. The built-in `history_basic` policy applies the usual
75% and 55% thresholds. The baseline profile requires it. Hook rows come from
the turn's leased composition, so a concurrent plugin replacement does not
change an in-progress turn.

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
outcomes. Large prepared strings use content-addressed blob references.
Literal maps with the same shape are escaped, so replay preserves the exact
provider input. Model-call records include wall-clock time and attempt results
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
