// The client's wiring, without a browser.
//
//   gene build --target web client/main.gene --out-dir dist    (and friends)
//   node tools/client_smoke.mjs
//
// Every other harness here tests a module. This tests the part no module test
// can see: that `client/main.gene` connects them — that a keydown reaches the
// physics step, that a click reaches the raycast and the edit, that a dug node
// arrives in the hotbar and a placed one leaves it.
//
// It exists because that part kept being the untested part. A browser is the
// obvious place to check it and is the least reliable one available here: a
// backgrounded tab throttles `requestAnimationFrame` to nothing, `screencapture`
// of a visible window returns black without a screen-recording permission, and
// the automation extension can simply be disconnected — which is what happened
// during M5. So the DOM the client actually uses is stubbed instead. It is
// about eighty lines, because the client uses about twenty host calls.
//
// **This is not a rendering test.** Every WebGL call is a no-op that records
// nothing, so it says the client asked for the right things in the right order
// only insofar as asking wrongly would throw. What it does check is every line
// of `main` that is not a draw call.

// --- the stub ---------------------------------------------------------------

const listeners = new Map();       // "id:type" -> [fn]
const texts = new Map();           // element id -> textContent

function element(id) {
  return {
    __id: id,
    get textContent() { return texts.get(id) ?? ""; },
    set textContent(v) { texts.set(id, v); },
    width: 1280, height: 720,
    addEventListener(type, fn) {
      const key = `${id}:${type}`;
      if (!listeners.has(key)) listeners.set(key, []);
      listeners.get(key).push(fn);
    },
    // The client draws its atlas into an offscreen 2D canvas.
    getContext(kind) { return kind === "2d" ? ctx2d : gl; },
  };
}

const ctx2d = new Proxy({}, { get: () => () => {} });

// Every WebGL entry point the client can reach, as a no-op. The three
// predicates must answer true or `build_program` logs an error and carries on
// with a program that is not there.
const gl = new Proxy({}, {
  get(_, name) {
    if (name === "getShaderParameter" || name === "getProgramParameter")
      return () => true;
    if (name === "getShaderInfoLog" || name === "getProgramInfoLog")
      return () => "";
    if (name === "getUniformLocation") return () => ({});
    if (name.startsWith("create")) return () => ({});
    if (name === "getError") return () => 0;
    if (name === "drawingBufferWidth" || name === "drawingBufferHeight")
      return 1280;
    return () => {};
  },
});

const stage = element("stage");
const hud = element("hud");
const hotbar = element("hotbar");
const byId = { stage, hud, hotbar, aim: element("aim"), help: element("help") };

let now = 0;
let pendingFrame = null;

globalThis.document = {
  getElementById: (id) => byId[id] ?? element(id),
  createElement: () => element("offscreen"),
};
globalThis.window = {
  innerWidth: 1280, innerHeight: 720,
  addEventListener: (type, fn) => element("window").addEventListener(type, fn),
  requestAnimationFrame: (cb) => { pendingFrame = cb; return 1; },
};
// The generated module reaches these unqualified.
globalThis.requestAnimationFrame = window.requestAnimationFrame;
// The frame clock is `now`, handed to the rAF callback so `dt` and the fps
// window are under this file's control. `performance.now()` stays real, so the
// build timings the client logs are the client's and not the stub's.

// `window` is a fresh object per `element()` call above, so route its listeners
// through one shared identity.
const win = element("window");
globalThis.window.addEventListener = win.addEventListener;

function fire(target, type, ev = {}) {
  for (const fn of listeners.get(`${target}:${type}`) ?? [])
    fn({ preventDefault() {}, stopPropagation() {}, ...ev });
}
function tick(frames = 1, ms = 16.7) {
  for (let i = 0; i < frames; i++) {
    now += ms;
    const cb = pendingFrame;
    pendingFrame = null;
    if (cb) cb(now);
  }
}
const key = (k, up = false) => fire("window", up ? "keyup" : "keydown", { key: k });
const click = (button = 0) => {
  fire("stage", "mousedown", { clientX: 400, clientY: 300, button });
  fire("window", "mouseup", { clientX: 400, clientY: 300, button });
};

// --- run it ------------------------------------------------------------------

const { main } = await import("../dist/main.mjs");
const t0 = Date.now();
main();
tick(4);
const buildMs = Date.now() - t0;

let bad = 0;
const say = (ok, label, detail) => {
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label}${detail ? "   " + detail : ""}`);
  if (!ok) bad++;
};

// The frame loop ran, which means the world built and every draw call survived
// the stub.
tick(70);                                    // past the HUD's one-second window
say(hud.textContent.includes("fps"), "the frame loop runs and fills the HUD",
    hud.textContent.slice(0, 64));

// Walking. The HUD reports a rounded position, so a second of holding "w" has
// to move it.
const posOf = (s) => (s.match(/at (-?\d+), (-?\d+), (-?\d+)/) ?? []).slice(1).join(",");
const before = posOf(hud.textContent);
key("w"); tick(120); key("w", true); tick(70);
say(posOf(hud.textContent) !== before && before !== "",
    "holding W moves the player", `${before} -> ${posOf(hud.textContent)}`);

// Flying is a toggle, and the HUD names the mode.
key("f"); key("f", true); tick(70);
say(hud.textContent.includes("flying"), "F toggles fly mode");
key("f"); key("f", true); tick(70);
say(!hud.textContent.includes("flying"), "and toggles it back");

// The hotbar starts empty and a dig fills it. Look down first, so the ray has
// the ground in front of it rather than the horizon: a mousemove with the
// button held is how the client turns the view.
say(hotbar.textContent.includes("—"), "the hotbar starts empty",
    hotbar.textContent.slice(0, 48));
fire("stage", "mousedown", { clientX: 400, clientY: 300, button: 0 });
fire("window", "mousemove", { movementX: 0, movementY: 400 });
fire("window", "mouseup", { clientX: 400, clientY: 700, button: 0 });
tick(4);
click(0);
tick(4);
const afterDig = hotbar.textContent;
say(/x\d+/.test(afterDig), "a click digs and the drop arrives in the hotbar",
    afterDig.slice(0, 56));

// Placing spends it again.
const held = Number((afterDig.match(/x(\d+)/) ?? [0, 0])[1]);
click(2);
tick(4);
const afterPlace = Number((hotbar.textContent.match(/x(\d+)/) ?? [0, 0])[1]);
say(afterPlace === held - 1 || (held === 1 && hotbar.textContent.includes("—")),
    "a right-click places it and spends the stack",
    `${held} -> ${afterPlace || 0}`);

// Slot selection, by key and by wheel. The selected slot is the bracketed one.
const selectedIndex = () =>
  hotbar.textContent.split(" ").findIndex((p) => p.startsWith("["));
key("3"); key("3", true); tick(4);
const bySelect = selectedIndex();
fire("stage", "wheel", { deltaY: 120 });
tick(4);
say(selectedIndex() !== bySelect && bySelect >= 0,
    "1-8 and the wheel move the selection",
    `slot ${bySelect} -> ${selectedIndex()}`);

// A drag must not dig: it is how the view turns, and the two share a button.
const beforeDrag = hotbar.textContent;
fire("stage", "mousedown", { clientX: 400, clientY: 300, button: 0 });
fire("window", "mousemove", { movementX: 60, movementY: 0 });
fire("window", "mouseup", { clientX: 480, clientY: 300, button: 0 });
tick(4);
say(hotbar.textContent === beforeDrag, "a drag turns the view without digging");

console.log("");
console.log(`  world built and 280 frames ran in ${buildMs} ms of wall clock`);
console.log("");
console.log(bad === 0
  ? "PASS — the client's wiring works with a stubbed DOM"
  : `FAIL — ${bad} check(s) failed`);
if (bad !== 0) process.exit(1);
