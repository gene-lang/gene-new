// The networked client's wiring, against a real server over a real socket.
//
//   gene build --target web client/net_main.gene --out-dir dist   (and friends)
//   node tools/net_client_smoke.mjs
//
// `client_smoke.mjs` drives `client/main.gene`, which generates its world in
// the tab. This drives `client/net_main.gene`, which is *handed* one — so the
// thing under test is the half that file adds: the handshake, the version and
// extent check, the flow-controlled request loop, and §7.1's rule that the
// hotbar fills because the server said so rather than because the client
// predicted it.
//
// **Nothing about the transport is stubbed.** The harness boots `gene run
// server` as its own process, and the client reaches it through the platform's
// own `WebSocket` — real TCP, real frames, real ordering. What is stubbed is
// the DOM, for the reasons `tools/dom_stub.mjs` gives, and that is the same
// stub the local client's smoke test uses.
//
// ## How this differs from `net_probe.mjs`
//
// The probe is a *peer*: it speaks the protocol itself, from `core/`, and
// proves the server answers correctly. This is a *client*: it runs the 535
// lines of `net_main.gene` that the probe replaces, and proves those lines
// wire the protocol to the game. Between them the probe owns "the server is
// right" and this owns "the client uses it right"; neither subsumes the other,
// and `net_main.gene` had no automated test at all until this file.
//
// ## Two traps this file exists downstream of
//
// - **The server's stdout is block-buffered when it is a pipe.** Waiting for
//   "listening on 8790" to appear hangs forever while the server is happily
//   serving. The readiness signal is the port, so that is what is polled.
// - **A world costs 64 s to generate and 28 s to load.** So the world is kept
//   between runs at `MICLONE_SMOKE_WORLD` (default `/tmp/miclone_smoke_world`)
//   and a second run is ~38 s; `MICLONE_SMOKE_FRESH=1` deletes it first.
//   Keeping it is safe because the one edit made here is a dig followed by a
//   place of the same node, and the face count asserts that round trip — but a
//   run that *failed* may have dug and not placed, so a failed run discards the
//   world rather than leave the next one a fixture nobody wrote.

import { spawn } from "node:child_process";
import net from "node:net";
import { rm, stat } from "node:fs/promises";
import { hud, hotbar, fire, tick, key, click, lookDown } from "./dom_stub.mjs";

const D = new URL("../dist/", import.meta.url).pathname;
const MICLONE = new URL("../", import.meta.url).pathname;
const GENE = process.env.GENE ?? new URL("../../../bin/gene", import.meta.url).pathname;
const WORLD = process.env.MICLONE_SMOKE_WORLD ?? "/tmp/miclone_smoke_world";
const PORT = 8790;                 // `net_main.gene` dials this literally

const { new_cursor } = await import(D + "wire.mjs");
const P = await import(D + "protocol.mjs");

// The wire format has one definition and it is `core/protocol.gene`; the web
// profile exports functions rather than `let` bindings, which is why these are
// calls. Restating a message kind here would be a second definition of the
// thing this whole harness is checking.
const KIND = {
  hello: P.kind_hello(), registry: P.kind_registry(), block: P.kind_block(),
  delta: P.kind_node_delta(), inventory: P.kind_inventory(),
  tiles: P.kind_tiles(), items: P.kind_items(),
  dig: P.kind_dig(), place: P.kind_place(), request: P.kind_request_blocks(),
};

// --- a socket that counts ----------------------------------------------------
//
// `$gene_ws_connect` does `new WebSocket(url)`, so swapping the global here
// hands the client a subclass of the real one. The connection, the framing and
// the timing all stay the platform's; the only thing added is a tally, which is
// what lets a failure say *which* message never arrived instead of "the world
// did not turn up".

const inCount = new Map();
const outCount = new Map();
const sockets = [];
let bytesIn = 0;
let helloFrame = null;

const RealWebSocket = globalThis.WebSocket;
class CountingWebSocket extends RealWebSocket {
  constructor(...args) {
    super(...args);
    sockets.push(this);
    this.addEventListener("message", (event) => {
      if (!(event.data instanceof ArrayBuffer)) return;
      const b = new Uint8Array(event.data);
      bytesIn += b.length;
      inCount.set(b[0], (inCount.get(b[0]) ?? 0) + 1);
      if (b[0] === KIND.hello) helloFrame = b.slice();
    });
  }
  send(payload) {
    outCount.set(payload[0], (outCount.get(payload[0]) ?? 0) + 1);
    return super.send(payload);
  }
}
globalThis.WebSocket = CountingWebSocket;

const got = (name) => inCount.get(KIND[name]) ?? 0;
const sent = (name) => outCount.get(KIND[name]) ?? 0;
const traffic = () =>
  ["hello", "tiles", "items", "registry", "block", "delta", "inventory"]
    .map((n) => `${got(n)} ${n}`).join(", ") + " in; " +
  ["request", "dig", "place"]
    .map((n) => `${sent(n)} ${n}`).join(", ") + " out";

// --- the server --------------------------------------------------------------

const portOpen = (port) => new Promise((res) => {
  const s = net.connect({ port, host: "127.0.0.1" });
  s.on("connect", () => { s.destroy(); res(true); });
  s.on("error", () => { s.destroy(); res(false); });
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const exists = (p) => stat(p).then(() => true, () => false);

let child = null;
let startedServer = false;
const serverLog = [];

async function bootServer() {
  if (await portOpen(PORT)) {
    console.log(`  joining the server already listening on ${PORT}`);
    return "reused";
  }
  startedServer = true;
  if (process.env.MICLONE_SMOKE_FRESH) await rm(WORLD, { recursive: true, force: true });
  const fresh = !(await exists(WORLD));
  console.log(`  starting \`gene run server\` on ${WORLD}` +
    (fresh ? " — generating a world, about a minute" : " — loading, about 30 s"));

  child = spawn(GENE, ["run", "server"], {
    cwd: MICLONE,
    env: { ...process.env, GENE_MICLONE_WORLD: WORLD },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let died = null;
  child.stdout.on("data", (d) => serverLog.push(String(d)));
  child.stderr.on("data", (d) => serverLog.push(String(d)));
  child.on("exit", (code, signal) => { died = signal ?? code; });

  // The port, not the log: see the header. Nim block-buffers a piped stdout, so
  // "listening on 8790" can sit unflushed for the whole run.
  const t0 = Date.now();
  while (!(await portOpen(PORT))) {
    if (died !== null)
      throw new Error(`the server exited (${died}) before it listened:\n${serverLog.join("")}`);
    if (Date.now() - t0 > 300000)
      throw new Error(`the server did not listen within 300 s:\n${serverLog.join("")}`);
    await sleep(500);
  }
  console.log(`  server ready in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  return "started";
}

function stopServer() {
  for (const s of sockets) { try { s.close(); } catch {} }
  if (child) { child.kill("SIGKILL"); child = null; }
}

// --- the pump ----------------------------------------------------------------
//
// `tick` is synchronous, and a socket message is delivered by the event loop —
// so a frame loop that never yields would run the client forever against a
// socket that never speaks. Every frame here is followed by a turn of the loop.
// The virtual clock still advances 16.7 ms per frame, which means the fps the
// HUD reports is this pump's rate and not a measurement of anything.

async function pumpUntil(pred, { timeoutMs, label, onProgress }) {
  const t0 = Date.now();
  while (!pred()) {
    if (Date.now() - t0 > timeoutMs)
      throw new Error(`timed out after ${timeoutMs} ms waiting for ${label}\n` +
        `         traffic: ${traffic()}\n` +
        `         HUD: ${hud.textContent}`);
    tick(1);
    await sleep(2);
    onProgress?.();
  }
  return Date.now() - t0;
}

let bad = 0;
const say = (ok, label, detail) => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label}${detail ? "   " + detail : ""}`);
  if (!ok) bad++;
};
const hudNums = () => {
  const m = hud.textContent.match(/(-?\d+) fps · (-?\d+) chunks · (-?\d+) faces/);
  return m ? { fps: +m[1], chunks: +m[2], faces: +m[3] } : { fps: 0, chunks: 0, faces: 0 };
};
const posOf = (s) =>
  (s.match(/at (-?\d+), (-?\d+), (-?\d+)/) ?? []).slice(1).map(Number);
// The *selected* slot, which is the bracketed one. Reading the whole hotbar for
// an "—" would find one in slots 2-8 no matter what slot 1 holds, and reading
// it for an `xN` would keep finding the stack the last check put there.
const heldLabel = () => (hotbar.textContent.match(/\[([^\]]*)\]/) ?? ["", ""])[1];
const heldCount = () => Number((heldLabel().match(/x(\d+)/) ?? [0, 0])[1]);

// --- run it ------------------------------------------------------------------

console.log("\ndesign.md §D8 M6 — the networked client, over a real socket\n");

try {
  const how = await bootServer();

  const { main } = await import(D + "net_main.mjs");
  main();
  tick(4);

  // The handshake, before anything asks for terrain.
  await pumpUntil(() => got("hello") > 0 && got("registry") > 0 && got("tiles") > 0 && got("items") > 0,
    { timeoutMs: 15000, label: "the handshake" });
  say(sockets.length === 1 && sockets[0].readyState === 1,
      "the client opened one real socket and it is open",
      `readyState ${sockets[0]?.readyState}`);
  say(got("hello") === 1 && got("registry") === 1 && got("inventory") === 1,
      "and the server answered with hello, registry and an inventory",
      traffic());
  // §9's promise, from the client's side: this process never imported the mod,
  // and it has an atlas because the mod's tile recipes arrived as data.
  say(got("tiles") === 1,
      "and the mod's tiles, which is the only way this client can paint",
      `${got("tiles")} tiles message(s)`);
  // §2: an item id is no longer a content id, so the hotbar cannot name what it
  // holds without this — which the dig check below is what really proves.
  say(got("items") === 1, "and the mod's items, which is what names a hotbar slot",
      `${got("items")} items message(s)`);

  // What the server said the spawn is — decoded here with the same `core/`
  // modules both peers use, so this is not a second reading of the format. The
  // field offsets are positional because `protocol.gene` names them with `let`
  // and the web profile exports functions only; `net_probe.mjs` reads them the
  // same way. 0 version, 1 seed, 2-4 origin block, 5-7 extent, 8-10 spawn.
  const hello = P.new_hello();
  P.decode_hello(helloFrame, new_cursor(), hello);
  const spawn = [hello[8], hello[9], hello[10]].map(Math.round);
  say(hello[0] === P.version(), "the handshake names the protocol version",
      `v${hello[0]}`);

  // Physics does not run until the world is here, so the position the HUD shows
  // during the transfer is the one the handshake set and nothing else.
  await pumpUntil(() => posOf(hud.textContent).length === 3,
    { timeoutMs: 15000, label: "the first HUD line" });
  const atSpawn = posOf(hud.textContent);
  say(atSpawn.every((v, i) => Math.abs(v - spawn[i]) <= 1),
      "and the client moved the player to the spawn the server chose",
      `server ${spawn.join(", ")} · client ${atSpawn.join(", ")}`);

  // §7.1 step 1, the client's own gate: a click before the world is here must
  // not reach the network. No need to aim — `meshed` is checked before the ray
  // is cast, which is the point.
  click(0);
  tick(2);
  say(sent("dig") === 0, "a click before the world arrives sends nothing",
      `${sent("dig")} dig message(s)`);

  // The world, in windows. The client asks and the server answers; the version
  // that pushed all 576 from `on_open` delivered 422 of them, because the
  // outbound queue holds 256 frames and `ws_send` drops the *oldest* (§10.1).
  const chunks = 12 * 4 * 12;
  let announced = 0;
  // Both halves, which is what the label has always said and what the predicate
  // did not check. `chunks > 0` was a proxy for "the transfer finished and the
  // mesh ran", and it held only while nothing *else* could cause a mesh. §12's
  // ambient ABM can: a node delta for a block still in flight remeshes the
  // chunk around it, the HUD reports a chunk, and this returned with ~500 of
  // 576 blocks in hand. The delta itself is harmless — the server serializes a
  // block on request, so the block that arrives afterwards already contains the
  // change — but it is an observable, and the predicate was reading it.
  const transferMs = await pumpUntil(
    () => got("block") === chunks && hudNums().chunks > 0, {
    timeoutMs: 180000,
    label: `all ${chunks} blocks and the mesh`,
    onProgress: () => {
      if (got("block") >= announced + 128) {
        announced = got("block") - (got("block") % 128);
        console.log(`       ${announced}/${chunks} blocks`);
      }
    },
  });
  say(got("block") === chunks, "every block arrived",
      `${got("block")} of ${chunks}`);
  say(sent("request") === Math.ceil(chunks / 64),
      "asked for in windows rather than pushed",
      `${sent("request")} requests of 64`);

  // A transfer that dropped payloads would still deliver the right *count* of
  // messages, so the mesh is what says the bytes were real.
  const built = hudNums();
  say(built.chunks > 100 && built.faces > 10000,
      "and the client meshed the world it was handed",
      `${built.chunks} chunks · ${built.faces} faces`);

  // §7.1's authority, from the client's side, and it runs *before* the player
  // walks anywhere: the ground beside the server-chosen spawn is the one piece
  // of this world whose shape another harness already states — `net_probe.mjs`
  // digs there and calls it "solid ground". Aiming from somewhere the player
  // wandered to would make a red result mean "the terrain there was sea".
  //
  // The hotbar is empty until an *inventory message* fills it: this client
  // predicts nothing.
  say(heldLabel() === "—", "the hotbar starts empty",
      hotbar.textContent.slice(0, 48));
  const facesBefore = hudNums().faces;
  // Once, and only once. Twice clamps the pitch to straight down, the dig then
  // takes the node under the player's feet, and the place that follows targets
  // the node the player is standing in — which the client correctly refuses,
  // for a reason that has nothing to do with the network.
  lookDown();
  tick(2);
  // Deltas counted from *here*, not from the socket opening. §12's ambient ABM
  // changes nodes nobody touched, at any moment, anywhere in the world — so a
  // running total is a count of "what this client did" only while nothing else
  // in the engine can change anything. That stopped being true when the sampled
  // trigger got a mod action to run.
  const deltasBefore = got("delta");
  click(0);
  await pumpUntil(() => got("delta") > deltasBefore && got("inventory") > 1,
    { timeoutMs: 20000, label: "the server's answer to a dig" });
  say(sent("dig") === 1, "a click digs, and the dig goes to the server");
  say(got("delta") >= deltasBefore + 1, "which answers with a node delta",
      `${got("delta") - deltasBefore} since the click`);
  // The HUD and the hotbar are redrawn once a virtual second, and that clock is
  // this file's — so 70 frames is a *deterministic* refresh. Only the socket is
  // asynchronous, and `pumpUntil` above is what waited on it.
  tick(70);
  say(heldCount() === 1,
      "and the drop reaches the hotbar because the server sent it, not because the client guessed",
      heldLabel());

  // The delta reached the *world*, not just the socket: a node removed changes
  // the faces of the chunk it was in, and the client remeshes around it.
  const facesDug = hudNums().faces;
  say(facesDug !== facesBefore,
      "and the delta lands in the world — the chunk around it is remeshed",
      `${facesBefore} -> ${facesDug} faces`);

  // Placing spends it, and the count that changes is the server's.
  const held = heldCount();
  const deltasBeforePlace = got("delta");
  click(2);
  await pumpUntil(() => got("delta") > deltasBeforePlace && got("inventory") > 2,
    { timeoutMs: 20000, label: "the server's answer to a place" });
  tick(70);
  say(sent("place") === 1 && got("delta") >= deltasBeforePlace + 1,
      "a right-click places it and comes back as a second delta",
      `${got("delta") - deltasBeforePlace} since the click`);
  say(heldCount() === held - 1, "and the stack is spent",
      `${held} -> ${heldCount()} · ${heldLabel()}`);
  say(hudNums().faces === facesBefore,
      "and the node is back, so the world is exactly as it was found",
      `${facesDug} -> ${hudNums().faces} faces`);

  // The client rejects what it can answer alone (§7.1 step 1), so an empty
  // slot never becomes a message the server has to refuse.
  click(2);
  tick(8);
  await sleep(200);
  say(sent("place") === 1, "placing from an empty slot never reaches the wire",
      `${sent("place")} place message(s)`);

  // A drag must not dig: it is how the view turns, and the two share a button.
  fire("stage", "mousedown", { clientX: 400, clientY: 300, button: 0 });
  fire("window", "mousemove", { movementX: 60, movementY: 0 });
  fire("window", "mouseup", { clientX: 480, clientY: 300, button: 0 });
  tick(8);
  await sleep(200);
  say(sent("dig") === 1, "a drag turns the view without digging");

  // Physics, against a world that came off a socket. The HUD reports a rounded
  // position and refreshes once a virtual second, so this holds "w" across
  // several of them and then reads what moved. It runs last because it is the
  // one check that leaves the player somewhere unspecified.
  const before = posOf(hud.textContent).join(",");
  key("w");
  tick(240);
  key("w", true);
  tick(70);
  const after = posOf(hud.textContent).join(",");
  say(after !== before && before !== "",
      "holding W moves the player through the received world",
      `${before} -> ${after}`);

  console.log("");
  console.log(`  ${(bytesIn / (1 << 20)).toFixed(2)} MB over a real socket; ` +
    `${chunks} blocks received and meshed in ` +
    `${(transferMs / 1000).toFixed(1)} s (server ${how})`);
  console.log("");
  console.log(bad === 0
    ? "PASS — net_main.gene plays a world it was handed, over a socket it opened itself"
    : `FAIL — ${bad} check(s) failed`);
} catch (err) {
  console.log("");
  console.log(`FAIL — ${err.message}`);
  if (serverLog.length) console.log("  server said:\n" + serverLog.join(""));
  bad++;
} finally {
  stopServer();
  // A run that finishes has put back the node it took, so the world is worth
  // keeping — it saves the next run a minute. A run that *failed* may have dug
  // and never placed, and a world with a hole in it is how the next run
  // inherits a fixture nobody wrote. So it is thrown away, and only when this
  // harness is the one that made it.
  if (bad !== 0 && startedServer) {
    await rm(WORLD, { recursive: true, force: true });
    console.log(`  discarded ${WORLD}; the next run generates a fresh one`);
  }
}

process.exit(bad === 0 ? 0 : 1);
