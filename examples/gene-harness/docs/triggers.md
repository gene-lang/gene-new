# Schedule workspace work

The active triggers plugin provides create_trigger, list_triggers and
delete_trigger. Discover their signatures rather than guessing.

```gene
(create_trigger
  {^id "nightly-audit" ^kind "cron" ^cron "0 3 * * *"
   ^timezone "Europe/Berlin" ^request "Audit the project."
   ^missed "once" ^overlap "queue_one" ^retention {^keep 30}})
(list_triggers)
(delete_trigger "nightly-audit")
```

Kinds: heartbeat uses positive every_ms; scheduled uses at (UTC timestamp text
or epoch milliseconds); cron uses five fields and an IANA timezone. Other
properties are enabled (Bool), continue_session (Bool), missed (skip/once),
overlap (skip/queue_one), and retention (keep/days). Creating a definition starts
future scheduled work; do so only when the user's task calls for scheduling.
delete_trigger disables future starts.

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
