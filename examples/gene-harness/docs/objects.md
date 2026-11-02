# Global objects

Code running in a Harness host reaches everything through three objects. Reflection
is ordinary access: read a property or send a message, and ask Gene what a value
accepts with `($runtime/messages value)`. There is no separate catalog or descriptor.

| Object | What it is |
| --- | --- |
| `workspace` | The root of this host, with access to everything in it |
| `manager` | The manager root, shared defaults and the workspaces under it |
| `session` | The current conversation, when code is running as part of one |

These expose internals. They filter nothing, and users are expected to know what they
are doing. Existing checks stay inside the operations that own them, such as revision
conflicts and the Workspaces view gate, and direct access to internals can reach past them.

## Getting them

Response code, `/run`, the REPL and cards have the three names bound. Plugin code has
closed module scope, so it calls accessors:

```gene
(import [current_workspace current_manager current_session] ^from "src/plugin_api.gene")
```

`current_workspace` and `current_manager` work from activation onward, including in
background tasks. `current_session` returns the call's session, or nil where there is
none: activation, background tasks and view actions. Spawned tasks inherit their
parent's session. A view action reaches a session explicitly with `(workspace .session id)`.

A `/sh` child or a standalone `gene run` is another process and has no objects. It can
use the CLI, such as `gene-harness --session ID run`. Browser code uses the authenticated
routes. Recovery keeps its own plugin-free surface. Running submitted code outside a session
is future work.

## Reading

Every internal value is reachable by property path:

```gene
workspace/root                      # the workspace directory
workspace/h                         # the kernel Harness: registries, plugins, event bus
workspace/runtime                   # the HarnessRuntime
workspace/sessions                  # the SessionManager
workspace/services/values/commands  # any host service
workspace/workspace                 # the composition store
session/id
session/.state                      # the live SessionState
session/.record                     # the stored record
manager/root
manager/service                     # the WorkspaceManager, in the manager host
```

A session's state and record are messages because a session can be unloaded and reloaded.

These values are cyclic, which is safe. They print with `(cycle)` and `(seen)` markers, `==`
terminates, and `$freeze` raises a catchable error. A printed value goes wherever you send it:
`(append_prompt "x" workspace)` puts internals in the conversation and sends them to the provider.

## Discovering

```gene
($runtime/messages session)                     # each message's send, kind, signature and @doc
(workspace .registries)                         # every registry, including plugin-created ones
(workspace .rows "functions")                   # real rows; a function row's fn is callable
(workspace .plugin "image")                     # state, reason and declared contributions
workspace/.revision                             # the composition revision being read
(discover "topic")                              # topic search over contributions
```

A disabled or failed plugin stays inspectable through `(workspace .plugin id)`, keeping its
state, reason and declared contributions. Its functions are no longer bound, so calling one
directly is `undefined symbol`.

## Working with sessions

```gene
(workspace .sessions ^q "audit")
(let other (workspace .session id))
(session .rename "Audit")
(other .submit "Run the checks.")
other/.round
(other .answer batch_id answers)
(other .cancel)
(other .delete)
```

Model code is not restricted in what it does to other sessions. Those messages call the same
operations as the operator's routes. A round submitted with `.submit` is not a delegated child and
has none of delegation's parent ownership or budgets; use `delegate` when you want those.
`.transcript` returns the same records the operator sees, including REPL activity. REPL activity
does not enter a model's history unless code reads it and sends it there.

## When a write takes effect

Most writes apply immediately. Plugin changes depend on the calling context, and the result says
which happened:

| Called from | `boundary` | Result |
| --- | --- | --- |
| A response or `/run`, or a plugin callback inside one | `turn` | `^status "queued"`; applied when the turn commits and discarded on cancellation |
| Anywhere else, such as a view action | `immediate` | The applied change and its revision |

Some work returns before it finishes: `.submit`, `.command`, `.refresh_models` and `.connect`. Read
the object again in a later evaluation to see the outcome. Response code cannot keep a subscription
after its turn; plugins subscribe through `PluginHost:subscribe`, and browsers and scripts use the
authenticated event stream.

## Manager

`manager` exists in every host, with the same messages.

| Message | Manager host | Ordinary workspace |
| --- | --- | --- |
| `manager/root`, `.model_configuration`, `.models`, `.settings` | Local | Local; no running manager needed |
| `.set_default_model`, `.save_model_configuration`, `.set_setting`, `.set_settings`, `.reset_setting` | Local, revision-checked | Local, revision-checked |
| `.workspaces` | Live status | Read from the workspaces directory, with status `unknown` |
| `.workspace`, `.control` | Available | Fails with `unavailable` |

The manager is itself a Harness workspace, so in its host `workspace` is the manager's own workspace.
Reaching another workspace's sessions needs a connection between hosts that does not exist yet.

## Settings

`workspace` owns writes to `config.gene`; `manager` owns the shared generic defaults in the manager
root's `settings.gene`. Each setting comes from the `settings` registry and reports its definition,
value, stored value, shared value, inherited value, default and source (`launch`, `workspace`,
`shared` or `default`). The [settings reference](settings.md) covers groups, choices, scopes and the
Settings screen.

```gene
(workspace .settings ^group "Triggers")
(workspace .setting "turn_limit")
(workspace .set_setting "turn_limit" 40 ^expected digest)
(workspace .set_settings {^provider "anthropic" ^model "claude-opus-5-5"} ^reset ["effort"] ^expected digest)
(workspace .reset_setting "turn_limit")            # inherit the shared value or the default
(workspace .settings_groups)
(workspace .setting_choices "effort" ^values {^provider "anthropic" ^model "claude-opus-5-5"})
workspace/.model_selection                          # what the next round would use, and why
(manager .settings)
(manager .set_setting "turn_limit" 40 ^expected digest)
(manager .set_settings {^turn_limit 40} ^reset ["question_timeout_ms"] ^expected digest)
(manager .reset_setting "turn_limit")
```

Each save writes one store against that store's digest; one invalid value or a stale digest saves
nothing. A definition's `applies` says whether a change takes effect at once, from the next round or
after a restart, and restart settings report the `active` value and `pending_restart`. Only
definitions with `^scopes ["workspace" "shared"]` take shared values: `turn_limit`,
`trigger_turn_limit`, `trigger_timeout_ms` and `question_timeout_ms`. The shared model default stays in
`models.gene` through `.set_default_model`, and conversation choices belong to `session`. A plugin adds
a setting by contributing a row with `key`, `label`, `group`, `doc`, `type`, `default`, `applies` and
optional `min`, `validate`, `choices` and `scopes`. Definitions are host-owned, so they stay
available whichever screen shows them.

## Browser tabs and keyboard actions

Browser-local state belongs to one tab. Asking about or changing a tab never touches workspace defaults.

```gene
workspace/.clients                              # connected tabs and their client ids
(workspace .client_view client)                 # the tab's selected view and presentation
(workspace .navigate_client client "harness")   # switch that tab
(workspace .invoke_client_action client "view/toggle")
```

An absent or silent tab fails with `unavailable`. The request travels over the push socket and the reply
on an authenticated route.

Shortcuts come from the `keyboard_actions` registry. Chords use event codes, such as `Ctrl+Shift+KeyK`.

```gene
workspace/.keyboard                             # binding, default, source, context, conflicts, owner, digest
(workspace .bind_key "view/toggle" "Ctrl+Shift+KeyK" ^expected digest)
(workspace .clear_key "view/toggle" ^expected digest)
(workspace .restore_key "view/toggle" ^expected digest)
```

Connected tabs pick up a change at once. Overrides are stored by action id in the workspace-only
`keyboard_bindings` setting, so they survive a plugin being disabled and apply again when it returns.
Each message changes one action's entry inside the map read under the configuration gate, and a stale
digest fails with a revision conflict. Keys that only move
through or dismiss an open menu or list stay with that widget, following standard menu behavior.

## Contributing

Plugins do not add messages to these objects, because a type's messages are fixed once its module
loads. Contributed operations remain registry rows with their supervised callables, found through
`(workspace .rows "functions")` or `discover`. New messages on these objects declare parameter and
result types and a literal `@doc`, and a spec enforces that.
