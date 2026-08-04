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
import { id_of, registered_count } from "../dist/registry.mjs";
// §9's game, exactly as the engine gets it: one call, and the registries come
// off the `Game` it returns. This harness never names a content id either.
import { load_mods } from "../dist/mods.mjs";
import {
  new_world, store_block, block_base, open_sky, node_at, light_at, set_node,
  world_dx, world_dy, world_dz, world_stride_z, world_nodes,
} from "../dist/loaded.mjs";
import { day_of } from "../dist/light.mjs";
import {
  new_player, step, player_x, player_y, player_z,
  on_ground$q, box_blocked$q,
} from "../dist/physics.mjs";
import {
  new_hit, cast, hit$q, hit_x, hit_y, hit_z, before_x, before_y, before_z,
  pointable$q,
} from "../dist/raycast.mjs";
import {
  new_inventory, add, take, slot_item, slot_count, slot_empty$q, total_of,
} from "../dist/inventory.mjs";
import { drop_item, drop_count } from "../dist/drops.mjs";
// §2 gave items their own id space, so what a dig yields and what a hotbar
// holds are item ids; `item_node` is how one becomes a node again.
import { item_node, item_named, placeable_item$q } from "../dist/item.mjs";
import { new_cursor, cursor_at } from "../dist/wire.mjs";
import {
  block_size, encode_block, decode_block, new_block_header,
  registry_size, encode_registry,
} from "../dist/protocol.mjs";
import {
  new_bounds, apply_node, diggable$q, placeable$q,
  bounds_min_x, bounds_min_y, bounds_min_z,
  bounds_max_x, bounds_max_y, bounds_max_z,
} from "../dist/edit.mjs";

const SEED = 1337;
const BLOCK = 16;
// client/main.gene's extent and site, restated: the web profile exports
// functions rather than `let` constants.
const ORIGIN_BX = -90, ORIGIN_BY = 0, ORIGIN_BZ = 198;
const SPAN_X = 12, SPAN_Y = 4, SPAN_Z = 12;
const QUEUE_OVERHEAD = 4;
const FLOATS_PER_VERTEX = 7;

const game = load_mods();
const reg = game.nodes;
const biomes = game.biomes;
const ores = game.ores;
const decors = game.decors;
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
                     biomes, ores, decors, SEED, AIR, WATER);
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

// --- editing the real world --------------------------------------------------
//
// probes/edit_spec.gene proves an incremental relight equals a full one on a
// hand-built fixture. This asks the same question of §3's terrain, where the
// light is a real sky over a real heightfield with caves under it — and reports
// what an edit costs, which is the number a player feels.

const editQueue = new Float32Array(world_nodes(world) + QUEUE_OVERHEAD);
const editSeed = new Float32Array(world_nodes(world) + QUEUE_OVERHEAD);
const bounds = new_bounds();
const AIR_ID = AIR;
const LAMP = id_of(reg, "miclone:lamp");

// A shaft straight down from the surface, then a lamp at the bottom of it:
// the two edits with the largest and the most awkward consequences. The shaft
// carries daylight down with it at every step, and the lamp lights a ball in a
// place that has never had light.
const editX = Math.floor(SPAWN_X), editZ = Math.floor(SPAWN_Z);
const edits = [];
for (let d = 0; d < 12; d++) edits.push([editX, spawnY - 1 - d, editZ, AIR_ID]);
edits.push([editX, spawnY - 12, editZ, LAMP]);

let editTotal = 0, worstEdit = 0, chunkTotal = 0, worstChunks = 0;
for (const [ex, ey, ez, id] of edits) {
  const t = performance.now();
  apply_node(world, reg, ex, ey, ez, id, sky, editQueue, editSeed, bounds);
  const ms = performance.now() - t;
  // The chunks the caller would have to remesh, counted the way client/main
  // counts them.
  const cLo = (v, o) => Math.max(0, Math.floor((v - o * BLOCK) / BLOCK));
  const cHi = (v, o, span) =>
    Math.min(span - 1, Math.floor((v - o * BLOCK) / BLOCK));
  const nChunks =
    (cHi(bounds_max_x(bounds), ORIGIN_BX, SPAN_X) - cLo(bounds_min_x(bounds), ORIGIN_BX) + 1) *
    (cHi(bounds_max_y(bounds), ORIGIN_BY, SPAN_Y) - cLo(bounds_min_y(bounds), ORIGIN_BY) + 1) *
    (cHi(bounds_max_z(bounds), ORIGIN_BZ, SPAN_Z) - cLo(bounds_min_z(bounds), ORIGIN_BZ) + 1);
  editTotal += ms;
  worstEdit = Math.max(worstEdit, ms);
  chunkTotal += nChunks;
  worstChunks = Math.max(worstChunks, nChunks);
}

// The property, against §3's terrain: the same world, generated fresh, with the
// same nodes set and lit from zero, must agree node for node.
const check = new_world(ORIGIN_BX, ORIGIN_BY, ORIGIN_BZ, SPAN_X, SPAN_Y, SPAN_Z);
for (let cz = 0; cz < SPAN_Z; cz++)
  for (let cy = 0; cy < SPAN_Y; cy++)
    for (let cx = 0; cx < SPAN_X; cx++) {
      const bx = ORIGIN_BX + cx, by = ORIGIN_BY + cy, bz = ORIGIN_BZ + cz;
      generate_block(block, blockSky, bx * BLOCK, by * BLOCK, bz * BLOCK,
                     biomes, ores, decors, SEED, AIR, WATER);
      store_block(check, bx, by, bz, block);
    }
for (const [ex, ey, ez, id] of edits) set_node(check, ex, ey, ez, id);
light_region(check.light, check.content, DX, DY, DZ, reg, sky,
             new Float32Array(world_nodes(check) + QUEUE_OVERHEAD), REGISTERED);

let lightDiff = 0, nodeDiff = 0;
for (let i = 0; i < world.light.length; i++) {
  if (world.light[i] !== check.light[i]) lightDiff++;
  if (world.content[i] !== check.content[i]) nodeDiff++;
}

// The client's own path, minus the DOM: cast from the eye, ask whether the
// node may be dug, apply. Straight down, so the answer is derivable — the node
// under the player's feet — and five in a row, so the player is standing on a
// hole they made and the cast has to keep finding its floor.
const aim = new_hit();
let castDug = 0, castWrong = 0;
for (let i = 0; i < 5; i++) {
  const px = player_x(player), py = player_y(player), pz = player_z(player);
  cast(world, reg, aim, px, py + 1.625, pz, 0, -1, 0, 5);
  if (!hit$q(aim)) break;
  if (hit_x(aim) !== Math.floor(px) || hit_z(aim) !== Math.floor(pz)) castWrong++;
  if (!diggable$q(world, reg, hit_x(aim), hit_y(aim), hit_z(aim))) break;
  apply_node(world, reg, hit_x(aim), hit_y(aim), hit_z(aim), AIR_ID,
             sky, editQueue, editSeed, bounds);
  if (node_at(world, hit_x(aim), hit_y(aim), hit_z(aim)) !== AIR_ID) castWrong++;
  castDug++;
  // Let the player fall into the hole, as they would on screen.
  for (let f = 0; f < 30; f++) step(player, world, reg, 0, 0, false, false, false, DT);
}
if (castDug !== 5 || castWrong !== 0) {
  console.log(`FAIL — dig path: dug ${castDug} of 5 nodes by raycast, ` +
    `${castWrong} landed somewhere unexpected`);
  bad++;
}

console.log("");
console.log(`  dig by ray    ${castDug} nodes straight down, each the node ` +
  `under the player`);
console.log(`  edits         ${edits.length} (a 12-node shaft and a lamp): ` +
  `${editTotal.toFixed(2)} ms total, worst ${worstEdit.toFixed(2)} ms`);
console.log(`  remesh scope  ${(chunkTotal / edits.length).toFixed(1)} chunks ` +
  `per edit on average, worst ${worstChunks}`);
if (nodeDiff !== 0) {
  console.log(`FAIL — edit: ${nodeDiff} nodes differ from a freshly built world`);
  bad++;
}
if (lightDiff !== 0) {
  console.log(`FAIL — edit: incremental relight differs from a full relight ` +
    `at ${lightDiff} nodes`);
  bad++;
}

// --- the loop ----------------------------------------------------------------
//
// Dig a node, get its drop; place it, lose it from the hand and gain it in the
// world. That is what M5 set out to end with, so it is asserted rather than
// left to a screenshot: the client wires these four modules together and the
// wiring is the only part a spec per module cannot see.

const drops = game.drops;
const items = game.items;
const inv = new_inventory(8);
let loopBad = 0;

// Three surface nodes beside the spawn column. Deliberately not relative to the
// player: by this point the walk and the shaft have moved them somewhere the
// fixture does not control, and a fixture that samples an uncontrolled position
// is the trap M3 and M4 both fell into.
const dugIds = [];
for (let i = 0; i < 3; i++) {
  const nx = COL_X + 2 + i, nz = COL_Z + 2;
  // Down to the first *pointable* node, not the first non-air one: the spawn
  // stands on a coastline and the columns beside it are sea, which §7 leaves
  // unpointable on purpose. A ray fired at them goes through to the floor, and
  // so does this.
  let sy = (ORIGIN_BY + SPAN_Y) * BLOCK - 1;
  while (sy > ORIGIN_BY * BLOCK &&
         !pointable$q(reg, node_at(world, nx, sy, nz))) sy--;
  const ny = sy;
  if (!diggable$q(world, reg, nx, ny, nz)) { loopBad++; continue; }
  const was = node_at(world, nx, ny, nz);
  apply_node(world, reg, nx, ny, nz, AIR_ID, sky, editQueue, editSeed, bounds);
  const left = add(inv, items, drop_item(drops, items, was),
                   drop_count(drops, items, was));
  if (left !== 0) loopBad++;
  if (node_at(world, nx, ny, nz) !== AIR_ID) loopBad++;
  dugIds.push([nx, ny, nz, drop_item(drops, items, was)]);
}
// Summed over slots rather than over the dug ids: three stone dug is three
// items in one slot, and totalling per id would report nine.
let carried = 0;
for (let i = 0; i < 8; i++) carried += slot_count(inv, i);
if (dugIds.length !== 3) loopBad++;

// And put them back, spending the stack each time.
let placed = 0;
for (const [nx, ny, nz, id] of dugIds) {
  // Find the slot holding it, as the hotbar would.
  let slot = -1;
  for (let i = 0; i < 8; i++)
    if (!slot_empty$q(inv, i) && slot_item(inv, i) === id) { slot = i; break; }
  if (slot < 0) { loopBad++; continue; }
  if (!placeable$q(world, reg, nx, ny, nz)) { loopBad++; continue; }
  if (!placeable_item$q(items, id)) { loopBad++; continue; }
  const asNode = item_node(items, id);
  if (take(inv, slot, 1) !== 1) { loopBad++; continue; }
  apply_node(world, reg, nx, ny, nz, asNode, sky, editQueue, editSeed, bounds);
  if (node_at(world, nx, ny, nz) !== asNode) loopBad++;
  placed++;
}

// Grass is the one node in the set whose drop is not itself, so a dug meadow
// comes back as dirt. If the fixture happened to dig grass, that shows up here
// as a node that changed identity, which is correct and worth saying.
const GRASS = id_of(reg, "miclone:grass");
if (drop_item(drops, items, GRASS) !== item_named(items, "miclone:dirt")) loopBad++;
if (drop_item(drops, items, id_of(reg, "miclone:stone")) !==
    item_named(items, "miclone:stone")) loopBad++;
// And §2's new case: a dug ore yields a lump, which is an item no one can place.
const COAL = id_of(reg, "miclone:coal_ore");
const lump = drop_item(drops, items, COAL);
if (lump !== item_named(items, "miclone:coal_lump")) loopBad++;
if (placeable_item$q(items, lump)) loopBad++;

console.log("");
console.log(`  dig and place ${dugIds.length} dug and carried ` +
  `(${carried} items), ${placed} placed back, ` +
  `hand now ${slot_empty$q(inv, 0) ? "empty" : "holding " + slot_count(inv, 0)}`);
if (loopBad !== 0) {
  console.log(`FAIL — loop: ${loopBad} step(s) of dig-carry-place went wrong`);
  bad++;
}

// --- what a world costs on the wire ------------------------------------------
//
// §10 moves a block per message and says block data needs "a packed binary
// encoding because 16 KB of nodes should not become a node tree". This is the
// number behind that sentence, measured on §3's real terrain rather than on a
// fixture — a uniform block is one run and tells you nothing.

{
  const wc = new_cursor();
  let totalBytes = 0, worstBytes = 0, encodeMs = 0, decodeMs = 0;
  let emptyBlocks = 0, worstAt = "";
  const outC = new Float32Array(4096);
  const outL = new Float32Array(4096);
  const header = new_block_header();
  let mismatch = 0;

  for (let cz = 0; cz < SPAN_Z; cz++)
    for (let cy = 0; cy < SPAN_Y; cy++)
      for (let cx = 0; cx < SPAN_X; cx++) {
        const bx = ORIGIN_BX + cx, by = ORIGIN_BY + cy, bz = ORIGIN_BZ + cz;
        const base = block_base(world, bx, by, bz);
        const size = block_size(world.content, world.light, base, DX, SZ);
        const msg = new Uint8Array(size);
        let t = performance.now();
        encode_block(msg, wc, bx, by, bz, world.content, world.light,
                     base, DX, SZ);
        encodeMs += performance.now() - t;
        totalBytes += size;
        if (size > worstBytes) { worstBytes = size; worstAt = `${bx},${by},${bz}`; }
        if (size <= 21) emptyBlocks++;   // 13 header + two single runs

        // And it decodes back to the same nodes. Checked on every block rather
        // than a sample: a run encoder's bugs are all about boundaries, and the
        // world has 576 different boundaries in it.
        t = performance.now();
        decode_block(msg, wc, header, outC, outL);
        decodeMs += performance.now() - t;
        for (let z = 0; z < 16 && !mismatch; z++)
          for (let y = 0; y < 16 && !mismatch; y++)
            for (let x = 0; x < 16; x++) {
              const src = base + y * DX + z * SZ + x;
              const dst = x + y * 16 + z * 256;
              if (outC[dst] !== world.content[src] ||
                  outL[dst] !== world.light[src]) { mismatch++; break; }
            }
      }

  const blocks = SPAN_X * SPAN_Y * SPAN_Z;
  const raw = blocks * 4096 * 4;      // u16 content + u8 light, padded to 4B/node
  const rc = new_cursor();
  const regSize = registry_size(reg);
  const regMsg = new Uint8Array(regSize);
  encode_registry(regMsg, rc, reg);

  console.log("");
  console.log(`  registry msg  ${regSize} bytes for ` +
    `${registered_count(reg)} node definitions`);
  console.log(`  block msgs    ${(totalBytes / blocks).toFixed(0)} bytes mean, ` +
    `${worstBytes} worst (at ${worstAt}), ${emptyBlocks} of ${blocks} uniform`);
  console.log(`  world on wire ${(totalBytes / (1 << 20)).toFixed(2)} MB ` +
    `against ${(raw / (1 << 20)).toFixed(1)} MB raw ` +
    `(${(raw / totalBytes).toFixed(0)}x)`);
  console.log(`  codec         ${(encodeMs / blocks * 1000).toFixed(0)} us to ` +
    `encode a block, ${(decodeMs / blocks * 1000).toFixed(0)} us to decode`);
  if (mismatch) {
    console.log("FAIL — protocol: a block did not survive the wire codec");
    bad++;
  }
}

console.log("");
console.log(bad === 0
  ? `PASS — shell intact, daylight crosses block boundaries ` +
    `(${crossings}/${sampled} columns), ${FRAMES} frames of walking never ` +
    `left the world or entered a block, and ${edits.length} edits relit the ` +
    `world exactly as a full relight would, and a node dug is a node carried ` +
    `and placed`
  : `FAIL — ${bad} invariant(s) broken`);
if (bad !== 0) process.exit(1);
