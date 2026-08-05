// The DOM the miclone clients use, as about eighty lines of stub.
//
// Shared by `client_smoke.mjs` (the local client) and `net_client_smoke.mjs`
// (the networked one), because both drive a real `main()` and neither has a
// browser. Importing this module installs `document`, `window` and
// `requestAnimationFrame` on `globalThis`; import it *before* the dynamic
// `import()` of the client under test — which is what module evaluation order
// already guarantees, since a static import is evaluated first.
//
// A browser is the obvious place to check that a keypress reaches the physics
// and a click reaches the edit, and it is the least reliable one available
// here: a backgrounded tab throttles `requestAnimationFrame` to nothing,
// `screencapture` of a visible window returns black without a screen-recording
// permission, and the automation extension can simply be disconnected — which
// is what happened during M5.
//
// **This is not a rendering test.** Every WebGL call is a no-op that records
// nothing, so it says the client asked for the right things in the right order
// only insofar as asking wrongly would throw. What it does check is every line
// of `main` that is not a draw call.

const listeners = new Map();       // "id:type" -> [fn]
// Exported so a harness can read an element the client writes but does not own
// a handle to — the formspec panel is written by id and never read back.
export const texts = new Map();    // element id -> textContent

// §13's panel is built rather than written: the client creates one div per form
// element and moves it by toggling `cN`/`rN` classes, because the profile has no
// way to remove a node or set a style. So a stub element carries a class set, a
// child list, and a rectangle derived from those classes.
//
// **The geometry below repeats `net.html`'s CSS**, and that is the honest cost
// of hit-testing without a browser: the numbers are the cell size and origin the
// stylesheet uses, and a change to one wants a change to the other. What this
// still checks is the part the client owns — which element a click lands on, and
// what it then sends.
const CELL_W = 56, CELL_H = 26, GRID_X = 14, GRID_Y = 44;
export const created = [];         // every element the client built, in order

function element(id) {
  const classes = new Set();
  const children = [];
  return {
    __id: id,
    __classes: classes,
    __children: children,
    get textContent() { return texts.get(id) ?? ""; },
    set textContent(v) { texts.set(id, v); },
    width: 1280, height: 720,
    classList: {
      toggle(name, on) { if (on) classes.add(name); else classes.delete(name); },
      contains: (name) => classes.has(name),
    },
    appendChild(child) { children.push(child); return child; },
    // Absolute, from the cell classes — the same reading the browser makes of
    // `#form .c6.r3`. An element with no cell has no box, which is what an
    // unplaced element should report.
    getBoundingClientRect() {
      let col = -1, row = -1;
      for (const c of classes) {
        if (/^c\d+$/.test(c)) col = +c.slice(1);
        if (/^r\d+$/.test(c)) row = +c.slice(1);
      }
      if (col < 0 || row < 0 || classes.has("off"))
        return { left: 0, top: 0, width: 0, height: 0 };
      return {
        left: GRID_X + col * CELL_W, top: GRID_Y + row * CELL_H,
        width: CELL_W - 8, height: 22,
      };
    },
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
// `drawElements` is the one call that is not a no-op, because it is the only
// place a harness can see that geometry exists rather than that a number was
// computed. Each frame's index counts are recorded and `glDraws()` hands back
// the last frame's — which is what lets a test assert "the entity pass drew
// something" without the client exposing its buffers.
let glFrame = [];
let glLastFrame = [];
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
    // `clear` opens a frame (`begin_frame` calls it once, first).
    if (name === "clear") return () => { glLastFrame = glFrame; glFrame = []; };
    if (name === "drawElements")
      return (_mode, count) => { glFrame.push(count); };
    return () => {};
  },
});

// The index counts of every `drawElements` in the last completed frame.
export const glDraws = () => glLastFrame.slice();

// Web Audio, at the same fidelity as the WebGL stub above: every call is a
// no-op that records nothing, so this says the client asked for a sound and
// not that a sound was heard. `currentTime` and `sampleRate` are real numbers
// because `audio/tone` and `audio/noise` do arithmetic on them — a stub
// returning undefined would make the ramp `NaN` and throw where a browser
// would play.
const audioNode = () => new Proxy({
  frequency: { value: 0 },
  gain: {
    setValueAtTime() {}, exponentialRampToValueAtTime() {},
  },
  buffer: null,
}, {
  get(target, name) {
    if (name in target) return target[name];
    return () => {};
  },
  set() { return true; },
});

// Extends the real `EventTarget`, because a `BaseAudioContext` is one and the
// profile checks that at the boundary — a plain object is rejected by the
// generated guard before any audio call happens.
globalThis.AudioContext = class extends EventTarget {
  get currentTime() { return 0; }
  get sampleRate() { return 48000; }
  get destination() { return audioNode(); }
  createOscillator() { return audioNode(); }
  createGain() { return audioNode(); }
  createBufferSource() { return audioNode(); }
  createBuffer(_channels, length) {
    return { getChannelData: () => new Float32Array(length) };
  }
};

export const stage = element("stage");
export const hud = element("hud");
export const hotbar = element("hotbar");
// §13's panel and its title. Both are looked up by id and kept, because the
// client attaches a listener to the panel and toggles classes on it — a fresh
// object per lookup would drop both.
export const form = element("form");
export const formTitle = element("form-title");
const byId = {
  stage, hud, hotbar, form, "form-title": formTitle,
  aim: element("aim"), help: element("help"),
};

let now = 0;
let pendingFrame = null;

globalThis.document = {
  getElementById: (id) => byId[id] ?? element(id),
  // A distinct id per element, because `textContent` is keyed by it: one shared
  // "offscreen" id would make every pooled panel element read back the last
  // one's text, and the panel is forty-eight of them.
  createElement: () => {
    const el = element(`made:${created.length}`);
    created.push(el);
    return el;
  },
};
globalThis.window = {
  innerWidth: 1280, innerHeight: 720,
  addEventListener: (type, fn) => element("window").addEventListener(type, fn),
  requestAnimationFrame: (cb) => { pendingFrame = cb; return 1; },
};
// The generated module reaches these unqualified.
globalThis.requestAnimationFrame = window.requestAnimationFrame;
// The frame clock is `now`, handed to the rAF callback so `dt` and the fps
// window are under the harness's control. `performance.now()` stays real, so
// the build timings a client logs are the client's and not the stub's.

// `window` is a fresh object per `element()` call above, so route its listeners
// through one shared identity.
const win = element("window");
globalThis.window.addEventListener = win.addEventListener;

export function fire(target, type, ev = {}) {
  for (const fn of listeners.get(`${target}:${type}`) ?? [])
    fn({ preventDefault() {}, stopPropagation() {}, ...ev });
}
export function tick(frames = 1, ms = 16.7) {
  for (let i = 0; i < frames; i++) {
    now += ms;
    const cb = pendingFrame;
    pendingFrame = null;
    if (cb) cb(now);
  }
}
export const key = (k, up = false) =>
  fire("window", up ? "keyup" : "keydown", { key: k });
export const click = (button = 0) => {
  fire("stage", "mousedown", { clientX: 400, clientY: 300, button });
  fire("window", "mouseup", { clientX: 400, clientY: 300, button });
};
// Look down, so a ray has the ground in front of it rather than the horizon: a
// mousemove with the button held is how both clients turn the view. The large
// travel makes this a drag, so it must not also dig.
export const lookDown = (pixels = 400) => {
  fire("stage", "mousedown", { clientX: 400, clientY: 300, button: 0 });
  fire("window", "mousemove", { movementX: 0, movementY: pixels });
  fire("window", "mouseup", { clientX: 400, clientY: 300 + pixels, button: 0 });
};
