# Theming

The Harness web UI takes every visual value from a theme. The host defines the
names: token roles, the icon vocabulary, the shell structure, the breakpoints
and the cascade layers. A theme supplies the values: colors for each mode,
fonts, the type and spacing scales, radii, borders, shadows, motion, layout
sizes, icon drawings and any extra CSS.

Two themes are built in. `default` is the general theme, designed by a UI/UX
designer. `minimal` is the owner's theme: square corners, pure grays, almost no
shadows. It extends `default`. Plugins can add themes, and users will be able
to duplicate a theme and edit the copy.

Each browser chooses its theme, its light or dark mode, density, text size and
content width. The app, the plugin manager, the recovery server and `/about/`
all follow that choice. Ordinary plugin views inherit the theme without CSS of
their own, and plugins can make their own structures themable.

## Goals

- **Everything visual is a theme value.** No host rule fixes a color, size,
  radius, shadow or font.
- **One source of truth** for the app, the plugin manager, the recovery UI,
  `/about/` and plugin views.
- **Light and dark are equal peers.** Light is the default, and the OS
  preference is not followed.
- **No flash.** The first paint already uses the chosen theme and mode.
- **Ordinary plugin views need no CSS**, and plugin structures follow the
  active theme.
- **Every width and text size works**, from 320px phones to wide screens, and
  at 200% text size.
- **Built-in themes meet WCAG AA** in both modes.

Non-goals: theming the terminal client, following `prefers-color-scheme`,
animated mode switching, free-form layout editing, and any sandbox or
restriction on plugin CSS.

## Principles

1. **The system names, the theme decides.** Host rules read tokens. A value
   appears only in a theme.
2. **Rules read roles.** A rule reads `--surface-raised` or `--radius-field`,
   never a palette step or a literal. A theme can then change any decision
   without touching a rule.
3. **User settings win.** Reduced motion, forced colors and the user's
   preferences beat every theme.
4. **Intrinsic layout first.** Components adapt without queries where they can,
   query their region where they must, and only the shell queries the page.
5. **Plugins are trusted.** The host provides defaults, tokens and shared
   structures. It never polices a plugin's CSS.
6. **Recovery always works.** The built-in themes ship with the host and need no
   plugin.

## System and theme

| | System | Theme |
| --- | --- | --- |
| Defines | Token names and roles, which rule reads which token, the icon names, the shell structure and region names, breakpoints, cascade layers, accessibility floors for built-in themes | Every value: palettes, fonts, type scale, spacing scale, radii, borders, shadows, motion, layout sizes, icon drawings, and any extra CSS |
| Owner | The host. Plugins and themes depend on the names, so changes to them are reviewed. | The theme's author: the designer for `default`, the owner for `minimal`, a plugin or a user for theirs |
| Lives in | Stylesheet modules under `src/web/style/`; the generator in `src/web/theme.gene` | Built-in themes in `src/web/themes/<name>.gene`; plugin `themes` rows; the user theme library |
| Checked by | The guard spec: rules use tokens | Built-in themes: the contrast floors in the guard spec. Other themes: the specimen and the editor show ratios and never refuse a value. |

## Tokens

### Tiers and names

1. **Scales.** Raw steps: the spacing scale, the type scale, gray ramps. Rules
   may use spacing and type steps directly. Color ramps are private to the
   theme, and rules use color roles only.
2. **Roles.** The public contract that host rules, plugin styles and
   `ui_configure ^tokens` use: `--surface-raised`, `--radius-field`,
   `--type-small`, `--layer-dialog`.
3. **Component tokens.** Optional hooks that one component reads with a role
   fallback, such as `--message-user-surface` or `--board-lane-surface`. The
   host adds them only where a designer needs to tune one component apart from
   its role. Plugins use them to make their own structures themable (see
   [Plugin-defined structures](#plugin-defined-structures)).

Names are kebab-case CSS custom properties, `--<group>-<role>[-<variant>]`.
Gene theme maps use snake_case keys (`^radius_field`), and the generator
converts `_` to `-`, as `$css` `decl` does.

### Color

| Role | Use |
| --- | --- |
| `surface` | Page and panels |
| `surface-alt` | Secondary regions: the sidebar, card headers, the `/about/` footer |
| `surface-raised` | Menus, drawers, dialogs, popovers |
| `soft` | Hover, code, badges |
| `selected` | The selected row, tab or option |
| `line` | Decorative dividers |
| `edge` | Control boundaries and floating-layer borders |
| `ink`, `muted` | Primary and secondary text |
| `accent` | Active markers, the status dot |
| `link-color`, `link-decoration` | Links |
| `action`, `action-hover`, `action-ink` | The primary button's fill, its hover fill and its text |
| `focus` | Focus rings |
| `danger`, `success`, `warning`, `info` | Status text and rules |
| `danger-surface`, `success-surface`, `warning-surface`, `info-surface` | Tinted notice and badge backgrounds |
| `scrim` | Overlay backdrop |
| `series-1` … `series-8` | Categorical data colors for charts, legends and diagrams |
| `syntax-string`, `syntax-number`, `syntax-keyword`, `syntax-callable`, `syntax-type` | Code highlighting |

Host component tokens, each read with the role in parentheses as fallback:
`message-user-surface` (`soft`), `sidebar-surface` (`surface-alt`),
`field-surface` (`surface`), `code-surface` (`soft`) and `notice-surface`
(`soft`).

**Links and hover.**

- Links read `link-color` and `link-decoration`. If a theme's link color is
  less than 3:1 against the surrounding text, the theme must underline links
  (WCAG 1.4.1).
- A hover or selection state never relies only on a change from `ink` to
  `accent`, because a theme may make them equal. Hover uses a fill (`soft`,
  `selected`) or an underline, and the primary action uses `action-hover`.

**Derived colors.**

- **Syntax.** Unless a theme sets them, the generator derives each `syntax-*`
  color as `color-mix(in srgb, <hue> 55%, var(--ink))`. Mixing with `ink`
  darkens a hue in light mode and lightens it in dark mode, so one formula
  serves both. The derived tokens are declared on `:root`, `[data-mode]` and
  `.ui_panel`. Custom properties inherit computed values, so a token resolved
  only at `:root` would keep the page's `ink` inside a panel or subtree that
  overrides it.
- **Select chevron.** A data-URI image cannot read custom properties. So for
  each mode, the generator draws the theme's `chevron-down` icon in that mode's
  `muted` color as `--select-chevron`.
- **`color-scheme`** is set per mode. It switches native scrollbars,
  checkboxes, date inputs and `select` popups to match.

**Contrast floors.** Built-in themes meet these in both modes. Plugin and user
themes see the same ratios in the specimen and the theme editor, which never
refuse a value.

- Text roles reach 4.5:1 on every surface they appear on.
- `edge` and `focus` reach 3:1 on every surface.
- Each `series-*` color reaches 3:1 on `surface` (WCAG 1.4.11, graphical
  objects).
- `action-ink` reaches 4.5:1 on `action` and on `action-hover`.

### Typography

- **Families**: `font-sans`, `font-mono`, and `font-display` for headings.
  `font-display` defaults to `font-sans`.
- **Root size**: `100%`, so the browser's text-size setting and the
  `text_size` preference scale everything measured in `rem`.
- **Weights**: `weight-regular` (400), `weight-medium` (550) and `weight-bold`
  (650). With system fonts, 550 renders as an intermediate weight only where
  the font is variable.
- **Size scale**:

| Step | Value | Typical use |
| --- | --- | --- |
| `text-2xs` | `.68rem` | Section labels, tab subtitles, hints |
| `text-xs` | `.75rem` | Metadata, run status, footer links |
| `text-sm` | `.82rem` | UI rows, conversation names, drawers, tables |
| `text-md` | `.94rem` | Transcript body, composer, markdown |
| `text-lg` | `1.05rem` | Small headings |
| `text-xl` | `1.2rem` | Section headings, icon buttons |
| `text-2xl` | `1.4rem` | Brand, page headings |
| `text-display` | `clamp(1.8rem, 2.7vw, 2.4rem)` | Empty-state headline |

- **Roles.** Each role is one `font` shorthand token, so a rule writes
  `font: var(--type-body)`. Letter spacing is a separate token, because `font`
  cannot carry it.

| Role | Use |
| --- | --- |
| `type-body` | Transcript and markdown |
| `type-ui` | Controls and rows |
| `type-small` | Metadata |
| `type-label` | Uppercase section labels, with `tracking-label` |
| `type-title` | Top-bar and drawer titles |
| `type-heading-1` … `type-heading-3` | Markdown and plugin headings, with `tracking-tight` |
| `type-display` | The empty-state headline |
| `type-code` | Code blocks, commands, REPL input |

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
  `$web/font` while constructing its descriptor, as spotlight does with
  `$web/stylesheet`. Bundled fonts work offline.
- **External URLs.** An `https:` `src` is used as given. It needs the network,
  and each page load is visible to the font host. That is the theme author's
  choice, and pages send no CSP that would block it.
- **Rendering.** The generator emits one `@font-face` per entry, with
  `font-display: swap` unless the theme says otherwise. `$css` has a
  `font_face` node so plugin and user themes can write font rules too. `page`
  adds `<link rel="preload" as="font" crossorigin>` for the face that the
  rendered theme's `font-sans` names, if any, so the first paint rarely shows
  a swap. A theme inherits its parent's font entries. A browser downloads a
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
- **Semantic spacing**: `gutter` (inline page padding: `2.25rem`, or `1rem`
  below `compact`), `stack-gap` (between blocks), `inline-gap` (between
  controls), `inset-control` (button padding), `inset-field` and
  `inset-surface` (cards, drawers).
- **Density.** Theme maps state base lengths, such as `^space_4 "1rem"`; the
  generator scales them, including plugin overrides. Each step is declared as `calc(<base> * var(--density))` on
  `:root`, and so is `control-height`. The theme sets `--density: 1`. The
  compact preference sets `.8` on the root element from the `preferences`
  layer, so it wins over the theme. Density applies to the whole page. A
  subtree that redeclares `--density` does not recompute the steps, because
  custom properties inherit computed values.
- **Rule.** Margins, paddings and gaps in host CSS use a space token, `0` or
  `auto`.

### Shape

| Role | Use |
| --- | --- |
| `radius-control` | Buttons and links that read as controls |
| `radius-field` | Inputs, textareas, selects, the composer |
| `radius-surface` | Cards, drawers, menus, dialogs, code blocks, images |
| `radius-row` | Rows, tabs, and buttons that read as rows, tabs or links |
| `radius-chip` | Badges, the status dot |
| `radius-message` | The user message block |

The reset sets `border-radius: 0`, and each component rule reads its role. The
role follows how an element reads, not its tag. Many rows are `<button>`
elements for keyboard access:

| `radius-control` | `radius-row` |
| --- | --- |
| Send, Stop, New conversation | Conversation rows and attention rows |
| Rename/Save, confirmation and input-panel actions | Session tabs and the buttons inside them |
| Drawer actions, Copy, Edit & retry, attachment Remove | Command-palette rows |
| Plugin component buttons, plugin manager actions | Notification list rows, trigger occurrence rows |
| Icon buttons: menu toggle, drawer close | Sidebar footer links (Triggers, Workspace status, About) |
| The "New output" jump button | Suggestion links, table-cell buttons in panels, "Older messages" |
| `/about/` call-to-action links, its menu toggle and its copy buttons | `/about/` view tabs, image-grid points |

If it reads as a control, it reads `radius-control`. If it reads as a row, a
tab or a link, it reads `radius-row`, and so does its hover background.

### Borders and focus

- `border-width` (1px), `border-width-strong` (2px: the selected tab, the
  attention rail) and `rule-width` (3px: status rules on notices).
- Decorative borders use `line`. Control borders use `edge`.
- `focus-width` (2px), `focus-offset` (4px) and the `focus` color make up the
  single focus ring rule. Focus outlines follow `border-radius`, so each ring
  matches its element's shape. The image-grid point keeps an inset ring by
  reading the same tokens with a negative offset.

### Elevation, layers and motion

- **Elevation**: `shadow-raised` (menus, popovers) and `shadow-overlay`
  (drawers, dialogs, the narrow sidebar), defined per mode. A dark shadow needs
  a much higher alpha than a light one. Floating layers always have a
  `border-width` border in `edge`, so they stay distinct in a theme whose
  shadows are `none`. The narrow sidebar's backdrop is drawn as
  `box-shadow: 0 0 0 100vmax var(--scrim)`, which is a backdrop rather than
  elevation.
- **Layers.** One z-index scale: `layer-raised` (1), `layer-sticky` (10, the
  host bar), `layer-overlay` (20, the narrow sidebar), `layer-drawer` (30),
  `layer-menu` (40), `layer-dialog` (50, spotlight), `layer-toast` (60).
  Plugin overlays use the same tokens, so they stack correctly with the host's.
- **Motion**: `duration-fast` (100ms), `duration-base` (180ms) and
  `ease-standard`. Under `prefers-reduced-motion: reduce`, the system sets
  both durations to `0ms` with `!important` in the `preferences` layer, so the
  setting beats any theme value (see
  [the cascade](#stylesheets-and-the-cascade)).

### Layout sizes

All are plain `rem` lengths. They scale with text size, and the generator can
compute the `narrow` breakpoint from them (see [Responsive](#responsive)).

| Token | Use | Initial value |
| --- | --- | --- |
| `sidebar-width` | Docked sidebar | `14.5rem` |
| `content-width` | Transcript and composer measure | `47.5rem` |
| `topbar-height` | Conversation top bar | `4.75rem` |
| `drawer-width`, `drawer-width-wide` | Drawers | `20rem`, `27.5rem` |
| `menu-width` | Menus | `13.75rem` |
| `panel-min`, `main-min` | Minimum widths of a docked view and of the conversation | `17.5rem`, `21.25rem` |
| `control-height` | Action buttons and single-line dropdowns | `2rem` |
| `touch-target` | Minimum control height under a coarse pointer | `2.75rem` |

Single-line dropdowns use `control-height` with border-box sizing. Action
buttons and the file chooser button use the same minimum height, so toolbar,
filter and composer controls line up. Buttons with several lines grow to fit.

## Icons

Host markup never uses text glyphs (`+`, `×`, `↓`, `⋯`) as icons. Like every
other visual decision, the drawings belong to the theme.

- **The system owns the names.** Host markup uses a fixed vocabulary: `add`,
  `close`, `menu`, `more`, `send`, `stop`, `copy`, `search`, `settings`,
  `notifications`, `light`, `dark`, `chevron-down`, `chevron-right`,
  `arrow-down`, `check`, `success`, `warning`, `error`, `info`, `external`,
  `attachment`, `microphone`, `pin`, `edit`, `retry`, `delete`, `sidebar`,
  `plugin`, `trigger`. Plugins can add names.
- **The theme owns the drawings.** A theme's `^icons` map gives each name a
  one-color SVG on a 24×24 view box. The generator writes each drawing into a
  custom property as a data URI, `--icon-close: url("data:image/svg+xml,…")`.
  A theme that omits a name inherits that drawing along its `extends` chain.
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
- **Drawings in `default`.** The designer picks an open-source set with a
  permissive license; Lucide (ISC), Phosphor (MIT) and Tabler (MIT) all fit.
- **Plugins.** Component trees have `(icon ^name "close")`. A plugin adds a
  name with an `icons` row, `{^name "board-lane" ^svg "<svg …>"}`. Its drawing
  is checked against the inert SVG subset that the workspace image route
  enforces. A theme can redraw a plugin's icon by defining the same name.
- **Accessibility.** Icons are decorative (`aria-hidden`). A button whose only
  content is an icon has an `aria_label`.

## Modes

There are two modes, `light` (the default) and `dark`. The OS preference is
ignored. Every theme supplies both palettes, as `^light` and `^dark` token
maps beside its `^shared` one.

- **The page.** `page` renders `<html id="harness_document" data-mode="…">`.
  `$dom/element` looks elements up by id, so the client reads and changes the
  mode there.
- **Part of a page.** The generator emits each palette for `:root`,
  `:root[data-mode="dark"]`, and for `[data-mode="light"]` and
  `[data-mode="dark"]` on any element. The derived tokens are declared on
  `[data-mode]` too, so they recompute inside the subtree. Any element can
  then force a mode: the specimen shows both modes side by side, a region can
  stay dark, and the theme picker can preview. Component trees take a `mode`
  attribute that renders as `data-mode`.
- **Separate words.** `data-mode` is the light/dark mode, and `data-theme`
  names the rendered theme.

## Host component rules

These are system rules about specific elements. Their values come from the
theme.

- **Native fields.** The reset covers text inputs, which WebKit rounds
  natively. Every single-choice `select` uses `appearance: none`, with
  `--select-chevron` as its background image. Select rules set
  `background-color`, never the `background` shorthand, which would drop the
  chevron.
- **Checkboxes and radios** stay native, colored with
  `accent-color: var(--accent)`. A radio's circle is the control's meaning, not
  a corner. If an engine squares it under the reset, exempt
  `input[type=radio]`.
- **The user message** is a block in `message-user-surface` with `ink` text,
  right-aligned at `fit-content` width, with `radius-message`.
- **The status dot** (`.local::before`) is a 6px chip in `accent`.
- **Badges** (`.web_badge`, `.plugin_badge`, the `/about/` totals) are chips on
  `soft`, or on a status surface for a status badge.
- **Floating layers** (drawers, menus, the notification center, the narrow
  sidebar, dialogs) read `surface-raised`, an `edge` border and their
  elevation role.

## Responsive

Three layers, in order of preference:

1. **Intrinsic layout first.** Flex wrapping, `repeat(auto-fit, minmax(…))`,
   `min()` and `clamp()` adapt without any query. `web_grid` works this way.
   Most components need nothing more.
2. **Container queries inside regions.** A component's layout depends on the
   width of the region it sits in, not on the window.
3. **A query on the whole page only for the shell's arrangement**, plus media
   queries for input modality and for user settings such as reduced motion.

### Shell breakpoints

The app, the plugin manager and `/about/` share two breakpoints:

| Name | Applies below | Shell |
| --- | --- | --- |
| `narrow` | The larger of `56.25rem` and `sidebar-width + panel-min + main-min` | The sidebar becomes an overlay. A docked view stacks above the conversation. |
| `compact` | `47.5rem` | Phone gutters, drawers at full width, a smaller empty state |

Both are measured in `rem` against the root's actual font size. They therefore
move with the browser's text size and with the `text_size` preference, as the
column widths do. A viewport media query cannot do this: in a media query,
`rem` means the browser's initial font size and ignores the preference. Take
`larger` (125%) with a 16px browser default. The three columns then need
290 + 350 + 425 = 1065px, and `narrow` starts at 1125px, so a 1024px window
gets the narrow layout instead of overflowing.

- **The page is the shell's container.** `body` is an `inline-size` container
  named `shell`, and the shell's rules are `@container shell (width < …)`
  queries. Their conditions resolve `rem` against the root element. A region
  container cannot do this, because the shell grid itself is what changes.
  Fixed overlays (the narrow sidebar, drawers, spotlight) must still cover the
  viewport with a container as an ancestor; the specimen checks it.
- **`narrow` follows the theme.** Query conditions cannot read custom
  properties. So the generator computes `narrow` from the theme's resolved
  layout sizes and writes the shell's narrow rules into the theme's stylesheet,
  inside the `shell` layer. If column sizes differ by mode, it uses the larger
  requirement so both modes fit. That is why layout sizes are plain `rem` lengths
  the generator can add up. A theme with a wider sidebar collapses earlier
  instead of overflowing. `compact` is a system constant.
- **The client follows the CSS.** The narrow rules also set `--shell-narrow: 1`
  on `.app`. The client reads it on resize and after applying an appearance
  change, through the `$dom/style_value` web-profile primitive. No host or
  client code compares the window width with a number.

### Region containers

Every region whose width the shell sets is a named `inline-size` container:

| Container | Element |
| --- | --- |
| `main` | `.workspace` |
| `view` | `#ui_view` |
| `sidebar` | `#sidebar_view` |
| `drawer` | `.drawer` |

Slot wrappers (`.plugin_component`) are not containers. An `inline-size`
container cannot take its width from its content, so a toolbar component would
collapse to zero width. Components in slots query the enclosing region.

**Plugin authors** get three container steps. They are documented constants,
because queries cannot use custom properties: `30rem` (phone-like), `48rem`
(two columns fit) and `64rem` (wide). The `$css` `container` node renders
`@container` and is scoped like `media`:

```gene
(css
  (rule ".sheet_grid" (decl grid_template_columns "12rem repeat(6, 1fr)"))
  (container "view (max-width: 30rem)"
    (rule ".sheet_grid" (decl grid_template_columns "1fr"))))
```

**Shared responsive structures**: `web_split` (two panes that wrap below their
basis, intrinsic) and `web_scroll_x` (horizontal scrolling for wide tables, the
plugin counterpart of `.table_scroll`).

### Input and accessibility

- **Coarse pointers.** Under `(hover: none), (pointer: coarse)`, controls and
  rows use `touch-target` as their minimum height, and actions that appear on
  hover stay visible.
- **Floors.** The UI reflows without horizontal page scrolling at 320 CSS px
  (WCAG 1.4.10) and stays usable at 200% text size. Forced colors and reduced
  motion are honored from the `preferences` layer. A landscape block for
  heights up to 600px tightens vertical spacing.

## Stylesheets and the cascade

A page links two generated stylesheets, and plugin styles mount after them:

| Stylesheet | Contents | Layer |
| --- | --- | --- |
| Host | System rules, the same for every theme, built from the modules under `src/web/style/` | `preferences, reset, base, shell, components, content, utilities` |
| Theme | One content-addressed stylesheet per theme: the token blocks for each mode, the `@font-face` rules, the icon properties, the generated `narrow` rules, and the theme's `style` | Unlayered, except the `narrow` rules, which sit in `shell` |
| Plugin | Style contributions, one `<style>` per contribution | Unlayered |

- **Order.** Unlayered rules beat layered ones regardless of specificity. So a
  theme rule beats a host rule, and a plugin rule beats both when it comes
  later. Host defaults therefore need no `:where()`, and their source order
  does not matter across layers.
- **User settings beat themes.** A normal declaration in a layer loses to any
  unlayered theme value. A layered `--duration-fast: 0ms` would lose to a
  theme's `180ms`, and a layered `--content-width` for the user's preference
  would lose to the theme's own `--content-width`. The host declarations that
  carry a user setting are therefore `!important`, in the `preferences` layer,
  which is declared first:
  - reduced motion
  - the forced-colors adjustments
  - the density, text size and content width preferences

  An important declaration beats every normal one. Among important
  declarations the first layer wins, even over an unlayered `!important` in a
  theme or plugin. A preference at its default declares nothing, so the
  theme's own value applies.
- **Switching** theme in a tab replaces one `<link>`. The appearance answer's
  `rendered` part carries the new stylesheet URL.
- **`$css`** has `container` and `font_face` nodes for plugin and user styles.
  The host stylesheet is text and can use any at-rule.

## Themes

### Format

A theme is data:

| Field | Meaning |
| --- | --- |
| `name`, `title`, `doc` | Identity shown in the picker. `light` and `dark` are reserved names. |
| `extends` | The theme that fills in what this one leaves unset; `default` when omitted |
| `tokens` | `{^shared {…} ^light {…} ^dark {…}}`: any scale, role or component token, with snake_case keys |
| `fonts` | Font entries; see [Web fonts](#web-fonts) |
| `icons` | Drawings by icon name; see [Icons](#icons) |
| `style` | Optional `$css` data for what tokens cannot express. It applies to the whole page. A theme's rules come after its parent's, which still apply. |

A token resolves from the theme first, then along its `extends` chain, ending
at `default`. A theme states only what it changes, and a token the system adds
later always has a value. `src/web/theme.gene` holds the generator, the token
names and `contrast_ratio`. The values live only in theme files.

### Sources

| Source | Lives in | Notes |
| --- | --- | --- |
| Built-in | `src/web/themes/default.gene`, `src/web/themes/minimal.gene` | Owned by the host, so they are available on the recovery server and with every plugin disabled |
| Plugin | `themes` rows | Re-publishing updates every tab that renders the theme. While the plugin is disabled or removed, those browsers render `default` and keep the theme saved. |
| User | The theme library (later) | Duplicates that the user edits; see [User themes](#user-themes-later) |

```gene
(host .PluginHost:contribute "themes"
  {^name "paper" ^title "Paper" ^extends "default"
   ^tokens {^shared {^radius_surface "6px" ^font_display "\"Iowan Old Style\", serif"}
            ^light {^surface "#fbfaf7" ^ink "#22201c"}
            ^dark {^surface "#1a1916" ^ink "#ece8e1"}}
   ^style (css (rule ".card_header" (decl background "var(--surface-alt)")))})
```

A designer iterates on a theme plugin with `register_plugin ^^replace`, with no
host restart.

### `default`

`default` is the designer's theme and the root of every `extends` chain. It
defines every system token, draws every icon in the vocabulary, and meets the
contrast floors. It starts with the values that `minimal` sets below, plus
initial values for the roles `minimal` leaves to it. The designer replaces
them, working in a theme plugin, and moves the values into
`src/web/themes/default.gene` once they are settled.

### `minimal`

`minimal` is the owner's theme. It extends `default` and sets its own values
for the choices that define it:

- **Color.** Pure neutral grays (R = G = B) in both modes, with the accent
  equal to the ink. Emphasis comes from weight, underline, borders and fills,
  not hue. Color appears only where status is the message (`danger`,
  `success`) and in syntax highlighting. The dark surface is not pure black and
  dark ink is not pure white, which reduces glare without losing contrast.
- **Links** are underlined, since the accent equals the ink.
- **Shape.** `radius-control` is `5px`, and every other radius is `0`.
- **Elevation.** `shadow-raised` is a menu shadow for each mode:
  `0 5px 18px #0002` in light and a stronger one in dark, where 13% black
  barely shows. `shadow-overlay` is `none`, so drawers and dialogs rely on
  their `edge` border.
- **Motion.** Both durations are `0ms`.
- **Fonts.** System stacks: `font-sans` and `font-display` are
  `-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`, and `font-mono`
  is `ui-monospace, SFMono-Regular, Menlo, Consolas, monospace`.

| Token | Light | Dark |
| --- | --- | --- |
| `surface` | `#ffffff` | `#151515` |
| `surface-alt` | `#f7f7f7` | `#1b1b1b` |
| `soft` | `#efefef` | `#262626` |
| `message-user-surface` | `#ebebeb` | `#2b2b2b` |
| `line` | `#e5e5e5` | `#2f2f2f` |
| `edge` | `#858585` | `#777777` |
| `muted` | `#636363` | `#9c9c9c` |
| `ink`, `accent` | `#1c1c1c` | `#e7e7e7` |
| `danger` | `#a8322b` | `#ef8b80` |
| `success` | `#2d6a38` | `#8fc89b` |
| `scrim` | `rgb(0 0 0 / .2)` | `rgb(0 0 0 / .5)` |

The other neutral roles are set as references: `surface-raised` is
`surface`, `selected` is `soft`, `action` is `ink`, `action-hover` is
`muted`, `action-ink` and `field-surface` are `surface`, and `focus` and
`link-color` are `accent`.

- **Why `message-user-surface` differs from `soft`.** The user message stays
  distinct from a code block beside it, and the block can be tuned without
  changing hover, code and badge backgrounds.
- **Why `edge` differs from `line`.** `line` stays faint for dividers, where
  WCAG asks nothing. `edge` meets 3:1 wherever a border is the only sign of a
  control.

Measured contrast:

| Foreground | Light on surface / surface-alt / soft / user | Dark on surface / surface-alt / soft / user |
| --- | --- | --- |
| `ink` | 17.04 / 15.91 / 14.82 / 14.30 | 14.77 / 13.93 / 12.24 / 11.45 |
| `muted` | 6.01 / 5.61 / 5.22 / 5.04 | 6.65 / 6.27 / 5.51 / 5.16 |
| `danger` | 6.65 / 6.21 / 5.79 / 5.58 | 7.54 / 7.12 / 6.25 / 5.85 |
| `success` | 6.50 / 6.07 / 5.65 / 5.45 | 9.48 / 8.94 / 7.86 / 7.35 |
| `edge` (3:1 target) | 3.69 / 3.44 / 3.21 / 3.10 | 4.08 / 3.85 / 3.38 / 3.16 |
| `line` (decorative) | 1.26 / 1.18 / 1.10 / 1.06 | 1.36 / 1.29 / 1.13 / 1.06 |

The primary action measures 17.04 (light) and 14.77 (dark) for `action-ink`
on `action`, and 6.01 / 6.65 on `action-hover`. The derived syntax colors,
measured on `soft`:

| | string | number | keyword | callable | type |
| --- | --- | --- | --- | --- | --- |
| Light | 7.76 | 6.16 | 6.90 | 6.70 | 6.84 |
| Dark | 5.99 | 7.16 | 6.58 | 6.74 | 6.68 |

Everything else comes from `default`: the type scale and roles, spacing and
density, border and focus widths, layers, layout sizes, the icon drawings, and
the `warning`, `info`, status-surface and series colors. A redesign of those
reaches `minimal`, and so does any token the system adds later. To keep a
value through a redesign, the owner sets it in `src/web/themes/minimal.gene`.

### User themes (later)

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
  commit. Until user themes can upload font files, they use fonts from
  installed themes or external URLs.

## Appearance preferences

Each browser keeps its own appearance:

| Preference | Values | Effect |
| --- | --- | --- |
| `theme` | A theme name; `default` when unset | The theme stylesheet, `data-theme` |
| `mode` | `light` (default), `dark` | `data-mode` |
| `density` | `comfortable` (default), `compact` | `--density` 1 or .8 |
| `text_size` | `small`, `default`, `large`, `larger` | Root font size 90%, 100%, 112.5% or 125% |
| `content_width` | `narrow`, `default`, `wide`, `full` | `--content-width` for the transcript and composer |

The user also controls presentation per tab: dock side and width, docked or
full view, whether the sidebar and the host bar are shown.

### Storage

The preferences live in a cookie, `gene_harness_appearance`, that the server
reads when it renders a page.

- **No port in the name.** Auth cookies put the port in their names
  (`gene_harness_session_<port>`) because browsers share cookies across ports.
  This cookie deliberately has none, so one choice follows a browser profile
  across every Harness host on the same host name: all local workspaces and
  the manager.
- **Value and attributes.** The value is a short URL-encoded field list, with
  `Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000`. The client never reads
  the cookie. It gets the values from `<html>` and from
  `GET /api/v9/appearance`.
- **No workspace state.** No workspace file holds appearance, and no setting
  definition does either; Settings scopes are workspace and shared.

### Saved and rendered

The cookie holds the *saved* choice. Each host resolves it into what it
*renders*:

- A theme that is not installed on that host renders `default`. So does every
  plugin or user theme on the recovery server and in the safe UI. The saved name
  stays, so the choice comes back wherever the theme is installed.
- A missing field renders its default. So does an invalid one, which the next
  write drops.
- A theme name is kept whether or not this host has the theme.

The saved value is never replaced by its fallback. Suppose a browser chooses
`paper` in workspace A, then changes only the mode in workspace B, which lacks
that plugin. B renders `default` and keeps `paper` saved, so A still shows
`paper`.

### Reading, writing and propagation

- **First paint.** `page` reads the cookie from the request. It renders
  `data-mode`, `data-theme`, `data-density`, `data-text-size` and
  `data-content-width` on `<html>`, links the rendered theme's stylesheet and
  preloads its body face. A browser with no cookie renders the defaults, and
  nothing is written until the user changes something.
- **Reading.** `GET /api/v9/appearance` answers from the cookie its request
  carries, with both forms:

  ```gene
  {^saved {^theme "paper" ^mode "dark"}
   ^rendered {^theme "default" ^mode "dark" ^stylesheet "…"}}
  ```

  Tabs apply `rendered`. Settings shows `saved`: the picker marks `paper` as
  chosen and notes that it is not installed on this host.
- **Writing.** `POST /api/v9/appearance` is the only path that writes the
  cookie. It takes the fields to change, with the same same-origin and CSRF
  checks as other mutations, and answers in the shape of the GET.
  - **Merging.** It merges the fields into the saved values from the request's
    cookie, and compares the saved values before and after, never the rendered
    ones.
  - **Nothing changed.** It sends no `Set-Cookie`, pushes nothing and publishes
    no event.
  - **Something changed.** It writes the merged saved values and publishes
    `AppearanceChanged` with them. It then sends `appearance_changed`, which
    carries no values, to every socket on this host.

  Settings and the client send only the fields the user changed, never a
  rendered value, so an ordinary mode or density change cannot save a fallback
  as the user's theme.
- **Applying.** A tab makes the GET when it receives `appearance_changed`,
  after its socket connects or reconnects, on window `focus`, and on
  `visibilitychange` to visible. It applies `rendered` if it differs from what
  it shows, and only the answer to its latest GET, so a slow answer cannot
  restore an older state.
  - The GET carries that tab's own cookie. A tab of the same browser picks up
    the change, and a tab of another browser finds nothing new. The push needs
    no browser identity, so a fresh browser behaves like any other.
  - The cost is one small GET per open tab on the host for each change.
  - A tab never answers a push or a GET with a POST, so one change cannot
    cause another.
- **Other workspaces.** A host can push only to its own sockets. A change made
  in workspace A does not reach a tab of workspace B that is already open in
  the same browser. B catches up when it becomes active, through the focus and
  visibility checks. Of two windows side by side, the one not focused stays
  stale until it is. A notification across hosts would need each host to reach
  the others, and the focus check needs nothing new.
- **Pages without a socket**, such as the plugin manager, render from the
  cookie and make the same GET on focus, on visibility and on Refresh.

### Server commands

`/theme`, `set_appearance` and the CLI run on the server, where no browser is
involved. They send `appearance_request` to every connected socket, with only
the fields the command sets, and each tab that receives it POSTs those fields.

- When one browser has several tabs open, the first POST changes the cookie
  and sends `appearance_changed`. The other tabs' POSTs merge the same fields
  and find nothing changed.
- If two POSTs race with the old cookie, both write the same merged values,
  and the extra `appearance_changed` only causes GETs.
- Browsers that are not connected keep their choice.

The model reads what each connected tab shows from `(workspace .appearance)`:
one entry per tab, with its saved and rendered values. Each tab reports them
over its socket after applying a change.

### Controls

- **The mode toggle** sits in the host bar (`#ui_host`, beside Notifications)
  and in the plugin manager's actions, which the recovery server also serves.
  It is labeled with the mode it switches to. Both places work with every
  plugin disabled. The Workspace status drawer and the sidebar footer would
  not: a sidebar plugin can omit or replace them.
- **Settings → Appearance** is a section for this browser: a theme picker with
  previews, then mode, density, text size and content width. It uses its own
  action, since these are not setting definitions.
- **`/theme`** with no argument reports the saved and rendered appearance and
  lists the installed themes. `/theme light` and `/theme dark` set the mode,
  and `/theme <name>` sets the theme.
- **`set_appearance`** takes the fields to set, `(set_appearance {^mode
  "dark"})`, so the model and `/run` can change it.
- **CLI:** `command /theme dark` goes through the generic command path.

`/theme` and `set_appearance` are host-owned rows contributed by `"core"`, and
the kernel reserves the `theme` command name. Disabling or replacing plugins
never removes them.

### Pages

| Page | Appearance |
| --- | --- |
| `/` | From the cookie, with live updates |
| `/?ui=default` (safe UI; `/ui/default` redirects here) | From the cookie, with live updates. Built-in themes only, and no plugin token overrides or styles, so a broken plugin theme cannot lock the user out. |
| Plugin manager | From the cookie on load; the GET on focus and Refresh |
| Recovery server (`--recovery`) | Serves the plugin manager page. Built-in themes only. Offers the same endpoints. |
| `/about/` (embedded) | From the cookie, rendered per request |
| Static website export | `default`, light. There is no browser choice to read. |

## Customization

Four parties customize different things:

| Who | Customizes | Through | Scope |
| --- | --- | --- | --- |
| Theme author | Every value | A built-in theme file, a `themes` row, or the theme editor | An installed theme |
| User | Theme, mode, density, text size and content width; dock side and width, docked or full view, sidebar shown, host bar shown | Settings → Appearance, the mode toggle, `/theme`, `set_appearance`, host controls | The browser for appearance; the tab for presentation |
| Plugin author | Their content, their regions (sidebar replacement, views, slots) and their view's tokens | Components, `style`, `ui_configure ^tokens`, component tokens | Their contributions, or the page if they choose |
| Host | The shell structure and the recovery path | The system | — |

**The layout is customizable at four levels:**

1. **Sizes are tokens.** A theme sets the sidebar width, content width,
   gutters and drawer widths.
2. **The user** chooses content width and density, and controls dock side,
   dock width, docked or full view, sidebar visibility and host bar visibility
   per tab. A sidebar width handle, remembered per tab like the dock width,
   fits the same model.
3. **Plugins** own region content: the replaceable conversation sidebar,
   views, and the `sidebar`, `toolbar`, `composer`, `status` and `welcome`
   slots.
4. **The shell structure is a documented contract.** A plugin with a page-wide
   style can rearrange the grid, and the hooks below let it survive host
   changes.

Rearranging regions by drag and drop, or a layout editor, is out of scope.
Each movable region would need keyboard docking, persistence and a
narrow-width behavior for every arrangement. The shell's four regions already
offer the useful arrangements: docked left, docked right, full, and sidebar
hidden. More arrangements, if wanted, are named presets (`grid-template-areas`
strings in the theme), not free-form docking.

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
| `[data-component="<name>"]` | A contribution's wrapper: slot wrappers, `#ui_view`, `#sidebar_view` | |
| `:root[data-mode]`, `:root[data-theme]` and the preference attributes | Mode, rendered theme and preferences | |

Other class names are internal. They remain usable, but they may change
without notice.

## Plugins

### Defaults for ordinary views

The host styles supported headings, paragraphs, lists, links, code,
preformatted text, rules, progress bars, summaries, buttons, forms, tables,
badges and notices inside `.plugin_component` and `.ui_panel`. These rules
live in the host's `content` layer, so any plugin rule wins. A plugin view
built from these elements and the shared classes looks complete in both modes
and every theme without a stylesheet.

The shared classes are `web_card`, `web_stack`, `web_row`, `web_spread`,
`web_grid`, `web_tight`, `web_loose`, `web_actions`, `web_badge` (with
`_danger` and `_success`), `web_notice` (with `_error` and `_success`),
`web_metric`, `web_muted`, `web_danger_text`, `web_success_text`,
`web_table_compact`, `web_split`, `web_scroll_x`, `web_dialog`, `web_listbox`,
`web_field`, `web_tabs`, and the button variants `web_primary`,
`web_secondary` and `web_danger`. The [Styling section of the component
contract](web-components.md#styling) documents them with an example that uses
no custom CSS.

When several plugins need the same missing style or structure, it becomes a
shared class.

### Style contributions

A `web_components` row (any slot) may carry an optional `style`: `$css` node
data such as `(css (rule ".grid" (decl display "grid")))`. The client mounts
the rendered CSS as a `<style>` element and replaces or removes it with the
component.

- **Scoped by default.** `validate_web_component` in `src/ui/components.gene`
  renders the style when the row is contributed. It wraps the data in
  `$css/scoped` labeled `plugin_<name>` and stores the rendered text as
  `style_css` and the scope class as `style_class` (for example
  `plugin_board__3f…`).
- **Page-wide on request.** `^!style_scoped` renders the data as given, with an
  empty `style_class`.
- **Errors.** Data that `$css/render` rejects, or a result over 64 KiB, fails
  the contribution with a component error naming the cause.
- **Delivery.** Slot components carry `style` and `style_class` in the status
  payload's `web_components`, and view descriptors carry them in `ui/state`.
  `sync_plugin_styles` in `client/main.gene` keeps one
  `<style data-component="…">` per contribution in the hidden
  `#plugin_styles` container, and rewrites the set only when it changes. The
  scope class goes on the component's wrapper: the `.plugin_component` div for
  slots, `#ui_view` for the active view, and `#sidebar_view` for a
  `conversation_sidebar` replacement.
- **Lifecycle.** Replacement updates a style, and removal or disablement
  removes it. The safe UI and the recovery server mount no plugin styles.

Scoping avoids accidental selector collisions. It is not isolation: authors
can deliberately use broader rules when their integration needs them.

### Token overrides

`ui_configure ^tokens` overrides tokens for the plugin's view, per mode:

```gene
(ui_configure {^^enabled ^layout "panel" ^panel "project_board"
  ^tokens {^light {^accent "#335577"} ^dark {^accent "#9db4d6"}}})
```

- **Keys.** Any color role, plus the tokens the view's own plugin declares (see
  [Plugin-defined structures](#plugin-defined-structures)). A color role takes
  a six-digit hex color, and a declared token takes any CSS value.
- **Maps are per mode.** A flat map, or one that mixes mode keys with token
  keys, is refused. A mode without overrides uses the theme.
- **Application.** The client applies the current mode's map to `.ui_panel` as
  inline custom properties each time the layout runs, including after every
  accepted status and every appearance change. It first clears every property
  it set before, so switching to a mode with fewer overrides leaves no stale
  values. Derived tokens recompute inside `.ui_panel`.
- **Contrast.** Plugin values are the author's decision and are never refused
  on contrast grounds.

### Plugin-defined structures

**Why the theme must reach structures that plugins define:**

1. **Much of the product is plugins.** The conversation sidebar, Settings, the
   model and provider screens, voice, spotlight and the workspace manager are
   all plugins, and response cards use the same vocabulary. A theme that cannot
   reach plugin structures cannot style the product.
2. **Plugins build structures the host never will**: boards, sheets, timelines,
   charts, game boards, palettes. When the user switches themes, these follow
   (rounder corners, warmer grays, a new type scale) without their authors
   editing anything.
3. **Without roles, plugins hard-code values**, and those values disagree with
   every theme but one.
4. **Domain visuals need values tuned per mode.** Without `series-*`, every
   chart plugin would choose its own hues, which would clash with each other and
   with one of the two modes.

**How, in order of preference:**

1. **Use roles.** Plugin CSS reads role tokens. Fallbacks such as
   `var(--surface, #fff)` never apply inside the Harness and are not needed. A
   dialog plugin such as spotlight needs no literals and no dark-mode block:

   ```css
   .spotlight-backdrop { z-index: var(--layer-dialog); background: var(--scrim); }
   .spotlight-dialog { background: var(--surface-raised); border: var(--border-width) solid var(--edge);
     border-radius: var(--radius-surface); box-shadow: var(--shadow-overlay); }
   .spotlight-option { padding: var(--space-2) var(--space-3); border-radius: var(--radius-row); }
   .spotlight-option.active { background: var(--action); color: var(--action-ink); }
   ```

2. **Use shared structures.** `web_dialog` (backdrop and raised panel),
   `web_listbox` (option rows with an active state), `web_field` (label,
   control, help and error), `web_tabs` and `web_split` cover the common
   cases.
3. **Expose component tokens, read with a fallback.** A plugin that wants a
   theme to restyle its structure reads each of its tokens with a role
   fallback:

   ```css
   .lane { background: var(--board-lane-surface, var(--soft));
           border-radius: var(--board-lane-radius, var(--radius-surface)); }
   ```

   The plugin never declares `--board-lane-surface` itself. A custom property
   uses the nearest declaration, so a value declared on the plugin's own element
   would shadow the theme's value on `:root`. Reading with a fallback lets a
   theme set the token, per mode, and win. Names are
   `--<plugin id>-<part>-<property>`. The contribution lists them so they can be
   discovered:

   ```gene
   ^tokens [{^name "board-lane-surface" ^fallback "var(--soft)" ^doc "Lane background."}]
   ```

   The host lists declared tokens in the specimen view and in
   `(workspace .theme_tokens)`. A theme can set them, and so can
   `ui_configure ^tokens` for the plugin's own view.
4. **Theme rules aimed at plugin markup.** As a last resort, a theme's `style`
   can target stable hooks such as `[data-component="board"] .lane`. This ties
   the theme to the plugin's markup, so it fits only when a token cannot
   express the change.

### What the theme covers

| Area | Provided by the host | Plugin responsibility |
| --- | --- | --- |
| Shared appearance | The theme's colors, typography, borders, shapes, focus and interaction states, in both modes | Use them, override tokens, or add CSS when the view needs it |
| Common structure | Styled standard controls and the shared classes | Compose them into the view |
| Specialized layout | Theme-compatible building blocks and region container queries | Spreadsheet column sizing, timeline tracks, chart layout, custom density, sticky regions, view-specific responsive behavior |
| Domain visuals | `series-*` and the status roles where their meaning fits | Diagram legends, document and media content, other domain values; component tokens to make them themable |
| Behavior | The existing component interaction contracts | Data, behavior, and keyboard and accessibility behavior for new custom widgets. Styling alone does not make a widget. |

The plugin author documentation keeps this boundary, so authors can tell
whether to use a host structure, add a small style contribution, or propose a
shared class.

**Trust.** Plugins are trusted code. The host provides the `$css` renderer and
scoping helpers. It does not sanitize plugin CSS, restrict selectors or
properties, or contain a plugin that deliberately changes host styling.
Keeping a custom view readable in both modes is the author's responsibility.

## `/about/`

`/about/` is part of the Harness and takes the theme the way a plugin view
does. It owns no palette.

- **Stylesheets.** It keeps its own layout, its `$css` scoping
  (`harness_site`) and its generated, content-addressed stylesheet, and links
  the host and theme stylesheets before it. The static export publishes all
  three.
- **Host names only.** Its rules read the host roles directly and never
  declare a local property with a host token's name. A local `--surface` would
  shadow the theme's value for every site rule that reads it, and a mapping
  such as `--ink: var(--ink)` is a cycle that is invalid at computed-value
  time.
- **Elements.** Call-to-action links, the menu toggle and the copy buttons read
  `radius-control`. The footer is a `surface-alt` band with a `line` rule.
  Eyebrows and highlights use weight or uppercase rather than a hue. Code
  samples use the `syntax-*` tokens.
- **Rendering.** The embedded page renders its `<html>` attributes and theme
  link per request from the cookie. It needs no session, and appearance is not
  sensitive.

## Page security

Harness pages send no Content-Security-Policy. Inline styles, external
resources such as web fonts, connections and framing follow the browser's
ordinary rules. Pages keep the `Cache-Control: no-store`, `nosniff` and
`no-referrer` headers. Libraries a page loads share that page's access.

Mutations, including the appearance POST, use same-origin and CSRF admission.
The workspace image route keeps its own sandbox policy and rejects scripted
SVG, so an image opened directly never gains a Harness page's script access.

Component validation is a separate contract: quoted component trees have no
style prop. Plugin CSS goes through `style` and `$css` with its normal
generation diagnostics.

## Designer workflow

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
   The Samples selector groups palette, type/icons, scales, shared structures,
   host structures and plugin tokens so each rendered tree stays within the
   component contract’s 64 KiB bound. Preview fonts and animations are
   namespaced so they cannot replace the active page’s resources.
3. **Check the real app** at widths 320, 390, 768, 1024 and 1440px. Cover:
   - views docked at 25%, 50% and 70% on both sides, and the full view
   - sidebar collapsed, and long titles
   - the safe UI, the recovery UI, the plugin manager and `/about/`
   - 200% text size, and each `text_size` preference with a view docked at
     1024 and 1440px
   - forced colors
   - reduced motion, with a theme whose durations are not zero; `minimal` has
     none, so it would hide a failure
   - `minimal` as well as `default`, since `minimal` takes whatever it does not
     set from `default`

   Resizing the window in browser automation can be unreliable. A same-origin
   `<iframe>` of the target width works, since pages send no CSP.
4. **Run the guards** with `../../bin/gene test` from `examples/gene-harness`.

## Guards

`tests/unit/web/theme_spec.gene` lints host code and the built-in themes. It
does not restrict plugin or user themes.

- No color literal (hex, `rgb()`, `hsl()`) outside `src/web/themes/`. The scan
  covers built-in plugin stylesheets too.
- In host CSS, `font`, `font-size`, `padding`, `margin`, `gap`, `z-index`,
  `border-radius`, `box-shadow` and `transition` values are `0`, `auto`,
  `inherit`, a token, or a `calc()` of tokens. A short list names deliberate
  exceptions with their reasons, such as the image-grid insets.
- A built-in theme's `style` follows the same rule. A literal in `default`'s
  `style`, such as a fixed radius on cards, would reach `minimal` with no token
  for `minimal` to override.
- Host markup uses icons by name, never text glyphs, and every name in the
  vocabulary has a drawing in `default`.
- Every shell query uses a named breakpoint, and no host or client code
  compares the window width with a number.
- The `preferences` layer is declared first and holds only `!important`
  declarations. Every user setting the host applies is declared there.
- The contrast floors hold for `default` and for `minimal`'s resolved tokens,
  in both modes.
- The specimen covers every shared `web_*` class.

## Moving the code to this design

The migration is organized into the phases below. The runtime now separates
host modules, resolved theme stylesheets and browser appearance. Phase 4
remains a later project; the first three phases provide the designer workflow.

**Phase 1: tokens and the two built-in themes.**

- Add the type, spacing, shape, border, elevation, layer, motion and layout
  tokens. Move every value into `src/web/themes/default.gene`, and add
  `src/web/themes/minimal.gene` with its values. The generator in
  `src/web/theme.gene` resolves `extends`.
- Give the roles that have no value yet (`warning`, `info`, the status
  surfaces, `series-1` … `series-8`) initial values in `default` that pass the
  floors.
- Rename to the design's names:
  - palette `sidebar` → `surface-alt`, `user` → `message-user-surface`
  - `radius-button` → `radius-control`, and `shadow-menu` → `shadow-raised`
  - the aliases `input-surface`, `selected-surface`, `code-surface`,
    `notice-surface` → the component tokens and roles above
  - `data-theme` (the mode) → `data-mode`
  - `ui_configure ^theme` → `^tokens`, and update
    [web-components.md](web-components.md) with it
- Rewrite `src/web/style.gene`, the plugin manager styles,
  `src/website/style.gene` and the spotlight stylesheet to read tokens:
  - Set the root font size to `100%` instead of `16px`.
  - Convert the px layout widths to the `rem` layout tokens.
  - Replace the literal mono stack in `.command_output` with `font-mono`.
  - Move the narrow overlay styling out of the 760px block into `narrow`, and
    delete the rules that repeat the 900px block.
  - Give `shadow-raised` its dark value.
  - Remove spotlight's literals, fallbacks and `[data-theme=dark]` block.
- Snap font sizes to the scale. The current 27 values map as .63–.7 →
  `text-2xs`, .72–.78 → `text-xs`, .8–.85 → `text-sm`, .88–.95 → `text-md`,
  1–1.1 → `text-lg`, 1.15–1.25 → `text-xl`, 1.4–1.65 → `text-2xl`, and
  1.8–1.9 and the clamp → `text-display`. The six weights map onto the three.
  Paddings, margins and gaps snap to the space scale, which moves some
  elements by up to about 1px.
- Split `base_styles` into modules under `src/web/style/` in the layers
  `preferences, reset, base, shell, components, content, utilities`. The
  reduced-motion and forced-colors blocks move into `preferences`. The
  `:where()` wrappers and the "select rule comes last" ordering go.
- Until Phase 3 moves appearance to the browser, the theme name sits next to
  the mode in the workspace appearance setting, so the owner's workspaces
  render `minimal` while the designer's render `default`.
- Replace the guard that asserts square corners with the guards above.

**Phase 2: responsive structure and the specimen.**

- Make `body` the `shell` container and add the breakpoints. Generate `narrow`
  from each theme's layout sizes. Add `$dom/style_value` and switch the
  client's `narrow_sidebar?` from `inner_width` ≤ 900 to `--shell-narrow`.
- Make the regions containers and add the `$css` `container` node.
- Support modes for part of a page, and put `data-component` on `#ui_view`
  and `#sidebar_view`.
- Add `web_dialog` and `web_listbox` (what spotlight needs), then `web_field`,
  `web_tabs` and `web_split`.
- Build the specimen view and add the touch-target rules.

**Phase 3: themes, fonts, icons and per-browser appearance.**

- Add the `themes` registry for plugin themes, and one stylesheet per theme.
- Store appearance in the cookie. Implement:
  - the split between saved and rendered values
  - the merging POST and the GET
  - `appearance_changed` and `appearance_request`
  - the re-reads on connect, focus and visibility

  Remove `<state_root>/appearance.gene` and `src/runtime/appearance.gene`'s
  per-workspace setter, which publishes even when nothing changed. Render
  `/about/` per request instead of pre-rendering one page per mode
  (`about_pages` in `src/web/server.gene`). Update the statement in
  [workspace views](workspace-views.md) that cookies handle only
  authentication. Add the theme picker and the new preferences to
  Settings → Appearance.
- Restrict the safe UI to built-in themes.
- Add web fonts: `$web/font`, the `$css` `font_face` node and preloads.
- Add icons: the vocabulary, mask rendering, the `icon` node and `icons` rows,
  and replace the glyphs in host markup.
- Add plugin component tokens, and widen `ui_configure ^tokens` to every color
  role and declared token.

**Phase 4 (later): user themes.** Duplicate, the theme editor, the library in
the manager root, and export as plugin source.

The designer needs Phases 1 to 3. They can start on palettes, the type scale
and spacing after Phase 2, restarting the host to see each change. Phase 3 adds
live reload, fonts and icons.

## Open questions

1. **Server commands under per-browser appearance.** `/theme`,
   `set_appearance` and the CLI have no browser, so every connected browser
   adopts their change. The alternative is to have them set a workspace-level
   default for browsers with no choice of their own, which would bring back a
   workspace value.
2. **What Duplicate makes.** A duplicate is a frozen copy. The alternative is a
   linked child that `extends` the original and follows later changes to it,
   the way `minimal` follows `default`. Both could be offered: Duplicate for a
   copy, Customize for a child.
