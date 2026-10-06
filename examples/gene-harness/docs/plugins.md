# Harness plugins

The profile lists trusted built-in plugin defaults. Stored plugins are
content-addressed modules in the workspace. Both use the same contribution
registries, snapshot leases, activation, retirement and error reporting.
`doctor` opens the workspace without activation if a plugin prevents normal
startup.

## Register from a session

Use `register_plugin` with one quoted `(mod plugin ...)` form or attachment
text. The module must define `init` returning a `Plugin`. Its top level is
inert; `init` is preflighted under a bounded budget. Generated imports are
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

## Contributions

Activation receives a `PluginHost`. Each row it contributes is owned by that
plugin and is removed when the activation unloads. Common rows are:

| Registry | Row |
| --- | --- |
| `functions` | `{^name ^doc ^fn}`; response code and `/run` bind it by name |
| `commands` | `{^name ^usage ^doc ^run}`; an operator slash command |
| `prompt` | `{^name ^text}` or `{^name ^render}`; an instruction section |
| `docs` | `{^name ^text}` or `{^name ^path}`; read with `(doc name)` |
| `providers` | `{^name ^doc ^available ^configure ^prepare ^send}`; a model adapter selected by the profile or configuration |
| `hooks` | `{^point ^name ^run}`; an ordered listener at a published shaping point |
| `triggers` | A definition that starts workspace work without a user |

Prompt sections have deterministic order. A plugin should describe only the
functions it also contributes, so disabling it removes both the binding and
the instruction. `prepare` on a provider row returns plain model-visible data
without credentials; `send` adds transport authentication and makes one
attempt. A provider row is inert until selected. Callback limits apply to
generated provider and hook rows just as to other plugin callbacks.

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
`^replace true`. The CLI recovery commands `doctor`, `enable ID`,
`disable ID` and `restore ID` do not activate plugins. A quarantined entry
remains durable and visible to repair commands; it does not supply functions
until it can activate. `doctor` does not commit a composition generation; it
uses the last successful activation marker to distinguish pending work from a
clean workspace.
