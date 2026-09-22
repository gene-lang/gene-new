// Milestone 1 end to end: one Commons world process, one browser-shaped
// player, real HTTP sign-in, a real WebSocket, and a real crash.
//
//   node tools/commons_smoke.mjs
//
// It creates a throwaway world, provisions a player, starts `gene run world
// run` as its own process, and speaks the protocol exactly as the browser page
// does (cookie session, same-origin `Origin`, `gene.world.v1`). Then it checks
// what docs/proposals/world.md §17 asks Milestone 1 to prove:
//
//   - admission: wrong Origin, no session, no subprotocol and a bad code are
//     refused before anything is upgraded (§9.4);
//   - server-owned click-to-move: the world plans and walks the route; the
//     client only names a cell (§6.5); telemetry labels the unsaved tail (§6.1);
//   - one unique object: picked up once, never twice, with the same rules on
//     a second attempt (§5.2, W1/W2);
//   - durable receipts: a resend returns the retained receipt, a changed
//     payload under a used id is a conflict, a cancellation that arrives first
//     leaves a tombstone (§10.2, §10.5, D4/D5);
//   - control-generation fencing: a second tab is refused until it takes over,
//     and the old controller is fenced (§4.4, P3);
//   - owner current-action and receipt queries (§10.7, §10.8);
//   - a confirmed pickup survives `kill -9`, and an uncheckpointed motion tail
//     is corrected to the last checkpoint on restart, with the walk suspended
//     until the player resumes it (§6.1, §6.3, R2).
//
// The world is kept on failure (its path is printed) and removed on success.
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const PKG = new URL("../", import.meta.url).pathname;
const GENE = process.env.GENE ?? new URL("../../../bin/gene", import.meta.url).pathname;
const PORT = Number(process.env.COMMONS_SMOKE_PORT ?? 8097);
const ORIGIN = `http://127.0.0.1:${PORT}`;
const ROOT = mkdtempSync(path.join(tmpdir(), "commons-smoke-"));

let bad = 0;
const say = (ok, label, detail = "") => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label}${detail ? "   " + detail : ""}`);
  if (!ok) bad++;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Another server on this port would be another world: refuse, don't test it.
try {
  await fetch(`http://127.0.0.1:${PORT}/login`);
  console.log(`FAIL — port ${PORT} is already serving; stop that server first`);
  process.exit(2);
} catch {}
const gene = (...args) => execFileSync(GENE, ["run", "world", ...args, "--root", ROOT],
  { cwd: PKG, encoding: "utf8" });

let server = null;
async function startServer() {
  server = spawn(GENE, ["run", "world", "run", "--root", ROOT, "--port", String(PORT)],
    { cwd: PKG, stdio: ["ignore", "pipe", "pipe"] });
  server.log = [];
  server.stdout.on("data", (d) => server.log.push(String(d)));
  server.stderr.on("data", (d) => server.log.push(String(d)));
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    try { const r = await fetch(`${ORIGIN}/login`); if (r.ok) return; } catch {}
    await sleep(200);
  }
  throw new Error("server did not start:\n" + server.log.join(""));
}
async function stopServer(signal = "SIGTERM") {
  if (!server) return;
  const done = new Promise((r) => server.once("exit", r));
  server.kill(signal);
  await done;
  server = null;
}

// The Origin a browser attaches to a same-origin form POST depends on the
// page's Referrer-Policy: under `no-referrer` it is the string "null" (Fetch,
// "serialize a request origin"). Derive it from what the server actually sent,
// as the browser does, rather than assuming it.
async function browserOrigin() {
  const policy = (await fetch(`${ORIGIN}/login`)).headers.get("referrer-policy") ?? "";
  return policy.split(",").map((p) => p.trim()).includes("no-referrer") ? "null" : ORIGIN;
}

async function signIn(player, code) {
  const r = await fetch(`${ORIGIN}/login`, {
    method: "POST", redirect: "manual",
    headers: { Origin: await browserOrigin(), "content-type": "application/x-www-form-urlencoded" },
    body: `player_id=${encodeURIComponent(player)}&code=${encodeURIComponent(code)}`,
  });
  return { status: r.status, cookie: (r.headers.get("set-cookie") ?? "").split(";")[0] };
}

// A protocol peer shaped like the browser page: it keeps every message and
// lets a test wait for the next one matching a predicate.
function connect(cookie, { origin = ORIGIN, protocol = "gene.world.v1" } = {}) {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/world/v1`,
    { protocols: protocol ? [protocol] : [], headers: { Cookie: cookie, Origin: origin } });
  const peer = { ws, log: [], waiters: [], closed: false, generation: "", welcome: null };
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.kind === "welcome") { peer.welcome = msg; peer.generation = msg.control_generation; }
    peer.log.push(msg);
    for (const w of [...peer.waiters]) if (w.test(msg)) {
      peer.waiters.splice(peer.waiters.indexOf(w), 1); w.resolve(msg);
    }
  };
  ws.onclose = () => { peer.closed = true; };
  peer.opened = new Promise((resolve, reject) => {
    ws.onopen = () => resolve(true);
    ws.onerror = () => resolve(false);
  });
  peer.next = (test, ms = 15000) => new Promise((resolve, reject) => {
    const found = peer.log.find((m) => !m.__taken && test(m));
    if (found) { found.__taken = true; return resolve(found); }
    const waiter = { test, resolve: (m) => { m.__taken = true; resolve(m); } };
    peer.waiters.push(waiter);
    setTimeout(() => reject(new Error("timed out waiting")), ms);
  });
  peer.send = (obj) => ws.send(JSON.stringify(obj));
  peer.hello = (extra = {}) => peer.send({ v: 1, kind: "hello", role: "controller", ...extra });
  let n = 0;
  peer.command = (operation, input, opId = `op-smoke-${Date.now()}-${n++}`, extra = {}) => {
    const w = peer.welcome;
    peer.send({ v: 1, kind: "command", world_id: w.world_id, history_id: w.history_id,
      control_generation: peer.generation, operation_id: opId, operation,
      contract_version: 1, rules_revision: w.rules_revision, input, preconditions: [], ...extra });
    return opId;
  };
  peer.receipt = (opId) => peer.next((m) => (m.kind === "receipt" || m.kind === "error") && m.operation_id === opId);
  peer.query = (query, args = {}) => {
    const id = `q-${Date.now()}-${n++}`;
    peer.send({ v: 1, kind: "query", request_id: id, query, args });
    return peer.next((m) => m.request_id === id);
  };
  return peer;
}

async function ready(peer) {
  await peer.next((m) => m.kind === "ready");
  return peer.log.find((m) => m.kind === "snapshot");
}

const entity = (snap, id) => snap.entities.find((e) => e.id === id);
const at = (e) => e.components["core/transform"];

try {
  console.log(`commons smoke — world at ${ROOT}`);
  gene("create");
  const code = gene("player", "add", "ada", "Ada").match(/login code: (\w+)/)[1];
  await startServer();

  // --- admission (§9.4) ---------------------------------------------------------
  const wrong = await signIn("ada", "not-the-code");
  say(wrong.status === 401 && wrong.cookie === "", "a wrong login code is refused", `HTTP ${wrong.status}`);
  const { status, cookie } = await signIn("ada", code);
  say(status === 303 && cookie.startsWith("commons_session="), "the operator's code signs the player in",
      `HTTP ${status}`);
  const noSession = await (connect("")).opened;
  say(!noSession, "a socket without a session is refused");
  const foreign = await (connect(cookie, { origin: "http://evil.example" })).opened;
  say(!foreign, "a socket from another origin is refused");
  const noProto = await (connect(cookie, { protocol: null })).opened;
  say(!noProto, "a socket that does not offer gene.world.v1 is refused");

  // --- attach and synchronize (§9.4, §11.3) ----------------------------------------
  const a = connect(cookie);
  await a.opened;
  say(a.ws.protocol === "gene.world.v1", "the world selects the subprotocol", a.ws.protocol);
  a.hello();
  const snap = await ready(a);
  const me = a.welcome.entity_id;
  say(a.welcome.participant_kind === "human" && me === "avatar-ada",
      "welcome names the player's own avatar, derived from the session", me);
  say(snap.region && snap.content && entity(snap, "object-watering-can"),
      "the snapshot carries the region, its content, and the watering can");
  const start = at(entity(snap, me));

  // Commands before readiness or from a stale generation never reach the world.
  const staleOp = a.command("movement.walk_to", { cell: { x: 30, z: 11 } }, "op-stale", { control_generation: "0" });
  const stale = await a.receipt(staleOp);
  say(stale.kind === "error" && stale.code === "stale_control_generation",
      "a command from an older control generation is fenced", stale.code);

  // --- server-owned click-to-move (§6.2, §6.5) -----------------------------------------
  const wall = a.command("movement.walk_to", { cell: { x: 4, z: 4 } });
  const wallR = await a.receipt(wall);
  say(wallR.admission === "rejected" && wallR.reason === "not_walkable",
      "a wall is not somewhere to stand: rejected, and retained", wallR.reason);
  const walk = a.command("movement.walk_to", { cell: { x: 30, z: 11 } });
  const walkR = await a.receipt(walk);
  say(walkR.admission === "accepted" && walkR.action_status === "running" && walkR.action_id,
      "the world plans the route and accepts the walk", `${walkR.action_id} ${walkR.result?.total_mm} mm`);
  const busy = await a.receipt(a.command("movement.walk_to", { cell: { x: 20, z: 20 } }));
  say(busy.admission === "rejected" && busy.reason === "busy",
      "a second walk while one is active is rejected, not silently replacing it", busy.reason);
  const tele = await a.next((m) => m.kind === "telemetry" && m.entities.some((s) => s.entity_id === me && s.provisional));
  say(tele.provisional === true && tele.server_epoch === a.welcome.server_epoch,
      "telemetry labels live motion ahead of the checkpoint as provisional");
  const done = await a.next((m) => m.kind === "event" && m.type === "movement.completed", 40000);
  say(done.payload.action_id === walkR.action_id && done.event_seq,
      "arrival is a durable event with a recipient sequence", `event ${done.event_seq}`);

  // --- the unique object (§5.2) ------------------------------------------------------
  const pick = a.command("object.pick_up", { object_id: "object-watering-can" });
  const pickR = await a.receipt(pick);
  say(pickR.admission === "accepted" && pickR.action_status === "completed",
      "picking up the watering can completes atomically", pickR.world_revision);
  const picked = await a.next((m) => m.kind === "event" && m.type === "object.picked_up");
  say(picked.payload.by_entity_id === me, "and the world publishes who holds it");
  const again = await a.receipt(a.command("object.pick_up", { object_id: "object-watering-can" }));
  say(again.admission === "rejected" && again.reason === "already_held",
      "a second pickup is a factual rejection; the object is not duplicated", again.reason);

  // --- durable receipts and operation identity (§10.2, §10.5) ---------------------------
  a.command("object.pick_up", { object_id: "object-watering-can" }, pick);
  const resent = await a.receipt(pick);
  say(resent.retained === true && resent.receipt_seq === pickR.receipt_seq && resent.admission === "accepted",
      "resending an operation returns its retained receipt, not a new effect");
  a.command("object.put_down", { object_id: "object-watering-can" }, pick);
  const conflict = await a.receipt(pick);
  say(conflict.kind === "error" && conflict.code === "operation_id_conflict",
      "the same id with a different payload is a conflict and never executes");
  const status1 = await a.query("operation.status", { operation_id: pick });
  const status2 = await a.query("operation.status", { operation_id: "op-never-sent" });
  say(status1.result.status === "found" && status2.result.status === "not_found",
      "receipt queries answer found / not_found for this participant");
  const cancelFirst = await a.receipt(a.command("core.cancel", { operation_id: "op-late-walk" }));
  say(cancelFirst.result?.outcome === "tombstoned", "a cancellation that arrives first leaves a tombstone");
  a.command("movement.walk_to", { cell: { x: 24, z: 30 } }, "op-late-walk");
  const late = await a.receipt("op-late-walk");
  say(late.admission === "cancelled", "and the original can never start afterwards", late.admission);

  // --- control generations (§4.4) ----------------------------------------------------
  const b = connect(cookie);
  await b.opened;
  b.hello();
  const refused = await b.next((m) => m.kind === "error");
  say(refused.code === "controlled_elsewhere" && refused.can_take_over,
      "a second tab is told the avatar is controlled elsewhere", refused.code);
  b.hello({ takeover: true });
  await ready(b);
  const replaced = await a.next((m) => m.kind === "error" && m.code === "controller_replaced");
  say(Number(b.generation) > Number(a.generation) && replaced,
      "explicit takeover fences the old controller with a newer generation",
      `${a.generation} -> ${b.generation}`);

  // --- recovery on a fresh attach (§10.7) ------------------------------------------------
  const page = await b.query("receipts.page", { after_seq: "0", limit: 100 });
  say(page.result.items.length >= 5 && page.result.complete === true,
      "the owner receipt history is paged with explicit coverage",
      `${page.result.items.length} receipts through ${page.result.through_seq}`);
  const bSnap = b.log.find((m) => m.kind === "snapshot");
  say(bSnap.self.inventory.includes("object-watering-can"),
      "a new tab sees the confirmed pickup from the server, not a browser cache");

  // --- crash: a confirmed pickup survives; the unsaved tail is corrected ---------------------
  const walk2 = b.command("movement.walk_to", { cell: { x: 23, z: 40 } });
  const walk2R = await b.receipt(walk2);
  say(walk2R.admission === "accepted", "a long walk is accepted", walk2R.action_id);
  // Wait until the live position is past a checkpoint, then kill mid-step.
  let lastLive = null;
  let lastSaved = null;
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const t = await b.next((m) => m.kind === "telemetry");
    const s = t.entities.find((e) => e.entity_id === me);
    if (s && s.saved && s.provisional && Number(t.committed_sim_time_ms) > 0 &&
        Math.hypot(s.x_mm - s.saved.x_mm, s.z_mm - s.saved.z_mm) > 300) {
      lastLive = s; lastSaved = s.saved; break;
    }
  }
  say(lastLive !== null, "telemetry shows live motion ahead of the last saved position",
      lastLive ? `live ${lastLive.x_mm},${lastLive.z_mm} saved ${lastSaved.x_mm},${lastSaved.z_mm}` : "");
  await stopServer("SIGKILL");
  await startServer();
  const c = connect(cookie);
  await c.opened;
  c.hello();
  const cSnap = await ready(c);
  const after = at(entity(cSnap, me));
  say(c.welcome.server_epoch !== b.welcome.server_epoch, "the restarted world has a new server epoch");
  say(cSnap.self.inventory.includes("object-watering-can"),
      "the confirmed pickup survived kill -9");
  const moved = Math.hypot(after.x_mm - lastLive.x_mm, after.z_mm - lastLive.z_mm);
  const fromSaved = Math.hypot(after.x_mm - lastSaved.x_mm, after.z_mm - lastSaved.z_mm);
  say(moved > 0 && fromSaved <= Math.hypot(lastLive.x_mm - lastSaved.x_mm, lastLive.z_mm - lastSaved.z_mm),
      "the uncheckpointed tail is gone: the avatar is back at or behind its last live position",
      `restored ${after.x_mm},${after.z_mm}; ${Math.round(moved)} mm behind the last live sample`);
  const suspended = cSnap.actions.find((x) => x.action_id === walk2R.action_id);
  say(suspended && suspended.status === "suspended" && suspended.suspended_reason === "world_restarted",
      "the interrupted walk is suspended until the player decides", suspended?.status);
  const current = await c.query("actions.current");
  say(current.result.actions.some((x) => x.action_id === walk2R.action_id),
      "the owner current-action query lists it");
  const resume = await c.receipt(c.command("movement.resume", { action_id: walk2R.action_id }));
  say(resume.admission === "accepted" && resume.action_status === "running", "Resume continues the same action");
  const finished = await c.next((m) => m.kind === "event" && m.type === "movement.completed", 60000);
  say(finished.payload.action_id === walk2R.action_id, "and it completes under its original action id");

  // --- a clean detach suspends instead of walking on unattended (§6.3) -------------------------
  const walk3 = await c.receipt(c.command("movement.walk_to", { cell: { x: 23, z: 3 } }));
  c.ws.close();
  await sleep(500);
  const d = connect(cookie);
  await d.opened;
  d.hello();
  const dSnap = await ready(d);
  const dAction = dSnap.actions.find((x) => x.action_id === walk3.action_id);
  say(dAction && dAction.status === "suspended" && dAction.suspended_reason === "controller_detached",
      "closing the controlling socket suspends its walk", dAction?.suspended_reason);
  const health = await (await fetch(`${ORIGIN}/health`)).json();
  say(health.status === "running" && health.durability.journal_mode === "wal",
      "health reports the running world and its durability settings",
      `revision ${health.world_revision}, ${health.commits.count} commits, max ${health.commits.max_ms} ms`);
  d.ws.close();
} catch (error) {
  say(false, "the smoke ran to completion", error.message);
  if (server) console.log(server.log.join("").slice(-2000));
} finally {
  await stopServer();
}

console.log("");
if (bad === 0) {
  rmSync(ROOT, { recursive: true, force: true });
  console.log("PASS — one browser player and the world (Milestone 1)");
} else {
  console.log(`FAIL — ${bad} check(s) failed; world kept at ${ROOT}`);
}
process.exit(bad === 0 ? 0 : 1);
