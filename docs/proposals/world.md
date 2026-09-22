# Gene World: An Expandable Human–AI Commons

**Status:** Experimental design proposal, not an implementation report.  
**Date:** 2026-09-21.  
**Revision:** 4 — selectively copy and adapt Miclone code; no Miclone build, runtime, or test dependency. Retain revision 3’s durability and browser-first rollout decisions.  
**Companion:** The latest reviewed `life.md` (uploaded as `life(2).md`, updated 2026-09-20).  
**Decision:** One authoritative world process, one separate process per AI Life, and a browser player client for humans. Human and AI controllers use the same world-action contracts over WebSocket. Keep HTTP for pages/assets and explicit application-level receipts, replay, and reconnection for live interaction. Miclone is a source reference for copied code, not a required package, engine, or service.

> One shared reality for human players and independent AI Lives. Humans act through a browser; each Life acts through Gene code in its own process. Places, possessions, conversations, and consequences persist as the world grows.

## 1. Purpose and scope

Gene World is a shared, persistent environment in which human players and independent Gene Lives can observe, act, meet, create, and change. The first environment is **The Commons**: a small human-like neighborhood with homes, a shared kitchen/gathering place, a workshop, a garden, and surrounding landscape. Aim for four Lives whose starting inclinations differ slightly—not permanently assigned professions—and human visitors who control their own persistent avatars in a browser. Prove browser play against the world first, then attach independent fake-brain Lives, then a real brain.

The experiment asks whether independent Lives develop coherent ways of living through experience, including encounters with people who actually inhabit and change the same place. Humans are participants, not merely observers or sources of chat prompts. The world supplies opportunities, constraints, and actual outcomes. It does not prescribe stories, maintain everyone's beliefs, force AI replies, or require activity on every heartbeat.

Prioritize human-scale causal and social realism over photorealistic graphics: objects have uses, activities take time, materials come from somewhere, people know different things, and shared projects leave persistent results. The neighborhood is a proposed design direction, not a claim to reproduce any existing game or to validate human psychology.

The world must be expandable in three ways:

1. **Space and content:** additional regions, objects, materials, plant varieties, and public artifacts.
2. **Behavior and systems:** additional interactions, environmental processes, and reusable world-side Gene modules.
3. **Interfaces:** additional observations, operations, and discoverable interactions that both browser and Life clients can understand, present generically, ignore safely, or identify as unsupported.

Expansion must preserve existing identities, meaningful state, operation receipts, and supported activity progress. “Expandable” does not mean that every arbitrary change can be installed live without migration.

### 1.1 Relationship to Gene Life

Keep the Life design's independent identity, replaceable brain, decision note plus executable Gene program, flexible memory organization, and explicit persistence. Life remains independent of Gene Harness. Neither Harness nor Cordis is a mandatory dependency of this world.

This document adds a **networked world profile** alongside Life's existing local-world implementation. It does not replace that local adapter, its demo, or its regression suite. The shared world is an **independently running environment** from each connected Life's perspective. In particular:

| Earlier local-world option in `life.md` | This multi-process profile |
| --- | --- |
| Life and the world may share one transactional store. | The world owns its store; each Life owns a separate private store. |
| A world update and cognitive update can sometimes share one local commit. | A Life commit can publish an outbound request, not commit remote world effects. |
| Stopping the local body freezes its local simulation. | Stopping one Life does not stop the shared world. Only the world process controls world simulation. |
| A Life restart restores a local world snapshot. | The world restores its state; the Life reconnects and reconciles its last observed view. |
| `water` may complete an immediate local operation. | A networked action distinguishes local submission, world acceptance, and completed effect. |

These are explicit profile differences, not claims that the older local transaction crosses a socket. Select `local` or `network` behind `body/world`; keep local behavior as the default for existing Life tests and demos. A network adapter has explicit submission/result semantics rather than pretending a remote effect completed synchronously. The companion's independent-environment and checkpoint rules remain applicable. This profile additionally allows a labeled provisional motion tail between world checkpoints (§6.1); confirmed gameplay effects remain durable. [L1, D2]

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

### 1.4 Implementation decision: copy and adapt, then develop independently

**Selectively copy useful code from Miclone into the Commons and adapt it to this design. Do not make the Commons depend on Miclone.** The Commons is its own application, not a Miclone profile, mod, thin wrapper, or deployment that must start Miclone underneath it. It owns its source, build scripts, tests, assets, protocol, content, and saves.

The previously reviewed Miclone sources provide useful transport wiring, portable world code, a browser shell, and persistence examples. Use them to avoid rewriting suitable foundations, not to inherit every assumption of the voxel game. Their documented behavior is source evidence, not a fresh execution of their smoke tests or proof that an adapted copy works. [R1]

| Source to consider copying | Commons-owned adaptation |
| --- | --- |
| Server `$net/http` WebSocket integration and `serve` tick hook | Copy the useful loop and transport wiring into the Commons server; add its sessions, command admission, receipts, and filtered observations. |
| Gene web-profile browser, WebGL2 renderer, camera, picking, meshing, and input | Copy the needed shell, helpers, shader/asset recipes, and build steps. Add click-to-move and interaction controls locally; simplify or replace rendering assumptions as the neighborhood evolves. |
| Portable geometry, inventory, entity, and content helpers | Copy the useful functions and required dependencies, then reshape their APIs and data for the Commons. Do not preserve an unsuitable voxel representation merely to minimize the diff. |
| Server-selected content and recipe-driven presentation | Adapt the data-only appearance and interaction machinery. Do not import the whole mod framework or the removed Gene capability machinery as prerequisites. |
| SQLite world integration and batched publication | Copy relevant adapter code and fixtures, then implement §6.1 and §12.8. Reusing source does not make whole-image commits inexpensive. |
| Native WebSocket integration example | Copy useful application-level connection/polling code. Depend directly on the independent Gene `genex/websocket` library and its documented prerequisites, not on Miclone's native client or launcher. [R2] |
| Client-simulated player motion | **Replace this authority model.** Commons walking, collision, speed, possession, and action preconditions remain server-owned for both humans and Lives. |
| Byte-oriented game protocol and codec helpers | Copy helpers only where they fit. Commons owns its versioned envelope and has no compatibility obligation to Miclone clients, messages, or saves. |
| Build scripts, tests, probes, and fixtures | Copy and adapt the relevant pieces into the Commons tree. Tests run against Commons code and fixtures; they do not invoke the Miclone test suite or reuse its generated output. |

#### Independence and maintenance rules

- **Copy the necessary dependency closure, not the entire project by default.** Resolve copied code's imports, assets, fixtures, and script paths locally. There must be no imports into `examples/miclone`, Miclone package dependency, required Miclone executable, symlink/submodule back to its source, or reliance on its `dist` files, caches, working directory, or running server. A build must not fetch or recopy Miclone automatically.
- **Make the copies ordinary Commons source.** Organize them by their current responsibility, rename and simplify them where helpful, and maintain them under Commons' own tests. This is not an unmodified vendor snapshot that must preserve an upstream API or layout. Sharing a repository with Miclone does not create a dependency between the applications.
- **Keep lightweight provenance.** A short `world/SOURCES.md` records original paths, source commit, local destinations, and any source/asset notices. Retain the original notices with the copied material. The source commit identifies where a copy came from; it is not a live dependency version that must be installed to build the Commons.
- **Upstream changes are optional inputs.** Review and manually port useful fixes or features, recording their origin and testing the adapted result. There is no automatic synchronization or requirement to keep the projects compatible. In exchange for independence, Commons maintainers own the copied code and the decision to incorporate later fixes.
- **Leave Miclone unchanged.** It remains a separate experiment. Its tests can be an optional source-comparison aid during the initial copying, but its availability and test status are not Commons build or release gates. Do not start a shared-engine extraction project just to avoid deliberate duplication; consider a separately versioned shared library only after a concrete need emerges.

The independence requirement concerns the **Miclone application**, not all external software. Normal, explicitly declared dependencies on Gene, its standard APIs, `genex/websocket`, libcurl, and the selected browser/graphics interfaces remain appropriate. They must be selected directly rather than acquired transitively by importing or launching Miclone.

**Acceptance criterion:** with `examples/miclone` and its generated outputs unavailable, a clean Commons checkout/package plus its declared platform dependencies can build the browser and server, run its own smoke tests, and support the browser/world interaction. Documentation and provenance may still name Miclone; executable paths must not require it.

This policy preserves source reuse while allowing the two applications to diverge. Persistent participants, receipt-backed interactions, actor-scoped views, and server-owned walking remain Commons implementation work. Existing Miclone renderer measurements are not Commons performance results.

### 1.5 Evidence and feasibility baseline

Revision 3 combined the prior world proposal, the supplied implementation review [D2], and a focused read of Miclone and native-WebSocket sources at `228d3304b872927aa1d82b5a46934e8ec8c479fe`. Revision 4 clarifies the project owner’s choice of selective copying and independent maintenance (§1.4); it does not claim another repository audit or that source has already been copied. [D1, R1, R2, R3]

The review reports a 3-second Life program limit, worker-process execution, a 100-call/hour default, an HTTP mailbox connector with crash tests, no real brain adapter in that reviewed implementation, and 110 existing Life tests. Those Life implementation details and the reported 128 ms → 1.24 s cycle timings over 200 cycles were **not independently reproduced here**. Record the actual Life checkout/revision and rerun its baseline before integration; do not turn these reported numbers into achieved targets or a permanent test-count promise.

The design below deliberately accommodates those constraints: short event-driven code, explicit real-brain work, bounded active storage, and preservation of the local adapter. It does not assert that a proposed API is already implemented merely because the design names it.

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

The first playable slice needs one browser-controlled actor, server-owned walking, one unique object, and receipt-backed interaction. Local speech and independent fake-brain Lives join in the next slice. A drop-and-pick-up exchange can demonstrate shared reality before a dedicated offer/accept system exists. Cooking, garden, furnishing, and construction are later additions, not prerequisites.

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

### 3.5 Immutable seed, editable current disposition

Store `creation_seed` once as provenance and initialize a separate `current_disposition` in the Life's selected cognitive data. Stable execution/API instructions may appear in every context. The original personality seed must not be continually reimposed as an instruction that overrides the current disposition.

The supplied review reports that the present Life context builder injects its protected seed on every call. Changing that is explicit integration work, not an assumed existing feature. Preserve that record, initialize the editable disposition without resetting other memories, and change context construction to use the selected current disposition. Historical seed text may be retrieved as labeled history, not as a competing command. A future brain-defined representation may replace this starter field without a new world schema. [D2]

Acceptance: edit the current disposition, make another decision, restart, and verify that the changed disposition is used while original creation provenance remains unchanged. Do not require a disposition edit to alter physical abilities or world permissions.

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
| Browser in-flight command map, installed view, unsent drafts | Browser memory; transient in version 1, not required persistent storage |
| Render interpolation, camera, selection, temporary input | Browser; transient, not authoritative world state |

Use one transactional world store and a separate private transactional store for each Life. Only the owner opens its store for mutation. No browser or Life reads or writes the world database directly. SQLite can supply local transactions; it does not turn these stores into a transaction across a socket. [T3]

The server is the durable home of human inventory, accepted speech, and completed actions. Version 1 requires no IndexedDB pending journal or persistent browser event cursor. A refresh recovers server-known actions/receipts/history; unsent or unrecorded client intent can be lost and is never guessed or automatically resent. Section 10.7 defines the recovery boundary; §11.4 separates human history retention from browser acknowledgments.

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

Maintain one server-owned live simulation and one durable frontier. At an action boundary or periodic checkpoint, commit the pending logical state, action progress, simulation time, relevant random-generator state, and resulting durable events together (§6.1). Intermediate render samples may be provisional. Recovery applies committed data changes; it does not rerun historical Gene action programs.

## 6. Simulation, time, actions, and disconnects

### 6.1 Three clocks remain separate

| Clock | Owner | Meaning |
| --- | --- | --- |
| Simulation time | World | Movement, growth, day/night, and physical activity progress |
| Wall/monotonic operational time | Each process | Liveness, timeouts, resource budgets, and reconnect delays |
| Cognitive schedules | Each Life | When that Life elects to think or execute a short routine |

Use fixed logical steps, initially 100 simulation milliseconds, and near-real-time progression for human play. **A step is not a database commit.** Rendering, logical stepping, and durable publication are separate rates. Accelerated simulation is an explicit shared setting, not a private speed multiplier.

**Selected version-1 persistence policy: action-boundary commits plus periodic checkpoints.** Start with a proposed one-second checkpoint interval and a maximum five-second dirty simulation horizon. These are adjustable prototype settings, not measured guarantees. A paused/idle world with no changes need not rewrite its image. If storage cannot keep the dirty horizon within the configured bound, stop advancing it and report storage lag; do not silently accumulate unlimited recoverable loss.

| Change | Publication requirement |
| --- | --- |
| Admission/rejection of a logical command; control-generation acquisition | Durable before returning a receipt or admitting the controlling session. |
| Pickup, transfer, placement, crafting, accepted speech, persistent notes | Commit effect, receipt, causally necessary world state, and recipient events before confirming success. |
| Activity completion, failure, suspension, cancellation | Commit physical progress and outcome together before a durable status/event. |
| Intermediate movement, animation, and reversible simulation progression | May advance in server memory and be shown as **provisional** until the next boundary/checkpoint. |
| Periodic checkpoint; clean pause/stop; feature selection | Publish a complete consistent frontier; pause/stop is settled only after its required commit succeeds. |

The world remains the authority while running; provisional means **not yet crash-durable**, not client-authoritative. Track a committed `world_revision`/`committed_sim_time_ms` and separate `server_epoch`, `live_seq`, and live simulation time. Telemetry includes `server_epoch`, `live_seq`, `base_world_revision`, live `sim_time_ms`, `committed_sim_time_ms`, and `provisional`; mark it provisional whenever it goes beyond the durable base. It receives no durable event sequence or success receipt merely because it was sent.

For simplicity, flush **all pending logical world changes** into the same frontier when a durable operation depends on live state. If a participant walks beyond its last checkpoint and then picks up an item or speaks to a nearby audience, commit that position and the relevant simulation state together with the interaction. Never retain the pickup while rolling back the movement or audience facts that made it valid. Feature code must use this publication path rather than invent independent durability domains.

A world crash restores the last durable frontier; only the advertised provisional tail may disappear. Send a new server epoch and snapshot so clients replace, rather than append to, that tail. Previously confirmed speech, transfers, receipts, and terminal activity results cannot disappear. This is a deliberate relaxation of revision 2's per-tick durability requirement, not a claim that periodic checkpointing preserves every displayed frame.

Perception snapshots and Life routines use the committed clock/view by default. Optional live inspection is explicitly labeled with its epoch and provisional status; it must not drive durable elapsed-time accounting as though that clock cannot rewind. Reconnect synchronization captures a durable baseline and separately resumes live telemetry. When a fresh live observation must become durable evidence, publish a frontier first under a bounded query policy.

Simulation pauses during world-process downtime; there is no implicit wall-time fast-forward. It continues while brains are idle and while an individual Life is offline. Life-owned routines using the committed world clock select explicit catch-up or rebasing rules and retain world/history identity with checkpoints. Pausing one Life is not pausing the world.

### 6.2 World-owned physical activities

A walk is a world activity with a destination, stable action ID, rules revision, current progress, and a recovery contract. Once admitted, it advances without model calls or per-frame client commands. A human click-to-move and a Life's `start_walk` submit the same `movement.walk_to` operation. The Life retains a corresponding local job; the browser shows the action reference and progress from the same world record.

For version 1, permit one locomotion activity per avatar. A new walk while another is active is rejected as busy unless the caller explicitly cancels/suspends or uses an operation whose documented replacement semantics cover both actions. Do not make a new command silently discard an earlier commitment.

A path may be recomputed when geometry changes. No route produces a recorded blocked/failed outcome rather than an endless hidden retry loop. The world owns intermediate live motion, checkpointed progress, and terminal outcomes. Life stores only its local tracking record and confirmed observations; it does not persist every motion sample. Completion is published only at a durable boundary.

### 6.3 Connection loss is not death or immediate certainty

The world detects an orderly close or an unresponsive controller through its configured liveness policy. Until detection, admitted work can advance beyond the client's last observation, provisionally and through later checkpoints. Suspending after disconnect publishes a consistent frontier. A disconnected controller must reconcile actual state rather than assume an immediate stop at its last received position; page-unload is not the sole stop mechanism.

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

### 7.5 Conversation latency, budgets, and honest availability

A human's input does not force a Life to answer. Separate transport receipt, attention admission, model inference, Gene worker execution, and delivered speech in measurements and UI. The reported Life path includes a model invocation and worker-process startup; include both, plus durable writes, rather than quoting model latency alone. [D2]

Initial **engineering targets**, to validate on a recorded machine with four Lives and up to two browser players:

| Stage | Proposed target / behavior |
| --- | --- |
| Browser feedback after input | Show a local pending marker within 100 ms; this is not server acceptance. |
| Small world operation receipt on loopback | p95 within 250 ms under the declared sustained load; never acknowledge before durability to meet the target. |
| Automatic delivery/availability status | Within one second of a change reaching the adapter; no model-authored response is implied. |
| A reply the Life elects to produce, with an available budget and healthy configured model | Aim for p95 within 30 seconds of deliberation admission, including model and worker cost. Measure queue wait separately and record end-to-end input-to-reply latency. This is not a promise that every message will be answered. |
| Work that will not meet the interactive target | Preserve the message and expose delayed/unavailable status; human play continues. Never manufacture a conversational answer or repeatedly spawn workers to animate a status indicator. |

Keep the reported default ceiling of 100 model calls per rolling hour per Life as a configurable compatibility limit, **not** a target consumption rate. Add explicit input/output token ceilings and a configured per-Life daily spend ceiling before enabling a paid adapter. A candidate local experiment budget is USD 5 per Life per day; this is an operator-chosen budget, not a provider-price assertion. Use configured model rates or authoritative usage for accounting, reserve worst-case cost for admitted calls, count repair/retry calls, and retain the budget window across restarts. Unknown pricing or exhausted accounting uses conservative limits; restarting must not reset the allowance.

The connector may publish coarse status such as `thinking`, `delayed`, `budget_exhausted`, `provider_unavailable`, or `offline`, with an expiry. The UI labels this as operational status, not speech or access to private thoughts. Publish `thinking` only while a real admitted request is active. Show **Received; this Life is currently unavailable** when appropriate, not an endless typing indicator. No exact reset-time promise is needed unless the controller knows it.

Budget exhaustion stops new inference, not the body, network receipt, existing admitted world actions, or inexpensive event routines. Coalesce pending conversational attention and reconsider relevance when budget returns; do not automatically answer an old backlog one message at a time. A provider may remain unavailable; begin with a fake brain and implement one real provider explicitly in milestone 4.

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

The network adapter is a **second implementation behind `body/world`**, alongside the existing local world. Keep common operations familiar, but document asynchronous remote submission rather than faking synchronous success. Existing local tests and demos must continue to run unchanged unless an intentional shared API migration is separately agreed. [D2]

| Operation | Network-profile behavior |
| --- | --- |
| `world.observe(selector)` | Return a cached committed observation with its revision/freshness; it may lag current physical motion. No network wait. Optional live telemetry is a separately labeled view. |
| `world.refresh(selector)` | Queue a filtered refresh; receive a later event, without blocking a brain-produced program. |
| `world.start_walk(destination, tx?)` | Prepare a local tracking job and durable outbound request; return after local publication. The world owns the physical activity. |
| `world.water(...)`, `world.say(...)`, or a generic world operation | Prepare an outbound operation and return a serializable reference, not fabricated effect completion. |
| `world.result(action_ref)` | Read the latest locally recorded status immediately. Pending or unknown stays pending or unknown. |
| `world.on_result(action_ref, code_revision, inputs, tx?)` | Convenience over a durable event-subscribed routine. Schedule short code for a recorded outcome; no waiting stack or implicit model call. |
| `world.cancel(action_ref)` | Record cancellation through the normal delivery kernel and report the eventual race outcome. |
| `world.describe()` | Read current supported interfaces and documentation from the cached catalogue. |

Names are proposed wrappers to map to the actual Life implementation. In version 1, omit `world.await_result` from the supported brain-program surface. The review reports a 3-second execution limit and no generic long-running arbitrary-code job. Keep programs bounded and use event routines instead of raising that limit so a walk can finish. The native transport is polled by the body's normal loop independently of model inference and worker-process execution; a generated program must not monopolize that loop. [D2]

No new mini-language or fixed brain tool envelope is introduced. Functions, loops, conditionals, stored code, and generated helpers remain ordinary Gene; the libraries expose submission and subsequent observation as separate operations.

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

Use event-driven continuation: **submit, retain the next step, return; run short Gene code when the outcome arrives**. A world walk may last minutes without keeping a Life program, worker, or model request alive.

Conceptually:

```text
One Life-local commit:
    prepare walking request O and local tracking record
    register a one-shot outcome routine for O with selected code/input
    publish related cognitive references and the outbox entry
Return immediately.

Later:
    persist world outcome for O and enqueue its subscribed routine
    execute a bounded Gene handler
    inspect the outcome; update state and/or prepare the next request
```

Reuse Life's event-subscription/routine machinery rather than introducing a new general job engine. `world.on_result` may be a convenience wrapper; its stored inputs and selected code revision are ordinary data. No live closure environment or stack is serialized.

Registering a result routine and the outbound request can share one local commit, preventing a fast reply from arriving before the continuation exists. If registration occurs later, atomically inspect retained outcome state as part of registering: an already completed operation triggers the routine once rather than becoming a missed event. Duplicate receipts/events must not enqueue duplicate logical triggers. Retain a trigger ID, source operation/event, current routine revision, and execution status.

For a handler that produces another world request, group the continuation's state change, consumed-trigger marker, and new outbound request in one local commit, using a stable operation identity. External dispatch occurs afterward. Arbitrary nonparticipating effects remain outside that guarantee; a handler interrupted after such work is reconciled, not automatically rerun as if nothing happened.

Cancellation/ownership generations and code-organization changes apply to pending routines as well as pending requests. An old-layout continuation is explicitly preserved as compatible, migrated, invalidated for reconsideration, or blocks selection. Do not silently execute it with a new memory layout.

The local-world `start_walk` implementation remains available for current tests. Networked walking is a world-owned activity with a **local record and event continuation**, not an implementation promise that Life can suspend arbitrary code across minutes or process restarts.

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

### 8.6 Generalize the existing delivery connector

Use Life's existing `connector.gene` delivery machinery as the starting point. The supplied review reports stable operation IDs and semantic digests, receipt queries distinguishing `not_found` from `unknown`, durable cursors and history gaps, cancellation, lane fairness, and process-kill tests. Preserve those contracts while adding a world transport adapter; do not implement a second unrelated outbox and recovery algorithm. Its exact public extraction points must be checked against the local Life revision. [D2]

Extract only the necessary transport-independent responsibilities: outbox state transitions, semantic identity, acknowledgment persistence, cursor/gap handling, retry/cancel scheduling, and receipt reconciliation. Keep HTTP mailbox and WebSocket framing/authentication in their respective adapters. World-specific activity, view-baseline, controller-generation, and rules-version fields belong to the world adapter, not the generic mailbox model.

Use one conformance suite with HTTP and WebSocket fixtures, plus world-only tests. An existing mailbox test pass is evidence for the reused mechanism, not proof of WebSocket integration. Keep its kill/restart tests and the local-world regression suite running throughout extraction. WebSocket remains the selected world transport; a transport-independent core is not permission to silently fall back to HTTP when native setup fails.

## 9. WebSocket as transport

### 9.1 Why use it here

Choose WebSocket for version 1. It supplies a bidirectional connection with message framing and protocol-level close/ping/pong behavior. Native Life clients and the browser can use the same transport family. It is suitable for commands going toward the world and observations going back without tying a response to the lifetime of one HTTP request. [T1]

Use ordinary HTTP for the browser page, static assets, documentation, and large immutable asset blobs. Do not send a multi-megabyte model or texture through the control queue simply because a socket exists.

This is initially a social, building, and everyday-activity world, not a low-latency competitive action game. WebSocket is the selected starting transport for real human play as well as Life processes. WebRTC, UDP simulation protocols, a message broker, and an RPC framework are not prerequisites for the first neighborhood. Keep serialization and command handling separate from the WebSocket adapter so another transport can be added without changing world semantics.

WebSocket does **not** define this application's durable receipt, replay, deduplication, or resume behavior. Those are specified below. A successful socket send is not a committed world action.

### 9.2 Encoding and protocol version

Use one complete UTF-8 JSON object per WebSocket application message. Accept it in text or binary messages under the same bounded decoder; the current native client queues binary byte messages, so requiring text-only sends would need extra binding work. A binary payload here contains UTF-8 JSON, not an alternative executable format. Reassemble before decoding; reject invalid UTF-8 and invalid JSON identically. Browser and server adapters must support the chosen framing in the first interoperability test. JSON does not replace Gene as the language of brains or body libraries. [R2, T4]

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
| `world_revision` | Last committed world frontier, not a blanket precondition on every action |
| `live_seq` / `committed_sim_time_ms` | Epoch-local live sample ordering / last durable simulation time; distinguish provisional motion from committed evidence |
| `rules_revision` | Selected world behavior/configuration revision; changes only when those semantics change |
| `owner_id` / `owner_generation` | Optional controller-local work ownership; interpreted within the authenticated participant, not a global goal schema |

Logical ticks advance live simulation state; checkpoints or action commits advance `world_revision`. Neither automatically changes `rules_revision`. Do not invalidate every pending thought because another avatar moved. Use explicit target preconditions and operation/rule compatibility. A new `server_epoch` invalidates old live samples, not durable operation identities.

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
| `telemetry` | World → browser / opted-in client | Replaceable server-owned samples; include epoch, live sequence, committed base, and explicit provisional status |
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

### 9.7 Concrete transport/build baseline

Use Commons-owned copies/adaptations of the server-side `$net/http` WebSocket wiring and Gene web-profile `$ws/*` browser path illustrated by Miclone. Import the underlying Gene APIs directly. Keep the host's `serve` tick loop free of model calls and unbounded client work. Verify Commons session/Origin handling and subprotocol selection against the actual server API; copied handshake code is a starting point, not an implementation of this protocol by itself. No transport setup step launches Miclone or reads its generated files. [R1]

For Life processes, use `src/genex/websocket`. Its documented prerequisites are **libcurl >= 8.11 built with WebSocket support**, Nim, a C compiler, and `pkg-config`. On macOS use a WebSocket-enabled Homebrew curl rather than assuming the system curl satisfies the library. This version requirement belongs to the Gene binding; it is not a claim about when WebSocket was first standardized or added to curl. [R2]

Repository-documented build path:

```sh
brew install curl pkg-config
python3 src/genex/websocket/tools/build.py   --pkg-config-path "$(brew --prefix curl)/lib/pkgconfig"
```

On Linux, supply the equivalent development library and verify its WebSocket support. Do not require SDL2/SDL_ttf for a headless Life client merely because Miclone's optional native graphical shell uses them. Check library loading, `ws`/`wss`, complete-message reassembly, polling, and shutdown with an independent peer before admitting the Life connection. Pin the actual build in experiment metadata. [R1, R2]

The current native API documents queued sends and `receive` polling that also advances writes; nil means no complete message, not a disconnected peer or an empty frame. Poll it outside generated foreground programs, under a small bounded work budget, including while the brain is idle or unavailable. Keep all accesses on the owning thread; do not busy-loop or spawn a model call to pump transport. Close can discard queued bytes, so durable receipts—not send return values—remain the recovery basis. Native hard message limits are ceilings; Commons' smaller configured limits still apply. [R2, T6]

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

Retain an exact anti-replay record for every admitted/rejected/cancelled operation throughout the supported history. This does **not** require full receipts, transcripts, or every event to stay in a repeatedly rewritten hot database image. Archive cold detail under §12.8 while retaining addressable proof of its result/identity. Until archival or an incremental store is implemented and measured, cap the experiment and pause admission before exhausting its storage budget. Deleting an old ID and accepting it as new is never an acceptable performance optimization.

### 10.3 Atomic world application

For a validated, previously unseen human or Life command, the world performs the same bounded serialized transition:

```text
Validate controller generation and compatible operation contract.
Check current physical preconditions in the server-owned live state.
Prepare changes, recipient observations, and the result.
Include pending simulation changes in the same consistent frontier.
Commit receipt + physical changes/action record + durable recipient events.
Only then expose the receipt and publish notifications.
```

A normal precondition or domain rejection can itself be retained as the command's immutable rejected result. Invalid framing/authentication or unavailable transport is not a committed operation and carries no false receipt. A persistence failure prevents publication and puts dependent processing into a visible recovery/failure state.

For a long action, admission commits the action record first. Intermediate movement may remain provisional; periodic/action-boundary checkpoints commit its progress with the physical state (§6.1). A terminal or suspension status is committed before its receipt/event is published. Statuses are `queued`, `running`, `suspended`, `completed`, `failed`, or `cancelled`; durable terminal statuses do not revert. Admission distinguishes rejection from failure of an already admitted activity.

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

**Do not require a persistent browser journal or IndexedDB in version 1.** Keep a small in-memory pending map, stable operation IDs, and the server's existing receipt/action history. Browser caches and drafts may disappear on refresh; accepted world effects and participant identity do not.

Within one page session, allocate one unpredictable operation ID per deliberate action before sending. Retain its exact semantic payload in memory until settled. Retransmission after a transient socket reconnect uses that same ID and payload. A spinner timeout is not permission to create another gift, pickup, or message. The initial UI admits one ordinary command at a time, separately tracking already accepted long activities.

After a **page refresh or lost client state**:

1. Reattach the same participant and acquire a new control generation. Fence the old controller and its unadmitted queue before declaring this client ready. An old connection must not admit an action after the new recovery barrier.
2. Synchronize the avatar/current view and retrieve current actions plus paged owner receipts and eligible conversation history. Include work admitted before the fencing barrier and catch up later durable status events. The server identifies coverage/truncation; an arbitrary recent-list limit is not proof that nothing happened.
3. Show the actual recorded outcomes and suspended activities. Never reconstruct and automatically resend old input gestures, text, or operations from the new view.
4. Requests whose ID/payload were lost and never became server records are not recoverable client intent. Tell the player that unconfirmed input or drafts may have been lost. A deliberate new action is allowed only after synchronization and review of current state; it is not labeled a retry of an unknown prior operation.

For receipt history that is unavailable or incomplete, display uncertainty and require explicit human judgment; do not automatically reissue an apparently missing action with a fresh ID. Stable-ID deduplication prevents repeated application of a **known logical operation**, not duplicate human intent authored under new IDs. Dropping the journal is therefore a scoped simplification, not a claim that all refresh ambiguity disappears.

The server supplies the owner-only current action list and receipt/history queries to new tabs or devices. No browser-local write must succeed before play. If IndexedDB is unavailable, normal play still works. A later optional draft/pending cache can improve convenience without becoming the authority for inventory, transcripts, or receipts.

Apply this rule to chat and object transfers. **Accepted** differs from **completed**; **sent to a socket** establishes neither. Do not use optimistic UI animation as an execution record.

### 10.8 Receipt queries: absence is not uncertainty

Reuse the connector's explicit result classes instead of mapping every unsuccessful lookup to “not sent”:

| Query outcome | Meaning / permitted response |
| --- | --- |
| `found` | Return the recorded semantic request, receipt, and latest committed activity status. Do not execute again. |
| `not_found` | The healthy server has authoritative coverage for this participant/history/ID and no receipt or tombstone exists at the query boundary. A client retaining the exact request may resend **the same ID**, subject to current admission rules. |
| `unknown` | Required history, archived detail, or a reliable store read is unavailable. Do not generate a new ID, infer nonexecution, or automatically repeat the effect. Reconcile or expose uncertainty. |

A negative query alone does not cancel an in-flight command. Same-ID resend is safe through deduplication; cancelling uses a durable tombstone. After browser refresh, old controller generations are fenced before recovery is declared complete. Query results and recovery summaries carry a coverage boundary or explicit truncation/gap, not merely a short “recent results” list presented as exhaustive. [D2]

## 11. Events, snapshots, reconnection, and backpressure

### 11.1 Separate durable observations from render telemetry

The world owns an ordered durable observation stream for each participant, human or Life. Audience is determined at the event's committed moment. Recipient-local sequences keep filtering from creating unexplained holes or revealing another participant's unseen events. Observer telemetry is a separate subscription, not the actor's authoritative inbox.

Durable events include admitted action outcomes, eligible conversation messages, meaningful committed environmental observations, and rule/history changes. Frequent transforms and transient visibility baselines use a separate coalescible presentation stream. A Life does not commit each browser-rate sample to its history. Any fact represented as a durable event comes from a committed frontier; provisional visibility or motion is explicitly labeled and is not retrospectively rewritten as confirmed history.

Sample or coalesce before assigning durable event IDs. Commit network intake in bounded batches with one cursor transition, not one full-store publication per render frame. Keep the synchronized current view separate from the retained event history, and replace stale telemetry in memory. A committed event is never changed under the same sequence.

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

A Life persists the event before acknowledging its durable cursor. Storing it does not mean the brain considered it or completed a commitment. A browser acknowledges only after installing the ordered batch in its current session; it is a flow-control acknowledgment, not evidence of persistent browser storage, human reading, or permission to delete the sole retained human transcript. Section 11.4 defines the difference.

Deduplicate by stream identity and sequence/event ID, and correlate direct receipts with events by operation/action identity. Receiving both must not create two completed jobs or two copies of the same speech.

### 11.3 A consistent reconnect sequence

Reconnection must recover historical messages as well as current position. A fresh snapshot alone cannot recreate an unacknowledged conversation.

Use this sequence:

1. Authenticate and establish the new control generation, but do not yet admit new ordinary mutations.
2. Read the participant client's last valid event cursor A; a browser without usable local history requests retained server history and a fresh baseline instead of claiming it has all prior events.
3. At a serialized boundary, capture the latest **durable** filtered snapshot at world revision R and recipient stream cut C. Do not fold an uncommitted motion tail into that durable baseline. Pin the required replay range while synchronization proceeds.
4. Send `sync_begin`, then the retained events after A through C in ordered, bounded pages. Persist these as observations even when a newer snapshot supersedes their old view-state changes.
5. Send the complete snapshot associated with R/C, including current visible entities, own avatar/inventory, relevant actions, world/rules metadata, and view-generation identity.
6. The client atomically installs the complete snapshot and sync metadata after the required preceding events have been stored/installed under its contract. A Life makes this a local durable commit. A browser publishes the complete view to its UI only after the baseline is complete. Neither reapplies older positional deltas on top of it.
7. Deliver durable events after C and separately resume epoch-tagged provisional telemetry. Their baselines/order are distinct; a mismatch resets the affected view rather than duplicating historical effects.
8. Reconcile outstanding operations or browser owner-receipt coverage; acknowledge under the Life-durable or browser-session contract and enter ready state.

The world continues serving other participants and ticking during this process. Capture the cut consistently, but do not hold an open world transaction while sending pages over a slow socket. Bound the pinned range/snapshot lifetime; if it expires, restart synchronization explicitly.

On a required event gap, do not advance the acknowledgment past it. A client may preserve an unknown optional event as opaque data and acknowledge it; an unknown required schema prevents affected processing until upgraded or explicitly resynchronized under a compatible contract.

### 11.4 Retention and gaps

Retain unacknowledged essential recipient events in retrievable storage, but not necessarily in the active image or memory. Limit queued bytes/events per participant and apply the storage policy in §12.8. At the limit, suspend affected ordinary production/admission or enter visible maintenance; do not silently drop promised events. Keep exact operation anti-replay information separately. A snapshot does not replace a conversation or proof of an exchange.

For a native Life, an acknowledged event may later be pruned under a documented policy once its relevant history is durably retained in that Life's store. For a human player, browser caches are not the permanent transcript: retain accepted in-world messages and the participant's eligible conversation/history records on the world server under an explicit retention policy independent of browser ACKs. An operator or secondary read-only tab cannot acknowledge away another controller's essential history.

If an explicitly selected retention/deletion policy removes history, retain the coverage/gap metadata and send `history_gap` with the missing range and a current snapshot. Record/show the gap rather than inventing lost dialogue. A human reconnecting from a new device can retrieve retained eligible history even without the old browser's cursor. Do not replay the entire world's conversation to compensate for a missing cursor.

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
Restore the latest durable frontier and activity progress; discard any provisional tail.
Create a new server epoch; invalidate old leases and all prior live telemetry.
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
| World exits during movement | Restore the last checkpointed position/progress/time; discard provisional samples and suspend until controller reconciliation. |
| Life exits while other Lives act | Others continue; reconnecting Life sees current world and its retained history. |
| Controller takeover while old commands are queued | Fence the old generation before admission; retained accepted work follows suspension/recovery policy. |
| Browser refresh after sending, before receiving a receipt | Fence the old generation, recover server-known receipts/actions, and do not auto-resend lost intent under a new ID. |
| Browser storage is cleared | Restore the registered actor and retained server history; unsent drafts may be lost, accepted world effects are not. |
| Old world snapshot is restored intentionally | New history branch; never transparently replay old-history commands. |

### 12.7 Browser reconnect, refresh, and logout

Refresh attaches to the same human participant through its server-issued session. Resolve writer ownership, fence the prior generation, install a durable filtered baseline, recover owner receipts and eligible history, and then resume live telemetry. A same-page reconnect can reconcile retained in-memory operation IDs; a refreshed page does not reconstruct a journal. Never upload old browser positions, inventories, or predictions as world authority.

Show **Connecting**, **Synchronizing**, **Connected**, **Controlled elsewhere**, or **Disconnected** based on actual protocol state. Disable mutating controls until ready; retain editable unsent text separately. When a saved activity is suspended, show its target and actual progress and offer Resume/Cancel rather than silently continuing it. Closing the browser does not abandon a Life's commitments or stop other actors.

Logout ends only the human application session and requests orderly detach; when the socket cannot deliver that request, liveness expiry settles control under the same disconnect rule. The world retains the player registration, avatar, possessions, and accepted history for a later login. Ending a session is not deletion of a participant. Model-driven takeover of a disconnected human is not part of version 1.

### 12.8 Storage feasibility, retention, and growth gates

**Do not assume Gene's current SQLite binding behaves like a conventional incremental on-disk SQLite connection.** Miclone's storage source explicitly describes publishing a connection image through Gene's filesystem layer, batching that publication with transactions, and not controlling it through WAL/synchronous pragmas. The supplied review additionally reports whole-file rewrite/fsync per commit. That explains why committing every 100 ms is not the chosen design. This is a binding-specific constraint, not a property of SQLite generally. [R3, D2, T3]

For the first bounded browser demo, reuse that binding behind `WorldStore`, with §6.1's action commits and periodic checkpoints, actual batched transactions, and a deliberately small world. There must be only one image publication for one logical batch. A flag that accepts `WAL` is not evidence of a different I/O path.

**Before sustained multi-Life operation**, benchmark the actual backend with retained records and action load. If action commits/checkpoints block transport or grow beyond the declared targets, replace the storage adapter with a genuine incremental disk-backed SQLite connection or another proven incremental transactional implementation. Preserve the application transaction/receipt contract. This is a targeted storage integration, not permission to weaken confirmed-effect durability, build a new database, or assume a different backend already exists.

#### Bound the active data path, not the Life's identity

Separate current operational state from cold history. Current world/entities, active jobs, pending outboxes, live registrations, selected code/data roots, unresolved deliveries, cursor positions, and cancellation generations remain directly available. Context snapshots, settled decision diagnostics, acknowledged event detail, and old transcripts can move to immutable, queryable cold segments after retention checks. Do not load or serialize all retained history on every cycle.

For Life, bounding history is an explicit pre-soak task. Keep cognitive memories/current roots selected by the Life; do not arbitrarily delete preferences or commitments to meet a cycle benchmark. Bound the **hot operational tail** and context inputs, archive settled detail, and retain evidence links or explicit deletion markers. Pinned work includes unresolved requests, unconsumed result triggers, pending subscriptions, active/recoverable jobs, selected code/decoder versions, and references still needed to reconstruct retained contexts. A receipt needed to resolve uncertainty cannot expire just because it is old.

Proposed starting limits, to tune from measurements:

| Item | Initial bounded experiment policy |
| --- | --- |
| Life hot settled cycle records | Keep the latest 200 plus pinned records; archive older settled detail after its references are preserved. |
| Life hot settled event detail | At most 2,000 entries or 8 MiB, whichever is reached first, excluding pinned operational state; archive/compact before widening the window. |
| Browser recent-history page | 100 records/page with explicit coverage and pagination; not an exhaustive absence proof. |
| Essential unacknowledged delivery backlog | 5,000 events or 16 MiB per recipient as an admission/maintenance threshold, not a drop-oldest queue. |
| World hot store / rewritten image | Initial 32 MiB warning and 64 MiB admission-stop thresholds until an incremental or archival path passes measurement. |

These are **new proposed defaults**, not measured limits or a fixed cognitive schema. If pinned state or a needed exact index exceeds a bound, stop new affected work visibly or migrate storage; never erase it to force a count down. Indefinite life/history retention is not achieved merely by selecting a number.

Archive publication must be crash-safe: write and durably validate a cold segment first; commit its manifest/reference and safe removal from the hot set afterward. A crash may leave an unused segment, never a selected missing segment. Keep metadata sufficient to locate exact operation IDs and retained history. If that index itself becomes too large for the image-rewrite backend, use incremental storage rather than scan every archive or keep expanding a monolithic map.

Deduplication proofs and cancellation tombstones survive archival. An unavailable archive yields `unknown`, not `not_found`, and blocks unsafe replay. Human transcripts remain server-owned and subject to explicit retention, independent of browser ACKs. Document archival/deletion behavior and preserve privacy and source visibility in derived summaries.

#### Measure before widening the experiment

The supplied 128 ms → 1.24 s Life-cycle measurement is a reported warning, not a reproduced benchmark. Record the Life/Gene commit, machine, retained bytes/rows, fake or real brain, and workload before making comparisons. [D2]

Use a deterministic fake-brain workload at 200, 2,000, and 10,000 accumulated cycles with increasing world events. Record p50/p95 cycle cost excluding model time, worker startup, commit latency, bytes written per commit, hot-store size, retained object count, archive growth, and reconnect time. The target is that per-cycle hot-path cost does not grow linearly with **cold history** after compaction; current state growth still has real cost. Run four independent Lives plus browsers only after the bounded path and crash tests pass.

Test retention and restart together: archive during pending operations, interrupt archive publication, replay a duplicate after archival, and reconnect a human from a fresh browser. Keeping a short prompt alone does not bound the storage engine's cost. No achieved throughput or test pass is claimed by this design.

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

Its contract must say how much water can move in one logical step, which containers are connected, what happens on blockage, and how resource quantities remain nonnegative and conserved according to the simulation rules. Water/moisture updates and their related progress remain in the same live simulation frontier and are checkpointed together. Any durable flow outcome or material-changing user interaction publishes its causal frontier before confirmation (§6.1). Declare whether growth reads moisture before or after irrigation during a tick; no feature may make confirmed events depend on subsequently discarded provisional state.

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
→ in-memory pending map (no IndexedDB prerequisite)
→ WebSocket submission
→ shared authoritative world handler and transaction
→ receipt / activity events / updated visible state
→ UI confirmation, progress, or a concrete failure reason
```

Use the same `movement.walk_to`, `object.pick_up`, `conversation.say`, and later feature operations as Life clients. The server—not the UI—validates actor binding, distance, possession, target revision where requested, and operation-specific access. A missing or stale UI button cannot establish whether a command is valid at application time.

Show a pending placement marker or requested destination separately from confirmed state. Inventory transfers are shown as complete only after the world result. For long work, distinguish local queued, server accepted, running, suspended, and terminal states. A person may continue independent interactions while an activity progresses, subject to ordinary world rules.

### 15.3 Movement, cameras, and time

Click-to-move starts a server-owned walk, the same as an AI request. Start with a third-person/isometric camera, orbit/zoom, and a readable world. Camera input is local presentation; physical movement remains a world operation. A later direct-keyboard mode follows section 6.5 rather than trusting client positions or relying on key-up delivery.

Render timestamped server samples smoothly, keeping the durable baseline separate from explicitly provisional live motion (§6.1). Use server epoch, view generation, live sequence, and entity revision to discard stale data after restart/resync or migration. A crash can correct only the provisional tail. Neither interpolation nor provisional telemetry confirms inventory changes, activity completion, or durable Life observations. Client prediction is not required for click-to-move.

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

Start with Commons-owned source copied and adapted from Miclone's Gene web-profile/WebGL2 browser path (§1.4). Bring the required picking, camera, recipe-driven appearance, shader/assets, and relevant build/smoke code into the Commons tree. Build from those local sources, with no imports, asset URLs, script calls, or generated artifacts from `examples/miclone`. Add the player interaction panel and server-owned motion; freely change the copied interfaces and presentation where this design needs it. Miclone performance is not a Commons benchmark, and client-authoritative physics must not survive as a compatibility shortcut. [R1]

## 16. Configuration, package layout, and running processes

### 16.1 A possible source layout

```text
world/
  SOURCES.md                copied-source paths/revisions/notices; not a dependency manifest
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
    session.gene             attach, fencing, in-memory pending state, server receipt recovery
    input.gene               click-to-move, selection, chat, interaction forms
    view.gene                filtered state, renderer, inventory and progress
    operator.gene            explicitly separate experiment controls
  assets/                    Commons-owned selected/adapted assets and their notices
  tools/                     local build/smoke scripts; no Miclone path dependencies
  tests/                     copied/adapted tests plus Commons crash/network/invariant fixtures

life/
  ...                        independent Life implementation from life.md
  body/world_client.gene     second world adapter: short calls, result routines, observed view
  delivery/                  extracted connector state machine; retain HTTP mailbox adapter
  transport/world_ws.gene    genex/websocket polling and Commons protocol adaptation
  config/                    common settings and individual seed definitions

experiment/
  config.gene                process configuration and controlled seed mapping
  launch                     optional script, not a new runtime framework
```

This layout names responsibilities, not a request to write all code from scratch. Populate the relevant `world/` modules with selected copies from Miclone, bring over their necessary assets/tests/build inputs, rewrite references to Commons-owned paths, and adapt them in place. The original Miclone tree is not part of the Commons dependency graph. Start Life networking by generalizing its existing connector and adding an adapter beside the local world; that Life-internal refactoring is separate from Miclone reuse. No new shared engine package is required. Each process still owns its runtime objects; a file-level global is not a cross-process object.

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

A store path belongs to its owner. Lifetimes, flushes, migrations, and backups follow that owner's contract. Do not let the browser or Life processes open `world.sqlite` directly. Human profiles, accepted world history, inventory, and operation receipts are owned by the world store; the browser initially has only an in-memory pending map, installed view, and drafts. No `lives/human/life.sqlite` is required.

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

The world configuration selects storage, world/history identity, bind address, modules, simulation settings, initial content, and player-session/Origin settings. Each Life configuration selects its own store, identity, `local` or `network` world adapter, brain adapter, retention/budget policy, and seed reference only for creation. Model credentials stay with the Life; neither the world nor browser needs them.

Once the HTTP/WS host is ready, the human opens the configured player URL, for example `http://127.0.0.1:8096/`, signs into its locally provisioned player session, and joins. That is an application route to implement, not a new Gene CLI command. Creating a player is explicit; refresh/relogin resumes the existing one. A launcher may open the page, but closing it must not signal global shutdown.

### 16.4 Process health and practical controls

Expose simple process-level status: ready/recovering/paused, current world/history, selected code revisions, connected controller count, queue depth, simulation lag, pending outbox count, oldest unacknowledged event, and unresolved operations.

Keep failures linked to operation, action, event, cycle, and revision IDs. A log line saying “sent” must not be used as a durable execution result. Avoid dumping every private model context into a global world log.

Use per-process memory/execution limits, a bounded brain-call budget, rate-limited participant queues, and reliable operator controls. These are application/deployment choices. Do not reintroduce the removed Gene capability system or make JIT or a production distributed scheduler a prerequisite for this experiment.

### 16.5 Preflight and measured deployment profile

Before connecting a Life, record the Commons, Gene, and Life revisions, WebSocket native-library build, curl version/features, storage adapter, and selected world manifest. Run Commons' own browser/server fixtures, the independent native WebSocket library's peer test, and Life's local-world/mailbox suites. Useful Miclone tests are copied and adapted under Commons ownership; the original Miclone suite is not required. Include a clean build/test with its source and outputs unavailable. The review's 110-test count is a reported Life baseline; record the actual suite and results rather than freezing the number. [R1, R2, D2]

Model-provider configuration is separate from the native execution worker limit. A remote inference request may take longer than three seconds without turning a generated program into an unbounded worker. Keep inference cancelable and asynchronous with respect to the body, and keep returned code within the selected short-execution policy. Implement one real adapter, its framing parser, timeout/retry rules, usage accounting, and failure observations before calling a milestone “real Lives.” A protocol-shaped fake brain does not complete that work.

Specify and measure the action/interaction targets in §7.5 and the storage-growth gates in §12.8. Report delayed replies, budget exhaustion, storage lag, worker failure, and provider unavailability distinctly. Do not classify an idle Life as broken merely because it chooses not to speak.

## 17. Implementation milestones

### Milestone 0: make a self-contained source starting point

Select the useful Miclone files at a recorded source commit and copy them, their necessary dependencies, relevant tests, and selected assets/build steps into the Commons tree. Remove cross-project imports and paths, adapt package/entrypoint names, and establish a clean Commons build with `examples/miclone` and its outputs unavailable. Record provenance and baseline results. An original Miclone build can help diagnose a copy but is not a permanent prerequisite. Establish the actual storage-publication behavior on the copied/adapted path.

Native curl setup and Life tests are **not prerequisites for the browser-only milestone**: pin the actual Life checkout, run its local demo/mailbox regressions, and run the independent native WebSocket peer test before milestone 2. This is a selective copying/integration step, not a new engine project or shared-library extraction; leave original Miclone and local Life behavior unchanged.

### Milestone 1: one browser player and the world

Build the independent Commons application from its locally copied/adapted source. Run one Commons server and one browser actor, with no Miclone process, Life process, or model provider required. Use and adapt the Commons-owned renderer/socket host. Implement server-owned click-to-move, a small scene, one unique object, participant binding, minimum session/Origin checks, control-generation fencing, durable action receipts, and owner current-action queries. Use an initial full snapshot plus bounded live updates; the mature recipient replay protocol need not block the first walking loop.

Use action-boundary commits and periodic checkpoints from the start. Show provisional motion separately from confirmed interactions. Refresh, fence the old page, and recover server-known results without IndexedDB. Prove a confirmed pickup survives a server crash and an uncheckpointed motion tail is corrected honestly. Full inventory/crafting/UI catalog polish, four brains, and Life inbox persistence are not milestone-1 dependencies.

### Milestone 2: attach one Life, then two, using the existing connector

Keep the local world/demo intact. Add the network adapter and generalize connector delivery state rather than rewriting it. Run one fake-brain Life in its own process/store through `genex/websocket`; implement the durable outbox, `found/not_found/unknown`, recipient cursor, snapshot/replay, and world-result subscriptions. Then add a second fake-brain Life and make human and Life requests contend through the same operation handler.

Express walk-then-act through a stored event routine, not `await_result` or a long-lived worker. Persist its subscription with the outbound request and verify fast completion, duplicate delivery, and cancellation. All network code remains outside short brain-program execution. Complete the real process boundary and filtered recipient recovery here.

### Milestone 3: durability, bounded storage, and independent recovery

Test Life exit before/after send, lost world reply, browser refresh/takeover, world crash during movement, cancellation before arrival, and replay after archive/compaction. Restore committed state without duplicate effects or rewinding another participant's confirmed history. Prove the network profile's checkpoint behavior separately from the stricter co-located local-world fixture.

Implement bounded active Life history and world event delivery before long runs. Run §12.8's growing-history benchmarks and hot/cold retention tests. Replace the whole-image backend with an incremental adapter if it cannot sustain §7.5's goals at the agreed retained size. Merely reducing the number of database commits does not close the growth issue. Passing this milestone is the prerequisite for sustained multi-Life sessions.

### Milestone 4: one human and two real Lives

Implement and test **one real brain adapter** as explicit work. Handle the note/program response, model failure, cancellation, usage, and worker execution separately. Split immutable creation seeds from editable dispositions in context construction. Run first with one real Life, then two independent contexts and stores.

Measure response latency, worker overhead, token/cost consumption, and fairness under human conversation. Exercise exhausted call/token/spend budgets: the UI shows coarse availability, the body keeps receiving events, and the world remains playable. A delayed or declined AI reply is not a server failure. No human player needs model credentials.

### Milestone 5: four individuals and a useful neighborhood

Create Aster, Brin, Cove, and Dara with the same basic abilities and short seed differences. Retain immutable creation records and evolving current dispositions. Add homes, a noticeboard, simple garden behavior, and one useful workshop/kitchen activity. Improve the Commons-owned renderer's presentation; this is polish and domain content, not the first introduction of a browser engine. Changes need not remain compatible with the Miclone source from which it began.

Run the human–AI continuity demonstration with measured storage and inference budgets. Do not turn seed labels into permanent occupations.

### Milestone 6: prove world expansion, then private Life evolution

Add a region using existing schemas, then irrigation or one household behavior module. Preserve IDs, current state, receipt history, and compatible activities; test a queued command, old browser, offline Life, and crash during migration. Expose the new operation through the browser catalogue and Gene documentation.

Separately let one Life change a learned procedure or cognitive organization while the others continue. Account for queued event routines and pending requests using old data. World expansion and private memory evolution remain independent changes.

### Integration checks before claiming support

For each milestone publish the actual revisions, declared build dependencies, test commands/results, and measured workload. Copied Miclone code and generalized Life connector code reduce implementation scope but do not prove new authentication, server motion, Commons persistence, or WebSocket recovery correct. Commons build, test, and release commands must not depend on the original Miclone tree or its test status. No benchmark or passing test is claimed by this proposal.

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
| W4 | Publish a movement checkpoint/action boundary | Position, progress, simulation clock, and durable outcomes agree; intervening telemetry is labeled provisional. |
| W5 | A browser or Life floods commands or stalls reads | Bounded per-participant queues do not stall other actors or grow without limit. |
| D1 | Abort Life group before request commit | Neither local job publication nor world dispatch occurs. |
| D2 | Exit after local commit before send | Recover the same pending operation, not a new ID. |
| D3 | Lose world reply after effect commit | Resend/query returns the retained outcome; effect is not repeated. |
| D4 | Reuse operation ID with changed input | Reject conflict without effects. |
| D5 | Cancel arrives before original request | Tombstone prevents later original admission. |
| D6 | Cancel arrives after completion | Report completion/too-late, not fictitious rollback. |
| D7 | World commit fails | No durable success is exposed; freeze/recover dependent work and invalidate any provisional tail without losing earlier receipts. |
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
| H2 | Refresh after world commit before receipt, with no local journal | Fence the old controller, recover its server-known receipt/action, and do not automatically create a second operation. |
| H3 | Clear browser cache and log in again | Same avatar/possessions and retained eligible server history; lost unsent drafts are not invented or resent. |
| H4 | Open two tabs as one human | One mutating controller; explicit takeover fences old queued commands and leaves read-only observation possible. |
| H5 | Use another participant ID or hidden object ID in input | Connection binding and filtered query/action checks prevent redirected control or private-field disclosure. |
| H6 | Browser has no IndexedDB or persistent application storage | Normal play works; in-session retries retain IDs, refresh recovers server facts, and unrecorded intent is not guessed. |
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

Additional feasibility and regression cases:

| ID | Scenario | Required result |
| --- | --- | --- |
| F1 | Establish the copied-source starting point | Selected browser/transport/renderer code, necessary assets, and relevant tests live in the Commons tree with source provenance; original Miclone files remain unchanged. |
| F2 | Browser sends a client-computed position | Never accepted as authoritative movement; server walking/physics governs both controller types. |
| F3 | Ten logical ticks with no durable action | No requirement for ten whole-image commits; periodic checkpoint cadence and dirty-horizon limits are honored. |
| F4 | Crash after live movement but before checkpoint | Restore durable position/time; new epoch discards provisional samples; no confirmed outcome is undone. |
| F5 | Pickup/speech depends on an uncheckpointed position | Commit the causal position/frontier with the effect/audience before success; crash cannot retain an impossible interaction. |
| F6 | Dirty horizon or hot-store limit is reached | Slow/pause admission and report maintenance; do not silently drop receipts, promise durability, or enlarge the loss window. |
| F7 | World activity exceeds the Life program limit | Short submitting program returns; event routine continues after the actual result with no held worker/model call. |
| F8 | Completion races result subscription | Atomic registration/current-result handling produces one logical trigger; none is missed or duplicated. |
| F9 | Duplicate result arrives while follow-up is prepared | Trigger consumption, local state, and next outbox request are atomic or reconciled; no new-ID duplicate follow-up. |
| F10 | Existing local-world demo and HTTP connector tests | Remain valid after adding the network profile and extracting delivery logic. Record actual test inventory, not an assumed fixed count. |
| F11 | Missing curl WebSocket support or native library | Preflight fails clearly; no silent transport downgrade or unbounded reconnect loop. |
| F12 | Native send has queued data but no inbound application events | Normal host polling advances writes; no busy wait or brain call is needed to pump the connection. |
| F13 | Receipt lookup is `unknown` versus `not_found` | Unknown never causes an automatic new-ID repeat; definitive absence is scoped to covered history, and known requests retain their IDs. |
| F14 | Edit disposition and restart | Current context uses the editable state while the creation seed remains immutable provenance. |
| F15 | Model/worker/budget failure during human chat | Show accurate coarse status, preserve receipt/history, and keep world controls and body receipt active. |
| F16 | 200 → 2,000 → 10,000 fake cycles with growing events | Measure hot-path/commit costs and verify bounded active history; cold-history growth is not copied into every decision. |
| F17 | Archive publication interrupted | Retained records remain locatable; orphan segments are tolerable, selected missing segments are not. |
| F18 | Replay an old operation after archival | Exact deduplication/result or explicit unknown; never execute because the hot receipt was removed. |
| F19 | Refresh loses an unsent command | No client journal is required; server facts are restored and the UI discloses lost unconfirmed input rather than inventing a resend. |
| F20 | Old socket and refreshed page overlap | Fencing and the recovery barrier account for already admitted work and prevent late old-generation admission. |
| F21 | Cold receipt pages are truncated or unavailable | Report coverage/uncertainty; absence from a recent list is not proof of nonexecution. |
| F22 | Event routine is queued during a cognitive-schema replacement | Preserve compatibility, migrate, invalidate visibly, or defer; never run an old-layout continuation against new-layout data. |
| F23 | Native binary JSON and browser text/binary JSON interoperate | One complete bounded UTF-8 JSON decoder and the same semantic validation; no codec-induced identity changes. |
| F24 | Clean build and smoke test with `examples/miclone` and its generated outputs unavailable | Commons builds its browser/server from its own files and declared platform dependencies; no source import, asset fetch, script, fixture, or launched process requires Miclone. |
| F25 | Original Miclone changes after copying | Commons remains on its own selected code; no build-time recopy or automatic update occurs. Any adopted fix is an explicit local change tested against Commons behavior. |

Test network faults with real separate processes: close sockets at selected points, delay receipt delivery, replay an old command, kill one process, and verify durable records after reopening. Assertions must inspect the actual item location, action count, receipt identity, and recipient inbox—not only returned status text.

### 18.2 Behavioral comparisons

Record common/individual seed revisions, initial placements, world rules/content revisions, model configuration, brain-call budgets, and selected Life code revisions. Distinguish scripted human-input fixtures from exploratory human sessions, and retain the relevant action/conversation trace; human participation is an experimental input, not controlled merely by using the same seed. Repeat runs and swap seed-to-position assignments. Compare identical seeds as a baseline so ordinary model variability is not misidentified as a personality effect.

Look for continuity of interests, preference recall, revision after contradictory evidence, chosen places, learned procedures, information exchanged between Lives, useful restraint, and reactions to changed circumstances. Allow both divergence and convergence. Distinct writing styles alone do not demonstrate distinct persistent behavior.

Recovery reconstructs durable frontiers and recorded action outcomes. It does not promise to reproduce discarded provisional frames. Optional diagnostic traces may record those separately. Reissuing model calls is a new behavioral run, not deterministic replay; keep that distinction visible.

### 18.3 A first public demonstration

One human enters through the browser while two independent Lives inhabit the same garden/workshop scene. The human walks over, speaks, and makes a watering can available through the implemented transfer interaction. A Life observes it, decides whether and when to respond, and starts an activity. The human refreshes and returns to the same avatar, possessions, eligible conversation, and current world, without repeating the transfer. Closing the browser leaves the world and Lives running.

Then expand to four lightly seeded Lives, stop/restart one during a walk, and have the human return later to inspect persistent changes. Add an adjacent place or feature while preserving identities and receipts. New browser interactions and Life documentation should expose the addition without resetting inhabitants or scripting their roles. Human play and independent AI continuity are both demonstrated by actual outcomes, not just by displaying several avatars.

## 19. Decisions to keep visible

The following are selected design choices, not unresolved hidden defaults:

| Choice | Version-1 decision |
| --- | --- |
| Deployment | Separate world process and process per AI Life; human controllers run in browsers, not extra Life processes |
| World consistency | One authoritative writer; no world sharding or replicated writers |
| Storage | Separate owners; action-boundary commits plus periodic world checkpoints; bounded hot history and a measured incremental-storage gate; no distributed `store.commit` |
| Source reuse | Selective Miclone source copies maintained as Commons code; no Miclone package/build/runtime/test dependency or automatic synchronization |
| Transport | Commons-owned HTTP/WS and browser code using Gene APIs directly; genex/websocket for Life; shared Life connector delivery state; HTTP assets |
| Brain interface | Ordinary Gene code plus a short note; bounded programs and event-subscribed continuation, not long waits |
| World requests | Versioned inert data, not remote execution of brain programs |
| Initial population | Browser/world first; one then two fake-brain Life processes; real adapter and budgets before four lightly seeded Lives |
| Perception | Actor-filtered views for play and AI observations; private minds; separately admitted observer/operator view |
| Reconnect | Durable receipts, recipient replay, consistent snapshot, reconciliation before fresh effects |
| Duplicate commands | Same durable operation ID returns the retained result; changed payload conflicts |
| Disconnect | Human/Life avatar remains; motor actions suspend when loss is detected; reconcile before explicit resume |
| World downtime | Restore last durable frontier and discard only provisional tail; no wall-time fast-forward; world receipts survive |
| Upgrade | Controlled quiescent selection; explicit schema/activity compatibility |
| Expansion | New content, regions, components, operations, and systems through versioned Gene modules |
| First experiment | Human-scale neighborhood activities; no mandatory survival economy or assigned AI professions |
| Human control | Own persistent avatar, click-to-move first, shared world operation contracts |
| Browser recovery | In-memory pending IDs only in v1; fenced server reconciliation after refresh; no automatic resend of lost intent |
| Language permissions | No dependency on the removed Gene capability system; normal world/session validation remains |
| Extensible UI | Data-only interaction discovery and appearance fallback, not executable scripts in world packets |

The renderer/server source origins and independent native transport dependency are selected (§1.4, §9.7); Miclone itself is not an installed dependency. Remaining implementation work includes exact adapter signatures, Commons session integration, an incremental storage option if the measured image path fails, retention/archive mechanics, one real brain provider, physical constants, and recorded deployment limits. These are explicit gates, not assumptions of existing support. No new core Gene syntax is required.

## 20. Basis and references

**[D1] World-design discussion, 2026-09-21.** The project owner requested an expandable human-like world, separate world and Life processes, WebSocket interaction, and human browser players; removed Gene capabilities; and requested incorporation of a second agent's implementation review. The subsequent clarification selects copying and adapting useful Miclone code without depending on Miclone. Revision 4 applies that decision to source ownership, builds, tests, maintenance, and milestones; the other product decisions remain unchanged.

**[D2] User-supplied feasibility review.** Its six points concern Miclone reuse, whole-image storage costs, Life execution/brain/seed limitations, connector reuse and native curl requirements, browser-first sequencing, and removing the mandatory browser journal. It reports Life cycle time rising from 128 ms to 1.24 s over 200 cycles, a 3-second program limit, a 100-call/hour default, and 110 tests. These measurements/counts and the Life implementation details were supplied by the reviewer, not independently reproduced in this document update. They motivate explicit integration/performance gates. Locate and pin the current Life implementation before extraction; no missing component is claimed to have been implemented by editing this file.

**[L1] User-supplied Gene Life proposal.** Latest reviewed attachment `life(2).md`, updated 2026-09-20; intended companion `life.md`. It supplies the code-first brain interface, private cognitive organization, local grouped commits, and checkpoint-based continuation. This proposal adds a network adapter profile; it does not delete the local-world implementation or imply a distributed transaction. The world-specific checkpoint/provisional-motion policy is explicit in §6.1. Source attachment SHA-256: `a3d9750da0d0f974fb646b157ae10c5ec3afb787478e3da248dd554a76bc6b43`.

Repository sources below were read for revision 3 at **`gene-lang/gene-new@228d3304b872927aa1d82b5a46934e8ec8c479fe`**. They remain provenance and technical references, not dependencies to resolve when building the Commons. Source and README inspection is not an execution or benchmark report; some historical comments describe older milestones.

**[R1] Miclone source reference for selective copying.** `examples/miclone/README.md`, `examples/miclone/server/main.gene`, and `examples/miclone/server/storage.gene`. Source reference for copying and adapting the Gene browser/renderer, WebSocket integration, portable helpers, content recipes, and world-store interface; not a runtime, build, or test dependency. The Commons' server-owned motion, protocol receipts, participant recovery, and browser session policy remain adaptation work. Sources: <https://github.com/gene-lang/gene-new/blob/228d3304b872927aa1d82b5a46934e8ec8c479fe/examples/miclone/README.md>, <https://github.com/gene-lang/gene-new/blob/228d3304b872927aa1d82b5a46934e8ec8c479fe/examples/miclone/server/main.gene>.

**[R2] Gene native WebSocket library.** `src/genex/websocket/README.md`: documented libcurl >= 8.11 with WebSocket support, C/Nim/pkg-config build, macOS curl selection, binary queued sends, bounded polling, message limits, owning-thread behavior, and close semantics. Source: <https://github.com/gene-lang/gene-new/blob/228d3304b872927aa1d82b5a46934e8ec8c479fe/src/genex/websocket/README.md>.

**[R3] Miclone storage binding caveat.** `examples/miclone/server/storage.gene` describes provider-backed connection-image publication and transaction batching, and warns that WAL/synchronous pragmas do not configure that path. The additional per-commit rewrite/fsync claim is from [D2]; no write-amplification benchmark was run here. Source: <https://github.com/gene-lang/gene-new/blob/228d3304b872927aa1d82b5a46934e8ec8c479fe/examples/miclone/server/storage.gene>.

**[T1] IETF RFC 6455.** Bidirectional framed transport and protocol-level control; it does not provide this application's receipts/recovery. <https://www.rfc-editor.org/rfc/rfc6455.html>.

**[T2] MDN WebSocket / bufferedAmount.** Browser buffering and backpressure considerations retained from the prior revision. <https://developer.mozilla.org/en-US/docs/Web/API/WebSocket>; <https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/bufferedAmount>.

**[T3] SQLite, Atomic Commit In SQLite.** Local transactional publication and storage assumptions; not a statement that Gene's connection-image layer provides native incremental file behavior. <https://www.sqlite.org/atomiccommit.html>.

**[T4] IETF RFC 8259.** JSON interchange and numeric considerations. The protocol imposes its own stricter bounded validation. <https://www.rfc-editor.org/rfc/rfc8259.html>.

**[T5] WHATWG WebSockets Standard.** Browser constructor/session behavior and non-exposure of protocol ping/pong, retained as the browser protocol basis. <https://websockets.spec.whatwg.org/>.

**[T6] libcurl WebSocket interface overview.** Native send/receive integration and the need to drive the connection through the selected API. <https://curl.se/libcurl/c/libcurl-ws.html>.

The curl and SQLite references and repository baseline above were checked for revision 3. Revision 4 updates the copy-and-adapt policy from the project owner’s clarification without another repository audit. Protocol references remain technical bases, not newly performed compatibility tests. Editing this proposal has not copied application source or run a Gene build, browser execution, Life test suite, independence test, or latency/storage benchmark. All new defaults, tests, and milestones are proposed targets.

### Review disposition

| Supplied comment | Decision |
| --- | --- |
| Build on Miclone or justify not | Accepted as source reuse, clarified by the owner: selectively copy and adapt useful code into an independent Commons app, not a Miclone dependency. Server movement and persistence semantics remain deliberate adaptations. |
| Copy and adapt without depending on Miclone | Selected: Commons-owned source/assets/build/tests, lightweight origin records, optional manual fix ports, and a clean build/run test with the original Miclone tree unavailable. |
| Per-tick commits and unbounded retained data are impractical | Accepted: action-boundary durability plus provisional motion/checkpoints; bounded active Life/world storage and a measured incremental-backend gate before sustained use. |
| Life cannot await long world activities; brain/seed/budget work is missing | Accepted: event-subscribed short continuations, real adapter as an explicit milestone, editable disposition separate from immutable seed, measured latency/cost and availability UI. |
| Reuse connector delivery and name native requirements | Accepted: shared transport-independent delivery semantics, preserved HTTP/local regressions, explicit genex/libcurl prerequisites. |
| Milestone 1 is too large | Accepted: browser/world/movement first, then fake Life processes, durability/growth testing, then real brains. |
| Drop required IndexedDB journal | Accepted with a qualification: same-ID retry and server fencing/recovery preserve known effects; lost browser intent is not recreated, and a fresh ID is not deduplicated merely because the human meant the same thing. |

**Copy useful foundations; own the result. Commit what matters. Let humans play first, then let independent Lives join and evolve.**

