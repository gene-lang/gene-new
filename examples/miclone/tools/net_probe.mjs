// design.md §D8's M6: a client and a server as separate processes.
//
//   gene run server &                 (or: gene run server, in another shell)
//   node tools/net_probe.mjs
//
// Joins the running Gene server over a real WebSocket and drives the whole
// §10 exchange with the same `core/` modules the browser client uses: the
// handshake, the registry, flow-controlled block transfer, and §7.1's
// authoritative dig and place.
//
// Every other harness here runs one process. This is the only one that proves
// the *split* — that a world generated in one process arrives intact in
// another, and that the second one cannot lie to the first.

const D = new URL("../dist/", import.meta.url).pathname;
const { new_cursor } = await import(D + "wire.mjs");
const P = await import(D + "protocol.mjs");
const R = await import(D + "registry.mjs");
const T = await import(D + "tiles.mjs");
const IT = await import(D + "item.mjs");

const PORT = 8790;
const BLOCK = 16;
// The web profile exports functions, not `let` constants, so protocol.gene
// exposes the numbers a non-Gene peer needs as accessors — restating them here
// would be a second definition of the wire format.
const K = {
  hello: P.kind_hello(), registry: P.kind_registry(), block: P.kind_block(),
  delta: P.kind_node_delta(), inventory: P.kind_inventory(),
  tiles: P.kind_tiles(), items: P.kind_items(), craft: P.kind_craft(),
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

let clientReg = null, regCount = 0, bytes = 0;
let clientTiles = null, tileCount = 0;
let clientItems = null, itemCount = 0;
const blocks = new Map();
const deltas = [], invs = [];
let waitBlocks = 0, blocksDone = null;

ws.onmessage = (e) => {
  const b = new Uint8Array(e.data);
  bytes += b.length;
  const kind = P.message_kind(b);
  if (kind === K.hello) P.decode_hello(b, c, hello);
  else if (kind === K.registry) {
    // A *bare* registry: §2's three reserved ids are the first three the
    // message carries, so `new_registry` would install them twice and shift
    // every id by three.
    clientReg = R.new_registry();
    clientReg.names = [];
    clientReg.count[0] = 0;
    regCount = P.decode_registry(b, c, clientReg);
  }
  else if (kind === K.tiles) {
    // M7's appearance table. Fresh, for `decode_registry`'s reason: slots are
    // positional and `new_tiles` is already empty.
    clientTiles = T.new_tiles();
    tileCount = P.decode_tiles(b, c, clientTiles);
  }
  else if (kind === K.items) {
    clientItems = IT.new_items();
    itemCount = P.decode_items(b, c, clientItems);
  }
  else if (kind === K.block) {
    P.decode_block(b, c, header, outC, outL);
    blocks.set(`${header[0]},${header[1]},${header[2]}`,
               { content: outC.slice(), light: outL.slice() });
    if (blocks.size >= waitBlocks && blocksDone) blocksDone();
  }
  else if (kind === K.delta) {
    P.decode_node_delta(b, c, delta);
    deltas.push([...delta]);
  }
  else if (kind === K.inventory) {
    const inv = new Float64Array(24);
    P.decode_inventory(b, c, inv);
    invs.push([...inv]);
  }
};

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const send = (msg) => ws.send(msg);
const request = (from, count) => {
  const m = new Uint8Array(P.size_request_blocks());
  P.encode_request_blocks(m, rc, from, count);
  send(m);
};

await new Promise((res, rej) => {
  ws.onopen = res;
  ws.onerror = () => rej(new Error(`no server on ${PORT} — run \`gene run server\` first`));
  setTimeout(() => rej(new Error("connect timed out")), 5000);
});
await wait(400);

console.log("\ndesign.md §D8 M6 — a client and a server as separate processes\n");

say(hello[0] === P.version(), "the handshake names a protocol version",
    `v${hello[0]}`);
say(hello[5] > 0 && hello[6] > 0 && hello[7] > 0,
    "and the world's extent", `${hello[5]}x${hello[6]}x${hello[7]} blocks`);
say(regCount > 3, "the registry arrived with more than the reserved ids",
    `${regCount} nodes`);
say(clientReg && R.name_of(clientReg, 0) === "air",
    "and id 0 is air, as §1 reserves it");
say(clientReg && R.name_of(clientReg, 3) === "miclone:stone",
    "and the content set follows them",
    clientReg && R.name_of(clientReg, 3));
say(invs.length === 1, "and an inventory came with the handshake");
// §9: a client draws what a mod defined without ever running the mod. The only
// thing that crossed the wire to make that true is this table.
say(tileCount > 8, "the mod's tiles arrived, so a client can paint its atlas",
    `${tileCount} tiles`);
say(clientTiles && T.tile_name(clientTiles, 0) === "miclone:stone",
    "and the first is the one the mod registered first",
    clientTiles && T.tile_name(clientTiles, 0));
// §2's item vocabulary. An item id stopped being a content id, so without this
// a client cannot name what it holds or know whether it places anything.
say(itemCount > 13, "the mod's items arrived", `${itemCount} items`);
say(clientItems && !IT.placeable_item$q(clientItems,
      IT.item_named(clientItems, "miclone:wood_pickaxe")),
    "including one that places nothing, so the -1 node link survived");

// --- the whole world, flow-controlled ---------------------------------------
//
// A request cannot outrun its own answers, which is what keeps the server's
// 256-frame outbound queue from overflowing. Pushing all 576 blocks from
// `on_open` delivered 422 of them and reported success.
const total = hello[5] * hello[6] * hello[7];
const WINDOW = 64;
const t0 = performance.now();
for (let from = 0; from < total; from += WINDOW) {
  const count = Math.min(WINDOW, total - from);
  waitBlocks = from + count;
  const arrived = new Promise((res) => { blocksDone = res; });
  request(from, count);
  await Promise.race([arrived,
    new Promise((_, r) => setTimeout(() => r(new Error(`window at ${from} timed out`)), 20000))]);
}
const transferMs = performance.now() - t0;
say(blocks.size === total, "every block arrived", `${blocks.size} of ${total}`);

// The world is not empty, and not uniform: a transfer that dropped payloads
// would still produce the right *count* of blocks.
let solidNodes = 0, litNodes = 0;
for (const { content, light } of blocks.values())
  for (let i = 0; i < 4096; i++) {
    if (content[i] !== 0) solidNodes++;
    if (light[i] !== 0) litNodes++;
  }
say(solidNodes > 100000, "with terrain in it", `${solidNodes} non-air nodes`);
say(litNodes > 100000, "and light on it", `${litNodes} lit nodes`);

// --- §7.1 over the socket ----------------------------------------------------
const sx = Math.floor(hello[8]), sy = Math.round(hello[9]), sz = Math.floor(hello[10]);
const bx = Math.floor(sx / BLOCK), by = Math.floor((sy - 1) / BLOCK), bz = Math.floor(sz / BLOCK);
const under = blocks.get(`${bx},${by},${bz}`);
const at = (nx, ny, nz) =>
  (nx - bx * BLOCK) + 16 * (ny - by * BLOCK) + 256 * (nz - bz * BLOCK);
const digY = sy - 1;
const nodeBefore = under.content[at(sx, digY, sz)];
say(nodeBefore !== 0 && R.solid$q(clientReg, nodeBefore),
    "the node under the spawn is solid ground",
    clientReg && R.name_of(clientReg, nodeBefore));

const dig = new Uint8Array(P.size_dig());
P.encode_dig(dig, rc, sx, digY, sz);
send(dig);
await wait(700);
say(deltas.length === 1, "a dig comes back as one node delta", `${deltas.length}`);
say(deltas[0] && deltas[0][0] === sx && deltas[0][1] === digY && deltas[0][2] === sz,
    "at the position asked for");
say(deltas[0] && deltas[0][3] === 0, "and the node is now air");
say(invs.length === 2, "and the inventory is authoritative, not predicted");
const held = invs[invs.length - 1];
say(held && held[1] === 1, "with the drop in it", held && `x${held[1]}`);
// §2's one drop-table exception, over the wire: grass yields dirt. The id in
// the hotbar is an *item* id now, so it is named through the item registry.
if (clientReg && R.name_of(clientReg, nodeBefore) === "miclone:grass")
  say(clientItems && IT.item_name(clientItems, held[0]) === "miclone:dirt",
      "and grass dropped dirt, as the drop table says",
      clientItems && IT.item_name(clientItems, held[0]));

const place = new Uint8Array(P.size_place());
P.encode_place(place, rc, sx, digY, sz, held[0]);
send(place);
await wait(700);
say(deltas.length === 2, "a place comes back as a second delta");
// The delta carries a *node* id and the hotbar holds an *item* id — §2 split
// them, and the server is what resolves one to the other. Comparing them
// directly is what this check used to do, and it passed only while the two
// spaces happened to be the same one.
say(deltas[1] && deltas[1][3] === IT.item_node(clientItems, held[0]),
    "restoring the node the held item places",
    clientItems && IT.item_name(clientItems, held[0]));
say(invs.length === 3 && invs[2][1] === 0, "and the stack is spent");

// The authority. A client that lies about its inventory is the one thing a
// server must not believe.
const cheat = new Uint8Array(P.size_place());
P.encode_place(cheat, rc, sx, digY + 2, sz, 9);
send(cheat);
await wait(700);
say(deltas.length === 2, "and the server refuses a node the client does not hold",
    `${deltas.length} deltas in all`);

// --- §9's crafting, over the wire -------------------------------------------
//
// The client asks to craft and says nothing about what. That is §7.1's shape in
// its smallest form — a one-byte message — and the check is that the server
// answered with an inventory the client never computed.
const beforeCraft = invs.length;
const craftMsg = new Uint8Array(P.size_craft());
P.encode_craft(craftMsg, rc);
send(craftMsg);
await wait(700);
say(invs.length === beforeCraft,
    "crafting nothing craftable changes nothing",
    `${invs.length - beforeCraft} inventory message(s)`);

console.log("");
console.log(`  ${(bytes / (1 << 20)).toFixed(2)} MB received, ` +
  `${total} blocks in ${transferMs.toFixed(0)} ms ` +
  `(${(bytes / 1024 / (transferMs / 1000) / 1024).toFixed(1)} MB/s)`);
console.log("");
console.log(bad === 0
  ? "PASS — the split is real: one process generated this world and another is playing it"
  : `FAIL — ${bad} check(s) failed`);
ws.close();
process.exit(bad === 0 ? 0 : 1);
