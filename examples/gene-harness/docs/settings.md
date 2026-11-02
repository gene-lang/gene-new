# Settings

Settings has one screen with a sidebar of groups, and the same values are available
directly on the [global objects](objects.md). The screen is the built-in `settings`
plugin. It owns presentation, drafts, search and shortcut recording. The host
operations behind it own validation, inheritance, persistence and revisions, so a
save from the screen, from Gene code or from another tab behaves the same way.

Open it from the View picker. It is listed even when optional workspace views are
off. Disabling the `settings` plugin removes the screen and leaves every definition
and object message in place.

## Groups

The sidebar is built from what is contributed, not from a fixed list:

- every setting definition names a `group`, and each group with at least one active
  setting appears;
- a `settings_groups` row adds a label, `order`, `doc` or a custom `section`, and can
  create a destination that has no ordinary settings, such as Providers.

Groups sort by `order`, then label, then name. The built-ins are General (10),
Models (20), Providers (30, from the models plugin), Appearance (40), Keyboard
Shortcuts (50) and Voice (60, from the voice plugin). Triggers, Images, Delegation and
Computer follow from their settings. Moving a group or renaming its label never
changes a setting key.

```gene
(workspace .settings_groups)
(host .PluginHost:contribute "settings_groups"
  {^name "Deploys" ^order 70 ^doc "Where releases go." ^section "deploy_settings"})
```

A section is a `web_components` row with `^slot "settings_section"`, a `render`
callback and an optional `actions` list. Settings renders it inside the group and
admits its actions as its own, using the ordinary view-action contract. Each
section's tree is checked on its own with `UiHost:validate tree ^view "settings"`,
and then again as part of the whole screen, which catches collisions such as a
reused key. A section whose plugin is disabled, whose render fails, or whose tree
breaks the component or action contract explains that inside its group and leaves
the rest of the screen working.

When a plugin is removed, its settings, group rows and sections go with it. An
inferred group stays while another plugin still contributes settings to it. Stored
values are never deleted, so re-enabling the plugin brings them back.

## Setting definitions

A `settings` row has `key`, `label`, `group`, `doc`, `type` (`int`, `str`, `bool`,
`map` or `any`), `default`, `applies` and optionally `min`, `validate`, `choices` and
`scopes`.

| Field | Meaning |
| --- | --- |
| `applies` | `immediate`, `next_round` or `restart`: when a saved value takes effect |
| `choices` | The name of a `setting_choices` source that offers values |
| `scopes` | `["workspace"]` by default; `["workspace" "shared"]` allows a shared default |

Built-in definitions are plain data, so consumers that run before the registry
exists use the same defaults the screen shows.

### Choice sources

A `setting_choices` row has a `name`, a `choices` callback and an optional
`closed` flag. The callback receives `{^key ^values ^scope}`. `values` are always the
complete values for that scope, so a source can read a dependency that was not
edited: in workspace scope they resolve through the shared file and defaults, in
shared scope they are the shared file over the defaults, and draft values are laid
on top. Saves check choices against the whole candidate inside the store's
transaction. The callback returns a list of options or a map:

```gene
{^options [{^value "high" ^label "high" ^available true ^reason nil}]
 ^complete true ^reason nil}
```

Evaluation is a read of cached catalogs. Refresh and sign-in stay explicit
operations. A closed, complete source rejects a new value it does not offer. An
open source, or an incomplete or failed one, only suggests: model ids that are not
in the catalog stay usable and are saved unverified. A saved value that disappears
from the options stays visible with its reason.

| Source | From | Closed |
| --- | --- | --- |
| `models` | models plugin, cached catalog | no |
| `efforts` | models plugin; the portable levels plus native levels the model advertises | yes, when the catalog describes the model |
| `voices` | voice plugin; current engines cannot list voices, so it says so | no |

```gene
(workspace .setting_choices "effort" ^values {^provider "anthropic" ^model "claude-opus-5-5"})
```

## Scopes and storage

| Values | Owner | Store |
| --- | --- | --- |
| Workspace overrides | `workspace` | `.gene-harness/config.gene` |
| Shared generic defaults | `manager` | `<manager root>/.gene-harness/settings.gene` |
| Shared model default and catalog configuration | `manager` model messages | `<manager root>/.gene-harness/models.gene` |
| Theme, provider connections and other domains | Their own owners | Their own files |

The shared keys are `turn_limit`, `trigger_turn_limit`, `trigger_timeout_ms` and
`question_timeout_ms`. Everything else, including `keyboard_bindings`,
`trigger_concurrency` and `response_budget`, is workspace-only. `response_budget`
also sets plugin admission limits when the host starts, so its new value reaches new
evaluations at once and plugin budgets after a restart.

A generic value resolves from the workspace value, then the shared value where the
definition allows it, then the definition default. Presence decides, so `false`,
`0`, `""` and `{}` are real values. Provider, model and effort keep the
[model selection order](models.md).

```gene
(workspace .settings ^group "Triggers")     # value, stored, shared, inherited, default, source
(workspace .set_settings {^turn_limit 40 ^trigger_turn_limit 8} ^reset ["question_timeout_ms"] ^expected digest)
(workspace .reset_setting "turn_limit")     # inherit the shared value or the default
(manager .settings)                         # shared defaults and settings.gene's digest
(manager .set_setting "turn_limit" 40 ^expected digest)
(manager .reset_setting "turn_limit")
```

Each save writes exactly one store and checks that store's digest. A batch with one
invalid value, a stale digest, or a key that belongs to another store saves nothing.
`set_settings` is the only workspace write path: single writes, resets, the
provider/model/effort editor and shortcut edits all go through it. Shared writes take
`settings.lock` beside `settings.gene` for the read, digest check and atomic write,
so two hosts cannot overwrite each other. They work from any host, with no manager
running.

A new workspace starts with an empty `config.gene`. An existing value stays a
workspace override, even when it equals a default, until you reset it.

Every consumer reads the files when it uses a value. A shared edit therefore reaches
each workspace's next applicable round with no restart, notification or open
browser. A round that has started keeps the limits and deadlines it was admitted with.

## When values apply

Each view reports `applies`. For `restart` settings it also reports `active`, the
value the running feature started with, and `pending_restart` when the value that
would apply after a restart differs. A feature that has not started yet reports
`active_known false` and no comparison.

After each committed save the host publishes `settings/changed` with the scope,
digest and keys, and open Settings screens refresh clean fields while keeping
unsaved drafts with the revision they were read at. A web host also watches
`settings.gene` once a second and refreshes screens when another host changes it.
That watch is for screens only; execution never waits for it.

## Models

The Models group shows what the next round would use and why
(`(workspace .model_selection)`). In Workspace scope its editor saves provider,
model and effort in one batch, so the screen cannot store a mismatched pair. A
provider alone ("its default model") is a selection of its own, and saving with the
selection unchanged leaves provider and model exactly as stored; **Follow the
selection order** and **Use inherited selection** are the only ways to remove them.
Changing the model refreshes the effort choices before saving. Effort accepts the
portable levels and any native level, such as `ultra`, that the selected model
advertises in the catalog. The model is the one the values being saved would select
by the usual order, so resetting the model or keeping only a provider is judged
against the inherited or default model. In Shared scope it saves `models.gene`'s default through
`(manager .set_default_model selection digest)`. Installing a provider or
refreshing the catalog never changes a saved selection.

## Providers

The Providers group lists each connection's state and model count, offers **Refresh
connections**, and links to the [Models page](models.md) for sign-in, accounts and
endpoints. Refresh checks connections and model lists; it does not send an
inference request.

## Keyboard Shortcuts

Shortcuts are workspace-only. The tab lists each action's label, chord, default,
context, owning plugin and conflicts, with search and a customized-only filter.

**Record** opens a field that takes the next key chord instead of text; Save stores
it and Cancel leaves the binding alone. While the field has focus, application and
plugin shortcuts are suspended. Plain Tab and Shift+Tab still move focus. Chords are
stored as event codes, such as `Ctrl+KeyK`, and shown in the platform's notation:
`⌃⇧K` on macOS, `Ctrl+Shift+K` elsewhere. Ctrl is never shown or stored as Command.

Conflicting shortcuts in overlapping contexts are listed with a button to clear the
other action; nothing is cleared for you. **Clear** stores an unbound override and
**Restore default** removes the override. Browsers and operating systems keep some
combinations, such as ⌘Q or Ctrl+W, and those never reach the recorder.

```gene
(let keys workspace/.keyboard)
(workspace .bind_key "view/toggle" "Ctrl+Shift+KeyK" ^expected keys/digest)
```

Every shortcut message takes the digest it read and changes only one action's entry
inside the map it reads under the configuration gate, so two editors get a revision
conflict instead of losing each other's overrides.
