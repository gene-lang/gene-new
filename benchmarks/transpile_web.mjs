import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { gzipSync } from "node:zlib";
import { performance } from "node:perf_hooks";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const gene = process.env.GENE_EXE
  ? resolve(process.env.GENE_EXE)
  : join(root, "bin", "gene");
const work = mkdtempSync(join(tmpdir(), "gene-transpile-web-"));
const fixtures = [
  ["core", "transpile_web_core.gene"],
  ["list_validation", "transpile_web_list.gene"],
  ["structural_equality", "transpile_web_equality.gene"],
  ["callback_boundary", "transpile_web_callback.gene"],
  ["structural_map", "transpile_web_map.gene"],
  ["protocol_dispatch", "transpile_web_protocol.gene"],
  ["closed_schema", "transpile_web_schema.gene"],
  ["stream", "transpile_web_stream.gene"],
  ["cancellation", "transpile_web_cancellation.gene"],
  ["dom", "transpile_web_dom.gene"],
];

// Fixed dependency-free minifier v1. Generated modules are line-oriented and
// semicolon-terminated, so dropping comments/indentation and joining lines is
// semantics-preserving for this emitter. Keeping this here pins the size tool.
function minifyV1(source) {
  return source
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("//"))
    .join("");
}

function build(source, outDir) {
  execFileSync(gene, ["build", "--target", "web", "--out-dir", outDir, source], {
    cwd: root,
    stdio: "ignore",
  });
}

const sizes = [];
for (const [feature, file] of fixtures) {
  const source = join(root, "benchmarks", "data", file);
  const outDir = join(work, feature);
  build(source, outDir);
  const base = file.slice(0, -5);
  const emitted = readFileSync(join(outDir, `${base}.mjs`), "utf8");
  const minified = minifyV1(emitted);
  sizes.push({
    feature,
    readable_bytes: Buffer.byteLength(emitted),
    minified_bytes: Buffer.byteLength(minified),
    gzip_bytes: gzipSync(minified, { level: 9 }).byteLength,
  });
}

const compileSource = join(root, "benchmarks", "data", "transpile_web_runtime.gene");
const compileOut = join(work, "compile");
build(compileSource, compileOut);
const compileSamples = [];
for (let i = 0; i < 25; i++) {
  const start = performance.now();
  build(compileSource, compileOut);
  compileSamples.push(performance.now() - start);
}
compileSamples.sort((a, b) => a - b);

const runtimeModule = join(compileOut, "transpile_web_runtime.mjs");
const runtimeProbe = join(work, "runtime_probe.mjs");
writeFileSync(runtimeProbe, `
import { work } from ${JSON.stringify(pathToFileURL(runtimeModule).href)};
const iterations = 1_000_000;
let value = 0n;
let total = 0n;
for (let i = 0; i < 100_000; i++) {
  value = (value + 1n) & 1023n;
  total += work(value);
}
if (globalThis.gc) globalThis.gc();
const heapBefore = process.memoryUsage().heapUsed;
const start = process.hrtime.bigint();
for (let i = 0; i < iterations; i++) {
  value = (value + 1n) & 1023n;
  total += work(value);
}
const elapsed = process.hrtime.bigint() - start;
if (globalThis.gc) globalThis.gc();
const heapAfter = process.memoryUsage().heapUsed;
console.log(JSON.stringify({
  ns_per_call: Number(elapsed) / iterations,
  retained_bytes_per_call: Math.max(0, heapAfter - heapBefore) / iterations,
  checksum: total.toString(),
}));
`);
const runtime = spawnSync(process.execPath, ["--expose-gc", runtimeProbe], {
  cwd: root,
  encoding: "utf8",
});
if (runtime.status !== 0) {
  process.stderr.write(runtime.stderr || runtime.stdout);
  process.exit(runtime.status ?? 1);
}

const report = {
  node: process.version,
  minifier: "gene-line-minifier-v1",
  compile_median_ms: compileSamples[Math.floor(compileSamples.length / 2)],
  runtime: JSON.parse(runtime.stdout),
  sizes,
};
console.log(JSON.stringify(report, null, 2));
