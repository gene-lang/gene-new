# Theming

Status: implemented (2026-10-17). This document is the design of record; the
[Verification](#verification) section names the specs that hold it.

The web UI has square geometry, two minimalist neutral palettes, and a
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

## Before this change

Measured in `src/web/style.gene`, `src/web/plugin_page.gene` and
`src/website/style.gene` before the theming work:

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
| `select-chevron` | Select arrow, a data-URI SVG drawn in `muted` | per palette | per palette |
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
`open_runtime` attaches `open_appearance` to the harness as `h/appearance` for
both the normal and the recovery runtime, and `appearance_mode` /
`set_appearance` read and change it. It deliberately depends on nothing else:

- **Not the event store, `config.gene`, or plugin state.** Recovery startup
  (`open_runtime ^recovery true` in `src/runtime/bootstrap.gene`) leaves the
  event store unopened and skips the configuration read. The recovery server
  must still find the mode, so the record cannot live in any of those.
- **Not `ui_experiment` state.** That plugin is disabled by default and owns
  plugin-content overrides. Appearance is a host concern that must work with
  every plugin disabled.
- **Missing or invalid means light.** A missing file, a read error or an
  unknown mode renders `light`, so a damaged file cannot break a page.
- **Persist, then publish.** The setter writes the file with
  `$fs/write_text_atomic` under a gate. Only after that succeeds does it update
  the in-memory mode and publish an `AppearanceChanged` harness event. A failed
  write raises and leaves the file, the active mode and the bus untouched.

The mode is stored per workspace for now. This has three advantages:

- **No flash.** `page` runs per request, so the server passes
  `(appearance_mode h)` and the response already carries
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
`POST /api/v8/appearance` with `{"mode": "dark"}`, on both the normal and the
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
next update or reload; it does not change the persisted choice. Handling this
race is outside this milestone.

Pages without a push connection update on load:

- **The plugin manager** (`client/plugin_manager.gene`) uses fetch only. It
  takes the mode from its server-rendered page and from every catalog load
  (page load and Refresh); `GET /api/v8/plugins` includes `appearance` on both
  servers, as does the recovery server's status.
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

`ui_configure ^theme` used to be one flat map applied to the plugin panel. A
light color like `#335577` would be unreadable on a dark surface, so overrides
are per mode:

```gene
(ui_configure {^^enabled ^layout "panel" ^panel "project_board"
  ^theme {^light {^accent "#335577"} ^dark {^accent "#9db4d6"}}})
```

- **A flat map is read as `^light`**, so existing configurations keep their
  meaning. In dark mode a panel with no `^dark` map uses the host dark palette.
  That is safer than applying light colors to a dark surface.
- **Validation per entry is unchanged**: the seven public keys, six-digit hex
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

## Verification

Specs (all model-free):

| Check | Where |
| --- | --- |
| Every `border-radius` in `base_styles` and the plugin manager CSS is `0` or `var(--radius-button)`, which appears only on `button`; in the rendered `/about/` CSS only the four site controls use it. The scan must find exactly those rules, so it cannot pass vacuously. | `tests/unit/web/theme_spec.gene` |
| No hex color literal in the app, plugin manager or website stylesheets outside `theme.gene`. | same |
| Both palettes meet the contrast table: text ≥ 4.5:1 on surface/sidebar/soft/user, `edge` ≥ 3:1, Send text on its `ink` fill and `muted` hover fill ≥ 4.5:1, and a visible hover change. | same |
| `page`, `plugin_page` and `website_page` render the requested mode, default to light, and the static (`standalone`) site is light. | same |
| Missing, unreadable, non-map and unknown-mode files read as light; a change is written before the event is published; an unknown mode and a failed write leave the mode, the file and the bus unchanged; a harness without a setting refuses changes. | `tests/unit/runtime/appearance_spec.gene` |
| Per-mode and legacy theme maps validate; mixed, unknown, malformed and host-only keys are rejected. | `tests/unit/ui/state_spec.gene` |
| The browser picks the active mode's overrides and gives dark nothing from a legacy map. | `tests/unit/client/theme_spec.gene` |
| Style contributions: scoped by default with a `plugin_<name>__…` class, page-wide with `^!style_scoped`, absent without a style, and malformed or >64 KiB styles are rejected. | `tests/unit/ui/components_spec.gene` |
| A real host serves `/`, `/plugins`, `/about/` and `/?ui=default` in the saved mode; the endpoint, `/theme` and `set_appearance` all switch it with `sidebar` and `ui_experiment` disabled; a bad mode is a 400 and changes nothing. | `tests/integration/web/appearance_spec.gene` |
| A recovery host with a corrupt `config.gene` and event store serves `/`, `/plugins` and `/ui/default` in the saved dark mode and switches it through its own endpoint. | same |
| The session service broadcasts `appearance` once per change; a style contribution reaches the status payload and the view descriptor, is replaced with its plugin, disappears on uninstall, and is absent from safe status. | same |
| Pages send no CSP; the image route keeps its sandbox policy. | `tests/integration/web/images_transport_spec.gene` |

Browser pass (Chrome, 2026-10-17, offline host with the project board and a
styled demo plugin; the OS color preference was not consulted):

- **Both modes at desktop width and at 390 px** (rendered in same-origin
  frames) for the conversation view, composer, sidebar, plugin manager and
  `/about/`.
- **Computed values.** `button` radius 3px; composer, cards, rows, selects and
  the drawer 0px. The drawer has an `edge` border and no shadow. The
  user-message block is `--user`, square. Selects use `appearance: none` with
  the chevron. A native radio still renders as a circle.
- **Plugin colors.** Overrides land on `#ui_panel`, and `--syntax-string`
  recomputes from the panel's overridden `ink`.
- **Overrides across a switch.** Light → dark → light with a legacy flat map
  (dark shows host colors, light restores them) and with a partial per-mode
  map (only `accent` changes).
- **Plugin styles.** The demo plugin's scoped rule is mounted in
  `#plugin_styles` and applies inside its component. `/ui/default` mounts no
  plugin styles.
- **Live updates.** A `/ui/default` tab followed a `/theme` change made from
  the CLI. A tab followed a change made from the plugin manager's toggle. After
  a host restart, reloaded pages painted dark on first load from the saved
  file.
- **Reconnect.** A tab whose stream reconnected re-applied the host's mode from
  the handshake status, even after its `data-theme` had been changed by hand.
- **`/about/`.** Inline links take `accent` and are underlined; the primary
  button is `ink` with `action-ink` text and the 3px radius.

Not covered: Safari and Firefox were not exercised; forced-colors mode was not
re-checked (its block is unchanged and uses system colors).

## Rollout

All five steps landed together on 2026-10-17:

1. **Geometry**: the reset, the button rule and the square exceptions in the
   app, the plugin manager and `/about/`.
2. **Neutral light palette**: `theme.gene`, the new host tokens, no hex
   literals outside it, no shadows, `danger` for errors, and `/about/` on the
   host tokens.
3. **Dark mode**: the dark palette, `data-theme` rendering on every page and
   the recovery server, `appearance.gene` with its setter and endpoint, the
   toggles, `/theme`, `set_appearance`, the status field and the `appearance`
   broadcast, and the flat-map-as-light rule.
4. **Per-mode plugin overrides**, documented in `docs/web-components.md` and
   `docs/recipes/ui-configuration.md`.
5. **Plugin styling**: the content defaults and shared classes, and the `style`
   contribution, documented in the [Styling section](web-components.md#styling).

The CSP removal shipped earlier the same day. Related docs updated:
`docs/commands.md`, `docs/recipes/ui.md`, `docs/workspace-views.md`,
`docs/web-client.md`, `README.md` and `experiments/ui` (per-mode board colors).
