# Miclone

A voxel game engine with [Luanti](https://github.com/luanti-org/luanti)'s
architecture, written in Gene, whose mod language is Gene.

**Status: M0 through M7's API — a generated, lit world you can walk around in,
dig, carry, and build with, running as two processes, and defined by a mod.**
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
  protocol.gene the nine messages, encoded as bytes (§10)
  physics.gene  the player box against the voxel grid (§7)
  raycast.gene  Amanatides-Woo node selection (§7)
  edit.gene     one node changes, and what that invalidates (§7.1)
  inventory.gene  stacks, in a buffer of (item, count) pairs (§7.1)
  drops.gene    what digging a node yields — §2's server half, for now
  tiles.gene    the atlas recipes a mod registers — §2's appearance side (M7)
  api.gene      §9's mod API: the surface a mod is written against, and the
                only thing it registers through (M7)
  mods.gene     §9's load step — one list, and the file where §D5's capability
                model will be true or not
mods/       the game, as mods (§9)
  default/    every node, tile, drop, biome and ore miclone has
server/     VM only: the on-disk block format, the SQLite world store (§11),
            and main.gene — the M6 server that owns the world (§10)
client/     the browser shell: WebGL2 renderer, atlas, camera
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
for m in core/exact core/noise core/field core/world core/registry \
         core/tiles core/biome core/cave core/ore core/api core/mods \
         core/mapgen core/light core/mesh core/loaded core/physics \
         core/raycast core/edit core/inventory core/drops core/wire \
         core/protocol core/vec mods/default/src/default \
         client/atlas client/render client/main; do
  gene build --target web $m.gene --out-dir dist
done

node tools/mesh_bench.mjs        # headless: generation + meshing budget
node tools/world_build.mjs       # headless: what opening a world costs
node tools/client_smoke.mjs      # headless: the client's wiring, DOM stubbed
python3 -m http.server 8000      # then open http://localhost:8000/
```

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

**What M7 has not built is the loading.** `mods/default` is imported like any
other module and its `register_all` is called, so nothing is sandboxed and
§D5's capability model is still a claim about a loader that does not exist.
Runtime module loading lives inside the VM and is not reachable from Gene;
`core/mods.gene` is the file where that promise will be true or not, and it
says so. See design.md §9.1.

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
