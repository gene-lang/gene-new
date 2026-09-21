# Schedules, recurrence, and host budgets

One-shot `scheduler.after` and `scheduler.wake_after` use wall-clock milliseconds.
Known code retains explicit input bindings and a lateness policy. Wakes request
fresh context. Neither a return value nor a decision note is a chat reply.

```gene
(scheduler .cron "0 9 * * *" "America/New_York"
  ^code (quote (scheduler .wake_after 0 "Review today's interests and commitments"))
  ^bindings {}
  ^missed "coalesce_once")
```

Omit `code` and provide `reason` to request a cognitive wake directly. An explicit
quoted `nil` program is valid silence. The five cron fields are minute, hour,
day of month, month, and day of week. They support numbers, lists, inclusive
ranges, steps, `*`, month names and weekday names. Sunday accepts 0 or 7.
When neither day field starts with `*`, the day fields match with OR; otherwise
both must match. Calendar search is bounded to eight years, covering the leap-century
gap. Invalid or impossible expressions report a failure instead of blocking forever.

## Retained timezone rules

The platform adapter imports installed IANA data through `zdump`. Its
[documented interval format](https://raw.githubusercontent.com/eggert/tz/main/zdump.8)
supplies local transition times and UTC offsets; Gene converts them into a
retained transition table. Subsequent occurrence calculations use that table,
without platform timezone queries. `UTC` needs no external utility.

The supported host layout is macOS/Linux with `/usr/share/zoneinfo` and `zdump`
supporting `-i`. Unknown names and path traversal are rejected. The default
snapshot covers 1970 through 2100 inclusive; explicit imports can extend through
2500:

```gene
(let zone (scheduler .timezone "America/New_York" ^through_year 2110))
(scheduler .cron "30 1 * * *" zone ^reason "Daily review" ^missed "coalesce_once")
```

Schedules retain a hash-addressed rule revision. Restart uses that revision.
`scheduler.timezone` with `refresh: true` selects newly imported rules for later
schedules and leaves existing schedules pinned. Re-register a known schedule ID
to adopt another revision. A horizon error suspends future recurrence with an
observation; the body remains responsive. The last known due occurrence can run
even when its successor exceeds the retained horizon.

Nonexistent civil minutes are skipped. A repeated civil minute runs only at its
earlier UTC instant. These rules handle arbitrary offset changes, including
fractional offsets. Import a named timezone before using it inside a grouped
callback; a group can use a prepared descriptor or an already imported name but
cannot initiate a platform lookup.

## Missed occurrences and identity

| Explicit policy | After pause or downtime |
| --- | --- |
| `"coalesce_once"` | Publish one invocation or wake for the latest eligible occurrence and retain the next future time. |
| `{^run_within_ms 60000 ^otherwise "expire"}` | Run the latest occurrence only within its allowed window; otherwise record it as missed and retain the next future time. |

There is no implicit backlog replay. Occurrence IDs include the schedule ID,
generation, and due timestamp. Publication advances recurrence and records its
queued invocation atomically. Restart dispatches a committed invocation that
never started under its original identity. A started arbitrary invocation remains
interrupted; a later calendar occurrence has a distinct ID. Earlier partial
effects are never reconstructed by replaying that old invocation.

Admission rechecks cancellation, generation, organization, ownership and lateness
when dispatch actually begins. Queue time does not extend the allowed window.
Once started, execution budgets control duration. Two consecutive failed or
interrupted recurring programs suspend the schedule; a success resets the count.
Expired windows do not count as program failures. Results retain occurrence and
cause references. Successful known code does not wake the model unless it asks.

`scheduler.get(id)` inspects a retained schedule; `scheduler.cancel(id)` revokes
its queued or active work. `after`, `wake_after` and `cron` accept `id` to replace
an existing schedule, advancing its generation. Old queued programs cannot act
under the replacement. Use owner tokens for schedules related to an intention.
Operator commands `cancel-schedule` and `cancel-owner` provide these controls
without waiting for inference. Partial effects remain inspectable.
Cancellation requests are retained separately from actual execution outcomes.
A withdrawal arriving after a process is known to have completed does not
relabel that completed work as cancelled.

## Inference and correction limits

The default is 100 admitted model attempts per wall-clock hour. Admissions commit
before invocation, survive restart, and are recorded on cycles. The operator
`budget` command sets `model_calls_per_hour`; 0 disables new inference. This host
limit is separate from modeled energy. Exhaustion retains observations while
known code, world progress, receipt and operator controls continue. Later admission
uses fresh context.

Decision failures become non-waking observations accompanying a bounded retry or
new information. Recording an error cannot manufacture another retry budget.
This supplies correction evidence without an automatic think-write-think loop.
