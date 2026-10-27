# Sub-agents

Status: phases 1 and 2 implemented and verified (2026-10-18).
The features explicitly marked later remain deferred.
The recommendations below are the defaults used for this implementation.

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
4. **A different setup.** Later, a sub-task may want a cheaper model, a smaller
   budget or a role prompt.

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

**Recommendation:** use child sessions. Do not add a separate agent runtime,
and do not run a nested turn loop inside a turn.

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
     not drain at all; it fails at the limit as today.
  2. **Collect.** The round then gets exactly one collection turn past the
     limit. In that turn `delegate`, `continue_delegation` and `^wait` raise,
     and `[harness_budget]` says it is the final collection turn.

  If the collection turn does not end with `done`, the round fails with the
  turn limit, as today. A round therefore runs at most limit + 1 turns. A
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
| `"any"` | The same set as `"all"` | At least one member has a terminal result the model has not seen |
| `["a" "b"]` | The latest admission of each listed delegation; each must be unfinished or unseen, otherwise the wait is an error | Every listed member is terminal |

- **A child waiting on a question is not terminal.** It holds an `"all"` wait
  open, and in phase 1 it does not wake an `"any"` wait.
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
| `(answer_delegation "id" answers)` | Answer a waiting child's question batch (phase 2) |

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

A child can return `Outcome ^questions` like any session. Its round waits with
an ordinary batch, and both sides can see it:

- **Phase 1:** the user answers it in the child session. The parent's
  delegation block shows "waiting for you" with a link, and attention bubbles
  up to the parent. The parent's wait does not wake.
- **An answered child goes back through the scheduler.** Waiting released the
  child's running slot, so an answer cannot restart the child at once. The
  workspace cap might already be full. The answer and its continuation intent
  are recorded as today. The resume then joins the dispatch queue (see
  [Lifetime, cancellation and recovery](#lifetime-cancellation-and-recovery))
  and starts when a slot is free and its owner is still valid. The deadline is restored from `remaining_ms` at dispatch, so time
  spent in the queue is not charged to the child. This needs a child branch in
  `continue_answered_round`, which today sets the deadline and calls
  `start_round_task` directly.
- **Phase 2:** the batch also wakes a parent waiting with `^wait "any"` (or
  `^wake_on_questions`), with the questions in the result. The parent model can
  answer with `answer_delegation`, through the ordinary `answer_round` path.
  Whichever answer is submitted first is final. The existing retry digest
  already makes a second, different answer a conflict.

  Each question batch has its own source identity. Once a parent response has
  seen that batch, waiting again does not wake for the same questions. The
  eventual terminal result remains a separate, unseen result until collected.

A sub-task that keeps needing input was probably not concrete enough. A brief
should say what to assume when something is unclear.

## Shared workspace

Children edit the same workspace as the parent and as each other.

**Anchor matching alone does not make concurrent patches safe.** In
`src/runtime/patch.gene`, `prepare_patch` and `commit_patch` are separate
steps. A durable `turn/response` record, which can park the task, sits between
them. Without coordination, this would allow three failures:

- Two sessions can prepare from the same original file. Both find valid
  anchors, and the later commit overwrites the earlier one's change.
- Both sessions stage to the same temporary sibling,
  `.<name>.gene-harness-tmp`.
- A rollback restores the in-memory originals, which can undo a commit another
  session made in between.

The coordination protects all parallel sessions, including ordinary
interactive sessions.

- **Phase 1 adds a workspace-wide patch gate**, held from preparation through
  commit or rollback. The second patch then prepares against the first one's
  result, so a real overlap fails on its anchors. The temporary name is used by
  one patch at a time. This is enough for the MVP and needs no worktree
  merging.
- **The gate covers patches only.** Shell commands and direct `$fs` writes from
  response code are not covered. For those, the only coordination is the file
  ownership that the brief states. The child's prompt row says so plainly:
  change only the files the brief names.
- **A per-child git worktree** would give real isolation. But the Harness
  assumes the workspace is the process's working directory, and a worktree's
  changes would need merging back. This is a later option, not a phase 1 need.

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

## Should a sub-agent start its own children?

There are two questions here: whether a child may delegate (nesting), and
whether a child may start from a copy of the parent's context (forking).

### Nesting

For nesting:

- It is uniform: a child is an ordinary session, and ordinary sessions can
  delegate.
- Some work decomposes recursively. For example, "migrate module X" might split
  into one sub-task per file.

Against nesting:

- **Cost multiplies.** A fan-out of 4 at depth 3 is 64 sessions, from a single
  prompt the user typed.
- **The coordinator is lost.** The parent holds the user's intent and the
  conversation with the user. A grandchild works from a brief of a brief.
- **Waiting chains.** A child waiting on grandchildren holds its own deadline
  while they queue behind the workspace cap. Its deadline then fails work that
  was progressing. Budgets would have to become tree budgets, carved from the
  parent's.
- **Supervision.** A flat list under one parent is easy to read and cancel. A
  tree needs tree UI, tree cancellation and attention that bubbles up several
  levels.
- **There is a better alternative.** A child that finds its task is too big can
  return `^result {^split [{^title … ^brief …} …]}`. The parent, which knows the
  user's intent and the budget, decides whether to delegate the parts.

**Recommendation: no nesting in phase 1 (depth 1).** The host refuses an
admission from a child session, with an error that says to return a proposed
split instead. The depth check therefore holds even if the delegation plugin is
replaced, and the child's prompt row does not mention `delegate`. Keep the data model ready for depth: the parent link chains, and
records carry the root round. Raising a `max_depth` setting later then needs
tree budgets and tree UI, but no new storage.

### Forking the context

A fork would start the child with a copy of the parent's history, followed by
the brief. It has real uses: "try approach B in parallel" needs everything the
parent has learned. With prompt caching, a copied prefix is also cheap. But a
fork works against isolation, the first reason to offload. It also raises
questions that a fresh child does not: which round's history is copied, what
happens to the parent's open round inside it, and how recall ids resolve.

**Recommendation:** children start fresh. Consider `^context "fork"` later, for
exploration rather than offloading, once a real case asks for it.

## Alternatives considered

- **A one-shot model call** (`(ask_model prompt)`): one completion, with no code
  execution and no loop. This suits summarizing or classifying text inside a
  turn. It is complementary, not a sub-agent, and could be added separately.
- **A nested turn loop inside the parent's turn.** This was rejected. It cannot
  be inspected, it is lost on a crash, it holds the parent's lease and budget,
  and it duplicates the session machinery.
- **Everything in the host.** This was rejected; see
  [Host and plugin split](#host-and-plugin-split). `plugin_api` cannot create
  sessions today, but that only means the host needs a narrow seam. It does not
  mean the functions and prompt policy belong in the host.
- **A question answered by an agent** (`{^id "auth" ^agent {…}}` inside a
  question batch). This is tempting because it unifies the two. But a user may
  dismiss a batch or answer part of it, while children finish independently and
  can be continued. The wait should reuse the batch's durability, not its UI or
  its rules.

## Host and plugin split

The Harness keeps replaceable behavior in plugins. Sub-agents follow the split
that `ImageHost` and the built-in `image` plugin already use.

- **The host owns the mechanics.** These are durable admission, waits and
  their membership, delivery, cancellation, caps and queueing, the depth check,
  and recovery. They also include the `child` session kind and the `^wait`
  Outcome field, which belongs to the loop.
- **A narrow `DelegationHost` protocol in `plugin_api`** exposes the mechanics.
  It has operations to stage, read, cancel, continue and answer a delegation.
- **A built-in `delegation` plugin** contributes `delegate`, `delegation`,
  `cancel_delegation`, `continue_delegation`, `answer_delegation`, the docs chapter
  and the child's prompt row, all through that protocol.
- **Replacing or disabling the plugin** removes the functions and the prompt
  policy. Outstanding children and waits stay with the host: they still finish,
  deliver and cancel.

Plugins can add **agent profiles** later, as rows of an `agents` registry. A
row has a name, a role prompt, a model and budgets, and is used as
`(delegate "id" ^agent "reviewer" …)`. That is an ordinary contribution, like
`interactions` rows, and is not needed in phase 1.

## Phases

1. **Child sessions and waiting.** This adds:
   - the `child` session kind and parent link;
   - `DelegationHost`, and the built-in `delegation` plugin with `delegate`,
     `delegation` and `cancel_delegation`, admitted at the turn boundary
     through a durable admission intent;
   - `Outcome ^wait` with frozen membership and per-mode predicates, plus
     `^reply` and `^result`, queued once and consumed only when seen;
   - per-round effective budgets, caps, and one dispatcher with a queue, which
     answered children also go through;
   - the last-turn drain and collection turn;
   - ownership of the unfinished set, cancellation and recovery, with the
     crash-point acceptance checks;
   - the workspace-wide patch gate;
   - the delegation block, child-session navigation and CLI printing;
   - depth 1.
2. **Conversation with a child.** This adds `continue_delegation`,
   `answer_delegation` and waking on child questions, plus a per-child
   `^model` override, which needs a session-level provider setting.
3. **Later, if needed:** agent profiles; delegations that outlive their round,
   with results attached to the parent's next user request; a context fork; a
   worktree per child; depth above 1 with tree budgets.

## Decisions used for implementation

The defaults above are the implementation decisions: require a parent-level
recovery action when work was cut off, keep ownership within the round, use
depth 1 and a shared workspace, and allow ordinary user rounds in a finished
child. Children participate in explicit search and filters. The API uses
`delegate` / `delegation` and the session kind `child`.
The dispatcher and ownership limits apply to parent-owned rounds. User-started
rounds in a finished child are ordinary user work and do not report to its parent.

Deleting a parent first checks the whole child tree for active rounds, pins,
attention and open viewers. It refuses the deletion if any member is protected.
A durable deletion intent lets startup finish the cascade after a crash. Blob
collection still retains any history needed by fallback event generations.

## Review comments (Codex, 2026-10-18)

The main direction makes sense: ordinary child sessions, fresh context, a
durable wait outside response evaluation, and depth 1 fit the existing Harness.
Shared workspaces are a reasonable first milestone. I would clarify the
following before implementation; none requires forks, worktrees, nested agents
or a general agent-profile system now.

1. **Ownership must cover every unfinished child, including queued and
   question-waiting children.** The current wording cancels only "running"
   children and forbids `done` only while children are running. A parent could
   otherwise finish or be cancelled while a queued child later starts, or a
   waiting child's answer starts another model call. Define one unfinished set
   covering pending admission, queued, running and waiting. Parent completion
   must join or explicitly cancel that set; cancellation must durably close
   admission before cancelling active work. Also specify what happens to queued
   children after a crash. They must not start automatically while their parent
   is awaiting the user's recovery decision. Keep the existing recommendation
   to require user action for interrupted work.

2. **Give waits and result delivery a precise, durable identity.** Consider A
   finishing while B runs: A's result is delivered in the parent's next request,
   then the parent returns `^wait "any"`. It should wait for a new completion,
   rather than immediately waking again for A. Freeze each wait's member set
   and identify completion events by delegation/admission, with a consumed
   position or equivalent rule. Register the wait and check already-completed
   children under the same coordination gate, so completion between those two
   steps cannot leave a parent asleep forever. The single `delivered` flag is
   insufficient on its own: persist the result item in the parent's pending
   request before marking it delivered, using a stable item id so reconciliation
   can deduplicate it. Also prevent `done` from silently dropping a completed
   but undelivered result. The current
   [`validate_outcome`](../src/agents/outcome.gene) deliberately drops ordinary
   appended items on `done`, so delegation results need an explicit rule.

3. **Spell out the admission commit point at the turn boundary.** "A cancelled
   turn starts nothing" is achievable for staged calls before admission, but
   cancellation can race the host admitting several children. Record a durable
   admission intent, including the allocated admission number, before creating
   any child. Retrying must reuse that intent and its deterministic session and
   round identities. Once admission has committed, parent cancellation owns
   cleanup of any admitted children; it cannot promise that none briefly
   started. This distinction also handles a crash after creating the first of
   several children. The existing `submit_round`/`on_admit` path in
   [`round_controller.gene`](../src/runtime/round_controller.gene) is a useful
   building block, but the cross-session handoff still needs its own recovery
   ordering. Acceptance checks should stop the process at those intermediate
   points and verify that there is neither duplicate work nor an orphan child.

4. **Anchor matching does not currently make concurrent patches safe.**
   [`prepare_patch` and `commit_patch`](../src/runtime/patch.gene) are separate
   operations. Two sessions can prepare from the same original file, both find
   valid anchors, and then overwrite each other's changes. They also use the
   same temporary filename for a target. The shared-workspace section therefore
   promises more than the patch implementation provides. A workspace-wide gate
   around preparation through commit/rollback is enough for the MVP; it avoids
   introducing worktree merging. Direct filesystem writes and shell commands
   still rely on the brief's file ownership guidance. Describe that limitation
   plainly rather than treating anchor failure as general write coordination.

5. **Define the clocks and retain the effective limits on each child round.**
   Does the child's ten-minute timeout start when queued or when it actually
   starts, and does a human question pause it? Existing non-user rounds preserve
   `remaining_ms` while waiting for answers and establish a new deadline when
   resumed; they are not a continuous wall-clock deadline. They also read
   workspace trigger limits, so `^turns` and `^timeout_ms` need per-round effective
   limits rather than temporary changes to shared configuration. I recommend
   starting the execution budget on dispatch and retaining the existing pause
   behavior for questions. Handle the parent's last permitted turn as well:
   admitting paid children and parking on that turn currently leaves no turn
   for collecting their results. Refuse that admission/wait before starting
   children, or explicitly reserve a continuation turn.

6. **Keep the host mechanics separate from the replaceable sub-agent API.**
   The host must own durable admission, waits, cancellation, caps and recovery.
   The fact that today's `plugin_api` lacks session creation does not require
   putting all sub-agent functions and prompt policy in the host. A narrow
   delegation host seam can support a built-in plugin contributing `delegate`,
   `delegation`, `cancel_delegation`, documentation and child instructions. The
   existing [`ImageHost`](../src/plugin_api.gene) and
   [`image` plugin](../src/builtin/image.gene) demonstrate this split. Outstanding
   children and waits should remain host-owned if that plugin is replaced or
   disabled. This preserves the Harness's plugin architecture without adding
   agent profiles in phase 1.

### Changes made after the Codex review

Each claim was checked against the code first. All six were accurate and are
now in the doc body.

| Comment | Change |
| --- | --- |
| 1. Ownership of every unfinished child | Delegation states and the **unfinished set** (queued, running, waiting) are defined. Ownership, cancellation and the `done` rule cover the whole set. Cancellation closes admission durably before cancelling, and also cancels a waiting child's batch. After a crash with an interrupted child, queued children stay held until **Continue**. Stop is treated like a crash for the recovery decision. |
| 2. Wait and delivery identity | New **Wait membership** section: frozen members, only undelivered results satisfy a wait, and registration and completion share the parent's round gate. New **Delivery** section: a stable identity per admission, the item written before delivery is marked, and duplicates removed by source identity. `done` is deferred while results are undelivered, because `validate_outcome` drops appended items on `done`. |
| 3. Admission commit point | The turn boundary now has a durable admission-intent commit point. "A cancelled turn starts nothing" applies only before that commit; after it, the round owns cleanup. Recovery finishes an intent by reusing its identities. Crash-point acceptance checks are listed. |
| 4. Concurrent patches | **Shared workspace** now says plainly that `prepare_patch`/`commit_patch` can lose updates and share a temporary name. Phase 1 adds a workspace-wide patch gate. Shell and `$fs` writes rely on the brief's file ownership. This gap exists today for any two parallel sessions, and `design.md` overstates anchor failure as a conflict signal. |
| 5. Clocks and effective limits | Child limits are stored on the round receipt instead of being read from shared trigger settings. The budget starts at dispatch, and a question pauses it through `remaining_ms`, as for trigger rounds. `delegate` and `^wait` raise on the parent's last permitted turn. |
| 6. Host and plugin split | New **Host and plugin split** section: the host owns the mechanics behind a `DelegationHost` seam, and a built-in `delegation` plugin contributes the functions, docs and child prompt row, as `ImageHost` and the `image` plugin do. The depth check is host-owned. |

### Second review (Codex, 2026-10-18)

The revision addresses the six original concerns and keeps the milestone
focused. The remaining points are correctness gaps in the new rules, not
requests for more features.

1. **Define separate completion predicates for `all`, `any` and a list.**
   The final Wait membership bullet currently continues immediately if *a*
   member already has a result. With A finished and B still running, that
   wakes `^wait "all"` too early. For `all`, keep the collected results pending
   until every frozen member is terminal; `any` needs one new eligible result.
   State whether an explicit list means all listed admissions. Also include
   completed-but-unseen results in `any` membership: its current definition
   includes unfinished children only, so it can exclude the very result that
   should wake it. Define empty/already-consumed waits so they cannot park
   forever waiting for a completion that already happened.

2. **Writing a pending item is not yet delivery to the model.** The Delivery
   section marks an admission delivered after its item reaches the durable
   pending request, whereas ownership says the result must have reached the
   model. Those are different boundaries. A child can finish while a parent
   model call is in flight; queuing its result must not let that older call's
   `done` finish the round before the next call sees it. Retain the distinction
   between queued output and inclusion in a specific parent model request.
   Only the latter should satisfy the `done` guard and consume a result for
   subsequent waits. Stable source identities can still deduplicate both.

3. **Recovery must check the owner before dispatching an admission intent.**
   The retry-safe admission paragraph says to submit a round whenever its
   receipt is missing, but the recovery paragraph requires some queues to stay
   held. Apply the owner's closed-admission marker and recovery decision
   before dispatch, including when the parent itself was interrupted while
   continuing to work. Similarly, Stop cannot preserve queued work owned by a
   parent round that Stop cancelled: the parent-cancellation rule must cancel
   that queue. Reconstructing child metadata is fine while held; starting a
   model round must go through the same owner/cap checks as normal dispatch.

4. **The last-turn guard still strands previously admitted children.** For
   example, on turn 23 of 24 the parent starts A and B and waits for `any`. A
   finishes, so the parent resumes on turn 24 while B runs. It now cannot
   `^wait`, and `done` is deferred because B is unfinished; there is no
   successful collection path left. Reserve a final collection turn that runs
   only after owned work settles, or define an equivalent bounded drain policy.
   Rejecting new delegations on the final turn is useful, but rejecting waits
   there does not solve this case. Add it to the acceptance checks.

5. **An answered child must re-enter the child scheduler.** Waiting releases
   a running slot. If eight other children are running when the user answers
   this child's question, the ordinary answer path currently starts its round
   immediately, exceeding the proposed workspace cap. Persist the answer and
   continuation intent, then queue the resume until a slot is available and
   ownership is still valid. Restore its deadline from `remaining_ms` at
   dispatch, rather than charging the time spent in this queue. This needs an
   explicit child-aware path in
   [`continue_answered_round`](../src/runtime/round_controller.gene), which
   currently sets the deadline and calls `start_round_task` directly.

### Changes made after the second Codex review

All five points were correct; the answered-child path was checked in
`continue_answered_round`, which sets the deadline and calls
`start_round_task` directly.

| Comment | Change |
| --- | --- |
| 1. Completion predicates | **Wait membership** is now a table. `"all"` and an explicit list need every member terminal; `"any"` needs one unseen terminal result. Members are admissions, `"any"` includes settled but unseen results, a child waiting on a question is not terminal, and an empty or fully consumed wait is an error that never parks. |
| 2. Queued is not seen | **Delivery** now separates *queued* (written to pending output) from *seen* (in a parent turn's request that recorded `turn/response`). Only seen results satisfy the `done` guard and are consumed by waits. A `done` whose request predates a result is deferred, and a failed model call leaves the result queued. |
| 3. Owner checks before dispatch | A single **dispatcher** handles first starts, recovered intents, answered resumes and `continue_delegation`. It checks the owner's state, closed admission, recovery hold and caps under the parent's round gate. Recovery may rebuild child metadata, but never submits a round directly. Stop and crash are now split by whether the parent is running or waiting. A running parent's unfinished set, queue included, is cancelled, and results it never saw attach to the next user request. |
| 4. Last-turn stranding | The last-turn rule is now a **drain then collect** policy. New work is refused on the last permitted turn. A round that reaches its limit with unfinished or unseen work parks in an implicit `"all"` wait, then gets one collection turn (at most limit + 1). The turn 23/24 case is an acceptance check. |
| 5. Answered children and caps | An answered child goes back through the dispatch queue instead of `start_round_task`, with its deadline restored from `remaining_ms` at dispatch. This needs a child branch in `continue_answered_round`. **Limits** and the acceptance checks mention it. |

### Third review (Codex, 2026-10-18)

The five second-review issues are addressed. The architecture and phase 1 scope
look ready. Two boundary cases should be made explicit in the implementation
rules and acceptance checks; neither needs a new feature or another redesign.

1. **The implicit drain must include settled but unseen results.** The
   last-turn section says the drain waits over the unfinished set, but the
   drain also runs when that set is empty and only unseen results remain.
   Use the full `"all"` membership defined above: unfinished admissions plus
   unseen results. If all members are already terminal, skip parking and run
   the collection turn immediately. An internal drain with nothing unfinished
   must not hit the public empty-wait error or wait for another completion.

2. **A waiting parent with only queued children needs a restart path.** For
   example, the workspace cap prevented any of its children from starting,
   then the host was stopped. The Stop row holds its queue, but no child is
   interrupted, so the later interrupted-child recovery branch does not apply.
   State whether this queue resumes normally after the dispatcher checks its
   owner, or remains held with a parent-level **Continue / Cancel** action.
   Either policy is workable; a recovery hold must always have a visible
   release path even when there are no interrupted child rows to display.

### Changes made after the third Codex review

| Comment | Change |
| --- | --- |
| 1. Drain membership | The drain now uses the full `"all"` membership: unfinished children plus unseen results. If every member is already terminal, the round skips parking and runs the collection turn at once. The internal wait never raises the empty-wait error. A round with nothing unfinished or unseen does not drain and fails at the limit as today. |
| 2. Queued-only waiting parent | Chose "resume normally". A recovery hold applies only when work was cut off: a child interrupted by a crash or cancelled by Stop. Queued children never ran, so after a restart they go through the dispatcher's owner and cap checks, which matches how Stop keeps due trigger occurrences. A hold's release is always a parent-level **Continue / Cancel round** notice that does not depend on child rows. Three acceptance checks cover these cases. |

### Implementation verification (Codex, 2026-10-18)

The latest revision addresses both third-review comments. No further design
blockers remain. Phases 1 and 2 now have 31 passing targeted checks across the
delegation contracts, runtime, session lifetime, HTTP controls and browser state.
The crash suite stops real processes at nine handoff boundaries and checks
reconciliation, recovery holds and result identity. Additional boundary tests
cover in-flight completion, failed-call carryover, cancellation before coordinator
reconciliation, and recovery during the final drain.

The relevant existing session, round, question, patch, history, provider,
composition, command, trigger and web-service checks passed. Browser compilation
and the generated event catalog check passed. Native browser acceptance used
scripted responses to verify child cards, nesting, question answers, parent/child
navigation, separate drafts, Cancel, and recovery Continue. The controls were
inspected in both themes.
This verifies the Harness flow; it is not live-provider qualification.

Implementation details reflected above include a dedicated durable delegation
wait, admission numbers in result display IDs, concrete workspace settings, and
waiting for a recovered final drain before consuming its collection turn.
