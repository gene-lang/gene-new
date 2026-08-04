// design.md §D6.1's meshing criterion, measured on the runtime that actually
// runs it. §D6.3 timed the VM because that is where mapgen lives; meshing is a
// client concern and the client is V8, so this harness is node.
//
//   gene run build_spike       (or: gene build --target web ... --out-dir dist)
//   node tools/mesh_bench.mjs

import { fill_padded } from "../dist/mapgen.mjs";
import { light_region } from "../dist/light.mjs";
import { chunk_base, count_faces, build_mesh } from "../dist/mesh.mjs";
import { id_of, opaque$q, registered_count } from "../dist/registry.mjs";
import { load_mods } from "../dist/mods.mjs";

// 18^3 — the padded neighbourhood core/mesh.gene reads. The web profile
// exports functions, not `let` constants, so the geometry is restated here.
const PAD_NODES = 18 * 18 * 18;
// core/mesh.gene addresses a chunk inside an arbitrary array by the index of
// its (0,0,0) and the array's two strides. The padded neighbourhood is that
// array with the chunk at (1,1,1) and the shell pressed against it.
const PAD_SY = 18, PAD_SZ = 18 * 18;
const PAD_BASE = chunk_base(1, 1, 1, PAD_SY, PAD_SZ);

const SEED = 1337;

// M2: the generator and the mesher both read the registries rather than
// hardcoded ids, so the harness loads the same game the client does — which
// since M7 means the same mod (§9). Content ids are `F64` and the node buffer
// is a Float32Array — see core/world.gene for why the obvious Uint16Array is
// 9x slower to read.
const game = load_mods();
const reg = game.nodes;
const biomes = game.biomes;
const ores = game.ores;
const AIR = id_of(reg, "air");
const WATER = id_of(reg, "miclone:water");

const padded = new Float32Array(PAD_NODES);
// M3: param1, the per-column sky boundary, and the flood queue, all reused
// across chunks — core/light.gene takes the queue from its caller precisely so
// a loader allocates once rather than per block (design.md §4).
const lit = new Float32Array(PAD_NODES);
const sky = new Float32Array(18 * 18);
// + 4 is core/light.gene's `queue_overhead`: the ring's header cells.
const queue = new Float32Array(PAD_NODES + 4);
const REGISTERED = registered_count(reg);
const FLOATS_PER_VERTEX = 7;

function meshOne(cx, cy, cz) {
  const t0 = performance.now();
  fill_padded(padded, sky, cx * 16, cy * 16, cz * 16, biomes, ores, SEED, AIR, WATER);
  const tGen = performance.now();
  lit.fill(0);
  light_region(lit, padded, 18, 18, 18, reg, sky, queue, REGISTERED);
  const tLight = performance.now();
  const faces = count_faces(reg, padded, PAD_BASE, PAD_SY, PAD_SZ);
  const verts = new Float32Array(faces * 4 * FLOATS_PER_VERTEX);
  const idx = new Uint32Array(faces * 6);
  build_mesh(reg, padded, lit, verts, idx, PAD_BASE, PAD_SY, PAD_SZ,
             cx * 16, cy * 16, cz * 16);
  const tMesh = performance.now();
  return { gen: tGen - t0, light: tLight - tGen, mesh: tMesh - tLight, faces,
           verts: verts.length / FLOATS_PER_VERTEX };
}

// Warm V8 before measuring: the first pass through a function is interpreted.
for (let i = 0; i < 8; i++) meshOne(i, 0, 0);

// A 8x4x8 volume, so the sample spans the whole terrain height rather than one
// slab. Chunks fully below the surface legitimately mesh to nothing — every
// face is interior — so a run confined to y 0..15 measures almost nothing and
// reports a budget it never tested. Both figures are printed below: the
// per-chunk average a loader pays, and the average over chunks that actually
// produced geometry, which is the number the 8 ms budget is about.
const SPAN_X = 8, SPAN_Y = 4, SPAN_Z = 8;
let gen = 0, light = 0, mesh = 0, faces = 0, verts = 0, worst = 0, empty = 0, total = 0;
let busyGen = 0, busyLight = 0, busyMesh = 0, busy = 0;
for (let cx = 0; cx < SPAN_X; cx++)
  for (let cy = 0; cy < SPAN_Y; cy++)
    for (let cz = 0; cz < SPAN_Z; cz++) {
      const r = meshOne(cx, cy, cz);
      gen += r.gen; light += r.light; mesh += r.mesh;
      faces += r.faces; verts += r.verts;
      worst = Math.max(worst, r.gen + r.light + r.mesh);
      total++;
      if (r.faces === 0) empty++;
      else { busy++; busyGen += r.gen; busyLight += r.light; busyMesh += r.mesh; }
    }

const CHUNK_COUNT = total;
const per = (t) => (t / CHUNK_COUNT).toFixed(3);
const perBusy = (t) => (t / Math.max(busy, 1)).toFixed(3);
console.log(`\ndesign.md §D6.1 — meshing, ${CHUNK_COUNT} chunks of 16^3 ` +
  `(${SPAN_X}x${SPAN_Y}x${SPAN_Z})\n`);
console.log(`  generate      ${per(gen)} ms/chunk      ${perBusy(busyGen)} ms/non-empty`);
console.log(`  light         ${per(light)} ms/chunk      ${perBusy(busyLight)} ms/non-empty`);
console.log(`  mesh          ${per(mesh)} ms/chunk      ${perBusy(busyMesh)} ms/non-empty`);
console.log(`  total         ${per(gen + light + mesh)} ms/chunk      ${perBusy(busyGen + busyLight + busyMesh)} ms/non-empty`);
console.log(`  worst chunk   ${worst.toFixed(3)} ms`);
console.log(`  faces         ${(faces / Math.max(busy, 1)).toFixed(0)} avg per non-empty chunk`);
console.log(`  vertices      ${(verts / Math.max(busy, 1)).toFixed(0)} avg per non-empty chunk`);
console.log(`  non-empty     ${busy} of ${CHUNK_COUNT} (${empty} fully interior or fully air)`);

// Winding check. A backwards-wound quad is culled rather than drawn
// inside-out, so the failure is a hole in the world and nothing reports it —
// which is exactly how the two Z faces shipped broken. For every emitted quad,
// the cross product of its first two edges must point away from the node the
// face belongs to; here that means it must be axis-aligned and unit length,
// and the six directions must all appear.
{
  // Search for a chunk that straddles the surface: an interior chunk emits no
  // quads at all, so checking a fixed one can silently check nothing.
  const pad = new Float32Array(PAD_NODES);
  let faces = 0, ox = 0, oy = 0, oz = 0;
  outer:
  for (let cy = 0; cy < SPAN_Y; cy++)
    for (let cx = 0; cx < SPAN_X; cx++)
      for (let cz = 0; cz < SPAN_Z; cz++) {
        fill_padded(pad, sky, cx * 16, cy * 16, cz * 16, biomes, ores, SEED, AIR, WATER);
        faces = count_faces(reg, pad, PAD_BASE, PAD_SY, PAD_SZ);
        if (faces > 100) { ox = cx*16; oy = cy*16; oz = cz*16; break outer; }
      }
  if (faces <= 100) {
    console.log("\nFAIL — winding: found no chunk with enough geometry to check");
    process.exit(1);
  }
  fill_padded(pad, sky, ox, oy, oz, biomes, ores, SEED, AIR, WATER);
  const padLit = new Float32Array(PAD_NODES);
  light_region(padLit, pad, 18, 18, 18, reg, sky,
               new Float32Array(PAD_NODES + 4), REGISTERED);
  const verts = new Float32Array(faces * 4 * FLOATS_PER_VERTEX);
  const idx = new Uint32Array(faces * 6);
  build_mesh(reg, pad, padLit, verts, idx, PAD_BASE, PAD_SY, PAD_SZ,
             ox, oy, oz);

  // The invariant, checked per quad rather than by which directions happen to
  // occur: the normal implied by the winding must point from the solid node
  // that owns the face into the transparent node it faces. An inverted quad
  // has a unit axis-aligned normal like any other, so only this catches it.
  // (A heightfield legitimately produces no downward faces, which is why
  // "all six directions appear" is the wrong test.)
  const at = (v) => [verts[v * FLOATS_PER_VERTEX + 0],
                     verts[v * FLOATS_PER_VERTEX + 1],
                     verts[v * FLOATS_PER_VERTEX + 2]];
  // Asks the registry rather than testing against ids 0 and 5, which is the
  // same change M2 made in core/mesh.gene: ids are assigned at load, so a
  // hardcoded pair is only ever right for one content set.
  const solid = (x, y, z) =>
    opaque$q(reg, pad[(x + 1) + (y + 1) * 18 + (z + 1) * 324]);
  const seen = new Set();
  let inverted = 0, degenerate = 0;
  for (let f = 0; f < faces; f++) {
    const [a, b, c] = [at(f * 4), at(f * 4 + 1), at(f * 4 + 2)];
    const e1 = [b[0]-a[0], b[1]-a[1], b[2]-a[2]];
    const e2 = [c[0]-b[0], c[1]-b[1], c[2]-b[2]];
    const n = [e1[1]*e2[2]-e1[2]*e2[1], e1[2]*e2[0]-e1[0]*e2[2],
               e1[0]*e2[1]-e1[1]*e2[0]];
    if (Math.abs(Math.hypot(...n) - 1) > 1e-6) { degenerate++; continue; }
    seen.add(n.map(v => Math.round(v)).join(","));
    // Centroid of the quad, in chunk-local coordinates.
    let cx = 0, cy = 0, cz = 0;
    for (let k = 0; k < 4; k++) {
      const p = at(f * 4 + k); cx += p[0]; cy += p[1]; cz += p[2];
    }
    cx = cx / 4 - ox; cy = cy / 4 - oy; cz = cz / 4 - oz;
    const owner = [cx - n[0]*0.5, cy - n[1]*0.5, cz - n[2]*0.5].map(Math.floor);
    const front = [cx + n[0]*0.5, cy + n[1]*0.5, cz + n[2]*0.5].map(Math.floor);
    if (!solid(...owner) || solid(...front)) inverted++;
  }
  console.log("");
  console.log(`  winding       ${faces} quads, ${seen.size} face directions, ` +
    `${inverted} inverted, ${degenerate} degenerate`);
  if (inverted || degenerate) {
    console.log(`FAIL — winding: ${inverted} quads face into the block they ` +
      `belong to and would be culled, ${degenerate} degenerate`);
    process.exit(1);
  }
}

const budget = 8.0;
console.log("");
if (busy === 0) {
  console.log("FAIL — every chunk meshed empty; the generator produced no terrain");
  process.exit(1);
}
console.log(worst <= budget
  ? `PASS — worst chunk ${worst.toFixed(3)} ms is within the ${budget} ms budget`
  : `FAIL — worst chunk ${worst.toFixed(3)} ms exceeds the ${budget} ms budget`);
