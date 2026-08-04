// design.md §12's tick, and the first thing in this engine that changes without
// being asked.
//
//   gene run server &
//   node tools/tick_probe.mjs
//
// Every other network harness drives a request and checks the answer. This one
// checks that the server does something **nobody asked it to**: it digs the
// node under a column of sand and then stops talking, and what it waits for is
// an unsolicited node delta arriving on a socket that sent nothing.
//
// That is the whole difference between M6's reactive server and §12's ticking
// one, and it is why the check is "a message arrived during silence" rather
// than "a message had the right contents".

const D = new URL("../dist/", import.meta.url).pathname;
const { new_cursor } = await import(D + "wire.mjs");
const P = await import(D + "protocol.mjs");
const R = await import(D + "registry.mjs");

const PORT = 8790, BLOCK = 16;
const K = {
  hello: P.kind_hello(), registry: P.kind_registry(), block: P.kind_block(),
  delta: P.kind_node_delta(),
};

let bad = 0;
const say = (ok, label, detail) => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label}${detail ? "   " + detail : ""}`);
  if (!ok) bad++;
};

const ws = new WebSocket(`ws://127.0.0.1:${PORT}/`);
ws.binaryType = "arraybuffer";
const c = new_cursor(), rc = new_cursor();
const hello = P.new_hello(), delta = P.new_node_delta();
const header = P.new_block_header();
const outC = new Float32Array(4096), outL = new Float32Array(4096);
let reg = null;
const blocks = new Map();
const deltas = [];
let waitBlocks = 0, blocksDone = null;

ws.onmessage = (e) => {
  const b = new Uint8Array(e.data);
  const kind = P.message_kind(b);
  if (kind === K.hello) P.decode_hello(b, c, hello);
  else if (kind === K.registry) {
    reg = R.new_registry(); reg.names = []; reg.count[0] = 0;
    P.decode_registry(b, c, reg);
  } else if (kind === K.block) {
    P.decode_block(b, c, header, outC, outL);
    blocks.set(`${header[0]},${header[1]},${header[2]}`,
               { content: outC.slice() });
    if (blocks.size >= waitBlocks && blocksDone) blocksDone();
  } else if (kind === K.delta) {
    P.decode_node_delta(b, c, delta);
    deltas.push([...delta]);
  }
};

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
await new Promise((res, rej) => {
  ws.onopen = res;
  ws.onerror = () => rej(new Error(`no server on ${PORT} — run \`gene run server\``));
  setTimeout(() => rej(new Error("connect timed out")), 5000);
});
await wait(400);

console.log("\ndesign.md §12 — the server tick, and a world that changes on its own\n");

// The whole world, so the probe can find a sand column rather than guess one.
const total = hello[5] * hello[6] * hello[7];
for (let from = 0; from < total; from += 64) {
  const count = Math.min(64, total - from);
  waitBlocks = from + count;
  const arrived = new Promise((res) => { blocksDone = res; });
  const m = new Uint8Array(P.size_request_blocks());
  P.encode_request_blocks(m, rc, from, count);
  ws.send(m);
  await Promise.race([arrived,
    new Promise((_, r) => setTimeout(() => r(new Error(`window ${from} timed out`)), 20000))]);
}
say(blocks.size === total, "the world arrived", `${blocks.size} blocks`);

// Find a sand node with sand under it, so that digging below leaves a column
// with nothing holding it up. Searching rather than assuming a position: the
// terrain is generated and a hardcoded coordinate is a fixture that rots.
const SAND = R.id_of(reg, "miclone:sand");
const ox = hello[2] * BLOCK, oy = hello[3] * BLOCK, oz = hello[4] * BLOCK;
const at = (b, nx, ny, nz) =>
  b.content[(nx & 15) + 16 * (ny & 15) + 256 * (nz & 15)];
const nodeAt = (nx, ny, nz) => {
  const b = blocks.get(`${Math.floor(nx / BLOCK)},${Math.floor(ny / BLOCK)},${Math.floor(nz / BLOCK)}`);
  return b ? at(b, ((nx % 16) + 16) % 16, ((ny % 16) + 16) % 16, ((nz % 16) + 16) % 16) : -1;
};

let target = null;
outer:
for (let x = ox + 1; x < ox + hello[5] * BLOCK - 1 && !target; x++)
  for (let z = oz + 1; z < oz + hello[7] * BLOCK - 1; z++)
    for (let y = oy + 2; y < oy + hello[6] * BLOCK - 1; y++)
      if (nodeAt(x, y, z) === SAND && nodeAt(x, y + 1, z) === SAND &&
          nodeAt(x, y - 1, z) !== 0) { target = [x, y - 1, z]; break outer; }

say(target !== null, "found a sand column with something under it",
    target ? `sand at ${target[0]}, ${target[1] + 1}, ${target[2]}` : "none");
if (!target) { console.log("\nFAIL — no fixture"); ws.close(); process.exit(1); }

// Dig the support out. That is the last thing this socket says.
const before = deltas.length;
const dig = new Uint8Array(P.size_dig());
P.encode_dig(dig, rc, target[0], target[1], target[2]);
ws.send(dig);
// Only long enough for the dig's own answer. The tick is 100 ms and a column
// falls a node per tick, so waiting longer here would let the whole cascade
// land inside the "asked for it" window and leave nothing to observe during
// the silence below — which is exactly how this probe first read a working
// tick as a broken one.
await wait(120);
say(deltas.length >= before + 1, "digging under it answers",
    `${deltas.length - before} delta(s)`);

// And now silence. Anything that arrives from here is the server acting on its
// own, which is the property §12 exists for and M6 could not have.
const quiet = deltas.length;
await wait(2500);
const unsolicited = deltas.length - quiet;
say(unsolicited > 0,
    "the server sent node deltas while the client said nothing",
    `${unsolicited} unsolicited delta(s)`);

// Two ABMs run on this server and they are triggered differently, so what
// arrives during the silence is sorted by *where* rather than counted. The
// column is the targeted one (§12's check queue); anything else is the ambient
// walk, which has the whole world to choose from and is not aimed at us.
//
// This check used to be "all of them in the column", and it was right until the
// sampled trigger had a mod action to run. It was the probe that was wrong, not
// the server — the ambient ABM firing somewhere else during the window is the
// engine doing exactly what §12 asks.
const moved = deltas.slice(quiet);
const inColumn = moved.filter((d) => d[0] === target[0] && d[2] === target[2]);
const elsewhere = moved.filter((d) => d[0] !== target[0] || d[2] !== target[2]);
const becameAir = inColumn.filter((d) => d[3] === 0).length;
const becameSand = inColumn.filter((d) => d[3] === SAND).length;
say(inColumn.length > 0, "the column that lost its support is one of them",
    `${inColumn.length} in column, ${elsewhere.length} elsewhere`);
say(becameSand > 0 && becameAir > 0,
    "and they are a node moving: some became sand, some became air",
    `${becameSand} sand, ${becameAir} air`);
say(inColumn.every((d) => d[1] >= target[1] && d[1] <= target[1] + 8),
    "and each is within the span the column could have moved through");

console.log("");
console.log(bad === 0
  ? "PASS — the world changed without being asked, which is what §12's tick is for"
  : `FAIL — ${bad} check(s) failed`);
ws.close();
process.exit(bad === 0 ? 0 : 1);
