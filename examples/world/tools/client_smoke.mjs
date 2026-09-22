// The browser client's wiring, against a real world process.
//
//   tools/build_web.sh && node tools/client_smoke.mjs
//
// `tools/commons_smoke.mjs` proves the world is right by speaking the protocol
// itself. This proves `client/main.gene` uses it right: the compiled client
// module runs with the DOM and WebGL stubbed (`tools/dom_stub.mjs`), against
// a real `gene run world run` over a real WebSocket carrying the player's
// session cookie — what the browser adds on its own. It checks that the page
// signs on, synchronizes, draws the region, and turns a click on the ground
// into a server-owned walk whose progress and arrival come back from the world.
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { texts, fire, tick, created } from "./dom_stub.mjs";

const PKG = new URL("../", import.meta.url).pathname;
const GENE = process.env.GENE ?? new URL("../../../bin/gene", import.meta.url).pathname;
const PORT = Number(process.env.CLIENT_SMOKE_PORT ?? 8098);
const ORIGIN = `http://127.0.0.1:${PORT}`;
const ROOT = mkdtempSync(path.join(tmpdir(), "commons-client-"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Another server on this port would be another world: refuse, don't test it.
try {
  await fetch(`http://127.0.0.1:${PORT}/login`);
  console.log(`FAIL — port ${PORT} is already serving; stop that server first`);
  process.exit(2);
} catch {}

let bad = 0;
const say = (ok, label, detail = "") => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label}${detail ? "   " + detail : ""}`);
  if (!ok) bad++;
};
const text = (id) => texts.get(id) ?? "";

// The stub's elements lack the two DOM calls this client adds.
const patch = (el) => {
  el.append ??= (child) => el.appendChild(child);
  el.replaceChildren ??= () => { el.__children.length = 0; };
  return el;
};
const byId = document.getElementById;
document.getElementById = (id) => patch(byId(id));
const make = document.createElement;
document.createElement = (tag) => patch(make(tag));

execFileSync(GENE, ["run", "world", "create", "--root", ROOT], { cwd: PKG });
const code = execFileSync(GENE, ["run", "world", "player", "add", "ada", "Ada", "--root", ROOT],
  { cwd: PKG, encoding: "utf8" }).match(/login code: (\w+)/)[1];
const serverLog = [];
let server = null;
const startServer = () => {
  server = spawn(GENE, ["run", "world", "run", "--root", ROOT, "--port", String(PORT)],
    { cwd: PKG, stdio: ["ignore", "pipe", "pipe"] });
  server.stdout.on("data", (d) => serverLog.push(String(d)));
  server.stderr.on("data", (d) => serverLog.push(String(d)));
};
startServer();

try {
  for (let i = 0; i < 300; i++) {
    try { if ((await fetch(`${ORIGIN}/login`)).ok) break; } catch {}
    await sleep(200);
  }
  const login = await fetch(`${ORIGIN}/login`, {
    method: "POST", redirect: "manual",
    headers: { Origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" },
    body: `player_id=ada&code=${code}`,
  });
  const cookie = (login.headers.get("set-cookie") ?? "").split(";")[0];
  say(login.status === 303 && cookie !== "", "the player signs in over HTTP");
  const page = await (await fetch(`${ORIGIN}/`, { headers: { Cookie: cookie } })).text();
  say(page.includes('id="commons_root"') && page.includes("/__gene/"),
      "the world serves the player page and its content-addressed client");

  // What a browser supplies without being asked: its origin, and the cookie
  // on the WebSocket handshake.
  globalThis.location = { origin: ORIGIN, replace() {} };
  window.location = globalThis.location;
  const Native = globalThis.WebSocket;
  globalThis.WebSocket = class extends Native {
    constructor(url, protocol) {
      super(url, { protocols: [protocol], headers: { Cookie: cookie, Origin: ORIGIN } });
    }
  };

  const { main } = await import("../dist/main.mjs");
  main(document.getElementById("commons_root"));
  const until = async (test, ms = 20000) => {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) { tick(2); if (test()) return true; await sleep(20); }
    return false;
  };
  say(await until(() => text("conn_state") === "Connected"),
      "the client attaches and reaches Connected", text("conn_state"));
  say(text("who").includes("Ada"), "the page names the signed-in player", text("who"));
  say(await until(() => text("hud").includes("revision") && text("hud").includes("epoch")),
      "the HUD shows the committed revision and server epoch");

  // A click with no drag is a pick: below the centre of the view is the
  // ground in front of the avatar.
  fire("stage", "mousedown", { clientX: 640, clientY: 560, button: 0 });
  fire("window", "mouseup", { clientX: 640, clientY: 560, button: 0 });
  say(await until(() => text("action_text").startsWith("Walking")),
      "a click on the ground becomes a walk the world accepted", text("action_text"));
  say(await until(() => text("hud").includes("provisional"), 5000),
      "live positions ahead of the checkpoint are shown as provisional");
  const arrived = await until(() => created.some((el) => (el.textContent ?? "").startsWith("Arrived")), 30000);
  say(arrived, "arrival comes back from the world and reaches the history");

  // A crash mid-walk: the page reconnects by itself, and tells the player the
  // unsaved part of the walk was not kept (§6.1, §12.7).
  fire("stage", "mousedown", { clientX: 700, clientY: 600, button: 0 });
  fire("window", "mouseup", { clientX: 700, clientY: 600, button: 0 });
  say(await until(() => text("action_text").startsWith("Walking")), "a second walk starts",
      text("action_text"));
  await until(() => /unsaved/.test(text("hud")), 8000);
  await until(() => false, 700);
  const exited = new Promise((r) => server.once("exit", r));
  server.kill("SIGKILL");
  await exited;
  say(await until(() => text("conn_state").startsWith("Disconnected"), 5000),
      "the page shows the world is gone", text("conn_state"));
  startServer();
  say(await until(() => text("conn_state") === "Connected", 60000),
      "and reconnects on its own when the world is back");
  say(await until(() => text("action_text").includes("suspended"), 5000),
      "the interrupted walk is shown suspended, with Resume and Cancel", text("action_text"));
  say(/last saved position/.test(text("notice")) || created.some((el) => /world restarted/i.test(el.textContent ?? "")),
      "the page says the unsaved tail was corrected", text("notice"));
} catch (error) {
  say(false, "the client smoke ran to completion", error.message);
  console.log(serverLog.join("").slice(-1500));
} finally {
  if (server) server.kill();
}
console.log("");
if (bad === 0) {
  rmSync(ROOT, { recursive: true, force: true });
  console.log("PASS — the browser client plays the world it is handed");
} else {
  console.log(`FAIL — ${bad} check(s) failed; world kept at ${ROOT}`);
}
process.exit(bad === 0 ? 0 : 1);
