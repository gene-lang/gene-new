// Canvas + rAF externs for the Gene `web` profile.
//
// Everything here takes and returns plain JS `number`, never `bigint`: the
// canvas API takes numbers, and a bigint crossing this boundary would throw.
// That is the whole reason the spike keeps hot-path math in Gene's `F64`.

let ctx = null;
let canvasW = 0;
let canvasH = 0;

export function init(width, height) {
  const canvas =
    typeof document === "undefined" ? null : document.getElementById("stage");
  canvasW = width;
  canvasH = height;
  if (canvas) {
    canvas.width = width;
    canvas.height = height;
    ctx = canvas.getContext("2d", { alpha: false });
  }
  return undefined;
}

export function clear() {
  if (ctx) {
    ctx.fillStyle = "#0d1117";
    ctx.fillRect(0, 0, canvasW, canvasH);
  }
  return undefined;
}

export function set_fill(r, g, b) {
  if (ctx) ctx.fillStyle = `rgb(${r | 0},${g | 0},${b | 0})`;
  return undefined;
}

export function fill_rect(x, y, w, h) {
  if (ctx) ctx.fillRect(x, y, w, h);
  return undefined;
}

export function now_ms() {
  return typeof performance === "undefined" ? Date.now() : performance.now();
}

export function random() {
  return Math.random();
}

export function report(fps, sprites, frame_ms) {
  const line = `${sprites} sprites  ${fps.toFixed(1)} fps  ${frame_ms.toFixed(2)} ms/frame`;
  if (typeof document !== "undefined") {
    const el = document.getElementById("readout");
    if (el) el.textContent = line;
  } else {
    console.log(line);
  }
  return undefined;
}

// Drives the Gene frame callback. Kept on the JS side because `requestAnimationFrame`
// is the host's scheduler, not Gene's.
export function start_loop(frame) {
  if (typeof requestAnimationFrame === "undefined") {
    // Headless (node) harness: run a fixed number of frames as fast as possible.
    for (let i = 0; i < 600; i++) frame(16.6667);
    return undefined;
  }
  let last = now_ms();
  const tick = () => {
    const t = now_ms();
    frame(t - last);
    last = t;
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  return undefined;
}
