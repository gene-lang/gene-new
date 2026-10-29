# Sub-agents

This reference describes the implemented delegation contract. Dated design
and verification discussion is in the [history record](verification/sub-agent-history.md).

A sub-agent takes one concrete sub-task off a conversation. The conversation
gives it a brief, the sub-agent works on its own, and the conversation gets a
compact result back. This design does not copy another tool's sub-agent
feature. It starts from what the Harness already has: durable sessions that run
in parallel, rounds with budgets, question batches that wait durably, and
request items with stubs and recall.

## What offloading is for

1. **Context isolation.** Reading thirty files, or three failing test runs,
   should not fill the parent's history. The parent needs the conclusion.
2. **Parallel work.** Independent sub-tasks should run at the same time.
   Sessions already run in parallel; one conversation cannot.
3. **A fresh view.** A review or an audit is worth more from a context that does
   not share the parent's assumptions.
4. **A bounded setup.** A sub-task can select its model and budget within
   the parent's provider and workspace caps.

Isolation of authority is not on the list. The Harness has no authority code,
and a child sees the same workspace and the whole standard library. "Do not
edit files" in a brief is an instruction, not an enforced boundary.

## A child session is the sub-agent

A sub-agent is an ordinary session of a new kind, `child`, linked to the
parent round that started it. The session already provides almost everything
the sub-agent needs:

| Need | Already provided by a session |
| --- | --- |
| Own context | Its own history, compaction and recall |
| Runs alongside the parent | Sessions execute concurrently as root-lane tasks |
| Bounded | Round turn limits; trigger rounds already have a wall deadline |
| Inspectable | The user can open its transcript like any other |
| Survives restart | Durable stream; running rounds become interrupted, never replayed |
| Can ask | Question batches wait durably and resume once |
| Follow-ups keep context | A second round in the same session sees the first |

A child adds four things that a session lacks:

- **A parent link.** The child's index record has
  `parent {^session ^round ^delegation}`, and its rounds have the initiator
  `parent:<session>/<id>`, as trigger rounds have `trigger:<id>`.
- **A result.** The child's final Outcome delivers `^reply` and an optional
  `^result` to the parent as a request item.
- **A way for the parent to wait.** This is a round state, not a blocked call.
- **Ownership.** A round owns every unfinished child it started: queued,
  running, or waiting on a question. Cancelling the round cancels all of them.
  The round cannot finish while any of them is unfinished, or while a child's
  result has not reached the model.

Triggers show that the gap is small. A model can already call `create_trigger`
with a `scheduled` kind and the current time to start a session with a brief.
What it cannot do is link the session to itself, get the result back, wait for
it, or cancel it with its own round.

Child sessions share ordinary session machinery. Delegation does not create
a separate agent runtime or run a nested turn loop inside a response.

## The parent's side

```gene
(delegate "auth_audit"
  ^title "Audit auth middleware"
  ^brief "Read src/auth/** and list every route that skips the session check.
Do not edit files. Return the routes as ^result [{^route ^file ^line}].")
(delegate "slow_queries"
  ^title "Find slow queries"
  ^brief "Run tools/query_log.gene on logs/today.log and report the five slowest
query shapes with their counts, as ^result."
  ^turns 8)
(Outcome ^wait "all" ^reply "Two audits are running.")
```

- `delegate` takes an id (`[a-z0-9][a-z0-9_]{0,39}`, unique in the parent
  session), a concise `^title` and a self-contained `^brief`. Optional `^turns`
  and `^timeout_ms` stay within the workspace caps. Titles have at most 256
  UTF-8 bytes; briefs have at most 60,000 bytes, leaving room for the delegated
  request prefix within the normal 64 KiB prompt limit.
- **Children start at the turn boundary, not during the call.** `delegate`
  stages the child in memory and returns a pending handle. Plugin changes are
  published the same way. When the turn ends normally, the host admits the
  staged children in two steps:
  1. **Commit.** One durable write records an admission intent for each child:
     its admission number and the session id and round request id derived from
     it. This write is the commit point.
  2. **Start.** The host creates the child sessions and submits their rounds
     through the existing `submit_round`/`on_admit` path, or leaves them queued
     behind a cap.

  If the turn is cancelled before the commit, nothing starts. After the
  commit, the children belong to the round. Cancelling the round then cancels
  them, so a child may start briefly before its cancellation reaches it. The
  next request reports
  `[57.delegations] started auth_audit (s-3f2a…), slow_queries (s-91c0…)`.
- **The last turn drains, then collects.** `delegate` and
  `continue_delegation` raise an error on the round's last permitted turn,
  before any child starts. That stops a round from adding work it has no turn
  left to read. The round can still reach its turn limit while it owns
  unfinished children or holds unseen results. Rejecting `^wait` would not help
  then. For example, on turn 23 of 24 the parent starts A and B and waits with
  `"any"`. A finishes, and turn 24 runs while B is still running. So the round
  does not fail at the limit:
  1. **Drain.** The round parks in an implicit wait with the full `"all"`
     membership: its unfinished children plus its settled results that the
     model has not seen. The wait is bounded by the children's own budgets.
     If every member is already terminal, the collection continuation is
     scheduled immediately, without waiting for another completion. This
     internal wait never raises the empty-wait error. A round with nothing
     unfinished and nothing unseen does
     not drain at all; ordinary round-limit policy applies (operator rounds pause,
     automated rounds fail).
  2. **Collect.** The round then gets exactly one collection turn past the
     limit. In that turn `delegate`, `continue_delegation` and `^wait` raise,
     and `[harness_budget]` says it is the final collection turn.

  If the collection turn does not end with `done`, ordinary round-limit policy
  applies: operator rounds pause and automated rounds fail. A round therefore runs at most limit + 1 turns. A
  `^wait` returned on the last permitted turn is the drain, whatever its mode.
- `(Outcome ^wait "all")`, `^wait "any"` or `^wait ["auth_audit"]` ends the
  turn and parks the round in `waiting`. The parent's turn ends, its
  composition lease is released, and the wait holds no response budget. The
  round resumes with a new turn when the wait is satisfied.
- The parent does not have to wait at once. It can start children and keep
  working in later turns. A result that settles while the parent is running is
  delivered in its next request, once (see [Delivery](#delivery)).
- **`done` is deferred while the round owns unfinished children or holds
  results the model has not [seen](#delivery).** The reply is shown as
  progress, and the next request says why, as for a turn that queued a plugin
  change. This rule is explicit because `validate_outcome` drops ordinary
  appended items on `done`. A child's result must never be dropped that way.

### Why the wait is an Outcome, not a blocking call

Blocking inside response code, `(await (delegate …))`, is simpler to write, but:

- the child's whole run would be charged to one parent turn, whose response
  budget is 600 s and whose evaluation task holds a composition lease;
- a crash or a stop would lose the wait, with no way to resume it;
- the parent's transcript would show one turn hanging for minutes.

A waiting round already has the right properties: it is durable, it survives
unloading and restart, and it resumes exactly once. A delegation wait retains
its frozen membership and generation in host state and on the round receipt.
The coordinator records a continuation intent and request before starting the
next turn, using the same durable handoff pattern as answered questions. It
does not create a human question batch for the parent wait.

### Wait membership

A wait freezes its members when it registers. Members are admissions: the
latest admission of each delegation counts, so a follow-up from
`continue_delegation` is a new member. A result the model has already
[seen](#delivery) is consumed. It is never a member again.

| Wait | Members | Satisfied when |
| --- | --- | --- |
| `"all"` | Every unfinished child of the round, plus every settled result the model has not seen | Every member is terminal |
| `"any"` | The same set as `"all"` | At least one member has an unseen terminal result or question batch |
| `["a" "b"]` | The latest admission of each listed delegation; each must be unfinished or unseen, otherwise the wait is an error | Every listed member is terminal |

- **A child waiting on a question is not terminal.** It holds an `"all"` wait
  open unless `^wake_on_questions` is set. An unseen question batch wakes an
  `"any"` wait; each batch is delivered once independently of the final result.
- **Results stay pending until the wait is satisfied.** With A finished and B
  running, an `"all"` wait keeps A's result and resumes once with both. Suppose
  instead that A's result was already seen and the parent then returns
  `^wait "any"`. A is not a member, so the wait sleeps until B settles.
- **An empty wait is an error in the turn that returns it.** A wait is empty
  when nothing is unfinished and nothing is unseen, or when every listed member
  is already consumed. It never parks.
- **Registering the wait and evaluating its predicate happen under the
  parent's round gate.** Completion takes the same gate, so a child that
  settles between the two steps cannot leave the parent asleep. If the
  predicate already holds when the wait registers, the round continues at once
  with the members' results, without needing another completion event.

### What comes back

```text
[58.delegation.auth_audit@1] done in 6 turns · s-3f2a… · Audit auth middleware
Found three routes without the session check; all are under /admin.
result: [{^route "/admin/export" ^file "src/auth/routes.gene" ^line 41} …]
[58.delegation.slow_queries@1] failed: turn limit (8) · s-91c0… · Find slow queries
last request: [8.result] line 3: …
```

- Each result is an ordinary output of the parent's request. The 16 KiB
  head/tail, settling and `recall` rules apply. The child's transcript is never
  inlined.
- The states are `done`, `failed` (error, turn limit or deadline), `cancelled`,
  `interrupted` and `waiting` (the child asked a question; see below).
- `^result` is data, written in the child's final Outcome:
  `(Outcome ^^done ^reply "…" ^result {…})`. Without it the parent gets the
  reply alone. A brief should say what shape it wants back.

### Delivery

- **Each result has a stable identity:** the delegation id and its admission
  number. A follow-up from `continue_delegation` is a new admission, so it
  produces a new result. The item's display id still follows the turn
  (`58.delegation.auth_audit@1`), but the item also carries its source identity.
- **A result is first queued.** When a child settles, its result item is
  written to the parent's durable pending output, and the delegation record
  marks that admission queued.
- **Later the result is seen.** A queued result becomes seen once it has been
  included in a parent turn's request and that turn has recorded
  `turn/response`. The model has then produced a response with the result in
  its context.
- **A failed model call does not make a result seen.** If the call fails, or
  never returns, no response was produced. The item stays queued, and the next
  request carries it again.
- **Only seen results count.** Seen results satisfy the `done` guard and are
  consumed for later waits. Queued results are neither.
- **The `done` guard is per turn.** A `done` from turn N is deferred if any
  result was not in turn N's request or an earlier one. This covers a child
  that settles while turn N's model call is in flight. Its result is queued,
  but that older call's `done` cannot finish the round before the next call
  sees it.
- **Source identity removes duplicates at both steps.** A result is queued at
  most once, and appears at most once in any request. A crash at any point
  neither drops a result nor delivers it twice.

### Functions

| Function | Effect |
| --- | --- |
| `(delegate "id" ^title "…" ^brief "…")` | Queue a child; it starts at the turn boundary |
| `(delegation "id")` | Read the state, turns used, session id and result |
| `(cancel_delegation "id")` | Cancel an unfinished child: queued, running or waiting |
| `(continue_delegation "id" "text")` | Start a follow-up round in a finished child, which keeps its context |
| `(answer_delegation "id" answers)` | Answer a waiting child's question batch |

`continue_delegation` is what a child session makes cheap. "Also check the
websocket routes" goes to the auditor that has already read `src/auth`, instead
of a new child that would read it again. The continued round belongs to the
parent round that continued it.

## The child's side

- The child starts with the normal instructions plus one short prompt row: it
  is working on a delegated task, it should finish with
  `Outcome ^^done ^reply ^result`, and its reply goes to an agent, not a person.
- Its first request is the brief, prefixed like a trigger request:
  `[delegated by s-8d1e… round 12 turn 57 · auth_audit]`.
- It sees no parent history. The brief must be self-contained, as a card must
  not depend on the turn that made it. The workspace is shared, so files are
  the way to pass anything large: the parent writes `tmp/brief-auth.md` and the
  brief names it.
- **Budgets.** Each child gets a turn limit (default 12, at most 24) and a
  running-time budget (default 10 minutes), set from `^turns` and `^timeout_ms`
  within workspace caps. They are effective limits stored on the child's round
  receipt. `run_round` reads them from the receipt instead of the workspace's
  shared trigger settings, and a child's limits never change shared
  configuration.
- **The running-time budget starts at dispatch**, when the child's round is
  admitted, not when the child is queued. A question pauses it as it pauses a
  trigger round today: waiting stores `remaining_ms`, and resuming sets a new
  deadline from it.
- The child's turns do not count against the parent's turn limit; each parent
  resume does.
- The instruction prefix is the same across sessions, so with providers that
  cache prompts the child's first call reuses the cached system part.

### When the child asks a question

A child can return Outcome ^questions like any session. Its round waits with
an ordinary batch. The parent's delegation block links to the child and
projects attention. The user can answer in that conversation.

The same batch wakes a parent waiting with ^wait "any" or
^wake_on_questions. The parent can use answer_delegation through ordinary
answer admission. The first submitted answer is final; an identical retry is
accepted and a conflicting answer is refused. Each batch has its own source
identity, so a batch already seen by the parent cannot wake it twice. The
eventual terminal result remains a separate unseen result until collected.

An answered child goes back through the dispatcher. Waiting released its
running slot, so it may queue behind the workspace cap. Its recorded answer
and continuation intent are retained, owner/cap checks run at dispatch, and
the deadline is restored from remaining_ms when work actually starts. Queue
time is not charged to that child's running budget.

A concrete brief states what the child should assume when details are unclear.

## Shared workspace

Children edit the same workspace as the parent and one another. A gate keyed
by the canonical workspace covers patch preparation, durable turn/response
recording, commit and rollback. Each patch prepares against the previous
patch's committed content; staging siblings and rollback cannot overlap with
another Harness patch. Anchor checks still determine whether an edit applies.

The gate covers patches only. Shell commands and direct $fs writes require
coordination between authors. A brief assigns file ownership, and the child's
prompt tells it to change only its assigned files. There is no per-child
worktree or implicit merge step.

## What the user sees

- **In the parent transcript**, one delegation block per child at the turn
  that started it, in the card styles. It shows the title, state, turns used,
  elapsed time and a link to the child session, and has **Cancel**. It updates
  live from push messages. This is a host record kind (`delegation`), not a
  model card, because the host owns its truth. A follow-up adds a block for its
  new admission at the turn that started it, preserving the earlier result.
- **In the sidebar**, child sessions are omitted, including from search and
  filtered results. Open them from the delegation block at the turn that
  started the work. A failed or waiting child sets attention on itself and on
  the parent. The CLI and API can still list children with the `child` kind
  filter. Pinning or unpinning a parent updates its children.
- **In the child transcript**, a header line reads "Delegated by <parent> ·
  turn 57", with a link back.
- **Typing into a child.** The user may continue a finished child like any
  session, but those rounds are not reported to the parent. A running child is
  busy, as any session is.
- The CLI `transcript` prints a delegation block as one line per state change.
  Elapsed time in a browser block is wall time since first dispatch, including
  question waits and later queueing; it is separate from the running-time budget.

## Lifetime, cancellation and recovery

A delegation moves through these states:

- `staged`: in the turn's memory only, and discarded with a cancelled turn.
- `queued`: the admission intent is durable, but no child round has started.
- `running`.
- `waiting`: the child asked a question.
- `done`, `failed`, `cancelled` or `interrupted`.

The **unfinished set** of a round is its queued, running and waiting
delegations. Ownership, cancellation and the `done` rule all apply to this set.

| Event | Effect |
| --- | --- |
| Parent round cancelled, or the round fails | Admission is closed durably first; then every unfinished child is cancelled, including a waiting child's question batch, so a late answer starts nothing |
| Child cancelled by the user | The parent's wait sees `cancelled` for it |
| Stop, parent running | Stop cancels the parent round, which cancels its whole unfinished set, queue included |
| Stop, parent waiting | The parent stays waiting. Running children are cancelled, as every running round is, and count as interrupted for the recovery decision. Queued children stay queued; after the restart they dispatch normally unless the round is under a recovery hold |
| Crash, parent waiting | Running children become `interrupted` (never replayed); the parent keeps its wait |
| Crash, parent running | The parent round becomes `interrupted`, a terminal state. Recovery cancels its unfinished set, including admission intents not yet dispatched. Results it never saw attach to the session's next user request, as command results do |
| Parent session deleted | Its child sessions are deleted with it |
| Retention | Child sessions follow their parent's pin and attention |

- **Records.** A `delegation/state` core projection in the parent's stream,
  keyed `delegation/<id>`, holds the id, title, brief digest, child session,
  owning round, starting turn and state. It also holds the current admission
  number with its derived identities and result reference, and which
  admissions are queued and which are seen. The child's index record holds the
  `parent` link.
- **Admission is retry-safe, as for triggers.** The admission intent is
  recorded before any child is created. Recovery finishes an intent by reusing
  its deterministic session and round identities. It may create a missing child
  session and rebuild its metadata while the intent is held. It hands the round
  to the dispatcher and never submits it directly. A crash after the first of
  several children therefore leaves neither a duplicate nor an orphan.
- **Dispatch.** Every start of a child model round goes through one dispatcher:
  a first start from the queue, the recovery of an admission intent, a resume
  after an answer, and a `continue_delegation`. Under the parent's round gate,
  the dispatcher checks:
  - the owning round is still running or waiting, not cancelled or terminal;
  - its admission is not closed;
  - no recovery decision is holding its queue;
  - the caps allow another child.

  Otherwise the child stays queued, or is cancelled if its owner is gone.
- **Completion** is pushed from `finish_round` for `parent:` initiators. Under
  the parent's round gate, it updates the delegation record and, when the wait
  is satisfied, records its continuation intent and resumes the parent once
  for that wait generation. Startup reconciles delegation records against child
  receipts, as the trigger manager reconciles occurrences.
- **After a restart, a waiting parent is held only if work was cut off.** Work
  is cut off when a child was interrupted by a crash or cancelled by Stop.
  - **Nothing was cut off.** Recovery treats a waiting parent normally. If
    every awaited child finished, the continuation is recorded and the parent
    resumes, as an answered batch does today. Queued children that never ran
    are not cut off. They go through the dispatcher's owner and cap checks and
    start as normal. This includes a waiting parent none of whose children had
    started, for example because the workspace cap was full when the host
    stopped.
  - **Something was cut off.** The round is under a recovery hold. It does not
    resume on its own, and its queue does not dispatch. The release is always
    at the parent level, not on a child row. The parent's transcript shows a
    recovery notice with **Continue** (release the queue and resume with the
    `interrupted` results) and **Cancel round** (cancel the unfinished set). The
    notice lists the interrupted children, and the round sets attention. The
    actions do not depend on the list, so a hold can always be released.
    If the round is draining for its final collection turn, **Continue** releases
    the queue but still finishes the drain before spending that one turn.

  A restart should not start a chain of model calls nobody asked for. Queued
  children were asked for when the parent's turn committed them.
- **Acceptance checks** stop the process at each step between the parent's
  turn end and the parent's resume:
  - after the admission intent is recorded;
  - after the first child session is created;
  - after the first child round is admitted;
  - after a child finishes;
  - after the result item is queued;
  - after the queued result is marked;
  - after the parent's request that includes it is recorded;
  - after that turn's `turn/response`.

  Each check confirms no duplicate work, no orphan child, and no lost or
  doubled result.

  Behavioral checks cover the rules that do not depend on a crash:
  - Turn 23 of 24 starts A and B with `"any"`; turn 24 runs while B is still
    running. The round drains, then gets its collection turn.
  - A round reaches its limit with nothing unfinished but one unseen result.
    It runs the collection turn at once, without waiting for another completion
    or an empty-wait error.
  - Stop happens while a waiting parent's children are all queued behind the
    cap. After the restart the queue dispatches without a hold.
  - A round under a recovery hold shows the parent-level **Continue** and
    **Cancel round**, and each one releases the hold.
  - A child settles while the parent's model call is in flight, and that call
    returns `done`. The `done` is deferred, and the next request carries the
    result.
  - An `"all"` wait with A finished and B running does not wake until B
    settles.
  - A child is answered while the workspace cap is full. It stays queued and
    is not charged for the time spent queued.
  - Stop and a crash are each tested with the parent running and with the
    parent waiting.

## Limits

- At most 4 running children per parent round, and 8 across the workspace,
  both configurable. Children over a cap are **queued**, not refused, so a
  fan-out of 12 files works without the model scheduling it. Queued and waiting
  children hold no running slot. An answered child queues again for a slot.
- At most 16 delegations started per round.
  Follow-up admissions count toward the same limit.
- Child turn limit and deadline as above. Per-child token use is shown in the
  delegation block and summed in the parent's result items, so the cost of a
  fan-out is visible. Unreported usage is marked unknown. Result items include
  the aggregate `round_usage` for the owning round, alongside the child's own
  `usage`. Failed results retain the last request diagnostic for inspection and
  recall.

Workspace settings live under `delegation` in `.gene-harness/config.gene`:

| Setting | Default | Allowed range |
| --- | --- | --- |
| `max_running` | 8 | 1–64 |
| `max_per_parent` | 4 | 1–64 |
| `max_per_round` | 16 | 1–16 |
| `turn_limit` | 12 | 1–`max_turns` |
| `max_turns` | 24 | 1–24 |
| `timeout_ms` | 600000 | 1–`max_timeout_ms` |
| `max_timeout_ms` | 600000 | 1–86400000 |

Children copy the parent's effective provider, model and effort when admitted.
`^model` changes only the child's model, within that provider. Follow-ups keep
the child session's settings. These settings never mutate workspace defaults.

Waiting rounds hold no running slot, because a waiting parent that held a slot
could starve the children it waits for. The trigger cap counts waiting rounds,
so children cannot share that cap.

## Nesting and context

Children cannot delegate. The host enforces depth one independently of plugin
replacement. A child that discovers a larger task can return a proposed split
in its result; the parent decides whether to admit more work. Children start
with fresh history and a self-contained brief, without a context-fork option.

User-started rounds in a finished child are ordinary work. They do not report
back to its former parent. Parent-owned rounds retain their dispatcher, caps
and ownership rules. Parent deletion checks protected children before changing
the subtree and records a durable cascade intent so startup can finish a
committed deletion. Blob collection preserves fallback-generation references.

## Host and contribution ownership

The delegation host owns durable admissions, frozen waits, delivery, scheduling,
cancellation, caps, child session links and recovery. DelegationHost exposes
stage, inspect, cancel, continue and answer through the shared plugin contract.
The built-in delegation plugin contributes model functions, prompt policy and
this chapter using that narrow protocol. Replacing it removes those
contributions; outstanding child work stays with its runtime owner.

The delegation participant owns turn staging and completion deferral. Its
outcome_extensions rows own delegation/wait, delegation/result and
delegation/wake_on_questions, with declared short spellings wait, result and
wake_on_questions. The loop's Outcome type has no delegation-specific fields.
The leased constructor, checked suspension admission and participant commit
share one revision; see [turn participants](turn-participants.md).
