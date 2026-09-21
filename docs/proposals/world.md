# Gene World: An Expandable Commons for Independent Lives

**Status:** Experimental design proposal, not an implementation report.  
**Date:** 2026-09-21.  
**Companion:** The latest reviewed `life.md` (uploaded as `life(2).md`, updated 2026-09-20).  
**Decision:** One authoritative world process, one separate process per Life, and a browser renderer. Use WebSocket for bidirectional world communication, with explicit application-level receipts, replay, and reconnection.

> One shared reality. Several independent histories. Ordinary Gene code for behavior. A world that can acquire new places, objects, and rules without restarting the experiment from nothing.

## 1. Purpose and scope

Gene World is the environment in which a few independent Gene Lives can observe, act, meet, remember, and change. The first environment is **The Commons**: a small persistent garden, workshop, gathering place, and surrounding landscape. Begin with four Lives whose starting inclinations differ slightly, not four permanently assigned professions.

The experiment asks whether these individuals develop distinct and coherent ways of living through their experiences. The world supplies opportunities, constraints, and actual outcomes. It does not prescribe their stories, maintain their private beliefs, or require activity on every heartbeat.

The world must be expandable in three ways:

1. **Space and content:** additional regions, objects, materials, plant varieties, and public artifacts.
2. **Behavior and systems:** additional interactions, environmental processes, and reusable world-side Gene modules.
3. **Interfaces:** additional observations and operations that old clients can either understand, ignore safely, or identify as unsupported.

Expansion must preserve existing identities, meaningful state, operation receipts, and supported activity progress. “Expandable” does not mean that every arbitrary change can be installed live without migration.

### 1.1 Relationship to Gene Life

Keep the Life design's independent identity, replaceable brain, decision note plus executable Gene program, flexible memory organization, and explicit persistence. Life remains independent of Gene Harness. Neither Harness nor Cordis is a mandatory dependency of this world.

This document deliberately changes the earlier single-process deployment option. Its multi-process world is an **independently running environment** from each Life's perspective. In particular:

| Earlier local-world option in `life.md` | This multi-process profile |
| --- | --- |
| Life and the world may share one transactional store. | The world owns its store; each Life owns a separate private store. |
| A world update and cognitive update can sometimes share one local commit. | A Life commit can publish an outbound request, not commit remote world effects. |
| Stopping the local body freezes its local simulation. | Stopping one Life does not stop the shared world. Only the world process controls world simulation. |
| A Life restart restores a local world snapshot. | The world restores its state; the Life reconnects and reconciles its last observed view. |
| `water` may complete an immediate local operation. | A networked action distinguishes local submission, world acceptance, and completed effect. |

These are explicit deployment changes, not claims that the older local transaction crosses a socket. The companion's sections on independent environments, explicit checkpoints, and uncertain effects remain applicable. [L1]

### 1.2 Non-goals for the first implementation

Do not begin with distributed world sharding, a consensus cluster, arbitrary remote code execution inside the world, general VM snapshots, a mandatory plugin framework, a full survival economy, or a complex capability subsystem. Authentication of a Life's identity and ownership of its avatar are basic communication requirements, not a new general permission language.

Start locally with separate operating-system processes. Tests may use in-memory substitutes for units, but the first end-to-end demonstration must actually cross process boundaries.

### 1.3 Reading map

| Concern | Sections |
| --- | --- |
| Initial environment and slightly different seeds | 2–3 |
| Process ownership, state, and simulation | 4–6 |
| Perception, conversation, and Gene-facing APIs | 7–8 |
| WebSocket messages and durable delivery | 9–11 |
| Restart, pause, and partial failures | 12 |
| Extending content, rules, and regions | 13–14 |
| Browser presentation and initial deployment | 15–16 |
| Implementation milestones and acceptance tests | 17–18 |

## 2. The initial environment: The Commons

### 2.1 A small place with interacting systems

Use a navigable ground plane with a 3D presentation. A candidate starting area is 64 by 64 world meters, represented as addressable regions rather than a permanently fixed-size array. The numbers are tunable experiment defaults, not language semantics.

| Place | Initial contents | Opportunities |
| --- | --- | --- |
| Central commons | Table, seats, shared shelves, noticeboard | Encounters, public messages, displays, collaborative projects |
| Garden | Several plots, two or three plant varieties, water source | Care, observation, comparison, learning delayed consequences |
| Workshop | Workbench, containers, reusable construction parts | Making and rearranging useful objects |
| Meadow and grove | Paths, trees, stones, partially hidden locations | Exploration, navigation, discovery, resource gathering |
| Personal nooks | Four roughly equivalent small spaces and storage areas | Personal projects, accumulated artifacts, chosen habits |

Keep starting access and travel distances reasonably comparable. Record the exact layout and initial positions. Rotate the mapping from seeds to positions in repeated experiments rather than assuming symmetry eliminates every advantage.

The map need not be completely visible to every Life. Initial geography can be fixed and intentionally designed; procedural generation is not required. When procedural generation is added, store the generated result and generator revision so a later generator does not regenerate already inhabited space.

### 2.2 A few causal rules are more valuable than many isolated actions

The initial world should have a small number of interactions whose effects combine:

- Plants respond to simulated moisture and light over time.
- A shade structure changes nearby light exposure.
- A container has finite volume; filling, carrying, and emptying it have defined consequences.
- A placed object may occupy space, change navigation, or provide seating/storage.
- Building consumes or relocates a defined set of reusable parts.
- Public notes and artifacts survive the writer's departure.

These are deliberately simplified simulation rules, not a claim of realistic biology or physics. Define them as reproducible functions over committed world state and simulation time.

Do not make the environment entirely decorative. A shade structure that changes no observation or outcome offers little opportunity to learn. Equally, do not require realistic fluid dynamics before watering becomes meaningful.

### 2.3 Mild constraints, no compulsory survival loop

Begin without death, mandatory hunger, disease, or a global reward score. Use modest travel time, limited carrying capacity, shared objects, and slow environmental changes to make choices consequential.

A Life may tend something, create an object, talk, explore, investigate, or remain quiet. It does not have to satisfy a host-defined productivity quota. A brain-invented energy or sleep model remains private body code and state unless a separately introduced world rule gives it physical consequences.

### 2.4 Candidate initial interaction vocabulary

Operations are supplied by world modules and exposed through ordinary Gene client functions. Their names below are proposed, versioned application names.

| Family | Initial operations or queries |
| --- | --- |
| Perception | Observe current surroundings, inspect a visible object, inspect own inventory |
| Movement | Start walking to a known point/place, query progress, suspend/resume/cancel a walk |
| Manipulation | Pick up, put down, move a reachable object into a container |
| Garden | Fill a container, water a plant, plant into a suitable plot |
| Construction | Assemble or disassemble a small declared recipe; place its result |
| Communication | Speak locally, read/write a noticeboard, inspect an accessible thread |

The first working slice only needs movement, one unique shared object, local speech, and persistent observation. Garden and construction systems follow that path rather than all being prerequisites.

New operations should not require changing the brain response format. They do require a world implementation with actual rules, documentation, and versioned input/output contracts.

## 3. Four independent Lives with light seeding

### 3.1 Independence is more than four display names

Each Life has its own durable identity, private data store, current cognitive organization, retrieved model context, decisions, selected Gene routines, agenda, and brain invocation loop. Do not place all model histories or mutable memory in a shared global cell.

The Lives may initially use the same model, model configuration, runtime libraries, and available physical actions. Shared immutable source is compatible with independent execution. Shared hidden cognitive state is not.

A Life's original seed is retained as creation provenance. Its current disposition may evolve. Restart reads the accumulated individual; it does not replay the seed as a new birth.

### 3.2 Common creation prompt

Use the same common foundation, substituting only identity and the slight seed variation:

> You are {name}, one independent virtual individual beginning life in the Commons. You have a body, a private history, and the ability to act through Gene programs.
>
> You are initially curious about this place and interested in discovering activities worth continuing. You have not yet formed relationships or completed projects. Learn about other inhabitants through encounters and communication rather than assuming you know their thoughts or histories.
>
> You can observe, move, manipulate objects, communicate, remember, schedule future activity, and develop reusable Gene behavior through the supplied interfaces. The world determines what actually happens. Use observations and execution results to distinguish intention from outcome.
>
> Decide what deserves your attention. You need not respond to every message or remain busy. You may explore, maintain something, experiment, collaborate, reconsider an intention, or wait.
>
> Your starting inclination is not a job assignment. It may change through experience. Preserve what matters using your selected memory and state organization.
>
> Return a brief decision note and a complete Gene program in the documented format. The program performs actions; the note records your expressed intent. Neither is automatically spoken to others.

This is a creation prompt, not an immutable personality instruction copied into every future model call. Stable execution/API instructions remain available; later cognitive context describes the individual as it has developed.

### 3.3 Small individual additions

**Aster — continuity and care**

> You are slightly more likely to notice gradual changes and things that could benefit from continued care. Initially, preserving or improving something worthwhile appeals to you a little more than immediately beginning another project. This is a starting tendency, not a permanent responsibility.

**Brin — explanation and comparison**

> You are slightly more curious about why things behave as they do. Initially, making a small comparison or trying a reversible experiment appeals to you a little more than relying on the first explanation. This is a starting tendency, not an obligation to investigate everything.

**Cove — arrangement and making**

> You are slightly more likely to notice how objects and spaces could be arranged differently. Initially, making a place or procedure more useful or pleasant appeals to you a little more than leaving it as you found it. This is a starting tendency, not an assigned building role.

**Dara — perspectives and exchange**

> You are slightly more curious about what others have noticed and what matters to them. Initially, exchanging or combining perspectives appeals to you a little more than working entirely alone. This is a starting tendency, not an obligation to join every conversation.

All four may garden, investigate, build, learn procedures, socialize, or work alone. Do not preassign friendships, rivalries, fabricated memories, or expertise. Keep the seed prompts short enough that the individual differences remain mild.

### 3.4 Experiment identity

Record the common prompt revision, individual seed, creation world revision, initial position, model configuration, and initial body-code revision. Give each Life a distinct stable ID independent of its display name.

A controlled restart preserves that ID. An experimental clone is an explicit new Life with a new store and identity; it does not silently attach as a second controller of the original avatar.

## 4. Process architecture and ownership

### 4.1 Required topology

```text
       Optional launcher: starts/stops separate processes

+-----------------------+         +--------------------------+
| World process         |<-- WS ->| Life A: brain/body/store |
|                       |         +--------------------------+
| simulation            |<-- WS ->| Life B: brain/body/store |
| authoritative store   |         +--------------------------+
| action transitions    |<-- WS ->| Life C: brain/body/store |
| observation delivery  |         +--------------------------+
| HTTP assets + WS      |<-- WS ->| Life D: brain/body/store |
+-----------+-----------+         +--------------------------+
            |
      HTTP + spectator WS
            |
+-----------+-----------+
| Browser renderer      |
| camera and controls   |
+-----------------------+
```

The world process does not call an LLM to advance physics or decide for an inhabitant. Each Life invokes its own replaceable brain adapter. A model can be a shared remote service without sharing the Lives' model contexts or decisions.

The launcher is convenience infrastructure, not a global mind. Killing the launcher must not be the only way to pause or inspect an individual. The browser is a presentation client; closing it does not stop the world or any Life.

### 4.2 State ownership

| State | Authoritative owner |
| --- | --- |
| World identity/history, regions, objects, simulation time | World process |
| Avatar location, orientation, physical inventory, held objects | World process |
| Active physical action and its committed progress | World process |
| Public artifacts and world-local conversation delivery | World process |
| Life identity, private memory, decision notes, cognitive code/data | That Life process |
| Intentions, schedules, local job records, outbound requests | That Life process |
| A Life's remembered/last observed world state | That Life process, explicitly a view rather than authority |
| Render interpolation, selection, camera | Browser |

Use a separate store per owner, initially local SQLite files or the equivalent existing transactional Gene store. Only the owning process opens its store for mutation. No Life reads another Life's database or the world's database directly, even when all processes run on the same machine.

SQLite can provide local transactional commits; it does not turn these separately owned stores into a transaction shared across WebSocket connections. The implementation must use an actual durable configuration and test crash recovery on supported storage. [T3]

### 4.3 Minimal identity and connection ownership

A local operator creates a Life registration and its stable avatar mapping in the world. Enrollment is idempotent for the same registered Life, and normal reconnect never creates another avatar. Display names are not authentication or database keys.

Bind each native client connection to its registered Life using an operator-issued local connection credential. The server derives the acting identity from that connection, not from an arbitrary `actor_id` supplied in a message. Keep spectator and operator sessions separate from Life controllers. This is enough for the local experiment; a full permissions model is outside this document.

Allow one controlling process for each Life/avatar. A live second controller is rejected by default. A replacement can attach after expiry or explicit operator takeover. Every successful controller attachment obtains a new monotonically increasing **control generation**; the world rejects commands from older generations, including already queued work that has not been admitted. This prevents a stale socket from issuing new commands after takeover.

Each Life also holds an exclusive claim on its own private store. The world and Life store claims solve different problems: only one world writer and only one brain/body writer may own their respective persistent state.

## 5. An extensible world model

### 5.1 Stable entities, versioned components

Represent world entities with stable IDs and named, versioned components rather than a separate hard-coded host structure for every object kind. A straightforward map representation is sufficient; adopting a high-performance ECS framework is not required.

Illustrative record:

```json
{
  "id": "entity-plant-17",
  "kind": "garden/plant",
  "revision": "82",
  "components": {
    "core/transform": {"schema": 1, "x_mm": 12000, "y_mm": 0, "z_mm": 8000},
    "garden/plant": {"schema": 1, "variety": "shade_leaf", "moisture": 31, "growth": 8},
    "core/appearance": {"schema": 1, "asset": "plant/shade_leaf"}
  }
}
```

This example uses the wire-style data representation. Internally, Gene can use checked string-keyed maps or suitable typed wrappers; no universal component framework is required.

Keep entity IDs stable across movement, code upgrades, disconnects, and normal restarts. Keep a deletion tombstone when an ID is removed; never reinterpret a saved reference as a new object occupying the same place.

### 5.2 Physical invariants

The world validates all actions against its current state. A Life cannot move an avatar by publishing a new position, create inventory by editing a local record, or water a distant plant because it once observed it.

Initial invariants include:

- A unique movable item has exactly one physical location or containing entity.
- Containment is acyclic, respects capacity, and does not duplicate inventory.
- Movement obeys the selected world geometry and activity rules.
- Required proximity and possession are checked when the effect is applied.
- A construction transaction consumes/reserves the actual parts and creates its result together.
- A failed atomic world operation leaves no half-applied physical change.

Several Lives may reason from the same observation. If both try to pick up the same container, the world serializes the attempts; at most one succeeds, and the other receives a factual failure. No world-wide cognitive lock is needed.

### 5.3 Regions and expansion

Give coordinates a stable definition: X east, Y up, Z north, with initial authoritative positions in integer millimeters. Use a one-meter navigation grid initially, while allowing visual positions between cell centers. Regions have stable IDs and bounded extents; optional 16-by-16-meter chunks are an internal indexing choice.

Adding an adjacent region must not renumber entities, reinterpret old coordinates, or regenerate inhabited terrain. Unloaded is not the same as nonexistent. If region streaming is not implemented, reject travel beyond active boundaries clearly.

Store generated regions and their generation inputs/revision. The same coordinate cannot spontaneously become a different place because the map generator changed.

### 5.4 Systems and transitions

A world module can supply operation handlers, tick handlers, component validation, observation projection, and migrations. Prefer bounded transition functions that prepare changes and events for a world transaction. They do not perform model inference, send unrelated network requests, or hold the world writer while awaiting external work.

Define a deterministic system order in the selected world manifest. If two systems modify the same component, their ordering or explicit combination rule must be declared. Loading modules in a different incidental order must not change the rules.

Commit authoritative state, action progress, simulation time, relevant random-generator state, and resulting durable events together. Recovery applies recorded state changes; it does not rerun historical Gene action programs to reconstruct their effects.

## 6. Simulation, time, actions, and disconnects

### 6.1 Three clocks remain separate

| Clock | Owner | Meaning |
| --- | --- | --- |
| Simulation time | World | Movement, growth, day/night, and world activity progress |
| Wall/monotonic operational time | Each process | Network health, timeouts, resource limits, and reconnect delays |
| Cognitive schedules | Each Life | When that Life decides to think or run its own code |

Start with fixed logical world steps, for example 100 simulation milliseconds. Render interpolation is independent. Persist a logical step before exposing it as authoritative; the world does not publish uncommitted positions as confirmed reality.

Simulation advances while the world is running even when every brain is idle. It pauses during world process downtime in version 1; no implicit fast-forward after restart. If overloaded, reduce effective simulation speed and expose the lag rather than silently skipping causal updates. A later fast-forward policy must define what it preserves.

A Life-owned routine using this world's simulation clock may see elapsed simulation time while that Life was offline. Its selected controller must explicitly choose bounded catch-up or rebasing its checkpoint without retroactive credit. For example, a sleep routine cannot silently assume the world clock paused with its own process. Qualify retained clock checkpoints with world/history identity; a world branch is not another elapsed interval on the same clock.

Slowing or pausing the world is a world operation. Pausing one Life is not.

### 6.2 World-owned physical activities

A walk is a world activity with a destination, stable action ID, rules revision, current progress, and a recovery contract. Once admitted, it advances without model calls or per-frame client commands. The Life retains a corresponding local job and receives progress or completion observations.

For version 1, permit one locomotion activity per avatar. A new walk while another is active is rejected as busy unless the caller explicitly cancels/suspends or uses an operation whose documented replacement semantics cover both actions. Do not make a new command silently discard an earlier commitment.

A path may be recomputed when geometry changes. No route produces a recorded blocked/failed outcome rather than an endless hidden retry loop. Changes to physical progress and its outcome are committed by the world, not by the Life's cognitive database.

### 6.3 Connection loss is not death or immediate certainty

The world's connection handler detects an orderly close immediately and an unresponsive peer after its configured timeout. Until detection, already admitted work can make additional committed progress. A disconnected Life must not assume it stopped at the last position it personally received.

Initial policy:

| Condition | World behavior |
| --- | --- |
| Brief loss before it is detected | Previously admitted activities may continue; no guarantees of instantaneous stop. |
| Controller close, expired lease, or explicit detach | Suspend that avatar's ongoing motor activities at the next safe committed step. |
| Life absent | Keep the avatar, possessions, and public artifacts; the environment and other Lives continue. |
| Reconnect | Reconcile action status and current entity state; do not automatically resume all prior activities. |
| Explicit resume after synchronization | Continue compatible suspended activity from committed progress under the same action ID. |

Suspending movement does not cancel environmental processes such as plant growth. The initial world has no mandatory survival damage while an inhabitant is offline. Presence is a transport/operational fact, not a forced psychological description such as sleeping.

At world restart, restore unfinished avatar-controlled motor activities as suspended until their Life reconciles. Autonomous world systems resume from saved simulation time. The selected policy must be visible in activity documentation.

### 6.4 Fairness without a universal mind scheduler

Each Life can deliberate independently. Bound queues per Life and process world commands fairly rather than allowing one sender to monopolize the world. A round-robin ready queue is sufficient initially; persist command acceptance order when recording a test trace.

Use comparable model settings and inference budgets for seed comparisons. Do not wait for every Life to finish a thought before the world can advance. Model latency is an experimental variable to record, not a reason to freeze all inhabitants.

## 7. Perception, conversations, and shared artifacts

### 7.1 A Life observes a view, not the whole database

The world computes an observation view using the avatar's actual location and the selected perception rules. Start with structured observations: nearby visible objects, own inventory, accessible signs, local speech, and known activity outcomes.

The world does not send another Life's decision notes, private memory, or internal rest model. Those records never need to reside in the world process.

Maintain separate concepts:

- **Current observed view:** entities and attributes the avatar can presently perceive.
- **Remembered observation:** an earlier view retained by the Life with its time and source.
- **Operator inspection:** a deliberately broader debugging view, never silently fed into a brain.

An entity leaving view produces removal from the current view, not a claim that it ceased to exist. New visibility requires a complete baseline for that entity before incremental changes can be interpreted.

### 7.2 Offline observation policy

Initially, an offline controller does not passively hear every future local conversation. Finalize the audience of local speech at its world commit using location and declared listening/presence rules. Once an event belongs to an audience, retain it for that recipient through ordinary reconnection.

A noticeboard is persistent: an inhabitant can later visit and read its retained posts whether or not it was online when they were written. Direct addressed mail, if added, has its own explicit retention and delivery contract.

This avoids reconstructing yesterday's audience from today's positions or silently giving an absent Life omniscient history.

### 7.3 Conversations are ordinary world events

Speech and posts carry a speaker ID, conversation or channel ID, optional thread/reply reference, text, operation ID, and committed simulation time. The world records the action of speaking and its eligible audience; each recipient decides whether and when to think about it.

Do not wake every brain for every acknowledgment. Coalescing and silence belong to each Life's attention policy. Its own outbound echo should not automatically provoke a new response to itself.

A public assertion is authored content, not a world-engine fact. A Life can remember who said it, test it, disagree, or ignore it. The world owns the delivered statement, not a universal belief that it is true.

### 7.4 Code sharing without automatic execution

A noticeboard artifact may contain text, a sketch, a procedure, or Gene source with an immutable revision/hash. Reading another inhabitant's program remains a data operation. It does not evaluate the code, install a callback, or alter the reader's cognitive organization.

A Life may explicitly inspect, test, adapt, and select that code locally. This makes exchange of procedures an experiment in learned behavior without turning ordinary world messaging into remote program execution.

## 8. Gene code stays the brain–body interface

### 8.1 Two different interfaces

```text
Brain → Life body:
    decision note + ordinary executable Gene program

Life body → World process:
    versioned data messages describing queries and world operations
```

A JSON command on a socket is not a requirement for the brain to emit a JSON tool call. The brain writes loops, functions, calculations, memory updates, scheduling logic, and ordinary library calls. The client adapter translates calls into transport messages and reconstructs results/events.

The world never evaluates arbitrary Gene source received on its normal action channel. World rules are operator-selected Gene modules; a proposed feature or shared script is inert until explicitly admitted through the extension workflow.

### 8.2 Suggested client-library surface

These method names are illustrative application APIs, not current Gene runtime promises.

| Operation | Proposed behavior |
| --- | --- |
| `world.observe(selector)` | Return a local synchronized observation snapshot with view revision and freshness information; no network wait. |
| `world.refresh(selector)` | Asynchronously request a fresh filtered view; never block a local transaction. |
| `world.start_walk(destination, tx?)` | Create a durable local job and outbound request; return the local job descriptor after local commit. |
| `world.water(plant, options, tx?)` | Create an action request; return an action reference, not a fabricated successful watering result. |
| `world.say(text, options, tx?)` | Queue an explicit local-speech request with a durable operation identity. |
| `world.result(action_ref)` | Read the most recent durably recorded status. |
| `world.await_result(action_ref)` | Return an awaitable for settlement; allowed outside `store.commit`. |
| `world.cancel(action_ref)` | Record a cancellation request; completion/cancellation races are reported honestly. |
| `world.describe()` | Return compact known interfaces, operation versions, and module documentation. |

Remote operations must not hide indefinite network blocking inside a method documented as immediate. An `await_result` timeout leaves the action pending/uncertain; it is not evidence that the world cancelled it.

### 8.3 Preserve the grouped-update example, with an explicit new boundary

```gene
(store .commit
  (fn [tx]
    (let job (body/world .start_walk "garden" ^tx tx))
    (state .put "activity" {^kind "walking" ^job_id job/id} ^tx tx)
    job/id))
```

In this profile, that transaction commits **only to the Life store**:

```text
local job + owning intention reference + outbound world request
```

It does not contact the world from inside the callback. After commit, an independent sender transmits the request. The world may reject it, start it, suspend it, or complete it. The Life records those outcomes through its normal foreground state-update path.

The world owns a different transaction:

```text
operation receipt + authoritative physical change/action record
+ recipient events + relevant world revision
```

No single commit covers these two stores. Correlation IDs and deduplication connect them. This is a deliberate replacement of the co-located local-world assumption in `life.md`, not an implementation of distributed `store.commit`.

### 8.4 Behavior without another model call

A Life may store a procedure that starts a walk, waits through an ordinary supervised activity controller, inspects the observed destination, and requests another action. The controller can run without continuous inference.

Only activity code with an explicit persisted continuation contract resumes automatically after restart. A generic foreground program that had performed half its calls remains interrupted; recover its known outcomes and let ordinary recovery code or the brain decide the remainder.

Wire handles, socket callbacks, tasks, and remote action references are not interchangeable. An action reference is serializable identity; a task waiting for it is transient execution.

## 9. WebSocket as transport

### 9.1 Why use it here

Choose WebSocket for version 1. It supplies a bidirectional connection with message framing and protocol-level close/ping/pong behavior. Native Life clients and the browser can use the same transport family. It is suitable for commands going toward the world and observations going back without tying a response to the lifetime of one HTTP request. [T1]

Use ordinary HTTP for the browser page, static assets, documentation, and large immutable asset blobs. Do not send a multi-megabyte model or texture through the control queue simply because a socket exists.

This is not a low-latency competitive action game. WebRTC, UDP simulation protocols, a message broker, and RPC framework are not needed for the initial four Lives. Keep serialization and command handling separate from the WebSocket adapter so another transport can be added without changing world semantics.

WebSocket does **not** define this application's durable receipt, replay, deduplication, or resume behavior. Those are specified below. A successful socket send is not a committed world action.

### 9.2 Encoding and protocol version

Use one complete UTF-8 JSON object per WebSocket application message. JSON is the initial interprocess representation; it does not replace Gene as the language of the brains or body libraries. [T4]

Proposed endpoint and subprotocol:

```text
ws://127.0.0.1:8096/world/v1
Sec-WebSocket-Protocol: gene.world.v1
```

The URL and port are proposed configuration defaults. Bind to loopback for the first experiment. Non-local deployment requires an explicitly configured authenticated endpoint using `wss`; it is not enabled by changing a bind address casually.

Messages use structural data, not process-local Gene type IDs, live objects, closures, or executable deserialization hooks. Gene source in an artifact remains a string with media type and revision metadata.

Use strings for IDs, large revisions, event sequences, and simulation timestamps. Initially restrict numeric payloads to bounded safe integers; authoritative coordinates and quantities can use integer units. Reject duplicate JSON keys, non-finite numbers, excessive nesting, and values outside the operation schema. JSON's interoperable integer considerations motivate avoiding unbounded Gene integers as bare browser numbers. [T4]

### 9.3 Identities that must not be conflated

| Field | Lifetime and meaning |
| --- | --- |
| `world_id` | Stable world identity across ordinary restart |
| `history_id` | A persistent branch of world history; changes on an intentional rewind/fork, not on restart |
| `server_epoch` | New transient process incarnation on every world-server boot |
| `life_id` | Stable individual identity |
| `entity_id` | Stable embodied entity assigned to that Life in this history |
| `control_generation` | Current controlling connection generation; invalidates stale controller entry |
| `operation_id` | A durable logical mutation request, stable across resend and reconnect |
| `request_id` | Correlation for a query/transport exchange; not proof of a world effect |
| `stream_id` / `event_seq` | A recipient's durable event stream and position |
| `world_revision` | Committed authoritative state revision, not a blanket precondition on every action |
| `rules_revision` | Selected world behavior/configuration revision; changes only when those semantics change |
| `owner_id` / `owner_generation` | Optional Life-defined work ownership, not a connection or goal schema |

Ordinary ticks can change `world_revision` without changing `rules_revision`. Do not invalidate every pending thought because another avatar moved. Use explicit target preconditions and relevant operation/rule compatibility.

### 9.4 Connection lifecycle

```text
connect
→ authenticate and select protocol version
→ bind registered Life and acquire controller generation
→ negotiate supported operation/feature contracts
→ replay and synchronize observations
→ reconcile pending requests/activities
→ declare client ready for new mutations
```

The server accepts no ordinary mutating commands before readiness. It can accept recovery queries and a documented cancellation during synchronization. Failure to recognize a required protocol version or feature returns a structured incompatibility, not best-effort execution under another meaning.

A `hello` proposes supported protocol versions, identifies the configured world/history and Life, supplies connection credentials, and reports the last durably stored event cursor. The server validates the Life identity rather than trusting the message's claimed actor. Never log the raw credential or put it in a URL.

An illustrative welcome:

```json
{
  "v": 1,
  "kind": "welcome",
  "world_id": "commons-01",
  "history_id": "history-01",
  "server_epoch": "boot-7f24",
  "life_id": "life-aster",
  "entity_id": "avatar-aster",
  "control_generation": "12",
  "stream_id": "events-life-aster",
  "rules_revision": "rules-4",
  "features": {
    "core": {"version": 1},
    "movement": {"version": 1},
    "conversation": {"version": 1},
    "garden": {"version": 1}
  },
  "sync_required": true
}
```

These are example values. A real connection also receives limits, world time/status, and the supported operation-contract catalog or its digest. Catalog retrieval is read-only; metadata never auto-loads code into a Life.

### 9.5 Message families

| Kind | Direction | Purpose |
| --- | --- | --- |
| `hello`, `welcome`, `ready` | Both | Identity, negotiation, controller ownership, synchronization |
| `query`, `query_result` | Both | Filtered inspection, catalog reads, operation-status reconciliation |
| `command`, `receipt` | Both | Durable world mutation or physical-activity request |
| `event` | World → Life | Recipient-specific durable observation or activity outcome |
| `ack` | Life → World | Highest consecutively persisted event, not completed cognition |
| `sync_begin`, `snapshot`, `sync_end` | World → Life | Consistent view baseline plus replay boundaries |
| `resync_required`, `history_gap` | World → Life | Explicit recovery from missing or incompatible view/history |
| `heartbeat` | Both | Application liveness/progress; no brain invocation implied |
| `error` | Both | Structured protocol/input/compatibility problem |

Operation names remain extensible, for example `movement.walk_to`, `garden.water`, `conversation.say`, and `core.cancel`. Adding an operation does not add another brain-response type or replace the transport envelope.

### 9.6 Example mutation and receipt

```json
{
  "v": 1,
  "kind": "command",
  "world_id": "commons-01",
  "history_id": "history-01",
  "control_generation": "12",
  "operation_id": "op-aster-204",
  "operation": "movement.walk_to",
  "contract_version": 1,
  "rules_revision": "rules-4",
  "owner": {"id": "owner-17", "generation": "3"},
  "input": {"destination_id": "place-garden"},
  "preconditions": []
}
```

The server derives the avatar from the connection. In version 1, new mutations require the stated rules revision to be current. This is conservative but changes only on rule updates, not every tick. A later per-feature compatibility rule can be more permissive. Retrying an already recorded operation retrieves its existing result even when rules have changed.

An accepted long activity returns:

```json
{
  "v": 1,
  "kind": "receipt",
  "world_id": "commons-01",
  "history_id": "history-01",
  "operation_id": "op-aster-204",
  "admission": "accepted",
  "action_id": "action-938",
  "action_status": "running",
  "world_revision": "2418",
  "rules_revision": "rules-4"
}
```

`accepted` means the request and action record are durably admitted. It does not mean the walk has finished. A later event supplies completion, failure, suspension, or cancellation. An immediate atomic operation may return a receipt whose action status is already `completed`.

Query responses and status updates identify their observation revision. An action can change after a status query returns; its response is evidence at that revision, not a reservation.

## 10. Delivery, local outboxes, and operation identity

### 10.1 Life-side publication

Before sending a mutation, the Life commits an immutable request record in its local outbox. The request receives a stable `operation_id` once, with the world/history, operation version, input, relevant preconditions, and optional work owner. It can share a local transaction with a job or cognitive record.

After commit, the sender transmits it. Initially send mutation requests in local outbox order and wait for an admission receipt before advancing dependent requests. Long activities need not finish before an independent request is admitted. A stuck observation stream or action must not prevent sending a cancellation/recovery query through its documented control path.

On receipt or outcome event, atomically record the result and advance local outbox/job status. A local timeout does not remove the request or generate a replacement operation ID.

### 10.2 World-side deduplication

The durable key is:

```text
(world_id, history_id, authenticated_life_id, operation_id)
```

Store the normalized semantic command and its receipt. Compare data structurally, ignoring JSON property ordering; a digest may accelerate comparison but is not a substitute for a specified canonical representation or equality check. Connection fields such as `control_generation` and `server_epoch` are not semantic payload, so reconnect can resend the same operation under its new valid connection.

For an already recorded key:

```text
Same semantic request → return its retained receipt/current action status.
Different semantic request → operation_id_conflict; never execute it.
```

Do not rerun the operation to discover its result. For a previously rejected request, return the same rejection; trying again under changed circumstances is an explicit new operation.

The first prototype keeps deduplication receipts or exact rejection/cancellation tombstones for the lifetime of the world history. Do not prune them with ordinary view telemetry. Future retention work must preserve anti-replay information; removing a receipt and then interpreting its ID as a new command is not allowed.

### 10.3 Atomic world application

For a validated, previously unseen command, the world performs a bounded serialized transition:

```text
Validate controller generation and compatible operation contract.
Check current physical preconditions.
Prepare changes, recipient observations, and the result.
Commit receipt + physical changes/action record + durable recipient events.
Only then expose the receipt and publish notifications.
```

A normal precondition or domain rejection can itself be retained as the command's immutable rejected result. Invalid framing/authentication or unavailable transport is not a committed operation and carries no false receipt. A persistence failure prevents publication and puts dependent processing into a visible recovery/failure state.

For a long action, admission commits the action record first. Each later logical step commits action progress and physical changes together. Action statuses are `queued`, `running`, `suspended`, `completed`, `failed`, or `cancelled`; terminal statuses do not revert. An independent admission field distinguishes a rejected request from a failed previously admitted activity.

This yields one logical application of a known command under an intact durable world history. It is not a promise of exactly-once effects in arbitrary external systems.

### 10.4 Lost reply example

```text
Life commits outbox operation O.
World applies O and commits receipt R.
Connection fails before Life stores R.
Life reconnects and queries/resends O with the same semantic content.
World returns R rather than applying O again.
Life commits R and the local job update.
```

Because both stores contain explicit identities, this does not require a distributed transaction. If the world has lost or intentionally rewound its durable history, use the history-change procedure instead of pretending the receipt must still exist.

### 10.5 Cancellation and out-of-order arrival

Cancelling a Life intention invalidates its unsent owned work locally and creates cancellation requests for work that may already have reached the world. Cancellation is a new durable operation; it is not inferred from closing a socket or deleting a local task.

`core.cancel` identifies the original operation and, where available, its semantic fingerprint. The world handles these cases:

| Original operation | Cancellation result |
| --- | --- |
| Not yet admitted | Record a cancellation tombstone for that original ID. A later arrival of the original must not start it. |
| Active/suspended activity | Stop at the next safe world transition and record committed progress plus cancellation. |
| Already completed/failed | Report the actual terminal result; cancellation is too late to undo it. |
| Already cancelled | Return the existing result. |

The tombstone reserves the target ID for the same authenticated Life and history. If an expected semantic fingerprint was recorded, a later mismatching command is a conflict; a matching command receives the cancelled result without executing. With no fingerprint, the ID remains cancelled rather than being bound to a new command. This prevents an in-flight original command from starting after cancellation wins the race. A differently authenticated Life cannot cancel it merely by guessing the ID.

Stopping runtime execution is not identical to abandoning a Life's intention. For temporary pause, use activity suspension and preserve progress. A graceful Life shutdown waits for its documented suspension/detachment result when reachable; otherwise it records uncertainty and the world's disconnect policy eventually applies.

### 10.6 No implicit multi-command transaction

A Gene loop issuing five separate world operations can make partial progress. The world does not turn a whole brain program into an atomic remote transaction.

When an invariant genuinely needs atomicity—such as moving an object from one container to another or consuming parts to assemble one object—supply a world operation that commits that invariant locally in the world store. Do not add arbitrary remote transaction callbacks to solve every multi-step plan.

## 11. Events, snapshots, reconnection, and backpressure

### 11.1 Separate durable observations from render telemetry

The world owns an ordered durable event stream for each Life. It assigns events to an audience using the rules at the event's committed moment. A recipient stream has its own sequence, so filtering out another Life's private or unseen events does not create unexplained sequence holes.

Durable events include admitted action outcomes, eligible conversation messages, important environmental observations, visibility changes, and rule/history changes. Fine-grained interpolated transforms for the browser can use a separate replaceable telemetry stream.

No Life needs an event for every millimeter of another avatar's movement. The perception module may sample or coalesce position observations before assigning durable event IDs. Once an event is committed to a recipient stream, it is not silently replaced with unrelated content under the same sequence.

### 11.2 Event example

```json
{
  "v": 1,
  "kind": "event",
  "world_id": "commons-01",
  "history_id": "history-01",
  "stream_id": "events-life-aster",
  "event_seq": "731",
  "world_revision": "2475",
  "sim_time_ms": "514000",
  "type": "movement.completed",
  "schema_version": 1,
  "required": true,
  "operation_id": "op-aster-204",
  "payload": {
    "action_id": "action-938",
    "entity_id": "avatar-aster",
    "destination_id": "place-garden"
  }
}
```

The recipient persists the event before acknowledging its cursor. Storing the event does not mean the brain has considered it or completed an associated commitment. Those are separate Life states.

Deduplicate by stream identity and sequence/event ID, and correlate direct receipts with events by operation/action identity. Receiving both must not create two completed jobs or two copies of the same speech.

### 11.3 A consistent reconnect sequence

Reconnection must recover historical messages as well as current position. A fresh snapshot alone cannot recreate an unacknowledged conversation.

Use this sequence:

1. Authenticate and establish the new control generation, but do not yet admit new ordinary mutations.
2. Read the Life's last durably stored event cursor A.
3. At a serialized world boundary, capture a filtered snapshot at world revision R and recipient stream cut C. Pin the required replay range while synchronization proceeds.
4. Send `sync_begin`, then the retained events after A through C in ordered, bounded pages. Persist these as observations even when a newer snapshot supersedes their old view-state changes.
5. Send the complete snapshot associated with R/C, including current visible entities, own avatar/inventory, relevant actions, world/rules metadata, and view-generation identity.
6. The Life atomically installs that snapshot and its sync metadata after all preceding required events are durable. It must not reapply an older positional delta on top of the snapshot.
7. Deliver subsequent events after C. Their view deltas name the expected baseline/entity revisions; a mismatch triggers resynchronization.
8. Reconcile outstanding operations, acknowledge the persisted cursor, and enter ready state.

The world continues serving other Lives and ticking during this process. Capture the cut consistently, but do not hold an open world transaction while sending pages over a slow socket. Bound the pinned range/snapshot lifetime; if it expires, restart synchronization explicitly.

On a required event gap, do not advance the acknowledgment past it. A client may preserve an unknown optional event as opaque data and acknowledge it; an unknown required schema prevents affected processing until upgraded or explicitly resynchronized under a compatible contract.

### 11.4 Retention and gaps

For the initial experiment, retain unacknowledged essential recipient events. Acknowledged events may later be pruned under a documented policy because the Life has durably retained its relevant history. Keep operation receipts under their separate anti-replay rule.

If an explicit maintenance action or later bounded-retention policy removes required history, send `history_gap` with the missing range and a new current snapshot. Record the gap in the Life; do not invent the lost conversation. Disk pressure must produce a visible maintenance/failure state, not silent deletion of undelivered essentials.

A client cursor ahead of the world's stream is a consistency/history error. An ordinary `server_epoch` change does not justify resetting durable sequence numbers or replaying old actions as new ones.

### 11.5 Connection health and flow control

Use WebSocket ping/pong when the selected binding exposes it, and an application heartbeat for progress and lease information. The RFC's transport keepalive is not a durable event acknowledgment or evidence that a brain is making progress. [T1]

Candidate local defaults are a heartbeat every 15 wall-clock seconds, a controller expiry after 45 seconds without valid liveness, and bounded reconnect backoff with jitter. These are tunable operational values. World simulation time must not determine network liveness.

The standard browser `WebSocket` API does not provide automatic receive backpressure, and `bufferedAmount` measures queued outbound bytes rather than durable receipt. Therefore the application must bound work and buffering itself. [T2]

Suggested starting limits, to be measured rather than treated as permanent laws:

| Limit | Initial default |
| --- | --- |
| Decoded command/event message | 256 KiB |
| Live outbound socket queue | 1 MiB or 256 messages, whichever is reached first |
| Replay page | At most 100 events and within the message-size limit |
| Outstanding ordinary mutation admissions per Life | One until its admission receipt, excluding dedicated recovery/cancel control |
| Expensive query work | Bounded per query and fairly scheduled |

Use paged/chunked snapshots when necessary, with one snapshot ID and no publication of a partial baseline. Duplicate or missing chunks restart the baseline transfer. Large assets use HTTP by digest.

When a peer cannot keep up, stop enqueueing replaceable telemetry, or close it with a resync reason and let it replay durable data. Never hold the authoritative world loop waiting for one peer's socket. Reserve a small bounded control path for close, heartbeat, cancellation, and protocol errors. Queue saturation does not permit unbounded memory growth.

Compression and complex transport extensions are not required for the first version. Validate complete application messages after WebSocket reassembly; never interpret a partial frame as a Gene program or complete command.

## 12. Persistence and independent recovery

### 12.1 Minimal world store

A possible logical schema is:

| Collection/table | Contents |
| --- | --- |
| `world_meta` | Identity/history, format, committed revision, simulation time, selected manifest, persistent RNG state |
| `world_entities` | Stable IDs, kinds, component payloads and schema revisions, deletion tombstones |
| `world_regions` | Geometry, content, generation provenance, activation state |
| `world_lives` | Registered Life-to-avatar mapping and controller-generation counter |
| `world_actions` | Accepted long actions, progress, status, selected implementation/rules revision |
| `world_operations` | Semantic request, receipt, result/status, cancellation tombstone |
| `world_events` / `recipient_events` | Authoritative changes and recipient-indexed durable observations |
| `world_artifacts` | Persistent notes, public content, source artifacts, and references |
| `world_releases` | Selected world modules, schemas, migrations, and immutable asset references |

These are responsibilities, not a required table count. A small transactional store can combine some collections. Keep the world journal as committed data changes, not a list of programs to execute again.

Each Life store continues to preserve the information in `life.md`, plus its world binding, durable outbox, operation/action links, event cursor, and last synchronized observed view. Its own cognitive schema remains freely replaceable.

### 12.2 World restart

Before accepting controllers or advancing simulation:

```text
Acquire exclusive world-store ownership.
Validate format, selected code/assets, and recovery state.
Restore the latest committed world state and activity progress.
Create a new server epoch; invalidate old connection leases.
Preserve world/history IDs, entity IDs, operation records, and event cursors.
Expose paused/reconciling motor activities and ready snapshots.
Resume simulation from committed time, without downtime fast-forward.
```

A missing required module or corrupt store is a recovery failure, not permission to start a fresh Commons in the same directory. A new world is an explicit create operation.

### 12.3 Life restart

The Life first restores its own identity, cognitive organization, pending requests, and observations. It then reconnects to the configured world/history, replays retained events, obtains current authoritative avatar state, and reconciles every uncertain outbound action.

While disconnected, its old world view is labeled last observed. It may inspect private memory or think about unrelated work, but must not claim to know its current physical location or complete a new world action without synchronization. The default first implementation waits for world synchronization before world-focused deliberation and action dispatch.

After a reconnect, its own entity may have changed because of already admitted movement or environmental activity. Accept the world's current facts; never upload an old inventory or position snapshot to overwrite them.

### 12.4 Pause, stop, and offline behavior

| Control | Result |
| --- | --- |
| Pause one Life | Stop new thinking/dispatch for that Life, checkpoint local work, request suspension of its world activity; other Lives and the world continue. |
| Stop one Life | Perform its local clean stop, attempt orderly world detach/suspension, and exit only that process. |
| Pause world | Stop simulation advancement and ordinary world-effect application; preserve networking, recovery queries, and defined suspend/cancel control transitions. Allow other Life-local reasoning if configured. |
| Stop world | Commit world state, suspend controlled activity, close clients, and exit; Lives enter a disconnected state. |
| Close renderer | No effect on Life or world lifetime. |

A requested pause is not settled until its documented local work and reachable world suspension have settled. During a network partition, report `pause_pending_remote` or equivalent uncertainty rather than claiming the remote motor is already stopped. Lease expiry bounds later world-side activity under the chosen disconnect policy.

### 12.5 No distributed rollback

If a Life commits an outbound request but the world rejects it, retain the failed request and repair/reconsider the cognitive expectation. Do not roll back an entire private history.

If the world commits an effect and the Life crashes before receiving it, receipt lookup and event replay repair the local view. Do not undo the world merely to match the stale Life database.

A consistency-preserving experiment backup can pause controllers, reconcile outboxes, and save each store with a manifest of world/history IDs and cursors. Arbitrarily restoring an old world database while leaving newer Life stores active is not ordinary recovery. An intentional rewind creates a new `history_id` or a new world, refuses old-history commands, and requires explicit branch/rebinding policy. Never reuse operation identities in a rewound history while pretending it is the same live timeline.

### 12.6 Failure matrix

| Failure point | Required recovery |
| --- | --- |
| Life exits before local request commit | No world dispatch; no acknowledged local job. |
| Life exits after local commit, before send | Recover pending outbox; dispatch only if still valid and not cancelled. |
| World exits before its operation transaction commits | Restore no partial effect; retry the same operation ID. |
| World commits, reply is lost | Return retained receipt on status query/resend; do not repeat the effect. |
| Life persists an event, ACK is lost | Replay may duplicate delivery; local deduplication suppresses duplicate state updates. |
| World exits during movement | Restore the last committed position/progress pair; suspend until controller reconciliation. |
| Life exits while other Lives act | Others continue; reconnecting Life sees current world and its retained history. |
| Controller takeover while old commands are queued | Fence the old generation before admission; retained accepted work follows suspension/recovery policy. |
| Old world snapshot is restored intentionally | New history branch; never transparently replay old-history commands. |

## 13. Expansion through versioned Gene world modules

### 13.1 A small stable core, not a closed world engine

Keep a small world core responsible for identity, stores, transaction publication, command routing, simulation scheduling, connections, observation delivery, and recovery. Put domain behavior into ordinary Gene modules.

A module can define:

| Contribution | Examples |
| --- | --- |
| Entity/component schemas | A plant, shade structure, water channel, weather sensor |
| Initial content and generation rules | New plots, objects, region templates, plant varieties |
| Operations and validators | Fill, irrigate, assemble, inspect a device |
| Simulation systems | Growth, shade calculation, water transfer, weather |
| Observation projectors | What a nearby Life can perceive about the new state |
| Activity checkpoint/recovery handlers | Continue an irrigation task or a construction phase |
| Migration functions | Transform old component data and retained activity records |
| Presentation descriptions/assets | Generic shapes, labels, meshes, materials, icons |
| Documentation/client helpers | Ordinary Gene calls that make the new operations usable |

Use a simple selected module manifest and normal Gene loading. A universal plugin marketplace, hot-reload framework, or cross-process dependency injector is not necessary.

### 13.2 Three kinds of expansion

**Content addition:** add more objects, varieties, recipes, or a region using existing behavior. Validate content and publish it transactionally. Do not require a new protocol version merely because there is another plant.

**Behavior addition:** add a new operation, component type, or simulation system. Supply schemas, migrations where needed, observation meaning, and client documentation. Select the module revision explicitly.

**Semantic replacement:** change how an existing operation or component behaves. Record a new rules revision and require compatibility/migration decisions for current state, active activities, and pending commands. A version string alone does not prove compatibility.

This separation lets the world grow without treating every added chair as a kernel upgrade or every change to collision rules as harmless content.

### 13.3 A module manifest

An illustrative data-only descriptor:

```gene
{^id "commons/irrigation"
 ^version "0.1.0"
 ^world_api 1
 ^dependencies ["core@1" "garden@1"]
 ^components ["irrigation/channel@1"]
 ^operations ["irrigation.connect@1" "irrigation.disconnect@1"]
 ^events ["irrigation.flow_changed@1"]
 ^systems ["irrigation/step@1"]
 ^migrations []
 ^assets ["channel/straight" "channel/corner"]}
```

Resolve names to selected immutable code revisions and dependency identities before activation. The descriptor identifies contributions; it does not run its operations merely by being read.

Namespaced identities prevent collisions. Schema versions, API contract versions, package versions, and active world rules revision are related but distinct. Runtime dispatch uses resolved identities rather than searching arbitrary source files for a similarly named function.

### 13.4 Operation handlers use one publication path

Every mutation handler, including added features, participates in the same world transition/transaction mechanism. Its implementation receives validated inputs, the acting entity, a bounded read view, and a change builder or transaction. It returns proposed changes, a result, and observation facts.

A new feature must not mutate global world maps outside that path, send its own untracked success reply, or start an independent timer that skips world pause/recovery. Its tick and activity registrations belong to the selected manifest and are reconstructed without duplication after restart.

The operation registry is an implementation detail of the world server. The brain sees ordinary documented Gene functions, not a forced tool-schema response format.

### 13.5 Initial activation policy: pause, migrate, select

Use one active world organization initially. A controlled world pause or stop/start migration is sufficient for version 1; uninterrupted hot replacement is an enhancement.

For a world upgrade:

1. Store the candidate modules/assets and validate their dependency closure, schemas, and operation catalog without publishing them.
2. Test migration against a copy of committed state and representative active action records.
3. Stop ordinary mutation admission and world ticks; settle or checkpoint affected world activities. Keep status/recovery connections responsive.
4. Determine the disposition of queued commands and suspended actions. Preserve compatible work, explicitly migrate it, reject/suspend it for reconsideration, or defer the upgrade. Never run old-layout code over new-layout data silently.
5. Atomically commit migrated data, compatible action/registration records, the selected manifest, and the new rules revision.
6. Publish the new in-memory dispatch tables as one control-loop transition, emit `world.rules_changed`, and resume simulation only when the committed selection can run.

The world may briefly stop while independent Life processes continue receiving other inputs or waiting. New mutations authored for the prior rules revision are rejected as stale unless a separately specified compatibility path exists. Do not rewrite an old operation's stored payload in order to make its retry pass.

If the process exits before selection commits, restore the old selection. If it exits after commit, restore the complete new selection. If activating the committed selection fails, remain paused with an inspectable recovery error. Do not quietly mix old handlers with new data.

Returning to older code requires compatible current data or a forward migration. It is not implemented by restoring an old entire world snapshot and erasing later conversations, receipts, or physical progress.

### 13.6 Queued and offline clients count as dependents

An offline Life may reconnect with scheduled code that uses an old API. A module upgrade cannot enumerate every future private program, so keep stable contract identities and reject unsupported versions explicitly.

The handshake advertises the current feature catalog and required versions. Each command states its contract/rules assumptions. Each Life receives a rules-change observation and may update its local adapter/library or ask its brain to reconsider affected work. Life-local cognitive migration remains separate and follows `life.md`.

Retain receipt/status queries for old operations even if the feature that created them is no longer available. Those results are core operational evidence. Removing an extension must not make completed work appear unknown and thereby executable again.

### 13.7 Unknown features and schemas

| Situation | Behavior |
| --- | --- |
| New content using known schemas | Existing clients can observe and act normally. |
| New optional observation field/component | Client preserves or ignores it under the schema contract; no automatic execution. |
| Unknown required observation or incompatible core schema | Stop affected processing and report the required update. |
| Unsupported operation version | Reject before effects with `unsupported_operation`/`incompatible_contract`. |
| Renderer lacks a new appearance | Use a generic fallback or explicit unsupported marker, not a runtime crash. |
| Server lacks a required persisted component implementation | Refuse normal simulation until it is restored or explicitly migrated. |

Do not drop unknown authoritative data merely because the running code cannot interpret it. Generic inspection should remain possible where the storage format permits it.

### 13.8 An example expansion: irrigation

The initial garden supports carrying water and watering individual plants. A later irrigation module adds channel components, connection/disconnection operations, a transfer system, and flow observations.

Its contract must say how much water can move in one logical step, which containers are connected, what happens on blockage, and how resource quantities remain nonnegative and conserved according to the simulation rules. State updates and flow outcomes commit together. It declares whether plant growth reads moisture before or after irrigation during a tick.

A possible observed development is:

```text
Aster repeatedly tends plants.
Brin compares moisture changes.
Cove builds a channel arrangement after the feature exists.
Dara shares observations or suggests a common project.
```

This is an illustrative possibility, not a script assigned to those seeds. Any individual may discover, ignore, or use irrigation. The new world feature supplies possibilities; the Lives choose behavior.

### 13.9 Lives may propose features, not silently redefine shared reality

A Life can publish a proposal, example code, tests, or a model of a desired mechanism as an artifact. The operator can adopt it through the world module workflow. Building an object with already supported rules remains an ordinary world action.

Writing a local function called `make_water` does not create water in the shared world. New world laws need an installed world implementation. A future experiment could automate more of feature admission, but arbitrary brain source is not executed as world-server code in this first design.

## 14. Spatial growth and larger experiments

### 14.1 Grow the map without replacing it

Add regions adjacent to or connected with the Commons: a stream, hill, orchard, library, or another workshop. Keep stable coordinate frames and explicit links between places. New links change navigation through a versioned world transaction.

Existing region revisions and object IDs remain. References stored by a Life can become stale if an object is deliberately moved or removed, but never because a new region renumbered everything.

Initially keep the entire small world resident. Introduce region streaming only when measurements require it. A later streaming contract must define inactive-region simulation, arrival synchronization, and cross-region actions before using unloading as an optimization.

### 14.2 Grow the population without coupling minds

The world should support an arbitrary configured set of registrations rather than special cases named Aster, Brin, Cove, and Dara. Four is an experiment size, not a wire-protocol limit.

A new Life receives its own process, data store, creation record, and entity registration. Adding it does not restart existing Lives or merge their private histories. Account for world computation, observation fanout, and model cost before increasing the population.

Do not add peer-to-peer Life networking initially. Local encounters and public artifacts go through the world, which supplies position-aware audience and durable delivery. External chat/forum connectors remain independent Life adapters.

### 14.3 Grow social and environmental possibilities gradually

Candidate later modules include seasonal changes, more construction recipes, persistent books or notebooks, collaborative work surfaces, energy networks, simple animals, weather, trade, and multiple connected settlements.

Each addition should create observable consequences or a new interaction that tests a question. Avoid a long checklist of decorative mechanics. Mandatory survival, economies, or population-scale competition can dominate behavior; treat them as separately configured experiments rather than default assumptions.

### 14.4 Do not promise world sharding yet

A single authoritative world process is the initial consistency boundary. New regions need not be new processes. Supporting multiple world servers, entity transfer between them, or simultaneous simulation writers requires a separate ownership and handoff design.

Keeping world operations, IDs, regions, and transport interfaces explicit leaves room for that work without pretending it already exists.

## 15. Browser presentation and inspection

The browser connects as a spectator or explicitly controlled visitor, not as another copy of the authoritative simulation. World mutation still goes through the server. The renderer never reads Life databases or supplies global observer state to all brains.

The first view can display terrain, simple meshes, avatar positions, object interactions, public speech, and activity labels. Use a follow-avatar mode that shows that individual's current perception separately from the operator's global camera.

Interpolation can make low-frequency committed updates appear smooth. Rendered predicted motion must not be fed back as a committed world fact. After reconnection, replace the renderer's stale baseline with a server snapshot; do not try to infer missed authoritative interactions from animation.

Appearance components should use declarative asset IDs and bounded rendering data, not arbitrary JavaScript embedded in world packets. New entity kinds receive a generic fallback appearance. Feature assets are immutable/versioned and fetched by the presentation client through the HTTP asset route.

Private decision-note or memory inspection, if added, connects explicitly to the selected Life's inspection interface. It is not a public world broadcast. A shared dashboard can display process status without becoming a combined cognitive memory.

The implementation may use Gene's supported browser output and a graphics library behind a narrow renderer adapter. No particular graphics engine or current Gene API compatibility is assumed here. Verify the actual chosen build/runtime path before treating it as supported.

## 16. Configuration, package layout, and running processes

### 16.1 A possible source layout

```text
world/
  main.gene                 explicit create/open/run, operator control
  runtime.gene              authoritative queue and logical ticks
  protocol.gene             wire schema, version checks, encoding
  server.gene               WebSocket and HTTP adapters
  persistence.gene          transactions, receipts, snapshots, recovery
  observations.gene         recipient views and replay
  modules/
    core.gene               transforms, items, containers, identity
    movement.gene           walking and its checkpoints
    conversation.gene       speech, noticeboards, audience
    garden.gene             light/moisture/growth and watering
    construction.gene       small recipes and placement
  content/commons.gene       initial regions and objects
  client/                    browser renderer and operator presentation
  tests/                     fake-clock, crash, network, invariant fixtures

life/
  ...                        independent Life implementation from life.md
  body/world_client.gene     Gene-facing world adapter, outbox, observed view
  config/                    common settings and individual seed definitions

experiment/
  config.gene                process configuration and controlled seed mapping
  launch                     optional script, not a new runtime framework
```

Shared protocol codecs or immutable library source can live in a separate package. Each process instantiates its own runtime objects. Never use a file-level global in a shared library as if it were a cross-process object.

### 16.2 Physical storage layout

```text
experiment-data/
  world/world.sqlite
  lives/aster/life.sqlite
  lives/brin/life.sqlite
  lives/cove/life.sqlite
  lives/dara/life.sqlite
  artifacts/                 optional immutable code/asset cache
```

A store path belongs to its owner. Lifetimes, journal flushes, migrations, and backups follow that owner's contract. Do not let the browser or Life processes open `world.sqlite` to make convenient writes.

Code may reside in versioned files or the proposed Gene code database. Database-backed module loading is optional; availability of the selected code/dependency revisions at restart is not.

### 16.3 Proposed launch shape

These commands illustrate application argument parsing to implement, not new built-in Gene CLI commands:

```sh
# Run independently, in separate terminals or under a small local launcher.
gene run world/main.gene -- --config experiment/world.gene

gene run life/main.gene -- --config experiment/aster.gene
gene run life/main.gene -- --config experiment/brin.gene
gene run life/main.gene -- --config experiment/cove.gene
gene run life/main.gene -- --config experiment/dara.gene
```

World and Life creation are separate explicit operations. Opening a missing or incompatible store must not seed a replacement silently. A Life started before the world becomes ready retries connection without discarding its existing state or generating a new entity.

The world configuration selects its storage, world/history identity, bind address, modules, simulation settings, and public initial content. Each Life configuration selects its own storage, identity, world binding, brain adapter, and seed reference only for creation. Model credentials stay with the Life; the world need not possess them.

### 16.4 Process health and practical controls

Expose simple process-level status: ready/recovering/paused, current world/history, selected code revisions, connected controller count, queue depth, simulation lag, pending outbox count, oldest unacknowledged event, and unresolved operations.

Keep failures linked to operation, action, event, cycle, and revision IDs. A log line saying “sent” must not be used as a durable execution result. Avoid dumping every private model context into a global world log.

Use per-process memory and execution limits, a bounded brain-call budget, and reliable operator stop controls. Do not make a new capability implementation, JIT, or production distributed scheduler a prerequisite for this local experiment.

## 17. Implementation milestones

### Milestone 1: actual process boundary and shared reality

Start one world process and two fake-brain Life processes, each with its own store. Register distinct entities; connect through real local WebSockets; observe the world; contend for one unique object; speak locally; independently stop and restart one Life.

Complete receipt deduplication and inbox acknowledgment on this slice. A single-process in-memory demo is useful for unit tests but does not complete this milestone.

### Milestone 2: durable movement and failure recovery

Implement one checkpointed world activity, walking. Use Life-local `store.commit` to group its local job, outbound request, and cognitive link. Commit physical position and world activity progress on the server. Demonstrate reply loss, network disconnection, Life crash, and world crash without duplicate activity or a rewind of another inhabitant.

### Milestone 3: four lightly seeded individuals

Replace fake brains with the configured real brain adapter, one independent context per Life. Create Aster, Brin, Cove, and Dara using the common foundation and small variations. Preserve original seed provenance and evolving dispositions. Add simple garden behavior and the noticeboard after the interaction loop works.

### Milestone 4: 3D presentation

Add a browser renderer using the same authoritative state and spectator synchronization. Demonstrate that closing/reopening the renderer affects neither the world nor the Lives. Distinguish the global camera from a Life's perception.

### Milestone 5: prove extensibility with one real addition

Add a new region using existing schemas, then one behavior module such as irrigation. Preserve old entities, receipts, and private histories. Test an old client, a pending action, an offline Life, and a restart during migration. Do not call the architecture extensible solely because a registry of feature names exists.

### Milestone 6: experimental body evolution

Let a Life save a learned procedure or replace its memory/attention organization using the existing Life contract. The world and other Lives should not need to understand that private schema change. If the change invalidates that Life's queued world work, reconcile/cancel it explicitly rather than altering the world's past.

### Integration checks before claiming support

The document does not audit the current Gene implementation. Verify the selected native WebSocket client/server APIs, cancellation and message-size enforcement, persistent-store behavior, renderer codec, normal module loading, and repeated generated-program lifetimes. Where an API is missing, add the smallest adapter rather than invent a second evaluator or silently abandon process separation.

## 18. Acceptance tests and experimental evaluation

### 18.1 Operational conformance

| ID | Scenario | Required result |
| --- | --- | --- |
| P1 | Launch world plus four Lives | Five distinct native processes, five private writer domains, stable registrations. |
| P2 | Stop one Life | Others and the world continue; stopped Life's identity is not recreated. |
| P3 | Attempt a second controller | Reject it or perform explicit takeover; stale generation cannot admit new work. |
| P4 | Close/reopen the browser | Simulation and Life continuity are unaffected. |
| P5 | Start a Life while world is unavailable | Preserve local state and retry connection; no new world/entity is invented. |
| P6 | Try to act as another avatar | Server uses authenticated binding; claimed actor data cannot redirect control. |
| W1 | Two Lives pick up one unique item | At most one succeeds; containment and inventory remain consistent. |
| W2 | An object moves/disappears after perception | Operation uses current preconditions and returns the actual outcome. |
| W3 | Run many movement requests in one program | Physical movement still consumes simulation time; no teleport by call count. |
| W4 | Commit a movement step | Position, action checkpoint, simulation time, and related events agree. |
| W5 | One sender floods commands or stalls reads | Its bounded queues do not stall other Lives or grow without limit. |
| D1 | Abort Life group before request commit | Neither local job publication nor world dispatch occurs. |
| D2 | Exit after local commit before send | Recover the same pending operation, not a new ID. |
| D3 | Lose world reply after effect commit | Resend/query returns the retained outcome; effect is not repeated. |
| D4 | Reuse operation ID with changed input | Reject conflict without effects. |
| D5 | Cancel arrives before original request | Tombstone prevents later original admission. |
| D6 | Cancel arrives after completion | Report completion/too-late, not fictitious rollback. |
| D7 | World commit fails | No success reply or uncommitted effect is exposed. |
| D8 | Life cannot persist an incoming result | Do not acknowledge it or proceed as though the local update succeeded. |
| E1 | ACK is lost | Event can replay; receiver deduplicates it. |
| E2 | Snapshot races live events | Use one consistent cut and baseline; no gap or double application. |
| E3 | Reconnect after an eligible conversation | Recover the retained message as well as current physical state. |
| E4 | Another Life's event is filtered out | Recipient sequences remain meaningful; no private data is exposed. |
| E5 | Event retention cannot satisfy replay | Explicit gap and resync; no invented history. |
| E6 | New object enters perception | Send a baseline before deltas; leaving view is not deletion. |
| E7 | Unknown optional/required schema | Ignore/preserve optional data safely; block incompatible required processing. |
| R1 | Life crashes during a walk | World follows disconnect policy; reconnect reconciles actual committed progress. |
| R2 | World crashes during a walk | Restore one position/progress point; suspend until controller reconciliation. |
| R3 | Restart world after downtime | Preserve simulation time; no implicit offline growth or movement. |
| R4 | Restart Life while world continued | Adopt current authoritative view, not an old local world snapshot. |
| R5 | Pause across a partition | Report pending remote suspension/uncertainty until resolved; never promise instant remote stop. |
| R6 | Intentional world rewind | New history branch; old-history commands do not execute. |
| X1 | Add a region | Existing coordinates, object IDs, and memories remain meaningful. |
| X2 | Add a behavior module | Use normal publication, observation, and recovery paths; no central brain response change. |
| X3 | Crash before/after feature selection commit | Restore complete old/new selection respectively, never mixed schemas and handlers. |
| X4 | Upgrade with queued old-contract operations | Preserve, migrate, reject, or defer explicitly; no silent reinterpretation. |
| X5 | Remove a feature with completed operations | Their receipts remain inspectable and cannot be replayed as new effects. |
| X6 | Renderer lacks a feature's appearance | Generic fallback; world and Life operation continues where contracts permit. |
| X7 | Public artifact contains Gene code | Reading does not execute or install it. |
| C1 | Seeds have the same available actions | Different initial interests do not create hidden competence or privilege differences. |
| C2 | Reopen an existing Life | Restore evolving state; do not reinject the seed as a new creation. |
| C3 | One Life changes its private memory schema | Others' stores and the world's rules are unchanged. |
| C4 | A Life receives no relevant event | Body and world remain operational without compulsory model calls. |

Test network faults with real separate processes: close sockets at selected points, delay receipt delivery, replay an old command, kill one process, and verify durable records after reopening. Assertions must inspect the actual item location, action count, receipt identity, and recipient inbox—not only returned status text.

### 18.2 Behavioral comparisons

Record common/individual seed revisions, initial placements, world rules/content revisions, model configuration, brain-call budgets, and selected Life code revisions. Repeat runs and swap seed-to-position assignments. Compare identical seeds as a baseline so ordinary model variability is not misidentified as a personality effect.

Look for continuity of interests, preference recall, revision after contradictory evidence, chosen places, learned procedures, information exchanged between Lives, useful restraint, and reactions to changed circumstances. Allow both divergence and convergence. Distinct writing styles alone do not demonstrate distinct persistent behavior.

World replay can reproduce recorded physical transitions under the recorded rule versions and action order. Reissuing model calls is a new behavioral run, not deterministic replay. Keep the two modes distinct.

### 18.3 A first public demonstration

Four lightly seeded Lives inhabit the small Commons. They pursue activities, encounter each other, and leave persistent changes. One Life is stopped partway through a walk while the others continue. It restarts with its own remembered experience, reconnects to the same avatar in the current world, reconciles its activity, and chooses what to do next.

Then add an adjacent region or a simple new environmental feature without replacing the world or reseeding anyone. Observe whether the new possibilities change their behavior through experience rather than through rewritten roles.

## 19. Decisions to keep visible

The following are selected design choices, not unresolved hidden defaults:

| Choice | Version-1 decision |
| --- | --- |
| Deployment | A separate world process and a separate process for each Life from the first integration slice |
| World consistency | One authoritative writer; no world sharding or replicated writers |
| Storage | Separate transactional world and Life stores; no distributed `store.commit` |
| Transport | WebSocket for commands/events; HTTP for assets; application-owned durability |
| Brain interface | Ordinary Gene code plus a short decision note, unchanged from `life.md` |
| World requests | Versioned inert data, not remote execution of brain programs |
| Initial population | Four slightly different seeds; same basic abilities |
| Perception | Local structured views; private minds; explicit operator view |
| Reconnect | Durable receipts, recipient replay, consistent snapshot, reconciliation before fresh effects |
| Duplicate commands | Same durable operation ID returns the retained result; changed payload conflicts |
| Disconnect | Avatar remains; motor actions suspend when loss is detected; no instant-stop promise |
| World downtime | Simulation pauses; wall-clock schedules use their explicit policies |
| Upgrade | Controlled quiescent selection; explicit schema/activity compatibility |
| Expansion | New content, regions, components, operations, and systems through versioned Gene modules |
| First experiment | Small commons, no mandatory survival economy, no assigned lifelong roles |

Some implementation selections still need to be made: the exact Gene transport/store APIs, supported local OS process-lock primitive, rendering library, model adapter, detailed physical constants, and deployment limits. They should implement the contracts above rather than silently redefine them. They do not require additional core Gene syntax.

## 20. Basis and references

**[L1] User-supplied Gene Life proposal.** Latest reviewed attachment `life(2).md`, updated 2026-09-20; intended companion filename `life.md`. This world design preserves its code-first brain interface, private cognitive organization, explicit state continuity, activity checkpoints, and independent-environment semantics. It explicitly supersedes its optional shared-store/local-world deployment for this multi-process experiment. Relevant sections: 1–4, 6–10, and 12–15. Source attachment SHA-256: `a3d9750da0d0f974fb646b157ae10c5ec3afb787478e3da248dd554a76bc6b43`.

**[T1] IETF RFC 6455, The WebSocket Protocol.** Basis for bidirectional framed communication, subprotocol negotiation, close/ping/pong, and secure WebSocket transport. Application receipts and world recovery rules in this document are proposed above that transport, not guarantees borrowed from it. Source: <https://www.rfc-editor.org/rfc/rfc6455.html>.

**[T2] MDN, WebSocket and bufferedAmount.** Basis for the browser API's buffering/backpressure limitations. Queue policies and replay limits here are proposed application rules. Sources: <https://developer.mozilla.org/en-US/docs/Web/API/WebSocket> and <https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/bufferedAmount>.

**[T3] SQLite, Atomic Commit In SQLite.** Basis for local transactional publication, subject to the chosen storage/durability configuration; not a claim of atomicity across independent databases and network messages. Source: <https://www.sqlite.org/atomiccommit.html>.

**[T4] IETF RFC 8259, The JavaScript Object Notation (JSON) Data Interchange Format.** Basis for the proposed text interchange format and interoperable numeric considerations. This document adds stricter bounded schemas, duplicate-key rejection, and string encoding for large identity/revision values. Source: <https://www.rfc-editor.org/rfc/rfc8259.html>.

The external references were checked while preparing this proposal. No Gene implementation, network integration, renderer, or test suite was executed. API names, message shapes, sample values, layout, and seed prompts are proposed design material rather than claims of existing support.

**A persistent world that keeps growing; independent Lives that keep becoming.**
