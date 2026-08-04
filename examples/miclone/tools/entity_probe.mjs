// design.md §8's `on_step` — a dropped item that falls, and the mod is what
// makes it fall.
//
//   gene run server &
//   node tools/entity_probe.mjs
//
// §8.1 listed "no entity physics — a dropped item stays where it was dropped,
// including in the air if the node under it is later dug" as the engine's first
// named absence. `mods/default` fills it with an `on_step`, and the engine
// gained no notion of gravity. This probe is the check, and what it asserts is
// the shape of that claim: an item is left hanging by digging the node under
// it, the socket then goes **silent**, and what arrives is the server stepping
// a mod's function on its own tick.
//
// The hotbar has to be full before a dig drops anything, so most of this file
// is fixture: eight distinct items, found by digging whatever the terrain
// offers rather than by naming nodes a generated world may not have here.

const D = new URL("../dist/", import.meta.url).pathname;
const { new_cursor } = await import(D + "wire.mjs");
const P = await import(D + "protocol.mjs");
const R = await import(D + "registry.mjs");

const PORT = 8790, BLOCK = 16;
const K = {
  hello: P.kind_hello(), registry: P.kind_registry(), block: P.kind_block(),
  delta: P.kind_node_delta(), entity: P.kind_entity(),
  inventory: P.kind_inventory(),
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
const header = P.new_block_header(), ent = P.new_entity_msg();
const outC = new Float32Array(4096), outL = new Float32Array(4096);
let reg = null;
const blocks = new Map();
const deltas = [], entities = [], invs = [];
let waitBlocks = 0, blocksDone = null;

ws.onmessage = (e) => {
  const b = new Uint8Array(e.data);
  const kind = P.message_kind(b);
  if (kind === K.hello) P.decode_hello(b, c, hello);
  else if (kind === K.registry) {
    reg = R.new_wire_registry();
    P.decode_registry(b, c, reg);
  } else if (kind === K.block) {
    P.decode_block(b, c, header, outC, outL);
    blocks.set(`${header[0]},${header[1]},${header[2]}`, { content: outC.slice() });
    if (blocks.size >= waitBlocks && blocksDone) blocksDone();
  } else if (kind === K.delta) {
    P.decode_node_delta(b, c, delta);
    deltas.push([...delta]);
  } else if (kind === K.entity) {
    P.decode_entity(b, c, ent);
    entities.push([...ent, Date.now()]);
  } else if (kind === K.inventory) {
    const inv = new Float64Array(24);
    P.decode_inventory(b, c, inv);
    invs.push([...inv]);
  }
};

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
await new Promise((res, rej) => {
  ws.onopen = res;
  ws.onerror = () => rej(new Error(`no server on ${PORT} — run \`gene run server\``));
  setTimeout(() => rej(new Error("connect timed out")), 5000);
});
await wait(400);

console.log("\ndesign.md §8 — a dropped item falls, and a mod is what makes it\n");

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

const ox = hello[2] * BLOCK, oy = hello[3] * BLOCK, oz = hello[4] * BLOCK;
const at = (b, nx, ny, nz) => b.content[(nx & 15) + 16 * (ny & 15) + 256 * (nz & 15)];
const nodeAt = (nx, ny, nz) => {
  const b = blocks.get(`${Math.floor(nx / BLOCK)},${Math.floor(ny / BLOCK)},${Math.floor(nz / BLOCK)}`);
  return b ? at(b, ((nx % 16) + 16) % 16, ((ny % 16) + 16) % 16, ((nz % 16) + 16) % 16) : -1;
};
const digAt = (x, y, z) => {
  const m = new Uint8Array(P.size_dig());
  P.encode_dig(m, rc, x, y, z);
  ws.send(m);
};

// Fill the hotbar. Eight slots, and a slot is claimed per distinct *item* —
// so digging one spot eight times stacks into one slot and never overflows.
// Distinct node kinds are not enough either: the drop table maps several nodes
// onto one item (grass yields dirt, §2's one exception), so this collects every
// kind the world has at every depth and digs them until the inventory says the
// eighth slot is taken. Terrain-driven rather than named, because the world is
// generated and a hardcoded node list is a fixture that rots.
const candidates = [];
const seenKind = new Set();
// Buried nodes count. The ores are never exposed and they are exactly the
// distinct items this needs, and a dig does not require line of sight — §7.1's
// authority check is about what the client *holds*, not where it is standing.
for (let x = ox + 1; x < ox + hello[5] * BLOCK - 1 && seenKind.size < 20; x += 2) {
  for (let z = oz + 1; z < oz + hello[7] * BLOCK - 1 && seenKind.size < 20; z += 2) {
    for (let y = oy + hello[6] * BLOCK - 2; y > oy + 1; y--) {
      const n = nodeAt(x, y, z);
      if (n > 0 && !seenKind.has(n)) {
        seenKind.add(n);
        candidates.push([x, y, z, n]);
      }
    }
  }
}
say(candidates.length >= 3, "found distinct node kinds to dig",
    `${candidates.length}: ` +
    candidates.map((s) => reg && R.name_of(reg, s[3])).join(", "));

const filled = () => {
  if (!invs.length) return 0;
  const last = invs[invs.length - 1];
  let n = 0;
  for (let i = 0; i < 8; i++) if (last[i * 2 + 1] > 0) n++;
  return n;
};

const beforeEnt = entities.length;
for (const [x, y, z] of candidates) {
  if (entities.length > beforeEnt) break;
  digAt(x, y, z);
  await wait(200);
}
say(entities.length > beforeEnt, "the hotbar filled and a dig dropped an entity",
    `${filled()}/8 slots, ${entities.length - beforeEnt} entity message(s)`);
if (entities.length === beforeEnt) {
  console.log("\nFAIL — no fixture: the hotbar never filled, so nothing was dropped");
  ws.close(); process.exit(1);
}

// Where it landed. The spawn is the centre of the node that was dug, so the
// node beneath it is what the item is resting on.
const spawned = entities[entities.length - 1];
const [eid, ex, ey, ez] = spawned;
say(spawned[5] > 0, "and it carries a stack", `x${spawned[5]}`);

const restY = ey;
await wait(600);
const stillThere = entities.filter((e) => e[0] === eid);
say(stillThere[stillThere.length - 1][2] === restY,
    "and it rests, because the node under it is solid",
    `y ${restY}`);

// Now take away what it is standing on. An item rests at the centre of the node
// it was dropped in — `n + 0.5` — so the node holding it up is the one *below*
// that, and digging `floor(ey)` would dig the air it is sitting in. Getting
// this wrong is how the first run of this probe read a working `on_step` as a
// broken one: nothing was removed, so nothing fell, and the check was right
// about what it saw.
const underY = Math.floor(ey) - 1;
digAt(Math.floor(ex), underY, Math.floor(ez));
// Shorter than one 100 ms tick, so the fall cannot land inside the window the
// client was still talking in. `tick_probe` records the same trap from the
// other side — it waited 600 ms there and read a working tick as a broken one.
await wait(50);

// And go quiet. Everything from here is the server's own tick.
const quiet = entities.length;
await wait(2000);
const moves = entities.slice(quiet).filter((e) => e[0] === eid);
say(moves.length > 0, "the server moved it while the client said nothing",
    `${moves.length} unsolicited entity message(s)`);
const lowest = moves.length ? moves[moves.length - 1][2] : restY;
say(lowest < restY, "and it fell", `y ${restY} -> ${lowest}`);

// It stops, rather than falling through the world. Two seconds at 6 nodes a
// second would leave it 12 nodes down if nothing caught it.
await wait(1500);
const after = entities.filter((e) => e[0] === eid);
const settled = after[after.length - 1][2];
say(settled > oy, "and it stopped inside the world rather than falling through",
    `y ${settled}, world floor ${oy}`);
// And it comes to rest rather than drifting for as long as the server runs.
// Compared against the previous sample rather than against the world, because
// this probe's copy of the blocks predates every dig above.
await wait(1200);
const later = entities.filter((e) => e[0] === eid);
say(later[later.length - 1][2] === settled, "and it came to rest",
    `y ${settled}, unchanged over 1.2 s`);

console.log("");
console.log(bad === 0
  ? "PASS — §8's on_step runs on the server tick, and the physics is the mod's"
  : `FAIL — ${bad} check(s) failed`);
ws.close();
process.exit(bad === 0 ? 0 : 1);
