// design.md §5's M5 build, measured on the runtime that runs it.
//
//   gene build --target web core/loaded.gene --out-dir dist     (and friends)
//   node tools/world_build.mjs
//
// The client's three build passes without a browser in front of them:
// generate every block into one array, light the whole array in one call, mesh
// every chunk out of it. `tools/mesh_bench.mjs` measures the same stages a
// chunk at a time and is still the §D6.1 budget check; this one measures what
// M5 actually does, which is a different shape — one 194 x 66 x 194 lighting
// call instead of 576 small ones — and reports what a world costs to open.
//
// It also checks the two invariants a loaded world has and a padded
// neighbourhood does not: the shell is intact, and light crossed a block
// boundary. The second is the M3 limitation this milestone exists to remove, so
// a build that quietly went back to per-block lighting should fail here rather
// than look slightly wrong on screen.

import { generate_block } from "../dist/mapgen.mjs";
import { light_region } from "../dist/light.mjs";
import { count_faces, build_mesh } from "../dist/mesh.mjs";
import { new_registry, id_of, registered_count } from "../dist/registry.mjs";
import { setup_nodes, setup_biomes, setup_ores } from "../dist/content.mjs";
import {
  new_world, store_block, block_base, open_sky, node_at, light_at,
  world_dx, world_dy, world_dz, world_stride_z, world_nodes,
} from "../dist/loaded.mjs";
import { day_of } from "../dist/light.mjs";
import {
  new_player, step, player_x, player_y, player_z,
  on_ground$q, box_blocked$q,
} from "../dist/physics.mjs";

const SEED = 1337;
const BLOCK = 16;
// client/main.gene's extent and site, restated: the web profile exports
// functions rather than `let` constants.
const ORIGIN_BX = -90, ORIGIN_BY = 0, ORIGIN_BZ = 198;
const SPAN_X = 12, SPAN_Y = 4, SPAN_Z = 12;
const QUEUE_OVERHEAD = 4;
const FLOATS_PER_VERTEX = 7;

const reg = new_registry();
setup_nodes(reg);
const biomes = setup_biomes(reg);
const ores = setup_ores(reg);
const AIR = id_of(reg, "air");
const WATER = id_of(reg, "miclone:water");
const IGNORE = id_of(reg, "ignore");
const REGISTERED = registered_count(reg);

const t0 = performance.now();
const world = new_world(ORIGIN_BX, ORIGIN_BY, ORIGIN_BZ, SPAN_X, SPAN_Y, SPAN_Z);
const DX = world_dx(world), DY = world_dy(world), DZ = world_dz(world);
const SZ = world_stride_z(world);
const tAlloc = performance.now();

const block = new Float32Array(BLOCK * BLOCK * BLOCK);
const blockSky = new Float32Array(BLOCK * BLOCK);
for (let cz = 0; cz < SPAN_Z; cz++)
  for (let cy = 0; cy < SPAN_Y; cy++)
    for (let cx = 0; cx < SPAN_X; cx++) {
      const bx = ORIGIN_BX + cx, by = ORIGIN_BY + cy, bz = ORIGIN_BZ + cz;
      generate_block(block, blockSky, bx * BLOCK, by * BLOCK, bz * BLOCK,
                     biomes, ores, SEED, AIR, WATER);
      store_block(world, bx, by, bz, block);
    }
const tGen = performance.now();

const sky = new Float32Array(DX * DZ);
open_sky(world, sky);
const queue = new Float32Array(world_nodes(world) + QUEUE_OVERHEAD);
light_region(world.light, world.content, DX, DY, DZ, reg, sky, queue, REGISTERED);
const tLight = performance.now();

let faces = 0, drawn = 0, vertexBytes = 0, worst = 0;
for (let cz = 0; cz < SPAN_Z; cz++)
  for (let cy = 0; cy < SPAN_Y; cy++)
    for (let cx = 0; cx < SPAN_X; cx++) {
      const bx = ORIGIN_BX + cx, by = ORIGIN_BY + cy, bz = ORIGIN_BZ + cz;
      const t = performance.now();
      const base = block_base(world, bx, by, bz);
      const n = count_faces(reg, world.content, base, DX, SZ);
      if (n > 0) {
        const verts = new Float32Array(n * 4 * FLOATS_PER_VERTEX);
        const idx = new Uint32Array(n * 6);
        build_mesh(reg, world.content, world.light, verts, idx, base, DX, SZ,
                   bx * BLOCK, by * BLOCK, bz * BLOCK);
        faces += n;
        drawn++;
        vertexBytes += verts.byteLength + idx.byteLength;
      }
      worst = Math.max(worst, performance.now() - t);
    }
const tMesh = performance.now();

const mb = (b) => (b / (1 << 20)).toFixed(1);
const ms = (t) => t.toFixed(1);
console.log(`\ndesign.md §5 — opening a world: ${SPAN_X}x${SPAN_Y}x${SPAN_Z} ` +
  `blocks, ${DX}x${DY}x${DZ} nodes\n`);
console.log(`  allocate      ${ms(tAlloc - t0)} ms`);
console.log(`  generate      ${ms(tGen - tAlloc)} ms   ` +
  `(${((tGen - tAlloc) / (SPAN_X * SPAN_Y * SPAN_Z)).toFixed(3)} ms/block)`);
console.log(`  light         ${ms(tLight - tGen)} ms   one call over ` +
  `${(world_nodes(world) / 1e6).toFixed(2)}M nodes`);
console.log(`  mesh          ${ms(tMesh - tLight)} ms   ` +
  `worst chunk ${worst.toFixed(3)} ms`);
console.log(`  total         ${ms(tMesh - t0)} ms`);
console.log("");
console.log(`  faces         ${faces} in ${drawn} of ` +
  `${SPAN_X * SPAN_Y * SPAN_Z} chunks`);
console.log(`  node arrays   ${mb(world.content.byteLength + world.light.byteLength)} MB` +
  `   queue ${mb(queue.byteLength)} MB   geometry ${mb(vertexBytes)} MB`);

// --- invariants --------------------------------------------------------------

let bad = 0;

// The shell. One node outside the world on every axis must read `ignore`
// through the array, and out of the array must read `ignore` too — physics and
// the mesher both rely on "one step past the edge is not walkable and hides
// nothing behind it".
const minX = ORIGIN_BX * BLOCK, minY = ORIGIN_BY * BLOCK, minZ = ORIGIN_BZ * BLOCK;
const maxX = minX + SPAN_X * BLOCK - 1;
const maxY = minY + SPAN_Y * BLOCK - 1;
const maxZ = minZ + SPAN_Z * BLOCK - 1;
const shell = [
  [minX - 1, minY + 8, minZ + 8], [maxX + 1, minY + 8, minZ + 8],
  [minX + 8, minY - 1, minZ + 8],
  [minX + 8, minY + 8, minZ - 1], [minX + 8, minY + 8, maxZ + 1],
  [minX - 40, minY + 8, minZ + 8],          // well outside the array
];
for (const [x, y, z] of shell) {
  if (node_at(world, x, y, z) !== IGNORE) {
    console.log(`FAIL — shell: (${x},${y},${z}) is ${node_at(world, x, y, z)}, want ignore`);
    bad++;
  }
}
// The ceiling is the one face that is air, because the sun comes in through it.
if (node_at(world, minX + 8, maxY + 1, minZ + 8) !== AIR) {
  console.log("FAIL — shell: the ceiling is not air, so no sunlight can enter");
  bad++;
}

// Light crossed a block boundary. Find a column of open sky and check that the
// daylight at the top of one block and at the bottom of the block above it are
// both full: per-block lighting cannot produce that, because the lower block's
// sky was never open.
let crossings = 0, sampled = 0;
for (let x = minX + 4; x < minX + 60 && crossings < 20; x += 3)
  for (let z = minZ + 4; z < minZ + 60 && crossings < 20; z += 3) {
    // A block boundary well above the terrain but below the ceiling.
    const y = minY + 2 * BLOCK;
    if (node_at(world, x, y, z) !== AIR) continue;
    sampled++;
    if (day_of(light_at(world, x, y - 1, z)) === 15 &&
        day_of(light_at(world, x, y, z)) === 15) crossings++;
  }
if (sampled === 0 || crossings === 0) {
  console.log(`FAIL — light: ${crossings} of ${sampled} sampled columns carry ` +
    "full daylight across a block boundary");
  bad++;
}

// --- walking the real world --------------------------------------------------
//
// probes/physics_spec.gene checks §7's collision against hand-built fixtures,
// which is where a derived expected value can exist. What a fixture cannot
// check is §3's terrain: overhangs, cave mouths, a shoreline, ore pockets, and
// the seams between 576 blocks. So the same invariant runs here against the
// world the client actually opens — never inside a block, never below the
// world — over a walk that crosses it.
//
// The spawn is the client's: down the middle column from the ceiling to the
// first drawn node, which is what puts a player on the surface rather than at
// the bottom of whatever cave happens to be under them.

// The column is whole — core/loaded.gene indexes with it and a fractional
// coordinate reads as `undefined` rather than raising. The player stands in the
// middle of that node, which is the + 0.5 below.
const COL_X = (ORIGIN_BX + SPAN_X / 2) * BLOCK;
const COL_Z = (ORIGIN_BZ + SPAN_Z / 2) * BLOCK;
let spawnY = (ORIGIN_BY + SPAN_Y) * BLOCK;
while (spawnY > ORIGIN_BY * BLOCK &&
       node_at(world, COL_X, spawnY - 1, COL_Z) === AIR) spawnY--;
const SPAWN_X = COL_X + 0.5, SPAWN_Z = COL_Z + 0.5;

const player = new_player(SPAWN_X, spawnY, SPAWN_Z);
const DT = 1 / 60;
let insideCount = 0, belowCount = 0, travelled = 0;
let lowest = spawnY, highest = spawnY;
const tWalk = performance.now();
const FRAMES = 7200;                       // two minutes of walking
for (let f = 0; f < FRAMES; f++) {
  // Eight compass directions, 240 frames each — sixteen nodes of walking per
  // leg, so the walk crosses block seams rather than circling one chunk.
  const leg = Math.floor(f / 240);
  const dir = (leg * 3) % 8;
  const wx = [1, 1, 0, -1, -1, -1, 0, 1][dir];
  const wz = [0, 1, 1, 1, 0, -1, -1, -1][dir];
  const len = Math.hypot(wx, wz) || 1;
  const x0 = player_x(player), y0 = player_y(player), z0 = player_z(player);
  step(player, world, reg, wx / len, wz / len, f % 47 === 0, false, false, DT);
  travelled += Math.abs(player_x(player) - x0) + Math.abs(player_z(player) - z0);
  if (box_blocked$q(world, reg, player_x(player), player_y(player), player_z(player)))
    insideCount++;
  if (player_y(player) < ORIGIN_BY * BLOCK) belowCount++;
  lowest = Math.min(lowest, player_y(player));
  highest = Math.max(highest, player_y(player));
}
const walkMs = performance.now() - tWalk;

console.log("");
console.log(`  spawn         (${SPAWN_X}, ${spawnY}, ${SPAWN_Z})`);
console.log(`  walk          ${FRAMES} frames in ${walkMs.toFixed(1)} ms ` +
  `(${(walkMs / FRAMES * 1000).toFixed(1)} us/step), ` +
  `${travelled.toFixed(0)} nodes travelled, y ${lowest.toFixed(1)}..${highest.toFixed(1)}`);
if (insideCount > 0) {
  console.log(`FAIL — physics: inside a block on ${insideCount} of ${FRAMES} frames`);
  bad++;
}
if (belowCount > 0) {
  console.log(`FAIL — physics: below the world on ${belowCount} frames`);
  bad++;
}
if (travelled < 200) {
  console.log(`FAIL — physics: the walk covered ${travelled.toFixed(0)} nodes; it is stuck`);
  bad++;
}

console.log("");
console.log(bad === 0
  ? `PASS — shell intact, daylight crosses block boundaries ` +
    `(${crossings}/${sampled} columns), and ${FRAMES} frames of walking never ` +
    `left the world or entered a block`
  : `FAIL — ${bad} invariant(s) broken`);
if (bad !== 0) process.exit(1);
