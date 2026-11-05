# Configure workspace UI

The built-in Workspace UI plugin provides configuration and preview functions.
Its persisted plugin ID remains `ui_experiment` so existing settings, stored
overrides and enable/disable choices retain their identity. The implementation
lives in `src/builtin/workspace_ui.gene`.

Discover `ui_configure`, then enable a view and set fresh-tab defaults:

```gene
(ui_configure {^^enabled ^default_view "repair_desk" ^layout "panel" ^panel "repair_desk"
  ^side "left" ^width 55
  ^tokens {^light {^ink "#203038" ^muted "#55656d" ^line "#ced8d5"
                  ^surface "#fcfbf7" ^surface_alt "#edf3f0" ^soft "#e5eeea"
                  ^accent "#27645b"}
          ^dark {^accent "#7fc4b8"}}})
```

Each call changes only the keys it names; omitted keys keep their current
values, so `(ui_configure {^^enabled})` leaves an existing layout and tokens in
place. A supplied `tokens` replaces the whole override map; pass `^tokens {}` to
clear the overrides.

`layout` is chat or panel; `side` is left or right; `width` is an integer from
25 to 70. `tokens` holds `^light` and `^dark` override maps; they accept any color role
with a six-digit hex color and any component token the view’s plugin declares
with a CSS value. Snake-case keys become CSS kebab-case names. Keys a
mode omits keep the host palette. Flat token maps are rejected; use explicit
mode keys. Configuration belongs to the workspace and supplies
fresh-tab defaults. The View picker, Show/Hide chat, dock side and width are
tab-local; they do not call `ui_configure`. `default_view` takes precedence over
the legacy `panel`/`layout` choice; `harness` means Classic alone. Canonical
`view` rows default to full screen and legacy panels to docked presentation.
Token overrides apply to the configured plugin’s views. Host controls follow
the browser’s theme and mode. Settings → Appearance changes this browser;
`(set_appearance {^mode "dark"})` and `/theme dark` request the change in every
connected browser. `/theme <name>` selects an installed theme. The host bar’s
Dark/Light button changes this browser’s mode. Defaults are `default` and light;
the OS color preference is ignored. For CSS a view needs beyond the theme, add a `style` to
its component row; see `harness/web_components`.

`(ui_configure {^!enabled})` disables customization without deleting records.
The `/ui/default` recovery page omits plugin views, token overrides and plugin styles, retains the
selected conversation, and provides a return path. See `harness/ui/publication`
for what to verify after changing the configuration.
