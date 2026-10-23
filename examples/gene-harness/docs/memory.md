# Memory for Gene Harness

**Status:** implementation proposal; the memory APIs below are not implemented.
Research date: 2026-10-22. Updated: 2026-10-23. Repository baseline: `db807312`.

## Recommendation

Build a **workspace-local memory system in Gene**, starting with an operator-owned
instructions file and a small set of durable notes. Preserve session history and
exact-body recall. Make both user statements and inferred lessons retrievable,
clearly labeled with their sources and dates. Use Harness's checkpointed event
store as the authority and a bounded Gene scan for lexical retrieval in v1.

A model response that finishes a user-initiated request may include an optional
`^memory` field on its final `Outcome`. Harness captures it as literal data,
carries a candidate-blob reference in the completed round receipt, then admits
the candidates in one idempotent `memory/batch` event after that receipt is durable.
Normal answers require no memory proposal and no extra model call. Defer
SQLite/FTS5, embeddings, episodes, and model-based review/consolidation until
measured needs justify them.

This design fits the current Harness. There is no established universal winner
across conversational recall, coding experience, privacy,
latency, and operating cost. The recommendation combines published practices
with the runtime and persistence model already present in this repository.

### Operating model

Harness response code and plugins run in-process with the full standard library
and filesystem access, as documented in the [implemented design](design.md).
Memory admission protects quality and consistency through the supported API;
it is not a security boundary against code that can write `.gene-harness/`
directly. Process/OS isolation remains a separate deployment decision.

Version 1 has one scope: the current workspace. Only rounds initiated by a user
may submit durable notes. User, child, and trigger rounds all receive relevant
memory, can use its read functions, and participate in received-set tracking and
withdrawal delivery. Child/trigger rounds omit the memory-submission prompt row;
unexpected proposals are rejected in their receipt without next-round feedback.
There is no staged review queue in v1. Session context remains in existing history
and compaction. Personal cross-workspace identity and sharing are deferred.

## Research findings and implications

The following are source findings. The architecture and numerical defaults in
later sections are proposed engineering choices for Harness.

| Finding | Implication for Harness | Primary source |
| --- | --- | --- |
| Finite context benefits from selective retrieval, compaction, and persistent notes. | Keep a small active context and retrieve details when needed. | Anthropic, [Effective context engineering](https://www.anthropic.com/research/effective-context-engineering-for-ai-agents), September 2025 |
| Session state and cross-session memory have different scopes; memory writes can occur during a request or in background work. | Keep history compaction separate from durable memory; combine final-response capture with later consolidation. | LangChain, [Memory overview](https://docs.langchain.com/oss/python/concepts/memory), current documentation |
| Versioned files and progressive disclosure provide inspectable memory for coding agents. | Offer readable exports, a concise memory index, and explicit fetch/search operations. | Letta, [Context Repositories](https://www.letta.com/blog/context-repositories/), February 2026 |
| Extraction, consolidation, and retrieval are separate memory operations. | A candidate write needs deduplication and update handling before it becomes active memory. | [Mem0 paper](https://arxiv.org/abs/2504.19413), April 2025 |
| Facts, agent experiences, and synthesized beliefs have different evidentiary status. | Store observations separately from inferred lessons; preserve their supporting sources. | [Hindsight paper](https://arxiv.org/abs/2512.12818), December 2025 |
| Temporal relationships matter when knowledge changes. | Track effective time, recorded time, supersession, and historical versions. | [Zep paper](https://arxiv.org/abs/2501.13956), January 2025 |
| Useful evaluation covers extraction, multi-session reasoning, time, updates, and abstention. | Test stale and missing knowledge as well as successful recall. | [LongMemEval](https://arxiv.org/abs/2410.10813), revised March 2025 |
| Environment experience includes workflows, changing state, gotchas, and incorrect premises. | Evaluate whether memory improves future actions in Harness projects. | [LongMemEval-V2](https://arxiv.org/abs/2605.12493), May 2026, work in progress |
| End-to-end answer scores hide whether failures came from storage, retrieval, or generation. | Instrument and evaluate those stages independently. | [EvalMem](https://arxiv.org/abs/2609.22231), September 2026 |

LongMemEval-V2 reports strong results for an agent gathering evidence from stored
trajectory files, with substantial latency costs. This supports keeping original
evidence navigable and offering deeper search when needed. It does not establish
that an extra agentic search is appropriate for every Harness request. See the
[LongMemEval-V2 study](https://arxiv.org/abs/2605.12493) for the evaluated setting.

Published scores from Mem0, Hindsight, Zep, and other systems use particular
models, datasets, prompts, and evaluation protocols. Treat their designs as
useful evidence and evaluate alternatives under the same Harness workload before
making comparative performance claims.

## What Harness already provides

Module paths below are relative to the Harness package root
(`examples/gene-harness/` in the repository) unless stated otherwise.

| Existing component | Current behavior | Memory integration |
| --- | --- | --- |
| `src/agents/history.gene` | Session messages, content-addressed exact bodies, elision, compaction, and recall. | Preserve these as working context and source evidence. |
| `src/agents/history_policy.gene`, `src/builtin/history_basic.gene` | Compaction thresholds, retained rounds, summary instructions. | Count injected memory in history; preserve received-set metadata and effective withdrawal guidance through compaction. |
| `src/agents/outcome.gene` | Validates outcomes and rewrites special response call sites, including cards. | Add literal memory capture and independent candidate validation. |
| `src/agents/instructions.gene` | Defines the model-visible response contract. | Explain final-response memory and when to omit it. |
| `src/agents/turn_loop.gene` | Assembles context, calls providers, evaluates responses, records replies and turn endings. | Capture candidates only after all completion deferrals have settled. |
| `src/runtime/round_controller.gene` | Flushes receipts; retains 128 per session; shutdown can override success with cancellation. | Save `memory_ref` plus an index hint; guard admission after active/delegation cleanup. |
| `src/storage/state.gene` | Serialized event writes, retained projections, checkpoint generations, recovery. | Reduce each `memory/batch` into a dedicated core projection. |
| `src/agents/model_call.gene`, `model_recording.gene` | Records prepared inputs and provider attempts/results. | Record the exact memory selection and source revisions used by each call. |
| `src/agents/hooks.gene` | Request preparation and history-policy hooks. | Inject a settled memory item at `round_turn == 1`. |

The current `Outcome` has no `memory` property. Its successful `done` can be
converted to continuation when plugin composition, produced media, or delegation
work must first be observed. Memory must follow the final accepted result.

The event store publishes dirty streams through one manifest checkpoint. A single
batch event can contain all changes for one round, so memory does not require a
new multi-event completion transaction or relocation of final reply publication.
Appends notify observers before a later flush: a saved-memory acknowledgement
must wait for checkpoint success. Core projection event kinds use allowlists.

## Memory layers

| Layer | Contents | Loading policy |
| --- | --- | --- |
| Working context | Current request, recent conversation, active task state, compaction summary. | Existing session context management. |
| Workspace instructions | Operator-maintained project rules, preferably versioned with the project. | Bounded prompt row; proposed filename below. |
| Core notes | A few operator-pinned or explicitly stated, broadly relevant workspace preferences and constraints. | Small bounded selection at request start. |
| Durable notes | Atomic project facts, decisions, preferences, and scoped lessons with provenance and validity. | Search and selective injection. |
| Episodes (deferred) | Completed request, outcome, artifact references, and links to relevant observations. | Later conversation/round search feature over existing records. |
| Original evidence | Exact user input, recorded observations, response bodies, and source revisions. | Explicit fetch or deeper investigation. |

Core notes and durable notes share one record format; pinning is a loading
policy. A raw transcript remains source material. A compaction summary is a lossy
working-context artifact. Existing receipts and transcripts provide completed
request records in v1; creating a separate episode per round is deferred.

Useful durable notes include a user correction, a project decision and its
rationale, a verified repository convention, or a reproduced failure with its
conditions and remedy. Generic facts, routine progress, copied conversation,
unverified claims of success, and unsupported broad conclusions should not
accumulate. A useful conditional lesson may be stored as an inference; it need
not wait for a future reviewer to become retrievable.

### Workspace instructions and scratch notes

Add an instructions-file baseline before automatic memory. Recommend the
workspace root's `AGENTS.md`, loaded as literal text through a built-in plugin
prompt row, with a file path and digest recorded for each round. Capture its
contents at admission to keep ordinary continuation prefixes stable. A missing
file is normal; unreadable or oversized files produce an explicit diagnostic.
Bound the content rather than silently truncating project rules. Automatic
memory cannot edit or supersede this row through its admission API.

`assemble_instructions` runs each turn and prompt rows currently receive only
`(runtime, session_record)`. Pass the round's captured instructions reference
explicitly through that assembly context; the prompt row must not reread the
mutable file each turn. Store the captured text as a blob referenced by the
receipt. An edit changes the system message and invalidates each session's
cached prefix once, at that session's next round; ordinary continuation turns
keep the same capture.
Switching a session between user- and non-user-initiated rounds also changes the
conditional memory-submission row in its system message. Each switch invalidates
the cached history prefix once; this is an expected cache cost, including when a
user continues a trigger-created session.

The filename remains an owner choice; this recommendation does not silently
add ancestor-file discovery or change existing Gene instruction semantics.
Keep the file's project guidance separate from retrieved model-written notes.

Existing `harness/budget` and `docs/recipes/ui-publication.md` recommend a working
notes file. That file holds unfinished investigations, hypotheses, and task
state across interruptions. Durable memory contains selected lessons for later
requests. Neither arbitrary scratch files nor compaction summaries are
automatically promoted into durable memory.

## Optional memory in the final response

Use the existing Gene response format and an ordinary additional property:

```gene
(Outcome ^^done
  ^reply "The import now works, and the integration test passes."
  ^memory [
    {^kind "decision"
     ^key "storage.primary"
     ^text "This project uses SQLite for local persistent state."
     ^evidence ["user.request"]}
    {^kind "lesson"
     ^key "imports.csv.empty_header"
     ^text "For this importer, reject an empty CSV header before writing rows; regression coverage is in tests/import_spec.gene."
     ^evidence ["14.tests"]
     ^tags ["csv" "import"]}])
```

Assume this example finishes on turn 15 or later: `14.tests` must have been
rendered to the model in an earlier turn. Evidence cannot cite outputs computed
in the final response itself. A `done` outcome drops appended items and creates
no next request, so the model has not observed those outputs. Run verification
in an earlier turn, inspect its result, then finish.

The following handles are proposed resolver APIs over existing records, not an
existing structured observation registry:

| Handle/source | Resolution and source class |
| --- | --- |
| `user.request` | Alias for the current user request; resolves to the receipt's unchanged `prompt`, only when `initiator == "user"`. |
| `N.user` | Visible header for a user round's original prompt, where N is that round's first session-wide turn number; also usable for earlier retained requests in this session. |
| `N.answers` (including collision suffixes) | Exact operator-submitted question answers, traced to the question/answer record. Parent-generated child answers do not acquire user origin. |
| `N.label` | Earlier rendered response output; record its actual origin. A label such as `tests` alone does not prove a tool ran or a test passed. |
| `cN.name` | Operator `/run` or `/sh` attachment; classify as tool output, not a user statement. |

Never use the evolving receipt `request` to classify user statements: command
attachments, hook items, trigger headers, and continuation output can occur
there. Trigger text and parent briefs are not user statements. Resolve handles
to immutable source content before admission and retain a bounded source quote.
Unavailable or pruned source handles produce a candidate rejection. Once a note
is accepted, its copied evidence survives the receipt retention window.

Render `[N.user]` directly above the original prompt on each new user round's
initial request, and preserve it in settled history. Command attachments and
prepared context keep their own labels. Persist the host-issued handle and exact
original-prompt reference with the receipt. Use its `first_turn`/`last_turn` range
to locate a candidate receipt, then require `first_turn == N`, the stored handle,
and `initiator == "user"`. A trigger or child prompt cannot become a user source.

Extend `(recall "N.user")` to return that exact original prompt, excluding the
header and added context. Reserve the issued `user` label in the existing turn
ID allocator, so a model's `(append_prompt "user" ...)` receives a collision
suffix instead of overwriting it. Do not retroactively reinterpret a legacy
`N.user` output without a host-issued user-handle record. No new Gene syntax is
needed: this is a request header and resolver convention. Opaque round IDs do
not need to appear in the model-visible evidence API.

Omit `^memory`, use `nil`, or use `[]` when nothing is worth remembering:

```gene
(Outcome ^^done ^reply "The answer is 42.")
```

Proposed candidate contract:

| Field | Meaning |
| --- | --- |
| `kind` | `preference`, `fact`, `decision`, or `lesson`. |
| `key` | Short semantic key within this workspace; an indexing hint, never a file path. |
| `text` | One concise, independently useful statement; include applicability conditions. |
| `evidence` | Nonempty list of host-resolvable source handles. |
| `tags` | Optional small list of search hints. |
| `replaces` | Optional existing memory ID when proposing a correction. |
| `expected_revision` | Required with `replaces`; prevents silent concurrent overwrites. |

Host-generated fields include ID, revision, workspace identity, source
round/turn/call, timestamps, status, and admission decision. The model cannot set
these by adding map fields. Reject unknown candidate fields for format version 1.

Start with a maximum of five candidates, 1 KiB UTF-8 text per candidate, four
evidence handles per candidate, eight tags, and 8 KiB serialized candidates per
final response. Bound nesting and reject non-data values before serialization.
These are tuning defaults, not research results. Reject oversized proposals with
diagnostics instead of silently truncating facts or evidence.

Add the property permissively at the outer `Outcome` boundary, for example
`^memory Any?`, so memory validation cannot spoil an otherwise valid final
reply. Ship the type, capture path, tests, and prompt together: the current type
rejects an unknown `memory` property.

Ordinary Gene property values are evaluated expressions. Merely validating the
result afterward would allow computed text, interpolation, or file reads in the
memory expression. For the proposed Harness response contract, extend
`rewrite_prompt_form` to capture the authored `^memory` subtree on a literal
`(Outcome ...)` call as quoted reader data, using the existing card rewrite as
a precedent. Do not recurse into that subtree. Wrap it with an internal
per-turn capture marker; accept candidates only from that capture path.

Deep validation allows literal lists/maps, strings, numbers, booleans, and nil.
Symbols, executable nodes, interpolation, callbacks, and computed/indirectly
constructed payloads receive a bounded rejection receipt. Do not throw an
`OutcomeError` merely because optional memory is invalid. Preserve already
quoted source as data during rewriting. No stored candidate is evaluated during
admission or recovery.

This is proposed Harness-only response rewriting, like its existing card call
sites. It does not change general Gene property evaluation or introduce syntax.
Code outside a recognized literal memory subtree still has normal effects and
full filesystem access; rejecting an indirect payload does not undo its earlier
evaluation. The capture path is a data-quality rule, not an isolation mechanism.

Rules:

- Only a final accepted `done` is eligible. Intermediate, question, waiting,
  failed, cancelled, and deferred-done responses create no durable notes.
- Invalid memory does not invalidate a valid reply or trigger another model
  call. Record a bounded rejection; accept other valid candidates where possible.
- An omitted memory field is normal. Never ask the model to fill a quota.
- The final reply describes the task outcome. Memory proposals remain separate
  metadata, with an inspectable acceptance receipt.
- Explicit operator forget/edit controls are authoritative. Version 1 does not
  grant model proposals an unrestricted delete operation.

For user-initiated rounds, when plugin/media publication or delegation defers a
`done`, extend both existing notices: "Memory proposals were not saved; include
them again in the final done." Do not silently carry proposals forward or lose
them without feedback. Summarize user-round rejections in a settled item at the
next round start in that session, without creating an extra model call:

```text
[harness_memory] last round: 1 saved, 1 rejected (unknown handle 3.tests).
```

Record the underlying batch/receipt ID and delivery cursor with session history
so ordinary retries do not repeat the feedback. Include invalid/oversized memory
diagnostics as well as source-resolution failures; keep reasons bounded and free
of sensitive payload excerpts. Omitted memory needs no feedback item.
Child and trigger rounds retain ordinary completion-deferral notices but receive
no memory-resubmission advice or next-round rejection item; their unexpected
proposals are rejected quietly in the receipt.

### Proposed user-round prompt addition

Render this small row only when the current round's captured `initiator` is
`user`. Pass that value through the same explicit round context used for the
instructions-file capture. Session kind is useful context but is not a substitute
for the round's actual initiator. Omit this row for parent/trigger-initiated rounds
while retaining the common response format, memory read APIs, and reference-data
policy. This avoids soliciting proposals that cannot be admitted.

```text
On a final literal (Outcome ^^done ...), optional ^memory holds a short literal
list of durable notes supported by earlier observed evidence. Omit it otherwise;
keep ^reply complete. See (doc "harness/memory") for fields and examples.
```

Put the candidate schema, examples, evidence-source table, correction protocol,
and detailed writing rules in the discoverable `harness/memory` chapter. Those
rules cover atomic conditional statements, explicit user corrections, costly
discoveries, and useful lessons; exclusion of secrets, copied conversation,
generic knowledge, and unchanged duplicates; and the requirement to observe
verification results before citing them. Explain that acceptance is a separate
host decision and that inferred notes remain hypotheses.

Put this policy beside retrieved data, only when a memory block is present:

```text
[harness_memory] Reference notes with sources and dates. Inferred notes are
hypotheses; verify changeable facts. Current instructions and project rules govern.
Later withdrawal/correction notices supersede these notes and their summaries.
```

## Admission, evidence, and updates

Admission has three separate questions: is the candidate well formed; what did
its source actually contain; and is the resulting note useful? Shape validation
and evidence resolution are deterministic. They do not establish that a model's
paraphrase follows from the source or that a lesson generalizes correctly.

Version 1 activates both directly attributed user statements and inferred
lessons after bounded validation and source resolution. Use a note-level class:

- `user_statement`: a model paraphrase of direct user input, with the exact
  source quote beside it. This is attributed information, not a verified entailment.
- `inference`: an agent-written fact, interpretation, or conditional lesson
  drawn from earlier outputs or artifacts. Mark it as a hypothesis and prefer
  stronger direct evidence when relevance is comparable.

Source entries independently preserve their origin: user prompt/answer, operator
tool output, response output, or captured artifact. Generic `append_prompt`
values are rendered text today; do not invent a structured observation registry
or call them machine-verified results. A future reviewer can improve these labels.

This policy trusts the primary model's extraction enough to make lessons useful
in v1 while exposing the source needed to check them. A confidence score does
not establish truth. Structurally invalid or unresolved proposals are rejected;
revision conflicts are visible but excluded from normal injection. There is no
`proposed` review queue in v1. A future proposed state is not retrieved as active
knowledge unless the operator explicitly requests it.

A retrieved memory quoting another memory is not independent evidence.
Repeated retrieval must not increase confidence or satisfy promotion criteria.

For deduplication, normalize keys and compare canonical content inside the
current workspace. An identical statement becomes a no-op or adds genuinely
new supporting evidence. Different keys can describe the same fact, such as
`storage.primary` and `db.engine`; compare normalized content too and show likely
duplicates in the operator view. Similarity can nominate duplicates but cannot
authorize a destructive merge. Different content under one key triggers
correction or conflict handling.

Corrections use compare-and-set on ID and revision. Keep the old revision and
its effective interval, link the replacement, and remove superseded content from
default current-state retrieval. Publish a withdrawal/replacement notice for
sessions that already received the older revision. Concurrent conflicting claims
become visible conflicts instead of last-writer-wins updates. A later timestamp
alone does not establish stronger evidence.

Version 1 record states are `active`, `superseded`, `conflicted`, and `forgotten`.
Only active, currently applicable notes are automatically injected. Historical
lookup can inspect superseded revisions with their status; conflicts are visible
in the view and explicit diagnostic queries, not ordinary injection. Forgotten
content is suppressed in supported lookup APIs. Provenance (`user_statement` or
`inference`) is independent of status; active does not mean verified. An expired
validity interval makes an active revision inapplicable without another status.

Track `recorded_at`, `observed_at`, and optional `valid_from`/`valid_until`.
Time-qualified historical questions may retrieve old revisions. Normal requests
receive active, applicable records. A remembered dependency version or passing
test describes its observed source revision; current files and tests can require
revalidation. Invalidation of a source should also invalidate unsupported derived
notes.

## Storage and durable completion

Use the existing filesystem-backed event store and content-addressed blobs for
canonical memory state. Add a dedicated stream, for example `workspace:memory`,
with a core projection containing records, revisions, tombstones, processed-round
markers, and a monotonic withdrawal sequence. Every dirty stream's whole
projection is serialized at checkpoint, so a dedicated stream avoids rewriting
all notes for unrelated workspace events. Core ownership also avoids the plugin
state cap (1 MiB by default) and plugin event-quarantine/lifecycle coupling.

**GC roots:** all flushed projections, core and plugin, are already walked
through `manifest/history`, including its current generation and retained fallback
generations. Those persisted projections already keep nested evidence blobs live.
The missing root is the dedicated memory stream's **unflushed in-memory** core
state: add it to the collector's direct walk alongside workspace/session core
state. Do not add a duplicate fallback-generation traversal.

Write candidate/evidence blobs and append their owning reference under one
body-use lease. Round completion already has a lease through the task watcher's
call to `finish_round`; keep that lifetime intact. Recovery and operator actions
use `with_body_use`. After a failed flush, the direct in-memory root keeps the
dirty batch's evidence alive when the lease ends, until a later flush publishes
it. Memory's own references then preserve sources after session unloading or
deletion under the policy below.

Use per-note projection keys or immutable record blobs plus a small catalog.
Add a `memory/batch` reducer that applies several key changes and the processed
round marker from one event; update the core event/projection allowlists. The
current `record_core_state` carries one state value and is capped by
`max_event_bytes` (256 KiB by default), with no separate core-state size check.
Preflight the complete batch and bound projection/catalog growth. A growing
single catalog event will eventually exceed that cap.

A canonical record includes:

```text
schema_version, id, revision, workspace, kind, key, text, tags,
status, provenance_class, pinned, evidence[], recorded_at, observed_at,
valid_from, valid_until, replaces, derived_from[]
```

An evidence entry carries host-owned source identity, source class, immutable
body or artifact digest, applicable source revision, and a bounded sanitized
excerpt where appropriate. Add explicit reachable references to the existing
body-GC traversal; verify sources survive session unloading, compaction,
checkpoint fallback, and retention. A session-local recall label alone is not
a permanent cross-session evidence reference.

### Durable receipt followed by one memory batch

1. Capture literal memory during normal response rewriting. Validate its bounded
   data shape independently of the reply. A deferred `done` creates no memory.
2. When the accepted round returns `done`, prepare normalized candidate data,
   stable candidate IDs, source call ID, and bounded source snapshots/references.
   Store them in one inert content-addressed blob. Carry only `memory_ref` and
   a small count/error summary beside `reply`; the receipt list is serialized on
   every save, so it must not repeat up to 8 KiB plus evidence for each old round.
   Nested digests in the candidate blob are already followed by body GC.
3. `finish_round_unlocked` determines the saved state and copies result fields
   into the receipt. Persist the reference only for a completed user round; store
   bounded rejection reasons for other initiators or invalid candidates.
   `save_round` writes the receipt blob and flushes the checkpoint. Its existing
   `update_session` also records a small memory recovery hint in the workspace
   session index, as specified below, in that same checkpoint.
4. After that save succeeds, first remove the session from `controller/active`
   and perform `note_delegation_round`, in their existing order. Then run memory
   admission in a guarded block, still within the session round gate. Recheck
   current revisions, deduplication, and suppression under the workspace memory
   gate; the per-session gate alone cannot serialize different sessions' updates.
5. Append one prevalidated `memory/batch` event keyed by the unique round ID.
   It contains every decision, record change, and processed-round marker, including
   all-rejected/no-op batches. A deterministic admission error caught before
   append produces a small terminal batch with an `admission_error` reason.
   Prevalidate batch size and reducer input so malformed candidates cannot leave
   a partially applied projection. Never append twice for an existing round marker.
6. Normally finish a terminal decision before releasing the round gate. Flush
   to acknowledge saved memory. If a checkpoint fails after append, retain the
   dirty batch and report "not yet checkpointed"; do not regenerate it. The
   normal store flush path retries all dirty streams, including this batch.
   Another session's successful flush can publish it without splitting the event.

Catch unexpected admission exceptions after the existing active/delegation
cleanup. Check whether that round's batch was already appended before doing
anything else. If it was, keep the existing batch and use the normal flush path;
do not replace a successful admission with an error merely because its checkpoint
failed. If admission threw **before append**, make one immediate attempt to
record a minimal terminal `admission_error` batch.

That fallback applies no note changes: it records the processed-round marker and
bounded error/count data only. Give it a fixed validated shape and a simple
reducer branch that does not call candidate parsing, evidence resolution, or the
failing admission logic again. It is terminal in the current projection, so the
next round may submit new memory; a successful checkpoint makes startup skip it
as well. Until publication, the existing dirty-batch flush rules still apply.

Keep the sticky indexed target only if even this terminal outcome cannot be
recorded. This is a recording failure, usually storage but potentially a host
bug; do not mislabel it as a bad user candidate. Emit a bounded best-effort trace
after attempting the terminal record. Trace failure must not mask the original
error or skip cleanup. The next ordinary round remains admissible: memory failure
must not leave the session `busy` or prevent the parent receiving its notification.
Preserve cancellation/panic categories under the host's existing policy rather
than relabeling them as an ordinary bad-candidate rejection; cleanup has already
run even if a fatal host failure must propagate.

Do not introduce a memory-specific reload operation or a reader gate. The store
clears dirty state only after `Store:checkpoint` succeeds and retains its event
arrays after failure. Reads may use the complete in-memory projection because
durability is prefix-ordered: if B reads A's unflushed note and proposes a
correction, publishing B's receipt also publishes A's dirty memory batch. A crash
before that flush recovers A's admission from its durable source receipt. A saved
acknowledgement still requires successful publication.

This argument depends on every checkpoint publishing all dirty streams of the
same store. Per-stream flushing or a separate memory store would invalidate it.
Fallback to an older checkpoint can roll back ordinary state; the independent
deletion floor preserves withdrawal suppression, not every later note or edit.
Operator edits and pin changes have no source receipt and must flush before
success is reported; forget additionally follows the floor-first protocol below.

Distinguish admission errors from persistence failures. A transient checkpoint
failure is not evidence that a candidate should be rejected, and failure to
append even a minimal error batch is a host/store fault, not another deterministic
rejection. Report the fault and preserve the indexed recovery target instead of
throwing past round cleanup. There is no unbounded memory retry queue or
background admission service in v1.

The final reply and `turn/end` keep their existing publication path. A final reply
can precede memory admission; the UI distinguishes request completion from memory
saved/rejected/not-yet-checkpointed. Optional-memory failures never rerun response code,
reissue a model call, or change a durable completed round into a failed task.
The host's existing authoritative-storage failure handling still applies.

### Selective startup recovery

Do not scan/load every finished session's event stream. The existing session
index is reconstructed from authoritative workspace core state, and ordinary
`recover_sessions` deliberately loads only the sessions needing runtime recovery.
For a completed user round with `memory_ref`, add `memory_round`,
`memory_receipt_ref`, and `memory_finished_at` to the session-index update already
performed by `save_round`. `memory_receipt_ref` points to the immutable completed
receipt blob that save already writes; its `memory_ref` keeps candidates and
evidence transitively live. The hint and receipt are durable in one checkpoint.

At startup, apply the deletion floor first. Then inspect the small index entries
and compare each `memory_round` with canonical processed-round markers. Load only
missing targets, dereferencing their receipt/candidate blobs directly where
possible; do not open all `done` or trigger session streams. Replay targets in
`finished_at` order with stable `(session_id, round_id)` tie-breaks. Recheck the
marker under the memory gate before append. If none are missing, there are no
memory-related session loads. Guard each recovery target independently: a bad
optional-memory target gets one normal attempt and, on a pre-append exception,
one attempt at the same minimal terminal-error record. Only failure to record
that terminal outcome retains the hint; ordinary poison candidates do not fail
again on every boot. Guard targets independently so a recording fault does not
block ordinary host startup. Never evaluate source or repeat tools.

**Recording-failure refinement:** a single latest-round hint is insufficient if
both admission and its terminal fallback fail while later rounds continue.
Preserve that unprocessed hint and its independent `memory_receipt_ref`; do not
overwrite it with a newer completion. Until the terminal outcome can be recorded,
continue ordinary tasks but decline new optional memory with an availability
diagnostic. Bound each repair/boot attempt as above. This retains one unresolved
recording target per affected session, without indefinitely disabling memory for
a candidate that merely throws while the recorder is healthy.

Keep the existing 128-receipt list limit. In the normal path, a later receipt
checkpoint publishes every earlier dirty batch before the older source receipt
could age out. In the exceptional pre-append path, the index's immutable receipt
reference remains a GC root even after that receipt leaves the list. Boot
recovery runs before new rounds or deletion, and processed markers survive event
retention. Stable candidate IDs live in `memory_ref`.

Lock order is **session round gate, then workspace memory gate, then existing
event-writer operations**. Acquire a body-use lease before those operations.
Nothing holding the memory gate may acquire a round gate. Operator mutations
hold the memory gate without visiting sessions; sessions pull notices later.

Shutdown currently can save `cancelled` after a final `done` reply was published.
For this proposal, admission follows the durable receipt as the code stands.
Changing precedence so completed `done` wins is a separate owner decision; memory
does not require changing that behavior or moving the reply path.

### Web metadata compatibility

Document the recovery hints as additive optional fields in the existing session
record contract. They serve host recovery; clients need not interpret them:

| Field | Type and meaning |
| --- | --- |
| `memory_round` | Optional Str identifying the indexed memory completion. |
| `memory_receipt_ref` | Optional Str digest of its immutable completed receipt. |
| `memory_finished_at` | Optional Str completion timestamp used for recovery ordering. |
| Round receipt `memory_ref` | Optional Str digest of the candidate/evidence blob. |

The current web layer already returns raw index records, pushes raw `round/state`
receipts, and copies a receipt into `last_round`, including existing fields such
as `digest` and `request_items_ref`. Preserve that behavior. Note the new fields
in protocol documentation and verify that clients tolerate unknown optional
metadata without requiring it or changing existing payload semantics. Keep lists
index-only and persist all recovery data unchanged.

A general public-record projection belongs in a separate, consistently versioned
change covering existing and new internal fields together. It is not part of
the memory admission milestone. Deliberate user-facing memory status remains
part of the later memory-view contract and its planned protocol update.

## Retrieval and context assembly

Version 1 searches the bounded canonical active set directly in Gene. Score exact
keys and paths, tag matches, lexical overlap, applicability, and source
strength with deterministic tie-breaking. Include at most a small pinned subset;
allow no-match. The expected initial corpus is small, but measure scan latency
and note counts rather than treating that as a guaranteed volume limit.
There is no entity-extraction subsystem in v1.

Implement retrieval as a built-in plugin's `request/prepare` hook, acting when
`round_turn == 1`. Add a labeled **settled** item containing `id@revision`, source
class/date, and a concise note. It stays with the round's initiating request in
history, so continuation turns retain it and normal settlement preserves cached
prefixes. A `^!settled` item would disappear after the first turn. A separately
moving provider-context message would disrupt that history model.

Keep two small pieces of session metadata: the set of note revisions ever received
and the last withdrawal/feedback sequences delivered. The received set does not
shrink at compaction. For automatic injection, persist the received revisions with
the history snapshot containing the settled item. For session-executed
`memory_search`, `memory_get`, and source reads that expose a note, record returned
revisions when the function is called, before returning its value—even if the
response code never prints or appends it. Do not wait for a model-visible item;
conservative over-inclusion merely causes an extra withdrawal notice.

Persist these explicit-read additions through the same session core/history
metadata without changing old message text. Delivery cursors have a different
rule: never advance a withdrawal/feedback cursor until its settled notice is in
the saved history snapshot. A read error must not be reported as a successful
untracked exposure. Operator-only view reads do not impersonate model-session
reads.

In particular, `/run` in a session can call `memory_get` and attach its result to
the model's next request as `[cN.name]`. It enters that session's received set at
call time, even though an operator initiated it and the attachment is delivered
later. Classify by exposure destination: exclude only reads whose output stays
in an operator-only view/UI, not all operator-initiated reads.

For duplicate suppression, skip an exact revision still present in retained
messages, using recorded injection locations/digests. The ever-received set is
for withdrawal matching, not proof that an exact note remains in active context.
No per-summary dependency graph is required. The visible settled block and
model/request recording show the actual bytes and revisions delivered.
Extend history/request metadata explicitly: `bounded_request` currently preserves
only selected item fields, so attaching an arbitrary `memory_refs` field to a
hook item would lose it. Deduplication uses host-recorded references and the
corresponding retained block, not ID-shaped text supplied by the model.

Start with a 4 KiB automatic-injection target, an 8 KiB hard UTF-8 ceiling, and
at most eight notes including pinned notes. Retrieval and explicit pull tools do
the rest. Record the policy version, selected revisions, and rendered digest.
Memory shares the existing aggregate request-item and compaction budgets; reserve
room for the actual request and other outputs. Byte estimates are not exact
provider token counts. Tune these defaults with measured context cost.

The plugin can own retrieval, its prompt row, functions, chapter, and view.
Literal capture, receipt admission, canonical storage, unflushed GC roots, and
withdrawal delivery remain host responsibilities. Automatic note selection runs
at round start; host withdrawal checks also run at continuation/resume boundaries
before model input is frozen. They append new settled context rather than change
old messages. Summary calls receive current withdrawal state too. Hook failure
may skip optional retrieval but must not silently skip mandatory withdrawals.

Proposed discoverable Gene functions:

```gene
(memory_search "CSV import failures" ^limit 5)
(memory_get "mem_..." ^revision 2)
(memory_sources "mem_...")
```

These names are application APIs, not implemented builtins. Keep existing
`recall` for exact historical bodies. Return paged, bounded data and expose
retrieval diagnostics without expanding the always-loaded prompt. Explicit
revision lookup must also enforce memory deletion suppression; an old revision
argument cannot resurrect a forgotten note through the supported memory API.

Harness's model can already gather evidence in ordinary Gene response code.
These functions and readable source records support deeper investigation in its
normal turns; no separate retrieval agent call is required.

### Deferred search upgrades

If scans become slow, SQLite FTS5 provides indexed text search and BM25 ranking.
[SQLite documentation](https://www.sqlite.org/fts5.html) Gene loads the system
SQLite library at runtime, so qualify FTS5 on each supported host, including
Linux x86_64. Use `$db/sqlite/open_file` for a persistent index, since its pager
avoids the whole-image publication mode of `open` described in the repository's
[library guide](../../../docs/stdlib.md).

A derived index then needs explicit canonical revision checks, replay/rebuild
progress, recent-change handling, and deletion suppression. Those obligations
belong to that later milestone. Optional embeddings additionally record model,
dimension, and content digest; a model change requires reindexing. Combine lexical
and semantic rankings with rank fusion, not raw score addition, and retain the
Gene scan as a fallback. Add ANN or graph storage only after measured need.

## Operator control, deletion, and later consolidation

Background review/consolidation is deferred. It can later combine duplicates,
build entity summaries, detect contradictions, and refine inferred lessons into
conditional procedures. Give it an independent model/time/token budget and
record calls with a distinct purpose such as `memory/consolidate`.

It should produce ordinary proposals with source revision dependencies and
compare-and-set expectations. Recheck those dependencies before commit. It may
not use the memory API to change project instructions, plugin code, or provenance.
Do not silently rewrite the facts supporting a lesson. A small index of related
IDs and entities can precede a dedicated graph database.

Version 1 has workspace-only notes and user-initiated admission. There is no
session-memory scope, child/trigger staging queue, or per-person namespace.
These are product filters inside the trusted process. Personal cross-workspace
memory requires an identity/sharing design before implementation.

Provide a memory view with source links, workspace identity, revisions, pin/unpin,
correction, forget, export, and consolidation diagnostics. Export a navigable Markdown/Gene
snapshot for inspection; canonical updates still go through the host service.
Useful controls should be explicit without requiring approval for every ordinary
well-supported project fact.

Show the exact quoted evidence beside both user paraphrases and inferred notes,
with conditions and dates. Offer likely-duplicate comparison and explicit merge.
New view endpoints need the existing web protocol/API version to be bumped, with
client compatibility tests. Consolidation controls can appear when that feature
ships; do not expose an unused review queue in v1.

### Append-only withdrawal and correction

Recommend withdrawal notices for ordinary forget/correct in v1. Forget means
"stop using this memory as guidance"; it does not promise removal of the words
from earlier conversations. Keep the original source statements and earlier
actions intact so their context remains explainable. Physical redaction is a
separate operation below.

Operator mutations use `with_body_use` and the memory gate. For forget, publish
the deletion floor **before** appending/checkpointing the canonical tombstone:

1. Build a versioned floor file containing suppression identities inline: note
   IDs/revision bounds, source-candidate identities, content digests, operation
   identity, and the monotonic withdrawal sequence. These are comparison data,
   not references to content blobs; include no note text or quoted evidence.
2. Publish it using the existing synchronized atomic-file write. Preserve all
   earlier suppression entries in v1. If this fails, do not publish a tombstone.
3. Install the new suppression state in memory, append the canonical tombstone
   and withdrawal record, and checkpoint the event store.
4. Acknowledge full success after both publications have succeeded.

Once the floor write succeeds, it is a durable withdrawal intent even if the
later append/checkpoint fails. Supported lookups consult the floor as well as
the projection and suppress the affected revisions immediately. At startup,
apply missing floor entries to the projection before any memory lookup or receipt
admission. A floor ahead of the checkpoint is safe; never roll it backward to
match an older generation. This removes the checkpoint-before-floor crash window
and requires no suppression-blob GC root.

V1 keeps floor entries and rewrites the small whole file on forget. A future
cleanup may drop an entry only after **every checkpoint the loader can still
select** contains its durable tombstone, equivalent suppression identities, and
the processed-round markers needed to reject old receipt/candidate replay.
A leading floor entry with no checkpointed terminal state is not redundant.
Enumerate the actual selectable generations: retention deletion is best effort,
so the configured retained count or `manifest/history` alone is not sufficient
proof. On uncertain proof, retain the entry.

Pruning changes only the redundant floor copy, not canonical tombstones or
processed markers. Use an atomic rewrite under the memory gate, preserve the
monotonic sequence and all unproven entries, and account for concurrent forgets.
Restoring an external older backup needs its own suppression/restore policy.
Implementing this cleanup is deferred; the rule records its safety condition now.

Ordinary corrections record the superseded revision, replacement, and withdrawal
sequence in their batch. Operator edit/pin/correct still flush before success;
the independent floor is specifically for durable forget suppression.

Each running or resumed session compares its ever-received revision set with
withdrawals after its delivered cursor. Matching changes become one settled
notice at its next model-call boundary. Unloaded sessions remain untouched until
they next run. The memory writer never acquires session gates or rewrites their
history. Examples:

```text
[harness_memory] mem_x@2 (storage.primary) was withdrawn by the operator on
<date>; do not rely on that note or its earlier summaries.
[harness_memory] mem_x@3 replaces mem_x@2: this project now uses PostgreSQL.
```

Keep each note's latest withdrawal sequence and effective state in the canonical
projection after old events are pruned. If a session's cursor predates the retained
notice window, reconstruct the needed current notices from its received set and
those canonical states. A long-unloaded session must not miss a withdrawal merely
because the original event aged out.

Include the key/subject, date, and a bounded identifying claim when needed to
connect a notice to an older summary. A replacement supplies its new text and
source. A forgotten note remains excluded from ordinary search/get; identifying
withdrawal text is a control notice, not a fresh active memory.

Commit delivered notices and their cursor in the same session history snapshot.
Coalesce multiple changes to the latest effective state per note. Keep notices
within the request/context budget and never advance over undelivered changes;
if they cannot fit even after normal compaction, report a context-limit failure
instead of silently continuing with obsolete guidance.

Delivery must happen at turn entry/final input preparation, analogous to incoming
delegation input. `request/prepare` for the next turn can run at the end of the
previous turn, so that hook alone misses changes arriving afterward. Treat input
freeze as the boundary: changes committed after it apply to the next call, and
an already-running call is not retracted. No extra model call is made merely to
deliver a notice.

Compaction may summarize text from before a withdrawal. Give the summary task
current withdrawals and, after compaction, append a concise reminder of effective
withdrawals/replacements for the session's received notes where needed. Do not
assume a model-written summary preserves every control notice. This uses the
ever-received set and current note state; it does not require tracking which
specific summary absorbed which note. Ordinary cached prefixes remain stable;
compaction remains the existing exceptional rewrite.

A checkpoint fallback older than the acknowledged deletion floor cannot serve
memory until required tombstones are reapplied. If recovery cannot establish
suppression, disable memory injection and lookups until repaired. A forgotten
note's old receipt cannot re-admit it; retain the source/candidate suppression
needed to enforce this. A deliberate new user statement can establish new
evidence, but replay of an old receipt cannot.

Withdrawal prevents supported memory retrieval and explicitly supersedes earlier
context; it cannot guarantee model obedience or erase original user input,
assistant proposals, summaries, transcripts, retained checkpoints, or backups.
Redacting all those copies requires a separate later design and may require
history changes and new summaries. The view must state this distinction. Later
indexes and consolidation jobs must participate in canonical suppression too.

### Conversation deletion

Recommend a delete-time choice: show the notes learned from the conversation,
default to **keep memory**, and offer **forget these notes**. State explicitly
that kept notes retain their quoted evidence excerpts after the conversation is
deleted. This lets cleanup preserve useful experience without hiding retained
content from the operator. The choice and its default remain an owner decision.

The delete request carries the explicit memory choice; do not guess it during
recovery. When forget is selected, apply its ordinary tombstone/floor/withdrawal
path and durably record the deletion intent before removing the session stream.
Surviving sessions pull notices on their next call. Kept records retain their own
evidence digests; they must not depend on the deleted stream's references.
Boot reconciliation finishes receipt admission before deletion is accepted, and
ordinary admission finishes under the round gate. If a caught exception
left an indexed unresolved completion, resolve it before a keep-memory deletion
or explicitly suppress/cancel its candidates under the forget choice. Never
delete the only recovery reference silently. Unloading does not delete notes.
Raw-source purge remains separate from either choice.

Use applicability and evidence to govern retention. Temporary observations can
expire; operator-pinned preferences survive ordinary age-based cleanup. Track
usage for utility assessment, while avoiding automatic confidence increases
based solely on frequent retrieval.

Memory ingestion can preserve malicious instructions for future sessions, so
retrieved text must retain its source class and remain reference data. Bound and
validate every write and read; scan for sensitive content before storing excerpts
or sending embeddings to a remote provider. Such scans are a mitigation, not a
complete guarantee. Anthropic's memory documentation likewise places storage
validation and bounds in the application. [Memory tool documentation](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)

These service policies do not establish a sandbox against trusted in-process
plugins or arbitrary admitted Gene code with filesystem access. Stronger isolation
requires an independently enforced process and storage boundary.

## Libraries and Gene ecosystem impact

Implement the memory policy and orchestration in Gene. Harness-specific
admission, workspace selection, completion semantics, and operator views belong here.
Reusable text-search primitives or embedding clients can graduate into `gene/`
or optional `genex/` packages when another application demonstrates the need.
This design requires no new Gene syntax or changes to language semantics.

| Option | Recommendation |
| --- | --- |
| Existing Harness store + bounded Gene scan | Default v1: fits checkpoint ownership, local operation, source recording, and a small canonical note set. |
| SQLite FTS5 | Deferred indexed-search upgrade, qualified against the host's runtime SQLite build. |
| Mem0 | Borrow extraction/consolidation patterns; benchmark as an optional external adapter if useful. |
| Hindsight | Borrow evidence/experience separation and traceable reflection; evaluate as an external alternative to maintaining advanced memory services. |
| Zep/Graphiti | Reconsider when real workloads require substantial evolving entity relationships and temporal graph traversal. |
| Letta-style context repository | Offer versioned readable exports and progressive disclosure; retain one canonical write authority. |
| Vector database | Add when corpus size, measured semantic-search gains, or deployment requirements justify it. |
| llama.cpp | Optional local inference/embedding backend; durable memory policy and storage remain host responsibilities. |

The source findings above explain these architectural influences. This table is
a fit assessment for Harness, not a claim that its proposed implementation
outperforms the named systems.

## Implementation sequence

Milestones 0 through 4 define v1. Milestone 5 is a later research track.

- **0. Workspace instructions baseline.** Add a bounded instructions-file prompt
  row with round-stable text/digest capture. Agree the filename before shipping.
  Document how it differs from scratch notes and automatic memory.
- **1. Literal final-response contract.** Ship `Outcome.memory`, Harness-only
  capture/marker handling, bounded validation, evidence resolvers, `memory_ref`,
  concise prompt, and chapter together. Include answers, prior user rounds, and
  operator-tool source classes. Render/reserve `[N.user]`, persist its source
  mapping, and extend recall. Add deferral notices and later rejection feedback.
  Render the submission prompt only for user-initiated rounds and reject other
  proposals quietly. Keep malformed memory independent of a valid reply.
- **2. Receipt-driven admission.** After durable user-round `done`, append one
  `memory/batch` under a workspace gate, guarded after active/delegation cleanup.
  Add active labeled inferences, dedup/CAS, the dedicated stream/reducer,
  unflushed GC root/body-use leases, index-directed ordered recovery, and bounded
  exception handling that immediately attempts a minimal terminal-error batch.
  Retain an unresolved target only when even terminal recording fails; keep
  ordinary tasks available. Document the additive recovery metadata and verify
  client compatibility at this step; a general public-record projection is deferred.
  Keep terminal admission-error batches, child/trigger rejections, normal dirty
  flush retries, and the existing receipt-list cap. Update `events.catalog` and
  regenerate `src/storage/generated_event_catalog.gene` with the existing Gene
  generator; update core event/projection allowlists.
- **3. Useful recall.** Add the built-in plugin, round-start settled injection,
  bounded Gene scan, retained-context duplicate suppression, session received sets
  and delivery cursors, plus `memory_search`, `memory_get`, `memory_sources`.
  Record explicit-read exposure at call time, including session `/run` commands,
  even without a prompt item. Inject/read/withdraw in child and trigger rounds too.
  No derived search index or new episode store is required.
- **4. Operator lifecycle.** Add source-quote/revision inspection, correction,
  likely-duplicate merge, pin/unpin, forget/export, inline floor-first suppression, and
  append-only withdrawal/replacement delivery, including active turns and
  post-compaction reminders. Decide the conversation-deletion keep/forget choice
  and default; bump the web protocol when adding endpoints. No retrospective
  history rebuild/redaction is required. This completes the v1 release gate.
- **5. Measured upgrades.** Consider FTS5, embeddings/rank fusion, round/episode
  search over existing receipts/transcripts, review/consolidation, and conditional
  procedure refinement. Add their indexing and deletion obligations with each
  feature, rather than requiring them for v1.

Likely new modules: `src/agents/memory_contract.gene`,
`src/agents/memory_context.gene`, `src/storage/memory.gene`,
`src/runtime/memory.gene`, `src/builtin/memory.gene`, and a memory view, with
focused integration into the existing files listed earlier. Use Gene for export,
migration, recovery, evaluation, and any later index-rebuild tooling. Keep the
reply/delegation publication paths and general Gene semantics intact.

## Evaluation and release criteria

Use model-free `gene test` specs with the scripted provider as the v1 release
gate. The milestone labels below identify when each scenario becomes required.

| Milestone | Required scenarios |
| --- | --- |
| 0 | Missing instructions file is normal; file text is not evaluated; round-captured text/reference is passed through instruction assembly; an edit changes each session's system prefix at its next round only; oversized/unreadable input is diagnosed. |
| 1 | Omitted/nil/empty/oversized/malformed memory leaves a valid reply intact. Calls and interpolation inside a captured subtree are not executed. Indirect payloads are rejected without claiming other response effects were prevented. |
| 1 | Render `[N.user]` only for a user round's first turn, resolve/recall the exact original prompt, reserve its label against `append_prompt` collisions, and preserve legacy output IDs. Resolve operator answers/tool evidence with correct origins; reject wrong-turn, child/trigger, nonexistent, and unobserved final-turn sources. |
| 1–2 | A user `done` deferred by plugins, media, or delegation creates no accepted notes and requests resubmission on final done. Child/trigger proposals receive receipt-only rejection, no resubmit advice, and no feedback queue. |
| 1–3 | Candidate/source rejections yield one bounded settled summary at the next round start; retry does not duplicate it and no extra provider call is made. Omitted memory stays quiet. |
| 2 | Both user paraphrases and inferred lessons become active with source quotes and dates; an inference is not labeled a verified result. A new session can retrieve them in milestone 3. |
| 2 | `memory_ref` keeps candidate/evidence blobs live through nested GC while receipt-list size stays small. Restart before receipt flush, between receipt/batch, and after batch yields at most one admitted batch; no response/tool effects replay. |
| 2 | Simultaneous sessions updating one revision produce a visible conflict; a matching key or different-key near-duplicate is handled without silent destructive merging. |
| 2 | Admission follows the durable saved state in the shutdown race. Deterministic pre-append errors get a terminal rejection batch; a checkpoint failure keeps the dirty batch for the store's normal retry. It is not converted into an admission rejection or a second append. |
| 2 | A failed batch flush followed by GC and a later successful flush preserves evidence through the new unflushed root and body-use lease. All persisted projections/fallback generations remain covered by the existing traversal; large batches obey byte limits. |
| 2 | An injected admission exception happens after active/delegation cleanup: the session is idle, the parent was notified, and the next ordinary round is accepted. A failed trace cannot undo cleanup. |
| 2 | A candidate that always throws gets one pre-append failure and one minimal terminal-error batch; the next round can save fresh memory and a successful checkpoint prevents retries on boot. The fallback never re-enters the failing candidate/reducer path. |
| 2 | If terminal recording also fails, retain one hint without leaving the session busy. Boot/repair bounds attempts; later rounds cannot overwrite the unresolved hint and its referenced receipt survives more than 128 ordinary receipts. |
| 2 | Boot scans index hints and loads no completed session streams when all targets have markers; only missing targets are loaded, in stable completion order. A normal batch already appended before a flush failure is never replaced by an error batch. |
| 2 | Session-list and round-receipt payloads accept the new recovery fields as optional additive metadata, including nested `last_round` data. Existing client behavior and index-only listings are preserved; no record-projection refactor is required. |
| 2 | Later receipt checkpoints publish earlier dirty batches; A's unflushed note and B's dependent correction receipt are published together. No memory-gate holder acquires a round gate. |
| 3 | Settled injection survives ordinary continuation with a stable prefix; notes still present are not repeated; ever-received metadata survives compaction but does not suppress needed exact retrieval. |
| 3–4 | Response code calls a memory function without rendering it, or operator `/run` returns it as a later `[cN.name]` attachment; returned revisions are recorded at call time and withdrawals reach that session. Operator-only view reads are excluded. Notice cursors require persisted notice text. |
| 1–4 | User, child, and trigger rounds receive relevant memory and withdrawal notices; only actual user initiators receive the submission prompt and can admit notes, regardless of session-kind labels. |
| 3 | No-match works; conditional lessons expose their conditions; explicit pull is bounded; total request/context byte limits still hold. |
| 4 | Correct/forget appends one settled notice per delivered effective change, preserving older messages. Unloaded sessions receive it when resumed; active rounds see changes arriving after earlier request preparation at their next input boundary. |
| 4 | Compaction cannot silently remove effective withdrawal guidance: summary tasks receive current status and post-compaction reminders cover ever-received notes. Late changes after input freeze apply next call without retracting an in-flight call. |
| 4 | The inline floor is durable before any tombstone can be checkpointed, even by another flusher. Crashes after floor write but before append/checkpoint keep suppression effective; boot applies missing tombstones before admissions. No floor-blob GC root is needed. |
| 4 | Source-candidate suppression survives fallback and old receipt replay; a floor ahead of the checkpoint is never rolled back. Operator actions acknowledge full success only after required publications; logical withdrawal is never described as erasure. |
| 4–5 | V1 retains floor entries. Any later pruning proof must cover every actually selectable checkpoint's tombstones, equivalent suppression identities, and replay markers; uncertain or leading entries stay, and floor cleanup cannot remove canonical suppression. |
| 4 | Conversation deletion persists the keep/forget choice and discloses kept excerpts. It resolves an indexed exception target or explicitly suppresses it before deleting its only recovery reference; unloading preserves notes. |
| 4 | The view shows paraphrase versus quoted source, inference labels, and near-duplicates; new endpoints enforce the bumped protocol contract. |
| 5 | A derived index can be lost/rebuilt without stale revisions; failed embeddings fall back to Gene retrieval; delayed consolidation respects revised/deleted source dependencies. |

Also replay a small set of real Harness tasks using the
[todo replay](todo-replay.md) format. Include a remembered gotcha,
a corrected false lesson, and an unrelated task where memory should stay quiet.
Score mistakes avoided, action/test outcomes, source correctness, and context
bytes spent. Keep this real-model replay distinct from deterministic contract
tests; neither a source quote nor literal capture proves a conclusion is true.

For later research, compare five arms under the same model and budgets: current
Harness, instructions-file-only, instructions plus lexical notes, added semantic
retrieval, and added consolidation. Split by project/task family and session;
only preceding interactions may form memories. Future questions must not leak
into extraction or promotion. Report repeated runs or confidence intervals.

LongMemEval needs an adapter to Harness's code-and-`Outcome` protocol and is
optional research work. Its update/abstention cases and LongMemEval-V2's workflow
and gotcha cases can inform product fixtures immediately. Diagnose storage,
retrieval, and downstream behavior separately, following EvalMem's distinction.

Measure evidence recall@k, incorrect/stale-note retrieval, useful abstention,
action success, memory-context bytes/tokens, p50/p95 scan latency, model cost, and
operator correction rate. Keep strict invariants for duplicate batches and
forgotten-note resurrection. Establish performance targets from measured
reference workloads rather than a universal accuracy or latency threshold.

The first release is successful when a completed request can optionally teach a
useful sourced note, a later session can retrieve it with its evidence class, and
a correction replaces it safely. Forget excludes it from ordinary memory lookup
and delivers withdrawal guidance to sessions that received it, including after
restart; it does not erase old conversation text. Embeddings and consolidation
should improve that verified baseline.

## Open questions

Resolve these choices before implementing the affected behavior:

1. **Shutdown race:** recommend preserving an already completed `done` when
   `/stop` arrives. Until separately decided, memory follows the current saved
   receipt, including its cancellation override.
2. **Inferred lessons:** recommend active hypotheses in v1 with labels and quoted
   evidence, as specified above. Confirm this policy rather than silently assuming
   that a model paraphrase is verified.
3. **Forget semantics:** recommend logical withdrawal with append-only notices
   in v1. Full redaction of history, summaries, logs, and checkpoints needs a
   separate design and is not implied by the forget control.
4. **Conversation deletion:** recommend asking at delete time, keeping memory
   by default while disclosing retained quotes, and offering explicit forget.
5. **Instructions file:** recommend root `AGENTS.md`; a configured file under
   `.gene-harness/` is an alternative if the owner prefers it.
