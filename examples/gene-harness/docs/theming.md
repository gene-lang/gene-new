# Theming

The web UI has square geometry, two minimalist neutral palettes, and a
host-owned light/dark setting. Light is the default; dark is an equal peer, not
an inverted afterthought. `/about/` follows the same theme as the rest of the
Harness. Plugins inherit usable styling with no or minimal CSS, keep their
public color overrides, and can contribute styles for presentation the host
does not provide. The host supplies visual defaults; trusted plugin authors
decide when to customize them.

This chapter has two parts. Everything up to [Plugin styling](#plugin-styling-defaults-and-customization)
describes the theme as implemented. That theme is the owner's personal
preference and will become the `minimal` theme. [Theme foundation](#theme-foundation-proposed)
proposes the system in which every visual decision can be customized. It covers
installable themes, web fonts, icons, responsive layout, per-browser
preferences, plugin-defined structures, and type, spacing, border, shape and
elevation tokens. A designer will build the `default` theme on it. That part is
not implemented.

## Decisions

Owner decisions, 2026-11-04:

| Question | Decision |
| --- | --- |
| Scope of customization | Everything can be customized. The 2026-10-17 decisions below describe the owner's own theme, `minimal`, not rules of the system. A designer creates the `default` theme. |
| Web fonts | Allowed |
| Icons | Use an icon set |
| Appearance preferences | Per browser, replacing the per-workspace mode |
| Several themes | Yes: users choose among installed themes. Later they can duplicate a theme and customize the copy. |
| `minimal` and `default` | `minimal` extends `default` and sets its own values for the owner's choices. Everything else follows `default`. |

Owner decisions, 2026-10-17, now the values of the `minimal` theme:

| Question | Decision |
| --- | --- |
| Button radius | `5px` |
| Accent | Fully neutral: pure grays, and the accent is the ink color |
| User message | Square block whose color is a theme token (`user`) |
| Where the mode is stored | Per workspace, for now. Superseded 2026-11-04: per browser. |
| Follow-the-OS mode | No. Only `light` (default) and `dark` |
| `/about/` | In scope. It is part of the Harness and takes the theme the way a plugin view does |
| Plugin styling | Ordinary plugin views should need no or minimal CSS. Provide scoped customization for needs outside the theme, and document what the theme does and does not cover. |
| Plugin trust | Assume plugins know what they are doing and are not malicious. Provide styling helpers and lifecycle support without building a CSS sandbox or policing their visual choices. |
| Page CSP | Removed (done 2026-10-17). Pages send no Content-Security-Policy; only the workspace image route keeps its sandbox policy. See [Content-Security-Policy](#content-security-policy). |

## Goals

- **Square by default.** No rounded corners anywhere except on buttons.
- **Minimalist light and dark themes**, both shipped by the host, both meeting
  WCAG AA.
- **Light by default**, regardless of the OS color preference.
- **No flash of the wrong theme**: the first paint uses the chosen mode.
- **One source of truth** for every shared UI color, shared by the app, the plugin
  manager and `/about/`.
- **Usable plugin defaults.** Common controls and layouts inherit the theme;
  plugins should not recreate basic styling to produce a complete view.
- **An extension path.** Plugins can customize their own presentation and add
  styles for specialized content that the host theme does not cover.

Non-goals: theming the terminal client, following `prefers-color-scheme`,
animated theme transitions, and defensive restrictions intended to contain
malicious plugin CSS. Plugin customization is in scope. User-made themes,
including their CSS, are planned; see [Themes](#themes).

## Principles

1. **Corners are square.** Square corners make a calm grid; a radius marks the
   one thing you press.
2. **Lines, not shadows.** Floating layers get a visible edge instead of a blur.
   Shadows and round corners do the same softening job, and both go.
3. **Gray does the work.** The palette is pure neutral gray. The accent is the
   ink color, so emphasis comes from weight, underline, borders and fills, not
   hue. Color appears only when status is the message (`danger`, `success`) and
   in syntax highlighting.
4. **The host supplies defaults; plugins extend their own presentation.**
   Shared controls, typography and corner rules come from the host. Plugins
   can override colors and supply styles for their own layouts and specialized
   visuals. Scoping helps avoid accidental collisions. Plugin authors are
   trusted to choose appropriate overrides, including intentional departures
   from the defaults. `/about/` consumes the same defaults.

## Geometry

### The rule

`--radius-button: 5px` is the only non-zero radius in the host theme. Everything
else has radius 0 by default. That includes inputs, textareas, selects, the composer,
cards, drawers, code blocks, inline code, images, badges, tabs, the user
message and the status dot.

The base stylesheet uses a reset plus one exception:

```css
*, *::before, *::after { box-sizing: border-box; border-radius: 0; }
button { border-radius: var(--radius-button); }
/* Buttons that read as rows, tabs or links stay square. */
.session, .session_tab button, .command, .notification_local, .occurrence,
.sidebar_footer button, .suggestions button, .ui_panel td button,
.older_messages, .web_image_grid > .web_image_point { border-radius: 0; }
```

No other `border-radius` declaration exists in `src/web/style.gene`; the plugin
manager's row buttons (`.plugin_row > button`) declare `0` in its own
stylesheet. `/about/` has its own reset in `src/website/style.gene` and gives
`--radius-button` explicitly to its four controls: the `.button` and `.nav_app`
links (they are `<a>` elements) and the `.nav_toggle` and `.copy_button`
buttons. Its view tabs are `<button role="tab">` elements and stay square.

### What counts as a button

The rule follows visual role, not tag name. Many rows in the Harness are
`<button>` elements for keyboard access.

| Rounded (`--radius-button`) | Square |
| --- | --- |
| Send, Stop, New conversation | Conversation rows and attention rows |
| Rename/Save, confirmation and input-panel actions | Session tabs and the buttons inside them |
| Drawer actions, Copy, Edit & retry, attachment Remove | Command-palette rows |
| Plugin component buttons, plugin manager actions | Notification list rows |
| Icon buttons: menu toggle, drawer close | Sidebar footer links (Triggers, Workspace status, About) |
| The "New output" jump button (was a 2rem pill) | Suggestion links, table-cell buttons in panels, "Older messages" |
| `/about/` call-to-action links (Run locally, See a plugin in action, Open Harness), its menu toggle and its copy buttons | `/about/` view tabs, cards, code blocks, badges |
| | Trigger occurrence rows |
| | Image-grid points (were circles; the hover highlight becomes a square cell) |

Rule of thumb: if it reads as a control, it is rounded. If it reads as a row,
a tab or a link, it is square, and so is its hover background.

### Details

- **Focus rings** follow the element's shape. Square elements get square
  rings, and buttons get rings that follow their small radius. That counts as
  "around buttons".
- **Native fields.** The reset covers text inputs, which WebKit rounds
  natively. Native selects round their corners in some engines, so every
  single-choice `select` uses `appearance: none` with the arrow drawn as a
  data-URI SVG background (`--select-chevron`). The rule comes last in the
  stylesheet so it wins over earlier select rules of equal specificity, and
  select rules set `background-color`, never the `background` shorthand.
  - **The chevron follows the theme.** A data-URI image cannot read CSS custom
    properties, so each palette carries its own `--select-chevron`, drawn in
    that palette's `muted` color.
- **Checkboxes and radios** stay native through `accent-color`. A radio's
  circle is the control's meaning, not a corner. Chrome keeps the native circle
  under the reset; if another engine squares it, exempt `input[type=radio]`.
- **The status dot** (`.local::before`) is a 6px square in `accent`.
- **Badges** (`.web_badge`, `.plugin_badge`, `/about/` totals) are square chips
  on `--soft`.
- **The user message** is a square block: `--user` background, `ink` text,
  right-aligned, `fit-content` width. The old blue bubble and its hard-coded
  colors are gone.
- **Shadows** are gone from the composer, drawers and the `/about/` hero
  panel. Floating layers (drawers, the notification center, the mobile sidebar)
  get a 1px `--edge` border. The exception is the conversation row menu
  (`.session_menu`), which uses `--shadow-menu`. The mobile overlay keeps its
  `box-shadow: 0 0 0 100vmax` scrim technique, colored by `--scrim`. That is a
  backdrop, not a shadow.

## Tokens

### Public tokens (plugin-overridable)

These are the existing seven, unchanged in name, so `ui_configure` and every
plugin keep working. This is the structured `^theme` API; custom plugin styles
can use and override additional CSS properties and tokens.

| Token | Role | Light | Dark |
| --- | --- | --- | --- |
| `surface` | Page, panels, fields | `#ffffff` | `#151515` |
| `sidebar` | Sidebar background | `#f7f7f7` | `#1b1b1b` |
| `soft` | Hover, selection, code, badges | `#efefef` | `#262626` |
| `line` | Dividers (decorative) | `#e5e5e5` | `#2f2f2f` |
| `muted` | Secondary text; Send hover fill | `#636363` | `#9c9c9c` |
| `ink` | Primary text; Send button fill | `#1c1c1c` | `#e7e7e7` |
| `accent` | Focus, links, selection border, status dot | `#1c1c1c` | `#e7e7e7` |

Every gray is pure neutral (R = G = B). The dark surface is not pure black, and
dark ink is not pure white. That reduces glare without losing contrast.

The default `accent` equals `ink`. The token stays separate so that a plugin
can still give its panel a hue, and so the role is named in the stylesheet.
Two rules make the neutral accent work:

- **Links are always underlined.** Color no longer separates a link from
  running text. `.markdown a` already does this; `/about/` links and any other
  inline link follow it.
- **No hover rule may change only `ink` to `accent`**: with the defaults, that
  hover is invisible. `.send:hover` switches its fill to `muted` instead.

### Additional host tokens (outside the `^theme` map)

These defaults are supplied by the host. Their absence from the seven-key
`^theme` API is an API distinction, not a restriction on trusted custom CSS.

| Token | Role | Light | Dark |
| --- | --- | --- | --- |
| `user` | User message block | `#ebebeb` | `#2b2b2b` |
| `edge` | Control boundaries: fields, composer, floating layers | `#858585` | `#777777` |
| `danger` | Errors, failed status, destructive actions | `#a8322b` | `#ef8b80` |
| `success` | Ready/passed status | `#2d6a38` | `#8fc89b` |
| `scrim` | Overlay behind the mobile sidebar | `rgb(0 0 0 / .2)` | `rgb(0 0 0 / .5)` |
| `select-chevron` | Select arrow, a data-URI SVG drawn in `muted` | per palette | per palette |
| `radius-button` | The only radius | `5px` | `5px` |
| `shadow-menu` | Conversation row menu | `0 5px 18px #0002` | same |
| `control-height` | Common action-button and dropdown height | `2.5rem` (40px) | same |
| `font-sans` | UI and prose text | `-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif` | same |
| `font-mono` | Code, commands, REPL input | `ui-monospace, SFMono-Regular, Menlo, Consolas, monospace` | same |

Single-line dropdowns use `--control-height` with border-box sizing, 5px left
padding and no vertical padding. Action buttons and the file chooser button use the same
minimum height and a 1.25 line height, so different local font sizes do not
make toolbar, filter and composer controls uneven. Buttons with multiple lines
can grow to fit their content; explicit select list boxes retain their list height.

- **`user`** is deliberately its own token rather than an alias of `soft`.
  Then the message block can be tuned without changing hover, code and badge
  backgrounds. It is a shade deeper than `soft`, so a user message stays
  distinct from a code block beside it.
- **`edge`** splits today's overloaded `--line`. `line` stays faint for
  dividers, where WCAG asks nothing. `edge` meets 3:1 wherever a border is the
  only sign of a control.
- **`danger`** replaces the accent-as-error usage and the plugin manager's
  literals.

### Aliases (derived, not themed)

`input-surface → surface`, `selected-surface → soft`, `code-surface → soft`,
`notice-surface → soft`, `action-ink → surface`. They are declared once in a
`:root, .ui_panel` rule:

- **`:root`** makes them exist on every page that links the theme, including
  the plugin manager and `/about/`. Neither page has an `.app` element.
- **`.ui_panel`** receives the `ui_configure` color overrides, so the
  aliases recompute from the overridden values there.

Custom properties inherit computed values. An alias resolved only at `:root`
would keep the host color inside an overridden panel.

`.send` stays `ink` fill with `action-ink` text, so it inverts correctly in dark
with no extra rule.

### Syntax colors

Keep today's formula, `color-mix(in srgb, <hue> 55%, var(--ink))`, and name the
five results `--syntax-string`, `--syntax-number`, `--syntax-keyword`,
`--syntax-callable` and `--syntax-type`, declared in the same `:root, .ui_panel`
rule as the aliases, so a panel's overridden `ink` reaches them. Because each
hue is mixed with `ink`, it darkens in light mode and lightens in dark mode with
no second palette. It also stays muted enough to sit inside a neutral UI.
Measured on `soft` (code background):

| | string | number | keyword | callable | type |
| --- | --- | --- | --- | --- | --- |
| Light | 7.76 | 6.16 | 6.90 | 6.70 | 6.84 |
| Dark | 5.99 | 7.16 | 6.58 | 6.74 | 6.68 |

### Measured contrast

WCAG ratios for the palettes. `accent` is identical to `ink` and is
omitted.

| Foreground | Light on surface / sidebar / soft / user | Dark on surface / sidebar / soft / user |
| --- | --- | --- |
| `ink` | 17.04 / 15.91 / 14.82 / 14.30 | 14.77 / 13.93 / 12.24 / 11.45 |
| `muted` | 6.01 / 5.61 / 5.22 / 5.04 | 6.65 / 6.27 / 5.51 / 5.16 |
| `danger` | 6.65 / 6.21 / 5.79 / 5.58 | 7.54 / 7.12 / 6.25 / 5.85 |
| `success` | 6.50 / 6.07 / 5.65 / 5.45 | 9.48 / 8.94 / 7.86 / 7.35 |
| `edge` (3:1 target) | 3.69 / 3.44 / 3.21 / 3.10 | 4.08 / 3.85 / 3.38 / 3.16 |
| `line` (decorative) | 1.26 / 1.18 / 1.10 / 1.06 | 1.36 / 1.29 / 1.13 / 1.06 |

Every text pairing clears 4.5:1, and `edge` clears 3:1 on every background.
The Send button measures 17.04 (light) and 14.77 (dark) for `surface` text on
its `ink` fill, and 6.01 / 6.65 on its `muted` hover fill.

## Source layout

Palettes are Gene data in `src/web/theme.gene`:

```gene
(var light_palette {^surface "#ffffff" ^sidebar "#f7f7f7" ^soft "#efefef"
  ^user "#ebebeb" ^line "#e5e5e5" ^edge "#858585" ^muted "#636363"
  ^ink "#1c1c1c" ^accent "#1c1c1c" ^danger "#a8322b" ^success "#2d6a38"
  ^scrim "rgb(0 0 0 / .2)"})
(var dark_palette {...})
(const public_tokens ["ink" "muted" "line" "surface" "sidebar" "soft" "accent"])
(var theme_css (render_css theme_styles))
```

`theme_styles` builds the token blocks with the `$css` DSL (dynamic custom
property names use `$css/decl_value`, since `decl` quotes its name). The
module also exports `theme_mode`, which maps anything but `"dark"` to
`"light"`, and `contrast_ratio`, the WCAG formula the guard spec uses.

The same data feeds several consumers:

- **The app and plugin manager stylesheets.** `src/web/style.gene` defines
  `styles` as `theme_css` followed by `base_styles`.
- **`/about/`**, which links `theme_css` as its own stylesheet and whose rules
  use the host token names (see below).
- **Plugin theme validation.** `src/ui/state.gene` checks override keys against
  `public_tokens`; the browser's copy of the list is `theme_tokens` in
  `client/ui/theme.gene`.
- **The guard spec** (`tests/unit/web/theme_spec.gene`), which checks contrast
  for every pairing in the tables above.

No host stylesheet contains a hex literal outside `theme.gene`. The only
`border-radius` declarations are the resets, the button rule, the square
exceptions and the four `/about/` controls.

Generated shape:

```css
:root {                                   /* light, the default */
  color-scheme: light;
  --surface: #ffffff; /* … */
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --surface: #151515; /* … */
}
```

There is no `prefers-color-scheme` block. `color-scheme` still matters: it
switches native scrollbars, checkboxes, date inputs and `select` popups to
match the theme.

## Choosing a mode

### Modes

| Mode | Behavior |
| --- | --- |
| `light` | Default. Used whenever no choice is recorded. The OS preference is ignored. |
| `dark` | Always dark. |

### Where the choice lives

The choice lives in a small host-owned file, `<state_root>/appearance.gene`,
holding serde data `{^mode "dark"}`. `src/runtime/appearance.gene` owns it:
the runtime service graph owns it under `services/values/appearance` in both
normal and metadata-recovery startup. `appearance_mode` and `set_appearance`
receive that runtime and read or change its owned setting. It deliberately depends on nothing else:

- **Not the event store, `config.gene`, or plugin state.** Recovery startup
  (`open_runtime ^mode "recovery"` in `src/runtime/bootstrap.gene`) leaves the
  event store unopened and skips the configuration read. The recovery server
  must still find the mode, so the record cannot live in any of those.
- **Not workspace view state.** The Workspace UI plugin owns plugin-content
  overrides. Appearance is a host concern that must work with
  every plugin disabled.
- **Missing or invalid means light.** A missing file, a read error or an
  unknown mode renders `light`, so a damaged file cannot break a page.
- **Persist, then publish.** The setter writes the file with
  `$fs/write_text_atomic` under a gate. Only after that succeeds does it update
  the in-memory mode and publish an `AppearanceChanged` harness event. A failed
  write raises and leaves the file, the active mode and the bus untouched.

The mode is stored per workspace for now. This has three advantages:

- **No flash.** `page` runs per request, so the server passes
  `(appearance_mode runtime)` and the response already carries
  `<html id="harness_document" data-theme="dark">`; the first paint is right.
- **No new primitive.** The web profile has `$session_storage` but no
  `$local_storage`. Per-browser persistence would need a new web-profile
  primitive, or a cookie set through a host endpoint.
- **The Harness is single-user.** One person, one workspace: a workspace-level
  preference is the natural scope.

A per-browser override (a cookie the server reads at render time) can be added
later without changing the token model.

### Changing it

There is one host setter, reached through a host endpoint,
`POST /api/v9/appearance` with `{"mode": "dark"}`, on both the normal and the
recovery server, with the same same-origin and CSRF checks as other mutations.
It answers `{"mode": …}`; an unknown mode is a 400 `invalid_request`.
Everything else calls the same setter:

- **UI control:** a toggle button in the host control bar (`#theme_toggle` in
  `#ui_host`, beside Notifications). It is labeled with the mode it switches
  to ("Dark" or "Light"). The plugin manager page, which the recovery server
  also serves, has the same toggle in its `manager_actions` navigation. Two
  places to avoid:
  - The Workspace status drawer: its only opener, `status_button`, sits in
    `sidebar_tools`. That group stays parked in the hidden `sidebar_storage`
    when the sidebar plugin is disabled or omits it.
  - The sidebar footer, for the same reason.
- **Operator command:** `/theme light|dark`. `/theme` with no argument reports
  the current mode.
- **Registered function:** `set_appearance "dark"`, so the model and `/run` can
  switch it ("switch to dark mode").
- **CLI:** `command /theme dark` works through the generic command path.

Both are host-owned rows, contributed by `"core"` like `/cancel`, `/stop` and
`/restart`; the kernel reserves the `theme` command name. Disabling or
replacing plugins never removes them, and the toggle never depends on them.

### Live propagation

The server-rendered `data-theme` handles first paint. Two push messages keep
an open tab current:

- **On connection.** `add_peer` in `src/web/push.gene` sends a `status` frame
  (`host_status`) to every peer, safe or not, before `ready`. Its `appearance`
  field carries the current mode, and the client applies it whenever it accepts
  a status (the same freshness check as the rest of the status). This covers a switch made between rendering the
  page and opening its socket, and a tab that reconnects after missing a
  change.
- **On change.** The session service turns `AppearanceChanged` into an
  `appearance` message (`{^mode …}`) to every peer. It must not ride on
  `ui/state`: `send_frame` drops `ui/state` for safe peers, so `/ui/default`
  tabs would never update.

On either message, the client sets `data-theme` on the document element and
re-applies the plugin panel's overrides for the new mode. `$dom/element` looks
elements up by id, so `page` gives `<html>` the id `harness_document`, and the
client reads the initial mode from its `data-theme` (`dataset/theme`). No new
DOM primitive and no reload are needed.

**Accepted limitation (owner decision, 2026-10-17).** Use the existing message
flow without a separate appearance revision or cross-transport ordering
protocol. An older response may restore the previous mode in a tab until its
next update or reload; it does not change the persisted choice. The current contract accepts this race.

Pages without a push connection update on load:

- **The plugin manager** (`client/plugin_manager.gene`) uses fetch only. It
  takes the mode from its server-rendered page and from every catalog load
  (page load and Refresh); `GET /api/v9/plugins` includes `appearance` on both
  servers, as does the recovery server's status.
- **`/about/`** picks up the new mode on its next load.

### Which pages honor it

| Page | Behavior |
| --- | --- |
| `/` | Mode from the request, live updates. |
| `/ui/default` (normal server) | Redirects to `/?ui=default`: honors the mode with live updates, still ignores plugin overrides. |
| Plugin manager page | Honors the mode on load and Refresh and uses the shared `danger`, `success` and `edge` tokens. |
| Recovery server (`--recovery`) | Serves the plugin manager page for `/`, `/plugins` and `/ui/default` (`src/web/recovery.gene`). Reads `appearance.gene` directly and passes the mode to `plugin_page`. Offers the toggle through the same endpoint. |
| `/about/` (embedded) | Honors the mode on each load; see below. |
| Static website export | Always light. There is no workspace to read. |

## `/about/` as part of the Harness

`/about/` is treated like a plugin view: it consumes the host tokens and
geometry and owns no palette. It keeps its layout, its `$css` scoping
(`harness_site`) and its generated, content-addressed stylesheet. Only its
color and shape decisions move to the theme.

**Token mapping.** The site's 16 token declarations are deleted, and every use
is rewritten to the host token name. Rewriting the uses is required, not just
tidier. The site root already declares `--surface`, `--ink`, `--muted` and
`--line`, so a mapping like `--ink: var(--ink)` there would be a cycle (invalid
at computed-value time). A local `--surface: var(--soft)` would also silently
change every other site rule that reads `--surface`. A custom property never
looks past a local declaration to the ancestor's value of the same name.

| Site token (uses rewritten) | Host token |
| --- | --- |
| `--paper`, `--panel` | `surface` |
| `--surface`, `--code-bg` | `soft` |
| `--ink` | `ink` |
| `--ink-soft`, `--muted` | `muted` |
| `--line`, `--code-line` | `line` |
| `--line-strong` | `edge` |
| `--blue`, `--focus` | `accent`; links are underlined |
| `--blue-dark` (hover) | `muted` |
| `--teal`, `--teal-ink` (eyebrows, highlights) | `ink` with weight or uppercase, not hue |
| `--teal-soft` | `soft` |
| `--sans`, `--mono` | `font-sans` (new host token, today's `:root` font stack), `font-mono` |

**Other changes.**

- **Hard-coded colors are gone.** The literal `#ffffff` text on blue buttons is
  now `action-ink` on `ink`. The translucent header background is solid
  `surface`. The hero shadow is removed.
- **Footer.** The ink-colored footer with light text became a `sidebar`-colored
  band with a `line` rule and ordinary `ink`/`muted` text, so it needs no
  inverted palette.
- **Code highlighting.** Code samples use the same `--syntax-*` tokens as the
  transcript.

**Rendering.** The server renders the embedded page once per mode at startup
(`about_pages` in `src/web/server.gene`) and picks one per request from the
current mode. The website now reads exactly one piece of workspace state, the
mode. It still needs no session, and the mode is not sensitive.

**Theme stylesheet.** The page links `theme_css` as a second generated
stylesheet (`gene-harness-theme`), which the static export publishes too.

**Website excerpt.** The page's "styles are `$css` data" example
(`site_excerpts/css`) is the narrow-screen media block of
`src/website/style.gene`, which the move left unchanged.

## Content-Security-Policy

Harness pages send no Content-Security-Policy. Inline styles, external
resources, connections and framing follow the browser's ordinary rules.
The host retains cache-control: no-store, nosniff and no-referrer headers.
This reflects the owner's decision to trust the Harness and its plugin code.
Deliberately loaded page libraries share that page's access.

Mutations still use same-origin and CSRF admission. The workspace image route
keeps its own sandbox policy and rejects scripted SVG content; an image opened
directly must not gain the Harness page's script access. This route-specific
policy does not restrict plugin style contributions.

Component validation is a separate contract: removing page CSP does not add a
style prop to quoted component trees. Plugin CSS uses the declared styling API
and its normal generation diagnostics, without a CSS security sandbox.

## Plugin color overrides

`ui_configure ^theme` accepts explicit light/dark token maps:

```gene
(ui_configure {^^enabled ^layout "panel" ^panel "project_board"
  ^theme {^light {^accent "#335577"} ^dark {^accent "#9db4d6"}}})
```

- **Maps are per mode.** A flat map is refused when configuring the UI.
  A mode without overrides uses the host palette. Previously stored flat maps
  are ignored by the browser and must be reapplied with explicit mode keys.
- **Validation per entry**: the seven public keys, six-digit hex
  values. `validate_theme` in `src/ui/state.gene` also rejects a map that mixes
  mode keys with token keys.
- **Application.** `theme_overrides` (`client/ui/theme.gene`) picks the map for
  the current mode, and the router's `layout` applies it to the panel as inline
  custom properties whenever it runs, including after every accepted `status`
  and every `appearance` message (`set_appearance` in
  `client/ui/controller.gene`).
  - **Always reset first.** `layout` clears all seven properties, then sets
    those the mode's map defines, so switching to a mode with no or partial
    overrides leaves no stale colors behind.
- **Contrast.** Keep the automated checks for host palettes. Custom plugin
  colors are an authoring decision and are not rejected on contrast grounds.
- **Shared control geometry is the default.** Plugin styles can customize
  layout, spacing, sizing and other presentation details. Authors are
  responsible for intentional changes to control shapes or focus styling.

## Plugin styling: defaults and customization

### No or minimal CSS for ordinary views

The host must provide documented default styles for supported headings, text,
links, buttons, forms, tables, lists, badges, notices and code blocks. Reusable
layout primitives should cover common rows, stacks, grids and spacing. A plugin
using these controls and primitives should look complete in light and dark mode
without supplying a stylesheet or repeating the host's colors, fonts, borders
and interaction states. Built-in variants should cover common needs such as
compact tables and secondary actions.

This is a requirement for the shared component styles as well as the palette.
Color tokens alone do not provide a usable plugin UI. When several plugins need
the same missing style or primitive, add it to the shared UI layer.

**Implemented.** The "Plugin content defaults" block at the end of
`src/web/style.gene` styles headings, paragraphs, lists, links, code,
preformatted text, rules, progress bars and summaries inside `.plugin_component`
and `.ui_panel`, under `:where()` so they have zero specificity and any plugin
rule wins. Forms and tables in views keep their existing `.ui_panel` rules. The
shared classes are `web_card`, `web_stack`, `web_row`, `web_spread`, `web_grid`,
`web_tight`, `web_loose`, `web_actions`, `web_badge` (with `_danger` and
`_success`), `web_notice` (with `_error` and `_success`), `web_metric`,
`web_muted`, `web_danger_text`, `web_success_text`, `web_table_compact`, and the
button variants `web_primary`, `web_secondary` and `web_danger`. The [Styling
section of the component contract](web-components.md#styling) documents them
with an example that uses no custom CSS.

### A scoped customization path

A `web_components` row (any slot) may carry an optional `style`: `$css` node
data such as `(css (rule ".grid" (decl display "grid")))`. With inline styles
allowed (see [Content-Security-Policy](#content-security-policy)), the client
mounts the rendered CSS as a `<style>` element and replaces or removes it with
the component. No new Gene syntax is involved.

**Descriptor and validation.** `validate_web_component` in
`src/ui/components.gene` renders the style when the row is contributed:

- **Scoped by default.** It wraps the data in `$css/scoped` labeled
  `plugin_<name>` and stores the rendered text as `style_css` and the scope
  class as `style_class` (for example `plugin_board__3f…`).
- **Page-wide on request.** `^!style_scoped` renders the data as given, with an
  empty `style_class`.
- **Errors.** Data that `$css/render` rejects, or a result over 64 KiB, fails
  the contribution with a component error naming the cause.

**Delivery.** Slot components carry `style` and `style_class` in the status
payload's `web_components`; view descriptors carry them in `ui/state`. The page
shell has a hidden `#plugin_styles` container. `sync_plugin_styles` in
`client/main.gene` keeps one `<style data-component="…">` per contribution
there and rewrites the set only when it changes. The scope class goes on the
component's wrapper: the `.plugin_component` div for slots, `#ui_view` for the
active view, and `#sidebar_view` for a `conversation_sidebar` replacement.

**Trust model.** Plugins are trusted code whose authors know what they are
doing. Use the existing `$css` renderer and scoping helpers. Do not build a
sanitizer, selector/property allowlist, or containment mechanism to stop a
plugin from deliberately reaching outside its view or changing host styling.

Plugins should first use shared components and public theme tokens, then add
only the styles their particular view needs. For example, a spreadsheet can
inherit themed inputs, buttons and cell text while supplying its own column
widths, sticky headers, selection layout and viewport sizing.

Scope contributions to their owning view/component by default using
`$css/scoped`. This is a convenience for avoiding accidental selector
collisions, not an isolation guarantee. Authors can deliberately use broader
rules when their integration needs them, without an additional approval flow.

Recommend the active theme's tokens and shared controls for ordinary UI, with
plugin-specific values for specialized visuals. Keeping custom views readable
and usable in both modes is the plugin author's responsibility.

Styles follow their owning contribution's lifecycle: replacement updates them,
removal or disablement removes them, and recovery views omit them along with
plugin color overrides (a safe status carries no components, and the client
mounts no styles in `/ui/default`).

### What the theme does and does not include

| Area | Provided by the host | Plugin responsibility / extension |
| --- | --- | --- |
| Shared appearance | Light/dark mode, semantic UI colors, default typography, borders, control shapes, focus and interaction states | Use the defaults, select variants/token overrides, or customize with CSS when the view needs it. |
| Common UI structure | Styled standard controls and reusable row, stack, grid and spacing primitives | Compose those primitives into the view. |
| Specialized layout | Theme-compatible building blocks | Spreadsheet column sizing, timeline tracks, chart layout, custom density, sticky regions and view-specific responsive behavior; use scoped styles where required. |
| Domain visuals | Shared colors where their meaning fits | Chart series colors, diagram legends, document/media content and other domain-specific visual values. These are not automatically part of the host palette. |
| Behavior and content | Existing component interaction contracts | Application data, business behavior and keyboard/accessibility behavior for newly introduced custom widgets. Styling alone does not implement a widget. |

Keep this boundary in the plugin author documentation so authors can tell
whether to use a host primitive, add a small scoped style contribution, or
propose a reusable addition to the shared UI layer.

## Theme foundation (proposed)

Proposed 2026-11-04. Nothing in this part is implemented.

The aim is a system in which the visual design is a set of values: a theme. A
designer produces the `default` theme, and the owner keeps the current look as
`minimal`, by changing values rather than restructuring the shell. Plugin
structures follow whichever theme is active. Users choose among installed
themes in each browser, and later duplicate one and customize the copy. The
current theme already treats color this way. This part extends that to every
other visual decision: fonts, icons, layout, responsiveness, user preferences
and plugin-defined structures.

### Where the current theme stands

The palettes are a good base: colors are data, both modes are complete, and a
spec guards contrast. Every other visual decision is still written inline in
about 500 lines of CSS text. Measured in `src/web/style.gene` on 2026-11-04:

| Dimension | Distinct values | Notes |
| --- | --- | --- |
| `font-size` | 27 | `.63rem` to `1.9rem`; `.8rem` ×15, `.78rem` ×13, `.75rem` ×8 |
| `padding` | 82 | |
| `margin` | 66 | |
| `gap` | 21 | |
| `line-height` | 11 | |
| `letter-spacing` | 7 | |
| `font-weight` | 6 | 400, 450, 500, 550, 600, 650 |
| `z-index` | 5 | 1, 3, 5, 6, 20; the spotlight plugin uses 1000 |
| Viewport breakpoints | 5 | app 760/900/901, website 760/960, plugin manager 760, spotlight 480; the client hard-codes 900 |

Other findings:

- **The guard enforces the look instead of the system.**
  `tests/unit/web/theme_spec.gene` asserts that every radius is `0` except the
  `button` rule and four `/about/` controls. A designer who wants rounded cards
  must first rewrite the test. The spec should require radius tokens and leave
  the values to the theme.
- **The root font size is pinned.** `:root { font-size: 16px }` overrides the
  reader's browser text-size setting, so every `rem` ignores it.
- **Layout widths are in px**: 232px sidebar, 760px content, 320px and 440px
  drawers, 220px menu, 76px top bar. They do not grow with text size.
  `--content-width` is declared in `base_styles`, not in the theme.
- **The no-shadow rule has drifted.** `--shadow-menu` (`0 5px 18px #0002`) is
  one value for both modes, and 13% black barely shows on the dark surface.
- **One literal font stack.** `.command_output` repeats the mono stack instead
  of using `var(--font-mono)`.
- **The narrow layout is split across two breakpoints.** The sidebar becomes an
  overlay at 900px (client and CSS), but its overlay styling (`.close_menu`,
  `.brand` padding, 40px row heights) only starts at 760px. Between 761px and
  900px the overlay's Close button keeps default button chrome. Four rules in the
  first 760px block repeat what the 900px block already does.
- **Built-in plugins invent their own tokens.** `src/builtin/spotlight.gene`
  ships a stylesheet with a 7px radius, two box shadows, px font sizes, a `#0005`
  backdrop, a hex fallback on every token (`var(--accent, #2463eb)`) and its own
  `[data-theme=dark]` block. It needs a dialog, an active list option and
  keyboard hints, and the theme has no tokens for any of them. The literal scan
  does not cover plugin stylesheets, so nothing flagged it.
- **Plugin views respond to the viewport, not to their own box.** A view docked
  at 25% of a 1440px window is 360px wide, but no media query fires.
- **A mode cannot apply to part of a page.** The dark palette is declared only
  on `:root[data-theme="dark"]`. So the two modes cannot be shown side by side,
  and a region cannot stay dark on its own.
- **`$css` has no `@container`, `@layer`, `@supports` or `@font-face` node.**
  Host CSS is text and can use them; plugin styles, which are `$css` data,
  cannot.
- **No webfont path.** Only system font stacks work; no route serves font files.

### System and theme

| | System | Theme |
| --- | --- | --- |
| Defines | Token names and roles, which rules read which token, the icon names, the shell structure and region names, breakpoint names, cascade layers, accessibility floors for built-in themes | Every value: palettes, fonts, type scale, spacing scale, radii, borders, shadows, motion, layout sizes, icon drawings, and any extra CSS |
| Owner | Host; changes are reviewed because plugins and themes depend on the names | The theme's author: the designer for `default`, the owner for `minimal`, a plugin or a user for theirs |
| Lives in | Stylesheet modules under `src/web/style/` | Built-in themes in `src/web/themes/<name>.gene`; plugin `themes` rows; the user theme library |
| Checked by | The guard spec: rules use tokens | Built-in themes: contrast floors in the guard spec. Other themes: the specimen and editor show ratios without enforcing them. |

Nothing in the system fixes a visual choice. Square corners, the neutral
palette, the 5px button radius, underlined links and the near-absence of
shadows are values of `minimal`. The `default` theme may choose differently.

### Token tiers

1. **Scales.** Raw steps: the spacing scale, the type scale, gray ramps. Rules
   may use spacing and type steps directly. Color ramps are private to the
   theme, and rules use color roles only.
2. **Roles.** The public contract that host rules, plugin styles and
   `ui_configure ^theme` use: `--surface-raised`, `--radius-field`,
   `--type-small`, `--layer-dialog`.
3. **Component tokens.** Optional hooks that a single component reads with a
   role fallback, such as `--message-user-surface` or `--board-lane-surface`.
   The host adds them only where a designer needs to tune one component apart
   from its role. Plugins use them to make their own structures themable (see
   [Extensibility](#extensibility-plugin-defined-structures)).

Names are kebab-case CSS custom properties, `--<group>-<role>[-<variant>]`.
Gene theme maps use snake_case keys (`^radius_field`), and the generator
converts `_` to `-`, as `$css` `decl` already does.

### Color

The current twelve palette entries become roles. `sidebar` and `user` describe
one component each, so they become component tokens. The new roles fill gaps
that host rules or plugins currently cover with literals.

| Role | Use | Today |
| --- | --- | --- |
| `surface` | Page, panels | `surface` |
| `surface-alt` | Secondary regions: sidebar, card headers, the `/about/` footer | `sidebar` |
| `surface-raised` | Menus, drawers, dialogs, popovers | `surface`, written per rule |
| `soft` | Hover, code, badges | `soft` |
| `selected` | Selected row, tab or option | alias `selected-surface` |
| `line` | Decorative dividers | `line` |
| `edge` | Control boundaries, floating-layer borders | `edge` |
| `ink`, `muted` | Primary and secondary text | same |
| `accent` | Links, active markers, the status dot | `accent` |
| `action`, `action-ink` | Primary button fill and its text | `ink` fill, alias `action-ink` |
| `focus` | Focus rings | `accent` |
| `danger`, `success`, `warning`, `info` | Status text and rules | `danger`, `success`; `warning` and `info` are new |
| `danger-surface` and the three other status surfaces | Tinted notice and badge backgrounds | none; notices are `soft` with a colored rule |
| `scrim` | Overlay backdrop | `scrim` |
| `series-1` … `series-8` | Categorical data colors for charts, legends and diagrams | none |
| `syntax-*` | Code | derived from `ink`, unchanged |

**Links** read `link-color` (default `accent`) and `link-decoration`. In
`minimal`, `link-decoration` is `underline`, because its accent equals its ink.
A theme that drops the underline needs a link color with 3:1 contrast against
the surrounding text (WCAG 1.4.1).

Floors for the built-in themes, checked in both modes. Plugin and user themes
see the same ratios in the specimen and the theme editor, which never refuse a
value.

- Text roles reach 4.5:1 on every surface role they appear on.
- `edge` and `focus` reach 3:1 on every surface.
- Each `series-*` color reaches 3:1 on `surface` (WCAG 1.4.11, graphical
  objects).
- `action-ink` reaches 4.5:1 on `action` and on the action's hover fill.

`ui_configure ^theme` accepts any color role, plus the tokens the view's own
plugin declares (see [Extensibility](#extensibility-plugin-defined-structures)),
instead of the current seven.

### Typography

- **Families**: `font-sans`, `font-mono`, and a new `font-display` for
  headings, which defaults to `font-sans`.
- **Root size**: `100%`, so the browser's text-size setting and the user's
  text-size preference (below) scale everything measured in `rem`.
- **Weights**: `weight-regular` (400), `weight-medium` (550) and `weight-bold`
  (650) replace the current six. With system fonts, 550 renders as an
  intermediate weight only where the font is variable.
- **Size scale.** Eight steps absorb the current 27 values:

| Step | Value | Absorbs | Typical use |
| --- | --- | --- | --- |
| `text-2xs` | `.68rem` | .63, .65, .68, .7 | Section labels, tab subtitles, hints |
| `text-xs` | `.75rem` | .72, .75, .78 | Metadata, run status, footer links |
| `text-sm` | `.82rem` | .8, .82, .85 | UI rows, conversation names, drawers, tables |
| `text-md` | `.94rem` | .88, .9, .92, .94, .95 | Transcript body, composer, markdown |
| `text-lg` | `1.05rem` | 1, 1.05, 1.1 | Small headings |
| `text-xl` | `1.2rem` | 1.15, 1.2, 1.25 | Section headings, glyph buttons |
| `text-2xl` | `1.4rem` | 1.4, 1.65 | Brand, page headings |
| `text-display` | `clamp(1.8rem, 2.7vw, 2.4rem)` | 1.8, 1.9, the clamp | Empty-state headline |

- **Roles.** Each role is one `font` shorthand token, so a rule writes
  `font: var(--type-body)`. Tracking (letter spacing) is a separate token
  because `font` cannot carry it.

| Role | Today's equivalent |
| --- | --- |
| `type-body` | `.94rem/1.75` transcript and markdown |
| `type-ui` | `.82rem/1.6` controls and rows |
| `type-small` | `.75rem` metadata |
| `type-label` | `.68rem` uppercase section labels, with `tracking-label` (`.07em`) |
| `type-title` | `.88rem`, weight 550, the top-bar and drawer titles |
| `type-heading-1` … `type-heading-3` | Markdown and plugin headings, with `tracking-tight` |
| `type-display` | The empty-state headline |
| `type-code` | `.82rem/1.7 var(--font-mono)` |

#### Web fonts

A theme can bring its own typefaces. Each font entry names a family, a file,
and the descriptors `@font-face` needs:

```gene
^fonts [{^family "Inter" ^src "fonts/InterVariable.woff2" ^weight "100 900" ^style "normal"}
        {^family "Inter" ^src "fonts/InterVariable-Italic.woff2" ^weight "100 900" ^style "italic"}]
^tokens {^shared {^font_sans "Inter, -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif"}}
```

- **Bundled files.** A relative `src` names a file that ships with the theme:
  `assets/fonts/` in the repository for built-in themes, or the plugin's
  package for a plugin theme. The host publishes each file under a
  content-addressed URL, as it does for stylesheets. It sends the font MIME type
  and a long cache lifetime, which is safe because the URL changes with the
  content. WOFF2 is the expected format. A plugin theme prepares its files with
  a new `$web/font` while constructing its descriptor, as spotlight does with
  `$web/stylesheet`. Bundled fonts work offline.
- **External URLs.** An `https:` `src` is used as given. It needs the network
  and reveals each page load to the font host. That is the theme author's
  choice; pages send no CSP, so nothing blocks it.
- **Rendering.** The generator emits one `@font-face` per entry, with
  `font-display: swap` unless the theme says otherwise. `$css` gains a
  `font_face` node so plugin and user themes can write font rules too. `page`
  adds `<link rel="preload" as="font" crossorigin>` for the face that the
  active theme's `font-sans` names, if any, so the first paint rarely shows a
  swap. A theme inherits its parent's font entries, but a browser downloads a
  face only when a family token uses it.
- **Fallbacks.** Every family token keeps a system stack after the web face. A
  theme may add metric overrides (`size-adjust`, `ascent-override`) on a local
  fallback face, which reduces layout shift when the web face arrives.
- **Licenses.** A bundled face needs a license that allows redistribution, such
  as the SIL Open Font License. Its license file ships beside the font files.
- **Recovery.** The recovery server serves the built-in themes' fonts without
  loading any plugin.

### Spacing and density

- **Scale**: `space-1` `.25rem`, `space-2` `.5rem`, `space-3` `.75rem`,
  `space-4` `1rem`, `space-5` `1.25rem`, `space-6` `1.5rem`, `space-8` `2rem`,
  `space-10` `2.5rem`, `space-12` `3rem`.
- **Semantic spacing**: `gutter` (inline page padding: today 2.25rem, or 1rem
  when narrow), `stack-gap` (between blocks), `inline-gap` (between controls),
  `inset-control` (button padding), `inset-field`, `inset-surface` (cards,
  drawers).
- **Density.** Each step is declared as `calc(<base> * var(--density))` on
  `:root`, with the same calc on `control-height`. The theme sets `--density: 1`;
  the compact preference sets `.8` on the root element. Density applies to the
  whole page; a subtree that redeclares `--density` does not recompute the
  steps, for the same reason the aliases are declared on `.ui_panel`.
- **Rule**: margins, paddings and gaps in host CSS use a space token, `0` or
  `auto`.

Snapping 82 paddings to nine steps moves some elements by up to about 1px.
That is expected and is the point of the scale.

### Shape

| Role | Use | `minimal` |
| --- | --- | --- |
| `radius-control` | Buttons (renames `radius-button`) | `5px` |
| `radius-field` | Inputs, selects, the composer | `0` |
| `radius-surface` | Cards, drawers, menus, dialogs, code blocks, images | `0` |
| `radius-row` | Rows, tabs, and row-like buttons | `0` |
| `radius-chip` | Badges, the status dot | `0` |
| `radius-message` | The user message block | `0` |

The reset keeps `border-radius: 0`. Each component rule reads its role, and the
list of square exceptions under [Geometry](#the-rule) becomes rules that read
`radius-row`. The guard changes from "only `button` is rounded" to "every
radius is `0` or `var(--radius-*)`". Focus outlines follow `border-radius` in
current engines, so focus rings still match each shape.

### Borders and focus

- `border-width` (1px), `border-width-strong` (2px: the selected tab, the
  attention rail) and `rule-width` (3px: status rules on notices).
- Decorative borders use `line` and control borders use `edge`, as today.
- `focus-width` (2px), `focus-offset` (4px) and the `focus` color make up the
  single focus ring rule. The image-grid point keeps its inset ring by reading
  the same tokens with a negative offset.

### Elevation, layers and motion

- **Elevation**: `shadow-raised` and `shadow-overlay`, defined per mode. A dark
  shadow needs a much higher alpha, or `none` with an `edge` border. `minimal`
  keeps "lines, not shadows" by setting `none` everywhere except the menu.
- **Layers.** One z-index scale replaces the scattered numbers: `layer-raised`
  (1), `layer-sticky` (10, the host bar), `layer-overlay` (20, the mobile
  sidebar), `layer-drawer` (30), `layer-menu` (40), `layer-dialog` (50,
  spotlight), `layer-toast` (60). Plugin overlays use the same tokens, so they
  stack correctly without guessing 1000.
- **Motion**: `duration-fast` (100ms), `duration-base` (180ms) and
  `ease-standard`. `minimal` has no transitions; the tokens let another theme
  add hover and drawer motion. Under `prefers-reduced-motion: reduce`
  the system sets both durations to `0ms`. Animated mode switching stays a
  non-goal.

### Layout sizes

All in `rem`, so they scale with text size:

| Token | Today |
| --- | --- |
| `sidebar-width` | 232px → `14.5rem` |
| `content-width` | 760px → `47.5rem`; moves into the theme |
| `topbar-height` | 76px → `4.75rem` |
| `drawer-width`, `drawer-width-wide` | 320px / 440px → `20rem` / `27.5rem` |
| `menu-width` | 220px → `13.75rem` |
| `panel-min`, `main-min` | Docked minimums, 280px / 340px |
| `control-height` | `2.5rem`, unchanged |
| `touch-target` | `2.75rem` (44px), used under a coarse pointer |

### Icons

Today the UI uses text glyphs: `+`, `×`, `↓`, `⋯`. An icon set replaces them.
Like every other visual decision, the drawings belong to the theme.

- **The system owns the names.** Host markup uses a fixed vocabulary: `add`,
  `close`, `menu`, `more`, `send`, `stop`, `copy`, `search`, `settings`,
  `notifications`, `light`, `dark`, `chevron-down`, `chevron-right`,
  `arrow-down`, `check`, `success`, `warning`, `error`, `info`, `external`,
  `attachment`, `microphone`, `pin`, `edit`, `retry`, `delete`, `sidebar`,
  `plugin`, `trigger`. Plugins can add names.
- **The theme owns the drawings.** A theme's `^icons` map gives each name a
  one-color SVG on a 24×24 view box. The generator writes each drawing into a
  custom property as a data URI, `--icon-close: url("data:image/svg+xml,…")`.
  A theme that omits a name inherits that drawing from `default`.
- **Painted with masks.** Host markup and the component node render
  `<span class="icon" data-icon="close" aria-hidden="true">`. The system paints
  every icon with `background: currentColor` and
  `mask: var(--icon) center / contain no-repeat`, plus one generated rule per
  name that sets `--icon`. With masks, switching themes is purely a CSS change:
  - no markup changes and no sprite URL in client state;
  - no flash, and the recovery server needs nothing extra;
  - icons take the current text color, so they follow mode, hover and
    disabled states.

  The cost is one color per icon. Stroke width cannot be tuned from CSS either,
  so a theme that wants a different weight ships different drawings. An inline
  SVG sprite referenced with `<use>` would allow tuning the stroke, but the
  client would have to track the sprite URL of the active theme.
- **Sizes**: `icon-size` (`1.25em`), `icon-size-sm` and `icon-size-lg`. They
  are in `em`, so an icon scales with the text beside it.
- **Default drawings.** The designer picks an open-source set with a
  permissive license; Lucide (ISC), Phosphor (MIT) and Tabler (MIT) all fit.
  `minimal` inherits these drawings unless the owner picks a square-capped
  variant.
- **Plugins.** Component trees gain `(icon ^name "close")`. A plugin adds a name
  with an `icons` row, `{^name "board-lane" ^svg "<svg …>"}`. Its drawing is
  checked against the inert SVG subset that the workspace image route already
  enforces. A theme can redraw a plugin's icon by defining the same name.
- **Accessibility.** Icons are decorative (`aria-hidden`). A button whose only
  content is an icon needs an `aria_label`. Host buttons such as the menu
  toggle and drawer close already have one.

### Responsive

Three layers, in order of preference:

1. **Intrinsic layout first.** Flex wrapping, `repeat(auto-fit, minmax(…))`,
   `min()` and `clamp()` adapt without any query. `web_grid` already works
   this way. Most components need nothing more.
2. **Container queries inside regions.** A component's layout depends on the
   width of the region it sits in, not on the window.
3. **Viewport media queries only for the shell's arrangement and for input
   modality.**

**Shell breakpoints.** There are two named breakpoints, defined once as Gene data
in `theme.gene`. The app, the plugin manager and `/about/` all use them.
Breakpoints belong to the system, not to a theme: media queries cannot read
tokens, and the client must agree with the CSS.

| Name | Width | Shell |
| --- | --- | --- |
| `narrow` | ≤ 900px | The sidebar becomes an overlay with all of its overlay styling. A docked view stacks above the conversation. |
| `compact` | ≤ 760px | Phone gutters, drawers at full width, smaller empty state |

Media queries cannot read custom properties, so host rules that use a
breakpoint are generated from the constant. Spotlight's 480px query moves to
`compact`. The client's `narrow_sidebar?` must agree with
the CSS. A guard spec can check both against the constant today. A
`$dom/match_media` web-profile primitive would remove the duplicate number.

**Region containers.** Every region whose width is set by the shell becomes a
named `inline-size` container:

| Container | Element |
| --- | --- |
| `main` | `.workspace` |
| `view` | `#ui_view` |
| `sidebar` | `#sidebar_view` |
| `drawer` | `.drawer` |

Slot wrappers (`.plugin_component`) are not containers. An `inline-size`
container cannot take its width from its content, so a toolbar component would
collapse to zero width. Components in slots query the enclosing region instead.

**Plugin authors** get three container steps, which are documented constants
because queries cannot use custom properties either: `30rem` (phone-like),
`48rem` (two columns fit) and `64rem` (wide). `$css` gains a `container` node
that renders `@container` and is scoped like `media`:

```gene
(css
  (rule ".sheet_grid" (decl grid_template_columns "12rem repeat(6, 1fr)"))
  (container "view (max-width: 30rem)"
    (rule ".sheet_grid" (decl grid_template_columns "1fr"))))
```

**Shared responsive structures**: `web_split` (two panes that wrap below their
basis, intrinsic), `web_scroll_x` (horizontal scrolling for wide tables, the
plugin counterpart of `.table_scroll`).

**Input modality.** Under `(hover: none), (pointer: coarse)`, controls and rows
use `touch-target` as their minimum height. Actions that are revealed on hover
stay visible, as `.session_more` already does.

**Accessibility floors**: reflow without horizontal page scrolling at 320 CSS
px (WCAG 1.4.10), usable at 200% text size, and the existing `forced-colors`
and `prefers-reduced-motion` blocks. The `max-height: 600px` landscape block
stays.

### Customization

Four parties customize different things:

| Who | Customizes | Through | Scope |
| --- | --- | --- | --- |
| Theme author | Every value | A built-in theme file, a `themes` row, or the theme editor | An installed theme |
| User | Theme, mode, density, text size and content width. Also dock side and width, docked or full view, sidebar shown, host bar shown | Settings → Appearance, the host toggle, `/theme`, `set_appearance`, host controls | Browser for appearance; tab for presentation (as today) |
| Plugin author | Their content and their regions (sidebar replacement, views, slots) and their view's colors | Components, `style`, `ui_configure ^theme`, component tokens | Their contributions, or page-wide if they choose |
| Host | The shell structure and the recovery path | The system | — |

**Appearance preferences, per browser:**

| Preference | Values | Effect |
| --- | --- | --- |
| `theme` | An installed theme name; `default` when unset | See [Themes](#themes) |
| `mode` | `light` (default), `dark` | `data-theme` |
| `density` | `comfortable` (default), `compact` | `--density` 1 or .8 |
| `text_size` | `small`, `default`, `large`, `larger` | Root font size 90%, 100%, 112.5% or 125% |
| `content_width` | `narrow`, `default`, `wide`, `full` | `--content-width` for the transcript and composer |

- **Storage.** The preferences are kept in a cookie, `gene_harness_appearance`,
  that the server reads when it renders a page. Auth cookies put the port in
  their names (`gene_harness_session_<port>`) because browsers share cookies
  across ports. This cookie deliberately has no port in its name. One choice
  therefore follows a browser profile across every Harness host on the same
  host name: all local workspaces and the manager. The value is a short
  URL-encoded field list plus a random browser id. Its attributes are
  `Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000`. The client never reads
  the cookie itself; it gets the values from `<html>` and from push messages.
- **Defaults.** A missing or invalid field falls back to its own default. A
  theme name that is not installed renders `default`. The cookie keeps the name,
  so the choice comes back if the theme is installed again.
- **Setting.** `POST /api/v9/appearance` takes any subset of the fields, with
  the same same-origin and CSRF checks as today. It answers with the resolved
  appearance and a `Set-Cookie`. The recovery server offers the same endpoint.
- **First paint.** `page` reads the cookie from the request. It renders
  `data-theme`, `data-density`, `data-text-size` and `data-content-width` on
  `<html>`, the active theme's stylesheet link and its font preloads. There is
  no flash, as today.
- **Live updates.** The WebSocket upgrade request carries cookies, so the push
  service records each socket's browser id. A change sends `appearance` only to
  the sockets of that browser. Other browsers keep their own choice.
- **`/theme`, `set_appearance` and the CLI** run on the server, where no browser
  is involved. They send `appearance` to every connected socket. Each tab
  applies it and stores it in its own cookie with the POST, which is harmless
  when several tabs of one browser repeat it. Browsers that are not connected
  keep their choice. The model reads the connected browsers' appearances from
  `(workspace .appearance)`, one entry per browser.
- **What goes away.** `<state_root>/appearance.gene` and the per-workspace mode
  are removed, with no migration. The recovery server reads the cookie like the
  normal server. `/about/` renders its `<html>` attributes per request instead
  of choosing one of two pre-rendered pages. The static export stays `default`
  and light. The statement in [workspace views](workspace-views.md) that
  cookies handle only authentication changes with it.
- **Settings → Appearance** becomes a section for this browser: a theme picker
  with previews, then mode, density, text size and content width. These are not
  setting definitions, since Settings scopes are workspace and shared. The
  section uses its own action, as the theme buttons do today.

**Is the layout customizable?** Yes, at four levels:

1. **Sizes are tokens.** A theme sets the sidebar width, content width,
   gutters and drawer widths.
2. **The user** chooses content width and density, and already controls dock
   side, dock width, docked or full view, sidebar visibility and host bar
   visibility per tab. A sidebar width handle, remembered per tab like the
   dock width, is a cheap addition.
3. **Plugins** already own region content: the replaceable conversation
   sidebar, views, and the `sidebar`, `toolbar`, `composer`, `status` and
   `welcome` slots.
4. **The shell structure is a documented contract.** A plugin with a page-wide
   style can already rearrange the grid. Documenting the hooks below lets such
   a plugin survive host changes.

Not recommended now: rearranging regions by drag and drop, or a layout editor.
Each movable region needs keyboard docking, persistence and a narrow-width
behavior for every arrangement. The shell has four regions and already offers
the useful arrangements: docked left, docked right, full, and sidebar hidden. If
more are wanted later, add them as named presets (`grid-template-areas` strings
in the theme), not as free-form docking.

**Shell hooks.** These are the stable surface for themes and page-wide plugin
styles:

| Hook | Element | Notes |
| --- | --- | --- |
| `#harness_root.app` | The shell grid, areas `host`, `sidebar`, `panel`, `main` | State classes: `sidebar_collapsed`, `menu_open`, `has_ui_panel`, `ui_full`, `ui_right` |
| `#ui_host` | Host bar | |
| `#classic_sidebar`, `#sidebar_view` | Sidebar region and its content root | |
| `#classic_workspace` (`.workspace`) | Conversation region: top bar, toolbar, transcript, composer | |
| `#ui_panel`, `#ui_view` | View region and its content root | |
| `.drawer` | Drawers | |
| `[data-component="<name>"]` | A contribution's wrapper | Slot wrappers have this today. `#ui_view` and `#sidebar_view` get it too; today they carry only the scope class. |
| `:root[data-theme]` and the preference attributes | Mode and preferences | |

Other class names are internal. They remain usable, but they may change
without notice.

### Extensibility: plugin-defined structures

**Why the theme must reach structures that plugins define:**

1. **Much of the product is already plugins.** The conversation sidebar,
   Settings, the model and provider screens, voice, spotlight and the workspace
   manager are all plugins, and response cards use the same vocabulary. A
   theme that cannot reach plugin structures cannot style the product.
2. **Plugins build structures the host never will**: boards, sheets, timelines,
   charts, game boards, palettes. When the user switches themes, these should
   follow (rounder corners, warmer grays, a new type scale) without their
   authors editing anything.
3. **Without roles, plugins hard-code values.** Spotlight is the evidence: its
   radius, shadows, backdrop and fallback colors already disagree with the
   current theme.
4. **Domain visuals need tuned values per mode.** Without `series-*`, every
   chart plugin chooses its own hues, and they clash with each other and with
   one of the two modes.

**How, in order of preference:**

1. **Use roles.** Plugin CSS reads role tokens only. Fallbacks such as
   `var(--surface, #fff)` never apply inside the Harness and can go. With the
   roles above, spotlight needs no literals and no dark-mode block:

   ```css
   /* today */
   .spotlight-backdrop { z-index: 1000; background: #0005; }
   .spotlight-dialog { background: var(--surface, #fff); border: 1px solid var(--line, #ccd2db); box-shadow: 0 16px 60px #0005; }
   .spotlight-option { padding: 9px 12px; border-radius: 7px; }
   .spotlight-option.active { background: var(--accent, #2463eb); color: var(--surface, #fff); }
   [data-theme=dark] .spotlight-dialog { background: var(--surface, #20242c); /* … */ }

   /* with roles */
   .spotlight-backdrop { z-index: var(--layer-dialog); background: var(--scrim); }
   .spotlight-dialog { background: var(--surface-raised); border: var(--border-width) solid var(--edge);
     border-radius: var(--radius-surface); box-shadow: var(--shadow-overlay); }
   .spotlight-option { padding: var(--space-2) var(--space-3); border-radius: var(--radius-row); }
   .spotlight-option.active { background: var(--action); color: var(--action-ink); }
   ```

2. **Promote shared structures.** When two plugins need the same structure, it
   becomes a host class, following the rule under [No or minimal CSS](#no-or-minimal-css-for-ordinary-views).
   The current candidates are `web_dialog` (backdrop and raised panel),
   `web_listbox` (option rows with an active state, used by spotlight and the
   command list), `web_field` (label, control, help and error), `web_tabs` and
   `web_split`.
3. **Component tokens, read with a fallback.** A plugin that wants a theme to be
   able to restyle its structure exposes tokens and reads each one with a role
   fallback:

   ```css
   .lane { background: var(--board-lane-surface, var(--soft));
           border-radius: var(--board-lane-radius, var(--radius-surface)); }
   ```

   The plugin never declares `--board-lane-surface` itself. A custom property
   uses the nearest declaration, so a value declared on the plugin's own element
   would shadow the theme's value on `:root`. This is the same trap described
   for `/about/` above. Reading with a fallback lets a theme set the token, per
   mode, and win. Names are `--<plugin id>-<part>-<property>`. The contribution
   lists them so they can be discovered:

   ```gene
   ^tokens [{^name "board-lane-surface" ^fallback "var(--soft)" ^doc "Lane background."}]
   ```

   The host lists declared tokens in the specimen view and in
   `(workspace .theme_tokens)`. A theme can set them, and so can
   `ui_configure ^theme` for the plugin's own view.
4. **Theme rules aimed at plugin markup.** As a last resort, a theme's `style`
   can target stable hooks such as `[data-component="board"] .lane`. This ties
   the theme to the plugin's markup, so use it only when a token cannot express
   the change.

**Modes for part of a page.** Emit each palette for `[data-theme="light"]` and
`[data-theme="dark"]` as well as for `:root`, and declare the derived tokens on
`[data-theme]` too, so that they recompute inside the subtree. Then any element
can force a mode. That allows a side-by-side specimen, a region that stays
dark, and theme previews. Component trees gain a `theme` attribute (values
`light` and `dark`) that renders as `data-theme`.

### Themes

A theme is data:

| Field | Meaning |
| --- | --- |
| `name`, `title`, `doc` | Identity shown in the picker |
| `extends` | The theme that fills in fields this one leaves unset; `default` when omitted |
| `tokens` | `{^shared {…} ^light {…} ^dark {…}}`: any scale, role or component token, with snake_case keys |
| `fonts` | Font entries; see [Web fonts](#web-fonts) |
| `icons` | Drawings by icon name; see [Icons](#icons) |
| `style` | Optional `$css` data for what tokens cannot express. It applies to the whole page. A theme's rules come after its parent's, which still apply. |

A token resolves from the theme first, then along its `extends` chain, then
from `default`. A theme states only what it changes, and a token added to the
system later always has a value. `src/web/theme.gene` keeps the generator, the
token names and `contrast_ratio`. The values move to theme files.

**Where themes come from:**

| Source | Lives in | Notes |
| --- | --- | --- |
| Built-in | `src/web/themes/default.gene`, `src/web/themes/minimal.gene` | Owned by the host, so they are available on the recovery server and with every plugin disabled. `default` is the designer's and starts with today's values. `minimal` extends it. |
| Plugin | `themes` rows | Re-publishing updates every tab that uses the theme. While the plugin is disabled or removed, those browsers render `default`. |
| User | The theme library (later) | Duplicates that the user edits; see below |

```gene
(host .PluginHost:contribute "themes"
  {^name "paper" ^title "Paper" ^extends "default"
   ^tokens {^shared {^radius_surface "6px" ^font_display "\"Iowan Old Style\", serif"}
            ^light {^surface "#fbfaf7" ^ink "#22201c"}
            ^dark {^surface "#1a1916" ^ink "#ece8e1"}}
   ^style (css (rule ".card_header" (decl background "var(--surface-alt)")))})
```

**`minimal` extends `default`.** `minimal` is the owner's personal theme. It
sets its own values for the choices that define it:

- every color role in both modes: pure grays, the accent equal to the ink, and
  the user message block color
- `link-decoration: underline`
- the radii: `radius-control` is `5px` and every other radius is `0`
- no shadows except the menu's, with a menu shadow for each mode
- `0ms` durations, so there are no transitions
- the system font stacks for `font-sans`, `font-mono` and `font-display`

Everything else comes from `default`: the type scale and roles, spacing and
density, border and focus widths, layers, layout sizes and the icon drawings.
A redesign of those reaches `minimal`, and so does any token the system adds
later. To keep a value through a redesign, the owner sets it in
`src/web/themes/minimal.gene`. `default` starts with today's values, so at
first `minimal` only restates them. The two diverge as the designer works.

**Applying a theme.**

- **One stylesheet per theme.** The generator renders the resolved theme into a
  single content-addressed stylesheet. It contains the token blocks for each
  mode, the `@font-face` rules, the icon properties and the theme's `style`.
  The host stylesheet of system rules is the same for every theme.
- **Cascade order.** `page` links the host stylesheet and then the active
  theme's. Plugin style contributions mount after both. The order is host
  rules, then theme rules, then plugin rules, and host rules sit in cascade
  layers, so a theme rule beats a host rule regardless of specificity.
- **Switching.** Changing theme in a tab replaces one `<link>`. The
  `appearance` message carries the new stylesheet URL.
- **Recovery** renders built-in themes only. A browser set to a plugin or user
  theme sees `default` there.

**Why a registry.** A designer iterates live with `register_plugin ^^replace`,
with no host restart. Users pick among installed themes in Settings →
Appearance, per browser. Once the design is settled, its values move into
`src/web/themes/default.gene`.

#### User themes: duplicate and customize (later)

- **Duplicate.** Each theme in Settings → Appearance has **Duplicate**. It
  creates a user theme holding a copy of the source's resolved tokens, font
  entries, icon drawings and `style`. Because it is a copy, later changes to
  the original do not reach it. Font files stay those of the source theme. If
  a plugin theme's fonts disappear with its plugin, the copy falls back to the
  system stack in its family token.
- **Editor.** A theme editor view groups the tokens:
  - color roles for each mode, with color pickers and live contrast ratios
  - fonts, the type scale and spacing
  - radii, borders and shadows
  - the theme's `style`, edited as `$css`

  The browser that is editing applies the theme as it changes, in the specimen
  and in the real app. Ratios are shown and never enforced.
- **Library.** User themes live with the shared settings, in
  `<manager root>/.gene-harness/themes/<name>.gene`. Every workspace and
  browser on the machine sees them, which matches a per-browser choice that
  follows the browser across workspaces. Saves use revision checks
  (`^expected`) like shared settings, and the library is reachable through the
  manager object.
- **Export.** A user theme can be exported as theme plugin source to share or
  commit. Uploading new font files for a user theme comes later; until then a
  user theme uses fonts from installed themes or external URLs.

### Designer workflow

1. **Edit values.** The fastest loop is a theme plugin reloaded with
   `register_plugin ^^replace`. When the design is settled, its values move into
   `src/web/themes/default.gene`.
2. **Review the specimen.** A built-in `theme` view, always available like
   Settings, renders the following in both modes side by side:
   - palette swatches with ratios from `contrast_ratio`
   - type roles, fonts and icons
   - samples of spacing, radius, border, elevation and layers
   - every shared `web_*` class
   - every button variant in its disabled and focus states
   - the host structures: user and agent messages, steps, execution blocks,
     source previews, cards, notices, drawers, menus and the composer
   - the tokens plugins have declared

   A theme picker in the view compares any installed theme against another.
3. **Check the real app** at widths 320, 390, 768, 1024 and 1440px. Cover:
   - views docked at 25%, 50% and 70% on both sides, and the full view
   - sidebar collapsed, and long titles
   - Recovery UI, the plugin manager and `/about/`
   - 200% text size, forced colors and reduced motion
   - `minimal` as well as `default`, since `minimal` takes whatever it does not
     set from `default`

   Resizing the window in browser automation can be unreliable. A same-origin
   `<iframe>` of the target width works, since pages send no CSP.
4. **Run the guards** with `../../bin/gene test` from `examples/gene-harness`.

**Guards.** These extend `theme_spec`. They lint host code and the built-in
themes. They do not restrict plugin or user themes.

- No color literal (hex, `rgb()`, `hsl()`) outside `src/web/themes/`. The scan
  covers built-in plugin stylesheets too.
- In host CSS, `font`, `font-size`, `padding`, `margin`, `gap`, `z-index`,
  `border-radius`, `box-shadow` and `transition` values are `0`, `auto`,
  `inherit`, a token, or a `calc()` of tokens. A short list names deliberate
  exceptions with their reasons, such as the image-grid insets.
- Host markup uses icons by name, never as text glyphs, and every name in the
  vocabulary has a drawing in `default`.
- Every viewport query uses a named breakpoint, and the client agrees with it.
- The color floors hold for `default` and `minimal` in both modes, checked on
  `minimal`'s resolved tokens.
- A built-in theme's `style` follows the token rule for values. A literal in
  `default`'s `style`, such as a fixed radius on cards, would reach `minimal`
  with no token for `minimal` to override.
- The specimen covers every shared `web_*` class.

### Plan

**Phase 1: tokens.** The look stays the same apart from the snapping noted
above.

- Add the type, spacing, shape, border, elevation, layer, motion and layout
  tokens at today's values, snapped to the scales. Move all values into
  `src/web/themes/default.gene`, and leave the generator in `theme.gene`.
- Add the theme format with `extends`, and `src/web/themes/minimal.gene` with
  the owner's values. Until Phase 3 moves appearance to the browser, the theme
  name sits next to the mode in the workspace appearance setting, so the
  owner's workspaces render `minimal` while the designer's render `default`.
- Rewrite `style.gene`, the plugin manager styles and the spotlight stylesheet
  to use the tokens. Set the root font size to `100%`, convert px widths to
  `rem`, fix the mono literal, move the overlay styling to `narrow`, delete the
  duplicate rules, and give the menu shadow a dark value.
- Split `base_styles` into modules under `src/web/style/` in the cascade layers
  `reset, base, shell, components, content, utilities`. Theme and plugin styles
  stay outside any layer, so they win over every host rule without `:where()`,
  and the "select rule comes last" ordering is no longer needed.
- Extend the guards.

**Phase 2: responsive structure and the specimen.**

- Add the named breakpoints and generate the media queries from them.
- Make the regions containers and add the `$css` `container` node.
- Support modes for part of a page, and add `data-component` on the view and
  sidebar roots.
- Add `web_dialog` and `web_listbox` (what spotlight needs), then `web_field`,
  `web_tabs` and `web_split`.
- Build the specimen view and add the touch-target rules.

**Phase 3: themes, fonts, icons and per-browser appearance.**

- Add the `themes` registry for plugin themes, and one stylesheet per theme.
- Store appearance, including the theme name, in the cookie, with live updates
  to the sockets of each browser. Remove `appearance.gene`, and add the theme
  picker and the new preferences to Settings → Appearance.
- Add web fonts: `$web/font`, the `$css` `font_face` node and preloads.
- Add icons: the vocabulary, mask rendering, the `icon` node and `icons` rows,
  and replace the glyphs in host markup.
- Add plugin component tokens, and widen `ui_configure ^theme` to every color
  role and declared token.

**Phase 4 (later): user themes.** Duplicate, the theme editor, the library in
the manager root, and export as plugin source.

The designer needs Phases 1 to 3: tokens, the specimen, and the registry with
fonts and icons. They can start on palettes, the type scale and spacing after
Phase 2, restarting the host to see each change. Phase 3 adds live reload,
fonts and icons.

### Open questions

1. **Server-side theme changes.** `/theme`, `set_appearance` and the CLI have
   no browser. The proposal above has every connected browser adopt the change.
   The alternative is to limit them to `default` preferences for browsers with
   no choice of their own, which would bring back a workspace-level value.
2. **Duplicate.** The proposal makes a duplicate a frozen copy. The alternative
   is a linked child that `extends` the original and follows later changes to
   it, the way `minimal` follows `default`.
   Both could be offered: Duplicate for a copy, Customize for a child.
