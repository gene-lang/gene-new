# Gene Life

**Status:** Independent experimental design proposal.  
**Date:** 2026-09-19.  
**Focus:** A persistent virtual being with an AI brain, a long-running body, and behavior expressed through Gene code.

> Gene Life observes, remembers, chooses, and acts over time. Its brain communicates with its body by writing Gene programs—not by selecting from a fixed tool-call protocol.

This document records the direction agreed in the Gene Life discussion and proposes a small starting architecture. The APIs below are illustrative application interfaces, not claims about an existing Gene Life implementation or new Gene language features. They should change as the experiment teaches us what is useful.

## 1. The experiment

Gene Life is a virtual being with an AI brain. Its body is a long-running process connected to environments: conversations, a virtual world, and other sources of observations and actions.

The body continues to operate when the brain is not thinking. It receives messages, advances ongoing activities, maintains schedules, stores information, and delivers outcomes. The brain is invoked when deliberation is useful; it decides what to pay attention to, what to do, what to postpone, and whether to communicate.

Interaction does not have to be real time. Receiving a prompt does not require producing a reply immediately—or producing any reply. Life can wait for more information, work on something else, return to an earlier discussion, or initiate an activity without a new human prompt.

The core experiment is whether continuity of memory, interests, decisions, and interaction produces coherent behavior over time. An avatar is one expression of that behavior, not the entire experiment. “Life” describes the application concept, not a claim that the system is conscious.

### Working principles

- **Code is the brain–body interface.** A response can contain computation, control flow, function definitions, API calls, and the construction of future behavior.
- **The brain chooses priorities.** The runtime supports those choices without hard-coding a universal priority formula or forcing every activity into a user-task workflow.
- **Memory and state can evolve.** Start with simple representations; allow the organization, retrieval methods, and supporting Gene code to change.
- **The body stays alive between thoughts.** World simulation, message receipt, timers, and active jobs do not require continuous model inference.
- **Keep the core small.** Implement one individual with useful observable behavior before building a framework for every possible kind of agent.

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
                         Gene program
                               v
                       Gene execution
                               |
                memory changes, schedules, actions
                               |
                      actual outcomes
                               +------> Body / control
```

### Body and control system

The body maintains the connection to its environments and keeps the experiment operational. It receives and records events, runs timers, tracks work, executes generated Gene programs, and reports actual results.

It also handles basic process concerns: startup, shutdown, pause, cancellation, errors, and persistence. These do not need an elaborate framework. They do need to keep working when a model call fails or a generated program makes a mistake.

Attention selection, memory retrieval, and scheduling policies can themselves be ordinary replaceable Gene code. They need not become permanent host-language rules.

### Brain

The brain interprets the selected experience and writes the next program. Its implementation is replaceable: a remote model, local model, or experimental combination can satisfy the same interface.

Conceptually:

```text
brain.think(context) -> Gene source
```

This may be an asynchronous request. Model connection details belong in the brain adapter, not in every part of Life.

The brain's model weights are not the whole being. Identity, remembered experience, interests, ongoing intentions, and learned procedures are retained separately. Changing the model is therefore an explicit experimental change, not necessarily the creation of a new individual.

### Environment

The environment owns its actual state. If Life tries to move, build, send a message, or read an object, the environment or its adapter reports what happened.

A generated sentence saying an action succeeded is not evidence that the action occurred. Record intentions, attempted operations, and observed outcomes as distinct information.

## 4. Brain responses are programs

### 4.1 No mandatory tool-call envelope

The brain returns one complete Gene program. A convenient initial convention is one `(do ...)` form:

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

### 4.2 Results are not automatically messages

The program's return value is an execution result recorded by the body. It is not automatically sent to the person or channel that supplied the latest observation.

Communication is explicit:

```gene
(body/chat .send context/focus/reply_to
  "I have checked the garden. The dry plants are now watered.")
```

A program returning `nil` is a valid no-action decision. A program that updates memory without sending anything is also valid. A program that schedules work for later does not need to manufacture an immediate conversational reply.

Transport acknowledgments, such as acknowledging receipt of an incoming event, remain body operations and are independent of the brain's eventual response.

### 4.3 Complete source before execution

Keep the transport convention simple: accept plain Gene source, or strip one enclosing Gene code fence if the model adapter supports that convention. Parse the complete program before executing it. Do not guess which fragments of a mixed prose response were intended as executable code.

Streaming model output may be displayed as a draft, but partial output is not executed. Parse or compile errors become observations for a later correction attempt. Limit repeated correction attempts rather than entering an endless automatic repair loop.

Text retrieved from a conversation, memory record, or web page remains input data. It is not another executable brain response merely because it contains Gene-looking text.

### 4.4 Normal execution, not a second interpreter

Use Gene's normal reader, compiler, and execution facilities for the supported program boundary. Do not implement a separate miniature language that recognizes a handful of approved action expressions.

Definitions and control flow inside a response follow the selected Gene execution path. Persistent module definitions and imports use the normal module loader; this proposal does not assume every top-level declaration or source import is legal inside an `eval` body.

Local variables and function definitions belong to that execution. To reuse behavior later, save it explicitly as code or retain it through a documented in-process registration. Accidental survival of an evaluator environment is not the persistence model.

## 5. Context supplied to the brain and program

The brain receives a bounded view of current experience, not necessarily the whole history or the entire world database.

A starting context can include:

```gene
{^life_id "life-001"
 ^cycle_id "cycle-104"
 ^revision 38
 ^now "2026-09-19T18:30:00Z"
 ^focus {^event_id "event-882"
         ^reply_to {^adapter "chat" ^conversation "workshop" ^thread "thread-7"}}
 ^observations []
 ^current_interests []
 ^pending_work []
 ^recent_results []
 ^memory_excerpt []}
```

These fields illustrate the needed information; they are not a permanent cognitive schema. An autonomous cycle may have no conversation focus or reply destination. Code must check for that before using it.

The context builder also supplies compact documentation of the available Gene APIs and relevant reusable code. Large reference material can be discovered through an ordinary documentation function instead of being copied into every prompt.

At execution, the program receives the same context snapshot and ordinary application objects:

| Binding | Initial responsibility |
| --- | --- |
| `context` | Snapshot used for this decision, including selected event identities. |
| `life` | Identity and public runtime operations, such as starting an asynchronous job. |
| `state` | Explicitly retained working state, initially a simple key/value interface. |
| `memory` | Replaceable remembering and retrieval behavior. |
| `body` | Named environment adapters, such as `body/chat` and `body/world`. |
| `scheduler` | Future wakeups, scheduled programs, and recurring work. |
| `code` | Stored Gene source and revision references for reusable behavior. |

These bindings are a suggested starting vocabulary, not a required object hierarchy. A small implementation can combine them or expose ordinary imported functions instead.

The remote model receives descriptions and data, not live process objects. The Gene program receives the actual runtime bindings when the body executes it.

## 6. The attention and execution loop

Start with one active brain decision and one foreground program execution per Life. The body can still receive events and run asynchronous jobs while waiting for the model.

```text
1. Receive and retain observations.
2. Decide whether a brain invocation is needed.
3. Select observations, working state, and relevant memory.
4. Request a complete Gene program from the brain.
5. Check whether the decision's basis is still usable.
6. Parse, compile, and execute the program.
7. Record its return value, failures, and actual action outcomes.
8. Preserve new events and schedule the next useful reconsideration.
```

The single foreground decision is a starting simplification, not a prohibition on future parallel thinking experiments. Background jobs return their results as events rather than directly racing to rewrite the agenda.

### New events during thought

Incoming events remain queued while the brain is working. Each cycle records which observations it considered; completing that cycle must not accidentally mark later arrivals as handled.

Do not reject every response merely because a newer message arrived. Recheck changes that matter: operator stop, a cancelled intention, a replaced code dependency, a changed conversation target, or an environmental precondition used by the proposed action.

A stale decision can be deferred or returned to the brain with the new observation. Do not automatically replay a program that may already have performed effects.

### Priority is a policy, not a fixed equation

An initial attention policy can batch nearby messages, wake on direct interaction, and revisit explicit intentions when due. The brain may later replace that policy with code using different considerations.

Importance, curiosity, timeliness, relationships, novelty, effort, and unfinished work are possible inputs. They need not all exist as numeric scores. Do not hard-code that chat always outranks exploration, or that every remembered interest must become a formal task.

A previously accepted commitment should remain visible until completed, revised, or abandoned explicitly. Flexibility does not require losing track of what Life already said it would do.

### Preserve responsiveness

A generated program should not freeze event receipt or the operator's stop/pause controls. Use the existing execution model's supported interruption mechanism, with a simple per-execution work limit. Long-running activity belongs in supervised jobs, not an infinite foreground loop.

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

The runtime records that the program returned. It does not automatically wake the brain again solely because a memory or state record changed.

### Long-running activity

A proposed `start_job` operation accepts quoted Gene code and explicit input:

```gene
(do
  (let job
    (life .start_job "walk-to-garden"
      (quote
        (body/world .walk_to input/destination))
      {^destination "garden"}))
  (state .put "activity" {^kind "walking" ^job_id job/id})
  nil)
```

`start_job` returns promptly with an ID. Completion, cancellation, or failure creates an observation tied to that ID. The job's own program may use supported asynchronous Gene APIs; it need not request another model call for each movement step.

The job is tracked and can be cancelled. Returning a task or lazy stream from arbitrary foreground code does not silently make it a durable job. The selected API must define who drives it and how completion is observed.

A serializable job description also does not make its effects replay-safe after a crash. Initially, interrupted jobs are reported as interrupted and reconsidered rather than automatically repeated.

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
             ^text "The scheduled workshop session is starting."})
```

This schedules a specific program rather than asking the model to decide the same thing again. It is appropriate when the desired action is already settled. When the wording or action depends on future circumstances, schedule a wake instead.

Scheduled code runs in a fresh execution scope with the saved bindings available as `input`. It does not implicitly capture the current stack or local variables. Store its source/revision and explicit data bindings; load ordinary dependencies through the normal code-loading path.

Both scheduling operations return IDs so code can inspect, update, or cancel them. Rescheduling the same conceptual activity should replace a known schedule rather than accidentally create unbounded duplicates.

### Recurring work

Cron-like scheduling is another library operation:

```gene
(scheduler .cron "0 9 * * *" "America/New_York"
  ^code (quote
    (scheduler .wake_after 0 "Review today's interests and commitments"))
  ^bindings {})
```

The exact cron library and method names remain implementation choices. The API must state its timezone and missed-run behavior. A useful first policy is to coalesce missed cognitive wakeups into one review, not replay every missed interval after downtime.

Give generated internal events a cause ID. Logs, memory writes, and reflection records must not create an automatic think–write–think feedback loop. New external information, explicit wake requests, and meaningful job outcomes are the initial wake sources.

## 9. Memory and state are flexible, but not indistinguishable

Life needs several kinds of information, without necessarily requiring separate stores or rigid record classes.

**Experience** is what it observed or attempted. **Belief** is an interpretation that may be wrong. **Working state** is what it is currently considering or doing. **Procedural memory** is reusable Gene code. **Operational records** say what the body actually received, executed, scheduled, or delivered.

An initial implementation can use one database plus a small set of ordinary Gene records. Do not require a vector database, a knowledge graph, or a universal ontology before the first experiment works.

For example:

```gene
(memory .remember
  {^kind "observation"
   ^text "A visitor said they prefer a shaded garden."
   ^source_event "event-882"
   ^conversation "workshop"
   ^subject "visitor-14"})
```

Later, Life might introduce a topic index, split observations from interpretations, summarize older experience, or write a specialized retrieval function. These are changes to data organization and ordinary Gene code, not changes to the brain-response protocol.

### Start with a small memory interface

A default memory module can offer `remember` and `recall`. It should be possible to replace its implementation, add specialized queries, or bypass a high-level helper for a documented lower-level data operation.

Record enough provenance to distinguish “the user said this,” “the world reported this,” and “the brain inferred this.” Do not replace an action result with a model-authored claim of success.

Memory is selective rather than an obligation to retain everything forever. Deletion and retention choices should apply to derived summaries and indexes as well as original records.

### Evolving organization

A practical sequence is to retain the old representation, build or migrate a candidate representation, compare retrieval on a few representative questions, and switch at a cycle boundary. Keep the migration and selected implementation revision explicit.

The cognitive organization may evolve aggressively. Keep a minimal operational record format readable by the body so an experiment with memory does not also erase its pending events, schedules, or last known execution outcomes.

Do not make unrestricted hot replacement of the body's persistence machinery a prerequisite for memory evolution.

## 10. Persistence and continuity

Code, memory, and serializable state may physically co-live in one database. That fits the experiment, but database-backed module loading is not a prerequisite for the first prototype; stored Gene source can initially be loaded through an ordinary file/module workflow.

Persist the information needed to reconstruct useful continuity:

```text
Life identity and selected configuration
received observations and processing references
memory and selected working-state snapshots
known intentions and future wakeups
saved programs and their revision references
job descriptions and recorded outcomes
outgoing messages and delivery status
```

Store snapshots by value, not mutable references that can silently change an already-recorded experience. Live runtime objects are not database records merely because ordinary data can represent some of their properties.

### What restart means initially

Restart creates a fresh body process, reloads explicitly stored information, reconnects its adapters, and emits a restart observation. The brain can decide how to continue from that evidence.

It does **not** restore an arbitrary paused Gene stack, a live model request, socket, task handle, or closure environment. Complete application-state capture and transparent execution resumption remain separate, more complex work.

The initial restart rule is deliberately modest: pending observations remain available; due wakeups follow the configured missed-run policy; interrupted executions are visible; uncertain external effects are not blindly retried.

For one logical Life, start with one active body process writing its operational state. Running two copies from the same state is an explicit branch experiment, not an implicit recovery technique.

### Partial progress and uncertain effects

A generated program is not automatically a transaction. If it sends a message and later fails, the message may already have been sent. Record completed operations before asking the brain to repair the remainder.

An outgoing operation should carry a stable local identity and destination. Adapters can use supported external deduplication or reconciliation features. If a crash leaves delivery uncertain and it cannot be reconciled, expose that uncertainty instead of sending again automatically.

These small continuity rules are enough to begin the experiment without claiming general exactly-once effects or universal state resumption.

## 11. Learning and changing behavior through code

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

Memory retrieval, attention policies, scheduled routines, and world behavior can all use this mechanism. There is no need for a separate plugin installation ritual for every new helper.

## 12. Conversations with several people

Life can participate in a direct conversation, a group channel, a forum thread, or a virtual room. These are environments observed through adapters, not reasons to create a new Life identity for every message.

Retain source, speaker, conversation, thread, event ID, and reply destination. Observation IDs and destination records must survive delayed work; do not reconstruct the destination later from whichever conversation was most recently active.

A communication adapter exposes ordinary Gene operations such as sending a message, retrieving an available thread, or observing new arrivals. The brain may read several observations, compute over them, and send one response—or no response—using the same program interface.

Deciding whether to participate is part of the experiment. Relevant considerations include whether Life was addressed, whether it has something useful to contribute, whether someone else already answered, and whether a delayed response is still timely.

Keep conversation and visibility tags on memories and summaries. Private conversations should not be flattened into a global public briefing. Start with a local multiuser test interface before adding a real channel or forum connector. Connectors should preserve external event identities so duplicate delivery does not become a second observation with a second reply.

The initial participant presents itself as Gene Life, an AI participant. There is no need to imitate a human account or maximize message volume to appear alive.

## 13. A small 3D world

A 3D world is a natural environment for the experiment, not just a visual status indicator. Start with a room, workshop, or garden containing a few objects and meaningful interactions.

The world should make actions observable: Life moves toward an object, examines it, changes something, responds to a visitor, or returns to an unfinished activity.

The brain selects goals and writes high-level Gene behavior. The body and world code handle movement, animation, pathfinding, collision, and simulation steps. Do not ask the model to produce a decision for each frame.

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

Visitors in the world and participants in an external conversation can address the same Life. It may continue a physical activity while waiting for a conversation reply.

Do not require a large world, many agents, a complete game engine, or a training pipeline before this interaction works. A convincing small experiment is preferable to an impressive environment containing a shallow scripted character.

## 14. Small initial implementation

A possible package layout is:

```text
life/
  main.gene              startup, operator controls, shutdown
  runtime.gene           events, foreground cycles, execution results
  brain.gene             model adapter and context construction
  memory.gene            first storage/retrieval implementation
  scheduler.gene         wakeups and stored scheduled programs
  code.gene              saved source revisions and loading
  body/
    chat.gene            local conversation adapter
    world.gene           small simulation and action jobs
  client/                optional browser presentation
  tests/                 fake brain, fake clock, recording adapters
```

This is a suggested separation of responsibilities, not a required number of files. Combine modules while small. Use existing Gene libraries where they fit; avoid introducing a new plugin framework, scheduler, or persistence engine merely to follow the diagram.

### First vertical slice

One Life starts in a small environment, receives an observation, obtains a Gene program from a replaceable brain, executes it, records the outcome, and chooses a later wakeup. A program can also choose silence.

Use a fake brain returning known programs before connecting a model. This makes the loop and failure handling testable independently of response quality.

### Continuity and social behavior

Add explicit memory, saved working state, durable schedules, and restart observations. Support several speakers in one local conversation and preserve delayed reply destinations. Then connect one real communication adapter.

### Embodiment and evolution

Add the small 3D presentation and a few meaningful world activities. Demonstrate saving and reusing a Gene helper, then compare two memory or attention strategies without changing the brain-response format.

The world can be the first environment rather than a late addition. The important sequencing rule is to finish one complete loop before broadening every subsystem.

## 15. What to demonstrate and measure

The first implementation should demonstrate these behaviors:

| Scenario | Expected behavior |
| --- | --- |
| Brain returns a program with computation, branches, and several API calls | Execute as ordinary Gene code, not as a list of tool commands. |
| Brain returns `nil` without sending | Valid silence; no automatic user-facing reply. |
| Another message arrives during inference | Retain it; do not lose it when the current cycle completes. |
| Program requests a future wakeup | Body remains responsive; later deliberation uses fresh context. |
| Known code is scheduled with explicit data | Execute that program at the due time without requiring a model call first. |
| Long world action is started | Return a job ID and later report the actual outcome. |
| A program fails after a completed action | Preserve partial progress; do not replay the whole program automatically. |
| Process restarts | Restore explicit data and schedules; report interrupted work rather than claim a resumed stack. |
| A delayed message is sent after another conversation becomes active | Use its saved destination, not the latest conversation. |
| A helper or memory implementation changes | Select a version explicitly; retain enough evidence to compare the behavior. |
| Nothing relevant has happened | Heartbeats continue without needless model calls. |
| Operator pauses or stops Life | Stop new deliberation and settle or cancel owned work through the normal runtime path. |

For behavioral evaluation, look for continuity of interests, accurate use of experience, useful initiative, appropriate silence, response to changed circumstances, and understandable recovery. Also record model cost, latency, repeated failures, and retained work.

Do not define success as producing more messages, more reflections, or more self-authored code. The experiment should reveal when those behaviors help and when they merely create activity.

## 16. Leave room to discover the mind

The following remain experimental choices rather than prerequisites:

- Whether attention uses numeric priorities, qualitative interests, or a mixture.
- Whether memory is mostly episodes, summaries, a graph, indexes, executable procedures, or several cooperating forms.
- Whether a consistent personality emerges from retained state or benefits from an explicit disposition model.
- Whether one model, several deliberation strategies, or parallel decision candidates improve behavior.
- How much of the environment Life should observe and what it should have to discover.

Keep detailed capability design, a universal plugin architecture, general VM snapshots, multi-process replicas, and unrestricted live rewriting of the body outside the initial scope. Basic operator control and execution limits are enough to start a local experiment; broader deployment is separate work.

## 17. Core statement

> Gene Life is an independent experiment in persistent, self-directed virtual behavior. A long-running body receives observations, maintains ordinary operational state, and acts in conversations and a virtual world. A replaceable AI brain decides what matters and returns executable Gene programs. Those programs can compute, communicate, schedule future work, change memory, and develop reusable behavior. The organization of memory, attention, and skills is allowed to evolve. Continuity begins with explicitly stored code and data, not a promise to serialize an entire running mind.

**One persistent individual. A replaceable brain. An active body. Gene code between them.**
