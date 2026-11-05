# Harness theming implementation

Scope: Phases 1–3 of `examples/gene-harness/docs/theming.md`. The user theme
library, duplication and editor remain Phase 4, explicitly deferred by that
document.

The implementation separates host CSS layers from resolved theme stylesheets.
`default` supplies the values and drawings; `minimal` preserves its defining
choices through inheritance. Child shared tokens override parent mode values.
Density scales theme base lengths, and page and region queries follow the
actual root text size. Compact conversations can scroll vertically rather than
clip their composer.

Appearance is an HttpOnly browser cookie. GET returns saved and rendered
preferences; POST merges changed fields and suppresses cookie/event writes on a
no-op. Documents serialize their own POSTs, reject stale GETs, reread on
connection/focus/visibility, and report their applied appearance over the socket.
Server commands request changes from connected browsers. Safe and recovery
pages resolve only built-in themes while preserving an unavailable saved name.

Plugin theme/icon registries, component token discovery, mode subtrees, named
icons, shared structures and the host-owned specimen are available. The
specimen groups its samples to retain the existing component size bound.
Preview font families and animations are namespaced so comparing themes cannot
replace the active page’s fonts or animation definitions.

Standard-library additions are `$css/container`, `$css/font_face`,
`$web/font`, `$dom/style_value`, and `$browser/visible?`. Generated font routes
use font MIME types and immutable content addresses. Binary font bodies remain
`Bytes` at the export boundary. No Gene syntax was changed.

## Validation

- An earlier full Harness suite passed **860 tests**, with no failures or
  errors. The last full run recorded **863 passed, 0 failed, 1 error**: it
  had collected the font test before its invalid `Bytes` type-name assertion
  was corrected. The current source contains no such assertion. A fresh
  current-source unit run passed **299 tests**, including the corrected font
  test and its binary export round trip, with no failures or errors.
- Focused appearance and compiled-client regressions passed, including missing
  theme fallback, merging/no-op writes, CSRF admission, recovery, plugin theme
  replacement/removal, declared tokens, stale reads and rapid browser changes.
- The theming guards cover host and built-in plugin styles, preference layer
  precedence, named queries, drawings, specimen coverage and contrast for both
  built-ins in both modes, including derived syntax colors.
- Pinned TypeScript and DOM binding checks passed.
- Native DOM component/socket fixtures and all three existing CSS renderer
  regressions passed with the rebuilt runtime.
- A fresh static export at `/theming-review/` rendered default/light, linked
  all three stylesheets, and wrote all eight generated assets with contents
  identical to the published routes.
- Native Chrome confirmed mode switching and the side-by-side specimen. The
  final browser pass completed through native Computer Use on 2026-11-05;
  Playwright was not used.

The browser pass checked **1,124 cases**, with no remaining failures:

- **240 page cases:** app, docked/full specimen, safe UI, plugin manager and
  `/about/`, at 320, 390, 768, 1024 and 1440px, normal/200% text, and both
  themes in both modes. Checked horizontal overflow, composer reachability,
  the CSS/client narrow flag and available specimen ratios.
- **640 docking/preference cases:** 1024/1440px, every text-size preference,
  25/50/70% on both sides, expanded/collapsed sidebar, long titles, both
  densities and every content-width preference. Preferences were changed
  through the appearance API. Checked column minima, placement, density
  steps, overflow and narrow sidebar coverage.
- **104 overlay cases:** spotlight, notification drawers and shared dialogs
  inside the main, view, sidebar and drawer regions. Dialogs covered the
  viewport; drawers stayed within it.
- **12 accessibility cases:** both themes/modes under reduced motion, forced
  colors and coarse-pointer emulation. Default motion measured 100/180ms
  before emulation; reduced motion forced zero even against competing
  unlayered important values. Forced colors preserved code, icon, border and
  selection visibility. Touch controls and row actions met their rules.
- **8 mobile conversation cases:** both themes/modes at normal/200% text.
  Checkbox and radio labels measured 44/88px, radios retained native
  appearance, the composer remained reachable and no horizontal overflow
  appeared.
- **120 recovery cases:** `/`, `/plugins` and `/ui/default` at all five
  widths, normal/200% text and both themes/modes, with loaded content and
  matching first-paint attributes.

The touch pass found that an inline checkbox label ignored `min-height`.
The coarse-pointer preference now makes checkbox/radio labels inline flex
containers. The corrected touch cases and all 14 theming guards passed.

## Button spacing follow-up

Following visual review, the standard control height was reduced from 40px
to 32px, with 4px rather than 8px of vertical button padding. Confirmation,
notification and question-editor buttons also use smaller vertical margins.
The menu icon is centered without padding so it fits compact density.
These values remain theme tokens and are inherited by `minimal`; the coarse
pointer target remains 44px. All 14 theming guards passed after this adjustment.
The 1,124-case browser acceptance above predates this spacing follow-up.

## Acceptance audit

The implementation scope follows the document's migration phases and Pages
table: Phases 1–3, browser synchronization for the app and manager, and
per-request appearance for embedded `/about/`. Phase 4 remains deferred.

| Requirement | Evidence | Result |
| --- | --- | --- |
| Token vocabulary, built-in values and inheritance | `src/web/theme.gene`, `src/web/themes/`; inheritance, completeness and parent-redesign guards in `tests/unit/web/theme_spec.gene` | Passed |
| Host and built-in plugin rules use tokens; cascade and preference precedence | Split style modules and built-in plugin styles; declaration/first-layer guards and browser preference/emulation checks | Passed |
| Built-in contrast floors in both modes | Contrast guard covers text, status, borders, focus, action text, series and derived syntax colors on their backgrounds | Passed |
| Mode subtrees, component hooks and derived tokens | Theme generation, component validation and preview CSS; side-by-side specimen and layout matrices in Chrome | Passed |
| Named shell breakpoints, region containers and CSS-driven client state | `src/public/web_style.gene`, style modules, `$css/container`, `$dom/style_value`, client sidebar; guards, bindings and browser matrices | Passed |
| Shared structures and host-owned specimen | `src/web/specimen.gene`, content styles and core registry reservation; all shared classes and bounded sample groups checked | Passed |
| Cookie-only appearance, saved/rendered split and first paint | `src/web/appearance.gene`; HTTP appearance tests, page attribute tests, missing-theme and recovery tests | Passed |
| Merging writes, no-op suppression, CSRF, latest reads and propagation | HTTP tests, runtime event tests and compiled `tests/appearance.mjs` fixture | Passed |
| Core commands, browser reports and plugin-independent controls | Runtime appearance/commands, registry reservations, push reports, host-bar and manager controls; runtime and HTTP tests | Passed |
| Theme/icon registries, plugin lifecycle and declared token overrides | Theme registry, component validation and UI state; replacement/removal/safe-mode and owner-token tests | Passed |
| Fonts, preloads, immutable publication and static export | `$web/font`, font-face renderer, binary export round trip and inherited-face/preload tests; built-ins currently use system fonts | Passed |
| `/about/` styling and static three-stylesheet export | Website page/style/export modules, first-paint guards, browser width matrix and fresh export with all eight assets checked | Passed |
| Current app layout at all specified widths, text sizes and dock settings | Final page, docking, mobile and recovery matrices described above | Passed |
| Forced colors, reduced motion, coarse pointers and viewport-covering overlays | Native Chrome emulation and overlay measurements described above | Passed |

## Language/tooling observations

The web profile still requires binary arithmetic where the VM permits a
variadic sum. The contrast calculation groups its terms explicitly; this work
does not alter arithmetic semantics. Computed CSS numbers use the existing
numeric JSON reader at the boundary. A general numeric-text parsing API would
be useful beyond these canonical CSS values.
