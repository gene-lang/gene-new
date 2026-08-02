// design.md §D6.1's meshing criterion, measured on the runtime that actually
// runs it. §D6.3 timed the VM because that is where mapgen lives; meshing is a
// client concern and the client is V8, so this harness is node.
//
//   gene run build_spike       (or: gene build --target web ... --out-dir dist)
//   node tools/mesh_bench.mjs

import { fill_padded } from "../dist/mapgen.mjs";

// 18^3 — the padded neighbourhood core/mesh.gene reads. The web profile
// exports functions, not `let` constants, so the geometry is restated here.
const PAD_NODES = 18 * 18 * 18;
import { count_faces, build_mesh } from "../dist/mesh.mjs";

const SEED = 1337;
const CHUNKS = 64;

const padded = new Uint16Array(PAD_NODES);

function meshOne(cx, cy, cz) {
  const t0 = performance.now();
  fill_padded(padded, cx * 16, cy * 16, cz * 16, SEED);
  const tGen = performance.now();
  const faces = count_faces(padded);
  const verts = new Float32Array(faces * 4 * 6);
  const idx = new Uint32Array(faces * 6);
  build_mesh(padded, verts, idx, cx * 16, cy * 16, cz * 16);
  const tMesh = performance.now();
  return { gen: tGen - t0, mesh: tMesh - tGen, faces, verts: verts.length / 6 };
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
let gen = 0, mesh = 0, faces = 0, verts = 0, worst = 0, empty = 0, total = 0;
let busyGen = 0, busyMesh = 0, busy = 0;
for (let cx = 0; cx < SPAN_X; cx++)
  for (let cy = 0; cy < SPAN_Y; cy++)
    for (let cz = 0; cz < SPAN_Z; cz++) {
      const r = meshOne(cx, cy, cz);
      gen += r.gen; mesh += r.mesh; faces += r.faces; verts += r.verts;
      worst = Math.max(worst, r.gen + r.mesh);
      total++;
      if (r.faces === 0) empty++;
      else { busy++; busyGen += r.gen; busyMesh += r.mesh; }
    }

const CHUNK_COUNT = total;
const per = (t) => (t / CHUNK_COUNT).toFixed(3);
const perBusy = (t) => (t / Math.max(busy, 1)).toFixed(3);
console.log(`\ndesign.md §D6.1 — meshing, ${CHUNK_COUNT} chunks of 16^3 ` +
  `(${SPAN_X}x${SPAN_Y}x${SPAN_Z})\n`);
console.log(`  generate      ${per(gen)} ms/chunk      ${perBusy(busyGen)} ms/non-empty`);
console.log(`  mesh          ${per(mesh)} ms/chunk      ${perBusy(busyMesh)} ms/non-empty`);
console.log(`  total         ${per(gen + mesh)} ms/chunk      ${perBusy(busyGen + busyMesh)} ms/non-empty`);
console.log(`  worst chunk   ${worst.toFixed(3)} ms`);
console.log(`  faces         ${(faces / Math.max(busy, 1)).toFixed(0)} avg per non-empty chunk`);
console.log(`  vertices      ${(verts / Math.max(busy, 1)).toFixed(0)} avg per non-empty chunk`);
console.log(`  non-empty     ${busy} of ${CHUNK_COUNT} (${empty} fully interior or fully air)`);

const budget = 8.0;
console.log("");
if (busy === 0) {
  console.log("FAIL — every chunk meshed empty; the generator produced no terrain");
  process.exit(1);
}
console.log(worst <= budget
  ? `PASS — worst chunk ${worst.toFixed(3)} ms is within the ${budget} ms budget`
  : `FAIL — worst chunk ${worst.toFixed(3)} ms exceeds the ${budget} ms budget`);
