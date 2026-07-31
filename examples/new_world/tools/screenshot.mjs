// Composites a real viewport of a generated world to a PNG, using the same
// atlas and the same world.gene the browser runs. No canvas, no browser — so
// the world can be reviewed (and regressions seen) from a terminal.
//
//   node examples/new_world/game/tools/screenshot.mjs [seed] [camX] [camY]

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { generate, get_tile, surface_at, render_variant } from "../dist/world.mjs";
import { atlasPixels, TILE, COLS, ATLAS_W, encodePng } from "./gen_atlas.mjs";

const W = 512;
const H = 192;
const seed = Number(process.argv[2] ?? 1);

const VIEW_W = 960;
const VIEW_H = 480;

const tiles = new Array(W * H).fill(0);
generate(tiles, W, H, seed);

// Frame the shot on the surface at mid-map unless told otherwise, so the
// default screenshot shows the thing worth looking at.
const centreX = Math.floor(W / 2);
const camX = Number(process.argv[3] ?? centreX * TILE - VIEW_W / 2);
const camY = Number(process.argv[4] ?? (surface_at(centreX, seed) - 8) * TILE);

const out = new Uint8Array(VIEW_W * VIEW_H * 4);

// Sky gradient, matching main.mjs so the screenshot is representative.
for (let y = 0; y < VIEW_H; y++) {
  const t = y / VIEW_H;
  const depth = Math.min(1, Math.max(0, (camY / TILE - 40) / 90));
  const top = depth > 0.5 ? [0x0b, 0x0d, 0x12] : [0x8f, 0xc4, 0xe8];
  const bot = depth > 0.2 ? [0x0b, 0x0d, 0x12] : [0xcf, 0xe6, 0xf4];
  for (let x = 0; x < VIEW_W; x++) {
    const i = (y * VIEW_W + x) * 4;
    out[i] = top[0] + (bot[0] - top[0]) * t;
    out[i + 1] = top[1] + (bot[1] - top[1]) * t;
    out[i + 2] = top[2] + (bot[2] - top[2]) * t;
    out[i + 3] = 255;
  }
}

function blit(id, sx, sy) {
  const ax = (id % COLS) * TILE;
  const ay = Math.floor(id / COLS) * TILE;
  for (let y = 0; y < TILE; y++) {
    const dy = sy + y;
    if (dy < 0 || dy >= VIEW_H) continue;
    for (let x = 0; x < TILE; x++) {
      const dx = sx + x;
      if (dx < 0 || dx >= VIEW_W) continue;
      const si = ((ay + y) * ATLAS_W + (ax + x)) * 4;
      const a = atlasPixels[si + 3] / 255;
      if (a === 0) continue;
      const di = (dy * VIEW_W + dx) * 4;
      out[di] = atlasPixels[si] * a + out[di] * (1 - a);
      out[di + 1] = atlasPixels[si + 1] * a + out[di + 1] * (1 - a);
      out[di + 2] = atlasPixels[si + 2] * a + out[di + 2] * (1 - a);
    }
  }
}

const x0 = Math.floor(camX / TILE);
const y0 = Math.floor(camY / TILE);
for (let ty = y0; ty < y0 + VIEW_H / TILE + 2; ty++) {
  for (let tx = x0; tx < x0 + VIEW_W / TILE + 2; tx++) {
    const id = get_tile(tiles, tx, ty, W, H) | 0;
    if (id > 0) blit(render_variant(id, tx, ty) | 0, tx * TILE - camX, ty * TILE - camY);
    else if (ty > surface_at(tx, seed)) {
      const t = Math.min(1, (ty - surface_at(tx, seed)) / 55);
      rect(tx * TILE - camX, ty * TILE - camY, TILE, TILE,
[Math.round(0x3a - 0x22 * t), Math.round(0x40 - 0x26 * t), Math.round(0x4c - 0x2c * t)]);
    }
  }
}

// The player, drawn the way host.mjs draws them.
const px = Math.round((centreX + 0.5 - 0.3) * TILE - camX);
const py = Math.round(surface_at(centreX, seed) * TILE - camY - 1.8 * TILE);
function rect(x, y, w, h, [r, g, b]) {
  for (let j = 0; j < h; j++) {
    for (let i = 0; i < w; i++) {
      const dx = x + i;
      const dy = y + j;
      if (dx < 0 || dy < 0 || dx >= VIEW_W || dy >= VIEW_H) continue;
      const d = (dy * VIEW_W + dx) * 4;
      out[d] = r; out[d + 1] = g; out[d + 2] = b;
    }
  }
}
rect(px, py + 19, 10, 10, [0x2f, 0x35, 0x42]);
rect(px, py + 8, 10, 11, [0xc8, 0x5a, 0x54]);
rect(px - 1, py, 12, 9, [0xe8, 0xc3, 0x9e]);

const here = dirname(fileURLToPath(import.meta.url));
const path = join(here, "..", "assets", `screenshot_seed${seed}.png`);
mkdirSync(dirname(path), { recursive: true });
writeFileSync(path, encodePng(VIEW_W, VIEW_H, out));
console.log(`wrote ${path}  (seed ${seed}, cam ${Math.round(camX)},${Math.round(camY)})`);
