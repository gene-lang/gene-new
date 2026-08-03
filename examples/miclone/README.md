# Miclone

A voxel game engine with [Luanti](https://github.com/luanti-org/luanti)'s
architecture, written in Gene, whose mod language is Gene.

**Status: M0 through M6 — a generated, lit world you can walk around in, dig,
carry, and build with, running as two processes.** The server owns the world
and answers a WebSocket; the browser client is handed it and plays it, sharing
every rule through `core/` (§1.1, §4.2, §7, §7.1, §10). M7 is the mod API,
which is the point of the project. Read
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
  protocol.gene the eight messages, encoded as bytes (§10)
  physics.gene  the player box against the voxel grid (§7)
  raycast.gene  Amanatides-Woo node selection (§7)
  edit.gene     one node changes, and what that invalidates (§7.1)
  inventory.gene  stacks, in a buffer of (item, count) pairs (§7.1)
  drops.gene    what digging a node yields — §2's server half, for now
  content.gene  the provisional node/biome/ore set — M7 replaces this with a mod
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
         core/biome core/cave core/ore core/content core/mapgen \
         core/light core/mesh core/loaded core/physics core/raycast \
         core/edit core/inventory core/drops core/wire core/protocol \
         core/vec \
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
So it stubs the twenty host calls the client makes and drives the real `main()`
with synthetic events. It found the spawn scan stopping at the first *drawn*
node — water is drawn, this site is 23% sea, and the player was spawning
afloat.

### §D8 M6 — client and server as separate processes

```sh
gene run server                  # generates the world, listens on 8790

node tools/net_probe.mjs         # headless: joins it, in another shell

gene build --target web client/net_main.gene --out-dir dist
python3 -m http.server 8000      # then open http://localhost:8000/net.html
```

The browser client renders a world it was **handed** rather than one it
generated: `net.html` draws 229 chunks and 62,395 faces at 166 fps, and a click
goes to the server, is applied there, and comes back as a node delta with the
drop in the hotbar. Same physics, mesher, raycast and hotbar as the local
client, because all of them are `core/` and neither side has its own copy.

The probe is the only harness here that runs two processes: it joins over a
real WebSocket and drives the whole §10 exchange with the same `core/` modules
the browser client uses — handshake, registry, flow-controlled block transfer,
and §7.1's authoritative dig and place, including the server refusing a node
the client does not hold.

**The client asks for terrain; the server does not push it.** That is flow
control and it is not optional: the WebSocket outbound queue holds 256 frames
per connection and `ws_send` drops the oldest when it overflows. Pushing all
576 blocks from `on_open` delivered 422 of them and reported success.

`gene run wire_bench` reports what a block message costs on the VM: **17.9 ms**
against V8's 0.032 ms, which is §D6.3's ~500 ns message send met again — a
block encode is ~16,000 buffer reads. That, not the socket, is why a world
takes ~12 s to transfer. See design.md §10.1.

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
