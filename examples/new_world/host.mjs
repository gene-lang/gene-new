// Host externs for world.gene. Everything here takes and returns plain JS
// `number`, never `bigint` — the canvas API takes numbers and a bigint crossing
// this boundary would throw. That is why world.gene is F64 throughout.

export const floor = Math.floor;
export const abs = Math.abs;
export const sin = Math.sin;

const TILE = 16;
const ATLAS_COLS = 4;

let ctx = null;
let atlas = null;

export function bind(context, atlasImage) {
  ctx = context;
  atlas = atlasImage;
  ctx.imageSmoothingEnabled = false;
}

export function draw_tile(id, sx, sy) {
  const i = id | 0;
  ctx.drawImage(
    atlas,
    (i % ATLAS_COLS) * TILE,
    Math.floor(i / ATLAS_COLS) * TILE,
    TILE,
    TILE,
    Math.round(sx),
    Math.round(sy),
    TILE,
    TILE,
  );
}

export function draw_player(sx, sy, facing) {
  const x = Math.round(sx);
  const y = Math.round(sy);
  const w = Math.round(0.6 * TILE);
  const h = Math.round(1.8 * TILE);

  ctx.fillStyle = "#2f3542";                 // legs
  ctx.fillRect(x, y + h - 10, w, 10);
  ctx.fillStyle = "#c85a54";                 // torso
  ctx.fillRect(x, y + 8, w, h - 18);
  ctx.fillStyle = "#e8c39e";                 // head
  ctx.fillRect(x - 1, y, w + 2, 9);
  ctx.fillStyle = "#2f3542";                 // eye, so facing is readable
  ctx.fillRect(facing < 0 ? x : x + w - 3, y + 3, 2, 2);
}

// The wall behind a cave. Without this, air below the surface shows the sky
// gradient and every cavern reads as a hole punched through the world.
export function draw_backdrop(sx, sy, depth) {
  const t = Math.min(1, depth / 55);
  const r = Math.round(0x3a - 0x22 * t);
  const g = Math.round(0x40 - 0x26 * t);
  const b = Math.round(0x4c - 0x2c * t);
  ctx.fillStyle = `rgb(${r},${g},${b})`;
  ctx.fillRect(Math.round(sx), Math.round(sy), TILE, TILE);
}

export function draw_highlight(sx, sy, ok) {
  ctx.strokeStyle = ok > 0.5 ? "rgba(255,255,255,0.85)" : "rgba(255,120,120,0.5)";
  ctx.lineWidth = 1;
  ctx.strokeRect(Math.round(sx) + 0.5, Math.round(sy) + 0.5, TILE - 1, TILE - 1);
}
