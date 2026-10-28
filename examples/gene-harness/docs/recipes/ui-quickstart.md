# A working UI plugin

Use this complete counter as the first working version of a workspace UI.
Its source, publication response and smoke-check response are exercised by
`tests/integration/ui/quickstart_spec.gene`. Read `gene/overview` alongside this
chapter, then adapt the working example. The default Harness already exposes
`register_plugin`, `ui_configure` and `ui_preview`.
Choose a small useful interaction from the user's task, get it working with
this structure, and then extend it. Styling and extra input mechanisms can be
added to that saved, verified version as their APIs become relevant.

## Save the complete module

Write this first Gene block to `counter.gene` in the workspace. Keep the outer
`(mod plugin ...)`: plugin registration takes one complete module. It imports
only the supported shared API. Rename the plugin ID and contribution names
together when adapting it for an application.

```gene
(mod plugin @interfaces {^core "gene-harness/PluginHost:3"}
  (import ^from "src/plugin_api.gene" [Plugin PluginHost])

  (fn current_count [host] : Int
    (let state (?? host/.PluginHost:state {^count 0}))
    state/count)

  (fn save_count [host, value : Int] : Int
    (host .PluginHost:update_state {^count value})
    value)

  (fn init [descriptor]
    (Plugin ^id "counter" ^requires ["ui/state_lock"]
      ^provides [["functions" "counter_get"] ["functions" "counter_add"]
                 ["functions" "counter_set"] ["web_components" "counter"]
                 ["docs" "counter/usage"]]
      ^activate (fn [host]
        (let with_state_lock (host .PluginHost:resolve "ui/state_lock"))
        (host .PluginHost:contribute "functions"
          {^name "counter_get" ^doc "Read the saved counter."
           ^tags ["counter"] ^docs ["counter/usage"]
           ^fn (fn [] (current_count host))})
        (host .PluginHost:contribute "functions"
          {^name "counter_add" ^doc "Add an integer amount to the saved counter."
           ^tags ["counter"] ^docs ["counter/usage"]
           ^fn (fn [^amount amount : Int = 1]
             (with_state_lock "counter" (fn []
               (save_count host (+ (current_count host) amount)))))})
        (host .PluginHost:contribute "functions"
          {^name "counter_set" ^doc "Set the counter from a numeric text field."
           ^tags ["counter"] ^docs ["counter/usage"]
           ^fn (fn [^value value : Str]
             (let parsed ($parse/parse_int value))
             (with_state_lock "counter" (fn [] (save_count host parsed))))})
        (host .PluginHost:contribute "web_components"
          {^name "counter" ^slot "view" ^title "Counter"
           ^view_state {} ^state_version "1"
           ^actions ["counter_add" "counter_set"]
           ^render (fn [context]
             (let count (current_count host))
             `(section ^key "counter" ^class_name "web_card"
                (h2 "Counter")
                (p ^role "status" ^aria_label "Current count" %($to_str count))
                (button ^key "increase" ^action "counter_add" ^args {^amount 1} "Increase")
                (button ^key "decrease" ^action "counter_add" ^args {^amount -1} "Decrease")
                (form ^key "set-count" ^action "counter_set"
                  (label "Count"
                    (input ^key "count-value" ^field "value" ^type "number"
                      ^value %($to_str count) ^^required))
                  (button ^key "set-submit" ^type "submit" "Set count"))))})
        (host .PluginHost:contribute "docs"
          {^name "counter/usage" ^summary "Saved counter, buttons and numeric form."
           ^tags ["counter" "ui"]
           ^text "Choose Counter in the View picker. Increase/Decrease change the saved value. Set count parses the numeric field. counter_get reads it; counter_add accepts named amount; counter_set accepts named value as text. The saved value survives reload and restart."})))))
```

The counter is durable plugin state. The shared state lock protects updates
from concurrent actions and plugin revisions. Rendering only reads that state.
Form inputs arrive as strings, so `counter_set` parses the value before saving.
The `field` name matches the function's named argument. Controls use stable
keys, and every form/action element is supported by the view validator.

## Publish, then inspect feedback

After saving the file, return this response code. Publication is queued until
the turn ends. The next request includes the plugin status and a view outline
or render error; inspect those before running the smoke check.

```gene
(let contents ($fs/read_text "counter.gene"))
(let forms (($parse/read_all contents) -> $into []))
($assert (== forms/.size 1) "A plugin file must contain one complete module.")
($assert (== ($head forms/0) (quote mod)) "Keep the outer mod form around all declarations.")
(ui_configure {^^enabled})
(append_prompt "plugin"
  (register_plugin "counter" contents))
(Outcome ^prompt "Inspect publication feedback, then run the counter smoke check."
  ^reply "I saved the counter source and submitted its plugin for publication.")
```

For a later replacement, use `register_plugin ^^replace "counter" ...` with
the edited file. Keep source in the workspace so it is easy to test and repair.

## Run the action and preview checks

Use the next response to exercise the same functions as the buttons and form.
The smoke check restores the counter's previous value even if an assertion
fails, and makes Counter the default view after the checks pass. When adapting
it, capture check failures, restore any saved data a check changes, then report
the failure. Omit `^default_view` if the workspace should keep opening its
current view.

```gene
(let before (counter_get))
(let failure
  (try
    ($assert (== (counter_set ^value "10") 10))
    ($assert (== (counter_add ^amount 2) 12))
    ($assert (== (counter_add ^amount -1) 11))
    ($assert (try (counter_set ^value "oops") false catch Any true))
    ($assert (== (counter_get) 11))
    nil
  catch Any $err))
(counter_set ^value ($to_str before))
($assert ($absent? failure) ($to_str failure/message))
(ui_configure {^^enabled ^default_view "counter"})
(let preview (ui_preview "counter"))
($assert ($absent? preview/error) ($to_str preview))
(Outcome ^^done
  ^reply "The counter actions and view preview pass. Select Counter in the View picker to try its buttons and form.")
```

Server preview verifies the view contract. In a browser, select **Counter**,
click Increase/Decrease, submit the field, and reload to check persistence.
Report separately which checks ran if browser access is unavailable.

## Expand the working version

Keep behavior in action functions and durable plugin state. Add a focused
test with each behavior change. Read `harness/ui/forms` for more controls,
`harness/ui/drafts` for browser selection/drafts, `harness/ui/revisions` for
record revisions, and `harness/web_components` for the full element/style
contract. Read the next chapter to resolve a specific implementation question;
continue from the saved source and completed checks.
