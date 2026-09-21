# Persistent Gene body routines

`routines.register` retains a handler revision, explicit inputs, ownership,
organization, clock, and dispatch progress. It does not invoke the model.
Registrations may be staged with other local data through the same `tx` handle.

```gene
(routines .register "garden/controller" revision
  ^handler "run"
  ^clock "simulation"
  ^every_ms 1000
  ^bindings {^root "garden/controller-state"})
```

A module handler exports `run(api, input)` (or the name supplied as `handler`).
A saved expression evaluates to an ordinary function accepting those same two
arguments. `api` contains the selected application bindings. `input` contains
`registration`, `generation`, `delivery_id`, `clock`, `now`, `elapsed_ms`,
`events`, and the explicit `bindings` payload. The code is loaded by the normal
Gene loader/evaluator in a supervised process.

`simulation` uses the retained world clock and pauses during downtime. `wall`
uses Unix milliseconds. These interval registrations **coalesce** missed firings:
one invocation receives the elapsed interval, rather than replaying a backlog.
The handler decides how to account for that interval. The first rest example
uses simulation time; it does not infer energy recovery from offline wall time.

For event subscriptions, use `^clock "events" ^events ["job_outcome"]`.
Delivery batches up to 32 matching observations and retains the event identities
already dispatched. Event receipt and model consideration remain separate from
subscription delivery.

Each registration permits one pending invocation. Its publication and dispatch
cursor are committed together. Re-registering the same active ID with an
identical specification preserves progress. Replacing its specification creates
a new generation; queued old-generation invocations lose dispatch authority.
`routines.cancel(id)` retires a registration. Owner cancellation invalidates
owned registrations and invocations as well as jobs and schedules.

The foreground queue applies bounded service fairness so a backlog of successful
callbacks cannot keep attention or an accepted decision waiting indefinitely.
There are at most 64 active registrations, and timer intervals must be at least
100 milliseconds. Failing invocations suspend their registration and retain
their actual partial effects, outcome, and a failure observation. Routine writes
and successful timer returns do not automatically wake the brain.

## Recovery contracts

The default `^recovery "interrupt"` contract never replays a started arbitrary
handler. Restart retains its partial effects and suspends its registration for
inspection and repair. A published invocation that never started remains
eligible under the same execution ID.

`^recovery "checkpointed"` is an explicit library contract: the handler must
retain the checkpoint and deduplication information needed to resume the same
delivery safely. A fresh process may invoke that handler again with the same
saved delivery ID and input. Declaring the contract does not make arbitrary
effects safe to repeat. The rest controller demonstrates the contract with
atomic data/clock updates and rejection of repeated or older timestamps.

Its tests kill the host immediately before and after a recovery commit. Both
paths restore the same invocation and finish at energy 42, without crediting the
elapsed interval twice. Sleep entry also has before/after-commit process tests,
so mode, activity, clock checkpoint, and registration appear together.

## Organization selection and repair

Registrations participate in organization compatibility decisions. An old
registration must be retained as explicitly compatible, invalidated, or replaced
by migration code. Migration may call `routines.register` and `routines.cancel`
with `input/tx`; replacement registrations belong to the candidate organization.
The selected definition retains their IDs and code references. A queued old
callback never runs against a newly selected incompatible layout.

The stable operator interface supports `register-routine` and `cancel-routine`,
as well as raw inspection. Registration fields use the same names as the Gene
API. These commands work while paused, but dispatch waits for resume. A repair
updates code selection and retained progress deliberately; it never rolls back
newer conversations or cognitive data.

## Energy and sleep example

[`body/rest.gene`](body/rest.gene) invents the `model/rest` record and its meaning.
`rest.sleep(revision)` atomically stores sleeping mode, an activity reference,
the current simulation checkpoint, and one recovery registration. Its controller
restores two modeled energy units per simulation minute, starting at 24 and
waking at 70. Re-entering the same sleep activity does not add another timer.

On waking, the same transaction completes the activity, retires the recovery
registration, and retains one cognitive wake request. The optional
`rest.account_for_activities(revision)` handler charges eight energy units per
new activity outcome and enters rest at or below 24. Those choices are ordinary
Gene constants and state, not host budgets or biological measurements.

The module also exports an attention policy. Ordinary observations remain
durable during sleep without model calls; a failed routine or a chat containing
`!urgent` may request attention. The wake transition revisits retained events.
No host branch interprets energy or sleeping mode.
