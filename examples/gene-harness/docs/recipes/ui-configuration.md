# Configure the experimental UI

Discover `ui_configure`, then enable a view and set fresh-tab defaults:

```gene
(ui_configure {^^enabled ^default_view "repair_desk" ^layout "panel" ^panel "repair_desk"
  ^side "left" ^width 55
  ^theme {^ink "#203038" ^muted "#55656d" ^line "#ced8d5"
          ^surface "#fcfbf7" ^sidebar "#edf3f0" ^soft "#e5eeea"
          ^accent "#27645b"}})
```

`layout` is chat or panel; `side` is left or right; `width` is an integer from
25 to 70. Theme keys are ink, muted, line, surface, sidebar, soft and accent,
with six-digit hex colors. Configuration belongs to the workspace and supplies
fresh-tab defaults. The View picker, Show/Hide chat, dock side and width are
tab-local; they do not call `ui_configure`. `default_view` takes precedence over
the legacy `panel`/`layout` choice; `harness` means Classic alone. Canonical
`view` rows default to full screen and legacy panels to docked presentation.
Themes apply to plugin content only; host controls retain their own palette.

`(ui_configure {^!enabled})` disables customization without deleting records.
The `/ui/default` recovery page omits custom components and theme, retains the
selected conversation, and provides a return path. See `harness/ui/publication`
for what to verify after changing the configuration.
