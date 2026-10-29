# Sub-agent design and verification history — 2026-10-18

Archived during the 2026-10-29 reference cleanup. Recommendations, phased
plans and review responses below are historical. The current contract is
[Sub-agents](../sub-agent.md); Outcome fields now belong to extension rows.

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
   [`validate_outcome`](../../src/agents/outcome.gene) deliberately drops ordinary
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
   [`round_controller.gene`](../../src/runtime/round_controller.gene) is a useful
   building block, but the cross-session handoff still needs its own recovery
   ordering. Acceptance checks should stop the process at those intermediate
   points and verify that there is neither duplicate work nor an orphan child.

4. **Anchor matching does not currently make concurrent patches safe.**
   [`prepare_patch` and `commit_patch`](../../src/runtime/patch.gene) are separate
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
   existing [`ImageHost`](../../src/plugin_api.gene) and
   [`image` plugin](../../src/builtin/image.gene) demonstrate this split. Outstanding
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
   [`continue_answered_round`](../../src/runtime/round_controller.gene), which
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
