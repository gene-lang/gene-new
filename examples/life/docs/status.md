# Proposal implementation audit

The goal remains the complete `docs/proposals/life.md` experiment, implemented
in Gene. This is a progress record, not a reduction of that scope.

## Current evidence

`bin/gene test examples/life/tests/` exercises the Gene implementation:

- Explicit create/open, first-start observation, recorded disposition, fake brain.
- Strict text/program framing, validation before effects, bounded rejected cycles.
- Ordinary functions, loops, saved function reuse, and fresh execution processes.
- Silent consideration, internal notes, explicit communication and failed outcomes.
- Arrival during inference without consuming later events.
- Atomic staged walk/state writes; helper missing `tx` rollback.
- Clean restart of identity, memory, working state, world, inventory, conversation,
  activity, and wakeup before inference; offline world time stays paused.
- Separate process killed without a shutdown hook; retained cursor and deduplication.
- Process kills after staging a walk, before commit, and after commit before dispatch.
- Scheduled code with explicit bindings, saved destination, lateness and cancellation.
- Responsive receipt and operator pause during runaway and waiting Gene execution.
- Failed storage commit, immutable snapshots, writer exclusion, and missing-state failure.
- Immutable saved module bundles and transitive imports through the ordinary
  module loader, reused after restart; inert symbols and quoted Gene data persist.
- Replacement memory/state bindings and a selected context builder over an
  immutable read view, with retained read revisions and cycle code references.
- Quiescent code/data selection after the requesting program settles, representative
  preference queries before/after migration, queued-work invalidation, explicit
  compatibility, deferral, and failed-migration rollback.
- Controllable old model responses both before selection and after explicit
  invalidation; late invalidated output is retained without effects.
- Process kills during migration staging, before selection commit, and after commit,
  recovering the complete old or new selection before inference.
- Host repair while paused, independent of a broken selected context builder,
  preserving later conversations and memories.
- Persistent clock/event registrations, once-per-event dispatch, interval
  coalescing, queued restart, failure suspension, generation replacement, and
  foreground fairness for attention alongside a callback backlog.
- Active owner cancellation, paused operator registration repair/cancellation,
  and rejection of backward simulation steps without changing checkpoints.
- Atomic migration of registrations and their code references; old queued
  handlers are invalidated before the new layout becomes executable.
- Replaceable attention/event selection with durable deferral and no repeat
  inference on quiet heartbeats. The rest policy preserves ordinary incoming
  messages while the model is unavailable.
- Gene-authored energy/rest state and handlers: atomic sleep entry, activity
  costs, energy 42 restart, duplicate/older interval accounting, one wake at 70,
  and forced exits before/after checkpoint publication under the same invocation.
- Real filesystem-publication failure preserves the preceding database bytes,
  stops dependent effects and cursor advancement, and requires reopen. A failed
  final checkpoint does not claim a clean shutdown. Optimistic conflicts abort
  complete groups without damaging the connection.
- Ordinary sandbox-loaded Gene program functions, transitive synchronous grouped
  callbacks, no direct I/O namespaces, serialized concurrent root-task API calls,
  and 24 repeated fresh execution-scope iterations retaining only explicit state.
- Separate-process recovery of queued arbitrary jobs/schedules and interrupted
  arbitrary jobs, scheduled programs and uncheckpointed routines without replay.
- Repair of a standalone walking-job link, adapter preconditions after a world
  change during inference, fresh resume context, and late paused-response rejection.
- Required world/activity consistency, invalid head/schema rejection, durable
  commit receipts, and compatible clock/event registration preservation.
- Five-field cron with timezone snapshots, ranges/lists/steps/names, fractional
  offsets, leap-day and daylight-saving tests, explicit missed-run policies,
  one-occurrence coalescing after restart/pause, and retained occurrence identities.
- Queued/active schedule cancellation and replacement, dispatch-time lateness
  checks, bounded recurring program failures, and visible timezone horizon errors.
- Late cancellation requests stay distinct from known completed process outcomes.
- Separate-process recovery of queued and interrupted cron occurrences; an
  interrupted occurrence is not replayed as a new occurrence.
- Durable inference admission budgets across restart, continuing maintenance
  and receipt while exhausted, with fresh context at later admission.
- Declared context ownership dependencies distinguish relevant from unrelated
  generation changes. Rejection/failure observations aid bounded correction
  without becoming an automatic wake source.

The CLI create/run/send/inspect/stop path has also been exercised with two live
Gene processes. Stop acknowledges only after committing its continuation point.
`bin/gene run examples/life/src/demo.gene` also runs the full garden continuity,
withdrawn-request cancellation, and sleep/restart/wake demonstration headlessly.

## Required work remaining

- Bounded longer histories with provenance, retention/deletion and reproducible
  experiment metadata. Event-subscription cursors currently retain delivered IDs
  and need to participate in the eventual history/retention policy.
- Longer histories and richer activity checkpoints; a real communication adapter
  with durable cursors and delivery reconciliation/uncertainty.
- Small browser/3D presentation of authoritative world state and additional
  meaningful activities, preserving headless use.
- Repeatable behavioral comparison harness and reports for memory access,
  decision notes, learned helpers, and optional energy/rest, with comparable budgets.

Do not mark the full proposal complete until these requirements are implemented
and their behavior has direct verification evidence.
