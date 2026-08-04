// design.md §13's input, and the container that justifies it.
//
//   gene run server &
//   node tools/chest_probe.mjs
//
// §13.3 said a form here was read-only: "no button that sends a message, no
// field to type into … Input needs a message per element kind and a server that
// can attribute one to a form it opened, and it wants the container that would
// justify it." This is the check that all four of those exist.
//
// It speaks the protocol itself, as a peer, like `net_probe.mjs` — what is
// under test is the *server's* authority over a button press, and a client
// would only get in the way of asking whether a lie is refused.

const D = new URL("../dist/", import.meta.url).pathname;
const { new_cursor } = await import(D + "wire.mjs");
const P = await import(D + "protocol.mjs");
const R = await import(D + "registry.mjs");
const IT = await import(D + "item.mjs");
const F = await import(D + "formspec.mjs");

const PORT = 8790, BLOCK = 16;
const K = {
  hello: P.kind_hello(), registry: P.kind_registry(), block: P.kind_block(),
  delta: P.kind_node_delta(), inventory: P.kind_inventory(),
  items: P.kind_items(), forms: P.kind_forms(), open: P.kind_open_form(),
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
let reg = null, items = null, forms = null;
const blocks = new Map();
const invs = [], opens = [];
let waitBlocks = 0, blocksDone = null;

ws.onmessage = (e) => {
  const b = new Uint8Array(e.data);
  const kind = P.message_kind(b);
  if (kind === K.hello) P.decode_hello(b, c, hello);
  else if (kind === K.registry) { reg = R.new_wire_registry(); P.decode_registry(b, c, reg); }
  else if (kind === K.items) { items = IT.new_items(); P.decode_items(b, c, items); }
  else if (kind === K.forms) { forms = F.new_forms(); P.decode_forms(b, c, forms); }
  else if (kind === K.block) {
    P.decode_block(b, c, header, outC, outL);
    blocks.set(`${header[0]},${header[1]},${header[2]}`, { content: outC.slice() });
    if (blocks.size >= waitBlocks && blocksDone) blocksDone();
  } else if (kind === K.delta) { P.decode_node_delta(b, c, delta); }
  else if (kind === K.inventory) {
    const inv = new Float64Array(24);
    P.decode_inventory(b, c, inv);
    invs.push([...inv]);
  } else if (kind === K.open) {
    const slot = P.new_open_form();
    const box = new Float64Array(24);
    const name = P.decode_open_form(b, c, slot, box);
    opens.push({ name, at: [slot[0], slot[1], slot[2]], box: [...box] });
  }
};

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
await new Promise((res, rej) => {
  ws.onopen = res;
  ws.onerror = () => rej(new Error(`no server on ${PORT} — run \`gene run server\``));
  setTimeout(() => rej(new Error("connect timed out")), 5000);
});
await wait(500);

console.log("\ndesign.md §13 — a form that sends a message, and a chest to send it about\n");

say(forms !== null, "the forms arrived at join, which they never used to",
    forms && `${F.form_count(forms)} form(s), ${F.element_count(forms)} elements`);
const chestForm = forms ? F.form_named(forms, "miclone:chest") : -1;
say(chestForm >= 0, "including the chest's");

// The layout is what travels at join, and the client rebuilt it through the
// same `add_form`/`add_element` the server registered it with — so a form that
// arrives is one that would have registered.
let buttons = 0;
if (chestForm >= 0) {
  const first = F.form_first(forms, chestForm);
  const last = first + F.form_len(forms, chestForm);
  for (let e = first; e < last; e++)
    if (F.element_kind(forms, e) === F.kind_button()) buttons++;
}
say(buttons > 0, "and it has buttons, which no form had before", `${buttons}`);

// The world, so a chest can be placed somewhere real.
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
const dig = (x, y, z) => {
  const m = new Uint8Array(P.size_dig());
  P.encode_dig(m, rc, x, y, z);
  ws.send(m);
};
// A right-click carries both what was aimed at and where a block would go.
const rightClick = (px, py, pz, item, ax, ay, az) => {
  const m = new Uint8Array(P.size_place());
  P.encode_place(m, rc, px, py, pz, item, ax, ay, az);
  ws.send(m);
};
const press = (x, y, z, slot, form, action) => {
  const m = new Uint8Array(P.size_form_action_for(form, action));
  P.encode_form_action(m, rc, x, y, z, slot, form, action);
  ws.send(m);
};

const CHEST = IT.item_named(items, "miclone:chest");
const CHEST_NODE = IT.item_node(items, CHEST);
say(CHEST >= 0 && CHEST_NODE >= 0, "the chest is an item that places a node",
    `item ${CHEST}, node ${CHEST_NODE}`);
say(R.opens_form_of(reg, CHEST_NODE) === "miclone:chest",
    "and the node declares the form it opens",
    R.opens_form_of(reg, CHEST_NODE));

// §7.1's authority, on a button, before anything is open. Every press must be
// refused — this is the check that the server attributes a press to a form *it*
// opened rather than to one the client claims.
const invBefore = invs.length;
press(0, 0, 0, 0, "miclone:chest", "take_0");
await wait(400);
say(invs.length === invBefore,
    "a press on a form nobody opened changes nothing",
    `${invs.length - invBefore} inventory message(s)`);

// --- get a chest by playing --------------------------------------------------
//
// **The chest is crafted, not conjured.** A container nobody can obtain is not
// a feature, so the recipe exists and this probe walks it: chop a tree, planks,
// chest. That also makes every step below a test of something else that already
// shipped — drops, stacking, and §9's crafting.
const TREE = R.id_of(reg, "miclone:tree");
let trunk = null;
outer2:
for (let x = ox + 1; x < ox + hello[5] * BLOCK - 1 && !trunk; x++)
  for (let z = oz + 1; z < oz + hello[7] * BLOCK - 1; z++)
    for (let y = oy + hello[6] * BLOCK - 2; y > oy + 1; y--)
      if (nodeAt(x, y, z) === TREE) { trunk = [x, y, z]; break outer2; }
say(trunk !== null, "found a tree to chop", trunk && trunk.join(", "));

const held = (item) => {
  if (!invs.length) return 0;
  const last = invs[invs.length - 1];
  let n = 0;
  for (let i = 0; i < 8; i++) if (last[i * 3] === item && last[i * 3 + 1] > 0) n += last[i * 3 + 1];
  return n;
};
const TREE_ITEM = IT.item_named(items, "miclone:tree");
const PLANK = IT.item_named(items, "miclone:plank");

// One trunk yields one wood; a chest wants four planks and one wood makes four.
for (let i = 0; i < 3 && held(TREE_ITEM) < 1; i++) {
  dig(trunk[0], trunk[1] + i, trunk[2]);
  await wait(250);
}
say(held(TREE_ITEM) >= 1, "chopping it yields wood", `x${held(TREE_ITEM)}`);

// A craft names its recipe. `craft_any` is the crafting key's "make whatever I
// can", and it is what makes the chest unreachable by itself: sticks match
// before the chest does and eat the planks. Naming the recipe is §9's answer
// and it is the reason `msg_craft` grew a byte.
const craft = (recipe) => {
  const m = new Uint8Array(P.size_craft());
  P.encode_craft(m, rc, recipe);
  ws.send(m);
};
const CR = await import(D + "craft.mjs");
const M = await import(D + "mods.mjs");
const modGame = M.load_mods();
const recipeOf = (name) => {
  const crafts = modGame.crafts, want = IT.item_named(modGame.items, name);
  for (let i = 0; i < CR.recipe_count(crafts); i++)
    if (CR.recipe_output(crafts, i) === want) return i;
  return -1;
};
const PLANK_RECIPE = recipeOf("miclone:plank");
const CHEST_RECIPE = recipeOf("miclone:chest");
say(PLANK_RECIPE >= 0 && CHEST_RECIPE >= 0, "the recipes are findable by name",
    `plank ${PLANK_RECIPE}, chest ${CHEST_RECIPE}`);

craft(PLANK_RECIPE);
await wait(400);
say(held(PLANK) >= 4, "wood crafts into planks", `x${held(PLANK)}`);

// The check that made this byte necessary: "make whatever I can" reaches sticks
// and never the chest, because sticks match first and spend the planks.
craft(CHEST_RECIPE);
await wait(400);
say(held(CHEST) >= 1, "and the planks into a chest, because the craft named it",
    `x${held(CHEST)}`);

// --- place it, open it, use it ------------------------------------------------
let spot = null;
outer3:
for (let x = ox + 3; x < ox + hello[5] * BLOCK - 3 && !spot; x += 2)
  for (let z = oz + 3; z < oz + hello[7] * BLOCK - 3; z++)
    for (let y = oy + hello[6] * BLOCK - 3; y > oy + 2; y--)
      if (nodeAt(x, y, z) !== 0 && nodeAt(x, y + 1, z) === 0 &&
          nodeAt(x, y + 2, z) === 0) { spot = [x, y + 1, z]; break outer3; }
say(spot !== null, "found open ground to build on", spot && spot.join(", "));

// Aimed at the ground, placing into the air above it.
rightClick(spot[0], spot[1], spot[2], CHEST, spot[0], spot[1] - 1, spot[2]);
await wait(500);
say(held(CHEST) === 0, "placing the chest spends it", `x${held(CHEST)}`);

// And now the thing §13.3 said did not exist: a right-click that *opens*
// rather than places. Aimed at the chest itself.
const opensBefore = opens.length;
rightClick(spot[0], spot[1] + 1, spot[2], CHEST, spot[0], spot[1], spot[2]);
await wait(500);
say(opens.length > opensBefore, "right-clicking it opens a form",
    `${opens.length - opensBefore} open message(s)`);
const opened = opens[opens.length - 1];
say(opened && opened.name === "miclone:chest", "and it is the chest's form",
    opened && opened.name);
say(opened && opened.at[0] === spot[0] && opened.at[1] === spot[1] &&
    opened.at[2] === spot[2],
    "about the chest that was clicked, not the form in general",
    opened && opened.at.join(", "));
say(opened && opened.box.slice(0, 24).every((v) => v === 0),
    "and it is empty, as a new chest is");

// Put a stack in. The chest recipe spent every plank, so dig something first —
// which is the ordinary way a player comes to have anything to store.
for (let i = 0; i < 4 && held(PLANK) === 0; i++) {
  dig(spot[0] + 2 + i, spot[1] - 1, spot[2]);
  await wait(250);
}
const stash = (() => {
  const last = invs[invs.length - 1];
  for (let i = 0; i < 8; i++) if (last[i * 3 + 1] > 0) return last[i * 3];
  return -1;
})();
const stashBefore = held(stash);
say(stashBefore > 0, "the player has something to store",
    `item ${stash} x${stashBefore}`);
const opens2 = opens.length;
press(spot[0], spot[1], spot[2], 0, "miclone:chest", "put_0");
await wait(500);
say(held(stash) < stashBefore, "pressing put moves it into the chest",
    `x${stashBefore} -> x${held(stash)}`);
const after = opens[opens.length - 1];
say(opens.length > opens2 && after.box[0] === stash && after.box[1] > 0,
    "and the chest says so, unprompted",
    after && `slot 0 = item ${after.box[0]} x${after.box[1]}`);

// Take it back out. Conservation, which is §7.1's rule and the one property
// worth asserting about a container: what went in comes out.
press(spot[0], spot[1], spot[2], 0, "miclone:chest", "take_0");
await wait(500);
say(held(stash) === stashBefore, "pressing take brings all of it back",
    `x${held(stash)} of x${stashBefore}`);
const emptied = opens[opens.length - 1];
say(emptied && emptied.box[1] === 0, "and the chest slot is empty again",
    emptied && `x${emptied.box[1]}`);

// §7.1 once more, now that a form *is* open: an action the form never declared
// must do nothing, because the server resolves it against the form rather than
// against the string.
const invNow = invs.length;
press(spot[0], spot[1], spot[2], 0, "miclone:chest", "empty_the_world");
await wait(400);
say(invs.length === invNow, "an action the form never declared does nothing",
    `${invs.length - invNow} inventory message(s)`);

// And a press about a different node, while this one is open.
press(spot[0] + 5, spot[1], spot[2], 0, "miclone:chest", "take_0");
await wait(400);
say(invs.length === invNow, "and a press about a chest that is not the open one",
    `${invs.length - invNow} inventory message(s)`);

console.log("");
console.log(bad === 0
  ? "PASS — a chest crafted, placed, opened, filled and emptied, and every lie about it refused"
  : `FAIL — ${bad} check(s) failed`);
ws.close();
process.exit(bad === 0 ? 0 : 1);
