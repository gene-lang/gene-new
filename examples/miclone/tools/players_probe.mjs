// design.md §8 — a player can see another player.
//
//   gene run server &
//   node tools/players_probe.mjs
//
// §8 said "the player is not an entity in M5; making it one is a refactor M8
// should do deliberately", and §8.1 called the consequence "the clearest
// statement of what §8 still owes": two clients on one server could dig the
// same world and not see each other.
//
// So this probe is two peers. Everything else in `tools/` is one client and a
// server; this is the only check in the tree that needs a second player to mean
// anything at all.

const D = new URL("../dist/", import.meta.url).pathname;
const { new_cursor } = await import(D + "wire.mjs");
const P = await import(D + "protocol.mjs");
const R = await import(D + "registry.mjs");
const IT = await import(D + "item.mjs");
const E = await import(D + "entity.mjs");

const PORT = 8790;
const K = { hello: P.kind_hello(), registry: P.kind_registry(),
            items: P.kind_items(), entity: P.kind_entity() };

let bad = 0;
const say = (ok, label, detail) => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label}${detail ? "   " + detail : ""}`);
  if (!ok) bad++;
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// One peer: opens a socket, keeps what it is told about entities, and can say
// where it is standing.
const peer = async (name) => {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/`);
  ws.binaryType = "arraybuffer";
  const c = new_cursor(), rc = new_cursor();
  const hello = P.new_hello(), ent = P.new_entity_msg();
  const seen = new Map();          // id -> {x,y,z,item,count,kind}
  let reg = null, items = null;
  ws.onmessage = (e) => {
    const b = new Uint8Array(e.data);
    const kind = P.message_kind(b);
    if (kind === K.hello) P.decode_hello(b, c, hello);
    else if (kind === K.registry) { reg = R.new_wire_registry(); P.decode_registry(b, c, reg); }
    else if (kind === K.items) { items = IT.new_items(); P.decode_items(b, c, items); }
    else if (kind === K.entity) {
      P.decode_entity(b, c, ent);
      const [id, x, y, z, item, count, ekind] = ent;
      if (count <= 0) seen.delete(id);
      else seen.set(id, { x, y, z, item, count, kind: ekind });
    }
  };
  await new Promise((res, rej) => {
    ws.onopen = res;
    ws.onerror = () => rej(new Error(`no server on ${PORT} — run \`gene run server\``));
    setTimeout(() => rej(new Error("connect timed out")), 5000);
  });
  await wait(500);
  return {
    name, ws, hello, seen,
    reg: () => reg, items: () => items,
    players: () => [...seen.values()].filter((e) => e.kind === E.kind_player()),
    // The position travels in `msg_input` (§8.1's trust decision), which is
    // what the server moves the avatar from.
    moveTo(x, y, z) {
      const m = new Uint8Array(P.size_input());
      P.encode_input(m, rc, 0, 0, false, false, false, 0, x, y, z);
      ws.send(m);
    },
    close() { ws.close(); },
  };
};

console.log("\ndesign.md §8 — a player can see another player\n");

const a = await peer("A");
say(a.reg() !== null && a.items() !== null, "the first client joined");
say(a.players().length === 0,
    "and sees no other player, because there is none",
    `${a.players().length}`);

// The second player. What A must learn about is B *existing*, not B moving —
// a world that only shows you someone once they walk is a world where standing
// still is invisibility.
const b = await peer("B");
await wait(600);
say(a.players().length === 1, "a second client joining is visible to the first",
    `${a.players().length} other player(s)`);
say(b.players().length === 1,
    "and the first is visible to the second, who arrived later",
    `${b.players().length} other player(s)`);

// Neither is sent their own avatar: a cube at your own eye position is a cube
// in front of your camera.
const spawn = [a.hello[8], a.hello[9], a.hello[10]];
say(a.players().length === 1 && b.players().length === 1,
    "and neither is sent their own", "1 each, not 2");

// It is drawn like anything else (§8.3): item -> node -> tile. A player has a
// visual for the same reason a dropped cobble does.
const av = a.players()[0];
const node = IT.item_node(a.items(), av.item);
say(node >= 0 && R.name_of(a.reg(), node) === "miclone:player",
    "the avatar is a node the mod registered, not an engine concept",
    node >= 0 ? R.name_of(a.reg(), node) : "none");

// Movement. B walks; A must see the avatar move without asking.
const before = { ...a.players()[0] };
b.moveTo(spawn[0] + 6, spawn[1], spawn[2] + 4);
await wait(700);
const after = a.players()[0];
say(after && (after.x !== before.x || after.z !== before.z),
    "when the second walks, the first sees the avatar move",
    `${before.x.toFixed(1)},${before.z.toFixed(1)} -> ${after.x.toFixed(1)},${after.z.toFixed(1)}`);
say(after && Math.abs(after.x - (spawn[0] + 6)) < 0.01,
    "to where they actually are", `x ${after.x.toFixed(2)}`);

// And leaving removes it. A disconnected player standing in the world forever
// is §8 failing in the other direction.
b.close();
await wait(800);
say(a.players().length === 0, "and when the second leaves, the avatar goes",
    `${a.players().length} other player(s)`);

console.log("");
console.log(bad === 0
  ? "PASS — two players on one server can see each other, which §8.1 called what §8 still owed"
  : `FAIL — ${bad} check(s) failed`);
a.close();
process.exit(bad === 0 ? 0 : 1);
