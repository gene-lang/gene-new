# Web components contributed by plugins

Plugins enhance the existing Harness browser UI through the `web_components`
registry. No separate app server or core source edits are needed for a plugin.
The registry uses the same activation ownership, queued publication, verified
module loading, replacement and retirement as functions and commands.

| Slot | Behaviour |
| --- | --- |
| `sidebar` | Add panels above the conversation list. |
| `toolbar` | Add compact components below the heading. |
| `composer` | Add components above the composer and questions. |
| `status` | Add panels in the workspace status drawer. |
| `welcome` | Replace the empty-conversation view. The name must be `welcome`. |
| `status_summary` | Replace the model/profile summary in the status drawer. The name must be `status_summary`. |

Each row has a stable `name`, a `slot`, and exactly one of `view` or `render`.
Additions use unique names such as `scratchpad` or `workspace_pulse`. Two plugins
cannot silently claim the same name: conflicting contributions fail unless
replacement is explicitly requested with `PluginHost:replace_contribution`.
Disabling/removing a plugin removes its components. A replacement's absence
restores the built-in view. Restart reconstructs enabled components and their
durable plugin state.

## Static view and actions

Use ordinary quoted Gene nodes as view data:

```gene
(host .PluginHost:contribute "web_components"
  {^name "quick_actions" ^slot "composer"
   ^view (quote
     (section ^class_name "web_card"
       (h3 "Next step")
       (p "Inspect the project or draft a focused request.")
       (div ^class_name "web_actions"
         (button ^command "/help" "Commands")
         (button ^prompt "Review the current project and suggest the next useful improvement." "Draft a review"))))})
```

A button's `command` submits a normal slash command with the existing cookie,
CSRF handling and command receipts. It preserves the composer draft. With no
conversation selected, it creates a conversation for the command. A button's
`prompt` fills the composer; the user decides when to send it. Both actions
are disabled while disconnected or submitting. Components do not replace
authentication, submission recovery or cancellation controls.

Supported elements: div, section, p, h2, h3, h4, span, strong, small, em, ul,
ol, li, button, a, details, summary, pre, code, progress, hr, br. Supported
attributes: class/class_name, title, role, aria-label/aria_label, type, href,
value, max, open, disabled, command, prompt. Attributes contain scalar data;
there are no inline scripts or raw HTML. Links use local paths, fragments or
HTTPS URLs. View text becomes DOM text, including user-supplied strings.

Use the shared classes `web_card`, `web_grid`, `web_actions`, `web_badge`,
`web_metric` and `web_muted` for cards, responsive grids, button groups, badges,
large metrics and supporting text. Component views are bounded to 24 levels
and 64 KiB. The underlying wire tree is `{tag, props, children}`; it can also
be supplied directly as maps/lists.
The wire normalizes text and attribute values to strings; true creates an
empty HTML attribute, while false/nil omit it.

## Dynamic view and persistent state

`render` receives immutable context with `session_id`, `session`, `round`,
`workspace`, `model` and `sessions`. An unselected conversation has an empty
session_id and nil session/round. Render should read state and return view
data promptly; each render has a one-second/32 MiB budget. A failing renderer is
reported without taking down the core UI, and a failing replacement leaves
the built-in view available.
Render callbacks should perform synchronous reads and return view data. If a
callback needs child tasks, it must own them with an explicit `scope` inside
the callback; the current VM assigns spawned tasks through the callback's
lexical scope. Do not detach tasks from a renderer.

```gene
(mod plugin
  (import ^from "src/plugin_api.gene" [Plugin PluginHost CommandResult])
  (fn init [descriptor]
    (Plugin ^id "counter"
      ^provides [["commands" "count"] ["web_components" "counter"]]
      ^activate (fn [host]
        (host .PluginHost:contribute "commands"
          {^name "count" ^usage "/count" ^doc "Increment the persistent counter."
           ^run (fn [ctx]
             (let state (?? host/.PluginHost:state {^count 0}))
             (host .PluginHost:update_state {^count (+ state/count 1)})
             (CommandResult ^display "Counted."))})
        (host .PluginHost:contribute "web_components"
          {^name "counter" ^slot "sidebar"
           ^render (fn [context]
             (let state (?? host/.PluginHost:state {^count 0}))
             `(section ^class_name "web_card"
                (h3 "Counter")
                (strong ^class_name "web_metric" %state/count)
                (button ^command "/count" "Add one")))})))))
```

`PluginHost:state` and `update_state` use workspace state by default. Pass
`^session context/session_id` (or `ctx/session` in a command) for per-session
state. Publication, round updates and finished commands send a new snapshot
with freshly rendered components. Views are data, so rerendering discards the
old DOM and its handlers; plugins have no lingering browser timers or globals.

Register the source with `register_plugin`. Generated sources import only the
shared `src/plugin_api.gene` plus declared content-addressed dependencies.
Do not import repository implementation modules from a generated plugin.
The model can load this reference with `(doc "harness/web_components")`.

The turn function takes an id and source, with optional `^dependencies` and
`^replace`:

```gene
(register_plugin "counter" ($fs/read_text "counter.gene"))
(register_plugin ^^replace "counter" ($fs/read_text "counter.gene"))
```

Save source in the workspace before registration. Publication is queued until
the turn closes; verify the contributions on the next turn. Registration
accepts source text or a quoted module. The shared API import is virtual inside
generated modules; its repository file is
`examples/gene-harness/src/plugin_api.gene`.
Updating an already registered id requires explicit `^^replace`.

Command handlers receive `ctx/raw` (the text after the command name) and
`ctx/session` (the current conversation id). A handler returns `CommandResult`,
usually with `^display` and optionally `^status "failed"`. Render context's
session entries contain `id`, `title`, `kind`, `status` and activity metadata;
count exact status values such as `running`, `waiting`, `idle` and `done`.
`model` contains `provider`, `model` and optional `effort`.

Operators can enable or disable registered plugins from the browser composer
using the same workspace helpers available to model turns:

```gene
/run (disable_plugin "counter")
/run (enable_plugin "counter")
```

Disabling removes owned components after command publication; enabling restores
them with their durable state. Removing a welcome replacement restores the
built-in welcome immediately for an empty conversation.
