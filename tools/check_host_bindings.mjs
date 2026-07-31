// Verifies the web profile's host surface against the pinned lib.dom.d.ts.
//
// The relationship here is deliberately inverted from a code generator: the
// compiler (src/gene/web.nim) is the single source of truth for what Gene can
// call, and TypeScript is the *oracle* that says whether those calls are real.
// A generator would be a second author, and two authors of one contract is how
// web/gene_dom_bindings.json came to advertise nine DOM methods of which three
// were never callable from Gene at all.
//
// What this checks, for every host operation the profile emits:
//   - the interface exists in lib.dom.d.ts
//   - the member exists on it
//   - it is a method where we call it as one, a property where we assign it
//   - the arity we emit is one the real signature accepts
//
// Run by `nimble test`. A drift here fails the build rather than producing a
// document nobody reads.

import fs from "node:fs";
import path from "node:path";
import ts from "typescript";

const root = process.cwd();
const domPath = path.join(root, "node_modules", "typescript", "lib", "lib.dom.d.ts");
if (!fs.existsSync(domPath)) {
  console.error("TypeScript lib.dom.d.ts is missing; run npm install first");
  process.exit(1);
}

// The contract, transcribed from the emitter in src/gene/web.nim. Each entry
// names the Gene operation, the DOM interface it lands on, the member, whether
// it is called or assigned, and the argument count we emit.
const contract = [
  // canvas — the 2D drawing surface
  ["canvas/context", "HTMLCanvasElement", "getContext", "call", 1],
  ["canvas/set_size (width)", "HTMLCanvasElement", "width", "assign"],
  ["canvas/set_size (height)", "HTMLCanvasElement", "height", "assign"],
  ["canvas/width", "HTMLCanvasElement", "width", "read"],
  ["canvas/height", "HTMLCanvasElement", "height", "read"],
  ["canvas/set_fill", "CanvasRenderingContext2D", "fillStyle", "assign"],
  ["canvas/set_stroke", "CanvasRenderingContext2D", "strokeStyle", "assign"],
  ["canvas/set_line_width", "CanvasRenderingContext2D", "lineWidth", "assign"],
  ["canvas/set_smoothing", "CanvasRenderingContext2D", "imageSmoothingEnabled", "assign"],
  ["canvas/fill_rect", "CanvasRenderingContext2D", "fillRect", "call", 4],
  ["canvas/stroke_rect", "CanvasRenderingContext2D", "strokeRect", "call", 4],
  ["canvas/clear_rect", "CanvasRenderingContext2D", "clearRect", "call", 4],
  ["canvas/draw_image", "CanvasRenderingContext2D", "drawImage", "call", 9],
  ["canvas/linear_gradient", "CanvasRenderingContext2D", "createLinearGradient", "call", 4],
  ["canvas/add_color_stop", "CanvasGradient", "addColorStop", "call", 2],
  // document, window, storage, timing
  ["dom/element", "Document", "getElementById", "call", 1],
  ["dom/create_element", "Document", "createElement", "call", 1],
  ["dom/append", "Node", "appendChild", "call", 1],
  ["dom/set_text", "Node", "textContent", "assign"],
  ["dom/text", "Node", "textContent", "read"],
  ["dom/set_class", "Element", "classList", "read"],
  ["dom/set_class (toggle)", "DOMTokenList", "toggle", "call", 2],
  ["dom/inner_width", "Window", "innerWidth", "read"],
  ["dom/inner_height", "Window", "innerHeight", "read"],
  ["dom/rect_*", "Element", "getBoundingClientRect", "call", 0],
  ["event/code", "KeyboardEvent", "code", "read"],
  ["event/key", "KeyboardEvent", "key", "read"],
  ["event/button", "MouseEvent", "button", "read"],
  ["event/client_x", "MouseEvent", "clientX", "read"],
  ["event/client_y", "MouseEvent", "clientY", "read"],
  ["event/delta_y", "WheelEvent", "deltaY", "read"],
  ["frame/request", "Window", "requestAnimationFrame", "call", 1],
  ["time/now", "Performance", "now", "call", 0],
  ["storage/get", "Storage", "getItem", "call", 1],
  ["storage/set", "Storage", "setItem", "call", 2],
  ["image/load (src)", "HTMLImageElement", "src", "assign"],
  ["image/load (onload)", "HTMLImageElement", "onload", "assign"],
  // events — the existing surface, checked by the same rule
  ["dom/prevent_default", "Event", "preventDefault", "call", 0],
  ["dom/stop_propagation", "Event", "stopPropagation", "call", 0],
  ["dom listener registration", "EventTarget", "addEventListener", "call", 2],
  ["dom listener removal", "EventTarget", "removeEventListener", "call", 2],
  // document construction — used by the generated DOM renderer
  ["dom/create_element", "Document", "createElement", "call", 1],
  ["dom/create_text_node", "Document", "createTextNode", "call", 1],
  ["dom/append_child", "Node", "appendChild", "call", 1],
  ["dom/remove_child", "Node", "removeChild", "call", 1],
  ["dom/set_attribute", "Element", "setAttribute", "call", 2],
  ["dom/remove_attribute", "Element", "removeAttribute", "call", 1],
];

const program = ts.createProgram([domPath], {
  noLib: true,
  types: [],
  target: ts.ScriptTarget.ES2022,
});
const checker = program.getTypeChecker();
const source = program.getSourceFile(domPath);
if (!source) {
  console.error(`could not load ${domPath}`);
  process.exit(1);
}

// Collect every interface declaration, merging the multiple declarations
// lib.dom.d.ts splits some interfaces across.
const interfaces = new Map();
for (const statement of source.statements) {
  if (!ts.isInterfaceDeclaration(statement)) continue;
  const name = statement.name.text;
  if (!interfaces.has(name)) interfaces.set(name, []);
  interfaces.get(name).push(statement);
}

// Walk the inheritance chain, because e.g. HTMLCanvasElement.addEventListener
// comes from EventTarget.
function membersOf(name, seen = new Set()) {
  if (seen.has(name)) return [];
  seen.add(name);
  const decls = interfaces.get(name);
  if (!decls) return [];
  const out = [];
  for (const decl of decls) {
    out.push(...decl.members);
    for (const clause of decl.heritageClauses ?? []) {
      for (const type of clause.types) {
        if (ts.isIdentifier(type.expression)) {
          out.push(...membersOf(type.expression.text, seen));
        }
      }
    }
  }
  return out;
}

let failures = 0;
const fail = (label, message) => {
  failures++;
  console.error(`  FAIL  ${label}: ${message}`);
};

for (const [label, ifaceName, member, kind, arity] of contract) {
  if (!interfaces.has(ifaceName)) {
    fail(label, `interface ${ifaceName} is not in lib.dom.d.ts`);
    continue;
  }
  const found = membersOf(ifaceName).filter(
    (m) => m.name && ts.isIdentifier(m.name) && m.name.text === member,
  );
  if (found.length === 0) {
    fail(label, `${ifaceName} has no member '${member}'`);
    continue;
  }

  if (kind === "call") {
    const signatures = found.filter(ts.isMethodSignature);
    if (signatures.length === 0) {
      fail(label, `${ifaceName}.${member} is not a method`);
      continue;
    }
    // At least one overload must accept the arity we emit.
    const ok = signatures.some((sig) => {
      const required = sig.parameters.filter(
        (p) => !p.questionToken && !p.dotDotDotToken,
      ).length;
      const max = sig.parameters.some((p) => p.dotDotDotToken)
        ? Infinity
        : sig.parameters.length;
      return arity >= required && arity <= max;
    });
    if (!ok) {
      const shapes = signatures
        .map((s) => `${s.parameters.length} params`)
        .join(", ");
      fail(label, `${ifaceName}.${member} accepts no ${arity}-argument form (${shapes})`);
      continue;
    }
  } else {
    // Modern lib.dom.d.ts declares many members as accessor pairs
    // (`get classList(): DOMTokenList; set classList(value: string);`) rather
    // than as `readonly` properties, so both spellings have to be understood
    // or the checker rejects real DOM members.
    const props = found.filter(ts.isPropertySignature);
    const getters = found.filter(ts.isGetAccessor);
    const setters = found.filter(ts.isSetAccessor);
    if (props.length === 0 && getters.length === 0 && setters.length === 0) {
      fail(label, `${ifaceName}.${member} is not a property or accessor`);
      continue;
    }
    if (kind === "assign") {
      const writableProp = props.some((p) => !p.modifiers?.some(
        (m) => m.kind === ts.SyntaxKind.ReadonlyKeyword,
      ));
      if (!writableProp && setters.length === 0) {
        fail(label, `${ifaceName}.${member} is readonly and cannot be assigned`);
        continue;
      }
    } else if (props.length === 0 && getters.length === 0) {
      fail(label, `${ifaceName}.${member} is write-only`);
      continue;
    }
  }
  console.log(`  ok    ${label.padEnd(28)} ${ifaceName}.${member}`);
}

const version = JSON.parse(
  fs.readFileSync(path.join(root, "node_modules", "typescript", "package.json"), "utf8"),
).version;
console.log(
  `\n${contract.length} host bindings checked against lib.dom.d.ts (TypeScript ${version})`,
);
if (failures > 0) {
  console.error(`${failures} FAILED — the web profile emits calls the DOM does not have`);
  process.exit(1);
}
