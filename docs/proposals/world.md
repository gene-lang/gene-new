# Gene World: An Expandable Human–AI Commons

**Status:** Experimental design proposal, not an implementation report.  
**Date:** 2026-09-21.  
**Revision:** 2 — human browser players, shared actor control, and a human-like neighborhood.  
**Companion:** The latest reviewed `life.md` (uploaded as `life(2).md`, updated 2026-09-20).  
**Decision:** One authoritative world process, one separate process per AI Life, and a browser player client for humans. Human and AI controllers use the same world-action contracts over WebSocket. Keep HTTP for pages/assets and explicit application-level receipts, replay, and reconnection for live interaction.

> One shared reality for human players and independent AI Lives. Humans act through a browser; each Life acts through Gene code in its own process. Places, possessions, conversations, and consequences persist as the world grows.

## 1. Purpose and scope

Gene World is a shared, persistent environment in which human players and independent Gene Lives can observe, act, meet, create, and change. The first environment is **The Commons**: a small human-like neighborhood with homes, a shared kitchen/gathering place, a workshop, a garden, and surrounding landscape. Aim for four Lives whose starting inclinations differ slightly—not permanently assigned professions—and human visitors who control their own persistent avatars in a browser. Prove the playable path first with one human and two fake-brain Lives.

The experiment asks whether independent Lives develop coherent ways of living through experience, including encounters with people who actually inhabit and change the same place. Humans are participants, not merely observers or sources of chat prompts. The world supplies opportunities, constraints, and actual outcomes. It does not prescribe stories, maintain everyone's beliefs, force AI replies, or require activity on every heartbeat.

Prioritize human-scale causal and social realism over photorealistic graphics: objects have uses, activities take time, materials come from somewhere, people know different things, and shared projects leave persistent results. The neighborhood is a proposed design direction, not a claim to reproduce any existing game or to validate human psychology.

The world must be expandable in three ways:

1. **Space and content:** additional regions, objects, materials, plant varieties, and public artifacts.
2. **Behavior and systems:** additional interactions, environmental processes, and reusable world-side Gene modules.
3. **Interfaces:** additional observations, operations, and discoverable interactions that both browser and Life clients can understand, present generically, ignore safely, or identify as unsupported.

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

Do not begin with distributed world sharding, a consensus cluster, arbitrary remote code execution inside the world, general VM snapshots, a mandatory plugin framework, a full survival economy, or a competitive twitch-action networking stack.

Gene-level capabilities have been removed by the project owner. This revision does not require capability literals, grants, provider catalogs, or block-level capability machinery. Keep ordinary application authentication, avatar ownership, input validation, world interaction rules, process limits, and operator controls. These are world/application responsibilities, not a replacement language-level capability system. Separate processes do not by themselves sandbox arbitrary generated code; the initial experiment runs in an operator-controlled environment.

Start locally with separate operating-system processes. Tests may use in-memory substitutes for units, but the first end-to-end demonstration must actually cross process boundaries.

### 1.3 Reading map

| Concern | Sections |
| --- | --- |
| Initial environment and slightly different seeds | 2–3 |
| Human/AI actor control, process ownership, state, and simulation | 4–6 |
| Perception, conversation, and Gene-facing APIs | 7–8 |
| WebSocket messages and durable delivery | 9–11 |
| Restart, pause, and partial failures | 12 |
| Extending content, rules, and regions | 13–14 |
| Human play, observer/operator modes, and initial deployment | 15–16 |
| Implementation milestones and acceptance tests | 17–18 |

## 2. The initial environment: The Commons

### 2.1 A small neighborhood with useful places

Use a navigable ground plane with a stylized 3D presentation. A candidate starting area is 64 by 64 world meters, represented as addressable regions rather than a permanently fixed-size array. The numbers are tunable experiment defaults, not language semantics.

| Place | Initial or next-stage contents | Opportunities |
| --- | --- | --- |
| Central commons | Table, seats, shared shelves, noticeboard, visitor arrival point | Encounters, invitations, public messages, displays, shared projects |
| Homes | Four roughly equivalent small homes with personal storage and project space | Persistent possessions, furnishing, hospitality, accumulated personal history |
| Shared kitchen / future café | Work surface, ingredient storage, simple cooking equipment, tables | Preparing and sharing food, hosting, learning preferences; add after the basic playable slice |
| Garden and park | Several plots, two or three plant varieties, water source, shade | Care, experiments, outdoor work, informal encounters |
| Workshop | Workbench, containers, reusable construction parts | Making, arranging, and repairing useful objects |
| Meadow and grove | Paths, trees, stones, partially hidden locations | Exploration, discovery, modest resource gathering |
| Future exchange point / library | Requests, offered goods, written procedures and books | Gifts, borrowing, barter, teaching, asynchronous cooperation |

Keep the four Life starts roughly comparable, with the same basic supplies and no hidden role-specific bonuses. Human enrollment starts at a defined visitor arrival point with explicitly configured supplies; obtaining or furnishing a home can be a later activity. Record layout, supplies, positions, and human participation in experiment provenance. Rotate the mapping from Life seeds to positions in repeated experiments rather than assuming symmetry eliminates every advantage.

A home is a persistent place, not just a spawn point. Returning should reveal the same possessions, unfinished work, and deliberate changes. The initial prototype may represent homes very simply; it need not have a detailed furnishing catalogue.

The map need not be completely visible to every participant. Initial geography can be fixed and intentionally designed; procedural generation is not required. When generation is added, store the generated result and generator revision so a later generator does not recreate inhabited space.

### 2.2 A few causal rules are more valuable than many isolated actions

The initial world should have a small number of interactions whose effects combine:

- Plants respond to simulated moisture and light over time.
- A shade structure changes nearby light exposure.
- A container has finite volume; filling, carrying, and emptying it have defined consequences.
- A placed object may occupy space, change navigation, or provide seating/storage.
- Building consumes or relocates a defined set of reusable parts.
- Public notes and artifacts survive the writer's departure.
- Later household features transform actual inputs: cooking consumes ingredients and produces a meal; cleaning, storage, and repair have explicit effects rather than animations alone.

These are deliberately simplified simulation rules, not a claim of realistic biology or physics. Define them as reproducible functions over committed world state and simulation time.

Do not make the environment entirely decorative. A shade structure that changes no observation or outcome offers little opportunity to learn. Equally, do not require realistic fluid dynamics before watering becomes meaningful.

### 2.3 Mild constraints, no compulsory survival loop

Begin without death, mandatory hunger, disease, or a global reward score. Use modest travel time, limited carrying capacity, shared objects, and slow environmental changes to make choices consequential.

Any participant may tend something, create an object, cook when that feature is available, talk, explore, investigate, or remain quiet. A Life does not have to satisfy a host-defined productivity quota or act as a human player's servant. A brain-invented energy or sleep model remains its private body code and state unless a separately introduced world rule gives it physical consequences.

### 2.4 Candidate initial interaction vocabulary

Operations are supplied by world modules and exposed through ordinary Gene client functions. Their names below are proposed, versioned application names.

| Family | Initial operations or queries |
| --- | --- |
| Perception | Observe current surroundings, inspect a visible object, inspect own inventory |
| Movement | Start walking to a known point/place, query progress, suspend/resume/cancel a walk |
| Manipulation | Pick up, put down, move a reachable object into a container; offer/accept a transfer when implemented |
| Garden | Fill a container, water a plant, plant into a suitable plot |
| Construction | Assemble or disassemble a small declared recipe; place its result |
| Communication | Speak locally, read/write a noticeboard, inspect an accessible thread |
| Household additions | Use storage and seating, prepare a recipe, serve a meal, clean or repair when their feature modules are installed |

The first working slice needs browser-controlled movement, one unique shared object, local speech, and persistent observation alongside two independent fake-brain Lives. A drop-and-pick-up exchange can demonstrate shared reality before a dedicated offer/accept system exists. Cooking, garden, furnishing, and construction follow that path; they are not all prerequisites.

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

All four may garden, cook, investigate, build, learn procedures, socialize, or work alone when the corresponding world features exist. Do not preassign friendships, rivalries, fabricated memories, or expertise. Keep the seed prompts short enough that the individual differences remain mild.

### 3.4 Experiment identity

Record the common prompt revision, individual seed, creation world revision, initial position, model configuration, and initial body-code revision. Give each Life a distinct stable ID independent of its display name.

A controlled restart preserves that ID. An experimental clone is an explicit new Life with a new store and identity; it does not silently attach as a second controller of the original avatar.

## 4. Process architecture and ownership

### 4.1 Required topology

```text
             Optional launcher: starts/stops native processes

+----------------------------+        +--------------------------+
| World server process       |<-- WS->| Life A: brain/body/store |
|                            |        +--------------------------+
| authoritative simulation   |<-- WS->| Life B: brain/body/store |
| actors, objects, activities |        +--------------------------+
| participants and sessions  |<-- WS->| Life C: brain/body/store |
| durable store and receipts |        +--------------------------+
| views and conversation     |<-- WS->| Life D: brain/body/store |
| HTTP assets + WebSocket    |        +--------------------------+
+-------------+--------------+
              | HTTP + WebSocket
              +---------------------------+
              |                           |
+-------------+--------------+  +---------+--------------------+
| Human browser player       |  | Observer/operator browser    |
| own avatar; input and chat |  | explicit separate mode       |
| renderer; pending commands |  | inspection; host controls     |
+----------------------------+  +------------------------------+
```

The world and each AI Life run in separate operating-system processes, each with its own runtime and writer domain. A human runs the browser client; no additional Gene Life process or model call is required for that human to play. The browser can use ordinary browser workers internally without changing this ownership model.

The world does not call an LLM to advance simulation or decide for an inhabitant. Each Life invokes its own replaceable brain adapter. A shared model service does not imply shared conversation state. Human and AI actions are processed while other brains are thinking, idle, or unavailable.

The launcher is convenience infrastructure, not a global mind. The world can continue with zero connected browsers. Closing a player browser detaches only that controller and invokes its avatar's documented disconnect behavior; it does not stop the world or any Life process.

### 4.2 Actors and controllers

An **actor** is a persistent embodied entity in the world. A **participant** is the registered identity entitled to control it. A **controller** is the currently attached client that submits its actions.

| Participant | Controller | Decision interface | World-facing interface |
| --- | --- | --- | --- |
| AI Life | Its independent Gene process | Brain note + executable Gene program | Versioned world commands and queries |
| Human player | Browser player session | Keyboard/pointer controls, interaction panel, chat | The same versioned world commands and queries |
| Observer | Read-only browser session | Camera, inspection of the authorized view | Queries and presentation subscription only |
| Operator | Separately admitted administrative session | Explicit experiment controls | Separate administrative operations |

Initially, each participating human or Life has one actor in a given world history. Humans receive their own avatars; ordinary play does not possess an AI Life, read its mind, or replace its controller. Cross-kind takeover is outside the first release.

Equivalent actions by equivalent actors obey the same proximity, possession, time, resource, and world-access rules. Controller kind may determine transport/session behavior and whether a model budget exists; it must not secretly make AI requests physically omnipotent or give browser requests priority. Differences such as a held item, a learned recipe, or ownership must be explicit world state.

### 4.3 State ownership

| State | Authoritative owner |
| --- | --- |
| World/history, regions, objects, simulation time | World process |
| Human and Life actor positions, orientation, inventory, held objects | World process |
| Physical activity and committed progress | World process |
| Public artifacts, world-local speech, eligible audiences | World process |
| Registered participant-to-actor mapping, current control generation | World process |
| Human world profile, possessions, retained in-world history and receipts | World process; browser copies are caches |
| Life identity, private memory, notes, cognitive code/data | That Life process |
| Life intentions, schedules, local jobs, outbound requests | That Life process |
| Life's last observed world state | That Life process; explicitly a view, not authority |
| Browser pending-command journal, installed view, unsent drafts | Browser local storage/cache under its documented recovery limits |
| Render interpolation, camera, selection, temporary input | Browser; transient, not authoritative world state |

Use one transactional world store and a separate private transactional store for each Life. Only the owner opens its store for mutation. No browser or Life reads or writes the world database directly. SQLite can supply local transactions; it does not turn these stores into a transaction across a socket. [T3]

Browser storage is not the sole durable home of human inventory, accepted speech, or completed actions. Clearing a cache must not delete the participant's avatar or cause a completed exchange to run again. Section 10.7 defines the pending-command journal; section 11.4 distinguishes human history retention from a browser acknowledgment.

### 4.4 Identity, attachment, and control ownership

The local operator provisions participants and stable actor mappings. Existing Life registrations map a `life_id`; human registrations map a `player_id`. Both receive a server-owned `participant_id`. Enrollment is idempotent for that registration, and reconnect never creates a new actor. Display names are labels, not authentication or database keys.

Native Life clients use operator-issued connection credentials. Browser players establish an application session through the HTTP host, then attach WebSocket with that session. Keep credentials out of URLs, public assets, examples, and logs. Use a same-origin player page and validate browser Origin and session identity on the server. The initial loopback deployment is not a public unauthenticated game server. Section 9.4 gives the transport contract.

The server derives participant and acting entity from the admitted connection. An arbitrary `actor_id`, player name, or `life_id` in command data cannot redirect control. Inspecting another actor never grants control of it.

Allow one mutating controller per participant/actor. A second live controller is rejected or offered read-only mode. A browser tab may explicitly request takeover of the same human participant; it never steals control merely by loading a page. Every successful attachment increments a persistent **control generation**. Reject older-generation commands, including queued commands not yet admitted, after takeover. Accepted work retains its real state and follows the suspension/reconciliation contract. Close/expiry handling checks its connection generation: an old socket closing after takeover cannot detach the new controller or suspend its newly admitted work.

Refresh may briefly overlap the old browser connection. The UI can wait for disconnect detection or let the user explicitly take over; do not create another avatar to avoid this case. Read-only tabs do not control movement, acknowledge away essential controller history, or invalidate the writer's session by merely observing.

Each Life also holds its own private-store writer claim. The world holds a separate exclusive world-store claim. One controlling connection and one local writer solve related but different problems.

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

The world validates actions from both human and AI controllers against its current state. Neither a browser nor a Life can move an avatar by declaring a new authoritative position, create inventory by editing a local record, or water a distant plant merely because it once observed it.

Initial invariants include:

- A unique movable item has exactly one physical location or containing entity.
- Containment is acyclic, respects capacity, and does not duplicate inventory.
- Movement obeys the selected world geometry and activity rules.
- Required proximity and possession are checked when the effect is applied.
- A construction transaction consumes/reserves the actual parts and creates its result together.
- A failed atomic world operation leaves no half-applied physical change.

A human and a Life—or any two actors—may act on the same earlier observation. If both try to pick up the same container, the world serializes the attempts; at most one succeeds, and the other receives a factual failure. No world-wide cognitive lock is needed. An animation or an optimistic inventory highlight is never the operation result.

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

Start with fixed logical world steps, for example 100 simulation milliseconds, and near-real-time progression for human play. Render interpolation is independent; model inference has no fixed per-tick requirement. Persist a logical step before exposing it as authoritative. Accelerated experiment time is an explicit world setting visible to all clients, not a private speed multiplier for one Life.

Simulation advances while the world is running even when every brain is idle. It pauses during world process downtime in version 1; no implicit fast-forward after restart. If overloaded, reduce effective simulation speed and expose the lag rather than silently skipping causal updates. A later fast-forward policy must define what it preserves.

A Life-owned routine using this world's simulation clock may see elapsed simulation time while that Life was offline. Its selected controller must explicitly choose bounded catch-up or rebasing its checkpoint without retroactive credit. For example, a sleep routine cannot silently assume the world clock paused with its own process. Qualify retained clock checkpoints with world/history identity; a world branch is not another elapsed interval on the same clock.

Slowing or pausing the world is a world operation. Pausing one Life is not.

### 6.2 World-owned physical activities

A walk is a world activity with a destination, stable action ID, rules revision, current progress, and a recovery contract. Once admitted, it advances without model calls or per-frame client commands. A human click-to-move and a Life's `start_walk` submit the same `movement.walk_to` operation. The Life retains a corresponding local job; the browser shows the action reference and progress from the same world record.

For version 1, permit one locomotion activity per avatar. A new walk while another is active is rejected as busy unless the caller explicitly cancels/suspends or uses an operation whose documented replacement semantics cover both actions. Do not make a new command silently discard an earlier commitment.

A path may be recomputed when geometry changes. No route produces a recorded blocked/failed outcome rather than an endless hidden retry loop. Changes to physical progress and its outcome are committed by the world, not by the Life's cognitive database.

### 6.3 Connection loss is not death or immediate certainty

The world detects an orderly close or an unresponsive controller through its configured liveness policy. Until detection, already admitted work can make additional committed progress. A disconnected browser or Life must not assume its actor stopped at the last position that client received. Do not rely on a page-unload callback as the only stop mechanism.

Initial policy:

| Condition | World behavior |
| --- | --- |
| Brief loss before it is detected | Previously admitted activities may continue; no guarantees of instantaneous stop. |
| Controller close, expired lease, or explicit detach | Suspend that avatar's ongoing motor activities at the next safe committed step. |
| Human or Life controller absent | Keep its avatar, possessions, and public artifacts; the environment and other participants continue. |
| Reconnect | Reconcile action status and current entity state; do not automatically resume all prior activities. |
| Explicit resume after synchronization | Continue compatible suspended activity from committed progress under the same action ID. |

Suspending movement does not cancel environmental processes such as plant growth. The initial world has no mandatory survival damage while an inhabitant is offline. Presence is a transport/operational fact, not a forced psychological description such as sleeping.

At world restart, restore unfinished avatar-controlled motor activities as suspended until their controller reconciles. A browser offers explicit Resume or Cancel; a Life decides through its own code. Autonomous world systems resume from saved simulation time. The selected policy must be visible in activity documentation. Closing a player browser is therefore not world shutdown, but it also does not promise that this actor continues walking forever unattended.

### 6.4 Fairness without a universal mind scheduler

Each Life can deliberate independently. Bound queues per participant and process human and AI commands fairly. A round-robin ready queue is sufficient initially; record acceptance order in test traces. Rate limits and domain constraints apply to both controller kinds. A Life cannot gain unlimited physical throughput by issuing a loop of requests, and a browser cannot do so by flooding clicks.

Use comparable model settings and inference budgets for seed comparisons. Do not wait for every Life to finish a thought before the world can advance. Model latency is an experimental variable to record, not a reason to freeze all inhabitants.

### 6.5 Human movement and control responsiveness

Use click-to-move first. The browser selects a point/place and displays a pending marker; the server resolves navigation and accepts or rejects the walking activity. The marker is not evidence of arrival. Opening an inventory panel or moving the camera does not pause the shared simulation.

Stop/Cancel is an explicit operation tied to the active action, with the same outcome races as AI cancellation. A later click does not silently create two walks. The first UI waits for cancellation or uses a documented atomic replacement operation before starting a new destination.

Direct keyboard locomotion is a later input profile, not required for the first playable slice. If added, it sends sequenced **intent** (direction/buttons) scoped to the current control generation, never a claimed authoritative position. The server checks speed/collision, rejects stale samples, and clamps how long an input can remain valid. Use a short documented expiry independent of the longer connection lease; lost key-up, blur, hidden tab, or disconnect must not leave continuous movement active. Clear input on takeover and reconnect. Do not replay stale input samples from the durable command outbox or after a world pause. Checkpoints still record the resulting authoritative physical state.

## 7. Perception, conversations, and shared artifacts

### 7.1 Participants observe views, not the whole database

The world computes a participant's observation view from the actor's actual location and the selected perception/access rules. Begin with nearby visible objects, own inventory, accessible signs, local speech, and known action outcomes. Apply the same underlying visibility rules to human players and AI Lives, while allowing different presentation: a rendered scene for the person, structured observations for the Life.

The world does not send another Life's decision notes, private memory, or internal rest model. Those records need not reside in the world process. A player's free camera is not an authorization to inspect hidden interiors, inventories, or objects outside its server-selected view; camera configuration and visibility must be compatible.

Maintain separate concepts:

- **Current observed view:** entities and attributes this actor can presently perceive.
- **Remembered observation:** an earlier view retained by a Life or shown in a player's retained history with its time and source.
- **Observer/operator inspection:** an explicitly broader view, not ordinary player knowledge and never silently fed into every brain.

An entity leaving view is removed from the current view; that does not claim it ceased to exist. New visibility requires a complete baseline before interpreting deltas. Object inspection and interaction discovery use the same server-side view/access rules; guessing an entity ID must not reveal hidden fields.

### 7.2 Offline observation policy

Initially, an offline human or Life controller does not passively hear every future local conversation. Finalize the audience of local speech at its world commit using location and declared listening/presence rules. Once an event belongs to an audience, retain it for that recipient through ordinary reconnection.

A noticeboard is persistent: a human or Life can later visit and read its retained posts whether or not it was online when they were written. Direct addressed mail, if added, has its own explicit retention and delivery contract.

This avoids reconstructing yesterday's audience from today's positions or silently giving an absent Life omniscient history.

### 7.3 Conversations are ordinary world events

Speech and posts carry a speaker ID, conversation or channel ID, optional thread/reply reference, text, operation ID, and committed simulation time. The world records the action of speaking and its eligible audience; each recipient decides whether and when to think about it.

Human chat sends ordinary world speech; it is not an instruction to the server to force an AI reply. Lives decide whether and when to respond, and humans can continue moving, inspecting, or speaking to others meanwhile. Show server-confirmed delivery separately from any later response. Do not invent typing/thinking indicators unless the Life explicitly publishes that public status.

Do not wake every brain for every acknowledgment. Coalescing and silence belong to each Life's attention policy. Its own outbound echo should not automatically provoke a new response to itself.

A public assertion is authored content, not a world-engine fact. A Life can remember who said it, test it, disagree, or ignore it. The world owns the delivered statement, not a universal belief that it is true.

### 7.4 Code sharing without automatic execution

A noticeboard artifact may contain text, a sketch, a procedure, or Gene source with an immutable revision/hash. Reading another inhabitant's program remains a data operation. It does not evaluate the code, install a callback, or alter the reader's cognitive organization.

A Life may explicitly inspect, test, adapt, and select that code locally. A browser displays an artifact as inert text or a supported declarative representation; it does not execute embedded Gene, HTML, or JavaScript. Humans may contribute notes or procedures through the same artifact operations, but submitting source does not install it on the world or in another participant. This makes procedure exchange possible without turning messaging into remote program execution.

## 8. Gene code stays the brain–body interface

### 8.1 Different decision interfaces, one action contract

```text
Human → browser controller:
    pointer/keyboard input, interaction forms, chat

Brain → Life controller:
    decision note + ordinary executable Gene program

Either controller → world process:
    versioned data messages describing the same queries and world operations
```

For example, clicking **Pick up** and calling a Gene `pick_up` helper both submit `object.pick_up` with an object ID. The world derives the acting entity from the connection and runs the same handler. No model invocation is required for a human input, and no new brain response type is required for a new world interaction.

A JSON command on a socket does not require the brain to emit a JSON tool call. The brain writes loops, functions, calculations, memory updates, scheduling logic, and ordinary library calls. Its client adapter translates calls into messages and reconstructs outcomes. Human UI controls construct those messages directly.

The world never evaluates arbitrary Gene source on its normal action channel. World rules are operator-selected Gene modules; a proposed feature or shared script remains inert until explicitly selected through the extension workflow.

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
local job + optional owning work reference + outbound world request
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

### 8.5 Discoverable interactions for both controllers

Expose a read-only operation catalogue and an actor-scoped interaction query. A query for a visible object can return supported operation IDs/versions, input schemas, display labels, documentation, current availability, and safe reasons when unavailable. A result is a description, not a reservation or an authority token; check preconditions again on application.

An illustrative interaction description is:

```json
{
  "interaction_id": "take",
  "label": "Pick up",
  "operation": "object.pick_up",
  "contract_version": 1,
  "target": {"object_id": "watering-can-7"},
  "availability": {"enabled": true},
  "form": {"kind": "confirm"}
}
```

The browser maps supported form primitives to ordinary controls. A Life receives equivalent documentation and uses its ordinary Gene client library, including a generic call for newly discovered operations before a convenience wrapper exists. This wire schema describes the environment's actions, not the brain's allowed forms of reasoning.

Begin with labels, confirmation, bounded text/numbers, choices, and visible-object selection. Treat remote descriptions as data; they contain no executable UI code. Unknown appearance can use a placeholder. An unsupported input form is visibly unavailable until the client understands it, not silently guessed. New features must update discovery for both humans and Lives; a generic control can precede custom graphics.

## 9. WebSocket as transport

### 9.1 Why use it here

Choose WebSocket for version 1. It supplies a bidirectional connection with message framing and protocol-level close/ping/pong behavior. Native Life clients and the browser can use the same transport family. It is suitable for commands going toward the world and observations going back without tying a response to the lifetime of one HTTP request. [T1]

Use ordinary HTTP for the browser page, static assets, documentation, and large immutable asset blobs. Do not send a multi-megabyte model or texture through the control queue simply because a socket exists.

This is initially a social, building, and everyday-activity world, not a low-latency competitive action game. WebSocket is the selected starting transport for real human play as well as Life processes. WebRTC, UDP simulation protocols, a message broker, and an RPC framework are not prerequisites for the first neighborhood. Keep serialization and command handling separate from the WebSocket adapter so another transport can be added without changing world semantics.

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
| `participant_id` | Stable server registration used for controller ownership and operation deduplication; human or Life |
| `participant_kind` | Server-known `human` or `life`; observers/operators use separate session roles |
| `life_id` / `player_id` | Corresponding stable external individual identity; applicable to that participant kind |
| `entity_id` | Stable embodied actor assigned to that participant in this history; no additional actor identity is required |
| `control_generation` | Current controlling connection generation; invalidates stale controller entry |
| `operation_id` | A durable logical mutation request, stable across resend and reconnect |
| `request_id` | Correlation for a query/transport exchange; not proof of a world effect |
| `stream_id` / `event_seq` | A participant's filtered durable observation stream and position; not render telemetry |
| `world_revision` | Committed authoritative state revision, not a blanket precondition on every action |
| `rules_revision` | Selected world behavior/configuration revision; changes only when those semantics change |
| `owner_id` / `owner_generation` | Optional controller-local work ownership; interpreted within the authenticated participant, not a global goal schema |

Ordinary ticks can change `world_revision` without changing `rules_revision`. Do not invalidate every pending thought because another avatar moved. Use explicit target preconditions and relevant operation/rule compatibility.

### 9.4 Connection lifecycle and browser attachment

```text
connect
→ authenticate and negotiate protocol
→ resolve registered participant, actor, and session role
→ acquire the writer's new control generation (player/Life controllers only)
→ obtain current operation/feature contracts
→ replay and synchronize the permitted view
→ reconcile pending requests and activities
→ declare this controller ready for new mutations
```

The server admits no ordinary mutations before readiness. Recovery queries and documented cancellation remain available during synchronization. Unsupported required versions produce a structured incompatibility rather than execution under an assumed meaning.

A native Life `hello` identifies its configured world/history and registered Life, presents its connection credential, and supplies its last durable cursor. A human browser first establishes a server-issued HTTP application session. Its `hello` selects the configured world and supplies resume metadata; the session, not a client-supplied player name, establishes the participant.

For the first local deployment, use same-origin HTTP/WS hosting and an operator-provisioned login or invitation. The session cookie is HTTP-only, has an appropriate same-site setting, and is Secure for HTTPS deployment. Validate the expected browser Origin and session before releasing participant data or granting control. Browser and native handshake differences are adapter concerns; they feed the same admitted-participant model. The browser WebSocket constructor exposes URL and subprotocol selection, not an arbitrary request-header API; use the HTTP session rather than inventing an Authorization-header argument. [T5]

Never put credentials in a URL, use them as a subprotocol name, embed them in public JavaScript, or log them. Model credentials remain only in the relevant Life process. Bound unauthenticated handshakes and payloads; successful transport upgrade alone does not authorize commands. Remote deployment requires explicitly configured HTTPS/WSS and a reviewed application login/deployment policy.

An illustrative Life welcome:

```json
{
  "v": 1,
  "kind": "welcome",
  "world_id": "commons-01",
  "history_id": "history-01",
  "server_epoch": "boot-7f24",
  "participant_id": "participant-aster",
  "participant_kind": "life",
  "life_id": "life-aster",
  "role": "controller",
  "entity_id": "avatar-aster",
  "control_generation": "12",
  "stream_id": "events-participant-aster",
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

A human welcome has `participant_kind: "human"`, its `player_id`, and its own `participant_id`/`entity_id`; otherwise it uses the same synchronization and action contract. Observer/operator sessions receive only the role and view the host admitted, not a controlling generation merely because they requested one. All examples describe proposed fields, not a released protocol.

The welcome also supplies limits, simulation time/status, and the operation catalogue or its digest. Metadata never auto-loads executable code into a browser or Life. An existing writer conflict is shown as **Already controlled elsewhere**; the second human tab may observe or explicitly take over that same participant.

### 9.5 Message families

| Kind | Direction | Purpose |
| --- | --- | --- |
| `hello`, `welcome`, `ready` | Both | Identity, negotiated role, controller ownership, synchronization |
| `query`, `query_result` | Both | Filtered inspection, catalogue/interaction reads, operation-status reconciliation |
| `command`, `receipt` | Both | Durable world mutation or activity request; same for human and Life |
| `event` | World → participant | Filtered durable observation, conversation, or action outcome |
| `ack` | Participant → world | Highest consecutively installed/persisted event under the client's retention contract, not proof of reading or cognition |
| `sync_begin`, `snapshot`, `sync_end` | World → participant | Consistent baseline and replay boundaries |
| `resync_required`, `history_gap` | World → participant | Explicit recovery from missing/incompatible view or history |
| `telemetry` | World → browser / opted-in client | Replaceable presentation samples based on committed state; separate sample sequence and baseline |
| `heartbeat` | Both | Application liveness/lease progress; no brain call implied |
| `error` | Both | Structured protocol, input, or compatibility problem |

Operation names remain extensible: `movement.walk_to`, `object.pick_up`, `garden.water`, `conversation.say`, and `core.cancel` are examples. New operations do not add brain-response types. A later keyboard-input profile can add `input` messages only after its expiry and reconciliation contract exists; version 1 does not silently accept them as durable commands.

Commands/outcomes, historical observations, and visual samples share a socket initially but retain different identities and retention policies. Telemetry can be coalesced before send; committed events and receipts cannot be silently replaced. Control messages are scheduled ahead of optional telemetry before enqueueing bytes; they cannot overtake bytes already in the connection.

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
(world_id, history_id, authenticated_participant_id, operation_id)
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

For a validated, previously unseen human or Life command, the world performs the same bounded serialized transition:

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

The tombstone reserves the target ID for the same authenticated participant and history. If an expected semantic fingerprint was recorded, a later mismatching command is a conflict; a matching command receives the cancelled result without executing. With no fingerprint, the ID remains cancelled rather than being bound to a new command. This prevents an in-flight original command from starting after cancellation wins the race. A different participant cannot cancel it merely by guessing the ID.

Stopping runtime execution is not identical to abandoning a Life's intention. For temporary pause, use activity suspension and preserve progress. A graceful Life shutdown waits for its documented suspension/detachment result when reachable; otherwise it records uncertainty and the world's disconnect policy eventually applies.

### 10.6 No implicit multi-command transaction

A Gene loop issuing five separate world operations can make partial progress. The world does not turn a whole brain program into an atomic remote transaction.

When an invariant genuinely needs atomicity—such as moving an object from one container to another or consuming parts to assemble one object—supply a world operation that commits that invariant locally in the world store. Do not add arbitrary remote transaction callbacks to solve every multi-step plan.

### 10.7 Browser pending commands and refresh recovery

A human action uses `operation_id`, not the transient query `request_id`, as its logical identity. Before sending a mutation, write its exact semantic payload and identity to a small persistent browser journal (for example, IndexedDB behind a browser-storage adapter). Do not send before that local write succeeds. Mark it locally queued, awaiting receipt, accepted/running, or terminal based on observed facts. Browser journal persistence is a proposed client contract to implement and test, not a substitute for the world store.

After refresh/reconnect, recover the same participant, synchronize, and query uncertain operation IDs. Resend an unresolved request only with the same ID and semantic payload under the current connection generation. A missing reply or spinner timeout must not create a second gift, pickup, post, or recipe. Distinguish a deliberate new user action from a retry of the previous one. An outbox entry never sent before disconnect is not automatically current intent: show it as unsent, recheck its assumptions, and require confirmation or cancellation before first transmission after reconnect.

If browser storage is cleared or unavailable, reconnect to the same server-owned avatar and inspect retained operations/history; do not replay a guessed action sequence. Unsaved drafts may be lost, which the UI should state. If journaling fails before a new mutation, report the failure and do not silently downgrade to an unsafe send. Pending journals contain no model or connection credentials.

The server's current action list and recent operation receipts are available to the authenticated owner, allowing a new tab or device to see work that its own cache did not create. A rejection is terminal for that operation ID. Changed input, a new target, or a revised rules assumption is a new user decision with a new ID—not a rewritten retry.

Apply the same handling to chat messages and object transfers. UI **accepted** is not the same as **completed**, and **sent to the socket** is neither. The browser never alters authoritative inventory or declares a successful action solely from optimistic rendering.

## 11. Events, snapshots, reconnection, and backpressure

### 11.1 Separate durable observations from render telemetry

The world owns an ordered durable observation stream for each participant, human or Life. Audience is determined at the event's committed moment. Recipient-local sequences keep filtering from creating unexplained holes or revealing another participant's unseen events. Observer telemetry is a separate subscription, not the actor's authoritative inbox.

Durable events include admitted action outcomes, eligible conversation messages, important environmental observations, visibility changes, and rule/history changes. Fine-grained interpolated transforms for the browser can use a separate replaceable telemetry stream.

No Life needs an event for every millimeter of another avatar's movement. The perception module may sample or coalesce position observations before assigning durable event IDs. Once an event is committed to a recipient stream, it is not silently replaced with unrelated content under the same sequence.

### 11.2 Event example

```json
{
  "v": 1,
  "kind": "event",
  "world_id": "commons-01",
  "history_id": "history-01",
  "stream_id": "events-participant-aster",
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

A Life persists the event before acknowledging its durable cursor. Storing it does not mean the brain considered it or completed a commitment. A browser acknowledges only after installing the ordered batch under its client-storage contract; that acknowledgment does not mean a person read it and never authorizes deletion of the sole retained human transcript. Section 11.4 defines the difference.

Deduplicate by stream identity and sequence/event ID, and correlate direct receipts with events by operation/action identity. Receiving both must not create two completed jobs or two copies of the same speech.

### 11.3 A consistent reconnect sequence

Reconnection must recover historical messages as well as current position. A fresh snapshot alone cannot recreate an unacknowledged conversation.

Use this sequence:

1. Authenticate and establish the new control generation, but do not yet admit new ordinary mutations.
2. Read the participant client's last valid event cursor A; a browser without usable local history requests retained server history and a fresh baseline instead of claiming it has all prior events.
3. At a serialized world boundary, capture a filtered snapshot at world revision R and recipient stream cut C. Pin the required replay range while synchronization proceeds.
4. Send `sync_begin`, then the retained events after A through C in ordered, bounded pages. Persist these as observations even when a newer snapshot supersedes their old view-state changes.
5. Send the complete snapshot associated with R/C, including current visible entities, own avatar/inventory, relevant actions, world/rules metadata, and view-generation identity.
6. The client atomically installs the complete snapshot and sync metadata after the required preceding events have been stored/installed under its contract. A Life makes this a local durable commit. A browser publishes the complete view to its UI only after the baseline is complete. Neither reapplies older positional deltas on top of it.
7. Deliver subsequent events after C. Their view deltas name the expected baseline/entity revisions; a mismatch triggers resynchronization.
8. Reconcile outstanding operations, acknowledge the persisted cursor, and enter ready state.

The world continues serving other participants and ticking during this process. Capture the cut consistently, but do not hold an open world transaction while sending pages over a slow socket. Bound the pinned range/snapshot lifetime; if it expires, restart synchronization explicitly.

On a required event gap, do not advance the acknowledgment past it. A client may preserve an unknown optional event as opaque data and acknowledge it; an unknown required schema prevents affected processing until upgraded or explicitly resynchronized under a compatible contract.

### 11.4 Retention and gaps

Retain unacknowledged essential recipient events in the initial experiment. Keep operation receipts/tombstones under their separate history-lifetime anti-replay rule. A world snapshot does not replace a conversation or proof of an exchange.

For a native Life, an acknowledged event may later be pruned under a documented policy once its relevant history is durably retained in that Life's store. For a human player, browser caches are not the permanent transcript: retain accepted in-world messages and the participant's eligible conversation/history records on the world server under an explicit retention policy independent of browser ACKs. An operator or secondary read-only tab cannot acknowledge away another controller's essential history.

If an explicit maintenance action or later bounded-retention policy removes required history, send `history_gap` with the missing range and a current snapshot. Record/show the gap rather than inventing lost dialogue. A human reconnecting from a new device can retrieve retained eligible history even without the old browser's cursor. Do not replay the entire world's conversation to compensate for a missing cursor.

Disk pressure produces a visible maintenance/failure state, not silent deletion of undelivered essentials. A client cursor ahead of its world stream is a consistency/history error. A new `server_epoch` does not reset durable sequences or turn old actions into new requests.

### 11.5 Connection health and flow control

Use WebSocket ping/pong in the native/server binding where exposed, and application heartbeat messages for client progress and lease information. Browser JavaScript does not expose protocol-level ping/pong frames directly; its code uses the documented application heartbeat instead. Neither kind is a durable event acknowledgment or evidence that a person or brain is making progress. [T1, T5]

Candidate local defaults are a heartbeat every 15 wall-clock seconds, a controller expiry after 45 seconds without valid liveness, and bounded reconnect backoff with jitter. These are tunable operational values. World simulation time must not determine network liveness.

The standard browser `WebSocket` API does not provide automatic receive backpressure, and `bufferedAmount` measures queued outbound bytes rather than durable receipt. Therefore the application must bound work and buffering itself. [T2]

Suggested starting limits, to be measured rather than treated as permanent laws:

| Limit | Initial default |
| --- | --- |
| Decoded command/event message | 256 KiB |
| Live outbound socket queue | 1 MiB or 256 messages, whichever is reached first |
| Replay page | At most 100 events and within the message-size limit |
| Outstanding ordinary mutation admissions per controlling participant | One until its admission receipt, excluding dedicated recovery/cancel control; activity completion can occur later |
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
| `world_participants` | Human/Life kind, registered player/Life identity, actor mapping, and control-generation counter |
| `world_player_sessions` | Admitted human session identity and role; revocation/expiry metadata, never model credentials |
| `world_actions` | Accepted long actions, progress, status, selected implementation/rules revision |
| `world_operations` | Semantic request, receipt, result/status, cancellation tombstone |
| `world_events` / `recipient_events` | Authoritative changes and recipient-indexed durable observations |
| `world_artifacts` | Persistent notes, public content, source artifacts, and references |
| `world_conversations` | Accepted messages, commit-time audiences, and retained human transcript history independent of browser caches |
| `world_releases` | Selected world modules, schemas, migrations, and immutable asset references |

These are responsibilities, not a required table count. A small transactional store can combine collections; retained conversation history may be an indexed projection of the event log rather than a second authoritative log. Keep the world journal as committed data changes, not a list of programs to execute again.

Each Life store continues to preserve the information in `life.md`, plus its world binding, durable outbox, operation/action links, event cursor, and last synchronized observed view. Its own cognitive schema remains freely replaceable.

### 12.2 World restart

Before accepting controllers or advancing simulation:

```text
Acquire exclusive world-store ownership.
Validate format, selected code/assets, and recovery state.
Restore the latest committed world state and activity progress.
Create a new server epoch; invalidate old connection leases.
Preserve world/history IDs, entity IDs, operation records, and event cursors.
Expose suspended/reconciling motor activities and ready snapshots to returning human and Life controllers.
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
| Close observer browser | No effect on Life or world lifetime. |
| Close/lose player browser | Detach only that human controller; its avatar remains and motor activity follows the disconnect policy. |
| Open a player menu or pause local rendering | Does not pause the shared world; explicit activity suspension is a separate action. |

A requested pause is not settled until its documented local work and reachable world suspension have settled. During a network partition, report `pause_pending_remote` or equivalent uncertainty rather than claiming the remote motor is already stopped. Lease expiry bounds later world-side activity under the chosen disconnect policy.

### 12.5 No distributed rollback

If a Life commits an outbound request but the world rejects it, retain the failed request and repair/reconsider the cognitive expectation. Do not roll back an entire private history.

If the world commits an effect and the Life crashes before receiving it, receipt lookup and event replay repair the local view. Do not undo the world merely to match the stale Life database.

A consistency-preserving experiment backup can pause all mutating controllers, reconcile admitted operations and Life outboxes, and save the authoritative stores with a manifest of world/history IDs and cursors. Human accepted state lives in the world store; browser caches are not additional authoritative snapshots. Unsent human drafts are outside the world backup. Arbitrarily restoring an old world database while leaving newer Life stores active is not ordinary recovery. An intentional rewind creates a new `history_id` or a new world, refuses old-history commands, and requires explicit branch/rebinding policy. Never reuse operation identities in a rewound history while pretending it is the same live timeline.

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
| Browser refresh after sending, before receiving a receipt | Restore the pending ID and query/resend that same request; do not apply the human action twice. |
| Browser storage is cleared | Restore the registered actor and retained server history; unsent drafts may be lost, accepted world effects are not. |
| Old world snapshot is restored intentionally | New history branch; never transparently replay old-history commands. |

### 12.7 Browser reconnect, refresh, and logout

Refresh and network reconnection attach to the same human participant. Restore identity from the server-issued session, resolve any writer conflict, install the current filtered snapshot, recover eligible history, and reconcile the pending-command journal before fresh mutations. Never restore old browser positions, inventories, or predicted states into the world.

Show **Connecting**, **Synchronizing**, **Connected**, **Controlled elsewhere**, or **Disconnected** based on actual protocol state. Disable mutating controls until ready; retain editable unsent text separately. When a saved activity is suspended, show its target and actual progress and offer Resume/Cancel rather than silently continuing it. Closing the browser does not abandon a Life's commitments or stop other actors.

Logout ends only the human application session and requests orderly detach; when the socket cannot deliver that request, liveness expiry settles control under the same disconnect rule. The world retains the player registration, avatar, possessions, and accepted history for a later login. Ending a session is not deletion of a participant. Model-driven takeover of a disconnected human is not part of version 1.

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
| Human interaction descriptors | Labels, supported form primitives, object targets, and availability queries for browser controls |
| Documentation/client helpers | Gene helpers for Lives and the same operation contracts for browser interactions |

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

The operation registry is a world-server implementation detail. The Life sees documented Gene functions and a discoverable catalogue, not a forced tool-response format. The browser uses the same operation identity and validation through its controls. An extension must not introduce a separate browser-only mutation path that bypasses ordinary world transactions.

### 13.5 Initial activation policy: pause, migrate, select

Use one active world organization initially. A controlled world pause or stop/start migration is sufficient for version 1; uninterrupted hot replacement is an enhancement.

For a world upgrade:

1. Store the candidate modules/assets and validate their dependency closure, schemas, and operation catalog without publishing them.
2. Test migration against a copy of committed state and representative active action records.
3. Stop ordinary mutation admission and world ticks; settle or checkpoint affected world activities. Keep status/recovery connections responsive.
4. Determine the disposition of queued commands and suspended actions. Preserve compatible work, explicitly migrate it, reject/suspend it for reconsideration, or defer the upgrade. Never run old-layout code over new-layout data silently.
5. Atomically commit migrated data, compatible action/registration records, the selected manifest, and the new rules revision.
6. Publish the new in-memory dispatch tables as one control-loop transition, emit `world.rules_changed`, and resume simulation only when the committed selection can run.

The world may briefly pause while independent Life processes continue receiving other inputs or waiting. Browser clients keep status/inspection responsive, show the pause, and stop ordinary action submission until the new catalogue and view are synchronized. New mutations authored for the prior rules revision are rejected as stale unless a separately specified compatibility path exists. Do not rewrite an old operation's stored payload in order to make its retry pass.

If the process exits before selection commits, restore the old selection. If it exits after commit, restore the complete new selection. If activating the committed selection fails, remain paused with an inspectable recovery error. Do not quietly mix old handlers with new data.

Returning to older code requires compatible current data or a forward migration. It is not implemented by restoring an old entire world snapshot and erasing later conversations, receipts, or physical progress.

### 13.6 Queued and offline clients count as dependents

An offline Life may reconnect with scheduled code using an old API; a browser may remain open with an old client build, interaction catalogue, and pending requests. A module upgrade cannot enumerate every future program or click, so keep stable contract identities and reject unsupported versions explicitly.

The handshake advertises the current feature catalogue and required versions. Each command states its contract/rules assumptions. A Life receives a rules-change observation and may update its library or reconsider. A browser refreshes discovery, resynchronizes, and disables interactions its loaded code cannot represent; an incompatible required client build shows an update-required state. Previously authored pending commands are reconciled under their original identities and payloads, not rewritten automatically. Life-local cognitive migration remains separate and follows `life.md`.

Retain receipt/status queries for old operations even if the feature that created them is no longer available. Those results are core operational evidence. Removing an extension must not make completed work appear unknown and thereby executable again.

### 13.7 Unknown features and schemas

| Situation | Behavior |
| --- | --- |
| New content using known schemas | Existing clients can observe and act normally. |
| New optional observation field/component | Client preserves or ignores it under the schema contract; no automatic execution. |
| Unknown required observation or incompatible core schema | Stop affected processing and report the required update. |
| Unsupported operation version | Reject before effects with `unsupported_operation`/`incompatible_contract`. |
| Renderer lacks a new appearance | Use a generic fallback or explicit unsupported marker, not a runtime crash. |
| Browser lacks an interaction form primitive | Display that action as unsupported; preserve other compatible interactions without guessing arguments. |
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

### 13.9 Participants may propose features, not silently redefine shared reality

A human or Life can publish a proposal, example code, tests, or a model of a desired mechanism as an artifact. The operator can adopt it through the world module workflow. Building an object with already supported rules remains an ordinary world action.

Writing a local function called `make_water` does not create water in the shared world. New world laws need an installed world implementation. A future experiment could automate more of feature admission, but arbitrary brain source is not executed as world-server code in this first design.

## 14. Spatial growth and larger experiments

### 14.1 Grow the map without replacing it

Add regions adjacent to or connected with the Commons: a stream, hill, orchard, library, café, shop, additional homes, or another workshop. Keep stable coordinate frames and explicit links between places. New links change navigation through a versioned world transaction.

Existing region revisions and object IDs remain. References stored by a Life can become stale if an object is deliberately moved or removed, but never because a new region renumbered everything.

Initially keep the entire small world resident. Introduce region streaming only when measurements require it. A later streaming contract must define inactive-region simulation, arrival synchronization, and cross-region actions before using unloading as an optimization.

### 14.2 Grow the population without coupling minds

The world should support an arbitrary configured set of registrations rather than special cases named Aster, Brin, Cove, and Dara. Four is an experiment size, not a wire-protocol limit.

A new Life receives its own process, private store, creation record, and participant/entity registration. A new human receives a player registration and actor and connects through the browser, without a new Life process. Neither addition restarts existing participants or merges private histories. Account for simulation, fanout, network load, and model cost before increasing the population.

Do not add peer-to-peer Life networking initially. Local encounters and public artifacts go through the world, which supplies position-aware audience and durable delivery. External chat/forum connectors remain independent Life adapters.

### 14.3 Grow social and environmental possibilities gradually

Candidate later modules include household cooking and food storage, furnishing and repair, persistent books, collaborative work surfaces, gifts/borrowing/barter, shops, music, bicycles/transport, weather, seasonal growth, energy networks, and connected neighborhoods. Add explicit exchange or currency mechanics only when the intended activities need them.

Each addition should create observable consequences or a new interaction that tests a question. Avoid a long checklist of decorative mechanics. Mandatory survival, economies, or population-scale competition can dominate behavior; treat them as separately configured experiments rather than default assumptions.

### 14.4 Do not promise world sharding yet

A single authoritative world process is the initial consistency boundary. New regions need not be new processes. Supporting multiple world servers, entity transfer between them, or simultaneous simulation writers requires a separate ownership and handoff design.

Keeping world operations, IDs, regions, and transport interfaces explicit leaves room for that work without pretending it already exists.

## 15. Human browser play, presentation, and inspection

### 15.1 The browser is a player client

A person opens the web interface, joins as an existing or newly provisioned player, and controls their own persistent avatar. The browser is not merely a dashboard and not a copy of the authoritative simulation. No model key, Gene runtime installation, or Life process is required on the human's machine to play through this client.

The first interface contains a 3D or simple initial scene, camera controls, click-to-move, object selection/inspection, an interaction panel, own inventory, local chat/thread history, activity progress with Stop/Resume/Cancel where applicable, and explicit connection state. Keep the operator panel separate.

A first-time human should be able to arrive, approach a Life, speak, place/pick up an object, and see the persistent result without learning Gene. The AI still controls its own response and attention. A human's message does not pause the world or force every Life to answer.

### 15.2 One input-to-outcome path

```text
Pointer, keyboard, or chat input
→ current client selection and discovered interaction
→ validated command data with one stable operation ID
→ browser pending journal
→ WebSocket submission
→ shared authoritative world handler and transaction
→ receipt / activity events / updated visible state
→ UI confirmation, progress, or a concrete failure reason
```

Use the same `movement.walk_to`, `object.pick_up`, `conversation.say`, and later feature operations as Life clients. The server—not the UI—validates actor binding, distance, possession, target revision where requested, and operation-specific access. A missing or stale UI button cannot establish whether a command is valid at application time.

Show a pending placement marker or requested destination separately from confirmed state. Inventory transfers are shown as complete only after the world result. For long work, distinguish local queued, server accepted, running, suspended, and terminal states. A person may continue independent interactions while an activity progresses, subject to ordinary world rules.

### 15.3 Movement, cameras, and time

Click-to-move starts a server-owned walk, the same as an AI request. Start with a third-person/isometric camera, orbit/zoom, and a readable world. Camera input is local presentation; physical movement remains a world operation. A later direct-keyboard mode follows section 6.5 rather than trusting client positions or relying on key-up delivery.

Render with interpolation between timestamped committed samples. Use the world's view-generation and entity revisions to discard stale samples after resync, teleport, migration, or history change. Interpolation is never fed back into Life context or world storage as a confirmed action. Prediction can be added later, with correction and replay rules, but is not needed for click-to-move.

For ordinary human sessions, world time is near real time. Brains deliberate asynchronously, and world updates do not wait for them. An AI can finish a previously started walk while thinking, and a human can work or converse while awaiting its reply. Menus, backgrounded rendering, and an idle player do not pause the world.

### 15.4 Conversation and persistent social interaction

Chat is tied to the player's actor and world conversation/thread, with a saved reply destination. Show local pending text separately from accepted speech. Correlate the receipt and inbound echo so one submitted message appears once. Mark AI participants as AI and human participants as human without inventing a shared access to private memories.

The first shared activity can be drop-and-pick-up transfer of a watering can. A later gift/borrow feature should define proximity, acceptance, ownership, and cancellation explicitly; neither a label saying Gift nor a line of dialogue moves the object. The same applies to invitations, cooking together, construction, or exchange: world records establish what occurred.

A human can leave, return to the same avatar, inspect retained eligible conversations, and see what the Lives changed. Private Life decisions are not published just because a person interacts with that Life. Render all participant-authored text and code artifacts as inert content, with bounded length; do not insert arbitrary HTML/scripts from chat or world packets.

### 15.5 Player, observer, and operator modes

| Mode | Interface and visibility | Mutation rights |
| --- | --- | --- |
| Player | Own avatar, inventory, actor-filtered scene, eligible conversations and interactions | Ordinary actions for its bound actor |
| Observer | Explicitly selected observation view, possibly a broader public scene | Read-only; no actor control and no private Life store |
| Operator | Process health, full experiment state where admitted, pause/recovery/feature selection | Separately authenticated administrative operations |

Selecting another avatar in player mode is inspection, not possession. A menu toggle cannot grant operator status. The default human page opens in player mode after login, not as an omniscient debugger. A broad observer view must be visually distinct from an actor-perception view; do not feed it into every brain.

Private note/memory inspection, when needed, uses an explicitly admitted interface of the relevant Life process. The world should not aggregate private cognitive databases just to populate a convenient dashboard. No such inspection is required for normal human play.

### 15.6 New features should not require a new browser for every object

Appearance uses versioned/declarative asset IDs, labels, primitive shapes, meshes, and materials fetched through HTTP. Unknown appearances have a generic fallback. Section 8.5's interaction catalogue lets new operations appear through supported generic forms before custom UI exists. For example, an added oven can expose Inspect, Open, and Begin cooking without a new brain-response type or arbitrary client script injection.

Custom renderer behavior, if needed, ships as an explicit client release—not executable code embedded in an object. A feature that needs an unsupported input or schema reports that requirement. Refresh discovery and baselines after a rules change without losing pending command identities or corrupting retained history.

The implementation may use Gene's supported browser output with a graphics library behind a narrow adapter. No engine or current Gene build compatibility is assumed here; verify the chosen build/runtime path. Rendering and UI can evolve independently of the world/Life process boundaries.

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
  participants.gene         human/Life registrations, sessions, controller ownership
  modules/
    core.gene               transforms, items, containers, identity
    movement.gene           walking and its checkpoints
    conversation.gene       speech, noticeboards, audience
    garden.gene             light/moisture/growth and watering
    construction.gene       small recipes and placement
  content/commons.gene       initial regions and objects
  client/
    main.gene                browser entry and player/observer mode selection
    session.gene             attach, reconnect, pending journal, receipt recovery
    input.gene               click-to-move, selection, chat, interaction forms
    view.gene                filtered state, renderer, inventory and progress
    operator.gene            explicitly separate experiment controls
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

A store path belongs to its owner. Lifetimes, flushes, migrations, and backups follow that owner's contract. Do not let the browser or Life processes open `world.sqlite` directly. Human profiles, accepted world history, inventory, and operation receipts are owned by the world store; the browser has only its local pending journal, cache, and drafts. No `lives/human/life.sqlite` is required.

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

The world configuration selects storage, world/history identity, bind address, modules, simulation settings, initial content, and player-session/Origin settings. Each Life configuration selects its own store, identity, world binding, brain adapter, and seed reference only for creation. Model credentials stay with the Life; neither the world nor browser needs them.

Once the HTTP/WS host is ready, the human opens the configured player URL, for example `http://127.0.0.1:8096/`, signs into its locally provisioned player session, and joins. That is an application route to implement, not a new Gene CLI command. Creating a player is explicit; refresh/relogin resumes the existing one. A launcher may open the page, but closing it must not signal global shutdown.

### 16.4 Process health and practical controls

Expose simple process-level status: ready/recovering/paused, current world/history, selected code revisions, connected controller count, queue depth, simulation lag, pending outbox count, oldest unacknowledged event, and unresolved operations.

Keep failures linked to operation, action, event, cycle, and revision IDs. A log line saying “sent” must not be used as a durable execution result. Avoid dumping every private model context into a global world log.

Use per-process memory/execution limits, a bounded brain-call budget, rate-limited participant queues, and reliable operator controls. These are application/deployment choices. Do not reintroduce the removed Gene capability system or make JIT or a production distributed scheduler a prerequisite for this experiment.

## 17. Implementation milestones

### Milestone 1: real processes and a minimal playable browser

Run one world process and two fake-brain Life processes, each with its own store. Add a minimal browser player with a separately registered avatar. Use real local WebSockets. Inspect a scene, speak, select an object, and make human and AI requests contend for the same item through one handler. A simple placeholder scene is enough; this milestone is not conditional on polished graphics.

Complete participant binding, writer-generation checks, operation receipts, browser pending-command journaling, and recipient synchronization on this path. A single-process in-memory demo remains a unit test, not completion.

### Milestone 2: durable walking and independent recovery

Implement server-owned walking and browser click-to-move. Keep Life-local grouped commits local; the server commits position and world-action progress. Test reply loss, browser refresh, browser cache loss, Life crash, world crash, and same-player tab takeover. No duplicate exchange or avatar, no rewinding another participant, and no unexplained resumed movement.

### Milestone 3: one human and two real Lives

Connect the real brain adapter for two Lives, each with its own context. The human visits the garden, speaks, drops/offers an object through implemented interactions, observes a Life using it, refreshes, and returns to the same world. A delayed AI reply must not freeze the human interface. A browser-only player can complete this without a model credential or native Gene installation.

### Milestone 4: four seeded Lives and the neighborhood

Create Aster, Brin, Cove, and Dara from the recorded common prompt and small variations. Add homes, a noticeboard, simple garden behavior, and polished enough 3D presentation for readable human interaction. Then add a shared kitchen or workshop activity with real inputs/outcomes. All four seeds keep the same basic action vocabulary; no assigned occupations.

### Milestone 5: prove expansion with an active player

Add a region using existing schemas, then irrigation or a household behavior module. Demonstrate new interaction discovery in the browser and Life client, generic fallback, retained object/actor IDs, and a restart during migration. Test an open old browser, a queued human command, a suspended AI action, and an offline Life. Publishing a feature name alone does not demonstrate extensibility.

### Milestone 6: private body evolution in the shared world

Let one Life select a learned procedure or new memory/attention organization while the human and other Lives continue. The world does not need to understand its private schema. Reconcile incompatible queued actions explicitly. New procedures can exploit existing world rules; they do not silently replace those rules.

### Integration checks before claiming support

Verify Gene's selected native WebSocket client/server and browser build interfaces, cancellation/limits, store durability, renderer codec, session/Origin behavior, and repeated generated-code lifetimes. Where an API is missing, add a small adapter rather than a second evaluator or collapsing the processes. No implementation or browser test success is claimed by this document.

## 18. Acceptance tests and experimental evaluation

### 18.1 Operational conformance

| ID | Scenario | Required result |
| --- | --- | --- |
| P1 | Launch world, four Lives, and a human browser | Five distinct native processes/writer domains plus a browser controller; no per-human Life process or model dependency. |
| P2 | Stop one Life | Others and the world continue; stopped Life's identity is not recreated. |
| P3 | Attempt a second controller | Reject it or perform explicit takeover; stale generation cannot admit new work. |
| P4 | Close/reopen a player or observer browser | World/Life lifetimes continue; only a player controller's actor follows its disconnect policy. |
| P5 | Start a Life while world is unavailable | Preserve local state and retry connection; no new world/entity is invented. |
| P6 | Try to act as another avatar | Server uses authenticated binding; claimed actor data cannot redirect control. |
| W1 | A human and a Life pick up the same unique item | At most one succeeds through the same handler; no optimistic UI duplication. |
| W2 | An object moves/disappears after perception | Operation uses current preconditions and returns the actual outcome. |
| W3 | Run many movement requests in one program | Physical movement still consumes simulation time; no teleport by call count. |
| W4 | Commit a movement step | Position, action checkpoint, simulation time, and related events agree. |
| W5 | A browser or Life floods commands or stalls reads | Bounded per-participant queues do not stall other actors or grow without limit. |
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
| X2 | Add a behavior module | Use normal publication/recovery and update both browser discovery and Gene-facing documentation; no brain-response change. |
| X3 | Crash before/after feature selection commit | Restore complete old/new selection respectively, never mixed schemas and handlers. |
| X4 | Upgrade with queued old-contract operations | Preserve, migrate, reject, or defer explicitly; no silent reinterpretation. |
| X5 | Remove a feature with completed operations | Their receipts remain inspectable and cannot be replayed as new effects. |
| X6 | Renderer lacks a feature's appearance | Generic fallback; world and Life operation continues where contracts permit. |
| X7 | Public artifact contains Gene code | Reading does not execute or install it. |
| C1 | Seeds have the same available actions | Different initial interests do not create hidden competence or privilege differences. |
| C2 | Reopen an existing Life | Restore evolving state; do not reinject the seed as a new creation. |
| C3 | One Life changes its private memory schema | Others' stores and the world's rules are unchanged. |
| C4 | A Life receives no relevant event | Body and world remain operational without compulsory model calls. |
| H1 | Human clicks and a Life calls the equivalent helper | Same operation contract, physical checks, and server outcome semantics. |
| H2 | Human refreshes after world commit but before receiving the receipt | Recover/query the same operation ID; no second pickup, speech, or exchange. |
| H3 | Clear browser cache and log in again | Same avatar/possessions and retained eligible server history; lost unsent drafts are not invented or resent. |
| H4 | Open two tabs as one human | One mutating controller; explicit takeover fences old queued commands and leaves read-only observation possible. |
| H5 | Use another participant ID or hidden object ID in input | Connection binding and filtered query/action checks prevent redirected control or private-field disclosure. |
| H6 | Browser journal fails before send | No mutation sent; UI exposes the failure rather than silently losing its retry identity. |
| H7 | Click-to-move returns accepted | Show progress, not arrival; completion follows the authoritative action event. |
| H8 | Stop/Cancel races with action completion | Display the real terminal outcome; no false rollback or duplicate replacement walk. |
| H9 | Browser disconnects during an activity | Shared world continues; that motor activity suspends under the documented detection policy and waits for explicit resume. |
| H10 | AI inference is slow or unavailable | Human controls, simulation, chat, and admitted physical work remain responsive. |
| H11 | Human message has both a receipt and an event echo | One visible accepted message, with correct actor/thread; no automatic forced AI response. |
| H12 | Switch UI mode or inspect a Life | No implicit control takeover, operator status, or access to private notes/memory. |
| H13 | New feature exposes a supported generic interaction | Human can use it through the catalogue and Life through Gene without an executable UI payload. |
| H14 | An old browser submits after a rule change | Reconcile prior IDs; reject incompatible new work and refresh/update instead of rewriting the old request. |
| H15 | Rapid visual updates saturate a peer | Coalesce telemetry before sending; preserve durable receipts/messages and keep the server responsive. |
| H16 | A conversation or artifact contains HTML/JS/Gene text | Display as inert data; no script execution or automatic code installation. |
| H17 | Browser actor-view camera moves away from the avatar | Server filtering does not reveal hidden state merely because the camera changed. |
| H18 | Browser session is absent/expired or Origin is unapproved | No controlling welcome or participant-private data; require valid attachment. |
| H19 | Later keyboard mode loses key-up, hides the tab, or reconnects | Server expires old input and clears it across generations; no replay from the durable outbox. |
| H20 | Browser ACKs then loses its storage | World retention preserves the human transcript/receipt contract independently of that ACK. |

Test network faults with real separate processes: close sockets at selected points, delay receipt delivery, replay an old command, kill one process, and verify durable records after reopening. Assertions must inspect the actual item location, action count, receipt identity, and recipient inbox—not only returned status text.

### 18.2 Behavioral comparisons

Record common/individual seed revisions, initial placements, world rules/content revisions, model configuration, brain-call budgets, and selected Life code revisions. Distinguish scripted human-input fixtures from exploratory human sessions, and retain the relevant action/conversation trace; human participation is an experimental input, not controlled merely by using the same seed. Repeat runs and swap seed-to-position assignments. Compare identical seeds as a baseline so ordinary model variability is not misidentified as a personality effect.

Look for continuity of interests, preference recall, revision after contradictory evidence, chosen places, learned procedures, information exchanged between Lives, useful restraint, and reactions to changed circumstances. Allow both divergence and convergence. Distinct writing styles alone do not demonstrate distinct persistent behavior.

World replay can reproduce recorded physical transitions under the recorded rule versions and action order. Reissuing model calls is a new behavioral run, not deterministic replay. Keep the two modes distinct.

### 18.3 A first public demonstration

One human enters through the browser while two independent Lives inhabit the same garden/workshop scene. The human walks over, speaks, and makes a watering can available through the implemented transfer interaction. A Life observes it, decides whether and when to respond, and starts an activity. The human refreshes and returns to the same avatar, possessions, eligible conversation, and current world, without repeating the transfer. Closing the browser leaves the world and Lives running.

Then expand to four lightly seeded Lives, stop/restart one during a walk, and have the human return later to inspect persistent changes. Add an adjacent place or feature while preserving identities and receipts. New browser interactions and Life documentation should expose the addition without resetting inhabitants or scripting their roles. Human play and independent AI continuity are both demonstrated by actual outcomes, not just by displaying several avatars.

## 19. Decisions to keep visible

The following are selected design choices, not unresolved hidden defaults:

| Choice | Version-1 decision |
| --- | --- |
| Deployment | Separate world process and process per AI Life; human controllers run in browsers, not extra Life processes |
| World consistency | One authoritative writer; no world sharding or replicated writers |
| Storage | Separate transactional world and Life stores; no distributed `store.commit` |
| Transport | WebSocket for commands/events; HTTP for assets; application-owned durability |
| Brain interface | Ordinary Gene code plus a short decision note, unchanged from `life.md` |
| World requests | Versioned inert data, not remote execution of brain programs |
| Initial population | Target four lightly seeded Lives and human players; first playable test uses one human and two fake-brain Lives |
| Perception | Actor-filtered views for play and AI observations; private minds; separately admitted observer/operator view |
| Reconnect | Durable receipts, recipient replay, consistent snapshot, reconciliation before fresh effects |
| Duplicate commands | Same durable operation ID returns the retained result; changed payload conflicts |
| Disconnect | Human/Life avatar remains; motor actions suspend when loss is detected; reconcile before explicit resume |
| World downtime | Simulation pauses; wall-clock schedules use their explicit policies |
| Upgrade | Controlled quiescent selection; explicit schema/activity compatibility |
| Expansion | New content, regions, components, operations, and systems through versioned Gene modules |
| First experiment | Human-scale neighborhood activities; no mandatory survival economy or assigned AI professions |
| Human control | Own persistent avatar, click-to-move first, shared world operation contracts |
| Browser recovery | Pending-operation journal plus authoritative server receipts/history; refresh is not a new action |
| Language permissions | No dependency on the removed Gene capability system; normal world/session validation remains |
| Extensible UI | Data-only interaction discovery and appearance fallback, not executable scripts in world packets |

Some implementation selections still need to be made: the exact Gene transport/store APIs, supported local OS process-lock primitive, rendering library, model adapter, detailed physical constants, and deployment limits. They should implement the contracts above rather than silently redefine them. They do not require additional core Gene syntax.

## 20. Basis and references

**[D1] World-design discussion, 2026-09-21.** This revision adopts the project owner's removal of Gene capabilities; the request for a human-like expandable world; and browser-controlled human participants using WebSocket alongside separate AI Life processes. It extends the earlier world proposal rather than reporting implemented features. The neighborhood, interaction catalogue, browser pending journal, and milestones are proposed design choices.

**[L1] User-supplied Gene Life proposal.** Latest reviewed attachment `life(2).md`, updated 2026-09-20; intended companion filename `life.md`. This world design preserves its code-first brain interface, private cognitive organization, explicit state continuity, activity checkpoints, and independent-environment semantics. It explicitly supersedes its optional shared-store/local-world deployment for this multi-process experiment. Relevant sections: 1–4, 6–10, and 12–15. Source attachment SHA-256: `a3d9750da0d0f974fb646b157ae10c5ec3afb787478e3da248dd554a76bc6b43`.

**[T1] IETF RFC 6455, The WebSocket Protocol.** Basis for bidirectional framed communication, subprotocol negotiation, close/ping/pong, and secure WebSocket transport. Application receipts and world recovery rules in this document are proposed above that transport, not guarantees borrowed from it. Source: <https://www.rfc-editor.org/rfc/rfc6455.html>.

**[T2] MDN, WebSocket and bufferedAmount.** Basis for the browser API's buffering/backpressure limitations. Queue policies and replay limits here are proposed application rules. Sources: <https://developer.mozilla.org/en-US/docs/Web/API/WebSocket> and <https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/bufferedAmount>.

**[T3] SQLite, Atomic Commit In SQLite.** Basis for local transactional publication, subject to the chosen storage/durability configuration; not a claim of atomicity across independent databases and network messages. Source: <https://www.sqlite.org/atomiccommit.html>.

**[T4] IETF RFC 8259, The JavaScript Object Notation (JSON) Data Interchange Format.** Basis for the proposed text interchange format and interoperable numeric considerations. This document adds stricter bounded schemas, duplicate-key rejection, and string encoding for large identity/revision values. Source: <https://www.rfc-editor.org/rfc/rfc8259.html>.

**[T5] WHATWG WebSockets Standard.** Browser API, HTTP/session integration in the handshake, and non-exposure of protocol ping/pong frames to script. The session, Origin, reconnect, and actor-control policies in this document are application design choices, not automatic WebSocket guarantees. Source: <https://websockets.spec.whatwg.org/>.

RFC 6455, MDN WebSocket/bufferedAmount, and the WHATWG browser interface were consulted for this revision; the SQLite and JSON references are retained technical bases from the earlier draft. No Gene implementation, network integration, renderer, or test suite was executed. API names, message shapes, sample values, layout, authentication flows, and seed prompts specify proposed behavior, not existing support.

**A world people can enter, independent Lives that continue, and shared places that keep growing.**
