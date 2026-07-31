// Game shell. Owns the canvas, the keyboard, the world arrays, and the save
// slot — everything world.gene is not allowed to hold, because the web profile
// rejects top-level mutable state.

import {
  generate,
  step_player,
  render,
  render_player,
  render_cursor,
  mine,
  place,
  get_tile,
} from "./dist/world.mjs";
// From dist/, not from here: dist/world.mjs imports "./host.mjs" relative to
// itself, and importing a second copy would give bind() a different module
// instance than draw_tile() reads from.
import { bind } from "./dist/host.mjs";

const W = 512;   // world width in tiles
const H = 192;   // world height in tiles
const TILE = 16;
const SAVE_KEY = "new_world.save.v1";

const NAMES = [
  "air", "grass", "dirt", "stone", "log", "leaves",
  "sand", "water", "coal", "iron", "gold", "plank",
];
// What you can hold and place. Air and water are not placeable.
const PLACEABLE = [1, 2, 3, 4, 5, 6, 8, 9, 10, 11];

const canvas = document.getElementById("stage");
const ctx = canvas.getContext("2d", { alpha: false });
const hud = document.getElementById("hud");
const bar = document.getElementById("bar");

let tiles = new Array(W * H).fill(0);
let player = new Array(6).fill(0);
let inventory = new Array(NAMES.length).fill(0);
let selected = 0;
let seed = 1;

// ------------------------------------------------------------------ input ---
const keys = new Set();
let mouseX = 0;
let mouseY = 0;
let mining = false;
let placing = false;

addEventListener("keydown", (e) => {
  if (e.code === "Space" || e.code.startsWith("Arrow")) e.preventDefault();
  keys.add(e.code);
  const n = "0123456789".indexOf(e.key);
  if (n > 0) selected = Math.min(n - 1, PLACEABLE.length - 1);
});
addEventListener("keyup", (e) => keys.delete(e.code));

canvas.addEventListener("contextmenu", (e) => e.preventDefault());
canvas.addEventListener("mousemove", (e) => {
  const r = canvas.getBoundingClientRect();
  mouseX = (e.clientX - r.left) * (canvas.width / r.width);
  mouseY = (e.clientY - r.top) * (canvas.height / r.height);
});
canvas.addEventListener("mousedown", (e) => {
  if (e.button === 0) mining = true;
  if (e.button === 2) placing = true;
});
addEventListener("mouseup", () => {
  mining = false;
  placing = false;
});
canvas.addEventListener("wheel", (e) => {
  e.preventDefault();
  selected = (selected + (e.deltaY > 0 ? 1 : PLACEABLE.length - 1)) % PLACEABLE.length;
}, { passive: false });

// ------------------------------------------------------------------ world ---
function spawn() {
  // Drop the player down the middle column until they land on something.
  const x = Math.floor(W / 2);
  let y = 0;
  while (y < H - 3 && get_tile(tiles, x, y + 2, W, H) < 0.5) y++;
  player = [x + 0.5, y, 0, 0, 0, 1];
}

function newWorld(withSeed) {
  seed = withSeed;
  tiles = new Array(W * H).fill(0);
  const t0 = performance.now();
  generate(tiles, W, H, seed);
  const ms = performance.now() - t0;
  inventory = new Array(NAMES.length).fill(0);
  spawn();
  console.log(`generated ${W}x${H} (${(W * H).toLocaleString()} tiles) in ${ms.toFixed(0)} ms`);
  return ms;
}

// ------------------------------------------------------------------- save ---
function save() {
  // Run-length encode: a world is mostly long runs of stone and air.
  const runs = [];
  let last = tiles[0];
  let n = 0;
  for (let i = 0; i < tiles.length; i++) {
    if (tiles[i] === last) n++;
    else {
      runs.push(last, n);
      last = tiles[i];
      n = 1;
    }
  }
  runs.push(last, n);
  localStorage.setItem(SAVE_KEY, JSON.stringify({ seed, player, inventory, runs }));
  flash("saved");
}

function load() {
  const raw = localStorage.getItem(SAVE_KEY);
  if (!raw) return flash("no save");
  const s = JSON.parse(raw);
  tiles = new Array(W * H);
  let i = 0;
  for (let r = 0; r < s.runs.length; r += 2) {
    for (let k = 0; k < s.runs[r + 1]; k++) tiles[i++] = s.runs[r];
  }
  seed = s.seed;
  player = s.player;
  inventory = s.inventory;
  flash("loaded");
}

let flashText = "";
let flashUntil = 0;
function flash(text) {
  flashText = text;
  flashUntil = performance.now() + 1200;
}

addEventListener("keydown", (e) => {
  if (e.code === "KeyN") newWorld((Math.random() * 1e6) | 0);
  if (e.code === "KeyS" && !e.metaKey && !e.ctrlKey) save();
  if (e.code === "KeyL") load();
});

// ------------------------------------------------------------------- loop ---
let camX = 0;
let camY = 0;
let frames = 0;
let simAcc = 0;
let drawAcc = 0;
let fpsText = "";

function frame() {
  const vw = canvas.width;
  const vh = canvas.height;

  const t0 = performance.now();
  step_player(
    tiles,
    player,
    keys.has("KeyA") || keys.has("ArrowLeft") ? 1 : 0,
    keys.has("KeyD") || keys.has("ArrowRight") ? 1 : 0,
    keys.has("Space") || keys.has("KeyW") || keys.has("ArrowUp") ? 1 : 0,
    W, H, 1,
  );

  // Camera centres the player, then clamps so the view never leaves the world.
  const targetX = player[0] * TILE - vw / 2;
  const targetY = player[1] * TILE - vh / 2;
  camX += (targetX - camX) * 0.18;
  camY += (targetY - camY) * 0.18;
  camX = Math.max(0, Math.min(W * TILE - vw, camX));
  camY = Math.max(0, Math.min(H * TILE - vh, camY));

  const tx = Math.floor((mouseX + camX) / TILE);
  const ty = Math.floor((mouseY + camY) / TILE);

  if (mining) {
    const got = mine(tiles, player, tx, ty, W, H);
    if (got > 0) inventory[got | 0]++;
  }
  if (placing) {
    const id = PLACEABLE[selected];
    if (inventory[id] > 0 && place(tiles, player, tx, ty, id, W, H) > 0) inventory[id]--;
  }
  const t1 = performance.now();

  // Sky gradient: depth is legible before you read a single number.
  const depth = Math.min(1, Math.max(0, (camY / TILE - 40) / 90));
  const g = ctx.createLinearGradient(0, 0, 0, vh);
  g.addColorStop(0, depth > 0.5 ? "#0b0d12" : "#8fc4e8");
  g.addColorStop(1, depth > 0.2 ? "#0b0d12" : "#cfe6f4");
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, vw, vh);

  render(tiles, W, H, camX, camY, vw, vh, seed);

  // One overlay rather than per-tile shading: depth should feel like light
  // running out, and a single gradient costs one draw instead of 3,600.
  const dark = Math.min(0.55, Math.max(0, (camY / TILE - 76) / 110));
  if (dark > 0.01) {
    ctx.fillStyle = `rgba(4,6,12,${dark.toFixed(3)})`;
    ctx.fillRect(0, 0, vw, vh);
  }
  render_player(player, camX, camY);
  render_cursor(tiles, player, tx, ty, camX, camY, W, H);
  const t2 = performance.now();

  simAcc += t1 - t0;
  drawAcc += t2 - t1;
  if (++frames === 30) {
    const total = (simAcc + drawAcc) / frames;
    fpsText =
      `${(1000 / total).toFixed(0)} fps · sim ${(simAcc / frames).toFixed(2)} ms · ` +
      `draw ${(drawAcc / frames).toFixed(2)} ms`;
    frames = 0;
    simAcc = 0;
    drawAcc = 0;
  }

  hud.textContent =
    `${fpsText}   ·   x ${player[0].toFixed(1)} y ${player[1].toFixed(1)}   ·   ` +
    `seed ${seed}` +
    (performance.now() < flashUntil ? `   ·   ${flashText}` : "");

  for (let i = 0; i < slots.length; i++) {
    slots[i].el.classList.toggle("on", i === selected);
    const n = String(inventory[PLACEABLE[i]]);
    if (slots[i].count.textContent !== n) slots[i].count.textContent = n;
  }

  requestAnimationFrame(frame);
}

// Hotbar is built once from static data and mutated in place — no markup is
// assembled from values at runtime, and no DOM is rebuilt per frame.
const slots = PLACEABLE.map((id, i) => {
  const el = document.createElement("span");
  el.className = "slot";
  const label = document.createElement("span");
  label.textContent = `${i + 1} ${NAMES[id]} `;
  const count = document.createElement("b");
  count.textContent = "0";
  el.append(label, count);
  bar.append(el);
  return { el, count };
});

// ------------------------------------------------------------------- boot ---
function resize() {
  canvas.width = Math.min(1280, Math.floor(innerWidth - 32));
  canvas.height = Math.min(720, Math.floor(innerHeight - 150));
}
addEventListener("resize", resize);
resize();

const atlas = new Image();
atlas.src = "./assets/tiles.png";
atlas.onload = () => {
  bind(ctx, atlas);
  newWorld(1);
  requestAnimationFrame(frame);
};
