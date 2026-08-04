# Miclone

A voxel game engine with [Luanti](https://github.com/luanti-org/luanti)'s
architecture, written in Gene, whose mod language is Gene.

**Status: M0 through M8, mostly — a generated, lit world you can walk around in,
dig, carry, craft with, and build with, running as two processes, defined by a
mod, and changing on its own.**
The server owns the world and answers a WebSocket; the browser client is handed
it and plays it, sharing every rule through `core/` (§1.1, §4.2, §7, §7.1, §10).
The game itself is `mods/default`, registered through §9's API — and a client
draws it from recipes on the wire without ever running mod code. What M7 has
*not* built is the loading: the mod is compiled in rather than read off disk, so
§D5's capability model is still a claim about a loader that does not exist
(§9.1). Read
[`docs/design.md`](docs/design.md) first — Part I is the direction and the
decisions, and §D2 is the constraint that shaped the rest.

The reference source is a shallow clone of upstream, not vendored here:

```sh
git clone --depth 1 https://github.com/luanti-org/luanti examples/miclone/luanti
```

---

## The M0 probes

design.md §D6 puts three probes in front of the engine, each able to kill or
reshape it. Two have run.

### §D6.2 — divergence: **PASS**, zero differing bits

Runs the exact `F64` chains mapgen depends on through both backends and
compares decomposed float bits — not printed floats, because the VM prints
`1e-7` as `0.0000001` while agreeing on every bit.

```sh
cd examples/miclone
gene run divergence                                 # the VM

gene build --target web probes/divergence.gene --out-dir dist
node tools/divergence.mjs                           # the web profile, via V8

gene run divergence | diff - <(node tools/divergence.mjs)   # no output
```

323 samples agree exactly, which is what makes §D3.1's *exact half* an
enforceable rule rather than a hope.

### §D6.3 — worldgen throughput: **FAIL at the 80³ chunk, PASS at the 16³ block**

```sh
gene run worldgen
```

M0 measured an 80³ chunk at 302 s against a 300 ms budget. The finding was not
that 3D noise is expensive — it is that a single message send is ~500 ns, so
512,000 nodes cannot be *written* inside 300 ms whatever is written, and the
*unit* was therefore wrong.

M2 acts on that: the generation unit is a 16³ block, and the probe now measures
whole blocks rather than extrapolating. **33.2 ms/block** of nodes, plus
**24.8 ms** for M3's lighting — **58.1 ms** for the block a server stores,
against §D6.3's 300 ms and against the 76.9 ms one lane needs to stay ahead of a
walking player. It still misses the node rate the old unit implied by 24x, and
the probe reports that anyway. See design.md §3.3 and §4.1.

---

## Layout

```
core/       portable Gene — compiles for the VM and the web profile
  exact.gene    exact F64 integer arithmetic and float bit comparison (§D3.1)
  noise.gene    value noise and fractal composition (§D7.5)
  field.gene    coarse-lattice 2D noise fields (§D6.3 rung 2)
  world.gene    blocks, coordinates, light packing (§1)
  registry.gene the node registry, client half (§2)
  biome.gene    the biome registry (§3 stage 2)
  cave.gene     Bézier-worm carving (§3 stage 3)
  ore.gene      the ore registry: scatter, sheet, blob (§3 stage 4)
  mapgen.gene   the staged pipeline (§3)
  light.gene    sunlight and light sources, packed into param1 (§4)
  mesh.gene     face-culled meshing (§5)
  loaded.gene   the client's loaded world: one array, one shell (§1.1)
  wire.gene     the byte codec both backends encode messages through (§10)
  protocol.gene the twelve messages, encoded as bytes (§10)
  physics.gene  the player box against the voxel grid (§7)
  raycast.gene  Amanatides-Woo node selection (§7)
  edit.gene     one node changes, and what that invalidates (§7.1)
  inventory.gene  stacks, in a buffer of (item, count) pairs (§7.1)
  drops.gene    what digging a node yields — §2's server half, for now
  item.gene     §2's item registry: an item id is not a content id (§2.2)
  groups.gene   §2's cross-cutting groups, and what a tool digs
  tiles.gene    the atlas recipes a mod registers — §2's appearance side (M7)
  api.gene      §9's mod API: the surface a mod is written against, and the
                only thing it registers through (M7)
  mods.gene     §9's load step — one list, and the file where §D5's capability
                model will be true or not
  abm.gene      §12's ABMs: a check queue for what just changed, and sampling
                for what did not, both running the mod's own action (M8)
  decor.gene    §3 stage 5: trees, placed by a pure function of the column (M8)
  craft.gene    §9's recipes — shapeless, because a grid needs §13 (M8)
  entity.gene   §8's dropped items, and the definitions that carry a mod's
                on_step (M8)
  seen.gene     §8's client half: what a client has been told is on the
                ground, which is what the renderer walks (M8)
  formspec.gene §13's UI as data — validated at registration, not on screen,
                and buttons that send an action a mod names (M8)
  container.gene §13's node inventories: a chest's contents, which are a node's
                *state* and so neither half of §2's split (M8)
mods/       the game, as mods (§9)
  default/    every node, tile, drop, biome and ore miclone has
server/     VM only: the on-disk block format, the SQLite world store (§11),
            and main.gene — the M6 server that owns the world (§10)
client/     the browser shell: WebGL2 renderer, atlas, sound, camera
              main.gene generates the world; net_main.gene is handed it (§10)
probes/     the probes and cross-backend specs; `run_*.gene` are their VM shells
tools/      the web-profile shells
docs/       design.md
```

`core/` is written in the intersection of what the VM runs and what the `web`
profile compiles. Printing is not in that intersection — `$println` is a VM
builtin and a browser has no stdout — which is why each probe is a portable
module with a shell per backend rather than one module with a conditional.

### §D6.1 — render spike: **PASS**

```sh
cd examples/miclone
tools/build_web.sh               # every portable module, into dist/
tools/build_web.sh --clean       # after adding or removing a core/ module

node tools/mesh_bench.mjs        # headless: generation + meshing budget
node tools/world_build.mjs       # headless: what opening a world costs
node tools/client_smoke.mjs      # headless: the client's wiring, DOM stubbed
python3 -m http.server 8000      # then open http://localhost:8000/
```

The module list lives in the script rather than here, because it was wrong here
twice: the profile emits one flat output directory keyed by basename, so the
list is the whole graph rather than a set of entry points, and every new `core/`
module has to join it. `--clean` matters for the other half of that — a deleted
module leaves its `dist/*.mjs` behind, and a harness importing it keeps passing
off the stale artifact.

M0 measured **121 fps** drawing 186 chunk meshes and 51,387 faces, with a worst
chunk of 0.44 ms against an 8 ms meshing budget. M2 draws 231 meshes and 62,580
faces — 22% more geometry — and M3 lights every one of them: a chunk now
generates, lights, and meshes in **0.22 ms** (0.128 + 0.018 + 0.076), worst
chunk 0.91 ms. Drag to look, WASD to move, space/shift for up and down.

M5 keeps the world instead of dropping it (§1.1) and lights all of it in one
call (§4.2). `tools/world_build.mjs` reports what that costs: **114 ms** to open
a 12x4x12 world — 55 ms generating, 24.7 ms lighting 2.48M nodes, 32.8 ms
meshing 229 non-empty chunks into 62,395 faces. Two faces fewer per border chunk
than M3, because the world's edge now hides its outward faces against the shell
rather than against terrain that was generated only to be looked at once.

An edit costs **0.40 ms at worst** and names **9.2 chunks** to rebuild on
average — the region is much larger than the node, because a dig in daylight
sends light fifteen nodes in every direction and down the shaft it opened
(§7.1). Thirteen edits relight the world exactly as a full relight would, and a
node dug is a node carried and placed back.

It also walks a player over the real generated terrain for two minutes at
**1.6 us per physics step**, asserting on every frame that the player is not
inside a block and has not left the world. That is the check a fixture spec
cannot make — §7's spec has the derivable numbers, and this has the cave mouths,
the shoreline, and the 576 block seams. It is what found the client's spawn scan
sampling a fractional node coordinate, which reads as `undefined` rather than
raising.

The spike stands at world (-1440, 3168) rather than the origin, because §3 gives
biomes a ~555-node scale and this view is 192 nodes across: wherever it stands it
sees one or two biomes, and at the origin it stands in the cold quadrant and is
uniformly snow. That site was found by scanning for the view with the most
distinct biomes and a coastline; nothing in the generator is tuned for it.

**M5, measured in a real tab: 166 fps**, drawing 229 chunk meshes and 62,417
faces while running physics — and that is the display's ceiling rather than the
engine's. Over 89 sampled frames the median interval was 6.00 ms (166.7 Hz,
vsync), the slowest was 7.6 ms, and **nothing exceeded 8 ms**. Against M0's 121
fps over 186 meshes and 51,387 faces, with no player in the world.

Two traps when re-measuring, one of them now with a way around it:

- **A backgrounded tab throttles `requestAnimationFrame`** — measured at 6 fps
  here, against 166 for the same build a second later. `document.hidden` is the
  thing to check, and a screenshot *forces* a render, so sampling the HUD right
  after one reports a burst rather than a rate. This was recorded as "fps cannot
  be measured through an automation tab" and that is too strong: bring the window
  to the front first (`osascript -e 'tell application "Google Chrome" to
  activate'`), confirm `document.hidden` is `false`, then sample.
- **`http.server` sends no `Cache-Control`**, so a plain reload can silently
  re-run the previous build.

Which is why `tools/client_smoke.mjs` exists. A browser is the obvious place to
check that a keypress reaches the physics and a click reaches the edit, and the
least reliable one available: throttled frames, black screenshots without a
recording permission, and an automation extension that can simply disconnect.
So `tools/dom_stub.mjs` stubs the twenty host calls the client makes and the
smoke test drives the real `main()` with synthetic events. It found the spawn
scan stopping at the first *drawn* node — water is drawn, this site is 23% sea,
and the player was spawning afloat. The same stub carries the networked client
in `tools/net_client_smoke.mjs` below, which is the point of it being a module:
the DOM is what neither client has, and the transport is not.

### §D8 M6 — client and server as separate processes

```sh
gene build --target web client/net_main.gene --out-dir dist

node tools/net_client_smoke.mjs  # headless: boots a server, plays it, ~40 s

gene run server                  # opens or generates the world, listens on 8790
                                 # GENE_MICLONE_WORLD=/tmp/w for a throwaway one
node tools/net_probe.mjs         # headless: joins it, in another shell

python3 -m http.server 8000      # then open http://localhost:8000/net.html
```

The browser client renders a world it was **handed** rather than one it
generated: `net.html` draws 229 chunks and 62,395 faces at 166 fps, and a click
goes to the server, is applied there, and comes back as a node delta with the
drop in the hotbar. Same physics, mesher, raycast and hotbar as the local
client, because all of them are `core/` and neither side has its own copy.

Two harnesses run two processes, and they are not the same test. **The probe is
a peer**: it speaks §10 itself, out of `core/`, and proves the server answers
correctly — handshake, registry, flow-controlled block transfer, and §7.1's
authoritative dig and place, including the server refusing a node the client
does not hold. **The smoke test is a client**: it boots `gene run server`
itself and runs the 535 lines of `client/net_main.gene` that the probe
replaces, over the platform's own `WebSocket`. Only the DOM is stubbed, by the
same `tools/dom_stub.mjs` the local client's smoke test uses; the socket is
real, and the `WebSocket` the client gets is a subclass that tallies frames by
kind so a failure can say *which* message never arrived.

It asserts that the handshake moves the player to the spawn the server chose,
that a click before the world arrives never reaches the wire, that 576 blocks
arrive in nine windows of 64 and mesh to 229 chunks and 62,395 faces, that a
dug node's drop reaches the hotbar **because the server sent an inventory**
rather than because the client predicted one, that the delta remeshes the chunk
around it (62,395 → 62,399 faces) and the place puts it back, and that placing
from an empty slot never becomes a message at all.

It keeps its world at `/tmp/miclone_smoke_world` between runs — 64 s to
generate, 28 s to load — and discards it if the run failed, because a world
with a hole in it is how the next run inherits a fixture nobody wrote.
`MICLONE_SMOKE_FRESH=1` forces a new one. **Wait on the port, not the log**: the
server's stdout is block-buffered when it is a pipe, so "listening on 8790" can
sit unflushed for the whole run.

**The client asks for terrain; the server does not push it.** That is flow
control and it is not optional: the WebSocket outbound queue holds 256 frames
per connection and `ws_send` drops the oldest when it overflows. Pushing all
576 blocks from `on_open` delivered 422 of them and reported success.

`gene run wire_bench` reports what a block message costs on the VM: **17.9 ms**
against V8's 0.032 ms, which is §D6.3's ~500 ns message send met again — a
block encode is ~16,000 buffer reads. That, not the socket, is why a world
takes ~12 s to transfer. See design.md §10.1.

### §D8 M7 — the mod API

The game is no longer in the engine. `core/content.gene` is gone and every
node, tile, drop, biome and ore is declared in `mods/default/src/default.gene`,
through `core/api.gene`:

```gene
(register_node game "miclone:grass"
               ^tiles ["miclone:grass_top" "miclone:grass_side" "miclone:dirt"])
(register_node game "miclone:water" ^tiles ["miclone:water"]
               ^drawtype draw_liquid
               ^solid false
               ^propagates_light true)
```

Almost every node says nothing about being a solid opaque cube, because that is
what a node is unless it declares otherwise — which leaves the two that *are*
different visibly different on the page. That shape cost a compiler change:
`^name : T` was a VM-only parameter form and `core/api.gene` compiles for both
backends, so the web profile learned named parameters
(`docs/web-profile.md`).

**A mod defines what its nodes look like, and a client draws them without
running the mod.** The atlas used to be a list of constants with a matching list
of `paint_*` calls; it is now `core/tiles.gene`'s registry, and the recipes
travel to the browser in `msg_tiles` (protocol v2). A tile is a kind and eleven
small numbers, so what crossed the wire is data — which is what makes §D5's "a
client renders without executing mod code" a property rather than a promise.

**The test of the move is that the world did not change.** Same four golden
checksums, same 229 chunks and 62,395 faces, the ten cross-backend specs diff
clean, and both clients play the same game. §14 layer 3 exists for terrain
changes and earned its keep on a change that was not one.

**What M7 has not built is the loading**, and starting it turned up something
worse than a gap. §D5 claims "a mod that never receives `$fs/WriteDir` cannot
write a file no matter what it evaluates". That is false today: any module can
`(import $fs [write_text WriteDir])` and write the file. Capability values are
real — the call does check for one — but they are not scarce, because the
namespace holding them is ambient.

So the sandbox belongs at the *import* boundary rather than the argument list: a
mod's module root needs a restricted builtins scope in which a denied namespace
is shadowed by an empty one. That makes M7's remaining half a VM change rather
than a game one, and it makes it more clearly worth doing — runtime loading
without it would be strictly worse than what exists now, since `mods/default` is
compiled in and audited by being in this repository. See design.md §D5.1 and
§9.1.

### §D8 M8 — the server tick, and a world that changes on its own

```sh
gene run server &
node tools/tick_probe.mjs        # digs under sand, then stops talking
```

§12.1 said the loop would arrive with "the first thing that changes without
being asked". That is falling sand. `serve` gained `^on_tick`/`^tick_ms` — the
event loop already slept only as long as nothing needed it, so a tick is one
more deadline rather than a thread.

**Sampling cannot do falling, and a probe measured why.** §12 specifies ABMs as
sampled; sampling 900 positions a pass out of 2.4M nodes takes about six minutes
to reach one *particular* node, so a column whose support was just dug stands
there. There are two mechanisms: a **check queue** seeded by whatever just
changed (a neighbour update, which cascades a node per tick), and **sampling**
for the ambient case — grass growing on open dirt. See design.md §12.2.

`tick_probe.mjs` asserts the property rather than the mechanism: it digs the
support out from under a sand column, stops talking, and waits for node deltas
to arrive on a silent socket. That is the whole difference between M6's reactive
server and this one.

### §13 — a form that sends a message, and a chest

```sh
gene run server &
node tools/chest_probe.mjs        # crafts, places, opens, fills, empties one
```

§13.3 said a form was read-only and that input "wants the container that would
justify it". Both exist now: `el_button` carries an **action** the engine hands
back verbatim, three messages carry forms to the client and presses back
(protocol v7), and `core/container.gene` gives a node position an inventory.
A press is refused unless *this* player has *that* form open at *that* node and
the form declares the action — §7.1's rule reaching UI.

The probe plays it: chop a tree, craft planks, craft a chest, place it,
right-click it, fill it, empty it. It also found the thing that was not on
§13's list — **a craft could not be chosen**, so the chest recipe was
unreachable behind sticks. See design.md §13.4.

### §8 — dropped items, drawn

```sh
gene run server &
node tools/entity_probe.mjs        # the server half: it falls
node tools/net_client_smoke.mjs    # the client half: it is drawn
```

§8.1 called this blocked on "a vertex format this renderer does not have". A
*billboard* would need one; a **scaled cube** needs exactly what the chunk pass
already uses, so `core/mesh.gene` gained `put_cube` and nothing in §6 changed at
all. `core/seen.gene` is the client's table — what it has been told is on the
ground, which is what a renderer walks. The smoke test counts **draw calls**: an
entity message is one more `drawElements` of exactly 36 indices, and a count of
0 takes it away again. See design.md §8.3.

### §5 — leaf face culling

```sh
node tools/mesh_bench.mjs
node tools/world_build.mjs       # faces, world-wide
```

`^merges_same` on `register_node`: a node declines to draw a face against
another node of its own kind. **208,608 faces to 117,528**, 43.7% of the
world's geometry, and nothing looks different because none of those faces was
visible — a canopy is a hundred leaves all facing each other. It is on the wire
(protocol v6) because the client is what meshes. See design.md §3.6.

### §8, §9 — the callbacks, and a blocker that was not one

```sh
gene run abm_spec | diff - <(node tools/abm_spec.mjs)   # 65 checks, both backends

gene run server &
node tools/entity_probe.mjs      # hangs an item in mid-air, then stops talking
```

An ABM takes `^action (fn [world x y z node] …)` and an entity definition takes
`^on_step` — mod code, run by the server tick. Both were recorded as blocked by
a compiler gap (§D7.17) and the gap did not exist: the annotation had been
spelled `Callback`, which only the web profile knew, and the VM has had function
types all along under the name `Fn`. The profile no longer accepts `Callback`,
so one spelling means one thing on both backends.

What that buys is the test §D8 sets for this API — *if the game needs an engine
change, the API is wrong*. §8.1 listed "a dropped item stays where it was
dropped, including in the air if the node under it is dug" as an engine
absence; `mods/default` fills it in eleven lines of `on_step`, and the engine
gained no notion of gravity.

**The ambient trigger had never run, and giving it a mod's action is what
showed it.** The sample walk drove all three axes from one counter, which traces
a one-dimensional curve — it could reach **192 positions out of 7,077,888**, and
the branch ended in a `void`, so nothing could ever look wrong. It strides the
flat index by a step coprime with the node count now, which makes it a
permutation: every node visited once per cycle, none unreachable, a full sweep
every 44 minutes. `abm_spec` asserts that directly. See design.md §12.3.

### Cross-backend specs

Both must produce byte-identical output on the VM and through the web profile.

```sh
gene run world_spec  | diff - <(node tools/world_spec.mjs)    # §1, §2
gene run mapgen_spec | diff - <(node tools/mapgen_spec.mjs)   # §3, §5, §14
gene run light_spec  | diff - <(node tools/light_spec.mjs)    # §4
gene run loaded_spec | diff - <(node tools/loaded_spec.mjs)   # §1.1, §4.2
gene run physics_spec | diff - <(node tools/physics_spec.mjs) # §7
gene run edit_spec   | diff - <(node tools/edit_spec.mjs)     # §7, §7.1
gene run inventory_spec | diff - <(node tools/inventory_spec.mjs)  # §2, §7.1
gene run wire_spec   | diff - <(node tools/wire_spec.mjs)     # §10
gene run protocol_spec | diff - <(node tools/protocol_spec.mjs)    # §10
gene run abm_spec    | diff - <(node tools/abm_spec.mjs)      # §8, §9, §12
```

### §11 — persistence

Run twice, in two processes: "quit and come back" is a claim about a process
boundary, and one process that writes and reads back cannot test it.

```sh
gene run persistence create    # generate, dig a lit pocket, save, exit
gene run persistence verify    # open it fresh and check
```

A block is **612 bytes** on average against 24,576 raw — run-length encoding,
40x. Deflate (design.md §D7.4) would be worth another 5.8x and is still open.
