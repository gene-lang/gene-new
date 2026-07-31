// D5 spike harness. Compares the transpiled Gene sim against a hand-written JS
// sim doing exactly the same arithmetic, so the ratio isolates what the web
// profile's lowering costs rather than what the algorithm costs.
//
//   node examples/new_world/spike/tools/bench.mjs [sprites] [frames]

import { advance, bench } from "../dist/sprites.mjs";
import { now_ms } from "../canvas.mjs";

const N = Number(process.argv[2] ?? 10000);
const FRAMES = Number(process.argv[3] ?? 600);
const W = 1280;
const H = 720;

function makeState(n) {
  const xs = new Array(n);
  const ys = new Array(n);
  const vxs = new Array(n);
  const vys = new Array(n);
  // Deterministic, so both sims see identical inputs.
  let seed = 12345;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  for (let i = 0; i < n; i++) {
    xs[i] = rnd() * W;
    ys[i] = rnd() * H;
    vxs[i] = rnd() * 4 - 2;
    vys[i] = rnd() * 4 - 2;
  }
  return { xs, ys, vxs, vys };
}

// Hand-written equivalent of sprites.gene `advance`.
function advanceJs(xs, ys, vxs, vys, n, w, h) {
  for (let i = 0; i < n; i++) {
    let vx = vxs[i];
    let vy = vys[i];
    const x = xs[i] + vx;
    const y = ys[i] + vy;
    if (x < 0 || x > w) vx = -vx;
    if (y < 0 || y > h) vy = -vy;
    xs[i] = xs[i] + vx;
    ys[i] = ys[i] + vy;
    vxs[i] = vx;
    vys[i] = vy;
  }
}

// Consumed after every timed run so V8 cannot eliminate the simulation as dead
// code — without this the JS baseline "runs" 40x faster than it really does.
function checksum(s) {
  let acc = 0;
  for (let i = 0; i < s.xs.length; i++) acc += s.xs[i] + s.ys[i] * 3 + s.vxs[i] * 7 + s.vys[i] * 11;
  return acc;
}

let sink = 0;

function run(label, fn, warmup = 60) {
  const w = makeState(N);
  for (let i = 0; i < warmup; i++) fn(w, 1);
  sink += checksum(w);

  const s = makeState(N);
  const t0 = now_ms();
  fn(s, FRAMES);
  const ms = now_ms() - t0;
  const sum = checksum(s);
  sink += sum;
  const perFrame = ms / FRAMES;
  console.log(
    `${label.padEnd(34)} ${perFrame.toFixed(3).padStart(8)} ms/frame` +
      `   ${(1000 / perFrame).toFixed(0).padStart(6)} fps` +
      `   budget ${((perFrame / 16.667) * 100).toFixed(1)}%`,
  );
  return { perFrame, sum };
}

console.log(`\n${N} sprites, ${FRAMES} frames, ${process.version}\n`);

const js = run("hand-written JS", (s, f) => {
  for (let i = 0; i < f; i++) advanceJs(s.xs, s.ys, s.vxs, s.vys, N, W, H);
});

const geneLoop = run("Gene (loop only, 1 boundary call)", (s, f) => {
  bench(s.xs, s.ys, s.vxs, s.vys, N, f, W, H);
});

const geneFrame = run("Gene (advance per frame)", (s, f) => {
  for (let i = 0; i < f; i++) advance(s.xs, s.ys, s.vxs, s.vys, N, W, H);
});

// The transpiled sim must agree with the hand-written one, or the timings are
// measuring two different programs.
const agree =
  Math.abs(js.sum - geneLoop.sum) < 1e-6 && Math.abs(js.sum - geneFrame.sum) < 1e-6;
console.log(`\nchecksums agree: ${agree ? "yes" : "NO — sims diverged"}`);
if (!agree) console.log(`  js=${js.sum} geneLoop=${geneLoop.sum} geneFrame=${geneFrame.sum}`);

console.log(
  `Gene loop      vs JS: ${(geneLoop.perFrame / js.perFrame).toFixed(1)}x slower` +
    `\nGene per-frame vs JS: ${(geneFrame.perFrame / js.perFrame).toFixed(1)}x slower` +
    `\nexported-boundary validation: ${(geneFrame.perFrame - geneLoop.perFrame).toFixed(3)} ms/frame`,
);

// Largest sprite count that still fits a 60 fps frame, measured rather than
// extrapolated.
const perSprite = geneFrame.perFrame / N;
console.log(`\nheadroom at 60 fps (16.67 ms): ~${Math.floor(16.667 / perSprite).toLocaleString()} sprites`);
if (sink === Infinity) console.log("");
