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
