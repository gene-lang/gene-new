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
with freshly rendered components. Workspace state and composition changes also
invalidate ordinary slots: the active browser fetches fresh status in its
selected session's context. Revision and render-order checks prevent cached
tabs or late responses from restoring older content. Views are data, so
rerendering discards the
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

## Experimental stateful panel

The optional workspace UI experiment adds a `panel` beside the conversation.
It is disabled by default. See the [project board](../experiments/ui/README.md)
for installation and a complete plugin. Its APIs are experimental.

Enable and configure it through `ui_configure`:

```gene
(ui_configure {^^enabled ^layout "panel" ^panel "project_board"
  ^side "left" ^width 45 ^theme {^accent "#335577"}})
```

`layout` is `chat` or `panel`; `side` is `left` or `right`; `width` is an integer
percentage from 25 to 70. Theme keys are `ink`, `muted`, `line`, `surface`,
`sidebar`, `soft` and `accent`, with six-digit hex colors. Passing
`{^!enabled}` restores the ordinary interface. Configuration is workspace state.
Host input, selected, code, notice and action surfaces derive from those same
tokens, including in a dark palette; plugins do not need host-specific CSS.
The `/ui/default` recovery URL omits plugin views and theme overrides for that
page and preserves the workspace selection.

A panel row declares `view_state` defaults, a `state_version`, an `actions`
list naming registered functions, and a `render` callback:

```gene
(host .PluginHost:contribute "web_components"
  {^name "project_board" ^slot "panel"
   ^view_state {^filter "" ^selected "welcome"} ^state_version "1"
   ^actions ["board_save"]
   ^render (fn [context]
     # Read durable task data; use context/view_state to filter and select.
     `(section ^key "board"
        (label "Filter" (input ^key "filter" ^state "filter"
          ^value %context/view_state/filter))
        (form ^key "edit-welcome" ^action "board_save"
          ^args {^id "welcome" ^revision "1"}
          (label "Title" (input ^key "title-welcome" ^field "title" ^value "Welcome"))
          (button ^type "submit" "Save"))))})
```

Use the actual task revision in `args`; the literal above illustrates the
wire data. Functions keep their usual signature, doc and callable. The action
adapter runs them in a command task; no new command-row shape is required.

For an optimistic read/check/write, declare `^requires ["ui/state_lock"]`,
resolve it through `PluginHost:resolve`, and call the returned function with a
workspace data key and a zero-argument body. The runtime owns this gate across
plugin activations. The board uses the key `project_board`; its function keeps
the expected-revision check and state write inside the same body.

In addition to the ordinary elements, stateful panels support form, label,
input, textarea, select, option, table, thead, tbody, tr, th and td.

| Property | Meaning |
| --- | --- |
| `key` | Nonempty identity, unique within the view. Required on forms, draft fields and state/action controls. Include the entity id when changing an entity must create a different editor. |
| `state` | Declared view-state field updated by this control. Inputs use their value; checkboxes use a Bool; buttons use `value`. |
| `field` | Named function argument collected from a form on submission. Draft fields must belong to a form and be unique within it. |
| `action` | Function from the row's `actions` list, invoked by a form submission or button. |
| `args` | Static named arguments, combined with submitted form fields. |
| `positional` | Optional static list of positional arguments. |
| `value`, `checked`, `selected`, `required`, `placeholder`, `rows`, `for`, `name` | Ordinary control attributes. Values and checked state are updated without overwriting dirty fields. |

Input types are text, search, checkbox, number and hidden. Field values are
strings except checkboxes, which produce Bool; parse numbers in the function
when needed. Nested forms, duplicate fields and duplicate keys are rejected.
Use Str view-state defaults for value-based controls and Bool for checkboxes.

View state is browser-owned scalar data. Filter typing is debounced, and only
the target component renders. The renderer receives `context/view_state` and
returns plain quoted data; it performs conditions and iteration in ordinary
Gene. Forms keep unsaved values locally until Save. Compatible keys preserve
focus, selection and drafts; increment `state_version` to reset incompatible
browser state.

Normal status snapshots carry a stateful view's descriptor and invalidation
revision, not a default-state tree. Workspace plugin-state updates and plugin
publication invalidate it. The browser requests a new tree with its current
state and rejects superseded responses. This works for changes made by the
model, CLI/REPL functions or another conversation.

Render callbacks have the existing one-second/32 MiB bound and must be read-only.
The Harness rejects durable state/event writes in the render context. Plugins
retain ordinary Gene host authority; OS isolation remains a separate concern.
Errors are reported per view and leave the rest of the interface usable.

`(ui_preview "project_board" {^filter "ready"})` uses the same renderer and
validator without a browser. Plugin publication includes JSON outlines beside
`[N.plugins]` in the next model request, only for views owned by successfully
published plugins. Each outline includes tags, keys, visible text, control
identities and enabled state, capped at 3 KiB of encoded nodes. A lone text child
is folded into its parent. Table bodies and lists retain the first three items
with an `omitted` count and `item_tag` on the parent, leaving room for forms and
controls after the data. There is no separate node-count cap.
Text and control values are clipped to 160 bytes. Publication feedback is capped
at eight views and 12 KiB overall, retaining whole nodes/views with explicit
`truncated` markers. Explicit `ui_preview` calls still return the full validated
tree or error. The model can exercise
its registered action functions after publication as well. A successful preview
checks the supplied context; browser layout and interaction still require
browser verification.

Actions retain durable command receipts and the session selected on submission.
The panel resolves an uncertain outcome under that original session and input
identity, even after switching conversations. Stale view/function revisions
are refused. UI action blocks are omitted from conversation transcripts;
progress, errors and cancellation stay in the panel. Failed actions contribute
one diagnostic to the submitting conversation's next user request. Successes
do not attach to model input. The normal 128-command retention window applies.
