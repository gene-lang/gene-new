// Input and frame-loop checks: boot the real game against a DOM stub, fire
// real events, and assert the player responds.
//
// tools/test.mjs covers the pure logic. This covers the wiring — the layer
// that broke when key handlers were attached to the canvas, which never
// receives keyboard events because a canvas is not focusable by default.
//
//   node tools/test_input.mjs

const L = { win: new Map(), stage: new Map() };
const on = (bag) => (t, f) => { if (!bag.has(t)) bag.set(t, []); bag.get(t).push(f); };
const ctx = {
  fillStyle: "", strokeStyle: "", lineWidth: 1, imageSmoothingEnabled: true,
  fillRect() {}, strokeRect() {}, clearRect() {}, drawImage() {},
  createLinearGradient: () => ({ addColorStop() {} }),
};
let hud = "";
const mk = (id) => ({
  id, width: 1280, height: 720, classList: { toggle() {} },
  set textContent(v) { if (id === "hud") hud = v; }, get textContent() { return ""; },
  appendChild() {}, addEventListener: on(L.stage),
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 1280, height: 720 }),
  getContext: () => ctx,
});
let frames = 0;
let pending = null;
globalThis.document = { getElementById: mk, createElement: mk };
globalThis.window = { innerWidth: 1400, innerHeight: 900, addEventListener: on(L.win) };
globalThis.requestAnimationFrame = (f) => { pending = f; };
globalThis.localStorage = { getItem: () => null, setItem() {} };
globalThis.performance = { now: () => Date.now() };
globalThis.Image = class { addEventListener() {} set src(v) { setTimeout(() => this.onload(), 0); } };

const step = (n) => { for (let i = 0; i < n; i++) { const f = pending; pending = null; if (f) f(++frames * 16); } };
const fire = (bag, type, ev) => (bag.get(type) || []).forEach((f) => f({ type, preventDefault() {}, ...ev }));
const px = () => Number(/x (-?\d+)/.exec(hud)?.[1] ?? NaN);

let failures = 0;
const check = (label, ok, detail = "") => {
  if (!ok) failures++;
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${label}${detail ? `  — ${detail}` : ""}`);
};

const { boot } = await import("../dist/main.mjs");
boot();
await new Promise((r) => setTimeout(r, 200));

console.log("\ninput wiring\n");
// Keyboard must be on the window: an element gets key events only when it is
// focusable and focused, and the canvas is neither.
check("keydown is on the window", L.win.has("keydown"));
check("keyup is on the window", L.win.has("keyup"));
// A release outside the canvas must still end the drag.
check("mouseup is on the window", L.win.has("mouseup"));
check("pointer events are on the canvas",
  ["mousemove", "mousedown", "wheel", "contextmenu"].every((t) => L.stage.has(t)));

console.log("\nmovement\n");
step(5);
const start = px();
check("the hud reports a position", Number.isFinite(start), `x=${start}`);

fire(L.win, "keydown", { code: "KeyD" });
step(40);
const right = px();
check("D walks right", right > start, `${start} -> ${right}`);

fire(L.win, "keyup", { code: "KeyD" });
step(20);
check("keyup stops the walk", px() === right, `x=${px()}`);

fire(L.win, "keydown", { code: "KeyA" });
step(40);
check("A walks left", px() < right, `${right} -> ${px()}`);
fire(L.win, "keyup", { code: "KeyA" });

console.log("\nframe loop\n");
const before = frames;
step(10);
check("the loop keeps scheduling itself", frames === before + 10, `${frames} frames`);

console.log(`\n${failures === 0 ? "all input checks passed" : `${failures} FAILED`}\n`);
process.exit(failures === 0 ? 0 : 1);
