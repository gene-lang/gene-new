// Headless check of world.gene: generation shape, physics, and interaction,
// with no canvas involved. Run after build.sh.
//
//   node examples/new_world/tools/test.mjs

import {
  generate, step_player, mine, place, get_tile, surface_at, solid$q as isSolid,
} from "../dist/world.mjs";
import {
  follow_camera, depth_shade, spawn_y, rle_encode, rle_decode, cycle_slot,
} from "../dist/shell.mjs";

const W = 512;
const H = 192;
const NAMES = ["air", "grass", "dirt", "stone", "log", "leaves",
               "sand", "water", "coal", "iron", "gold", "plank"];

let failures = 0;
function check(label, ok, detail = "") {
  if (!ok) failures++;
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${label}${detail ? `  — ${detail}` : ""}`);
}

// ---------------------------------------------------------------- generate ---
const tiles = new Array(W * H).fill(0);
const t0 = performance.now();
generate(tiles, W, H, 1);
const genMs = performance.now() - t0;

const hist = new Array(NAMES.length).fill(0);
for (const t of tiles) hist[t | 0]++;

console.log(`\ngeneration: ${W}x${H} = ${(W * H).toLocaleString()} tiles in ${genMs.toFixed(0)} ms\n`);
console.log("  " + hist.map((n, i) =>
  `${NAMES[i]} ${((n / tiles.length) * 100).toFixed(1)}%`).join("  ") + "\n");

check("every tile id is valid", hist.slice(0, NAMES.length).reduce((a, b) => a + b, 0) === W * H);
check("has sky", hist[0] > 0);
check("has grass", hist[1] > 0);
check("has stone", hist[3] > 0, `${hist[3]}`);
check("stone dominates", hist[3] / (W * H) > 0.3, `${((hist[3] / (W * H)) * 100).toFixed(1)}%`);
check("has trees", hist[4] > 0 && hist[5] > 0, `${hist[4]} log, ${hist[5]} leaves`);
check("has all three ores", hist[8] > 0 && hist[9] > 0 && hist[10] > 0,
  `coal ${hist[8]}, iron ${hist[9]}, gold ${hist[10]}`);
check("ore rarity ordered coal>iron>gold", hist[8] > hist[9] && hist[9] > hist[10]);
check("caves cut into rock", hist[0] > W * 60, `${hist[0]} air`);

// Surface must be continuous — no cliffs taller than a few tiles, or the world
// is unwalkable however good it looks.
let maxStep = 0;
for (let x = 1; x < W; x++) {
  maxStep = Math.max(maxStep, Math.abs(surface_at(x, 1) - surface_at(x - 1, 1)));
}
check("surface is walkable (no big cliffs)", maxStep <= 3, `max step ${maxStep}`);

// Determinism: the same seed must rebuild the same world, or saves that store
// only a seed are worthless.
const again = new Array(W * H).fill(0);
generate(again, W, H, 1);
check("generation is deterministic", again.every((v, i) => v === tiles[i]));

const other = new Array(W * H).fill(0);
generate(other, W, H, 2);
check("a different seed differs", other.some((v, i) => v !== tiles[i]));

// ----------------------------------------------------------------- physics ---
console.log("\nphysics\n");
const x = Math.floor(W / 2);
let y = 0;
while (y < H - 3 && get_tile(tiles, x, y + 2, W, H) < 0.5) y++;
const p = [x + 0.5, y, 0, 0, 0, 1];

for (let i = 0; i < 240; i++) step_player(tiles, p, 0, 0, 0, W, H, 1);
check("falls and lands", p[4] > 0.5, `y=${p[1].toFixed(2)} grounded=${p[4]}`);
check("stands on solid ground",
  isSolid(get_tile(tiles, Math.floor(p[0]), Math.floor(p[1] + 1.9), W, H)),
  `tile below = ${NAMES[get_tile(tiles, Math.floor(p[0]), Math.floor(p[1] + 1.9), W, H) | 0]}`);
check("body is not inside rock",
  !isSolid(get_tile(tiles, Math.floor(p[0]), Math.floor(p[1] + 1.0), W, H)));

const restY = p[1];
for (let i = 0; i < 60; i++) step_player(tiles, p, 0, 0, 0, W, H, 1);
check("rests still once landed", Math.abs(p[1] - restY) < 0.01, `drift ${(p[1] - restY).toFixed(4)}`);

const beforeX = p[0];
for (let i = 0; i < 60; i++) step_player(tiles, p, 0, 1, 0, W, H, 1);
check("walks right", p[0] > beforeX, `${beforeX.toFixed(2)} -> ${p[0].toFixed(2)}`);
check("faces right", p[5] > 0);

for (let i = 0; i < 60; i++) step_player(tiles, p, 1, 0, 0, W, H, 1);
check("faces left after walking left", p[5] < 0);

// Jump must leave the ground and come back down.
const groundY = p[1];
step_player(tiles, p, 0, 0, 1, W, H, 1);
let peak = p[1];
for (let i = 0; i < 90; i++) {
  step_player(tiles, p, 0, 0, 0, W, H, 1);
  peak = Math.min(peak, p[1]);
}
check("jump gets airborne", groundY - peak > 1.5, `rose ${(groundY - peak).toFixed(2)} tiles`);
check("jump lands again", Math.abs(p[1] - groundY) < 0.5, `y=${p[1].toFixed(2)}`);

// --------------------------------------------------------------- interaction ---
console.log("\ninteraction\n");
const tx = Math.floor(p[0]);
const ty = Math.floor(p[1] + 2);
const was = get_tile(tiles, tx, ty, W, H);
const got = mine(tiles, p, tx, ty, W, H);
check("mining returns the tile mined", got === was, `${NAMES[was | 0]}`);
check("mined tile becomes air", get_tile(tiles, tx, ty, W, H) === 0);

check("placing fills it back", place(tiles, p, tx, ty, 11, W, H) === 1);
check("placed tile is what was chosen", get_tile(tiles, tx, ty, W, H) === 11);
check("cannot place into a solid tile", place(tiles, p, tx, ty, 3, W, H) === 0);

const farX = Math.floor(p[0]) + 40;
check("cannot mine out of reach", mine(tiles, p, farX, ty, W, H) === 0);
check("cannot place out of reach", place(tiles, p, farX, ty, 3, W, H) === 0);

// Sealing yourself into a wall is the classic griefing-yourself bug.
check("cannot place inside the player",
  place(tiles, p, Math.floor(p[0]), Math.floor(p[1]), 3, W, H) === 0);

// ---------------------------------------------------------------- shell ---
// The camera, spawn scan, save encoding, and hotbar live in shell.gene. The
// save round-trip is the one that matters most: a wrong pair count would
// silently truncate somebody's world.
console.log("\nshell\n");

const out = new Array(W * H).fill(0);
const pairs = rle_encode(tiles, W * H, out, out.length);
const runs = out.slice(0, pairs * 2);
const back = new Array(W * H).fill(0);
rle_decode(runs, runs.length / 2, back, W * H);
check("save round-trips every tile", back.every((v, i) => v === tiles[i]),
  `${pairs} pairs, ${((pairs * 2 / (W * H)) * 100).toFixed(1)}% of raw`);
check("run lengths sum to the whole world",
  (() => { let s = 0; for (let i = 1; i < runs.length; i += 2) s += runs[i]; return s === W * H; })());

const sx = Math.floor(W / 2);
const sy = spawn_y(tiles, sx, W, H);
check("spawn stands on solid ground", get_tile(tiles, sx, sy + 2, W, H) > 0.5, `y=${sy}`);
check("spawn head is clear", get_tile(tiles, sx, sy, W, H) < 0.5);

const cam = [0, 0];
for (let i = 0; i < 200; i++) follow_camera(cam, 5, 5, W, H, 1280, 720, 0.18);
check("camera clamps at the near edge", cam[0] === 0 && cam[1] === 0, `[${cam}]`);
for (let i = 0; i < 400; i++) follow_camera(cam, W - 1, H - 1, W, H, 1280, 720, 0.18);
check("camera clamps at the far edge",
  cam[0] === W * 16 - 1280 && cam[1] === H * 16 - 720, `[${cam}]`);
const cam2 = [0, 0];
follow_camera(cam2, 100, 100, W, H, 1280, 720, 0.18);
check("camera eases rather than snapping", cam2[0] > 0 && cam2[0] < 100 * 16 - 640,
  cam2[0].toFixed(1));

check("depth_shade clamps to its limit", depth_shade(99999, 76, 110, 0.55) === 0.55);
check("depth_shade floors at zero", depth_shade(0, 76, 110, 0.55) === 0);

check("hotbar wraps forward", cycle_slot(9, 1, 10) === 0);
check("hotbar wraps backward", cycle_slot(0, -1, 10) === 9);
check("hotbar steps normally", cycle_slot(3, 1, 10) === 4);

console.log(`\n${failures === 0 ? "all checks passed" : `${failures} FAILED`}\n`);
process.exit(failures === 0 ? 0 : 1);
