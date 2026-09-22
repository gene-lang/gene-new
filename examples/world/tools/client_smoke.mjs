// The local client's wiring, without a browser.
//
//   gene build --target web client/main.gene --out-dir dist    (and friends)
//   node tools/client_smoke.mjs
//
// Every other single-process harness here tests a module. This tests the part
// no module test can see: that `client/main.gene` connects them — that a
// keydown reaches the physics step, that a click reaches the raycast and the
// edit, that a dug node arrives in the hotbar and a placed one leaves it.
//
// It exists because that part kept being the untested part. The DOM it needs is
// `tools/dom_stub.mjs`, which explains why a stub rather than a tab; the
// networked client's equivalent is `tools/net_client_smoke.mjs`, which stubs
// the same DOM and uses a real socket against a real server.

import { hud, hotbar, texts, fire, tick, key, click, lookDown } from "./dom_stub.mjs";

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

// The *selected* slot, which is the bracketed one. Reading the whole hotbar for
// an "—" would find one in slots 2-8 no matter what slot 1 holds.
const heldLabel = () => (hotbar.textContent.match(/\[([^\]]*)\]/) ?? ["", ""])[1];
const heldCount = () => Number((heldLabel().match(/x(\d+)/) ?? [0, 0])[1]);

// The hotbar starts empty and a dig fills it.
say(heldLabel() === "—", "the hotbar starts empty",
    hotbar.textContent.slice(0, 48));
lookDown();
tick(4);
click(0);
tick(4);
say(heldCount() === 1, "a click digs and the drop arrives in the hotbar",
    heldLabel());

// Placing spends it again.
const held = heldCount();
click(2);
tick(4);
say(heldCount() === held - 1, "a right-click places it and spends the stack",
    `${held} -> ${heldCount()} · ${heldLabel()}`);

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

// §13's formspec, rendered from a form the mod declared and this client has
// never seen the shape of. The check is that the text came from the *mod* —
// nothing in `client/main.gene` contains the word "planks".
const panelBefore = texts.get("panel") ?? "";
key("e"); key("e", true); tick(4);
const panelAfter = texts.get("panel") ?? "";
say(panelBefore === "" && panelAfter.includes("Crafting"),
    "E opens the mod's crafting form", panelAfter.split("\n")[0] ?? "");
say(panelAfter.includes("planks"),
    "and its text is the mod's, not the client's");
key("e"); key("e", true); tick(4);
say((texts.get("panel") ?? "") === "", "and E closes it again");

console.log("");
console.log(`  world built and 280 frames ran in ${buildMs} ms of wall clock`);
console.log("");
console.log(bad === 0
  ? "PASS — the client's wiring works with a stubbed DOM"
  : `FAIL — ${bad} check(s) failed`);
if (bad !== 0) process.exit(1);
