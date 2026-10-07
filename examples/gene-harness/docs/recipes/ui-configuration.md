# Configure the experimental UI

Discover the active `ui_configure` function, then enable a registered panel:

```gene
(ui_configure {^^enabled ^layout "panel" ^panel "repair_desk"
  ^side "left" ^width 55
  ^theme {^ink "#203038" ^muted "#55656d" ^line "#ced8d5"
          ^surface "#fcfbf7" ^sidebar "#edf3f0" ^soft "#e5eeea"
          ^accent "#27645b"}})
```

`layout` is chat or panel; `side` is left or right; `width` is an integer from
25 to 70. Theme keys are ink, muted, line, surface, sidebar, soft and accent,
with six-digit hex colors. Configuration belongs to the workspace. Shared host
surfaces derive their colors from these tokens, including for dark themes.

`(ui_configure {^!enabled})` disables customization without deleting records.
The `/ui/default` recovery page omits custom components and theme, retains the
selected conversation, and provides a return path. See `harness/ui/publication`
for what to verify after changing the configuration.
