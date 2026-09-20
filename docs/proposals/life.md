# Gene Life

**Status:** Independent experimental design proposal.  
**Date:** 2026-09-19.  
**Focus:** A persistent virtual being with an AI brain, a long-running body, and behavior expressed through Gene code.

**Updated:** 2026-09-20.

> Gene Life observes, remembers, chooses, and acts over time. Its brain writes a brief decision note alongside an executable Gene program. The note preserves its expressed state of mind; the program directs its body.

This document records the direction agreed in the Gene Life discussion and proposes a small starting architecture. The APIs below are illustrative application interfaces, not claims about an existing Gene Life implementation or new Gene language features. They should change as the experiment teaches us what is useful.

## 1. The experiment

Gene Life is a virtual being with an AI brain. Its body is a long-running process connected to environments: conversations, a virtual world, and other sources of observations and actions.

The body continues to operate when the brain is not thinking. It receives messages, advances ongoing activities, maintains schedules, stores information, and delivers outcomes. It can also run internal control routines the brain previously wrote, such as restoring a modeled energy level during sleep. The brain is invoked when deliberation is useful; it decides what to pay attention to, what to do, what to postpone, and whether to communicate.

Interaction does not have to be real time. Receiving a prompt does not require producing a reply immediately—or producing any reply. Life can wait for more information, work on something else, return to an earlier discussion, or initiate an activity without a new human prompt.

The core experiment is whether continuity of memory, interests, decisions, and interaction produces coherent behavior over time. An avatar is one expression of that behavior, not the entire experiment. “Life” describes the application concept, not a claim that the system is conscious.

Persistence is essential to that experiment. Stopping and restarting the body must continue the same Life from its saved point: its memories, working state, location, possessions, conversations, relationships, and unfinished activities survive the process. Restart continuity is part of the first working version.

### Working principles

- **Code is the brain–body interface.** A response can contain computation, control flow, function definitions, API calls, and the construction of future behavior.
- **Decisions have a remembered context.** A brief text note records current focus, intent, uncertainty, and the rationale for acting or staying silent. Preserve it alongside the program and its actual outcome.
- **The brain chooses priorities.** The runtime supports those choices without hard-coding a universal priority formula or forcing every activity into a user-task workflow.
- **The brain defines its cognitive organization.** Memory and state have no required cognitive schema. The brain can define, combine, replace, and migrate their structures and the Gene code that interprets them.
- **The body can acquire new behavior.** The brain can introduce persistent variables, routines, and feedback rules that run between model calls. Energy and sleep are possible inventions, not required built-in traits.
- **Life survives its process.** Durable application state is the source of continuity. A clean stop saves a consistent continuation point; an unexpected exit recovers the latest committed point and identifies any uncertain effects.
- **The body stays alive between thoughts.** World simulation, message receipt, timers, and active jobs do not require continuous model inference.
- **Keep the core small.** Implement one individual with useful observable behavior before building a framework for every possible kind of agent.

### Starting disposition

Choose an explicit starting disposition for the first individual: curiosity about its surroundings and an interest in tending a small garden. Store that seed with the initial configuration, and issue a first-start observation so Life can inspect its environment without waiting for a human message. Creating a new Life is an explicit operation. Opening an existing Life restores its retained interests, state, and world position; it never reruns first-start initialization or silently substitutes a fresh individual when restoration fails.

These are starting interests, not permanent obligations or a universal motivation formula. Life may develop, revise, or abandon them through experience. A quiet environment may lead to exploration, a future wakeup, or inactivity. Record which starting disposition an experiment used so comparisons do not confuse different initial conditions with learning.

## 2. Independent from Gene Harness

Gene Life is a separate experiment, not a Harness profile, renamed Harness, or layer that must boot Harness underneath it.

It has its own package, entrypoint, state model, brain interface, and development milestones. It does not have to adopt Harness's runs, turns, tool envelopes, plugin registries, or composition workflow.

The projects can share ideas and later reuse well-separated components, such as a model client or storage library. Reuse is optional and should follow demonstrated needs. Cordis is also an optional implementation choice, not a required foundation.

The difference in purpose is useful:

| Project | Central question |
| --- | --- |
| Gene Harness | How can an agent execute requested work reliably? |
| Gene Life | How can a persistent individual develop coherent, self-directed behavior through experience? |

Do not postpone Life until Harness is complete. Do not build a universal shared agent core before either experiment establishes which abstractions it needs.

## 3. Body, control system, and brain

```text
Conversations       Timers        Virtual world       Other observations
      \                |                |                    /
       +---------------+----------------+-------------------+
                               |
                         Body / control
                   events, storage, jobs, delivery
                               |
                       selected experience
                               v
                            AI brain
                               |
                   decision note + Gene program
                               v
                 Gene execution (program only)
                               |
                memory changes, schedules, actions
                               |
                      actual outcomes
                               +------> Body / control
```

### Body and control system

Separate a small stable host from the evolving body it runs. The host receives and durably records events, maintains clocks and execution queues, commits data, invokes selected Gene code, and records actual adapter outcomes. The evolving body is ordinary stored Gene code plus persistent data: perception filters, attention, memory organization, internal variables, activity controllers, and routines that operate between thoughts.

| Part | What it owns |
| --- | --- |
| Stable host | Life identity, durable storage mechanics, code revision selection, event delivery, execution limits, operator controls, recovery, and records of actual operations. |
| Brain-defined organization | Cognitive data structures and their meaning; retrieval, context, attention, internal body models, routines, and learned behavior. |
| Environment and adapters | Authoritative external state and the rules and outcomes of operations performed there. |

The host needs to know how to retain and run a routine, not what its `energy`, `mood`, or `memory` fields mean. Adding such a concept should require data and Gene code, not a new host field or scheduler branch. The brain can evolve adapter-facing control code and compose existing operations; creating an internal variable does not change an external world's rules or manufacture a successful action.

Startup, shutdown, pause, execution limits, storage recovery, and the minimal operational record remain host responsibilities. They keep working if a generated memory library, attention policy, or body controller breaks. Keep a known working recovery path that can inspect generic stored data and select a repaired revision without requiring the faulty organization to interpret itself.

### Brain

The brain interprets the selected experience and writes a decision note and the next program. Its implementation is replaceable: a remote model, local model, or experimental combination can satisfy the same interface.

Conceptually:

```text
brain.think(context) -> { note: text, program: Gene source }
```

This may be an asynchronous request. Model connection details belong in the brain adapter, not in every part of Life.

The brain's model weights are not the whole being. Identity, remembered experience, interests, ongoing intentions, and learned procedures are retained separately. Changing the model is therefore an explicit experimental change, not necessarily the creation of a new individual.

### Environment

The environment owns its actual state. If Life tries to move, build, send a message, or read an object, the environment or its adapter reports what happened.

A generated sentence saying an action succeeded is not evidence that the action occurred. Record intentions, attempted operations, and observed outcomes as distinct information.

## 4. Brain responses pair a decision note with a program

### 4.1 No mandatory tool-call envelope

The brain returns a brief text block followed by one complete Gene program. The text is a decision summary: what currently matters, what it intends to do, relevant uncertainty, and a short rationale. It can capture an unresolved question or why silence is appropriate. It is an authored account of the current decision, not a complete record of the model's internal computation.

A response can look like this:

```text
My current focus is caring for the garden. I will inspect the plants and water
those that are still dry when the action runs. I do not yet know their current
condition. If none need water, I will check again later. No conversation reply
is needed for this routine inspection.
```

```gene
(do
  (let plants (body/world .observe "garden/plants"))
  (var dry [])
  (for plant in plants
    (if_yes (== plant/status "dry")
      (dry .push plant/id)))
  (if (> dry/.size 0)
    (then
      (for id in dry (body/world .water id))
      (memory .remember
        {^kind "experience"
         ^text "Watered the plants that were observed to be dry."
         ^subjects dry}))
    (else
      (scheduler .wake_after 600000 "Check whether the garden needs attention")))
  {^inspected plants/.size ^dry dry/.size})
```

All names other than ordinary Gene forms are proposed example interfaces. Here the world adapter's `water` call completes an immediate simulation operation or raises; a long-duration action uses a job as described below.

There is no required response type such as `tool`, `answer`, `wait`, or `plan`. Those choices are expressed by what the program does. A single program can perform several useful operations without another model round between each one.

Ordinary functions remain ordinary functions. Introducing a new body method or importing a reusable library does not require defining a new JSON tool schema, adding a response-enum variant, or modifying a central dispatcher.

Keep the note short enough to carry forward usefully; a simple decision may need only one sentence. The body retains the note with its cycle, context reference, program, and execution status. Writing an intention in the note does not schedule work or update an operational commitment. Those changes still require code.

The note remains free text, with no compulsory emotion, confidence, or plan fields. Its pairing with source is a transport convention; it does not define a vocabulary of permitted actions.

### 4.2 Results are not automatically messages

The program's return value is an execution result recorded by the body. It is not automatically sent to the person or channel that supplied the latest observation.

The decision note is also internal by default. It may appear in an operator inspection view, but it is not automatically published to a conversation or turned into a chat message.

Communication is explicit:

```gene
(body/chat .send context/focus/reply_to
  "I have checked the garden. The dry plants are now watered.")
```

A program returning `nil` is a valid no-action decision. A program that updates memory without sending anything is also valid. A program that schedules work for later does not need to manufacture an immediate conversational reply.

Transport acknowledgments, such as acknowledging receipt of an incoming event, remain body operations and are independent of the brain's eventual response.

### 4.3 Complete, explicitly separated text and source

The initial textual response format is exactly one `text` fenced block followed by exactly one `gene` fenced block, with only whitespace outside them. The adapter validates that framing and extracts the two fields; it never evaluates the text block. Reject missing, repeated, unclosed, or ambiguously delimited blocks. Do not guess which fragments of an arbitrary mixed prose response were intended as executable code. A provider may supply the two fields separately if its adapter documents that transport.

Both parts must be complete before the response is accepted. Parse and compile the complete program before executing it. Silence still includes an executable program, such as `nil`; a note alone is not an executable decision. A fake brain can return the same two fields directly without a textual transport.

Streaming output may be displayed as a draft, but partial output is not executed or selected as the latest decision note. Framing, parse, or compile errors become observations for a later correction attempt. Retain rejected responses as diagnostics, clearly separate from accepted decisions. Limit repeated correction attempts rather than entering an endless automatic repair loop.

Text retrieved from a conversation, memory record, or web page remains input data. It is not another executable brain response merely because it contains Gene-looking text.

### 4.4 Normal execution, not a second interpreter

Use Gene's normal reader, compiler, and execution facilities for the supported program boundary. Do not implement a separate miniature language that recognizes a handful of approved action expressions.

Definitions and control flow inside a response follow the selected Gene execution path. Persistent module definitions and imports use the normal module loader; this proposal does not assume every top-level declaration or source import is legal inside an `eval` body.

Local variables and function definitions belong to that execution. To reuse behavior later, save it explicitly as code or retain it through a documented in-process registration. Accidental survival of an evaluator environment is not the persistence model.

### 4.5 Remembered decision notes

Persist an accepted note and its program before execution, then attach the actual execution outcome. A note describes intent at the time of the decision: if the program is deferred, cancelled, interrupted, or fails halfway through, that status must accompany the note when it is retrieved. A note saying that Life plans to water a plant is not evidence that the plant was watered.

Recent notes or a compact summary can help the next cycle recover its focus, unresolved questions, and reasons for postponing something. Keep this context bounded, allow later decisions to revise earlier interpretations, and retain links to the source cycles when summarizing. A contradiction should be visible rather than silently rewriting the earlier note. Notes follow the visibility and retention rules of the information they summarize, and saving one does not itself wake the brain.

## 5. Context supplied to the brain and program

The brain receives a bounded view of current experience, not necessarily the whole history or the entire world database.

A starting context can include:

```gene
{^life_id "life-001"
 ^cycle_id "cycle-104"
 ^context_id "context-104"
 ^policy_revisions {^attention "attention@1"
                    ^retrieval "recall@1"
                    ^context "context@1"}
 ^now "2026-09-19T18:30:00Z"
 ^focus {^event_id "event-882"
         ^reply_to {^adapter "chat" ^conversation "workshop" ^thread "thread-7"}}
 ^observations []
 ^current_interests []
 ^pending_work []
 ^recent_decisions []
 ^recent_results []
 ^memory_excerpt []}
```

This is the starter context builder's output, not a required cognitive schema. The brain may replace fields such as `current_interests`, `pending_work`, and `memory_excerpt`, or replace their organization entirely. The host records cycle identity, provenance, and revision metadata independently of that presentation. An autonomous cycle may have no conversation focus or reply destination. Code using the starter builder must check for that before using it.

The context builder also supplies compact documentation of the available Gene APIs and relevant reusable code. Large reference material can be discovered through an ordinary documentation function instead of being copied into every prompt.

Observation selection, retrieval, and compression shape what the brain can consider. Treat the context builder as an evolving part of the cognitive organization. Record the selected event and memory references, policy revisions, and resulting context snapshot for each cycle. Select policy changes at a cycle boundary; keep the policies used for an in-flight context identifiable.

`context_id` identifies this immutable snapshot, not a global validity counter. Record relevant ownership IDs/generations and code revision references with the cycle for later checks; the cognitive libraries map those ownership tokens to their own concepts. Unrelated arrivals or state changes do not invalidate the entire snapshot. `recent_decisions` contains selected notes together with their execution statuses and outcome references, not unqualified assertions that their plans succeeded.

At execution, the program receives the same context snapshot and ordinary application objects:

| Binding | Initial responsibility |
| --- | --- |
| `context` | Snapshot used for this decision, including selected event identities. |
| `life` | Identity and public runtime operations, such as starting an asynchronous job. |
| `store` | Generic durable records, immutable revision reads, and atomic commits of related local changes. |
| `state` | Starter library for working data, with brain-defined contents and replaceable access methods. |
| `memory` | Starter library for remembering and retrieval; its schema and implementation belong to the brain. |
| `body` | Named adapters and selected body routines, such as `body/chat`, `body/world`, or a later `body/rest`. |
| `scheduler` | Future wakeups, scheduled programs, and recurring work. |
| `code` | Stored Gene source and revision references for reusable behavior. |

These bindings are a suggested starting vocabulary, not a required object hierarchy. A small implementation can combine them or expose ordinary imported functions instead.

The remote model receives descriptions and data, not live process objects. The Gene program receives the actual runtime bindings when the body executes it.

The `memory` and `state` bindings are conveniences built on the same durable store. They may share a representation, split into several modules, or disappear behind a different interface. The host persists selected roots and revisions without traversing a prescribed cognitive object model.

## 6. The attention and execution loop

Start with one active brain decision and one foreground program execution per Life. The body can still receive events and run asynchronous jobs while waiting for the model.

Brain-produced programs, scheduled programs, and brief body-control handlers share one serialized foreground execution queue for application data changes. A due handler may execute while inference is pending; the returned decision must then pass the checks below. Background jobs affect their environments through adapters and return outcomes as events; they do not receive live mutable cognitive records to rewrite concurrently. Apply cognitive state changes through the foreground path.

```text
1. Receive and retain observations.
2. Decide whether a brain invocation is needed.
3. Select observations, working state, and relevant memory.
4. Request a complete decision note and Gene program from the brain.
5. Validate the response framing; parse and compile the complete program.
6. Retain the accepted decision, check its basis, and execute if still usable.
7. Record its status, return value, failures, and actual action outcomes.
8. Preserve new events and schedule the next useful reconsideration.
```

The single foreground decision is a starting simplification, not a prohibition on future parallel thinking experiments. Background jobs return their results as events rather than directly racing to rewrite the agenda.

### New events during thought

Incoming events remain queued while the brain is working. Each cycle records which observations it considered; completing that cycle must not accidentally mark later arrivals as handled.

Distinguish an observation included in a context, a completed consideration of it, and an outstanding intention. A successful `nil` program counts as consideration and does not leave the same event continuously eligible just because no message was sent. Reading a request does not complete a commitment. Future reconsideration comes from retained intentions, new information, or an explicit wake request. A rejected, stale, or failed cycle retains its selected event references for bounded recovery; it neither drops those events nor triggers unlimited immediate retries.

Do not reject every response merely because a newer message arrived. Before execution, check operator stop/pause, the validity of relevant ownership IDs/generations, and availability of the selected code revisions. Pin code dependencies used by a decision; selecting a newer version does not silently substitute it into an already accepted program. Explicitly withdrawing an old revision can instead defer that decision.

A cognitive-organization replacement follows the quiescent selection rule in section 9. Ordinary state updates may proceed during inference; changing the meaning or layout of that state waits for the affected cycle to settle or be explicitly invalidated. Record the organization revision with each model request, and reject a late response from an invalidated cycle before any effects.

The body cannot infer every semantic dependency of arbitrary Gene code. Adapters check current action preconditions when performing the operation: for example, whether a plant still exists and needs water, or whether a conversation destination is still valid. Programs can supply explicit expected versions where the application needs them. A cycle-level check does not reserve world state while inference or execution continues.

A stale decision can be deferred or returned to the brain with the new observation. Do not automatically replay a program that may already have performed effects.

### Priority is a policy, not a fixed equation

An initial attention policy can batch nearby messages, wake on direct interaction, and revisit explicit intentions when due. The brain may later replace that policy with code using different considerations.

Importance, curiosity, timeliness, relationships, novelty, effort, and unfinished work are possible inputs. They need not all exist as numeric scores. Do not hard-code that chat always outranks exploration, or that every remembered interest must become a formal task.

A previously accepted commitment should remain visible until completed, revised, or abandoned explicitly. Flexibility does not require losing track of what Life already said it would do.

### Preserve responsiveness

A generated program should not freeze event receipt or the operator's stop/pause controls. Use the existing execution model's supported interruption mechanism, with a simple per-execution work limit. Long-running activity belongs in supervised jobs, not an infinite foreground loop.

Initially, pause stops new inference and foreground dispatch, checkpoints resumable activities, requests cancellation of their current execution handles, and retains incoming observations and due schedules. Pausing or stopping execution preserves its owning intention and saved progress; explicitly abandoning an activity is a different operation. Late model responses are recorded but not executed. The body continues receipt and maintenance, and an external environment may continue to advance. Mark pause settled only after active work has settled and its progress and outcomes are durable. Resume uses restored state and fresh context, and rechecks due work under the missed-run policy. Stop additionally freezes the local simulation and saves the consistent continuation point described in section 10 before shutdown.

Start with basic limits on model calls, repeated failures, and queued work. This document does not define a new permission or capability subsystem.

## 7. Asynchronous behavior through ordinary code

The difference between an immediate action, a long activity, and future reconsideration should be visible in the library APIs—not encoded in a fixed brain-response format.

### Immediate computation and operations

A normal function can inspect data, update local state, or perform an operation that returns promptly:

```gene
(do
  (let entries (memory .recall "unfinished experiments" ^limit 10))
  (state .put "attention/next" entries)
  nil)
```

The runtime records that the program returned. It does not automatically wake the brain again solely because a memory or state record changed. Selected body handlers can update brain-defined state through the same durable library APIs, even while the model is idle or unavailable.

### Long-running activity

Use an ordinary activity-library call for behavior with a defined recovery contract. The first world library provides `start_walk`, which prepares a durable job and its recovery information. Related cognitive state can be committed with the job through the grouped-update API specified in section 10:

```gene
(store .commit
  (fn [tx]
    (let job (body/world .start_walk "garden" ^tx tx))
    (state .put "activity" {^kind "walking" ^job_id job/id} ^tx tx)
    job/id))
```

Inside this callback, `start_walk` returns a prepared job descriptor containing its ID; the job cannot execute yet. `store.commit` returns the callback's `job/id` result only after both records commit. Without an explicit transaction, `start_walk` commits its job before returning, and each subsequent state update is a separate durable operation.

The generic `life.start_job` primitive remains available for quoted Gene code and explicit serializable inputs. It accepts the same optional `tx` argument, and activity libraries use it underneath their public calls. Completion, cancellation, or failure creates an observation tied to the job ID. A job may use supported asynchronous Gene APIs without a model call for every step.

The job's ID, optional ownership ID/generation, code revision, inputs, status, and recorded progress are durable. A durable description is not a durable execution stack. The job's recovery behavior must be explicit:

| Job state or implementation | Recovery |
| --- | --- |
| Started through an activity implementation with a registered checkpoint/recovery contract | Reconcile outcomes and continue from its committed progress under the same job ID. |
| Committed but never started | Dispatch if its saved inputs, code/data compatibility, organization revision, ownership generation, and admission conditions remain valid. |
| Started arbitrary code without sufficient continuation information | Preserve partial outcomes and mark interrupted for reconsideration; do not replay the program. |

For walking, the library prepares the destination, job identity, and recovery-handler revision before publication. Its implementation advances logical movement steps and commits position, activity progress, and outcomes together. On restart it reads that checkpoint, recomputes the remaining path if needed, and continues. This machinery lives in the world/activity library; the brain does not generate a state machine each time it wants to walk.

Calling a checkpointed function inside an arbitrary program does not make the surrounding program resumable. Recovery handlers cover their declared activity and completion boundary; additional computation after that call needs its own continuation contract. Returning a task or lazy stream likewise does not silently create a durable job. Stronger recovery guarantees come from the activity implementation and the checkpoints it actually uses.

### More information without a special tool round

When the brain lacks information, it can generate code that retrieves it and requests a later reconsideration:

```gene
(do
  (let notes (memory .recall "visitor project" ^limit 12))
  (state .put "working/visitor_notes" notes)
  (scheduler .wake_after 0 "Use the retrieved project notes")
  nil)
```

A zero-delay wake means eligible after the current execution settles, not recursive re-entry into the brain. The scheduler coalesces it with other pending reasons.

## 8. Heartbeat, scheduled code, and cron

Separate three kinds of activity:

| Mechanism | Purpose |
| --- | --- |
| Heartbeat | Cheap body maintenance: connector health, job progress, due work, and pending attention. |
| Cognitive wake | Ask the brain to reconsider with fresh context. |
| World tick | Advance movement, physics, animation, and simulation rules. |

Neither a heartbeat nor a world tick requires a model call. Inactivity is allowed; Life need not invent work on every timer firing.

### Wake for a new decision

```gene
(scheduler .wake_after 300000 "Revisit the workshop conversation")
```

This asks for fresh deliberation after a delay. It does not preserve the current model context as the next context or promise that a message will be sent.

### Execute known code later

```gene
(scheduler .after 300000
  ^code (quote
    (body/chat .send input/destination input/text))
  ^bindings {^destination context/focus/reply_to
             ^text "The scheduled workshop session is starting."}
  ^missed {^run_within_ms 60000 ^otherwise "expire"})
```

This schedules a specific program rather than asking the model to decide the same thing again. It is appropriate when the desired action is already settled. When the wording or action depends on future circumstances, schedule a wake instead.

Here the illustrative `missed` option permits dispatch up to one minute late; after that, the reminder expires and the body records the missed execution.

Scheduled code runs in a fresh execution scope with the saved bindings available as `input`. It does not implicitly capture the current stack or local variables. Store its source/revision and explicit data bindings; load ordinary dependencies through the normal code-loading path.

Due programs enter the same foreground queue as brain-produced programs. Due time means eligible to run, not a guarantee of simultaneous or exact-time execution. Keep queued dependencies pinned, and recheck organization compatibility, cancellation, and action preconditions when dispatched. Section 9 defines how organization changes account for queued work. A scheduled program has its own execution record linked to the originating cycle and note; running it does not require the brain to author a new note.

Both scheduling operations return IDs so code can inspect, update, or cancel them. Rescheduling the same conceptual activity should replace a known schedule rather than accidentally create unbounded duplicates.

Work ownership uses generic IDs and generations, such as `{^owner_id "owner-17" ^generation 3}`. The brain's libraries decide whether an owner represents an intention, a routine, or another concept. Cancelling or replacing it advances or retires that generation, invalidates related queued work, and requests cancellation of active owned work. The host checks these tokens without requiring a goal schema. Independent schedules need no owner. A delayed message about a cancelled workshop must not survive merely because its destination and text were saved correctly.

### Recurring work

Cron-like scheduling is another library operation:

```gene
(scheduler .cron "0 9 * * *" "America/New_York"
  ^code (quote
    (scheduler .wake_after 0 "Review today's interests and commitments"))
  ^bindings {}
  ^missed "coalesce_once")
```

The exact cron library and method names remain implementation choices. The API must state its timezone and missed-run behavior. Initially, coalesce missed cognitive wakeups into one review. A known program must select a missed-run policy when scheduled, such as run once within an explicit lateness window or expire and report that it was missed; do not replay a backlog implicitly. Apply these rules after downtime and operator pause, with cancellation checks before dispatch.

Give generated internal events a cause ID. Logs, memory writes, and reflection records must not create an automatic think–write–think feedback loop. New external information, explicit wake requests, and meaningful job outcomes are the initial wake sources.

Brain-defined body routines may later subscribe to selected events or a chosen clock. Persist each registration, its code revision, clock choice, and dispatch progress. A routine runs bounded ordinary Gene code without invoking the model. It can explicitly request cognitive attention on a meaningful transition, such as finishing sleep, while ordinary internal updates remain quiet. Coalesce timer firings where the routine's declared elapsed-time rule permits it; a failed or noisy routine cannot monopolize the queue or bypass stop controls.

## 9. The brain defines memory and state

The host imposes no cognitive schema: no required episode class, belief table, goal object, personality vector, or separation between long-term memory and working state. The brain chooses the structures, their semantics, the functions that access them, and how they change over time. It can start with plain records and later use journals, graphs, topic documents, indexes, or a combined representation.

Descriptions such as **experience**, **belief**, **working state**, and **procedural memory** help explain what information is doing; they are not mandatory storage classes. A single brain-defined record may serve several purposes. The host's **operational records** separately preserve what it received, executed, scheduled, or delivered, so an interpretation can be compared with its evidence after a cognitive reorganization.

**Decision notes** preserve expressed focus, intent, uncertainty, and rationale at particular cycles. The brain may organize or summarize them in any useful way. Their original cycle records and outcome links keep the distinction between a reported intention and an observed effect inspectable.

### Generic persistence, replaceable meaning

Offer a small durable store that can read records by identity/revision, enumerate named data roots, and atomically commit related writes and root selections. The host retains only the metadata it needs for durability, revision checks, causal/source links, visibility, and retention. Cognitive payloads are ordinary serializable Gene data interpreted by selected Gene code. Code is stored by immutable revision reference; a live closure or runtime object is not silently serialized.

Persistence covers all committed data reachable through the selected roots, including fields the host has never heard of. The brain does not need to register each new cognitive field with the host. A custom encoded representation must retain the decoder revision needed to read it; the host can still preserve and inspect its raw records if that decoder fails.

The starter `memory` module can offer `remember` and `recall`, and `state` can offer simple keyed access. These are replaceable libraries. For example, the starter memory module might accept:

```gene
(memory .remember
  {^kind "observation"
   ^text "A visitor said they prefer a shaded garden."
   ^source_event "event-882"
   ^conversation "workshop"
   ^subject "visitor-14"})
```

The fields in this example belong to that library, not the host. A later implementation may organize the same retained evidence as a visitor document, a graph edge, or a procedure that retrieves related observations. It may merge memory and state into a single representation without changing the brain-response format.

### Preserve meaning across representation changes

The freedom to choose structure does not remove continuity requirements. Remembered preferences, ongoing commitments, and relevant experience must remain accessible according to the new organization. The host stores them without understanding their meaning; the brain's migration and retrieval code is responsible for preserving that meaning, and representative before/after queries provide evidence that it did so.

Keep source references or equivalent provenance sufficient to distinguish “the user said this,” “the world reported this,” and “the brain inferred this.” Original action outcomes remain operational evidence. Stable ownership references connect scheduled work to its brain-defined intention or activity; changing the cognitive schema must preserve or explicitly retire those references. The host need not know the intention's record layout to check its cancellation generation.

Memory is selective rather than an obligation to retain everything forever. Deletion and retention choices should apply to derived summaries and indexes as well as original records.

### Evolving organization

A practical sequence is to build a candidate representation from a retained snapshot, exercise its retrieval and update code, and prepare a migration. The initial selection strategy is **quiescent selection**: stop admitting new affected cycles, let the current affected decision and foreground execution settle, checkpoint affected activities, and pause affected handlers. Then migrate from their latest committed state and atomically select compatible code, data roots, and registrations. A crash must expose either the old selection or the complete new selection.

A replacement request does not itself change active bindings. A response that arrives while selection is pending may finish under the old organization before the switch. If that cycle is explicitly invalidated to proceed with selection, retain a late response as superseded without executing it, and request fresh deliberation under the new organization. Selection requested by the current program is queued until that program settles. Keep event receipt durable throughout; unrelated work can continue. If affected work cannot settle within its limits, defer the change or explicitly interrupt it and retain its recovery state.

Selection also accounts for affected queued programs, schedules, routine registrations, and jobs that have not started. Initially, conservatively associate cognitive work with the organization revision under which it was created; do not infer its data dependencies from arbitrary Gene code. Each item must remain explicitly compatible with the selected organization, be migrated with its code/input bindings, or be invalidated for reconsideration; otherwise defer selection. Commit these dispositions with the new organization and recheck compatibility before dispatch. Pinning an old code revision alone does not make it compatible with migrated data.

Invalidating queued execution preserves its owner, original revision, reason, and pending commitment for reconsideration. It does not silently delete work or mark an intention completed. Keep the original provenance when replacing or migrating a queued item.

Start with one active cognitive organization. Running old and new organizations concurrently, catching up migrations while both accept writes, or preserving incompatible readers through a switch is later work that needs a demonstrated benefit.

Keep a short description of the selected organization, its access functions, and its roots with the code revision. The context builder can teach a later model how to use the current organization instead of assuming the starter `memory` and `state` libraries still exist. The host can restore the selected code and raw data before any model call.

Recovery keeps event receipt, schedules, delivery records, and operator control readable even if the cognitive migration fails. Changing a memory schema or introducing energy does not require changing the durable host format. Versioned changes to that host remain a separate development task.

## 10. Persistence and continuity

Persistence is a core application contract. After a clean stop and restart, Life must recover the same durable identity, memories, working state, embodied state, conversations, and ongoing activities at the saved continuation point. After an unexpected process exit, it must recover the latest committed point and reconcile interrupted operations. A restart must not require a person to reconstruct its context or tell it where it was and what it was doing.

Persist the selected organization as well as its data. Its definition is a small revision record identifying selected code/dependency revisions, named data roots, registered routines, clock choices, subscriptions, and their dispatch progress. It describes how to reconstruct the running organization; it does not prescribe its cognitive schema. Saving code alone does not activate it, and defining a new body field does not require a host schema migration.

Use one transactional local store initially, with one active body process writing a Life's state. Code, memory, conversation records, and the small world's authoritative state can co-live there. Snapshots and a journal of committed changes can support recovery without replaying programs or external actions. Database-backed module loading is optional: source may use the ordinary file/module workflow, provided saved revisions and their dependencies remain available after restart.

### State that must be restored

The areas below describe continuity obligations, not required tables or record layouts. Cognitive and internal-body contents use the brain's selected representation; the host persists their generic roots and revisions. World and transport adapters keep their own operational contracts.

| Area | Required durable contents |
| --- | --- |
| Identity and configuration | Life ID, starting disposition, current interests and dispositions, model configuration references, selected cognitive policies, and storage version. |
| Selected organization | Compatible code/data revisions, access documentation, body routines, event/timer registrations, clock choices, and dispatch progress. |
| Memory | Retained experiences, beliefs, relationships, summaries, provenance, visibility, and retention/deletion decisions. Derived indexes may be rebuilt from durable records. |
| Working state | All values saved through the state interface, current focus, intentions, commitments, unresolved questions, and current activity references. |
| Brain-defined body state | Any introduced variables and modes, such as energy, sleeping status, recovery rules, and elapsed-time checkpoints, without host knowledge of their field names. |
| Mind and decisions | Retained decision notes, context snapshots or their reconstructible contents, generated programs, and execution statuses and outcomes. |
| Embodiment and local world | Stable world/entity IDs, location and orientation, inventory and held objects, relevant body state, object states and relationships, and simulation time. |
| Conversations | Retained message histories, participant identities, conversation and thread IDs, visibility, reply destinations, pending replies, external event IDs, and connector receipt cursors. |
| Events and schedules | Durable inbox, consideration references, wake reasons, due times, recurrence and missed-run policies, cancellation state, and generic ownership IDs/generations. |
| Code and activities | Saved source and dependency revisions, selected helpers, job IDs and inputs, completed phases, continuation checkpoints, and recorded outcomes. |
| Delivery | Outgoing operation IDs, destinations, payloads, attempt status, external receipts when available, and unresolved delivery uncertainty. |

Persistent application state is the default for these interfaces. The brain should not have to remember to issue a separate save command for each state, memory, conversation, or schedule update. A successful standalone write or outer grouped commit means it has committed; individual calls inside an explicit group only stage changes. Temporary locals, caches, connections, and rendering interpolation are explicitly transient; any information needed to continue an activity belongs in durable state.

Store snapshots by value, not mutable references that can silently change an already-recorded experience. Live runtime objects are not database records merely because ordinary data can represent some of their properties.

Context and decision records follow retention rules too. Keep source content or immutable revision references sufficient for reconstruction while a record is retained; an ID pointing to an overwritten value is insufficient. If deletion removes that evidence, record that the context can no longer be reconstructed.

### Save consistently during operation

Persistence runs throughout Life's operation, not only at shutdown. Commit an incoming event before acknowledging durable receipt or advancing its connector cursor. Persist an accepted decision before execution. Commit local state changes, schedule/job transitions, and completed local operations with the records needed to explain them. A persistence failure must surface as a failed operation and stop dependent work from proceeding as though the write succeeded.

For the local world, commit an authoritative logical update together with the corresponding activity progress and outcome. Position, inventory, object changes, and job progress must restore from a consistent committed point. The renderer can interpolate between committed positions; animation frames are not recovery state. Rebuilding state from a journal applies recorded changes, never re-executes the Gene programs that caused them.

Use atomic commits for related local records and publish complete checkpoints with an explicit committed revision. Preserve the preceding valid checkpoint until its replacement is durable. A periodic snapshot can bound journal replay, but does not replace committing acknowledged operations. Schema or memory migrations preserve a recoverable previous representation until the new version is validated and selected.

### One explicit grouped-update API

The proposed `store.commit(callback)` operation runs an ordinary Gene callback with a short-lived transaction handle, `tx`. Participating local APIs accept `^tx tx`: state and memory writes, job preparation, schedule or routine registration, and local activity updates can therefore use the same durable commit. Section 7's walking example groups job preparation with the brain-defined `activity` record.

Atomicity covers changes staged through participating transaction APIs. Aborting a group does not reverse arbitrary mutations to captured or other transient Gene objects. Stored records and staged values must not expose mutable aliases that bypass those APIs; reads and writes use value snapshots.

The initial contract is small:

- Outside an explicit group, an ordinary persistent operation commits before returning success. Separate calls can leave a recoverable partial result if the process stops between them.
- With `tx`, an operation validates and stages its changes. Reads through that handle use one consistent view plus staged writes. Prepared job and schedule IDs can be referenced by other records in the same group, but are not yet published.
- The callback performs bounded synchronous computation and participating local operations. It cannot await, invoke the model, perform external I/O, or start work immediately. Application APIs reject nonparticipating writes and external effects inside the callback before performing them, including calls through helpers that fail to forward `tx`; such calls cannot create independent commits. Initially, nested groups and reuse of the handle after the callback are errors.
- After the callback returns normally, the host validates affected revisions and commits all staged changes together. An error, revision conflict, or cancellation before commit aborts the group and publishes none of its work. The callback's result is returned to the caller only after a successful commit; the host does not automatically rerun the callback on conflict.
- Job, schedule, and callback dispatch follows durable publication. An aborted group never runs its staged work. If the process exits after commit but before dispatch, recovery finds the committed eligible records and continues from them. If commit completed before its response was observed, retained execution/commit references reveal that outcome without replaying the callback.

For example, a stop between staging the walking job and staging `activity` leaves neither change committed. A stop after commit leaves both, even if the job has not begun. Choosing two standalone calls instead can leave a durable job without that cognitive link; recovery exposes the actual job and repairs the missing link rather than starting another walk.

Entering sleep uses this same group to publish its mode, clock checkpoint, activity reference, and routine registration. A world movement step groups its authoritative position with the job checkpoint and outcome. Recording an outgoing delivery request may also be local, but actual delivery happens after commit and retains the reconciliation rules below. No group rolls back an earlier external effect, and the surrounding generated program is still not automatically a transaction.

### Clean stop and restart

A clean stop stops new deliberation and dispatch, settles or interrupts current execution at application checkpoints, freezes the local simulation, commits received events and outgoing statuses, and saves the final consistent state. Report shutdown complete only after those writes succeed. Cancelling an execution handle for shutdown must not mark its intention abandoned or discard its continuation data.

Restart proceeds in this order:

1. Open the existing Life store with exclusive writer ownership and validate its identity, schema, and required revisions. Missing or incompatible state is a visible recovery failure; creating a fresh Life requires an explicit choice.
2. Restore the latest complete checkpoint and subsequent committed records, including memory, working state, local world, conversations, schedules, and job progress.
3. Recreate bindings and routine registrations from the selected definition, preserving registration IDs and dispatch progress rather than registering duplicates. Reconnect adapters using retained identities and cursors. Reconcile external deliveries and activity status while new foreground actions remain stopped.
4. Emit a restart observation identifying the recovery point, elapsed downtime, completed work, interrupted work, and unresolved outcomes. Build fresh context from the restored state before new deliberation.
5. Continue supported activities from their saved progress, expose other interrupted work for reconsideration, and dispatch due work under its cancellation and missed-run rules. If Life was explicitly paused, retain that mode until resumed; a normal stop of a running Life can restart into running mode.

The restored local world and conversation history must be inspectable before a model call. The brain interprets restored evidence; it does not invent missing location, state, or history from a summary. A model request that was in flight can be requested again using fresh context and its retained cycle references. An accepted program that had begun execution is reconciled before any further effects.

Continuation uses application-level data and activity checkpoints. It does not require restoring arbitrary Gene stacks, closure environments, sockets, task handles, or provider-side model sessions. Recreating those transient objects must preserve the Life's durable identity and application state.

### Location, world time, and downtime

For the first local world, simulation time pauses while the process is stopped. Restore the saved location, orientation, inventory, and environment state before advancing the next tick. Wall-clock schedules still account for elapsed downtime through their missed-run policy. Any later policy for simulating offline growth or movement must be explicit and tested; elapsed wall time does not silently move Life elsewhere.

An independently running external world owns its current state. Reconnect the same entity, restore the last known state, then reconcile it with the environment's authoritative state. Record changes that occurred while Life was offline. Do not respawn a new avatar at a default location or overwrite an external world's newer state with an old local snapshot.

### Unexpected exits and uncertain effects

A crash recovers the latest committed state even if no shutdown hook ran. Committed memories, conversation messages, state changes, and local world updates remain present. Uncommitted work may be absent; interrupted operations are reconciled against their durable attempt records. Tests must cover this path separately from a graceful restart.

A generated program is not automatically a transaction. If it sends a message and later fails, the message may already have been sent. Record each outgoing operation with a stable identity, destination, and payload before attempting delivery, and retain its receipt or uncertainty afterward. Adapters use supported external deduplication or reconciliation features. If delivery cannot be reconciled, expose that uncertainty instead of sending again automatically. Local transactional effects and their outcome records can commit together; external systems may require reconciliation.

Recovery preserves partial progress and continues the remaining activity. It does not replay an entire decision or completed action merely to regenerate lost transient execution. Only one body may own the writable Life store; starting a second writer must fail visibly. Running two copies is an explicit branch experiment with distinct identities and external adapter ownership.

The required result is application continuity: the same Life remembers its experience, occupies its restored place, can inspect and continue its conversations, and retains what it was doing across process restarts.

## 11. Learning and evolving the body through code

A useful result of experience is a reusable program, not necessarily a new prompt paragraph.

The brain can define a helper inside one response and later store a version for reuse. For example:

```gene
(do
  (let definition
    (quote
      (fn [observations]
        (var ids [])
        (for observation in observations
          (if_yes (== observation/status "dry")
            (ids .push observation/id)))
        ids)))
  (let revision (code .save "garden/dry_items" definition))
  (let dry_items (code .load revision))
  (let sample [{^id "plant-a" ^status "dry"}
               {^id "plant-b" ^status "wet"}])
  (if (== (dry_items sample) ["plant-a"])
    (state .put "garden/dry_items_revision" revision)
    (memory .remember {^kind "experiment" ^text "Candidate helper failed its example."})))
```

For this illustrative API, `save` stores the quoted program and returns an immutable revision reference. `load` evaluates that revision through ordinary Gene execution and returns its value; this example stores a function expression, so the value is callable. Saving a revision does not automatically replace any running behavior.

A saved program must not depend on an unrecorded local closure. Provide dependencies through named modules, documented execution bindings, or explicit serializable inputs. Bind ordinary library versions consistently for reproducible experiments.

The useful cycle is:

```text
Try something → observe the result → create or revise code
→ exercise it → retain a selected version → use it again
```

One successful example is evidence, not proof of improvement. Keep the old version and the observations used to select a new one. Compare actual outcomes on relevant cases.

Memory retrieval, attention policies, internal body controllers, scheduled routines, and world behavior can all use this mechanism. There is no need for a separate plugin installation ritual for every new helper.

### From a helper to an ongoing body routine

An evolving body routine consists of ordinary versioned Gene code, its brain-defined persistent data, and any event or timer registrations that drive it. An energy model, habit, sleep controller, or perception filter uses these same pieces. Public methods are ordinary Gene functions or messages; event handlers use the documented callback boundary. The host has no special `energy` or `sleep` response type.

The brain can propose and select such changes through normal code. A small selection operation records compatible code, data roots, and registrations atomically. Invoke handlers through the existing loader and execution queue, with explicit inputs and bounded work. A handler that needs a long activity starts a supervised job. A handler that needs fresh deliberation requests a wake. Most body updates need neither.

### Example: inventing energy and sleep

Suppose Life notices that it keeps starting activities without pausing to consolidate experience. It can choose to introduce a rest model. This is the first demonstration of an evolving body controller after the basic continuity slice works; it is not a prerequisite for Life to operate. The model is optional, and its usefulness is an experimental question. One candidate might store this ordinary record:

```gene
{^energy 24
 ^capacity 100
 ^mode "awake"
 ^recovery_per_sim_minute 2
 ^wake_at_energy 70
 ^last_accounted_sim_ms 120000
 ^sleep_activity nil}
```

These names, units, and thresholds are invented by the brain. It also writes the ordinary Gene routines that interpret them. For example, a pure helper can calculate a candidate energy level:

```gene
(code .save "rest/recovered_energy"
  (quote
    (fn [energy capacity rate elapsed_minutes]
      (let recovered (+ energy (* rate elapsed_minutes)))
      (if (> recovered capacity) capacity recovered))))
```

The accompanying controller defines when this helper applies, validates its inputs, and connects the state to behavior:

1. Account for energy costs on selected activity outcomes. Low energy may make the attention policy favor rest or defer discretionary work.
2. Enter sleep by committing the sleeping mode, an activity reference, the current clock checkpoint, and the routine registration together. Re-entering the same sleep activity updates that registration rather than adding a second recovery timer.
3. While sleeping, use bounded handlers to account for the elapsed simulation time since `last_accounted_sim_ms`, ignoring timestamps at or before that checkpoint. Commit the updated energy and the new clock checkpoint together, so a repeated or out-of-order timer delivery cannot credit the same interval twice.
4. On crossing the selected wake threshold, atomically leave sleeping mode, finish the sleep activity, retire its registration, and retain one cognitive wake request. Model inference is unnecessary for each recovery interval.

The attention policy decides which ordinary observations justify interrupting sleep. Event receipt and persistence continue, and operator pause, stop, and recovery remain available independently of this policy. Sleeping is a modeled body activity, not a stopped host process.

Start this example on simulation time, matching the local world's downtime policy. If the process stops at energy 42 while sleeping, restart restores energy 42, the sleeping mode, the selected controller, and the same registration and clock checkpoint. Recovery continues when simulation resumes. A later wall-clock rest model must explicitly define bounded downtime accounting and commit its elapsed-time checkpoint with the energy update.

Energy gains behavioral meaning through the controller's effect on activity, attention, and rest. It is not a measurement of the model's biological fatigue or the host's remaining compute budget. The brain may revise the model, remove it, or change its values; record such changes as revisions or explicit state edits rather than reporting them as recovery caused by sleep. External resource limits and world outcomes retain their own authority.

### Select changes without losing continuity

Use the same progression for a memory redesign or a body controller:

1. Save a candidate revision with its input contracts, data interpretation, and migration code if needed.
2. Exercise it on copied data with a fake clock and recording adapters. Compare representative retrieval queries or behavior, including restart, duplicate events, and invalid inputs.
3. Use section 9's quiescent selection: settle or explicitly invalidate the affected decision, checkpoint affected activities, and stop affected handlers before migrating from the current committed revision. Atomically select compatible code, data roots, and registrations, then resume their dispatch. Defer selection if safe settlement or migration is unavailable; the initial implementation does not keep incompatible organizations running concurrently.
4. Observe outcomes and retain the preceding revision and selection evidence. New code must demonstrate useful behavior beyond its selection examples.

If a selected routine fails, suspend its dispatch and retain its current data and diagnostics. Other healthy body operations and durable event receipt continue. The host's small recovery context exposes the failed revision, raw records, and actual outcomes for a bounded repair decision even if ordinary attention or context construction is broken. It remains possible to inspect and repair the Life without depending on the failed routine.

Returning to earlier code requires compatible current data or a tested migration of that data. Do not restore an old whole-Life snapshot to undo a controller change: that would also erase later conversations, world progress, or delivery evidence. Reverting code does not reverse external effects. Recovery preserves those facts and either repairs the affected component or leaves it visibly suspended.

## 12. Conversations with several people

Life can participate in a direct conversation, a group channel, a forum thread, or a virtual room. These are environments observed through adapters, not reasons to create a new Life identity for every message.

Retain source, speaker, conversation, thread, event ID, and reply destination. Observation IDs and destination records must survive delayed work; do not reconstruct the destination later from whichever conversation was most recently active.

Conversation continuity includes the retained transcript, participant relationships, unresolved exchanges, pending replies, and delivery status. These survive restart with the same identities and ordering. Reconnect from durable connector cursors, deduplicate repeated deliveries, and retrieve missed messages where the transport supports it. Record a known history gap if the transport cannot recover messages received while Life was offline. The local test interface must durably retain accepted messages even while the brain is idle.

A communication adapter exposes ordinary Gene operations such as sending a message, retrieving an available thread, or observing new arrivals. The brain may read several observations, compute over them, and send one response—or no response—using the same program interface.

Deciding whether to participate is part of the experiment. Relevant considerations include whether Life was addressed, whether it has something useful to contribute, whether someone else already answered, and whether a delayed response is still timely.

Keep conversation and visibility tags on memories, decision notes, context snapshots, and summaries. Derived notes retain the visibility restrictions of their sources; summarizing several sources does not make the result public. Private conversations should not be flattened into a global public briefing. Start with a local multiuser test interface before adding a real channel or forum connector. Connectors should preserve external event identities so duplicate delivery does not become a second observation with a second reply.

The initial participant presents itself as Gene Life, an AI participant. There is no need to imitate a human account or maximize message volume to appear alive.

## 13. A small 3D world

A 3D world is a natural environment for the experiment, not just a visual status indicator. Start with a room, workshop, or garden containing a few objects and meaningful interactions.

The world should make actions observable: Life moves toward an object, examines it, changes something, responds to a visitor, or returns to an unfinished activity.

The brain selects goals and writes high-level Gene behavior. The body and world code handle movement, animation, pathfinding, collision, and simulation steps. Life can evolve its movement routines, rest behavior, and other internal control logic through saved Gene code; the world's authoritative interaction rules remain explicit environment contracts. Do not ask the model to produce a decision for each frame.

```text
Brain: “Inspect the garden and take care of dry plants.”
    ↓ executable Gene behavior
Body: movement and interaction jobs
    ↓ actual simulation results
World: changed plants, positions, observations
    ↓ selected experience
Brain: reconsider, remember, or continue
```

Start with structured observations instead of requiring visual perception. Make the perception model explicit: local observations, remembered locations, and optional debug inspection are different sources. A browser renderer can display the authoritative world state while Life receives only its configured observation view.

Keep simulation usable without rendering for repeatable tests. The renderer is a client of the world, not the owner of Life's memory or decision loop. Closing the browser need not stop the body.

The world's authoritative application state is persistent from its first implementation. A body restart restores Life at the saved location with the same orientation, possessions, surrounding objects, and activity progress before either the renderer or a new decision treats the world as ready. Movement can continue toward the retained destination from that restored position. The initial local world's downtime policy pauses simulation as specified in section 10.

Visitors in the world and participants in an external conversation can address the same Life. It may continue a physical activity while waiting for a conversation reply.

Do not require a large world, many agents, a complete game engine, or a training pipeline before this interaction works. A convincing small experiment is preferable to an impressive environment containing a shallow scripted character.

## 14. Small initial implementation

A possible package layout is:

```text
life/
  main.gene              startup, operator controls, shutdown
  persistence.gene       durable commits, checkpoints, restoration and recovery
  runtime.gene           events, decision records, execution queue and results
  brain.gene             model adapter, response framing, context construction
  memory.gene            replaceable starter memory organization and retrieval
  scheduler.gene         wakeups and stored scheduled programs
  code.gene              saved revisions, loading, and atomic definition selection
  body/
    chat.gene            local conversation adapter
    world.gene           small simulation and action jobs
    routines.gene        starter routines; later revisions can be brain-authored
  client/                optional browser presentation
  tests/                 fake brain, fake clock, recording adapters
```

This is a suggested separation of responsibilities, not a required number of files. Combine modules while small. Use existing Gene libraries where they fit; avoid introducing a new plugin framework, scheduler, or persistence engine merely to follow the diagram.

### First vertical slice

One Life starts with its seed disposition in a small environment, receives a first-start observation, obtains a decision note and Gene program from a replaceable brain, executes the program, records the outcome alongside the note, and chooses a later wakeup. A program can also choose silence. This slice includes durable storage and restart: stop the process, open the same Life, and verify that its identity, memory, working state, location, conversation history, and scheduled work return before adding more environments.

Use a fake brain returning known notes and programs before connecting a model. This makes the loop and failure handling testable independently of response quality.

Keep this implementation to one local chat, a tiny logical world, one resumable activity (`start_walk`), one durable store, and the fake brain. Make grouped publication and the activity's checkpoint/recovery contract concrete along this path. A 3D presentation and the evolving sleep controller follow the working stop/restart demonstration.

Make the first local world and chat adapter small but persistent. Their test fixtures should include a changed location, a remembered preference, a saved state value, an unfinished activity, a conversation with a pending reply, and a future wakeup. A fresh process must recover these without invoking the brain to reconstruct them. Add forced-exit recovery alongside the clean-stop test; persistence is a completion requirement for this slice.

First verify the selected Gene execution path with functions, loops, saved code loading, repeated scope creation/disposal, and cancellation. Exercise a runaway foreground loop and a waiting adapter while event receipt and operator controls remain active; merely configuring a budget does not demonstrate responsiveness. The current [development status](../development.md#status) identifies eval-defined type/method and closure-retention limitations. Establish which constructs this prototype supports before relying on repeated generated execution in a long-lived process.

### Extend continuity and social behavior

Extend the proven restart path to longer histories, several speakers in one local conversation, delayed replies, and richer activity checkpoints. Then connect one real communication adapter with durable cursors and delivery reconciliation. Each new kind of state or adapter must define how it is saved, restored, and reconciled before becoming part of normal Life behavior.

### Embodiment and evolution

Add the small 3D presentation and a few meaningful world activities. Demonstrate saving and reusing a Gene helper, then changing memory organization without a host schema change. Introduce the energy/sleep controller through ordinary code and data selection, stop during sleep, and restore the selected controller and its progress. Exercise a failed controller revision and recovery that preserves later memories and conversations. These changes should use the same brain-response format and storage primitives.

The first evolution mechanism needs only saved code, named data roots, durable event/timer registrations, and atomic revision selection. Use a small fake-clock experiment before adding further internal variables, competing controllers, or a general component framework.

The world can be the first environment rather than a late addition. The important sequencing rule is to finish one complete loop before broadening every subsystem.

### First continuity demonstration

Use one small garden scenario across these milestones. A visitor expresses a preference for shade; Life remembers it, chooses a garden activity, and walks partway toward its destination carrying an object. Stop and restart the body. Before a model call, verify the same location, held object, changed world objects, conversation history, preference, activity checkpoint, and pending wakeup. Then let Life continue from that position using retained notes and actual outcomes. Repeat with an unexpected process exit. Change a relevant circumstance—such as the visitor withdrawing the request—so Life must revise or abandon the plan and cancel related scheduled work. Inspect the notes, code, and world changes together to see whether its continuity is supported by experience.

## 15. What to demonstrate and measure

The first implementation should demonstrate these behaviors:

| Scenario | Expected behavior |
| --- | --- |
| Life starts without a human message | Use its recorded starting disposition and first-start observation; allow exploration, scheduling, or inactivity. |
| Brain returns a text note and a complete program | Retain both with the context reference; execute only the program. |
| Response has missing, duplicated, or incomplete blocks | Reject the response without effects; keep diagnostics and bound correction attempts. |
| Brain returns a program with computation, branches, and several API calls | Execute as ordinary Gene code, not as a list of tool commands. |
| Brain returns a note and `nil` without sending | Valid silence; record consideration without repeatedly waking on the same event. |
| A note describes an action whose program later fails | Retrieve the note with its failure or partial outcome; do not report the intention as success. |
| Another message arrives during inference | Retain it; do not lose it when the current cycle completes. |
| A considered request leaves a commitment unfinished | Keep the commitment visible independently of the event's consideration status. |
| Program requests a future wakeup | Body remains responsive; later deliberation uses fresh context. |
| Known code is scheduled with explicit data | Dispatch once due under its lateness policy, without requiring a model call first. |
| Scheduled work becomes due during inference or execution | Use the shared foreground queue; recheck relevant changes before the brain-produced program acts. |
| An intention is cancelled before its delayed action runs | Invalidate owned queued work and request cancellation of active owned jobs. |
| A world precondition changes after the context was built | Check at the adapter operation and report the actual result or precondition failure. |
| Long world action is started | Return a job ID and later report the actual outcome. |
| Process exits while grouping a walking job and its related state update | Publish neither before the grouped commit; recover both after commit, with dispatch beginning only after durable publication. |
| Two standalone calls leave a job committed without its cognitive state link | Expose the partial result and repair the link without creating a duplicate job. |
| A helper inside `store.commit` writes without forwarding `tx`, then the outer group fails | Reject the helper's write before any independent commit; durable records remain unchanged. |
| A started arbitrary job has no continuation contract | Preserve partial outcomes and mark interrupted; do not infer resumability from its durable source. |
| A program fails after a completed action | Preserve partial progress; do not replay the whole program automatically. |
| Process stops cleanly and restarts | Restore the same identity, memory, working state, location, inventory, local world, conversations, commitments, and schedules before new deliberation. |
| Process exits without a shutdown hook | Recover all committed records and a consistent world/activity checkpoint; identify and reconcile interrupted effects. |
| Life stops partway through a walk | Restore its committed position and destination, then continue the remaining movement under the same job ID. |
| Restart occurs during an ongoing conversation | Restore the retained transcript, speakers, thread, pending reply, connector cursor, and delivery status without duplicate accepted messages. |
| A sent message has no recorded receipt when the process exits | Reconcile by its stable operation ID where supported; preserve uncertainty instead of blindly resending. |
| Local simulation is offline for an hour | Restore saved simulation time and location; apply elapsed wall time only through explicit schedule policies. |
| A persistent write fails | Report failure, preserve the previous committed state, and stop dependent work; do not claim a successful save or clean shutdown. |
| Required saved state or a schema revision cannot be restored | Report a recovery failure without replacing the existing Life with a fresh one. |
| A second body opens the same Life for writing | Reject the second writer; preserve one authoritative continuation. |
| A delayed message is sent after another conversation becomes active | Use its saved destination, not the latest conversation. |
| A helper, memory implementation, or context policy changes | Select a version explicitly; retain cycle revision references and comparison evidence. |
| The brain replaces the starter memory/state schema | Preserve retained meanings and operational references using selected migration/access code; require no new host cognitive fields. |
| The brain adds an internal variable and body controller | Store the new data and register ordinary Gene handlers without changing the host's data model or dispatcher. |
| Life sleeps while the model is unavailable | Run its selected rest controller, preserve incoming observations, and request a wake only when its policy calls for one. |
| The process restarts during sleep | Restore the chosen code revision, energy, mode, clock checkpoint, and one registration; follow the selected downtime policy. |
| A sleep timer is delivered twice | Account for the elapsed interval once and retain one wake request on the transition out of sleep. |
| A code/data migration is interrupted | Restore either the complete old selection or the complete new selection, with compatible callbacks and data. |
| An old-layout memory operation is scheduled, then the organization changes before it is due | Migrate it, explicitly retain compatibility, invalidate it with its owner and reason, or defer selection; never dispatch it against incompatible data. |
| A model response arrives after organization replacement was requested | Finish the still-valid cycle under the old organization before selection, or retain an invalidated response without effects and request fresh deliberation; never execute against incompatible data. |
| A selected body routine fails after new conversations arrive | Suspend that routine, preserve current data and conversations, and repair through the host recovery path. |
| Nothing relevant has happened | Heartbeats continue without needless model calls. |
| Operator pauses or stops Life | Halt new inference and dispatch, checkpoint activities, settle execution, and durably retain progress and observations before reporting completion. |
| Operator resumes after scheduled work became due | Build fresh context; apply cancellation, lateness, and missed-run rules without replaying cancelled execution. |

For behavioral evaluation, look for continuity of interests, accurate use of experience, useful initiative, appropriate silence, response to changed circumstances, and understandable recovery. Also record model cost, latency, repeated failures, and retained work.

Two focused failure tests should establish the operation boundaries early. First, inject process exit after staging the walking job but before its related state write, immediately before commit, and immediately after commit but before dispatch. Second, use a controllable fake brain to return an old response after a cognitive replacement request, including after explicit invalidation and selection. Observe durable records and actual dispatches, not only returned status values. The replacement case belongs with the first organization-change implementation and does not require the energy model.

### Test the behavioral hypothesis

The scenarios above test operational correctness. Separately compare behavior in repeatable environments using the same model, starting disposition, initial world state, external event script, and comparable inference budgets. Repeat runs so one fortunate response does not decide the result. Record model configuration and selected code/policy revisions with each run.

| Comparison | Question |
| --- | --- |
| Cognitive-memory retrieval enabled versus withheld from the brain, with durable state and recovery preserved in both | Does access to remembered experience improve preference recall and follow-through across interruptions and restarts? |
| Decision notes carried into later context versus retained only for inspection, with the same other memory inputs | Does the expressed state of mind improve continuity and revision of plans? |
| Fixed procedures versus explicitly selected learned procedures | Does saved code improve later outcomes on cases beyond the examples used to select it? |
| A selected energy/rest controller versus the same Life without that controller, under the same host budgets | Does this internal model improve follow-through, pacing, or useful reflection enough to justify its cost and delays? |

Measure accurate use of preferences, completed or explicitly revised commitments, adaptation to changed conditions, unnecessary actions, and unsupported claims of success. Include note generation and retrieval in token costs. Compare notes with code and outcomes; fluent self-description alone is not evidence of coherent behavior.

Do not define success as producing more messages, more reflections, or more self-authored code. The experiment should reveal when those behaviors help and when they merely create activity.

## 16. Leave room to discover the mind

The following remain experimental choices rather than prerequisites:

- Whether attention uses numeric priorities, qualitative interests, or a mixture.
- Whether memory is mostly episodes, summaries, a graph, indexes, executable procedures, or several cooperating forms.
- Whether a consistent personality emerges from retained state or benefits from an explicit disposition model.
- Which internal body models, such as energy and sleep, improve behavior and which can be revised or discarded.
- Whether one model, several deliberation strategies, or parallel decision candidates improve behavior.
- How much of the environment Life should observe and what it should have to discover.

Keep detailed capability design, a universal plugin architecture, general VM snapshots, multi-process replicas, and unrestricted live rewriting of the stable host outside the initial scope. Brain-defined memory/state structures and versioned body routines are within scope. Durable application state, tested stop/restart continuity, operator control, and execution limits remain requirements for the local experiment; broader deployment is separate work.

## 17. Core statement

> Gene Life is an independent experiment in persistent, self-directed virtual behavior. A small stable host preserves continuity and runs an evolving body of Gene code and data. A replaceable AI brain decides what matters and returns a brief decision note alongside an executable program. The brain defines its memory and state structures and can introduce internal body models, routines, and learned behavior that operate between thoughts. Retained notes stay linked to actual execution outcomes. Stopping and restarting the process restores the selected code and the same Life's memories, working state, location, possessions, conversations, commitments, and activity progress so it can continue from its saved point. Memory, attention, context, and body behavior evolve together on that persistent foundation.

**One persistent individual. A replaceable brain. An active body. Gene code between them.**
