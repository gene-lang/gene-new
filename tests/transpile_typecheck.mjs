import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const gene = process.env.GENE_EXE
  ? resolve(process.env.GENE_EXE)
  : join(root, "bin", "gene");
const tsc = join(root, "node_modules", ".bin", "tsc");
if (!existsSync(gene)) {
  throw new Error("bin/gene is missing; run `nimble build` first");
}
if (!existsSync(tsc)) {
  throw new Error("TypeScript is missing; run `npm ci` first");
}

const work = mkdtempSync(join(tmpdir(), "gene-transpile-typecheck-"));
const sources = [
  join(root, "tests", "transpile", "web_slice.gene"),
  join(root, "benchmarks", "data", "transpile_web_equality.gene"),
  join(root, "tests", "transpile", "web_interop.gene"),
  join(root, "tests", "transpile", "web_advanced.gene"),
  join(root, "tests", "transpile", "web_namespace.gene"),
  join(root, "examples", "web_component.gene"),
];
for (const source of sources) {
  execFileSync(gene, ["build", "--target", "web", "--out-dir", work, source], {
    cwd: root,
    stdio: "ignore",
  });
}
copyFileSync(join(root, "tests", "transpile", "web_host.mjs"),
             join(work, "web_host.mjs"));

const generated = [
  join(work, "web_slice.ts"),
  join(work, "transpile_web_equality.ts"),
  join(work, "web_interop.ts"),
  join(work, "web_host.mjs"),
  join(work, "web_advanced.ts"),
  join(work, "web_namespace.ts"),
  join(work, "web_component.ts"),
  join(root, "web", "gene_dom.generated.d.ts"),
];
execFileSync(tsc, [
  "--noEmit",
  "--strict",
  "--allowJs",
  "--target", "ES2022",
  "--module", "NodeNext",
  "--moduleResolution", "NodeNext",
  ...generated,
], { cwd: root, stdio: "inherit" });
console.log("transpile typecheck: TypeScript 5.9.2 fixtures passed");
