# Conversation sidebar plugin

The baseline's `sidebar` plugin contributes the `conversation_sidebar` web
component. It owns the default layout and its navigation guidance. The host
owns the hamburger, responsive layout, session transport and durable state.
The sidebar is optional: disabling it hides the left panel and its hamburger
without closing sessions, tabs or running work. `/ui/default` uses host-owned
recovery navigation and does not run sidebar plugin render callbacks.

The conversation list excludes sub-agent sessions, including search and
filtered results. Open a sub-agent from its delegation block in the parent
transcript at the turn that started the work.

```gene
(disable_plugin "sidebar")
(enable_plugin "sidebar")
(restore_plugin "sidebar")
```

Replace the default with `register_plugin ^^replace "sidebar" ...`. The plugin
contributes one `web_components` row whose **name and slot are both
`conversation_sidebar`**. Use a static `view` or a bounded `render` callback
with the ordinary web-component context. This slot does not use experimental
`view_state`; it works while workspace views are disabled.

Ordinary safe component elements, command/prompt buttons and view navigation
are available. A `host_widget` node mounts one existing host control group:

| Name | Controls |
| --- | --- |
| `brand` | Gene Harness identity and local-host indicator |
| `new_conversation` | New conversation button |
| `filters` | Search, kind, status, trigger and date filters |
| `attention` | Host attention-navigation group |
| `conversations` | Live filtered conversation list |
| `extensions` | Contributions to the existing additive `sidebar` slot |
| `workspace_tools` | Triggers, workspace status and About links |

A widget requires exactly its `name` and has no children. Each name may occur
once in the tree. Widgets are allowed only in `conversation_sidebar`; they
cannot be moved into another plugin view. Omitted controls remain inactive
and invisible in host storage. Their field values and event handlers survive
layout replacement. Identical layouts are not rebuilt during ordinary status
updates, so typing a filter does not lose focus.

Use `sidebar_content` on the root to give the conversation list the remaining
height and keep it scrollable. Branding and headings can be ordinary plugin
content; including the `brand` widget is optional.

```gene
(mod plugin @interfaces {^core "gene-harness/PluginHost:3"}
  (import ^from "src/plugin_api.gene" [Plugin PluginHost])
  (fn init [descriptor]
    (Plugin ^id "sidebar"
      ^provides [["web_components" "conversation_sidebar"]]
      ^activate (fn [host]
        (host .PluginHost:contribute "web_components"
          {^name "conversation_sidebar" ^slot "conversation_sidebar"
           ^summary "A compact project navigation sidebar."
           ^tags ["sidebar" "navigation"]
           ^view (quote (div ^class_name "sidebar_content"
             (h3 "Project workspace")
             (host_widget ^name "new_conversation")
             (host_widget ^name "filters")
             (host_widget ^name "conversations")
             (host_widget ^name "extensions")
             (button ^switch_view "harness" "Open conversation")
             (host_widget ^name "workspace_tools")))})))))
```

Save that source and register it normally. Replacement follows the same
composition leases, publication and restart persistence as other plugins.
A render failure shows a sidebar error and leaves Recovery UI accessible.
The host does not silently restore an overridden layout; `restore_plugin`
explicitly restores the baseline plugin. Sidebar visibility remains local to
each browser tab and the existing desktop collapse preference is retained.
