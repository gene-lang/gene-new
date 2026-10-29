# Theming implementation evidence — 2026-10-17

Archived during the 2026-10-29 reference cleanup. This records the original
baseline, checks and rollout; flat theme-map acceptance described here has
since been retired. Current rules are in [Theming](../theming.md).

## Before the theming change

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
- **Computed values.** `button` radius 5px; composer, cards, rows, selects and
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
  button is `ink` with `action-ink` text and the 5px radius.

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
   contribution, documented in the [Styling section](../web-components.md#styling).

The CSP removal shipped earlier the same day. Related docs updated:
`docs/commands.md`, `docs/recipes/ui.md`, `docs/workspace-views.md`,
`docs/web-client.md`, `README.md` and `experiments/ui` (per-mode board colors).
