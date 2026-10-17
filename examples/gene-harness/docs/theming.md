# Theming

Status: proposal (2026-10-17). Only the [CSP removal](#content-security-policy)
is implemented.

The web UI gets square geometry, two minimalist neutral palettes, and a
host-owned light/dark setting. Light is the default; dark is an equal peer, not
an inverted afterthought. `/about/` follows the same theme as the rest of the
Harness. Plugins inherit usable styling with no or minimal CSS, keep their
public color overrides, and can contribute styles for presentation the host
does not provide. The host supplies visual defaults; trusted plugin authors
decide when to customize them.

## Decisions

Owner decisions, 2026-10-17:

| Question | Decision |
| --- | --- |
| Button radius | `3px` |
| Accent | Fully neutral: pure grays, and the accent is the ink color |
| User message | Square block whose color is a theme token (`user`) |
| Where the mode is stored | Per workspace, for now |
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

Non-goals: user-authored CSS, theming the terminal client, following
`prefers-color-scheme`, animated theme transitions, and defensive restrictions
intended to contain malicious plugin CSS. Plugin customization is in scope.

## Current state

Measured in `src/web/style.gene`, `src/web/plugin_page.gene` and
`src/website/style.gene`:

| Area | Today |
| --- | --- |
| Tokens | 7 color tokens on `:root` (`ink muted line surface sidebar soft accent`), light only, `color-scheme: light`. Five aliases (`input-surface`, `selected-surface`, `code-surface`, `notice-surface`, `action-ink`) are declared on `.app` and repeated on `.ui_panel`. |
| Radii | 38 `border-radius` declarations in the app and plugin manager, with 13 distinct non-zero values: 3–12px, 18px (user bubble), 2rem and 99px (pills), and 50% (status dot, image-grid points). `/about/` adds 20 more. |
| Hard-coded colors | User bubble `#163a63` on `#e6f1ff`. Shadows and scrims use `#292b27` with alpha (4 places). Five syntax hues. Plugin manager status uses `#982c25`, `#285b36` and `#a9b7a3`, plus `color: white`. Image-point hover uses `rgb(255 255 255 / .22)`. |
| Errors | `.run_error` and error notices use `--accent` (green). There is no danger color. |
| Field borders | `--line` `#e5e5de` on `#fcfcf9` measures 1.23:1. The composer and inputs rely on that border alone, so they fail WCAG 1.4.11 (3:1 for control boundaries). |
| Plugin themes | `ui_configure ^theme {...}`: a flat map over the 7 keys with six-digit hex values, applied to the plugin panel only (`client/ui/router.gene`). Validated in `src/ui/state.gene`. |
| `/about/` | Its own 16-token palette (warm paper, navy ink, blue links, teal highlights), hero shadows and 20 radii, written with the `$css` DSL and scoped to `harness_site`. Rendered once per server lifetime (`about_page` in `src/web/server.gene`). Also exported statically by `src/website/export.gene`. |

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

`--radius-button: 3px` is the only non-zero radius in the host theme. Everything
else has radius 0 by default. That includes inputs, textareas, selects, the composer,
cards, drawers, code blocks, inline code, images, badges, tabs, the user
message and the status dot.

The base stylesheet uses a reset plus one exception:

```css
*, *::before, *::after { border-radius: 0; }
button { border-radius: var(--radius-button); }
/* Buttons that read as rows, tabs or links stay square. */
.session, .session_tab button, .command, .notification_local,
.sidebar_footer button, .suggestions button, .ui_panel td button,
.older_messages, .web_image_grid > .web_image_point,
.view_tab { border-radius: 0; }
```

Then every other `border-radius` declaration is deleted. On `/about/`, links
styled as buttons (`.button`, `.nav_app`) take `--radius-button` explicitly,
because they are `<a>` elements. Its view tabs are `<button role="tab">`
elements, so they join the square exceptions.

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
| `/about/` call-to-action links (Run locally, See a plugin in action, Open Harness) and its menu toggle | `/about/` view tabs, cards, code blocks, badges |
| | Image-grid points (were circles; the hover highlight becomes a square cell) |

Rule of thumb: if it reads as a control, it is rounded. If it reads as a row,
a tab or a link, it is square, and so is its hover background.

### Details

- **Focus rings** follow the element's shape. Square elements get square
  rings, and buttons get rings that follow their small radius. That counts as
  "around buttons".
- **Native fields.** The reset covers text inputs, which WebKit rounds
  natively. Safari may still draw a rounded `select` while it has native
  appearance. If it does, use `appearance: none` with a small data-URI SVG
  chevron as the background image; no wrapper element is needed.
  - **The chevron must follow the theme.** A data-URI image cannot read CSS
    custom properties, so it needs one variant per mode, set in each mode's
    token block.
- **Checkboxes and radios** stay native through `accent-color`. A radio's
  circle is the control's meaning, not a corner. Verification must confirm the
  reset does not square them in any engine; if it does, exempt
  `input[type=radio]`.
- **The status dot** (`.local::before`) becomes a 6px square in `accent`.
- **Badges** (`.web_badge`, `.plugin_badge`, `/about/` totals) become square
  chips on `--soft`.
- **The user message** becomes a square block: `--user` background, `ink`
  text, right-aligned, `fit-content` width. The blue bubble and its hard-coded
  colors go.
- **Shadows** are removed from the composer, drawers and the `/about/` hero
  panel. Floating layers (drawers, the notification center, the mobile sidebar)
  get a 1px `--edge` border. The mobile overlay keeps its
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
| `radius-button` | The only radius | `3px` | `3px` |
| `font-sans` | UI and prose text | `-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif` | same |
| `font-mono` | Code, commands, REPL input | `ui-monospace, SFMono-Regular, Menlo, Consolas, monospace` | same |

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

WCAG ratios for the proposed palettes. `accent` is identical to `ink` and is
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

Palettes become Gene data in a new `src/web/theme.gene`:

```gene
(var light_palette {^surface "#ffffff" ^sidebar "#f7f7f7" ^soft "#efefef"
  ^user "#ebebeb" ^line "#e5e5e5" ^edge "#858585" ^muted "#636363"
  ^ink "#1c1c1c" ^accent "#1c1c1c" ^danger "#a8322b" ^success "#2d6a38"
  ^scrim "rgb(0 0 0 / .2)"})
(var dark_palette {...})
(var public_tokens ["ink" "muted" "line" "surface" "sidebar" "soft" "accent"])
(fn theme_css [] : Str ...)
```

`theme_css` builds the token blocks with the `$css` DSL, the same one `/about/`
already uses, and the result is prepended to `styles`.

The same data feeds several consumers:

- **The app and plugin manager stylesheets**, through the generated blocks.
- **`/about/`**, whose rules switch to the host token names (see below).
- **Plugin theme validation.** `public_tokens` replaces the literal key lists in
  `src/ui/state.gene` and `client/ui/router.gene`.
- **The guard spec**, which checks contrast for every pairing in the tables
  above.

After this change, no host stylesheet contains a hex literal. The only
`border-radius` declarations left are the reset, the button rule, the square
exceptions and the `/about/` button links.

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

Store the choice in a small host-owned file, `<state_root>/appearance.gene`,
containing `{^mode "dark"}`. It deliberately depends on nothing else:

- **Not the event store, `config.gene`, or plugin state.** Recovery startup
  (`open_runtime ^recovery true` in `src/runtime/bootstrap.gene`) leaves the
  event store unopened and skips the configuration read. The recovery server
  must still find the mode, so the record cannot live in any of those.
- **Not `ui_experiment` state.** That plugin is disabled by default and owns
  plugin-content overrides. Appearance is a host concern that must work with
  every plugin disabled.
- **Missing or invalid means light.** A missing file, a read error or an
  unknown mode renders `light`, so a damaged file cannot break a page.
- **Persist, then publish.** The setter writes a temporary file and renames it
  over the old one. Only after that succeeds does it update the in-memory mode
  and publish the change. A failed write returns an error and leaves the active
  mode unchanged.

The mode is stored per workspace for now. This has three advantages:

- **No flash.** `page` already runs per request (`src/web/server.gene` calls
  `(page)` for `/`). Passing the mode lets it render
  `<html data-theme="dark">` into the response, so the first paint is right.
- **No new primitive.** The web profile has `$session_storage` but no
  `$local_storage`. Per-browser persistence would need a new web-profile
  primitive, or a cookie set through a host endpoint.
- **The Harness is single-user.** One person, one workspace: a workspace-level
  preference is the natural scope.

A per-browser override (a cookie the server reads at render time) can be added
later without changing the token model.

### Changing it

There is one host setter, reached through a host endpoint,
`POST /api/v8/appearance`, with the same same-origin and CSRF checks as other
mutations. Everything else calls it:

- **UI control:** a Light / Dark toggle button in the host control bar
  (`#ui_host`, beside Notifications). The recovery server shows the plugin
  manager page, so the same toggle also goes in that page's `manager_actions`
  navigation. Two places to avoid:
  - The Workspace status drawer: its only opener, `status_button`, sits in
    `sidebar_tools`. That group stays parked in the hidden `sidebar_storage`
    when the sidebar plugin is disabled or omits it.
  - The sidebar footer, for the same reason.
- **Operator command:** `/theme light|dark`. `/theme` with no argument reports
  the current mode.
- **Registered function:** `set_appearance "dark"`, so the model and `/run` can
  switch it ("switch to dark mode").
- **CLI:** `command /theme dark` works through the generic command path.

The command and the function are conveniences over the host setter. If the
plugin that registers them is disabled, the toggle still works.

### Live propagation

The server-rendered `data-theme` handles first paint. Two push messages keep
an open tab current:

- **On connection.** `add_peer` in `src/web/push.gene` sends a `status` frame
  (`host_status`) to every peer, safe or not, before `ready`. That frame
  carries the current mode. This covers a switch made between rendering the
  page and opening its socket, and a tab that reconnects after missing a
  change.
- **On change.** The host broadcasts an `appearance` message to every peer. It
  must not ride on `ui/state`: `send_frame` drops `ui/state` for safe peers, so
  `/ui/default` tabs would never update.

On either message, the client sets `data-theme` on the document element and
re-applies the plugin panel's overrides for the new mode. `$dom/element` looks
elements up by id, so `page` gives `<html>` an id (for example
`harness_document`). That avoids adding a DOM primitive. No reload is needed.

**Accepted limitation (owner decision, 2026-10-17).** Use the existing message
flow without a separate appearance revision or cross-transport ordering
protocol. An older response may restore the previous mode in a tab until its
next update or reload; it does not change the persisted choice. Handling this
race is outside this milestone.

Pages without a push connection update on load:

- **The plugin manager** (`client/plugin_manager.gene`) uses fetch only. It
  takes the mode from its server-rendered page and from its existing Refresh
  action, whose status response includes the mode.
- **`/about/`** picks up the new mode on its next load.

### Which pages honor it

| Page | Behavior |
| --- | --- |
| `/` | Mode from the request, live updates. |
| `/ui/default` (normal server) | Redirects to `/?ui=default`: honors the mode with live updates, still ignores plugin overrides. |
| Plugin manager page | Honors the mode on load and Refresh. Its `#982c25`, `#285b36` and `#a9b7a3` literals become `danger`, `success` and `edge`. |
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

- **Hard-coded colors go.** The literal `#ffffff` text on blue buttons becomes
  `action-ink` on `ink`. The translucent header background
  `rgba(250, 248, 243, 0.95)` becomes solid `surface`. Both hero shadows are
  removed.
- **Code highlighting.** Code samples use the same `--syntax-*` tokens as the
  transcript.

**Rendering.** The embedded page is rendered once today; it would be rendered
once per mode instead. The server caches a light and a dark copy at startup and
picks one per request from the current mode. This changes one stated invariant
in `server.gene`: the website now reads exactly one piece of workspace state,
the mode. It still needs no session, and the mode is not sensitive.

**Theme stylesheet.** The page links the same generated theme stylesheet as
the app.

**Website excerpt.** The page shows an excerpt of `src/website/style.gene` as
its "styles are `$css` data" example (`site_excerpts/css`). After the move, that
excerpt shows the token mapping rather than the old palette.

## Content-Security-Policy

Status: done (2026-10-17), ahead of the rest of this proposal.

Harness pages send no Content-Security-Policy. `secure_response` in
`src/web/server.gene` used to add a strict default to every response from both
the normal and the recovery server:

```
default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self';
base-uri 'none'; frame-ancestors 'none'; form-action 'self'
```

That default is gone. Inline styles, `data:` images, external scripts, styles,
fonts and connections, framing and form targets are all unrestricted.
`secure_response` still sets `cache-control: no-store`, `nosniff` and
`no-referrer`.

**Why the default was removed.** The owner prefers flexibility for the Harness
and its trusted plugins. Libraries deliberately loaded into the page are also
trusted with that page's access. This is an accepted tradeoff; existing request
checks are not a replacement for every restriction the policy imposed.

The client builds component DOM node by node, and mutations retain their
same-origin and CSRF checks. `SameSite=Strict` restricts cross-site cookies but
does not isolate local applications on different ports of the same host.
[Site and origin definitions](https://web.dev/articles/same-site-same-origin).
`HttpOnly` prevents reading the cookie, while page scripts can still make
authenticated requests. [HttpOnly behavior](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie#httponly).

**What it unblocks.**

- **Plugin style contributions** can be `<style>` elements that the client
  mounts, replaces and removes with their owning view.
- **Small icons inline in CSS**, such as the `select` chevron, can be `data:`
  SVG backgrounds.
- **Experiments** can pull a library, font or stylesheet from a CDN without a
  policy change.

**What stays.**

- **The image route sandbox.** `/api/v8/ui/image` serves workspace files and
  keeps its own `sandbox; default-src 'none'; script-src 'none'; …` policy.
  This route-specific policy restricts nothing the Harness builds. Without it,
  an SVG in a workspace, which may come from a cloned repository or a model,
  could run script at the Harness origin with the owner's cookie when opened
  directly. The route also rejects SVGs containing `<script>`; the policy is
  the second layer.
- **No new style prop.** Component trees do not gain a `^style` prop: what the
  component validator accepts is a separate contract from what the browser
  allows.
- **Plugin styling remains a contribution API.** Check its descriptor and
  report generation errors normally. Use the existing CSS helpers without
  adding selector or property restrictions to contain trusted plugins.

**Coverage.** `tests/integration/web/images_transport_spec.gene` asserts that
`GET /` carries no CSP header and that the image route keeps its sandbox
policy.

## Plugin color overrides

Today `ui_configure ^theme` is a flat map, applied to the plugin panel. A light
color like `#335577` would be unreadable on a dark surface, so overrides become
per-mode:

```gene
(ui_configure {^^enabled ^layout "panel" ^panel "project_board"
  ^theme {^light {^accent "#335577"} ^dark {^accent "#9db4d6"}}})
```

- **A flat map is read as `^light`**, so existing configurations keep their
  meaning. In dark mode a panel with no `^dark` map uses the host dark palette.
  That is safer than applying light colors to a dark surface.
- **Validation is unchanged per entry**: the seven public keys, six-digit hex
  values.
- **Application.** The router applies the map for the current mode to the panel
  as inline custom properties, as it does today, and re-applies on every
  `status` or `appearance` message.
  - **Always reset first.** It clears all seven properties, then sets those the
    mode's map defines. This keeps today's reset-every-key behavior in
    `client/ui/router.gene`, so switching to a mode with no or partial
    overrides leaves no stale colors behind.
  - **The flat-map-as-light rule ships with dark mode** (rollout step 3), not
    after it. Otherwise one release would paint saved light overrides on dark
    panels.
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
Color tokens alone do not provide a usable plugin UI. Document which elements,
classes or component options have this support, with a small example that uses
no custom CSS. When several plugins need the same missing style or primitive,
add it to the shared UI layer.

### A scoped customization path

Provide an optional style contribution attached to a plugin view or component,
using the existing Gene `$css` DSL. With inline styles allowed (see
[Content-Security-Policy](#content-security-policy)), the client can mount the
generated CSS as a `<style>` element owned by the view, and replace or remove
it with the view. This is a new Harness contribution contract; the current
component validator does not accept arbitrary styles. Define its descriptor,
basic type checks and lifecycle alongside the view API, without introducing
new Gene syntax.

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
plugin color overrides. Document the descriptor, scoping helper and lifecycle,
and report malformed contribution data or CSS generation errors clearly.

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

## Verification

- **Guard spec, part 1.** Every `border-radius` value in `src/web/style.gene` and
  `src/web/plugin_page.gene` is `0` or `var(--radius-button)`, and
  `var(--radius-button)` appears only in the `button` rule. For `/about/`, the
  spec walks the `site_styles` data, which is plain Gene data: a
  `border_radius` declaration is allowed only on the `.button` and `.nav_app`
  rules.
- **Guard spec, part 2.** Host stylesheets keep shared UI color literals in
  `theme.gene`. Plugin token overrides and domain-specific visual values use
  their documented extension points.
- **Guard spec, part 3.** Each palette meets the contrast table above, so a
  palette edit that breaks contrast fails the build. `accent` must also differ
  visibly from any hover fill it is paired with.
- **Server spec.** With `appearance.gene` set to `dark`, `GET /`, `GET /plugins`
  and `GET /about/` contain `data-theme="dark"`. With the file missing or
  invalid, all three contain `data-theme="light"`. The static export contains
  `data-theme="light"`.
- **Recovery spec.** With a broken plugin composition, `--recovery` startup
  still serves `GET /` and `GET /ui/default` with `data-theme="dark"`, and its
  toggle changes the file.
- **Setter spec.** A failed write leaves the active mode and the file unchanged
  and publishes nothing.
- **Reachability.** With `sidebar` and `ui_experiment` both disabled, the toggle
  is visible and works, and so does the endpoint.
- **Catch-up.** A tab disconnected while another tab switches the mode shows
  the new mode after reconnecting, without a reload.
- **Legacy overrides.** Switch light → dark → light with a legacy flat map and
  with a partial mode map. Dark must show host colors for undefined keys, and
  light must restore the overrides exactly.
- **Computed colors.** Source-level checks miss scoping failures, so read
  `getComputedStyle` values for:
  - action text on the plugin manager and `/about/` buttons;
  - a syntax token inside a panel with an `ink` override (it must differ from
    the same token at `:root`);
  - the `/about/` page background and link color in both modes.
- **Browser pass**, in light and dark at 1280px and 390px, with the OS set to
  dark both times to prove it is ignored. Cover the conversation view,
  composer, drawers, notification center, plugin manager, `/ui/default`, a
  docked plugin panel with and without overrides, code blocks, markdown tables,
  the image grid and `/about/`. Confirm that:
  - radios are still circles;
  - the Safari `select` is square;
  - links are underlined everywhere;
  - focus rings are visible on every background.
- **Forced colors.** The `forced-colors: active` block keeps working; it
  already uses system colors and needs no change.
- **Plugin defaults and extension.** Render a representative form/table view
  with no custom CSS in both modes, and a specialized view with a scoped style
  contribution. Check the generated scope class, intended appearance, style
  replacement, cleanup on disablement and omission in recovery views. No
  hostile-plugin containment or CSS-bypass rejection tests are required.

## Rollout

Each step ships independently and leaves the UI coherent.

1. **Geometry.** Add the radius reset, the button rule and the square
   exceptions; delete the other radii; give the status dot, badges and user
   message their square forms. This covers the app, the plugin manager and
   `/about/`. Colors are unchanged.
2. **Neutral light palette.** Add `theme.gene` with the light palette, plus
   `user`, `edge`, `danger`, `success` and `scrim`. Replace every hex literal,
   drop the shadows, point errors at `danger` and underline links. Map the
   `/about/` tokens onto the host palette. The site moves from blue and teal to
   gray in this step.
3. **Dark mode.** This step adds:
   - the dark palette;
   - the `data-theme` render on `/`, the plugin manager, `/about/` and the
     recovery server;
   - `appearance.gene` and its host setter and endpoint;
   - the host-bar and plugin-manager toggles, `/theme` and `set_appearance`;
   - the mode in the `status` handshake and the `appearance` broadcast;
   - the flat-map-as-light rule, with all seven panel properties cleared on
     every mode change;
   - `/theme` in `docs/commands.md` and `set_appearance` in `docs/recipes/ui.md`.
4. **Per-mode plugin override authoring** (`^light`/`^dark` maps), documented in
   `docs/web-components.md` and `docs/recipes/ui-configuration.md`.
5. **Plugin styling support.** Complete and document the shared control/layout
   defaults and the scoped style contribution API. Include an example with no
   custom CSS and an example extending the theme for specialized content.
   - **Doc that changes:** `docs/workspace-views.md` currently says plugin CSS
     is neither required nor accepted.
   - **Docs that gain the styling path:** `docs/web-components.md` and
     `docs/recipes/ui-configuration.md` describe the seven `^theme` tokens as
     the only plugin styling. Both add the style contribution.
