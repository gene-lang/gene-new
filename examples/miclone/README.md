# Miclone

A voxel game engine with [Luanti](https://github.com/luanti-org/luanti)'s
architecture, written in Gene, whose mod language is Gene.

**Status: M0, M1, and M2 — a generated world you can fly through. There is no
game yet.** Read
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
whole blocks rather than extrapolating. **31.8 ms/block**, against §D6.3's
300 ms and against what a walking player needs — and against the node rate the
old unit implied, which it still misses by 13.2x and which the probe reports
anyway. See design.md §3.3.

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
  mesh.gene     face-culled meshing (§5)
  content.gene  the provisional node/biome/ore set — M7 replaces this with a mod
client/     the browser shell: WebGL2 renderer, atlas, camera
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
         core/mesh core/vec client/atlas client/render client/main; do
  gene build --target web $m.gene --out-dir dist
done

node tools/mesh_bench.mjs        # headless: generation + meshing budget
python3 -m http.server 8000      # then open http://localhost:8000/
```

M0 measured **121 fps** drawing 186 chunk meshes and 51,387 faces, with a worst
chunk of 0.44 ms against an 8 ms meshing budget. M2 draws 231 meshes and 62,580
faces — 22% more geometry through an unchanged render path — and meshes a chunk
in **0.069 ms**, worst chunk 0.79 ms. Drag to look, WASD to move, space/shift
for up and down.

The spike stands at world (-1440, 3168) rather than the origin, because §3 gives
biomes a ~555-node scale and this view is 192 nodes across: wherever it stands it
sees one or two biomes, and at the origin it stands in the cold quadrant and is
uniformly snow. That site was found by scanning for the view with the most
distinct biomes and a coastline; nothing in the generator is tuned for it.

Two traps when re-measuring: a backgrounded tab throttles `requestAnimationFrame`
to nothing (the fps reads 1, and `document.hidden` is the thing to check), and
`http.server` sends no `Cache-Control`, so a plain reload can silently re-run the
previous build.

### Cross-backend specs

Both must produce byte-identical output on the VM and through the web profile.

```sh
gene run world_spec  | diff - <(node tools/world_spec.mjs)    # §1, §2
gene run mapgen_spec | diff - <(node tools/mapgen_spec.mjs)   # §3, §5, §14
```
