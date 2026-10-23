# Web components contributed by plugins

Plugins enhance the existing Harness browser UI through the `web_components`
registry. Response code can also place inline [cards](cards.md) in its own
conversation with the same vocabulary, without a plugin. No separate app server or core source edits are needed for a plugin.
The registry uses the same activation ownership, queued publication, verified
module loading, replacement and retirement as functions and commands.

| Slot | Behaviour |
| --- | --- |
| `sidebar` | Add panels above the conversation list. |
| `conversation_sidebar` | Replace the whole conversation sidebar layout; its name must equal the slot. See [sidebar](sidebar.md) for host navigation widgets. |
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
ol, li, button, a, details, summary, pre, code, progress, hr, br, img. Supported
attributes: class/class_name, title, role, aria-label/aria_label, type, href, target,
value, max, open, disabled, command, prompt, src, alt, width, height, columns, inset (the image properties are detailed below). Attributes contain scalar data;
there are no inline scripts or raw HTML. Links use local paths, fragments or
HTTPS URLs. View text becomes DOM text, including user-supplied strings.
An anchor's `target` can be `_self` (the default) or `_blank` to open a new tab.
The host adds `rel="noopener"` to `_blank` links.

Use the shared classes described under [Styling](#styling) for cards, rows,
grids, badges, notices and button variants. Component views are bounded to 24
levels and 64 KiB. The underlying wire tree is `{tag, props, children}`; it can also
be supplied directly as maps/lists.
The wire normalizes text and attribute values to strings; true creates an
empty HTML attribute, while false/nil omit it.

## Styling

The host theme (see [theming](theming.md)) styles plugin content in light and
dark mode. A component built from the supported elements and these classes
needs no CSS of its own:

| Class | Use |
| --- | --- |
| `web_card` | Bordered card; headings and paragraphs inside get card spacing |
| `web_stack`, `web_row`, `web_spread` | Vertical stack, wrapping row, row with items pushed apart |
| `web_grid` | Responsive grid of equal columns |
| `web_tight`, `web_loose` | Smaller or larger gaps on a stack, row, spread or grid |
| `web_actions` | Button group |
| `web_badge`, `web_badge_danger`, `web_badge_success` | Square status chip |
| `web_notice`, `web_notice_error`, `web_notice_success` | Notice with a status rule |
| `web_metric`, `web_muted` | Large number; supporting text |
| `web_danger_text`, `web_success_text` | Status-colored text |
| `web_table_compact` | Denser table cells (views) |
| `web_primary`, `web_secondary`, `web_danger` | Button variants: filled, quiet, destructive |

Headings, paragraphs, lists, links (always underlined), code, preformatted
text, rules, progress bars, forms and tables in views get theme defaults. Only
buttons have rounded corners. For example, with no custom CSS:

```gene
(quote
  (section ^class_name "web_card"
    (div ^class_name "web_spread"
      (h3 "Deploys")
      (span ^class_name "web_badge web_badge_success" "Healthy"))
    (p ^class_name "web_muted" "Last run 4 minutes ago.")
    (div ^class_name "web_actions"
      (button ^class_name "web_primary" ^command "/deploy" "Deploy")
      (button ^class_name "web_secondary" ^prompt "Summarize the last deploy." "Explain"))))
```

When a view needs presentation the host does not provide (column widths,
sticky headers, chart layout, domain colors), add a `style` to the component
row. It is `$css` node data. By default the host scopes it to the component
with `$css/scoped`, so its selectors only match inside that component;
`^!style_scoped` makes the rules page-wide. Scoping prevents accidental
collisions; it is not isolation, and plugins are trusted to use broader rules
deliberately.

```gene
(import $css [css rule decl])

(host .PluginHost:contribute "web_components"
  {^name "sheet" ^slot "view" ^title "Sheet" ^view_state {} ^render render_sheet
   ^style (css
     (rule ".sheet_grid" (decl display "grid") (decl grid_template_columns "12rem repeat(6, 1fr)"))
     (rule ".sheet_grid > .header" (decl position "sticky") (decl top 0) (decl background "var(--surface)"))
     (rule ".cell.selected" (decl outline "2px solid var(--accent)")))})
```

Prefer the theme tokens (`--ink`, `--muted`, `--line`, `--surface`, `--soft`,
`--accent`, `--edge`, `--danger`, `--success`, `--font-mono`) so the view
follows light and dark mode; values without a shared token are the plugin's
own, and keeping them readable in both modes is the author's job. A rendered
style may be at most 64 KiB, and a style that cannot be rendered is a
validation error. The browser mounts it as a `<style>` element while the
component is present: replacing the row replaces it, disabling or removing the
plugin removes it, and `/ui/default` omits it.

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

## Stateful workspace views

The optional workspace UI supports `view` components, full screen or docked
beside Classic Harness. Legacy `panel` registrations are aliases with a docked
default. It is disabled by default. See the [project board](../experiments/ui/README.md)
for a two-view plugin and [workspace views](workspace-views.md) for navigation.

Enable and configure it through `ui_configure`:

```gene
(ui_configure {^^enabled ^layout "panel" ^panel "project_board"
  ^side "left" ^width 45 ^theme {^light {^accent "#335577"} ^dark {^accent "#9db4d6"}}})
```

`layout` is `chat` or `panel`; `side` is `left` or `right`; `width` is an integer
percentage from 25 to 70. `theme` overrides the panel's colors per mode:
`^light` and `^dark` each map the keys `ink`, `muted`, `line`, `surface`,
`sidebar`, `soft` and `accent` to six-digit hex colors. A single flat key map
is accepted and applies to light mode only; in dark mode such a panel uses the
host's dark palette. Passing
`{^!enabled}` restores the ordinary interface. Configuration is workspace state
and supplies fresh-tab defaults; navigation and presentation choices are local
to a tab. `default_view` selects a canonical initial view or `harness` and takes
precedence over the legacy layout/panel fields. Theme overrides style plugin
content only; Classic Harness and host controls follow the workspace's light
or dark theme.
The `/ui/default` recovery URL omits plugin views and theme overrides for that
page and preserves the workspace selection.

A view row declares a nonempty `title`, `view_state` defaults, a `state_version`, an `actions`
list naming registered functions or browser-only `ui_actions`, and a `render` callback:

```gene
(host .PluginHost:contribute "web_components"
  {^name "project_board" ^slot "view" ^title "Project board"
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

For an action that should only be offered through a view, contribute the same
`{^name ... ^doc ... ^fn ...}` row to **`ui_actions`**. These rows use the same
receipts, composition leases and callback limits, but are absent from model
function bindings and discovery. View action lookup checks `ui_actions` first,
then `functions`. The workspace manager uses this for deletion and explicit
interruption confirmation; its public model functions share the underlying
service but never confirm active-work interruption.

For browser-only navigation, **`ui_links`** rows use the same row shape with a
callback accepting the request's parameter map and returning a destination
URL. Link to `/api/v8/ui/open?name=ROW_NAME&...` from the view. The host checks
owner authentication, invokes the current row and returns a redirect without
putting its destination into a function result or action receipt. This lets the
manager open a target's authenticated connection link while keeping its token
out of rendered component state. Plugins remain full-grant; these registries
separate ordinary interfaces rather than creating a sandbox.

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
Textareas accept an explicit `value` or plain text children for their initial
value. Text children are normalized into the value property for draft binding;
an explicit value takes precedence. Markup children are not an initial text value.

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

Actions use a dedicated workspace log and no implicit session. They never create
a conversation or automatically attach failures to model input. Stale
view/function revisions are refused; record-revision checks remain the save
function's responsibility. Receipts survive view switching and host restart;
unfinished work is interrupted without replay. Inspect them when requested with
`(ui_action_receipts ^view "project_board" ^status "failed")`.

An original generation-bound input identity is required for explicit retry.
Generations rotate every 128 admissions; four generations and nonterminal
records are protected. Receipt absence after expiry means the outcome can be
unknown. Do not create a replacement identity to replay an uncertain operation.

Navigation buttons may use `^switch_view "name"` and optionally
`^presentation "docked"` or `"full"`. `harness` selects Classic alone and cannot
have a presentation override. Navigation cannot share a button with a function,
command, prompt, or view-state action. A `prompt` button stages in Classic
Harness and offers Replace/Append/Keep when an unsent draft already exists.


## Workspace images and image surfaces

`img` is available in ordinary components and stateful views. It requires `src`
and `alt` (empty alt is permitted for decorative images) and has no children.
`src` is a workspace-relative image filename, not a URL. Supported extensions
are lowercase `.svg`, `.png`, `.jpg`, `.jpeg`, `.webp`. Paths are limited to
240 bytes and ASCII letters, digits, `_`, `-`, `.`, `/`; absolute, hidden,
empty, `.` and `..` segments, URL schemes, query strings and fragments are
rejected. The validator maps it to `/api/v8/ui/image?path=...`; this GET route
requires the existing owner authentication and same-origin policy.

Optional `width` and `height` are integer intrinsic dimensions from 1 to 2048.
Files must be regular, nonempty, at most 1 MiB, and resolve canonically inside
the workspace (escaping symlinks are refused). Reads are bounded even if a
file grows. Raster image signatures are checked. SVG is an inert drawing
subset: svg/defs, gradients/stops, groups, rectangles, paths, lines, circles,
ellipses and text, with bounded lexical drawing attributes. No scripts,
event handlers, CSS, entities, foreign HTML, embedded images, animation or
external references are accepted. Paint references use local `url(#id)` only.
Images are served with explicit MIME type, no-store and nosniff; their response
has a sandbox CSP with default/script/style sources disabled. Arbitrary HTML
remains unsupported; plugin CSS goes through a [style](#styling) contribution.

Use host-owned classes to overlay ordinary accessible controls on an image:

```gene
(quote (div ^class_name "web_image_surface"
  (img ^src "assets/diagram.svg" ^alt "Diagram" ^width 1000 ^height 1000)
  (div ^class_name "web_image_grid" ^columns 9 ^inset 5
    (button ^key "point-a" ^class_name "web_image_point"
      ^action "choose" ^args {^point "0"} ^aria_label "Choose point A"
      (img ^src "assets/marker.svg" ^alt "Marker at point A"
        ^width 100 ^height 100)))))
```

`web_image_surface` is responsive with a 960px maximum width. Its direct image
sets the aspect ratio. `web_image_grid` is a transparent absolutely positioned
equal-cell overlay. Only this exact div class accepts integer `columns` (1–25)
and `inset` (0–25 percent), normalized to data attributes using fixed host CSS.
Supply rows implicitly through the child count (use complete equal-length rows).
Cell centers, not corners, are the clickable positions. `web_image_point`
removes ordinary button chrome but preserves a visible keyboard focus ring,
hover highlight and disabled-state semantics. Its image children fill 96% of
the cell; disabled stones remain fully opaque. The overlay itself takes no
style strings or positioning attributes. Existing keyed actions, validation,
tree bounds and revision checks are unchanged. Preview validates structure,
but alignment and actual image loading must also be checked after host restart
and browser reload.
