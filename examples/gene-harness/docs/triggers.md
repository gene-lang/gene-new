# Schedule workspace work

The active triggers plugin provides create_trigger, update_trigger, list_triggers
and delete_trigger. Discover their signatures rather than guessing.

```gene
(create_trigger
  {^id "nightly-audit" ^kind "cron" ^cron "0 3 * * *"
   ^timezone "Europe/Berlin" ^request "Audit the project."
   ^model_settings {^provider "anthropic" ^model "claude-haiku-5-5" ^effort "low"}
   ^missed "once" ^overlap "queue_one" ^retention {^keep 30}})
(list_triggers)
(update_trigger "nightly-audit" {^model_settings {^effort "low"}})
(update_trigger "nightly-audit" {}) # Follow the current default again.
(delete_trigger "nightly-audit")
```

Kinds: heartbeat uses positive every_ms; scheduled uses at (UTC timestamp text
or epoch milliseconds); cron uses five fields and an IANA timezone. Other
properties are enabled (Bool), continue_session (Bool), missed (skip/once),
overlap (skip/queue_one), and retention (keep/days). Creating a definition starts
future scheduled work; do so only when the user's task calls for scheduling.
delete_trigger disables future starts.

Omit model_settings to follow the current workspace/default selection on every
firing. An effort-only map follows the default model at that requested effort;
a model id must include its provider. Triggers do not inherit the creating
conversation's choice. Even with continue_session, an operator changing that
session's model changes only operator rounds. Each triggered round resolves its
own selection and keeps it until that round ends.

update_trigger changes only model_settings, preserving the schedule. Omit that
field or pass nil to clear the pin, including for an occurrence already due.
Already started rounds keep their snapshot. Plugin declarations accept the same
field, and a changed declaration replaces the stored definition. The CLI accepts
`triggers update ID FILE`, and the
browser API accepts PATCH /api/v9/triggers/ID with the same changes map.

Unknown fields and providers are rejected. A signed-out provider or unlisted
model is accepted with returned warnings; review them. Requested effort is kept
and resolved for the model at each firing. A blocked occurrence stays due with
waiting_reason, publishes one workspace notification when blocked, and does not
prevent healthy triggers from running. There is no provider fallback.

Definitions are workspace-wide and can also be managed in the browser's Triggers
view. Occurrences create durable sessions. Already admitted rounds are not
replayed after a crash. Missed/overlapping work follows the selected policy.
Verify the returned definition/list, timezone and occurrence behavior before
claiming a schedule is installed. The scheduler and its functions disappear
when the plugin or its loop dependency is withdrawn.

The polling loop runs as host background work owned by the plugin's activation
effect. It must outlive the activation callback's execution budget; starting it
with a plain spawn inside activation can leave a ready plugin whose scheduler
has stopped. Individual triggered rounds retain their own execution limits.
