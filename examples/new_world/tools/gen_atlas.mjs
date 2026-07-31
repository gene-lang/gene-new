// Generates assets/tiles.png — the game's entire visual identity.
//
// Procedural rather than hand-drawn, because design.md §5.1 makes the palette
// effectively unchangeable after launch: generating it from a named palette and
// a seeded hash means it can be re-tuned by editing numbers here and re-running,
// rather than by repainting a file nobody has the source for.
//
//   node examples/new_world/game/tools/gen_atlas.mjs

import { deflateSync } from "node:zlib";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const TILE = 16;
const COLS = 4;
const ROWS = 4;
const W = TILE * COLS;
const H = TILE * ROWS;

// ---------------------------------------------------------------- palette ---
// One coherent earthy set. Every tile draws from it so districts read as
// composition rather than as unrelated art.
const P = {
  grass: [0x6a, 0x99, 0x55],
  grassDark: [0x4f, 0x7a, 0x3d],
  dirt: [0x8b, 0x68, 0x49],
  dirtDark: [0x6d, 0x50, 0x37],
  stone: [0x7d, 0x84, 0x91],
  stoneDark: [0x63, 0x6a, 0x76],
  log: [0x6b, 0x4f, 0x34],
  logDark: [0x52, 0x3b, 0x26],
  leaf: [0x4f, 0x7a, 0x42],
  leafDark: [0x3d, 0x61, 0x33],
  sand: [0xd6, 0xc0, 0x8a],
  sandDark: [0xc0, 0xa8, 0x71],
  water: [0x3f, 0x7f, 0xb5],
  waterDark: [0x35, 0x6d, 0x9e],
  coal: [0x2b, 0x2f, 0x36],
  iron: [0xc8, 0x9a, 0x6b],
  gold: [0xd9, 0xb0, 0x4a],
  plank: [0xa9, 0x79, 0x3f],
  plankDark: [0x8a, 0x60, 0x30],
};

// Deterministic value hash — same atlas on every machine, every run.
function hash(x, y, seed) {
  let h = (x * 374761393 + y * 668265263 + seed * 1442695040888963407) | 0;
  h = (h ^ (h >>> 13)) * 1274126177;
  return ((h ^ (h >>> 16)) >>> 0) / 4294967295;
}

const px = new Uint8Array(W * H * 4);

function put(x, y, [r, g, b], a = 255) {
  const i = (y * W + x) * 4;
  px[i] = r;
  px[i + 1] = g;
  px[i + 2] = b;
  px[i + 3] = a;
}

function mix(a, b, t) {
  return [
    Math.round(a[0] + (b[0] - a[0]) * t),
    Math.round(a[1] + (b[1] - a[1]) * t),
    Math.round(a[2] + (b[2] - a[2]) * t),
  ];
}

// Three-tone speckle. Two tones read as flat at 16px because half the pixels
// land on the base colour; adding a highlight gives the eye a grain to catch.
function speckle(ox, oy, base, dark, seed, density = 0.42) {
  const light = mix(base, [255, 255, 255], 0.16);
  const deep = mix(dark, [0, 0, 0], 0.18);
  for (let y = 0; y < TILE; y++) {
    for (let x = 0; x < TILE; x++) {
      const n = hash(x, y, seed);
      let c;
      if (n < density * 0.35) c = deep;
      else if (n < density) c = dark;
      else if (n > 1 - density * 0.4) c = light;
      else c = base;
      put(ox + x, oy + y, c);
    }
  }
}

// A few 2x2 clumps, so a material has structure at a scale above the pixel.
function pebbles(ox, oy, colour, seed, count) {
  for (let i = 0; i < count; i++) {
    const cx = Math.floor(hash(i, 2, seed) * (TILE - 1));
    const cy = Math.floor(hash(i, 5, seed) * (TILE - 1));
    for (let y = 0; y < 2; y++) {
      for (let x = 0; x < 2; x++) put(ox + cx + x, oy + cy + y, colour);
    }
  }
}

function oreBlobs(ox, oy, colour, seed, count) {
  for (let i = 0; i < count; i++) {
    const cx = 2 + Math.floor(hash(i, 7, seed) * (TILE - 5));
    const cy = 2 + Math.floor(hash(i, 13, seed) * (TILE - 5));
    const r = 1.2 + hash(i, 29, seed) * 1.1;
    for (let y = -3; y <= 3; y++) {
      for (let x = -3; x <= 3; x++) {
        if (x * x + y * y > r * r) continue;
        const tx = cx + x;
        const ty = cy + y;
        if (tx < 0 || ty < 0 || tx >= TILE || ty >= TILE) continue;
        const shade = hash(tx, ty, seed + 91) * 0.35;
        put(ox + tx, oy + ty, mix(colour, [0, 0, 0], shade));
      }
    }
  }
}

// ------------------------------------------------------------------ tiles ---
// Index order must match TILE_* in world.gene.
const tiles = [
  // 0 air — left transparent
  ["air", (ox, oy) => {}],

  ["grass", (ox, oy) => {
    speckle(ox, oy, P.dirt, P.dirtDark, 11);
    for (let x = 0; x < TILE; x++) {
      const depth = 3 + Math.floor(hash(x, 0, 5) * 3);
      for (let y = 0; y < depth; y++) {
        const n = hash(x, y, 17);
        put(ox + x, oy + y, n < 0.4 ? P.grassDark : P.grass);
      }
      // A few blades breaking the line, so the surface is not a ruler edge.
      if (hash(x, 99, 23) < 0.3) put(ox + x, oy + depth, P.grassDark);
    }
  }],

  ["dirt", (ox, oy) => {
    speckle(ox, oy, P.dirt, P.dirtDark, 31, 0.5);
    pebbles(ox, oy, mix(P.dirtDark, [0, 0, 0], 0.25), 33, 3);
  }],

  ["stone", (ox, oy) => {
    speckle(ox, oy, P.stone, P.stoneDark, 43, 0.5);
    // Faint fracture lines give scale to a big underground expanse.
    for (let i = 0; i < 3; i++) {
      let x = Math.floor(hash(i, 3, 47) * TILE);
      let y = Math.floor(hash(i, 9, 47) * TILE);
      for (let s = 0; s < 5; s++) {
        if (x >= 0 && y >= 0 && x < TILE && y < TILE) put(ox + x, oy + y, mix(P.stoneDark, [0, 0, 0], 0.3));
        x += hash(s, i, 51) < 0.5 ? 1 : 0;
        y += hash(s, i, 53) < 0.5 ? 1 : -0;
      }
    }
  }],

  ["log", (ox, oy) => {
    speckle(ox, oy, P.log, P.logDark, 61, 0.3);
    for (let y = 0; y < TILE; y++) {
      put(ox + 3, oy + y, P.logDark);
      put(ox + 11, oy + y, P.logDark);
    }
  }],

  ["leaves", (ox, oy) => {
    for (let y = 0; y < TILE; y++) {
      for (let x = 0; x < TILE; x++) {
        const n = hash(x, y, 71);
        // Holes let sky through, which is what stops a canopy reading as a box.
        if (n < 0.16) continue;
        put(ox + x, oy + y, n < 0.5 ? P.leafDark : P.leaf);
      }
    }
  }],

  ["sand", (ox, oy) => {
    speckle(ox, oy, P.sand, P.sandDark, 83, 0.55);
    pebbles(ox, oy, mix(P.sandDark, [0, 0, 0], 0.18), 87, 2);
  }],

  ["water", (ox, oy) => {
    for (let y = 0; y < TILE; y++) {
      for (let x = 0; x < TILE; x++) {
        const band = Math.sin(y * 0.9 + Math.sin(x * 0.55) * 1.3) * 0.5 + 0.5;
        const crest = band > 0.82 ? 0.5 : 0;
        const c = mix(mix(P.waterDark, P.water, band), [255, 255, 255], crest * 0.35);
        put(ox + x, oy + y, c, 205);
      }
    }
  }],

  ["coal_ore", (ox, oy) => {
    speckle(ox, oy, P.stone, P.stoneDark, 43, 0.5);
    oreBlobs(ox, oy, P.coal, 101, 4);
  }],

  ["iron_ore", (ox, oy) => {
    speckle(ox, oy, P.stone, P.stoneDark, 43, 0.5);
    oreBlobs(ox, oy, P.iron, 113, 3);
  }],

  ["gold_ore", (ox, oy) => {
    speckle(ox, oy, P.stone, P.stoneDark, 43, 0.5);
    oreBlobs(ox, oy, P.gold, 127, 3);
  }],

  ["plank", (ox, oy) => {
    speckle(ox, oy, P.plank, P.plankDark, 131, 0.25);
    for (let y = 3; y < TILE; y += 5) {
      for (let x = 0; x < TILE; x++) put(ox + x, oy + y, P.plankDark);
    }
    for (let y = 0; y < TILE; y++) {
      const seam = y < 3 ? 6 : y < 8 ? 12 : 4;
      put(ox + seam, oy + y, P.plankDark);
    }
  }],

  // 12-14: render-only variants. The world stores stone as 3 and dirt as 2;
  // these exist purely so a cliff face is not the same 16px stamp repeated
  // three hundred times, which is the single most obvious tell of tile art.
  ["stone_b", (ox, oy) => {
    speckle(ox, oy, P.stone, P.stoneDark, 211, 0.46);
    pebbles(ox, oy, mix(P.stoneDark, [0, 0, 0], 0.22), 213, 2);
  }],

  ["stone_c", (ox, oy) => {
    speckle(ox, oy, P.stone, P.stoneDark, 223, 0.54);
    for (let i = 0; i < 2; i++) {
      const y = 3 + Math.floor(hash(i, 1, 227) * (TILE - 6));
      for (let x = 2; x < TILE - 2; x++) {
        put(ox + x, oy + y + (hash(x, i, 229) < 0.3 ? 1 : 0),
            mix(P.stoneDark, [0, 0, 0], 0.28));
      }
    }
  }],

  ["dirt_b", (ox, oy) => {
    speckle(ox, oy, P.dirt, P.dirtDark, 233, 0.44);
    pebbles(ox, oy, mix(P.dirtDark, [0, 0, 0], 0.3), 239, 4);
  }],

];

for (let i = 0; i < tiles.length; i++) {
  const ox = (i % COLS) * TILE;
  const oy = Math.floor(i / COLS) * TILE;
  tiles[i][1](ox, oy);
}

// -------------------------------------------------------------- PNG encode ---
const crcTable = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(W, 0);
ihdr.writeUInt32BE(H, 4);
ihdr[8] = 8; // bit depth
ihdr[9] = 6; // colour type: RGBA
// 10..12 = compression, filter, interlace — all 0

// Filter byte 0 (None) per scanline.
const raw = Buffer.alloc(H * (1 + W * 4));
for (let y = 0; y < H; y++) {
  raw[y * (1 + W * 4)] = 0;
  Buffer.from(px.buffer, y * W * 4, W * 4).copy(raw, y * (1 + W * 4) + 1);
}

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", deflateSync(raw, { level: 9 })),
  chunk("IEND", Buffer.alloc(0)),
]);

function encodePng(width, height, pixels) {
  const hdr = Buffer.alloc(13);
  hdr.writeUInt32BE(width, 0);
  hdr.writeUInt32BE(height, 4);
  hdr[8] = 8;
  hdr[9] = 6;
  const rows = Buffer.alloc(height * (1 + width * 4));
  for (let y = 0; y < height; y++) {
    rows[y * (1 + width * 4)] = 0;
    Buffer.from(pixels.buffer, pixels.byteOffset + y * width * 4, width * 4).copy(
      rows,
      y * (1 + width * 4) + 1,
    );
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", hdr),
    chunk("IDAT", deflateSync(rows, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

export { px as atlasPixels, TILE, COLS, W as ATLAS_W, H as ATLAS_H, encodePng };

// Only write files when invoked directly; importing this module just builds
// the atlas in memory.
const isMain = process.argv[1] && process.argv[1].endsWith("gen_atlas.mjs");
if (!isMain) {
  // eslint-disable-next-line no-undef
} else {
const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "..", "assets", "tiles.png");
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, png);

// Nearest-neighbour blow-up on a mid grey, purely so the art can be reviewed at
// a size a human can judge. Not shipped to the game.
const S = 8;
const PW = W * S;
const PH = H * S;
const prev = new Uint8Array(PW * PH * 4);
for (let y = 0; y < PH; y++) {
  for (let x = 0; x < PW; x++) {
    const si = (Math.floor(y / S) * W + Math.floor(x / S)) * 4;
    const di = (y * PW + x) * 4;
    const a = px[si + 3] / 255;
    // Composite over a checker so transparent pixels are visibly transparent.
    const chk = (Math.floor(x / (S * 2)) + Math.floor(y / (S * 2))) % 2 ? 0x50 : 0x3a;
    prev[di] = Math.round(px[si] * a + chk * (1 - a));
    prev[di + 1] = Math.round(px[si + 1] * a + chk * (1 - a));
    prev[di + 2] = Math.round(px[si + 2] * a + chk * (1 - a));
    prev[di + 3] = 255;
  }
}
const previewPath = join(here, "..", "assets", "tiles_preview.png");
writeFileSync(previewPath, encodePng(PW, PH, prev));

console.log(`wrote ${out}`);
console.log(`  ${W}x${H}, ${tiles.length} tiles of ${TILE}px, ${png.length} bytes`);
console.log(`  ${tiles.map((t, i) => `${i}:${t[0]}`).join("  ")}`);
console.log(`wrote ${previewPath} (${PW}x${PH} review blow-up)`);
}
