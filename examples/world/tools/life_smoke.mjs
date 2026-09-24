// Milestone 2 end to end: one Commons world process, two fake-brain Life
// processes attached through `genex/websocket`, and one browser-shaped human.
//
//   node tools/life_smoke.mjs
//
// Everything crosses real process boundaries: the world is `gene run world
// run`; each Life is `gene run examples/life/src/main.gene run HOME` with its
// own private store; the human speaks the protocol the browser page does. It
// checks what docs/proposals/world.md §17 asks Milestone 2 to prove:
//
//   - native Life admission: no browser Origin, an operator-issued credential
//     in `hello`, one answer for every failure (§4.4, §9.4, P6);
//   - walk-then-act as a data continuation: a Life's fake brain walks to the
//     garden and its continuation speaks on arrival, with no waiting program,
//     worker or model call (§8.4, F7);
//   - speech is an ordinary world event heard by a commit-time audience, and a
//     Life answers a person through its own outbox (§7.3, H11);
//   - a human and two Lives contend for the one watering can through the same
//     handler: exactly one holds it (W1, H1);
//   - a Life killed mid-walk: the world suspends the walk; the restarted Life
//     is shown the suspension, decides to resume it itself, and the
//     continuation registered before the crash still runs once (R1, F8);
//   - the world killed mid-walk while a Life commits a request and is then
//     killed itself: the request reaches the restarted world once, under the
//     same operation ID (R2, D2);
//   - a missing native library is a clear, slow-retrying preflight failure
//     (F11).
//
// Assertions read the actual stores — the world's file after it stops, each
// Life's records — not only returned status text (§18.1). Temporary worlds
// are removed on success and kept (paths printed) on failure.
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, mkdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const PKG = new URL("../", import.meta.url).pathname;
const REPO = new URL("../../../", import.meta.url).pathname;
const GENE = process.env.GENE ?? new URL("../../../bin/gene", import.meta.url).pathname;
const PORT = Number(process.env.LIFE_SMOKE_PORT ?? 8099);
const ORIGIN = `http://127.0.0.1:${PORT}`;
const ENDPOINT = `ws://127.0.0.1:${PORT}/world/v1`;
const ROOT = mkdtempSync(path.join(tmpdir(), "life-smoke-"));
// A Life's sandboxed execution directories must live inside its package.
const LIVES = path.join(REPO, "examples/life/tmp", path.basename(ROOT));
mkdirSync(LIVES, { recursive: true });

let bad = 0;
const say = (ok, label, detail = "") => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label}${detail ? "   " + detail : ""}`);
  if (!ok) bad++;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(check, label, ms = 30000, every = 200) {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    try { last = await check(); if (last) return last; } catch (e) { last = e; }
    await sleep(every);
  }
  throw new Error(`timed out: ${label}${last instanceof Error ? " — " + last.message : ""}`);
}
try {
  await fetch(`${ORIGIN}/login`);
  console.log(`FAIL — port ${PORT} is already serving; stop that server first`);
  process.exit(2);
} catch {}

// --- the world process ------------------------------------------------------------------

const world = (...args) => execFileSync(GENE, ["run", "world", ...args, "--root", ROOT],
  { cwd: PKG, encoding: "utf8" });
let server = null;
let worldLog = [];
async function startWorld() {
  server = spawn(GENE, ["run", "world", "run", "--root", ROOT, "--port", String(PORT)],
    { cwd: PKG, stdio: ["ignore", "pipe", "pipe"] });
  server.log = worldLog;
  server.stdout.on("data", (d) => server.log.push(String(d)));
  server.stderr.on("data", (d) => server.log.push(String(d)));
  await until(async () => (await fetch(`${ORIGIN}/login`)).ok, "world start", 60000);
}
async function stopWorld(signal = "SIGTERM") {
  if (!server) return;
  const done = new Promise((r) => server.once("exit", r));
  server.kill(signal);
  await done;
  server = null;
}
const health = async () => (await fetch(`${ORIGIN}/health`)).json();

// --- Life processes -----------------------------------------------------------------------

const lifeCli = (...args) => execFileSync(GENE, ["run", "examples/life/src/main.gene", ...args],
  { cwd: REPO, encoding: "utf8", env: process.env });
const lives = {};
function startLife(name, env = {}) {
  const home = path.join(LIVES, name);
  const child = spawn(GENE, ["run", "examples/life/src/main.gene", "run", home],
    { cwd: REPO, stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, ...env } });
  child.log = [];
  child.stdout.on("data", (d) => child.log.push(String(d)));
  child.stderr.on("data", (d) => child.log.push(String(d)));
  lives[name] = child;
  return child;
}
async function killLife(name, signal = "SIGKILL") {
  const child = lives[name];
  if (!child || child.exitCode !== null) return;
  const done = new Promise((r) => child.once("exit", r));
  child.kill(signal);
  await done;
}
function command(name, request) {
  const out = lifeCli("command", path.join(LIVES, name), JSON.stringify(request)).trim().split("\n").pop();
  const reply = JSON.parse(out);
  if (!reply.ok) throw new Error(`${name} ${request.op}: ${reply.error}`);
  return reply.value;
}
const inspect = (name, prefix) => command(name, { op: "inspect", prefix });
const worldStatus = (name) => command(name, { op: "world" });
async function attached(name) {
  return until(() => worldStatus(name).phase === "ready", `${name} attached`, 60000, 400);
}
function decide(name, note, program) {
  command(name, { op: "decision", note, program });
}
const values = (map) => Object.values(map ?? {});
const opsOf = (name, operation) => values(inspect(name, "world_op/")).filter((o) => !operation || o.operation === operation);
const resultOf = (name, id) => inspect(name, `world_result/${id}`)[`world_result/${id}`];
const contOf = (name, id) => inspect(name, `world_cont/${id}`)[`world_cont/${id}`];

// --- a browser-shaped human, and a native-shaped peer --------------------------------------

async function signIn(player, code) {
  const r = await fetch(`${ORIGIN}/login`, {
    method: "POST", redirect: "manual",
    headers: { Origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" },
    body: `player_id=${encodeURIComponent(player)}&code=${encodeURIComponent(code)}`,
  });
  return (r.headers.get("set-cookie") ?? "").split(";")[0];
}
function connect({ cookie = null, origin = ORIGIN } = {}) {
  const headers = {};
  if (cookie) headers.Cookie = cookie;
  if (origin) headers.Origin = origin;
  const ws = new WebSocket(ENDPOINT, { protocols: ["gene.world.v1"], headers });
  const peer = { ws, log: [], waiters: [], closed: false, welcome: null, generation: "" };
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.kind === "welcome") { peer.welcome = msg; peer.generation = msg.control_generation; }
    peer.log.push(msg);
    for (const w of [...peer.waiters]) if (w.test(msg)) {
      peer.waiters.splice(peer.waiters.indexOf(w), 1); w.resolve(msg);
    }
  };
  ws.onclose = () => { peer.closed = true; };
  peer.opened = new Promise((resolve) => { ws.onopen = () => resolve(true); ws.onerror = () => resolve(false); });
  peer.next = (test, ms = 30000) => new Promise((resolve, reject) => {
    const found = peer.log.find((m) => !m.__taken && test(m));
    if (found) { found.__taken = true; return resolve(found); }
    peer.waiters.push({ test, resolve: (m) => { m.__taken = true; resolve(m); } });
    setTimeout(() => reject(new Error("timed out waiting")), ms);
  });
  peer.send = (obj) => ws.send(JSON.stringify({ v: 1, ...obj }));
  let n = 0;
  peer.command = (operation, input) => {
    const id = `op-ada-${Date.now()}-${n++}`;
    const w = peer.welcome;
    peer.send({ kind: "command", world_id: w.world_id, history_id: w.history_id,
      control_generation: peer.generation, operation_id: id, operation, contract_version: 1,
      rules_revision: w.rules_revision, input, preconditions: [] });
    return id;
  };
  peer.receipt = (id) => peer.next((m) => (m.kind === "receipt" || m.kind === "error") && m.operation_id === id);
  return peer;
}
const heard = (peer, from, text) => peer.next((m) => m.kind === "event" && m.type === "conversation.said"
  && m.payload.speaker_name === from && (!text || m.payload.text.includes(text)), 60000);

// Continuation code saved by a decision: ordinary Gene, as data (§8.4).
const pickUpAfterWalk = `(fn [api input] (if (== input/result/status "completed") (api/body/world .pick_up "object-watering-can") input/result/status))`;
const sayAfterWalk = (words) => `(fn [api input] (if (== input/result/status "completed") (api/body/world .say "${words}") input/result/status))`;
const walkThen = (destination, code) => `(do
  (let next (code .save "after-walk" ${JSON.stringify(code)}))
  (store .commit (fn [tx]
    (let walk (body/world .start_walk ${destination} ^tx tx))
    (body/world .on_result walk next {} ^tx tx)
    (state .put "walk" walk/operation_id ^tx tx)
    walk/operation_id)))`;

const lifeIds = {};
try {
  console.log(`life smoke — world at ${ROOT}, Lives at ${LIVES}`);
  world("create");
  const code = world("player", "add", "ada", "Ada").match(/login code: (\w+)/)[1];
  for (const [name, display] of [["aster", "Aster"], ["brin", "Brin"]]) {
    const home = path.join(LIVES, name);
    lifeIds[name] = JSON.parse(lifeCli("create", home, "--network").trim().split("\n").pop()).id;
    const credential = path.join(ROOT, `${name}.credential`);
    world("life", "add", lifeIds[name], display, "--credential-out", credential);
    lifeCli("bind", home, ENDPOINT, credential);
  }
  const credential = (name) => readFileSync(path.join(ROOT, `${name}.credential`), "utf8").trim();
  const stored = lifeCli("inspect", path.join(LIVES, "aster")).trim().split("\n").pop();
  const mode = execFileSync("stat", ["-f", "%Lp", path.join(LIVES, "aster", "world.credential")], { encoding: "utf8" }).trim();
  say(!stored.includes(credential("aster")) && JSON.parse(stored).world_binding.life_id === lifeIds.aster && mode === "600",
      "a Life keeps its credential in an owner-only file, never in a record", `mode ${mode}`);
  await startWorld();

  // --- native admission (§4.4, §9.4) ------------------------------------------------------
  const stranger = connect({ origin: null });
  say(await stranger.opened, "a native client without Origin may upgrade — it is nobody yet");
  stranger.send({ kind: "query", request_id: "q-early", query: "actions.current", args: {} });
  const early = await stranger.next((m) => m.kind === "error");
  say(early.code === "not_attached", "before an authenticated hello it can do nothing", early.code);
  stranger.send({ kind: "hello", life_id: lifeIds.aster, credential: credential("brin") });
  const refused = await stranger.next((m) => m.kind === "error");
  await until(() => stranger.closed, "refused socket closed", 5000);
  say(refused.code === "authentication_failed" && !refused.message.includes(credential("brin")),
      "another Life's credential is refused and the socket closed; nothing echoes the secret", refused.code);
  const native = connect({ origin: null });
  await native.opened;
  native.send({ kind: "hello", life_id: lifeIds.brin, credential: credential("brin"), telemetry: false, view: "structured" });
  await native.next((m) => m.kind === "ready");
  const nsnap = native.log.find((m) => m.kind === "snapshot");
  say(native.welcome.participant_kind === "life" && native.welcome.life_id === lifeIds.brin
      && native.welcome.entity_id === `avatar-${lifeIds.brin}`,
      "the credential, not a claimed name, decides the participant and its avatar", native.welcome.entity_id);
  say(nsnap.region === null && nsnap.content === null && nsnap.places?.garden,
      "a structured view omits render data and names the places");
  native.ws.close();
  await until(() => native.closed, "native close", 5000);

  const cookie = await signIn("ada", code);
  const ada = connect({ cookie });
  await ada.opened;
  ada.send({ kind: "hello", role: "controller" });
  await ada.next((m) => m.kind === "ready");

  // --- one Life: walk-then-act as a data continuation (§8.4) -------------------------------
  startLife("aster");
  await attached("aster");
  const hs = await health();
  say(hs.controllers === 2, "the Life attached as a second controller beside the human", `${hs.controllers} controllers`);
  const arrival = await heard(ada, "Aster", "reached the garden");
  say(arrival.payload.speaker_kind === "life",
      "Aster's fake brain walked to the garden and its continuation spoke on arrival");
  const asterWalk = opsOf("aster", "movement.walk_to")[0];
  const asterCont = contOf("aster", asterWalk.id);
  say(asterCont.status === "completed" && resultOf("aster", asterWalk.id).status === "completed",
      "the walk's canonical result is completed and its continuation ran once", asterCont.status);
  const dispatcher = inspect("aster", "world_dispatcher").world_dispatcher;
  say(values(inspect("aster", "routine/")).length === 0 && dispatcher.id === "world-result-dispatcher",
      "one standing result dispatcher; no routine registration per operation");

  // --- speech between a person and a Life (§7.3) -------------------------------------------
  const hello = ada.command("conversation.say", { text: "Hello Aster, can you hear me?" });
  const helloR = await ada.receipt(hello);
  say(helloR.admission === "accepted" && helloR.result.audience >= 2,
      "the human's speech is accepted with its commit-time audience", `audience ${helloR.result?.audience}`);
  const echo = await ada.next((m) => m.kind === "event" && m.type === "conversation.said" && m.operation_id === hello);
  say(echo.payload.message_id === helloR.result.message_id,
      "the speaker's own echo carries the same message id as its receipt: one message");
  const reply = await heard(ada, "Aster", "I heard you");
  say(reply.payload.reply_to === helloR.result.message_id && reply.operation_id === null,
      "Aster answered through its outbox, replying to that message; another participant's op id never leaks");
  const asterChat = values(inspect("aster", "conversation/"))[0];
  say(asterChat.messages.length >= 2 && asterChat.pending.length === 0,
      "Aster's private transcript holds the exchange, with nothing left unanswered");

  // --- a second Life, and three-way contention for one object (W1, H1) ---------------------
  startLife("brin");
  await attached("brin");
  await heard(ada, "Brin", "reached the garden");
  say(true, "Brin, in its own process and store, attached and walked to the garden too");
  for (const name of ["aster", "brin"]) {
    decide(name, "I will fetch the watering can.", walkThen(`{^object_id "object-watering-can"}`, pickUpAfterWalk));
  }
  const adaWalk = ada.command("movement.walk_to", { object_id: "object-watering-can" });
  const adaWalkR = await ada.receipt(adaWalk);
  let adaPick = null;
  if (adaWalkR.admission === "accepted") {
    await ada.next((m) => m.kind === "event" && m.operation_id === adaWalk && m.type.startsWith("movement."), 60000);
    adaPick = await ada.receipt(ada.command("object.pick_up", { object_id: "object-watering-can" }));
  }
  const fetchWalk = (name) => opsOf(name, "movement.walk_to").find((o) => o.input.object_id === "object-watering-can");
  const attempts = await until(() => {
    const done = ["aster", "brin"].every((name) => {
      const walk = fetchWalk(name);
      const c = walk && contOf(name, walk.id);
      return c && ["completed", "failed", "invalidated"].includes(c.status);
    });
    if (!done) return null;
    const picks = ["aster", "brin"].flatMap((name) =>
      opsOf(name, "object.pick_up").map((o) => ({ name, o, r: resultOf(name, o.id) })));
    return picks.every((p) => p.r?.terminal) ? picks : null;
  }, "both Lives' fetch attempts settled", 90000, 500);
  const winners = attempts.filter((p) => p.r.status === "completed").map((p) => p.name);
  if (adaPick?.admission === "accepted") winners.push("ada");
  const losers = attempts.filter((p) => p.r.status !== "completed");
  say(winners.length === 1, "exactly one of the human and two Lives holds the can", `winner ${winners.join(",")}`);
  say(losers.every((p) => p.r.status === "rejected" && p.r.reason === "held_by_someone_else")
      && (!adaPick || adaPick.admission === "accepted" || adaPick.reason === "held_by_someone_else"),
      "every other attempt got the same handler's factual rejection", losers.map((p) => `${p.name}:${p.r.reason}`).join(" "));

  // --- a Life killed mid-walk (R1) ------------------------------------------------------------
  decide("brin", "I will walk to the pond.", walkThen(`"pond"`, sayAfterWalk("I reached the pond.")));
  const pondWalk = await until(() => {
    const w = opsOf("brin", "movement.walk_to").find((o) => o.input.place_id === "pond");
    return w && resultOf("brin", w.id)?.status === "running" ? w : null;
  }, "Brin walking to the pond", 30000);
  await killLife("brin");
  await until(async () => (await health()).controllers === 2, "the world noticed Brin's socket close", 10000);
  startLife("brin");
  await attached("brin");
  // Nobody tells Brin what to do: the restarted Life is shown the suspended
  // walk and decides itself (its fake brain resumes it), §6.3.
  await heard(ada, "Brin", "reached the pond");
  const noticed = values(inspect("brin", "event/")).filter((e) =>
    e.kind === "world_activity_suspended" && e.data.operation_id === pondWalk.id);
  say(noticed.length === 1 && noticed[0].data.reason === "controller_detached",
      "after the crash the Life was shown its suspended walk once, with why and how far it had got");
  say(opsOf("brin", "movement.walk_to").filter((o) => o.input.place_id === "pond").length === 1
      && opsOf("brin", "movement.resume").length === 1,
      "it resumed that action itself — one resume, no second walk");
  say(contOf("brin", pondWalk.id).status === "completed" && resultOf("brin", pondWalk.id).status === "completed",
      "and the continuation registered before the crash ran once, on arrival");

  // --- the world killed mid-walk; a Life commits while it is down, then dies (R2, D2) ---------
  decide("aster", "I will walk to the hall.", walkThen(`"hall"`, sayAfterWalk("I reached the hall.")));
  const hallWalk = await until(() => {
    const w = opsOf("aster", "movement.walk_to").find((o) => o.input.place_id === "hall");
    return w && resultOf("aster", w.id)?.status === "running" ? w : null;
  }, "Aster walking to the hall", 30000);
  await sleep(1500);
  await stopWorld("SIGKILL");
  await until(() => worldStatus("aster").phase !== "ready", "Aster noticed the world is gone", 15000);
  decide("aster", "I will speak even though nobody can hear yet.",
    `(body/world .say "Said while the world was away.")`);
  const offline = await until(() => opsOf("aster", "conversation.say").find((o) => o.input.text.includes("while the world was away")),
    "the request committed locally", 30000);
  say(offline.status === "pending", "the Life committed the request to its outbox while the world was down", offline.status);
  await killLife("aster");
  await startWorld();
  startLife("aster");
  await attached("aster");
  const restartNotice = await until(() => values(inspect("aster", "event/")).find((e) =>
    e.kind === "world_activity_suspended" && e.data.operation_id === hallWalk.id),
    "Aster learned the walk was suspended by the restart", 30000);
  say(restartNotice.data.reason === "world_restarted",
      "the restarted world suspended the walk at its checkpoint, and the Life was shown that");
  const sent = await until(() => resultOf("aster", offline.id)?.terminal && resultOf("aster", offline.id),
    "the offline request reached the world", 30000);
  say(sent.status === "completed" && opsOf("aster", "conversation.say").filter((o) => o.input.text.includes("while the world was away")).length === 1,
      "the request committed before the crash reached the world under its original ID, once", offline.id);
  await until(() => contOf("aster", hallWalk.id)?.status === "completed", "Aster's hall continuation", 60000);
  say(resultOf("aster", hallWalk.id).status === "completed"
      && opsOf("aster", "movement.walk_to").filter((o) => o.input.place_id === "hall").length === 1,
      "Aster resumed it on its own; the walk completed once and its continuation ran");

  // --- preflight: no native library (F11) -----------------------------------------------------
  command("brin", { op: "stop" });
  await until(() => lives.brin.exitCode !== null, "Brin stopped", 15000);
  startLife("brin", { GENE_WEBSOCKET_LIBRARY: "/nonexistent/libgene_websocket.dylib" });
  const preflight = await until(() => {
    const s = worldStatus("brin");
    return s.last_error && s.last_error.includes("not built") ? s : null;
  }, "Brin's preflight failure", 30000);
  await sleep(3000);
  say(worldStatus("brin").connects <= 2 && worldStatus("brin").phase === "disconnected",
      "a missing native library is a clear failure with a slow retry, not a busy loop or another transport",
      preflight.last_error.slice(0, 60));
  command("brin", { op: "stop" });

  // --- the real files ----------------------------------------------------------------------------
  const final = await health();
  say(final.status === "running" && final.durability.backend === "sqlite/open_file",
      "the restarted world stayed healthy on its incremental store",
      `${final.commits.count} commits since restart, max ${final.commits.max_ms} ms`);
  command("aster", { op: "stop" });
  await until(() => lives.aster.exitCode !== null && lives.brin.exitCode !== null, "Lives stopped", 15000);
  ada.ws.close();
  await stopWorld();
  const can = JSON.parse(world("inspect", "entity", "object-watering-can"));
  const holder = can.components["core/contained_in"]?.entity_id;
  const expected = winners[0] === "ada" ? "avatar-ada" : `avatar-${lifeIds[winners[0]]}`;
  say(holder === expected, "the world's file agrees: the can is held by the one winner", holder);
  const record = JSON.parse(world("inspect", "operation", `participant-${lifeIds.aster}`, offline.id));
  say(record?.receipt?.operation_id === offline.id && record.receipt.admission === "accepted",
      "the world's file holds the offline request's receipt under the Life's own operation ID");
  const brinEvents = JSON.parse(world("inspect", "events", `participant-${lifeIds.brin}`));
  say(brinEvents.some((e) => e.type === "movement.suspended" && e.payload.reason === "controller_detached")
      && brinEvents.some((e) => e.type === "movement.completed"),
      "Brin's recipient stream in the file shows the detach suspension and the later completion");
  const cursor = JSON.parse(lifeCli("inspect", path.join(LIVES, "aster"), "world_cursor").trim().split("\n").pop()).world_cursor;
  say(cursor.routed === cursor.received && cursor.gaps.length === 0,
      "Aster's receipt and dispatcher cursors meet with no gaps", `${cursor.received} events`);
} catch (e) {
  bad++;
  console.log(`  FAIL ${e.message}`);
} finally {
  for (const name of Object.keys(lives)) await killLife(name);
  await stopWorld("SIGKILL");
  if (bad === 0) {
    rmSync(ROOT, { recursive: true, force: true });
    rmSync(LIVES, { recursive: true, force: true });
    console.log("\nPASS — one human and two Lives in one world (Milestone 2)");
  } else {
    for (const [name, child] of Object.entries(lives)) console.log(`--- ${name} log\n${child.log.join("").slice(-2000)}`);
    console.log(`--- world log\n${worldLog.join("").slice(-2000)}`);
    console.log(`\nFAIL — ${bad} check(s) failed; world kept at ${ROOT}, Lives at ${LIVES}`);
    process.exitCode = 1;
  }
}
